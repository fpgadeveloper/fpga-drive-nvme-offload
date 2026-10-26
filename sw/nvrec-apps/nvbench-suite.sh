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
#   sustained  32 GB per step, --step MB/s steps (250), until --stop-after
#              (1) consecutive failing steps; fresh trimmed volume + 60 s idle
#              before every step
#   glance     4000 MiB rate sweep + confirmations of the top step
#   burst      10 GB / 40 GB recordings at given rates (or a sweep)
#   playback   nvplay sweep on a 10 GB recording made at 1000 MB/s, until
#              the first rate with underflows, + confirmations
#   fabric     fabric-only record sweep (nvrec --no-write, 64 GiB per step):
#              the source -> ring -> DDR path without SSD (register map 1.2)
#   fabricplay fabric-only ring-resident playback sweep (nvplay --ring-only)
#   Sweeps run --from/--step/--to up to the source maximum (src_clk x
#   beat_bytes: 8000 MB/s on the 256-bit designs, 3200 on 128-bit ones) and
#   end with one step AT the maximum when it is not on the grid. With
#   --stop-after 2 a sweep goes on past a failing step and ends after two
#   consecutive failing steps; --confirm repeats the top clean step,
#   --confirm-fail the first failing step above it.
#   gaps       only the final source-max steps (+ the confirmations of
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
# Ring: nvrec/nvplay's default (512 MB of slots: 2048 x 256 KB, 1024 x
# 512 KB, 512 x 1 MB; a split ring 1 GB: 4096 x 256 KB, 2048 x 512 KB, ..)
# unless --buffers is given (then in the run ids as /slots=N); chunk and
# inflight keep --ring-mb constant. Every run stores the ring the app set up
# (ring_slots, ring_bytes, ring = single/split/mem1, stripe_kb,
# ring_mem1_bytes from its RESULT line) and the ring ports' wait times
# (wr_port_stall_ms / rd_port_wait_ms, register map 1.3).
# Ring layout (register map 1.3): --ring single|split|mem1|auto and --stripe
# <KB>|chunk are passed to nvrec / nvplay and appended to every id
# (/ring=split/stripe=4K); without them the apps' default (the driver's:
# split on a design with a second ring memory, single for one SSD) runs
# under the plain id. Comma lists (--ring single,split --stripe 4,64,chunk)
# run the whole command once per combination: A/B of ring layouts and
# stripes in one call (a stripe only combines with split; --stripe alone
# means --ring split). The playback source is always recorded with the
# default ring (the file is the same).
# --tag <word> is appended to every id (/tag=<word>) for A/B runs of the same
# steps (MaxPayload, APST, ...).
# --budget-min stops cleanly before a run that would not finish in time.
# Drive temperature guard (driver 1.1 sysfs temperature): a run is stopped
# (SIGINT = a clean stop) when a member drive passes --temp-max (70 C), not
# stored, and repeated once after the drives cooled to --temp-resume (45 C);
# a second over-temperature stops the suite (exit 4).
#
# Exit codes: 0 = everything asked for is in the results file, 3 = stopped
# for the time budget (power-cycle and run again), 4 = drive over
# temperature twice on one run, 5 = the Host Accelerator stopped responding
# (power-cycle and run again), 1 = error, 2 = usage.

set -u

VERSION=3
SYS_NVREC=${NVBENCH_SYS_NVREC:-/sys/class/misc/nvrec}
SYS_BLOCK=${NVBENCH_SYS_BLOCK:-/sys/block}
SYS_PCI=${NVBENCH_SYS_PCI:-/sys/bus/pci/devices}
SYS_MODULE=${NVBENCH_SYS_MODULE:-/sys/module/nvrec}
PROC_STAT=${NVBENCH_PROC_STAT:-/proc/stat}
DEV_DIR=${NVBENCH_DEV_DIR:-/dev}

STATE_DIR=/var/lib/nvbench
RESULTS=""
DIR=/mnt/rec
BUDGET_MIN=150
T0_AGO=""
IDLE=60
IDLE_SET=0
# nvverify read rate assumed by the budget: measured ~461 MB/s on the ZCU106's
# Cortex-A53 (10 GiB in ~23 s, 200 GiB in ~8 min), the slowest bench CPU
VERIFY_MBPS=450
DRY=0
LAYOUTS="single1 single2 raid0"
LAYOUT=""
FROM=250
STEP=250
TO=""
FROM_SET=0
STEP_SET=0
STOP_AFTER=1
CONFIRM_FAIL=0
PASSES=1
FILL_RATE=2000
TAG=""
SOURCE_FRESH=0
QD=32
TEMP_MAX=70
TEMP_RESUME=45
TEMP_POLL=10
SIZE=""
RATES=""
CONFIRM=""
RATE=""
CHUNKS=""
QDS="1 2 4 8 16 32 63"
RUNS=2
RING_MB=512
BUFFERS=""
RING_LIST=""
STRIPE_LIST=""
RING=""
STRIPE=""
NOTE=""

