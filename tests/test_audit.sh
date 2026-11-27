#!/usr/bin/env bash
# The --audit hygiene rows (docker_reclaim, docker_stopped, mem_pressure, journal, caches) and the
# laptop rows (battery_cap, wifi_powersave) against stubbed docker, journalctl and iw, a fixture
# sysroot (/proc/meminfo, /sys, the sbin directories) and a throwaway HOME. The audit must stay
# valid JSON and must never remove, prune or stop anything.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/servermaxxing.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
FAILS=0
command -v python3 >/dev/null || { echo "python3 is needed to check the JSON"; exit 1; }

BASE="$T/base"
mkdir -p "$BASE" "$T/stub" "$T/fx" "$T/sys/proc"
for tool in bash sh env tr uname id cat grep cut awk head tail sed sort wc du date timeout mktemp rm hostname dirname; do
    real="$(command -v "$tool" || true)"
    [ -z "$real" ] || ln -s "$real" "$BASE/$tool"
done

cat > "$T/stub/docker" <<STUB
#!/bin/sh
echo "docker \$*" >> "$T/calls"
[ -e "$T/fx/docker_down" ] && exit 1
case "\$1" in
  info) case "\$*" in *DockerRootDir*) echo "$T" ;; *DriverStatus*) cat "$T/fx/driver" 2>/dev/null ;; *) echo ok ;; esac ;;
  --version) echo "Docker version 99.0.0, build stub" ;;
  system) case "\$*" in
      *-v*--format*) [ -e "$T/fx/dfv_lines" ] && cat "$T/fx/dfv_lines" || exit 1 ;;
      *-v*) [ -e "$T/fx/dfv_table" ] && cat "$T/fx/dfv_table" || exit 1 ;;
      *) cat "$T/fx/df" ;;
    esac ;;
  ps) cat "$T/fx/exited" ;;
  inspect) cat "$T/fx/inspect" ;;
  *) exit 1 ;;
esac
STUB
cat > "$T/stub/journalctl" <<STUB
#!/bin/sh
echo "journalctl \$*" >> "$T/calls"
echo "Archived and active journals take up \$(cat "$T/fx/journal") in the file system."
STUB
cat > "$T/stub/df" <<STUB
#!/bin/sh
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/stub 1000000000 %s %s 50%% /\n' "\$(cat "$T/fx/free_kb")" "\$(cat "$T/fx/free_kb")"
STUB
echo 500000000 > "$T/fx/free_kb"  # 500 GB free unless a case says otherwise
chmod +x "$T/stub/docker" "$T/stub/journalctl" "$T/stub/df"

ago() { date -u -d "$1 days ago" +%Y-%m-%dT%H:%M:%S.123456789Z; }
meminfo() {  # meminfo <total kB> <available kB> <swap total kB> <swap free kB>
    printf 'MemTotal: %s kB\nMemFree: 1 kB\nMemAvailable: %s kB\nSwapTotal: %s kB\nSwapFree: %s kB\n' "$@" > "$T/sys/proc/meminfo"
}
scene() {  # scene <reclaim images> <volumes> <build cache> <journal size>
    printf 'Images\t%s (40%%)\nContainers\t0B (0%%)\nLocal Volumes\t%s (10%%)\nBuild Cache\t%s\n' "$1" "$2" "$3" > "$T/fx/df"
    echo "$4" > "$T/fx/journal"
    : > "$T/fx/exited"; : > "$T/fx/inspect"
}
exited() {  # exited <name> <days since it stopped> [compose project]
    echo "id-$1" >> "$T/fx/exited"
    echo "/$1|$(ago "$2")|${3:-}" >> "$T/fx/inspect"
}

