// DDR4 -> BRAM -> ReckOn streaming engine, steps 2 and 3 of the flow.
//
//     reckon_prepare_ddr()   STEP 2  populate the DDR4 source buffers
//     reckon_stream_run()    STEP 3  double-buffered streaming + measurement
//     reckon_report()                publish telemetry and print the summary
//
// STEP 2 has two implementations, selected by RECKON_DATA_FROM_PS:
//     0 (default)  reckon_prepare_ddr()      the CVA6 builds the dataset itself
//     1            reckon_wait_ddr_from_ps() the PS wrote it; we wait and check
//
// The transport that moves one BRAM half is not implemented here: each test
// provides it, which is the only difference between reckon_stream_cva6.c and
// reckon_stream_idma.c.
//
//     void reckon_transport_copy(uint64_t dst, uint64_t src, uint64_t nbytes);
//     const char *const reckon_transport_name;
//
// Between NEW_EPOCH and EPOCH_DONE the code prints nothing and writes no scratch
// register; reckon_report() publishes everything afterwards (README.md §4.2).
// The streaming state lives in a caller-owned struct, so it does not depend on
// .bss (README.md §4.1).

#pragma once

#include <stdint.h>

#include "reckon/reckon_bringup.h"
#include "reckon/reckon_ps_mbox.h"  // PS <-> CVA6 contract: addresses, mailbox, checksum

// Where the samples in DDR4 come from. 0 = the CVA6 packs them from the copy of
// the reference dataset baked into the ELF; 1 = the PS wrote them over
// M_AXI_HPM0_FPD and we only wait for its mailbox and validate. The PS variants
// define it to 1 before including this header.
#ifndef RECKON_DATA_FROM_PS
#define RECKON_DATA_FROM_PS  0
#endif

#if !RECKON_DATA_FROM_PS
#include "reckon/reckon_dataset_ref.h"  // ref_sample[][], ref_sample_len[], REF_N_SAMPLES
#endif

// ---------------------------------------------------------------------------
// Dataset geometry
// ---------------------------------------------------------------------------
// AER word: [31:28] ignored, [27:24] code, [23:12] data, [11:0] tick.
#define AER_CODE_SPIKE  0x3u
#define AER_CODE_LABEL  0x2u
#define AER_CODE_EOS    0x1u

#define N_HALVES_TOTAL  4u  // total BRAM halves streamed per run

// Samples packed into one BRAM half == BATCH_SIZE (aer_decoder leaves END_S for
// END_B when cnt_sample_batch == BATCH_SIZE):
//   1  = plumbing test: ReckOn stops at the first EOS, ~931 words into the half;
//   37 = full-BRAM test: the most samples that fit in a half whatever the
//        starting offset (at most 32225 words, 97.6-98.3% full).
#define SAMPLES_PER_HALF  37u

// Bounded waits: the handshakes take well under a millisecond, so reaching one
// of these limits means a desync, which is reported.
#define RECKON_GRANT_TIMEOUT_MS  500u
#define RECKON_EPOCH_TIMEOUT_MS  5000u

// How long STEP 2 waits for the PS mailbox (RECKON_DATA_FROM_PS only); in the
// normal flow the magic is already there (README.md §5.4).
#define RECKON_PS_WAIT_TIMEOUT_MS  5000u

// What each epoch writes into DO_EPROP, ReckOn's 3-bit learning enable. 0 keeps
// the network in inference; 7, ReckOn's own
// reset value, enables the update on all three weight sets. The weights are only
// programmed with RECKON_PROGRAM_WEIGHTS, so 7 alone is a transport test.
#ifndef RECKON_DO_EPROP
#define RECKON_DO_EPROP  0u
#endif

static inline uint64_t rk_deadline(uint64_t core_freq, uint32_t ms) {
    return get_mcycle() + (uint64_t)ms * core_freq / 1000ull;
}

