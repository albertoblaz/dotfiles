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
dryrun_note() { echo -e "${YELLOW}[dry-run]${NC} $*"; }
run()    { if [[ "$DRYRUN" == "1" ]]; then dryrun_note "$*"; else "$@"; fi; }
run_sh() { if [[ "$DRYRUN" == "1" ]]; then dryrun_note "$*"; else bash -c "$*"; fi; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

# Load an already-installed Homebrew onto PATH (Apple Silicon or Intel), and set
# BREW_SHELLENV to the line that reproduces it for shell persistence.
load_brew_env() {
  local p
  for p in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [[ -x "$p" ]] && { eval "$("$p" shellenv)"; BREW_SHELLENV="eval \"\$($p shellenv)\""; return 0; }
  done
  return 1
}

# True (0) when the 1Password CLI is connected; probed once, then cached.
op_connected() {
  [[ -n "${OP_CONNECTED:-}" ]] && return "$OP_CONNECTED"
  if have op && op account list >/dev/null 2>&1; then OP_CONNECTED=0; else OP_CONNECTED=1; fi
  return "$OP_CONNECTED"
}

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
HOST="$(hostname -s)"
MARKER_DIR="$HOME/.config/mac-bootstrap"
# Directory this script lives in (= the dotfiles repo) — source of .gitconfig etc.
DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Repos to clone into ~/git (alphabetical). golden-gamers additionally runs its
# own scripts/setup.sh.
REPOS=(
  albertoblaz
  albertoblaz.github.io
  dotfiles
  golden-gamers
  golden-gamers-methodology
  logseq-books
  logseq-work
)
GG_CLONE_DIR="$HOME/git/golden-gamers"

# Fresh machine fetches the sanitized pet config from the (public) dotfiles repo,
# then injects the real token from 1Password (never committed). Override via env.
PET_CONFIG_URL="${PET_CONFIG_URL:-https://raw.githubusercontent.com/${GITHUB_USER}/dotfiles/main/pet/config.toml}"
PET_OP_ITEM="${PET_OP_ITEM:-pet - Github Classic Token}"

# One email, reused for the git commit identity (.gitconfig) and the Chrome/Google
# sign-in. It's PII, so it's never committed — the repo's .gitconfig ships a
# WORK_EMAIL_ADDRESS placeholder that we substitute in the LOCAL copy only.
GOOGLE_EMAIL=""
read -rp "Your email (git config, Google sign-in): " GOOGLE_EMAIL || true

# Apply the repo's .gitconfig locally (COPY, not symlink, so we can fill the email
# placeholder without writing PII back into the public repo).
if [[ -f "$DOTFILES_DIR/.gitconfig" ]]; then
  if [[ -f "$HOME/.gitconfig" ]] && grep -qs 'gst = git status' "$HOME/.gitconfig"; then
    # A distinctive alias from our .gitconfig → it's already applied. Idempotent.
    ok "~/.gitconfig already applied"
  elif [[ -e "$HOME/.gitconfig" && ! -L "$HOME/.gitconfig" ]]; then
    warn "Existing ~/.gitconfig (not ours) — leaving it; merge $DOTFILES_DIR/.gitconfig manually."
  else
    run rm -f "$HOME/.gitconfig"                       # drop any symlink from older runs
    run cp "$DOTFILES_DIR/.gitconfig" "$HOME/.gitconfig"
    if [[ -n "$GOOGLE_EMAIL" ]]; then
      esc="${GOOGLE_EMAIL//\//\\/}"                    # escape '/' for sed
      run_sh "sed -i '' 's/WORK_EMAIL_ADDRESS/$esc/' \"$HOME/.gitconfig\""
      ok "Applied .gitconfig (email: $GOOGLE_EMAIL)"
    else
      warn "No email given — ~/.gitconfig keeps the WORK_EMAIL_ADDRESS placeholder; edit it manually."
    fi
  fi
fi

echo -e "${GREEN}💻 macOS dev bootstrap (personal)${NC}"
echo "User: $GITHUB_USER   Workspace: $HOME/git"
[[ "$DRYRUN" == "1" ]] && warn "DRY RUN — no changes will be made."

# ===========================================================================
# A. Homebrew (also installs the Xcode Command Line Tools)
# ===========================================================================
section "Homebrew"
# Load an already-installed brew onto PATH FIRST — otherwise `have brew` is false
# in a fresh shell and we'd needlessly re-download and re-run the installer.
BREW_SHELLENV=""
load_brew_env || true
if have brew; then
  ok "Homebrew already installed ($(brew --prefix))"
else
  info "Installing Homebrew (this also installs the Xcode Command Line Tools)…"
  run_sh '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
  load_brew_env || true   # load the just-installed brew onto PATH
fi
# Persist brew to future shells.
if [[ -n "$BREW_SHELLENV" ]] && ! grep -qs 'brew shellenv' "$HOME/.zprofile" 2>/dev/null; then
  run_sh "echo '$BREW_SHELLENV' >> \"$HOME/.zprofile\""
fi

# ===========================================================================
# B. Homebrew formulae (CLI tools)
# ===========================================================================
section "CLI tools (brew formulae)"
FORMULAE=(git curl vim zsh gh mise pet 1password-cli)  # 1password-cli provides `op`
# One `brew install` call installs them together (brew fetches bottles in
# parallel); already-installed formulae are skipped.
info "Installing: ${FORMULAE[*]}"
run brew install "${FORMULAE[@]}" || warn "One or more formulae failed — check output above."

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
  dropbox
  tailscale
  rectangle        # window tiling manager
  telegram
  whatsapp
  chatgpt          # ChatGPT for Mac
)
# One `brew install --cask` call installs them together (parallel fetch);
# already-installed casks are skipped.
info "Installing: ${CASKS[*]}"
run brew install --cask "${CASKS[@]}" || warn "One or more casks failed — check output above."

