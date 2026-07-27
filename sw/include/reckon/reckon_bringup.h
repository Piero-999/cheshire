// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// ReckOn bring-up: platform map, AXI register file, SPI network programming and
// the step/telemetry plumbing shared by every streaming test.
//
// STEP 1 of the flow (see reckon_stream.h for steps 2 and 3):
//
//     reckon_platform_init()   clock calibration + UART, must come first
//     reckon_check_version()   is stream_ctrl_fsm2 really in this bitstream?
//     reckon_bringup()         SPI config + decoder reset + baseline latch
//
// This header DEFINES the ReckOn configuration tables (reckon_params_vec.h and
// the weight matrices), so include it from exactly one translation unit. Each
// test ELF is a single TU, so that is automatic here.
//
// WARM-RESTART CONTRACT (why reckon_bringup() is not just "send the SPI config")
// -----------------------------------------------------------------------------
// run_test.sh reloads the ELF over JTAG and resumes; it never resets the SoC
// (util/openocd.common.tcl has `reset_config none`). Three pieces of hardware
// state therefore survive from the previous run and must be handled explicitly,
// otherwise a second test in the same session is silently wrong or hangs:
//
//  1. aer_decoder parks in END_E with EPOCH_DONE high once an epoch completes
//     (aer_decoder.v: `END_E: next_state <= STOP ? IDLE : ...`, and with
//     N_EPOCHS=1 the epochs_target arm keeps it there). NEW_EPOCH is ignored in
//     that state, so a fresh run would see EPOCH_DONE already set and "finish"
//     instantly. => reckon_bringup() strobes STOP first.
//  2. fill_cnt_q / consumed_q are free-running counters cleared only by
//     acc_rst_ni (stream_ctrl_fsm2.sv:144-156). Starting the SW counters at 0
//     makes grant_half() wait for a match that never happens => hang.
//     => we LATCH them instead of assuming zero.
//  3. underrun_q / overrun_q are sticky and likewise survive. A run after a run
//     that underran would inherit the flag. => we latch a baseline and report
//     the flags relative to it.
//
// out_reg[7] is write-only, so the SW shadow cannot be recovered by reading it.
// reckon_bringup() writes a known value (all fill_tgl low) to re-synchronise the
// shadow; after a clean N_HALVES_TOTAL run the toggles are already back to zero,
// so no spurious fill edge is generated. If ownership is still dirty we say so
// and refuse to start rather than produce a meaningless measurement.

#pragma once

#include <stdint.h>

#include "dif/clint.h"
#include "dif/uart.h"
#include "params.h"
#include "printf.h"
#include "regs/cheshire.h"
#include "sw/device/lib/dif/dif_spi_host.h"
#include "util.h"

// ReckOn network configuration, ported from Barocci's "works firmware"
// (branch reckon_cheshire_bad, commit 033eba1). These headers *define* the SPI
// config vector and the weight matrices.
#include "reckon/reckon_params_vec.h"  // reckon_spi_conf[], N_*_NEUR, KAPPA, ALPHALSB, THRESHOLD
#include "reckon/winp.h"               // int8_t winp[N_INP][N_REC]
#include "reckon/wout.h"               // int8_t wout[N_REC][N_OUT]
#include "reckon/wrec.h"               // int8_t wrec[N_REC][N_REC]

// ---------------------------------------------------------------------------
// Platform memory map
// ---------------------------------------------------------------------------
#define DRAM_BASE_ADDR   0x80000000ull
#define BRAM_BASE_ADDR   0x48000000ull
#define RECKON_REG_BASE  0x40000000ull

#define HALF_WORDS  32768u                 // one BRAM half = one batch (HALF_BATCH=1)
#define HALF_BYTES  (HALF_WORDS * 4u)

// ---------------------------------------------------------------------------
// ReckOn AXI register file (offsets from RECKON_REG_BASE)
// ---------------------------------------------------------------------------
#define IN_REG0_INFER_COUNT    0x00u  // R
#define IN_REG1_BATCH_DONE     0x08u  // R, bit0
#define IN_REG2_EPOCH_DONE     0x10u  // R, bit0
#define IN_REG3_STREAM_STATUS  0x18u  // R, see SS_* below

