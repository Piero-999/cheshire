// DDR4 -> BRAM -> ReckOn streaming with the dataset from the PS, in a loop: one
// JTAG start serves any number of epochs, one per handover from the PS. Each
// epoch runs the code of reckon_stream_ps.c; this file adds the loop and two
// freshness rules, refusing with rc = 3 and acking the refused seq:
//   * a handover already standing when the session starts predates it;
//   * inside the session, a seq not greater than the last one accepted.
//
// Session:
//     dev host : util/reckon/reckon.py loop        # starts it, returns once listening
//     PS       : sudo ./reckon_feed --seq N         # one epoch, waits for its own ack
//                (again with a larger N for the next one; reckon.py feed --epochs)
// It ends after RECKON_LOOP_IDLE_MS without a handover, or when the core is halted
// over JTAG. Its state is in mailbox words 13 and 14, readable over JTAG.

#define RECKON_DATA_FROM_PS 1  // read by reckon_stream.h

// e-prop on every epoch (DO_EPROP, README.md §4.3):
//#define RECKON_DO_EPROP 7u

#include <stdint.h>

#include "dif/dma.h"
#include "reckon/reckon_bringup.h"
#include "reckon/reckon_stream.h"

#ifndef RECKON_LOOP_IDLE_MS
#define RECKON_LOOP_IDLE_MS  300000u  // 5 minutes without a handover end the session
#endif

#define RK_MBOX_W_LOOP_STATE  13u
#define RK_MBOX_W_LOOP_COUNT  14u
#define RK_LOOP_LISTENING     0x100B0001u
#define RK_LOOP_ENDED         0x100B0002u
#define RK_RC_STALE           3u

// ---------------------------------------------------------------------------
// Transport - identical to reckon_stream_idma.c
// ---------------------------------------------------------------------------
const char *const reckon_transport_name = "iDMA block copy (Option B), data from PS, loop";

void reckon_transport_copy(uint64_t dst, uint64_t src, uint64_t nbytes) {
    sys_dma_blk_memcpy(dst, src, nbytes);
}

// ---------------------------------------------------------------------------
// The two additions: refusing a stale handover, and waiting for the next one
// ---------------------------------------------------------------------------

// Consume the standing handover without streaming it, so it cannot come back,
// and ack it with its own seq so whoever sent it learns it was refused.
static void rk_refuse_stale(uint32_t seq, const char *why) {
    volatile uint32_t *mb = rk_mbox();
    reckon_result_t none = {0};

    mb[RK_MBOX_W_MAGIC] = 0;
    fence();
    reckon_ps_ack(seq, RK_RC_STALE, &none);
    printf("  refused handover seq=%u: %s\n", seq, why);
    uart_write_flush(&__base_uart);
}

// 0 when a handover is standing, 1 after RECKON_LOOP_IDLE_MS with nothing.
static int rk_wait_next(const reckon_clocks_t *clk) {
    volatile uint32_t *mb = rk_mbox();
    uint64_t deadline = rk_deadline(clk->core_freq, RECKON_LOOP_IDLE_MS);

    while (mb[RK_MBOX_W_MAGIC] != RK_MBOX_MAGIC) {
        if (get_mcycle() > deadline) return 1;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// main - the steps of reckon_stream_ps.c, once per handover
// ---------------------------------------------------------------------------
int main(void) {
    reckon_clocks_t    clk = reckon_platform_init();
    volatile uint32_t *mb  = rk_mbox();
    uint32_t           last_seq = 0;
    uint32_t           served   = 0;
    int                rc       = 0;

    printf("\n=== ReckOn streaming: %s ===\n", reckon_transport_name);
    uart_write_flush(&__base_uart);

    // STEP 0 - is the right streaming FSM in this bitstream at all?
    if (reckon_check_version()) return 1;

    // Anything standing now was published before this session existed.
    if (mb[RK_MBOX_W_MAGIC] == RK_MBOX_MAGIC)
        rk_refuse_stale(mb[RK_MBOX_W_SEQ], "it was standing before the session started");

    mb[RK_MBOX_W_LOOP_COUNT] = 0;
    fence();

    for (;;) {
        reckon_baseline_t base;
        reckon_stream_t   stream;
        reckon_result_t   res = {0};
        uint32_t          seq = 0;

        // STEP 1 - bring-up before every epoch (reckon_bringup.h).
        reckon_step(RECKON_STEP_BRINGUP, "BRING UP RECKON");
        if (reckon_bringup(&clk, &base)) { rc = 1; break; }

        // STEP 2 - listen. Here B00B0012 on scratch3 is the idle state of the
        //          session, not a run stuck in step 2.
        reckon_step(RECKON_STEP_DDR, "LISTENING FOR THE PS");
        mb[RK_MBOX_W_LOOP_STATE] = RK_LOOP_LISTENING;
        fence();
        if (rk_wait_next(&clk)) break;

        uint32_t next = mb[RK_MBOX_W_SEQ];
        if (next <= last_seq) {
            rk_refuse_stale(next, "sequence number not greater than the last one accepted");
            continue;
        }
        if (reckon_wait_ddr_from_ps(&clk, &seq)) {
            reckon_ps_ack(next, 2, &res);  // geometry or checksum: refused, keep listening
            continue;
        }

        // STEP 3 - stream, as in the one-shot firmware.
        reckon_stream_init(&stream, &clk, &base);
        int erc = reckon_stream_run(&stream, &res);

        // STEP 4 - report and ack, outside the window.
        reckon_step(RECKON_STEP_DONE, "END STREAM");
        reckon_report(&res, &clk);
        if (!erc && res.overrun) erc = 1;
        reckon_ps_ack(seq, (uint32_t)erc, &res);

        last_seq = seq;
        mb[RK_MBOX_W_LOOP_COUNT] = ++served;
        fence();
    }

    mb[RK_MBOX_W_LOOP_STATE] = RK_LOOP_ENDED;
    fence();
    if (!rc) reckon_step(RECKON_STEP_DONE, "SESSION ENDED");
    printf("loop session over: %u epochs served\n", served);
    uart_write_flush(&__base_uart);
    return rc;
}