usage() {
    cat <<EOF
Usage: nvbench-suite.sh [options] <command> [command options]

Commands:
  info                 print the fixture (drives, links, versions) as JSON
  status               list the results file, per test and layout
  sustained            32 GB sweep: --from --step --to, until --stop-after
                       consecutive failing steps (1)
  glance               4000 MiB sweep + --confirm runs of the top step
  burst                --size (10G) at --rates a,b,.. or a --from/--step sweep
  playback             nvplay sweep of a 10 GB recording + --confirm runs
                       (every sweep ends with a step at the source maximum
                       when the grid misses it)
  fabric               fabric only, no SSD, no layout: nvrec --no-write sweep,
                       --size (64G) per step (needs register map 1.2)
  fabricplay           fabric only: nvplay --ring-only sweep (ring filled once
                       per run, --passes playbacks of it)
  cpu                  record + play at --rate (1000) x --runs (2), CPU figures
  chunk                chunk sizes 128K .. the drives' MDTS (max 4M) at --rate (auto)
  inflight             --qds "$QDS" at --rate (auto)
  longrun              --size (200G) at --rate a,b,.. (MB/s), each on a fresh
                       trimmed volume after --idle (default 600 s here)
  verify [file]        nvverify a recording (default: the last one)
  all                  the whole matrix for --layouts "$LAYOUTS"
  gaps                 per layout of --layouts, only the source-max steps that
                       sweeps ending at the last 250 MB/s grid step below the
                       maximum missed (results of suite version 1): sustained
                       32 GB, burst 10 GB (1 run each), playback (1 + 2
                       confirmations); only where that grid step passed

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
  --from/--step/--to   sweep rates in MB/s (10^6 B/s, default $FROM/$STEP); --to
                       defaults to (and is capped at) the generator maximum
                       (src_clk x beat_bytes, the clock to the nearest MHz:
                       8000 at 250 MHz x 32 B); any requested rate above it
                       runs at the maximum and is stored with rate_req_mbps =
                       the maximum, rate_capped true; a sweep whose grid misses
                       --to ends with a step at --to. 'all' uses them too
                       (default 250/250; its 10 GB burst sweep starts at 500)
  --stop-after <n>     a sweep ends after n consecutive failing steps (default
                       $STOP_AFTER: at the first failure)
  --confirm-fail <n>   extra runs at the first failing step above the top
                       clean step (default $CONFIRM_FAIL)
  --tag <word>         appended to every run id (/tag=<word>) and stored: A/B
                       runs of the same steps (MaxPayload, APST, ...)
  --qd <n>             NVMe commands in flight per SSD for nvrec / nvplay,
                       1..63 (default 32); any other value than 32 is in the
                       run ids (/qd=<n>). Not for 'inflight' (--qds) or the
                       playback source (always 32)
  --temp-max <C>       stop a run when a member drive passes this composite
                       temperature (default $TEMP_MAX, 0 = off; needs the sysfs
                       temperature of driver 1.1); the run is not stored and is
                       repeated once after --temp-resume
  --temp-resume <C>    wait until every member drive is at or below this
                       before repeating (default $TEMP_RESUME)
  --size <bytes>       recording size (nvrec suffixes); per-command default
  --rates <a,b,..>     sustained, glance, burst, playback: run exactly these
                       rates (MB/s), each once, no stop at a failure, each capped
                       at the source maximum; + --confirm <n> repeats of every
                       listed rate when --confirm is given
  --confirm <n>        extra runs at the top clean step (glance, playback: 2;
                       sustained, burst, fabric, fabricplay: 0); with --rates:
                       at every rate (0)
  --rate <MB/s|auto>   cpu / chunk / inflight rate; auto = the layout's
                       highest clean 10 GB burst rate in the results (capped at
                       the source maximum); longrun: one or more rates, a,b,..
                       (MB suffix allowed)
  --chunks "<..>"      chunk sizes for 'chunk' (default: 128K, 256K, .. up to the MDTS)
  --qds "<..>"         SSD_MAX_INFLIGHT values for 'inflight' (1..63)
  --runs <n>           cpu: runs per direction (default $RUNS)
  --ring-mb <MB>       chunk/inflight: ring size kept constant (default $RING_MB;
                       slots = MB / chunk, at most the hardware's slots)
  --buffers <n>        ring slots for every other run, 2..4096 (default: the
                       apps' default, 512 MB of slots, 1 GB split; in the ids
                       as /slots=n)
  --ring <l[,l..]>     ring layout for nvrec / nvplay: single, split, mem1 or
                       auto (register map 1.3); in the ids as /ring=<l>; a
                       list runs the command once per layout (A/B)
  --stripe <s[,s..]>   split-ring stripe: KB (4, 64, ..; power of two up to
                       the chunk) or chunk; in the ids as /stripe=4K; a list
                       runs the command once per stripe; implies --ring split
                       when --ring is not given
  --passes <n>         fabricplay: playbacks of the ring per run (default $PASSES)
  --fill-rate <MB/s>   fabricplay: generator rate of the ring fill before the
                       playbacks (nvplay --fill-rate, default $FILL_RATE); the fill
                       must not drop a beat, so lower it for a slow ring memory
                       (--ring mem1); stored as fill_rate_mbps, not in the ids
  --source-fresh       record the 10 GB playback source again (once per layout
                       in this invocation) even when the one on the volume is
                       still valid for the layout, chunk and beat size
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
        --from) FROM="${2:?}"; FROM_SET=1; shift 2 ;;
        --step) STEP="${2:?}"; STEP_SET=1; shift 2 ;;
        --stop-after) STOP_AFTER="${2:?}"; shift 2 ;;
        --confirm-fail) CONFIRM_FAIL="${2:?}"; shift 2 ;;
        --tag) TAG="${2:?}"; shift 2
            case "$TAG" in *[!A-Za-z0-9._-]*) echo "nvbench-suite: --tag: letters, digits, . _ - only" >&2; exit 2 ;; esac ;;
        --temp-max) TEMP_MAX="${2:?}"; shift 2 ;;
        --temp-resume) TEMP_RESUME="${2:?}"; shift 2 ;;
        --passes) PASSES="${2:?}"; shift 2 ;;
        --fill-rate) FILL_RATE="${2:?}"; FILL_RATE=${FILL_RATE%[Mm][Bb]}; shift 2 ;;
        --source-fresh) SOURCE_FRESH=1; shift ;;
        --qd) QD="${2:?}"; shift 2 ;;
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
            [ "$BUFFERS" -ge 2 ] && [ "$BUFFERS" -le 4096 ] || { echo "nvbench-suite: --buffers must be 2..4096" >&2; exit 2; } ;;
        --ring) RING_LIST="${2:?}"; shift 2
            for v in ${RING_LIST//,/ }; do
                case "$v" in auto|single|split|mem1) ;; *) echo "nvbench-suite: --ring: auto, single, split or mem1 (comma list)" >&2; exit 2 ;; esac
            done ;;
        --stripe) STRIPE_LIST="${2:?}"; shift 2
            for v in ${STRIPE_LIST//,/ }; do
                [ "$v" = chunk ] || v=${v%[Kk]}
                case "$v" in
                    chunk) ;;
                    ''|*[!0-9]*) echo "nvbench-suite: --stripe: KB (power of two, 4..4096) or chunk (comma list)" >&2; exit 2 ;;
                    *) [ "$v" -ge 4 ] && [ "$v" -le 4096 ] && [ $(( v & (v - 1) )) -eq 0 ] || { echo "nvbench-suite: --stripe: KB (power of two, 4..4096) or chunk" >&2; exit 2; } ;;
                esac
            done ;;
        --verify-mbps) VERIFY_MBPS="${2:?}"; shift 2 ;;
        --note) NOTE="${2:?}"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) usage >&2; exit 2 ;;
        *) if [ -z "$CMD" ]; then CMD=$1; else CMD_ARGS+=("$1"); fi; shift ;;
    esac
done
[ -n "$CMD" ] || { usage >&2; exit 2; }
for v in STOP_AFTER CONFIRM_FAIL PASSES TEMP_MAX TEMP_RESUME FROM STEP QD FILL_RATE; do
    case "${!v}" in ''|*[!0-9]*) echo "nvbench-suite: --$(echo "$v" | tr 'A-Z_' 'a-z-') must be a number" >&2; exit 2 ;; esac
