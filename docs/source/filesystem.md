# Filesystem and striping

The hardware writes raw LBAs: it knows nothing about filesystems. A recording can still be an
ordinary file that you copy off the board with `scp` or read on a PC, as long as the file is
**contiguous**, **preallocated** before the run, and the filesystem is **not mounted** while
the hardware writes under it. This page explains how `nvrec` arranges that on exFAT, and the
md RAID0 arithmetic that makes the hardware's stripe identical to Linux's.

## Why exFAT

| filesystem | contiguous preallocation | data valid without writing it | readable on |
|---|---|---|---|
| **exFAT** | yes: a file can be one cluster run (`NoFatChain`) | yes: *ValidDataLength* is a plain field of the directory entry | Linux, Windows, macOS |
| XFS / ext4 | `fallocate` + FIEMAP, usually several extents | no: fallocated extents are *unwritten* and read back as zeros until something writes them through the filesystem | Linux |

exFAT keeps the "it is just a file" story with one start LBA per recording and a single field
to fix afterwards. XFS/ext4 would need an extent table in hardware and a full write pass (or
`FALLOC_FL_WRITE_ZEROES`, ext4, Linux ≥ 6.17) to make the extents "written" — kept as a
possible advanced recipe, not the default.

## The recording volume

`nvsetup-raid0.sh` creates it:

```
mdadm --create /dev/md0 --level=0 --raid-devices=2 --chunk=<C> --metadata=1.2 /dev/nvrec0n1 /dev/nvrec1n1
mkfs.exfat -L NVREC -c <C> -b <C> /dev/md0      # cluster = chunk, heap aligned to the chunk
mount -t exfat -o noatime /dev/md0 /mnt/rec
```

(`--single /dev/nvrec0n1` formats one SSD without md.)

* **Chunk *C* = 1 MB or the drive's MDTS, whichever is smaller.** One NVMe command is one
  chunk, and an NVMe command cannot move more than the drive's maximum data transfer size
  (MDTS, from Identify Controller; 512 KB on the Samsung 980 PRO). `nvsetup-raid0.sh` reads
  the MDTS of every drive (`/sys/block/nvrecXn1/nvrec/mdts_bytes`) and uses the smaller of
  1 MB and the smallest MDTS; a larger `--chunk` is refused, and so is a larger `nvrec
  --chunk` (by the app and by the driver).
* **md chunk = nvrec chunk.** No command ever spans two members, and the hardware's stripe
  (chunk *c* → member *c* mod *N*) is md's. `nvrec` takes the chunk from the md array.
* **exFAT cluster = chunk, cluster heap aligned to the chunk.** Every cluster — hence every
  file — starts on a chunk boundary of the array. Smaller clusters work too: `nvrec` places
  the data at the first chunk boundary at least 4 KB into the file (the header sits in front
  of it), so only 4 KB alignment of the heap is strictly required.

## How nvrec makes a contiguous file (and its limits)

1. **Preallocate through the kernel.** `nvrec` creates the file and calls
   `ftruncate(size + one chunk)`. The kernel exFAT driver (Linux 6.12 `fs/exfat/file.c`,
   `exfat_cont_expand`) allocates the clusters starting at the first free cluster and keeps
   the file `NoFatChain` (contiguous) as long as the free clusters are consecutive. It does
   **not** write the data (the extended range is beyond *ValidDataLength*, which stays 0), so
   preallocating 100 GB takes milliseconds.

   The Linux exFAT driver has no `fallocate` and no FIEMAP in 6.12; `FIBMAP`
   (`exfat_aop_bmap`) exists but only maps blocks below *ValidDataLength*. That is why `nvrec`
   reads the allocation from the volume itself (step 3).
2. **Unmount** the volume (`umount2`), so that nothing caches, writes or re-reads the area
   the hardware is going to write. Freezing (`FIFREEZE`) would also stop writes, but it would
   keep stale page-cache pages of the very blocks the hardware overwrites, and the directory
   entry must be edited on the raw device anyway (step 5). Keep no shell or open file on the
   mount point: the unmount fails with `EBUSY` otherwise.
