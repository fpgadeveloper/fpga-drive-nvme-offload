################################################################
# Block design build script for Zynq US+ designs
#
# FPGA Drive NVMe offload recorder (nvrec). The PS, PCIe root ports, clocks,
# resets and GT locations are those of fpga-drive-recorder /
# fpga-drive-aximm-pcie; the root ports' AXI connectivity is rebuilt below so
# that the AMD NVMe Host Accelerator (nvmeha) can reach the SSD BARs
# (doorbells) and the SSDs can reach the Host Accelerator's queue memory.
################################################################

# Returns true if str contains substr
proc str_contains {str substr} {
  if {[string first $substr $str] == -1} {
    return 0
  } else {
    return 1
  }
}

# nvrec datapath parameters of this target (nvrec_data_width, FIFO depths, ...)
source [file join [file dirname [file normalize [info script]]] nvrec_params.tcl]

# GT and PCIe LOCs
set select_quad_0 [dict get $gt_loc_dict $target 0 quad]
set pcie_blk_locn_0 [dict get $gt_loc_dict $target 0 pcie]

if {$dual_design} {
  set select_quad_1 [dict get $gt_loc_dict $target 1 quad]
  set pcie_blk_locn_1 [dict get $gt_loc_dict $target 1 pcie]
}

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

# Add the Processor System and apply board preset
create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e zynq_ultra_ps_e_0
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset "1" }  [get_bd_cells zynq_ultra_ps_e_0]

# Configure the PS: Enable HP0 and HP1 (for dual designs) to DDR
if {$dual_design} {
  set_property -dict [list CONFIG.PSU__USE__S_AXI_GP2 {1} \
  CONFIG.PSU__USE__S_AXI_GP3 {1} \
  CONFIG.PSU__USE__M_AXI_GP0 {1} \
  CONFIG.PSU__USE__M_AXI_GP1 {1} \
  CONFIG.PSU__USE__IRQ0 {1} \
  CONFIG.PSU__HIGH_ADDRESS__ENABLE {1}] [get_bd_cells zynq_ultra_ps_e_0]
} else {
  set_property -dict [list CONFIG.PSU__USE__S_AXI_GP2 {1} \
  CONFIG.PSU__USE__S_AXI_GP3 {0} \
  CONFIG.PSU__USE__M_AXI_GP0 {1} \
  CONFIG.PSU__USE__M_AXI_GP1 {0} \
  CONFIG.PSU__USE__IRQ0 {1} \
  CONFIG.PSU__HIGH_ADDRESS__ENABLE {1}] [get_bd_cells zynq_ultra_ps_e_0]
}

# NVMe offload recorder: PS clocks and HP port for the recording datapath
#   pl_clk1 = 250 MHz : dp_clk  (nvrec_core, nvmeha clk_core (PG328: <= 250 MHz),
#                       HP0/HP1 = the SSDs' DMA path to DDR, SmartConnects)
#   pl_clk2 = 250 MHz : src_clk (test pattern generator / user data source and sink,
#                       ingest write side, egress read side): nvrec_data_width bits x
#                       250 MHz = 8.0 GB/s at 256 bits
#   pl_clk3 = 333 MHz : S_AXI_HP2_FPD only (saxihp2_fpd_aclk; DS925 max for the PS-PL AXI
#   requested           interfaces): 128 bits x 333 MHz = 5.33 GB/s peak
#   S_AXI_HP2_FPD (128-bit) : nvrec_core ring writer / reader -> PS DDR (non-coherent),
#                       through axi_smc_dma (nvrec_data_width @ dp_clk -> 128-bit @ pl_clk3)
# PLL sources: pl_clk0/1/2 come from the IOPLL (1500 MHz / 15, / 6, / 6), pl_clk3 from the RPLL.
# The PS clock wizard never exceeds a requested frequency, so it retunes the RPLL to the
# highest pl_clk3 <= 333 MHz that it can make: 322.19 MHz on the ZCU106 (PSS_REF_CLK
# 33.330 MHz), 327.77 MHz on the UltraZed-EV (33.333 MHz). With all four on one PLL it would
# pull dp_clk and src_clk down to 245.8 MHz, hence the explicit SRCSEL (as fpga-drive-recorder).
# The HP2 request is a variable so that it can be lowered (300, 250) if timing does not close.
if {![info exists nvrec_hp2_mhz]} { set nvrec_hp2_mhz 333 }
set_property -dict [list CONFIG.PSU__FPGA_PL1_ENABLE {1} \
  CONFIG.PSU__CRL_APB__PL1_REF_CTRL__SRCSEL {IOPLL} \
  CONFIG.PSU__CRL_APB__PL1_REF_CTRL__FREQMHZ {250} \
  CONFIG.PSU__FPGA_PL2_ENABLE {1} \
  CONFIG.PSU__CRL_APB__PL2_REF_CTRL__SRCSEL {IOPLL} \
  CONFIG.PSU__CRL_APB__PL2_REF_CTRL__FREQMHZ {250} \
  CONFIG.PSU__FPGA_PL3_ENABLE {1} \
  CONFIG.PSU__CRL_APB__PL3_REF_CTRL__SRCSEL {RPLL} \
  CONFIG.PSU__CRL_APB__PL3_REF_CTRL__FREQMHZ $nvrec_hp2_mhz \
  CONFIG.PSU__USE__S_AXI_GP4 {1} \
  CONFIG.PSU__SAXIGP4__DATA_WIDTH {128}] [get_bd_cells zynq_ultra_ps_e_0]

# Connect the PS clocks
# (nvrec: S_AXI_HP0/HP1_FPD, the SSDs' DMA path to DDR, run on dp_clk = pl_clk1,
# 250 MHz x 128 bit, instead of pl_clk0; they are connected further below)
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins zynq_ultra_ps_e_0/maxihpm0_fpd_aclk]
if {$dual_design} {
  connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins zynq_ultra_ps_e_0/maxihpm1_fpd_aclk]
}