done
[ "$STOP_AFTER" -ge 1 ] && [ "$STEP" -ge 1 ] && [ "$PASSES" -ge 1 ] && [ "$FILL_RATE" -ge 1 ] || { echo "nvbench-suite: --stop-after, --step, --passes and --fill-rate must be >= 1" >&2; exit 2; }
[ "$QD" -ge 1 ] && [ "$QD" -le 63 ] || { echo "nvbench-suite: --qd must be 1..63" >&2; exit 2; }
[ -n "$RESULTS" ] || RESULTS=$STATE_DIR/results.jsonl
LOGDIR=$(dirname "$RESULTS")/logs
EVENTS=$(dirname "$RESULTS")/events.log
VOLSTATE=$(dirname "$RESULTS")/volume.state
PS_STATE=$(dirname "$RESULTS")/playsrc.state
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
members_of() { case "$1" in single1) echo nvrec0n1 ;; single2) echo nvrec1n1 ;; raid0) echo "nvrec0n1 nvrec1n1" ;; fabric) echo "" ;; *) die "unknown layout '$1'" ;; esac; }
# PCIe MaxPayload / MaxReadReq of a function (Device Control via setpci, root)
SETPCI=${NVBENCH_SETPCI:-setpci}
pci_ctl() { "$SETPCI" -s "$1" CAP_EXP+8.w 2>/dev/null; }
mps_of_pci() { local v; v=$(pci_ctl "$1"); case "$v" in ''|*[!0-9a-fA-F]*) return 0 ;; esac; echo $(( 128 << ((0x$v >> 5) & 7) )); }
mrrs_of_pci() { local v; v=$(pci_ctl "$1"); case "$v" in ''|*[!0-9a-fA-F]*) return 0 ;; esac; echo $(( 128 << ((0x$v >> 12) & 7) )); }
port_of_pci() { basename "$(dirname "$(readlink -f "$SYS_PCI/$1")")"; }
drive_json() { # <nvrecXn1>
    local d=$1 s=$SYS_BLOCK/$1/nvrec pci link="" rp=""
    pci=$(rd "$s/pci")
    if [ -n "$pci" ] && [ -e "$SYS_PCI/$pci/current_link_speed" ]; then
        link="$(rd "$SYS_PCI/$pci/current_link_speed") x$(rd "$SYS_PCI/$pci/current_link_width")"
    fi
    [ -n "$pci" ] && [ -e "$SYS_PCI/$pci" ] && rp=$(port_of_pci "$pci")
    printf '{"dev":%s,"model":%s,"serial":%s,"firmware":%s,"mdts_bytes":%s,"nr_io_queues":%s,"pci":%s,"link":%s,"mps":%s,"mrrs":%s,"root_port":%s,"rp_mps":%s,"apst":%s,"temperature_warn":%s,"temperature_crit":%s}' \
        "$(jstr "$d")" "$(jstr "$(rd "$s/model")")" "$(jstr "$(rd "$s/serial")")" \
        "$(jstr "$(rd "$s/firmware")")" "$(jnum "$(rd "$s/mdts_bytes")")" \
        "$(jnum "$(rd "$s/nr_io_queues")")" "$(jstr "$pci")" "$(jstr "$link")" \
        "$(jnum "$([ -n "$pci" ] && mps_of_pci "$pci")")" "$(jnum "$([ -n "$pci" ] && mrrs_of_pci "$pci")")" \
        "$(jstr "$rp")" "$(jnum "$([ -n "$rp" ] && mps_of_pci "$rp")")" \
        "$(jstr "$(rd "$s/apst")")" "$(jnum "$(rd "$s/temperature_warn")")" "$(jnum "$(rd "$s/temperature_crit")")"
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
# bytes per fabric beat: the driver's sysfs beat_bytes (driver 1.1: 16, 32 or
# 64), 16 = the 128-bit datapath of drivers without the attribute
BEAT=$(rd "$SYS_NVREC/beat_bytes"); case "$BEAT" in ''|*[!0-9]*) BEAT=16 ;; esac
# the test-pattern generator's maximum rate: src_clk x beat_bytes, from the
# driver's sysfs src_clk_hz, a measured value (249975021 for the 250 MHz
# clock of zcu106_hpc0, 199980011 for 200 MHz) taken to the nearest MHz:
# 250 x 32 = 8000 MB/s on the 256-bit designs, 200 x 16 = 3200 on the 128-bit
# ones; 250 x BEAT when the attribute is missing. nvrec/nvplay clamp a higher
# --rate silently (to the true maximum), so the suite caps every requested
# rate here and records the capped value.
src_max_mbps() { local c; c=$(rd "$SYS_NVREC/src_clk_hz"); [ -n "$c" ] && [ "$c" -gt 0 ] && echo $(( (c + 500000) / 1000000 * BEAT )) || echo $(( 250 * BEAT )); }
SRC_MAX=$(src_max_mbps)
# id suffixes: --buffers (/slots=N), --qd other than 32 (/qd=N), --tag
# (/tag=word); fab_sfx for the fabric-only runs (no NVMe command, no qd)
id_sfx() { echo "${BUFFERS:+/slots=$BUFFERS}$([ "$QD" != 32 ] && echo "/qd=$QD")$(ring_sfx)${TAG:+/tag=$TAG}"; }
fab_sfx() { echo "${BUFFERS:+/slots=$BUFFERS}$(ring_sfx)${TAG:+/tag=$TAG}"; }
# the ring layout of this pass (--ring / --stripe): id suffix, app options
stripe_name() { case "$1" in chunk) echo chunk ;; *) echo "${1}K" ;; esac; }
ring_sfx() { echo "${RING:+/ring=$RING}${STRIPE:+/stripe=$(stripe_name "$STRIPE")}"; }
ring_args() { echo "${RING:+--ring $RING}${STRIPE:+ --stripe $STRIPE}"; }
# hardware slot table (driver 1.2 sysfs max_slots; 2048 before)
MAX_SLOTS=$(rd "$SYS_NVREC/max_slots"); case "$MAX_SLOTS" in ''|*[!0-9]*) MAX_SLOTS=2048 ;; esac
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
        FIXTURE_JSON=$(printf '"target":%s,"board":%s,"kernel":%s,"image":%s,"hw_version":%s,"drv_version":%s,"src_clk_hz":%s,"dp_clk_hz":%s,"beat_bytes":%s,"fifo_depth":%s,"egr_fifo_depth":%s,"apst_param":%s,"ring_ports":%s,"ring1_bytes":%s,"mem1_ready":%s,"ring_split_param":%s,"stripe_kb_param":%s,"ring_stripe_default":%s,"cpus":%s,"drives":[%s]' \
            "$(jstr "$(target_name)")" "$(jstr "$(rd /proc/device-tree/model)")" "$(jstr "$(uname -r)")" \
            "$(jstr "$os")" "$(jstr "$(rd "$SYS_NVREC/version")")" "$(jstr "$(rd "$SYS_MODULE/version")")" \
            "$(jnum "$(rd "$SYS_NVREC/src_clk_hz")")" "$(jnum "$(rd "$SYS_NVREC/dp_clk_hz")")" "$BEAT" \
            "$(jnum "$(rd "$SYS_NVREC/fifo_depth")")" "$(jnum "$(rd "$SYS_NVREC/egr_fifo_depth")")" \
            "$(jnum "$(rd "$SYS_MODULE/parameters/apst")")" \
            "$(jnum "$(rd "$SYS_NVREC/ring_ports")")" "$(jnum "$(rd "$SYS_NVREC/ring1_bytes")")" \
            "$(jnum "$(rd "$SYS_NVREC/mem1_ready")")" "$(jstr "$(rd "$SYS_MODULE/parameters/ring_split")")" \
            "$(jstr "$(rd "$SYS_MODULE/parameters/stripe_kb")")" "$(jstr "$(rd "$SYS_NVREC/ring_stripe_default")")" \
            "$(grep -c '^cpu[0-9]' "$PROC_STAT")" "${drives#,}")
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