# ---------------------------------------------------------------------------
# Trello — no desktop app anymore; install as a Chrome app.
# Detect the ACTUAL installed Chrome PWA (Chrome installs web apps as .app
# bundles under ~/Applications/Chrome Apps.localized/). A marker only proved we
# opened the page, not that anything was installed — that gave false positives.
# ---------------------------------------------------------------------------
section "Trello (Chrome app)"
trello_app_installed() {
  compgen -G "$HOME/Applications/Chrome Apps.localized/*[Tt]rello*.app" >/dev/null 2>&1 \
    || compgen -G "$HOME/Applications/Chrome Apps/*[Tt]rello*.app" >/dev/null 2>&1 \
    || compgen -G "/Applications/*[Tt]rello*.app" >/dev/null 2>&1
}
if [[ "$DRYRUN" != "1" ]] && trello_app_installed; then
  ok "Trello Chrome app is installed"
else
  info "Trello Chrome app not detected — opening it in Chrome."
  info "Install it via ⋮ ▸ Cast, save, and share ▸ Install page as app…  (re-run to confirm)"
  run_sh "open -a 'Google Chrome' 'https://trello.com' || true"
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
  run_sh 'curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/master/install.sh | sh'
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
    dryrun_note "mise exec -- npm install -g @googleworkspace/cli"
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
pet_token_missing() {  # true when the config exists and access_token is still blank
  [[ -f "$PET_CONFIG" ]] && grep -qE '^[[:space:]]*access_token[[:space:]]*=[[:space:]]*""' "$PET_CONFIG"
}
if have pet; then
  PET_CONFIG="$HOME/.config/pet/config.toml"

  # 1. Ensure the config exists (download the sanitized one from dotfiles).
  if [[ ! -f "$PET_CONFIG" && "$DRYRUN" != "1" ]]; then
    info "No pet config — fetching sanitized config from dotfiles: $PET_CONFIG_URL"
    mkdir -p "$(dirname "$PET_CONFIG")"
    curl -fsSL "$PET_CONFIG_URL" -o "$PET_CONFIG" \
      || warn "Could not download pet config — run 'pet configure' manually."
  fi

  # 2. Inject the GitHub token from 1Password whenever access_token is still blank.
  #    This runs on EVERY re-run until the token is present — not only on first
  #    download — so a config written before 1Password was connected gets fixed.
  if [[ "$DRYRUN" == "1" ]]; then
    dryrun_note "if access_token blank: op item get \"$PET_OP_ITEM\" → write into config"
  elif pet_token_missing; then
    if op_connected; then
      PET_TOKEN="$(op item get "$PET_OP_ITEM" --fields type=concealed --reveal 2>/dev/null | head -1 || true)"
      if [[ -z "$PET_TOKEN" ]]; then
        warn "1Password item '$PET_OP_ITEM' not found or empty — let's set it."
        read -rsp "Paste the GitHub token for pet: " PET_TOKEN; echo
        if [[ -n "$PET_TOKEN" ]]; then
          op item create --category password --title "$PET_OP_ITEM" "password=$PET_TOKEN" >/dev/null 2>&1 \
            && ok "Created 1Password item '$PET_OP_ITEM'." \
            || warn "Couldn't create the 1Password item — writing the token to the config anyway."
        fi
      else
        info "Read pet token from 1Password item '$PET_OP_ITEM'."
      fi
      if [[ -n "$PET_TOKEN" ]]; then
        esc="${PET_TOKEN//\//\\/}"   # escape '/' for sed
        # Fill every blank access_token (Gist backend is the one pet uses).
        sed -i '' -E "s/^([[:space:]]*access_token[[:space:]]*=[[:space:]]*)\"\"/\1\"$esc\"/" "$PET_CONFIG" \
          && ok "Wrote the pet token into $PET_CONFIG" \
          || warn "Could not write token into $PET_CONFIG."
      else
        warn "No token available — set access_token in $PET_CONFIG manually."
      fi
    else
      warn "1Password CLI not connected — enable 1Password ▸ Settings ▸ Developer ▸"
      warn "  'Integrate with 1Password CLI', then re-run. Or set access_token in $PET_CONFIG."
    fi
  fi

  # 3. Sync only when the token is actually present.
  if [[ "$DRYRUN" == "1" ]]; then
    dryrun_note "pet sync (if access_token present)"
  elif [[ -f "$PET_CONFIG" ]] && ! pet_token_missing; then
    info "Syncing pet snippets from GitHub Gist…"
    pet sync || warn "pet sync failed — check the gist id/token in $PET_CONFIG."
  else
    warn "pet access_token still blank — skipping sync. Fill it and re-run (or 'pet configure')."
  fi