# Add the DMA/Bridge Subsystem for PCIe IPs
create_bd_cell -type ip -vlnv xilinx.com:ip:xdma xdma_0
if {$dual_design} {
  create_bd_cell -type ip -vlnv xilinx.com:ip:xdma xdma_1
}

# ZCU106 HPC0 has enough MGTs for all 4-lanes for SSD1 and SSD2
# ZCU106 HPC1 has only 1x MGT for SSD1 (cannot support SSD2)
# ZCU104 LPC has only 1x MGT for SSD1
if {[lindex $num_lanes 0] == "X4"} {
  # 4-lane PCIe config
  set max_link_width X4
  set axi_data_width 128_bit
  set axisten_freq 250
  set pf_device_id 9134
} else {
  # 1-lane PCIe config
  set max_link_width X1
  set axi_data_width 64_bit
  set axisten_freq 125
  set pf_device_id 9131
}

# We need to get the correct name format of the PCIe selection
set pcie_blk [get_property CONFIG.pcie_blk_locn [get_bd_cells xdma_0]]
# Find the position of the last underscore
set last_underscore_index [string last "_" $pcie_blk]
# Check if the string contains an underscore
if {$last_underscore_index >= 0} {
    set pcie_blk_locn_0 "[string range $pcie_blk 0 [expr {$last_underscore_index - 1}]]_$pcie_blk_locn_0"
    if {$dual_design} {
      set pcie_blk_locn_1 "[string range $pcie_blk 0 [expr {$last_underscore_index - 1}]]_$pcie_blk_locn_1"
    }
}
# ##########################################################
# Configure DMA/Bridge Subsystem for PCIe IP
# ##########################################################
# Notes:
# (1) The high speed PCIe traces on the FPGA Drive FMC are very
#    short, so there is very low signal loss between the FPGA
#    and the SSD. For this reason, it is best to use the
#    "Chip-to-Chip" loss profile in the "GT Settings" (the
#    default is "Add-on card"). Also, the "Chip-to-Chip"
#    profile is the only one that disables the DFE, a feature
#    that is better suited for longer and more lossy traces.
# (2) Answer record 70854 was important in getting the settings
#    right in this design:
#    https://www.xilinx.com/support/answers/70854.html
# (3) On Zynq Ultrascale+ designs, we have found that at least
#    one BAR had to be assigned in the lower 32-bit address space,
#    or the SSD would not be properly enumerated.
# (4) To further the above point, we have also found that if BAR0
#    is placed at address 0x10_0000_0000 (the default value),
#    the NVMe driver crashes on boot. This occurs even when we
#    enable "High Address" in ZynqMP settings "PS-PL Configuration"->
#    "Address Fragmentation": CONFIG.PSU__HIGH_ADDRESS__ENABLE {1}
#    and even when the SSD's BARs are assigned to the lower 32-bit
#    address space via another BAR (eg. BAR1 @ 0xA0000000).
#    It seems that BAR0 must be assigned in the lower 32-bit
#    address space for this to work, which is in line with the
#    answer record mentioned above (although the images in that
#    document do not align with what is written).
#    
set_property -dict [list CONFIG.functional_mode {AXI_Bridge} \
CONFIG.mode_selection {Advanced} \
CONFIG.device_port_type {Root_Port_of_PCI_Express_Root_Complex} \
CONFIG.pl_link_cap_max_link_width $max_link_width \
CONFIG.pl_link_cap_max_link_speed {8.0_GT/s} \
CONFIG.axi_addr_width {49} \
CONFIG.axi_data_width $axi_data_width \
CONFIG.axisten_freq $axisten_freq \
CONFIG.dedicate_perst {false} \
CONFIG.sys_reset_polarity {ACTIVE_LOW} \
CONFIG.pf0_device_id $pf_device_id \
CONFIG.pf0_base_class_menu {Bridge_device} \
CONFIG.pf0_class_code_base {06} \
CONFIG.pf0_sub_class_interface_menu {PCI_to_PCI_bridge} \
CONFIG.pf0_class_code_sub {04} \
CONFIG.pf0_class_code_interface {00} \
CONFIG.pf0_class_code {060400} \
CONFIG.xdma_axilite_slave {true} \
CONFIG.pcie_blk_locn $pcie_blk_locn_0 \
CONFIG.en_gt_selection {true} \
CONFIG.select_quad $select_quad_0 \
CONFIG.INS_LOSS_NYQ {5} \
CONFIG.plltype {QPLL1} \
CONFIG.ins_loss_profile {Chip-to-Chip} \
CONFIG.type1_membase_memlimit_enable {Enabled} \
CONFIG.type1_prefetchable_membase_memlimit {64bit_Enabled} \
CONFIG.axibar_num {1} \
CONFIG.axibar2pciebar_0 {0x00000000A0000000} \
CONFIG.BASEADDR {0x00000000} \
CONFIG.HIGHADDR {0x001FFFFF} \
CONFIG.pf0_bar0_enabled {false} \
CONFIG.pf1_class_code {060700} \
CONFIG.pf1_base_class_menu {Bridge_device} \
CONFIG.pf1_class_code_base {06} \
CONFIG.pf1_class_code_sub {07} \
CONFIG.pf1_sub_class_interface_menu {CardBus_bridge} \
CONFIG.pf1_class_code_interface {00} \
CONFIG.pf1_bar2_enabled {false} \
CONFIG.pf1_bar2_64bit {false} \
CONFIG.pf1_bar4_enabled {false} \
CONFIG.pf1_bar4_64bit {false} \
CONFIG.dma_reset_source_sel {Phy_Ready} \
CONFIG.pf0_bar0_type_mqdma {Memory} \
CONFIG.pf1_bar0_type_mqdma {Memory} \
CONFIG.pf2_bar0_type_mqdma {Memory} \
CONFIG.pf3_bar0_type_mqdma {Memory} \
CONFIG.pf0_sriov_bar0_type {Memory} \
CONFIG.pf1_sriov_bar0_type {Memory} \
CONFIG.pf2_sriov_bar0_type {Memory} \
CONFIG.pf3_sriov_bar0_type {Memory} \
CONFIG.PF0_DEVICE_ID_mqdma $pf_device_id \
CONFIG.PF2_DEVICE_ID_mqdma $pf_device_id \
CONFIG.PF3_DEVICE_ID_mqdma $pf_device_id \
CONFIG.pf0_base_class_menu_mqdma {Bridge_device} \
CONFIG.pf0_class_code_base_mqdma {06} \
CONFIG.pf0_class_code_mqdma {068000} \
CONFIG.pf1_base_class_menu_mqdma {Bridge_device} \
CONFIG.pf1_class_code_base_mqdma {06} \
CONFIG.pf1_class_code_mqdma {068000} \
CONFIG.pf2_base_class_menu_mqdma {Bridge_device} \
CONFIG.pf2_class_code_base_mqdma {06} \
CONFIG.pf2_class_code_mqdma {068000} \
CONFIG.pf3_base_class_menu_mqdma {Bridge_device} \
CONFIG.pf3_class_code_base_mqdma {06} \
CONFIG.pf3_class_code_mqdma {068000}] [get_bd_cells xdma_0]

