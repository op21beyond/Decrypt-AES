################################################################################
# File        : constraints.sdc
# Project     : AES Decryption Engine IP
# Company     : SSVD
# Description : Synopsys Design Constraints (SDC) for aes_decrypt_engine.
#               Timing constraints target 200 MHz operation (5 ns period).
#               Throughput at 200 MHz far exceeds the 200 Mbps specification.
#
# Clock:  clk — single synchronous clock domain, 200 MHz (5 ns period)
# Reset:  rst_n — asynchronous active-low reset (false path)
#
# NOTE: Adjust CLK_PERIOD_NS and I/O delay values to match the actual SoC
#       integration context and the chosen technology node.
################################################################################

# ==============================================================================
# 0. Parameters (edit as needed)
# ==============================================================================

set CLK_PERIOD_NS   5.0    ;# 200 MHz target clock
set CLK_SKEW_NS     0.1    ;# estimated clock network uncertainty
set CLK_LAT_NS      0.3    ;# estimated clock insertion delay
set IO_IN_DELAY_NS  1.0    ;# input port external delay budget
set IO_OUT_DELAY_NS 1.0    ;# output port external delay budget

# ==============================================================================
# 1. Clock definition
# ==============================================================================

create_clock -name clk \
    -period ${CLK_PERIOD_NS} \
    -waveform [list 0 [expr ${CLK_PERIOD_NS} / 2]] \
    [get_ports clk]

# Clock uncertainty (skew + jitter)
set_clock_uncertainty -setup ${CLK_SKEW_NS} [get_clocks clk]
set_clock_uncertainty -hold  [expr ${CLK_SKEW_NS} / 2] [get_clocks clk]

# Clock latency
set_clock_latency -source ${CLK_LAT_NS} [get_clocks clk]

# ==============================================================================
# 2. Reset — asynchronous, treat as false path for timing
# ==============================================================================

set_false_path -from [get_ports rst_n]

# ==============================================================================
# 3. AXI4-Lite Subordinate interface (register interface)
# ==============================================================================

# Inputs
set_input_delay  ${IO_IN_DELAY_NS} -clock clk \
    [get_ports {s_awaddr s_awvalid s_wdata s_wstrb s_wvalid s_bready
                s_araddr s_arvalid s_rready}]

# Outputs
set_output_delay ${IO_OUT_DELAY_NS} -clock clk \
    [get_ports {s_awready s_wready s_bresp s_bvalid
                s_arready s_rdata s_rresp s_rvalid}]

# ==============================================================================
# 4. AXI4 Manager interface (memory bus)
# ==============================================================================

# Write address / data / response
set_output_delay ${IO_OUT_DELAY_NS} -clock clk \
    [get_ports {m_awaddr m_awlen m_awsize m_awburst m_awcache m_awprot m_awvalid
                m_wdata m_wstrb m_wlast m_wvalid m_bready}]
set_input_delay  ${IO_IN_DELAY_NS} -clock clk \
    [get_ports {m_awready m_wready m_bresp m_bvalid}]

# Read address / data
set_output_delay ${IO_OUT_DELAY_NS} -clock clk \
    [get_ports {m_araddr m_arlen m_arsize m_arburst m_arcache m_arprot m_arvalid
                m_rready}]
set_input_delay  ${IO_IN_DELAY_NS} -clock clk \
    [get_ports {m_arready m_rdata m_rresp m_rlast m_rvalid}]

# ==============================================================================
# 5. Interrupt output
# ==============================================================================

set_output_delay ${IO_OUT_DELAY_NS} -clock clk [get_ports irq]

# ==============================================================================
# 6. Operating conditions and drive / load
# ==============================================================================

# Set a typical drive strength for input ports (adjust to match actual SoC FF)
set_driving_cell -lib_cell <DRIVING_CELL> -pin <PIN> [all_inputs]

# Set typical load on output ports (adjust to match interconnect model)
set_load 0.05 [all_outputs]   ;# 50 fF nominal — replace with PDK value

# ==============================================================================
# 7. Area / power hints
# ==============================================================================

# Maximum transition time (adjust to PDK recommendations)
set_max_transition 0.3 [current_design]

# Maximum fanout per cell
set_max_fanout 16 [current_design]

# ==============================================================================
# 8. Multicycle and false paths
# ==============================================================================

# AES key registers: key is loaded once per job (static during operation).
# The combinational key schedule (aes128_key_sched) is purely combinational
# and may have long paths; declare a 2-cycle multicycle path if timing is tight.
# Uncomment and adjust as needed after first compile:
#
# set_multicycle_path 2 -setup \
#     -from [get_cells u_regfile/r_aes_key*] \
#     -to   [get_cells u_key_sched/*]
# set_multicycle_path 1 -hold \
#     -from [get_cells u_regfile/r_aes_key*] \
#     -to   [get_cells u_key_sched/*]

# ==============================================================================
# 9. Don't-touch: SRAM behavioral models
# ==============================================================================

# Prevent DC from optimizing through the SRAM behavioral models.
# Remove when real SRAM macros (.db) are integrated.
set_dont_touch [get_cells u_mem_top/u_sram_cipher_fifo]
set_dont_touch [get_cells u_mem_top/u_sram_out_fifo]
