################################################################
# Block design build script for Versal designs
################################################################

# This design follows the Versal PL QDMA Root Port CED from 2025.2.1 but it has been
# adapted to work with the Opsero FPGA Drive FMC Gen4 and M.2 M-key Stack FMCs.
#
# Information on the CEDs:
# - VCK190 CED: 1x PCIe Gen4 (16GT/s) 8-lane design
# - VPK120 CED: 1x PCIe Gen5 (32GT/s) 4-lane design
#
# Our designs deviate from the CEDs in the following ways:
# - VCK190_FMCP1/2, VMK180_FMCP1/2, VEK280: 2x PCIe Gen4 (16GT/s) 4-lane
# - VHK158, VPK120, VPK180: 1x PCIe Gen5 (32GT/s) 4-lane
#
# FPGA Drive NVMe offload recorder (nvrec). The CIPS, NoC/DDR, QDMA root ports
# (incl. the 2 PCIe PIPE pipeline stages), clocks, resets and GT locations are
# those of fpga-drive-recorder / fpga-drive-aximm-pcie, unchanged; the
# NVMe offload datapath (nvrec_core + AMD NVMe Host Accelerator) is added at
# the end and mirrors bd_zynqmp.tcl. Only vck190_fmcp1 is supported (dual
# design, 2x X4).

# CHECKING IF PROJECT EXISTS
if { [get_projects -quiet] eq "" } {
   puts "ERROR: Please open or create a project!"
   return 1
}

set cur_design [current_bd_design -quiet]
set list_cells [get_bd_cells -quiet]

create_bd_design $block_name

current_bd_design $block_name

set parentCell [get_bd_cells /]

# Get object for parentCell
set parentObj [get_bd_cells $parentCell]
if { $parentObj == "" } {
   puts "ERROR: Unable to find parent cell <$parentCell>!"
   return
}

# Make sure parentObj is hier blk
set parentType [get_property TYPE $parentObj]
if { $parentType ne "hier" } {
   puts "ERROR: Parent <$parentObj> has TYPE = <$parentType>. Expected to be <hier>."
   return
}

# Save current instance; Restore later
set oldCurInst [current_bd_instance .]

# Set parent object as current
current_bd_instance $parentObj

# Returns true if str contains substr
proc str_contains {str substr} {
  if {[string first $substr $str] == -1} {
    return 0
  } else {
    return 1
  }
}

# nvrec datapath parameters of this target (nvrec_data_width, FIFO depths,
# nvrec_bridge_split, ...)
source [file join [file dirname [file normalize [info script]]] nvrec_params.tcl]

# Target board checks
set is_vck190 [str_contains $target "vck190"]
set is_vmk180 [str_contains $target "vmk180"]
set is_vek280 [str_contains $target "vek280"]
set is_vpk120 [str_contains $target "vpk120"]
set is_vpk180 [str_contains $target "vpk180"]
set is_vhk158 [str_contains $target "vhk158"]

# GT type
if {$is_vck190 || $is_vmk180} {
  set gt_type "GTY"
} else {
  set gt_type "GTYP"
}

# Work out the ref board label
set ref_board [string toupper $target]
set underscore_pos [string first "_" $ref_board]
if {$underscore_pos != -1} {
  set ref_board [string range $ref_board 0 [expr {$underscore_pos - 1}]]
}

# PCIe LOCs
if {$dual_design} {
  set pcie_blk_locn [list [dict get $gt_loc_dict $target 0 pcie] [dict get $gt_loc_dict $target 1 pcie]]
} else {
  set pcie_blk_locn [list [dict get $gt_loc_dict $target 0 pcie] ]
}

# BAR addresses and sizes
set bar_addr { 0x000A8000000 0x000B0000000 }
set bar_size { 128M 256M }
set qdma_cfg_addr { 0x400000000 0x440000000 }

# List of interrupt pins
set intr_list {}

# Add the CIPS
create_bd_cell -type ip -vlnv xilinx.com:ip:versal_cips versal_cips_0

# Configure the CIPS using automation feature
if {$is_vpk120 || $is_vek280 || $is_vpk180} {
  apply_bd_automation -rule xilinx.com:bd_rule:cips -config { \
    board_preset {Yes} \
    boot_config {Custom} \
    configure_noc {Add new AXI NoC} \
    debug_config {JTAG} \
    design_flow {Full System} \
    mc_type {LPDDR} \
    num_mc_ddr {None} \
    num_mc_lpddr {1} \
    pl_clocks {None} \
    pl_resets {None} \
  }  [get_bd_cells versal_cips_0]
} else {
  apply_bd_automation -rule xilinx.com:bd_rule:cips -config { \
    board_preset {Yes} \
    boot_config {Custom} \
    configure_noc {Add new AXI NoC} \
    debug_config {JTAG} \
    design_flow {Full System} \
    mc_type {DDR} \
    num_mc_ddr {1} \
    num_mc_lpddr {None} \
    pl_clocks {None} \
    pl_resets {None} \
  }  [get_bd_cells versal_cips_0]
}

# Extra config for this design:
# PL CLK0 output clock enabled 250MHz
# Enable interrupts: IRO0-IRQ5
# NoC interfaces: PS to NoC Interface 0 + 1 (no NoC to PS interface, see NoC
# config comment further down)
# PS-PL interfaces: PL Resets 1, Enable M_AXI_FPD 128 + M_AXI_LPD 128

if {$is_vpk120 || $is_vpk180} {
  set_property -dict [list \
    CONFIG.CLOCK_MODE {Custom} \
    CONFIG.PS_PL_CONNECTIVITY_MODE {Custom} \
    CONFIG.PS_PMC_CONFIG { \
      CLOCK_MODE {Custom} \
      DDR_MEMORY_MODE {Connectivity to DDR via NOC} \
      DEBUG_MODE {JTAG} \
      DESIGN_MODE {1} \
      DEVICE_INTEGRITY_MODE {Sysmon temperature voltage and external IO monitoring} \
      PMC_CRP_PL0_REF_CTRL_FREQMHZ {250} \
      PMC_GPIO0_MIO_PERIPHERAL {{ENABLE 1} {IO {PMC_MIO 0 .. 25}}} \
      PMC_GPIO1_MIO_PERIPHERAL {{ENABLE 1} {IO {PMC_MIO 26 .. 51}}} \
      PMC_MIO37 {{AUX_IO 0} {DIRECTION out} {DRIVE_STRENGTH 8mA} {OUTPUT_DATA high} {PULL pullup} {SCHMITT 0} {SLEW slow} {USAGE GPIO}} \
      PMC_QSPI_FBCLK {{ENABLE 1} {IO {PMC_MIO 6}}} \
      PMC_QSPI_PERIPHERAL_DATA_MODE {x4} \
      PMC_QSPI_PERIPHERAL_ENABLE {1} \
      PMC_QSPI_PERIPHERAL_MODE {Dual Parallel} \
      PMC_REF_CLK_FREQMHZ {33.3333} \
      PMC_SD1 {{CD_ENABLE 1} {CD_IO {PMC_MIO 28}} {POW_ENABLE 1} {POW_IO {PMC_MIO 51}} {RESET_ENABLE 0} {RESET_IO {PMC_MIO 12}} {WP_ENABLE 0} {WP_IO {PMC_MIO 1}}} \
      PMC_SD1_PERIPHERAL {{CLK_100_SDR_OTAP_DLY 0x3} {CLK_200_SDR_OTAP_DLY 0x2} {CLK_50_DDR_ITAP_DLY 0x36} {CLK_50_DDR_OTAP_DLY 0x3} {CLK_50_SDR_ITAP_DLY 0x2C} {CLK_50_SDR_OTAP_DLY 0x4} {ENABLE 1} {IO {PMC_MIO 26 .. 36}}} \
      PMC_SD1_SLOT_TYPE {SD 3.0} \
      PMC_USE_PMC_NOC_AXI0 {1} \
      PS_BOARD_INTERFACE {ps_pmc_fixed_io} \
      PS_ENET0_MDIO {{ENABLE 1} {IO {PS_MIO 24 .. 25}}} \
      PS_ENET0_PERIPHERAL {{ENABLE 1} {IO {PS_MIO 0 .. 11}}} \
      PS_GEN_IPI0_ENABLE {1} \
      PS_GEN_IPI0_MASTER {A72} \
      PS_GEN_IPI1_ENABLE {1} \
      PS_GEN_IPI2_ENABLE {1} \
      PS_GEN_IPI3_ENABLE {1} \
      PS_GEN_IPI4_ENABLE {1} \
      PS_GEN_IPI5_ENABLE {1} \
      PS_GEN_IPI6_ENABLE {1} \
      PS_HSDP_EGRESS_TRAFFIC {JTAG} \
      PS_HSDP_INGRESS_TRAFFIC {JTAG} \
      PS_HSDP_MODE {NONE} \
      PS_I2C0_PERIPHERAL {{ENABLE 1} {IO {PMC_MIO 46 .. 47}}} \
      PS_I2C1_PERIPHERAL {{ENABLE 1} {IO {PMC_MIO 44 .. 45}}} \
      PS_I2CSYSMON_PERIPHERAL {{ENABLE 0} {IO {PMC_MIO 39 .. 40}}} \
      PS_IRQ_USAGE {{CH0 1} {CH1 1} {CH10 0} {CH11 0} {CH12 0} {CH13 0} {CH14 0} {CH15 0} {CH2 1} {CH3 1} {CH4 1} {CH5 1} {CH6 0} {CH7 0} {CH8 0} {CH9 0}} \
      PS_MIO7 {{AUX_IO 0} {DIRECTION in} {DRIVE_STRENGTH 8mA} {OUTPUT_DATA default} {PULL disable} {SCHMITT 0} {SLEW slow} {USAGE Reserved}} \
      PS_MIO9 {{AUX_IO 0} {DIRECTION in} {DRIVE_STRENGTH 8mA} {OUTPUT_DATA default} {PULL disable} {SCHMITT 0} {SLEW slow} {USAGE Reserved}} \
      PS_NUM_FABRIC_RESETS {1} \
      PS_PCIE_EP_RESET1_IO {PS_MIO 18} \
      PS_PCIE_EP_RESET2_IO {PS_MIO 19} \
      PS_PCIE_RESET {ENABLE 1} \
      PS_PL_CONNECTIVITY_MODE {Custom} \
      PS_UART0_PERIPHERAL {{ENABLE 1} {IO {PMC_MIO 42 .. 43}}} \
      PS_USB3_PERIPHERAL {{ENABLE 1} {IO {PMC_MIO 13 .. 25}}} \
      PS_USE_FPD_AXI_NOC0 {1} \
      PS_USE_FPD_AXI_NOC1 {1} \
      PS_USE_FPD_CCI_NOC {1} \
      PS_USE_FPD_CCI_NOC0 {1} \
      PS_USE_M_AXI_FPD {1} \
      PS_USE_M_AXI_LPD {1} \
      PS_USE_NOC_FPD_AXI0 {0} \
      PS_USE_NOC_LPD_AXI0 {1} \
      PS_USE_PMCPL_CLK0 {1} \
      PS_USE_PMCPL_CLK1 {0} \
      PS_USE_PMCPL_CLK2 {0} \
      PS_USE_PMCPL_CLK3 {0} \
      SMON_ALARMS {Set_Alarms_On} \
      SMON_ENABLE_TEMP_AVERAGING {0} \
      SMON_INTERFACE_TO_USE {I2C} \
      SMON_PMBUS_ADDRESS {0x18} \
      SMON_TEMP_AVERAGING_SAMPLES {0} \
    } \
  ] [get_bd_cells versal_cips_0]
} elseif {$is_vek280} {
  set_property -dict [list \
    CONFIG.CLOCK_MODE {Custom} \
    CONFIG.PS_PL_CONNECTIVITY_MODE {Custom} \
    CONFIG.PS_PMC_CONFIG { \
      CLOCK_MODE {Custom} \
      DDR_MEMORY_MODE {Connectivity to DDR via NOC} \
      DEBUG_MODE {JTAG} \
      DESIGN_MODE {1} \
      DEVICE_INTEGRITY_MODE {Sysmon temperature voltage and external IO monitoring} \
      PMC_CRP_PL0_REF_CTRL_FREQMHZ {250} \
      PMC_GPIO0_MIO_PERIPHERAL {{ENABLE 1} {IO {PMC_MIO 0 .. 25}}} \
      PMC_GPIO1_MIO_PERIPHERAL {{ENABLE 1} {IO {PMC_MIO 26 .. 51}}} \
      PMC_MIO12 {{AUX_IO 0} {DIRECTION out} {DRIVE_STRENGTH 8mA} {OUTPUT_DATA default} {PULL pullup} {SCHMITT 0} {SLEW slow} {USAGE GPIO}} \
      PMC_MIO37 {{AUX_IO 0} {DIRECTION out} {DRIVE_STRENGTH 8mA} {OUTPUT_DATA high} {PULL pullup} {SCHMITT 0} {SLEW slow} {USAGE GPIO}} \
      PMC_MIO38 {{AUX_IO 0} {DIRECTION out} {DRIVE_STRENGTH 8mA} {OUTPUT_DATA high} {PULL pullup} {SCHMITT 0} {SLEW slow} {USAGE GPIO}} \
      PMC_OSPI_PERIPHERAL {{ENABLE 1} {IO {PMC_MIO 0 .. 11}} {MODE Single}} \
      PMC_REF_CLK_FREQMHZ {33.3333} \
      PMC_SD1 {{CD_ENABLE 1} {CD_IO {PMC_MIO 28}} {POW_ENABLE 1} {POW_IO {PMC_MIO 51}} {RESET_ENABLE 0} {RESET_IO {PMC_MIO 12}} {WP_ENABLE 0} {WP_IO {PMC_MIO 1}}} \
      PMC_SD1_PERIPHERAL {{CLK_100_SDR_OTAP_DLY 0x3} {CLK_200_SDR_OTAP_DLY 0x2} {CLK_50_DDR_ITAP_DLY 0x36} {CLK_50_DDR_OTAP_DLY 0x3} {CLK_50_SDR_ITAP_DLY 0x2C} {CLK_50_SDR_OTAP_DLY 0x4} {ENABLE 1} {IO {PMC_MIO 26 .. 36}}} \
      PMC_SD1_SLOT_TYPE {SD 3.0} \
      PMC_USE_PMC_NOC_AXI0 {1} \
      PS_BOARD_INTERFACE {ps_pmc_fixed_io} \
      PS_CAN0_PERIPHERAL {{ENABLE 1} {IO {PS_MIO 14 .. 15}}} \
      PS_CAN1_PERIPHERAL {{ENABLE 1} {IO {PS_MIO 16 .. 17}}} \
      PS_CRL_CAN0_REF_CTRL_FREQMHZ {160} \
      PS_CRL_CAN1_REF_CTRL_FREQMHZ {160} \
      PS_ENET0_MDIO {{ENABLE 1} {IO {PS_MIO 24 .. 25}}} \
      PS_ENET0_PERIPHERAL {{ENABLE 1} {IO {PS_MIO 0 .. 11}}} \
      PS_GEN_IPI0_ENABLE {1} \
      PS_GEN_IPI0_MASTER {A72} \
      PS_GEN_IPI1_ENABLE {1} \
      PS_GEN_IPI2_ENABLE {1} \
      PS_GEN_IPI3_ENABLE {1} \
      PS_GEN_IPI4_ENABLE {1} \
      PS_GEN_IPI5_ENABLE {1} \
      PS_GEN_IPI6_ENABLE {1} \
      PS_HSDP_EGRESS_TRAFFIC {JTAG} \
      PS_HSDP_INGRESS_TRAFFIC {JTAG} \
      PS_HSDP_MODE {NONE} \
      PS_I2C0_PERIPHERAL {{ENABLE 1} {IO {PMC_MIO 46 .. 47}}} \
      PS_I2C1_PERIPHERAL {{ENABLE 1} {IO {PMC_MIO 44 .. 45}}} \
      PS_I2CSYSMON_PERIPHERAL {{ENABLE 0} {IO {PMC_MIO 39 .. 40}}} \
      PS_IRQ_USAGE {{CH0 1} {CH1 1} {CH10 0} {CH11 0} {CH12 0} {CH13 0} {CH14 0} {CH15 0} {CH2 1} {CH3 1} {CH4 1} {CH5 1} {CH6 0} {CH7 0} {CH8 0} {CH9 0}} \
      PS_MIO7 {{AUX_IO 0} {DIRECTION in} {DRIVE_STRENGTH 8mA} {OUTPUT_DATA default} {PULL disable} {SCHMITT 0} {SLEW slow} {USAGE Reserved}} \
      PS_MIO9 {{AUX_IO 0} {DIRECTION in} {DRIVE_STRENGTH 8mA} {OUTPUT_DATA default} {PULL disable} {SCHMITT 0} {SLEW slow} {USAGE Reserved}} \
      PS_NUM_FABRIC_RESETS {1} \
      PS_PCIE_EP_RESET1_IO {PS_MIO 18} \
      PS_PCIE_EP_RESET2_IO {PS_MIO 19} \
      PS_PCIE_RESET {ENABLE 1} \
      PS_PL_CONNECTIVITY_MODE {Custom} \
      PS_UART0_PERIPHERAL {{ENABLE 1} {IO {PMC_MIO 42 .. 43}}} \
      PS_USB3_PERIPHERAL {{ENABLE 1} {IO {PMC_MIO 13 .. 25}}} \
      PS_USE_FPD_AXI_NOC0 {1} \
      PS_USE_FPD_AXI_NOC1 {1} \
      PS_USE_FPD_CCI_NOC {1} \
      PS_USE_FPD_CCI_NOC0 {1} \
      PS_USE_M_AXI_FPD {1} \
      PS_USE_M_AXI_LPD {1} \
      PS_USE_NOC_FPD_AXI0 {0} \
      PS_USE_NOC_LPD_AXI0 {1} \
      PS_USE_PMCPL_CLK0 {1} \
      PS_USE_PMCPL_CLK1 {0} \
      PS_USE_PMCPL_CLK2 {0} \
      PS_USE_PMCPL_CLK3 {0} \
      SMON_ALARMS {Set_Alarms_On} \
      SMON_ENABLE_TEMP_AVERAGING {0} \
      SMON_INTERFACE_TO_USE {I2C} \
      SMON_PMBUS_ADDRESS {0x18} \
      SMON_TEMP_AVERAGING_SAMPLES {0} \
    } \
  ] [get_bd_cells versal_cips_0]
} elseif {$is_vhk158} {
  set_property -dict [list \
    CONFIG.CLOCK_MODE {Custom} \
    CONFIG.PS_PL_CONNECTIVITY_MODE {Custom} \
    CONFIG.PS_PMC_CONFIG { \
      CLOCK_MODE {Custom} \
      DDR_MEMORY_MODE {Connectivity to DDR via NOC} \
      DEBUG_MODE {JTAG} \
      DESIGN_MODE {1} \
      DEVICE_INTEGRITY_MODE {Sysmon temperature voltage and external IO monitoring} \
      PMC_CRP_PL0_REF_CTRL_FREQMHZ {250} \
      PMC_GPIO0_MIO_PERIPHERAL {{ENABLE 1} {IO {PMC_MIO 0 .. 25}}} \
      PMC_GPIO1_MIO_PERIPHERAL {{ENABLE 1} {IO {PMC_MIO 26 .. 51}}} \
      PMC_MIO12 {{AUX_IO 0} {DIRECTION out} {DRIVE_STRENGTH 8mA} {OUTPUT_DATA default} {PULL pullup} {SCHMITT 0} {SLEW slow} {USAGE GPIO}} \
      PMC_MIO37 {{AUX_IO 0} {DIRECTION out} {DRIVE_STRENGTH 8mA} {OUTPUT_DATA high} {PULL pullup} {SCHMITT 0} {SLEW slow} {USAGE GPIO}} \
      PMC_OSPI_PERIPHERAL {{ENABLE 1} {IO {PMC_MIO 0 .. 11}} {MODE Single}} \
      PMC_REF_CLK_FREQMHZ {33.333} \
      PMC_SD1 {{CD_ENABLE 1} {CD_IO {PMC_MIO 28}} {POW_ENABLE 1} {POW_IO {PMC_MIO 51}} {RESET_ENABLE 0} {RESET_IO {PMC_MIO 12}} {WP_ENABLE 0} {WP_IO {PMC_MIO 1}}} \
      PMC_SD1_PERIPHERAL {{CLK_100_SDR_OTAP_DLY 0x3} {CLK_200_SDR_OTAP_DLY 0x2} {CLK_50_DDR_ITAP_DLY 0x2A} {CLK_50_DDR_OTAP_DLY 0x3} {CLK_50_SDR_ITAP_DLY 0x25} {CLK_50_SDR_OTAP_DLY 0x4} {ENABLE 1} {IO {PMC_MIO 26 .. 36}}} \
      PMC_SD1_SLOT_TYPE {SD 3.0 AUTODIR} \
      PMC_USE_PMC_NOC_AXI0 {1} \
      PS_BOARD_INTERFACE {ps_pmc_fixed_io} \
      PS_ENET0_MDIO {{ENABLE 1} {IO {PS_MIO 24 .. 25}}} \
      PS_ENET0_PERIPHERAL {{ENABLE 1} {IO {PS_MIO 0 .. 11}}} \
      PS_GEN_IPI0_ENABLE {1} \
      PS_GEN_IPI0_MASTER {A72} \
      PS_GEN_IPI1_ENABLE {1} \
      PS_GEN_IPI2_ENABLE {1} \
      PS_GEN_IPI3_ENABLE {1} \
      PS_GEN_IPI4_ENABLE {1} \
      PS_GEN_IPI5_ENABLE {1} \
      PS_GEN_IPI6_ENABLE {1} \
      PS_HSDP_EGRESS_TRAFFIC {JTAG} \
      PS_HSDP_INGRESS_TRAFFIC {JTAG} \
      PS_HSDP_MODE {NONE} \
      PS_I2C0_PERIPHERAL {{ENABLE 1} {IO {PMC_MIO 46 .. 47}}} \
      PS_I2C1_PERIPHERAL {{ENABLE 1} {IO {PMC_MIO 44 .. 45}}} \
      PS_I2CSYSMON_PERIPHERAL {{ENABLE 0} {IO {PMC_MIO 39 .. 40}}} \
      PS_IRQ_USAGE {{CH0 1} {CH1 1} {CH10 0} {CH11 0} {CH12 0} {CH13 0} {CH14 0} {CH15 0} {CH2 1} {CH3 1} {CH4 1} {CH5 1} {CH6 0} {CH7 0} {CH8 0} {CH9 0}} \
      PS_MIO7 {{AUX_IO 0} {DIRECTION in} {DRIVE_STRENGTH 8mA} {OUTPUT_DATA default} {PULL disable} {SCHMITT 0} {SLEW slow} {USAGE Reserved}} \
      PS_MIO9 {{AUX_IO 0} {DIRECTION in} {DRIVE_STRENGTH 8mA} {OUTPUT_DATA default} {PULL disable} {SCHMITT 0} {SLEW slow} {USAGE Reserved}} \
      PS_NUM_FABRIC_RESETS {1} \
      PS_PCIE_EP_RESET1_IO {PS_MIO 18} \
      PS_PCIE_EP_RESET2_IO {PS_MIO 19} \
      PS_PCIE_RESET {ENABLE 1} \
      PS_PL_CONNECTIVITY_MODE {Custom} \
      PS_UART0_PERIPHERAL {{ENABLE 1} {IO {PMC_MIO 42 .. 43}}} \
      PS_USB3_PERIPHERAL {{ENABLE 1} {IO {PMC_MIO 13 .. 25}}} \
      PS_USE_FPD_AXI_NOC0 {1} \
      PS_USE_FPD_AXI_NOC1 {1} \
      PS_USE_FPD_CCI_NOC {1} \
      PS_USE_FPD_CCI_NOC0 {1} \
      PS_USE_M_AXI_FPD {1} \
      PS_USE_M_AXI_LPD {1} \
      PS_USE_NOC_FPD_AXI0 {0} \
      PS_USE_NOC_LPD_AXI0 {1} \
      PS_USE_PMCPL_CLK0 {1} \
      PS_USE_PMCPL_CLK1 {0} \
      PS_USE_PMCPL_CLK2 {0} \
      PS_USE_PMCPL_CLK3 {0} \
      SMON_ALARMS {Set_Alarms_On} \
      SMON_ENABLE_TEMP_AVERAGING {0} \
      SMON_INTERFACE_TO_USE {I2C} \
      SMON_PMBUS_ADDRESS {0x18} \
      SMON_TEMP_AVERAGING_SAMPLES {0} \
    } \
  ] [get_bd_cells versal_cips_0]
} else {
  set_property -dict [list \
    CONFIG.PS_PL_CONNECTIVITY_MODE {Custom} \
    CONFIG.CLOCK_MODE {Custom} \
    CONFIG.PS_PMC_CONFIG { \
      CLOCK_MODE {Custom} \
      DDR_MEMORY_MODE {Connectivity to DDR via NOC} \
      DEBUG_MODE {JTAG} \
      DESIGN_MODE {1} \
      PMC_CRP_PL0_REF_CTRL_FREQMHZ {250} \
      PMC_GPIO0_MIO_PERIPHERAL {{ENABLE 1} {IO {PMC_MIO 0 .. 25}}} \
      PMC_GPIO1_MIO_PERIPHERAL {{ENABLE 1} {IO {PMC_MIO 26 .. 51}}} \
      PMC_MIO37 {{AUX_IO 0} {DIRECTION out} {DRIVE_STRENGTH 8mA} {OUTPUT_DATA high} {PULL pullup} {SCHMITT 0} {SLEW slow} {USAGE GPIO}} \
      PMC_OSPI_PERIPHERAL {{ENABLE 0} {IO {PMC_MIO 0 .. 11}} {MODE Single}} \
      PMC_QSPI_COHERENCY {0} \
      PMC_QSPI_FBCLK {{ENABLE 1} {IO {PMC_MIO 6}}} \
      PMC_QSPI_PERIPHERAL_DATA_MODE {x4} \
      PMC_QSPI_PERIPHERAL_ENABLE {1} \
      PMC_QSPI_PERIPHERAL_MODE {Dual Parallel} \
      PMC_REF_CLK_FREQMHZ {33.3333} \
      PMC_SD1 {{CD_ENABLE 1} {CD_IO {PMC_MIO 28}} {POW_ENABLE 1} {POW_IO {PMC_MIO 51}} {RESET_ENABLE 0} {RESET_IO {PMC_MIO 12}} {WP_ENABLE 0} {WP_IO {PMC_MIO 1}}} \
      PMC_SD1_COHERENCY {0} \
      PMC_SD1_DATA_TRANSFER_MODE {8Bit} \
      PMC_SD1_PERIPHERAL {{CLK_100_SDR_OTAP_DLY 0x3} {CLK_200_SDR_OTAP_DLY 0x2} {CLK_50_DDR_ITAP_DLY 0x36} {CLK_50_DDR_OTAP_DLY 0x3} {CLK_50_SDR_ITAP_DLY 0x2C} {CLK_50_SDR_OTAP_DLY 0x4} {ENABLE 1} {IO {PMC_MIO 26 .. 36}}} \
      PMC_SD1_SLOT_TYPE {SD 3.0} \
      PMC_USE_PMC_NOC_AXI0 {1} \
      PS_BOARD_INTERFACE {ps_pmc_fixed_io} \
      PS_CAN1_PERIPHERAL {{ENABLE 1} {IO {PMC_MIO 40 .. 41}}} \
      PS_CRL_CAN1_REF_CTRL_FREQMHZ {160} \
      PS_ENET0_MDIO {{ENABLE 1} {IO {PS_MIO 24 .. 25}}} \
      PS_ENET0_PERIPHERAL {{ENABLE 1} {IO {PS_MIO 0 .. 11}}} \
      PS_ENET1_PERIPHERAL {{ENABLE 1} {IO {PS_MIO 12 .. 23}}} \
      PS_GEN_IPI0_ENABLE {1} \
      PS_GEN_IPI0_MASTER {A72} \
      PS_GEN_IPI1_ENABLE {1} \
      PS_GEN_IPI2_ENABLE {1} \
      PS_GEN_IPI3_ENABLE {1} \
      PS_GEN_IPI4_ENABLE {1} \
      PS_GEN_IPI5_ENABLE {1} \
      PS_GEN_IPI6_ENABLE {1} \
      PS_HSDP_EGRESS_TRAFFIC {JTAG} \
      PS_HSDP_INGRESS_TRAFFIC {JTAG} \
      PS_HSDP_MODE {NONE} \
      PS_I2C0_PERIPHERAL {{ENABLE 1} {IO {PMC_MIO 46 .. 47}}} \
      PS_I2C1_PERIPHERAL {{ENABLE 1} {IO {PMC_MIO 44 .. 45}}} \
      PS_IRQ_USAGE {{CH0 1} {CH1 1} {CH10 0} {CH11 0} {CH12 0} {CH13 0} {CH14 0} {CH15 0} {CH2 1} {CH3 1} {CH4 1} {CH5 1} {CH6 0} {CH7 0} {CH8 0} {CH9 0}} \
      PS_MIO19 {{AUX_IO 0} {DIRECTION in} {DRIVE_STRENGTH 8mA} {OUTPUT_DATA default} {PULL disable} {SCHMITT 0} {SLEW slow} {USAGE Reserved}} \
      PS_MIO21 {{AUX_IO 0} {DIRECTION in} {DRIVE_STRENGTH 8mA} {OUTPUT_DATA default} {PULL disable} {SCHMITT 0} {SLEW slow} {USAGE Reserved}} \
      PS_MIO7 {{AUX_IO 0} {DIRECTION in} {DRIVE_STRENGTH 8mA} {OUTPUT_DATA default} {PULL disable} {SCHMITT 0} {SLEW slow} {USAGE Reserved}} \
      PS_MIO9 {{AUX_IO 0} {DIRECTION in} {DRIVE_STRENGTH 8mA} {OUTPUT_DATA default} {PULL disable} {SCHMITT 0} {SLEW slow} {USAGE Reserved}} \
      PS_NUM_FABRIC_RESETS {1} \
      PS_PCIE_EP_RESET1_IO {PMC_MIO 38} \
      PS_PCIE_EP_RESET2_IO {PMC_MIO 39} \
      PS_PCIE_RESET {ENABLE 1} \
      PS_PL_CONNECTIVITY_MODE {Custom} \
      PS_UART0_PERIPHERAL {{ENABLE 1} {IO {PMC_MIO 42 .. 43}}} \
      PS_USB3_PERIPHERAL {{ENABLE 1} {IO {PMC_MIO 13 .. 25}}} \
      PS_USE_FPD_AXI_NOC0 {1} \
      PS_USE_FPD_AXI_NOC1 {1} \
      PS_USE_FPD_CCI_NOC {1} \
      PS_USE_FPD_CCI_NOC0 {1} \
      PS_USE_M_AXI_FPD {1} \
      PS_USE_M_AXI_LPD {1} \
      PS_USE_NOC_FPD_AXI0 {0} \
      PS_USE_NOC_LPD_AXI0 {1} \
      PS_USE_PMCPL_CLK0 {1} \
      PS_USE_PMCPL_CLK1 {0} \
      PS_USE_PMCPL_CLK2 {0} \
      PS_USE_PMCPL_CLK3 {0} \
      SMON_ALARMS {Set_Alarms_On} \
      SMON_ENABLE_TEMP_AVERAGING {0} \
      SMON_TEMP_AVERAGING_SAMPLES {0} \
    } \
  ] [get_bd_cells versal_cips_0]
}