if {$dual_design} {
  # Create xdma_1 and place it at PCIe block X0Y0
  set_property -dict [list CONFIG.functional_mode {AXI_Bridge} \
  CONFIG.mode_selection {Advanced} \
  CONFIG.device_port_type {Root_Port_of_PCI_Express_Root_Complex} \
  CONFIG.pl_link_cap_max_link_width $max_link_width \
  CONFIG.pl_link_cap_max_link_speed {8.0_GT/s} \
  CONFIG.axi_addr_width {49} \
  CONFIG.axi_data_width $axi_data_width \
  CONFIG.axisten_freq $axisten_freq \
  CONFIG.dedicate_perst {false} \
  CONFIG.sys_reset_polarity {ACTIVE_LOW} \
  CONFIG.pf0_device_id $pf_device_id \
  CONFIG.pf0_base_class_menu {Bridge_device} \
  CONFIG.pf0_class_code_base {06} \
  CONFIG.pf0_sub_class_interface_menu {PCI_to_PCI_bridge} \
  CONFIG.pf0_class_code_sub {04} \
  CONFIG.pf0_class_code_interface {00} \
  CONFIG.pf0_class_code {060400} \
  CONFIG.xdma_axilite_slave {true} \
  CONFIG.pcie_blk_locn $pcie_blk_locn_1 \
  CONFIG.en_gt_selection {true} \
  CONFIG.select_quad $select_quad_1 \
  CONFIG.INS_LOSS_NYQ {5} \
  CONFIG.plltype {QPLL1} \
  CONFIG.ins_loss_profile {Chip-to-Chip} \
  CONFIG.type1_membase_memlimit_enable {Enabled} \
  CONFIG.type1_prefetchable_membase_memlimit {64bit_Enabled} \
  CONFIG.axibar_num {1} \
  CONFIG.axibar2pciebar_0 {0x00000000B0000000} \
  CONFIG.BASEADDR {0x00000000} \
  CONFIG.HIGHADDR {0x001FFFFF} \
  CONFIG.pf0_bar0_enabled {false} \
  CONFIG.pf1_class_code {060700} \
  CONFIG.pf1_base_class_menu {Bridge_device} \
  CONFIG.pf1_class_code_base {06} \
  CONFIG.pf1_class_code_sub {07} \
  CONFIG.pf1_sub_class_interface_menu {CardBus_bridge} \
  CONFIG.pf1_class_code_interface {00} \
  CONFIG.pf1_bar2_enabled {false} \
  CONFIG.pf1_bar2_64bit {false} \
  CONFIG.pf1_bar4_enabled {false} \
  CONFIG.pf1_bar4_64bit {false} \
  CONFIG.dma_reset_source_sel {Phy_Ready} \
  CONFIG.pf0_bar0_type_mqdma {Memory} \
  CONFIG.pf1_bar0_type_mqdma {Memory} \
  CONFIG.pf2_bar0_type_mqdma {Memory} \
  CONFIG.pf3_bar0_type_mqdma {Memory} \
  CONFIG.pf0_sriov_bar0_type {Memory} \
  CONFIG.pf1_sriov_bar0_type {Memory} \
  CONFIG.pf2_sriov_bar0_type {Memory} \
  CONFIG.pf3_sriov_bar0_type {Memory} \
  CONFIG.PF0_DEVICE_ID_mqdma $pf_device_id \
  CONFIG.PF2_DEVICE_ID_mqdma $pf_device_id \
  CONFIG.PF3_DEVICE_ID_mqdma $pf_device_id \
  CONFIG.pf0_base_class_menu_mqdma {Bridge_device} \
  CONFIG.pf0_class_code_base_mqdma {06} \
  CONFIG.pf0_class_code_mqdma {068000} \
  CONFIG.pf1_base_class_menu_mqdma {Bridge_device} \
  CONFIG.pf1_class_code_base_mqdma {06} \
  CONFIG.pf1_class_code_mqdma {068000} \
  CONFIG.pf2_base_class_menu_mqdma {Bridge_device} \
  CONFIG.pf2_class_code_base_mqdma {06} \
  CONFIG.pf2_class_code_mqdma {068000} \
  CONFIG.pf3_base_class_menu_mqdma {Bridge_device} \
  CONFIG.pf3_class_code_base_mqdma {06} \
  CONFIG.pf3_class_code_mqdma {068000}] [get_bd_cells xdma_1]
}

