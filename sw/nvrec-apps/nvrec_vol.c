// SPDX-License-Identifier: MIT
/*
 * nvrec_vol.c -- mounts, md RAID0 targets and a minimal exFAT patcher.
 *
 * Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
 *
 * The exFAT code follows the Microsoft exFAT File System Specification
 * (2019): boot sector fields, directory entry sets (File 0x85, Stream
 * Extension 0xC0, File Name 0xC1), the entry-set checksum and the
 * NoFatChain flag. It only reads directories, follows FAT chains and
 * rewrites the Stream Extension's ValidDataLength (+ the set checksum). It
 * must only be used on an UNMOUNTED volume.
 */

#define _GNU_SOURCE
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <endian.h>
#include <libgen.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <linux/fs.h>

#include "nvrec_vol.h"

/* ------------------------------------------------------------------------ */
/* small helpers                                                            */

/* bounded string copy, always NUL-terminated */
static void scopy(char *d, size_t n, const char *s)
{
	size_t l = strlen(s);

	if (l >= n)
		l = n - 1;

	memcpy(d, s, l);
	d[l] = 0;
}

static int read_str(const char *path, char *buf, size_t len)
{
	FILE *f = fopen(path, "r");
	size_t n;

	if (!f)
		return -errno;
	n = fread(buf, 1, len - 1, f);
	fclose(f);
	buf[n] = 0;
	while (n && (buf[n - 1] == '\n' || buf[n - 1] == ' '))
		buf[--n] = 0;
	return 0;
}

static int read_u64(const char *path, uint64_t *v)
{
	char buf[64], *end;

	if (read_str(path, buf, sizeof(buf)))
		return -1;
	errno = 0;
	*v = strtoull(buf, &end, 0);
	return (errno || end == buf) ? -1 : 0;
}

/* ------------------------------------------------------------------------ */
/* mounts                                                                   */

/* mountinfo escapes space, tab, newline and backslash as \ooo */
static void unescape(char *s)
{
	char *d = s;

	while (*s) {
		if (s[0] == '\\' && s[1] >= '0' && s[1] <= '7' && s[2] && s[3]) {
			*d++ = (char)(((s[1] - '0') << 6) | ((s[2] - '0') << 3) | (s[3] - '0'));
			s += 4;
		} else {
			*d++ = *s++;
		}
	}
	*d = 0;
}

static int parse_mountinfo(dev_t want_dev, const char *want_src, struct vol_mount *m)
{
	FILE *f = fopen("/proc/self/mountinfo", "r");
	char line[4096];
	int ret = -ENOENT;

	if (!f)
		return -errno;
	while (fgets(line, sizeof(line), f)) {
		char *fld[16], *p, *sep;
		unsigned maj, min, n = 0;

		sep = strstr(line, " - ");
		if (!sep)
			continue;
		*sep = 0;
		for (p = strtok(line, " "); p && n < 10; p = strtok(NULL, " "))
			fld[n++] = p;
		if (n < 6 || sscanf(fld[2], "%u:%u", &maj, &min) != 2)
			continue;
		{
			char *rest = sep + 3, *fs, *src, *so;

			fs = strtok(rest, " ");
			src = strtok(NULL, " ");
			so = strtok(NULL, " \n");
			if (!fs || !src)
				continue;
			unescape(src);
			if (want_src ? strcmp(src, want_src) :
			    (makedev(maj, min) != want_dev))
				continue;
			unescape(fld[4]);
			scopy(m->mountpoint, sizeof(m->mountpoint), fld[4]);
			scopy(m->source, sizeof(m->source), src);
			scopy(m->fstype, sizeof(m->fstype), fs);
			scopy(m->mopts, sizeof(m->mopts), fld[5]);
			scopy(m->sopts, sizeof(m->sopts), so ? so : "");
			ret = 0;
			/* keep the LAST match: the top of a stacked mount */
		}
	}
	fclose(f);
	return ret;
}

int vol_find_mount(const char *path, struct vol_mount *m)
{
	char abs[PATH_MAX], dir[PATH_MAX], *d;
	struct stat st;
	size_t ml;
	int ret;

	memset(m, 0, sizeof(*m));
	scopy(dir, sizeof(dir), path);
	d = dirname(dir);
	if (!realpath(d, abs))
		return -errno;
	if (stat(abs, &st) < 0)
		return -errno;
	ret = parse_mountinfo(st.st_dev, NULL, m);
	if (ret)
		return ret;
	ml = strlen(m->mountpoint);
	if (strcmp(m->mountpoint, "/") == 0)
		ml = 0;
	{
		char base[PATH_MAX];

		scopy(base, sizeof(base), path);
		if (snprintf(m->relpath, sizeof(m->relpath), "%s/%s",
			     abs + ml, basename(base)) >= (int)sizeof(m->relpath))
			return -ENAMETOOLONG;
	}
	return 0;
}

