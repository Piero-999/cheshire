// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// DDR4 -> BRAM -> ReckOn streaming, transport = iDMA block copy.
//
// This is the production transport (Option B). It differs from
// reckon_stream_cva6.c only in reckon_transport_copy() below.
//
// The iDMA is a separate AXI master: it issues bursts instead of one
// single-beat transaction per 32-bit store, and its read and write channels are
// independent, so it does not pay the read-blocked-by-outstanding-write penalty
// the CVA6 bypass path pays (axi_adapter.sv:228-232). Measured ~1.04 cycles per
// word against the CVA6's 91.79.
//
// sys_dma_blk_memcpy() blocks until done_id == tf_id, i.e. until the transfer
// has actually completed on the AXI side. That is a real completion wait, not
// an ordering barrier like fence() on posted stores.

#include <stdint.h>

#include "dif/dma.h"
#include "reckon/reckon_bringup.h"
#include "reckon/reckon_stream.h"

// ---------------------------------------------------------------------------
// Transport (the only difference from reckon_stream_cva6.c)
// ---------------------------------------------------------------------------
const char *const reckon_transport_name = "iDMA block copy (Option B)";

void reckon_transport_copy(uint64_t dst, uint64_t src, uint64_t nbytes) {
    sys_dma_blk_memcpy(dst, src, nbytes);
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
