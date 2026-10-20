#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
#
# nvbench-suite.sh -- the benchmark matrix of docs/source/benchmarks.md,
# run on the board (as root) with nvrec / nvplay / nvverify, one JSON line
# per run appended to a results file.
#
# Method = fpga-drive-recorder's benchmarks (recorder.fpgadrive.com), so the
# two designs compare line by line:
#   sustained  32 GB per step, 250 MB/s steps, until the first failing step;
#              fresh trimmed volume + 60 s idle before every step
#   glance     4000 MiB rate sweep (250..3000) + confirmations of the top step
#              (the "highest clean" cells of the recorder's at-a-glance table)
#   burst      10 GB / 40 GB recordings at given rates (or a sweep)
#   playback   nvplay sweep on a 10 GB recording made at 1000 MB/s, until
#              the first rate with underflows, + confirmations
#   Sweeps (sustained, 10 GB burst, playback) run 250 MB/s steps up to the
#   source maximum and end with one step AT the maximum (3200 MB/s) when it
#   is not on the grid: ..., 2750, 3000, 3200, as the recorder's sweeps. The
#   4000 MiB glance sweep ends at 3000 (the recorder's never runs 3200).
#   gaps       only those final source-max steps (+ the confirmations of
#              playback) for layouts swept before the sweeps ended at the max
#   cpu        10 GB record + play at 1000 MB/s, /proc/stat deltas + time -p
#   chunk      chunk-size sweep (128K .. the drives' MDTS) at a fixed rate
#   inflight   SSD_MAX_INFLIGHT sweep (1 .. 63) at a fixed rate
#   longrun    post-SLC-cache sustained rate: --size (200G) at one or more
#              --rate(s); fresh trimmed volume + --idle (600 s) before each
#   verify     nvverify of a recording
#   all        the whole matrix for the fixture (SSD1, SSD2, RAID0)
#
# Resumable: every run has an id (test, layout, drive serials, parameters);
# a run whose id is already in the results file is not repeated (its result
# is reused for the sweep logic), so a session can stop at the evaluation
# license limit and continue after a power-cycle with the same command.
#
# Ring: nvrec/nvplay's default (256 MB of slots: 1024 x 256 KB, 512 x 512 KB,
# 256 x 1 MB = the recorder's 32 x 8 MB) unless --buffers is given; chunk and
# inflight keep --ring-mb constant. Every run stores the ring the app set up
# (ring_slots, ring_bytes from its RESULT line).
# --budget-min stops cleanly before a run that would not finish in time.
#
# Exit codes: 0 = everything asked for is in the results file, 3 = stopped
# for the time budget (power-cycle and run again), 5 = the Host Accelerator
# stopped responding (power-cycle and run again), 1 = error, 2 = usage.

set -u

VERSION=1
SYS_NVREC=${NVBENCH_SYS_NVREC:-/sys/class/misc/nvrec}
SYS_BLOCK=${NVBENCH_SYS_BLOCK:-/sys/block}
SYS_PCI=${NVBENCH_SYS_PCI:-/sys/bus/pci/devices}
PROC_STAT=${NVBENCH_PROC_STAT:-/proc/stat}
DEV_DIR=${NVBENCH_DEV_DIR:-/dev}

STATE_DIR=/var/lib/nvbench
RESULTS=""
DIR=/mnt/rec
BUDGET_MIN=150
T0_AGO=""
IDLE=60
IDLE_SET=0
VERIFY_MBPS=800
DRY=0
LAYOUTS="single1 single2 raid0"
LAYOUT=""
FROM=250
STEP=250
TO=""
# the 4000 MiB glance sweep's top: the recorder's at-a-glance sweep runs
# 250..3000 and never 3200 (its loop stops at 3250 > 3200), so ours ends at
# 3000 too unless --to is given (apples-to-apples "highest clean" cells)
GLANCE_TO=3000
SIZE=""
RATES=""
CONFIRM=""
RATE=""
CHUNKS=""
QDS="1 2 4 8 16 32 63"
RUNS=2
RING_MB=256
BUFFERS=""
NOTE=""

usage() {
    cat <<EOF
Usage: nvbench-suite.sh [options] <command> [command options]

Commands:
  info                 print the fixture (drives, links, versions) as JSON
  status               list the results file, per test and layout
  sustained            32 GB sweep: --from --step --to, until the first failure
  glance               4000 MiB sweep (to $GLANCE_TO unless --to) + --confirm runs
                       of the top step
  burst                --size (10G) at --rates a,b,.. or a --from/--step sweep
  playback             nvplay sweep of a 10 GB recording + --confirm runs
                       (sustained, burst and playback sweeps end with a step at
                       the source maximum: .., 2750, 3000, 3200)
  cpu                  record + play at --rate (1000) x --runs (2), CPU figures
  chunk                chunk sizes 128K .. the drives' MDTS (max 4M) at --rate (auto)
  inflight             --qds "$QDS" at --rate (auto)
  longrun              --size (200G) at --rate a,b,.. (MB/s), each on a fresh
                       trimmed volume after --idle (default 600 s here)
  verify [file]        nvverify a recording (default: the last one)
  all                  the whole matrix for --layouts "$LAYOUTS"
  gaps                 per layout of --layouts, only the source-max steps that
                       sweeps ending at 3000 missed: sustained 32 GB, burst
                       10 GB (1 run each), playback (1 + 2 confirmations); runs
                       them only where the sweep's last grid step passed

Options:
  --layout <l>         single1 (/dev/nvrec0n1), single2 (/dev/nvrec1n1) or
                       raid0 (md0 of both); every command but 'all' needs it
  --layouts "<l ..>"   layouts for 'all' (default "$LAYOUTS")
  --results <file>     JSONL results file (default $STATE_DIR/results.jsonl)
  --dir <dir>          mount point of the recording volume (default $DIR)
  --budget-min <min>   stop before a run that would end later than this many
                       minutes after the bitstream load (default $BUDGET_MIN;
                       the evaluation core stops after ~183 min)
  --t0-ago <sec>       the bitstream was loaded this many seconds ago (the host
                       knows when it powered the board on); default: the
                       kernel's boot time minus 30 s
  --idle <sec>         idle time after preparing a fresh volume (default $IDLE)
  --from/--step/--to   sweep rates in MB/s (10^6 B/s); --to defaults to (and is
                       capped at) the generator maximum (src_clk x 16 = 3200);
                       any requested rate above it runs at the maximum and is
                       stored with rate_req_mbps = the maximum, rate_capped true;
                       a sweep whose grid misses --to ends with a step at --to
  --size <bytes>       recording size (nvrec suffixes); per-command default
  --rates <a,b,..>     sustained, glance, burst, playback: run exactly these
                       rates (MB/s), each once, no stop at a failure, each capped
                       at the source maximum; + --confirm <n> repeats of every
                       listed rate when --confirm is given
  --confirm <n>        extra runs at the top clean step (glance, playback: 2;
                       sustained, burst: 0); with --rates: at every rate (0)
  --rate <MB/s|auto>   cpu / chunk / inflight rate; auto = the layout's
                       highest clean 10 GB burst rate in the results (cap 3000);
                       longrun: one or more rates, a,b,.. (MB suffix allowed)
  --chunks "<..>"      chunk sizes for 'chunk' (default: 128K, 256K, .. up to the MDTS)
  --qds "<..>"         SSD_MAX_INFLIGHT values for 'inflight' (1..63)
  --runs <n>           cpu: runs per direction (default $RUNS)
  --ring-mb <MB>       chunk/inflight: ring size kept constant (default $RING_MB;
                       slots = MB / chunk, at most 1024)
  --buffers <n>        ring slots for every other run (default: the apps'
                       default, 256 MB of slots)
  --verify-mbps <n>    nvverify read rate assumed by the budget (default $VERIFY_MBPS)
  --note <text>        free text stored with every run
  --dry-run            print the plan (run / skip) without touching anything
  -h, --help           this help
EOF
}