# NoC connections and config
# S00_AXI - FPD_CCI_NOC_0 - PS Cache Coh - 0
# S01_AXI - FPD_CCI_NOC_1 - PS Cache Coh - 1
# S02_AXI - FPD_CCI_NOC_2 - PS Cache Coh - 2
# S03_AXI - FPD_CCI_NOC_3 - PS Cache Coh - 3
# S04_AXI - LPD_AXI_NOC_0 - PS LPD       - 2
# S05_AXI - PMC_NOC_AXI_0 - PS PMC       - 1
# S06_AXI - FPD_AXI_NOC_1 - PS Non-Coh   - 0
# S07_AXI - FPD_AXI_NOC_0 - PS Non-Coh   - 0
# S08_AXI - BRIDGE        - PL           - 3
#
# Unlike AMD's PL QDMA RP CED that this design is based on, there is no M00_AXI
# NSU looping back into the PS via NOC_FPD_AXI_0. The CED attaches that NSU
# (with fixed destID 0x140 and no assigned BD address) to the PMC's NoC port
# (S05_AXI here). The PMC is a "virtual" PS master whose NMU routing tables are
# programmed from the static NoC solution at boot, and on SSIT (stacked
# silicon) Versal devices (eg. VP1802 on the VPK180, VP1552 — monolithic parts
# like VC1902/VM1802/VE2802/VP1202 are unaffected) the NoC compiler cannot
# combine address-decoded MC routes with a fixed-destID NSU on the same
# virtual-master NMU: it skips the address decode settings entirely (CRITICAL
# WARNING Ipconfig 75-657 / BD 41-2842), which breaks the PMC-to-DDR route and
# hangs the PLM during PDI boot (GitHub issue #40). Every BD address segment through that NSU was
# excluded anyway, so the path carried no addressable traffic; it has been
# removed entirely so that every NMU has a single, address-decoded MC fanout.
# (Moving the NSU to another NMU instead would either re-trigger BD 41-2842 or
# expose PS peripherals to SSD DMA, depending on segment assignment.)

# Configure the NoC
set_property -dict [list \
  CONFIG.MC_CHAN_REGION1 {DDR_CH1} \
  CONFIG.NUM_CLKS {9} \
  CONFIG.NUM_MI {0} \
  CONFIG.NUM_SI {9} \
] [get_bd_cells axi_noc_0]
set_property -dict [list CONFIG.CONNECTIONS {MC_3 {read_bw {5} write_bw {5} read_avg_burst {4} write_avg_burst {4} initial_boot {true} }}] [get_bd_intf_pins /axi_noc_0/S00_AXI]
set_property -dict [list CONFIG.CONNECTIONS {MC_2 {read_bw {5} write_bw {5} read_avg_burst {4} write_avg_burst {4} initial_boot {true} }}] [get_bd_intf_pins /axi_noc_0/S01_AXI]
set_property -dict [list CONFIG.CONNECTIONS {MC_0 {read_bw {5} write_bw {5} read_avg_burst {4} write_avg_burst {4} initial_boot {true} }}] [get_bd_intf_pins /axi_noc_0/S02_AXI]
set_property -dict [list CONFIG.CONNECTIONS {MC_1 {read_bw {5} write_bw {5} read_avg_burst {4} write_avg_burst {4} initial_boot {true} }}] [get_bd_intf_pins /axi_noc_0/S03_AXI]
set_property -dict [list CONFIG.CATEGORY {ps_rpu} CONFIG.CONNECTIONS {MC_3 {read_bw {5} write_bw {5} read_avg_burst {4} write_avg_burst {4} initial_boot {true} }}] [get_bd_intf_pins /axi_noc_0/S04_AXI]
set_property -dict [list CONFIG.CONNECTIONS {MC_2 {read_bw {5} write_bw {5} read_avg_burst {4} write_avg_burst {4} initial_boot {true} }}] [get_bd_intf_pins /axi_noc_0/S05_AXI]
set_property -dict [list CONFIG.CATEGORY {ps_nci} CONFIG.CONNECTIONS {MC_0 {read_bw {5} write_bw {5} read_avg_burst {4} write_avg_burst {4} initial_boot {true} }}] [get_bd_intf_pins /axi_noc_0/S06_AXI]
set_property -dict [list CONFIG.CATEGORY {ps_nci} CONFIG.CONNECTIONS {MC_0 {read_bw {5} write_bw {5} read_avg_burst {4} write_avg_burst {4} initial_boot {true} }}] [get_bd_intf_pins /axi_noc_0/S07_AXI]
set_property -dict [list CONFIG.CONNECTIONS {MC_1 {read_bw {1720} write_bw {1720} read_avg_burst {4} write_avg_burst {4} }}] [get_bd_intf_pins /axi_noc_0/S08_AXI]

# Connect FPD AXI NOC interfaces and clocks to NoC
connect_bd_intf_net [get_bd_intf_pins versal_cips_0/FPD_AXI_NOC_0] [get_bd_intf_pins axi_noc_0/S06_AXI]
connect_bd_intf_net [get_bd_intf_pins versal_cips_0/FPD_AXI_NOC_1] [get_bd_intf_pins axi_noc_0/S07_AXI]
connect_bd_net [get_bd_pins versal_cips_0/fpd_axi_noc_axi0_clk] [get_bd_pins axi_noc_0/aclk6]
connect_bd_net [get_bd_pins versal_cips_0/fpd_axi_noc_axi1_clk] [get_bd_pins axi_noc_0/aclk7]