int vol_find_mount_of_dev(const char *dev, struct vol_mount *m)
{
	memset(m, 0, sizeof(*m));
	return parse_mountinfo(0, dev, m);
}

int vol_umount(const struct vol_mount *m)
{
	sync();
	if (umount2(m->mountpoint, 0) < 0)
		return -errno;
	return 0;
}

int vol_remount(const struct vol_mount *m)
{
	static const struct { const char *opt; unsigned long flag; } fl[] = {
		{ "ro", MS_RDONLY }, { "nosuid", MS_NOSUID }, { "nodev", MS_NODEV },
		{ "noexec", MS_NOEXEC }, { "sync", MS_SYNCHRONOUS },
		{ "noatime", MS_NOATIME }, { "nodiratime", MS_NODIRATIME },
		{ "relatime", MS_RELATIME },
	};
	char mo[512], data[512], *tok, *save;
	unsigned long flags = 0;
	size_t i, dl = 0;

	scopy(mo, sizeof(mo), m->mopts);
	for (tok = strtok_r(mo, ",", &save); tok; tok = strtok_r(NULL, ",", &save))
		for (i = 0; i < sizeof(fl) / sizeof(fl[0]); i++)
			if (!strcmp(tok, fl[i].opt))
				flags |= fl[i].flag;
	/* superblock options minus rw/ro */
	data[0] = 0;
	scopy(mo, sizeof(mo), m->sopts);
	for (tok = strtok_r(mo, ",", &save); tok; tok = strtok_r(NULL, ",", &save)) {
		if (!strcmp(tok, "rw") || !strcmp(tok, "ro"))
			continue;
		dl += snprintf(data + dl, sizeof(data) - dl, "%s%s", dl ? "," : "", tok);
		if (dl >= sizeof(data))
			return -E2BIG;
	}
	if (mount(m->source, m->mountpoint, m->fstype, flags, data) < 0)
		return -errno;
	return 0;
}

/* ------------------------------------------------------------------------ */
/* targets                                                                  */

/* "nvrec0n1p1" -> disk "nvrec0n1", start sector; "nvrec0n1" -> itself, 0 */
static int resolve_part(const char *name, char *disk, size_t dlen, uint64_t *start)
{
	char p[PATH_MAX], real[PATH_MAX];
	uint64_t v;

	snprintf(p, sizeof(p), "/sys/class/block/%s/partition", name);
	if (access(p, F_OK) != 0) {
		snprintf(disk, dlen, "%s", name);
		*start = 0;
		return 0;
	}
	snprintf(p, sizeof(p), "/sys/class/block/%s/start", name);
	if (read_u64(p, &v))
		return -EIO;
	*start = v;
	snprintf(p, sizeof(p), "/sys/class/block/%s/..", name);
	if (!realpath(p, real))
		return -errno;
	snprintf(disk, dlen, "%s", basename(real));
	return 0;
}

int vol_flush_bdev(const char *dev)
{
	int fd = open(dev, O_RDONLY | O_CLOEXEC);
	int ret = 0;

	if (fd < 0)
		return -errno;
	if (fsync(fd) < 0 || ioctl(fd, BLKFLSBUF, 0) < 0)
		ret = -errno;
	close(fd);
	return ret;
}