die() { echo "nvbench-suite: $*" >&2; exit 1; }
say() { echo "[$(date +%H:%M:%S)] $*"; }

CMD=""
CMD_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --layout) LAYOUT="${2:?}"; shift 2 ;;
        --layouts) LAYOUTS="${2:?}"; shift 2 ;;
        --results) RESULTS="${2:?}"; shift 2 ;;
        --dir) DIR="${2:?}"; shift 2 ;;
        --budget-min) BUDGET_MIN="${2:?}"; shift 2 ;;
        --t0-ago) T0_AGO="${2:?}"; shift 2 ;;
        --idle) IDLE="${2:?}"; IDLE_SET=1; shift 2 ;;
        --from) FROM="${2:?}"; shift 2 ;;
        --step) STEP="${2:?}"; shift 2 ;;
        --to) TO="${2:?}"; shift 2 ;;
        --size) SIZE="${2:?}"; shift 2 ;;
        --rates) RATES="${2:?}"; shift 2 ;;
        --confirm) CONFIRM="${2:?}"; shift 2 ;;
        --rate) RATE="${2:?}"; shift 2 ;;
        --chunks) CHUNKS="${2:?}"; shift 2 ;;
        --qds) QDS="${2:?}"; shift 2 ;;
        --runs) RUNS="${2:?}"; shift 2 ;;
        --ring-mb) RING_MB="${2:?}"; shift 2 ;;
        --buffers) BUFFERS="${2:?}"; shift 2
            case "$BUFFERS" in ''|*[!0-9]*) usage >&2; exit 2 ;; esac
            [ "$BUFFERS" -ge 2 ] && [ "$BUFFERS" -le 1024 ] || { echo "nvbench-suite: --buffers must be 2..1024" >&2; exit 2; } ;;
        --verify-mbps) VERIFY_MBPS="${2:?}"; shift 2 ;;
        --note) NOTE="${2:?}"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) usage >&2; exit 2 ;;
        *) if [ -z "$CMD" ]; then CMD=$1; else CMD_ARGS+=("$1"); fi; shift ;;
    esac
done
[ -n "$CMD" ] || { usage >&2; exit 2; }
[ -n "$RESULTS" ] || RESULTS=$STATE_DIR/results.jsonl
LOGDIR=$(dirname "$RESULTS")/logs
EVENTS=$(dirname "$RESULTS")/events.log
VOLSTATE=$(dirname "$RESULTS")/volume.state
OUT=$DIR/nvbench.dat
PLAYSRC=$DIR/playsrc.dat

# ---------------------------------------------------------------- helpers
# size string (nvrec suffixes: K/M/G/T = 1024^n, KB/MB/GB/TB = 1000^n) -> bytes
to_bytes() {
    local v=${1^^} m=1
    case "$v" in
        *KB) m=1000; v=${v%KB} ;; *MB) m=1000000; v=${v%MB} ;;
        *GB) m=1000000000; v=${v%GB} ;; *TB) m=1000000000000; v=${v%TB} ;;
        *K) m=1024; v=${v%K} ;; *M) m=1048576; v=${v%M} ;;
        *G) m=1073741824; v=${v%G} ;; *T) m=1099511627776; v=${v%T} ;;
    esac
    echo $(( v * m ))
}
# bytes -> 128K / 1M style
chunk_name() { local b=$1; if [ $((b % 1048576)) -eq 0 ]; then echo "$((b / 1048576))M"; else echo "$((b / 1024))K"; fi; }
jstr() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; s=$(printf '%s' "$s" | tr -d '\000-\037'); printf '"%s"' "$s"; }
jnum() { case "${1:-}" in ''|-|nan|inf) printf 'null' ;; *) printf '%s' "$1" ;; esac; }
rd() { tr -d '\000\n' 2>/dev/null <"$1" | sed 's/  */ /g; s/^ //; s/ $//'; }
now_s() { if [ -n "${NVBENCH_FAKE_CLOCK:-}" ]; then cat "$NVBENCH_FAKE_CLOCK"; else date +%s; fi; }  # fake clock: test harness
TEST=${NVBENCH_TEST:-0}   # 1 = test harness with stub apps (no root, no sleeps)
nap() { [ "$TEST" = 1 ] || sleep "$1"; }

# ---------------------------------------------------------------- fixture
dev_of() { case "$1" in single1) echo nvrec0n1 ;; single2) echo nvrec1n1 ;; esac; }
members_of() { case "$1" in single1) echo nvrec0n1 ;; single2) echo nvrec1n1 ;; raid0) echo "nvrec0n1 nvrec1n1" ;; *) die "unknown layout '$1'" ;; esac; }
drive_json() { # <nvrecXn1>
    local d=$1 s=$SYS_BLOCK/$1/nvrec pci link=""
    pci=$(rd "$s/pci")
    if [ -n "$pci" ] && [ -e "$SYS_PCI/$pci/current_link_speed" ]; then
        link="$(rd "$SYS_PCI/$pci/current_link_speed") x$(rd "$SYS_PCI/$pci/current_link_width")"
    fi
    printf '{"dev":%s,"model":%s,"serial":%s,"firmware":%s,"mdts_bytes":%s,"nr_io_queues":%s,"pci":%s,"link":%s}' \
        "$(jstr "$d")" "$(jstr "$(rd "$s/model")")" "$(jstr "$(rd "$s/serial")")" \
        "$(jstr "$(rd "$s/firmware")")" "$(jnum "$(rd "$s/mdts_bytes")")" \
        "$(jnum "$(rd "$s/nr_io_queues")")" "$(jstr "$pci")" "$(jstr "$link")"
}
serials_of() { local d out=""; for d in $(members_of "$1"); do out="$out+$(rd "$SYS_BLOCK/$d/nvrec/serial")"; done; echo "${out#+}"; }
mdts_of() { # smallest MDTS of the layout's members
    local d m min=0
    for d in $(members_of "$1"); do
        m=$(rd "$SYS_BLOCK/$d/nvrec/mdts_bytes"); m=${m:-0}
        if [ "$m" -gt 0 ] && { [ "$min" -eq 0 ] || [ "$m" -lt "$min" ]; }; then min=$m; fi
    done
    echo "$min"
}
default_chunk() { local m; m=$(mdts_of "$1"); if [ "$m" -gt 0 ] && [ "$m" -lt 1048576 ]; then echo "$m"; else echo 1048576; fi; }
target_name() {
    local t
    t=$(nvrec --print-target 2>/dev/null) && [ -n "$t" ] && { echo "$t"; return; }
    # nvrec before --print-target: the default in --help
    nvrec --help 2>&1 | sed -n 's/.*--target <name>.*(default \([^)]*\)).*/\1/p' | head -n1
}
# the test-pattern generator's maximum rate: src_clk x 16 bytes/beat, from the
# driver's sysfs src_clk_hz, a measured value (199980011 for the 200 MHz clock)
# taken to the nearest MHz: 3200 MB/s on every target, 3200 when the attribute
# is missing. nvrec/nvplay clamp a higher --rate silently, so the suite caps
# every requested rate here and records the capped value.
src_max_mbps() { local c; c=$(rd "$SYS_NVREC/src_clk_hz"); [ -n "$c" ] && [ "$c" -gt 0 ] && echo $(( (c + 500000) / 1000000 * 16 )) || echo 3200; }
SRC_MAX=$(src_max_mbps)
cap_rate() { if [ "$1" -gt "$SRC_MAX" ]; then echo "$SRC_MAX"; else echo "$1"; fi; }
# cap_id <id> <requested> <capped>: the id's rate=<requested> -> rate=<capped>
cap_id() { echo "$1" | sed "s#/rate=$2\(/\|\$\)#/rate=$3\1#"; }