# QDMA support block
proc create_qdma_support { index } {

  global pcie_blk_locn
  global target
  global is_vpk120
  global is_vpk180
  global is_vck190
  global is_vmk180
  global is_vek280
  global is_vhk158
  set hier_obj [create_bd_cell -type hier qdma_support_$index]
  current_bd_instance $hier_obj

  # Create interface pins
  create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:axis_rtl:1.0 m_axis_cq

  create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:axis_rtl:1.0 m_axis_rc

  # VPK120, VPK180 and VHK158 have PCIE5 blocks
  # VCK190, VMK180 and VEK280 have PCIE4 blocks
  # Strangely the tools insist on us using interfaces pcie5_cfg_control/status_rtl with VEK280
  if {$is_vpk120 || $is_vpk180 || $is_vhk158 || $is_vek280} {
    create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:pcie5_cfg_control_rtl:1.0 pcie_cfg_control
    create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:pcie5_cfg_status_rtl:1.0 pcie_cfg_status
  } else {
    create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:pcie4_cfg_control_rtl:1.0 pcie_cfg_control
    create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:pcie4_cfg_status_rtl:1.0 pcie_cfg_status
  }

  create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:pcie_cfg_fc_rtl:1.1 pcie_cfg_fc

  create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:pcie3_cfg_interrupt_rtl:1.0 pcie_cfg_interrupt

  create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:pcie3_cfg_msg_received_rtl:1.0 pcie_cfg_mesg_rcvd

  create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:pcie3_cfg_mesg_tx_rtl:1.0 pcie_cfg_mesg_tx

  create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:pcie4_cfg_mgmt_rtl:1.0 pcie_cfg_mgmt

  create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:gt_rtl:1.0 pcie_mgt

  create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 pcie_refclk

  create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:pcie3_transmit_fc_rtl:1.0 pcie_transmit_fc

  create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:axis_rtl:1.0 s_axis_cc

  create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:axis_rtl:1.0 s_axis_rq


  # Create pins
  create_bd_pin -dir O -from 5 -to 0 pcie_ltssm_state
  create_bd_pin -dir O phy_rdy_out
  create_bd_pin -dir I -type rst sys_reset
  create_bd_pin -dir O -type clk user_clk
  create_bd_pin -dir O user_lnk_up
  create_bd_pin -dir O -type rst user_reset

  # Create instance: bufg_gt_sysclk, and set properties
  set bufg_gt_sysclk [ create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf bufg_gt_sysclk ]
  set_property -dict [ list \
   CONFIG.C_BUFG_GT_SYNC {true} \
   CONFIG.C_BUF_TYPE {BUFG_GT} \
 ] $bufg_gt_sysclk

  # Create instance: pcie, and set properties
  global ref_board
  set pcie [ create_bd_cell -type ip -vlnv xilinx.com:ip:pcie_versal pcie ]
  if {$is_vck190 || $is_vmk180 || $is_vek280} {
    set_property -dict [ list \
      CONFIG.AXISTEN_IF_CQ_ALIGNMENT_MODE {Address_Aligned} \
      CONFIG.AXISTEN_IF_EXT_512_RQ_STRADDLE {true} \
      CONFIG.AXISTEN_IF_RQ_ALIGNMENT_MODE {DWORD_Aligned} \
      CONFIG.PF0_DEVICE_ID {B048} \
      CONFIG.PF0_INTERRUPT_PIN {INTA} \
      CONFIG.PF0_LINK_STATUS_SLOT_CLOCK_CONFIG {true} \
      CONFIG.PF0_REVISION_ID {00} \
      CONFIG.PF0_SRIOV_VF_DEVICE_ID {C048} \
      CONFIG.PF0_SUBSYSTEM_ID {0007} \
      CONFIG.PF0_Use_Class_Code_Lookup_Assistant {false} \
      CONFIG.PF1_DEVICE_ID {9011} \
      CONFIG.PF1_REVISION_ID {00} \
      CONFIG.PF1_SUBSYSTEM_ID {0007} \
      CONFIG.PF1_SUBSYSTEM_VENDOR_ID {10EE} \
      CONFIG.PF1_Use_Class_Code_Lookup_Assistant {false} \
      CONFIG.PF2_DEVICE_ID {B248} \
      CONFIG.PF2_REVISION_ID {00} \
      CONFIG.PF2_SUBSYSTEM_ID {0007} \
      CONFIG.PF2_SUBSYSTEM_VENDOR_ID {10EE} \
      CONFIG.PF2_Use_Class_Code_Lookup_Assistant {false} \
      CONFIG.PF3_DEVICE_ID {B348} \
      CONFIG.PF3_REVISION_ID {00} \
      CONFIG.PF3_SUBSYSTEM_ID {0007} \
      CONFIG.PF3_SUBSYSTEM_VENDOR_ID {10EE} \
      CONFIG.PF3_Use_Class_Code_Lookup_Assistant {false} \
      CONFIG.PF4_DEVICE_ID {B448} \
      CONFIG.PF5_DEVICE_ID {B548} \
      CONFIG.PF6_DEVICE_ID {B648} \
      CONFIG.PF7_DEVICE_ID {B748} \
      CONFIG.PL_DISABLE_LANE_REVERSAL {false} \
      CONFIG.PL_LINK_CAP_MAX_LINK_SPEED {16.0_GT/s} \
      CONFIG.PL_LINK_CAP_MAX_LINK_WIDTH {X4} \
      CONFIG.REF_CLK_FREQ {100_MHz} \
      CONFIG.acs_ext_cap_enable {false} \
      CONFIG.axisten_freq {250} \
      CONFIG.axisten_if_enable_client_tag {true} \
      CONFIG.axisten_if_enable_msg_route_override {TRUE} \
      CONFIG.axisten_if_width {256_bit} \
      CONFIG.cfg_ext_if {false} \
      CONFIG.cfg_mgmt_if {true} \
      CONFIG.copy_pf0 {true} \
      CONFIG.dedicate_perst {false} \
      CONFIG.device_port_type {Root_Port_of_PCI_Express_Root_Complex} \
      CONFIG.disable_double_pipe {NO} \
      CONFIG.en_dbg_descramble {false} \
      CONFIG.en_ext_clk {FALSE} \
      CONFIG.en_l23_entry {false} \
      CONFIG.en_parity {false} \
      CONFIG.enable_auto_rxeq {False} \
      CONFIG.enable_ccix {FALSE} \
      CONFIG.enable_dvsec {FALSE} \
      CONFIG.enable_gen4 {true} \
      CONFIG.enable_gtwizard {true} \
      CONFIG.enable_ibert {false} \
      CONFIG.enable_jtag_dbg {false} \
      CONFIG.ext_pcie_cfg_space_enabled {false} \
      CONFIG.extended_tag_field {true} \
      CONFIG.insert_cips {false} \
      CONFIG.legacy_ext_pcie_cfg_space_enabled {false} \
      CONFIG.mode_selection {Advanced} \
      CONFIG.pcie_blk_locn [lindex $pcie_blk_locn $index] \
      CONFIG.pf0_ari_enabled {false} \
      CONFIG.pf0_bar0_64bit {true} \
      CONFIG.pf0_bar0_enabled {true} \
      CONFIG.pf0_bar0_prefetchable {true} \
      CONFIG.pf0_bar0_scale {Terabytes} \
      CONFIG.pf0_bar0_size {16} \
      CONFIG.pf0_bar2_enabled {false} \
      CONFIG.pf0_bar4_enabled {false} \
      CONFIG.pf0_base_class_menu {Bridge_device} \
      CONFIG.pf0_class_code_base {06} \
      CONFIG.pf0_class_code_interface {00} \
      CONFIG.pf0_class_code_sub {04} \
      CONFIG.pf0_dll_feature_cap_enabled {true} \
      CONFIG.pf0_margining_cap_enabled {true} \
      CONFIG.pf0_msi_enabled {false} \
      CONFIG.pf0_msix_enabled {false} \
      CONFIG.pf0_pl16_cap_enabled {true} \
      CONFIG.pf0_sub_class_interface_menu {InfiniBand_to_PCI_host_bridge} \
      CONFIG.pf1_base_class_menu {Bridge_device} \
      CONFIG.pf1_class_code_base {06} \
      CONFIG.pf1_class_code_interface {00} \
      CONFIG.pf1_class_code_sub {04} \
      CONFIG.pf1_msix_enabled {false} \
      CONFIG.pf1_sub_class_interface_menu {InfiniBand_to_PCI_host_bridge} \
      CONFIG.pf1_vendor_id {10EE} \
      CONFIG.pf2_base_class_menu {Bridge_device} \
      CONFIG.pf2_class_code_base {06} \
      CONFIG.pf2_class_code_interface {00} \
      CONFIG.pf2_class_code_sub {04} \
      CONFIG.pf2_msix_enabled {false} \
      CONFIG.pf2_sub_class_interface_menu {InfiniBand_to_PCI_host_bridge} \
      CONFIG.pf2_vendor_id {10EE} \
      CONFIG.pf3_base_class_menu {Bridge_device} \
      CONFIG.pf3_class_code_base {06} \
      CONFIG.pf3_class_code_interface {00} \
      CONFIG.pf3_class_code_sub {04} \
      CONFIG.pf3_msix_enabled {false} \
      CONFIG.pf3_sub_class_interface_menu {InfiniBand_to_PCI_host_bridge} \
      CONFIG.pf3_vendor_id {10EE} \
      CONFIG.pf4_base_class_menu {Bridge_device} \
      CONFIG.pf4_class_code_base {06} \
      CONFIG.pf4_class_code_sub {04} \
      CONFIG.pf4_sub_class_interface_menu {InfiniBand_to_PCI_host_bridge} \
      CONFIG.pf5_base_class_menu {Bridge_device} \
      CONFIG.pf5_class_code_base {06} \
      CONFIG.pf5_class_code_sub {04} \
      CONFIG.pf5_sub_class_interface_menu {InfiniBand_to_PCI_host_bridge} \
      CONFIG.pf6_base_class_menu {Bridge_device} \
      CONFIG.pf6_class_code_base {06} \
      CONFIG.pf6_class_code_sub {04} \
      CONFIG.pf6_sub_class_interface_menu {InfiniBand_to_PCI_host_bridge} \
      CONFIG.pf7_base_class_menu {Bridge_device} \
      CONFIG.pf7_class_code_base {06} \
      CONFIG.pf7_class_code_sub {04} \
      CONFIG.pf7_sub_class_interface_menu {InfiniBand_to_PCI_host_bridge} \
      CONFIG.pipe_line_stage {2} \
      CONFIG.pipe_sim {false} \
      CONFIG.plltype {LCPLL} \
      CONFIG.sys_reset_polarity {ACTIVE_LOW} \
      CONFIG.type1_membase_memlimit_enable {Enabled} \
      CONFIG.type1_prefetchable_membase_memlimit {64bit_Enabled} \
      CONFIG.userclk2_freq {250} \
      CONFIG.vendor_id {10EE} \
  ] $pcie
  } else {
    set_property -dict [list \
      CONFIG.AXISTEN_IF_CQ_ALIGNMENT_MODE {Address_Aligned} \
      CONFIG.AXISTEN_IF_RQ_ALIGNMENT_MODE {DWORD_Aligned} \
      CONFIG.PF0_AER_CAP_ECRC_GEN_AND_CHECK_CAPABLE {false} \
      CONFIG.PF0_DEVICE_ID {B0D4} \
      CONFIG.PF0_INTERRUPT_PIN {INTA} \
      CONFIG.PF0_LINK_STATUS_SLOT_CLOCK_CONFIG {true} \
      CONFIG.PF0_REVISION_ID {00} \
      CONFIG.PF0_SRIOV_VF_DEVICE_ID {C034} \
      CONFIG.PF0_SUBSYSTEM_ID {0007} \
      CONFIG.PF1_DEVICE_ID {913F} \
      CONFIG.PF1_MSI_CAP_MULTIMSGCAP {1_vector} \
      CONFIG.PF1_REVISION_ID {00} \
      CONFIG.PF1_SUBSYSTEM_ID {0007} \
      CONFIG.PF1_SUBSYSTEM_VENDOR_ID {10EE} \
      CONFIG.PF2_DEVICE_ID {B2D4} \
      CONFIG.PF2_MSI_CAP_MULTIMSGCAP {1_vector} \
      CONFIG.PF2_REVISION_ID {00} \
      CONFIG.PF2_SUBSYSTEM_ID {0007} \
      CONFIG.PF2_SUBSYSTEM_VENDOR_ID {10EE} \
      CONFIG.PF3_DEVICE_ID {B3D4} \
      CONFIG.PF3_MSI_CAP_MULTIMSGCAP {1_vector} \
      CONFIG.PF3_REVISION_ID {00} \
      CONFIG.PF3_SUBSYSTEM_ID {0007} \
      CONFIG.PF3_SUBSYSTEM_VENDOR_ID {10EE} \
      CONFIG.PF4_DEVICE_ID {B4D4} \
      CONFIG.PF5_DEVICE_ID {B5D4} \
      CONFIG.PF6_DEVICE_ID {B6D4} \
      CONFIG.PF7_DEVICE_ID {B7D4} \
      CONFIG.PL_DISABLE_LANE_REVERSAL {TRUE} \
      CONFIG.PL_LINK_CAP_MAX_LINK_SPEED {32.0_GT/s} \
      CONFIG.PL_LINK_CAP_MAX_LINK_WIDTH {X4} \
      CONFIG.REF_CLK_FREQ {100_MHz} \
      CONFIG.acs_ext_cap_enable {false} \
      CONFIG.all_speeds_all_sides {NO} \
      CONFIG.axisten_freq {250} \
      CONFIG.axisten_if_enable_client_tag {true} \
      CONFIG.axisten_if_enable_msg_route_override {TRUE} \
      CONFIG.axisten_if_width {512_bit} \
      CONFIG.cfg_ext_if {false} \
      CONFIG.cfg_mgmt_if {true} \
      CONFIG.copy_pf0 {true} \
      CONFIG.coreclk_freq {500} \
      CONFIG.dedicate_perst {false} \
      CONFIG.device_port_type {Root_Port_of_PCI_Express_Root_Complex} \
      CONFIG.en_dbg_descramble {false} \
      CONFIG.en_ext_clk {FALSE} \
      CONFIG.en_l23_entry {false} \
      CONFIG.en_parity {false} \
      CONFIG.en_transceiver_status_ports {false} \
      CONFIG.enable_auto_rxeq {False} \
      CONFIG.enable_ccix {FALSE} \
      CONFIG.enable_dvsec {FALSE} \
      CONFIG.enable_gen4 {true} \
      CONFIG.enable_gtwizard {true} \
      CONFIG.enable_ibert {false} \
      CONFIG.enable_jtag_dbg {false} \
      CONFIG.enable_more_clk {false} \
      CONFIG.ext_pcie_cfg_space_enabled {false} \
      CONFIG.extended_tag_field {true} \
      CONFIG.insert_cips {false} \
      CONFIG.lane_order {Bottom} \
      CONFIG.legacy_ext_pcie_cfg_space_enabled {false} \
      CONFIG.mode_selection {Advanced} \
      CONFIG.pcie_blk_locn [lindex $pcie_blk_locn $index] \
      CONFIG.pcie_link_debug {false} \
      CONFIG.pcie_link_debug_axi4_st {false} \
      CONFIG.pf0_ari_enabled {false} \
      CONFIG.pf0_bar0_64bit {true} \
      CONFIG.pf0_bar0_enabled {true} \
      CONFIG.pf0_bar0_prefetchable {false} \
      CONFIG.pf0_bar0_scale {Terabytes} \
      CONFIG.pf0_bar0_size {16} \
      CONFIG.pf0_bar2_64bit {true} \
      CONFIG.pf0_bar2_enabled {true} \
      CONFIG.pf0_bar2_prefetchable {false} \
      CONFIG.pf0_bar2_scale {Kilobytes} \
      CONFIG.pf0_bar2_size {4} \
      CONFIG.pf0_bar2_type {Memory} \
      CONFIG.pf0_bar4_enabled {false} \
      CONFIG.pf0_base_class_menu {Bridge_device} \
      CONFIG.pf0_class_code_base {06} \
      CONFIG.pf0_class_code_interface {00} \
      CONFIG.pf0_class_code_sub {0A} \
      CONFIG.pf0_expansion_rom_enabled {false} \
      CONFIG.pf0_msi_enabled {false} \
      CONFIG.pf0_msix_enabled {false} \
      CONFIG.pf0_sub_class_interface_menu {InfiniBand_to_PCI_host_bridge} \
      CONFIG.pf0_vc_cap_enabled {true} \
      CONFIG.pf1_base_class_menu {Bridge_device} \
      CONFIG.pf1_class_code_base {06} \
      CONFIG.pf1_class_code_interface {00} \
      CONFIG.pf1_class_code_sub {0A} \
      CONFIG.pf1_msix_enabled {false} \
      CONFIG.pf1_sub_class_interface_menu {InfiniBand_to_PCI_host_bridge} \
      CONFIG.pf1_vendor_id {10EE} \
      CONFIG.pf2_base_class_menu {Bridge_device} \
      CONFIG.pf2_class_code_base {06} \
      CONFIG.pf2_class_code_interface {00} \
      CONFIG.pf2_class_code_sub {0A} \
      CONFIG.pf2_msix_enabled {false} \
      CONFIG.pf2_sub_class_interface_menu {InfiniBand_to_PCI_host_bridge} \
      CONFIG.pf2_vendor_id {10EE} \
      CONFIG.pf3_base_class_menu {Bridge_device} \
      CONFIG.pf3_class_code_base {06} \
      CONFIG.pf3_class_code_interface {00} \
      CONFIG.pf3_class_code_sub {0A} \
      CONFIG.pf3_msix_enabled {false} \
      CONFIG.pf3_sub_class_interface_menu {InfiniBand_to_PCI_host_bridge} \
      CONFIG.pf3_vendor_id {10EE} \
      CONFIG.pf4_base_class_menu {Bridge_device} \
      CONFIG.pf4_class_code_base {06} \
      CONFIG.pf4_class_code_sub {0A} \
      CONFIG.pf4_sub_class_interface_menu {InfiniBand_to_PCI_host_bridge} \
      CONFIG.pf5_base_class_menu {Bridge_device} \
      CONFIG.pf5_class_code_base {06} \
      CONFIG.pf5_class_code_sub {0A} \
      CONFIG.pf5_sub_class_interface_menu {InfiniBand_to_PCI_host_bridge} \
      CONFIG.pf6_base_class_menu {Bridge_device} \
      CONFIG.pf6_class_code_base {06} \
      CONFIG.pf6_class_code_sub {0A} \
      CONFIG.pf6_sub_class_interface_menu {InfiniBand_to_PCI_host_bridge} \
      CONFIG.pf7_base_class_menu {Bridge_device} \
      CONFIG.pf7_class_code_base {06} \
      CONFIG.pf7_class_code_sub {0A} \
      CONFIG.pf7_sub_class_interface_menu {InfiniBand_to_PCI_host_bridge} \
      CONFIG.pipe_line_stage {2} \
      CONFIG.pipe_sim {false} \
      CONFIG.replace_uram_with_bram {false} \
      CONFIG.sys_reset_polarity {ACTIVE_LOW} \
      CONFIG.type1_membase_memlimit_enable {Enabled} \
      CONFIG.type1_prefetchable_membase_memlimit {64bit_Enabled} \
      CONFIG.vendor_id {10EE} \
      CONFIG.warm_reboot_sbr_fix {false} \
      CONFIG.xlnx_ref_board $ref_board \
    ] $pcie
  }
  # Create instance: pcie_phy, and set properties
  set pcie_phy [ create_bd_cell -type ip -vlnv xilinx.com:ip:pcie_phy_versal pcie_phy ]
  # PCIE4 (Gen4, 500 MHz PIPE): 2 PIPE pipeline stages between the PCIE40 block and the
  # GTY quad, set on both pcie_phy (pipeline_stages) and pcie_versal (pipe_line_stage, whose
  # standalone IP default is 2). With 1 stage the PIPELTSSM -> GT PCIELTSSM route failed timing
  # on vck190_fmcp1 (PCIE40_X1Y2 + GTY_QUAD_X1Y2 are in different clock regions).
  if {$is_vck190 || $is_vmk180 || $is_vek280} {
    set_property -dict [ list \
      CONFIG.PL_LINK_CAP_MAX_LINK_SPEED {16.0_GT/s} \
      CONFIG.PL_LINK_CAP_MAX_LINK_WIDTH {X4} \
      CONFIG.aspm {No_ASPM} \
      CONFIG.disable_double_pipe {YES} \
      CONFIG.en_gt_pclk {false} \
      CONFIG.enable_gtwizard {true} \
      CONFIG.enable_rpll {false} \
      CONFIG.ins_loss_profile {Add-in_Card} \
      CONFIG.lane_order {Bottom} \
      CONFIG.lane_reversal {false} \
      CONFIG.phy_async_en {true} \
      CONFIG.phy_coreclk_freq {500_MHz} \
      CONFIG.phy_refclk_freq {100_MHz} \
      CONFIG.phy_userclk2_freq {250_MHz} \
      CONFIG.phy_userclk_freq {250_MHz} \
      CONFIG.pipeline_stages {2} \
      CONFIG.tx_preset {4} \
   ] $pcie_phy
  } else {
    set_property -dict [list \
      CONFIG.PL_LINK_CAP_MAX_LINK_SPEED {32.0_GT/s} \
      CONFIG.PL_LINK_CAP_MAX_LINK_WIDTH {X4} \
      CONFIG.aspm {No_ASPM} \
      CONFIG.async_mode {SRNS} \
      CONFIG.disable_double_pipe {YES} \
      CONFIG.en_gt_pclk {false} \
      CONFIG.enable_gtwizard {true} \
      CONFIG.ins_loss_profile {Add-in_Card} \
      CONFIG.lane_order {Bottom} \
      CONFIG.lane_reversal {false} \
      CONFIG.phy_async_en {true} \
      CONFIG.phy_coreclk_freq {500_MHz} \
      CONFIG.phy_refclk_freq {100_MHz} \
      CONFIG.phy_userclk2_freq {250_MHz} \
      CONFIG.phy_userclk_freq {250_MHz} \
      CONFIG.pipeline_stages {4} \
      CONFIG.sim_model {NO} \
      CONFIG.tx_preset {4} \
    ] $pcie_phy
  }

  # Create instance: refclk_ibuf, and set properties
  set refclk_ibuf [ create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf refclk_ibuf ]
  set_property CONFIG.C_BUF_TYPE {IBUFDSGTE} $refclk_ibuf


  # Create instance: gtwiz_versal_0, and set properties
  set gtwiz_versal_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:gtwiz_versal:1.0 gtwiz_versal_0 ]
  global gt_type
  if {$is_vck190 || $is_vmk180 || $is_vek280} {
    set_property -dict [list \
      CONFIG.GT_TYPE $gt_type \
      CONFIG.INTF0_GT_SETTINGS(GT_DIRECTION) {DUPLEX} \
      CONFIG.INTF0_GT_SETTINGS(GT_TYPE) $gt_type \
      CONFIG.INTF0_GT_SETTINGS(LR0_SETTINGS) {TX_BUFFER_MODE 0 PCIE_ENABLE true TX_PLL_TYPE LCPLL TX_REFCLK_SOURCE R0 TXPROGDIV_FREQ_ENABLE true TXPROGDIV_FREQ_SOURCE RPLL TX_OUTCLK_SOURCE TXPROGDIVCLK TX_DIFF_SWING_EMPH_MODE\
  CUSTOM TX_BUFFER_BYPASS_MODE Fast_Sync TX_DATA_ENCODING 8B10B TX_LINE_RATE 2.5 TX_USER_DATA_WIDTH 16 TX_INT_DATA_WIDTH 20 TX_REFCLK_FREQUENCY 100 PCIE_USERCLK_FREQ 250 TXPROGDIV_FREQ_VAL 500.000 PCIE_USERCLK2_FREQ\
  250 OOB_ENABLE true RX_BUFFER_MODE 1 RXPROGDIV_FREQ_ENABLE false RX_CC_LEN_SEQ 1 RX_CC_NUM_SEQ 1 RX_CC_K_0_0 true RX_CC_MASK_0_0 false RX_CC_VAL_0_0 00011100 RX_CC_KEEP_IDLE ENABLE RX_COMMA_ALIGN_WORD\
  1 RX_COMMA_PRESET K28.5 RX_COMMA_M_ENABLE true RX_COMMA_P_ENABLE true RX_COMMA_MASK 1111111111 RX_COMMA_M_VAL 0101111100 RX_COMMA_P_VAL 1010000011 RX_COMMA_DOUBLE_ENABLE false RX_JTOL_FC 1 RX_PLL_TYPE\
  LCPLL RX_SLIDE_MODE OFF RX_REFCLK_SOURCE R0 RX_OUTCLK_SOURCE RXOUTCLKPMA RX_EQ_MODE LPM RX_SSC_PPM 0 INS_LOSS_NYQ 20 RX_DATA_DECODING 8B10B RX_LINE_RATE 2.5 RX_PPM_OFFSET 0 RX_USER_DATA_WIDTH 16 RX_INT_DATA_WIDTH\
  20 RX_REFCLK_FREQUENCY 100} \
      CONFIG.INTF0_GT_SETTINGS(LR1_SETTINGS) {TX_BUFFER_MODE 0 PCIE_ENABLE true TX_PLL_TYPE LCPLL TX_REFCLK_SOURCE R0 TXPROGDIV_FREQ_ENABLE true TXPROGDIV_FREQ_SOURCE RPLL TX_OUTCLK_SOURCE TXPROGDIVCLK TX_DIFF_SWING_EMPH_MODE\
  CUSTOM TX_BUFFER_BYPASS_MODE Fast_Sync TX_DATA_ENCODING 8B10B TX_LINE_RATE 5.0 TX_USER_DATA_WIDTH 16 TX_INT_DATA_WIDTH 20 TX_REFCLK_FREQUENCY 100 PCIE_USERCLK_FREQ 250 TXPROGDIV_FREQ_VAL 500.000 PCIE_USERCLK2_FREQ\
  250 OOB_ENABLE true RX_BUFFER_MODE 1 RXPROGDIV_FREQ_ENABLE false RX_CC_LEN_SEQ 1 RX_CC_NUM_SEQ 1 RX_CC_K_0_0 true RX_CC_MASK_0_0 false RX_CC_VAL_0_0 00011100 RX_CC_KEEP_IDLE ENABLE RX_COMMA_ALIGN_WORD\
  1 RX_COMMA_PRESET K28.5 RX_COMMA_M_ENABLE true RX_COMMA_P_ENABLE true RX_COMMA_MASK 1111111111 RX_COMMA_M_VAL 0101111100 RX_COMMA_P_VAL 1010000011 RX_COMMA_DOUBLE_ENABLE false RX_JTOL_FC 1 RX_PLL_TYPE\
  LCPLL RX_SLIDE_MODE OFF RX_REFCLK_SOURCE R0 RX_OUTCLK_SOURCE RXOUTCLKPMA RX_EQ_MODE LPM RX_SSC_PPM 0 INS_LOSS_NYQ 20 RX_DATA_DECODING 8B10B RX_LINE_RATE 5.0 RX_PPM_OFFSET 0 RX_USER_DATA_WIDTH 16 RX_INT_DATA_WIDTH\
  20 RX_REFCLK_FREQUENCY 100} \
      CONFIG.INTF0_GT_SETTINGS(LR2_SETTINGS) {TX_BUFFER_MODE 0 PCIE_ENABLE true TX_PLL_TYPE LCPLL TX_REFCLK_SOURCE R0 TXPROGDIV_FREQ_ENABLE true TXPROGDIV_FREQ_SOURCE RPLL TX_OUTCLK_SOURCE TXPROGDIVCLK TX_DIFF_SWING_EMPH_MODE\
  CUSTOM TX_BUFFER_BYPASS_MODE Fast_Sync TX_DATA_ENCODING 128B130B TX_LINE_RATE 8.0 TX_USER_DATA_WIDTH 32 TX_INT_DATA_WIDTH 32 TX_REFCLK_FREQUENCY 100 PCIE_USERCLK_FREQ 250 TXPROGDIV_FREQ_VAL 500.000 PCIE_USERCLK2_FREQ\
  250 OOB_ENABLE true RX_BUFFER_MODE 1 RXPROGDIV_FREQ_ENABLE false RX_CC_LEN_SEQ 1 RX_CC_NUM_SEQ 1 RX_CC_K_0_0 true RX_CC_MASK_0_0 false RX_CC_VAL_0_0 00011100 RX_CC_KEEP_IDLE ENABLE RX_COMMA_ALIGN_WORD\
  1 RX_COMMA_PRESET K28.5 RX_COMMA_M_ENABLE true RX_COMMA_P_ENABLE true RX_COMMA_MASK 1111111111 RX_COMMA_M_VAL 0101111100 RX_COMMA_P_VAL 1010000011 RX_COMMA_DOUBLE_ENABLE false RX_JTOL_FC 1 RX_PLL_TYPE\
  LCPLL RX_SLIDE_MODE OFF RX_REFCLK_SOURCE R0 RX_OUTCLK_SOURCE RXOUTCLKPMA RX_EQ_MODE DFE RX_SSC_PPM 0 INS_LOSS_NYQ 20 RX_DATA_DECODING 128B130B RX_LINE_RATE 8.0 RX_PPM_OFFSET 0 RX_USER_DATA_WIDTH 32 RX_INT_DATA_WIDTH\
  32 RX_REFCLK_FREQUENCY 100} \
      CONFIG.INTF0_GT_SETTINGS(LR3_SETTINGS) {TX_BUFFER_MODE 0 PCIE_ENABLE true TX_PLL_TYPE LCPLL TX_REFCLK_SOURCE R0 TXPROGDIV_FREQ_ENABLE true TXPROGDIV_FREQ_SOURCE RPLL TX_OUTCLK_SOURCE TXPROGDIVCLK TX_DIFF_SWING_EMPH_MODE\
  CUSTOM TX_BUFFER_BYPASS_MODE Fast_Sync TX_DATA_ENCODING 128B130B TX_LINE_RATE 16.0 TX_USER_DATA_WIDTH 32 TX_INT_DATA_WIDTH 32 TX_REFCLK_FREQUENCY 100 PCIE_USERCLK_FREQ 250 TXPROGDIV_FREQ_VAL 500.000 PCIE_USERCLK2_FREQ\
  250 OOB_ENABLE true RX_BUFFER_MODE 1 RXPROGDIV_FREQ_ENABLE false RX_CC_LEN_SEQ 1 RX_CC_NUM_SEQ 1 RX_CC_K_0_0 true RX_CC_MASK_0_0 false RX_CC_VAL_0_0 00011100 RX_CC_KEEP_IDLE ENABLE RX_COMMA_ALIGN_WORD\
  1 RX_COMMA_PRESET K28.5 RX_COMMA_M_ENABLE true RX_COMMA_P_ENABLE true RX_COMMA_MASK 1111111111 RX_COMMA_M_VAL 0101111100 RX_COMMA_P_VAL 1010000011 RX_COMMA_DOUBLE_ENABLE false RX_JTOL_FC 1 RX_PLL_TYPE\
  LCPLL RX_SLIDE_MODE OFF RX_REFCLK_SOURCE R0 RX_OUTCLK_SOURCE RXOUTCLKPMA RX_EQ_MODE DFE RX_SSC_PPM 0 INS_LOSS_NYQ 20 RX_DATA_DECODING 128B130B RX_LINE_RATE 16.0 RX_PPM_OFFSET 0 RX_USER_DATA_WIDTH 32 RX_INT_DATA_WIDTH\
  32 RX_REFCLK_FREQUENCY 100} \
    CONFIG.INTF0_GT_SETTINGS(LR4_SETTINGS) {TX_BUFFER_MODE 0 PCIE_ENABLE true TX_PLL_TYPE LCPLL TX_REFCLK_SOURCE R0 TXPROGDIV_FREQ_ENABLE true TXPROGDIV_FREQ_SOURCE RPLL TX_OUTCLK_SOURCE TXPROGDIVCLK TX_DIFF_SWING_EMPH_MODE\
CUSTOM TX_BUFFER_BYPASS_MODE Fast_Sync TX_DATA_ENCODING 128B130B TX_LINE_RATE 16.0 TX_USER_DATA_WIDTH 32 TX_INT_DATA_WIDTH 32 TX_REFCLK_FREQUENCY 100 PCIE_USERCLK_FREQ 250 TXPROGDIV_FREQ_VAL 500.000 PCIE_USERCLK2_FREQ\
250 TX_ACTUAL_REFCLK_FREQUENCY 100.0 TX_FRACN_ENABLED false TX_FRACN_NUMERATOR 0 TX_PIPM_ENABLE false TX_64B66B_SCRAMBLER false TX_64B66B_ENCODER false TX_64B66B_CRC false TX_RATE_GROUP A TX_BUFFER_RESET_ON_RATE_CHANGE\
ENABLE PRESET None INTERNAL_PRESET None OOB_ENABLE true RX_BUFFER_MODE 1 RXPROGDIV_FREQ_ENABLE false RX_CC_LEN_SEQ 1 RX_CC_NUM_SEQ 1 RX_CC_K_0_0 false RX_CC_MASK_0_0 false RX_CC_VAL_0_0 00011100 RX_CC_KEEP_IDLE\
ENABLE RX_COMMA_ALIGN_WORD 1 RX_COMMA_PRESET K28.5 RX_COMMA_M_ENABLE true RX_COMMA_P_ENABLE true RX_COMMA_MASK 1111111111 RX_COMMA_M_VAL 0101111100 RX_COMMA_P_VAL 1010000011 RX_COMMA_DOUBLE_ENABLE false\
RX_JTOL_FC 1 RX_PLL_TYPE LCPLL RX_SLIDE_MODE OFF RX_REFCLK_SOURCE R0 RX_OUTCLK_SOURCE RXOUTCLKPMA RX_EQ_MODE DFE RX_SSC_PPM 0 INS_LOSS_NYQ 20 RX_DATA_DECODING 128B130B RX_LINE_RATE 16.0 RX_PPM_OFFSET 0\
RX_USER_DATA_WIDTH 32 RX_INT_DATA_WIDTH 32 RX_REFCLK_FREQUENCY 100 RESET_SEQUENCE_INTERVAL 0 RXPROGDIV_FREQ_SOURCE LCPLL RXPROGDIV_FREQ_VAL 322.265625 RX_64B66B_CRC false RX_64B66B_DECODER false RX_64B66B_DESCRAMBLER\
false RX_ACTUAL_REFCLK_FREQUENCY 100.0 RX_BUFFER_BYPASS_MODE Fast_Sync RX_BUFFER_BYPASS_MODE_LANE MULTI RX_BUFFER_RESET_ON_CB_CHANGE ENABLE RX_BUFFER_RESET_ON_COMMAALIGN DISABLE RX_BUFFER_RESET_ON_RATE_CHANGE\
ENABLE RX_CB_DISP 00000000 RX_CB_DISP_0_0 false RX_CB_DISP_0_1 false RX_CB_DISP_0_2 false RX_CB_DISP_0_3 false RX_CB_DISP_1_0 false RX_CB_DISP_1_1 false RX_CB_DISP_1_2 false RX_CB_DISP_1_3 false RX_CB_K\
00000000 RX_CB_K_0_0 false RX_CB_K_0_1 false RX_CB_K_0_2 false RX_CB_K_0_3 false RX_CB_K_1_0 false RX_CB_K_1_1 false RX_CB_K_1_2 false RX_CB_K_1_3 false RX_CB_LEN_SEQ 1 RX_CB_MASK 00000000 RX_CB_MASK_0_0\
false RX_CB_MASK_0_1 false RX_CB_MASK_0_2 false RX_CB_MASK_0_3 false RX_CB_MASK_1_0 false RX_CB_MASK_1_1 false RX_CB_MASK_1_2 false RX_CB_MASK_1_3 false RX_CB_MAX_LEVEL 1 RX_CB_MAX_SKEW 1 RX_CB_NUM_SEQ\
0 RX_CB_VAL 00000000000000000000000000000000000000000000000000000000000000000000000000000000 RX_CB_VAL_0_0 00000000 RX_CB_VAL_0_1 00000000 RX_CB_VAL_0_2 00000000 RX_CB_VAL_0_3 00000000 RX_CB_VAL_1_0 00000000\
RX_CB_VAL_1_1 00000000 RX_CB_VAL_1_2 00000000 RX_CB_VAL_1_3 00000000 RX_CC_DISP 00000000 RX_CC_DISP_0_0 false RX_CC_DISP_0_1 false RX_CC_DISP_0_2 false RX_CC_DISP_0_3 false RX_CC_DISP_1_0 false RX_CC_DISP_1_1\
false RX_CC_DISP_1_2 false RX_CC_DISP_1_3 false RX_CC_K 00000000 RX_CC_K_0_1 false RX_CC_K_0_2 false RX_CC_K_0_3 false RX_CC_K_1_0 false RX_CC_K_1_1 false RX_CC_K_1_2 false RX_CC_K_1_3 false RX_CC_MASK\
00000000 RX_CC_MASK_0_1 false RX_CC_MASK_0_2 false RX_CC_MASK_0_3 false RX_CC_MASK_1_0 false RX_CC_MASK_1_1 false RX_CC_MASK_1_2 false RX_CC_MASK_1_3 false RX_CC_PERIODICITY 5000 RX_CC_PRECEDENCE ENABLE\
RX_CC_REPEAT_WAIT 0 RX_CC_VAL 00000000000000000000000000000000000000000000000000000000000000000000000000011100 RX_CC_VAL_0_1 00000000 RX_CC_VAL_0_2 00000000 RX_CC_VAL_0_3 00000000 RX_CC_VAL_1_0 00000000\
RX_CC_VAL_1_1 00000000 RX_CC_VAL_1_2 00000000 RX_CC_VAL_1_3 00000000 RX_COMMA_SHOW_REALIGN_ENABLE true RX_COMMA_VALID_ONLY 0 RX_COUPLING AC RX_FRACN_ENABLED false RX_FRACN_NUMERATOR 0 RX_JTOL_LF_SLOPE\
-20 RX_RATE_GROUP A RX_TERMINATION PROGRAMMABLE RX_TERMINATION_PROG_VALUE 800} \
    CONFIG.INTF0_PARENTID {pl_pcie_qdma_rp_pcie_phy_0} \
    CONFIG.INTF0_PCIE_ENABLE {true} \
    CONFIG.INTF_PARENT_PIN_LIST {QUAD0_RX0 /qdma_0_support/pcie_phy/GT_RX0 QUAD0_RX1 /qdma_0_support/pcie_phy/GT_RX1 QUAD0_RX2 /qdma_0_support/pcie_phy/GT_RX2 QUAD0_RX3 /qdma_0_support/pcie_phy/GT_RX3\
QUAD0_TX0 /qdma_0_support/pcie_phy/GT_TX0 QUAD0_TX1 /qdma_0_support/pcie_phy/GT_TX1 QUAD0_TX2 /qdma_0_support/pcie_phy/GT_TX2 QUAD0_TX3 /qdma_0_support/pcie_phy/GT_TX3} \
    CONFIG.QUAD0_CH0_PCIERSTB_EN {true} \
    CONFIG.QUAD0_CH0_PHYREADY_EN {true} \
    CONFIG.QUAD0_CH0_PHYSTATUS_EN {true} \
    CONFIG.QUAD0_CH1_PCIERSTB_EN {true} \
    CONFIG.QUAD0_CH1_PHYREADY_EN {true} \
    CONFIG.QUAD0_CH1_PHYSTATUS_EN {true} \
    CONFIG.QUAD0_CH2_PCIERSTB_EN {true} \
    CONFIG.QUAD0_CH2_PHYREADY_EN {true} \
    CONFIG.QUAD0_CH2_PHYSTATUS_EN {true} \
    CONFIG.QUAD0_CH3_PCIERSTB_EN {true} \
    CONFIG.QUAD0_CH3_PHYREADY_EN {true} \
    CONFIG.QUAD0_CH3_PHYSTATUS_EN {true} \
    CONFIG.QUAD0_GT0_BUFGT_EN {true} \
    CONFIG.QUAD0_GT1_BUFGT_EN {true} \
    CONFIG.QUAD0_GT2_BUFGT_EN {true} \
    CONFIG.QUAD0_GT3_BUFGT_EN {true} \
    CONFIG.QUAD0_GT_RXMARGIN_INTF_EN {true} \
    CONFIG.QUAD0_PCIELTSSM_EN {true} \
    CONFIG.QUAD0_REFCLK_STRING {HSCLK0_LCPLLGTREFCLK0 refclk_PROT0_R0_100_MHz_unique1 HSCLK0_RPLLGTREFCLK0 refclk_PROT0_R0_100_MHz_unique1 HSCLK1_LCPLLGTREFCLK0 refclk_PROT0_R0_100_MHz_unique1 HSCLK1_RPLLGTREFCLK0\
refclk_PROT0_R0_100_MHz_unique1} \
    CONFIG.QUAD0_USAGE {TX_QUAD_CH {TXQuad_0_/pl_pcie_qdma_rp_gtwiz_versal_0_0/pl_pcie_qdma_rp_gtwiz_versal_0_0_gt_quad_base_0 {/pl_pcie_qdma_rp_gtwiz_versal_0_0/pl_pcie_qdma_rp_gtwiz_versal_0_0_gt_quad_base_0\
pl_pcie_qdma_rp_pcie_phy_0.IP_CH0,pl_pcie_qdma_rp_pcie_phy_0.IP_CH1,pl_pcie_qdma_rp_pcie_phy_0.IP_CH2,pl_pcie_qdma_rp_pcie_phy_0.IP_CH3 MSTRCLK 1,0,0,0 IS_CURRENT_QUAD 1}} RX_QUAD_CH {RXQuad_0_/pl_pcie_qdma_rp_gtwiz_versal_0_0/pl_pcie_qdma_rp_gtwiz_versal_0_0_gt_quad_base_0\
{/pl_pcie_qdma_rp_gtwiz_versal_0_0/pl_pcie_qdma_rp_gtwiz_versal_0_0_gt_quad_base_0 pl_pcie_qdma_rp_pcie_phy_0.IP_CH0,pl_pcie_qdma_rp_pcie_phy_0.IP_CH1,pl_pcie_qdma_rp_pcie_phy_0.IP_CH2,pl_pcie_qdma_rp_pcie_phy_0.IP_CH3\
MSTRCLK 1,0,0,0 IS_CURRENT_QUAD 1}}} \
    ] $gtwiz_versal_0

    set_property -dict [list \
      CONFIG.INTF0_PARENTID.VALUE_MODE {auto} \
      CONFIG.INTF_PARENT_PIN_LIST.VALUE_MODE {auto} \
      CONFIG.QUAD0_USAGE.VALUE_MODE {auto} \
    ] $gtwiz_versal_0
  } else {
    set_property -dict [list \
      CONFIG.GT_TYPE $gt_type \
      CONFIG.INTF0_GT_SETTINGS(GT_DIRECTION) {DUPLEX} \
      CONFIG.INTF0_GT_SETTINGS(GT_TYPE) $gt_type \
      CONFIG.INTF0_GT_SETTINGS(LR0_SETTINGS) {TX_BUFFER_MODE 0 PCIE_ENABLE true TX_PLL_TYPE LCPLL TX_REFCLK_SOURCE R0 TXPROGDIV_FREQ_ENABLE true TXPROGDIV_FREQ_SOURCE RPLL TX_OUTCLK_SOURCE TXPROGDIVCLK TX_DIFF_SWING_EMPH_MODE\
  CUSTOM TX_BUFFER_BYPASS_MODE Fast_Sync TX_DATA_ENCODING 8B10B TX_LINE_RATE 2.5 TX_USER_DATA_WIDTH 16 TX_INT_DATA_WIDTH 20 TX_REFCLK_FREQUENCY 100 PCIE_USERCLK_FREQ 250 TXPROGDIV_FREQ_VAL 500.000 PCIE_USERCLK2_FREQ\
  250 OOB_ENABLE true RX_BUFFER_MODE 1 RXPROGDIV_FREQ_ENABLE false RX_CC_LEN_SEQ 1 RX_CC_NUM_SEQ 1 RX_CC_K_0_0 true RX_CC_MASK_0_0 false RX_CC_VAL_0_0 00011100 RX_CC_KEEP_IDLE ENABLE RX_COMMA_ALIGN_WORD\
  1 RX_COMMA_PRESET K28.5 RX_COMMA_M_ENABLE true RX_COMMA_P_ENABLE true RX_COMMA_MASK 1111111111 RX_COMMA_M_VAL 0101111100 RX_COMMA_P_VAL 1010000011 RX_COMMA_DOUBLE_ENABLE false RX_JTOL_FC 1 RX_PLL_TYPE\
  LCPLL RX_SLIDE_MODE OFF RX_REFCLK_SOURCE R0 RX_OUTCLK_SOURCE RXOUTCLKPMA RX_EQ_MODE LPM RX_SSC_PPM 0 INS_LOSS_NYQ 20 RX_DATA_DECODING 8B10B RX_LINE_RATE 2.5 RX_PPM_OFFSET 0 RX_USER_DATA_WIDTH 16 RX_INT_DATA_WIDTH\
  20 RX_REFCLK_FREQUENCY 100} \
      CONFIG.INTF0_GT_SETTINGS(LR1_SETTINGS) {TX_BUFFER_MODE 0 PCIE_ENABLE true TX_PLL_TYPE LCPLL TX_REFCLK_SOURCE R0 TXPROGDIV_FREQ_ENABLE true TXPROGDIV_FREQ_SOURCE RPLL TX_OUTCLK_SOURCE TXPROGDIVCLK TX_DIFF_SWING_EMPH_MODE\
  CUSTOM TX_BUFFER_BYPASS_MODE Fast_Sync TX_DATA_ENCODING 8B10B TX_LINE_RATE 5.0 TX_USER_DATA_WIDTH 16 TX_INT_DATA_WIDTH 20 TX_REFCLK_FREQUENCY 100 PCIE_USERCLK_FREQ 250 TXPROGDIV_FREQ_VAL 500.000 PCIE_USERCLK2_FREQ\
  250 OOB_ENABLE true RX_BUFFER_MODE 1 RXPROGDIV_FREQ_ENABLE false RX_CC_LEN_SEQ 1 RX_CC_NUM_SEQ 1 RX_CC_K_0_0 true RX_CC_MASK_0_0 false RX_CC_VAL_0_0 00011100 RX_CC_KEEP_IDLE ENABLE RX_COMMA_ALIGN_WORD\
  1 RX_COMMA_PRESET K28.5 RX_COMMA_M_ENABLE true RX_COMMA_P_ENABLE true RX_COMMA_MASK 1111111111 RX_COMMA_M_VAL 0101111100 RX_COMMA_P_VAL 1010000011 RX_COMMA_DOUBLE_ENABLE false RX_JTOL_FC 1 RX_PLL_TYPE\
  LCPLL RX_SLIDE_MODE OFF RX_REFCLK_SOURCE R0 RX_OUTCLK_SOURCE RXOUTCLKPMA RX_EQ_MODE LPM RX_SSC_PPM 0 INS_LOSS_NYQ 20 RX_DATA_DECODING 8B10B RX_LINE_RATE 5.0 RX_PPM_OFFSET 0 RX_USER_DATA_WIDTH 16 RX_INT_DATA_WIDTH\
  20 RX_REFCLK_FREQUENCY 100} \
      CONFIG.INTF0_GT_SETTINGS(LR2_SETTINGS) {TX_BUFFER_MODE 0 PCIE_ENABLE true TX_PLL_TYPE LCPLL TX_REFCLK_SOURCE R0 TXPROGDIV_FREQ_ENABLE true TXPROGDIV_FREQ_SOURCE RPLL TX_OUTCLK_SOURCE TXPROGDIVCLK TX_DIFF_SWING_EMPH_MODE\
  CUSTOM TX_BUFFER_BYPASS_MODE Fast_Sync TX_DATA_ENCODING 128B130B TX_LINE_RATE 8.0 TX_USER_DATA_WIDTH 32 TX_INT_DATA_WIDTH 32 TX_REFCLK_FREQUENCY 100 PCIE_USERCLK_FREQ 250 TXPROGDIV_FREQ_VAL 500.000 PCIE_USERCLK2_FREQ\
  250 OOB_ENABLE true RX_BUFFER_MODE 1 RXPROGDIV_FREQ_ENABLE false RX_CC_LEN_SEQ 1 RX_CC_NUM_SEQ 1 RX_CC_K_0_0 true RX_CC_MASK_0_0 false RX_CC_VAL_0_0 00011100 RX_CC_KEEP_IDLE ENABLE RX_COMMA_ALIGN_WORD\
  1 RX_COMMA_PRESET K28.5 RX_COMMA_M_ENABLE true RX_COMMA_P_ENABLE true RX_COMMA_MASK 1111111111 RX_COMMA_M_VAL 0101111100 RX_COMMA_P_VAL 1010000011 RX_COMMA_DOUBLE_ENABLE false RX_JTOL_FC 1 RX_PLL_TYPE\
  LCPLL RX_SLIDE_MODE OFF RX_REFCLK_SOURCE R0 RX_OUTCLK_SOURCE RXOUTCLKPMA RX_EQ_MODE DFE RX_SSC_PPM 0 INS_LOSS_NYQ 20 RX_DATA_DECODING 128B130B RX_LINE_RATE 8.0 RX_PPM_OFFSET 0 RX_USER_DATA_WIDTH 32 RX_INT_DATA_WIDTH\
  32 RX_REFCLK_FREQUENCY 100} \
      CONFIG.INTF0_GT_SETTINGS(LR3_SETTINGS) {TX_BUFFER_MODE 0 PCIE_ENABLE true TX_PLL_TYPE LCPLL TX_REFCLK_SOURCE R0 TXPROGDIV_FREQ_ENABLE true TXPROGDIV_FREQ_SOURCE RPLL TX_OUTCLK_SOURCE TXPROGDIVCLK TX_DIFF_SWING_EMPH_MODE\
  CUSTOM TX_BUFFER_BYPASS_MODE Fast_Sync TX_DATA_ENCODING 128B130B TX_LINE_RATE 16.0 TX_USER_DATA_WIDTH 32 TX_INT_DATA_WIDTH 32 TX_REFCLK_FREQUENCY 100 PCIE_USERCLK_FREQ 250 TXPROGDIV_FREQ_VAL 500.000 PCIE_USERCLK2_FREQ\
  250 OOB_ENABLE true RX_BUFFER_MODE 1 RXPROGDIV_FREQ_ENABLE false RX_CC_LEN_SEQ 1 RX_CC_NUM_SEQ 1 RX_CC_K_0_0 true RX_CC_MASK_0_0 false RX_CC_VAL_0_0 00011100 RX_CC_KEEP_IDLE ENABLE RX_COMMA_ALIGN_WORD\
  1 RX_COMMA_PRESET K28.5 RX_COMMA_M_ENABLE true RX_COMMA_P_ENABLE true RX_COMMA_MASK 1111111111 RX_COMMA_M_VAL 0101111100 RX_COMMA_P_VAL 1010000011 RX_COMMA_DOUBLE_ENABLE false RX_JTOL_FC 1 RX_PLL_TYPE\
  LCPLL RX_SLIDE_MODE OFF RX_REFCLK_SOURCE R0 RX_OUTCLK_SOURCE RXOUTCLKPMA RX_EQ_MODE DFE RX_SSC_PPM 0 INS_LOSS_NYQ 20 RX_DATA_DECODING 128B130B RX_LINE_RATE 16.0 RX_PPM_OFFSET 0 RX_USER_DATA_WIDTH 32 RX_INT_DATA_WIDTH\
  32 RX_REFCLK_FREQUENCY 100} \
      CONFIG.INTF0_GT_SETTINGS(LR4_SETTINGS) {TX_BUFFER_MODE 0 PCIE_ENABLE true TX_PLL_TYPE LCPLL TX_REFCLK_SOURCE R0 TXPROGDIV_FREQ_ENABLE true TXPROGDIV_FREQ_SOURCE RPLL TX_OUTCLK_SOURCE TXPROGDIVCLK TX_DIFF_SWING_EMPH_MODE\
  CUSTOM TX_BUFFER_BYPASS_MODE Fast_Sync TX_DATA_ENCODING 128B130B TX_LINE_RATE 32.0 TX_USER_DATA_WIDTH 64 TX_INT_DATA_WIDTH 64 TX_REFCLK_FREQUENCY 100 PCIE_USERCLK_FREQ 250 TXPROGDIV_FREQ_VAL 500.000 PCIE_USERCLK2_FREQ\
  250 TX_ACTUAL_REFCLK_FREQUENCY 100.0 TX_FRACN_ENABLED false TX_FRACN_NUMERATOR 0 TX_PIPM_ENABLE false TX_64B66B_SCRAMBLER false TX_64B66B_ENCODER false TX_64B66B_CRC false TX_RATE_GROUP A TX_BUFFER_RESET_ON_RATE_CHANGE\
  ENABLE PRESET None INTERNAL_PRESET None OOB_ENABLE true RX_BUFFER_MODE 1 RXPROGDIV_FREQ_ENABLE false RX_CC_LEN_SEQ 1 RX_CC_NUM_SEQ 1 RX_CC_K_0_0 false RX_CC_MASK_0_0 false RX_CC_VAL_0_0 00011100 RX_CC_KEEP_IDLE\
  ENABLE RX_COMMA_ALIGN_WORD 1 RX_COMMA_PRESET K28.5 RX_COMMA_M_ENABLE true RX_COMMA_P_ENABLE true RX_COMMA_MASK 1111111111 RX_COMMA_M_VAL 0101111100 RX_COMMA_P_VAL 1010000011 RX_COMMA_DOUBLE_ENABLE false\
  RX_JTOL_FC 1 RX_PLL_TYPE LCPLL RX_SLIDE_MODE OFF RX_REFCLK_SOURCE R0 RX_OUTCLK_SOURCE RXOUTCLKPMA RX_EQ_MODE DFE RX_SSC_PPM 0 INS_LOSS_NYQ 20 RX_DATA_DECODING 128B130B RX_LINE_RATE 32.0 RX_PPM_OFFSET 0\
  RX_USER_DATA_WIDTH 64 RX_INT_DATA_WIDTH 64 RX_REFCLK_FREQUENCY 100 RESET_SEQUENCE_INTERVAL 0 RXPROGDIV_FREQ_SOURCE LCPLL RXPROGDIV_FREQ_VAL 322.265625 RX_64B66B_CRC false RX_64B66B_DECODER false RX_64B66B_DESCRAMBLER\
  false RX_ACTUAL_REFCLK_FREQUENCY 100.0 RX_BUFFER_BYPASS_MODE Fast_Sync RX_BUFFER_BYPASS_MODE_LANE MULTI RX_BUFFER_RESET_ON_CB_CHANGE ENABLE RX_BUFFER_RESET_ON_COMMAALIGN DISABLE RX_BUFFER_RESET_ON_RATE_CHANGE\
  ENABLE RX_CB_DISP 00000000 RX_CB_DISP_0_0 false RX_CB_DISP_0_1 false RX_CB_DISP_0_2 false RX_CB_DISP_0_3 false RX_CB_DISP_1_0 false RX_CB_DISP_1_1 false RX_CB_DISP_1_2 false RX_CB_DISP_1_3 false RX_CB_K\
  00000000 RX_CB_K_0_0 false RX_CB_K_0_1 false RX_CB_K_0_2 false RX_CB_K_0_3 false RX_CB_K_1_0 false RX_CB_K_1_1 false RX_CB_K_1_2 false RX_CB_K_1_3 false RX_CB_LEN_SEQ 1 RX_CB_MASK 00000000 RX_CB_MASK_0_0\
  false RX_CB_MASK_0_1 false RX_CB_MASK_0_2 false RX_CB_MASK_0_3 false RX_CB_MASK_1_0 false RX_CB_MASK_1_1 false RX_CB_MASK_1_2 false RX_CB_MASK_1_3 false RX_CB_MAX_LEVEL 1 RX_CB_MAX_SKEW 1 RX_CB_NUM_SEQ\
  0 RX_CB_VAL 00000000000000000000000000000000000000000000000000000000000000000000000000000000 RX_CB_VAL_0_0 00000000 RX_CB_VAL_0_1 00000000 RX_CB_VAL_0_2 00000000 RX_CB_VAL_0_3 00000000 RX_CB_VAL_1_0 00000000\
  RX_CB_VAL_1_1 00000000 RX_CB_VAL_1_2 00000000 RX_CB_VAL_1_3 00000000 RX_CC_DISP 00000000 RX_CC_DISP_0_0 false RX_CC_DISP_0_1 false RX_CC_DISP_0_2 false RX_CC_DISP_0_3 false RX_CC_DISP_1_0 false RX_CC_DISP_1_1\
  false RX_CC_DISP_1_2 false RX_CC_DISP_1_3 false RX_CC_K 00000000 RX_CC_K_0_1 false RX_CC_K_0_2 false RX_CC_K_0_3 false RX_CC_K_1_0 false RX_CC_K_1_1 false RX_CC_K_1_2 false RX_CC_K_1_3 false RX_CC_MASK\
  00000000 RX_CC_MASK_0_1 false RX_CC_MASK_0_2 false RX_CC_MASK_0_3 false RX_CC_MASK_1_0 false RX_CC_MASK_1_1 false RX_CC_MASK_1_2 false RX_CC_MASK_1_3 false RX_CC_PERIODICITY 5000 RX_CC_PRECEDENCE ENABLE\
  RX_CC_REPEAT_WAIT 0 RX_CC_VAL 00000000000000000000000000000000000000000000000000000000000000000000000000011100 RX_CC_VAL_0_1 00000000 RX_CC_VAL_0_2 00000000 RX_CC_VAL_0_3 00000000 RX_CC_VAL_1_0 00000000\
  RX_CC_VAL_1_1 00000000 RX_CC_VAL_1_2 00000000 RX_CC_VAL_1_3 00000000 RX_COMMA_SHOW_REALIGN_ENABLE true RX_COMMA_VALID_ONLY 0 RX_COUPLING AC RX_FRACN_ENABLED false RX_FRACN_NUMERATOR 0 RX_JTOL_LF_SLOPE\
  -20 RX_RATE_GROUP A RX_TERMINATION PROGRAMMABLE RX_TERMINATION_PROG_VALUE 800} \
      CONFIG.INTF0_PARENTID {pl_pcie_qdma_rp_pcie_phy_0} \
      CONFIG.INTF0_PCIE_ENABLE {true} \
      CONFIG.INTF_PARENT_PIN_LIST {QUAD0_RX0 /qdma_0_support/pcie_phy/GT_RX0 QUAD0_RX1 /qdma_0_support/pcie_phy/GT_RX1 QUAD0_RX2 /qdma_0_support/pcie_phy/GT_RX2 QUAD0_RX3 /qdma_0_support/pcie_phy/GT_RX3\
  QUAD0_TX0 /qdma_0_support/pcie_phy/GT_TX0 QUAD0_TX1 /qdma_0_support/pcie_phy/GT_TX1 QUAD0_TX2 /qdma_0_support/pcie_phy/GT_TX2 QUAD0_TX3 /qdma_0_support/pcie_phy/GT_TX3} \
      CONFIG.QUAD0_CH0_PCIERSTB_EN {true} \
      CONFIG.QUAD0_CH0_PHYREADY_EN {true} \
      CONFIG.QUAD0_CH0_PHYSTATUS_EN {true} \
      CONFIG.QUAD0_CH1_PCIERSTB_EN {true} \
      CONFIG.QUAD0_CH1_PHYREADY_EN {true} \
      CONFIG.QUAD0_CH1_PHYSTATUS_EN {true} \
      CONFIG.QUAD0_CH2_PCIERSTB_EN {true} \
      CONFIG.QUAD0_CH2_PHYREADY_EN {true} \
      CONFIG.QUAD0_CH2_PHYSTATUS_EN {true} \
      CONFIG.QUAD0_CH3_PCIERSTB_EN {true} \
      CONFIG.QUAD0_CH3_PHYREADY_EN {true} \
      CONFIG.QUAD0_CH3_PHYSTATUS_EN {true} \
      CONFIG.QUAD0_GT0_BUFGT_EN {true} \
      CONFIG.QUAD0_GT1_BUFGT_EN {true} \
      CONFIG.QUAD0_GT2_BUFGT_EN {true} \
      CONFIG.QUAD0_GT3_BUFGT_EN {true} \
      CONFIG.QUAD0_GT_RXMARGIN_INTF_EN {true} \
      CONFIG.QUAD0_PCIELTSSM_EN {true} \
      CONFIG.QUAD0_REFCLK_STRING {HSCLK0_LCPLLGTREFCLK0 refclk_PROT0_R0_100_MHz_unique1 HSCLK0_RPLLGTREFCLK0 refclk_PROT0_R0_100_MHz_unique1 HSCLK1_LCPLLGTREFCLK0 refclk_PROT0_R0_100_MHz_unique1 HSCLK1_RPLLGTREFCLK0\
  refclk_PROT0_R0_100_MHz_unique1} \
      CONFIG.QUAD0_USAGE {TX_QUAD_CH {TXQuad_0_/pl_pcie_qdma_rp_gtwiz_versal_0_0/pl_pcie_qdma_rp_gtwiz_versal_0_0_gt_quad_base_0 {/pl_pcie_qdma_rp_gtwiz_versal_0_0/pl_pcie_qdma_rp_gtwiz_versal_0_0_gt_quad_base_0\
  pl_pcie_qdma_rp_pcie_phy_0.IP_CH0,pl_pcie_qdma_rp_pcie_phy_0.IP_CH1,pl_pcie_qdma_rp_pcie_phy_0.IP_CH2,pl_pcie_qdma_rp_pcie_phy_0.IP_CH3 MSTRCLK 1,0,0,0 IS_CURRENT_QUAD 1}} RX_QUAD_CH {RXQuad_0_/pl_pcie_qdma_rp_gtwiz_versal_0_0/pl_pcie_qdma_rp_gtwiz_versal_0_0_gt_quad_base_0\
  {/pl_pcie_qdma_rp_gtwiz_versal_0_0/pl_pcie_qdma_rp_gtwiz_versal_0_0_gt_quad_base_0 pl_pcie_qdma_rp_pcie_phy_0.IP_CH0,pl_pcie_qdma_rp_pcie_phy_0.IP_CH1,pl_pcie_qdma_rp_pcie_phy_0.IP_CH2,pl_pcie_qdma_rp_pcie_phy_0.IP_CH3\
  MSTRCLK 1,0,0,0 IS_CURRENT_QUAD 1}}} \
    ] $gtwiz_versal_0

    set_property -dict [list \
      CONFIG.INTF0_PARENTID.VALUE_MODE {auto} \
      CONFIG.INTF_PARENT_PIN_LIST.VALUE_MODE {auto} \
      CONFIG.QUAD0_USAGE.VALUE_MODE {auto} \
    ] $gtwiz_versal_0
  }

  # Create instance: ilconstant_1, and set properties
  set ilconstant_1 [ create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconstant:1.0 ilconstant_1 ]

  # Create interface connections
  connect_bd_intf_net -intf_net Conn1 [get_bd_intf_pins refclk_ibuf/CLK_IN_D] [get_bd_intf_pins pcie_refclk]
  connect_bd_intf_net -intf_net Conn2 [get_bd_intf_pins pcie_phy/pcie_mgt] [get_bd_intf_pins pcie_mgt]
  connect_bd_intf_net -intf_net Conn3 [get_bd_intf_pins pcie/m_axis_cq] [get_bd_intf_pins m_axis_cq]
  connect_bd_intf_net -intf_net Conn4 [get_bd_intf_pins pcie/m_axis_rc] [get_bd_intf_pins m_axis_rc]
  connect_bd_intf_net -intf_net Conn5 [get_bd_intf_pins pcie/pcie_cfg_fc] [get_bd_intf_pins pcie_cfg_fc]
  connect_bd_intf_net -intf_net Conn6 [get_bd_intf_pins pcie/pcie_cfg_interrupt] [get_bd_intf_pins pcie_cfg_interrupt]
  connect_bd_intf_net -intf_net Conn7 [get_bd_intf_pins pcie/pcie_cfg_mesg_rcvd] [get_bd_intf_pins pcie_cfg_mesg_rcvd]
  connect_bd_intf_net -intf_net Conn8 [get_bd_intf_pins pcie/pcie_cfg_mesg_tx] [get_bd_intf_pins pcie_cfg_mesg_tx]
  connect_bd_intf_net -intf_net Conn9 [get_bd_intf_pins pcie/s_axis_cc] [get_bd_intf_pins s_axis_cc]
  connect_bd_intf_net -intf_net Conn10 [get_bd_intf_pins pcie/s_axis_rq] [get_bd_intf_pins s_axis_rq]
  connect_bd_intf_net -intf_net Conn11 [get_bd_intf_pins pcie/pcie_cfg_control] [get_bd_intf_pins pcie_cfg_control]
  connect_bd_intf_net -intf_net Conn12 [get_bd_intf_pins pcie/pcie_cfg_mgmt] [get_bd_intf_pins pcie_cfg_mgmt]
  connect_bd_intf_net -intf_net Conn13 [get_bd_intf_pins pcie/pcie_cfg_status] [get_bd_intf_pins pcie_cfg_status]
  connect_bd_intf_net -intf_net Conn14 [get_bd_intf_pins pcie/pcie_transmit_fc] [get_bd_intf_pins pcie_transmit_fc]
  connect_bd_intf_net -intf_net gt_quad_0_GT0_BUFGT [get_bd_intf_pins pcie_phy/GT_BUFGT] [get_bd_intf_pins gtwiz_versal_0/Quad0_GT0_BUFGT]
  connect_bd_intf_net -intf_net gt_quad_0_GT_Serial [get_bd_intf_pins pcie_phy/GT0_Serial] [get_bd_intf_pins gtwiz_versal_0/Quad0_GT_Serial]
  connect_bd_intf_net -intf_net pcie_phy_GT_RX0 [get_bd_intf_pins pcie_phy/GT_RX0] [get_bd_intf_pins gtwiz_versal_0/INTF0_RX0_GT_IP_Interface]
  connect_bd_intf_net -intf_net pcie_phy_GT_RX1 [get_bd_intf_pins pcie_phy/GT_RX1] [get_bd_intf_pins gtwiz_versal_0/INTF0_RX1_GT_IP_Interface]
  connect_bd_intf_net -intf_net pcie_phy_GT_RX2 [get_bd_intf_pins pcie_phy/GT_RX2] [get_bd_intf_pins gtwiz_versal_0/INTF0_RX2_GT_IP_Interface]
  connect_bd_intf_net -intf_net pcie_phy_GT_RX3 [get_bd_intf_pins pcie_phy/GT_RX3] [get_bd_intf_pins gtwiz_versal_0/INTF0_RX3_GT_IP_Interface]
  connect_bd_intf_net -intf_net pcie_phy_GT_TX0 [get_bd_intf_pins pcie_phy/GT_TX0] [get_bd_intf_pins gtwiz_versal_0/INTF0_TX0_GT_IP_Interface]
  connect_bd_intf_net -intf_net pcie_phy_GT_TX1 [get_bd_intf_pins pcie_phy/GT_TX1] [get_bd_intf_pins gtwiz_versal_0/INTF0_TX1_GT_IP_Interface]
  connect_bd_intf_net -intf_net pcie_phy_GT_TX2 [get_bd_intf_pins pcie_phy/GT_TX2] [get_bd_intf_pins gtwiz_versal_0/INTF0_TX2_GT_IP_Interface]
  connect_bd_intf_net -intf_net pcie_phy_GT_TX3 [get_bd_intf_pins pcie_phy/GT_TX3] [get_bd_intf_pins gtwiz_versal_0/INTF0_TX3_GT_IP_Interface]
  connect_bd_intf_net -intf_net pcie_phy_gt_rxmargin_q0 [get_bd_intf_pins pcie_phy/gt_rxmargin_q0] [get_bd_intf_pins gtwiz_versal_0/QUAD0_GT_RXMARGIN_INTF]
  connect_bd_intf_net -intf_net pcie_phy_mac_rx [get_bd_intf_pins pcie_phy/phy_mac_rx] [get_bd_intf_pins pcie/phy_mac_rx]
  connect_bd_intf_net -intf_net pcie_phy_mac_tx [get_bd_intf_pins pcie_phy/phy_mac_tx] [get_bd_intf_pins pcie/phy_mac_tx]
  connect_bd_intf_net -intf_net pcie_phy_phy_mac_command [get_bd_intf_pins pcie_phy/phy_mac_command] [get_bd_intf_pins pcie/phy_mac_command]
  connect_bd_intf_net -intf_net pcie_phy_phy_mac_rx_margining [get_bd_intf_pins pcie_phy/phy_mac_rx_margining] [get_bd_intf_pins pcie/phy_mac_rx_margining]
  connect_bd_intf_net -intf_net pcie_phy_phy_mac_status [get_bd_intf_pins pcie_phy/phy_mac_status] [get_bd_intf_pins pcie/phy_mac_status]
  connect_bd_intf_net -intf_net pcie_phy_phy_mac_tx_drive [get_bd_intf_pins pcie_phy/phy_mac_tx_drive] [get_bd_intf_pins pcie/phy_mac_tx_drive]
  connect_bd_intf_net -intf_net pcie_phy_phy_mac_tx_eq [get_bd_intf_pins pcie_phy/phy_mac_tx_eq] [get_bd_intf_pins pcie/phy_mac_tx_eq]

  # Create port connections
  connect_bd_net -net bufg_gt_sysclk_BUFG_GT_O  [get_bd_pins bufg_gt_sysclk/BUFG_GT_O] \
  [get_bd_pins gtwiz_versal_0/gtwiz_freerun_clk] \
  [get_bd_pins pcie/sys_clk] \
  [get_bd_pins pcie_phy/phy_refclk]
  connect_bd_net -net gt_quad_0_ch0_phyready  [get_bd_pins gtwiz_versal_0/QUAD0_ch0_phyready] \
  [get_bd_pins pcie_phy/ch0_phyready]
  connect_bd_net -net gt_quad_0_ch0_phystatus  [get_bd_pins gtwiz_versal_0/QUAD0_ch0_phystatus] \
  [get_bd_pins pcie_phy/ch0_phystatus]
  connect_bd_net -net gt_quad_0_ch0_rxoutclk  [get_bd_pins gtwiz_versal_0/QUAD0_RX0_outclk] \
  [get_bd_pins pcie_phy/gt_rxoutclk]
  connect_bd_net -net gt_quad_0_ch0_txoutclk  [get_bd_pins gtwiz_versal_0/QUAD0_TX0_outclk] \
  [get_bd_pins pcie_phy/gt_txoutclk]
  connect_bd_net -net gt_quad_0_ch1_phyready  [get_bd_pins gtwiz_versal_0/QUAD0_ch1_phyready] \
  [get_bd_pins pcie_phy/ch1_phyready]
  connect_bd_net -net gt_quad_0_ch1_phystatus  [get_bd_pins gtwiz_versal_0/QUAD0_ch1_phystatus] \
  [get_bd_pins pcie_phy/ch1_phystatus]
  connect_bd_net -net gt_quad_0_ch2_phyready  [get_bd_pins gtwiz_versal_0/QUAD0_ch2_phyready] \
  [get_bd_pins pcie_phy/ch2_phyready]
  connect_bd_net -net gt_quad_0_ch2_phystatus  [get_bd_pins gtwiz_versal_0/QUAD0_ch2_phystatus] \
  [get_bd_pins pcie_phy/ch2_phystatus]
  connect_bd_net -net gt_quad_0_ch3_phyready  [get_bd_pins gtwiz_versal_0/QUAD0_ch3_phyready] \
  [get_bd_pins pcie_phy/ch3_phyready]
  connect_bd_net -net gt_quad_0_ch3_phystatus  [get_bd_pins gtwiz_versal_0/QUAD0_ch3_phystatus] \
  [get_bd_pins pcie_phy/ch3_phystatus]
  connect_bd_net -net pcie_pcie_ltssm_state  [get_bd_pins pcie/pcie_ltssm_state] \
  [get_bd_pins pcie_ltssm_state] \
  [get_bd_pins pcie_phy/pcie_ltssm_state]
  connect_bd_net -net pcie_phy_gt_pcieltssm  [get_bd_pins pcie_phy/gt_pcieltssm] \
  [get_bd_pins gtwiz_versal_0/QUAD0_pcieltssm]
  connect_bd_net -net pcie_phy_gtrefclk  [get_bd_pins pcie_phy/gtrefclk] \
  [get_bd_pins gtwiz_versal_0/QUAD0_GTREFCLK0]
  connect_bd_net -net pcie_phy_pcierstb  [get_bd_pins pcie_phy/pcierstb] \
  [get_bd_pins gtwiz_versal_0/QUAD0_ch0_pcierstb] \
  [get_bd_pins gtwiz_versal_0/QUAD0_ch1_pcierstb] \
  [get_bd_pins gtwiz_versal_0/QUAD0_ch2_pcierstb] \
  [get_bd_pins gtwiz_versal_0/QUAD0_ch3_pcierstb]
  connect_bd_net -net pcie_phy_phy_coreclk  [get_bd_pins pcie_phy/phy_coreclk] \
  [get_bd_pins pcie/phy_coreclk]
  connect_bd_net -net pcie_phy_phy_mcapclk  [get_bd_pins pcie_phy/phy_mcapclk] \
  [get_bd_pins pcie/phy_mcapclk]
  connect_bd_net -net pcie_phy_phy_pclk  [get_bd_pins pcie_phy/phy_pclk] \
  [get_bd_pins gtwiz_versal_0/QUAD0_TX0_usrclk] \
  [get_bd_pins gtwiz_versal_0/QUAD0_TX1_usrclk] \
  [get_bd_pins gtwiz_versal_0/QUAD0_TX2_usrclk] \
  [get_bd_pins gtwiz_versal_0/QUAD0_TX3_usrclk] \
  [get_bd_pins gtwiz_versal_0/QUAD0_RX0_usrclk] \
  [get_bd_pins gtwiz_versal_0/QUAD0_RX1_usrclk] \
  [get_bd_pins gtwiz_versal_0/QUAD0_RX2_usrclk] \
  [get_bd_pins gtwiz_versal_0/QUAD0_RX3_usrclk] \
  [get_bd_pins pcie/phy_pclk]
  connect_bd_net -net pcie_phy_phy_userclk  [get_bd_pins pcie_phy/phy_userclk] \
  [get_bd_pins pcie/phy_userclk]
  connect_bd_net -net pcie_phy_phy_userclk2  [get_bd_pins pcie_phy/phy_userclk2] \
  [get_bd_pins pcie/phy_userclk2]
  connect_bd_net -net pcie_phy_rdy_out  [get_bd_pins pcie/phy_rdy_out] \
  [get_bd_pins phy_rdy_out]
  connect_bd_net -net pcie_user_clk  [get_bd_pins pcie/user_clk] \
  [get_bd_pins user_clk]
  connect_bd_net -net pcie_user_lnk_up  [get_bd_pins pcie/user_lnk_up] \
  [get_bd_pins user_lnk_up]
  connect_bd_net -net pcie_user_reset  [get_bd_pins pcie/user_reset] \
  [get_bd_pins user_reset]
  connect_bd_net -net refclk_ibuf_IBUF_DS_ODIV2  [get_bd_pins refclk_ibuf/IBUF_DS_ODIV2] \
  [get_bd_pins bufg_gt_sysclk/BUFG_GT_I]
  connect_bd_net -net refclk_ibuf_IBUF_OUT  [get_bd_pins refclk_ibuf/IBUF_OUT] \
  [get_bd_pins pcie/sys_clk_gt] \
  [get_bd_pins pcie_phy/phy_gtrefclk]
  connect_bd_net -net sys_reset_1  [get_bd_pins sys_reset] \
  [get_bd_pins pcie/sys_reset] \
  [get_bd_pins pcie_phy/phy_rst_n]
  connect_bd_net -net xlconstant_0_dout  [get_bd_pins ilconstant_1/dout] \
  [get_bd_pins bufg_gt_sysclk/BUFG_GT_CE]

  # Restore current instance
  current_bd_instance /
}

