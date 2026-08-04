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

# A root-owned directory that an installer created under a restrictive umask is
# left mode 700, which hides everything inside it: `docker`, `kubectl` and
# `tailscale` are all "command not found" even though the symlinks are present
# and correct. Nothing self-heals it — later installers add links but never
# chmod a directory they didn't create. Asks the question that matters (can I
# traverse it?) rather than comparing a mode string, the same way the
# ~/.local/bin check below asks a fresh shell instead of grepping.
#
# Deliberately says NOTHING on the happy path — no "✓ already traversable".
# It's called at more than one point, so a success line would print twice on
# every healthy run to report that nothing happened. Only the broken path is
# worth output. Don't add one.
ensure_traversable() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0                 # doesn't exist — nothing to fix
  [[ -r "$dir" && -x "$dir" ]] && return 0
  warn "$dir is $(stat -f '%Sp' "$dir") — its contents are hidden from you."
  if run sudo chmod 755 "$dir"; then
    # run() only *prints* the command under DRYRUN, so it reports success
    # without having chmod'd anything — hence the guard, or a dry run would
    # claim it set a mode it didn't touch.
    [[ "$DRYRUN" == "1" ]] || ok "Set $dir to 755"
  else
    warn "Could not chmod $dir."
    pending "$dir isn't traversable; run: sudo chmod 755 $dir"
  fi
}

# True (0) when the 1Password CLI is connected AND signed in; probed once, then
# cached. `op vault list` rather than `op account list`: the latter succeeds as
# soon as an account is registered, even while signed out, so it reports a
# working CLI right up until the first read fails. Listing vaults is the
# cheapest call that actually needs an authenticated session.
op_connected() {
  [[ -n "${OP_CONNECTED:-}" ]] && return "$OP_CONNECTED"
  if have op && op vault list >/dev/null 2>&1; then OP_CONNECTED=0; else OP_CONNECTED=1; fi
  return "$OP_CONNECTED"
}

# True (0) when stdin is a terminal. Guards every pause, so an unattended run
# never hangs.
interactive() { [[ -t 0 ]]; }

# Work that outlives the run, reported at the end. Steps that prompt inline
# (gh auth login, the GitHub SSH check) don't belong here.
PENDING=()
pending() { PENDING+=("$1"); }

