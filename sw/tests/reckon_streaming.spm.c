// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// DDR4 -> BRAM -> ReckOn streaming test (CHECKPOINT 2, stream_ctrl_fsm2).
//
// Bring-up dataset: this test fabricates its own tiny synthetic AER blocks in DDR4
// (a handful of spikes + a label + end-of-sample per "sample", BATCH_SIZE = 1 sample
// per BRAM half) instead of loading a real dataset. This is enough to exercise the
// whole pipeline end-to-end and observe consumed/fill_cnt/underrun/overrun/infer_count
// on real hardware, but the network has NOT been given trained weights or a tuned
// SPI_ALPHA_CONF/threshold/learning-rate config -
// infer_count here is not meaningful, only the *streaming plumbing* is being tested.
//
// SPI bring-up (reckon_spi_bringup below) is new glue: it drives ReckOn's custom
// SPI_slave frame protocol
// (hw/axi_reckon/rtl/reckon/spi_slave.v) through Cheshire's existing SPI host DIF
// (the same one used by sw/lib/hal/spi_s25fs512s.c / spi_sdcard.c). It has not been
// exercised on real hardware yet - if the run below hangs forever after "NEW_EPOCH"
// (consumed/fill_cnt never advance), check this first with a scope/ILA on SCK/MOSI.
// ReckOn's SPI slave takes CS0 (spi_cs_soc[0], wired in xilinx_zcu102_reckon_chs_top.sv):
// the active-low chip select resynchronises its frame counter on every transaction, so a
// misaligned frame can no longer desync every following one.

#include "regs/cheshire.h"
#include "dif/clint.h"
#include "dif/uart.h"
#include "dif/dma.h"
#include "params.h"
#include "util.h"
#include "printf.h"
#include "sw/device/lib/dif/dif_spi_host.h"
#include <stdint.h>

// ReckOn network configuration, ported from Barocci's "works firmware"
// (branch reckon_cheshire_bad, sw/include/reckon/). These headers *define* the
// SPI config vector and the weight matrices, so include them in exactly one TU.
#include "reckon/reckon_params_vec.h"   // reckon_spi_conf[], N_*_NEUR, KAPPA, ALPHALSB, THRESHOLD
#include "reckon/winp.h"                // int8_t winp[N_INP][N_REC]
#include "reckon/wrec.h"                // int8_t wrec[N_REC][N_REC]
#include "reckon/wout.h"                // int8_t wout[N_REC][N_OUT]
#include "reckon/reckon_dataset_ref.h"  // ref_sample[][] : Barocci ESA/w200 train samples

// ---------------------------------------------------------------------------
// Memory map
// ---------------------------------------------------------------------------
#define DRAM_BASE_ADDR      0x80000000ull
#define BRAM_BASE_ADDR      0x48000000ull
#define RECKON_REG_BASE     0x40000000ull

#define HALF_WORDS          32768u                  // one BRAM half = one batch (HALF_BATCH=1)
#define HALF_BYTES          (HALF_WORDS * 4u)

// ---------------------------------------------------------------------------
// ReckOn register map (offsets from RECKON_REG_BASE)
// ---------------------------------------------------------------------------
#define IN_REG0_INFER_COUNT    0x00u   // R
#define IN_REG1_BATCH_DONE     0x08u   // R, bit0
#define IN_REG2_EPOCH_DONE     0x10u   // R, bit0
#define IN_REG3_STREAM_STATUS  0x18u   // R, see SS_* below

#define OUT_REG0_BATCH_SIZE    0x20u   // W, [11:0], samples per BRAM half (here: 1)
#define OUT_REG1_N_EPOCHS      0x28u   // W, [11:0]
#define OUT_REG2_N_SAMPLES     0x30u   // W, [11:0]
#define OUT_REG3_DO_EPROP      0x38u   // W, [2:0]
#define OUT_REG4_NEW_EPOCH     0x40u   // W, bit0, strobe
#define OUT_REG5_RESERVED      0x48u   // W, ignored by HW (was manual NEW_BATCH)
#define OUT_REG6_TEST          0x50u   // W, bit0, level
#define OUT_REG7_STREAM_CTRL   0x58u   // W, bit0 STOP (strobe) + stream_ctrl below - NOT READABLE