// The transport, provided by the test TU (see the header comment).
void reckon_transport_copy(uint64_t dst, uint64_t src, uint64_t nbytes);
extern const char *const reckon_transport_name;

// ---------------------------------------------------------------------------
// STEP 2 - get the dataset into DDR4
// ---------------------------------------------------------------------------
#if !RECKON_DATA_FROM_PS
// Outside every measurement window. Packs SAMPLES_PER_HALF consecutive reference
// samples back to back, starting from the global sample index `first` (the pool
// of REF_N_SAMPLES real samples is cycled), then pads to the half boundary with
// no-op (code 0) words that ReckOn reads and discards. Returns the number of
// samples packed: fewer than SAMPLES_PER_HALF means the half overflowed, which
// would leave ReckOn waiting at END_B for an EOS that is not there.
static inline unsigned rk_pack_half(volatile uint32_t *blk, unsigned first, unsigned *used_words) {
    unsigned idx = 0, packed = 0;
    for (unsigned n = 0; n < SAMPLES_PER_HALF; n++) {
        unsigned s = (first + n) % REF_N_SAMPLES;
        if (idx + ref_sample_len[s] > HALF_WORDS) break;  // never cross the half
        for (unsigned i = 0; i < ref_sample_len[s]; i++)
            blk[idx++] = ref_sample[s][i];
        packed++;
    }
    *used_words = idx;
    for (; idx < HALF_WORDS; idx++)
        blk[idx] = 0;
    return packed;
}

static inline int reckon_prepare_ddr(void) {
    unsigned min_used = HALF_WORDS, max_used = 0;
    int ok = 1;

    for (unsigned b = 0; b < N_HALVES_TOTAL; b++) {
        unsigned used = 0;
        unsigned packed = rk_pack_half((volatile uint32_t *)(DRAM_BASE_ADDR + (uint64_t)b * HALF_BYTES),
                                       (b * SAMPLES_PER_HALF) % REF_N_SAMPLES, &used);
        if (packed != SAMPLES_PER_HALF) {
            printf("  half %u: only %u/%u samples fit (%u words) - would hang at END_B\n",
                   b, packed, SAMPLES_PER_HALF, used);
            ok = 0;
        }
        if (used < min_used) min_used = used;
        if (used > max_used) max_used = used;
    }

    if (!ok) {
        reckon_fail("DDR4 layout would truncate a half: lower SAMPLES_PER_HALF");
        return 1;
    }

    // Per-half occupancy, not just half 0: the four halves differ (the 931/931/
    // 683/932 sample cycle does not divide evenly into 37).
    printf("  DDR4 ready: %u halves, %u samples/half, occupancy %u-%u/%u words\n",
           N_HALVES_TOTAL, SAMPLES_PER_HALF, min_used, max_used, HALF_WORDS);
    uart_write_flush(&__base_uart);
    return 0;
}

#else  // RECKON_DATA_FROM_PS

// Exhaustive instead of sampled handover check: ~240 ms instead of ~1 ms.
#ifndef RECKON_PS_FULL_CHECKSUM
#define RECKON_PS_FULL_CHECKSUM 0
#endif

// The PS wrote the samples (util/reckon/ps/reckon_feed.c; addresses and mailbox
// in reckon_ps_mbox.h). This side waits for the handover and checks that what
// landed is what was announced, outside every measurement window.
static inline volatile uint32_t *rk_mbox(void) {
    return (volatile uint32_t *)RK_MBOX_CVA6_ADDR;
}