#define OUT_REG0_BATCH_SIZE    0x20u  // W, [11:0], samples per BRAM half
#define OUT_REG1_N_EPOCHS      0x28u  // W, [11:0]
#define OUT_REG2_N_SAMPLES     0x30u  // W, [11:0]
#define OUT_REG3_DO_EPROP      0x38u  // W, [2:0]
#define OUT_REG4_NEW_EPOCH     0x40u  // W, bit0, strobe
#define OUT_REG5_RESERVED      0x48u  // W, ignored by HW
#define OUT_REG6_TEST          0x50u  // W, bit0, level
#define OUT_REG7_STREAM_CTRL   0x58u  // W, see SC_* below - NOT READABLE

// out_reg[7] bit layout (xilinx_zcu102_reckon_chs_top.sv:855-865).
// bit0 is edge-detected into STOP_strb inside reckon_axi_top.v.
#define SC_STOP_BIT       0u
#define SC_FILL_TGL0_BIT  1u
#define SC_FILL_TGL1_BIT  2u
#define SC_EXHAUSTED_BIT  3u

// in_reg[3] (stream_status) bit layout, produced by stream_ctrl_fsm2.sv:163-172
#define SS_OWNER_MASK      0x3u  // bit0/bit1 = owner[0]/owner[1]
#define SS_READ_HALF_BIT   2u
#define SS_NEED_FILL_BIT   4u
#define SS_UNDERRUN_BIT    5u
#define SS_OVERRUN_BIT     6u
#define SS_CONSUMED_SHIFT  8u
#define SS_CONSUMED_MASK   0xFFu
#define SS_FILLCNT_SHIFT   16u
#define SS_FILLCNT_MASK    0xFFu
#define SS_VERSION_SHIFT   24u
#define SS_VERSION_MASK    0xFFu
#define SS_VERSION_FSM2    0xA6u  // 0xA5 = old v1 FSM, 0xDE = no streaming at all

static inline volatile uint32_t *reckon_reg(uint32_t off) {
    return (volatile uint32_t *)(RECKON_REG_BASE + off);
}

// The ReckOn register file is MMIO in the weakly ordered, non-idempotent window
// [0x4000_0000, 0x8000_0000): every access needs its own fence.
static inline uint32_t reckon_rd(uint32_t off) {
    fence();
    return *reckon_reg(off);
}

static inline void reckon_wr(uint32_t off, uint32_t v) {
    *reckon_reg(off) = v;
    fence();
}

// Decoded view of in_reg[3], so callers stop open-coding shifts.
typedef struct {
    uint32_t raw;
    uint32_t version;
    uint32_t fill_cnt;
    uint32_t consumed;
    uint32_t owner;
    uint32_t read_half;
    uint32_t need_fill;
    uint32_t underrun;
    uint32_t overrun;
} reckon_status_t;

static inline reckon_status_t reckon_status(void) {
    uint32_t s = reckon_rd(IN_REG3_STREAM_STATUS);
    reckon_status_t st = {
        .raw       = s,
        .version   = (s >> SS_VERSION_SHIFT) & SS_VERSION_MASK,
        .fill_cnt  = (s >> SS_FILLCNT_SHIFT) & SS_FILLCNT_MASK,
        .consumed  = (s >> SS_CONSUMED_SHIFT) & SS_CONSUMED_MASK,
        .owner     = s & SS_OWNER_MASK,
        .read_half = (s >> SS_READ_HALF_BIT) & 1u,
        .need_fill = (s >> SS_NEED_FILL_BIT) & 1u,
        .underrun  = (s >> SS_UNDERRUN_BIT) & 1u,
        .overrun   = (s >> SS_OVERRUN_BIT) & 1u,
    };
    return st;
}

