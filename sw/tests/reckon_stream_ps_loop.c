// DDR4 -> BRAM -> ReckOn streaming with the dataset from the PS, IN A LOOP: one
// JTAG start serves any number of epochs, each one a separate handover from the
// PS. Everything done per epoch - bring-up, validation, streaming, measurement,
// ack - is the code reckon_stream_ps.c runs once; this file only adds the loop
// around it and a freshness rule the one-shot firmware cannot have.
//
// Why a loop: the PS reaches the DRAM aperture but not the debug module, so with
// the one-shot firmware every epoch needs JTAG from outside. Here JTAG starts the
// session once; after that the PS alone decides when the next epoch runs, and it
// can write a different image each time.
//
// Freshness. The one-shot firmware streams whatever handover it finds standing,
// so one left behind by a failed or abandoned run is consumed as if it were new.
// The loop is started BEFORE the data, and that allows two rules:
//   * a handover already standing when the session starts predates it: it is
//     refused (rc = 3) and cleared instead of streamed;
//   * inside the session, a handover must carry a sequence number greater than
//     the last one accepted, or it is refused the same way.
// A refusal is acked with the refused seq, so a producer still polling for it
// gets a loud failure instead of silence.
//
// Session:
//     dev host : util/reckon/reckon.py loop        # starts it, returns once listening
//     PS       : sudo ./reckon_feed --seq N         # one epoch, waits for its own ack
//                (again with a larger N for the next one; reckon.py feed --epochs)
// It ends after RECKON_LOOP_IDLE_MS without a handover, or when the core is
// halted over JTAG.
//
// Mailbox words 13 and 14 are unused by the one-shot contract; the loop publishes
// its state there, so the dev host can read it over JTAG without the UART.

#define RECKON_DATA_FROM_PS 1  // must precede reckon_stream.h

// Uncomment to run the epochs with e-prop enabled (DO_EPROP, reckon_stream.h).
// It makes the consumer slower; with the weights unprogrammed it tests the
// transport under that load, not the learning.
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

        // STEP 1 - bring-up before every epoch: the warm-restart contract,
        //          applied between epochs instead of between ELF loads.
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

        // STEP 3 - stream, exactly as the one-shot firmware does.
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