# Answer record 71106: Zynq Ultrascale+ MPSoC - PL PCIe Root Port Bridge (Vivado 2018.1)
# - MSI Interrupt handling causes downstream devices to time out
# https://www.xilinx.com/support/answers/71106.html
set_property -dict [list CONFIG.msi_rx_pin_en {true}] [get_bd_cells xdma_0]
if {$dual_design} {
  set_property -dict [list CONFIG.msi_rx_pin_en {true}] [get_bd_cells xdma_1]
}

# Create AXI Interconnect for the XDMA slave interfaces
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect periph_intercon_0
if {$dual_design} {
  create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect periph_intercon_1
}

# Use connection automation after configuration of the PCIe block - so it will assign 512MB to the S_AXI_CTL interfaces
# (nvrec: the root ports' M_AXI_B masters are connected further below, through
# SmartConnects that also reach the NVMe Host Accelerator's queue window)
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config { Clk_master {/zynq_ultra_ps_e_0/pl_clk0 (99 MHz)} Clk_slave {/xdma_0/axi_aclk (250 MHz)} Clk_xbar {Auto} Master {/zynq_ultra_ps_e_0/M_AXI_HPM0_FPD} Slave {/xdma_0/S_AXI_B} intc_ip {periph_intercon_0} master_apm {0}}  [get_bd_intf_pins xdma_0/S_AXI_B]
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config { Clk_master {/zynq_ultra_ps_e_0/pl_clk0 (99 MHz)} Clk_slave {/xdma_0/axi_aclk (250 MHz)} Clk_xbar {Auto} Master {/zynq_ultra_ps_e_0/M_AXI_HPM0_FPD} Slave {/xdma_0/S_AXI_LITE} intc_ip {periph_intercon_0} master_apm {0}}  [get_bd_intf_pins xdma_0/S_AXI_LITE]
if {$dual_design} {
  apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config { Clk_master {/zynq_ultra_ps_e_0/pl_clk0 (99 MHz)} Clk_slave {/xdma_1/axi_aclk (250 MHz)} Clk_xbar {Auto} Master {/zynq_ultra_ps_e_0/M_AXI_HPM1_FPD} Slave {/xdma_1/S_AXI_B} intc_ip {periph_intercon_1} master_apm {0}}  [get_bd_intf_pins xdma_1/S_AXI_B]
  apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config { Clk_master {/zynq_ultra_ps_e_0/pl_clk0 (99 MHz)} Clk_slave {/xdma_1/axi_aclk (250 MHz)} Clk_xbar {Auto} Master {/zynq_ultra_ps_e_0/M_AXI_HPM1_FPD} Slave {/xdma_1/S_AXI_LITE} intc_ip {periph_intercon_1} master_apm {0}}  [get_bd_intf_pins xdma_1/S_AXI_LITE]
}

# Set the BAR0 offsets and sizes
set_property offset 0x00A0000000 [get_bd_addr_segs {zynq_ultra_ps_e_0/Data/SEG_xdma_0_BAR0}]
set_property range 256M [get_bd_addr_segs {zynq_ultra_ps_e_0/Data/SEG_xdma_0_BAR0}]
if {$dual_design} {
  set_property offset 0x00B0000000 [get_bd_addr_segs {zynq_ultra_ps_e_0/Data/SEG_xdma_1_BAR0}]
  set_property range 256M [get_bd_addr_segs {zynq_ultra_ps_e_0/Data/SEG_xdma_1_BAR0}]
}

# Add MGT external port for PCIe (SSD1)
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:pcie_7x_mgt_rtl:1.0 pci_exp_0
connect_bd_intf_net [get_bd_intf_pins xdma_0/pcie_mgt] [get_bd_intf_ports pci_exp_0]

# Add MGT external port for PCIe (SSD2)
if {$dual_design} {
  create_bd_intf_port -mode Master -vlnv xilinx.com:interface:pcie_7x_mgt_rtl:1.0 pci_exp_1
  connect_bd_intf_net [get_bd_intf_pins xdma_1/pcie_mgt] [get_bd_intf_ports pci_exp_1]
}

# Add differential buffer for the 100MHz PCIe reference clock (SSD1)
create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf ref_clk_0_buf
set_property -dict [list CONFIG.C_BUF_TYPE {IBUFDSGTE}] [get_bd_cells ref_clk_0_buf]
# sys_clk and sys_clk_gt connected as per DMA/Bridge Subsystem for PCIe Product guide PG195
# https://www.xilinx.com/support/documentation/ip_documentation/xdma/v2_0/pg195-pcie-dma.pdf
connect_bd_net [get_bd_pins ref_clk_0_buf/IBUF_DS_ODIV2] [get_bd_pins xdma_0/sys_clk]
connect_bd_net [get_bd_pins ref_clk_0_buf/IBUF_OUT] [get_bd_pins xdma_0/sys_clk_gt]
create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 ref_clk_0
connect_bd_intf_net [get_bd_intf_pins ref_clk_0_buf/CLK_IN_D] [get_bd_intf_ports ref_clk_0]

# Add differential buffer for the 100MHz PCIe reference clock (SSD2)
if {$dual_design} {
  create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf ref_clk_1_buf
  set_property -dict [list CONFIG.C_BUF_TYPE {IBUFDSGTE}] [get_bd_cells ref_clk_1_buf]
  # sys_clk and sys_clk_gt connected as per DMA/Bridge Subsystem for PCIe Product guide PG195
  # https://www.xilinx.com/support/documentation/ip_documentation/xdma/v2_0/pg195-pcie-dma.pdf
  connect_bd_net [get_bd_pins ref_clk_1_buf/IBUF_DS_ODIV2] [get_bd_pins xdma_1/sys_clk]
  connect_bd_net [get_bd_pins ref_clk_1_buf/IBUF_OUT] [get_bd_pins xdma_1/sys_clk_gt]
  create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 ref_clk_1
  connect_bd_intf_net [get_bd_intf_pins ref_clk_1_buf/CLK_IN_D] [get_bd_intf_ports ref_clk_1]
}