// out_reg[7] bit layout (shadow-only, axi_rf never returns it on read-back)
#define SC_STOP_BIT        0u
#define SC_FILL_TGL0_BIT   1u
#define SC_FILL_TGL1_BIT   2u
#define SC_EXHAUSTED_BIT   3u

// in_reg[3] (stream_status) bit layout
#define SS_OWNER_MASK       0x3u        // bit0/bit1 = owner[0]/owner[1]
#define SS_READ_HALF_BIT    2u
#define SS_NEED_FILL_BIT    4u
#define SS_UNDERRUN_BIT     5u
#define SS_OVERRUN_BIT      6u
#define SS_CONSUMED_SHIFT   8u
#define SS_CONSUMED_MASK    0xFFu
#define SS_FILLCNT_SHIFT    16u
#define SS_FILLCNT_MASK     0xFFu
#define SS_VERSION_SHIFT    24u
#define SS_VERSION_MASK     0xFFu
#define SS_VERSION_FSM2     0xA6u       // 0xA5 = old v1 FSM, 0xDEADBEEF = no streaming at all

static inline volatile uint32_t *reckon_reg(uint32_t off) {
    return (volatile uint32_t *)(RECKON_REG_BASE + off);
}
static inline uint32_t reckon_rd(uint32_t off) { fence(); return *reckon_reg(off); }
static inline void reckon_wr(uint32_t off, uint32_t v) { *reckon_reg(off) = v; fence(); }

// ---------------------------------------------------------------------------
// ReckOn SPI bring-up
// ---------------------------------------------------------------------------
// Frame format (hw/axi_reckon/rtl/reckon/spi_slave.v):
//   32-bit command word, MSB first: {R/Wb(1), code[2:0], num_write[11:0], addr[15:0]}
//     R/Wb = 0 for write. code = 3'b000 (cfg) addresses the registers below.
//   followed by `num_write` 32-bit data words, MSB first.
//   Each cfg register occupies exactly one data word (no address auto-increment),
//   so multi-register programming = one full frame per register.
#define RECKON_SPI_CSID           0u   // CS0 -> ReckOn's CSN; see file header note
#define RECKON_SPI_CODE_CFG       0x0u
#define RECKON_SPI_ADDR_LABEL_DELAY     37u
#define RECKON_SPI_ADDR_CYCLES_PER_TICK 64u

// Bring-up-only tuning (NOT trained/tuned values - see file header):
#define RECKON_TICK_PERIOD   15u   // clk15 cycles per algorithmic tick (~1 us @ 15 MHz)
#define RECKON_LABEL_DELAY   10u   // ticks; must be >= last spike tick in the synthetic sample below

// SPI_slave command codes (bits [30:28] of the command word). code 0 = cfg register.
#define RECKON_SPI_CODE_NEURMEM  0x1u   // neuron memory (alpha + threshold)
#define RECKON_SPI_CODE_WINP     0x3u   // input weights
#define RECKON_SPI_CODE_WREC     0x4u   // recurrent weights
#define RECKON_SPI_CODE_WOUT     0x5u   // output weights
#define RECKON_SPI_ADDR_EN_CONF  0u     // SPI_EN_CONF gate (open before / close after SRAM writes)

#define RK_MAX(a, b)  (((a) > (b)) ? (a) : (b))
// NOTE: faithful port of Barocci's CEIL macro - it returns n or n+1 (it does NOT
// divide by m). Kept identical so the num_write geometry matches the working firmware.
#define RK_CEIL(n, m) ((((n) % (m)) != 0) ? ((n) + 1) : (n))

// Bisection knob: 0 = program only mode/config registers (proven cfg_write path),
// skip neuron-memory + weight SRAM writes. Those multi-word frames are the only
// unverified new code and a prime suspect for desyncing ReckOn's free-running SPI
// slave frame counter (which stalls the fill handshake). Weights are NOT needed for
// TIME_TICK liveness. Set to 1 to restore the full network programming.
#define RECKON_PROGRAM_WEIGHTS 0