# ---------------------------------------------------------------- temperature
# temp_of <layout>: the hottest member drive's composite temperature (C),
# empty when no member reports one (driver before 1.1, fabric runs)
temp_of() {
    local d t max=""
    [ "$1" = fabric ] && return 0
    for d in $(members_of "$1"); do
        t=$(rd "$SYS_BLOCK/$d/nvrec/temperature")
        case "$t" in ''|*[!0-9-]*) continue ;; esac
        if [ -z "$max" ] || [ "$t" -gt "$max" ]; then max=$t; fi
    done
    echo "$max"
}
wnap() { if [ "$TEST" = 1 ]; then sleep 0.1; else sleep "$1"; fi; }
# cool_wait <layout> [trigger C]: when the hottest member is above the
# trigger (default --temp-max), wait until every member is at or below
# --temp-resume (the budget still applies: exit 3 when it runs out while
# waiting). Before every run with the default trigger; after a temperature
# stop with --temp-resume as the trigger.
cool_wait() {
    local t
    [ "$TEMP_MAX" -gt 0 ] && [ "$DRY" -eq 0 ] || return 0
    t=$(temp_of "$1"); [ -n "$t" ] || return 0
    [ "$t" -gt "${2:-$TEMP_MAX}" ] || return 0
    say "drives at $t C: waiting for <= $TEMP_RESUME C"
    while t=$(temp_of "$1"); [ -n "$t" ] && [ "$t" -gt "$TEMP_RESUME" ]; do
        budget_ok 60
        wnap 10
    done
    say "drives at ${t:-?} C: continuing"
}
# temp_watch <layout> <app name> <flag file>: while the flag file exists, the
# hottest member's temperature every TEMP_POLL (10) s into <flag>.max; above
# --temp-max: <flag>.over and SIGINT to the app (a clean stop)
temp_watch() {
    local t m=""
    while [ -e "$3" ]; do
        t=$(temp_of "$1")
        if [ -n "$t" ]; then
            if [ -z "$m" ] || [ "$t" -gt "$m" ]; then m=$t; echo "$m" >"$3.max"; fi
            if [ "$TEMP_MAX" -gt 0 ] && [ "$t" -gt "$TEMP_MAX" ]; then
                echo "$t" >"$3.over"
                pkill -INT -x "$2"
                break
            fi
        fi
        wnap "$TEMP_POLL"
    done
}
# run_app <layout> <log> <cmd...>: run an app (time -p, RC= in its log) with
# the temperature watch; sets APP_TIME (time -p output), TEMP_START, TEMP_END,
# TEMP_MAX_SEEN (the hottest sample incl. start and end; C or empty) and
# TEMP_OVER (C when the run was stopped)
run_app() {
    local l=$1 log=$2 flag wpid="" t
    shift 2
    flag=$LOGDIR/.tempwatch.$$
    rm -f "$flag" "$flag.max" "$flag.over"
    TEMP_START=$(temp_of "$l"); TEMP_END=""; TEMP_MAX_SEEN=""; TEMP_OVER=""
    if [ -n "$TEMP_START" ]; then
        : >"$flag"
        # 9>&-: the watcher (and its sleep, which can outlive a kill of
        # the subshell by up to TEMP_POLL s) must not hold the suite lock
        temp_watch "$l" "$1" "$flag" 9>&- &
        wpid=$!
    fi
    APP_TIME=$( { time -p "$@" >"$log" 2>&1; echo "RC=$?" >>"$log"; } 2>&1 )
    if [ -n "$wpid" ]; then
        rm -f "$flag"
        kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null
        TEMP_MAX_SEEN=$(cat "$flag.max" 2>/dev/null)
        TEMP_OVER=$(cat "$flag.over" 2>/dev/null)
        rm -f "$flag.max" "$flag.over"
        TEMP_END=$(temp_of "$l")
        for t in "$TEMP_START" "$TEMP_END"; do
            [ -n "$t" ] || continue
            if [ -z "$TEMP_MAX_SEEN" ] || [ "$t" -gt "$TEMP_MAX_SEEN" ]; then TEMP_MAX_SEEN=$t; fi
        done
    fi
    return 0
}
temp_json() { printf '"temp_start_c":%s,"temp_end_c":%s,"temp_max_c":%s' "$(jnum "$TEMP_START")" "$(jnum "$TEMP_END")" "$(jnum "$TEMP_MAX_SEEN")"; }
# temp_stopped <id> <layout>: the run was stopped over temperature: not
# stored; 0 = cooled down, repeat it; exit 4 when it happened twice
temp_stopped() {
    say "  drive at $TEMP_OVER C > $TEMP_MAX C: run stopped, not stored"
    echo "$(date -Is) temperature stop ($TEMP_OVER C) in '$1'" >>"$EVENTS"
    if [ "${TEMP_RETRY_ID:-}" = "$1" ]; then
        say "second over-temperature on '$1': stopping (cool the drives, then re-run)"
        exit 4
    fi
    TEMP_RETRY_ID=$1
    cool_wait "$2" "$TEMP_RESUME"
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
    # a fresh volume: the playback source on the old one is gone
    rm -f "$PS_STATE"
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
# the requested count), "buffers_req" = --buffers given (null = app default);
# the ring layout used (ring, stripe_kb, ring_mem1_bytes; apps 1.2) and the
# one asked for (ring_req / stripe_req, null = default); the ring ports'
# wait times (register map 1.3, ms per memory)
jarr() { case "${1:-}" in '') printf 'null' ;; *) printf '[%s]' "$1" ;; esac; }
ring_json() { # <app log> <requested slots|"">
    local rs; rs=$(res_get "$1" ring_slots); [ -n "$rs" ] || rs=$2
    printf '"mps":%s,"buffers":%s,"buffers_req":%s,"ring_slots":%s,"ring_bytes":%s,"ring":%s,"stripe_kb":%s,"ring_mem1_bytes":%s,"ring_req":%s,"stripe_req":%s,"wr_port_stall_ms":%s,"rd_port_wait_ms":%s' \
        "$(m=$(res_get "$1" mps); case "$m" in ''|0) printf null ;; *) printf '%s' "$m" ;; esac)" \
        "$(jnum "$rs")" "$(jnum "$2")" \
        "$(jnum "$(res_get "$1" ring_slots)")" "$(jnum "$(res_get "$1" ring_bytes)")" \
        "$(r=$(res_get "$1" ring); [ -n "$r" ] && jstr "$r" || printf null)" \
        "$(jnum "$(res_get "$1" stripe_kb)")" "$(jnum "$(res_get "$1" ring_mem1_bytes)")" \
        "$([ -n "$RING" ] && jstr "$RING" || printf null)" "$([ -n "$STRIPE" ] && jstr "$STRIPE" || printf null)" \
        "$(jarr "$(res_get "$1" wr_port_stall_ms)")" "$(jarr "$(res_get "$1" rd_port_wait_ms)")"
}
# nvverify 1.1 reports 16-byte words: "GAP at word N (file offset X)",
# "discontinuities D, words missing W (B beats...)", "corrupted words C"
verify_json() { # <rc> <nvverify log> <seconds>
    local first
    first=$(sed -n 's/^GAP at \(word\|beat\) [0-9]* (file offset \([0-9]*\)).*/\2/p' "$2" | head -n1)
    printf '"verify":{"rc":%s,"result":%s,"discontinuities":%s,"words_missing":%s,"beats_missing":%s,"corrupted":%s,"first_gap_offset":%s,"seconds":%s}' \
        "$1" "$(jstr "$(sed -n 's/^RESULT //p' "$2" | tail -n1)")" \
        "$(jnum "$(sed -n 's/^  discontinuities \([0-9]*\).*/\1/p' "$2")")" \
        "$(jnum "$(sed -n 's/.*words missing \([0-9]*\) .*/\1/p' "$2")")" \
        "$(jnum "$(sed -n 's/.*words missing [0-9]* (\([0-9]*\) beats.*/\1/p' "$2")")" \
        "$(jnum "$(sed -n 's/^  corrupted \(words\|beats\) \([0-9]*\).*/\2/p' "$2")")" "$(jnum "$first")" "$3"
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
    local log vlog rc vrc s0 s1 t pass vt0 vt1 achieved st capped=false args=("$@")
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
    cool_wait "$l"
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
    # shellcheck disable=SC2046
    run_app "$l" "$log" nvrec --rate "${rate}MB" --size "$bytes" --chunk "$chunk" --qd "$qd" \
        ${slots:+--buffers "$slots"} $(ring_args) --stats 0 --force "$f"
    t=$APP_TIME
    s1=$(cpusnap)
    rc=$(sed -n 's/^RC=//p' "$log" | tail -n1)
    if [ "$rc" = 5 ]; then ha_check; exit 5; fi
    if [ -n "$TEMP_OVER" ]; then
        rm -f "$f"; temp_stopped "$id" "$l"
        rec_run "${args[@]}"; return
    fi
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
    emit "$id" "$test" "$l" "$(printf '"direction":"record","size_bytes":%s,"rate_req_mbps":%s,"rate_capped":%s,"rate_mbps":%s,"seconds":%s,"bytes":%s,"chunk":%s,"qd":%s,%s,"prep":%s,"idle_s":%s,"exit":%s,"pass":%s,"drops":%s,"nvme_errors":%s,"fifo_hwm":%s,"fifo_depth":%s,"beat_bytes":%s,"tag":%s,%s,%s,%s,%s' \
        "$bytes" "$rate" "$capped" "$achieved" "$(jnum "$(res_get "$log" seconds)")" "$(jnum "$(res_get "$log" bytes)")" \
        "$chunk" "$qd" "$(ring_json "$log" "$slots")" "$(jstr "$([ "$prep" = trim ] && echo 'blkdiscard+mkfs.exfat' || echo 'rm+sync')")" \
        "$([ "$prep" = trim ] && echo "$IDLE" || echo 10)" "$(jnum "$rc")" "$pass" \
        "$(jnum "$(res_get "$log" drops)")" "$(jnum "$(res_get "$log" nvme_errors)")" \
        "$(jnum "$(res_get "$log" fifo_hwm)")" "$(jnum "$(res_get "$log" fifo_depth)")" \
        "$(jnum "$(res_get "$log" beat_bytes)")" "$(jstr "$TAG")" "$(temp_json)" \
        "$st" "$(verify_json "$vrc" "$vlog" "$(awk -v a="$vt0" -v b="$vt1" 'BEGIN{printf "%.1f", b - a}')")" \
        "$(cpu_json "$s0" "$s1" "$t")")${REC_EXTRA:+,$REC_EXTRA}"
    say "  -> rc=$rc verify=$(sed -n 's/^RESULT //p' "$vlog" | tail -n1) pass=$pass ($achieved MB/s)"
    [ "$pass" = true ]
}

