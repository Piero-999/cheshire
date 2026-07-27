// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// DDR4 -> BRAM -> ReckOn streaming, transport = CVA6 word-by-word copy.
//
// This is the slow reference (Option A). It exists to be compared against
// reckon_stream_idma.c under identical instrumentation; the two files differ
// only in reckon_transport_copy() below.
//
// Why it is slow, measured at 91.79 cycles per 32-bit word:
//   * Nothing is cacheable in this bitstream. cheshire_soc.sv selects
//     gen_cva6_noCache_cfg(), which sets NrCachedRegionRules = 0, so
//     is_inside_cacheable_regions() is false for every address: the D$ never
//     allocates, the I$ never allocates either (cva6_icache.sv:330), and even
//     the instructions of this loop are re-fetched from DDR4 every iteration.
//   * The CVA6 can therefore never burst. Uncached accesses are single-beat
//     AXI transactions, one per store.
//   * The load and the store cannot overlap. Both go through the same bypass
//     axi_adapter, which refuses to issue a read while any write is still
//     without its B response (axi_adapter.sv:228-232), so each iteration pays a
//     full BRAM write round-trip plus a full DDR4 read round-trip, serialised.
//
// The iDMA is a separate AXI master that bursts and does not alternate
// read/write on one adapter, which is why it reaches ~1.04 cycles per word.

#include <stdint.h>

#include "reckon/reckon_bringup.h"
#include "reckon/reckon_stream.h"

// ---------------------------------------------------------------------------
// Transport (the only difference from reckon_stream_idma.c)
// ---------------------------------------------------------------------------
const char *const reckon_transport_name = "CVA6 word-by-word copy (Option A)";

void reckon_transport_copy(uint64_t dst, uint64_t src, uint64_t nbytes) {
    volatile uint32_t *d = (volatile uint32_t *)(uintptr_t)dst;
    volatile uint32_t *s = (volatile uint32_t *)(uintptr_t)src;
    unsigned nwords = (unsigned)(nbytes / 4u);
    // Kept as an explicit volatile 32-bit loop with an `unsigned` induction
    // variable: this is the transport under measurement, so the compiler must
    // neither widen it to 64-bit accesses nor unroll it, and the loop body must
    // stay the same length as the one the 91.79 cycles/word figure was measured
    // on - with an uncacheable I$ every extra instruction is another DDR4 read.
    for (unsigned i = 0; i < nwords; i++)
        d[i] = s[i];
}

// ---------------------------------------------------------------------------
// main - the four steps of a run, in order
// ---------------------------------------------------------------------------
int main(void) {
    reckon_clocks_t   clk = reckon_platform_init();
    reckon_baseline_t base;
    reckon_stream_t   stream;
    reckon_result_t   res = {0};

    printf("\n=== ReckOn streaming: %s ===\n", reckon_transport_name);
    uart_write_flush(&__base_uart);

    // STEP 0 - is the right streaming FSM in this bitstream at all?
    if (reckon_check_version()) return 1;

    // STEP 1 - BRING UP RECKON: SPI network config, decoder back to IDLE,
    //          latch the free-running HW counters and the sticky flags.
    reckon_step(RECKON_STEP_BRINGUP, "BRING UP RECKON");
    if (reckon_bringup(&clk, &base)) return 1;

    // STEP 2 - PREPARE DATA IN DDR4. Outside every measurement window: the PS
    //          will own this step eventually, so it must not touch the numbers.
    reckon_step(RECKON_STEP_DDR, "PREPARE DATA IN DDR4");
    if (reckon_prepare_ddr()) return 1;

    // STEP 3 - STREAM. reckon_stream_run() announces START STREAM itself, just
    //          before NEW_EPOCH, and prints nothing until EPOCH_DONE.
    reckon_stream_init(&stream, &clk, &base);
    int rc = reckon_stream_run(&stream, &res);

    // STEP 4 - report. Always outside the window.
    reckon_step(RECKON_STEP_DONE, "END STREAM");
    reckon_report(&res, &clk);

    if (rc) return 1;
    // overrun is a real error (the data layout was violated). underrun is a
    // performance note: the transport fell behind ReckOn at least once.
    return res.overrun ? 1 : 0;
}
