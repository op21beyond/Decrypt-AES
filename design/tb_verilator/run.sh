#!/usr/bin/env bash
# =============================================================================
# File        : run.sh
# Project     : AES Decryption Engine IP
# Description : Verilator compile and simulation script.
#               Run from design/tb_verilator/:
#                 chmod +x run.sh && ./run.sh
#
# Options:
#   -clean : remove out/ and gen_mem before rebuilding from scratch
#
# Output directory layout (created automatically):
#   out/obj_dir/            Verilator-generated C++ model + compiled binary
#   out/dump.fst            Simulation waveform (open with GTKWave)
#   out/verilator_console.log  Full simulation stdout/stderr capture
#
# Intermediary files (kept across -clean for speed):
#   mem_init.hex            Memory image loaded by $readmemh — regenerated
#                           automatically when gen_mem.c or host_software/*.c
#                           changes, but NOT removed on -clean.
#   gen_mem                 C helper binary; removed on -clean.
# =============================================================================

set -euo pipefail

TB_DIR="$(cd "$(dirname "$0")" && pwd)"
RTL_DIR="${TB_DIR}/../rtl"
LEGACY_TB_DIR="${TB_DIR}/../tb"
OUT_DIR="${TB_DIR}/out"
OBJ_DIR="${OUT_DIR}/obj_dir"

# -----------------------------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------------------------
CLEAN=0
for arg in "$@"; do
    case "$arg" in
        -clean) CLEAN=1 ;;
    esac
done

if [ "$CLEAN" -eq 1 ]; then
    echo "[run.sh] Cleaning Verilator artifacts..."
    rm -rf "${OUT_DIR}" "${TB_DIR}/gen_mem"
fi

mkdir -p "${OUT_DIR}"

# -----------------------------------------------------------------------------
# Environment checks
# -----------------------------------------------------------------------------
check_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "[run.sh] ERROR: '$1' not found in PATH. $2"
        exit 1
    fi
}

check_tool verilator "Install Verilator 5.x (see README.md)."
check_tool gcc       "Install build-essential: sudo apt-get install build-essential"
check_tool g++       "Install build-essential: sudo apt-get install build-essential"
check_tool make      "Install make: sudo apt-get install make"

# Verilator version check (requires 5.x for --timing)
VLT_MAJOR=$(verilator --version 2>&1 | awk '/^Verilator/{print $2}' | cut -d. -f1)
if [ "${VLT_MAJOR:-0}" -lt 5 ]; then
    echo "[run.sh] ERROR: Verilator 5.x required (found: $(verilator --version 2>&1 | head -1))"
    exit 1
fi

# GCC C++20 support check (required for Verilator --timing coroutines)
if ! echo "" | g++ -std=c++20 -x c++ - -o /dev/null 2>/dev/null; then
    echo "[run.sh] ERROR: g++ does not support -std=c++20. GCC 11+ required."
    exit 1
fi

# -----------------------------------------------------------------------------
# Generate memory image (only when sources are newer than the hex file)
# -----------------------------------------------------------------------------
GEN_EXE="${TB_DIR}/gen_mem"
GEN_HEX="${TB_DIR}/mem_init.hex"
GEN_SRC="${LEGACY_TB_DIR}/gen_mem.c"

if [ ! -f "$GEN_HEX" ] || \
   [ ! -f "$GEN_EXE" ] || \
   [ "$GEN_SRC" -nt "$GEN_HEX" ] || \
   [ "${TB_DIR}/../../host_software/aes128_ctr.c" -nt "$GEN_HEX" ] || \
   [ "${TB_DIR}/../../host_software/crc32.c"      -nt "$GEN_HEX" ]; then
    echo "[run.sh] Building gen_mem..."
    gcc -O2 -std=c99 \
        -I"${TB_DIR}/../../host_software" \
        -o "${GEN_EXE}" \
        "${GEN_SRC}" \
        "${TB_DIR}/../../host_software/aes128_ctr.c" \
        "${TB_DIR}/../../host_software/crc32.c"
    echo "[run.sh] Generating mem_init.hex..."
    (
        cd "${TB_DIR}"
        "${GEN_EXE}"
    )
fi

# -----------------------------------------------------------------------------
# RTL file list
# -----------------------------------------------------------------------------
RTL_FILES=(
    "${RTL_DIR}/aes_decrypt_engine.v"
    "${RTL_DIR}/aes_decrypt_mem_top.v"
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
    "${RTL_DIR}/util/sram_2p.v"
    "${RTL_DIR}/util/sram_2p_32x64.v"
    "${RTL_DIR}/util/sram_2p_32x72.v"
    "${LEGACY_TB_DIR}/fake_mem.v"
    "${TB_DIR}/tb_top_verilator.sv"
)

# -----------------------------------------------------------------------------
# Verilator build
#
# Warning policy
# ──────────────
# Suppressed (harmless, must-ignore):
#   TIMESCALEMOD  `timescale declared in multiple source files — precision
#                 mismatch is irrelevant for functional simulation.
#   DECLFILENAME  fake_mem.v lives under tb/ — module/filename mismatch is
#                 intentional (shared with NCVerilog TB).
#
# Suppressed (review before permanently ignoring):
#   LITENDIAN     Some RTL uses [0:N-1] vectors.  These generate no functional
#                 issue but should be reviewed and converted to [N-1:0] when
#                 possible to improve Verilator compatibility.
#
# NOT suppressed (surface as errors):
#   WIDTH, UNOPTFLAT, CASEINCOMPLETE, STMTDLY — these indicate real RTL issues
#   and must be fixed rather than silenced.
#
# Assertion note (item 4 from code review):
#   RTL assertions are guarded by `ifdef ENABLE_ASSERTIONS.  To enable them
#   in this flow add: -DENABLE_ASSERTIONS --assert
#   Currently disabled to avoid false positives from unguarded assert paths.
# -----------------------------------------------------------------------------
echo "[run.sh] Building Verilator model..."
verilator \
    --sv \
    --timing \
    --trace-fst \
    --build \
    --cc \
    --exe \
    --top-module tb_top_verilator \
    --Mdir "${OBJ_DIR}" \
    -CFLAGS "-std=c++20" \
    -I"${RTL_DIR}" \
    -I"${RTL_DIR}/inc" \
    -Wno-TIMESCALEMOD \
    -Wno-DECLFILENAME \
    -Wno-LITENDIAN \
    "${RTL_FILES[@]}" \
    "${TB_DIR}/tb_dpi.cpp"

# -----------------------------------------------------------------------------
# Run simulation
# -----------------------------------------------------------------------------
echo "[run.sh] Running Verilator simulation..."
(
    cd "${TB_DIR}"
    "${OBJ_DIR}/Vtb_top_verilator"
) 2>&1 | tee "${OUT_DIR}/verilator_console.log"

echo "[run.sh] Done."
echo "[run.sh] Log  : ${OUT_DIR}/verilator_console.log"
echo "[run.sh] Waves: ${OUT_DIR}/dump.fst"

if grep -q "ALL TESTS PASSED" "${OUT_DIR}/verilator_console.log"; then
    echo "[run.sh] *** PASS ***"
else
    echo "[run.sh] *** FAIL — see ${OUT_DIR}/verilator_console.log ***"
    exit 1
fi