# play_run <id> <test> <layout> <rate> <file> <qd> <slots|"">  (0 = clean)
play_run() {
    local id=$1 test=$2 l=$3 rate=$4 f=$5 qd=$6 slots=$7
    local log rc s0 s1 t pass bytes capped=false args=("$@")
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
    cool_wait "$l"
    bytes=$(stat -c %s "$f" 2>/dev/null || echo 0)
    budget_ok "$(est_rec "$bytes" "$rate" 0)"
    sync; echo 3 2>/dev/null >/proc/sys/vm/drop_caches; nap 5
    say "play $id"
    s0=$(cpusnap)
    # shellcheck disable=SC2046
    run_app "$l" "$log" nvplay --rate "${rate}MB" --qd "$qd" ${slots:+--buffers "$slots"} $(ring_args) --stats 0 "$f"
    t=$APP_TIME
    s1=$(cpusnap)
    rc=$(sed -n 's/^RC=//p' "$log" | tail -n1)
    if [ "$rc" = 5 ]; then ha_check; exit 5; fi
    if [ -n "$TEMP_OVER" ]; then
        temp_stopped "$id" "$l"
        play_run "${args[@]}"; return
    fi
    if [ "$rc" != 0 ] && [ "$rc" != 2 ] && ! grep -q '^RESULT ' "$log"; then
        die "nvplay failed before playing (rc $rc), not stored as a result: see $log"
    fi
    pass=false; [ "$rc" = 0 ] && pass=true
    emit "$id" "$test" "$l" "$(printf '"direction":"play","file_bytes":%s,"rate_req_mbps":%s,"rate_capped":%s,"rate_mbps":%s,"seconds":%s,"bytes":%s,"qd":%s,%s,"exit":%s,"pass":%s,"underflows":%s,"chk_errors":%s,"gaps":%s,"gap_beats":%s,"drop_count":%s,"beats":%s,"complete":%s,"nvme_errors":%s,"prefill_s":%s,"beat_bytes":%s,"file_beat_bytes":%s,"tag":%s,%s,%s,%s' \
        "$bytes" "$rate" "$capped" \
        "$(awk -v b="$(res_get "$log" bytes)" -v s="$(res_get "$log" seconds)" 'BEGIN { if (s > 0) printf "%.1f", b / s / 1e6; else print "null" }')" \
        "$(jnum "$(res_get "$log" seconds)")" "$(jnum "$(res_get "$log" bytes)")" "$qd" "$(ring_json "$log" "$slots")" "$(jnum "$rc")" "$pass" \
        "$(jnum "$(res_get "$log" underflows)")" "$(jnum "$(res_get "$log" errors)")" "$(jnum "$(res_get "$log" gaps)")" \
        "$(jnum "$(res_get "$log" gap_beats)")" "$(jnum "$(res_get "$log" drop_count)")" "$(jnum "$(res_get "$log" beats)")" \
        "$(jnum "$(res_get "$log" complete)")" "$(jnum "$(res_get "$log" nvme_errors)")" "$(jnum "$(res_get "$log" prefill_seconds)")" \
        "$(jnum "$(res_get "$log" beat_bytes)")" "$(jnum "$(res_get "$log" file_beat_bytes)")" "$(jstr "$TAG")" "$(temp_json)" \
        "$(stats_json "$log")" "$(cpu_json "$s0" "$s1" "$t")")"
    say "  -> rc=$rc underflows=$(res_get "$log" underflows) pass=$pass"
    [ "$pass" = true ]
}

# ---------------------------------------------------------------- tests
fx() { echo "$1-$(chunk_name "$2"):$(serials_of "$1")"; }   # layout tag in ids
need_layout() { [ -n "$LAYOUT" ] && [ "$LAYOUT" != fabric ] || die "$CMD needs --layout single1|single2|raid0"; members_of "$LAYOUT" >/dev/null; }
top_rate() { [ -n "$TO" ] && cap_rate "$TO" || echo "$SRC_MAX"; }   # sweeps skip steps above the source max
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
            rec_run "$test/$(fx "$l" "$c")/size=$bytes/rate=$r$(run_sfx "$i")$(id_sfx)" "$test" "$l" "$bytes" "$r" "$c" "$QD" "$BUFFERS" "$prep" \
                && [ "$(cap_rate "$r")" -gt "$best" ] && best=$(cap_rate "$r")
        done
    done
    SWEEP_BEST=$best
}