// On success *seq_out carries the producer's sequence number, which
// reckon_ps_ack() echoes back so the PS can tell its own run from a stale ack.
static inline int reckon_wait_ddr_from_ps(const reckon_clocks_t *clk, uint32_t *seq_out) {
    volatile uint32_t *mb = rk_mbox();

    *seq_out = 0;

    printf("  waiting for the PS: mailbox at 0x%08X (PS writes 0x%08X), timeout %u ms\n",
           (uint32_t)RK_MBOX_CVA6_ADDR, (uint32_t)RK_MBOX_PS_ADDR,
           RECKON_PS_WAIT_TIMEOUT_MS);
    uart_write_flush(&__base_uart);

    uint64_t deadline = rk_deadline(clk->core_freq, RECKON_PS_WAIT_TIMEOUT_MS);
    while (mb[RK_MBOX_W_MAGIC] != RK_MBOX_MAGIC) {
        if (get_mcycle() > deadline) {
            printf("  mailbox word0 = %08X, expected %08X\n",
                   mb[RK_MBOX_W_MAGIC], RK_MBOX_MAGIC);
            printf("  the PS writes at CVA6 address + 0x%08X: check it used 0x%08X\n",
                   (uint32_t)RK_PS_TO_CVA6_OFFSET, (uint32_t)RK_MBOX_PS_ADDR);
            reckon_fail("no handover from the PS within the timeout");
            return 1;
        }
    }

    uint32_t seq        = mb[RK_MBOX_W_SEQ];
    uint32_t n_halves   = mb[RK_MBOX_W_N_HALVES];
    uint32_t per_half   = mb[RK_MBOX_W_SAMPLES];
    uint32_t half_words = mb[RK_MBOX_W_HALF_WORDS];
#if RECKON_PS_FULL_CHECKSUM
    uint32_t want_sum   = mb[RK_MBOX_W_CHECKSUM];
#else
    uint32_t want_sum   = mb[RK_MBOX_W_SAMPLE_SUM];
#endif

    // Consume-once: clearing the magic keeps the next run, after an ELF reload,
    // from taking this handover again.
    mb[RK_MBOX_W_MAGIC] = 0;
    fence();

    if (n_halves != N_HALVES_TOTAL || per_half != SAMPLES_PER_HALF ||
        half_words != HALF_WORDS) {
        printf("  PS announced %u halves x %u samples, %u words/half; "
               "this firmware wants %u x %u, %u\n",
               n_halves, per_half, half_words,
               N_HALVES_TOTAL, SAMPLES_PER_HALF, HALF_WORDS);
        reckon_fail("geometry mismatch: regenerate the image with gen_ps_dataset.py");
        return 1;
    }

    // This is what distinguishes "the PS wrote the data" from "the PS wrote the
    // mailbox", the failure a wrong aperture offset produces. It samples
    // (rk_sum32_sampled, ~1 ms instead of ~240 ms) and stays outside every
    // measurement window.
    uint64_t t0 = get_mcycle();
#if RECKON_PS_FULL_CHECKSUM
    uint32_t got_sum = rk_sum32((const volatile uint32_t *)DRAM_BASE_ADDR,
                                N_HALVES_TOTAL * HALF_WORDS);
    const char *how = "full";
#else
    uint32_t got_sum = rk_sum32_sampled((const volatile uint32_t *)DRAM_BASE_ADDR,
                                        N_HALVES_TOTAL * HALF_WORDS);
    const char *how = "sampled";
#endif
    uint32_t dt = (uint32_t)(get_mcycle() - t0);
    // Published for the PS, which has no other way to see what the check cost.
    mb[RK_MBOX_W_ACK_CHK_CY] = dt;
    fence();

    if (got_sum != want_sum) {
        printf("  %s checksum over %u KiB: got %08X, PS announced %08X\n",
               how, (N_HALVES_TOTAL * HALF_BYTES) >> 10, got_sum, want_sum);
        reckon_fail("payload does not match the mailbox: partial or misplaced write");
        return 1;
    }

    printf("  PS handover ok: seq=%u, %u halves x %u samples, %s checksum %08X "
           "(verified in %u cycles)\n",
           seq, n_halves, per_half, how, got_sum, dt);
    uart_write_flush(&__base_uart);

    *seq_out = seq;
    return 0;
}

#endif  // RECKON_DATA_FROM_PS