FIXTURE_JSON=""
fixture_json() {
    if [ -z "$FIXTURE_JSON" ]; then
        local d drives="" os=""
        for d in nvrec0n1 nvrec1n1; do
            [ -e "$SYS_BLOCK/$d/nvrec" ] && drives="$drives,$(drive_json $d)"
        done
        [ -r /etc/os-release ] && os=$(sed -n 's/^\(BUILD_ID\|VERSION_ID\)=//p' /etc/os-release | tr -d '"' | tr '\n' ' ')
        FIXTURE_JSON=$(printf '"target":%s,"board":%s,"kernel":%s,"image":%s,"hw_version":%s,"src_clk_hz":%s,"dp_clk_hz":%s,"cpus":%s,"drives":[%s]' \
            "$(jstr "$(target_name)")" "$(jstr "$(rd /proc/device-tree/model)")" "$(jstr "$(uname -r)")" \
            "$(jstr "$os")" "$(jstr "$(rd "$SYS_NVREC/version")")" "$(jnum "$(rd "$SYS_NVREC/src_clk_hz")")" \
            "$(jnum "$(rd "$SYS_NVREC/dp_clk_hz")")" "$(grep -c '^cpu[0-9]' "$PROC_STAT")" "${drives#,}")
    fi
    printf '%s' "$FIXTURE_JSON"
}

# ---------------------------------------------------------------- budget
BOOT_EPOCH=$(( $(now_s) - $(cut -d. -f1 /proc/uptime) ))
if [ -n "$T0_AGO" ]; then T0=$(( $(now_s) - T0_AGO )); else T0=$(( BOOT_EPOCH - 30 )); fi
DEADLINE=$(( T0 + BUDGET_MIN * 60 ))
left_s() { echo $(( DEADLINE - $(now_s) )); }
# budget_ok <estimated seconds>: exit 3 when the run would end after the deadline
budget_ok() {
    local need=$1 left; left=$(left_s)
    [ "$DRY" -eq 1 ] && return 0
    if [ "$need" -gt "$left" ]; then
        say "budget: next run needs ~${need} s, ${left} s left of ${BUDGET_MIN} min: stopping (power-cycle and re-run to continue)"
        echo "$(date -Is) budget stop before '$CUR_ID' (need $need s, left $left s)" >>"$EVENTS"
        exit 3
    fi
}
# estimated seconds for a recording (+ verify) of <bytes> at <MB/s>
est_rec() { echo $(( $1 * 3 / 2 / ($2 * 1000000) + ${3:-0} * $1 / (VERIFY_MBPS * 1000000) + 15 )); }

# ---------------------------------------------------------------- health
ha_check() {
    [ "$DRY" -eq 1 ] && return 0
    if [ "$(rd "$SYS_NVREC/ha_dead")" = 1 ]; then
        say "the Host Accelerator stopped responding (evaluation license): power-cycle and re-run"
        echo "$(date -Is) ha_dead before '$CUR_ID'" >>"$EVENTS"
        exit 5
    fi
}

# ---------------------------------------------------------------- results
have() { [ -f "$RESULTS" ] && grep -qF "\"id\":\"$1\"" "$RESULTS"; }
# field of the stored line for <id>: pass (true/false), rate_mbps, ...
field() { grep -F "\"id\":\"$1\"" "$RESULTS" 2>/dev/null | tail -n1 | sed -n "s/.*\"$2\":\([^,}]*\).*/\1/p" | tr -d '"'; }
passed() { [ "$(field "$1" pass)" = true ]; }

# ---------------------------------------------------------------- volume
cur_volume() { cat "$VOLSTATE" 2>/dev/null; }
# prep_volume <layout> <chunk bytes>: trimmed drives, fresh exFAT, idle
prep_volume() {
    local l=$1 c=$2 args
    args="-y --trim --mount $DIR --chunk $(chunk_name "$c")"
    [ "$l" != raid0 ] && args="$args --single $DEV_DIR/$(dev_of "$l")"
    if [ "$DRY" -eq 1 ]; then echo "      prep: nvsetup-raid0.sh $args; sleep $IDLE"; return 0; fi
    say "prep: nvsetup-raid0.sh $args"
    # shellcheck disable=SC2086
    nvsetup-raid0.sh $args >>"$LOGDIR/prep.log" 2>&1 || die "nvsetup-raid0.sh $args failed (see $LOGDIR/prep.log)"
    echo "$l $c" >"$VOLSTATE"
    sync
    nap "$IDLE"
}
# mount_volume <layout> <chunk>: the existing volume (after a reboot), no format
mount_volume() {
    local l=$1 c=$2 src
    [ "$(cur_volume)" = "$l $c" ] || return 1
    if [ "$l" = raid0 ]; then
        [ -e "$DEV_DIR/md0" ] || mdadm --assemble "$DEV_DIR/md0" "$DEV_DIR/nvrec0n1" "$DEV_DIR/nvrec1n1" >>"$LOGDIR/prep.log" 2>&1 || return 1
        src=$DEV_DIR/md0
    else
        src=$DEV_DIR/$(dev_of "$l")
    fi
    if ! mountpoint -q "$DIR"; then
        mkdir -p "$DIR"
        fsck.exfat -y "$src" >>"$LOGDIR/prep.log" 2>&1
        mount -o noatime "$src" "$DIR" >>"$LOGDIR/prep.log" 2>&1 || return 1
    fi
    [ "$(findmnt -n -o SOURCE "$DIR")" = "$src" ]
}