proc create_qdma { index } {
  global is_vpk120
  global is_vpk180
  global is_vck190
  global is_vmk180
  global is_vek280
  global is_vhk158
  global pcie_blk_locn
  set qdma [ create_bd_cell -type ip -vlnv xilinx.com:ip:qdma qdma_$index ]
  if {$is_vck190 || $is_vmk180 || $is_vek280} {
    set_property -dict [ list \
      CONFIG.pcie_blk_locn [lindex $pcie_blk_locn $index] \
      CONFIG.axibar_notranslate {true} \
      CONFIG.axibar_num {2} \
      CONFIG.device_port_type {Root_Port_of_PCI_Express_Root_Complex} \
      CONFIG.dma_reset_source_sel {Phy_Ready} \
      CONFIG.functional_mode {AXI_Bridge} \
      CONFIG.mode_selection {Advanced} \
      CONFIG.pf0_bar0_prefetchable_qdma {true} \
      CONFIG.pf0_bar0_scale_qdma {Terabytes} \
      CONFIG.pf0_bar0_size_qdma {16} \
      CONFIG.pl_link_cap_max_link_speed {16.0_GT/s} \
      CONFIG.pl_link_cap_max_link_width {X4} \
    ] $qdma
  } else {
    set_property -dict [ list \
      CONFIG.enable_gtwizard {false} \
      CONFIG.pcie_blk_locn [lindex $pcie_blk_locn $index] \
      CONFIG.axibar_notranslate {true} \
      CONFIG.axibar_num {2} \
      CONFIG.device_port_type {Root_Port_of_PCI_Express_Root_Complex} \
      CONFIG.dma_reset_source_sel {Phy_Ready} \
      CONFIG.functional_mode {AXI_Bridge} \
      CONFIG.mode_selection {Advanced} \
      CONFIG.pf0_bar0_prefetchable_qdma {true} \
      CONFIG.pf0_bar0_scale_qdma {Terabytes} \
      CONFIG.pf0_bar0_size_qdma {16} \
      CONFIG.pl_link_cap_max_link_speed {32.0_GT/s} \
      CONFIG.pl_link_cap_max_link_width {X4} \
    ] $qdma
  }
}