// One SPI_slave frame: a 32-bit command/address word followed by `ndata` 32-bit
// payload words, every word transmitted MSB-byte first (matches spi_slave.v and the
// cfg path proven on ILA). One CS-framed transaction; the DIF derives the length.
static int reckon_spi_frame(const dif_spi_host_t *host, uint32_t cmd,
                            const uint32_t *data, uint32_t ndata) {
    uint8_t buf[128];
    uint32_t nbytes = 4u * (1u + ndata);
    if (nbytes > sizeof(buf)) return 1;

    uint32_t bi = 0;
    buf[bi++] = (uint8_t)(cmd >> 24); buf[bi++] = (uint8_t)(cmd >> 16);
    buf[bi++] = (uint8_t)(cmd >> 8);  buf[bi++] = (uint8_t)(cmd);
    for (uint32_t i = 0; i < ndata; i++) {
        uint32_t w = data[i];
        buf[bi++] = (uint8_t)(w >> 24); buf[bi++] = (uint8_t)(w >> 16);
        buf[bi++] = (uint8_t)(w >> 8);  buf[bi++] = (uint8_t)(w);
    }

    dif_spi_host_segment_t seg = {
        .type = kDifSpiHostSegmentTypeTx,
        .tx = {.width = kDifSpiHostWidthStandard, .buf = buf, .length = nbytes},
    };
    return (dif_spi_host_transaction(host, RECKON_SPI_CSID, &seg, 1) == kDifOk) ? 0 : 1;
}

static int reckon_spi_cfg_write(const dif_spi_host_t *host, uint16_t addr, uint32_t value) {
    uint32_t cmd = ((uint32_t)(RECKON_SPI_CODE_CFG & 0x7u) << 28) | (1u << 16) | addr;
    return reckon_spi_frame(host, cmd, &value, 1);
}

