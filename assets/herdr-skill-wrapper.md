---
name: herdr
description: "Control Herdr App, the desktop terminal and coding-agent manager on this machine. Start, read, message, wait on and clean up terminals and coding agents with hc; change the spaces, tabs and panes the person sees with herdr-app. Use only when the user explicitly mentions Herdr or asks to inspect or control Herdr panes, tabs, workspaces, terminals, commands or another agent. Do not use merely because a task could benefit from a background terminal, delegation or parallel work. Requires HC_TERMINAL_ID - you must be inside a Herdr terminal."
---

# Herdr

Herdr shows spaces, tabs and panes; herdr-core (`hc`) runs the terminals and
agents in them and keeps them alive when the window closes. Two CLIs, two
jobs:

- `herdr-app` — the **window**: spaces, tabs, panes, and what the person sees.
- `hc` — **terminals and agents**: start, read, message, wait, clean up.

Both are on `PATH`. **There is no `herdr` command in this Herdr** — the two
manuals below are the ones the installed binaries print (`herdr-app --skill`
and `hc --skill`), so they are the authority on syntax. Use
`hc <command> --help` for exact arguments.

## Check that you are inside Herdr

```sh
test -n "${HC_TERMINAL_ID:-}"
```

`$HC_TERMINAL_ID` is **your terminal's address** (`t7`), not a pane ID. Herdr
sets it — together with `HC_TERMINAL_SOCKET` and `HC_SCOPE` — in every
terminal it spawns. If it is empty you are not in a Herdr terminal: say so
and stop. Do not inspect or control the person's Herdr session from outside
Herdr.

There is no `HERDR_ENV` in this Herdr. Nothing sets it, in any terminal, so
do not wait for it and do not read its absence as a fault. `HERDR_ENV` belongs
to the separate `herdr` 0.9.5 terminal application, which is a different
product with its own CLI, socket and guide — that guide is kept beside this
one as `SKILL.md.herdr-0.9.5` for sessions running inside a 0.9.5 pane.

**Codex must run with `--no-daemon`** (including templates), or its commands
execute outside hc.

## Addressing a terminal

`hc` addresses a terminal by ID (`t7`), by name (`review`), or as
`machine/t7` (`herdr-wsl/t3`).

A name is set when a terminal is started with `hc run --name`. A terminal's
*title* — what the program inside it prints — is **not** an address: a
terminal whose title is `bob-rae` still answers to its ID.

---