int vol_resolve_target(const char *dev, struct vol_target *t, char *err, size_t errlen)
{
	char real[PATH_MAX], name[64], p[PATH_MAX], buf[64];
	uint64_t v;
	unsigned i;
	int fd;

	memset(t, 0, sizeof(*t));
	if (!realpath(dev, real)) {
		snprintf(err, errlen, "%s: %s", dev, strerror(errno));
		return -errno;
	}
	scopy(t->dev, sizeof(t->dev), real);
	scopy(name, sizeof(name), basename(real));
	fd = open(real, O_RDONLY | O_CLOEXEC);
	if (fd < 0 || ioctl(fd, BLKGETSIZE64, &t->dev_bytes) < 0) {
		snprintf(err, errlen, "%s: not a block device", real);
		if (fd >= 0)
			close(fd);
		return -ENOTBLK;
	}
	close(fd);

	snprintf(p, sizeof(p), "/sys/block/%s/md/level", name);
	if (read_str(p, buf, sizeof(buf)) == 0) {
		uint64_t min_data = UINT64_MAX;

		t->md = true;
		if (strcmp(buf, "raid0")) {
			snprintf(err, errlen, "%s is md %s, only raid0 is supported", real, buf);
			return -EINVAL;
		}
		snprintf(p, sizeof(p), "/sys/block/%s/md/chunk_size", name);
		if (read_u64(p, &t->chunk_bytes) || !t->chunk_bytes)
			goto sysfs_err;
		snprintf(p, sizeof(p), "/sys/block/%s/md/raid_disks", name);
		if (read_u64(p, &v))
			goto sysfs_err;
		if (v < 1 || v > VOL_MAX_MEMBERS) {
			snprintf(err, errlen, "%s has %llu members, the hardware stripes over at most %d",
				 real, (unsigned long long)v, VOL_MAX_MEMBERS);
			return -EINVAL;
		}
		t->nr_members = (unsigned)v;
		for (i = 0; i < t->nr_members; i++) {
			char link[PATH_MAX], tgt[PATH_MAX], comp[64];
			struct vol_member *m = &t->m[i];
			uint64_t pstart, off, kib;
			ssize_t n;

			/* rdN -> dev-<component>, N = stripe position */
			snprintf(link, sizeof(link), "/sys/block/%s/md/rd%u", name, i);
			n = readlink(link, tgt, sizeof(tgt) - 1);
			if (n <= 0)
				goto sysfs_err;
			tgt[n] = 0;
			if (strncmp(basename(tgt), "dev-", 4))
				goto sysfs_err;
			scopy(comp, sizeof(comp), basename(tgt) + 4);
			if (resolve_part(comp, m->disk, sizeof(m->disk), &pstart))
				goto sysfs_err;
			snprintf(p, sizeof(p), "/sys/block/%s/md/dev-%s/offset", name, comp);
			if (read_u64(p, &off))
				goto sysfs_err;
			snprintf(p, sizeof(p), "/sys/block/%s/md/dev-%s/size", name, comp);
			if (read_u64(p, &kib))
				goto sysfs_err;
			m->base_sector = pstart + off;
			m->data_sectors = kib * 2;
			if (m->data_sectors < min_data)
				min_data = m->data_sectors;
		}
		/* md raid0 zone 0: every member contributes the same number of
		 * whole chunks (the smallest member's) */
		t->zone0_bytes = (min_data * 512 / t->chunk_bytes) * t->chunk_bytes *
				 t->nr_members;
		return 0;
	}

	/* a plain nvrec disk or a partition of one */
	t->nr_members = 1;
	if (resolve_part(name, t->m[0].disk, sizeof(t->m[0].disk), &t->m[0].base_sector))
		goto sysfs_err;
	t->m[0].data_sectors = t->dev_bytes / 512;
	t->zone0_bytes = t->dev_bytes;
	return 0;

sysfs_err:
	snprintf(err, errlen, "%s: cannot read %s", real, p);
	return -EIO;
}

/* ------------------------------------------------------------------------ */
/* exFAT                                                                    */

static inline uint16_t le16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }
static inline uint32_t le32(const uint8_t *p) { return le16(p) | (uint32_t)le16(p + 2) << 16; }
static inline uint64_t le64(const uint8_t *p) { return le32(p) | (uint64_t)le32(p + 4) << 32; }

static void put_le16(uint8_t *p, uint16_t v) { p[0] = v; p[1] = v >> 8; }
static void put_le64(uint8_t *p, uint64_t v)
{
	int i;

	for (i = 0; i < 8; i++)
		p[i] = (uint8_t)(v >> (8 * i));
}

int exfat_open(struct exfat_vol *v, const char *dev, bool rw, bool allow_dirty,
	       char *err, size_t errlen)
{
	uint8_t bs[512];

	memset(v, 0, sizeof(*v));
	v->fd = open(dev, (rw ? O_RDWR : O_RDONLY) | O_CLOEXEC);
	if (v->fd < 0) {
		snprintf(err, errlen, "%s: %s", dev, strerror(errno));
		return -errno;
	}
	if (pread(v->fd, bs, sizeof(bs), 0) != (ssize_t)sizeof(bs) ||
	    memcmp(bs + 3, "EXFAT   ", 8)) {
		snprintf(err, errlen, "%s: no exFAT boot sector", dev);
		close(v->fd);
		v->fd = -1;
		return -EINVAL;
	}
	v->volume_bytes = le64(bs + 72);
	v->bps_shift = bs[108];
	v->spc_shift = bs[109];
	if (v->bps_shift < 9 || v->bps_shift > 12 || v->bps_shift + v->spc_shift > 25) {
		snprintf(err, errlen, "%s: bad exFAT geometry", dev);
		close(v->fd);
		v->fd = -1;
		return -EINVAL;
	}
	v->volume_bytes <<= v->bps_shift;
	v->fat_off = (uint64_t)le32(bs + 80) << v->bps_shift;
	v->heap_off = (uint64_t)le32(bs + 88) << v->bps_shift;
	v->cluster_count = le32(bs + 92);
	v->root_clu = le32(bs + 96);
	v->cluster_bytes = 1ull << (v->bps_shift + v->spc_shift);
	if ((bs[106] & 0x02) && !allow_dirty) {
		snprintf(err, errlen, "%s: exFAT volume is marked dirty (mounted, or not cleanly unmounted: run fsck.exfat)", dev);
		close(v->fd);
		v->fd = -1;
		return -EUCLEAN;
	}
	return 0;
}

