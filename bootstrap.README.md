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
| CLI tools | git, curl, vim, zsh, gh, jq, mise, pet (formulae) + `1password-cli` (`op`) — a **cask**, no formula of that name exists |
| Apps (brew casks) | Ghostty, Claude Desktop, Logseq, 1Password, Zed, Google Chrome, Spotify, Docker Desktop, Dropbox, Tailscale, Rectangle, Telegram, WhatsApp, ChatGPT |
| curl installers | oh-my-zsh, Claude Code, rtk |
| Runtime manager | mise + a global Node (LTS) and **gws** (`@googleworkspace/cli`) |
| git config | copies the repo's `.gitconfig` to `~/.gitconfig`, filling the email placeholder |
| Claude Code | merges the repo's `claude/settings.json` into `~/.claude/settings.json` (auto mode by default) |
| Rectangle | imports the repo's `rectangle/com.knollsoft.Rectangle.plist`, then launches the app so it arms **Launch at login** |
| Apple toolchain | Xcode Command Line Tools, full Xcode (**Mac App Store**), iOS simulator runtime |
| Snippets | pet config fetched from this repo + token from 1Password + `pet sync` |
| SSH | key **generated in 1Password** (SSH Key item), served by the **1Password SSH agent** (private key never on disk), **registered on GitHub** |
| 1Password agent | installs the repo's `1password/agent.toml` so the agent also serves keys from **non-default vaults** |
| Workspace | `~/git/` + clones my repos (see below) |
| Dock | pinned to an exact list and order — **replaces** whatever is pinned, including the macOS defaults |

Anything already installed is filtered out with a single `brew list` first — one
`brew` call instead of one per item, so a re-run on a provisioned machine costs
milliseconds. Whatever's left is fetched up front with `brew fetch` so downloads
overlap, then installed **one at a time**. This matters: `brew install a b c`
**aborts the whole command at the first failure**, so one conflicting item silently
takes out everything listed after it — a pre-existing `/Applications/1Password.app`
(installed outside brew) is enough to skip the ten casks that follow it. Installing
individually means a failure costs you that one item, and the script names it
instead of reporting a vague "one or more failed". Casks use **`--adopt`**, so an
app already sitting in `/Applications` that matches the cask is taken over rather
than treated as a conflict.

Casks are listed under their **canonical tokens**, not aliases — `docker-desktop`
and `tailscale-app`, since plain `tailscale` is the *formula* (the CLI daemon).

The repo clones still run **concurrently**.

### Xcode

Installed from the **Mac App Store** (first-party). The script opens the App Store
Xcode page; after Xcode finishes installing, **re-run** the script to accept the
license and download the iOS simulator runtime (`xcodebuild -downloadPlatform iOS`).
The Command Line Tools come in automatically with the Homebrew install.

### Claude Code