// ---------------------------------------------------------------------------
// Telemetry: uncached scratch registers + UART step announcements
// ---------------------------------------------------------------------------
// Reading variables out of DRAM over JTAG is unreliable (DRAM is cacheable and
// the debug module bypasses the cache), so every number this test wants to
// publish goes to a Cheshire scratch register, which is plain MMIO and always
// coherent. Slot map, kept byte-compatible with util/reckon/run_test.sh:
//
//   s0 0x03000000  cycles of ONE half-fill
//   s1 0x03000004  epoch duration (NEW_EPOCH -> EPOCH_DONE)
//   s2 0x03000008  *** RESERVED - DO NOT USE ***
//   s3 0x0300000c  step marker (RECKON_STEP_*)
//   s4 0x03000010  consume interval, half 0
//   s5 0x03000014  consume interval, half 1
//   s6 0x03000018  cumulative fill cycles INSIDE the epoch window
//   s7 0x0300001c  consume interval, half 2
//   s8 0x03000020  consume interval, half 3
//   s9 0x03000024  core cycles measured in 100 ms of RTC (clock check)
//   sA 0x03000028  stream_status latched at BRING-UP (the inherited baseline)
//   sB 0x0300002c  stream_status at EPOCH_DONE
//
// sA exists because underrun_q/overrun_q are sticky across runs and the
// counters free-run: comparing sB against sA is what tells you whether a flag
// belongs to this run or was inherited, without needing the UART.
//
// s2 is reserved because crt0.S `_exit` writes (main_ret << 1) | 1 there after
// main returns (sw/lib/crt0.S:125-129). Anything parked in s2 reads back as 1
// over JTAG. That - not a broken clint_get_core_freq() - is why the previous
// harness saw "1 Hz": the frequency was fine, the slot was overwritten.
#define RK_SCRATCH(n)  ((volatile uint32_t *)(0x03000000ull + 4ull * (n)))

#define RK_S_FILL_ONE    0u
#define RK_S_EPOCH       1u
#define RK_S_STEP        3u
#define RK_S_FILL_SUM    6u
#define RK_S_CLKCHECK    9u
#define RK_S_BASE_STAT  10u
#define RK_S_FIN_STAT   11u

// Consume-interval slots, deliberately skipping s2 and s6.
static const unsigned rk_s_cons[4] = {4u, 5u, 7u, 8u};

static inline void rk_publish(unsigned slot, uint32_t v) {
    *RK_SCRATCH(slot) = v;
    fence();
}

// Step codes. The last two keep the values util/reckon/run_test.sh and the
// LOGBOOK already document (B00B0001 = in the streaming loop, B00B0002 =
// EPOCH_DONE); the earlier ones are overwritten as the run progresses, so a
// hang leaves the marker of the step it died in.
typedef enum {
    RECKON_STEP_BOOT    = 0xB00B0010u,
    RECKON_STEP_BRINGUP = 0xB00B0011u,
    RECKON_STEP_DDR     = 0xB00B0012u,
    RECKON_STEP_ARMED   = 0xB00B0013u,
    RECKON_STEP_STREAM  = 0xB00B0001u,
    RECKON_STEP_DONE    = 0xB00B0002u,
    RECKON_STEP_ERROR   = 0xB00B00EEu,
} reckon_step_t;

// Announce a step on the UART and on scratch3. NEVER call this inside a timed
// window: a printf + flush costs ~4 ms, which is longer than ReckOn takes to
// eat a half, and it is exactly what once set the sticky underrun flag on the
// first handover (LOGBOOK 8.4).
static inline void reckon_step(reckon_step_t code, const char *msg) {
    rk_publish(RK_S_STEP, (uint32_t)code);
    printf("[STEP %08X] %s\n", (uint32_t)code, msg);
    uart_write_flush(&__base_uart);
}

static inline void reckon_fail(const char *msg) {
    rk_publish(RK_S_STEP, (uint32_t)RECKON_STEP_ERROR);
    printf("[FAIL] %s\n", msg);
    uart_write_flush(&__base_uart);
}

