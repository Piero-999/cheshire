#!/usr/bin/env bash
set -euo pipefail

make chs-sw-all

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VSIM_DIR="$ROOT_DIR/target/sim/vsim"
QHOME="$(dirname "$(dirname "$(which vsim)")")"

#BINARY="${BINARY:-$ROOT_DIR/sw/tests/helloworld.spm.elf}"
BINARY="${BINARY:-$ROOT_DIR/sw/tests/dma_ddr4_bram_256k.spm.spm.elf}"
BOOTMODE="${BOOTMODE:-0}"
PRELMODE="${PRELMODE:-1}"
USE_DRAMSYS="${USE_DRAMSYS:-1}"
RUN_ALL="${RUN_ALL:-0}"
ENABLE_VCD="${ENABLE_VCD:-1}"
VCD_FILE="${VCD_FILE:-$(basename "$BINARY".elf).vcd}"
VCD_RUN="${VCD_RUN:-15 ms}"
DEBUG_PROFILE="${DEBUG_PROFILE:-minimal}"
DEBUG_ARTIFACTS="${DEBUG_ARTIFACTS:-1}"
DEBUG_MOVE_ROOT_LOGS="${DEBUG_MOVE_ROOT_LOGS:-1}"
RUN_TAG="${RUN_TAG:-$(basename "$BINARY" .elf)}"
RUN_TAG="$(echo "$RUN_TAG" | tr -cs '[:alnum:]_.-' '_')"

if [[ ! -f "$BINARY" ]]; then
    echo "[ERROR] Test binary not found: $BINARY"
    exit 1
fi

if [[ ! -f "$VSIM_DIR/elfloader.so" ]]; then
    echo "[INFO] Building $VSIM_DIR/elfloader.so"
    /usr/bin/g++ -shared -fPIC -O2 -m64 -static-libstdc++ -static-libgcc \
        -I"$QHOME/include" \
        "$ROOT_DIR/target/sim/src/elfloader.cpp" \
        -o "$VSIM_DIR/elfloader.so"
fi

export QSIM_VCO_MODE=64
export MTI_VCO_MODE=64

if [[ -f /usr/lib/x86_64-linux-gnu/libstdc++.so.6 ]]; then
    if [[ -n "${LD_PRELOAD:-}" ]]; then
        export LD_PRELOAD="/usr/lib/x86_64-linux-gnu/libstdc++.so.6:$LD_PRELOAD"
    else
        export LD_PRELOAD="/usr/lib/x86_64-linux-gnu/libstdc++.so.6"
    fi
fi

cd "$VSIM_DIR"

if [[ "$DEBUG_ARTIFACTS" == "1" ]]; then
    STAMP="$(date +%Y%m%d_%H%M%S)"
    ARTIFACT_DIR="${ARTIFACT_DIR:-$VSIM_DIR/debug_artifacts/${RUN_TAG}_${STAMP}}"
    mkdir -p "$ARTIFACT_DIR"
    TRANSCRIPT_FILE="$ARTIFACT_DIR/transcript.log"
    VCD_PATH="$ARTIFACT_DIR/$VCD_FILE"
else
    ARTIFACT_DIR=""
    TRANSCRIPT_FILE="${TRANSCRIPT_FILE:-$VSIM_DIR/transcript}"
    VCD_PATH="$VCD_FILE"
fi

DO_CMD=" set SELCFG 4; set USE_DRAMSYS $USE_DRAMSYS; \
set BINARY $BINARY; \
set BOOTMODE $BOOTMODE; \
set PRELMODE $PRELMODE; \
source compile.cheshire_soc.tcl; \
source start.cheshire_soc.tcl;"

if [[ "$RUN_ALL" == "1" ]]; then
    if [[ "$ENABLE_VCD" == "1" ]]; then
        DO_CMD="$DO_CMD; \
            set DEBUG_VCD_FILE {$VCD_PATH}; \
            set DEBUG_VCD_RUN {$VCD_RUN}; \
            set DEBUG_PROFILE {$DEBUG_PROFILE}; \
            source debug_capture.tcl; \
            chs_debug_capture;"
    else
        DO_CMD="$DO_CMD; run -all;"
    fi