# ---------------------------------------------------------------- CPU
cpusnap() { awk '/^cpu/ {print $1, $2+$3, $4, $5, $6, $7+$8, $2+$3+$4+$5+$6+$7+$8+$9}' "$PROC_STAT"; }
# cpu_json <snap before> <snap after> <time -p output> -> "cpu":{...}
cpu_json() {
    local rt us sy
    rt=$(awk '/^real/ {print $2}' <<<"$3"); us=$(awk '/^user/ {print $2}' <<<"$3"); sy=$(awk '/^sys/ {print $2}' <<<"$3")
    paste -d' ' <(echo "$1") <(echo "$2") | awk -v rt="${rt:-0}" -v us="${us:-0}" -v sy="${sy:-0}" '
        function pct(a, b, T) { return T > 0 ? sprintf("%.2f", 100 * (b - a) / T) : "null" }
        {   T = $14 - $7
            s = sprintf("{\"usr\":%s,\"sys\":%s,\"irq\":%s,\"iowait\":%s,\"busy\":%s}",
                pct($2, $9, T), pct($3, $10, T), pct($6, $13, T), pct($5, $12, T),
                (T > 0 ? sprintf("%.2f", 100 * (($9 - $2) + ($10 - $3) + ($13 - $6)) / T) : "null"))
            if ($1 == "cpu") tot = s; else { pc = pc (n++ ? "," : "") s
                busy1 += (T > 0 ? 100 * (($9 - $2) + ($10 - $3) + ($13 - $6)) / T : 0) }
        }
        END { printf "\"cpu\":{\"ncores\":%d,\"total\":%s,\"per_core\":[%s],\"busy_core_pct\":%.2f,\"real_s\":%s,\"user_s\":%s,\"sys_s\":%s,\"proc_pct_core\":%s}",
                n, tot, pc, busy1, rt, us, sy, (rt > 0 ? sprintf("%.2f", 100 * (us + sy) / rt) : "null") }'
}

# ---------------------------------------------------------------- run parsing
res_get() { sed -n 's/^RESULT .*/&/p' "$1" | tail -n1 | tr ' ' '\n' | sed -n "s/^$2=//p"; }
# "...: N bytes in S s, R MB/s; C commands, E errors, max Q in flight per SSD"
inflight_max() { sed -n 's/.*max \([0-9]*\) in flight per SSD.*/\1/p' "$1" | tail -n1; }
# "...: command latency min A / avg B / max C us; ring high-water H slots, writer waited W ms ..."
lat_field() { sed -n 's/.*command latency min \([0-9.]*\) \/ avg \([0-9.]*\) \/ max \([0-9.]*\) us; ring high-water \([0-9]*\) slots, writer waited \([0-9.]*\) ms.*/\1 \2 \3 \4 \5/p' "$1" | tail -n1 | cut -d' ' -f"$2"; }
# RESULT key <2>, else the summary-line field <3> of lat_field (apps before
# the latency keys were added to RESULT)
res_or_lat() { local v; v=$(res_get "$1" "$2"); [ -n "$v" ] && echo "$v" || lat_field "$1" "$3"; }
stats_json() { # <app log>
    local h b0 hwm
    h=$(res_get "$1" lat_hist); [ -n "$h" ] || h=$(rd "$SYS_NVREC/lat_hist" | tr ' ' ',')
    b0=$(res_get "$1" lat_bin0_log2); [ -n "$b0" ] || b0=$(rd "$SYS_NVREC/lat_bin0_log2"); [ -n "$b0" ] || b0=10
    hwm=$(res_get "$1" inflight_hwm)
    printf '"inflight_max":%s,"inflight_hwm":[%s],"lat_min_us":%s,"lat_avg_us":%s,"lat_max_us":%s,"lat_count":%s,"ring_hwm":%s,"ring_wait_ms":%s,"lat_hist":[%s],"lat_bin0_log2":%s' \
        "$(jnum "$(inflight_max "$1")")" "$hwm" "$(jnum "$(res_or_lat "$1" lat_min_us 1)")" \
        "$(jnum "$(res_or_lat "$1" lat_avg_us 2)")" "$(jnum "$(res_or_lat "$1" lat_max_us 3)")" \
        "$(jnum "$(res_get "$1" lat_count)")" "$(jnum "$(res_or_lat "$1" ring_hwm 4)")" \
        "$(jnum "$(res_or_lat "$1" ring_wait_ms 5)")" "$h" "$b0"
}
# "buffers" = the slots the app used (RESULT ring_slots; apps before that key:
# the requested count), "buffers_req" = --buffers given (null = app default)
ring_json() { # <app log> <requested slots|"">
    local rs; rs=$(res_get "$1" ring_slots); [ -n "$rs" ] || rs=$2
    printf '"buffers":%s,"buffers_req":%s,"ring_slots":%s,"ring_bytes":%s' "$(jnum "$rs")" "$(jnum "$2")" \
        "$(jnum "$(res_get "$1" ring_slots)")" "$(jnum "$(res_get "$1" ring_bytes)")"
}
verify_json() { # <rc> <nvverify log> <seconds>
    local first
    first=$(sed -n 's/^GAP at beat [0-9]* (file offset \([0-9]*\)).*/\1/p' "$2" | head -n1)
    printf '"verify":{"rc":%s,"result":%s,"discontinuities":%s,"beats_missing":%s,"corrupted":%s,"first_gap_offset":%s,"seconds":%s}' \
        "$1" "$(jstr "$(sed -n 's/^RESULT //p' "$2" | tail -n1)")" \
        "$(jnum "$(sed -n 's/^  discontinuities \([0-9]*\).*/\1/p' "$2")")" \
        "$(jnum "$(sed -n 's/.*beats missing \([0-9]*\)$/\1/p' "$2")")" \
        "$(jnum "$(sed -n 's/^  corrupted beats \([0-9]*\).*/\1/p' "$2")")" "$(jnum "$first")" "$3"
}

# emit <id> <test> <layout> <json body without braces>
emit() {
    local line
    line=$(printf '{"schema":1,"suite":%s,"id":%s,"ts":%s,"test":%s,"layout":%s,"members":%s,%s,"uptime_s":%s,"budget_left_s":%s,"note":%s,%s}' \
        "$(jstr "nvbench-suite $VERSION")" "$(jstr "$1")" "$(jstr "$(date -u +%Y-%m-%dT%H:%M:%SZ)")" \
        "$(jstr "$2")" "$(jstr "$3")" "$(jstr "$(members_of "$3")")" "$(fixture_json)" \
        "$(cut -d. -f1 /proc/uptime)" "$(left_s)" "$(jstr "$NOTE")" "$4")
    echo "$line" >>"$RESULTS"
    sync
}