void exfat_close(struct exfat_vol *v)
{
	if (v->fd >= 0)
		close(v->fd);
	v->fd = -1;
}

static uint64_t clu_off(const struct exfat_vol *v, uint32_t clu)
{
	return v->heap_off + ((uint64_t)(clu - 2) << (v->bps_shift + v->spc_shift));
}

static int fat_next(const struct exfat_vol *v, uint32_t clu, uint32_t *next)
{
	uint8_t e[4];

	if (pread(v->fd, e, 4, (off_t)(v->fat_off + (uint64_t)clu * 4)) != 4)
		return -EIO;
	*next = le32(e);
	return 0;
}

static bool clu_valid(const struct exfat_vol *v, uint32_t clu)
{
	return clu >= 2 && clu < v->cluster_count + 2;
}

static uint16_t set_checksum(const uint8_t (*set)[32], unsigned nent)
{
	uint16_t sum = 0;
	unsigned i, j;

	for (i = 0; i < nent; i++)
		for (j = 0; j < 32; j++) {
			if (i == 0 && (j == 2 || j == 3))
				continue;
			sum = (uint16_t)(((sum & 1) ? 0x8000 : 0) + (sum >> 1) + set[i][j]);
		}
	return sum;
}

/* Iterate a directory: calls cb for every in-use file entry set */
struct dir_iter {
	const struct exfat_vol *v;
	uint32_t clu;           /* current cluster */
	bool nofat;
	uint64_t left;          /* clusters left (nofat), or 0 = follow FAT */
	uint8_t *buf;
	uint64_t pos;           /* entry index in the cluster */
	bool end;
};

static int dir_load(struct dir_iter *it)
{
	ssize_t n = pread(it->v->fd, it->buf, it->v->cluster_bytes, (off_t)clu_off(it->v, it->clu));

	return n == (ssize_t)it->v->cluster_bytes ? 0 : -EIO;
}

static int dir_open(struct dir_iter *it, const struct exfat_vol *v, uint32_t clu,
		    bool nofat, uint64_t bytes)
{
	memset(it, 0, sizeof(*it));
	it->v = v;
	it->clu = clu;
	it->nofat = nofat;
	it->left = nofat ? (bytes + v->cluster_bytes - 1) / v->cluster_bytes : 0;
	if (!clu_valid(v, clu))
		return -EIO;
	it->buf = malloc(v->cluster_bytes);
	if (!it->buf)
		return -ENOMEM;
	return dir_load(it);
}

/* next 32-byte entry; returns 1 with entry + its offset, 0 at the end */
static int dir_next(struct dir_iter *it, uint8_t *ent, uint64_t *off)
{
	uint64_t per = it->v->cluster_bytes / 32;
	int ret;

	if (it->end)
		return 0;
	if (it->pos == per) {
		if (it->nofat) {
			if (--it->left == 0)
				return it->end = true, 0;
			it->clu++;
		} else {
			uint32_t next;

			if (fat_next(it->v, it->clu, &next))
				return -EIO;
			if (next >= 0xFFFFFFF8u)
				return it->end = true, 0;
			if (!clu_valid(it->v, next))
				return -EIO;
			it->clu = next;
		}
		ret = dir_load(it);
		if (ret)
			return ret;
		it->pos = 0;
	}
	memcpy(ent, it->buf + it->pos * 32, 32);
	*off = clu_off(it->v, it->clu) + it->pos * 32;
	it->pos++;
	if (ent[0] == 0x00)
		return it->end = true, 0;
	return 1;
}

static bool name_eq(const uint16_t *u, unsigned len, const char *s, size_t slen)
{
	unsigned i;

	if (len != slen)
		return false;
	for (i = 0; i < len; i++) {
		if (u[i] >= 0x80)
			return false;   /* only ASCII names are matched */
		if (toupper((unsigned char)u[i]) != toupper((unsigned char)s[i]))
			return false;
	}
	return true;
}

