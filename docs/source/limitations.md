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
* **Ring size.** The ring has at most 2048 chunks (the hardware slot table) and 1 GB, and it
  and its PRP lists (4 KB per slot) must fit in the CMA pool that the image reserves (1 GB on
  `uzev`, 1.5 GB on `zcu106_hpc0` and `vck190_fmcp1`, `NVREC_CMA`). The default is 512 MB
  whatever the chunk (2048 × 256 KB, 1024 × 512 KB, 512 × 1 MB); a 1 GB ring
  (1024 × 1 MB) needs 1028 MB and does not fit the 1 GB pool of `uzev`. At 8 GB/s the
  default ring covers 64 ms of SSD stall.

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
* **Drive behaviour.** One Sabrent Rocket 2230 writes ~5 % slower with this design than with
  fpga-drive-recorder, on Gen3 and Gen4 links, in and past its SLC cache (~1.73 against
  ~1.8 GB/s past it; the cause has not been isolated), and both drives wrote 3-5 % slower after
  about 4.9 TB had been written to them in one night. See
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
  * Zynq UltraScale+: the ring goes through one 128-bit HP port into DDR, at 322.19 MHz on the
    ZCU106 (5.16 GB/s peak; 327.77 MHz and 5.24 GB/s on the UltraZed-EV). Recording, with or
    without SSDs, is clean up to 5000 MB/s. RAID0 playback holds 4250 MB/s with two Samsung
    980 PRO and 4500 MB/s with two Sabrent Rocket 2230: the SSDs writing DDR and the ring reader
    reading it share the DDR. One drive is bound
    by its Gen3 x4 slot (~2.8-3.0 GB/s write, ~3.2 GB/s read at MaxPayload 128 bytes).
  * Versal: without SSDs the 512-bit datapath records 14 500 MB/s and plays back 13 750 MB/s.
    With two Samsung 980 PRO the single DDR4 controller sets the limit, since every byte crosses
    it twice: 9250 MB/s recording, 8750 MB/s playback. With two Sabrent Rocket 2230 the drives
    do: 7750 MB/s recording, 7500 MB/s sustained playback (8750 MB/s for a 10 GiB file; short
    underflows above 7500 MB/s over long files).
  * A recording crosses DDR twice (the fabric writes the ring, the SSDs read it), and the SSDs'
    own write rates, especially past their SLC cache, are usually lower still.
  * `src_clk` and `dp_clk` run at the same 250 MHz, so a source at one beat every cycle leaves
    the ingest FIFO no time to drain after a pause of the ring writer: a 256-bit Versal build
    records without an SSD only up to 7750 MB/s (playback 7500 MB/s), which is why the Versal
    design is 512 bits wide.
* **Fabric-only mode needs register map 1.2.** `nvrec --no-write` and `nvplay --ring-only`
  refuse to run on a bitstream of the previous revision (register map 1.1).
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
  [target table](build_instructions.md#target-designs). `zcu106_hpc0` and `vck190_fmcp1` have
  been tested on hardware in this revision, each with two Samsung 980 PRO 1TB (FPGA Drive FMC
  Gen4) and with two Sabrent Rocket 2230 1TB (M.2 M-key Stack FMC); `uzev` is built but not
  tested on hardware in this revision (see [supported carriers](supported_carriers.md)).
* **Linux only.** There is no standalone (baremetal) application and no PetaLinux flow; the
  Linux image is built with the Yocto / EDF flow, which needs a native Linux build machine.
* **Tool version.** The repository is for Vivado / Vitis / EDF 2025.2.
