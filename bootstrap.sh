#!/usr/bin/env bash
#
# macOS dev-machine bootstrap
# ===========================
# Provisions a fresh Mac with the full Golden Gamers dev toolset. Idempotent:
# safe to re-run — every step skips whatever is already present.
#
# Usage:
#   ./scripts/bootstrap.sh              # install everything
#   BOOTSTRAP_DRYRUN=1 ./scripts/bootstrap.sh   # print commands, change nothing
#
# Policy: prefer Homebrew wherever a formula/cask exists; use official curl
# installers only where none does (Claude Code, rtk, oh-my-zsh). Languages are
# pinned to the repo's version files; Postgres is pinned to prod's major.

set -euo pipefail

# ---------------------------------------------------------------------------
# Colors & logging (matches scripts/ggdev/install.sh style)
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}➜${NC} $*"; }
ok()      { echo -e "${GREEN}✓${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠${NC} $*"; }
error()   { echo -e "${RED}✗${NC} $*" >&2; }
section() { echo; echo -e "${BLUE}==>${NC} ${1}"; echo "------------------------------------------------------------"; }

# ---------------------------------------------------------------------------
# Dry-run wrapper: `run <cmd...>` executes, or just prints under BOOTSTRAP_DRYRUN
# ---------------------------------------------------------------------------
DRYRUN="${BOOTSTRAP_DRYRUN:-0}"
run() {
  if [[ "$DRYRUN" == "1" ]]; then
    echo -e "${YELLOW}[dry-run]${NC} $*"
  else
    "$@"
  fi
}
# Same, but for a shell pipeline passed as a single string.
run_sh() {
  if [[ "$DRYRUN" == "1" ]]; then
    echo -e "${YELLOW}[dry-run]${NC} $*"
  else
    bash -c "$*"
  fi
}