create_qdma 0
create_qdma_support 0
if {$dual_design} {
  create_qdma 1
  create_qdma_support 1
}

# Constant high
create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconstant:1.0 const_high

# Ports
proc connect_qdma_ports { index } {
  create_bd_intf_port -mode Master -vlnv xilinx.com:interface:gt_rtl:1.0 pci_exp_$index
  connect_bd_intf_net -intf_net qdma_support_${index}_pcie_mgt [get_bd_intf_ports pci_exp_$index] [get_bd_intf_pins qdma_support_${index}/pcie_mgt]

  create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 ref_clk_$index
  connect_bd_intf_net -intf_net pcie_refclk_$index [get_bd_intf_ports ref_clk_$index] [get_bd_intf_pins qdma_support_${index}/pcie_refclk]
}

connect_qdma_ports 0
if {$dual_design} {
  connect_qdma_ports 1
}

# QDMA interrupts
proc connect_qdma_intr { index } {
  global intr_list
  lappend intr_list "qdma_$index/interrupt_out"
  lappend intr_list "qdma_$index/interrupt_out_msi_vec0to31"
  lappend intr_list "qdma_$index/interrupt_out_msi_vec32to63"
}

connect_qdma_intr 0
if {$dual_design} {
  connect_qdma_intr 1
}