// Full ReckOn network programming, ported from Barocci reckon-chs-ESA.c "works
// firmware". This is the piece the streaming bring-up was missing: without the mode
// bits, neuron counts, LFSR seeds, thresholds and weights the SNN never completes a
// compute step, so TIMING_ERROR_RDY stays low, aer_decoder stops issuing TIME_TICK
// and the stream stalls with consumed=0. All SRAM writes must happen with SPI_EN_CONF
// asserted (open at the start, close at the end).
static int reckon_program_network(const dif_spi_host_t *host) {
    uint32_t data[64] __attribute__((unused));

    // --- open config window ---
    CHECK_CALL(reckon_spi_cfg_write(host, RECKON_SPI_ADDR_EN_CONF, 1));

    // --- 63 config registers (modes/FP_LOC/regul/thresholds/seeds/LR/neuron counts) ---
    for (int i = 0; i < NPARAM_RECKON; i++) {
        uint16_t addr = (uint16_t)(reckon_spi_conf[2 * i] & 0xFFFFu);
        uint32_t val  = reckon_spi_conf[2 * i + 1];
        CHECK_CALL(reckon_spi_cfg_write(host, addr, val));
    }

    // This streaming test overrides Barocci's shipped 4/4 timing with its own geometry
    // (still inside the config window so the writes land).
    CHECK_CALL(reckon_spi_cfg_write(host, RECKON_SPI_ADDR_CYCLES_PER_TICK, RECKON_TICK_PERIOD));
    CHECK_CALL(reckon_spi_cfg_write(host, RECKON_SPI_ADDR_LABEL_DELAY, RECKON_LABEL_DELAY));

#if RECKON_PROGRAM_WEIGHTS
    // --- neuron memory: per-neuron {alpha (ALPHALSB), threshold (THRESHOLD)} ---
    {
        uint32_t num_rw = RK_MAX(N_REC_NEUR, N_INP_NEUR);
        num_rw = RK_CEIL(num_rw, 2);
        uint32_t spi_data = ((ALPHALSB & 0xFFF) << 20) | ((THRESHOLD) << 4);
        uint32_t cmd = ((uint32_t)RECKON_SPI_CODE_NEURMEM << 28) | ((num_rw * 2) << 16);
        uint32_t k = 0;
        for (uint32_t n = 0; n < (num_rw >> 1); n++) {
            data[k++] = 0; data[k++] = 0; data[k++] = 0; data[k++] = spi_data;
        }
        CHECK_CALL(reckon_spi_frame(host, cmd, data, k));
    }

    // --- input weights (winp), code 0b011, packed 4 int8 per word ---
    {
        uint32_t num_rw = (RK_CEIL(N_REC_NEUR, 4) >> 2) & 0xFFF;
        for (int n = 0; n < N_INP_NEUR; n++) {
            uint32_t cmd = ((uint32_t)RECKON_SPI_CODE_WINP << 28) | (num_rw << 16) | ((uint32_t)n << 6);
            uint32_t k = 0; int p1;
            for (p1 = 0; p1 < N_REC_NEUR - 3; p1 += 4) {
                uint32_t d = 0;
                for (int p2 = 0; p2 < 4; p2++) d |= ((uint32_t)winp[n][p1 + p2] & 0xFF) << (p2 * 8);
                data[k++] = d;
            }
            if ((N_REC_NEUR & 0x3) != 0) {
                uint32_t d = 0;
                for (int r1 = 0; r1 < (N_REC_NEUR & 0x3); r1++) d |= ((uint32_t)winp[n][r1 + p1] & 0xFF) << (r1 * 8);
                data[k++] = d;
            }
            CHECK_CALL(reckon_spi_frame(host, cmd, data, k));
        }
    }

    // --- recurrent weights (wrec), code 0b100 ---
    {
        uint32_t num_rw = (RK_CEIL(N_REC_NEUR, 4) >> 2) & 0xFFF;
        for (int n = 0; n < N_REC_NEUR; n++) {
            uint32_t cmd = ((uint32_t)RECKON_SPI_CODE_WREC << 28) | (num_rw << 16) | ((uint32_t)n << 6);
            uint32_t k = 0; int p1;
            for (p1 = 0; p1 < N_REC_NEUR - 3; p1 += 4) {
                uint32_t d = 0;
                for (int p2 = 0; p2 < 4; p2++) d |= ((uint32_t)wrec[n][p1 + p2] & 0xFF) << (p2 * 8);
                data[k++] = d;
            }
            if ((N_REC_NEUR & 0x3) != 0) {
                uint32_t d = 0;
                for (int r1 = 0; r1 < (N_REC_NEUR & 0x3); r1++) d |= ((uint32_t)wrec[n][r1 + p1] & 0xFF) << (r1 * 8);
                data[k++] = d;
            }
            CHECK_CALL(reckon_spi_frame(host, cmd, data, k));
        }
    }

    // --- output weights (wout), code 0b101 (with N_OUT=2 this ports Barocci's quirk:
    //     num_rw computes to 0, so only the SRAM address word is sent per rec neuron) ---
    {
        uint32_t num_rw = (RK_CEIL(N_OUT_NEUR, 4) >> 2) & 0xFFF;
        for (int n = 0; n < N_REC_NEUR; n++) {
            uint32_t cmd = ((uint32_t)RECKON_SPI_CODE_WOUT << 28) | (num_rw << 16) | ((uint32_t)n << 2);
            uint32_t k = 0; int p1;
            for (p1 = 0; p1 < N_OUT_NEUR - 3; p1 += 4) {
                uint32_t d = 0;
                for (int p2 = 0; p2 < 4; p2++) d |= ((uint32_t)wout[n][p1 + p2] & 0xFF) << (p2 * 8);
                data[k++] = d;
            }
            if ((N_REC_NEUR & 0x3) != 0) {
                uint32_t d = 0;
                for (int r1 = 0; r1 < (N_OUT_NEUR & 0x3); r1++) d |= ((uint32_t)wout[n][r1 + p1] & 0xFF) << (r1 * 8);
                data[k++] = d;
            }
            CHECK_CALL(reckon_spi_frame(host, cmd, data, k));
        }
    }
#endif // RECKON_PROGRAM_WEIGHTS

    // --- close config window ---
    CHECK_CALL(reckon_spi_cfg_write(host, RECKON_SPI_ADDR_EN_CONF, 0));
    return 0;
}

