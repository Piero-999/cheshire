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
// Reminder: ReckOn's SPI slave has no chip-select of its
// own, so it free-runs its own frame counter from power-up reset - do this bring-up
// before any other SPI transaction (flash/SD) in the same boot, or it will desync.

#include "regs/cheshire.h"
#include "dif/clint.h"
#include "dif/uart.h"
#include "dif/dma.h"
#include "params.h"
#include "util.h"
#include "printf.h"
#include "sw/device/lib/dif/dif_spi_host.h"
#include <stdint.h>

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
#define RECKON_SPI_CSID           0u   // no CS reaches ReckOn's slave; see file header note
#define RECKON_SPI_CODE_CFG       0x0u
#define RECKON_SPI_ADDR_LABEL_DELAY     37u
#define RECKON_SPI_ADDR_CYCLES_PER_TICK 64u

// Bring-up-only tuning (NOT trained/tuned values - see file header):
#define RECKON_TICK_PERIOD   15u   // clk15 cycles per algorithmic tick (~1 us @ 15 MHz)
#define RECKON_LABEL_DELAY   10u   // ticks; must be >= last spike tick in the synthetic sample below

static int reckon_spi_cfg_write(const dif_spi_host_t *host, uint16_t addr, uint32_t value) {
    uint32_t cmd = ((uint32_t)(RECKON_SPI_CODE_CFG & 0x7u) << 28) | (1u << 16) | addr;
    uint8_t buf[8];
    buf[0] = (uint8_t)(cmd >> 24); buf[1] = (uint8_t)(cmd >> 16);
    buf[2] = (uint8_t)(cmd >> 8);  buf[3] = (uint8_t)(cmd);
    buf[4] = (uint8_t)(value >> 24); buf[5] = (uint8_t)(value >> 16);
    buf[6] = (uint8_t)(value >> 8);  buf[7] = (uint8_t)(value);

    dif_spi_host_segment_t seg = {
        .type = kDifSpiHostSegmentTypeTx,
        .tx = {.width = kDifSpiHostWidthStandard, .buf = buf, .length = sizeof(buf)},
    };
    return (dif_spi_host_transaction(host, RECKON_SPI_CSID, &seg, 1) == kDifOk) ? 0 : 1;
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

    // Mandatory: SPI_CYCLES_PER_TICK has no reset value in
    // HW. Without it TIME_TICK never pulses and the streaming loop below hangs forever.
    CHECK_CALL(reckon_spi_cfg_write(&host, RECKON_SPI_ADDR_CYCLES_PER_TICK, RECKON_TICK_PERIOD));
    // Shrink the label delay so the synthetic dataset doesn't wait out the 2100-tick
    // HW reset default per sample.
    CHECK_CALL(reckon_spi_cfg_write(&host, RECKON_SPI_ADDR_LABEL_DELAY, RECKON_LABEL_DELAY));

    // TODO before a real training/inference run:
    //  - SPI_ALPHA_CONF (addr 65-68): resets to 0 -> instantaneous membrane/trace leak.
    //  - W_inp/W_rec/W_out (PROG_WINP/WREC/WOUT, code 3/4/5): SRAM starts undefined.
    //  - thresholds / learning rates / LFSR seeds: left at HW reset defaults here.
    // None of these block the streaming path itself.
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

static inline uint32_t aer_word(uint32_t code, uint32_t data8, uint32_t tick) {
    return (code << 24) | ((data8 & 0xFFu) << 12) | (tick & 0xFFFu);
}

// Fills exactly HALF_WORDS words in DDR4 with one BATCH_SIZE=1 sample: a few spikes,
// one label, one end-of-sample, then no-op padding (code=0) to the half boundary.
// Block is exactly one BRAM half, and BATCH_SIZE=1 divides it evenly.
static void gen_synthetic_block(volatile uint32_t *blk) {
    unsigned idx = 0;
    for (unsigned k = 0; k < N_SPIKES_PER_SAMPLE; k++)
        blk[idx++] = aer_word(AER_CODE_SPIKE, (uint8_t)k, k);
    blk[idx++] = aer_word(AER_CODE_LABEL, 0, RECKON_LABEL_DELAY);
    blk[idx++] = aer_word(AER_CODE_EOS, 0, 0);
    for (; idx < HALF_WORDS; idx++)
        blk[idx] = 0;   // no-op: read and discarded, does not advance algorithmic time
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

    // Step 2: prepare the synthetic dataset directly in DDR4 (N_HALVES_TOTAL blocks).
    for (unsigned b = 0; b < N_HALVES_TOTAL; b++)
        gen_synthetic_block((volatile uint32_t *)(DRAM_BASE_ADDR + (uint64_t)b * HALF_BYTES));

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