# ---------------------------------------------------------------- one recording
# rec_run <id> <test> <layout> <bytes> <rate MB/s> <chunk> <qd> <slots|""> <prep: trim|none> [file]
# (slots "" = nvrec's default ring)
# returns 0 when the run passed (rc 0 and nvverify PASS), 1 otherwise.
rec_run() {
    local id=$1 test=$2 l=$3 bytes=$4 rate=$5 chunk=$6 qd=$7 slots=$8 prep=$9 f=${10:-$OUT}
    local log vlog rc vrc s0 s1 t pass vt0 vt1 achieved st capped=false
    if [ "$rate" -gt "$SRC_MAX" ]; then
        id=$(cap_id "$id" "$rate" "$SRC_MAX"); say "  rate $rate MB/s > source max $SRC_MAX MB/s: capped ($id)"; rate=$SRC_MAX; capped=true
    fi
    log=$LOGDIR/$(echo "$id" | tr '/:+=' '____').log
    CUR_ID=$id
    if have "$id"; then
        [ "$DRY" -eq 1 ] && echo "  skip $id ($(field "$id" pass))"
        passed "$id"; return
    fi
    if [ "$DRY" -eq 1 ]; then
        echo "  RUN  $id (~$(est_rec "$bytes" "$rate" 1) s)"
        if [ "$prep" = trim ]; then DRY_EST=$(( DRY_EST + IDLE + 20 )); else DRY_EST=$(( DRY_EST + 10 )); fi
        DRY_EST=$(( DRY_EST + $(est_rec "$bytes" "$rate" 1) ))
        [ "$prep" = trim ] && prep_volume "$l" "$chunk"
        [ "$rate" -le "$DRY_MAXRATE" ]; return
    fi
    ha_check
    if [ "$prep" = trim ]; then
        budget_ok $(( $(est_rec "$bytes" "$rate" 1) + IDLE + 20 ))
        prep_volume "$l" "$chunk"
    else
        budget_ok "$(est_rec "$bytes" "$rate" 1)"
        if ! mount_volume "$l" "$chunk"; then prep_volume "$l" "$chunk"; fi
        rm -f "$f"; sync; nap 10
    fi
    say "record $id"
    s0=$(cpusnap)
    t=$( { time -p nvrec --rate "${rate}MB" --size "$bytes" --chunk "$chunk" --qd "$qd" \
              ${slots:+--buffers "$slots"} --stats 0 --force "$f" >"$log" 2>&1; echo "RC=$?" >>"$log"; } 2>&1 )
    s1=$(cpusnap)
    rc=$(sed -n 's/^RC=//p' "$log" | tail -n1)
    if [ "$rc" = 5 ]; then ha_check; exit 5; fi
    if [ "$rc" != 0 ] && [ "$rc" != 2 ] && ! grep -q '^RESULT ' "$log"; then
        die "nvrec failed before recording (rc $rc), not stored as a result: see $log"
    fi
    st=$(stats_json "$log")
    vlog=$log.verify
    if [ "$rc" = 0 ] || [ "$rc" = 2 ]; then
        vt0=$(date +%s.%N); nvverify -q --max-errors 5 "$f" >"$vlog" 2>&1; vrc=$?; vt1=$(date +%s.%N)
    else
        echo "RESULT -" >"$vlog"; vrc=-1; vt0=0; vt1=0
    fi
    pass=false; [ "$rc" = 0 ] && [ "$vrc" = 0 ] && pass=true
    achieved=$(awk -v b="$(res_get "$log" bytes)" -v s="$(res_get "$log" seconds)" 'BEGIN { if (s > 0) printf "%.1f", b / s / 1e6; else print "null" }')
    emit "$id" "$test" "$l" "$(printf '"direction":"record","size_bytes":%s,"rate_req_mbps":%s,"rate_capped":%s,"rate_mbps":%s,"seconds":%s,"bytes":%s,"chunk":%s,"qd":%s,%s,"prep":%s,"idle_s":%s,"exit":%s,"pass":%s,"drops":%s,"nvme_errors":%s,"fifo_hwm":%s,"fifo_depth":%s,%s,%s,%s' \
        "$bytes" "$rate" "$capped" "$achieved" "$(jnum "$(res_get "$log" seconds)")" "$(jnum "$(res_get "$log" bytes)")" \
        "$chunk" "$qd" "$(ring_json "$log" "$slots")" "$(jstr "$([ "$prep" = trim ] && echo 'blkdiscard+mkfs.exfat' || echo 'rm+sync')")" \
        "$([ "$prep" = trim ] && echo "$IDLE" || echo 10)" "$(jnum "$rc")" "$pass" \
        "$(jnum "$(res_get "$log" drops)")" "$(jnum "$(res_get "$log" nvme_errors)")" \
        "$(jnum "$(res_get "$log" fifo_hwm)")" "$(jnum "$(res_get "$log" fifo_depth)")" \
        "$st" "$(verify_json "$vrc" "$vlog" "$(awk -v a="$vt0" -v b="$vt1" 'BEGIN{printf "%.1f", b - a}')")" \
        "$(cpu_json "$s0" "$s1" "$t")")${REC_EXTRA:+,$REC_EXTRA}"
    say "  -> rc=$rc verify=$(sed -n 's/^RESULT //p' "$vlog" | tail -n1) pass=$pass ($achieved MB/s)"
    [ "$pass" = true ]
}

# play_run <id> <test> <layout> <rate> <file> <qd> <slots|"">  (0 = clean)
play_run() {
    local id=$1 test=$2 l=$3 rate=$4 f=$5 qd=$6 slots=$7
    local log rc s0 s1 t pass bytes capped=false
    if [ "$rate" -gt "$SRC_MAX" ]; then
        id=$(cap_id "$id" "$rate" "$SRC_MAX"); say "  rate $rate MB/s > source max $SRC_MAX MB/s: capped ($id)"; rate=$SRC_MAX; capped=true
    fi
    log=$LOGDIR/$(echo "$id" | tr '/:+=' '____').log
    CUR_ID=$id
    if have "$id"; then
        [ "$DRY" -eq 1 ] && echo "  skip $id ($(field "$id" pass))"
        passed "$id"; return
    fi
    if [ "$DRY" -eq 1 ]; then
        echo "  RUN  $id"; DRY_EST=$(( DRY_EST + 15 + 10737418240 * 3 / 2 / (rate * 1000000) ))
        [ "$rate" -le "$DRY_MAXRATE" ]; return
    fi
    ha_check
    bytes=$(stat -c %s "$f" 2>/dev/null || echo 0)
    budget_ok "$(est_rec "$bytes" "$rate" 0)"
    sync; echo 3 2>/dev/null >/proc/sys/vm/drop_caches; nap 5
    say "play $id"
    s0=$(cpusnap)
    t=$( { time -p nvplay --rate "${rate}MB" --qd "$qd" ${slots:+--buffers "$slots"} --stats 0 "$f" >"$log" 2>&1; echo "RC=$?" >>"$log"; } 2>&1 )
    s1=$(cpusnap)
    rc=$(sed -n 's/^RC=//p' "$log" | tail -n1)
    if [ "$rc" = 5 ]; then ha_check; exit 5; fi
    if [ "$rc" != 0 ] && [ "$rc" != 2 ] && ! grep -q '^RESULT ' "$log"; then
        die "nvplay failed before playing (rc $rc), not stored as a result: see $log"
    fi
    pass=false; [ "$rc" = 0 ] && pass=true
    emit "$id" "$test" "$l" "$(printf '"direction":"play","file_bytes":%s,"rate_req_mbps":%s,"rate_capped":%s,"rate_mbps":%s,"seconds":%s,"bytes":%s,"qd":%s,%s,"exit":%s,"pass":%s,"underflows":%s,"chk_errors":%s,"gaps":%s,"gap_beats":%s,"drop_count":%s,"beats":%s,"complete":%s,"nvme_errors":%s,"prefill_s":%s,%s,%s' \
        "$bytes" "$rate" "$capped" \
        "$(awk -v b="$(res_get "$log" bytes)" -v s="$(res_get "$log" seconds)" 'BEGIN { if (s > 0) printf "%.1f", b / s / 1e6; else print "null" }')" \
        "$(jnum "$(res_get "$log" seconds)")" "$(jnum "$(res_get "$log" bytes)")" "$qd" "$(ring_json "$log" "$slots")" "$(jnum "$rc")" "$pass" \
        "$(jnum "$(res_get "$log" underflows)")" "$(jnum "$(res_get "$log" errors)")" "$(jnum "$(res_get "$log" gaps)")" \
        "$(jnum "$(res_get "$log" gap_beats)")" "$(jnum "$(res_get "$log" drop_count)")" "$(jnum "$(res_get "$log" beats)")" \
        "$(jnum "$(res_get "$log" complete)")" "$(jnum "$(res_get "$log" nvme_errors)")" "$(jnum "$(res_get "$log" prefill_seconds)")" \
        "$(stats_json "$log")" "$(cpu_json "$s0" "$s1" "$t")")"
    say "  -> rc=$rc underflows=$(res_get "$log" underflows) pass=$pass"
    [ "$pass" = true ]
}

