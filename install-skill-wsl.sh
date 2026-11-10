#!/bin/sh
# Installs the Herdr guide for the WSL side, for codex and Claude Code.
#
# The Windows side has its own installer (install-skill.ps1). This one is for
# a WSL machine that talks to a Windows Herdr App: it writes the guide an
# agent here reads, and the `win-hc` wrapper that lets this machine reach the
# Windows core.
#
# The guide is built from the manuals the *installed* binaries print, so it
# cannot go stale in the repository: `hc --skill` for the core here, and the
# head in assets/herdr-skill-wrapper-wsl.md in front of it. The head is a
# local addition (the frontmatter, the HC_TERMINAL_ID gate, the note about
# HERDR_ENV, and the two cores).
#
# Usage (run it with sh: a zip from Windows carries no exec bit):
#   sh install-skill-wsl.sh              # install both
#   sh install-skill-wsl.sh --dry-run    # print what would happen
#   sh install-skill-wsl.sh --only guide # only the guide, not the wrapper
#
# Requires: a POSIX shell, `hc` on PATH (the herdr-core of this machine) and
# a Windows herdr-core for the wrapper.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
wrapper="$root/assets/herdr-skill-wrapper-wsl.md"
win_hc_source="$root/assets/win-hc"

dry_run=0
only=all
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) dry_run=1 ;;
        --only) shift; only=${1:-all} ;;
        -h|--help)
            sed -n '2,20p' "$0"
            exit 0
            ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

home=${HOME:-}
if [ -z "$home" ]; then
    echo "no HOME" >&2
    exit 1
fi

say() { printf '%s\n' "$*"; }
fail() { printf 'x %s\n' "$*" >&2; exit 1; }

install_wrapper() {
    command -v hc >/dev/null 2>&1 || fail "'hc' is not on PATH: the guide would have no manual in it."
    [ -f "$wrapper" ] || fail "no guide head at $wrapper"

    manual=$(hc --skill 2>/dev/null) || fail "'hc --skill' did not answer."
    [ -n "$manual" ] || fail "'hc --skill' printed nothing."

    guide="$(cat "$wrapper")
---
$(printf '%s' "$manual" | tr -d '\r')
"
    for folder in "$home/.claude/skills/herdr" "$home/.codex/skills/herdr"; do
        if [ "$dry_run" = 1 ]; then
            say "    dry run: the guide was not written to $folder"
            continue
        fi
        mkdir -p "$folder"
        file="$folder/SKILL.md"
        if [ -f "$file" ]; then
            cp "$file" "$file.bak-$(date +%Y%m%d-%H%M%S)"
            say "    kept the old guide as $file.bak-$(date +%Y%m%d-%H%M%S)"
        fi
        printf '%s\n' "$guide" > "$file"
        say "    wrote the guide into $file"
    done
}

install_win_hc() {
    [ -f "$win_hc_source" ] || fail "no wrapper at $win_hc_source"
    target="$home/.local/bin/win-hc"
    if [ "$dry_run" = 1 ]; then
        say "    dry run: the wrapper was not written to $target"
        return
    fi
    mkdir -p "$(dirname "$target")"
    cp "$win_hc_source" "$target"
    chmod +x "$target"
    say "    wrote the wrapper into $target"
    case ":$PATH:" in
        *":$home/.local/bin:"*) ;;
        *) say "    note: $home/.local/bin is not on PATH" ;;
    esac
}

say "installing into: $home/.claude/skills, $home/.codex/skills"
if [ "$only" = all ] || [ "$only" = guide ]; then
    install_wrapper
fi
if [ "$only" = all ] || [ "$only" = wrapper ]; then
    install_win_hc
fi
say "done"