# Single owner of the EXIT trap, so later additions have one obvious home
# instead of silently replacing someone else's trap.
SUDO_KEEPALIVE_PID=""
cleanup() {
  [[ -n "$SUDO_KEEPALIVE_PID" ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
  return 0
}
trap cleanup EXIT

# Re-run <check> until it succeeds, prompting between attempts. Returns 1 if the
# user skips or the run is unattended. Used by the GitHub SSH auth check before
# cloning.
wait_until() {  # <check-fn> <prompt> <pending-message>
  local check="$1" prompt="$2" pending_msg="$3" ans=""
  while ! "$check"; do
    if ! interactive; then
      warn "  Unattended run — continuing without it."
      pending "$pending_msg"; return 1
    fi
    read -rp "$prompt" ans || return 1
    case "$ans" in [sS]*) warn "  Skipped."; pending "$pending_msg"; return 1 ;; esac
  done
}

# `brew install a b c` aborts at the first failure, silently skipping everything
# after it. Install one at a time so a failure costs only that item; fetch up
# front so the downloads still overlap. --adopt takes over a matching app that's
# already in /Applications instead of calling it a conflict.
brew_install_each() {  # <formula|cask> <item…>
  local kind="$1"; shift
  local item installed missing=() failed=() cask="" list_flag="--formula"
  if [[ "$kind" == "cask" ]]; then cask="--cask"; list_flag="--cask"; fi
  if [[ "$DRYRUN" == "1" ]]; then
    dryrun_note "brew install $cask (one at a time, skipping what's present): $*"
    return 0
  fi
  # Skip what's already there: `brew install` on a present item still pays
  # Homebrew's startup, and one-at-a-time turns that into N on every re-run.
  installed="$(brew list $list_flag -1 2>/dev/null || true)"
  for item in "$@"; do
    if grep -qxF "$item" <<<"$installed"; then ok "$item"; else missing+=("$item"); fi
  done
  [[ ${#missing[@]} -eq 0 ]] && return 0
  brew fetch $cask "${missing[@]}" || true
  for item in "${missing[@]}"; do
    if brew install $cask ${cask:+--adopt} "$item"; then ok "$item"
    else warn "$item — install failed"; failed+=("$item"); fi
  done
  if [[ ${#failed[@]} -gt 0 ]]; then
    warn "Not installed (${#failed[@]}): ${failed[*]}"
    warn "  Run 'brew install $cask ${failed[0]}' to see the reason."
    pending "Homebrew: these didn't install — ${failed[*]}"
  fi
}

# ~/.local/bin (Claude Code, rtk) onto PATH: this shell + ~/.zshrc, once. Export
# rather than `source ~/.zshrc` — this is bash, and sourcing a zsh rc from it is
# neither valid nor needed just for PATH.
LOCAL_BIN="$HOME/.local/bin"

# Ask a NEW login shell whether it resolves ~/.local/bin. That's the question
# that matters and the only reliable way to answer it: THIS shell's $PATH says
# nothing about future ones, and grepping ~/.zshrc reads intent rather than
# behaviour — it can't see .zprofile/.zshenv, or anything that rewrites PATH
# further down, and it once matched a commented-out line.
# PATH=/usr/bin:/bin is essential: the child inherits our environment, and we
# export LOCAL_BIN into this run below — without resetting it the probe would
# just measure our own export and always pass. Starting minimal means only what
# the login shell's rc files contribute can satisfy the check.
# </dev/null so an rc file that reads from stdin gets EOF instead of hanging the
# whole bootstrap.
fresh_shell_has_local_bin() {
  have zsh || return 1
  PATH=/usr/bin:/bin zsh -lic 'case ":$PATH:" in *"/.local/bin:"*) exit 0 ;; *) exit 1 ;; esac' \
    </dev/null >/dev/null 2>&1
}

ensure_local_bin_path() {
  local rc="$HOME/.zshrc" line='export PATH="$HOME/.local/bin:$PATH"'
  case ":$PATH:" in
    *":$LOCAL_BIN:"*) ;;                                # already live in this run
    *) export PATH="$LOCAL_BIN:$PATH" ;;
  esac
  if [[ "$DRYRUN" == "1" ]]; then
    dryrun_note "if a new zsh doesn't resolve ~/.local/bin: append '$line' to $rc"
    return 0
  fi
  if fresh_shell_has_local_bin; then
    ok "~/.local/bin resolves in a new shell"
    return 0
  fi
  # It doesn't resolve. If an active export is already in the rc, something later
  # overrides PATH — a second copy wouldn't help, so say so instead.
  if grep -qsE '^[[:space:]]*[^#]*\.local/bin' "$rc"; then
    warn "$rc exports ~/.local/bin, but a new shell doesn't see it — PATH is overridden later."
    pending "PATH: ~/.zshrc exports ~/.local/bin but new shells don't see it."
    return 0
  fi
  printf '%s\n' "$line" >> "$rc"
  if fresh_shell_has_local_bin; then
    ok "Added ~/.local/bin to PATH in ~/.zshrc"
  else
    warn "Appended the export to $rc, but a new shell still doesn't resolve ~/.local/bin."
    pending "PATH: new shells don't pick up ~/.local/bin; check ~/.zshrc."
  fi
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
# Directory this script lives in (= the dotfiles repo) — source of git/.gitconfig etc.
DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Repos to clone into ~/git (alphabetical). Cloning is all this does — per-project
# setup (runtimes, deps, databases) is each repo's own business.
REPOS=(
  albertoblaz
  albertoblaz.github.io
  dotfiles
  golden-gamers
  golden-gamers-methodology
  logseq-books
  logseq-work
)

# Fresh machine fetches the sanitized pet config from the (public) dotfiles repo,
# then injects the real token from 1Password (never committed). Override via env.
PET_CONFIG_URL="${PET_CONFIG_URL:-https://raw.githubusercontent.com/${GITHUB_USER}/dotfiles/main/pet/config.toml}"
PET_OP_ITEM="${PET_OP_ITEM:-pet - GitHub Classic Token}"

# 1Password vault holding the pet token ("Personal" is the CLI name for the
# personal vault; `op` also answers to its old name, "Private").
OP_VAULT="${OP_VAULT:-Personal}"

# One email, reused for the git commit identity (.gitconfig) and the Chrome/Google
# sign-in. It's PII, so it's never committed — the repo's .gitconfig ships a
# WORK_EMAIL_ADDRESS placeholder that we substitute in the LOCAL copy only.
GOOGLE_EMAIL=""
read -rp "Your email (git config, Google sign-in): " GOOGLE_EMAIL || true

# Apply the repo's .gitconfig locally (COPY, not symlink, so we can fill the email
# placeholder without writing PII back into the public repo).
if [[ -f "$DOTFILES_DIR/git/.gitconfig" ]]; then
  if [[ -f "$HOME/.gitconfig" ]] && grep -qs 'gst = git status' "$HOME/.gitconfig"; then
    # A distinctive alias from our .gitconfig → it's already applied. Idempotent.
    ok "~/.gitconfig already applied"
  elif [[ -e "$HOME/.gitconfig" && ! -L "$HOME/.gitconfig" ]]; then
    warn "Existing ~/.gitconfig (not ours) — leaving it; merge $DOTFILES_DIR/git/.gitconfig manually."
  else
    run rm -f "$HOME/.gitconfig"                       # drop any symlink from older runs
    run cp "$DOTFILES_DIR/git/.gitconfig" "$HOME/.gitconfig"
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

# ---------------------------------------------------------------------------
# Admin rights, asked for once, up front.
# Some casks symlink into /usr/local/bin (docker-desktop, tailscale-app) and the
# Xcode license step needs root. Asking here turns a prompt that would otherwise
# interrupt a long download into one predictable prompt; the keep-alive stops
# sudo lapsing mid-install (it forgets after ~5 idle minutes).
# ---------------------------------------------------------------------------
prime_sudo() {
  if [[ "$DRYRUN" == "1" ]]; then
    dryrun_note "sudo -v (prime admin rights, then refresh in the background)"
    return 0
  fi
  if sudo -n true 2>/dev/null; then
    ok "Admin rights already available"
  elif ! interactive; then
    warn "No terminal to read a sudo password — steps needing admin rights will fail."
    warn "  Everything else still runs; re-run from a terminal to finish those."
    return 1
  else
    info "Admin rights are needed for a few steps (casks that link into /usr/local/bin, Xcode license)."
    if ! sudo -v; then
      warn "No admin rights — those steps will fail; the rest of the run continues."
      return 1
    fi
    ok "Admin rights granted"
  fi
  # Refresh until this script exits, so a long download can't let sudo lapse.
  # `|| true` is load-bearing: the subshell inherits `set -e`, so one failed
  # refresh would kill the keep-alive and every later step would prompt again.
  ( while kill -0 "$$" 2>/dev/null; do sudo -n -v 2>/dev/null || true; sleep 60; done ) &
  SUDO_KEEPALIVE_PID="$!"   # cleanup() kills it on exit
}
prime_sudo || true

# Before anything looks for a binary: an unreadable /usr/local/bin hides brew
# itself on an Intel prefix, so every `have` below would answer "not installed"
# and we'd re-run installers that already ran. Needs the sudo primed just above.
ensure_traversable /usr/local/bin

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
# B. CLI tools (brew)
# ===========================================================================
section "CLI tools"
FORMULAE=(git curl vim zsh gh jq mise pet)   # jq merges the Claude Code settings below
CLI_CASKS=(1password-cli)                    # provides `op`; shipped as a cask, not a formula
info "Installing: ${FORMULAE[*]} ${CLI_CASKS[*]}"
brew_install_each formula "${FORMULAE[@]}"
brew_install_each cask "${CLI_CASKS[@]}"

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
  docker-desktop   # canonical token; `docker` is an alias for it
  dropbox
  tailscale-app    # canonical token; the `tailscale` formula is the CLI daemon
  rectangle        # window tiling manager
  telegram
  whatsapp
  chatgpt          # ChatGPT for Mac
)
info "Installing: ${CASKS[*]}"
brew_install_each cask "${CASKS[@]}"
# Again, in case a cask just created /usr/local/bin under its own umask.
ensure_traversable /usr/local/bin

# ---------------------------------------------------------------------------
# Rectangle — settings, including "Launch at login".
#
# The repo's plist is the source of truth; `defaults import` replaces the whole
# domain. Two things make this less trivial than a file copy:
#   - Rectangle has to be QUIT first. cfprefsd hands a running app its own
#     cached copy of the domain, which gets flushed back over our import.
#   - The plist only carries the launch-at-login *checkbox*. The real login-item
#     registration lives in the SIP-protected Background Task Management store,
#     which nothing here can write. Rectangle's checkLaunchOnLogin() runs on
#     every launch and reconciles the two (pref on + not registered → register
#     via SMAppService), so launching it once after the import is what actually
#     arms it.
# ---------------------------------------------------------------------------
section "Rectangle"
RECTANGLE_DOMAIN="com.knollsoft.Rectangle"
RECTANGLE_PLIST_SRC="$DOTFILES_DIR/rectangle/$RECTANGLE_DOMAIN.plist"
# Compare as a SUBSET, not an exact match: Rectangle writes its own bookkeeping
# keys (lastVersion, SUHasLaunchedBefore…) on first run, so an exact diff would
# never settle and we'd re-import — and stomp any later GUI tweaks — every run.
rectangle_settings_applied() {
  local src cur
  # Read the live domain first: on a fresh machine it's unset, and an unset
  # domain can't satisfy a non-empty subset — so bail before paying for the
  # source conversion and jq.
  cur="$(defaults export "$RECTANGLE_DOMAIN" - 2>/dev/null | plutil -convert json -o - - 2>/dev/null)" || return 1
  [[ -n "$cur" && "$cur" != "{}" ]] || return 1
  src="$(plutil -convert json -o - "$RECTANGLE_PLIST_SRC" 2>/dev/null)" || return 1
  jq -n --argjson src "$src" --argjson cur "$cur" -e \
    '$src | to_entries | all(.value == $cur[.key])' >/dev/null 2>&1
}
rectangle_running() { pgrep -x Rectangle >/dev/null 2>&1; }

# Launch Rectangle so checkLaunchOnLogin() reconciles the launchOnLogin pref with
# the login-item store, and flag the one-time Accessibility grant. Needed after an
# import, but also when the domain already matches and the app simply isn't up.
rectangle_arm_login_item() {
  local marker="$MARKER_DIR/rectangle-accessibility-prompted"
  if ! open -a Rectangle 2>/dev/null; then
    warn "Could not launch Rectangle — open it once to arm launch-at-login."
    return 0
  fi
  # One-time human step, and nothing here can read TCC to confirm it — so use the
  # same marker mechanism as Chrome sign-in rather than nagging every run.
  if [[ ! -f "$marker" ]]; then
    mkdir -p "$MARKER_DIR"
    touch "$marker"
    pending "Rectangle: grant Accessibility access when prompted (System Settings → Privacy & Security → Accessibility)."
  fi
}

if [[ ! -f "$RECTANGLE_PLIST_SRC" ]]; then
  warn "No $RECTANGLE_PLIST_SRC in the repo — skipping Rectangle settings."
elif [[ ! -d /Applications/Rectangle.app ]]; then
  # No pending here: the cask failing to install is already reported by
  # brew_install_each, and one root cause shouldn't take two lines in the summary.
  warn "Rectangle.app not found — skipping its settings."
elif [[ "$DRYRUN" == "1" ]]; then
  dryrun_note "import $RECTANGLE_PLIST_SRC → $RECTANGLE_DOMAIN, then launch Rectangle once"
elif ! have jq; then
  warn "jq not available — import it manually: defaults import $RECTANGLE_DOMAIN $RECTANGLE_PLIST_SRC"
elif rectangle_settings_applied; then
  # Settings are in place, so there is nothing to import and nothing to back up.
  # The only open question is the login item, and only a launch can settle that.
  if rectangle_running; then
    # Running on macOS 13+ means checkLaunchOnLogin() has already had its chance.
    ok "Rectangle already configured"
  else
    ok "Rectangle settings already match the repo"
    rectangle_arm_login_item
  fi
else
  if rectangle_running; then
    # Bounded: a bare `quit app` waits on the AppleEvent reply for AppleScript's
    # default 120s, which would hang an unattended run behind a modal dialog.
    osascript -e 'with timeout of 5 seconds' -e 'quit app "Rectangle"' -e 'end timeout' \
      >/dev/null 2>&1 || pkill -x Rectangle || true
    # ~5s ceiling — 50 polls of 0.1s plus a pgrep each. A quick quit costs ~0.1s.
    for _ in {1..50}; do
      rectangle_running || break
      sleep 0.1
    done
  fi
  if rectangle_running; then
    # Importing now would be theatre: cfprefsd would flush the running app's
    # cached domain back over it, and we'd have reported success for a no-op.
    warn "Rectangle wouldn't quit — skipping the import, since cfprefsd would undo it."
    pending "Rectangle: quit it by hand, then re-run ./bootstrap.sh to apply its settings."
  else
    # `defaults import` MERGES: keys the repo file doesn't carry are left alone
    # (verified — Rectangle's own lastVersion/SUHasLaunchedBefore survive it).
    # What it does overwrite is a UI change to a key the repo DOES carry, e.g. a
    # shortcut retuned in Rectangle and never re-exported. Snapshot first so that
    # is recoverable.
    RECTANGLE_BACKUP="$MARKER_DIR/$RECTANGLE_DOMAIN.plist.bak"
    RECTANGLE_BACKED_UP=0
    if defaults read "$RECTANGLE_DOMAIN" >/dev/null 2>&1; then
      mkdir -p "$MARKER_DIR"
      if defaults export "$RECTANGLE_DOMAIN" "$RECTANGLE_BACKUP" 2>/dev/null; then
        RECTANGLE_BACKED_UP=1
      fi
    fi
    if defaults import "$RECTANGLE_DOMAIN" "$RECTANGLE_PLIST_SRC"; then
      ok "Imported Rectangle settings from the repo"
      if [[ "$RECTANGLE_BACKED_UP" == "1" ]]; then
        warn "Repo values overwrote the live ones — previous domain saved to $RECTANGLE_BACKUP"
      fi
      rectangle_arm_login_item
    else
      warn "Could not import $RECTANGLE_PLIST_SRC into $RECTANGLE_DOMAIN."
      pending "Rectangle: settings import failed — enable 'Launch on login' in its preferences by hand."
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Dock — exact contents and order.
# Finder and Trash aren't listed: macOS keeps them out of persistent-apps and
# won't let them move. The divider before Downloads is drawn automatically
# between the apps and the folders, so it needs no spacer tile.
# ---------------------------------------------------------------------------
section "Dock"
# Trello has no native app — it's installed by hand as a Chrome web app, which
# Chrome drops under ~/Applications/Chrome Apps[.localized]/. Resolve it rather
# than hardcoding, since that directory's name is localized.
TRELLO_APP="/Applications/Trello.app"          # fallback, for the "not found" warning
for candidate in "$HOME/Applications/Chrome Apps.localized/Trello.app" \
                 "$HOME/Applications/Chrome Apps/Trello.app"; do
  [[ -e "$candidate" ]] && { TRELLO_APP="$candidate"; break; }
done

DOCK_APPS=(
  "/System/Applications/Apps.app"
  "/System/Applications/Calendar.app"
  "$TRELLO_APP"
  "/Applications/Google Chrome.app"
  "/Applications/Ghostty.app"
  "/Applications/Zed.app"
  "/Applications/Claude.app"
  "/Applications/ChatGPT.app"
  "/Applications/Tailscale.app"
  "/Applications/Logseq.app"
  "/Applications/1Password.app"
  "/Applications/Docker.app"
  "/Applications/Spotify.app"
  "/Applications/WhatsApp.app"
  "/Applications/Telegram.app"
  "/System/Applications/App Store.app"
  "/System/Applications/Utilities/Activity Monitor.app"
  "/System/Applications/System Settings.app"
)
DOCK_OTHERS=("$HOME/Downloads")

# _CFURLStringType 0 = plain path; the Dock rewrites it to a file:// URL itself.
dock_app_tile() {
  printf '<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>%s</string><key>_CFURLStringType</key><integer>0</integer></dict></dict></dict>' "$1"
}
dock_dir_tile() {
  printf '<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>%s</string><key>_CFURLStringType</key><integer>0</integer></dict><key>file-type</key><integer>2</integer></dict><key>tile-type</key><string>directory-tile</string></dict>' "$1"
}

# Compare by name, not URL: the Dock rewrites what we write (spaces become %20,
# and some system apps resolve to /System/Volumes/Preboot/Cryptexes/…), so
# comparing URLs would report a difference on every run and rebuild the Dock
# each time.
dock_current_names() {  # <persistent-apps|persistent-others>
  local url name
  defaults read com.apple.dock "$1" 2>/dev/null \
    | sed -n 's/.*"_CFURLString" = "\(.*\)";/\1/p' \
    | while IFS= read -r url; do
        url="${url%/}"; name="${url##*/}"; name="${name%.app}"
        printf '%b\n' "${name//%/\\x}"      # %20 → space
      done
}
dock_names_of() {  # <path…>
  local p n
  for p in "$@"; do n="${p##*/}"; printf '%s\n' "${n%.app}"; done
}

dock_present=()
for app in "${DOCK_APPS[@]}"; do
  if [[ -e "$app" ]]; then dock_present+=("$app")
  else
    warn "Dock: $app not found — not pinned."
    pending "Dock: ${app##*/} isn't installed, so it wasn't pinned."
  fi
done

if [[ "$DRYRUN" == "1" ]]; then
  dryrun_note "set Dock to: $(dock_names_of "${dock_present[@]}" | tr '\n' ' ')+ Downloads"
elif [[ ${#dock_present[@]} -eq 0 ]]; then
  warn "Dock: none of the listed apps are installed — leaving the Dock alone."
elif [[ "$(dock_current_names persistent-apps)" == "$(dock_names_of "${dock_present[@]}")" ]] \
  && [[ "$(dock_current_names persistent-others)" == "$(dock_names_of "${DOCK_OTHERS[@]}")" ]]; then
  ok "Dock already matches"
else
  defaults delete com.apple.dock persistent-apps   >/dev/null 2>&1 || true
  defaults delete com.apple.dock persistent-others >/dev/null 2>&1 || true
  for app in "${dock_present[@]}"; do
    defaults write com.apple.dock persistent-apps -array-add "$(dock_app_tile "$app")"
  done
  for dir in "${DOCK_OTHERS[@]}"; do
    defaults write com.apple.dock persistent-others -array-add "$(dock_dir_tile "$dir")"
  done
  killall Dock 2>/dev/null || true
  ok "Dock set (${#dock_present[@]} apps + ${#DOCK_OTHERS[@]} folder)"
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
  pending "Chrome: finish signing in${GOOGLE_EMAIL:+ as $GOOGLE_EMAIL} in the tab that opened."
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

# $EDITOR for every tool that reads it. Must come AFTER oh-my-zsh: its installer
# replaces ~/.zshrc with a fresh template (the old one is backed up), so an
# earlier append would be lost. The stock template only ships EDITOR commented
# out, which leaves it unset — and an unset $EDITOR is how `pet edit` ended up
# calling the Debian-only `sensible-editor`. git survives it (it falls back to
# its built-in `vi`); tools without a fallback chain don't.
EDITOR_RC="$HOME/.zshrc"
EDITOR_LINE="export EDITOR='vim'"
if [[ "$DRYRUN" == "1" ]]; then
  dryrun_note "if ~/.zshrc has no active EDITOR export: append \"$EDITOR_LINE\""
elif grep -qsE '^[[:space:]]*export[[:space:]]+EDITOR=' "$EDITOR_RC"; then
  ok "~/.zshrc already exports EDITOR"
else
  [[ -f "$EDITOR_RC" ]] || run touch "$EDITOR_RC"
  printf '%s\n' "$EDITOR_LINE" >> "$EDITOR_RC" \
    && ok "Set EDITOR=vim in ~/.zshrc" \
    || warn "Could not append the EDITOR export to $EDITOR_RC."
fi

section "Claude Code"
# Check the path too: ~/.local/bin isn't on a fresh PATH, so `have claude` alone
# would re-run the installer every time.
if have claude || [[ -x "$LOCAL_BIN/claude" ]]; then
  ok "Claude Code already installed"
else
  info "Installing Claude Code…"
  run_sh 'curl -fsSL https://claude.ai/install.sh | bash'
fi
ensure_local_bin_path   # the installer drops `claude` in ~/.local/bin

# ---------------------------------------------------------------------------
# Claude Code settings — this repo's claude/settings.json is the source of truth.
# Has to land in USER settings: Claude Code ignores defaultMode "auto" from a
# project's .claude/settings.json (v2.1.142+), so a repo can't grant itself auto
# mode. Merged with jq's recursive `*` — repo values win, local keys survive.
# ---------------------------------------------------------------------------
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
CLAUDE_SETTINGS_SRC="$DOTFILES_DIR/claude/settings.json"
if [[ ! -f "$CLAUDE_SETTINGS_SRC" ]]; then
  warn "No $CLAUDE_SETTINGS_SRC in the repo — skipping Claude Code settings."
elif [[ "$DRYRUN" == "1" ]]; then
  dryrun_note "merge $CLAUDE_SETTINGS_SRC → $CLAUDE_SETTINGS"
elif [[ ! -f "$CLAUDE_SETTINGS" ]]; then
  mkdir -p "$(dirname "$CLAUDE_SETTINGS")"
  cp "$CLAUDE_SETTINGS_SRC" "$CLAUDE_SETTINGS"
  ok "Applied Claude Code settings → $CLAUDE_SETTINGS"
elif ! have jq; then
  warn "jq not available — merge $CLAUDE_SETTINGS_SRC into $CLAUDE_SETTINGS manually."
elif jq -s '.[0] * .[1]' "$CLAUDE_SETTINGS" "$CLAUDE_SETTINGS_SRC" > "$CLAUDE_SETTINGS.tmp" 2>/dev/null; then
  if cmp -s "$CLAUDE_SETTINGS.tmp" "$CLAUDE_SETTINGS"; then
    rm -f "$CLAUDE_SETTINGS.tmp"
    ok "Claude Code settings already applied"
  else
    mv "$CLAUDE_SETTINGS.tmp" "$CLAUDE_SETTINGS"
    ok "Merged Claude Code settings → $CLAUDE_SETTINGS"
  fi
else
  rm -f "$CLAUDE_SETTINGS.tmp"
  warn "Could not parse $CLAUDE_SETTINGS — merge $CLAUDE_SETTINGS_SRC into it manually."
fi

section "rtk (Rust Token Killer)"
if have rtk || [[ -x "$LOCAL_BIN/rtk" ]]; then
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
  pending "Xcode: install it from the App Store, then re-run this script."
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
PET_CONFIG="$HOME/.config/pet/config.toml"

# Section-scoped TOML read/write. pet repeats `access_token` under [GHEGist],
# [Gist] and [GitLab]; only [Gist] is used (Backend = "gist"), so scope writes to
# it rather than spreading the token across all three.
toml_get() {  # <file> <section> <key>
  awk -v sec="$2" -v key="$3" '
    /^[[:space:]]*\[/ { s = $0; gsub(/[][ \t]/, "", s); next }
    s == sec && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      sub("^[^=]*=[[:space:]]*", "", $0); gsub(/^"|"$/, "", $0); print; exit
    }
  ' "$1" 2>/dev/null
}
toml_set() {  # <file> <section> <key> <value>
  local tmp="$1.bootstrap.tmp"
  # Values here are tokens and paths. A quote or backslash would produce invalid
  # TOML (and awk -v would eat the escape), so refuse rather than corrupt the
  # config — anything like that is a bad paste, not a real token.
  case "$4" in
    *[\"\\]*|*$'\n'*) warn "Refusing to write a $3 containing a quote, backslash or newline."; return 1 ;;
  esac
  awk -v sec="$2" -v key="$3" -v val="$4" '
    /^[[:space:]]*\[/ { s = $0; gsub(/[][ \t]/, "", s); print; next }
    s == sec && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      match($0, /^[[:space:]]*/)
      print substr($0, 1, RLENGTH) key " = \"" val "\""; next
    }
    { print }
  ' "$1" > "$tmp" && chmod "$(stat -f '%Lp' "$1")" "$tmp" && mv "$tmp" "$1"
}

# Read the item's concealed field. NOT `--fields type=concealed | head -1`: op
# prints a "Label:/Value:/Reference:" block, so head -1 returns the literal
# "Label:        token" — the string that got written into the config and caused
# the 401. Reading the value also works for any item category.
op_read_token() {  # <item-title>
  local json
  if have jq; then
    json="$(op item get "$1" --format json --reveal 2>/dev/null)" || return 1
    jq -r 'first(.fields[]? | select(.type == "CONCEALED" and (.value // "") != "") | .value) // empty' <<<"$json"
  else
    op item get "$1" --fields type=concealed --reveal 2>/dev/null \
      | sed -n 's/^Value:[[:space:]]*//p' | head -1
  fi
}

# Write <token> back to the item's concealed field. `op item edit` takes
# `[section.]label=value`, so resolve both from the item rather than assuming a
# Password item's top-level `password`.
op_write_token() {  # <item-title> <token>
  local assign
  have jq || return 1
  assign="$(op item get "$1" --format json 2>/dev/null \
    | jq -r 'first(.fields[]? | select(.type == "CONCEALED")
             | (if .section then .section.id + "." else "" end) + .label) // empty')" || return 1
  [[ -z "$assign" ]] && return 1
  op item edit "$1" "$assign=$2" >/dev/null 2>&1
}

gh_api_code()     { curl -sS -o /dev/null -w '%{http_code}' -m 20 -H "Authorization: Bearer $2" \
                         -H "Accept: application/vnd.github+json" "$1" 2>/dev/null || echo 000; }
gh_token_scopes() { curl -sSI -m 20 -H "Authorization: Bearer $1" https://api.github.com/user 2>/dev/null \
                      | awk -F': ' 'tolower($1) == "x-oauth-scopes" { print $2 }' | tr -d '\r'; }

# Copy the token from 1Password into the config. Returns 1 when there's nothing
# usable there, or when it matches the config already — no progress, so the
# caller should escalate to asking for a new one.
pet_token_from_op() {
  local token current
  op_connected || return 1
  token="$(op_read_token "$PET_OP_ITEM" || true)"
  [[ -z "$token" ]] && return 1
  current="$(toml_get "$PET_CONFIG" Gist access_token)"
  [[ "$token" == "$current" ]] && return 1
  toml_set "$PET_CONFIG" Gist access_token "$token" || return 1
  ok "Applied the pet token from 1Password item '$PET_OP_ITEM'"
}

# Ask for a fresh token, store it in 1Password (edit the item if it exists,
# create it otherwise) and write it into the local config.
pet_refresh_token() {
  local token=""
  interactive || { warn "Non-interactive run — can't prompt for a new pet token."; return 1; }
  info "Create a CLASSIC PAT with the 'gist' scope:"
  info "  https://github.com/settings/tokens/new?scopes=gist&description=pet"
  read -rsp "Paste the GitHub token for pet (empty to skip): " token; echo
  [[ -z "$token" ]] && { warn "No token entered — skipping."; return 1; }
  if op_connected; then
    if op item get "$PET_OP_ITEM" >/dev/null 2>&1; then
      op_write_token "$PET_OP_ITEM" "$token" \
        && ok "Updated the token in 1Password item '$PET_OP_ITEM'" \
        || warn "Couldn't update the 1Password item — writing it to the config anyway."
    else
      op item create --category "API Credential" --title "$PET_OP_ITEM" --vault "$OP_VAULT" \
        "token[concealed]=$token" >/dev/null 2>&1 \
        && ok "Created 1Password item '$PET_OP_ITEM'" \
        || warn "Couldn't create the 1Password item — writing it to the config anyway."
    fi
  fi
  toml_set "$PET_CONFIG" Gist access_token "$token" \
    && ok "Wrote the pet token into $PET_CONFIG" \
    || { warn "Could not write the token into $PET_CONFIG."; return 1; }
}

# Validate token and gist separately before syncing: pet only ever reports an
# opaque 401, which is always the TOKEN — a bad gist id is a 404, a missing
# 'gist' scope a 403.
pet_check_and_sync() {
  local token gist code scopes tries=0
  while :; do
    token="$(toml_get "$PET_CONFIG" Gist access_token)"
    if [[ -z "$token" ]]; then
      warn "pet access_token is blank — skipping sync. Set it in $PET_CONFIG (or run 'pet configure')."
      return 0
    fi
    code="$(gh_api_code "https://api.github.com/user" "$token")"
    case "$code" in
      200) break ;;
      401)
        warn "GitHub rejected the pet token (401) — invalid, expired, revoked, or never written correctly."
        warn "  (A 401 is the TOKEN, not the gist id — a bad gist id would be a 404.)"
        tries=$((tries + 1))
        # Re-read 1Password first: a config holding a stale or mangled value
        # should self-heal, not nag for a token that already exists.
        if [[ "$tries" == "1" ]] && pet_token_from_op; then
          info "Re-read the token from 1Password — retrying."
        elif [[ "$tries" -le 2 ]] && pet_refresh_token; then
          info "Retrying with the new token."
        else
          warn "Skipping pet sync — fix the token in 1Password and re-run."
          return 0
        fi ;;
      000) warn "Couldn't reach api.github.com — skipping pet sync."; return 0 ;;
      *)   warn "Unexpected GitHub API response ($code) while validating the pet token — skipping sync."; return 0 ;;
    esac
  done
  ok "pet token accepted by GitHub"

  # Classic PATs report their scopes in a header; fine-grained tokens don't.
  scopes="$(gh_token_scopes "$token")"
  if [[ -n "$scopes" ]] && ! grep -q 'gist' <<<"$scopes"; then
    warn "Token scopes ($scopes) don't include 'gist' — sync will fail. Regenerate it with the gist scope."
  fi

  gist="$(toml_get "$PET_CONFIG" Gist gist_id)"
  if [[ -z "$gist" ]]; then
    info "No gist_id set — 'pet sync' will create a gist and record its id."
  else
    code="$(gh_api_code "https://api.github.com/gists/$gist" "$token")"
    case "$code" in
      200) ok "Gist $gist is reachable" ;;
      404) warn "Gist id '$gist' doesn't exist or isn't visible to this token."
           info "Clearing it so 'pet sync' creates a fresh gist and records the new id."
           toml_set "$PET_CONFIG" Gist gist_id "" || warn "Could not clear gist_id in $PET_CONFIG." ;;
      *)   warn "Couldn't verify gist '$gist' (HTTP $code) — attempting the sync anyway." ;;
    esac
  fi

  info "Syncing pet snippets from GitHub Gist…"
  pet sync || warn "pet sync failed — see the error above; check $PET_CONFIG."
}

if have pet; then
  # 1. Ensure the config exists (download the sanitized one from dotfiles).
  if [[ ! -f "$PET_CONFIG" && "$DRYRUN" != "1" ]]; then
    info "No pet config — fetching sanitized config from dotfiles: $PET_CONFIG_URL"
    mkdir -p "$(dirname "$PET_CONFIG")"
    curl -fsSL "$PET_CONFIG_URL" -o "$PET_CONFIG" \
      || warn "Could not download pet config — run 'pet configure' manually."
  fi
  # The GitHub token gets written into this file, and curl creates it 0644.
  # toml_set preserves the mode, so this holds across re-runs.
  [[ "$DRYRUN" != "1" && -f "$PET_CONFIG" ]] && chmod 600 "$PET_CONFIG"

  # 1b. SnippetFile must be set AND exist: pet 1.0.1 panics on a blank one and
  #     refuses to run on a missing file. The path embeds $HOME, so it's filled
  #     here rather than committed.
  PET_SNIPPETS="$HOME/.config/pet/snippet.toml"
  if [[ "$DRYRUN" == "1" ]]; then
    dryrun_note "if [General].SnippetFile blank: set it to $PET_SNIPPETS; touch that file"
  elif [[ -f "$PET_CONFIG" ]]; then
    if [[ -z "$(toml_get "$PET_CONFIG" General SnippetFile)" ]]; then
      toml_set "$PET_CONFIG" General SnippetFile "$PET_SNIPPETS" \
        && ok "Set pet SnippetFile → $PET_SNIPPETS" \
        || warn "Could not set SnippetFile in $PET_CONFIG."
    fi
    if [[ ! -f "$PET_SNIPPETS" ]]; then
      mkdir -p "$(dirname "$PET_SNIPPETS")"
      touch "$PET_SNIPPETS" && ok "Created empty $PET_SNIPPETS (pet requires it to exist)"
    fi
  fi

  # 1c. pet execs [General].Editor literally — no $EDITOR fallback, no $PATH
  #     search rescue. A config written while $EDITOR was unset carries
  #     "sensible-editor", which is Debian-only, so `pet edit` dies with 127.
  #     Repaired here rather than only in the committed config: this file already
  #     exists on a re-run, so the download in step 1 never touches it.
  if [[ "$DRYRUN" == "1" ]]; then
    dryrun_note "if [General].Editor is blank or 'sensible-editor': set it to vim"
  elif [[ -f "$PET_CONFIG" ]]; then
    pet_editor="$(toml_get "$PET_CONFIG" General Editor)"
    if [[ -z "$pet_editor" || "$pet_editor" == "sensible-editor" ]]; then
      toml_set "$PET_CONFIG" General Editor "vim" \
        && ok "Set pet Editor → vim" \
        || warn "Could not set Editor in $PET_CONFIG."
    fi
  fi

  # 2. Inject the token from 1Password whenever access_token is blank — on every
  #    re-run, so a config written before 1Password was connected gets fixed.
  if [[ "$DRYRUN" == "1" ]]; then
    dryrun_note "if [Gist].access_token blank: op item get \"$PET_OP_ITEM\" → write into config"
  elif [[ -f "$PET_CONFIG" ]] && [[ -z "$(toml_get "$PET_CONFIG" Gist access_token)" ]]; then
    if ! op_connected; then
      # Two causes, one symptom: the integration toggle is off, or it's on and
      # you're signed out. Name both, or the fix looks like a switch to flip
      # that's already flipped.
      warn "1Password CLI not usable — either enable 1Password ▸ Settings ▸ Developer ▸"
      warn "  'Integrate with 1Password CLI', or sign in ('op signin') if it's already on."
      pet_refresh_token || true
    elif ! pet_token_from_op; then
      warn "No usable token in 1Password item '$PET_OP_ITEM' (missing, or no concealed field)."
      pet_refresh_token || true
    fi
  fi

  # 3. Validate, then sync.
  if [[ "$DRYRUN" == "1" ]]; then
    dryrun_note "validate the token (GET /user) and gist (GET /gists/<id>), then pet sync"
  elif [[ -f "$PET_CONFIG" ]]; then
    pet_check_and_sync
  fi
fi

# ===========================================================================
# H. SSH key (on disk, macOS keychain agent) + register on GitHub
# ===========================================================================
# The private key used to live in 1Password, served by its SSH agent — better
# key protection, but 1Password ALWAYS demands an interactive approval per key
# with no way to disable it, which stalls every scripted or background git
# operation. A passphrase-less key in the keychain never prompts; its protection
# is FileVault plus file permissions instead. Full reasoning and the trade
# accepted: bootstrap.README.md § "Why not the 1Password SSH agent".
# ===========================================================================
section "SSH key (on-disk + macOS keychain)"
# Purpose-named, not algorithm-named: every Host block below sets IdentityFile
# explicitly, so OpenSSH's default-lookup name (`id_ed25519`) buys nothing.
SSH_KEY="$HOME/.ssh/github"
run mkdir -p "$HOME/.ssh"
run chmod 700 "$HOME/.ssh"

# Append a block to ~/.ssh/config once (idempotent, keyed by a unique marker).
append_ssh_block() {  # <grep-marker> <block-text>
  local cfg="$HOME/.ssh/config"
  grep -qs "$1" "$cfg" 2>/dev/null && return 0
  if [[ "$DRYRUN" == "1" ]]; then dryrun_note "append ssh-config block matching /$1/ to $cfg"
  else printf '%s\n' "$2" >> "$cfg"; fi
}

if [[ -f "$SSH_KEY" ]]; then
  ok "SSH key already exists — not overwriting ($SSH_KEY)"
else
  run ssh-keygen -t ed25519 -C "$GOOGLE_EMAIL" -f "$SSH_KEY" -N ""
  run chmod 600 "$SSH_KEY"; run chmod 644 "${SSH_KEY}.pub"
  # The only copy of a passphrase-less private key, and nothing else will ever
  # remind you — the security argument above assumes this backup exists.
  pending "1Password: save a copy of $SSH_KEY as the backup of record."
fi

# Specific hosts must precede the `Host *` catch-all: ssh keeps the FIRST value
# it obtains for each option, so a catch-all placed above would win.
append_ssh_block '^Host github.com' "Host github.com
  User git
  IdentityFile $SSH_KEY
  IdentitiesOnly yes
"
append_ssh_block 'UseKeychain yes' "Host *
  AddKeysToAgent yes
  UseKeychain yes
  IdentityFile $SSH_KEY
"
run ssh-add --apple-use-keychain "$SSH_KEY" 2>/dev/null || true

section "Add SSH key to GitHub"
if ! have gh; then
  warn "gh not found — skipping GitHub key upload."
elif [[ "$DRYRUN" == "1" ]]; then
  dryrun_note "gh auth login (if not authenticated), then gh ssh-key add ${SSH_KEY}.pub"
else
  # Walk the user through `gh auth login` when needed. No --scopes flag: with a
  # PAT the scopes come from the token, which just needs write:public_key.
  # Choosing SSH during login also offers to upload the key directly.
  if gh auth status >/dev/null 2>&1; then
    gh_authed=1
  else
    info "gh is not authenticated — starting 'gh auth login'…"
    info "Suggested answers: github.com · SSH · your ${SSH_KEY} key · title 'gh' · authenticate with your PAT."
    gh auth login || warn "gh auth login was cancelled or failed."
    gh auth status >/dev/null 2>&1 && gh_authed=1 || gh_authed=0
  fi
  if [[ "$gh_authed" != "1" ]]; then
    warn "gh still not authenticated — add ${SSH_KEY}.pub manually at https://github.com/settings/keys."
    pending "GitHub: add ${SSH_KEY}.pub at https://github.com/settings/keys (gh auth login didn't complete)."
  elif [[ ! -f "${SSH_KEY}.pub" ]]; then
    warn "No public key at ${SSH_KEY}.pub — skipping GitHub upload (SSH key setup didn't complete)."
  else
    # The SSH-protocol login may already have added it; a repeat add returns
    # "already in use", which counts as success.
    if add_out="$(gh ssh-key add "${SSH_KEY}.pub" --title "$HOST" 2>&1)"; then
      ok "Registered SSH key on GitHub"
    elif grep -qiE 'already' <<<"$add_out"; then
      ok "SSH key already registered on GitHub"
    else
      warn "Could not add the key to GitHub:"
      warn "  $add_out"
      warn "Your PAT likely needs the write:public_key (admin:public_key) scope, or add"
      warn "  ${SSH_KEY}.pub manually at https://github.com/settings/keys."
      pending "GitHub: add ${SSH_KEY}.pub at https://github.com/settings/keys (upload failed — PAT scope?)."
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

# Confirm SSH auth before cloning, so one clear failure here replaces seven
# confusing ones in the parallel clone fan-out. `ssh -T` exits 1 even on success,
# so match the greeting, not the exit status.
github_ssh_ok() {
  local out
  out="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 \
             -T git@github.com 2>&1 || true)"
  grep -q 'successfully authenticated' <<<"$out"
}
if [[ "$DRYRUN" != "1" ]]; then
  if github_ssh_ok; then
    ok "SSH to github.com authenticates"
  else
    warn "SSH to github.com isn't authenticating yet (key not registered, or not loaded into the agent)."
    wait_until github_ssh_ok \
      "Press Enter to retry (or 's' to skip the check): " \
      "GitHub: SSH didn't authenticate — some clones may have failed." \
      && ok "SSH to github.com authenticates" || true
  fi
fi
# Clone the missing repos in parallel, then wait for all of them.
clone_pids=()
for repo in "${REPOS[@]}"; do
  dest="$HOME/git/$repo"
  if [[ -d "$dest/.git" ]]; then
    ok "$repo already cloned"
  elif [[ -d "$dest" ]]; then
    # Exists but isn't a repo — git would refuse a non-empty target anyway.
    warn "$repo: $dest exists but isn't a git repo — skipping clone."
  elif [[ "$DRYRUN" == "1" ]]; then
    dryrun_note "git clone git@github.com:${GITHUB_USER}/${repo}.git $dest (parallel)"
  else
    # Braces are load-bearing: in "$repo…" bash swallows the multi-byte ellipsis
    # into the variable name, so `set -u` aborted with `repo?: unbound variable`.
    info "Cloning ${repo}…"
    ( git clone "git@github.com:${GITHUB_USER}/${repo}.git" "$dest" >/dev/null 2>&1 \
        && ok "cloned ${repo}" \
        || warn "Clone failed for ${repo} — confirm the SSH key is active on GitHub." ) &
    clone_pids+=("$!")
  fi
done
[[ ${#clone_pids[@]} -gt 0 ]] && wait "${clone_pids[@]}" 2>/dev/null || true

# ===========================================================================
echo
ok "Bootstrap complete."
# Count first: expanding an empty array under `set -u` errors on macOS's bash 3.2.
if [[ ${#PENDING[@]} -gt 0 ]]; then
  warn "Still needs you:"
  for item in "${PENDING[@]}"; do warn "  • $item"; done
else
  ok "Nothing left that needs a human."
fi
info "Per-project setup (runtimes, deps, databases) is left to each repo's own scripts."
info "Open a new terminal so PATH / shell changes take effect."
