/* SPDX-License-Identifier: MIT */
/*
 * Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
 *
 * nvrec_vol.h -- where a recording lives on the SSDs:
 *   - mounts: which filesystem/device a path is on, unmount/remount it;
 *   - targets: a block device (/dev/md0, /dev/nvrec0n1[pN]) resolved to
 *     stripe members (nvrec disks, base sectors, md chunk);
 *   - exFAT: a minimal reader/patcher of an UNMOUNTED exFAT volume: find a
 *     file, return its cluster run, set its ValidDataLength.
 * docs/source/filesystem.md explains the scheme.
 */

#ifndef NVREC_VOL_H
#define NVREC_VOL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* ---- mounts ------------------------------------------------------------ */

struct vol_mount {
	char mountpoint[256];
	char source[128];       /* /dev/md0 */
	char fstype[32];
	char mopts[256];        /* per-mount options (rw,noatime,...) */
	char sopts[512];        /* superblock options (fmask=...,iocharset=...) */
	char relpath[512];      /* path of the file below the mountpoint ("/x.dat") */
};

/* Mount that holds path (the file may not exist yet: its directory is used) */
int vol_find_mount(const char *path, struct vol_mount *m);
/* Find the mount of a block device, 0 if mounted, -ENOENT if not */
int vol_find_mount_of_dev(const char *dev, struct vol_mount *m);
int vol_umount(const struct vol_mount *m);
int vol_remount(const struct vol_mount *m);

/* ---- targets ----------------------------------------------------------- */

#define VOL_MAX_MEMBERS 2

struct vol_member {
	char disk[32];          /* nvrec disk name: "nvrec0n1" */
	uint64_t base_sector;   /* 512-byte sector of member chunk 0 on the disk
				 * (md data offset + partition start) */
	uint64_t data_sectors;  /* usable sectors from base */
};

struct vol_target {
	char dev[128];          /* the device the filesystem is on */
	bool md;                /* Linux md RAID0 */
	unsigned nr_members;
	uint64_t chunk_bytes;   /* md chunk (0 = not striped) */
	uint64_t zone0_bytes;   /* array bytes covered by the plain stripe */
	uint64_t dev_bytes;
	struct vol_member m[VOL_MAX_MEMBERS];
};

int vol_resolve_target(const char *dev, struct vol_target *t, char *err, size_t errlen);
/* BLKFLSBUF: drop the page cache of a block device (after the hardware wrote) */
int vol_flush_bdev(const char *dev);

/* ---- exFAT ------------------------------------------------------------- */

struct exfat_vol {
	int fd;
	unsigned bps_shift;     /* bytes per sector, log2 */
	unsigned spc_shift;     /* sectors per cluster, log2 */
	uint64_t fat_off;       /* bytes */
	uint64_t heap_off;      /* bytes */
	uint32_t cluster_count;
	uint32_t root_clu;
	uint64_t cluster_bytes;
	uint64_t volume_bytes;
};

#define EXFAT_MAX_SET 19        /* file + stream + up to 17 name entries */

struct exfat_file {
	unsigned nent;                  /* entries in the set */
	uint8_t set[EXFAT_MAX_SET][32];
	uint64_t off[EXFAT_MAX_SET];    /* device byte offset of each entry */
	uint32_t first_clu;
	uint64_t data_len;
	uint64_t valid_len;
	bool nofatchain;
	bool is_dir;
};

/* allow_dirty: also open a volume flagged dirty (a mounted one: read-only
 * peeks at metadata that is known to be on disk) */
int exfat_open(struct exfat_vol *v, const char *dev, bool rw, bool allow_dirty,
	       char *err, size_t errlen);
void exfat_close(struct exfat_vol *v);
int exfat_lookup(struct exfat_vol *v, const char *path, struct exfat_file *f);
/* byte offset on the device and length of the file's clusters; -EFBIG if
 * the clusters are not one contiguous run */
int exfat_extent(struct exfat_vol *v, const struct exfat_file *f,
		 uint64_t *dev_off, uint64_t *alloc_bytes);
int exfat_set_valid_len(struct exfat_vol *v, struct exfat_file *f, uint64_t vdl);

#endif /* NVREC_VOL_H */
