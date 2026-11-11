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
#   sh install-skill-wsl.sh --only wrapper # only the win-hc wrapper
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
        --only)
            shift
            if [ $# -eq 0 ]; then
                echo "--only needs a value: all, guide or wrapper" >&2
                exit 3
            fi
            only=$1
            ;;
        -h|--help)
            sed -n '2,20p' "$0"
            exit 0
            ;;
        *) echo "unknown option: $1" >&2; exit 3 ;;
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
    # The guide is built from the manual 'hc' prints, so a machine without hc
    # cannot get one. That is not a reason to install nothing: the win-hc
    # wrapper is what reaches the Windows core, and that is often the whole
    # point of being on WSL at all.
    # Every failure here returns instead of exiting: the win-hc wrapper is
    # installed after this, and it is what reaches the Windows core - the one
    # thing a WSL machine is here for.
    if ! command -v hc >/dev/null 2>&1; then
        say "    x no 'hc' on PATH: the guide is built from the manual it prints, so it was not written"
        say "    install herdr-core on this machine, or run this where 'hc' is on PATH"
        return 1
    fi
    if [ ! -f "$wrapper" ]; then
        say "    x no guide head at $wrapper"
        return 1
    fi
    if ! manual=$(hc --skill 2>/dev/null); then
        say "    x 'hc --skill' did not answer."
        return 1
    fi
    if [ -z "$manual" ]; then
        say "    x 'hc --skill' printed nothing."
        return 1
    fi

    guide="$(cat "$wrapper")
---
$(printf '%s' "$manual" | tr -d '\r')
"
    wrote=0
    failed=0
    for folder in "$home/.claude/skills/herdr" "$home/.codex/skills/herdr"; do
        if [ "$dry_run" = 1 ]; then
            say "    dry run: the guide was not written to $folder"
            continue
        fi
        file="$folder/SKILL.md"
        # Every step is checked here: a function called from an "if" does not
        # stop on an error, so "set -e" cannot be relied on inside it.
        if ! mkdir -p "$folder"; then
            say "    x could not create $folder"
            failed=1
            continue
        fi
        if [ -f "$file" ]; then
            if ! grep -q 'win-hc' "$file"; then
                say "    the old guide does not mention win-hc: it was the wrong head for this side"
            fi
            if ! cp "$file" "$file.bak-$(date +%Y%m%d-%H%M%S)"; then
                say "    x could not keep the old guide as $file.bak-..."
                failed=1
                continue
            fi
            say "    kept the old guide as $file.bak-$(date +%Y%m%d-%H%M%S)"
        fi
        # The guide goes through a temporary file: a write that fails half-way
        # must not leave a truncated guide where the old one was.
        tmp="$file.tmp.$$"
        if ! printf '%s\n' "$guide" > "$tmp"; then
            say "    x could not write the guide into $folder"
            rm -f "$tmp"
            failed=1
            continue
        fi
        if ! grep -q 'win-hc' "$tmp"; then
            say "    x the guide for $folder does not mention win-hc: the head is wrong"
            rm -f "$tmp"
            failed=1
            continue
        fi
        if ! mv "$tmp" "$file"; then
            say "    x could not put the guide in place at $file"
            rm -f "$tmp"
            failed=1
            continue
        fi
        say "    wrote the guide into $file (it names win-hc: the head for this side)"
        wrote=1
    done
    if [ "$failed" = 1 ]; then
        return 1
    fi
    if [ "$dry_run" = 0 ] && [ "$wrote" = 0 ]; then
        say "    x no guide was written"
        return 1
    fi
    return 0
}

install_win_hc() {
    if [ ! -f "$win_hc_source" ]; then
        say "    x no wrapper at $win_hc_source: the package is incomplete"
        return 1
    fi
    target="$home/.local/bin/win-hc"
    if [ "$dry_run" = 1 ]; then
        say "    dry run: the wrapper was not written to $target"
        return 0
    fi
    # Checked one by one: a function called from an "if" does not stop on an
    # error, so "set -e" cannot be relied on here either.
    if ! mkdir -p "$(dirname "$target")"; then
        say "    x could not create $(dirname "$target")"
        return 1
    fi
    if ! cp "$win_hc_source" "$target"; then
        say "    x could not write the wrapper into $target"
        return 1
    fi
    if ! chmod +x "$target"; then
        say "    x could not make $target executable"
        return 1
    fi
    say "    wrote the wrapper into $target"
    case ":$PATH:" in
        *":$home/.local/bin:"*) ;;
        *) say "    note: $home/.local/bin is not on PATH"
           say "    add it to your shell: export PATH=\"$home/.local/bin:\$PATH\"" ;;
    esac
    return 0
}

case "$only" in
    all|guide|wrapper) ;;
    *) echo "unknown --only value: $only (all, guide or wrapper)" >&2; exit 3 ;;
esac

# The exit codes, one meaning each:
#   0  everything that was asked for is done
#   1  one part is done and the other is not
#   2  nothing was installed
#   3  the command line was wrong
say "installing into: $home/.claude/skills, $home/.codex/skills"
guide_done=0
guide_failed=0
wrapper_done=0
wrapper_failed=0
if [ "$only" = all ] || [ "$only" = guide ]; then
    if install_wrapper; then guide_done=1; else guide_failed=1; fi
fi
if [ "$only" = all ] || [ "$only" = wrapper ]; then
    if install_win_hc; then wrapper_done=1; else wrapper_failed=1; fi
fi
if [ "$dry_run" = 1 ]; then
    say "dry run: nothing was changed"
    exit 0
fi
if [ "$guide_failed" = 1 ] && [ "$wrapper_failed" = 1 ]; then
    say "done: nothing was installed"
    exit 2
fi
if [ "$guide_failed" = 1 ]; then
    if [ "$wrapper_done" = 1 ]; then
        say "done: the win-hc wrapper is installed, but the guide was not written"
    else
        say "done: nothing was installed - the guide could not be written"
        exit 2
    fi
    exit 1
fi
if [ "$wrapper_failed" = 1 ]; then
    if [ "$guide_done" = 1 ]; then
        say "done: the guide is installed, but the win-hc wrapper was not written"
    else
        say "done: nothing was installed - the wrapper could not be written"
        exit 2
    fi
    exit 1
fi
say "done"
