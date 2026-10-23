#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
#
# nvbench.sh -- sustained recording rate sweep (port of fpga-drive-recorder's
# fdbench.sh: same method and table, so the two designs compare directly).
#
# Records a fixed amount of test-pattern data at increasing generator rates
# with the hardware recorder (nvrec), verifies every recording with nvverify,
# and prints rate vs. pass/fail vs. drop count vs. FIFO high-water mark. The
# highest passing rate is the sustained recording rate of this board + SSD
# (+ RAID0) combination.
#
# Default sweep: 500 MB/s steps from 500 up to the generator maximum,
# src_clk x beat_bytes from sysfs with the clock taken to the nearest MHz
# (249.975 MHz x 32 B -> 8000, 199.98 MHz x 16 B -> 3200: the old x16
# truncation gave 3199 and never swept 3200). A rate a hair above the true
# maximum runs at the maximum (the driver clamps it).

set -u

DIR=/mnt/rec
SIZE=32G
FROM=500
TO=""
STEP=500
NVREC_ARGS=""
RAW=""
KEEP=0
STOP_ON_FAIL=0

usage() {
    cat <<EOF
Usage: nvbench.sh [options]

Sweep the test pattern generator rate and record --size bytes at each step
(default $SIZE: large enough to exhaust the SLC cache of typical smaller
SSDs, so the result is the sustained rate, not the cache rate).

Options:
  --dir <dir>          directory on the exFAT recording volume (default $DIR)
  --raw <dev>          record raw LBAs of <dev> (unmounted nvrec disk or md
                       array) instead of a file; verified with nvverify --raw
  --size <bytes>       data per step, nvrec suffixes (default $SIZE)
  --from <MB/s>        first rate in MB/s (10^6 bytes/s, default $FROM)
  --to <MB/s>          last rate (default: generator maximum = src_clk x
                       beat_bytes, e.g. 250 MHz x 32 B = 8000)
  --step <MB/s>        rate step (default $STEP)
  --stop-on-fail       stop at the first failing rate
  --keep               keep the recordings (default: delete after verifying)
  --nvrec-args "<..>"  extra nvrec options (e.g. "--qd 16 --buffers 512")
  -h, --help           this help

Prerequisites: the nvrec module is loaded (/dev/nvrec) and an exFAT volume
is mounted at --dir (nvsetup-raid0.sh). The free space must exceed --size.
nvrec unmounts and remounts the volume for every step: keep no shell or
file open on it.
EOF
}

die() { echo "nvbench: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --dir) DIR="${2:?}"; shift 2 ;;
        --size) SIZE="${2:?}"; shift 2 ;;
        --from) FROM="${2:?}"; shift 2 ;;
        --to) TO="${2:?}"; shift 2 ;;
        --step) STEP="${2:?}"; shift 2 ;;
        --stop-on-fail) STOP_ON_FAIL=1; shift ;;
        --keep) KEEP=1; shift ;;
        --nvrec-args) NVREC_ARGS="${2:?}"; shift 2 ;;
        --raw) RAW="${2:?}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 1 ;;
    esac
done

command -v nvrec >/dev/null || die "nvrec not found in PATH"
command -v nvverify >/dev/null || die "nvverify not found in PATH"
[ -c /dev/nvrec ] || die "/dev/nvrec not found (modprobe nvrec)"
if [ -z "$RAW" ]; then
    [ -d "$DIR" ] || die "$DIR does not exist (run nvsetup-raid0.sh)"
fi

SYS=/sys/class/misc/nvrec
# bytes per fabric beat (driver >= 1.1); 16 = the 128-bit datapath of older drivers
BEAT=$(cat $SYS/beat_bytes 2>/dev/null || echo 16)
if [ -z "$TO" ]; then
    clk=$(cat $SYS/src_clk_hz 2>/dev/null || echo 0)
    [ "$clk" -gt 0 ] || die "cannot read $SYS/src_clk_hz; give --to"
    TO=$(( (clk + 500000) / 1000000 * BEAT ))
fi

if [ -n "$RAW" ]; then
    FS_DEV=$RAW; FS_TYPE=raw