# ---------------------------------------------------------------- tests
fx() { echo "$1-$(chunk_name "$2"):$(serials_of "$1")"; }   # layout tag in ids
need_layout() { [ -n "$LAYOUT" ] || die "$CMD needs --layout single1|single2|raid0"; members_of "$LAYOUT" >/dev/null; }
top_rate() { [ -n "$TO" ] && cap_rate "$TO" || echo "$SRC_MAX"; }   # sweeps skip steps above the source max
glance_top() { [ -n "$TO" ] && cap_rate "$TO" || cap_rate "$GLANCE_TO"; }
# grid_last <from> <step> <to>: the last grid rate from + k*step <= to
grid_last() { echo $(( $1 + ( ($3 - $1) / $2 ) * $2 )); }
# rate_list: --rates as MB/s integers, one per line (dies on a bad value)
rate_list() {
    local r
    for r in ${RATES//,/ }; do
        r=${r%[Mm][Bb]}
        case "$r" in ''|*[!0-9]*) die "$CMD: invalid rate '$r' (MB/s)" ;; esac
        echo "$r"
    done
}
# rates_rec <test> <layout> <bytes> <prep>: every --rates rate once (+ --confirm
# repeats when given), no stop at a failure; SWEEP_BEST = highest clean (capped)
rates_rec() {
    local test=$1 l=$2 bytes=$3 prep=$4 c r i best=0
    c=$(default_chunk "$l")
    for r in $(rate_list); do
        # a rate above the source max runs at the max, rate_capped
        for i in $(seq 1 $(( ${CONFIRM:-0} + 1 ))); do
            rec_run "$test/$(fx "$l" "$c")/size=$bytes/rate=$r$(run_sfx "$i")" "$test" "$l" "$bytes" "$r" "$c" 32 "$BUFFERS" "$prep" \
                && [ "$(cap_rate "$r")" -gt "$best" ] && best=$(cap_rate "$r")
        done
    done
    SWEEP_BEST=$best
}

# sweep <test> <layout> <bytes> <from> <step> <to> <prep> <confirm>
# rates from..to until the first failure, the last step AT <to> when the grid
# misses it (250, .., 3000, 3200); then <confirm> repeats of the top clean
# step. SWEEP_BEST = the top clean rate (0 = none).
sweep() {
    local test=$1 l=$2 bytes=$3 r=$4 step=$5 to=$6 prep=$7 confirm=$8
    local c q s best=0 i last=0
    c=$(default_chunk "$l"); q=32; s=$BUFFERS
    while [ "$r" -le "$to" ]; do
        if rec_run "$test/$(fx "$l" "$c")/size=$bytes/rate=$r" "$test" "$l" "$bytes" "$r" "$c" "$q" "$s" "$prep"; then
            best=$r; last=$r
        else
            last=-1; break
        fi
        # the grid's last step passed and is below <to>: one more step at <to>
        if [ $(( r + step )) -gt "$to" ] && [ "$r" -lt "$to" ]; then r=$to; else r=$(( r + step )); fi
        [ "$last" -eq "$to" ] && break
    done
    for i in $(seq 2 $(( confirm + 1 ))); do
        [ "$best" -gt 0 ] || break
        rec_run "$test/$(fx "$l" "$c")/size=$bytes/rate=$best/run=$i" "$test" "$l" "$bytes" "$best" "$c" "$q" "$s" "$prep" || true
    done
    SWEEP_BEST=$best
}