static int reckon_spi_bringup(uint64_t core_freq) {
    dif_spi_host_t host;
    mmio_region_t spi_host_base = (mmio_region_t){.base = (void *)&__base_spih};
    CHECK_CALL(dif_spi_host_init(spi_host_base, &host));
    dif_spi_host_reset(&host);

    dif_spi_host_config_t cfg = {
        .spi_clock = 1 * 1000 * 1000,   // 1 MHz: conservative for a first bring-up
        .peripheral_clock_freq_hz = (uint32_t)core_freq,
        .chip_select = {.idle = 0xF, .lead = 0xF, .trail = 0xF},
        .full_cycle = false,
        .cpha = false,                  // matches spi_slave.v: sample MOSI on posedge SCK
        .cpol = false,
    };
    CHECK_CALL(dif_spi_host_configure_cs(&host, cfg, RECKON_SPI_CSID));
    dif_spi_host_enable(&host, 1);
    CHECK_CALL(dif_spi_host_output_set_enabled(&host, 1));

    // Program the full ReckOn network (mode bits, neuron counts, LFSR seeds,
    // thresholds/alpha, weights) + this test's timing override. This is the piece the
    // original 2-register bring-up was missing and the reason TIME_TICK never advanced
    // (see reckon_program_network above). RECKON_TICK_PERIOD/RECKON_LABEL_DELAY are
    // applied inside it, overriding Barocci's shipped 4/4.
    CHECK_CALL(reckon_program_network(&host));
    return 0;
}

// ---------------------------------------------------------------------------
// Synthetic bring-up dataset
// ---------------------------------------------------------------------------
// AER word: [31:28] ignored, [27:24] code, [23:12] data, [11:0] tick.
#define AER_CODE_SPIKE  0x3u
#define AER_CODE_LABEL  0x2u
#define AER_CODE_EOS    0x1u

#define N_SPIKES_PER_SAMPLE  4u             // ticks 0..3, must stay < RECKON_LABEL_DELAY
#define N_HALVES_TOTAL       4u             // total BRAM halves streamed this run

// Isolation experiment. 1 = "Barocci mode": all samples in ONE half with
// BATCH_SIZE == N_SAMPLES, so aer_decoder reaches END_B only once and goes straight
// to END_E (cnt_sample_epoch == N_SAMPLES) -- our stream_ctrl_fsm2 new_batch grant is
// never exercised, reproducing the control flow of the working Barocci firmware.
// 0 = normal double-buffered streaming (one sample per half, grant per batch).
#define RECKON_BAROCCI_MODE  0

static inline uint32_t aer_word(uint32_t code, uint32_t data8, uint32_t tick) {
    return (code << 24) | ((data8 & 0xFFu) << 12) | (tick & 0xFFFu);
}

// Fills exactly HALF_WORDS words in DDR4 with one BATCH_SIZE=1 sample: a few spikes,
// one label, one end-of-sample, then no-op padding (code=0) to the half boundary.
// Block is exactly one BRAM half, and BATCH_SIZE=1 divides it evenly.
__attribute__((unused))
static void gen_synthetic_block(volatile uint32_t *blk) {
    unsigned idx = 0;
    for (unsigned k = 0; k < N_SPIKES_PER_SAMPLE; k++)
        blk[idx++] = aer_word(AER_CODE_SPIKE, (uint8_t)k, k);
    blk[idx++] = aer_word(AER_CODE_LABEL, 0, RECKON_LABEL_DELAY);
    blk[idx++] = aer_word(AER_CODE_EOS, 0, 0);
    for (; idx < HALF_WORDS; idx++)
        blk[idx] = 0;   // no-op: read and discarded, does not advance algorithmic time
}

// Loads one real reference sample (Barocci ESA/w200 train, label word already inserted
// at LABEL_DELAY) into a BRAM half, padded with no-op (code 0) words to HALF_WORDS.
// One sample per half (BATCH_SIZE = 1), same layout gen_synthetic_block produced.
__attribute__((unused))
static void load_ref_block(volatile uint32_t *blk, unsigned s) {
    unsigned idx = 0;
    for (; idx < ref_sample_len[s] && idx < HALF_WORDS; idx++)
        blk[idx] = ref_sample[s][idx];
    for (; idx < HALF_WORDS; idx++)
        blk[idx] = 0;
}

// ---------------------------------------------------------------------------
// Streaming loop
// ---------------------------------------------------------------------------
static uint32_t shadow = 0;   // out_reg[7] is not readable: SW must own a shadow copy
static uint32_t fills = 0;    // local count of fill_tgl toggles emitted so far
static uint64_t dram_word_off = 0;

