# herdr-pipe-patch

Grant other accounts access to the [herdr](https://github.com/herdrdev/herdr-core)
pipes on Windows — and take it back again.

herdr-core's named pipes grant access to SYSTEM and to the account that started
the core, and to nobody else:

```
D:P(A;;GA;;;SY)(A;;GA;;;<owner SID>)S:(ML;;NRNW;;;ME)
```

A client that has to run as another account — a coding agent's sandbox, for
instance — is refused:

```
the Windows core exists but this process cannot access its pipe: Access is denied. (os error 5)
```

This repository carries a tool that installs a herdr-core which understands
`HERDR_PIPE_EXTRA_SIDS`, sets that variable for the accounts you name, and
**proves the result by reading the live pipe's access control list back**.

It also carries a **skill** for codex and Claude Code that walks a person (or an
agent) through the whole thing, including the parts only an administrator can do.

---

## The fix

herdr-core reads `HERDR_PIPE_EXTRA_SIDS` when it starts and adds one allow-ACE
per SID to every pipe it creates:

```
HERDR_PIPE_EXTRA_SIDS=S-1-5-21-…-1010;S-1-5-21-…-1011
```

The variable is empty by default, so an install that does not set it behaves
exactly as before.

This is upstream PR [herdrdev/herdr-core#219](https://github.com/herdrdev/herdr-core/pull/219)
(issue [#224](https://github.com/herdrdev/herdr-core/issues/224)). The diff is in
[`patches/`](patches) and the tool can apply it to any herdr-core release.

Two things make this worth a tool rather than a one-off change:

- **The binary has to change.** The core creates a fresh pipe instance on every
  accept, each carrying the descriptor above, so the access rules cannot be
  fixed from outside once the core runs. Patching the descriptor of the instance
  you can see changes nothing: the client always meets the next, unpatched
  instance.
- **A group SID is not enough.** The access check honours a restricted token's
  *user* SID but not its group SIDs, so an ACE for a group the client belongs to
  grants it nothing. Only the account's own user SID (or Everyone) works. The
  accounts differ per machine, so they have to be discovered, never hardcoded.

---

## Install

### As a plugin

This repository is a plugin marketplace with one plugin in it, and **two agents
read the same manifest**: Claude Code and codex both look for
`.claude-plugin/marketplace.json` and `.claude-plugin/plugin.json`. So a
machine that runs either one can take the whole thing — the skill and the tool —
in one step.

**Claude Code:**

```
/plugin install herdr-pipe-patch --marketplace cifilaci/herdr-pipe-patch
```

or, on Claude Code 2.1.275 or later, from the shell in one command:

```
claude plugin install herdr-pipe-patch --marketplace cifilaci/herdr-pipe-patch
```

**codex:**

```
codex plugin marketplace add cifilaci/herdr-pipe-patch
codex plugin add herdr-pipe-patch@herdr-pipe-patch
```

codex prefers `.codex-plugin/` when a repository has one and falls back to
`.claude-plugin/`, so the same two files serve both products. The plugin lands
in `~/.codex/plugins/cache/<marketplace>/<plugin>/<version>/`, and the agent
sees the skill namespaced as `herdr-pipe-patch:herdr-pipe-patch`.

The one thing the two do not share is the name of the plugin's own folder.
Claude Code expands `${CLAUDE_PLUGIN_ROOT}` into the text of the skill; codex
leaves the text as it is and only exports the variable to hooks. So the skill
names that folder by its place instead — two levels up from the skill file —
which is the same folder under both installations.

codex keeps what it installed in the folder named after the version, and it
does not look at the repository again on its own. After a release, refresh the
marketplace and install again:

```
codex plugin marketplace upgrade
codex plugin add herdr-pipe-patch@herdr-pipe-patch
```

The folder is named after the plugin's `version` in `.claude-plugin/plugin.json`,
so a new version lands in a new folder and the old one is dropped. The version
is bumped with every release, and the release fails if the manifest still
carries an older one.

The skill then walks the agent through the whole flow, and the tool comes with
it: the script, the patch and the prebuilt patched core.

What a plugin cannot do is the one step that needs an administrator —
`codex sandbox setup --elevated --current-user`. The skill says to stop and
ask for it. A plugin also does not change what `apply` does: it still restarts
the core, and it still grants the accounts the elevated sandbox runs as.

### One file

[`herdr-pipe-patch.exe`](https://github.com/cifilaci/herdr-pipe-patch/releases)
is the whole tool in one executable: the script, the patched core, the patch,
the skill and the two skill installers are inside it. Copy that one file to a
machine that has herdr-core installed and run it.

```
herdr-pipe-patch.exe status
herdr-pipe-patch.exe apply -Account CodexSandboxOffline
herdr-pipe-patch.exe verify -Probe
```

On the first run it unpacks itself into
`%LOCALAPPDATA%\herdr-pipe-patch\<marker>` and runs the script from there. The
unpacked files stay on disk in plain text, so the script can be read before it is
trusted — and the marker is a hash of what the executable carries, so a new
build of the exe unpacks afresh.

It needs PowerShell 5.1 (it ships with Windows) and nothing else: no Rust, no
cargo, no folder of loose files. The skill installers it carries need the
herdr binaries on the machine they run on.

### The zip

The release also carries `herdr-pipe-patch-<version>.zip` with the script, the
patch and the payload, so you can read everything before running it:

```powershell
$version = '0.1.20'
$base = "https://github.com/cifilaci/herdr-pipe-patch/releases/download/v$version"
$zip = "$env:TEMP\herdr-pipe-patch-$version.zip"
curl.exe -fsSL -o $zip "$base/herdr-pipe-patch-$version.zip"

# compare with the published checksum before unpacking
$want = (curl.exe -fsSL "$base/herdr-pipe-patch-$version.zip.sha256").Split()[0]
$got = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLower()
if ($got -ne $want) { throw "the download is not the published file: $got, expected $want" }

Expand-Archive -Force $zip "$env:TEMP\herdr-pipe-patch-$version"
cd "$env:TEMP\herdr-pipe-patch-$version"
```

The zip is flat, so the tool sits at the top of the folder the archive is
expanded into. The commands below are relative to it, so `cd` there first.

The checksum proves the download is intact. It is not signed, so it does not
prove who published it.

A checksum that does not match is usually **not** a damaged download: when a
release is re-published, the download service keeps serving the previous file
for a while, and the checksum beside it is already the new one. Wait a few
minutes and download again.

### The skill

The skill and its installer are in the tool zip above, in this repository, and
inside `herdr-pipe-patch.exe`. On Windows:

```powershell
.\install-skill.ps1
```

installs two things into `~/.codex/skills/` and `~/.claude/skills/`:

- **`herdr-pipe-patch`** — this repository's skill. It tells an agent how to
  grant the accounts, how to set the codex side up, and when to stop and ask the
  person.
- **`herdr`** — the guide an agent reads to drive Herdr at all. It is built from
  the manuals the *installed* binaries print (`hc --skill` and `herdr-app
  --skill`), with a head in front of them: the frontmatter, the `HC_TERMINAL_ID`
  gate and the note that there is no `HERDR_ENV` in this Herdr. The manuals
  themselves are never copied into this repository — they are read from the
  machine, so the guide is never stale.

```powershell
.\install-skill.ps1 -Target Codex        # or -Target ClaudeCode
.\install-skill.ps1 -Only HerdrGuide     # only refresh the guide
.\install-skill.ps1 -DryRun              # print what would happen
```

### The skill on a WSL machine

`install-skill-wsl.sh` does the same for a WSL machine that talks to a Windows
Herdr App. It is in the tool zip above and in the repository:

```
sh install-skill-wsl.sh              # the guide and the win-hc wrapper
sh install-skill-wsl.sh --dry-run    # print what would happen
```

Run it with `sh`: a zip made on Windows carries no exec bit.

It writes the guide into `~/.claude/skills/herdr/` and `~/.codex/skills/herdr/`
— built from the `hc --skill` of the core **on this machine** — and puts the
`win-hc` wrapper into `~/.local/bin/`, so a WSL-side agent can reach the
Windows core's terminals and agents too.

`~/.local/bin` has to be on `PATH` for `win-hc` to be found. The installer says
so when it is not, and the remedy is one line:

```
export PATH="$HOME/.local/bin:$PATH"
```

---

## Use

```powershell
# what is installed, and does the pipe already grant what you want?
.\herdr-pipe-patch.ps1 status

# grant accounts, by name (their user SIDs are resolved on this machine)
.\herdr-pipe-patch.ps1 apply -Account CodexSandboxOffline,CodexSandboxOnline

# or grant by SID
.\herdr-pipe-patch.ps1 apply -Sids "S-1-5-21-…-1010;S-1-5-21-…-1011"

# see the plan without changing anything
.\herdr-pipe-patch.ps1 apply -DryRun

# check, and drive the core from a sandbox for real
.\herdr-pipe-patch.ps1 verify -Probe

# put it all back
.\herdr-pipe-patch.ps1 unpatch
```

With no `-Account` and no `-Sids`, the tool grants the local accounts whose name
matches `-AccountPattern` (default `CodexSandbox*`).

### Commands

| Command | What it does |
|---|---|
| `status` | Read-only. The installed core, whether it carries the patch, the user-level variable, the live pipe's descriptor, the codex settings, both agents' guides, and a verdict. |
| `apply` | Installs a patched core if the installed one lacks it, sets the variable (process + user level), restarts the core, repairs the codex settings and both agents' guides, and verifies both. |
| `unpatch` | Restores the stock core, removes the variable, restarts the core, verifies the grants are gone. |
| `verify` | The live descriptor, `hc server status` and the codex side. With `-Probe`, a real sandboxed client drives the core. |
| `build` | Builds a patched core for a version and stores it as a payload. |

### Options

| Option | Meaning |
|---|---|
| `-HcPath <path>` | The `hc` to manage. Default: the one this machine would use (the app's `settings.json`, then `PATH`, then `%LOCALAPPDATA%\Programs\herdr-core`, then `~\.cargo\bin`). A path given here is used as it is: if it is not a working hc the tool stops, rather than quietly managing a different one. |
| `-Session <name>` | The core session. Default `default`. |
| `-Sids <list>` | SIDs to grant, separated by `,` or `;`. |
| `-Account <names>` | Accounts to grant, by name. Several names are separated by a comma: `-Account Alice,Bob`. |
| `-AccountPattern <glob>` | Which accounts to grant when neither of the above is given. Default `CodexSandbox*`. |
| `-Version <v>` | The version for `build`. |
| `-DryRun` | Print the plan, change nothing. |
| `-Quiet` | Only the errors and the warnings. |
| `-Probe` | Also drive the core from a sandbox (needs `codex` on `PATH`). The command fails if the probe cannot run, and if the sandboxed client cannot reach the core. |
| `-ReleasesUrl <url>` | Where `unpatch` downloads the stock core from. Default `https://releases.herdr.dev`. |
| `-Repo <path>` | An existing herdr-core clone to build in. |
| `-WorkDir <path>` | Where the build happens. |

---

## The codex side

The pipe is only half of it. A sandboxed codex also has to be set up to *run as
another account at all*, and to be told where the manuals are. The tool checks
that too, and `status` prints it:

```
codex
    codex           : codex-cli 0.167.0
    config.toml     : C:\Users\Cifi\.codex\config.toml
    sandbox_mode    : workspace-write
    windows.sandbox : elevated
    daemon_auto_start: false
    sandbox accounts: CodexSandboxOffline, CodexSandboxOnline
    sandbox service : CodexSandboxService.OpenAI.Codex (Running)
    app-server      : running
    ! a shared app-server daemon is running. Codex sessions started without --no-daemon use it, and it froze the pane environment before.
    skill           : C:\Users\Cifi\.codex\skills\herdr\SKILL.md
    gate            : HC_TERMINAL_ID
    hc manual       : up to date
    app manual      : up to date
claude code
    skill           : C:\Users\Cifi\.claude\skills\herdr\SKILL.md
    gate            : HC_TERMINAL_ID
    hc manual       : up to date
    app manual      : up to date
```

What it checks, and why each one matters:

| Check | Why |
|---|---|
| `[windows] sandbox = "elevated"` in `~/.codex/config.toml` | Only the elevated sandbox runs as a separate account. The restricted-token sandbox runs as the user, and the access check honours a restricted token's *user* SID but not its group SIDs — so nothing in the pipe's descriptor grants it. |
| `codex sandbox setup --elevated --current-user` has been run | It creates the service `CodexSandboxService.OpenAI.Codex` and the accounts `CodexSandboxOffline` / `CodexSandboxOnline`. Without them codex falls back to the restricted token, and the pipe refuses it. |
| The pipe grants those accounts | The grant list must cover the accounts the elevated sandbox runs as. |
| `[features] daemon_auto_start = false` | A shared app-server daemon spawns the session's hooks and tools with *its* environment, so the pane's `HC_TERMINAL_ID` never reaches the agent. |
| The skill gates on `HC_TERMINAL_ID` | The older `herdr` guide gates on `HERDR_ENV=1`, a variable nothing sets in this Herdr — the agent would stop and say it is not inside Herdr. |
| The skill carries the current manuals | The skill is the wrapper plus `hc --skill` plus `herdr-app --skill`. When the core is updated, the copy in `~/.codex/skills/herdr/` is left behind, and the agent reads yesterday's commands. |

`apply` fixes the two it can fix safely, keeping a copy of the old file beside
it: the two keys in `config.toml`, and the skill (rebuilt from the manuals the
installed binaries print right now, with the wrapper taken from the installed
file).

Two steps it deliberately leaves to you, because both reach beyond this tool:

```
codex sandbox setup --elevated --current-user    # needs an elevated terminal
codex app-server daemon stop                     # only when no other session needs it
```

and starting codex as `codex --no-daemon` — the flag goes **before** the
subcommand (`codex --no-daemon exec …`, not `codex exec --no-daemon …`).

---

## What it touches

- `%LOCALAPPDATA%\Programs\herdr-core\herdr-core.exe` — replaced by a patched
  build (the old one is kept beside it as `herdr-core.exe.stock-<version>.bak`).
- The user environment variable `HERDR_PIPE_EXTRA_SIDS`.
- The core process: it is restarted, because the variable is read at start-up.
- On the codex side: `~/.codex/config.toml` (two keys).
- The Herdr guide, for both agents that read one: `~/.codex/skills/herdr/SKILL.md`
  and `~/.claude/skills/herdr/SKILL.md`, rebuilt from the current manuals. They
  are copied to `*.bak-<timestamp>` before they are changed.

It does **not** touch your terminals. The holders own them, not the core, so they
survive the restart.

## What it checks

- The candidate binary is verified twice before it is installed: its sha256
  against the `.sha256` file beside it, and a **behavioural probe** — the
  candidate is run as an isolated core (its own session, its own pipe) and the
  pipe's descriptor is read back to confirm it really grants the SIDs on this
  machine. A binary that merely contains the string `HERDR_PIPE_EXTRA_SIDS` but
  does not implement the feature fails the probe and is never installed.
- `unpatch` restores the stock core from the `.bak` backup, or downloads the
  release and checks it against the checksum in the release manifest. The
  manifest is not signed, so that proves the download is intact, not who
  published it.
- After every change the live pipe's descriptor is read back, and the tool exits
  non-zero if the result is not what was asked for.
- Everything is logged to `herdr-pipe-patch.log` next to the tool.

---

## The repository

```
herdr-pipe-patch\
  herdr-pipe-patch.ps1                the tool
  install-skill.ps1                   installs the skills for codex and Claude Code (Windows)
  install-skill-wsl.sh                the same for a WSL machine
  README.md                           this file
  LICENSE
  patches\
    herdr-core-pipe-extra-sids.patch    the upstream diff
  payload\
    0.1.20\                           one folder per built version
      herdr-core.exe                   a prebuilt patched core
      herdr-core.exe.sha256            its checksum
      BUILD.txt                        where it came from
  scripts\
    probe-core.ps1                    the behavioural probe, on its own
  skills\
    herdr-pipe-patch\SKILL.md         the skill agents read
  assets\
    herdr-skill-wrapper.md            the head of the Herdr guide (Windows)
    herdr-skill-wrapper-wsl.md        the head of the Herdr guide (WSL)
    win-hc                            the Windows core, run from WSL
  launcher\                            the source of the one-file exe
    build.rs                            collects the payloads into the binary
    src\main.rs                         the launcher itself
    build.cmd                           copy the files in and rebuild it
  .claude-plugin\                       what makes this a plugin and a marketplace
    plugin.json                          the plugin manifest, with the version
    marketplace.json                     the catalog that lists the plugin
  .github\workflows\release.yml         builds and publishes the release
```

The `payload` folder is committed so that `apply` works on a machine with no
compiler. The one-file executable is built from `launcher\`:

```
launcher\build.cmd
```

which copies the files into `launcher\tree`, runs `cargo build --release` and
puts the new `herdr-pipe-patch.exe` back in the folder. The build fails when a
file in the tree is not carried by the executable, when one of the files the
executable carries is missing from the tree, and when the tree holds no
payload at all: the released zip and the one-file form would otherwise differ,
and nothing would say so. The tree is a build artefact — `build.cmd` makes it
fresh every time, so the check runs on every build.

### The release

The tag names the herdr-core version the payload was built from: the tag
`v0.1.20` publishes the assets for herdr-core 0.1.20. Pushing that tag runs
[`.github/workflows/release.yml`](.github/workflows/release.yml), which

1. installs Rust and Zig 0.16,
2. clones herdr-core at the tag and applies `patches/`,
3. builds the core,
4. **proves it** — the binary is run as an isolated core and its pipe descriptor
   read back; the job fails if it does not grant the SIDs,
5. stamps the release's version into the README and the skill — the
   one-file executable carries both, so it has to happen before it is built,
6. checks that the plugin manifest is not behind the release,
7. builds the one-file executable, and checks that what it carries names that
   version too,
8. checks that the executable and the package carry the same files,
9. publishes the tool zip, the executable, the patched core on its own, and a
   `.sha256` beside every asset.

The plugin manifest (`.claude-plugin/plugin.json`) carries the payload's
version, and a plugin that declares a `version` stays on it until the manifest
changes — so the people who installed the plugin keep the tool the manifest
names. **Bump it and commit before you tag.** The release checks it: a tag
whose manifest still carries an older version fails the job, rather than
publishing a release that quietly leaves the plugin behind.

`.claude-plugin/marketplace.json` is what makes the repository a marketplace:
it lists the plugin, whose `source` is `"./"` — the repository root, which is
the plugin's own directory. The entry's name and the manifest's name have to be
the same, or the install fails with `Plugin "<name>" not found in marketplace
"<marketplace>"`. Check both with `claude plugin validate .` in the repository
root.

---

## Things worth knowing

- **Grant the account's own SID, not a group.** The tool says so when you pass a
  group SID: a restricted token's group SIDs are not honoured by the access
  check.
- **The Herdr app's "Update herdr-core" button will undo this.** It installs a
  stock core. `status` shows the installed version so you can see it happen;
  `apply` puts the patch back.
- **A new herdr-core release does not contain the patch** until PR #219 is
  merged and released. After an update, run `status`; it will say the core needs
  the patch again, and `apply` will fix it. `build -Version <v>` builds a
  patched core for the new version if the bundled payload does not match.
- **The release ships a patched core for its own version.** `apply` looks for
  `payload\<installed version>\`, and falls back to building one from the tag
  when there is none. The payload folder can hold more than one version; the
  one that matters is the one that matches the core you have.
- **The codex skill goes stale when the core is updated.** It is a copy of the
  manuals the binaries printed at the time; `status` says when it is older than
  the installed core, and `apply` rebuilds it.
- **Rust embeds a path-dependent metadata hash**, so a rebuild of the same source
  is not byte-identical to the bundled payload. Compare behaviour, not bytes.

## Requirements

- Windows 10 or newer, PowerShell 5.1 (the tool) — no compiler needed to *run*
  it.
- herdr-core installed (`hc --version` prints `hc <version>`).
- **herdr-app** installed as well, for `install-skill.ps1`: the Herdr guide is
  built from the manuals both binaries print, so it needs both.
- To build a payload instead of using the bundled one: git, Rust (cargo) and
  **Zig 0.16** (the vendored `ghostty-vt` needs it).

## Licence

Apache 2.0 — see [LICENSE](LICENSE). The herdr-core patch is upstream's work
under herdr-core's own licence.