t_sustained() {
    need_layout
    local bytes; bytes=$(to_bytes "${SIZE:-32G}")
    if [ -n "$RATES" ]; then rates_rec sustained "$LAYOUT" "$bytes" trim
    else sweep sustained "$LAYOUT" "$bytes" "$FROM" "$STEP" "$(top_rate)" trim 0; fi
    say "sustained ($LAYOUT): highest clean step $SWEEP_BEST MB/s"
}
t_glance() {
    need_layout
    local bytes; bytes=$(to_bytes "${SIZE:-4000M}")
    if [ -n "$RATES" ]; then rates_rec glance "$LAYOUT" "$bytes" none
    else sweep glance "$LAYOUT" "$bytes" "$FROM" "$STEP" "$(glance_top)" none "${CONFIRM:-2}"; fi
    say "glance ($LAYOUT): highest clean step $SWEEP_BEST MB/s"
}
t_burst() {
    need_layout
    local bytes
    bytes=$(to_bytes "${SIZE:-10G}")
    if [ -n "$RATES" ]; then
        rates_rec burst "$LAYOUT" "$bytes" trim
    else
        sweep burst "$LAYOUT" "$bytes" "$FROM" "$STEP" "$(top_rate)" trim "${CONFIRM:-0}"
    fi
    say "burst ($LAYOUT, $bytes bytes): highest clean $SWEEP_BEST MB/s"
}
# the layout's highest clean result of <test> at <size>, from the results file
best_of() { # <test> <layout> <bytes>
    local tag; tag="$1/$(fx "$2" "$(default_chunk "$2")")/size=$3/"
    [ -f "$RESULTS" ] || { echo 0; return; }
    grep -F "\"id\":\"$tag" "$RESULTS" | grep -F '"pass":true' | sed -n 's/.*"rate_req_mbps":\([0-9]*\).*/\1/p' | sort -n | tail -n1 | grep . || echo 0
}
auto_rate() { # <layout>
    local r
    if [ -n "$RATE" ] && [ "$RATE" != auto ]; then echo "$RATE"; return; fi
    r=$(best_of burst "$1" "$(to_bytes 10G)")
    [ "$r" -gt 0 ] || r=1000
    [ "$r" -gt 3000 ] && r=3000
    echo "$r"
}
# the playback source: a 10 GB recording at 1000 MB/s on a fresh volume
# (the recorder's playback method); reused while the volume and file survive
ensure_playsrc() { # <layout> <chunk>
    local l=$1 c=$2 sbytes; sbytes=$(to_bytes 10G)
    [ "$DRY" -eq 1 ] && [ -n "${PLAYSRC_OK:-}" ] && return 0
    if [ "$DRY" -eq 0 ] && mount_volume "$l" "$c" && [ -f "$PLAYSRC" ] && \
       nvverify --header-only "$PLAYSRC" 2>/dev/null | grep -q 'drop_count *0$'; then
        return 0
    fi
    rec_run "playsrc/$(fx "$l" "$c")/size=$sbytes/rate=1000/boot=$BOOT_EPOCH" playsrc "$l" "$sbytes" 1000 "$c" 32 "$BUFFERS" trim "$PLAYSRC" \
        || die "playback source recording failed"
    PLAYSRC_OK=1
}
play_id() { echo "playback/$(fx "$1" "$2")/size=$(to_bytes 10G)/rate=$3${4:+/run=$4}"; }
run_sfx() { [ "$1" -gt 1 ] && echo "/run=$1"; }
# play1 <layout> <chunk> <rate> [run]: one playback (the source recorded first
# when the run is not in the results yet); 0 = clean
play1() {
    local id cr; id=$(play_id "$1" "$2" "$3" "${4:-}"); cr=$(cap_rate "$3")
    have "$(cap_id "$id" "$3" "$cr")" || ensure_playsrc "$1" "$2"
    play_run "$id" playback "$1" "$3" "$PLAYSRC" 32 "$BUFFERS"
}
# play_sweep <layout> <from> <step> <to> <confirm>: as sweep(), for nvplay
play_sweep() {
    local l=$1 r=$2 step=$3 to=$4 confirm=$5 c best=0 i last=0
    c=$(default_chunk "$l"); PLAYSRC_OK=""
    while [ "$r" -le "$to" ]; do
        if play1 "$l" "$c" "$r"; then best=$r; last=$r; else break; fi
        if [ $(( r + step )) -gt "$to" ] && [ "$r" -lt "$to" ]; then r=$to; else r=$(( r + step )); fi
        [ "$last" -eq "$to" ] && break
    done
    for i in $(seq 2 $(( confirm + 1 ))); do
        [ "$best" -gt 0 ] || break
        play1 "$l" "$c" "$best" "$i" || true
    done
    SWEEP_BEST=$best
}
t_playback() {
    need_layout
    local c r i best=0
    if [ -n "$RATES" ]; then
        c=$(default_chunk "$LAYOUT"); PLAYSRC_OK=""
        for r in $(rate_list); do
            for i in $(seq 1 $(( ${CONFIRM:-0} + 1 ))); do
                play1 "$LAYOUT" "$c" "$r" "$([ "$i" -gt 1 ] && echo "$i")" && [ "$(cap_rate "$r")" -gt "$best" ] && best=$(cap_rate "$r")
            done
        done
        SWEEP_BEST=$best
    else
        play_sweep "$LAYOUT" "$FROM" "$STEP" "$(top_rate)" "${CONFIRM:-2}"
    fi
    say "playback ($LAYOUT): highest clean step $SWEEP_BEST MB/s"
}
# cpu: records of --size at --rate (CPU over the nvrec run), playbacks of the
# 10 GB playback source at the same rate (CPU over the nvplay run)
t_cpu() {
    need_layout
    local c bytes r i id
    c=$(default_chunk "$LAYOUT"); bytes=$(to_bytes "${SIZE:-10G}"); r=${RATE:-1000}; [ "$r" = auto ] && r=1000
    PLAYSRC_OK=""
    for i in $(seq 1 "$RUNS"); do
        rec_run "cpu/$(fx "$LAYOUT" "$c")/size=$bytes/rate=$r/run=$i" cpu "$LAYOUT" "$bytes" "$r" "$c" 32 "$BUFFERS" none "$DIR/cpu.dat" || true
        [ "$DRY" -eq 0 ] && rm -f "$DIR/cpu.dat" && nap 20
        id="cpuplay/$(fx "$LAYOUT" "$c")/size=$(to_bytes 10G)/rate=$r/run=$i"
        have "$id" || ensure_playsrc "$LAYOUT" "$c"
        play_run "$id" cpuplay "$LAYOUT" "$r" "$PLAYSRC" 32 "$BUFFERS" || true
        [ "$DRY" -eq 0 ] && nap 20
    done
    return 0
}
t_chunk() {
    need_layout
    local m c list r bytes slots
    m=$(mdts_of "$LAYOUT"); [ "$m" -gt 0 ] || m=1048576
    [ "$m" -gt 4194304 ] && m=4194304     # nvrec's largest chunk
    list=$CHUNKS
    if [ -z "$list" ]; then c=131072; while [ "$c" -le "$m" ]; do list="$list $(chunk_name $c)"; c=$(( c * 2 )); done; fi
    r=$(auto_rate "$LAYOUT"); bytes=$(to_bytes "${SIZE:-10G}")
    for c in $list; do
        c=$(to_bytes "$c")
        [ "$c" -le "$m" ] || { say "chunk $(chunk_name "$c") > MDTS $(chunk_name "$m"): skipped"; continue; }
        slots=$(( RING_MB * 1048576 / c )); [ "$slots" -gt 1024 ] && slots=1024
        rec_run "chunk/$(fx "$LAYOUT" "$c")/size=$bytes/rate=$r/chunk=$c/slots=$slots" chunk "$LAYOUT" "$bytes" "$r" "$c" 32 "$slots" trim || true
    done
}
t_inflight() {
    need_layout
    local c q r bytes slots
    c=$(default_chunk "$LAYOUT"); r=$(auto_rate "$LAYOUT"); bytes=$(to_bytes "${SIZE:-10G}")
    slots=$(( RING_MB * 1048576 / c )); [ "$slots" -gt 1024 ] && slots=1024
    for q in $QDS; do
        [ "$q" -ge 1 ] && [ "$q" -le 63 ] || { say "qd $q outside 1..63: skipped"; continue; }
        rec_run "inflight/$(fx "$LAYOUT" "$c")/size=$bytes/rate=$r/qd=$q" inflight "$LAYOUT" "$bytes" "$r" "$c" "$q" "$slots" trim || true
    done
}
# longrun: the post-SLC-cache sustained rate (the recorder's long recordings):
# per rate a fresh trimmed volume, --idle (default 600 s) so the drive can
# flush its SLC cache, one --size (200G) recording, nvverify
t_longrun() {
    need_layout
    local bytes c r list
    bytes=$(to_bytes "${SIZE:-200G}"); c=$(default_chunk "$LAYOUT")
    list=${RATES:-$RATE}
    [ -n "$list" ] && [ "$list" != auto ] || die "longrun needs --rate <MB/s>[,<MB/s>..]"
    [ "$IDLE_SET" = 1 ] || IDLE=600
    REC_EXTRA="\"cmd\":\"longrun\",\"pre_idle_s\":$IDLE"
    for r in ${list//,/ }; do
        r=${r%[Mm][Bb]}
        case "$r" in ''|*[!0-9]*) die "longrun: invalid rate '$r' (MB/s)" ;; esac
        rec_run "longrun/$(fx "$LAYOUT" "$c")/size=$bytes/rate=$r/idle=$IDLE" longrun "$LAYOUT" "$bytes" "$r" "$c" 32 "$BUFFERS" trim || true
    done
    REC_EXTRA=""
}
t_verify() {
    local f=${CMD_ARGS[0]:-$OUT} log rc
    [ -f "$f" ] || f=$PLAYSRC
    [ -f "$f" ] || die "no recording to verify (give a file)"
    log=$LOGDIR/verify_$(date +%Y%m%d_%H%M%S).log
    nvverify "$f" | tee "$log"; rc=${PIPESTATUS[0]}
    return "$rc"
}
t_info() { printf '{%s}\n' "$(fixture_json)"; }
t_status() {
    [ -f "$RESULTS" ] || { echo "no results yet ($RESULTS)"; return 0; }
    echo "$RESULTS: $(wc -l <"$RESULTS") runs"
    sed -n 's/.*"id":"\([^/]*\)\/\([^/]*\)\/.*"pass":\([a-z]*\).*/\1 \2 \3/p' "$RESULTS" | \
        awk '{k=$1" "$2; n[k]++; if ($3=="true") p[k]++} END {for (k in n) printf "  %-12s %-70s %3d runs, %3d pass\n", substr(k,1,index(k," ")-1), substr(k,index(k," ")+1), n[k], p[k]}' | sort
}