audit() {  # audit [VAR=value...]: runs the audit as JSON into $T/out
    : > "$T/calls"
    env -i HOME="$T/my home" PATH="$T/stub:$BASE" SERVERMAXXING_SYSROOT="$T/sys" "$@" \
        "$BASE/bash" "$SCRIPT" --audit --json > "$T/out" 2> "$T/err" || { echo "audit exited non-zero"; cat "$T/err"; return 1; }
}
row() {  # row <check>: "status|detail"
    python3 -c 'import json,sys
rows = json.load(open(sys.argv[1]))
hit = [r for r in rows if r["check"] == sys.argv[2]]
print(hit[0]["status"] + "|" + hit[0]["detail"] if hit else "absent|")' "$T/out" "$1"
}
expect() {  # expect <name> <check> <status> [text in detail]
    local got; got="$(row "$2")"
    if [ "${got%%|*}" = "$3" ] && [[ "${got#*|}" == *"${4:-}"* ]]; then echo "ok   $1"
    else echo "FAIL $1: $2 is '$got' (want $3 with '${4:-}')"; FAILS=$((FAILS + 1)); fi
}
untouched() {  # nothing was removed, pruned, stopped or vacuumed
    if grep -Eq ' (rm|prune|stop|kill)( |$)|vacuum' "$T/calls"; then
        echo "FAIL $1: the audit changed something:"; cat "$T/calls"; FAILS=$((FAILS + 1))
    else echo "ok   $1"; fi
}

mkdir -p "$T/my home/.npm" "$T/my home/.cache/pip" 
head -c 3000000 /dev/zero > "$T/my home/.cache/pip/blob"

# A tidy machine: everything ok.
scene "1.2GB" "100MB" "300MB" "200.0M"
exited fresh 1
exited stack 30 myapp
meminfo 8000000 6000000 2000000 2000000
audit
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$T/out" && echo "ok   --json is valid" || { echo "FAIL --json"; FAILS=$((FAILS + 1)); }
expect "small reclaimable space is ok" docker_reclaim ok "1.6 GB"
expect "recent and compose containers are not listed" docker_stopped ok
expect "plenty of memory is ok" mem_pressure ok
expect "a small journal is ok" journal ok "0.2 GB"
expect "small caches are ok" caches ok
untouched "a tidy audit changes nothing"

# A neglected machine: warnings, each with its fix.
scene "4.5GB" "1GB" "500MB" "1.5G"
exited old-job 10
exited fresh 1
exited stack 30 myapp
meminfo 8000000 1000000 2000000 2000000
audit SMX_CACHES_WARN_GB=0.002
expect "6 GB reclaimable warns" docker_reclaim warn "docker image prune"
expect "an old exited container without compose warns" docker_stopped warn "docker rm old-job"
expect "only the old one is named" docker_stopped warn "1 exited"
expect "12% available memory warns" mem_pressure warn "12%"
expect "a 1.5 GB journal warns" journal warn "journalctl --vacuum-size"
expect "caches over the threshold warn" caches warn ".cache"
untouched "a neglected audit changes nothing"

# Swap more than half used warns even with memory free.
meminfo 8000000 6000000 2000000 600000
audit
expect "swap 70% used warns" mem_pressure warn "swap 70%"
expect "the swap threshold comes from the environment" mem_pressure warn ""
audit SMX_SWAP_WARN_PCT=80
expect "SMX_SWAP_WARN_PCT raises the swap threshold" mem_pressure ok

# Failures.
scene "21GB" "0B" "0B" "1.5G"
meminfo 8000000 300000 0 0
audit
expect "over 20 GB reclaimable fails" docker_reclaim fail "21.0 GB"
expect "under 5% available memory fails" mem_pressure fail "3%"
scene "6GB" "0B" "0B" "100M"
echo 20000000 > "$T/fx/free_kb"  # 20 GB free: 6 GB is 29% of it
audit
expect "reclaimable space over 25% of free disk fails" docker_reclaim fail "29% of free disk"
audit SMX_DOCKER_RECLAIM_FAIL_FREE_PCT=50
expect "SMX_DOCKER_RECLAIM_FAIL_FREE_PCT moves the share" docker_reclaim warn
echo 500000000 > "$T/fx/free_kb"
audit SMX_DOCKER_RECLAIM_WARN_GB=10
expect "SMX_DOCKER_RECLAIM_WARN_GB raises the warning" docker_reclaim ok
audit SMX_JOURNAL_WARN_GB=0.05
expect "SMX_JOURNAL_WARN_GB lowers the journal threshold" journal warn
exited old-job 10
audit SMX_DOCKER_STOPPED_DAYS=30
expect "SMX_DOCKER_STOPPED_DAYS widens the age" docker_stopped ok