# gsweep <runner> <from> <step> <to> <confirm>: the sweep logic of every
# command. Rates from..to, the last step AT <to> when the grid misses it
# (.., 7500, 7750, 8000 / .., 3000, 3200), until --stop-after consecutive
# failing steps (1: the first failure ends it); then <confirm> repeats of the
# top clean step and --confirm-fail repeats of the first failing step above
# it. "<runner> <rate> <run#>" runs one step (run# > 1 = a repeat), 0 = clean.
# SWEEP_BEST = the top clean rate (0 = none), SWEEP_FAIL = the first failing
# step above it (0 = none).
gsweep() {
    local fn=$1 r=$2 step=$3 to=$4 confirm=$5 best=0 fails=0 failed="" ff=0 i f
    while [ "$r" -le "$to" ]; do
        if "$fn" "$r" 1; then
            best=$r; fails=0
        else
            fails=$(( fails + 1 )); failed="$failed $r"
            [ "$fails" -ge "$STOP_AFTER" ] && break
        fi
        [ "$r" -ge "$to" ] && break
        # one more step at <to> when the grid misses it
        if [ $(( r + step )) -gt "$to" ]; then r=$to; else r=$(( r + step )); fi
    done
    for f in $failed; do
        if [ "$f" -gt "$best" ]; then ff=$f; break; fi
    done
    for i in $(seq 2 $(( confirm + 1 ))); do
        [ "$best" -gt 0 ] || break
        "$fn" "$best" "$i" || true
    done
    for i in $(seq 2 $(( CONFIRM_FAIL + 1 ))); do
        [ "$ff" -gt 0 ] || break
        "$fn" "$ff" "$i" || true
    done
    SWEEP_BEST=$best; SWEEP_FAIL=$ff
}

# sweep <test> <layout> <bytes> <from> <step> <to> <prep> <confirm>: nvrec
# recordings (+ nvverify) as gsweep steps
sweep() {
    SW_TEST=$1; SW_L=$2; SW_BYTES=$3; SW_PREP=$7; SW_C=$(default_chunk "$2")
    gsweep sweep_step "$4" "$5" "$6" "$8"
}
sweep_step() { # <rate> <run#>
    rec_run "$SW_TEST/$(fx "$SW_L" "$SW_C")/size=$SW_BYTES/rate=$1$(run_sfx "$2")$(id_sfx)" \
        "$SW_TEST" "$SW_L" "$SW_BYTES" "$1" "$SW_C" "$QD" "$BUFFERS" "$SW_PREP"
}