# Connections between QDMA and QDMA support block
proc connect_qdma_support { index } {

  connect_bd_intf_net -boundary_type upper [get_bd_intf_pins qdma_support_${index}/m_axis_cq] [get_bd_intf_pins qdma_${index}/m_axis_cq]
  connect_bd_intf_net -boundary_type upper [get_bd_intf_pins qdma_support_${index}/m_axis_rc] [get_bd_intf_pins qdma_${index}/m_axis_rc]
  connect_bd_intf_net -boundary_type upper [get_bd_intf_pins qdma_support_${index}/pcie_cfg_fc] [get_bd_intf_pins qdma_${index}/pcie_cfg_fc]
  connect_bd_intf_net -boundary_type upper [get_bd_intf_pins qdma_support_${index}/pcie_cfg_mesg_rcvd] [get_bd_intf_pins qdma_${index}/pcie_cfg_mesg_rcvd]
  connect_bd_intf_net -boundary_type upper [get_bd_intf_pins qdma_support_${index}/pcie_cfg_mesg_tx] [get_bd_intf_pins qdma_${index}/pcie_cfg_mesg_tx]
  connect_bd_intf_net -boundary_type upper [get_bd_intf_pins qdma_support_${index}/pcie_cfg_status] [get_bd_intf_pins qdma_${index}/pcie_cfg_status_if]
  connect_bd_intf_net -boundary_type upper [get_bd_intf_pins qdma_support_${index}/pcie_transmit_fc] [get_bd_intf_pins qdma_${index}/pcie_transmit_fc_if]
  connect_bd_net [get_bd_pins qdma_support_${index}/phy_rdy_out] [get_bd_pins qdma_${index}/phy_rdy_out_sd]
  connect_bd_net [get_bd_pins qdma_support_${index}/user_clk] [get_bd_pins qdma_${index}/user_clk_sd]
  connect_bd_net [get_bd_pins qdma_support_${index}/user_lnk_up] [get_bd_pins qdma_${index}/user_lnk_up_sd]
  connect_bd_net [get_bd_pins qdma_support_${index}/user_reset] [get_bd_pins qdma_${index}/user_reset_sd]
  connect_bd_intf_net [get_bd_intf_pins qdma_${index}/pcie_cfg_control_if] -boundary_type upper [get_bd_intf_pins qdma_support_${index}/pcie_cfg_control]
  connect_bd_intf_net [get_bd_intf_pins qdma_${index}/pcie_cfg_interrupt] -boundary_type upper [get_bd_intf_pins qdma_support_${index}/pcie_cfg_interrupt]
  connect_bd_intf_net [get_bd_intf_pins qdma_${index}/pcie_cfg_mgmt_if] -boundary_type upper [get_bd_intf_pins qdma_support_${index}/pcie_cfg_mgmt]
  connect_bd_intf_net [get_bd_intf_pins qdma_${index}/s_axis_cc] -boundary_type upper [get_bd_intf_pins qdma_support_${index}/s_axis_cc]
  connect_bd_intf_net [get_bd_intf_pins qdma_${index}/s_axis_rq] -boundary_type upper [get_bd_intf_pins qdma_support_${index}/s_axis_rq]
  connect_bd_net [get_bd_pins const_high/dout] [get_bd_pins qdma_support_${index}/sys_reset]
  connect_bd_net [get_bd_pins const_high/dout] [get_bd_pins qdma_${index}/soft_reset_n]

}

connect_qdma_support 0
if {$dual_design} {
  connect_qdma_support 1
}

# QDMA axi_aclk drives CIPS M_AXI_FPD/LPD clock inputs and the NoC
connect_bd_net [get_bd_pins versal_cips_0/pl0_ref_clk] [get_bd_pins versal_cips_0/m_axi_fpd_aclk]
connect_bd_net [get_bd_pins versal_cips_0/pl0_ref_clk] [get_bd_pins versal_cips_0/m_axi_lpd_aclk]
connect_bd_net [get_bd_pins versal_cips_0/pl0_ref_clk] [get_bd_pins axi_noc_0/aclk8]

# Add processor system reset for CIPS pl0_resetn
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 reset_pl0
connect_bd_net [get_bd_pins versal_cips_0/pl0_resetn] [get_bd_pins reset_pl0/ext_reset_in]
connect_bd_net [get_bd_pins versal_cips_0/pl0_ref_clk] [get_bd_pins reset_pl0/slowest_sync_clk]

# Add smartconnect for the M_AXI_BRIDGE of the QDMA
# (nvrec_bridge_split: qdma_1 gets its own SmartConnect and NoC NMU further
# below, so this one only carries qdma_0)
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 smc_m_axi_bridge
if {$dual_design && !$nvrec_bridge_split} {
  set_property -dict [list CONFIG.NUM_CLKS {3} CONFIG.NUM_MI {1} CONFIG.NUM_SI {2}] [get_bd_cells smc_m_axi_bridge]
  connect_bd_intf_net [get_bd_intf_pins smc_m_axi_bridge/M00_AXI] [get_bd_intf_pins axi_noc_0/S08_AXI]
  connect_bd_intf_net [get_bd_intf_pins qdma_0/M_AXI_BRIDGE] [get_bd_intf_pins smc_m_axi_bridge/S00_AXI]
  connect_bd_intf_net [get_bd_intf_pins qdma_1/M_AXI_BRIDGE] [get_bd_intf_pins smc_m_axi_bridge/S01_AXI]
  connect_bd_net [get_bd_pins versal_cips_0/pl0_ref_clk] [get_bd_pins smc_m_axi_bridge/aclk]
  connect_bd_net [get_bd_pins qdma_0/axi_aclk] [get_bd_pins smc_m_axi_bridge/aclk1]
  connect_bd_net [get_bd_pins qdma_1/axi_aclk] [get_bd_pins smc_m_axi_bridge/aclk2]
  connect_bd_net [get_bd_pins reset_pl0/peripheral_aresetn] [get_bd_pins smc_m_axi_bridge/aresetn]
} else {
  set_property -dict [list CONFIG.NUM_CLKS {2} CONFIG.NUM_MI {1} CONFIG.NUM_SI {1}] [get_bd_cells smc_m_axi_bridge]
  connect_bd_intf_net [get_bd_intf_pins smc_m_axi_bridge/M00_AXI] [get_bd_intf_pins axi_noc_0/S08_AXI]
  connect_bd_intf_net [get_bd_intf_pins qdma_0/M_AXI_BRIDGE] [get_bd_intf_pins smc_m_axi_bridge/S00_AXI]
  connect_bd_net [get_bd_pins versal_cips_0/pl0_ref_clk] [get_bd_pins smc_m_axi_bridge/aclk]
  connect_bd_net [get_bd_pins qdma_0/axi_aclk] [get_bd_pins smc_m_axi_bridge/aclk1]
  connect_bd_net [get_bd_pins reset_pl0/peripheral_aresetn] [get_bd_pins smc_m_axi_bridge/aresetn]
}

# Add smartconnects for the M_AXI_FPD to QDMA S_AXI_BRIDGE
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 smc_m_axi_fpd
if {$dual_design} {
  set_property -dict [list CONFIG.NUM_CLKS {3} CONFIG.NUM_MI {2} CONFIG.NUM_SI {1}] [get_bd_cells smc_m_axi_fpd]
  connect_bd_intf_net [get_bd_intf_pins versal_cips_0/M_AXI_FPD] [get_bd_intf_pins smc_m_axi_fpd/S00_AXI]
  connect_bd_net [get_bd_pins versal_cips_0/pl0_ref_clk] [get_bd_pins smc_m_axi_fpd/aclk]
  connect_bd_net [get_bd_pins qdma_0/axi_aclk] [get_bd_pins smc_m_axi_fpd/aclk1]
  connect_bd_net [get_bd_pins qdma_1/axi_aclk] [get_bd_pins smc_m_axi_fpd/aclk2]
  connect_bd_intf_net [get_bd_intf_pins smc_m_axi_fpd/M00_AXI] [get_bd_intf_pins qdma_0/S_AXI_BRIDGE]
  connect_bd_intf_net [get_bd_intf_pins smc_m_axi_fpd/M01_AXI] [get_bd_intf_pins qdma_1/S_AXI_BRIDGE]
  connect_bd_net [get_bd_pins reset_pl0/peripheral_aresetn] [get_bd_pins smc_m_axi_fpd/aresetn]
} else {
  set_property -dict [list CONFIG.NUM_CLKS {2} CONFIG.NUM_MI {1} CONFIG.NUM_SI {1}] [get_bd_cells smc_m_axi_fpd]
  connect_bd_intf_net [get_bd_intf_pins versal_cips_0/M_AXI_FPD] [get_bd_intf_pins smc_m_axi_fpd/S00_AXI]
  connect_bd_net [get_bd_pins versal_cips_0/pl0_ref_clk] [get_bd_pins smc_m_axi_fpd/aclk]
  connect_bd_net [get_bd_pins qdma_0/axi_aclk] [get_bd_pins smc_m_axi_fpd/aclk1]
  connect_bd_intf_net [get_bd_intf_pins smc_m_axi_fpd/M00_AXI] [get_bd_intf_pins qdma_0/S_AXI_BRIDGE]
  connect_bd_net [get_bd_pins reset_pl0/peripheral_aresetn] [get_bd_pins smc_m_axi_fpd/aresetn]
}

# Add smartconnects for the M_AXI_LPD to QDMA S_AXI_LITE and S_AXI_LITE_CSR
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 smc_m_axi_lpd
if {$dual_design} {
  set_property -dict [list CONFIG.NUM_CLKS {3} CONFIG.NUM_MI {4} CONFIG.NUM_SI {1}] [get_bd_cells smc_m_axi_lpd]
  connect_bd_intf_net [get_bd_intf_pins versal_cips_0/M_AXI_LPD] [get_bd_intf_pins smc_m_axi_lpd/S00_AXI]
  connect_bd_net [get_bd_pins versal_cips_0/pl0_ref_clk] [get_bd_pins smc_m_axi_lpd/aclk]
  connect_bd_net [get_bd_pins qdma_0/axi_aclk] [get_bd_pins smc_m_axi_lpd/aclk1]
  connect_bd_net [get_bd_pins qdma_1/axi_aclk] [get_bd_pins smc_m_axi_lpd/aclk2]
  connect_bd_intf_net [get_bd_intf_pins smc_m_axi_lpd/M00_AXI] [get_bd_intf_pins qdma_0/S_AXI_LITE]
  connect_bd_intf_net [get_bd_intf_pins smc_m_axi_lpd/M01_AXI] [get_bd_intf_pins qdma_0/S_AXI_LITE_CSR]
  connect_bd_intf_net [get_bd_intf_pins smc_m_axi_lpd/M02_AXI] [get_bd_intf_pins qdma_1/S_AXI_LITE]
  connect_bd_intf_net [get_bd_intf_pins smc_m_axi_lpd/M03_AXI] [get_bd_intf_pins qdma_1/S_AXI_LITE_CSR]
  connect_bd_net [get_bd_pins reset_pl0/peripheral_aresetn] [get_bd_pins smc_m_axi_lpd/aresetn]
} else {
  set_property -dict [list CONFIG.NUM_CLKS {2} CONFIG.NUM_MI {2} CONFIG.NUM_SI {1}] [get_bd_cells smc_m_axi_lpd]
  connect_bd_intf_net [get_bd_intf_pins versal_cips_0/M_AXI_LPD] [get_bd_intf_pins smc_m_axi_lpd/S00_AXI]
  connect_bd_net [get_bd_pins versal_cips_0/pl0_ref_clk] [get_bd_pins smc_m_axi_lpd/aclk]
  connect_bd_net [get_bd_pins qdma_0/axi_aclk] [get_bd_pins smc_m_axi_lpd/aclk1]
  connect_bd_intf_net [get_bd_intf_pins smc_m_axi_lpd/M00_AXI] [get_bd_intf_pins qdma_0/S_AXI_LITE]
  connect_bd_intf_net [get_bd_intf_pins smc_m_axi_lpd/M01_AXI] [get_bd_intf_pins qdma_0/S_AXI_LITE_CSR]
  connect_bd_net [get_bd_pins reset_pl0/peripheral_aresetn] [get_bd_pins smc_m_axi_lpd/aresetn]
}


# ##########################################################
# FPGA Drive NVMe offload recorder (nvrec), Versal
# ##########################################################
#
#  user_data_source (src_clk 250)    nvrec_core_0 (dp_clk 250)                nvmeha_0 (AMD NVMe
#  [fdrec_tpg] --AXIS DWb--> [ingest -> ring writer] --AXI4 DWb--> axi_smc_dma -> axi_noc_0 (PL NMU, DWb) -> DDR MC
#                             [cmd builder] --SQE AXIS 512b--> S_AXIS    Host Accelerator)
#                             [cq router]   <--CQE AXIS 128b-- M_AXIS
#                             [dbmon] <--- M_AXI_SSD (doorbells) ; m_axi_db -> smc_m_axi_fpd -> qdma_N/S_AXI_BRIDGE
#  user_data_sink  <-- egress FIFO <-- [ring reader] (playback)
#
#  SSD DMA:  qdma_N/M_AXI_BRIDGE -> smc_m_axi_bridge -+-> axi_noc_0/S08_AXI -> DDR MC (data, PRP lists,
#                                                    |                       admin queues)
#                                                    +-> nvmeha_0/S_AXI_SSD (I/O SQ/CQ memory, 0x9000_0000)
#            nvrec_bridge_split (512-bit build): one NMU per bridge
#            qdma_0/M_AXI_BRIDGE -> smc_m_axi_bridge   -+-> axi_noc_0/S08_AXI -> MC_1
#            qdma_1/M_AXI_BRIDGE -> smc_m_axi_bridge_1 -+-> axi_noc_0/Snn_AXI -> MC_3
#                                     (both M01) -> smc_q -> nvmeha_0/S_AXI_SSD
#  PS:       M_AXI_FPD -> smc_m_axi_fpd -> qdma_N/S_AXI_BRIDGE (BAR windows, base design),
#            nvrec_core_0 regs, nvmeha_guard (AXI-Lite timeout guard) -> nvmeha_0 S_AXI_LITE
#  Split ring (register map 1.3, ring_mem lpddr4 in config/data.json): memory 1 =
#  the on-board LPDDR4 (second NoC instance noc_lpddr4 with ONE DDRMC, both x32
#  channels interleaved; see the split-ring block below for why not the BSP's two
#  interleaved DDRMCs), at DDR_CH2 0x600_0000_0000 (4 GB):
#            nvrec_core_0/m_axi1 -> axi_smc_dma1 -> noc_lpddr4/S00_AXI (PL NMU, DWb) -> MC_0
#            axi_noc_0/S08_AXI (qdma_0 bridge) -> M00_INI -> noc_lpddr4/S00_INI -> MC_1
#            axi_noc_0/Snn_AXI (qdma_1 bridge) -> M01_INI -> noc_lpddr4/S01_INI -> MC_2
#            (the PS NMUs get no route: the CPUs never see the LPDDR4)
#
# Differences from the Zynq UltraScale+ design (bd_zynqmp.tcl), same function:
#   * the QDMA bridges translate nothing (axibar_notranslate, root-port BAR0 at
#     PCIe 0 = AXI 0): an SSD's PCIe address is the AXI address on the bridge's
#     M_AXI_BRIDGE, and the CPU's BAR-window address is the SSD's PCIe address.
#     The SSD BARs land in the 32-bit windows 0xA800_0000 / 0xAC00_0000 (64 MB
#     each, the non-prefetchable windows of the base design), which the 32-bit
#     doorbell master of the Host Accelerator (M_AXI_SSD) can reach.
#   * both bridges' M_AXI_BRIDGE share one SmartConnect (as in the base design);
#     its second master port is the Host Accelerator's queue window. With
#     nvrec_bridge_split each bridge has its own SmartConnect and NoC NMU, and
#     a 2-SI SmartConnect (smc_q, as on ZynqMP) merges their queue-window paths.
#   * the doorbell master (through the nvrec_core doorbell monitor) is a second
#     slave port of the base design's M_AXI_FPD SmartConnect; its address space
#     holds only the two BAR0 windows (everything else excluded).
#   * clocks: CIPS PL1 = 250 MHz dp_clk, PL2 = 250 MHz src_clk, PL3 = 100 MHz
#     (nvmeha AXI-Lite, <= 100 MHz per PG328). PL0 (250 MHz) stays the base
#     design's QDMA / PS-interface clock.
#   * the ring path is one NoC NMU of nvrec_data_width bits at dp_clk (no HP
#     port width limit as on ZynqMP): 8.0 GB/s per direction at 256 bits,
#     16.0 GB/s at 512 bits (NoC QoS request capped at 14000 MB/s, see below).
#   * DDR: PS DDR4 at 0x0 (2 GB) and 0x500_0000_0000 (6 GB, DDR_CH1) on the
#     VCK190; LPDDR4 (split ring memory 1) at 0x600_0000_0000 (DDR_CH2) for
#     nvrec_core_0/m_axi1 and the QDMA bridges only; all PL masters use 64-bit
#     addresses, the queue window 0x9000_0000 sits in the bridges' address
#     spaces where no DDR is mapped.
#
# DWb = nvrec_data_width bits (nvrec_params.tcl / config/data.json data_width,
# 512 on vck190_fmcp1 since dp256: with it nvrec_bridge_split = 1, ie. one NoC
# NMU per QDMA bridge).
#
# The user_data_source / user_data_sink hierarchies are the documented
# insertion points for a customer's own data source / sink; identical to the
# Zynq UltraScale+ design.