fi

# ===========================================================================
# H. SSH key (generated in 1Password as an SSH Key item) + register on GitHub
# ===========================================================================
# The op CLI can't IMPORT an existing private key as an "SSH Key" item (that's
# desktop-app only), so we GENERATE the key inside 1Password. The PRIVATE key
# never touches disk — the 1Password SSH agent serves it; we pull only the PUBLIC
# key (for the ssh-config IdentityFile and the GitHub upload). Falls back to a
# local on-disk key + Keychain when op isn't available. Override the vault with
# OP_VAULT=... if your keys don't live in "Personal".
section "SSH key (1Password SSH agent)"
SSH_KEY="$HOME/.ssh/id_ed25519"
OP_VAULT="${OP_VAULT:-Personal}"
SSH_ITEM_TITLE="${SSH_ITEM_TITLE:-SSH: $HOST}"
OP_SSH_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
run mkdir -p "$HOME/.ssh"
run chmod 700 "$HOME/.ssh"

# Append a block to ~/.ssh/config once (idempotent, keyed by a unique marker).
append_ssh_block() {  # <grep-marker> <block-text>
  local cfg="$HOME/.ssh/config"
  grep -qs "$1" "$cfg" 2>/dev/null && return 0
  if [[ "$DRYRUN" == "1" ]]; then dryrun_note "append ssh-config block matching /$1/ to $cfg"
  else printf '%s\n' "$2" >> "$cfg"; fi
}
pull_op_key() {  # <op-reference> <dest> <chmod-mode> <label> — idempotent
  if [[ -f "$2" ]]; then ok "$4 already present at $2"; return 0; fi
  if op read "$1" > "$2" 2>/dev/null && [[ -s "$2" ]]; then
    chmod "$3" "$2"; ok "Wrote $4 → $2"
  else
    rm -f "$2"; warn "Could not read the $4 from 1Password (vault '$OP_VAULT'?)."
  fi
}

if [[ "$DRYRUN" != "1" ]] && op_connected; then
  # 1. Ensure the SSH Key item exists in 1Password (idempotent — generate once).
  if op item get "$SSH_ITEM_TITLE" --vault "$OP_VAULT" >/dev/null 2>&1; then
    ok "1Password SSH Key item '$SSH_ITEM_TITLE' already exists"
  else
    info "Generating a new SSH Key in 1Password ('$SSH_ITEM_TITLE', vault $OP_VAULT)…"
    op item create --category ssh --title "$SSH_ITEM_TITLE" --vault "$OP_VAULT" >/dev/null \
      && ok "Created 1Password SSH Key item" \
      || warn "Could not create the SSH Key item in 1Password."
  fi
  # 2. Pull ONLY the public key — the private key stays in 1Password (agent-served).
  pull_op_key "op://$OP_VAULT/$SSH_ITEM_TITLE/public key" "$SSH_KEY.pub" 644 "public key"
  # 3. Point ssh at the 1Password agent, and restrict GitHub to just this key so
  #    it authorizes once per session instead of once per key.
  append_ssh_block '1password/t/agent.sock' "Host *
  IdentityAgent \"$OP_SSH_SOCK\"
"
  append_ssh_block '^Host github.com' "Host github.com
  IdentitiesOnly yes
  IdentityFile $SSH_KEY.pub
"
  # 4. The agent itself must be enabled in the app (one-time, can't be scripted).
  if [[ -S "$OP_SSH_SOCK" ]]; then
    ok "1Password SSH agent is enabled"
  else
    warn "1Password SSH agent is OFF — enable it: 1Password ▸ Settings ▸ Developer ▸ 'Use the SSH agent'."
    warn "  One-time in-app toggle (can't be scripted). Opening 1Password; re-run after so clones can auth."
    open -a "1Password" 2>/dev/null || true
  fi