t_sustained() {
    need_layout
    local bytes; bytes=$(to_bytes "${SIZE:-32G}")
    if [ -n "$RATES" ]; then rates_rec sustained "$LAYOUT" "$bytes" trim
    else sweep sustained "$LAYOUT" "$bytes" "$FROM" "$STEP" "$(top_rate)" trim "${CONFIRM:-0}"; fi
    say "sustained ($LAYOUT): highest clean step $SWEEP_BEST MB/s"
}
t_glance() {
    need_layout
    local bytes; bytes=$(to_bytes "${SIZE:-4000M}")
    if [ -n "$RATES" ]; then rates_rec glance "$LAYOUT" "$bytes" none
    else sweep glance "$LAYOUT" "$bytes" "$FROM" "$STEP" "$(top_rate)" none "${CONFIRM:-2}"; fi
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
    cap_rate "$r"
}
# The playback source: a 10 GB recording at 1000 MB/s (qd 32) on a fresh
# volume (the recorder's playback method). It is reused only while it is
# valid for what is being played: the mounted volume is this layout's
# (volume.state), playsrc.state names this layout, chunk, fabric beat, qd,
# path and size, and the file is a complete, drop-free test-pattern
# recording of that size, chunk and beat size (nvverify --header-only;
# a 512-bit image never plays a source recorded with 32-byte beats).
# Otherwise it is recorded again, under a new id (/ts=<epoch>: a source
# recorded earlier, in this boot or not, never blocks a new one).
# --source-fresh records it again once per layout in this invocation.
playsrc_valid() { # <layout> <chunk> <bytes>
    local l=$1 c=$2 sbytes=$3 h off size
    [ "$(cat "$PS_STATE" 2>/dev/null)" = "$l $c $BEAT 32 $PLAYSRC $sbytes" ] || return 1
    [ -f "$PLAYSRC" ] || return 1
    h=$(nvverify --header-only "$PLAYSRC" 2>/dev/null)
    echo "$h" | grep -q "(test pattern, complete)" || return 1
    echo "$h" | grep -q "^  header .* $BEAT-byte beats\$" || return 1
    echo "$h" | grep -q '^  drop_count *0\( beats\)\?$' || return 1
    echo "$h" | grep -q "^  data_bytes *$sbytes\$" || return 1
    echo "$h" | grep -q "^  chunk / members $c bytes /" || return 1
    off=$(echo "$h" | sed -n 's/^  header .*, data at \([0-9]*\),.*/\1/p')
    size=$(stat -c %s "$PLAYSRC" 2>/dev/null)
    [ -n "$off" ] && [ "$size" = "$(( off + sbytes ))" ]
}
ensure_playsrc() { # <layout> <chunk>
    # the source is recorded with the default ring (RING / STRIPE local: unset
    # for the recording below, the file does not depend on them)
    local l=$1 c=$2 sbytes RING="" STRIPE=""; sbytes=$(to_bytes 10G)
    [ "$DRY" -eq 1 ] && [ -n "${PLAYSRC_OK:-}" ] && return 0
    if [ "$DRY" -eq 0 ] && { [ "$SOURCE_FRESH" = 0 ] || [[ " $FRESH_DONE " == *" $l:$c "* ]]; } && \
       mount_volume "$l" "$c" && playsrc_valid "$l" "$c" "$sbytes"; then
        return 0
    fi
    [ "$DRY" -eq 0 ] && rm -f "$PS_STATE"
    rec_run "playsrc/$(fx "$l" "$c")/size=$sbytes/rate=1000/beat=$BEAT/qd=32/ts=$(now_s)" playsrc "$l" "$sbytes" 1000 "$c" 32 "$BUFFERS" trim "$PLAYSRC" \
        || die "playback source recording failed"
    [ "$DRY" -eq 0 ] && echo "$l $c $BEAT 32 $PLAYSRC $sbytes" >"$PS_STATE"
    FRESH_DONE="$FRESH_DONE $l:$c"
    PLAYSRC_OK=1
}
play_id() { echo "playback/$(fx "$1" "$2")/size=$(to_bytes 10G)/rate=$3${4:+/run=$4}$(id_sfx)"; }
run_sfx() { [ "$1" -gt 1 ] && echo "/run=$1"; }
# play1 <layout> <chunk> <rate> [run]: one playback (the source recorded first
# when the run is not in the results yet); 0 = clean
play1() {
    local id cr; id=$(play_id "$1" "$2" "$3" "${4:-}"); cr=$(cap_rate "$3")
    have "$(cap_id "$id" "$3" "$cr")" || ensure_playsrc "$1" "$2"
    play_run "$id" playback "$1" "$3" "$PLAYSRC" "$QD" "$BUFFERS"
}
# play_sweep <layout> <from> <step> <to> <confirm>: as sweep(), for nvplay
play_sweep() {
    PS_L=$1; PS_C=$(default_chunk "$1"); PLAYSRC_OK=""
    gsweep play_step "$2" "$3" "$4" "$5"
}
play_step() { play1 "$PS_L" "$PS_C" "$1" "$([ "$2" -gt 1 ] && echo "$2")"; }
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
        rec_run "cpu/$(fx "$LAYOUT" "$c")/size=$bytes/rate=$r/run=$i$(id_sfx)" cpu "$LAYOUT" "$bytes" "$r" "$c" "$QD" "$BUFFERS" none "$DIR/cpu.dat" || true
        [ "$DRY" -eq 0 ] && rm -f "$DIR/cpu.dat" && nap 20
        id="cpuplay/$(fx "$LAYOUT" "$c")/size=$(to_bytes 10G)/rate=$r/run=$i$(id_sfx)"
        have "$id" || ensure_playsrc "$LAYOUT" "$c"
        play_run "$id" cpuplay "$LAYOUT" "$r" "$PLAYSRC" "$QD" "$BUFFERS" || true
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
        slots=$(( RING_MB * 1048576 / c )); [ "$slots" -gt "$MAX_SLOTS" ] && slots=$MAX_SLOTS
        rec_run "chunk/$(fx "$LAYOUT" "$c")/size=$bytes/rate=$r/chunk=$c/slots=$slots$([ "$QD" != 32 ] && echo "/qd=$QD")$(ring_sfx)${TAG:+/tag=$TAG}" chunk "$LAYOUT" "$bytes" "$r" "$c" "$QD" "$slots" trim || true
    done
}
t_inflight() {
    need_layout
    local c q r bytes slots
    c=$(default_chunk "$LAYOUT"); r=$(auto_rate "$LAYOUT"); bytes=$(to_bytes "${SIZE:-10G}")
    slots=$(( RING_MB * 1048576 / c )); [ "$slots" -gt "$MAX_SLOTS" ] && slots=$MAX_SLOTS
    for q in $QDS; do
        [ "$q" -ge 1 ] && [ "$q" -le 63 ] || { say "qd $q outside 1..63: skipped"; continue; }
        rec_run "inflight/$(fx "$LAYOUT" "$c")/size=$bytes/rate=$r/qd=$q$(ring_sfx)${TAG:+/tag=$TAG}" inflight "$LAYOUT" "$bytes" "$r" "$c" "$q" "$slots" trim || true
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
        rec_run "longrun/$(fx "$LAYOUT" "$c")/size=$bytes/rate=$r/idle=$IDLE$(id_sfx)" longrun "$LAYOUT" "$bytes" "$r" "$c" "$QD" "$BUFFERS" trim || true
    done
    REC_EXTRA=""
}
# ---------------------------------------------------------------- fabric only
# fab_run <id> <test> <rec|play> <rate>: one fabric-only run (no SSD, no
# volume): nvrec --no-write of --size, or nvplay --ring-only (--passes)
fab_run() {
    local id=$1 test=$2 kind=$3 rate=$4 log rc s0 s1 t pass capped=false est
    if [ "$rate" -gt "$SRC_MAX" ]; then
        id=$(cap_id "$id" "$rate" "$SRC_MAX"); say "  rate $rate MB/s > source max $SRC_MAX MB/s: capped ($id)"; rate=$SRC_MAX; capped=true
    fi
    log=$LOGDIR/$(echo "$id" | tr '/:+=' '____').log
    CUR_ID=$id
    if [ "$kind" = rec ]; then est=$(( FB_BYTES * 3 / 2 / (rate * 1000000) + 10 )); else est=$(( 10 + PASSES )); fi
    if have "$id"; then
        [ "$DRY" -eq 1 ] && echo "  skip $id ($(field "$id" pass))"
        passed "$id"; return
    fi
    if [ "$DRY" -eq 1 ]; then
        echo "  RUN  $id (~$est s)"; DRY_EST=$(( DRY_EST + est ))
        [ "$rate" -le "$DRY_MAXRATE" ]; return
    fi
    budget_ok "$est"
    say "fabric $kind $id"
    s0=$(cpusnap)
    # shellcheck disable=SC2046
    if [ "$kind" = rec ]; then
        run_app fabric "$log" nvrec --no-write --rate "${rate}MB" --size "$FB_BYTES" ${BUFFERS:+--buffers "$BUFFERS"} $(ring_args) --stats 0
    else
        run_app fabric "$log" nvplay --ring-only --rate "${rate}MB" --passes "$PASSES" --fill-rate "${FILL_RATE}MB" \
            ${BUFFERS:+--buffers "$BUFFERS"} $(ring_args) --stats 0
    fi
    t=$APP_TIME
    s1=$(cpusnap)
    rc=$(sed -n 's/^RC=//p' "$log" | tail -n1)
    if [ "$rc" != 0 ] && [ "$rc" != 2 ] && ! grep -q '^RESULT ' "$log"; then
        die "$test failed before running (rc $rc), not stored as a result: see $log"
    fi
    pass=false; [ "$rc" = 0 ] && pass=true
    emit "$id" "$test" fabric "$(printf '"direction":%s,"fabric_only":true,"size_bytes":%s,"rate_req_mbps":%s,"rate_capped":%s,"rate_mbps":%s,"seconds":%s,"bytes":%s,"chunk":%s,%s,"exit":%s,"pass":%s,"drops":%s,"fifo_hwm":%s,"fifo_depth":%s,"underflows":%s,"chk_errors":%s,"gaps":%s,"gap_beats":%s,"beats":%s,"complete":%s,"passes":%s,"fill_rate_mbps":%s,"fill_rate_bps":%s,"prefill_s":%s,"beat_bytes":%s,"tag":%s,%s' \
        "$(jstr "$([ "$kind" = rec ] && echo record || echo play)")" "$([ "$kind" = rec ] && echo "$FB_BYTES" || echo null)" \
        "$rate" "$capped" \
        "$(awk -v b="$(res_get "$log" bytes)" -v s="$(res_get "$log" seconds)" 'BEGIN { if (s > 0) printf "%.1f", b / s / 1e6; else print "null" }')" \
        "$(jnum "$(res_get "$log" seconds)")" "$(jnum "$(res_get "$log" bytes)")" "$(jnum "$(res_get "$log" chunk)")" \
        "$(ring_json "$log" "$BUFFERS")" "$(jnum "$rc")" "$pass" \
        "$(jnum "$(res_get "$log" drops)")" "$(jnum "$(res_get "$log" fifo_hwm)")" "$(jnum "$(res_get "$log" fifo_depth)")" \
        "$(jnum "$(res_get "$log" underflows)")" "$(jnum "$(res_get "$log" errors)")" "$(jnum "$(res_get "$log" gaps)")" \
        "$(jnum "$(res_get "$log" gap_beats)")" "$(jnum "$(res_get "$log" beats)")" "$(jnum "$(res_get "$log" complete)")" \
        "$(jnum "$(res_get "$log" passes)")" "$([ "$kind" = rec ] && echo null || echo "$FILL_RATE")" \
        "$(jnum "$(res_get "$log" fill_rate_bps)")" "$(jnum "$(res_get "$log" prefill_seconds)")" \
        "$(jnum "$(res_get "$log" beat_bytes)")" "$(jstr "$TAG")" "$(cpu_json "$s0" "$s1" "$t")")"
    if [ "$kind" = rec ]; then
        say "  -> rc=$rc drops=$(res_get "$log" drops) pass=$pass"
    else
        say "  -> rc=$rc underflows=$(res_get "$log" underflows) errors=$(res_get "$log" errors) pass=$pass"
    fi
    [ "$pass" = true ]
}
fab_rec_step() { fab_run "fabric/dry/size=$FB_BYTES/rate=$1$(run_sfx "$2")$(fab_sfx)" fabric rec "$1"; }
fab_play_step() { fab_run "fabricplay/dry/passes=$PASSES/rate=$1$(run_sfx "$2")$(fab_sfx)" fabricplay play "$1"; }
fab_sweep() { # <runner>
    local fn=$1 r i best=0
    if [ -n "$RATES" ]; then
        for r in $(rate_list); do
            for i in $(seq 1 $(( ${CONFIRM:-0} + 1 ))); do
                "$fn" "$r" "$i" && [ "$(cap_rate "$r")" -gt "$best" ] && best=$(cap_rate "$r")
            done
        done
        SWEEP_BEST=$best
    else
        gsweep "$fn" "$FROM" "$STEP" "$(top_rate)" "${CONFIRM:-0}"
    fi
}
t_fabric() {
    FB_BYTES=$(to_bytes "${SIZE:-64G}")
    fab_sweep fab_rec_step
    say "fabric record (no SSD, $FB_BYTES bytes): highest clean step $SWEEP_BEST MB/s"
}
t_fabricplay() {
    fab_sweep fab_play_step
    say "fabric ring-resident playback (no SSD, $PASSES pass(es)): highest clean step $SWEEP_BEST MB/s"
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
    local l s40 best r f0=250 st0=250 fb=500
    # --from / --step given: the floor and grid of every sweep (the burst
    # sweep starts at 500 otherwise, as the recorder's)
    [ "$FROM_SET" = 1 ] && { f0=$FROM; fb=$FROM; }
    [ "$STEP_SET" = 1 ] && st0=$STEP
    for l in $LAYOUTS; do
        LAYOUT=$l
        layout_ok "$l" || continue
        say "=== layout $l ($(serials_of "$l"))"
        FROM=$f0; STEP=$st0; SIZE=""; RATES=""; CONFIRM=""; RATE=""
        t_sustained
        best=$SWEEP_BEST
        t_glance
        FROM=$fb; SIZE=10G; t_burst; SIZE=""; FROM=$f0
        # 40 GB at the sustained rate and the next step (the recorder's 40 GB rows)
        # (the next step capped at the source max; skipped when that is no step up)
        s40=$best; [ "$s40" -gt 0 ] || s40=$f0
        r=$(( s40 + st0 )); RATES=$s40; [ "$(cap_rate "$r")" -gt "$(cap_rate "$s40")" ] && RATES="$s40,$r"
        SIZE=40G; t_burst; SIZE=""; RATES=""
        t_playback
        t_cpu
        RATE=auto; t_chunk; t_inflight; RATE=""
    done
    say "matrix complete for: $LAYOUTS"
}

