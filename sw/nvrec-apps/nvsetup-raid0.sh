#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
#
# nvsetup-raid0.sh -- prepare the recording volume for nvrec: a Linux md
# RAID0 across the two nvrec SSDs (/dev/nvrecXn1), or one SSD, formatted
# exFAT and mounted at /mnt/rec. Port of fpga-drive-recorder's
# fdsetup-raid0.sh. DESTROYS all data on the drives used.
#
# Why these settings (docs/source/filesystem.md):
#  - md chunk = nvrec chunk (1M, or the drives' MDTS if smaller: one NVMe
#    command per chunk): one NVMe command never spans two members,
#    and the hardware's stripe math (chunk c -> member c mod N) is md's.
#  - exFAT cluster = chunk, cluster heap aligned to the chunk: every file
#    starts on a chunk boundary of the array, and a preallocated file is one
#    contiguous cluster run (NoFatChain) on a fresh volume.

set -eu

CHUNK=          # default: 1M, or the drives' maximum transfer size (MDTS) if smaller
CLUSTER=""
MNT=/mnt/rec
MD=/dev/md0
LABEL=NVREC
SINGLE=""
FORCE=0
TEARDOWN=0
TRIM=0
DEVS=""

usage() {
    cat <<USAGE
Usage: nvsetup-raid0.sh [options] [<nvrec-dev> <nvrec-dev>]

Create a RAID0 array ($MD) from two nvrec SSDs with mdadm, format it exFAT
and mount it at $MNT for recording with nvrec. Without device arguments the
two nvrec namespaces found in /dev (nvrec0n1, nvrec1n1) are used.
ALL DATA ON THE DRIVES IS DESTROYED.

Options:
  --chunk <size>     RAID0 chunk = nvrec --chunk (default 1M, or the
                     drives' maximum transfer size if smaller: 512K on a 980 PRO)
  --cluster <size>   exFAT cluster size (default: the chunk)
  --mount <dir>      mount point, created if missing (default $MNT);
                     give the same --mount to --teardown
  --single <dev>     no RAID: format and mount this one drive instead
  --trim             deallocate (TRIM) the whole drives first (blkdiscard):
                     the reference starting point for benchmarks
  --label <name>     exFAT volume label (default $LABEL)
  --teardown         unmount the mount point and stop $MD (data is kept)
  -y, --yes          do not ask for confirmation
  -h, --help         this help

Examples:
  nvsetup-raid0.sh                         # both SSDs, RAID0, exFAT
  nvsetup-raid0.sh --trim -y               # same, drives trimmed first
  nvsetup-raid0.sh --single /dev/nvrec0n1  # one SSD

After a reboot the array is re-assembled with:
  mdadm --assemble $MD /dev/nvrec0n1 /dev/nvrec1n1 && mkdir -p $MNT && mount -o noatime $MD $MNT
USAGE
}

die() { echo "nvsetup-raid0: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --chunk) CHUNK="${2:?}"; shift 2 ;;
        --cluster) CLUSTER="${2:?}"; shift 2 ;;
        --mount) MNT="${2:?}"; shift 2 ;;
        --single) SINGLE="${2:?}"; shift 2 ;;
        --trim) TRIM=1; shift ;;
        --label) LABEL="${2:?}"; shift 2 ;;
        --teardown) TEARDOWN=1; shift ;;
        -y|--yes) FORCE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) usage >&2; exit 1 ;;
        *) DEVS="$DEVS $1"; shift ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "must run as root"

if [ "$TEARDOWN" -eq 1 ]; then
    mountpoint -q "$MNT" && umount "$MNT"
    [ -e "$MD" ] && mdadm --stop "$MD"
    echo "nvsetup-raid0: $MNT unmounted, $MD stopped"
    exit 0
fi

# size in bytes from 512K / 1M / 1048576 (mdadm default unit: KiB)
to_bytes() {
    v=$(echo "$1" | tr 'a-z' 'A-Z')
    case "$v" in
        *K) echo $(( ${v%K} * 1024 )) ;;
        *M) echo $(( ${v%M} * 1048576 )) ;;
        *[0-9]) echo $(( v * 1024 )) ;;
        *) die "bad size '$1'" ;;
    esac
}

if [ -n "$SINGLE" ]; then
    TARGET="$SINGLE"
    set -- "$SINGLE"
else
    if [ -z "$DEVS" ]; then
        DEVS=$(ls /dev/nvrec[0-9]*n1 2>/dev/null | sort | head -n 2 | tr '\n' ' ')
    fi
    set -- $DEVS
    [ $# -eq 2 ] || die "need exactly two nvrec drives for RAID0 (found: ${DEVS:-none}); use --single <dev> for one"
    TARGET="$MD"
fi
for d in "$@"; do
    [ -b "$d" ] || die "$d is not a block device"
    case "$(basename "$d")" in
        nvrec*) ;;
        *) die "$d is not an nvrec disk: the hardware recorder only writes to /dev/nvrecXn1" ;;
    esac