3. **Locate the file on the raw device.** `nvrec_vol.c` is a small exFAT reader: boot
   sector, directory entry sets (File / Stream Extension / File Name, entry-set checksum
   verified), FAT chains. It finds the file, takes `FirstCluster` and `DataLength`, and
   checks that the run is contiguous (`NoFatChain`, or a FAT chain with every link +1). A
   fragmented free space is reported (`delete files or reformat`), the file removed.
4. **Record**: the device offset of the data start is turned into the hardware geometry (next
   section) and the hardware records.
5. **Finish the file on the raw device**: write the 4 KB header (and zero padding up to the
   data), set the Stream Extension's *ValidDataLength* = *DataLength* and recompute the
   entry-set checksum — without that, Linux and Windows would read the recording as zeros.
6. **Remount and truncate** the file to the recorded length (`header + bytes`). The kernel
   frees the unused clusters at the end and clamps *ValidDataLength*. Done: the file is an
   ordinary exFAT file.

Pitfalls and limits:

* **Page cache.** The hardware writes behind the block layer. The driver writes back and
  invalidates the page cache of the member disks (`sync_blockdev` + `invalidate_bdev`) at the
  start of a run and invalidates it again at the end; `nvrec` drops the cache of the array
  device (`BLKFLSBUF`) before reading and after patching the volume. Never record into a
  mounted volume, and never read the raw devices with buffered I/O during a run.
* **Contiguous free space.** On a fresh volume the first file is always contiguous. Deleting
  recordings in the middle of the volume leaves holes; the kernel allocator fills them first
  and the next large file becomes fragmented — `nvrec` refuses it. Reformat between benchmark
  campaigns (`nvsetup-raid0.sh`), or delete from the end.
* **Unclean shutdown during a run** leaves a file with *ValidDataLength* 0 (reads as zeros)
  and the volume unmounted. The data is on the disk: `nvverify --raw` checks it in place.
* **Interrupted run (Ctrl-C, stall).** `nvrec` still writes the header with the bytes really
  recorded and truncates the file to them.
* **Dirty flag.** A mounted exFAT volume carries the *VolumeDirty* flag; `nvrec` refuses to
  patch a volume that is dirty after the unmount (run `fsck.exfat` first). `nvplay` only reads
  the directory and accepts it.
* **ASCII file names** only (the reader compares names case-insensitively in ASCII).
* **md zones.** md RAID0 over members of different sizes has a second zone (only the larger
  member) after `N × smallest member`. The hardware stripe is valid only in zone 0; `nvrec`
  refuses a file that would reach beyond it.

## md RAID0 layout math

md RAID0 with *N* members of equal size, chunk *C* bytes, member data offset *D_m* (sectors,
`/sys/block/md0/md/dev-<member>/offset`, plus the partition start when a member is a
partition): array byte *a* lies in array chunk *A* = *a* / *C*; that chunk is on member
`A mod N` (member order = `md/rdN` slot *N*), member chunk `A div N`, i.e. at member byte

    D_m × 512 + (A div N) × C + (a mod C)

The hardware does the same: chunk *c* of a run is array chunk *A* = `START_CHUNK + c`, stored
on member `A mod N` at LBA

    MEMBER_BASE_LBA[m] + (A div N) × (C / LBA size),    MEMBER_BASE_LBA[m] = D_m × 512 / LBA size

So `nvrec` only needs `START_CHUNK` = (device offset of the file's data) / *C* and the members'
data offsets. With one SSD (no md) *N* = 1 and `MEMBER_BASE_LBA` is the partition start (0 for
the whole disk).

Worked example, 2 × SSD, `--chunk 1M` (drives with an MDTS of at least 1 MB), md data offset 264192 sectors (129 MiB) on both, 512-byte
LBAs, a file whose data starts 5 GiB into `/dev/md0`:

* `START_CHUNK` = 5 GiB / 1 MiB = 5120; chunk 0 of the run → member 5120 mod 2 = 0, member
  chunk 2560 → LBA 264192 + 2560 × 2048 = 5 507 072;
* chunk 1 → array chunk 5121 → member 1, same member chunk 2560, same LBA on the second SSD;
* chunk 2 → array chunk 5122 → member 0, LBA 264192 + 2561 × 2048.

Because the layout is md's, the array assembles on any Linux PC (`mdadm --assemble`) and the
recording is read there with `cp`.