# Create concat for the interrupts and connect them
create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconcat:1.0 concat_interrupts
connect_bd_net [get_bd_pins concat_interrupts/dout] [get_bd_pins zynq_ultra_ps_e_0/pl_ps_irq0]
if {$dual_design} {
  set_property -dict [list CONFIG.NUM_PORTS {6}] [get_bd_cells concat_interrupts]
  connect_bd_net [get_bd_pins xdma_0/interrupt_out] [get_bd_pins concat_interrupts/In0]
  connect_bd_net [get_bd_pins xdma_1/interrupt_out] [get_bd_pins concat_interrupts/In1]
  connect_bd_net [get_bd_pins xdma_0/interrupt_out_msi_vec0to31] [get_bd_pins concat_interrupts/In2]
  connect_bd_net [get_bd_pins xdma_0/interrupt_out_msi_vec32to63] [get_bd_pins concat_interrupts/In3]
  connect_bd_net [get_bd_pins xdma_1/interrupt_out_msi_vec0to31] [get_bd_pins concat_interrupts/In4]
  connect_bd_net [get_bd_pins xdma_1/interrupt_out_msi_vec32to63] [get_bd_pins concat_interrupts/In5]
} else {
  set_property -dict [list CONFIG.NUM_PORTS {3}] [get_bd_cells concat_interrupts]
  connect_bd_net [get_bd_pins xdma_0/interrupt_out] [get_bd_pins concat_interrupts/In0]
  connect_bd_net [get_bd_pins xdma_0/interrupt_out_msi_vec0to31] [get_bd_pins concat_interrupts/In1]
  connect_bd_net [get_bd_pins xdma_0/interrupt_out_msi_vec32to63] [get_bd_pins concat_interrupts/In2]
}

# Add proc system reset for xdma_0/axi_ctl_aresetn
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_pcie_0_axi_aclk
connect_bd_net [get_bd_pins xdma_0/axi_aclk] [get_bd_pins rst_pcie_0_axi_aclk/slowest_sync_clk]
connect_bd_net [get_bd_pins xdma_0/axi_ctl_aresetn] [get_bd_pins rst_pcie_0_axi_aclk/ext_reset_in]
disconnect_bd_net /xdma_0_axi_aresetn [get_bd_pins periph_intercon_0/M01_ARESETN]
connect_bd_net [get_bd_pins xdma_0/axi_ctl_aresetn] [get_bd_pins periph_intercon_0/M01_ARESETN]

# Add proc system reset for xdma_1/axi_ctl_aresetn
if {$dual_design} {
  create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_pcie_1_axi_aclk
  connect_bd_net [get_bd_pins xdma_1/axi_aclk] [get_bd_pins rst_pcie_1_axi_aclk/slowest_sync_clk]
  connect_bd_net [get_bd_pins xdma_1/axi_ctl_aresetn] [get_bd_pins rst_pcie_1_axi_aclk/ext_reset_in]
  disconnect_bd_net /xdma_1_axi_aresetn [get_bd_pins periph_intercon_1/M01_ARESETN]
  connect_bd_net [get_bd_pins xdma_1/axi_ctl_aresetn] [get_bd_pins periph_intercon_1/M01_ARESETN]
}

# Create PERST ports
create_bd_port -dir O -from 0 -to 0 -type rst perst_0
connect_bd_net [get_bd_pins /rst_pcie_0_axi_aclk/peripheral_reset] [get_bd_ports perst_0]
if {$dual_design} {
  create_bd_port -dir O -from 0 -to 0 -type rst perst_1
  connect_bd_net [get_bd_pins /rst_pcie_1_axi_aclk/peripheral_reset] [get_bd_ports perst_1]
}

# Connect AXI PCIe reset
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0] [get_bd_pins xdma_0/sys_rst_n]
if {$dual_design} {
  connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0] [get_bd_pins xdma_1/sys_rst_n]
}

# Constant to enable/disable 3.3V power supply of SSD2 and clock source
set const_dis_ssd2_pwr [ create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconstant:1.0 const_dis_ssd2_pwr ]
create_bd_port -dir O disable_ssd2_pwr
connect_bd_net [get_bd_pins const_dis_ssd2_pwr/dout] [get_bd_ports disable_ssd2_pwr]
if {$dual_design} {
  # LOW to enable SSD2
  set_property -dict [list CONFIG.CONST_VAL {0}] $const_dis_ssd2_pwr
} else {
  # HIGH to disable SSD2
  set_property -dict [list CONFIG.CONST_VAL {1}] $const_dis_ssd2_pwr
}

# ##########################################################
# FPGA Drive NVMe offload recorder (nvrec)
# ##########################################################
#
#  user_data_source (src_clk 250)    nvrec_core_0 (dp_clk 250)                nvmeha_0 (AMD NVMe
#  [fdrec_tpg] --AXIS DWb--> [ingest -> ring writer] --AXI4 DWb--> axi_smc_dma --128b @ pl_clk3-->
#                             [cmd builder] --SQE AXIS 512b--> S_AXIS    S_AXI_HP2_FPD -> DDR)
#                             [cq router]   <--CQE AXIS 128b-- M_AXIS
#                             [dbmon] <--- M_AXI_SSD (doorbells) ; m_axi_db -> smc_db -> smc_bar_0/1 -> xdma_N/S_AXI_B
#  user_data_sink  <-- egress FIFO <-- [ring reader] (playback)
#
#  SSD DMA:  xdma_N/M_AXI_B -> smc_ssd_N -+-> S_AXI_HPN_FPD (DDR: data, PRP lists, admin queues)
#                                         +-> smc_q -> nvmeha_0/S_AXI_SSD (I/O SQ/CQ memory, 0x9000_0000)
#  PS:       M_AXI_HPM0_FPD -> periph_intercon_0 -> nvrec_core_0 regs,
#            nvmeha_guard (AXI-Lite timeout guard) -> nvmeha_0 S_AXI_LITE,
#            and (through smc_bar_0) xdma_0/S_AXI_B; M_AXI_HPM1_FPD -> periph_intercon_1 -> smc_bar_1
#
# DWb = nvrec_data_width bits (256 on the reference designs: 8.0 GB/s from the
# source and into the sink). The HP2 port (128 bits x pl_clk3: 5.16 GB/s peak on
# the ZCU106, 5.24 GB/s on the UltraZed-EV) is the ring's DDR-side ceiling.
#
# The user_data_source / user_data_sink hierarchies are the documented
# insertion points for a customer's own data source / sink.

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
    set_property range $range $seg
    set_property offset $offset $seg
  }
}

