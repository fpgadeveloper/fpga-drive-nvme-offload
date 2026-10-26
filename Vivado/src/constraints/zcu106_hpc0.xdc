#----------------------------------------------------------------------------------------
# Constraints for Opsero FPGA Drive FMC Gen4 ref design for ZCU106-HPC0 using 2x SSDs
#----------------------------------------------------------------------------------------

# SSD1 PCI Express reset (perst_0)
set_property PACKAGE_PIN F17 [get_ports {perst_0[0]}]; # LA00_CC_P
set_property IOSTANDARD LVCMOS18 [get_ports {perst_0[0]}]

# SSD2 PCI Express reset (perst_1)
set_property PACKAGE_PIN L17 [get_ports {perst_1[0]}]; # LA04_P
set_property IOSTANDARD LVCMOS18 [get_ports {perst_1[0]}]

# SSD1 PE Detect (pedet_0, not connected in the design)
# set_property PACKAGE_PIN F16 [get_ports {pedet_0[0]}]; # LA00_CC_N
# set_property IOSTANDARD LVCMOS18 [get_ports {pedet_0[0]}]

# SSD2 PE Detect (pedet_1, not connected in the design)
# set_property PACKAGE_PIN L16 [get_ports {pedet_1[0]}]; # LA04_N
# set_property IOSTANDARD LVCMOS18 [get_ports {pedet_1[0]}]

# Disable signal for 3.3V power supply for SSD2 (disable_ssd2_pwr)
set_property PACKAGE_PIN J16 [get_ports disable_ssd2_pwr]; # LA07_P
set_property IOSTANDARD LVCMOS18 [get_ports disable_ssd2_pwr]

##############################
# PCIe reference clock 100MHz
##############################

# SSD1 ref clock
set_property PACKAGE_PIN V8 [get_ports {ref_clk_0_clk_p[0]}]; # GBTCLK0_M2C_P
set_property PACKAGE_PIN V7 [get_ports {ref_clk_0_clk_n[0]}]; # GBTCLK0_M2C_N
create_clock -period 10.000 -name ref_clk_0_clk_p -waveform {0.000 5.000} [get_ports ref_clk_0_clk_p]

# SSD2 ref clock
set_property PACKAGE_PIN T8 [get_ports {ref_clk_1_clk_p[0]}]; # GBTCLK1_M2C_P
set_property PACKAGE_PIN T7 [get_ports {ref_clk_1_clk_n[0]}]; # GBTCLK1_M2C_N
create_clock -period 10.000 -name ref_clk_1_clk_p -waveform {0.000 5.000} [get_ports ref_clk_1_clk_p]

############################
# SSD1 Gigabit transceivers
############################

# Reset the LOC on all of the GTs
set_property LOC "" [get_cells -hierarchical -filter { PRIMITIVE_TYPE =~ ADVANCED.GT.GTHE4_CHANNEL && NAME =~ "*xdma_0*" }]

set_property LOC GTHE4_CHANNEL_X0Y14 [get_cells -hierarchical -regexp -filter { PRIMITIVE_TYPE =~ ADVANCED.GT.GTHE4_CHANNEL && PARENT =~  ".*xdma_0.*" && NAME =~ ".*channel_inst\[0\].*" }]
set_property LOC GTHE4_CHANNEL_X0Y13 [get_cells -hierarchical -regexp -filter { PRIMITIVE_TYPE =~ ADVANCED.GT.GTHE4_CHANNEL && PARENT =~  ".*xdma_0.*" && NAME =~ ".*channel_inst\[1\].*" }]
set_property LOC GTHE4_CHANNEL_X0Y15 [get_cells -hierarchical -regexp -filter { PRIMITIVE_TYPE =~ ADVANCED.GT.GTHE4_CHANNEL && PARENT =~  ".*xdma_0.*" && NAME =~ ".*channel_inst\[2\].*" }]
set_property LOC GTHE4_CHANNEL_X0Y12 [get_cells -hierarchical -regexp -filter { PRIMITIVE_TYPE =~ ADVANCED.GT.GTHE4_CHANNEL && PARENT =~  ".*xdma_0.*" && NAME =~ ".*channel_inst\[3\].*" }]