Installed via the official installer, which drops the binary in `~/.local/bin` —
not on a fresh macOS `PATH`. The script **adds `~/.local/bin` to `~/.zshrc` at most
once** (and exports it for the current run, since re-sourcing a zsh rc from a bash
script isn't valid).

Settings live in this repo at **`claude/settings.json`** — the source of truth,
versioned like `.gitconfig`. The script **merges** it into `~/.claude/settings.json`
with `jq`'s recursive `*`, so the repo's values win while anything else already in
the local file (including other keys under `permissions`) survives. Re-runs are a
no-op once applied. To change a Claude Code default on every machine, edit
`claude/settings.json` here and re-run.

It ships `permissions.defaultMode: "auto"` — **auto mode by default**. That has to
go in **user** settings: since v2.1.142 Claude Code ignores `defaultMode: "auto"` in
a project's `.claude/settings.json`, so a repo can't grant itself auto mode.

### Rectangle

Settings live in this repo at **`rectangle/com.knollsoft.Rectangle.plist`** and are
applied with `defaults import`, which **replaces the whole preferences domain** — the
repo file is the source of truth. Edit it here and re-run; the file's header has the
re-export command if you changed something in Rectangle's UI instead.

Two things the script works around:

- **Rectangle is quit before the import.** `cfprefsd` serves a running app its own
  cached copy of the domain and flushes it back on quit, undoing the import.
- **"Launch at login" is not fully a file.** `launchOnLogin` is only the checkbox; the
  login item itself is registered in macOS's Background Task Management store, which is
  SIP-protected. Rectangle's `checkLaunchOnLogin()` reconciles the two at startup, so
  the script **launches Rectangle once after importing** — that's what arms it.

Re-runs are a no-op. The idempotency check treats the repo's keys as a **subset** of the
live domain, since Rectangle writes bookkeeping keys of its own (`lastVersion`,
`SUHasLaunchedBefore`) on first run. Those aren't committed, so a fresh machine takes
Rectangle's new-install path instead of replaying upgrade migrations.

First launch prompts for **Accessibility** access, which can't be scripted — it's listed
in the pending items.

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

The token is read from the 1Password item named **`pet - GitHub Classic Token`**
(override with `PET_OP_ITEM`). If that item doesn't exist, the script **creates it**
from a token you paste in. The committed config already has the real `gist_id`
(syncing `pet-snippet.toml`) — the Gist id is not a secret.

`~/.config/pet/config.toml` is chmod **600** — `curl` creates it world-readable
and the GitHub token gets written into it. The TOML writer preserves the file's
mode, so that survives re-runs.

The token is read from the item's **concealed field**, via `--format json` (or the
`Value:` line without `jq`). Not `op item get --fields type=concealed | head -1`:
that prints a labelled block, so `head -1` returns the literal string
`Label:        token` — which used to get written into `access_token` and was the
real cause of the `401` from `pet sync`. Reading the field's value also makes the
category irrelevant (the item is an **API Credential** whose concealed field lives
in a section, not a Password item's `password`).

The token lands **only in the `[Gist]` section** — pet's config repeats
`access_token` under `[GHEGist]` and `[GitLab]` too, and only `[Gist]` is used
(`Backend = "gist"`).

The script also fills **`General.SnippetFile`** (`~/.config/pet/snippet.toml`) and
**creates that file** if missing. pet 1.0.1 needs both: with the committed blank
value `pet sync` dies with a nil-pointer panic, and a merely missing file makes it
refuse to run. The path embeds `$HOME`, so like the token it's filled at bootstrap
time rather than committed.

**Before syncing**, the script validates against the GitHub API, because `pet sync`
only reports an opaque `401`:

- `GET /user` — a **401 is always the token**, never the gist id. It first
  **re-reads 1Password** (so a config holding a stale or mangled value self-heals on
  a re-run instead of nagging for a token that already exists), and only then asks
  you to paste a new one — which it writes back to **both 1Password and the config**.
- the token's `x-oauth-scopes` header — warns if the classic PAT lacks **`gist`**.
- `GET /gists/<gist_id>` — a **404** means the gist is gone or belongs to another
  account; the script **clears `gist_id`** so `pet sync` creates a fresh gist and
  records the new id.

## Repos cloned into ~/git

`albertoblaz`, `albertoblaz.github.io`, `dotfiles`, `golden-gamers`,
`golden-gamers-methodology`, `logseq-books`, `logseq-work`.

Cloning is all the script does. **Per-project setup — pinned runtimes, deps,
databases — is left to each repo's own scripts**, run by you afterwards.

## Steps that need a human (interactive)

Isolated and **non-fatal** — an unattended run finishes everything else and tells
you what still needs you. Most of these are handled **inline, during the run**
(`gh auth login` prompts you, the 1Password agent check waits for you); the closing
summary lists only work that genuinely **outlives** the script, and says
"Nothing left that needs a human" when there is none.

- **Admin password** — asked for **once at the start** (`sudo -v`), then kept warm
  in the background for the rest of the run. A few casks symlink into
  `/usr/local/bin` (`docker-desktop`, `tailscale-app`) and the Xcode license step
  needs root. Without priming it up front the prompt appears mid-run after a long
  download — and with no terminal it fails outright with `sudo: a terminal is
  required`, losing that cask. If admin rights aren't available the run continues;
  only the steps that need root fail, and they're named at the end.
- **Xcode** — install from the App Store (Apple ID), then re-run.
- **1Password** — two one-time in-app toggles (Settings ▸ Developer), neither
  scriptable: **Integrate with 1Password CLI** (needed to generate the SSH key and
  read the pet token) and **Use the SSH agent** (serves the SSH key so the private
  key never touches disk). If the agent is off the script opens 1Password and
  **waits** — press Enter to re-check, or `s` to skip. Every clone depends on it,
  so racing ahead just produced failed clones.
- **GitHub SSH key** — if `gh` isn't authenticated, the script **runs `gh auth
  login`** so you're prompted through it. Suggested answers: **github.com · SSH ·
  your `~/.ssh/id_ed25519` key · title `gh` · authenticate with your PAT**. Your
  PAT (from 1Password) just needs the **`write:public_key`** (`admin:public_key`)
  scope — no `--scopes` flag is needed, since token scopes come from the PAT.
  Choosing SSH during login uploads the key directly; the script's follow-up add
  then reports "already registered" instead of erroring.
- **Chrome sign-in** — a one-time browser step.
- **Rectangle Accessibility access** — the script imports Rectangle's settings and
  launches it, but macOS only grants Accessibility on an explicit user approval
  (System Settings ▸ Privacy & Security ▸ Accessibility). Until then Rectangle
  can't move windows. Launch-at-login itself needs no approval.

All pauses are guarded by a `[[ -t 0 ]]` check, so an unattended run never hangs —
it warns and carries on.

## SSH key → GitHub → clone

Uses the **1Password SSH agent** — the private key never touches disk.

1. **Generates the key inside 1Password** as a proper **SSH Key** item
   (`op item create --category ssh`) — the op CLI can't *import* an existing key as
   an SSH Key item (desktop-app only), so generating it there is the way to get the
   right item type. Idempotent: skips if the item already exists. Defaults to the
   `Personal` vault; set `OP_VAULT=…` to override.
2. Pulls **only the public key** to `~/.ssh/id_ed25519.pub` (for the ssh-config
   `IdentityFile` and the GitHub upload), and writes `~/.ssh/config` to point at the
   1Password agent socket with a `Host github.com` block (`IdentitiesOnly yes` +
   that one `IdentityFile`) so GitHub authorizes **once per session, not per key**.
   With Touch ID unlock this is seamless. If `op` isn't available it **falls back to
   a local on-disk key + Keychain** so the clone still works.
3. Registers the **public** key on **GitHub** via `gh ssh-key add` (treats
   "already in use" as success).
4. Pre-trusts `github.com` (`ssh-keyscan`) so the first SSH clone doesn't hang, then
   **verifies `ssh -T git@github.com` actually authenticates** before cloning —
   retry/skip prompt on failure. This also front-loads the 1Password approval onto
   one foreground connection instead of racing it against seven parallel clones.
5. Clones the repos over SSH — **skipping any repo already present in `~/git/`**.

## 1Password SSH agent — which vaults it serves

By default the agent only offers keys from the **default** Personal / Private /
Employee vault. A key kept in any other vault is simply never offered, and ssh then
falls through to a password prompt — which reads like a broken key rather than a
config problem. `~/.config/1Password/ssh/agent.toml` is what widens that.

The repo's **`1password/agent.toml`** is the source of truth; the script installs it
(mode 600). The trap the file's own header calls out: creating it **overrides the
default wholesale** — the agent then serves *only* what's listed, so the everyday vault
has to be listed explicitly. Drop it and git over SSH breaks.

Edit the repo copy and re-run `./bootstrap.sh`, not the installed file. If the installed
file has diverged anyway, the script backs it up to `agent.toml.bak` rather than
silently overwriting it, so a hand-added vault entry isn't lost.

**What's public:** vault *names* only. No keys, no fingerprints, no item or host names.
Keep it that way — no hostnames or IPs in the comments, even to explain why a vault is
listed.

## Security note — pet token

This repo is **public**, so the committed `pet/config.toml` has **blank**
`access_token` fields. The real token lives in **1Password** and is injected into
the local config at bootstrap time. Never commit the token here.

## Notes

- Open a **new terminal** after the run so PATH / shell changes take effect.
