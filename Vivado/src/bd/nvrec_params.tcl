# Opsero Electronic Design Inc. Copyright 2026
#
# NVMe offload recorder (nvrec): per-target datapath parameters, sourced by
# bd_zynqmp.tcl and bd_versal.tcl after gt_locs.tcl.
#
# build.py / build.tcl pass only the target label to Vivado, so the per-target
# attributes of the nvrec datapath are read here from the target's entry in
# config/data.json:
#
#   "data_width": 128 | 256 | 512   fabric datapath width in bits (default 256):
#                                   source/sink streams, ingest/egress FIFOs and
#                                   the ring writer/reader AXI4 master
#   "egress_fifo_kb": <KB>          egress FIFO size in KB (optional; default by
#                                   width, see below)
#   "ring_mem": "none" | "pl_ddr4" | "lpddr4"
#                                   memory 1 of the split ring (register map
#                                   1.3, "one ring per SSD in two memories"):
#                                   pl_ddr4 = Zynq UltraScale+ PL DDR4 behind a
#                                   DDR4 controller (board interface
#                                   "ring_mem_intf", default ddr4_sdram_062) at
#                                   0x20_0000_0000; lpddr4 = Versal on-board
#                                   LPDDR4 (second NoC instance, two DDRMCs) at
#                                   DDR_CH2 0x600_0000_0000. Mapped for the ring
#                                   master nvrec_core/m_axi1 and the root ports'
#                                   bridges only, never for the CPUs. Default
#                                   none: single ring (N_RING_PORTS 1).
#   "ring_mem_intf": <board intf>   pl_ddr4 only: the DDR4 board interface of
#                                   the PL DDR4 (default ddr4_sdram_062)
#
# A variable set before the block design script runs (eg. `set
# nvrec_data_width 512` or `set nvrec_egr_fifo_kb 512` in the Tcl console
# before sourcing build.tcl) takes precedence over data.json.
#
# Derived values (byte-sized FIFOs):
#   nvrec_beat_bytes      = nvrec_data_width / 8
#   nvrec_ing_fifo_depth  = 256 KB / nvrec_beat_bytes   (ingest FIFO, beats)
#   nvrec_egr_fifo_depth  = nvrec_egr_fifo_kb KB / nvrec_beat_bytes (egress FIFO,
#                           beats); nvrec_egr_fifo_kb = 128 at 128/256 bits,
#                           256 at 512 bits: at 8+ GB/s the ring reader keeps up
#                           to 128 KB of reads in flight (32 x 4 KB), so a
#                           128 KB egress FIFO left no buffered data beyond the
#                           requests in flight and DDR read-latency spikes showed
#                           as short underflows (VCK190 playback at 8250-8500
#                           MB/s, 2026-10-23)
#   nvrec_slot_w          = 12 (ring of at most 4096 slots; register map 1.3)
#   nvrec_ring_ports      = N_RING_PORTS of nvrec_core: 2 when ring_mem is not
#                           none (second ring AXI4 master m_axi1), else 1
#   nvrec_rd_skid_depth   = ring reader skid FIFO per ring port, beats: 512
#                           (32 KB at 512 bits, 16 KB at 256 bits, block RAM),
#                           so the port that is not streaming keeps fetching
#                           ahead and a memory switch (chunk boundary with
#                           chunk-sized stripes) costs no read latency
#                           (unused with one ring port)
#   nvrec_bridge_split    = Versal only: 1 = one NoC NMU per QDMA bridge (each
#                           bridge with its own SmartConnect), 0 = both bridges
#                           share the base design's S08 NMU. Default: 1 at
#                           512 bits, else 0.

# Value of <key> in the config/data.json design entry whose "label" is <target>
# (design entries are flat JSON objects: only arrays are nested in them)
proc nvrec_target_attr {json_file target key default} {
  if {![file exists $json_file]} {
    puts "WARNING: nvrec: $json_file not found, $key = $default"
    return $default
  }
  set fh [open $json_file r]
  set text [read $fh]
  close $fh
  foreach obj [regexp -all -inline {\{[^{}]*\}} $text] {
    if {[regexp "\"label\"\\s*:\\s*\"([string map {. \\.} $target])\"" $obj]} {
      if {[regexp "\"$key\"\\s*:\\s*\"?(\[^\",\\s\}\]+)" $obj -> val]} {
        return $val
      }
      return $default
    }
  }
  return $default
}

set nvrec_json [file normalize [file join [file dirname [file normalize [info script]]] .. .. .. config data.json]]
if {![info exists nvrec_data_width]} {
  set nvrec_data_width [nvrec_target_attr $nvrec_json $target data_width 256]
}
if {[lsearch -exact {128 256 512} $nvrec_data_width] < 0} {
  error "nvrec: data_width of $target must be 128, 256 or 512 (got $nvrec_data_width)"
}
set nvrec_beat_bytes     [expr {$nvrec_data_width / 8}]
set nvrec_ing_fifo_depth [expr {262144 / $nvrec_beat_bytes}]
if {![info exists nvrec_egr_fifo_kb]} {
  set nvrec_egr_fifo_kb [nvrec_target_attr $nvrec_json $target egress_fifo_kb \
    [expr {$nvrec_data_width == 512 ? 256 : 128}]]
}
set nvrec_egr_fifo_depth [expr {$nvrec_egr_fifo_kb * 1024 / $nvrec_beat_bytes}]
if {$nvrec_egr_fifo_depth & ($nvrec_egr_fifo_depth - 1)} {
  error "nvrec: egress FIFO of $nvrec_egr_fifo_kb KB is not a power-of-2 number of $nvrec_beat_bytes-byte beats"
}
set nvrec_slot_w 12
if {![info exists nvrec_bridge_split]} {
  set nvrec_bridge_split [expr {$nvrec_data_width == 512}]
}
if {![info exists nvrec_ring_mem]} {
  set nvrec_ring_mem [nvrec_target_attr $nvrec_json $target ring_mem none]
}
if {[lsearch -exact {none pl_ddr4 lpddr4} $nvrec_ring_mem] < 0} {
  error "nvrec: ring_mem of $target must be none, pl_ddr4 or lpddr4 (got $nvrec_ring_mem)"
}
if {![info exists nvrec_ring_mem_intf]} {
  set nvrec_ring_mem_intf [nvrec_target_attr $nvrec_json $target ring_mem_intf ddr4_sdram_062]
}
set nvrec_ring_ports [expr {$nvrec_ring_mem eq "none" ? 1 : 2}]
if {![info exists nvrec_rd_skid_depth]} {
  set nvrec_rd_skid_depth [nvrec_target_attr $nvrec_json $target rd_skid_depth 512]
}
puts "INFO: nvrec $target: DATA_WIDTH $nvrec_data_width ($nvrec_beat_bytes B/beat),\
 ingest FIFO $nvrec_ing_fifo_depth beats, egress FIFO $nvrec_egr_fifo_depth beats ($nvrec_egr_fifo_kb KB),\
 SLOT_W $nvrec_slot_w, bridge NMU split $nvrec_bridge_split, reader skid $nvrec_rd_skid_depth beats, ring memory 1 $nvrec_ring_mem\
 ([expr {$nvrec_ring_mem eq "pl_ddr4" ? "$nvrec_ring_mem_intf, " : ""}]N_RING_PORTS $nvrec_ring_ports)"
