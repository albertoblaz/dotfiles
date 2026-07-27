# macOS dev-machine bootstrap

`scripts/bootstrap.sh` provisions a fresh **Mac** with the full Golden Gamers dev
toolset in one command. It is **idempotent** — safe to re-run; every step skips
whatever is already installed.

Lives in this **dotfiles** repo; it clones `golden-gamers` (and other setup) for you.

## Usage

```bash
# From the dotfiles repo root:
./bootstrap.sh

# Preview every command without changing anything:
BOOTSTRAP_DRYRUN=1 ./bootstrap.sh
```

macOS only — it refuses to run on any other OS.

## What it installs

**Package manager / policy:** prefers **Homebrew** for anything with a
formula/cask (clean upgrade/uninstall, idempotency). Official `curl | sh`
installers are used only where no formula exists: **Claude Code**, **rtk**,
**oh-my-zsh**.

| Category | Tools |
|----------|-------|
| CLI (brew formulae) | curl, vim, zsh, gh, mise, pet, `postgresql@16`, `1password-cli` (`op`) |
| Apps (brew casks) | Ghostty, Claude Desktop, Logseq, 1Password, Zed, Google Chrome, Spotify, Docker Desktop, Tailscale, Telegram, WhatsApp, ChatGPT |
| curl installers | oh-my-zsh, Claude Code, rtk |
| Runtime manager | mise (the tool only — languages are installed by the repo's `setup.sh`) |
| Database | PostgreSQL **16** (matches prod) |
| Apple toolchain | Xcode Command Line Tools, full Xcode (**Mac App Store**), iOS simulator runtime |
| Snippets | pet config fetched from dotfiles + token from 1Password + `pet sync` |
| SSH | new `~/.ssh/id_ed25519`, stored in 1Password **and registered on GitHub** |
| Workspace | `~/git/`, clones `golden-gamers`, then runs its `scripts/setup.sh` |

### Project setup lives in golden-gamers

Anything golden-gamers-specific — installing the pinned Ruby/Node and the
backend/frontend dependencies — is **not** in this bootstrap. After cloning, the
bootstrap delegates to **`golden-gamers/scripts/setup.sh`**, which:
- reads `backend/.ruby-version` (`3.4.5`) + `frontend/.node-version` (`20`) and
  installs them via mise (`ruby.compile=false`, idiomatic version files), and
- runs `bundle install` (backend, provides `bin/rails`) and `npm install` (frontend).

That script is cross-platform and can be run on its own anytime:
`cd ~/git/golden-gamers && ./scripts/setup.sh`.

### Version pinning
- **Postgres** is pinned to **major 16** to match production
  (`backend/config/deploy.yml` → `image: postgres:16`). The check is
  version-aware — an existing *different* major won't cause a false skip.

### Rails is not installed globally

There is no `gem install rails`. Rails is a dependency of `backend/Gemfile`;
`golden-gamers/scripts/setup.sh` runs `bundle install` in `backend/`, which installs
Rails into the bundle and exposes it as **`backend/bin/rails`** (or
`bundle exec rails`). The frontend gets `npm install`.

### Xcode

Installed from the **Mac App Store** (first-party). The script opens the App Store
Xcode page; after Xcode finishes installing, **re-run** the script to accept the
license and download the iOS simulator runtime (`xcodebuild -downloadPlatform iOS`).
The Command Line Tools come in automatically with the Homebrew install.

### Trello

Atlassian discontinued the standalone desktop app and the Homebrew cask was removed
(confirmed 404). The script installs it as a **web app**: it opens
<https://trello.com> once so you can **Add to Dock** (Safari) or **Install** as an
app (Chrome). A marker at `~/.config/gg-bootstrap/` keeps re-runs from reopening it.

### pet

If `~/.config/pet/config.toml` is missing, the script downloads the **sanitized**
config from this repo (`pet/config.toml`, via `PET_CONFIG_URL`), then **injects the
real Gist token from 1Password** before running `pet sync`. The committed config
carries a **blank** `access_token` — the secret never lives in git.

The token is read from the 1Password item named **`pet - Github Classic Token`**
(override with `PET_OP_ITEM`). If that item doesn't exist, the script **creates it**
from a token you paste in. The committed config already has the real `gist_id`
(`61acc538…`, syncing `pet-snippet.toml`) — the Gist id is not a secret.

## Steps that need a human (interactive)

Isolated and **non-fatal** — an unattended run finishes everything else and tells
you what still needs you:

- **Xcode** — install from the App Store (Apple ID), then re-run.
- **1Password** — storing the SSH key needs `op` **signed in** (desktop-app
  integration or `op signin`).
- **GitHub SSH key** — `gh` must be authenticated (`gh auth login`) **with the
  `write:public_key` scope**. The default login scopes don't include it; the script
  runs `gh auth refresh -h github.com -s write:public_key` (opens a browser) when
  the scope is missing.
- **pet** — needs a valid `config.toml` (Gist id + token) to sync.

## SSH key → GitHub → clone

1. Generates `~/.ssh/id_ed25519` **only if none exists** (never overwrites), sets
   perms, and wires it into the ssh-agent + macOS Keychain.
2. Uploads the private key to **1Password** as a document.
3. Registers the **public** key on **GitHub** via `gh ssh-key add`.
4. Clones `git@github.com:albertoblaz/golden-gamers.git` into `~/git/golden-gamers`
   over SSH (works because step 3 registered the key), then installs deps.

## Security note — pet token

This repo is **public**, so the committed `pet/config.toml` has **blank**
`access_token` fields. The real token lives in **1Password** and is injected into
the local config at bootstrap time (see the **pet** section). Never commit the
token here.

## Notes

- The script only *installs* PostgreSQL — it never runs `db:seed`, `db:reset`, or
  any database-mutating command.
- Open a **new terminal** after the run so PATH / shell changes take effect.