# gaps: results from suites whose sweeps ended at the last 250-grid step
# below the maximum (3000 of 3200 with suite version 1 on the 128-bit
# designs) get the final step at the source maximum that 'all' now runs: per
# layout the 32 GB sustained, the 10 GB burst (from 500, as in 'all') and the
# playback sweeps, each continued from its last grid step -- only where that
# step is in the results and passed (a sweep that failed earlier ended there,
# as it would now). The ids are those 'all' produces (resume skips them); the
# 4000 MiB glance sweep is not continued.
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
    # -w 15: a child of the previous call (a watcher sleep) may still hold
    # the lock for a few seconds after it exited
    flock -w 15 9 || die "another nvbench-suite is running"
    trap 'echo $? >"$(dirname "$RESULTS")/last_exit"' EXIT
    echo "$(date -Is) start: $CMD layout=${LAYOUT:-$LAYOUTS} budget=${BUDGET_MIN}min left=$(left_s)s" >>"$EVENTS"
fi
DRY_MAXRATE=${NVBENCH_DRY_MAXRATE:-1500}   # dry run: pretend rates up to this pass
CUR_ID=""
SWEEP_BEST=0
SWEEP_FAIL=0
FRESH_DONE=""
FB_BYTES=0
TEMP_RETRY_ID=""
DRY_EST=0
REC_EXTRA=""
[ "$DRY" -eq 1 ] && say "dry run: deadline in $(left_s) s; results $RESULTS"

run_cmd() {
    case "$CMD" in
        sustained) t_sustained ;;
        glance) t_glance ;;
        burst) t_burst ;;
        playback) t_playback ;;
        cpu) t_cpu ;;
        chunk) t_chunk ;;
        inflight) t_inflight ;;
        longrun) t_longrun ;;
        fabric) t_fabric ;;
        fabricplay) t_fabricplay ;;
        all) t_all ;;
        gaps) t_gaps ;;
        *) usage >&2; exit 2 ;;
    esac
}
case "$CMD" in
    info) t_info ;;
    status) t_status ;;
    verify) t_verify; exit $? ;;
    *)
        # --ring / --stripe lists: the command once per combination (A/B);
        # a stripe only with split (--stripe alone = split), a non-split
        # layout once without one
        [ -n "$STRIPE_LIST" ] && [ -z "$RING_LIST" ] && RING_LIST=split
        ab_rings=${RING_LIST:-_}
        # the options every pass starts from ('all' / 'gaps' / longrun change them)
        ab_save="$FROM|$STEP|$SIZE|$RATES|$CONFIRM|$RATE|$LAYOUT|$IDLE"
        for RING in ${ab_rings//,/ }; do
            [ "$RING" = _ ] && RING=""
            if [ "$RING" = split ] && [ -n "$STRIPE_LIST" ]; then
                ab_stripes=$STRIPE_LIST
            else
                ab_stripes=_
            fi
            for STRIPE in ${ab_stripes//,/ }; do
                [ "$STRIPE" = _ ] && STRIPE=""
                [ "$STRIPE" = chunk ] || STRIPE=${STRIPE%[Kk]}
                IFS='|' read -r FROM STEP SIZE RATES CONFIRM RATE LAYOUT IDLE <<<"$ab_save"
                [ -n "$RING$STRIPE" ] && say "=== ring ${RING:-default}${STRIPE:+, stripe $(stripe_name "$STRIPE")}"
                SWEEP_BEST=0; SWEEP_FAIL=0
                run_cmd
            done
        done
        ;;
esac
[ "$DRY" -eq 1 ] && say "dry run: the runs marked RUN need ~$(( DRY_EST / 60 )) min (estimate; budget ${BUDGET_MIN} min per session)"
[ "$DRY" -eq 0 ] && [ "$CMD" != info ] && [ "$CMD" != status ] && \
    echo "$(date -Is) done: $CMD layout=${LAYOUT:-$LAYOUTS}" >>"$EVENTS"
exit 0
