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
| git config | copies the repo's `.gitconfig` to `~/.gitconfig`, filling the email placeholder |
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
Install page as app…**. It **detects the actual installed app** (Chrome PWAs live
under `~/Applications/Chrome Apps.localized/`), so re-runs only reopen the page if
Trello isn't installed yet — no false "already set up".

### Chrome sign-in

The script opens the Google sign-in page in Chrome so you can sign in with your
Google account — the 1Password extension autofills the password. Google sign-in
can't be scripted safely, so this step is a one-time prompt, marker-guarded.

### Email

The script asks for your email **once** at the start and reuses it for three things:
the git commit identity (`.gitconfig`), the SSH key comment, and the Chrome/Google
sign-in. It's PII, so it's **never** committed — the repo's `.gitconfig` keeps a
`WORK_EMAIL_ADDRESS` placeholder, and the script substitutes your address only in
the local `~/.gitconfig` copy. (If your git/work email differs from your Google
account, split the prompt back into two.)

### pet

If `~/.config/pet/config.toml` is missing, the script downloads the **sanitized**
config from this repo (`pet/config.toml`). It then **injects the real Gist token
from 1Password whenever `access_token` is still blank** — on every re-run, not just
the first download — so a config written before 1Password CLI was connected gets
fixed on the next run. `pet sync` only runs once the token is present. The committed
config carries a **blank** `access_token` — the secret never lives in git.

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
- **1Password** — the `op` CLI must be connected: 1Password app → **Settings ▸
  Developer ▸ Integrate with 1Password CLI** (then it uses the app's session /
  Touch ID). Needed for storing the SSH key and reading the pet token.
- **GitHub SSH key** — if `gh` isn't authenticated, the script **runs `gh auth
  login`** so you're prompted through it. Suggested answers: **github.com · SSH ·
  your `~/.ssh/id_ed25519` key · title `gh` · authenticate with your PAT**. Your
  PAT (from 1Password) just needs the **`write:public_key`** (`admin:public_key`)
  scope — no `--scopes` flag is needed, since token scopes come from the PAT.
  Choosing SSH during login uploads the key directly; the script's follow-up add
  then reports "already registered" instead of erroring.
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