if {!$dual_design} {
  error "nvrec: the NVMe offload design needs both SSD slots (dual design)"
}

# Returns the address segment of <space> that maps <slave_seg> (or "")
proc nvrec_find_seg {space slave_seg} {
  set ss [get_bd_addr_segs $slave_seg]
  foreach s [get_bd_addr_segs -quiet -of_objects [get_bd_addr_spaces $space]] {
    if {[get_bd_addr_segs -of_objects $s] eq $ss} { return $s }
  }
  return ""
}
# Maps <slave_seg> into <space> at <offset>/<range> (assigning it if needed)
proc nvrec_map {space slave_seg offset range} {
  set seg [nvrec_find_seg $space $slave_seg]
  if {$seg eq ""} {
    assign_bd_address -target_address_space [get_bd_addr_spaces $space] -offset $offset -range $range [get_bd_addr_segs $slave_seg]
  } else {
    # offset first: the new offset is aligned for the new range, the old
    # range may not be aligned for the new offset
    set_property offset $offset $seg
    set_property range $range $seg
  }
}

# Enable PL1 (250 MHz), PL2 (250 MHz) and PL3 (100 MHz) reference clocks.
# CIPS merges these keys into the per-board PS_PMC_CONFIG above.
set_property CONFIG.PS_PMC_CONFIG { \
  PS_USE_PMCPL_CLK1 {1} \
  PMC_CRP_PL1_REF_CTRL_FREQMHZ {250} \
  PS_USE_PMCPL_CLK2 {1} \
  PMC_CRP_PL2_REF_CTRL_FREQMHZ {250} \
  PS_USE_PMCPL_CLK3 {1} \
  PMC_CRP_PL3_REF_CTRL_FREQMHZ {100} \
} [get_bd_cells versal_cips_0]

# Actual PL clock frequencies (the PMC PLL dividers may not hit the requested values exactly)
set dp_clk_hz   [expr {int(round([get_property CONFIG.FREQ_HZ [get_bd_pins versal_cips_0/pl1_ref_clk]]))}]
set src_clk_hz  [expr {int(round([get_property CONFIG.FREQ_HZ [get_bd_pins versal_cips_0/pl2_ref_clk]]))}]
set lite_clk_hz [expr {int(round([get_property CONFIG.FREQ_HZ [get_bd_pins versal_cips_0/pl3_ref_clk]]))}]
puts "INFO: nvrec dp_clk (pl1_ref_clk) = $dp_clk_hz Hz, src_clk (pl2_ref_clk) = $src_clk_hz Hz, lite clk (pl3_ref_clk) = $lite_clk_hz Hz, DATA_WIDTH = $nvrec_data_width"
foreach {name hz} [list dp_clk $dp_clk_hz src_clk $src_clk_hz] {
  if {abs($hz - 250000000) > 250000} {
    error "nvrec: $name = $hz Hz, expected 250 MHz"
  }
}
if {$lite_clk_hz > 100000000} {
  error "nvrec: nvmeha clk_axi_lite must be <= 100 MHz (PG328), pl3_ref_clk = $lite_clk_hz Hz"
}

# Resets: dp_clk, src_clk, and pl3 (nvmeha AXI-Lite)
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_dp_clk
connect_bd_net [get_bd_pins versal_cips_0/pl1_ref_clk] [get_bd_pins rst_dp_clk/slowest_sync_clk]
connect_bd_net [get_bd_pins versal_cips_0/pl0_resetn] [get_bd_pins rst_dp_clk/ext_reset_in]
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_src_clk
connect_bd_net [get_bd_pins versal_cips_0/pl2_ref_clk] [get_bd_pins rst_src_clk/slowest_sync_clk]
connect_bd_net [get_bd_pins versal_cips_0/pl0_resetn] [get_bd_pins rst_src_clk/ext_reset_in]
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_lite_clk
connect_bd_net [get_bd_pins versal_cips_0/pl3_ref_clk] [get_bd_pins rst_lite_clk/slowest_sync_clk]
connect_bd_net [get_bd_pins versal_cips_0/pl0_resetn] [get_bd_pins rst_lite_clk/ext_reset_in]

# user_data_source hierarchy: the test pattern generator (as fpga-drive-recorder)
create_bd_cell -type hier user_data_source
create_bd_pin -dir I -type clk user_data_source/src_clk
create_bd_pin -dir I -type rst user_data_source/src_resetn
create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:axis_rtl:1.0 user_data_source/M_AXIS
create_bd_pin -dir I user_data_source/tpg_enable
create_bd_pin -dir I user_data_source/tpg_seq_rst
create_bd_pin -dir I -from 31 -to 0 user_data_source/tpg_rate_inc
create_bd_pin -dir O -from 63 -to 0 user_data_source/tpg_seq_next
create_bd_cell -type module -reference fdrec_tpg user_data_source/fdrec_tpg_0
set_property CONFIG.DATA_WIDTH $nvrec_data_width [get_bd_cells user_data_source/fdrec_tpg_0]
foreach p {src_clk src_resetn tpg_enable tpg_seq_rst tpg_rate_inc tpg_seq_next} {
  connect_bd_net [get_bd_pins user_data_source/$p] [get_bd_pins user_data_source/fdrec_tpg_0/$p]
}
connect_bd_intf_net [get_bd_intf_pins user_data_source/M_AXIS] [get_bd_intf_pins user_data_source/fdrec_tpg_0/m_axis]

# user_data_sink hierarchy: the playback checker (as fpga-drive-recorder)
create_bd_cell -type hier user_data_sink
create_bd_pin -dir I -type clk user_data_sink/snk_clk
create_bd_pin -dir I -type rst user_data_sink/snk_resetn
create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:axis_rtl:1.0 user_data_sink/S_AXIS
create_bd_pin -dir I user_data_sink/chk_enable
create_bd_pin -dir I user_data_sink/chk_reset
create_bd_pin -dir I -from 31 -to 0 user_data_sink/chk_rate_inc
set chk_counters {chk_beats chk_errors chk_gaps chk_gap_beats chk_underflows chk_last_seq}
foreach p $chk_counters {
  create_bd_pin -dir O -from 63 -to 0 user_data_sink/$p
}
create_bd_cell -type module -reference fdrec_check user_data_sink/fdrec_check_0
set_property CONFIG.DATA_WIDTH $nvrec_data_width [get_bd_cells user_data_sink/fdrec_check_0]
foreach p [concat {snk_clk snk_resetn chk_enable chk_reset chk_rate_inc} $chk_counters] {
  connect_bd_net [get_bd_pins user_data_sink/$p] [get_bd_pins user_data_sink/fdrec_check_0/$p]
}
connect_bd_intf_net [get_bd_intf_pins user_data_sink/S_AXIS] [get_bd_intf_pins user_data_sink/fdrec_check_0/s_axis]

# nvrec_core: ingest/egress FIFOs, ring writer/reader, command builder,
# completion router, injector, doorbell monitor, AXI-Lite registers.
# FIFOs by bytes at every width: ingest 256 KB, egress 128 KB (nvrec_params.tcl).
create_bd_cell -type module -reference nvrec_core nvrec_core_0
set_property -dict [list CONFIG.DATA_WIDTH $nvrec_data_width \
  CONFIG.SRC_CLK_HZ $src_clk_hz \
  CONFIG.DP_CLK_HZ $dp_clk_hz \
  CONFIG.FIFO_DEPTH $nvrec_ing_fifo_depth \
  CONFIG.EGR_FIFO_DEPTH $nvrec_egr_fifo_depth \
  CONFIG.SLOT_W $nvrec_slot_w \
  CONFIG.N_RING_PORTS $nvrec_ring_ports \
  CONFIG.RD_SKID_DEPTH $nvrec_rd_skid_depth] [get_bd_cells nvrec_core_0]

connect_bd_intf_net [get_bd_intf_pins user_data_source/M_AXIS] [get_bd_intf_pins nvrec_core_0/s_axis]
foreach p {tpg_enable tpg_seq_rst tpg_rate_inc tpg_seq_next} {
  connect_bd_net [get_bd_pins nvrec_core_0/$p] [get_bd_pins user_data_source/$p]
}
connect_bd_intf_net [get_bd_intf_pins nvrec_core_0/m_axis_snk] [get_bd_intf_pins user_data_sink/S_AXIS]
foreach p [concat {chk_enable chk_reset chk_rate_inc} $chk_counters] {
  connect_bd_net [get_bd_pins nvrec_core_0/$p] [get_bd_pins user_data_sink/$p]
}

# AMD NVMe Host Accelerator (PG328): same configuration as bd_zynqmp.tcl.
# 2 SSDs, ONE hardware queue per SSD and no software queues (the hardware
# SQ/CQ is NVMe QID 1 on every drive; all CPU I/O goes through the nvrec_core
# command injector). Depth 64, full 64-byte commands, QoS off, statistics on.
create_bd_cell -type ip -vlnv xilinx.com:ip:nvmeha:1.0 nvmeha_0
set_property -dict [list CONFIG.C_NUM_SSD {2} \
  CONFIG.C_NUM_SQ {1} \
  CONFIG.C_EN_HW_IF {true} \
  CONFIG.C_EN_SW_IF {false} \
  CONFIG.C_NUM_SQ_SW_0 {0} CONFIG.C_NUM_SQ_HW_0 {1} \
  CONFIG.C_NUM_SQ_SW_1 {0} CONFIG.C_NUM_SQ_HW_1 {1} \
  CONFIG.C_SQ_DEPTH_HW {64} \
  CONFIG.C_HW_FULL_CMD {true} \
  CONFIG.C_HW_QOS_EN {false} \
  CONFIG.STATISTICS_EN {true} \
  CONFIG.CQ_FIFO_DEPTH {64}] [get_bd_cells nvmeha_0]
foreach p {C_NUM_SQ C_EN_SW_IF C_NUM_SQ_SW_0 C_NUM_SQ_HW_0 C_NUM_SQ_SW_1 C_NUM_SQ_HW_1} {
  puts "INFO: nvmeha_0 $p = [get_property CONFIG.$p [get_bd_cells nvmeha_0]]"
}

connect_bd_intf_net [get_bd_intf_pins nvrec_core_0/m_axis_sqe] [get_bd_intf_pins nvmeha_0/S_AXIS]
connect_bd_intf_net [get_bd_intf_pins nvmeha_0/M_AXIS] [get_bd_intf_pins nvrec_core_0/s_axis_cqe]
connect_bd_intf_net [get_bd_intf_pins nvmeha_0/M_AXI_SSD] [get_bd_intf_pins nvrec_core_0/s_axi_db]

# Ring writer / reader -> SmartConnect -> new NoC slave port (PL NMU) -> DDR MC.
# The NMU is nvrec_data_width bits wide at dp_clk: 256 bit x 250 MHz = 8000 MB/s
# per direction (16000 at 512 bits); the NoC QoS request reserves that in both
# directions (record = write, playback = read). The NoC compiler adds the
# packetization overhead (write data x 1.0625, read requests 1/16 of the read
# rate) and refuses more than 16000 MB/s per NMU and per DDR MC port (Ipconfig
# 75-885/886): at 512 bits a symmetric request is capped at 14000 MB/s
# (14000 x 1.125 = 15750). nvrec_dma_qos (MB/s) can be set before the BD script
# runs to change the request (report_noc_qos shows what the NoC solution meets).
if {![info exists nvrec_dma_qos]} {
  # the same request with or without the split ring: a ring port carries the
  # whole stream with a single ring, MEM1 or chunk-sized stripes (the 8000 MB/s
  # of the first split-ring build cost the single ring margin on the bench)
  set nvrec_dma_qos [expr {min($nvrec_data_width * 250 / 8, 14000)}]
}
set noc_si [get_property CONFIG.NUM_SI [get_bd_cells axi_noc_0]]
set noc_clks [get_property CONFIG.NUM_CLKS [get_bd_cells axi_noc_0]]
set noc_port [format "S%02d_AXI" $noc_si]
set noc_aclk "aclk$noc_clks"
set_property -dict [list CONFIG.NUM_SI [expr {$noc_si + 1}] CONFIG.NUM_CLKS [expr {$noc_clks + 1}]] [get_bd_cells axi_noc_0]
# (CONNECTIONS in the exact literal form the NoC IP writes itself: every value in braces)
set_property -dict [list CONFIG.DATA_WIDTH $nvrec_data_width \
  CONFIG.CONNECTIONS [format {MC_2 {read_bw {%d} write_bw {%d} read_avg_burst {64} write_avg_burst {64}}} $nvrec_dma_qos $nvrec_dma_qos]] \
  [get_bd_intf_pins /axi_noc_0/$noc_port]
puts "INFO: nvrec ring writer/reader -> axi_noc_0/$noc_port (clock $noc_aclk, $nvrec_data_width bits, QoS $nvrec_dma_qos MB/s) -> MC_2"
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect axi_smc_dma
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] [get_bd_cells axi_smc_dma]
connect_bd_intf_net [get_bd_intf_pins nvrec_core_0/m_axi] [get_bd_intf_pins axi_smc_dma/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc_dma/M00_AXI] [get_bd_intf_pins axi_noc_0/$noc_port]

# SSD DMA. The NoC QoS request of S08 is raised from the base design's 1720 MB/s
# to 7000 MB/s per direction (a Gen4 x4 link moves up to ~7 GB/s; a bandwidth
# request to the NoC compiler, not a cap; as fpga-drive-recorder).
if {!$nvrec_bridge_split} {
  # Shared NMU (base design): smc_m_axi_bridge (both QDMA M_AXI_BRIDGE -> NoC
  # S08_AXI -> DDR) gets a second master port to the Host Accelerator's queue
  # window (S_AXI_SSD, dp_clk).
  set_property -dict [list CONFIG.NUM_MI {2} CONFIG.NUM_CLKS {4}] [get_bd_cells smc_m_axi_bridge]
  connect_bd_intf_net [get_bd_intf_pins smc_m_axi_bridge/M01_AXI] [get_bd_intf_pins nvmeha_0/S_AXI_SSD]
  connect_bd_net [get_bd_pins versal_cips_0/pl1_ref_clk] [get_bd_pins smc_m_axi_bridge/aclk3]
  set_property -dict [list CONFIG.CONNECTIONS {MC_1 {read_bw {7000} write_bw {7000} read_avg_burst {4} write_avg_burst {4} }}] [get_bd_intf_pins /axi_noc_0/S08_AXI]
} else {
  # One NMU per QDMA bridge: qdma_0 keeps smc_m_axi_bridge -> S08 (MC_1),
  # (with ring_mem lpddr4 each bridge NMU also gets an INI route to the
  # LPDDR4, see the split-ring block below, and both requests are halved)
  # qdma_1 gets smc_m_axi_bridge_1 -> a new NoC slave port (MC_3), each 7000/7000
  # MB/s. Both SmartConnects' second master port reaches the Host Accelerator's
  # queue window through smc_q (2 SI, dp_clk), as smc_ssd_N / smc_q on ZynqMP.
  set_property -dict [list CONFIG.CONNECTIONS {MC_1 {read_bw {7000} write_bw {7000} read_avg_burst {4} write_avg_burst {4} }}] [get_bd_intf_pins /axi_noc_0/S08_AXI]
  set noc_si [get_property CONFIG.NUM_SI [get_bd_cells axi_noc_0]]
  set noc_clks [get_property CONFIG.NUM_CLKS [get_bd_cells axi_noc_0]]
  set noc_port1 [format "S%02d_AXI" $noc_si]
  set noc_aclk1 "aclk$noc_clks"
  set_property -dict [list CONFIG.NUM_SI [expr {$noc_si + 1}] CONFIG.NUM_CLKS [expr {$noc_clks + 1}]] [get_bd_cells axi_noc_0]
  set_property -dict [list CONFIG.DATA_WIDTH {256} \
    CONFIG.CONNECTIONS {MC_3 {read_bw {7000} write_bw {7000} read_avg_burst {4} write_avg_burst {4} }}] \
    [get_bd_intf_pins /axi_noc_0/$noc_port1]
  connect_bd_net [get_bd_pins versal_cips_0/pl0_ref_clk] [get_bd_pins axi_noc_0/$noc_aclk1]
  puts "INFO: nvrec qdma_1/M_AXI_BRIDGE -> smc_m_axi_bridge_1 -> axi_noc_0/$noc_port1 (clock $noc_aclk1 = pl0_ref_clk) -> MC_3"

  create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect smc_q
  set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1}] [get_bd_cells smc_q]
  connect_bd_intf_net [get_bd_intf_pins smc_q/M00_AXI] [get_bd_intf_pins nvmeha_0/S_AXI_SSD]

  # qdma_0: smc_m_axi_bridge (1 SI from the base block above) + M01 -> smc_q
  set_property -dict [list CONFIG.NUM_MI {2} CONFIG.NUM_CLKS {3}] [get_bd_cells smc_m_axi_bridge]
  connect_bd_intf_net [get_bd_intf_pins smc_m_axi_bridge/M01_AXI] [get_bd_intf_pins smc_q/S00_AXI]
  connect_bd_net [get_bd_pins versal_cips_0/pl1_ref_clk] [get_bd_pins smc_m_axi_bridge/aclk2]

  # qdma_1: smc_m_axi_bridge_1
  create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 smc_m_axi_bridge_1
  set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {2} CONFIG.NUM_CLKS {3}] [get_bd_cells smc_m_axi_bridge_1]
  connect_bd_intf_net [get_bd_intf_pins qdma_1/M_AXI_BRIDGE] [get_bd_intf_pins smc_m_axi_bridge_1/S00_AXI]
  connect_bd_intf_net [get_bd_intf_pins smc_m_axi_bridge_1/M00_AXI] [get_bd_intf_pins axi_noc_0/$noc_port1]
  connect_bd_intf_net [get_bd_intf_pins smc_m_axi_bridge_1/M01_AXI] [get_bd_intf_pins smc_q/S01_AXI]
  connect_bd_net [get_bd_pins versal_cips_0/pl0_ref_clk] [get_bd_pins smc_m_axi_bridge_1/aclk]
  connect_bd_net [get_bd_pins qdma_1/axi_aclk] [get_bd_pins smc_m_axi_bridge_1/aclk1]
  connect_bd_net [get_bd_pins versal_cips_0/pl1_ref_clk] [get_bd_pins smc_m_axi_bridge_1/aclk2]
  connect_bd_net [get_bd_pins reset_pl0/peripheral_aresetn] [get_bd_pins smc_m_axi_bridge_1/aresetn]
}

