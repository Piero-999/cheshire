// DDR4 -> BRAM -> ReckOn streaming, with the dataset written by the PS.
//
// The same code as reckon_stream_idma.c except for STEP 2, which waits for the PS
// handover and validates it instead of building the samples here:
//   * RECKON_DATA_FROM_PS = 1 -> reckon_wait_ddr_from_ps() instead of
//     reckon_prepare_ddr(); the reference dataset is not linked in (~42 KiB less);
//   * reckon_ps_ack() mirrors the outcome back into the mailbox at the end.
// PS 0xA000_0000 == CVA6 0x8000_0000: see reckon_ps_mbox.h.
//
// Normal flow (the PS writes first, then the ELF runs):
//     PS        : util/reckon/reckon.py feed   (reckon_feed, on the board)
//     dev host  : util/reckon/reckon.py start

#define RECKON_DATA_FROM_PS 1  // read by reckon_stream.h

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

    // STEP 2 - TAKE THE DATA FROM THE PS, outside every measurement window.
    reckon_step(RECKON_STEP_DDR, "TAKE DATA FROM PS");
    if (reckon_wait_ddr_from_ps(&clk, &seq)) {
        reckon_ps_ack(seq, 2, &res);  // tell the producer: rc = 2
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