else
    FS_DEV=$(df -P "$DIR" | awk 'NR==2 {print $1}')
    FS_TYPE=$(df -PT "$DIR" | awk 'NR==2 {print $2}')
fi
OUT="$DIR/nvbench.dat"
LOG=$(mktemp /tmp/nvbench.XXXXXX)
trap 'rm -f "$LOG"' EXIT

echo "nvbench: $FS_DEV ($FS_TYPE) ${RAW:-at $DIR}, $SIZE per step, $FROM..$TO MB/s step $STEP ($BEAT-byte beats)"
for d in /sys/block/nvrec*n1; do
    [ -e "$d" ] && echo "  $(basename "$d"): $(cat "$d/nvrec/model" 2>/dev/null) ($(cat "$d/nvrec/firmware" 2>/dev/null)), block I/O via $(cat "$d/nvrec/io_path" 2>/dev/null)"
done
echo
printf "%10s  %-6s  %14s  %16s  %12s  %10s\n" "rate MB/s" "result" "drops" "fifo_hwm/depth" "avg MB/s" "nvverify"
printf "%10s  %-6s  %14s  %16s  %12s  %10s\n" "---------" "------" "-----" "--------------" "--------" "--------"

best=0
rate=$FROM
while [ "$rate" -le "$TO" ]; do
    if [ -n "$RAW" ]; then
        # shellcheck disable=SC2086
        nvrec --rate "${rate}MB" --size "$SIZE" --stats 0 $NVREC_ARGS --raw "$RAW" >"$LOG" 2>&1
    else
        rm -f "$OUT"
        sync
        # shellcheck disable=SC2086
        nvrec --rate "${rate}MB" --size "$SIZE" --stats 0 $NVREC_ARGS "$OUT" >"$LOG" 2>&1
    fi
    rc=$?
    res=$(grep '^RESULT ' "$LOG" | tail -n1)
    get() { echo "$res" | tr ' ' '\n' | sed -n "s/^$1=//p"; }
    drops=$(get drops); hwm=$(get fifo_hwm); depth=$(get fifo_depth)
    bytes=$(get bytes); secs=$(get seconds)
    avg=$(awk -v b="${bytes:-0}" -v s="${secs:-0}" 'BEGIN { if (s > 0) printf "%.1f", b / s / 1e6; else print "-" }')
    if [ -n "$RAW" ]; then
        VERIFY="nvverify -q --raw --beat-bytes $BEAT --length $(( ${bytes:-0} / BEAT * BEAT )) $RAW"
    else
        VERIFY="nvverify -q $OUT"
    fi
    if [ $rc -eq 0 ]; then
        if $VERIFY >"$LOG.v" 2>&1; then v=PASS; else v=FAIL; fi
    elif [ $rc -eq 2 ]; then
        # dropped beats: nvverify must report the gaps (cross-check)
        if $VERIFY >"$LOG.v" 2>&1; then v=PASS?; else v=gaps; fi
    else
        v=-
    fi
    rm -f "$LOG.v"
    if [ $rc -eq 0 ] && [ "$v" = PASS ]; then
        result=PASS; best=$rate
    elif [ $rc -eq 2 ]; then
        result=DROPS
    else
        result=ERROR
        sed 's/^/    /' "$LOG" | tail -n 5
    fi
    printf "%10s  %-6s  %14s  %16s  %12s  %10s\n" "$rate" "$result" "${drops:--}" "${hwm:--}/${depth:--}" "$avg" "$v"
    [ "$KEEP" -eq 1 ] && [ -z "$RAW" ] && mv "$OUT" "$DIR/nvbench-${rate}MBps.dat" 2>/dev/null
    if [ "$result" != PASS ] && [ "$STOP_ON_FAIL" -eq 1 ]; then
        break
    fi
    rate=$(( rate + STEP ))
done
[ "$KEEP" -eq 1 ] || [ -n "$RAW" ] || rm -f "$OUT"

echo
if [ "$best" -gt 0 ]; then
    echo "nvbench: sustained recording rate: $best MB/s ($FS_DEV, $FS_TYPE, $SIZE per step)"
else
    echo "nvbench: no rate passed"
    exit 1
fi