# Actual PL clock frequencies (the PS PLLs may not hit the requested values exactly)
set dp_clk_hz  [expr {int(round([get_property CONFIG.FREQ_HZ [get_bd_pins zynq_ultra_ps_e_0/pl_clk1]]))}]
set src_clk_hz [expr {int(round([get_property CONFIG.FREQ_HZ [get_bd_pins zynq_ultra_ps_e_0/pl_clk2]]))}]
set hp2_clk_hz [expr {int(round([get_property CONFIG.FREQ_HZ [get_bd_pins zynq_ultra_ps_e_0/pl_clk3]]))}]
puts "INFO: nvrec dp_clk (pl_clk1) = $dp_clk_hz Hz, src_clk (pl_clk2) = $src_clk_hz Hz, hp2 (pl_clk3) = $hp2_clk_hz Hz, DATA_WIDTH = $nvrec_data_width"
# dp_clk / src_clk must stay at 250 MHz (nvmeha clk_core limit, source rate): a PLL
# retune that pulls them off (eg. all PL clocks on one PLL) is a build error
foreach {name hz} [list dp_clk $dp_clk_hz src_clk $src_clk_hz] {
  if {abs($hz - 250000000) > 250000} {
    error "nvrec: $name = $hz Hz, expected 250 MHz (check the PL1/PL2 SRCSEL)"
  }
}
if {$hp2_clk_hz > 333334000} {
  error "nvrec: pl_clk3 (HP2) = $hp2_clk_hz Hz exceeds the 333 MHz PS-PL interface maximum (DS925)"
}

# Resets: dp_clk, src_clk, and pl_clk0 (nvmeha AXI-Lite)
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_dp_clk
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk1] [get_bd_pins rst_dp_clk/slowest_sync_clk]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0] [get_bd_pins rst_dp_clk/ext_reset_in]
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_src_clk
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk2] [get_bd_pins rst_src_clk/slowest_sync_clk]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0] [get_bd_pins rst_src_clk/ext_reset_in]
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_lite_clk
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins rst_lite_clk/slowest_sync_clk]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0] [get_bd_pins rst_lite_clk/ext_reset_in]

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
  CONFIG.SLOT_W $nvrec_slot_w] [get_bd_cells nvrec_core_0]

connect_bd_intf_net [get_bd_intf_pins user_data_source/M_AXIS] [get_bd_intf_pins nvrec_core_0/s_axis]
foreach p {tpg_enable tpg_seq_rst tpg_rate_inc tpg_seq_next} {
  connect_bd_net [get_bd_pins nvrec_core_0/$p] [get_bd_pins user_data_source/$p]
}
connect_bd_intf_net [get_bd_intf_pins nvrec_core_0/m_axis_snk] [get_bd_intf_pins user_data_sink/S_AXIS]
foreach p [concat {chk_enable chk_reset chk_rate_inc} $chk_counters] {
  connect_bd_net [get_bd_pins nvrec_core_0/$p] [get_bd_pins user_data_sink/$p]
}

# AMD NVMe Host Accelerator (PG328): 2 SSDs, ONE hardware queue per SSD and no
# software queues. PG328 (Ch.3 Product Specification) numbers an SSD's software
# queues before its hardware queues, so with any software queue the hardware
# queue would be NVMe QID 2 -- impossible on drives that grant a single I/O
# queue. Hardware-only: the hardware SQ/CQ is QID 1 on every drive; all CPU
# I/O goes through the nvrec_core command injector on that same queue.
# Depth 64, full 64-byte commands, QoS off, statistics on.
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

# AXI-Lite timeout guard in front of the Host Accelerator registers: when the
# evaluation-licensed core stops (~3 h after the bitstream load) its register
# slave never answers again and a CPU read would hang the whole system. The
# guard completes such an access itself after 16384 clocks (OKAY, data all
# ones -- an SLVERR would be an SError panic on the A53), latches `dead`, and
# answers every later access at once. `dead` -> nvrec_core STATE.HA_DEAD /
# IRQ_STATUS.HA_DEAD. A heartbeat read every 2^24 clocks detects the expiry
# even when software does not touch the IP.
create_bd_cell -type module -reference nvrec_axil_guard nvmeha_guard
connect_bd_intf_net [get_bd_intf_pins nvmeha_guard/m_axi] [get_bd_intf_pins nvmeha_0/S_AXI_LITE]
connect_bd_net [get_bd_pins nvmeha_guard/dead] [get_bd_pins nvrec_core_0/ha_dead]

connect_bd_intf_net [get_bd_intf_pins nvrec_core_0/m_axis_sqe] [get_bd_intf_pins nvmeha_0/S_AXIS]
connect_bd_intf_net [get_bd_intf_pins nvmeha_0/M_AXIS] [get_bd_intf_pins nvrec_core_0/s_axis_cqe]
connect_bd_intf_net [get_bd_intf_pins nvmeha_0/M_AXI_SSD] [get_bd_intf_pins nvrec_core_0/s_axi_db]

