#!/usr/bin/env bash
# The guards that run before any change. Every system command is a stub that records its use.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/servermaxxing.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
FAILS=0

stubs() {  # stubs <dir> <name>...
    local dir="$1"; shift
    mkdir -p "$dir"
    for name in "$@"; do
        printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\nexit 0\n' "$name" "$T" > "$dir/$name"
        chmod +x "$dir/$name"
    done
}
BASE="$T/base"
mkdir -p "$BASE"
for tool in bash sh env tr uname id cat grep cut awk head mktemp rm getent logname dirname; do
    real="$(command -v "$tool" || true)"
    [ -z "$real" ] || ln -s "$real" "$BASE/$tool"
done
stubs "$T/apt" apt-get systemctl curl sudo
printf 'ID=ubuntu\n' > "$T/ubuntu"
printf 'ID=umbrelos\nNAME="umbrelOS"\n' > "$T/umbrel"

expect() {  # expect <name> <exit> <text> <PATH> <os-release> <args...>
    local name="$1" want="$2" text="$3" path="$4" os="$5" got=0 out; shift 5
    : > "$T/calls"
    out="$(HOME="$T/home" PATH="$path" SERVERMAXXING_SYSROOT="${SERVERMAXXING_SYSROOT:-$T/empty}" SERVERMAXXING_OS_RELEASE="$os" "$BASE/bash" "$SCRIPT" "$@" 2>&1)" || got=$?
    if [ "$got" != "$want" ] || [[ "$out" != *"$text"* ]] || [ -s "$T/calls" ]; then
        echo "FAIL $name: exit $got (want $want)"; echo "$out" | tail -3; cat "$T/calls"; FAILS=$((FAILS + 1))
    else
        echo "ok   $name"
    fi
}
mkdir -p "$T/home"
expect "a mistyped flag changes nothing" 2 "unknown option" "$T/apt:$BASE" "$T/ubuntu" --no-wifi-watchdgo
expect "an appliance is refused" 1 "appliance OS" "$T/apt:$BASE" "$T/umbrel"
mkdir -p "$T/sysroot/opt/umbreld"
SERVERMAXXING_SYSROOT="$T/sysroot" expect "an appliance reporting plain Debian is refused" 1 "appliance OS" "$T/apt:$BASE" "$T/ubuntu"
expect "no apt is refused" 1 "needs apt" "$BASE" "$T/ubuntu"
expect "dry run changes nothing" 0 "Nothing was changed" "$T/apt:$BASE" "$T/ubuntu" --dry-run
if [ "$(id -u)" -ne 0 ]; then
    expect "a normal user is refused" 1 "needs root" "$T/apt:$BASE" "$T/ubuntu"
fi
expect "user tools dry run" 0 "would install uv" "$T/apt:$BASE" "$T/ubuntu" --user-tools --dry-run
[ "$FAILS" = 0 ] && echo "all passed" || { echo "$FAILS failed"; exit 1; }