done
# One NVMe command per chunk: the chunk may not exceed any drive's MDTS
# (/sys/block/nvrecXn1/nvrec/mdts_bytes, 0 = unlimited)
MDTS_MIN=0
for d in "$@"; do
    m=$(cat "/sys/block/$(basename "$d")/nvrec/mdts_bytes" 2>/dev/null || echo 0)
    if [ "$m" -gt 0 ] && { [ "$MDTS_MIN" -eq 0 ] || [ "$m" -lt "$MDTS_MIN" ]; }; then
        MDTS_MIN=$m
    fi
done
if [ -z "$CHUNK" ]; then
    CHUNK=1M
    if [ "$MDTS_MIN" -gt 0 ] && [ "$MDTS_MIN" -lt 1048576 ]; then
        CHUNK="$((MDTS_MIN / 1024))K"
        echo "nvsetup-raid0: chunk $CHUNK (the drives' maximum transfer size)"
    fi
fi
CHUNK_B=$(to_bytes "$CHUNK")
[ "$MDTS_MIN" -eq 0 ] || [ "$CHUNK_B" -le "$MDTS_MIN" ] || \
    die "--chunk $CHUNK exceeds the drives' maximum transfer size ($((MDTS_MIN / 1024))K)"
[ -n "$CLUSTER" ] || CLUSTER=$CHUNK
CLUSTER_B=$(to_bytes "$CLUSTER")
command -v mkfs.exfat >/dev/null || die "mkfs.exfat not found (exfatprogs)"
[ -n "$SINGLE" ] || command -v mdadm >/dev/null || die "mdadm not found"

echo "nvsetup-raid0: about to ERASE: $*"
if [ -n "$SINGLE" ]; then
    echo "  layout: single drive, exFAT (cluster $CLUSTER), mounted at $MNT"
else
    echo "  layout: RAID0 $MD, chunk $CHUNK, exFAT (cluster $CLUSTER), mounted at $MNT"
fi
if [ "$FORCE" -ne 1 ]; then
    printf "Type 'yes' to continue: "
    read -r ans
    [ "$ans" = "yes" ] || die "aborted"
fi

# Release anything that holds the drives
mountpoint -q "$MNT" && umount "$MNT"
for d in "$@"; do
    for p in $(lsblk -nrpo NAME "$d" 2>/dev/null); do
        grep -q "^$p " /proc/mounts && umount "$p"
    done
done
if [ -r /proc/mdstat ]; then
    for d in "$@"; do
        b=$(basename "$d")
        for md in $(awk -v b="$b" '/^md[0-9]+ :/ {
                        for (i = 3; i <= NF; i++) { m = $i; sub(/\[.*/, "", m);
                            if (m == b || index(m, b "p") == 1) print $1 } }' /proc/mdstat); do
            mdp="/dev/$md"
            for p in $(lsblk -nrpo NAME "$mdp" 2>/dev/null); do
                grep -q "^$p " /proc/mounts && { umount "$p" || die "cannot unmount $p (in use?)"; }
            done
            echo "nvsetup-raid0: stopping $mdp (uses $d)"
            mdadm --stop "$mdp" || die "cannot stop $mdp; run 'nvsetup-raid0.sh --teardown' first"
        done
    done
fi
if [ -z "$SINGLE" ]; then
    [ -e "$MD" ] && mdadm --stop "$MD" 2>/dev/null || true
fi
for d in "$@"; do
    mdadm --zero-superblock "$d" 2>/dev/null || true
    wipefs -a "$d" >/dev/null 2>&1 || true
done
if [ "$TRIM" -eq 1 ]; then
    for d in "$@"; do
        echo "nvsetup-raid0: deallocating $d"
        blkdiscard "$d" || echo "nvsetup-raid0: blkdiscard $d failed (no Dataset Management support?)" >&2
    done
fi

if [ -z "$SINGLE" ]; then
    mdadm --create "$MD" --run --level=0 --raid-devices=2 --chunk="$CHUNK" \
          --metadata=1.2 "$@"
    mdadm --wait "$MD" 2>/dev/null || true
fi

# cluster = chunk and the FAT / cluster heap aligned to the chunk: every
# cluster, hence every file, starts on a chunk boundary of the array
mkfs.exfat -L "$LABEL" -c "$CLUSTER_B" -b "$CHUNK_B" "$TARGET"

mkdir -p "$MNT"
mount -t exfat -o noatime "$TARGET" "$MNT"
echo "nvsetup-raid0: $TARGET (exFAT) mounted at $MNT"
df -h "$MNT"
[ -n "$SINGLE" ] || mdadm --detail "$MD" | grep -E "Raid Level|Array Size|Chunk Size|Raid Devices|/dev/"