############################
# SSD2 Gigabit transceivers
############################

# Reset the LOC on all of the GTs
set_property LOC "" [get_cells -hierarchical -filter { PRIMITIVE_TYPE =~ ADVANCED.GT.GTHE4_CHANNEL && NAME =~ "*xdma_1*" }]

set_property LOC GTHE4_CHANNEL_X0Y19 [get_cells -hierarchical -regexp -filter { PRIMITIVE_TYPE =~ ADVANCED.GT.GTHE4_CHANNEL && PARENT =~  ".*xdma_1.*" && NAME =~ ".*channel_inst\[0\].*" }]
set_property LOC GTHE4_CHANNEL_X0Y17 [get_cells -hierarchical -regexp -filter { PRIMITIVE_TYPE =~ ADVANCED.GT.GTHE4_CHANNEL && PARENT =~  ".*xdma_1.*" && NAME =~ ".*channel_inst\[1\].*" }]
set_property LOC GTHE4_CHANNEL_X0Y16 [get_cells -hierarchical -regexp -filter { PRIMITIVE_TYPE =~ ADVANCED.GT.GTHE4_CHANNEL && PARENT =~  ".*xdma_1.*" && NAME =~ ".*channel_inst\[2\].*" }]
set_property LOC GTHE4_CHANNEL_X0Y18 [get_cells -hierarchical -regexp -filter { PRIMITIVE_TYPE =~ ADVANCED.GT.GTHE4_CHANNEL && PARENT =~  ".*xdma_1.*" && NAME =~ ".*channel_inst\[3\].*" }]

############################
# SSD1 PCIe block
############################

set_property LOC PCIE40E4_X0Y1 [get_cells -hierarchical -filter { PRIMITIVE_TYPE =~ ADVANCED.PCIE.* && NAME =~ "*xdma_0*" }]

############################
# SSD2 PCIe block
############################

set_property LOC PCIE40E4_X0Y0 [get_cells -hierarchical -filter { PRIMITIVE_TYPE =~ ADVANCED.PCIE.* && NAME =~ "*xdma_1*" }]


#####################################################################
# Split ring (register map 1.3): PL DDR4 controller ddr4_0 (banks 64-66)
#####################################################################
# Keep each byte lane's write-data registers (the MIG's u_ddr_mc_write
# genByte[n]) in the clock region of its I/O bank: data bytes 0-3 sit in
# CLOCKREGION_X2Y1, bytes 4-7 in X2Y2 (address/command in X2Y3). Left free,
# the placer moved part of them one clock region away in this congested
# design and the XIPHY pulse-width check "Min Skew" between the D[1] and D[2]
# inputs of a DQ bitslice failed (-0.283 ns, byte lane 1, 2026-10-23).
create_pblock pb_ddr4_wr_x2y1
add_cells_to_pblock pb_ddr4_wr_x2y1 [get_cells -hierarchical -regexp -filter {IS_PRIMITIVE && NAME =~ "nvrec_i/ddr4_0/.*/u_ddr_mc_write/genByte\[[0-3]\]\..*"}]
resize_pblock pb_ddr4_wr_x2y1 -add {CLOCKREGION_X2Y1:CLOCKREGION_X2Y1}
create_pblock pb_ddr4_wr_x2y2
add_cells_to_pblock pb_ddr4_wr_x2y2 [get_cells -hierarchical -regexp -filter {IS_PRIMITIVE && NAME =~ "nvrec_i/ddr4_0/.*/u_ddr_mc_write/genByte\[[4-7]\]\..*"}]
resize_pblock pb_ddr4_wr_x2y2 -add {CLOCKREGION_X2Y2:CLOCKREGION_X2Y2}