# The containerd image store: df's image figure counts layers other images still use, so the
# audit sums the unique size of images no container uses (here 0.8 GB, not 4.9 GB).
scene "4.889GB (85%)" "1GB" "600MB" "100M"
echo "io.containerd.snapshotter.v1" > "$T/fx/driver"
printf '1 173.4MB\n0 173.3MB\n0 115.9MB\n0 351.7MB\n0 178.4MB\n1 1.697GB\n0 12.18MB\n' > "$T/fx/dfv_lines"
audit
expect "containerd store: images count by unused unique size" docker_reclaim ok "2.4 GB"
expect "containerd store: the detail says how images were counted" docker_reclaim ok "unique size"
untouched "the containerd audit changes nothing"
rm "$T/fx/dfv_lines"
cat > "$T/fx/dfv_table" <<'TABLE'
Images space usage:

REPOSITORY   TAG       IMAGE ID       CREATED        SIZE      SHARED SIZE   UNIQUE SIZE   CONTAINERS
app          v2        fd49f56bfcfb   17 hours ago   306MB     132.9MB       173.4MB       1
app          v1        e64b3e9814f3   22 hours ago   306MB     132.9MB       173.3MB       0
<none>       <none>    9fdeeda2801c   2 weeks ago    352MB     0B            351.7MB       0

Containers space usage:

CONTAINER ID   IMAGE     COMMAND   LOCAL VOLUMES   SIZE      CREATED       STATUS    NAMES
abc            app:v2    "run"     0               0B        2 days ago    Up        app
TABLE
audit
expect "containerd store without -v --format: the table is read" docker_reclaim ok "2.1 GB"
rm "$T/fx/dfv_table"
audit
expect "containerd store with no per-image data: an upper bound" docker_reclaim warn "upper bound"
rm "$T/fx/driver"
audit
expect "the classic store keeps df's image figure" docker_reclaim warn "6.5 GB"

# Laptop rows read the fixture /sys; no systemd-detect-virt on PATH means bare metal.
PS_DIR="$T/sys/sys/class/power_supply/BAT0"
mkdir -p "$PS_DIR"
audit
expect "a battery without a threshold attribute is n/a, not a warning" battery_cap n/a "not supported"
echo 80 > "$PS_DIR/charge_control_end_threshold"
audit
expect "an 80% cap is ok" battery_cap ok "80%"
echo 100 > "$PS_DIR/charge_control_end_threshold"
audit
expect "a 100% cap on AC still fails" battery_cap fail "100%"

# iw lives in sbin, which a service's PATH often leaves out: the audit must still find it.
mkdir -p "$T/sys/sys/class/net/wlan0" "$T/sys/usr/sbin"
echo up > "$T/sys/sys/class/net/wlan0/operstate"
audit
expect "no iw anywhere says to install it" wifi_powersave warn "install iw"
printf '#!/bin/sh\necho "iw $*" >> "%s/calls"\necho "Power save: off"\n' "$T" > "$T/sys/usr/sbin/iw"
chmod +x "$T/sys/usr/sbin/iw"
audit
expect "iw only in sbin, sbin not on PATH, is still found" wifi_powersave ok "wlan0: off"
printf '#!/bin/sh\nexit 1\n' > "$T/sys/usr/sbin/iw"
audit
expect "iw present but failing does not say install iw" wifi_powersave warn "iw could not read"
row wifi_powersave | grep -q "install iw" && { echo "FAIL a failing iw still says install iw"; FAILS=$((FAILS + 1)); } || echo "ok   a failing iw is not reported as missing"

# No docker daemon, no journalctl, no meminfo: n/a, and still valid JSON.
touch "$T/fx/docker_down"
rm "$T/stub/journalctl" "$T/sys/proc/meminfo"
audit
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$T/out" && echo "ok   --json is valid without docker" || { echo "FAIL --json without docker"; FAILS=$((FAILS + 1)); }
expect "no docker daemon: reclaim is n/a" docker_reclaim n/a
expect "no docker daemon: stopped is n/a" docker_stopped n/a
expect "no journalctl is n/a" journal n/a
expect "no meminfo is n/a" mem_pressure n/a

[ "$FAILS" = 0 ] && echo "all passed" || { echo "$FAILS failed"; exit 1; }
