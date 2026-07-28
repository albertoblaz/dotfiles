# macOS dev-machine bootstrap

`bootstrap.sh` provisions a fresh **Mac** with my personal dev toolset in one
command. It is **idempotent** — safe to re-run; every step skips whatever is
already installed.

## Usage

```bash
# From the dotfiles repo root:
./bootstrap.sh

# Preview every command without changing anything:
BOOTSTRAP_DRYRUN=1 ./bootstrap.sh
```

macOS only — it refuses to run on any other OS.

## What it installs

**Policy:** prefer **Homebrew** for anything with a formula/cask (clean
upgrade/uninstall, idempotency). Official `curl | sh` installers are used only
where no formula exists: **Claude Code**, **rtk**, **oh-my-zsh**.

| Category | Tools |
|----------|-------|
| CLI (brew formulae) | git, curl, vim, zsh, gh, mise, pet, `1password-cli` (`op`) |
| Apps (brew casks) | Ghostty, Claude Desktop, Logseq, 1Password, Zed, Google Chrome, Spotify, Docker Desktop, Dropbox, Tailscale, Rectangle, Telegram, WhatsApp, ChatGPT |
| curl installers | oh-my-zsh, Claude Code, rtk |
| Runtime manager | mise + a global Node (LTS) and **gws** (`@googleworkspace/cli`) |
| git config | symlinks the repo's `.gitconfig` to `~/.gitconfig` |
| Apple toolchain | Xcode Command Line Tools, full Xcode (**Mac App Store**), iOS simulator runtime |
| Snippets | pet config fetched from this repo + token from 1Password + `pet sync` |
| SSH | new `~/.ssh/id_ed25519`, stored in 1Password **and registered on GitHub** |
| Workspace | `~/git/` + clones my repos (see below) |

Formulae and casks each install in a **single `brew` call** so bottles download in
parallel, and the repo clones run **concurrently** — the slow steps overlap.

### Xcode

Installed from the **Mac App Store** (first-party). The script opens the App Store
Xcode page; after Xcode finishes installing, **re-run** the script to accept the
license and download the iOS simulator runtime (`xcodebuild -downloadPlatform iOS`).
The Command Line Tools come in automatically with the Homebrew install.

### Trello

There's no Trello desktop app anymore, so it's installed as a **Chrome app**: the
script opens Trello in Chrome — install it via **⋮ ▸ Cast, save, and share ▸
Install page as app…**. A marker under `~/.config/mac-bootstrap/` keeps re-runs
from reopening it.

### Chrome sign-in

The script opens the Google sign-in page in Chrome so you can sign in with your
Google account — the 1Password extension autofills the password. The script
**prompts** for the email (it is **never** hardcoded in this public repo). Google
sign-in can't be scripted safely, so this step is a one-time prompt, marker-guarded.

### pet

If `~/.config/pet/config.toml` is missing, the script downloads the **sanitized**
config from this repo (`pet/config.toml`), then **injects the real Gist token from
1Password** before running `pet sync`. The committed config carries a **blank**
`access_token` — the secret never lives in git.

The token is read from the 1Password item named **`pet - Github Classic Token`**
(override with `PET_OP_ITEM`). If that item doesn't exist, the script **creates it**
from a token you paste in. The committed config already has the real `gist_id`
(syncing `pet-snippet.toml`) — the Gist id is not a secret.

## Repos cloned into ~/git

`albertoblaz`, `albertoblaz.github.io`, `dotfiles`, `golden-gamers`,
`golden-gamers-methodology`, `logseq-books`, `logseq-work`.

**golden-gamers** additionally runs its own **`scripts/setup.sh`** after cloning.

## Steps that need a human (interactive)

Isolated and **non-fatal** — an unattended run finishes everything else and tells
you what still needs you:

- **Xcode** — install from the App Store (Apple ID), then re-run.
- **1Password** — storing the SSH key needs `op` **signed in** (desktop-app
  integration or `op signin`).
- **GitHub SSH key** — `gh` must be authenticated (`gh auth login`) **with the
  `write:public_key` scope**. The script runs `gh auth refresh -h github.com -s
  write:public_key` (opens a browser) when the scope is missing, then **re-checks**:
  if the scope is still absent it **warns and skips** the upload (pointing you to
  `github.com/settings/keys`) rather than failing silently.
- **Chrome sign-in** and **Trello** — one-time browser steps.

## SSH key → GitHub → clone

1. Generates `~/.ssh/id_ed25519` **only if none exists** (never overwrites), sets
   perms, wires it into the ssh-agent + macOS Keychain.
2. Uploads the private key to **1Password** as a document.
3. Registers the **public** key on **GitHub** via `gh ssh-key add`.
4. Pre-trusts `github.com` (`ssh-keyscan`) so the first SSH clone doesn't hang, then
   clones the repos over SSH.

## Security note — pet token

This repo is **public**, so the committed `pet/config.toml` has **blank**
`access_token` fields. The real token lives in **1Password** and is injected into
the local config at bootstrap time. Never commit the token here.

## Notes

- Open a **new terminal** after the run so PATH / shell changes take effect.