# Ring writer / reader -> SmartConnect -> S_AXI_HP2_FPD. Two clocks: aclk = dp_clk
# (nvrec_core side, nvrec_data_width bits), aclk1 = pl_clk3 (the HP2 side, 128
# bits); the SmartConnect does the width and clock conversion.
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect axi_smc_dma
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1} CONFIG.NUM_CLKS {2}] [get_bd_cells axi_smc_dma]
connect_bd_intf_net [get_bd_intf_pins nvrec_core_0/m_axi] [get_bd_intf_pins axi_smc_dma/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc_dma/M00_AXI] [get_bd_intf_pins zynq_ultra_ps_e_0/S_AXI_HP2_FPD]

# Doorbells: nvmeha M_AXI_SSD -> nvrec_core_0 (dbmon) -> smc_db -> smc_bar_N -> xdma_N/S_AXI_B.
# The PS path to each S_AXI_B (periph_intercon_N) is moved behind smc_bar_N.
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect smc_db
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {2}] [get_bd_cells smc_db]
connect_bd_intf_net [get_bd_intf_pins nvrec_core_0/m_axi_db] [get_bd_intf_pins smc_db/S00_AXI]
foreach n {0 1} {
  set bar_net [get_bd_intf_nets -of_objects [get_bd_intf_pins xdma_${n}/S_AXI_B]]
  set ps_pin  [get_bd_intf_pins -of_objects $bar_net -filter {MODE == Master}]
  delete_bd_objs $bar_net
  create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect smc_bar_${n}
  set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1} CONFIG.NUM_CLKS {2}] [get_bd_cells smc_bar_${n}]
  connect_bd_intf_net $ps_pin [get_bd_intf_pins smc_bar_${n}/S00_AXI]
  connect_bd_intf_net [get_bd_intf_pins smc_db/M0${n}_AXI] [get_bd_intf_pins smc_bar_${n}/S01_AXI]
  connect_bd_intf_net [get_bd_intf_pins smc_bar_${n}/M00_AXI] [get_bd_intf_pins xdma_${n}/S_AXI_B]
  connect_bd_net [get_bd_pins xdma_${n}/axi_aclk] [get_bd_pins smc_bar_${n}/aclk]
  connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk1] [get_bd_pins smc_bar_${n}/aclk1]
  connect_bd_net [get_bd_pins xdma_${n}/axi_aresetn] [get_bd_pins smc_bar_${n}/aresetn]
}

# SSD DMA: xdma_N/M_AXI_B -> smc_ssd_N -> {S_AXI_HPN_FPD, smc_q -> nvmeha_0/S_AXI_SSD}
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect smc_q
set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1}] [get_bd_cells smc_q]
connect_bd_intf_net [get_bd_intf_pins smc_q/M00_AXI] [get_bd_intf_pins nvmeha_0/S_AXI_SSD]
foreach n {0 1} {
  create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect smc_ssd_${n}
  set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {2} CONFIG.NUM_CLKS {2}] [get_bd_cells smc_ssd_${n}]
  connect_bd_intf_net [get_bd_intf_pins xdma_${n}/M_AXI_B] [get_bd_intf_pins smc_ssd_${n}/S00_AXI]
  connect_bd_intf_net [get_bd_intf_pins smc_ssd_${n}/M00_AXI] [get_bd_intf_pins zynq_ultra_ps_e_0/S_AXI_HP${n}_FPD]
  connect_bd_intf_net [get_bd_intf_pins smc_ssd_${n}/M01_AXI] [get_bd_intf_pins smc_q/S0${n}_AXI]
  connect_bd_net [get_bd_pins xdma_${n}/axi_aclk] [get_bd_pins smc_ssd_${n}/aclk]
  connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk1] [get_bd_pins smc_ssd_${n}/aclk1]
  connect_bd_net [get_bd_pins xdma_${n}/axi_aresetn] [get_bd_pins smc_ssd_${n}/aresetn]
}

# AXI-Lite from the PS: nvrec registers, nvmeha S_AXI_LITE
set n_mi [get_property CONFIG.NUM_MI [get_bd_cells periph_intercon_0]]
set mi_regs [format "M%02d" $n_mi]
set mi_lite [format "M%02d" [expr {$n_mi + 1}]]
set_property CONFIG.NUM_MI [expr {$n_mi + 2}] [get_bd_cells periph_intercon_0]
connect_bd_intf_net [get_bd_intf_pins periph_intercon_0/${mi_regs}_AXI] [get_bd_intf_pins nvrec_core_0/s_axi]
connect_bd_intf_net [get_bd_intf_pins periph_intercon_0/${mi_lite}_AXI] [get_bd_intf_pins nvmeha_guard/s_axi]

# HP2 clock: S_AXI_HP2_FPD and the ring SmartConnect's master side only
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk3] \
  [get_bd_pins zynq_ultra_ps_e_0/saxihp2_fpd_aclk] \
  [get_bd_pins axi_smc_dma/aclk1]

# dp_clk domain clocks and resets
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk1] \
  [get_bd_pins zynq_ultra_ps_e_0/saxihp0_fpd_aclk] \
  [get_bd_pins zynq_ultra_ps_e_0/saxihp1_fpd_aclk] \
  [get_bd_pins axi_smc_dma/aclk] \
  [get_bd_pins smc_db/aclk] \
  [get_bd_pins smc_q/aclk] \
  [get_bd_pins nvrec_core_0/dp_clk] \
  [get_bd_pins nvmeha_0/clk_core] \
  [get_bd_pins periph_intercon_0/${mi_regs}_ACLK]
connect_bd_net [get_bd_pins rst_dp_clk/peripheral_aresetn] \
  [get_bd_pins nvrec_core_0/dp_resetn] \
  [get_bd_pins nvmeha_0/rst_n_core] \
  [get_bd_pins periph_intercon_0/${mi_regs}_ARESETN]