// ---------------------------------------------------------------------------
// Platform init: clock, UART, clock cross-check
// ---------------------------------------------------------------------------
typedef struct {
    uint64_t rtc_freq;   // Hz, from the Cheshire RTC_FREQ register
    uint64_t core_freq;  // Hz, from clint_get_core_freq()
    uint32_t cy_100ms;   // core cycles counted in 100 ms of RTC wall time
} reckon_clocks_t;

// Brings up the UART and measures soc_clk against the RTC. The RTC is an
// independent hardware time base, so this cross-check does not depend on
// clint_get_core_freq(); every cycles->ms conversion downstream rests on it.
static inline reckon_clocks_t reckon_platform_init(void) {
    reckon_clocks_t clk;
    clk.rtc_freq  = *reg32(&__base_regs, CHESHIRE_RTC_FREQ_REG_OFFSET);
    clk.core_freq = clint_get_core_freq(clk.rtc_freq, 2500);
    uart_init(&__base_uart, clk.core_freq, __BOOT_BAUDRATE);

    rk_publish(RK_S_STEP, (uint32_t)RECKON_STEP_BOOT);

    // 100 ms of wall time, derived from the RTC frequency actually reported by
    // the hardware instead of assuming a 1 MHz RTC.
    uint64_t ticks_100ms = clk.rtc_freq / 10ull;
    if (ticks_100ms == 0) ticks_100ms = 1;

    uint64_t r0 = clint_get_mtime();
    while (clint_get_mtime() == r0)  // align to a tick edge
        ;
    uint64_t m0 = get_mcycle(), s0 = clint_get_mtime();
    while (clint_get_mtime() < s0 + ticks_100ms)
        ;
    clk.cy_100ms = (uint32_t)(get_mcycle() - m0);
    rk_publish(RK_S_CLKCHECK, clk.cy_100ms);
    return clk;
}

// ---------------------------------------------------------------------------
// ReckOn SPI bring-up
// ---------------------------------------------------------------------------
// Frame format (hw/axi_reckon/rtl/reckon/spi_slave.v):
//   32-bit command word, MSB first: {R/Wb(1), code[2:0], num_write[11:0], addr[15:0]}
//     R/Wb = 0 for write. code = 3'b000 (cfg) addresses the registers below.
//   followed by `num_write` 32-bit data words, MSB first.
//   Each cfg register occupies exactly one data word (no address auto-increment),
//   so multi-register programming = one full frame per register.
// ReckOn's SPI slave takes CS0 (spi_cs_soc[0]): the active-low chip select
// resynchronises its frame counter on every transaction, so a misaligned frame
// can no longer desync every following one (LOGBOOK 7).
#define RECKON_SPI_CSID  0u

#define RECKON_SPI_CODE_CFG      0x0u
#define RECKON_SPI_CODE_NEURMEM  0x1u  // neuron memory (alpha + threshold)
#define RECKON_SPI_CODE_WINP     0x3u  // input weights
#define RECKON_SPI_CODE_WREC     0x4u  // recurrent weights
#define RECKON_SPI_CODE_WOUT     0x5u  // output weights

#define RECKON_SPI_ADDR_EN_CONF          0u   // SPI_EN_CONF gate
#define RECKON_SPI_ADDR_LABEL_DELAY      37u
#define RECKON_SPI_ADDR_CYCLES_PER_TICK  64u

// Streaming timing override applied inside the config window (Barocci ships 4/4).
#define RECKON_TICK_PERIOD  15u  // clk15 cycles per algorithmic tick
#define RECKON_LABEL_DELAY  10u  // ticks

// Bisection knob: 0 = program only mode/config registers (proven cfg_write
// path), skip neuron-memory + weight SRAM writes. Those multi-word frames are
// the only unverified code and are a prime suspect for desyncing the SPI slave.
// Weights are NOT needed for TIME_TICK liveness or for any transport
// measurement, but while this is 0 `infer_count` is NOT meaningful: the network
// runs without computing anything sensible. Turning it to 1 is the next
// substantial work block (LOGBOOK 9, open point 1).
#define RECKON_PROGRAM_WEIGHTS  0

