---
name: herdr-pipe-patch
description: "Grant other accounts access to the herdr-core pipes on Windows, and take it back. Use when an agent in a sandbox cannot open the Herdr pipe (\"Access is denied\", os error 5), when a client runs as another account than the one that started the core, when a herdr-core update dropped the patch, or when setting up a machine to run Herdr and a coding agent's sandbox together. Also installs and refreshes the Herdr skill for codex and Claude Code."
---

# The Herdr pipe patch

herdr-core's Windows named pipes grant access to SYSTEM and to the account that
started the core, and to nobody else. A client that has to run as another account —
a coding agent's sandbox — is refused:

```
the Windows core exists but this process cannot access its pipe: Access is denied. (os error 5)
```

The fix is in the core: it reads `HERDR_PIPE_EXTRA_SIDS` at start-up and adds one
allow-ACE per SID to every pipe it creates. This skill installs a core that has
that support, sets the variable, and proves the result by reading the live pipe's
descriptor back.

The upstream work: [herdrdev/herdr-core#219](https://github.com/herdrdev/herdr-core/pull/219)
(issue [#224](https://github.com/herdrdev/herdr-core/issues/224)).

## Before you start

You need:

- Windows and herdr-core installed (`hc --version` prints `hc <version>`);
- the tool from this repository's releases (below);
- **one step that needs an elevated terminal** — the sandbox provisioning. When you
  get there, ask the user to run it, or run it yourself if your shell is elevated.

Check what is already in place before changing anything:

```powershell
$hc = "$env:LOCALAPPDATA\Programs\herdr-core\herdr-core.exe"
& $hc --version
& $hc server status --json
```

`hc server status` never starts a core on Windows, so it is safe to call. `hc ls`
does start one — do not use it to look around.

## Get the tool

The tool is in this repository; a release also carries it as a zip. If you have
the repository, use it:

```
herdr-pipe-patch.ps1
```

Otherwise download the release asset and check it. The release tag is the
herdr-core version the payload was built from:

```powershell
$version = '0.1.20'   # the herdr-core version you are patching
$base = "https://github.com/cifilaci/herdr-pipe-patch/releases/download/v$version"
$zip = "$env:TEMP\herdr-pipe-patch-$version.zip"
curl.exe -fsSL -o $zip "$base/herdr-pipe-patch-$version.zip"

# compare with the published .sha256 before unpacking
$want = (curl.exe -fsSL "$base/herdr-pipe-patch-$version.zip.sha256").Split()[0]
$got = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLower()
if ($got -ne $want) { throw "the download is damaged: $got, expected $want" }

Expand-Archive -Force $zip "$env:TEMP\herdr-pipe-patch-$version"
cd "$env:TEMP\herdr-pipe-patch-$version"
```

The zip holds the script, the patch and a prebuilt patched core, so no compiler
is needed. `herdr-pipe-patch.exe` is the same tool in one file if you only want
to copy something to another machine.

## The steps

### 1. See the state

```powershell
.\herdr-pipe-patch.ps1 status
```

It prints the installed core, whether it carries the patch, the live pipe's
descriptor, and the codex side. It changes nothing.

### 2. Decide who to grant

The client must be granted **its own account SID, not a group**. An access check
honours a restricted token's user SID but not its group SIDs, so an ACE for a group
the client belongs to grants it nothing — that is the mistake this whole thing is
about.

On a machine where codex runs its elevated sandbox, the accounts are
`CodexSandboxOffline` and `CodexSandboxOnline`; the tool finds them by pattern:

```powershell
.\herdr-pipe-patch.ps1 apply -Account CodexSandboxOffline -Account CodexSandboxOnline
```

or by SID, or with `-Sids`. `status` prints the SIDs the pipe currently grants. `apply`
**warns** when you give it a group SID and grants it anyway - the warning is
the point: an access check honours a restricted token's user SID but not its
group SIDs, so a group grants the client nothing. Give the account's own SID.

### 3. Apply

```powershell
.\herdr-pipe-patch.ps1 apply
```

It checks the state, installs a patched core if the installed one lacks it (from the
bundled payload, or by building one), verifies the candidate **behaviourally** — it
runs it as an isolated core and reads that pipe's descriptor back — backs up the
stock core, sets `HERDR_PIPE_EXTRA_SIDS` for the user, restarts the core so it
reads the variable, and reads the live descriptor back again.

`-DryRun` prints the plan and changes nothing.

This restarts the core. **Terminals keep running** — the holders own them, not the
core — but a client connected at that moment sees a brief gap.

### 4. The codex side

`status` prints this too. Three things decide whether a sandboxed codex can reach
the core at all:

| Setting | Why |
|---|---|
| `[windows] sandbox = "elevated"` in `~/.codex/config.toml` | Only the elevated sandbox runs as a separate account. The restricted-token sandbox runs as the user, and nothing in the pipe's descriptor grants it. |
| the elevated sandbox provisioned | `codex sandbox setup --elevated --current-user` creates the service `CodexSandboxService.OpenAI.Codex` and the accounts `CodexSandboxOffline` / `CodexSandboxOnline`. Without them codex falls back to the restricted token, and the pipe refuses it. |
| `[features] daemon_auto_start = false` | A shared app-server daemon spawns the session's hooks and tools with *its* environment, so the pane's `HC_TERMINAL_ID` never reaches the agent. |

The first and the third are settings `apply` writes for you (a copy of the old file
is kept beside it). The second needs an **elevated terminal**:

```
codex sandbox setup --elevated --current-user
```

**Ask the user to run that in an elevated terminal** if it has not been run — it
creates local accounts and a service. If your own shell is elevated you may run it,
but say what you are about to do first.

Also: start codex as `codex --no-daemon` — the flag goes **before** the subcommand
(`codex --no-daemon exec …`). And if a shared daemon is already running, it has to
be stopped before it lets go of the old environment: `codex app-server daemon stop`
— only when no other session needs it, so ask the user.

### 5. Verify

```powershell
.\herdr-pipe-patch.ps1 verify -Probe
```

`verify` checks the live descriptor and the codex side. `-Probe` runs a real
sandboxed client (`codex sandbox -c windows.sandbox=elevated <hc> ls --json`) and
fails if it cannot reach the core — that is the end-to-end proof, not an inference.

### 6. Take it back

```powershell
.\herdr-pipe-patch.ps1 unpatch
```

Restores the stock core, removes the variable, restarts the core, and checks that
the grants are gone.

## The Herdr skill for codex and Claude Code

The Herdr skill is a separate thing from this patch: it is the guide an agent reads
to drive Herdr. It goes into `~/.codex/skills/herdr/` **and**
`~/.claude/skills/herdr/` — codex reads the first, Claude Code the second. A
guide that is right for one and missing for the other leaves that session with
no guide at all.

What the guide has to say, or an agent stops before it does anything:

- **The gate is `HC_TERMINAL_ID`.** The older guide gates on `HERDR_ENV=1`, a
  variable nothing in this Herdr sets — an agent reading it says "I am not
  inside Herdr, so I stop", and the session is over before it starts.
- **`herdr` is a different product.** On a machine that has it, `herdr` is the
  0.9.5 terminal multiplexer: its own socket, its own agents, its own guide.
  `herdr agent list`, `herdr machine list` and `herdr --machine <label> agent
  prompt <name>` describe *that* product, not the Herdr App. The 0.1.x App's
  agents are driven with `hc`, by address.
- **The head must match the side of the machine.** On WSL the guide needs the
  head that names the two cores and `win-hc`; the Windows head tells the agent
  to use `hc` and `herdr-app` on the local core only, and never mentions
  `win-hc`, so a WSL agent reading it still cannot reach the Windows agents. If
  the installed guide does not mention `win-hc` on WSL, it has the wrong head.
- **The manuals must be current.** The guide is a copy of what the installed
  binaries print. When the core is updated, the copy goes stale and the agent
  reads yesterday's commands.

`herdr-pipe-patch.ps1 status` checks both guides (installed, the gate, the
head, the manuals) and `apply` rebuilds both from the binaries on this machine.

To install it on another machine:

```powershell
.\install-skill.ps1
```

which copies it into `~/.codex/skills/herdr/` and `~/.claude/skills/herdr/`.

On a **WSL** machine that talks to a Windows Herdr App, use the shell installer
instead — it writes the guide for the core *on that machine*, with the WSL head
(the two cores, `win-hc`), and puts the `win-hc` wrapper in `~/.local/bin/`, so
a WSL-side agent can reach the Windows core's terminals and agents:

```sh
sh install-skill-wsl.sh
```

Run it with `sh`: a zip made on Windows carries no exec bit. The pipe patch
itself is a Windows-side job — the core that owns the pipes runs on Windows —
so on WSL it is the `win-hc` wrapper that reaches them, not a patched core.

Check the WSL guide like this: it has to mention `win-hc`, and it has to gate on
`HC_TERMINAL_ID`. A guide that mentions neither is the wrong one — the 0.9.5
guide, or the Windows head.

## When the core is updated

A released herdr-core does **not** contain the patch until the upstream PR is
merged and released. After an update, `status` says the core needs the patch
again, and `apply` puts it back. The Herdr app's own **"Update herdr-core"**
button installs a stock core — `status` shows the installed version so you can see
it happen.

## What to tell the user

- before anything that restarts the core or writes to `~/.codex`;
- when the elevated sandbox provisioning is needed (that is the one step you
  cannot do for them);
- when a shared codex daemon would have to be stopped, because that ends other
  sessions;
- if the pipe still refuses a client after everything above — then the grant list
  is wrong for that client, and the `status` output says which SIDs it grants.