// ---------------------------------------------------------------------------
// STEP 3 - streaming
// ---------------------------------------------------------------------------
typedef struct {
    // configuration
    uint64_t core_freq;
    reckon_baseline_t *base;
    // live state
    uint32_t shadow;         // SW mirror of the write-only out_reg[7]
    uint32_t fills;          // absolute HW fill_cnt expected after the last grant
    uint64_t dram_word_off;  // read cursor in the DDR4 source region
    unsigned n_fills;
    int      in_epoch;       // 1 while the epoch window is open
    // accumulators (published only after the window closes)
    uint32_t fill_one;
    uint32_t fill_sum_epoch;
} reckon_stream_t;

typedef struct {
    uint32_t fill_one;        // cycles for one half-fill
    uint32_t fill_sum_epoch;  // cumulative fill cycles inside the epoch window
    uint32_t epoch;           // NEW_EPOCH -> EPOCH_DONE, cycles
    uint32_t cons[4];         // per-half consume intervals, cycles
    unsigned n_cons;
    uint32_t infer_count;
    uint32_t fill_cnt;        // relative to the bring-up baseline
    uint32_t consumed;        // relative to the bring-up baseline
    uint32_t underrun;        // 1 only if the flag went up during this run
    uint32_t overrun;
    uint32_t sticky_inherited;  // a flag was already set at bring-up
    uint32_t status_raw;
    int      timed_out;
} reckon_result_t;

static inline void reckon_stream_init(reckon_stream_t *s, const reckon_clocks_t *clk,
                                      reckon_baseline_t *base) {
    s->core_freq      = clk->core_freq;
    s->base           = base;
    s->shadow         = base->shadow;
    s->fills          = base->fill_cnt_base;  // latched at bring-up (reckon_bringup.h)
    s->dram_word_off  = 0;
    s->n_fills        = 0;
    s->in_epoch       = 0;
    s->fill_one       = 0;
    s->fill_sum_epoch = 0;
}

// Copies the next half from DDR4 into BRAM half `h` and times it.
static inline void rk_fill_half(reckon_stream_t *s, unsigned h) {
    uint64_t t0 = get_mcycle();

    uint64_t dst = BRAM_BASE_ADDR + (uint64_t)h * HALF_BYTES;
    uint64_t src = DRAM_BASE_ADDR + s->dram_word_off * 4u;
    reckon_transport_copy(dst, src, HALF_BYTES);

    // Read back the last word written: the writes are posted, and this read
    // completes only after them (README.md §2.4).
    volatile uint32_t sink = *(volatile uint32_t *)(dst + HALF_BYTES - 4u);
    (void)sink;
    fence();

    uint32_t dt = (uint32_t)(get_mcycle() - t0);
    if (s->n_fills == 0) s->fill_one = dt;
    s->n_fills++;
    // Only the fills inside the epoch window are accumulated, so fill_sum and
    // the epoch duration cover the same interval. The priming fill, before
    // NEW_EPOCH, is reported separately as fill_one.
    if (s->in_epoch) s->fill_sum_epoch += dt;

    s->dram_word_off += HALF_WORDS;
}

// Grants half `h` to ReckOn: fill it, invert fill_tgl[h], then wait for the FSM
// to acknowledge (fill_cnt advancing). The only place fill_tgl is touched.
static inline int rk_grant_half(reckon_stream_t *s, unsigned h) {
    rk_fill_half(s, h);
    fence();  // make the copy visible before ReckOn is told about it

    s->shadow ^= (1u << (h == 0 ? SC_FILL_TGL0_BIT : SC_FILL_TGL1_BIT));
    reckon_wr(OUT_REG7_STREAM_CTRL, s->shadow);
    s->fills = (s->fills + 1u) & SS_FILLCNT_MASK;

    uint64_t deadline = rk_deadline(s->core_freq, RECKON_GRANT_TIMEOUT_MS);
    while (reckon_status().fill_cnt != s->fills) {
        if (get_mcycle() > deadline) return 1;
    }
    return 0;
}

