// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// DDR4 -> BRAM -> ReckOn streaming, with the DATASET SUPPLIED BY THE PS.
//
// This is the "last development step" the HANDOFF pins: STEP 2 no longer builds
// the samples on this core, it waits for the PS to have written them into PL DDR4
// over M_AXI_HPM0_FPD and validates the handover. Everything else - bring-up,
// double-buffered streaming, measurement - is byte-for-byte the code the other two
// tests run, so the numbers stay comparable with LOGBOOK 8.5/8.7.
//
// Differences from reckon_stream_idma.c, and only these:
//   * RECKON_DATA_FROM_PS = 1 -> reckon_wait_ddr_from_ps() instead of
//     reckon_prepare_ddr(); the reference dataset is no longer linked in at all,
//     which also takes ~42 KiB of .rodata out of the image.
//   * reckon_ps_ack() mirrors the outcome back into the mailbox at the end.
// The transport is the iDMA, i.e. the production path (LOGBOOK 8.4).
//
// THE ONE THING THAT TRIPS PEOPLE UP: the PS and this core see the same DDR4
// cells at addresses 0x2000_0000 apart. PS 0xA000_0000 == CVA6 0x8000_0000. See
// the header comment in sw/include/reckon/reckon_ps_mbox.h for why.
//
// Normal flow (the PS writes first, then the ELF runs):
//     PS        : util/reckon/ps/reckon_feed --data reckon_dataset.bin
//     dev host  : util/reckon/run_test.sh sw/tests/reckon_stream_ps.dram.elf
// Both directions of the handshake tolerate the other order too, as long as the
// wait fits inside RECKON_PS_WAIT_TIMEOUT_MS and run_test.sh's sleep window.

#define RECKON_DATA_FROM_PS 1  // must precede reckon_stream.h

#include <stdint.h>

#include "dif/dma.h"
#include "reckon/reckon_bringup.h"
#include "reckon/reckon_stream.h"

// ---------------------------------------------------------------------------
// Transport - identical to reckon_stream_idma.c
// ---------------------------------------------------------------------------
const char *const reckon_transport_name = "iDMA block copy (Option B), data from PS";

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
    uint32_t          seq = 0;

    printf("\n=== ReckOn streaming: %s ===\n", reckon_transport_name);
    uart_write_flush(&__base_uart);

    // STEP 0 - is the right streaming FSM in this bitstream at all?
    if (reckon_check_version()) return 1;

    // STEP 1 - BRING UP RECKON: SPI network config, decoder back to IDLE,
    //          latch the free-running HW counters and the sticky flags.
    reckon_step(RECKON_STEP_BRINGUP, "BRING UP RECKON");
    if (reckon_bringup(&clk, &base)) return 1;

    // STEP 2 - TAKE THE DATA FROM THE PS. Outside every measurement window, same
    //          as the placeholder it replaces, so no transport or consume number
    //          moves because of it.
    reckon_step(RECKON_STEP_DDR, "TAKE DATA FROM PS");
    if (reckon_wait_ddr_from_ps(&clk, &seq)) {
        reckon_ps_ack(seq, 2, &res);  // tell the producer instead of leaving it polling
        return 1;
    }

    // STEP 3 - STREAM. reckon_stream_run() announces START STREAM itself, just
    //          before NEW_EPOCH, and prints nothing until EPOCH_DONE.
    reckon_stream_init(&stream, &clk, &base);
    int rc = reckon_stream_run(&stream, &res);

    // STEP 4 - report. Always outside the window.
    reckon_step(RECKON_STEP_DONE, "END STREAM");
    reckon_report(&res, &clk);

    // overrun is a real error (the data layout was violated). underrun is a
    // performance note: the transport fell behind ReckOn at least once.
    if (!rc && res.overrun) rc = 1;
    reckon_ps_ack(seq, (uint32_t)rc, &res);
    return rc;
}