#define RK_MAX(a, b)  (((a) > (b)) ? (a) : (b))
// NOTE: faithful port of Barocci's CEIL macro - it returns n or n+1 (it does
// NOT divide by m). Kept identical so the num_write geometry matches the
// working firmware.
#define RK_CEIL(n, m)  ((((n) % (m)) != 0) ? ((n) + 1) : (n))

// One SPI_slave frame: a 32-bit command/address word followed by `ndata` 32-bit
// payload words, every word transmitted MSB-byte first. One CS-framed
// transaction; the DIF derives the length.
static inline int reckon_spi_frame(const dif_spi_host_t *host, uint32_t cmd,
                                   const uint32_t *data, uint32_t ndata) {
    uint8_t buf[128];
    uint32_t nbytes = 4u * (1u + ndata);
    if (nbytes > sizeof(buf)) return 1;

    uint32_t bi = 0;
    buf[bi++] = (uint8_t)(cmd >> 24);
    buf[bi++] = (uint8_t)(cmd >> 16);
    buf[bi++] = (uint8_t)(cmd >> 8);
    buf[bi++] = (uint8_t)(cmd);
    for (uint32_t i = 0; i < ndata; i++) {
        uint32_t w = data[i];
        buf[bi++] = (uint8_t)(w >> 24);
        buf[bi++] = (uint8_t)(w >> 16);
        buf[bi++] = (uint8_t)(w >> 8);
        buf[bi++] = (uint8_t)(w);
    }

    dif_spi_host_segment_t seg = {
        .type = kDifSpiHostSegmentTypeTx,
        .tx = {.width = kDifSpiHostWidthStandard, .buf = buf, .length = nbytes},
    };
    return (dif_spi_host_transaction(host, RECKON_SPI_CSID, &seg, 1) == kDifOk) ? 0 : 1;
}

static inline int reckon_spi_cfg_write(const dif_spi_host_t *host, uint16_t addr, uint32_t value) {
    uint32_t cmd = ((uint32_t)(RECKON_SPI_CODE_CFG & 0x7u) << 28) | (1u << 16) | addr;
    return reckon_spi_frame(host, cmd, &value, 1);
}

// Full ReckOn network programming, ported from Barocci reckon-chs-ESA.c. All
// SRAM writes must happen with SPI_EN_CONF asserted (open first, close last).
static inline int reckon_program_network(const dif_spi_host_t *host) {
    uint32_t data[64] __attribute__((unused));

    // --- open config window ---
    CHECK_CALL(reckon_spi_cfg_write(host, RECKON_SPI_ADDR_EN_CONF, 1));

    // --- 63 config registers (modes/FP_LOC/regul/thresholds/seeds/LR/counts) ---
    for (int i = 0; i < NPARAM_RECKON; i++) {
        uint16_t addr = (uint16_t)(reckon_spi_conf[2 * i] & 0xFFFFu);
        uint32_t val  = reckon_spi_conf[2 * i + 1];
        CHECK_CALL(reckon_spi_cfg_write(host, addr, val));
    }

    // Streaming geometry override, still inside the config window.
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

    // --- output weights (wout), code 0b101 (with N_OUT=2 this ports Barocci's
    //     quirk: num_rw computes to 0, so only the SRAM address word is sent) ---
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
#endif  // RECKON_PROGRAM_WEIGHTS

    // --- close config window ---
    CHECK_CALL(reckon_spi_cfg_write(host, RECKON_SPI_ADDR_EN_CONF, 0));
    return 0;
}

static inline int reckon_spi_configure(uint64_t core_freq) {
    dif_spi_host_t host;
    mmio_region_t spi_host_base = (mmio_region_t){.base = (void *)&__base_spih};
    CHECK_CALL(dif_spi_host_init(spi_host_base, &host));
    dif_spi_host_reset(&host);

    dif_spi_host_config_t cfg = {
        .spi_clock = 1 * 1000 * 1000,  // 1 MHz: conservative for bring-up
        .peripheral_clock_freq_hz = (uint32_t)core_freq,
        .chip_select = {.idle = 0xF, .lead = 0xF, .trail = 0xF},
        .full_cycle = false,
        .cpha = false,  // matches spi_slave.v: sample MOSI on posedge SCK
        .cpol = false,
    };
    CHECK_CALL(dif_spi_host_configure_cs(&host, cfg, RECKON_SPI_CSID));
    dif_spi_host_enable(&host, 1);
    CHECK_CALL(dif_spi_host_output_set_enabled(&host, 1));

    return reckon_program_network(&host);
}

