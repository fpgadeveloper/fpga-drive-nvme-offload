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
#   nvrec_slot_w          = 11 (ring of at most 2048 slots)
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
set nvrec_slot_w 11
if {![info exists nvrec_bridge_split]} {
  set nvrec_bridge_split [expr {$nvrec_data_width == 512}]
}
puts "INFO: nvrec $target: DATA_WIDTH $nvrec_data_width ($nvrec_beat_bytes B/beat),\
 ingest FIFO $nvrec_ing_fifo_depth beats, egress FIFO $nvrec_egr_fifo_depth beats ($nvrec_egr_fifo_kb KB),\
 SLOT_W $nvrec_slot_w, bridge NMU split $nvrec_bridge_split"