// STEP 3. Programs the batch geometry, primes half 0, runs the epoch and
// measures it. Announces "start" before NEW_EPOCH and never prints inside.
static inline int reckon_stream_run(reckon_stream_t *s, reckon_result_t *r) {
    // --- batch geometry over AXI (outside every window) ---
    reckon_wr(OUT_REG0_BATCH_SIZE, SAMPLES_PER_HALF);
    reckon_wr(OUT_REG1_N_EPOCHS, 1);
    reckon_wr(OUT_REG2_N_SAMPLES, SAMPLES_PER_HALF * N_HALVES_TOTAL);
    reckon_wr(OUT_REG3_DO_EPROP, RECKON_DO_EPROP);  // 0 unless a test asks for e-prop

    // --- prime half 0: filled before NEW_EPOCH, outside the epoch window
    //     (in_epoch is still 0) ---
    if (rk_grant_half(s, 0)) {
        reckon_fail("timeout waiting for fill_cnt after the priming grant");
        return 1;
    }

    reckon_step(RECKON_STEP_ARMED, "half 0 primed, ReckOn armed");

    // From here to EPOCH_DONE: the measured window.
    reckon_step(RECKON_STEP_STREAM, "START STREAM");

    uint64_t t_epoch0 = get_mcycle();
    reckon_wr(OUT_REG4_NEW_EPOCH, 1);
    reckon_wr(OUT_REG4_NEW_EPOCH, 0);  // strobe: 1 then 0
    s->in_epoch = 1;

    unsigned next = 1, halves_sent = 1;
    int exhausted_sent = 0, failed = 0;

    // Timestamp every increment of `consumed` (every BATCH_DONE): the time ReckOn
    // takes per half. The loop does not poll while it fills a half, so an edge
    // that falls inside a fill is seen up to one fill later (~0.7 ms with the
    // iDMA, ~60 ms with the CPU copy).
    uint32_t cons_prev = s->base->consumed_base;
    uint64_t t_prev    = t_epoch0;
    unsigned ci        = 0;

    uint64_t deadline = rk_deadline(s->core_freq, RECKON_EPOCH_TIMEOUT_MS);

    while (!(reckon_rd(IN_REG2_EPOCH_DONE) & 1u)) {
        if (get_mcycle() > deadline) { failed = 1; break; }

        reckon_status_t st = reckon_status();
        if (st.consumed != cons_prev) {
            uint64_t now = get_mcycle();
            if (ci < 4) r->cons[ci++] = (uint32_t)(now - t_prev);
            t_prev    = now;
            cons_prev = st.consumed;
        }

        if (((st.owner >> next) & 1u) == 0u) {  // owner[next] == 0 -> free to refill
            if (halves_sent >= N_HALVES_TOTAL) {
                if (!exhausted_sent) {
                    s->shadow |= (1u << SC_EXHAUSTED_BIT);  // safe at any instant
                    reckon_wr(OUT_REG7_STREAM_CTRL, s->shadow);
                    exhausted_sent = 1;
                }
            } else {
                if (rk_grant_half(s, next)) { failed = 1; break; }
                halves_sent++;
                next ^= 1u;
            }
        }
    }

    r->epoch = (uint32_t)(get_mcycle() - t_epoch0);
    // The last consumed edge coincides with EPOCH_DONE, so the loop exits
    // without recording it: close the final interval here.
    if (!failed && ci < 4) r->cons[ci++] = (uint32_t)(get_mcycle() - t_prev);
    s->in_epoch = 0;
    r->n_cons   = ci;
    r->timed_out = failed;

    // --- window closed: safe to touch the status and the scratch registers ---
    reckon_status_t fin = reckon_status();
    r->fill_one         = s->fill_one;
    r->fill_sum_epoch   = s->fill_sum_epoch;
    r->status_raw       = fin.raw;
    r->infer_count      = reckon_rd(IN_REG0_INFER_COUNT);
    r->fill_cnt         = (fin.fill_cnt - s->base->fill_cnt_base) & SS_FILLCNT_MASK;
    r->consumed         = (fin.consumed - s->base->consumed_base) & SS_FILLCNT_MASK;
    // underrun_q/overrun_q are sticky and are cleared only by acc_rst_ni, so a
    // raw read would inherit the previous run's verdict: report the delta.
    r->underrun         = (fin.underrun && !s->base->underrun_base) ? 1u : 0u;
    r->overrun          = (fin.overrun && !s->base->overrun_base) ? 1u : 0u;
    r->sticky_inherited = (s->base->underrun_base || s->base->overrun_base) ? 1u : 0u;

    if (failed) {
        reckon_fail("streaming did not reach EPOCH_DONE within the timeout");
        return 1;
    }
    return 0;
}