// ---------------------------------------------------------------------------
// Bring-up result: the hardware baseline every later measurement is relative to
// ---------------------------------------------------------------------------
typedef struct {
    uint32_t shadow;         // SW mirror of the write-only out_reg[7]
    uint32_t fill_cnt_base;  // free-running HW fill counter at bring-up
    uint32_t consumed_base;  // free-running HW consume counter at bring-up
    uint32_t underrun_base;  // sticky flags inherited from a previous run
    uint32_t overrun_base;
} reckon_baseline_t;

// Checks that the bitstream on the FPGA really contains stream_ctrl_fsm2.
static inline int reckon_check_version(void) {
    uint32_t v = reckon_status().version;
    printf("stream_status version marker: 0x%02X (expect 0x%02X)\n", v, SS_VERSION_FSM2);
    uart_write_flush(&__base_uart);
    if (v != SS_VERSION_FSM2) {
        reckon_fail("wrong/missing streaming FSM in this bitstream");
        return 1;
    }
    return 0;
}

// STEP 1. SPI config, decoder reset and baseline latch. See the warm-restart
// contract at the top of this file for why the last two exist.
static inline int reckon_bringup(const reckon_clocks_t *clk, reckon_baseline_t *base) {
    if (reckon_spi_configure(clk->core_freq)) {
        reckon_fail("ReckOn SPI bring-up failed");
        return 1;
    }

    // Re-synchronise the shadow of the write-only out_reg[7]: all fill_tgl low,
    // exhausted low, STOP low. After a clean run that completed an even number
    // of alternating half grants the toggles are already zero, so this generates
    // no fill edge; the owner check below catches the case where it did.
    base->shadow = 0u;
    reckon_wr(OUT_REG7_STREAM_CTRL, base->shadow);

    // Force aer_decoder out of END_E (where a completed epoch parks it with
    // EPOCH_DONE high and NEW_EPOCH ignored) back to IDLE, which also clears
    // its RAM_ADDR, half_sel, cnt_sample_epoch and infer_count.
    reckon_wr(OUT_REG7_STREAM_CTRL, base->shadow | (1u << SC_STOP_BIT));
    reckon_wr(OUT_REG7_STREAM_CTRL, base->shadow);

    // Wait for EPOCH_DONE to drop, bounded: if the decoder was stuck somewhere
    // STOP is not honoured from (only END_E goes to IDLE), say so instead of
    // spinning forever.
    uint64_t deadline = get_mcycle() + 10ull * clk->core_freq / 1000ull;  // 10 ms
    while (reckon_rd(IN_REG2_EPOCH_DONE) & 1u) {
        if (get_mcycle() > deadline) {
            reckon_fail("EPOCH_DONE still high after STOP: decoder not in END_E, reset the SoC");
            return 1;
        }
    }

    reckon_status_t st = reckon_status();
    base->fill_cnt_base = st.fill_cnt;
    base->consumed_base = st.consumed;
    base->underrun_base = st.underrun;
    base->overrun_base  = st.overrun;
    rk_publish(RK_S_BASE_STAT, st.raw);

    if (st.owner != 0u) {
        reckon_fail("stale half ownership after bring-up (owner != 0): reset the SoC via VIO");
        return 1;
    }

    printf("bring-up ok: fill_cnt=%u consumed=%u underrun=%u overrun=%u (HW baseline)\n",
           base->fill_cnt_base, base->consumed_base, base->underrun_base, base->overrun_base);
    uart_write_flush(&__base_uart);
    return 0;
}
