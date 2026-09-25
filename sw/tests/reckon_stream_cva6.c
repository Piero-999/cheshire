// DDR4 -> BRAM -> ReckOn streaming, transport = CVA6 word-by-word copy.
//
// The slow reference, compared with reckon_stream_idma.c under the same
// instrumentation: the two files differ only in reckon_transport_copy() below.

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
    // One volatile 32-bit load and store per word.
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

    // STEP 2 - PREPARE DATA IN DDR4, outside every measurement window.
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