// Copies the next HALF_WORDS from DDR4 into BRAM half `h` (Option A: CVA6/CPU memcpy;
// swap for sys_dma_blk_memcpy for Option B/iDMA).
static void fill_half_from_ddr(unsigned h) {
    volatile uint32_t *bram = (volatile uint32_t *)(BRAM_BASE_ADDR + (uint64_t)h * HALF_BYTES);
    volatile uint32_t *src  = (volatile uint32_t *)(DRAM_BASE_ADDR + dram_word_off * 4u);
    for (unsigned i = 0; i < HALF_WORDS; i++)
        bram[i] = src[i];
    // The writes above are POSTED on the AXI path: fence() orders them but does NOT
    // guarantee they have reached the BRAM. Without this read-back ReckOn was granted a
    // half whose data had not landed yet, decoded garbage (code != 3 -> the READM
    // default branch) and so raced through the half at full speed without ever ticking.
    // It only bit while streaming: the *next* half's 32768-word copy keeps the write
    // path busy and delays the previous half from draining. Reading the LAST word
    // written forces every preceding write to the same slave to complete first.
    volatile uint32_t sink = bram[HALF_WORDS - 1];
    (void)sink;
    fence();
    dram_word_off += HALF_WORDS;
}

// Grants half `h` to ReckOn: fill it, invert fill_tgl[h], then wait for the FSM's ack
// (fill_cnt advancing) before returning. This is the only place fill_tgl is touched.
static void grant_half(unsigned h) {
    fill_half_from_ddr(h);
    fence();   // make the copy visible before ReckOn is told about it
    shadow ^= (1u << (h == 0 ? SC_FILL_TGL0_BIT : SC_FILL_TGL1_BIT));
    reckon_wr(OUT_REG7_STREAM_CTRL, shadow);
    fills++;
    while (((reckon_rd(IN_REG3_STREAM_STATUS) >> SS_FILLCNT_SHIFT) & SS_FILLCNT_MASK) !=
           (fills & SS_FILLCNT_MASK))
        ;
}

