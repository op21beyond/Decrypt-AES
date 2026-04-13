################################################################################
# File        : run_dc.tcl
# Project     : AES Decryption Engine IP
# Company     : SSVD
# Description : Synopsys Design Compiler synthesis script.
#               Targets ASIC implementation of aes_decrypt_engine (DUT top).
#
# Usage       : dc_shell-t -f run_dc.tcl | tee run_dc.log
#               (or: dc_shell -tcl_mode -f run_dc.tcl | tee run_dc.log)
#
# Directory layout assumed:
#   design/rtl/          — RTL source files
#   design/rtl/inc/      — `include header files
#   design/rtl/crypto/   — AES crypto sub-modules
#   design/rtl/util/     — FIFO, SRAM behavioral models
#   design/syn/          — this script, output files written here
#
# Outputs (written to design/syn/output/):
#   aes_decrypt_engine_netlist.v  — mapped gate-level netlist
#   aes_decrypt_engine.sdc        — exported constraints
#   aes_decrypt_engine.ddc        — DC compiled design database
#   reports/                      — timing, area, power reports
################################################################################

# ==============================================================================
# 0. Environment setup — edit these variables to match your PDK / library paths
# ==============================================================================

# Target technology library (replace with actual PDK library path)
set TARGET_LIBRARY     "/pdk/libs/std_cell/db/std_cell_tt_1p0v_25c.db"

# Link libraries (standard cell + SRAM behavioral models for elaboration)
# In real flow, include compiled SRAM .db or .lib files here.
set LINK_LIBRARY       "* $TARGET_LIBRARY"

# Symbol library (for schematic view, optional)
set SYMBOL_LIBRARY     ""

# Search path for RTL source and include files
set SEARCH_PATH_LIST   {
    ../rtl
    ../rtl/inc
    ../rtl/crypto
    ../rtl/util
}

# Design top module name
set DESIGN_TOP         "aes_decrypt_engine"

# Clock name (must match the clock port in the SDC)
set CLK_PORT           "clk"

# Output directory
set OUTPUT_DIR         "./output"
file mkdir ${OUTPUT_DIR}
file mkdir ${OUTPUT_DIR}/reports

# ==============================================================================
# 1. Library / search path configuration
# ==============================================================================

set_app_var target_library  ${TARGET_LIBRARY}
set_app_var link_library    ${LINK_LIBRARY}
set_app_var search_path     [concat ${search_path} ${SEARCH_PATH_LIST}]

# ==============================================================================
# 2. Read RTL — analyze + elaborate
# ==============================================================================

# Define compile-time macros for synthesis
# (remove ENABLE_ASSERTIONS and ENABLE_COVERAGE for synthesis)
set VERILOG_DEFINES ""

# Analyze all RTL files
# Utility modules
analyze -format verilog ../rtl/util/sram_2p.v
analyze -format verilog ../rtl/util/sram_2p_32x64.v
analyze -format verilog ../rtl/util/sram_2p_32x72.v
analyze -format verilog ../rtl/util/sync_fifo.v
analyze -format verilog ../rtl/util/crc32_engine.v

# Crypto sub-modules
analyze -format verilog ../rtl/crypto/aes128_key_sched.v
analyze -format verilog ../rtl/crypto/aes128_enc_pipe.v
analyze -format verilog ../rtl/crypto/aes128_ctr_top.v

# IP sub-modules
analyze -format verilog ../rtl/aes_decrypt_regfile.v
analyze -format verilog ../rtl/aes_decrypt_axi_mgr.v
analyze -format verilog ../rtl/aes_decrypt_desc_fetch.v
analyze -format verilog ../rtl/aes_decrypt_input_ctrl.v
analyze -format verilog ../rtl/aes_decrypt_output_ctrl.v
analyze -format verilog ../rtl/aes_decrypt_writeback.v
analyze -format verilog ../rtl/aes_decrypt_ctrl.v
analyze -format verilog ../rtl/aes_decrypt_mem_top.v

# Top-level
analyze -format verilog ../rtl/aes_decrypt_engine.v

# Elaborate the design
elaborate ${DESIGN_TOP}

# Verify that the design was elaborated without errors
if {[llength [get_designs -filter "design_name == ${DESIGN_TOP}"] == 0]} {
    echo "ERROR: Elaboration of ${DESIGN_TOP} failed."
    quit
}

current_design ${DESIGN_TOP}
link

# ==============================================================================
# 3. SRAM macro: mark behavioral models as black boxes for synthesis
#    (replace with actual SRAM hard macro .db entries when available)
# ==============================================================================

# Mark SRAM behavioral models as dont-touch to prevent logic optimization.
# When real SRAM macros are available, remove these lines and add the SRAM .db
# files to the link_library instead.
set_dont_touch [get_cells -hierarchical -filter "ref_name =~ sram_2p_32x64"]
set_dont_touch [get_cells -hierarchical -filter "ref_name =~ sram_2p_32x72"]

# ==============================================================================
# 4. Read SDC timing constraints
# ==============================================================================

read_sdc constraints.sdc

# ==============================================================================
# 5. Compile settings
# ==============================================================================

# Flatten hierarchy for area / timing (preserve top boundary)
set_app_var compile_seqmap_propagate_constants         true
set_app_var compile_seqmap_propagate_high_effort       true
set_app_var compile_delete_unloaded_sequential_cells   true

# Enable timing-driven compile
set_app_var compile_timing_high_effort_for_negative_slack   true

# ==============================================================================
# 6. Compile
# ==============================================================================

# First pass: map logic
compile_ultra -no_autoungroup

# Incremental compile for timing closure
compile_ultra -no_autoungroup -incremental

# ==============================================================================
# 7. Reports
# ==============================================================================

# Timing reports
report_timing -path full -delay max -nworst 10 -max_paths 20 \
    > ${OUTPUT_DIR}/reports/timing_setup.rpt
report_timing -path full -delay min -nworst 10 -max_paths 20 \
    > ${OUTPUT_DIR}/reports/timing_hold.rpt

# Area report
report_area -hierarchy > ${OUTPUT_DIR}/reports/area.rpt

# Power report (switching activity from simulation VCD recommended for accuracy)
report_power -hierarchy > ${OUTPUT_DIR}/reports/power.rpt

# Design rule violations
report_constraint -all_violators -nosplit > ${OUTPUT_DIR}/reports/violations.rpt

# Cell usage summary
report_cell > ${OUTPUT_DIR}/reports/cells.rpt

# ==============================================================================
# 8. Write outputs
# ==============================================================================

# Gate-level netlist
write -format verilog -hierarchy \
    -output ${OUTPUT_DIR}/aes_decrypt_engine_netlist.v

# DDC (Design Compiler database — for incremental runs)
write -format ddc -hierarchy \
    -output ${OUTPUT_DIR}/aes_decrypt_engine.ddc

# Export final SDC for place-and-route
write_sdc ${OUTPUT_DIR}/aes_decrypt_engine_final.sdc

# SDF for gate-level simulation (optional)
write_sdf ${OUTPUT_DIR}/aes_decrypt_engine.sdf

echo "=========================================================="
echo " Synthesis complete."
echo " Netlist : ${OUTPUT_DIR}/aes_decrypt_engine_netlist.v"
echo " Reports : ${OUTPUT_DIR}/reports/"
echo "=========================================================="

quit
