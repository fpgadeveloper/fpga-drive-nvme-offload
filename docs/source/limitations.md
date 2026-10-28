# Known limitations

## Positioning

This design moves the NVMe command path into the fabric: once a recording is running, the
fabric builds every command, the AMD NVMe Host Accelerator queues it and the SSDs move the
data, with no CPU involvement. The price is a narrower, more rigid storage model than a
Linux filesystem gives you: the file must be prepared before the recording, and the SSDs
belong to the design's own driver. The limits below follow from that. If they do not suit
your application,
[fpga-drive-recorder](https://recorder.fpgadrive.com) records the same stream through the
standard Linux storage stack, with no IP license.

## Licensing

### IP license required

Every target needs a license for the AMD NVMe Host Accelerator IP (purchased or
evaluation) to build; see [Requirements](requirements.md#nvme-host-accelerator-license).
No other FPGA Drive reference design has this requirement.

### Evaluation license timeout

A bitstream built with an evaluation license contains a hardware-evaluation core that
**stops 183-184 minutes (about 3 hours) after the bitstream is loaded** (measured on the
ZCU106). Only a bitstream reload restarts it, which
for the SD-card images of this design means a power cycle; a soft reboot does not reload
the bitstream.

The expired core's register interface stops answering. Without protection, the first
processor access to it would hang the whole system. The design therefore has an AXI-Lite
timeout guard (`nvmeha_guard`) in front of the Host Accelerator: it completes such accesses
itself, flags the condition in `nvrec_core`, and checks the IP every 168 ms even when
nothing is running. The driver then:

* logs `Host Accelerator stopped responding (evaluation license expired?)` once and
  disables the SSDs, so any I/O to the block devices fails with an I/O error;
* ends a recording or playback that is running as failed, and refuses new ones:
  `nvrec` and `nvplay` exit with code 5 and say so (the fabric-only runs, which use no NVMe
  path, still work);
* keeps the rest of the system running (console, SSH, network).

A recording that is running when the core stops is lost from that point on, and its file
is not finished (see [an interrupted recording](#an-interrupted-recording)). Plan
evaluation sessions to end within about 2 h 45 min of power-on. **A single recording can
therefore not run longer than the time left before the core stops; recordings longer than
the limit need a purchased license** (see
[Troubleshooting](troubleshooting.md#extended-recordings-on-the-evaluation-core)). The
prebuilt boot images of the releases are built with the evaluation license and have this
limit. With a purchased license none of this applies.

## Recording model

* **Contiguous, preallocated file.** The hardware writes raw LBAs, so a recording must be
  one contiguous run of clusters on the exFAT volume, allocated before the hardware starts.
  `nvrec` does this for you, but it needs contiguous free space: deleting recordings in the
  middle of the volume fragments it, and `nvrec` then refuses a large file (`the free
  space of the volume is fragmented`). Reformat the volume (`nvsetup-raid0.sh`), or delete
  from the end. See [Filesystem and striping](filesystem).
* **The length is fixed in advance.** `--size` sets the length of a recording before it
  starts. A recording can be stopped early (Ctrl-C, or the source stops: the file keeps what
  was recorded), but it cannot grow beyond `--size`.
* **exFAT only, unmounted while recording.** The recording volume is exFAT (one SSD, or an
  md RAID0 array of two). `nvrec` unmounts it for the duration of the recording, so
  nothing else can use the volume meanwhile; no shell or open file may be on it. XFS and
  ext4 are not supported by the recording path.
* **exFAT valid data length.** exFAT keeps a *ValidDataLength* per file, and reads beyond
  it return zeros. `nvrec` sets it when the recording ends. Until then the file reads as
  zeros, even though the data is on the SSDs.
* **One chunk = one NVMe command, at most the drive's MDTS.** The chunk is 1 MB, or the
  drive's maximum transfer size if that is smaller (512 KB on the Samsung 980 PRO). The
  hardware does not split a chunk into several commands. With two SSDs the md RAID0 chunk
  must equal the recording chunk (`nvsetup-raid0.sh` takes care of it).
* **Ring size.** The ring has at most 4096 chunks (the hardware slot table) and 1 GB in each
  memory: a single ring up to 1 GB, a split ring (`zcu106_hpc0`, `vck190_fmcp1`) up to 2 GB.
  Its PS DDR part and the PRP lists (4 KB per slot) must fit in the CMA pool that the image
  reserves (1 GB on `uzev`, 1.5 GB on `zcu106_hpc0` and `vck190_fmcp1`, `NVREC_CMA`), its
  second-memory part in the 1 GB region the device tree reserves there. The default is 512 MB
  for a single ring and 1 GB for a split ring (512 MB in each memory) whatever the chunk; a
  1 GB single ring (1024 × 1 MB) needs 1028 MB of CMA and does not fit the 1 GB pool of
  `uzev`. At 8 GB/s a 512 MB ring covers 64 ms of SSD stall, at 12.5 GB/s a 1 GB ring 85 ms.
* **Split ring: two memories, one CPU-invisible.** The second memory of a split ring (PL DDR4
  on `zcu106_hpc0`, LPDDR4 on `vck190_fmcp1`) is reached only by the ring port and the PCIe
  root ports; Linux never maps it, so the CPU cannot read a ring there (it never needs to: the
  sample data does not pass through the CPU). `uzev` has one ring port (its PL DDR4 is 16 bits
  wide, too narrow for half of the stream) and always uses a single ring. On `zcu106_hpc0` a
  split ring needs the PL DDR4 controller calibrated (`STATE.MEM1_READY`); if it is not, the
  driver falls back to a single ring and refuses `--ring split` / `mem1`.

## SSDs

* **The design's driver owns the SSDs.** The stock Linux `nvme` driver is kept off them,
  so there is no `/dev/nvme*`, and tools that need it (such as `nvme-cli`) only work
  after you hand an SSD to the stock driver (see
  [Kernel driver](driver.md#using-the-stock-nvme-driver-reference-tests)). The driver
  exposes what a recording needs from them: the drive's identity, its MDTS, its composite
  temperature (`/sys/block/nvrecXn1/nvrec/temperature`) and its APST state.
* **One I/O queue per SSD.** The Host Accelerator has one hardware queue (64 entries) per
  SSD. The command builder uses up to 63 entries; the CPU's own I/O (block device,
  filesystem) shares the same queue through the command injector, with at most 16 commands
  outstanding for both SSDs together, so filesystem I/O is not as fast as with the stock
  driver.
* **Doorbell stride 0 and BAR0 below 4 GB.** The Host Accelerator computes the doorbell
  addresses with a 4-byte stride (`CAP.DSTRD` = 0) and reaches the SSDs through a 32-bit
  address master. The driver refuses an SSD that does not meet both (see
  [supported SSDs](supported_ssds)). On the VCK190, an SSD with a prefetchable BAR0 is
  placed above 4 GB and cannot be used.
* **Namespace 1, no metadata.** The design records to namespace 1 with 512-byte or 4 KB
  LBAs; namespaces with metadata are not supported, and the driver does not reformat a
  drive.
* **No per-command abort.** A command that times out disables the SSD's controller; unbind
  and rebind the SSD (or reboot) to bring it back.
* **Drive behaviour.** One Sabrent Rocket 2230 writes 5-8 % slower with this design than with
  fpga-drive-recorder (2.76-2.78 against 2.88-2.95 GB/s in its SLC cache on a Gen3 x4 link,
  4.21-4.23 against 4.57-4.65 GB/s on Gen4 x4); the cause has not been isolated. A drive's SLC
  cache needs idle time to recover after a long recording. See
  [Supported SSDs](supported_ssds.md#observations-with-the-tested-drives).

## Data path

* **One stream width per build.** The source and sink interfaces are 256-bit AXI4-Stream on
  the Zynq UltraScale+ designs (`zcu106_hpc0`, `uzev`) and 512-bit on the Versal design
  (`vck190_fmcp1`); 128, 256 or 512 bits are a build option (`data_width`). The data is
  recorded and played back in whole beats (32 or 64 bytes). Narrower data must be packed into
  beats of the build's width (see [custom data source](custom_source)); a partly filled last
  beat is not recorded.
* **Rate ceilings.** The source and sink run at up to one beat per `src_clk` cycle (250 MHz):
  8 GB/s at 256 bits, 16 GB/s at 512 bits. What a target sustains is lower, and measured (see
  [Ceilings at a glance](benchmarks.md#ceilings-at-a-glance)):
  * ZCU106: the split ring goes through a 128-bit HP port into PS DDR (322.19 MHz, 5.16 GB/s
    peak) and through a DDR4 controller in the PL into the PL DDR4 (~7.8 GB/s for the ring).
    The ring writer and reader stream in order and alternate between the two, so the split
    ring does not reach the PL DDR4 port's 7750 MB/s: without SSDs it records 6000 MB/s and
    plays back 6250 MB/s with whole-chunk stripes (7000 / 6750 MB/s with 4 KB stripes). Two
    Samsung 980 PRO and two Sabrent Rocket 2230 record 6000 MB/s and play back 5750 and
    6000 MB/s at the default MaxPayload of 256 bytes (5250 MB/s at 128). One drive is bound by its Gen3 x4
    slot (~2.8-3.0 GB/s write, ~3.2 GB/s read at MaxPayload 128 bytes). The UltraZed-EV has the HP port only (327.77 MHz, 5.24 GB/s peak).
  * Versal: without SSDs the split ring records 14 750 MB/s and plays back 15 000 MB/s with
    whole-chunk stripes (15 750 / 16 000 MB/s with 4 KB stripes). Two Samsung 980 PRO record
    10 000 MB/s (their write rate) and play back 11 000 MB/s sustained. Two Sabrent Rocket 2230
    record 8250 MB/s and play back 9250 MB/s, both their drives' rates. Two WD_BLACK SN8100
    (PCIe Gen5 drives at Gen4 x4) record 13 750 MB/s, their Gen4 x4 links' write rate, and play
    back 11 000 MB/s with whole-chunk stripes, 14 250 MB/s with `--stripe 4` (their links' read
    rate). **With whole-chunk stripes about 12 GB/s of playback is not reached** with any pair
    (11.84-11.95 GB/s at 12 000-14 000 MB/s sinks): the memory being read carries the stream
    and one SSD's writes, ~18 GB/s of mixed traffic. 4 KB stripes lift it only with drives
    that take them (the SN8100 pair, not the 980 PRO pair).
  * A recording crosses DDR twice (the fabric writes the ring, the SSDs read it), and the SSDs'
    own write rates, especially past their SLC cache, are usually lower still.
  * `src_clk` and `dp_clk` run at the same 250 MHz, so a source at one beat every cycle leaves
    the ingest FIFO no time to drain after a pause of the ring writer: a 256-bit datapath on
    the VCK190 (fpga-drive-recorder's) records without an SSD only up to 7750 MB/s (playback
    7500 MB/s), which is why the Versal design is 512 bits wide.
* **Fabric-only mode needs register map 1.2.** `nvrec --no-write` and `nvplay --ring-only`
  refuse to run on a bitstream of register map 1.1.
* **The split ring needs register map 1.3** and a device tree with the second memory's
  region (`memory-region`); on older bitstreams and on `uzev` the apps' `--ring auto` is a
  single ring and `--ring split` / `mem1` are refused.
* **Playback near the top fails by short underflows.** With whole-chunk stripes a playback
  close to the highest sustained rate does not fall short steadily but runs dry for short,
  intermittent moments (on `vck190_fmcp1` 11 000 MB/s was clean in 3 of 3 runs of a 40 GiB file
  on the release image but in 8 of 9 in the measurement session with the 980 PRO pair, in 8 of 9
  on three recordings with the SN8100 pair, and 11 250-11 750 MB/s in some runs only). Leave a
  margin below the published rate.
* **One SSD must stay on a single ring.** One SSD whose writes alternate between the two
  memories plays back much slower: **one Samsung 980 PRO on `zcu106_hpc0` plays only
  ~1.44 GB/s on the split ring** (12 ms read latency) against 3000 MB/s on the single ring; one
  Sabrent there ~13 % slower; one 980 PRO on `vck190_fmcp1` 5750 against 6250 MB/s with 4 KB
  stripes. The driver therefore keeps a single-SSD run on a single ring by default
  (`ring_split=auto`); loading it with `ring_split=1`, or `--ring split` on one SSD, forces the
  split and should not be used for one drive.
* **Whole-chunk stripes are essential with 512 KB chunks.** With `--stripe 4` every 512 KB
  NVMe command of a Samsung 980 PRO switches memory 128 times, and the 980 PRO pair on
  `zcu106_hpc0` plays back only ~3.8-4.0 GB/s (6.3 ms read latency at MaxPayload 128) instead
  of 5750 MB/s (5250 MB/s at 128). With the Sabrent pair's 256 KB chunks 4 KB and whole-chunk
  stripes tie in playback. Keep the default stripe (the whole chunk) unless you have measured
  the alternative with your drives: two WD_BLACK SN8100 (1 MB chunks) on `vck190_fmcp1` play
  back faster with `--stripe 4` (14 250 against 11 000 MB/s).
* **The single ring on `vck190_fmcp1`** (`--ring single`) records RAID0 at 9250 MB/s with
  drops in 3 of 3 runs (9.24-9.25 GB/s written), less than the Release 1.1 build sustained
  with the same ring; the NoC bandwidth requests and MaxPayload were ruled out, the cause was
  not isolated. The default split ring is not affected.
* **Ring port counters saturate.** `WR_PORT_STALL0/1` and `RD_PORT_WAIT0/1` are 32-bit cycle
  counters: they stop at 17 179.886 ms, which a run longer than about 17 s can reach without
  meaning anything about the memory. They are also not zero in a clean run (see
  [Kernel driver](driver.md#split-ring-one-ring-in-two-memories)).
* **No backpressure to the source.** By design, the source is never stalled. When the SSDs
  cannot keep up, beats are dropped at the ingest FIFO and counted; a recording is valid only
  if its drop count is 0. There is no mode that pauses the source instead.
* **No framing or timestamps.** The recorder adds no headers, markers or timestamps to the
  data; only the file header records the start and stop times. Put frame markers or
  timestamps into the data in your source if you need them.
* **Record and playback are not simultaneous.** The design has one `nvrec_core` with one
  ring, shared by recording and playback, and `/dev/nvrec` has one opener at a time;
  `nvrec` and `nvplay` cannot run together.
* **The playback sink shares the source clock.** `user_data_sink` runs on `src_clk`; a sink
  with its own clock needs its own clock-domain crossing inside the hierarchy (see
  [custom data sink](custom_sink)).

## An interrupted recording

* **Ctrl-C or a stalled source**: `nvrec` stops the hardware cleanly, writes the header with
  the bytes really recorded, and truncates the file to them.
* **A crash, power loss or reset during a recording** (or the evaluation core stopping):
  the file keeps its preallocated size with a *ValidDataLength* of 0, so it reads as
  zeros, and the volume is left unmounted and marked dirty. The data that reached the SSDs
  is still there: run `fsck.exfat -y` on the volume, then check or extract the data with
  `nvverify --raw` on the raw device (see [Filesystem and striping](filesystem)).

## Software

* **fsck after an unclean end.** After a power cycle with the volume mounted, run
  `fsck.exfat -y` before mounting it again; `nvrec` refuses to record on a volume that
  is marked dirty (`exFAT volume is marked dirty`).
* **RAID0 needs re-assembly after a reboot.** The image does not assemble or mount the
  array at boot; see [Applications](apps.md#nvsetup-raid0sh).
* **nvverify checks the test pattern only.** It verifies recordings made with the test
  pattern generator, per 16-byte word, at any beat size (16, 32 or 64 bytes). For your own data source it checks the header, and the drop count tells
  you whether data was lost; checking the content is up to your tools. The same holds for
  playback with your own sink (`nvplay --no-check`).
* **ASCII file names.** The volume reader in `nvrec` compares file names in ASCII.

## Platforms and tools

* **Targets.** The design is available for the targets in the
  [target table](build_instructions.md#target-designs). `zcu106_hpc0` has been tested on
  hardware in this revision with two Samsung 980 PRO 1TB (FPGA Drive FMC Gen4) and with two
  Sabrent Rocket 2230 1TB (M.2 M-key Stack FMC), and so has `vck190_fmcp1`; `uzev` is built but not
  tested on hardware in this revision (see [supported carriers](supported_carriers.md)).
* **Linux only.** There is no standalone (baremetal) application and no PetaLinux flow; the
  Linux image is built with the Yocto / EDF flow, which needs a native Linux build machine.
* **Tool version.** The repository is for Vivado / Vitis / EDF 2025.2.
