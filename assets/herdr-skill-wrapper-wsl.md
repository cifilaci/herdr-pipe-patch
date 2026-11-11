---
name: herdr
description: "Drive Herdr: the terminals and coding agents that stay alive. Use to list, read, message, wait on or stop a terminal or an agent (codex, claude) - including the codex agents in the Herdr App on the Windows host, which are reached with win-hc. Two cores here: hc drives this machine, win-hc drives the Windows one. Requires HC_TERMINAL_ID - you must be inside a Herdr terminal."
---

# Herdr, from WSL

Herdr App (the 0.1.x line) runs herdr-core, and herdr-core runs the terminals
and the coding agents in them. On this box there are **two cores**, in two
processes, with separate pipes and separate terminals:

| Command | Core | Whose terminals |
|---|---|---|
| `hc` | the herdr-core in this WSL machine | the terminals here: `t1`, `t2` |
| `win-hc` | the herdr-core on the Windows host | the Herdr App's terminals: `t4`, `t1y`, and the codex agents in them |

`win-hc` is the Windows binary, run from WSL. It takes the same commands as
`hc`: `ls`, `get`, `read`, `send`, `keys`, `wait`, `run`, `kill`, `exec`,
`machine`. `hc --help` lists them; `win-hc --help` lists the same ones.

**The codex agents live on the Windows side.** To reach one:

```sh
win-hc ls                       # find it: an address like t1y, agent "codex"
win-hc get t1y                  # what it is: cwd, title, status, turn
win-hc send t1y "the question"  # paste the text and submit it
win-hc read t1y                 # read the answer
```

`send` pastes the text **and submits it** - the message is delivered. Do not
follow it with `keys <t> enter`: that submits an empty turn. `keys` is for
what `send` cannot do - a trust dialog (`hc keys <t> down enter`), an
interrupt, a control key.

If a send answers "nothing was typed", nothing was lost: that is a status
guard, because the target was busy or silent rather than idle. Send to a
working agent with `--if working`, or type anyway with `--force`.

## Check that you are inside Herdr

```sh
test -n "${HC_TERMINAL_ID:-}"
```

`$HC_TERMINAL_ID` is **your terminal's address** (`t7`), not a pane ID. Herdr
sets it - together with `HC_SCOPE` - in every terminal it spawns. If it is
empty you are not in a Herdr terminal: say so and stop.

There is no `HERDR_ENV` in this Herdr. Nothing sets it, in any terminal, so do
not wait for it and do not read its absence as a fault.

**`HERDR_ENV=1` belongs to the other herdr product**: the 0.9.5 terminal
multiplexer, the `herdr` command. On this machine `herdr` *is* that older
multiplexer, with its own socket, its own agents and its own guide. Its gate
(`HERDR_ENV`), its `herdr agent list` and its `herdr agent prompt <name>`
describe that product - not the Herdr App, and not the agents in it. The
Herdr App's agents are reached with `hc` and `win-hc`, by address.

## Addressing a terminal

A terminal is addressed by its **ID** (`t1y`, `herdr-wsl/t2`). A name works
only when the terminal was started with `hc run --name`. A terminal's *title* -
what the program inside it prints - and its tab or space label
(`PricingDevCodex`) are **not** addresses: `hc get PricingDevCodex` says not
found. Find the addresses with `hc ls` and `win-hc ls`.

## Replying to another machine

A message that arrives from the other machine arrives wrapped:

```
<hc from="2fc213724fef6cd4719fae00eeda8b26/t21">the question</hc>
```

The address in `from` names the sender: its machine and its terminal. Answer
it the same way the question was asked - `send` - through the core that owns
it: `win-hc send t21 ...` when the sender is on the Windows host,
`hc send herdr-wsl/t2 ...` when it is on this one.

The answer arrives on its own, as the next thing you are given. There is
nothing to poll for: while the target is working, `hc read` returns only the
screen.

## A machine link reaches only its own terminals

A peer link (`herdr-wsl/t2`) reaches the terminals **that machine started
itself**. The App's own terminals are not the peers' terminals:

```
hc get herdr-wsl/t1y
  -> denied: herdr-wsl may only reach the terminals here that started its own
```

Adding the Windows host over ssh does not change that: it would let the WSL
side start terminals there, not reach the App's.

So a request for an App terminal goes through the core that owns it - the
Windows one, with `win-hc`. `win-hc` runs the Windows binary from WSL, so the
request is local to that core and the rule does not apply.