// Publishes the telemetry to the scratch registers and prints the summary.
// Always called after the epoch window is closed.
static inline void reckon_report(const reckon_result_t *r, const reckon_clocks_t *clk) {
    rk_publish(RK_S_FILL_ONE, r->fill_one);
    rk_publish(RK_S_EPOCH, r->epoch);
    rk_publish(RK_S_FILL_SUM, r->fill_sum_epoch);
    rk_publish(RK_S_FIN_STAT, r->status_raw);
    for (unsigned i = 0; i < 4; i++)
        rk_publish(rk_s_cons[i], i < r->n_cons ? r->cons[i] : 0u);

    // cycles -> us using the RTC-checked frequency, so the console is readable
    // without post-processing. cy_100ms counts core cycles in 100 ms, so
    // cy_100ms / 100000 is cycles per microsecond - and numerically also the
    // clock in MHz.
    uint32_t cy_per_us = clk->cy_100ms / 100000u;
    if (cy_per_us == 0) cy_per_us = 1;  // guard the divisions below

    printf("transport      : %s\n", reckon_transport_name);
    printf("soc_clk check  : %u cycles / 100 ms  (%u MHz)\n", clk->cy_100ms, cy_per_us);
    printf("fill (one half): %u cycles  (%u us)\n", r->fill_one, r->fill_one / cy_per_us);
    printf("fill in epoch  : %u cycles  (%u us, %u fills)\n", r->fill_sum_epoch,
           r->fill_sum_epoch / cy_per_us, N_HALVES_TOTAL - 1u);
    printf("epoch          : %u cycles  (%u us)\n", r->epoch, r->epoch / cy_per_us);
    printf("consume/half   : %u %u %u %u cycles\n", r->cons[0], r->cons[1], r->cons[2], r->cons[3]);
    printf("stream_status  : %08X\n", r->status_raw);
    printf("fill_cnt=%u consumed=%u infer_count=%u underrun=%u overrun=%u\n",
           r->fill_cnt, r->consumed, r->infer_count, r->underrun, r->overrun);
    if (r->sticky_inherited)
        printf("NOTE: a sticky flag was already set at bring-up; underrun/overrun above are\n"
               "      reported as deltas of THIS run. Reset the SoC for an absolute reading.\n");
    uart_write_flush(&__base_uart);
}

#if RECKON_DATA_FROM_PS
// Mirrors the outcome into the mailbox, since the PS reaches only the DRAM
// aperture and not the register window. The ack word goes last: it is what the
// PS polls on.
static inline void reckon_ps_ack(uint32_t seq, uint32_t rc, const reckon_result_t *r) {
    volatile uint32_t *mb = rk_mbox();

    mb[RK_MBOX_W_ACK_SEQ]    = seq;
    mb[RK_MBOX_W_ACK_STATUS] = r->status_raw;
    mb[RK_MBOX_W_ACK_EPOCH]  = r->epoch;
    fence();
    mb[RK_MBOX_W_ACK]        = RK_MBOX_ACK_BASE | (rc & 0xFFFFu);
    fence();
}
#endif
