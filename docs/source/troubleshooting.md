# Troubleshooting

## The Host Accelerator stopped (exit code 5)

**Symptom:** `nvrec` or `nvplay` exits with code 5 and prints
`Host Accelerator stopped responding (evaluation license expired?): reload the bitstream (power-cycle the board) to record again`;
the kernel log has
`nvrec ...: Host Accelerator stopped responding (evaluation license expired?): NVMe I/O stopped; reload the bitstream (power-cycle the board) to continue`;
`cat /sys/class/misc/nvrec/ha_dead` reads 1; I/O to `/dev/nvrecXn1` or `/mnt/rec` fails
with an I/O error.

**Cause:** the bitstream was built with an evaluation license for the NVMe Host
Accelerator, and the evaluation core stopped, 183-184 minutes after the bitstream was
loaded (see [Known limitations](limitations.md#evaluation-license-timeout)). The rest of
the system keeps running.

**What to do:**

1. Power-cycle the board. A soft reboot (`reboot`) does not reload the bitstream; only a
   power cycle (or a full reconfiguration of the device) restarts the core.
2. Re-assemble the volume and check it, because it was mounted when the SSDs stopped:
   ```
   sudo mdadm --assemble /dev/md0 /dev/nvrec0n1 /dev/nvrec1n1   # RAID0 only
   sudo fsck.exfat -y /dev/md0                                  # or /dev/nvrec0n1
   sudo mount -o noatime /dev/md0 /mnt/rec
   ```
3. Plan your sessions to end within about 2 h 45 min of power-on, or use a purchased
   license, which has no time limit.

If the stop happens much earlier than 183 minutes after power-on, the core is not expiring:
check the kernel log for NVMe errors before the message (an SSD that stops answering
looks different: `disabling controller` with a timeout, see below).

A bitstream without the timeout guard (register map 1.0, an early build of this design)
logs `nvrec_core v1.0 has no Host Accelerator timeout guard` at boot; with that bitstream an
expired core hangs the whole system. Rebuild the image from the current sources.

## Extended recordings on the evaluation core

With an evaluation license, the Host Accelerator stops about 3 hours (183-184 minutes)
after the device was configured, i.e. after the board was powered on. A recording that is
running at that moment:

* ends with **exit code 5** (`Host Accelerator stopped responding (evaluation license expired?)`);
* leaves its file with a *ValidDataLength* of 0, so the file **reads as zeros**, although
  the data recorded up to the stop **is on the SSDs**: check or extract it from the raw
  extent with `nvverify --raw` (see [Filesystem and striping](filesystem));
* leaves the recording volume **unmounted**.

Reconfigure the device (power-cycle the board), run `fsck.exfat -y` on the volume, and
mount it again before you continue (see [above](#the-host-accelerator-stopped-exit-code-5)).
Start long recordings right after a power cycle so that they end before the limit; **for
recordings longer than the limit, a purchased (full) license is required.**

## SSDs and PCIe

### No `PCIe Link is UP`, or an SSD is missing

The PCIe part of this design is the one of fpga-drive-aximm-pcie, so its
[troubleshooting guide](https://github.com/fpgadeveloper/fpga-drive-aximm-pcie/blob/master/docs/source/troubleshooting.md)
applies as well. Work through these in order:

1. **Is the mezzanine card on the right connector?** Each target design is built for one
   FMC connector (see the [target designs](build_instructions.md#target-designs)). A design
   built for another connector cannot see the SSDs.
2. **Is the card seated, and the SSD?** Re-seat the mezzanine card on the FMC connector and
   the SSD in its M.2 slot, and tighten the SSD's screw.
3. **Is VADJ on?** The FMC signals that release the SSDs from reset are powered by the
   carrier's VADJ supply. On the **VCK190**, the image's U-Boot script enables VADJ itself
   and prints `FPGA Drive FMC: enabling VADJ (1.5V) via IR38164` on the console before
   Linux starts; if that line is missing, the SD card holds another image (or an old
   `boot.scr`), and the SSDs never link up. On the other boards, check the carrier's VADJ
   setting against the [FMC card's requirements](https://docs.opsero.com/op063/datasheet/overview/).
4. **Is the right image running?** The boot log should show this design's driver line
   (`nvrec ... /dev/nvrec: nvrec_core v1.1 ...`). A card that holds another design's image
   has another bitstream.
5. **Check the link** with `dmesg | grep -i "pcie link"` and
   `sudo lspci -vv | grep -E "LnkCap|LnkSta"` (see [Test the design in Linux](linux_test)).
   A link that trains slower or narrower than the design supports points to a seating or
   signal problem: try the SSD in the other slot, or another SSD.

### The SSD is in `lspci` but there is no `/dev/nvrecXn1`

The SSD must be bound to the design's `nvrec-nvme` driver. Check which driver has it and
what the driver said:

```
lspci -k | grep -A3 -i "non-volatile"
dmesg | grep -E "nvrec|SSD[01]"
```

* **`Kernel driver in use: nvme`** — the stock driver took the SSD (for example after a
  `modprobe nvme`). Hand it back as described in
  [Kernel driver](driver.md#using-the-stock-nvme-driver-reference-tests).
* **No driver in use, and `nvrec-nvme` printed an error** for the SSD — the drive does not
  meet one of the design's requirements (see [supported SSDs](supported_ssds)):
  * `doorbell stride N bytes: the NVMe Host Accelerator assumes 4` — the drive's
    `CAP.DSTRD` is not 0. It cannot be used with this design.
  * `BAR0 at ... is at or above 4 GB: the NVMe Host Accelerator's doorbell master has 32 address bits` —
    the root port placed the SSD's BAR in its 64-bit window, which happens on the VCK190
    with an SSD whose BAR0 is prefetchable. Use another SSD.
  * `namespace 1 uses N bytes of metadata per LBA` — reformat the namespace without
    metadata on a PC (`nvme format`), or use another SSD.
  * `queue depth 64 exceeds the controller's MQES` — the drive's queues are shorter than
    the Host Accelerator's; use another SSD.
  * `not bringing the SSD up: the Host Accelerator is not responding` — see
    [above](#the-host-accelerator-stopped-exit-code-5).
* **`no "opsero,ssd-ports": no SSD will be claimed`**, or no `nvrec` line at all — the
  device tree has no (or an incomplete) `compatible = "opsero,nvrec"` node. It is added by
  the board's `system-user.dtsi` (`Yocto/bsp/<board>/`); check with
  `find /proc/device-tree -name "*nvrec*"`.

### No `/dev/nvrec`

```
lsmod | grep nvrec
dmesg | grep nvrec
```

* **The module is not loaded:** load it with `sudo modprobe nvrec` and look at the kernel
  log. The module must match the running kernel; after you rebuild the kernel, rebuild the
  image so that both come from the same build.
* **`no nvrec_core at this address`** or **`unsupported nvrec_core VERSION 0x...`:** the
  bitstream in `BOOT.BIN` is not this design (or not a compatible version), or the device
  tree describes hardware that is not in the bitstream. Rebuild the image from the matching
  XSA (`./build.sh yocto`), and copy the new `BOOT.BIN` to the SD card together with the
  rest of the image.
* **`the Host Accelerator is not answering: /dev/nvrec only reports the status`:** the
  module was loaded after the evaluation core stopped; power-cycle the board.

## Recording

### `nvrec` refuses to start

| Message | Cause and fix |
|---|---|
| `... is on ... (...), not exFAT: format the recording volume with nvsetup-raid0.sh` | The file is not on the exFAT recording volume. Prepare it with `nvsetup-raid0.sh` and record into `/mnt/rec`. |
| `--chunk N exceeds the SSDs' maximum transfer size (M)` (kernel log: `chunk of N bytes exceeds the maximum transfer size (MDTS) of nvrecXn1 (M bytes)`) | One chunk is one NVMe command and cannot exceed the drives' MDTS. Use a chunk of at most M bytes, or leave `--chunk` out. |
| `... has an md chunk of N bytes: use --chunk N` | The md array was made with another chunk than the one requested. Leave `--chunk` out (`nvrec` follows the array), or re-create the volume with `nvsetup-raid0.sh --chunk`. |
| `unmount /mnt/rec (close every file and shell on it): Device or resource busy` | A shell or a program is using the volume. `cd` out of `/mnt/rec`, close the files (`fuser -vm /mnt/rec` shows who), and try again. |
| `... is not contiguous: the free space of the volume is fragmented` | Deleted recordings left holes in the volume. Delete from the end of the volume, or reformat it (`nvsetup-raid0.sh`). |
| `exFAT volume is marked dirty (mounted, or not cleanly unmounted: run fsck.exfat)` | The volume was not unmounted cleanly (power cycle, crash). Unmount it, run `sudo fsck.exfat -y /dev/md0` (or the single SSD), and mount it again. |
| `ring of ... needs N MB of CMA ... but the kernel's CMA pool is only M MB`, or `cannot allocate the ring: ... CMA free ...` (kernel log: `cannot allocate a N MB ring (CMA too small? cma= kernel argument)`) | The CMA pool is too small or fragmented for the ring. Use fewer `--buffers` (or a smaller chunk), or raise `NVREC_CMA` in `Yocto/bsp/<target>/conf/local.conf.append` and rebuild the image. `grep Cma /proc/meminfo` shows the pool. |
| `/dev/nvrec: Device or resource busy (another recorder/player is running)` | Only one program can use the recorder at a time: `nvrec` and `nvplay` cannot run together. Check `ps aux \| grep -E "nvrec\|nvplay"`. |
| `the recording would end at byte ... beyond ... (end of the device or of the md RAID0 stripe zone)` | Not enough room after the file's position. Free space at the end of the volume, or record less. |

### Beats are dropped (`nvrec` exits with code 2)

A drop means the data arrived while the ring had no free chunk, because the SSDs were not
completing the writes fast enough. In order of likelihood:

1. **The rate is above what the SSDs sustain.** Find the sustained rate with `nvbench.sh`
   (32 GB per step) and record below it. A rate that works for 10 GB may fail for longer
   recordings.
2. **The SLC cache ran out.** If the drops start after a fixed amount of data, the SSD's
   write cache filled up; see [supported SSDs](supported_ssds.md#choosing-ssds-for-recording).
   Use a lower rate, a larger or faster SSD, or RAID0.
3. **The ring is too small for the SSDs' write stalls.** The default ring is 256 MB; more
   chunks (`--buffers`, up to 1024) absorb longer stalls, within the CMA pool. The `ring high-water` figure in the summary
   shows how much of the ring was used.
4. **Other I/O on the same SSDs** during the recording, or a nearly full volume.

`nvverify` shows where the gaps are (file offsets), which tells you whether they are at the
start, after a fixed amount (cache) or spread over the file (rate too high).

### Recording stops with `stalled: no NVMe command completed for ... s` (exit code 1)

`nvrec` has a stall watchdog (`--timeout`, default 10 s). If no command completes for that
long, it aborts the recording, finishes the file with what was recorded, and exits with
code 1. Two causes:

* **The source stopped producing data** (a custom source that is not enabled, or
  `--no-tpg` with nothing driving the stream): no chunk fills, so no command is issued.
  Check the source's clock, its enable and its `TVALID` (see
  [custom data source](custom_source)). A source that is legitimately slower than one chunk
  per `--timeout` needs a larger `--timeout`.
* **An SSD stopped completing commands**: the message then shows commands in flight. Check
  `dmesg` for `disabling controller` or NVMe errors.

### NVMe errors (`nvrec` exits with code 1, `nvme_errors` > 0)

The SSD completed a command with an error status. The summary prints
`last NVMe error: status 0x... on SSD<n>`; the kernel log may have more. Typical causes are
a recording past the end of the namespace (prevented by `nvrec`) or a failing drive. Run the
same recording on the other SSD to tell the two apart.

## Playback

### `nvplay` reports underflows (exit code 2)

The sink consumed faster than the SSDs delivered the data.

* **No `--rate`, or a rate above the read rate.** The checker's default rate is one beat
  per clock (3.2 GB/s); give `nvplay --rate` below the read rate of your SSDs.
* **Read stalls.** Isolated underflow bursts near the read rate are read stalls longer than
  the ring lasts at that rate; more chunks (`--buffers`) absorb them.

### `nvplay` stalls and gives up (`--no-check`)

With `--no-check`, the driver does not enable the checker. On the reference design the
checker is the sink, and while it is disabled it holds `TREADY` low, so the stream stalls
and `nvplay` gives up after `--timeout` seconds with exit code 1. Drop `--no-check`, or
enable the sink by hand (`sudo nvregs wr core 0x060 1`). With your own sink, make sure it
is enabled and consuming (see [custom data sink](custom_sink)).

## After a power cycle

* **`/mnt/rec` is empty or not mounted:** the image does not assemble the RAID0 array or
  mount the volume at boot. `sudo mdadm --assemble /dev/md0 /dev/nvrec0n1 /dev/nvrec1n1`,
  then `sudo mount -o noatime /dev/md0 /mnt/rec`.
* **`mount` fails, or `nvrec` reports a dirty volume:** run `sudo fsck.exfat -y /dev/md0`
  first (the board was switched off with the volume mounted).
* **A file that reads as zeros:** it was being recorded when the board lost power, or when
  the evaluation core stopped; its *ValidDataLength* was never set. The data is on the
  SSDs; see [Known limitations](limitations.md#an-interrupted-recording).

## Boot and SD card

* **The board does not boot from a freshly written card.** Check that `BOOT.BIN` was
  copied onto the card's first (FAT) partition — the EDF disk image leaves it empty (see
  [Yocto](yocto.md#boot-from-sd-card)) — and that the boot-mode switches select the SD card
  ([board specific notes](supported_carriers.md#board-specific-notes)). If the card was
  written with `dd`, write it again with `bmaptool` and let it verify.
* **The board boots another design.** The card holds an older image or the old `BOOT.BIN`;
  the boot log's `nvrec_core v1.1` line identifies this design's bitstream.

## Build failures

1. **License errors for `nvmeha` / `nvmehc` during synthesis.** The NVMe Host Accelerator
   license is missing, expired or not visible to Vivado. Install it and check the Vivado
   License Manager (see [Build instructions](build_instructions.md#license-requirements)).
   `IP license key 'nvmehc@2019.04' is enabled with a Hardware_Evaluation license` is not an
   error: it confirms an evaluation license.
2. **Are you using the correct version of Vivado for this version of the repository?**
   The design needs Vivado, Vitis and EDF 2025.2 (see [Requirements](requirements)).
3. **Does the target need Vivado Enterprise?** The `vck190_fmcp1` target does (XCVC1902).
4. **Did you change the RTL?** A module-reference top must be a Verilog (`.v`) or VHDL
   file; Vivado 2025.2 rejects a SystemVerilog top (`[filemgmt 56-195]`).
5. **Yocto on Windows or WSL** is not supported; build the XSA there and the Yocto image
   on a native Linux machine (see [Build instructions](build_instructions)).
6. **A change to the driver or the apps does not show up in the image:** the Yocto stage
   is skipped when the images exist; delete `Yocto/<target>/images/linux/` and build again
   (see [Yocto](yocto.md#how-to-build)).