static int dir_find(const struct exfat_vol *v, uint32_t clu, bool nofat, uint64_t bytes,
		    const char *name, size_t nlen, struct exfat_file *f)
{
	struct dir_iter it;
	uint8_t ent[32];
	uint64_t off;
	int r, ret = -ENOENT;

	r = dir_open(&it, v, clu, nofat, bytes);
	if (r) {
		free(it.buf);
		return r;
	}
	while ((r = dir_next(&it, ent, &off)) == 1) {
		uint16_t uname[255];
		unsigned sc, i, nl, got = 0;

		if (ent[0] != 0x85)
			continue;
		sc = ent[1];
		if (sc < 2 || sc + 1 > EXFAT_MAX_SET)
			continue;
		memset(f, 0, sizeof(*f));
		memcpy(f->set[0], ent, 32);
		f->off[0] = off;
		for (i = 1; i <= sc; i++) {
			r = dir_next(&it, f->set[i], &f->off[i]);
			if (r != 1)
				break;
		}
		if (i <= sc)
			break;
		f->nent = sc + 1;
		if (f->set[1][0] != 0xC0)
			continue;
		nl = f->set[1][3];
		for (i = 2; i <= sc && got < nl; i++) {
			unsigned k;

			if (f->set[i][0] != 0xC1)
				break;
			for (k = 0; k < 15 && got < nl; k++)
				uname[got++] = le16(f->set[i] + 2 + 2 * k);
		}
		if (!name_eq(uname, got, name, nlen))
			continue;
		if (set_checksum((const uint8_t (*)[32])f->set, f->nent) != le16(f->set[0] + 2)) {
			ret = -EUCLEAN;
			break;
		}
		f->is_dir = le16(f->set[0] + 4) & 0x10;
		f->nofatchain = f->set[1][1] & 0x02;
		f->valid_len = le64(f->set[1] + 8);
		f->first_clu = le32(f->set[1] + 20);
		f->data_len = le64(f->set[1] + 24);
		ret = 0;
		break;
	}
	if (r < 0)
		ret = r;
	free(it.buf);
	return ret;
}

int exfat_lookup(struct exfat_vol *v, const char *path, struct exfat_file *f)
{
	uint32_t clu = v->root_clu;
	bool nofat = false;
	uint64_t bytes = 0;
	const char *p = path;

	for (;;) {
		const char *e;
		size_t n;
		int ret;

		while (*p == '/')
			p++;
		if (!*p)
			return -EISDIR;
		e = strchr(p, '/');
		n = e ? (size_t)(e - p) : strlen(p);
		ret = dir_find(v, clu, nofat, bytes, p, n, f);
		if (ret)
			return ret;
		if (!e || !e[strspn(e, "/")])
			return f->is_dir ? -EISDIR : 0;
		if (!f->is_dir)
			return -ENOTDIR;
		clu = f->first_clu;
		nofat = f->nofatchain;
		bytes = f->data_len;
		p = e;
	}
}

int exfat_extent(struct exfat_vol *v, const struct exfat_file *f,
		 uint64_t *dev_off, uint64_t *alloc_bytes)
{
	uint64_t nclu = (f->data_len + v->cluster_bytes - 1) / v->cluster_bytes;
	uint32_t clu = f->first_clu;
	uint64_t i;

	if (!nclu || !clu_valid(v, clu))
		return -ENODATA;
	if (clu - 2 + nclu > v->cluster_count)
		return -EIO;
	if (!f->nofatchain) {
		/* FAT chain: contiguous only if every link is +1 */
		for (i = 1; i < nclu; i++) {
			uint32_t next;

			if (fat_next(v, clu, &next))
				return -EIO;
			if (next != clu + 1)
				return -EFBIG;
			clu = next;
		}
	}
	*dev_off = clu_off(v, f->first_clu);
	*alloc_bytes = nclu * v->cluster_bytes;
	return 0;
}

int exfat_set_valid_len(struct exfat_vol *v, struct exfat_file *f, uint64_t vdl)
{
	unsigned i;

	if (vdl > f->data_len)
		return -EINVAL;
	put_le64(f->set[1] + 8, vdl);
	put_le16(f->set[0] + 2, set_checksum((const uint8_t (*)[32])f->set, f->nent));
	for (i = 0; i < 2; i++)		/* File (checksum) + Stream (VDL) */
		if (pwrite(v->fd, f->set[i], 32, (off_t)f->off[i]) != 32)
			return -EIO;
	if (fsync(v->fd) < 0)
		return -errno;
	f->valid_len = vdl;
	return 0;
}