int main(void) {
    volatile uint32_t *scratch = reg32(&__base_regs, CHESHIRE_SCRATCH_3_REG_OFFSET);
    uint32_t rtc_freq = *reg32(&__base_regs, CHESHIRE_RTC_FREQ_REG_OFFSET);
    uint64_t core_freq = clint_get_core_freq(rtc_freq, 2500);
    uart_init(&__base_uart, core_freq, __BOOT_BAUDRATE);

    *scratch = 0xB00B0001u;

    // Step 0: confirm the bitstream on the FPGA actually contains stream_ctrl_fsm2
    // before doing anything else (in_reg[3][31:24]).
    uint32_t version = (reckon_rd(IN_REG3_STREAM_STATUS) >> SS_VERSION_SHIFT) & SS_VERSION_MASK;
    printf("stream_status version marker: 0x%02X (expect 0x%02X)\n", version, SS_VERSION_FSM2);
    uart_write_flush(&__base_uart);
    if (version != SS_VERSION_FSM2) {
        printf("ERROR: wrong/missing streaming FSM in this bitstream.\n");
        uart_write_flush(&__base_uart);
        return 1;
    }

    // Step 1: SPI bring-up - mandatory, see reckon_spi_bringup() above.
    if (reckon_spi_bringup(core_freq)) {
        printf("ERROR: ReckOn SPI bring-up failed.\n");
        uart_write_flush(&__base_uart);
        return 1;
    }

#if RECKON_BAROCCI_MODE
    // ---- Isolation experiment: reproduce Barocci's control flow on our bitstream ----
    // All reference samples concatenated into HALF 0 only, BATCH_SIZE == N_SAMPLES.
    // aer_decoder does END_S->READM between samples and hits END_B just once, at the
    // end, where cnt_sample_epoch == N_SAMPLES routes it directly to END_E. The
    // new_batch grant from stream_ctrl_fsm2 is therefore never needed.
    //   -> if ReckOn ticks/consumes here, the blocker is OUR END_B grant handshake;
    //   -> if it still does not, the blocker is upstream (SPI/config), not streaming.
    {
        volatile uint32_t *blk = (volatile uint32_t *)DRAM_BASE_ADDR;
        unsigned idx = 0;
        for (unsigned s = 0; s < REF_N_SAMPLES; s++)
            for (unsigned i = 0; i < ref_sample_len[s] && idx < HALF_WORDS; i++)
                blk[idx++] = ref_sample[s][i];
        for (; idx < HALF_WORDS; idx++)
            blk[idx] = 0;    // no-op padding to the half boundary
    }

    reckon_wr(OUT_REG0_BATCH_SIZE, REF_N_SAMPLES);   // one batch = the whole epoch
    reckon_wr(OUT_REG1_N_EPOCHS, 1);
    reckon_wr(OUT_REG2_N_SAMPLES, REF_N_SAMPLES);
    reckon_wr(OUT_REG3_DO_EPROP, 0);

    grant_half(0);                       // the only half; never regranted
    reckon_wr(OUT_REG4_NEW_EPOCH, 1);
    reckon_wr(OUT_REG4_NEW_EPOCH, 0);    // strobe: 1 then 0

    printf("BAROCCI MODE: %u samples in half 0, BATCH_SIZE=N_SAMPLES=%u\n",
           REF_N_SAMPLES, REF_N_SAMPLES);
    uart_write_flush(&__base_uart);

    while (!(reckon_rd(IN_REG2_EPOCH_DONE) & 1u))
        ;
#else
    // Step 2: prepare the reference dataset (Barocci ESA/w200 train) directly in DDR4,
    // one real sample per BRAM half (N_HALVES_TOTAL blocks).
    for (unsigned b = 0; b < N_HALVES_TOTAL; b++)
        load_ref_block((volatile uint32_t *)(DRAM_BASE_ADDR + (uint64_t)b * HALF_BYTES),
                       b % REF_N_SAMPLES);

    // Step 3: batch geometry over AXI.
    reckon_wr(OUT_REG0_BATCH_SIZE, 1);
    reckon_wr(OUT_REG1_N_EPOCHS, 1);
    reckon_wr(OUT_REG2_N_SAMPLES, N_HALVES_TOTAL);
    reckon_wr(OUT_REG3_DO_EPROP, 0);   // no e-prop: weights are untrained garbage, see header

    // Step 4: avvio non protetto - half 0 must be filled before NEW_EPOCH.
    grant_half(0);
    unsigned next = 1;
    unsigned halves_sent = 1;
    int exhausted_sent = 0;

    reckon_wr(OUT_REG4_NEW_EPOCH, 1);
    reckon_wr(OUT_REG4_NEW_EPOCH, 0);   // strobe: 1 then 0

    printf("NEW_EPOCH given, entering streaming loop...\n");
    uart_write_flush(&__base_uart);

    while (!(reckon_rd(IN_REG2_EPOCH_DONE) & 1u)) {
        uint32_t st = reckon_rd(IN_REG3_STREAM_STATUS);
        uint32_t owner_next = (st >> next) & 1u;
        if (owner_next == 0) {   // owner[next] == 0 -> free to (re)fill
            if (halves_sent >= N_HALVES_TOTAL) {
                if (!exhausted_sent) {
                    shadow |= (1u << SC_EXHAUSTED_BIT);   // safe at any instant
                    reckon_wr(OUT_REG7_STREAM_CTRL, shadow);
                    exhausted_sent = 1;
                }
            } else {
                grant_half(next);
                halves_sent++;
                next ^= 1u;
            }
        }
    }
#endif // RECKON_BAROCCI_MODE

    uint32_t infer_count = reckon_rd(IN_REG0_INFER_COUNT);
    uint32_t final_status = reckon_rd(IN_REG3_STREAM_STATUS);
    uint32_t consumed = (final_status >> SS_CONSUMED_SHIFT) & SS_CONSUMED_MASK;
    uint32_t underrun = (final_status >> SS_UNDERRUN_BIT) & 1u;
    uint32_t overrun  = (final_status >> SS_OVERRUN_BIT) & 1u;

    printf("EPOCH_DONE: infer_count=%u consumed=%u fill_cnt=%u underrun=%u overrun=%u\n",
           infer_count, consumed, fills & SS_FILLCNT_MASK, underrun, overrun);
    uart_write_flush(&__base_uart);

    *scratch = 0xB00B0002u;

    // overrun (bit6) is a real error: dataset layout was violated. underrun (bit5) is a
    // performance note only (the CVA6 fell behind ReckOn at least once), not a failure.
    return overrun ? 1 : 0;
}