# ----------------------------------------------------------
# Split ring (register map 1.3): memory 1 = on-board LPDDR4
# ----------------------------------------------------------
# ring_mem lpddr4 (config/data.json): a second NoC instance with ONE of the
# VCK190's two LPDDR4 DDRMCs (LPDDR4_Controller0: board interfaces
# ch0_lpddr4_c0 + ch1_lpddr4_c0, system clock lpddr4_sma_clk1), its two x32
# channels interleaved inside the controller (MC_CHANNEL_INTERLEAVING, 256 B),
# mapped at DDR_CH2 (0x600_0000_0000, 4 GB; the PS DDR4 uses DDR_LOW0 +
# DDR_CH1).
# Why one controller and not the BSP's two interleaved ones: the (first
# generation) AXI NoC orders writes strictly (MC_ORDERING has the single choice
# "Strict"). An NMU writing to two interleaved DDRMCs chops every burst into
# interleave-size pieces (128 B) and sends the next piece only after the write
# response of the previous one, so one NoC master wrote the LPDDR4 at only
# 1.8-2.0 GB/s (bench 2026-10-23; reads, which the NMU reorders, ran at
# 12.45 GB/s). Behind one DDRMC every ring/bridge NMU has a single LPDDR4
# destination; the controller spreads the data over both channels itself, so
# the peak stays 2 x 15.6 GB/s (2 x32 channels at 3906 MT/s, the same two
# channels the 1 GB carve-out used before: channel 0 of each controller).
# Not DDR_LOW1
# (0x8_0000_0000): an NMU may not reach DDR_LOW regions of two axi_noc
# instances (BD 41-3567), and the bridges' NMUs reach DDR_LOW0 (DDR4) too; the
# DDR_CHn regions may sit on another instance (the BSP puts its LPDDR4 at
# DDR_CH1). Three routes into it, none from the PS:
#   ring port 1 : nvrec_core_0/m_axi1 -> axi_smc_dma1 -> noc_lpddr4/S00_AXI (its
#                 own PL NMU, DWb @ dp_clk) -> MC_0, QoS nvrec_dma_qos
#   SSD bridges : axi_noc_0 S08 (qdma_0) -> M00_INI -> S00_INI -> MC_1 and the
#                 qdma_1 NMU -> M01_INI -> S01_INI -> MC_2, 4000 MB/s each; the
#                 bridges keep their 7000 MB/s to the DDR4 (as the single-ring
#                 build). A bridge NMU still has two destinations (DDR4, LPDDR4):
#                 strict ordering costs one write round trip at each switch,
#                 i.e. once per split-ring stripe.
# QoS values are requests to the NoC compiler, not caps (report_noc_qos).
set nvrec_noc_lp_ports {}
if {$nvrec_ring_mem eq "lpddr4"} {
  if {!$nvrec_bridge_split} {
    error "nvrec: ring_mem lpddr4 needs one NoC NMU per QDMA bridge (nvrec_bridge_split 1, data_width 512)"
  }
  if {!$is_vck190} {
    error "nvrec: ring_mem lpddr4 is only defined for the VCK190 (target $target)"
  }
  if {![info exists nvrec_bridge_lp_qos]} { set nvrec_bridge_lp_qos 4000 }
  if {![info exists nvrec_bridge_ddr_qos]} { set nvrec_bridge_ddr_qos 7000 }
  if {![info exists nvrec_lp_ch_intlv]} { set nvrec_lp_ch_intlv 256_Bytes }
  create_bd_cell -type ip -vlnv xilinx.com:ip:axi_noc noc_lpddr4
  set_property -dict [list \
    CONFIG.NUM_SI {1} \
    CONFIG.NUM_MI {0} \
    CONFIG.NUM_NSI {2} \
    CONFIG.NUM_CLKS {1} \
    CONFIG.NUM_MC {1} \
    CONFIG.NUM_MCP {4} \
    CONFIG.CONTROLLERTYPE {LPDDR4_SDRAM} \
    CONFIG.MC_CHAN_REGION0 {DDR_CH2} \
    CONFIG.MC_CHAN_REGION1 {NONE} \
    CONFIG.CH0_LPDDR4_0_BOARD_INTERFACE {ch0_lpddr4_c0} \
    CONFIG.CH1_LPDDR4_0_BOARD_INTERFACE {ch1_lpddr4_c0} \
    CONFIG.sys_clk0_BOARD_INTERFACE {lpddr4_sma_clk1} \
  ] [get_bd_cells noc_lpddr4]
  # (after the board interfaces: their presets would reset it)
  set_property -dict [list CONFIG.MC_CHANNEL_INTERLEAVING {true} \
    CONFIG.MC_CH_INTERLEAVING_SIZE $nvrec_lp_ch_intlv] [get_bd_cells noc_lpddr4]
  foreach intf {ch0_lpddr4_c0 ch1_lpddr4_c0} pin {CH0_LPDDR4_0 CH1_LPDDR4_0} {
    create_bd_intf_port -mode Master -vlnv xilinx.com:interface:lpddr4_rtl:1.0 $intf
    connect_bd_intf_net [get_bd_intf_ports $intf] [get_bd_intf_pins noc_lpddr4/$pin]
  }
  foreach clk {lpddr4_sma_clk1} pin {sys_clk0} {
    create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 $clk
    set_property CONFIG.FREQ_HZ 200000000 [get_bd_intf_ports $clk]
    connect_bd_intf_net [get_bd_intf_ports $clk] [get_bd_intf_pins noc_lpddr4/$pin]
  }

  # ring port 1 -> its own NMU on noc_lpddr4
  set_property -dict [list CONFIG.DATA_WIDTH $nvrec_data_width \
    CONFIG.CONNECTIONS [format {MC_0 {read_bw {%d} write_bw {%d} read_avg_burst {64} write_avg_burst {64}}} $nvrec_dma_qos $nvrec_dma_qos]] \
    [get_bd_intf_pins /noc_lpddr4/S00_AXI]
  create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect axi_smc_dma1
  set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] [get_bd_cells axi_smc_dma1]
  connect_bd_intf_net [get_bd_intf_pins nvrec_core_0/m_axi1] [get_bd_intf_pins axi_smc_dma1/S00_AXI]
  connect_bd_intf_net [get_bd_intf_pins axi_smc_dma1/M00_AXI] [get_bd_intf_pins noc_lpddr4/S00_AXI]
  connect_bd_net [get_bd_pins versal_cips_0/pl1_ref_clk] \
    [get_bd_pins noc_lpddr4/aclk0] \
    [get_bd_pins axi_smc_dma1/aclk]
  connect_bd_net [get_bd_pins rst_dp_clk/interconnect_aresetn] [get_bd_pins axi_smc_dma1/aresetn]
  puts "INFO: nvrec ring port 1 nvrec_core_0/m_axi1 -> axi_smc_dma1 -> noc_lpddr4/S00_AXI ($nvrec_data_width bits, QoS $nvrec_dma_qos MB/s) -> MC_0 (LPDDR4)"

  # SSD bridges -> INI -> LPDDR4
  set_property CONFIG.NUM_NMI {2} [get_bd_cells axi_noc_0]
  foreach ini {M00_INI M01_INI} {
    set_property CONFIG.INI_STRATEGY {auto} [get_bd_intf_pins /axi_noc_0/$ini]
  }
  foreach ini {S00_INI S01_INI} mc {MC_1 MC_2} {
    set_property -dict [list CONFIG.INI_STRATEGY {auto} \
      CONFIG.CONNECTIONS [format {%s {read_bw {%d} write_bw {%d} read_avg_burst {4} write_avg_burst {4}}} $mc $nvrec_bridge_lp_qos $nvrec_bridge_lp_qos]] \
      [get_bd_intf_pins /noc_lpddr4/$ini]
  }
  connect_bd_intf_net [get_bd_intf_pins axi_noc_0/M00_INI] [get_bd_intf_pins noc_lpddr4/S00_INI]
  connect_bd_intf_net [get_bd_intf_pins axi_noc_0/M01_INI] [get_bd_intf_pins noc_lpddr4/S01_INI]
  set_property -dict [list CONFIG.CONNECTIONS [format {MC_1 {read_bw {%d} write_bw {%d} read_avg_burst {4} write_avg_burst {4}} M00_INI {read_bw {%d} write_bw {%d}}} \
    $nvrec_bridge_ddr_qos $nvrec_bridge_ddr_qos $nvrec_bridge_lp_qos $nvrec_bridge_lp_qos]] [get_bd_intf_pins /axi_noc_0/S08_AXI]
  set_property -dict [list CONFIG.CONNECTIONS [format {MC_3 {read_bw {%d} write_bw {%d} read_avg_burst {4} write_avg_burst {4}} M01_INI {read_bw {%d} write_bw {%d}}} \
    $nvrec_bridge_ddr_qos $nvrec_bridge_ddr_qos $nvrec_bridge_lp_qos $nvrec_bridge_lp_qos]] [get_bd_intf_pins /axi_noc_0/$noc_port1]
  puts "INFO: nvrec qdma_0 bridge axi_noc_0/S08_AXI -> MC_1 ($nvrec_bridge_ddr_qos MB/s) + M00_INI -> noc_lpddr4 MC_1, qdma_1 bridge axi_noc_0/$noc_port1 -> MC_3 ($nvrec_bridge_ddr_qos MB/s) + M01_INI -> noc_lpddr4 MC_2 ($nvrec_bridge_lp_qos MB/s each)"
  set nvrec_noc_lp_ports {S00_AXI S00_INI S01_INI}

  # memory 1 needs no calibration status from the PL (the PLM calibrates the
  # DDRMCs before the PL runs; a failed calibration stops the boot)
  connect_bd_net [get_bd_pins const_high/dout] [get_bd_pins nvrec_core_0/mem1_ready]
}

# Doorbells: nvmeha M_AXI_SSD -> nvrec_core_0 (dbmon) -> smc_m_axi_fpd (second
# slave port) -> qdma_N/S_AXI_BRIDGE BAR0 window. The same SmartConnect gets
# two more master ports: nvrec_core registers and the nvmeha AXI-Lite slave.
set n_si   [get_property CONFIG.NUM_SI [get_bd_cells smc_m_axi_fpd]]
set n_mi   [get_property CONFIG.NUM_MI [get_bd_cells smc_m_axi_fpd]]
set n_clks [get_property CONFIG.NUM_CLKS [get_bd_cells smc_m_axi_fpd]]
set si_db   [format "S%02d_AXI" $n_si]
set mi_regs [format "M%02d_AXI" $n_mi]
set mi_lite [format "M%02d_AXI" [expr {$n_mi + 1}]]
set smc_dp_aclk   "aclk$n_clks"
set smc_lite_aclk "aclk[expr {$n_clks + 1}]"
set_property -dict [list CONFIG.NUM_SI [expr {$n_si + 1}] \
  CONFIG.NUM_MI [expr {$n_mi + 2}] \
  CONFIG.NUM_CLKS [expr {$n_clks + 2}]] [get_bd_cells smc_m_axi_fpd]
connect_bd_intf_net [get_bd_intf_pins nvrec_core_0/m_axi_db] [get_bd_intf_pins smc_m_axi_fpd/$si_db]
connect_bd_intf_net [get_bd_intf_pins smc_m_axi_fpd/$mi_regs] [get_bd_intf_pins nvrec_core_0/s_axi]

# nvmeha S_AXI_LITE behind the AXI-Lite timeout guard (as bd_zynqmp.tcl): when
# the evaluation-licensed core stops (~3 h after the device image is loaded)
# its register slave never answers again and a CPU read would hang the whole
# system. The guard completes such an access itself (OKAY, data all ones),
# latches `dead` -> nvrec_core STATE.HA_DEAD / IRQ_STATUS.HA_DEAD, and answers
# every later access at once. Same clock as nvmeha clk_axi_lite (pl3, 100 MHz).
create_bd_cell -type module -reference nvrec_axil_guard nvmeha_guard
connect_bd_intf_net [get_bd_intf_pins smc_m_axi_fpd/$mi_lite] [get_bd_intf_pins nvmeha_guard/s_axi]
connect_bd_intf_net [get_bd_intf_pins nvmeha_guard/m_axi] [get_bd_intf_pins nvmeha_0/S_AXI_LITE]
connect_bd_net [get_bd_pins nvmeha_guard/dead] [get_bd_pins nvrec_core_0/ha_dead]

# dp_clk domain clocks and resets
connect_bd_net [get_bd_pins versal_cips_0/pl1_ref_clk] \
  [get_bd_pins axi_noc_0/$noc_aclk] \
  [get_bd_pins axi_smc_dma/aclk] \
  [get_bd_pins smc_m_axi_fpd/$smc_dp_aclk] \
  [get_bd_pins nvrec_core_0/dp_clk] \
  [get_bd_pins nvmeha_0/clk_core]
connect_bd_net [get_bd_pins rst_dp_clk/peripheral_aresetn] \
  [get_bd_pins nvrec_core_0/dp_resetn] \
  [get_bd_pins nvmeha_0/rst_n_core]
connect_bd_net [get_bd_pins rst_dp_clk/interconnect_aresetn] [get_bd_pins axi_smc_dma/aresetn]
if {$nvrec_bridge_split} {
  connect_bd_net [get_bd_pins versal_cips_0/pl1_ref_clk] [get_bd_pins smc_q/aclk]
  connect_bd_net [get_bd_pins rst_dp_clk/interconnect_aresetn] [get_bd_pins smc_q/aresetn]
}

# nvmeha AXI-Lite clock (<= 100 MHz, PG328): pl3_ref_clk
connect_bd_net [get_bd_pins versal_cips_0/pl3_ref_clk] \
  [get_bd_pins nvmeha_0/clk_axi_lite] \
  [get_bd_pins nvmeha_guard/aclk] \
  [get_bd_pins smc_m_axi_fpd/$smc_lite_aclk]
connect_bd_net [get_bd_pins rst_lite_clk/peripheral_aresetn] \
  [get_bd_pins nvmeha_0/rst_n_axi_lite] \
  [get_bd_pins nvmeha_guard/aresetn]

# src_clk domain
connect_bd_net [get_bd_pins versal_cips_0/pl2_ref_clk] \
  [get_bd_pins user_data_source/src_clk] \
  [get_bd_pins user_data_sink/snk_clk] \
  [get_bd_pins nvrec_core_0/src_clk]
connect_bd_net [get_bd_pins rst_src_clk/peripheral_aresetn] \
  [get_bd_pins user_data_source/src_resetn] \
  [get_bd_pins user_data_sink/snk_resetn] \
  [get_bd_pins nvrec_core_0/src_resetn]

# Interrupts: appended after the 6 QDMA interrupts, in the same order as on
# Zynq UltraScale+: pl_ps_irq6 = nvrec_core_0/irq (GIC SPI 90),
# pl_ps_irq7 = nvmeha_0/ha_interrupt (GIC SPI 91). pl_ps_irqN = GIC SPI 84 + N.
lappend intr_list "nvrec_core_0/irq"
lappend intr_list "nvmeha_0/ha_interrupt"
set irq_usage {}
for {set i 0} {$i < 16} {incr i} {
  lappend irq_usage [list "CH$i" [expr {$i < [llength $intr_list] ? 1 : 0}]]
}
set_property CONFIG.PS_PMC_CONFIG [list PS_IRQ_USAGE $irq_usage] [get_bd_cells versal_cips_0]
set pmc_cfg [get_property CONFIG.PS_PMC_CONFIG [get_bd_cells versal_cips_0]]
puts "INFO: CIPS PS_IRQ_USAGE = [dict get $pmc_cfg PS_IRQ_USAGE]; UART0 = [dict get $pmc_cfg PS_UART0_PERIPHERAL]"

# ----------------------------------------------------------
# Address map
# ----------------------------------------------------------
# The register windows first (the automatic assignment cannot place module
# reference segments inside the M_AXI_FPD apertures), then everything else
nvrec_map versal_cips_0/M_AXI_FPD nvrec_core_0/s_axi/reg0 0x0420010000 4K
nvrec_map versal_cips_0/M_AXI_FPD nvmeha_guard/s_axi/reg0 0x0420020000 64K
assign_bd_address

# PS view: QDMA BAR windows (base design), nvrec / nvmeha register windows
# (same addresses as the Zynq UltraScale+ design)
set_property offset 0x480000000 [get_bd_addr_segs {versal_cips_0/M_AXI_FPD/SEG_qdma_0_BAR1}]
set_property range 1G [get_bd_addr_segs {versal_cips_0/M_AXI_FPD/SEG_qdma_0_BAR1}]
set_property offset 0x4c0000000 [get_bd_addr_segs {versal_cips_0/M_AXI_FPD/SEG_qdma_1_BAR1}]
set_property range 1G [get_bd_addr_segs {versal_cips_0/M_AXI_FPD/SEG_qdma_1_BAR1}]
set_property offset 0xA8000000 [get_bd_addr_segs {versal_cips_0/M_AXI_FPD/SEG_qdma_0_BAR0}]
set_property range 64M [get_bd_addr_segs {versal_cips_0/M_AXI_FPD/SEG_qdma_0_BAR0}]
set_property offset 0xAc000000 [get_bd_addr_segs {versal_cips_0/M_AXI_FPD/SEG_qdma_1_BAR0}]
set_property range 64M [get_bd_addr_segs {versal_cips_0/M_AXI_FPD/SEG_qdma_1_BAR0}]
nvrec_map versal_cips_0/M_AXI_FPD nvrec_core_0/s_axi/reg0 0x0420010000 4K
nvrec_map versal_cips_0/M_AXI_FPD nvmeha_guard/s_axi/reg0 0x0420020000 64K
# the guard forwards the low 32 address bits it receives (0x2002_xxxx)
nvrec_map nvmeha_guard/m_axi nvmeha_0/S_AXI_LITE/Reg 0x20020000 64K
foreach seg [get_bd_addr_segs -quiet -excluded -of_objects [get_bd_addr_spaces nvmeha_guard/m_axi]] {
  include_bd_addr_seg $seg
}

# Host Accelerator doorbells: whole 32-bit space into the doorbell monitor,
# which forwards to the two BAR0 windows at the SAME addresses as the PS sees
# them (the QDMA bridges translate nothing: AXI address = PCIe address)
nvrec_map nvmeha_0/Data nvrec_core_0/s_axi_db/reg0 0x00000000 4G
foreach seg [get_bd_addr_segs -quiet -excluded -of_objects [get_bd_addr_spaces nvmeha_0/Data]] {
  include_bd_addr_seg $seg
}
# The doorbell monitor's master (m_axi_db) shares smc_m_axi_fpd with the PS:
# keep only the two BAR0 windows in its address space (BAR1 windows and the
# register blocks are excluded), then place them where the PS sees them.
set bar0_segs [list [get_bd_addr_segs qdma_0/S_AXI_BRIDGE/BAR0] [get_bd_addr_segs qdma_1/S_AXI_BRIDGE/BAR0]]
foreach seg [get_bd_addr_segs -quiet -of_objects [get_bd_addr_spaces nvrec_core_0/m_axi_db]] {
  set slv [get_bd_addr_segs -of_objects $seg]
  if {[lsearch -exact $bar0_segs $slv] < 0} {
    exclude_bd_addr_seg -target_address_space [get_bd_addr_spaces nvrec_core_0/m_axi_db] $slv
  }
}
nvrec_map nvrec_core_0/m_axi_db qdma_1/S_AXI_BRIDGE/BAR0 0xAC000000 64M
nvrec_map nvrec_core_0/m_axi_db qdma_0/S_AXI_BRIDGE/BAR0 0xA8000000 64M
# SSD view (QDMA M_AXI_BRIDGE, no inbound translation): queue window
nvrec_map qdma_0/M_AXI_BRIDGE nvmeha_0/S_AXI_SSD/Reg 0x90000000 64K
nvrec_map qdma_1/M_AXI_BRIDGE nvmeha_0/S_AXI_SSD/Reg 0x90000000 64K
# Split ring memory 1 (LPDDR4, DDR_CH2): ring port 1 and both bridges see it at
# 0x600_0000_0000 (4 GB), the same address (fabric view = SSD view); the PS has
# no route to it. Every LPDDR4 segment is checked to sit at 0x600_0000_0000.
if {$nvrec_ring_mem eq "lpddr4"} {
  foreach sp {nvrec_core_0/m_axi1 qdma_0/M_AXI_BRIDGE qdma_1/M_AXI_BRIDGE} {
    set n_lp 0
    foreach seg [get_bd_addr_segs -quiet -of_objects [get_bd_addr_spaces $sp]] {
      set slv [get_bd_addr_segs -of_objects $seg]
      if {[string match "/noc_lpddr4/*" $slv] || [string match "noc_lpddr4/*" $slv]} {
        if {[string is true -strict [get_property EXCLUDED $seg]]} { include_bd_addr_seg $seg }
        if {[expr {[get_property OFFSET $seg]}] != 0x60000000000} {
          error "nvrec: LPDDR4 segment [get_property NAME $seg] of $sp at [get_property OFFSET $seg], expected 0x600_0000_0000"
        }
        incr n_lp
      }
    }
    if {$n_lp == 0} { error "nvrec: $sp has no LPDDR4 segment (no NoC route to noc_lpddr4)" }
  }
  foreach seg [get_bd_addr_segs -quiet -of_objects [get_bd_addr_spaces versal_cips_0/*]] {
    if {[string match "*noc_lpddr4*" [get_property NAME $seg]]} {
      error "nvrec: the PS address space maps the LPDDR4 ([get_property NAME $seg]): it must not"
    }
  }
}

foreach sp {versal_cips_0/M_AXI_FPD nvmeha_guard/m_axi nvmeha_0/Data nvrec_core_0/m_axi_db nvrec_core_0/m_axi nvrec_core_0/m_axi1 qdma_0/M_AXI_BRIDGE qdma_1/M_AXI_BRIDGE} {
  if {[llength [get_bd_addr_spaces -quiet $sp]] == 0} { continue }
  foreach seg [get_bd_addr_segs -quiet -of_objects [get_bd_addr_spaces $sp]] {
    puts "INFO: addr $sp [get_property NAME $seg] offset [get_property OFFSET $seg] range [get_property RANGE $seg] excluded [get_property EXCLUDED $seg]"
  }
}

# Create PERST ports
create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconstant:1.0 const_low
set_property -dict [list CONFIG.CONST_VAL {0}] [get_bd_cells const_low]
create_bd_port -dir O -from 0 -to 0 -type rst perst_0
connect_bd_net [get_bd_pins /const_low/dout] [get_bd_ports perst_0]
create_bd_port -dir O -from 0 -to 0 -type rst perst_1
connect_bd_net [get_bd_pins /const_low/dout] [get_bd_ports perst_1]

# Constant to enable the 3.3V power supply of SSD2 and its clock source (LOW = enabled)
set const_dis_ssd2_pwr [ create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconstant:1.0 const_dis_ssd2_pwr ]
create_bd_port -dir O disable_ssd2_pwr
connect_bd_net [get_bd_pins const_dis_ssd2_pwr/dout] [get_bd_ports disable_ssd2_pwr]
set_property -dict [list CONFIG.CONST_VAL {0}] $const_dis_ssd2_pwr

# Connect the interrupts
set intr_index 0
foreach intr $intr_list {
  connect_bd_net [get_bd_pins $intr] [get_bd_pins versal_cips_0/pl_ps_irq$intr_index]
  puts "INFO: $intr -> versal_cips_0/pl_ps_irq$intr_index (GIC SPI [expr {84 + $intr_index}])"
  set intr_index [expr {$intr_index+1}]
}

validate_bd_design

# The nvrec NoC ports after parameter propagation: widths, clocks and QoS
set nvrec_noc_ports [list S08_AXI $noc_port]
if {$nvrec_bridge_split} { lappend nvrec_noc_ports $noc_port1 }
foreach p $nvrec_noc_ports {
  set ipin [get_bd_intf_pins axi_noc_0/$p]
  puts "INFO: nvrec axi_noc_0/$p DATA_WIDTH [get_property CONFIG.DATA_WIDTH $ipin] FREQ_HZ [get_property CONFIG.FREQ_HZ $ipin] CONNECTIONS [get_property CONFIG.CONNECTIONS $ipin]"
}
foreach p $nvrec_noc_lp_ports {
  set ipin [get_bd_intf_pins noc_lpddr4/$p]
  puts "INFO: nvrec noc_lpddr4/$p DATA_WIDTH [get_property CONFIG.DATA_WIDTH $ipin] FREQ_HZ [get_property CONFIG.FREQ_HZ $ipin] CONNECTIONS [get_property CONFIG.CONNECTIONS $ipin]"
}
if {$nvrec_ring_mem eq "lpddr4"} {
  foreach k {CONTROLLERTYPE NUM_MC NUM_MCP MC_CHAN_REGION0 MC_INTERLEAVE_SIZE MC_CHANNEL_INTERLEAVING MC_CH_INTERLEAVING_SIZE MC_ADDR_BIT32 MC_ORDERING MC_ECC MC_MEMORY_SPEEDGRADE MC_MEMORY_TIMEPERIOD0 MC_INPUTCLK0_PERIOD MC_NO_CHANNELS MC_MEMORY_DENSITY} {
    puts "INFO: nvrec noc_lpddr4 $k = [get_property -quiet CONFIG.$k [get_bd_cells noc_lpddr4]]"
  }
}
foreach ip [concat {nvrec_core_0/m_axi axi_smc_dma/M00_AXI} [expr {$nvrec_ring_mem eq "lpddr4" ? {nvrec_core_0/m_axi1 axi_smc_dma1/M00_AXI} : {}}]] {
  set ipin [get_bd_intf_pins $ip]
  puts "INFO: nvrec $ip DATA_WIDTH [get_property CONFIG.DATA_WIDTH $ipin] FREQ_HZ [get_property CONFIG.FREQ_HZ $ipin]"
}
save_bd_design
