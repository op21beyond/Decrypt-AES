#!/usr/bin/env bash
# =============================================================================
# File        : run.sh
# Project     : AES Decryption Engine IP
# Company     : SSVD
# Description : NCVerilog (Xcelium) compile and simulation script.
#               Run from design/tb/:
#                 chmod +x run.sh && ./run.sh
#
# Options (set via environment or command-line flags):
#   -nofsdb   : use VCD dump instead of FSDB (if Novas/Verdi not available)
#   -clean    : remove INCA_libs and intermediate files before compiling
# =============================================================================

set -e

TB_DIR="$(cd "$(dirname "$0")" && pwd)"
RTL_DIR="${TB_DIR}/../rtl"

NOFSDB=0
CLEAN=0
for arg in "$@"; do
    case "$arg" in
        -nofsdb) NOFSDB=1 ;;
        -clean)  CLEAN=1  ;;
    esac
done

if [ "$CLEAN" -eq 1 ]; then
    echo "[run.sh] Cleaning intermediate files..."
    rm -rf INCA_libs ncvlog.log ncelab.log ncsim.log irun.log xrun.log
fi

# Generate memory image if not present (or if gen_mem sources are newer)
GEN_EXE="${TB_DIR}/gen_mem"
GEN_HEX="${TB_DIR}/mem_init.hex"
if [ ! -f "$GEN_HEX" ] || \
   [ "$GEN_EXE" -nt "$GEN_HEX" 2>/dev/null ] || \
   [ "${TB_DIR}/gen_mem.c" -nt "$GEN_HEX" ]; then
    echo "[run.sh] Building gen_mem..."
    gcc -O2 -std=c99 \
        -I"${TB_DIR}/../../host_software" \
        -o "${GEN_EXE}" \
        "${TB_DIR}/gen_mem.c" \
        "${TB_DIR}/../../host_software/aes128_ctr.c" \
        "${TB_DIR}/../../host_software/crc32.c"
    echo "[run.sh] Generating mem_init.hex..."
    cd "$TB_DIR" && "${GEN_EXE}"
    cd "$TB_DIR"
fi

# ---------------------------------------------------------------------------
# Source file list
# ---------------------------------------------------------------------------
RTL_FILES=(
    "${RTL_DIR}/aes_decrypt_engine.v"
    "${RTL_DIR}/aes_decrypt_regfile.v"
    "${RTL_DIR}/aes_decrypt_ctrl.v"
    "${RTL_DIR}/aes_decrypt_desc_fetch.v"
    "${RTL_DIR}/aes_decrypt_input_ctrl.v"
    "${RTL_DIR}/aes_decrypt_output_ctrl.v"
    "${RTL_DIR}/aes_decrypt_writeback.v"
    "${RTL_DIR}/aes_decrypt_axi_mgr.v"
    "${RTL_DIR}/crypto/aes128_ctr_top.v"
    "${RTL_DIR}/crypto/aes128_enc_pipe.v"
    "${RTL_DIR}/crypto/aes128_key_sched.v"
    "${RTL_DIR}/util/crc32_engine.v"
    "${RTL_DIR}/util/sync_fifo.v"
    "${TB_DIR}/fake_mem.v"
    "${TB_DIR}/tb_top.v"
)

# ---------------------------------------------------------------------------
# Compile and simulate
# ---------------------------------------------------------------------------
DEFINES="+define+ENABLE_ASSERTIONS"
if [ "$NOFSDB" -eq 1 ]; then
    DEFINES="${DEFINES} +define+NOFSDB"
fi

# Novas FSDB PLI library (update path if Verdi is installed elsewhere)
FSDB_PLI=""
if [ "$NOFSDB" -eq 0 ] && [ -n "$VERDI_HOME" ]; then
    FSDB_PLI="-loadpli1 ${VERDI_HOME}/share/PLI/IUS/LINUX64/novas.pli:novas_pli_boot"
fi

echo "[run.sh] Running NCVerilog..."
ncverilog -sv \
    +access+r \
    +incdir+"${RTL_DIR}/inc" \
    "${RTL_FILES[@]}" \
    ${DEFINES} \
    ${FSDB_PLI} \
    -timescale 1ns/1ps \
    +notimingchecks \
    -log sim.log \
    2>&1 | tee ncsim_console.log

echo "[run.sh] Done.  Log: sim.log"
if grep -q "ALL TESTS PASSED" ncsim_console.log; then
    echo "[run.sh] *** PASS ***"
else
    echo "[run.sh] *** FAIL — see ncsim_console.log ***"
    exit 1
fi
