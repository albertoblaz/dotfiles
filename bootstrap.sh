#!/usr/bin/env bash
#
# macOS dev-machine bootstrap (personal)
# ======================================
# Provisions a fresh Mac with my personal dev toolset. Idempotent: safe to
# re-run — every step skips whatever is already present.
#
# Usage:
#   ./bootstrap.sh                       # install everything
#   BOOTSTRAP_DRYRUN=1 ./bootstrap.sh    # print commands, change nothing
#
# Policy: prefer Homebrew wherever a formula/cask exists; use official curl
# installers only where none does (Claude Code, rtk, oh-my-zsh).

set -euo pipefail

# ---------------------------------------------------------------------------
# Colors & logging
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
# Dry-run wrappers
# ---------------------------------------------------------------------------
DRYRUN="${BOOTSTRAP_DRYRUN:-0}"
run() {
  if [[ "$DRYRUN" == "1" ]]; then echo -e "${YELLOW}[dry-run]${NC} $*"; else "$@"; fi
}
run_sh() {
  if [[ "$DRYRUN" == "1" ]]; then echo -e "${YELLOW}[dry-run]${NC} $*"; else bash -c "$*"; fi
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
GITHUB_USER="albertoblaz"
GOOGLE_EMAIL="ablazquezrod@gmail.com"
MARKER_DIR="$HOME/.config/mac-bootstrap"

# Repos to clone into ~/git. golden-gamers additionally runs its own setup.sh.
REPOS=(
  golden-gamers
  dotfiles
  logseq-work
  golden-gamers-methodology
  logseq-books
  albertoblaz
  albertoblaz.github.io
)
GG_CLONE_DIR="$HOME/git/golden-gamers"

# Fresh machine fetches the sanitized pet config from the (public) dotfiles repo,
# then injects the real token from 1Password (never committed). Override via env.
PET_CONFIG_URL="${PET_CONFIG_URL:-https://raw.githubusercontent.com/${GITHUB_USER}/dotfiles/main/pet/config.toml}"
PET_OP_ITEM="${PET_OP_ITEM:-pet - Github Classic Token}"

# Email used as the SSH key comment.
GIT_EMAIL="$(git config --global user.email 2>/dev/null || true)"
if [[ -z "$GIT_EMAIL" ]]; then
  read -rp "Email for the new SSH key comment: " GIT_EMAIL
fi

echo -e "${GREEN}💻 macOS dev bootstrap (personal)${NC}"
echo "User: $GITHUB_USER   Workspace: $HOME/git"
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
if [[ -n "${BREW_SHELLENV:-}" ]] && ! grep -qs 'brew shellenv' "$HOME/.zprofile" 2>/dev/null; then
  run_sh "echo '$BREW_SHELLENV' >> \"$HOME/.zprofile\""
fi

# ===========================================================================
# B. Homebrew formulae (CLI tools)
# ===========================================================================
section "CLI tools (brew formulae)"
FORMULAE=(git curl vim zsh gh mise pet 1password-cli)  # 1password-cli provides `op`
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
  rectangle        # window tiling manager
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

# ---------------------------------------------------------------------------
# Trello — no desktop app anymore; install as a Chrome app.
# ---------------------------------------------------------------------------
section "Trello (Chrome app)"
TRELLO_MARKER="$MARKER_DIR/trello-chrome-app"
if [[ -f "$TRELLO_MARKER" ]]; then
  ok "Trello Chrome app already set up (marker present)"
else
  info "Opening Trello in Chrome — install it via ⋮ ▸ Cast, save, and share ▸ Install page as app…"
  run mkdir -p "$MARKER_DIR"
  run_sh "open -a 'Google Chrome' 'https://trello.com' || true"
  run touch "$TRELLO_MARKER"
fi

# ---------------------------------------------------------------------------
# Sign in to Chrome with my Google account (creds in 1Password autofill it).
# ---------------------------------------------------------------------------
section "Chrome sign-in"
CHROME_SIGNIN_MARKER="$MARKER_DIR/chrome-signin-opened"
if [[ -f "$CHROME_SIGNIN_MARKER" ]]; then
  ok "Chrome sign-in already prompted (marker present)"
else
  info "Sign in to Chrome as $GOOGLE_EMAIL (1Password will autofill the password)."
  run mkdir -p "$MARKER_DIR"
  run_sh "open -a 'Google Chrome' 'https://accounts.google.com/ServiceLogin?continue=https://www.google.com' || true"
  run touch "$CHROME_SIGNIN_MARKER"
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
# E. mise (runtime manager) — the tool + shell activation
# ===========================================================================
section "mise"
if ! have mise; then
  error "mise not found on PATH after install — skipping mise setup."
else
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
  ok "mise ready"
fi

# ---------------------------------------------------------------------------
# Global Node (for personal CLI tools) + gws (@googleworkspace/cli).
# Per-project Node stays pinned by each repo's version file.
# ---------------------------------------------------------------------------
section "Global Node + gws"
if have mise; then
  run mise use -g node@lts
  if [[ "$DRYRUN" == "1" ]]; then
    echo -e "${YELLOW}[dry-run]${NC} mise exec -- npm install -g @googleworkspace/cli"
  elif mise exec -- npm ls -g @googleworkspace/cli >/dev/null 2>&1; then
    ok "gws already installed"
  else
    info "Installing gws (@googleworkspace/cli)…"
    run_sh "mise exec -- npm install -g @googleworkspace/cli" \
      || warn "Failed to install gws — install it manually: npm install -g @googleworkspace/cli"
  fi
else
  warn "mise unavailable — skipping global Node + gws."
fi

# ===========================================================================
# F. Xcode + iOS simulator
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
if ls -d /Applications/Xcode*.app >/dev/null 2>&1; then
  run sudo xcodebuild -license accept || true
  info "Downloading the iOS simulator runtime…"
  run xcodebuild -downloadPlatform iOS || warn "Could not download the iOS platform — do it in Xcode ▸ Settings ▸ Platforms."
fi

# ===========================================================================
# G. pet — config from dotfiles + token from 1Password, then sync
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
    # Read the item "$PET_OP_ITEM" if it exists; otherwise create it from a token
    # you paste in.
    if [[ "$DRYRUN" == "1" ]]; then
      echo -e "${YELLOW}[dry-run]${NC} op item get \"$PET_OP_ITEM\" (create if missing) → inject into access_token"
    elif have op; then
      if op account list >/dev/null 2>&1; then
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
# H. SSH key + store in 1Password + register on GitHub
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

section "Add SSH key to GitHub"
if ! have gh; then
  warn "gh not found — skipping GitHub key upload."
elif [[ "$DRYRUN" != "1" ]] && ! gh auth status >/dev/null 2>&1; then
  warn "gh is not authenticated — run 'gh auth login', then re-run to upload the key."
else
  # `gh ssh-key add` needs the write:public_key scope; default login scopes don't
  # include it. Refresh if it's missing.
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
# I. ~/git workspace + clone repos
# ===========================================================================
section "~/git workspace"
run mkdir -p "$HOME/git"
ok "$HOME/git ready"

section "Clone repos"
# Pre-trust github.com so the first SSH clone doesn't hang on the host-key prompt.
if [[ "$DRYRUN" == "1" ]] || ! ssh-keygen -F github.com >/dev/null 2>&1; then
  run_sh "ssh-keyscan -t ed25519,rsa github.com >> \"$HOME/.ssh/known_hosts\" 2>/dev/null" || true
fi
for repo in "${REPOS[@]}"; do
  dest="$HOME/git/$repo"
  if [[ -d "$dest/.git" ]]; then
    ok "$repo already cloned"
  else
    info "Cloning $repo…"
    run_sh "git clone 'git@github.com:${GITHUB_USER}/${repo}.git' '$dest'" \
      || warn "Clone failed for $repo — confirm the SSH key is active on GitHub."
  fi
done

# golden-gamers project setup lives in the repo itself (pinned Ruby/Node,
# Postgres, deps, first-time DB) — hand off to it.
section "golden-gamers project setup"
if [[ -x "$GG_CLONE_DIR/scripts/setup.sh" ]]; then
  run_sh "'$GG_CLONE_DIR/scripts/setup.sh'" \
    || warn "setup.sh failed — run it manually: $GG_CLONE_DIR/scripts/setup.sh"
elif [[ -d "$GG_CLONE_DIR" ]]; then
  warn "golden-gamers cloned but scripts/setup.sh not found — run project setup manually."
else
  warn "golden-gamers not cloned — skipping project setup."
fi

# ===========================================================================
echo
ok "Bootstrap complete."
warn "Some steps may need a human: Xcode (App Store / Apple ID), 1Password (unlock/signin),"
warn "gh (auth login + write:public_key scope), Chrome sign-in, Trello (install as Chrome app)."
info "golden-gamers deps + database were handled by its own scripts/setup.sh."
info "Open a new terminal so PATH / shell changes take effect."