connect_bd_net [get_bd_pins rst_dp_clk/interconnect_aresetn] \
  [get_bd_pins axi_smc_dma/aresetn] \
  [get_bd_pins smc_db/aresetn] \
  [get_bd_pins smc_q/aresetn]

# nvmeha AXI-Lite clock (<= 100 MHz, PG328): pl_clk0
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] \
  [get_bd_pins nvmeha_0/clk_axi_lite] \
  [get_bd_pins nvmeha_guard/aclk] \
  [get_bd_pins periph_intercon_0/${mi_lite}_ACLK]
connect_bd_net [get_bd_pins rst_lite_clk/peripheral_aresetn] \
  [get_bd_pins nvmeha_0/rst_n_axi_lite] \
  [get_bd_pins nvmeha_guard/aresetn] \
  [get_bd_pins periph_intercon_0/${mi_lite}_ARESETN]

# src_clk domain
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk2] \
  [get_bd_pins user_data_source/src_clk] \
  [get_bd_pins user_data_sink/snk_clk] \
  [get_bd_pins nvrec_core_0/src_clk]
connect_bd_net [get_bd_pins rst_src_clk/peripheral_aresetn] \
  [get_bd_pins user_data_source/src_resetn] \
  [get_bd_pins user_data_sink/snk_resetn] \
  [get_bd_pins nvrec_core_0/src_resetn]

# Interrupts: pl_ps_irq0[6] = nvrec_core_0/irq (GIC SPI 95),
#             pl_ps_irq0[7] = nvmeha_0/ha_interrupt (GIC SPI 96)
foreach src {nvrec_core_0/irq nvmeha_0/ha_interrupt} {
  set n_irq [get_property CONFIG.NUM_PORTS [get_bd_cells concat_interrupts]]
  set_property CONFIG.NUM_PORTS [expr {$n_irq + 1}] [get_bd_cells concat_interrupts]
  connect_bd_net [get_bd_pins $src] [get_bd_pins concat_interrupts/In${n_irq}]
  puts "INFO: nvrec $src -> pl_ps_irq0\[$n_irq\] (GIC SPI [expr {89 + $n_irq}])"
}

# ----------------------------------------------------------
# Address map
# ----------------------------------------------------------
assign_bd_address
# PS view: PCIe BAR windows (base design), nvrec / nvmeha register windows
nvrec_map zynq_ultra_ps_e_0/Data xdma_0/S_AXI_B/BAR0 0x00A0000000 256M
nvrec_map zynq_ultra_ps_e_0/Data xdma_1/S_AXI_B/BAR0 0x00B0000000 256M
nvrec_map zynq_ultra_ps_e_0/Data nvrec_core_0/s_axi/reg0 0x0420010000 4K
nvrec_map zynq_ultra_ps_e_0/Data nvmeha_guard/s_axi/reg0 0x0420020000 64K
# the guard forwards the low 32 address bits it receives (0x2002_xxxx)
nvrec_map nvmeha_guard/m_axi nvmeha_0/S_AXI_LITE/Reg 0x20020000 64K
foreach seg [get_bd_addr_segs -quiet -excluded -of_objects [get_bd_addr_spaces nvmeha_guard/m_axi]] {
  include_bd_addr_seg $seg
}
# Host Accelerator doorbells: whole 32-bit space into the doorbell monitor,
# which forwards to the two BAR windows at the SAME addresses as the PS sees
# them (one AXI-to-PCIe translation per root port)
nvrec_map nvmeha_0/Data nvrec_core_0/s_axi_db/reg0 0x00000000 4G
# (the module reference's slave is a 'register' segment, the IP's master a
# 'memory' space: Vivado excludes such a mapping unless it is included)
foreach seg [get_bd_addr_segs -quiet -excluded -of_objects [get_bd_addr_spaces nvmeha_0/Data]] {
  include_bd_addr_seg $seg
}
nvrec_map nvrec_core_0/m_axi_db xdma_0/S_AXI_B/BAR0 0xA0000000 256M
nvrec_map nvrec_core_0/m_axi_db xdma_1/S_AXI_B/BAR0 0xB0000000 256M
# SSD view (root port M_AXI_B, no inbound translation): queue window
nvrec_map xdma_0/M_AXI_B nvmeha_0/S_AXI_SSD/Reg 0x90000000 64K
nvrec_map xdma_1/M_AXI_B nvmeha_0/S_AXI_SSD/Reg 0x90000000 64K
assign_bd_address

foreach sp {zynq_ultra_ps_e_0/Data nvmeha_guard/m_axi nvmeha_0/Data nvrec_core_0/m_axi_db nvrec_core_0/m_axi xdma_0/M_AXI_B xdma_1/M_AXI_B} {
  foreach seg [get_bd_addr_segs -quiet -of_objects [get_bd_addr_spaces $sp]] {
    puts "INFO: addr $sp [get_property NAME $seg] offset [get_property OFFSET $seg] range [get_property RANGE $seg]"
  }
}

validate_bd_design

# The ring path after parameter propagation: widths and clocks of the
# SmartConnect's two sides (it must have both clocks: dp_clk and pl_clk3)
foreach ip {nvrec_core_0/m_axi axi_smc_dma/S00_AXI axi_smc_dma/M00_AXI zynq_ultra_ps_e_0/S_AXI_HP2_FPD} {
  set ipin [get_bd_intf_pins $ip]
  puts "INFO: nvrec $ip DATA_WIDTH [get_property CONFIG.DATA_WIDTH $ipin] FREQ_HZ [get_property CONFIG.FREQ_HZ $ipin]"
}
foreach clk {aclk aclk1} {
  puts "INFO: nvrec axi_smc_dma/$clk <- [get_bd_nets -of_objects [get_bd_pins axi_smc_dma/$clk]]"
}

# Restore current instance
current_bd_instance $oldCurInst

save_bd_design