# layout_ok <layout>: its drives are present (for all / gaps)
layout_ok() {
    local l=$1
    if ! members_of "$l" >/dev/null || ! [ -e "$SYS_BLOCK/$(members_of "$l" | cut -d' ' -f1)/nvrec" ]; then
        say "layout $l: drive missing, skipped"; return 1
    fi
    if [ "$l" = raid0 ] && ! [ -e "$SYS_BLOCK/nvrec1n1/nvrec" ]; then say "raid0: one drive only, skipped"; return 1; fi
}
# all: the matrix per layout, ordered so that the auto rates exist when needed
t_all() {
    local l s40 best r
    for l in $LAYOUTS; do
        LAYOUT=$l
        layout_ok "$l" || continue
        say "=== layout $l ($(serials_of "$l"))"
        FROM=250; STEP=250; SIZE=""; RATES=""; CONFIRM=""; RATE=""
        t_sustained
        best=$SWEEP_BEST
        t_glance
        FROM=500; SIZE=10G; t_burst; SIZE=""; FROM=250
        # 40 GB at the sustained rate and the next step (the recorder's 40 GB rows)
        # (the next step capped at the source max; skipped when that is no step up)
        s40=$best; [ "$s40" -gt 0 ] || s40=250
        r=$(( s40 + 250 )); RATES=$s40; [ "$(cap_rate "$r")" -gt "$(cap_rate "$s40")" ] && RATES="$s40,$r"
        SIZE=40G; t_burst; SIZE=""; RATES=""
        t_playback
        t_cpu
        RATE=auto; t_chunk; t_inflight; RATE=""
    done
    say "matrix complete for: $LAYOUTS"
}

# gaps: results from suites whose sweeps ended at the last 250-grid step
# (3000) get the final step at the source maximum that 'all' now runs: per
# layout the 32 GB sustained, the 10 GB burst (from 500, as in 'all') and the
# playback sweeps, each continued from its last grid step -- only where that
# step is in the results and passed (a sweep that failed earlier ended there,
# as it would now). The ids are those 'all' produces (resume skips them); the
# 4000 MiB glance sweep ends at 3000 (as the recorder's) and has no gap.
# gap_due <test> <id of the last grid step> <last grid rate> <to>: 0 = run the gap step
gap_due() {
    if [ "$3" -ge "$4" ]; then say "$1 ($LAYOUT): the grid ends at $4 MB/s: no gap"; return 1; fi
    if ! have "$2"; then say "$1 ($LAYOUT): no $3 MB/s step in the results (the sweep ended below it, or has not run: '$1' runs the whole sweep): no gap step"; return 1; fi
    if ! passed "$2"; then say "$1 ($LAYOUT): the sweep failed at $3 MB/s (its end): no gap"; return 1; fi
}
t_gaps() {
    local l to c last
    to=$(top_rate)
    for l in $LAYOUTS; do
        LAYOUT=$l
        layout_ok "$l" || continue
        say "=== gaps, layout $l ($(serials_of "$l")): source max $to MB/s"
        FROM=250; STEP=250; SIZE=""; RATES=""; CONFIRM=""; RATE=""
        c=$(default_chunk "$l")
        last=$(grid_last 250 250 "$to")
        if gap_due sustained "sustained/$(fx "$l" "$c")/size=$(to_bytes 32G)/rate=$last" "$last" "$to"; then
            sweep sustained "$l" "$(to_bytes 32G)" "$last" 250 "$to" trim 0
            say "sustained ($l): highest clean step $SWEEP_BEST MB/s"
        fi
        last=$(grid_last 500 250 "$to")
        if gap_due burst "burst/$(fx "$l" "$c")/size=$(to_bytes 10G)/rate=$last" "$last" "$to"; then
            sweep burst "$l" "$(to_bytes 10G)" "$last" 250 "$to" trim 0
            say "burst ($l, $(to_bytes 10G) bytes): highest clean $SWEEP_BEST MB/s"
        fi
        last=$(grid_last 250 250 "$to")
        if gap_due playback "$(play_id "$l" "$c" "$last")" "$last" "$to"; then
            play_sweep "$l" "$last" 250 "$to" 2
            say "playback ($l): highest clean step $SWEEP_BEST MB/s"
        fi
    done
    say "gaps complete for: $LAYOUTS"
}

# ---------------------------------------------------------------- main
if [ "$DRY" -eq 0 ] && [ "$CMD" != info ] && [ "$CMD" != status ]; then
    [ "$TEST" = 1 ] || [ "$(id -u)" -eq 0 ] || die "run as root"
    for p in nvrec nvplay nvverify nvsetup-raid0.sh; do command -v $p >/dev/null || die "$p not found in PATH"; done
    [ "$TEST" = 1 ] || [ -c "$DEV_DIR/nvrec" ] || die "$DEV_DIR/nvrec not found (modprobe nvrec)"
    mkdir -p "$LOGDIR" || die "cannot create $LOGDIR"
    exec 9>"$(dirname "$RESULTS")/lock"
    flock -n 9 || die "another nvbench-suite is running"
    trap 'echo $? >"$(dirname "$RESULTS")/last_exit"' EXIT
    echo "$(date -Is) start: $CMD layout=${LAYOUT:-$LAYOUTS} budget=${BUDGET_MIN}min left=$(left_s)s" >>"$EVENTS"
fi
DRY_MAXRATE=${NVBENCH_DRY_MAXRATE:-1500}   # dry run: pretend rates up to this pass
CUR_ID=""
SWEEP_BEST=0
DRY_EST=0
REC_EXTRA=""
[ "$DRY" -eq 1 ] && say "dry run: deadline in $(left_s) s; results $RESULTS"

case "$CMD" in
    info) t_info ;;
    status) t_status ;;
    sustained) t_sustained ;;
    glance) t_glance ;;
    burst) t_burst ;;
    playback) t_playback ;;
    cpu) t_cpu ;;
    chunk) t_chunk ;;
    inflight) t_inflight ;;
    longrun) t_longrun ;;
    verify) t_verify; exit $? ;;
    all) t_all ;;
    gaps) t_gaps ;;
    *) usage >&2; exit 2 ;;
esac
[ "$DRY" -eq 1 ] && say "dry run: the runs marked RUN need ~$(( DRY_EST / 60 )) min (estimate; budget ${BUDGET_MIN} min per session)"
[ "$DRY" -eq 0 ] && [ "$CMD" != info ] && [ "$CMD" != status ] && \
    echo "$(date -Is) done: $CMD layout=${LAYOUT:-$LAYOUTS}" >>"$EVENTS"
exit 0