else
    DO_CMD="$DO_CMD; \
        #add wave -r /tb_cheshire_soc/fix/dut/gen_cva6_cores[0]/i_core_cva6/*; \
        #delete wave -r /tb_cheshire_soc/fix/dut/gen_cva6_cores[0]/i_core_cva6/ex_stage_i/fpu_gen/*; \
        #delete wave -r /tb_cheshire_soc/fix/dut/gen_cva6_cores[0]/i_core_cva6/ex_stage_i/lsu_i/gen_mmu/*; \
        #delete wave -r /tb_cheshire_soc/fix/dut/gen_cva6_cores[0]/i_core_cva6/ex_stage_i/i_mult/*; \
        #delete wave -r /tb_cheshire_soc/fix/dut/gen_cva6_cores[0]/i_core_cva6/issue_stage_i/issue_read_operands/*; \
        #delete wave -r /tb_cheshire_soc/fix/dut/gen_cva6_cores[0]/i_core_cva6/gen_cache*/*; \
        #delete wave -r /tb_cheshire_soc/fix/dut/gen_cva6_cores[0]/i_core_cva6/csr_regfile_i/*; \
        #delete wave -r /tb_cheshire_soc/fix/dut/gen_cva6_cores[0]/i_core_cva6/gen_perf_counter/*; \
        ##add wave -r /tb_cheshire_soc/fix/dut/gen_dma/i_idma/*; \

        # Solo PC pipeline stages (ID/ISSUE/EX/COMMIT).
        add wave -r /tb_cheshire_soc/fix/dut/gen_cva6_cores[0]/i_core_cva6/id_stage_i/*pc*; \
        add wave -r /tb_cheshire_soc/fix/dut/gen_cva6_cores[0]/i_core_cva6/issue_stage_i/*pc*; \
        add wave -r /tb_cheshire_soc/fix/dut/gen_cva6_cores[0]/i_core_cva6/ex_stage_i/*pc*; \
        add wave -r /tb_cheshire_soc/fix/dut/gen_cva6_cores[0]/i_core_cva6/commit_stage_i/*pc*; \
        # AXI significativi per capire write verso BRAM (AW/W/B + remap path).
        add wave /tb_cheshire_soc/fix/dut/axi_ext_slv_req_o; \
        add wave /tb_cheshire_soc/fix/dut/axi_ext_slv_rsp_i; \
        add wave /tb_cheshire_soc/fix/dut/axi_llc_cut_req; \
        add wave /tb_cheshire_soc/fix/dut/axi_llc_cut_rsp; \
        add wave /tb_cheshire_soc/fix/dut/axi_llc_remap_req; \
        add wave /tb_cheshire_soc/fix/dut/axi_llc_remap_rsp; \
        add wave /tb_cheshire_soc/fix/dut/axi_llc_mst_req_o; \
        add wave /tb_cheshire_soc/fix/dut/axi_llc_mst_rsp_i;
        add wave /tb_cheshire_soc/fix/dut/gen_cva6_cores[0]/i_core_cva6/csr_regfile_i/*; \
        run -all;"
fi

echo "[INFO] Launching VSIM with:"
echo "       BINARY=$BINARY BOOTMODE=$BOOTMODE PRELMODE=$PRELMODE USE_DRAMSYS=$USE_DRAMSYS RUN_ALL=$RUN_ALL ENABLE_VCD=$ENABLE_VCD VCD_FILE=$VCD_FILE VCD_RUN=$VCD_RUN DEBUG_PROFILE=$DEBUG_PROFILE"
if [[ "$DEBUG_ARTIFACTS" == "1" ]]; then
    echo "       ARTIFACT_DIR=$ARTIFACT_DIR"
fi

vsim -64  -do "$DO_CMD" -t 1ns -l "$TRANSCRIPT_FILE"

if [[ "$DEBUG_ARTIFACTS" == "1" ]]; then
    for f in trace_hart_0.log trace_hart_0_commit.log DRAMSysRecordable0_ddr4-example_example_ch0.tdb; do
        if [[ -f "$f" ]]; then
            if [[ "$DEBUG_MOVE_ROOT_LOGS" == "1" ]]; then
                mv -f "$f" "$ARTIFACT_DIR/$f"
            else
                cp -f "$f" "$ARTIFACT_DIR/$f"
            fi
        fi
    done
    echo "[INFO] Debug artifacts collected in: $ARTIFACT_DIR"
fi