# ---------------------------------------------------------------------------
# Idempotency helpers
# ---------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }
brew_has_formula() { brew list --formula --versions "$1" >/dev/null 2>&1; }
brew_has_cask()    { brew list --cask --versions "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Guard: macOS only
# ---------------------------------------------------------------------------
if [[ "$(uname -s)" != "Darwin" ]]; then
  error "This script targets macOS only (detected: $(uname -s))."
  exit 1
fi

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
PG_VERSION=16

GITHUB_USER="albertoblaz"
REPO_SSH_URL="git@github.com:${GITHUB_USER}/golden-gamers.git"
CLONE_DIR="$HOME/git/golden-gamers"
# Ruby/Node are pinned by golden-gamers' own version files (backend/.ruby-version,
# frontend/.node-version); mise reads them after the repo is cloned below.

# Fresh machine fetches the sanitized pet config from the (public) dotfiles repo,
# then injects the real token from 1Password (never committed). Override via env.
PET_CONFIG_URL="${PET_CONFIG_URL:-https://raw.githubusercontent.com/${GITHUB_USER}/dotfiles/main/pet/config.toml}"
# 1Password item holding the GitHub token pet uses for Gist sync.
PET_OP_ITEM="${PET_OP_ITEM:-pet - Github Classic Token}"

# Email used as the SSH key comment.
GIT_EMAIL="$(git config --global user.email 2>/dev/null || true)"
if [[ -z "$GIT_EMAIL" ]]; then
  read -rp "Email for the new SSH key comment: " GIT_EMAIL
fi

echo -e "${GREEN}🎮 Golden Gamers — macOS dev bootstrap${NC}"
echo "Clone target: $CLONE_DIR   Postgres: $PG_VERSION"
echo "Ruby/Node:    installed by the repo's scripts/setup.sh after clone"
[[ "$DRYRUN" == "1" ]] && warn "DRY RUN — no changes will be made."

# ===========================================================================
# A. Homebrew (also installs the Xcode Command Line Tools)
# ===========================================================================
section "Homebrew"
if have brew; then
  ok "Homebrew already installed"
else
  info "Installing Homebrew (this also installs the Xcode Command Line Tools)…"
  run_sh '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
fi
# Ensure brew is on PATH for the rest of this run (Apple Silicon vs Intel).
if [[ -x /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
  BREW_SHELLENV='eval "$(/opt/homebrew/bin/brew shellenv)"'
elif [[ -x /usr/local/bin/brew ]]; then
  eval "$(/usr/local/bin/brew shellenv)"
  BREW_SHELLENV='eval "$(/usr/local/bin/brew shellenv)"'
fi
# Persist brew to future shells.
if [[ -n "${BREW_SHELLENV:-}" ]] && ! grep -qs 'brew shellenv' "$HOME/.zprofile" 2>/dev/null; then
  run_sh "echo '$BREW_SHELLENV' >> \"$HOME/.zprofile\""
fi

# ===========================================================================
# B. Homebrew formulae (CLI tools)
# ===========================================================================
section "CLI tools (brew formulae)"
FORMULAE=(curl vim zsh gh mise pet "postgresql@${PG_VERSION}")
# 1Password CLI provides `op`.
FORMULAE+=(1password-cli)
for f in "${FORMULAE[@]}"; do
  if brew_has_formula "$f"; then
    ok "$f already installed"
  else
    info "Installing $f…"
    run brew install "$f" || warn "Failed to install $f — continuing."
  fi
done

# ===========================================================================
# C. Homebrew casks (GUI apps)
# ===========================================================================
section "Applications (brew casks)"
CASKS=(
  ghostty          # terminal
  claude           # Claude Desktop
  logseq
  1password
  zed
  google-chrome
  spotify
  docker           # Docker Desktop
  tailscale
  telegram
  whatsapp
  chatgpt          # ChatGPT for Mac
)
for c in "${CASKS[@]}"; do
  if brew_has_cask "$c"; then
    ok "$c already installed"
  else
    info "Installing $c…"
    run brew install --cask "$c" || warn "Failed to install $c — continuing."
  fi
done

# Trello: Atlassian discontinued the desktop app and the Homebrew cask was
# removed, so install it as a web app. If the cask ever returns, prefer it.
section "Trello (web app)"
TRELLO_MARKER="$HOME/.config/gg-bootstrap/trello-webapp-opened"
if brew info --cask trello >/dev/null 2>&1; then
  if brew_has_cask trello; then ok "trello already installed"; else
    info "Installing trello desktop app…"; run brew install --cask trello || warn "Failed to install trello."
  fi
elif [[ -f "$TRELLO_MARKER" ]]; then
  ok "Trello web app already set up (marker present)"
else
  warn "No Trello desktop app/cask exists anymore — opening the web app to install it."
  info "In the browser: use 'Add to Dock' (Safari) or Chrome ▸ Install to pin it as an app."
  run mkdir -p "$(dirname "$TRELLO_MARKER")"
  run_sh "open 'https://trello.com' || true"
  run touch "$TRELLO_MARKER"
fi

# ===========================================================================
# D. Tools without a Homebrew formula (official curl installers)
# ===========================================================================
section "oh-my-zsh"
if [[ -d "$HOME/.oh-my-zsh" ]]; then
  ok "oh-my-zsh already installed"
else
  info "Installing oh-my-zsh (unattended)…"
  run_sh 'RUNZSH=no CHSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"'
fi

section "Claude Code"
if have claude; then
  ok "Claude Code already installed"
else
  info "Installing Claude Code…"
  run_sh 'curl -fsSL https://claude.ai/install.sh | bash'
fi

section "rtk (Rust Token Killer)"
if have rtk || [[ -x "$HOME/.local/bin/rtk" ]]; then
  ok "rtk already installed"
else
  info "Installing rtk…"
  run_sh 'curl -fsSL https://raw.githubusercontent.com/nikvdp/rtk/main/install.sh | sh'
fi

# ===========================================================================
# E. mise setup (languages installed later, from the golden-gamers clone)
# ===========================================================================
section "mise setup"
if ! have mise; then
  error "mise not found on PATH after install — skipping mise setup."
else
  # Activate mise for this shell so later `mise install`/`use` work now.
  if [[ "$DRYRUN" != "1" ]]; then eval "$(mise activate bash)"; fi
  # Persist activation to shells (map rc file → shell name explicitly).
  add_mise_activate() {
    local rc="$1" shell="$2"
    [[ -f "$rc" ]] || run touch "$rc"
    if ! grep -qs 'mise activate' "$rc"; then
      run_sh "echo 'eval \"\$(mise activate $shell)\"' >> \"$rc\""
    fi
  }
  add_mise_activate "$HOME/.zshrc" zsh
  add_mise_activate "$HOME/.bashrc" bash
  ok "mise ready — golden-gamers' scripts/setup.sh installs the pinned Ruby/Node."
fi

# ===========================================================================
# F. PostgreSQL (pinned to prod's major)
# ===========================================================================
section "PostgreSQL ${PG_VERSION}"
if brew_has_formula "postgresql@${PG_VERSION}"; then
  ok "postgresql@${PG_VERSION} already installed"
  run brew services start "postgresql@${PG_VERSION}" || true
else
  info "Installing postgresql@${PG_VERSION}…"
  run brew install "postgresql@${PG_VERSION}"
  run brew services start "postgresql@${PG_VERSION}"
fi
# Put this Postgres' bin on PATH (keg-only formula).
if have brew; then
  PG_BIN="$(brew --prefix)/opt/postgresql@${PG_VERSION}/bin"
  if [[ -d "$PG_BIN" ]] && ! grep -qs "postgresql@${PG_VERSION}/bin" "$HOME/.zprofile" 2>/dev/null; then
    run_sh "echo 'export PATH=\"$PG_BIN:\$PATH\"' >> \"$HOME/.zprofile\""
  fi
fi

# ===========================================================================
# G. Xcode + iOS simulator
# ===========================================================================
section "Xcode Command Line Tools"
if xcode-select -p >/dev/null 2>&1; then
  ok "Command Line Tools present ($(xcode-select -p))"
else
  info "Installing Command Line Tools…"
  run xcode-select --install
fi

section "Xcode (full IDE) + iPhone simulator"
if ls -d /Applications/Xcode*.app >/dev/null 2>&1; then
  ok "Xcode already installed"
else
  warn "Xcode is a first-party app — install it from the Mac App Store (needs an Apple ID)."
  info "Opening the App Store to the Xcode page…"
  run_sh "open 'macappstore://apps.apple.com/app/xcode/id497799835' || open 'https://apps.apple.com/app/xcode/id497799835' || true"
  warn "After Xcode finishes installing, re-run this script to accept the license and fetch the iOS simulator."
fi
# License + simulator runtime (only once Xcode is actually installed).
if ls -d /Applications/Xcode*.app >/dev/null 2>&1; then
  run sudo xcodebuild -license accept || true
  info "Downloading the iOS simulator runtime…"
  run xcodebuild -downloadPlatform iOS || warn "Could not download the iOS platform — do it in Xcode ▸ Settings ▸ Platforms."
fi

# ===========================================================================
# H. pet sync (pull snippets from GitHub Gist)
# ===========================================================================
section "pet sync"
if have pet; then
  PET_CONFIG="$HOME/.config/pet/config.toml"
  if [[ ! -f "$PET_CONFIG" ]]; then
    info "No pet config — fetching sanitized config from dotfiles: $PET_CONFIG_URL"
    run mkdir -p "$(dirname "$PET_CONFIG")"
    run_sh "curl -fsSL '$PET_CONFIG_URL' -o '$PET_CONFIG'" \
      || warn "Could not download pet config — run 'pet configure' manually."
    # The committed config has a blank token; inject the real one from 1Password.
    # Read the item "$PET_OP_ITEM" if it exists; otherwise create it from a
    # token you paste in.
    if [[ "$DRYRUN" == "1" ]]; then
      echo -e "${YELLOW}[dry-run]${NC} op item get \"$PET_OP_ITEM\" (create if missing) → inject into access_token"
    elif have op; then
      if op account list >/dev/null 2>&1; then
        # Try to read the token from the existing item (any concealed field).
        PET_TOKEN="$(op item get "$PET_OP_ITEM" --fields type=concealed --reveal 2>/dev/null | head -1 || true)"
        if [[ -z "$PET_TOKEN" ]]; then
          warn "1Password item '$PET_OP_ITEM' not found — let's create it."
          read -rsp "Paste the GitHub classic token for pet: " PET_TOKEN; echo
          if [[ -n "$PET_TOKEN" ]]; then
            op item create --category password --title "$PET_OP_ITEM" "password=$PET_TOKEN" >/dev/null \
              && ok "Created 1Password item '$PET_OP_ITEM'." \
              || warn "Could not create the 1Password item — store the token manually."
          fi
        else
          info "Read pet token from 1Password item '$PET_OP_ITEM'."
        fi
        if [[ -n "$PET_TOKEN" ]]; then
          esc="${PET_TOKEN//\//\\/}"   # escape '/' for sed
          sed -i '' -E "s/^([[:space:]]*access_token[[:space:]]*=[[:space:]]*)\"\"/\1\"$esc\"/" "$PET_CONFIG" \
            || warn "Could not write token into $PET_CONFIG."
        else
          warn "No token available — set the access_token in $PET_CONFIG manually."
        fi
      else
        warn "1Password not signed in — set the pet gist token in $PET_CONFIG manually."
      fi
    fi
  fi
  if [[ "$DRYRUN" == "1" || -f "$PET_CONFIG" ]]; then
    info "Syncing pet snippets from GitHub Gist…"
    run pet sync || warn "pet sync failed — check gist id/token in $PET_CONFIG."
  fi
fi

# ===========================================================================
# I. SSH key + store in 1Password
# ===========================================================================
section "SSH key"
SSH_KEY="$HOME/.ssh/id_ed25519"
run mkdir -p "$HOME/.ssh"
run chmod 700 "$HOME/.ssh"
if [[ -f "$SSH_KEY" ]]; then
  ok "SSH key already exists — not overwriting ($SSH_KEY)"
else
  info "Generating a new ed25519 SSH key…"
  run ssh-keygen -t ed25519 -C "$GIT_EMAIL" -f "$SSH_KEY" -N ""
  run chmod 600 "$SSH_KEY"
  run chmod 644 "${SSH_KEY}.pub"
  # Configure the agent + Keychain.
  if ! grep -qs "id_ed25519" "$HOME/.ssh/config" 2>/dev/null; then
    run_sh "printf 'Host *\n  AddKeysToAgent yes\n  UseKeychain yes\n  IdentityFile %s\n' '$SSH_KEY' >> \"$HOME/.ssh/config\""
  fi
  run ssh-add --apple-use-keychain "$SSH_KEY" || true
fi

section "Store SSH key in 1Password"
if have op; then
  if [[ "$DRYRUN" != "1" ]] && ! op account list >/dev/null 2>&1; then
    warn "1Password CLI not signed in — run 'op signin' (or enable desktop app integration), then re-run."
  else
    TITLE="SSH: $(hostname -s) id_ed25519"
    if [[ "$DRYRUN" != "1" ]] && op document get "$TITLE" >/dev/null 2>&1; then
      ok "SSH key already stored in 1Password ($TITLE)"
    else
      info "Uploading private key to 1Password as a document…"
      run op document create "$SSH_KEY" --title "$TITLE" \
        || warn "Could not upload to 1Password — store $SSH_KEY manually."
    fi
  fi
else
  warn "1Password CLI (op) not found — cannot store the SSH key automatically."
fi

# ---------------------------------------------------------------------------
# Register the public key on GitHub (needed before the SSH clone below).
# ---------------------------------------------------------------------------
section "Add SSH key to GitHub"
if ! have gh; then
  warn "gh not found — skipping GitHub key upload."
elif [[ "$DRYRUN" != "1" ]] && ! gh auth status >/dev/null 2>&1; then
  warn "gh is not authenticated — run 'gh auth login', then re-run to upload the key."
else
  # `gh ssh-key add` needs the write:public_key scope; the default login scopes
  # (repo, read:org, project) don't include it. Refresh if it's missing.
  if [[ "$DRYRUN" != "1" ]] && ! gh auth status 2>&1 | grep -qiE 'public_key'; then
    warn "gh token lacks the write:public_key scope — requesting it (opens a browser)…"
    run gh auth refresh -h github.com -s write:public_key || warn "Scope refresh failed; upload the key manually with 'gh ssh-key add'."
  fi
  KEY_TITLE="$(hostname -s) (bootstrap)"
  if [[ "$DRYRUN" != "1" ]] && gh ssh-key list 2>/dev/null | grep -qF "$(awk '{print $2}' "${SSH_KEY}.pub" 2>/dev/null)"; then
    ok "This key is already registered on GitHub"
  else
    info "Uploading public key to GitHub…"
    run gh ssh-key add "${SSH_KEY}.pub" --title "$KEY_TITLE" \
      || warn "Could not add key to GitHub — add ${SSH_KEY}.pub manually at github.com/settings/keys."
  fi
fi

# ===========================================================================
# J. ~/git workspace + clone the repo
# ===========================================================================
section "~/git workspace"
run mkdir -p "$HOME/git"
ok "$HOME/git ready"

section "Clone golden-gamers"
if [[ -d "$CLONE_DIR/.git" ]]; then
  ok "Repo already cloned at $CLONE_DIR"
else
  # Pre-trust github.com so the first SSH clone doesn't hang on the host-key
  # prompt (critical for an unattended fresh-Mac run).
  if [[ "$DRYRUN" == "1" ]] || ! ssh-keygen -F github.com >/dev/null 2>&1; then
    run_sh "ssh-keyscan -t ed25519,rsa github.com >> \"$HOME/.ssh/known_hosts\" 2>/dev/null" || true
  fi
  info "Cloning $REPO_SSH_URL → $CLONE_DIR (uses the SSH key just registered)…"
  run_sh "git clone '$REPO_SSH_URL' '$CLONE_DIR'" \
    || warn "Clone failed — confirm the SSH key is active on GitHub, then: git clone $REPO_SSH_URL $CLONE_DIR"
fi

# Hand off project setup to the repo's own script. Everything golden-gamers
# specific — the pinned Ruby/Node install and the backend/frontend deps — lives
# in scripts/setup.sh inside the repo, not here.
section "Project setup (golden-gamers/scripts/setup.sh)"
if [[ -x "$CLONE_DIR/scripts/setup.sh" ]]; then
  run_sh "'$CLONE_DIR/scripts/setup.sh'" \
    || warn "setup.sh failed — run it manually: $CLONE_DIR/scripts/setup.sh"
elif [[ -d "$CLONE_DIR" ]]; then
  warn "Clone present but scripts/setup.sh not found — run project setup manually."
else
  warn "Repo not cloned — skipping project setup."
fi

# ===========================================================================
echo
ok "Bootstrap complete."
warn "Some steps may need a human: Xcode (App Store / Apple ID), 1Password (unlock/signin),"
warn "gh (auth login + write:public_key scope for the SSH key), Trello (Add to Dock in browser)."
info "Ruby/Node + project deps were handled by golden-gamers/scripts/setup.sh."
info "Open a new terminal so PATH / shell changes take effect."