elif [[ "$DRYRUN" == "1" ]]; then
  dryrun_note "ensure 1Password SSH Key item '$SSH_ITEM_TITLE', pull public key → $SSH_KEY.pub,"
  dryrun_note "configure ~/.ssh/config for the 1Password SSH agent (private key stays in 1Password)"
  append_ssh_block '1password/t/agent.sock' ""
  append_ssh_block '^Host github.com' ""
else
  # Fallback: no op — local on-disk key + Keychain (no agent available).
  warn "1Password CLI not available/connected — using a local on-disk key + Keychain instead."
  warn "  (Enable 1Password ▸ Settings ▸ Developer ▸ Integrate with 1Password CLI to store it as an SSH Key item.)"
  if [[ -f "$SSH_KEY" ]]; then
    ok "SSH key already exists — not overwriting ($SSH_KEY)"
  else
    run ssh-keygen -t ed25519 -C "$GOOGLE_EMAIL" -f "$SSH_KEY" -N ""
    run chmod 600 "$SSH_KEY"; run chmod 644 "${SSH_KEY}.pub"
  fi
  append_ssh_block 'UseKeychain yes' "Host *
  AddKeysToAgent yes
  UseKeychain yes
  IdentityFile $SSH_KEY
"
  [[ -f "$SSH_KEY" ]] && ssh-add --apple-use-keychain "$SSH_KEY" 2>/dev/null || true
fi

section "Add SSH key to GitHub"
if ! have gh; then
  warn "gh not found — skipping GitHub key upload."
elif [[ "$DRYRUN" == "1" ]]; then
  dryrun_note "gh auth login (if not authenticated), then gh ssh-key add ${SSH_KEY}.pub"
else
  # If gh isn't authenticated, walk the user through `gh auth login`. Scopes come
  # from the token, so no --scopes flag is needed with a PAT — just make sure the
  # PAT has write:public_key (admin:public_key). Choosing the SSH protocol during
  # login also offers to upload this public key, which registers it directly.
  # Authenticate once on the happy path; only re-check if we had to run login.
  if gh auth status >/dev/null 2>&1; then
    gh_authed=1
  else
    info "gh is not authenticated — starting 'gh auth login'…"
    info "Suggested answers: github.com · SSH · your ~/.ssh/id_ed25519 key · title 'gh' · authenticate with your PAT."
    gh auth login || warn "gh auth login was cancelled or failed."
    gh auth status >/dev/null 2>&1 && gh_authed=1 || gh_authed=0
  fi
  if [[ "$gh_authed" != "1" ]]; then
    warn "gh still not authenticated — add ${SSH_KEY}.pub manually at https://github.com/settings/keys."
  elif [[ ! -f "${SSH_KEY}.pub" ]]; then
    warn "No public key at ${SSH_KEY}.pub — skipping GitHub upload (SSH key setup didn't complete)."
  else
    # Ensure the key is registered. The SSH-protocol login may already have added
    # it; a repeat add returns "already in use", which we treat as success.
    if add_out="$(gh ssh-key add "${SSH_KEY}.pub" --title "$HOST" 2>&1)"; then
      ok "Registered SSH key on GitHub"
    elif grep -qiE 'already' <<<"$add_out"; then
      ok "SSH key already registered on GitHub"
    else
      warn "Could not add the key to GitHub:"
      warn "  $add_out"
      warn "Your PAT likely needs the write:public_key (admin:public_key) scope, or add"
      warn "  ${SSH_KEY}.pub manually at https://github.com/settings/keys."
    fi
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
# Clone the missing repos in parallel, then wait for all of them.
clone_pids=()
for repo in "${REPOS[@]}"; do
  dest="$HOME/git/$repo"
  if [[ -d "$dest/.git" ]]; then
    ok "$repo already cloned"
  elif [[ -d "$dest" ]]; then
    # Directory exists but isn't a git repo — don't clone into it (git would
    # refuse a non-empty target anyway). Skip and let the user sort it out.
    warn "$repo: $dest exists but isn't a git repo — skipping clone."
  elif [[ "$DRYRUN" == "1" ]]; then
    dryrun_note "git clone git@github.com:${GITHUB_USER}/${repo}.git $dest (parallel)"
  else
    info "Cloning $repo…"
    ( git clone "git@github.com:${GITHUB_USER}/${repo}.git" "$dest" >/dev/null 2>&1 \
        && ok "cloned $repo" \
        || warn "Clone failed for $repo — confirm the SSH key is active on GitHub." ) &
    clone_pids+=("$!")
  fi
done
[[ ${#clone_pids[@]} -gt 0 ]] && wait "${clone_pids[@]}" 2>/dev/null || true

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
