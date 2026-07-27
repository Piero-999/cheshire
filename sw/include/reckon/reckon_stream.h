// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// DDR4 -> BRAM -> ReckOn streaming engine, steps 2 and 3 of the flow.
//
//     reckon_prepare_ddr()   STEP 2  populate the DDR4 source buffers
//     reckon_stream_run()    STEP 3  double-buffered streaming + measurement
//     reckon_report()                publish telemetry and print the summary
//
// The transport that moves one BRAM half is NOT implemented here: each test
// provides it, which is the only difference between reckon_stream_cva6.c and
// reckon_stream_idma.c.
//
//     void reckon_transport_copy(uint64_t dst, uint64_t src, uint64_t nbytes);
//     const char *const reckon_transport_name;
//
// MEASUREMENT DISCIPLINE
// ----------------------
//  * No printf and no UART flush ever happens between NEW_EPOCH and EPOCH_DONE.
//    A printf + flush costs ~4 ms, longer than ReckOn takes to eat a half at
//    BATCH_SIZE=1 (1.30 ms); since underrun_q is sticky, one late handover
//    poisons the flag for the whole run (LOGBOOK 8.4).
//  * No telemetry is written to the scratch registers inside the epoch either.
//    Everything is accumulated in the (stack-resident) context and published in
//    reckon_report(), after the window is closed.
//  * STEP 2 is outside every window on purpose: filling DDR4 is a stand-in for
//    what the PS will do later, so it must never appear in the numbers.
//  * All streaming state lives in a caller-owned struct rather than in globals,
//    so nothing here depends on .bss having been zeroed (LOGBOOK 7).

#pragma once

#include <stdint.h>

#include "reckon/reckon_bringup.h"
#include "reckon/reckon_dataset_ref.h"  // ref_sample[][], ref_sample_len[], REF_N_SAMPLES

// ---------------------------------------------------------------------------
// Dataset geometry
// ---------------------------------------------------------------------------
// AER word: [31:28] ignored, [27:24] code, [23:12] data, [11:0] tick.
#define AER_CODE_SPIKE  0x3u
#define AER_CODE_LABEL  0x2u
#define AER_CODE_EOS    0x1u

#define N_HALVES_TOTAL  4u  // total BRAM halves streamed per run

// Samples packed into one BRAM half == BATCH_SIZE (aer_decoder leaves END_S for
// END_B when cnt_sample_batch == BATCH_SIZE). This is the load-regime selector:
//   1  = plumbing test. A half is 128 KiB but a sample is ~3.6 KiB, so ReckOn
//        stops at the EOS after ~931 words and 97% of a CVA6 copy is padding it
//        never reads.
//   37 = FULL-BRAM test. The 931/931/683/932 cycle sums to 3477 words per 4
//        samples, so 37 samples are 9 full cycles (31293) plus one more (<=932)
//        = 32225 <= HALF_WORDS whatever the starting offset, leaving >= 543
//        padding words (97.6-98.3% full). 38 would need up to 33156 > HALF_WORDS
//        and would truncate some halves and not others.
#define SAMPLES_PER_HALF  37u

// Bounded waits. The hardware handshakes are sub-millisecond; these only exist
// so a desync reports itself instead of hanging until run_test.sh times out.
#define RECKON_GRANT_TIMEOUT_MS  500u
#define RECKON_EPOCH_TIMEOUT_MS  5000u

static inline uint64_t rk_deadline(uint64_t core_freq, uint32_t ms) {
    return get_mcycle() + (uint64_t)ms * core_freq / 1000ull;
}

// The transport, provided by the test TU (see the header comment).
void reckon_transport_copy(uint64_t dst, uint64_t src, uint64_t nbytes);
extern const char *const reckon_transport_name;

// ---------------------------------------------------------------------------
// STEP 2 - prepare the reference dataset in DDR4
// ---------------------------------------------------------------------------
// OUTSIDE every measurement window, and deliberately so: this is a placeholder
// for the PS writing the samples into DDR4 over its own AXI master. When that
// lands, this step disappears from the firmware entirely and the streaming code
// below is untouched. It is the last development step of the project.
//
// Packs SAMPLES_PER_HALF consecutive reference samples back to back starting
// from the global sample index `first` (the pool of REF_N_SAMPLES real samples
// is cycled), then pads to the half boundary with no-op (code 0) words that
// ReckOn reads and discards. Returns the number of samples actually packed:
// fewer than SAMPLES_PER_HALF means the half overflowed, which would leave
// ReckOn waiting at END_B for an EOS that is not there.
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
    uint32_t fill_sum_epoch;  // cumulative fill cycles INSIDE the epoch window
    uint32_t epoch;           // NEW_EPOCH -> EPOCH_DONE, cycles
    uint32_t cons[4];         // per-half consume intervals, cycles
    unsigned n_cons;
    uint32_t infer_count;
    uint32_t fill_cnt;        // relative to the bring-up baseline
    uint32_t consumed;        // relative to the bring-up baseline
    uint32_t underrun;        // 1 only if the flag went up during THIS run
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
    s->fills          = base->fill_cnt_base;  // latch, never assume 0: see reckon_bringup.h
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

    // The writes above are POSTED: fence() orders them but does NOT guarantee
    // they reached the BRAM. Without this read-back ReckOn was granted a half
    // whose data had not landed, decoded garbage (code != 3 -> the READM default
    // branch) and raced through the half without ever ticking (LOGBOOK 6).
    // Reading the LAST word written is a real completion barrier here: the load
    // is a bypass access, and cva6's axi_adapter refuses to issue a read while
    // any write has no B response yet (axi_adapter.sv:230), so every preceding
    // store to this slave must have completed first. Kept on the iDMA path too -
    // it costs ~90 cycles out of millions and it is the failure this project has
    // already paid for once.
    volatile uint32_t sink = *(volatile uint32_t *)(dst + HALF_BYTES - 4u);
    (void)sink;
    fence();

    uint32_t dt = (uint32_t)(get_mcycle() - t0);
    if (s->n_fills == 0) s->fill_one = dt;
    s->n_fills++;
    // Only the fills inside the epoch window are accumulated, so fill_sum and
    // the epoch duration describe the SAME interval and their ratio means
    // something. The priming fill happens before NEW_EPOCH and is reported
    // separately as fill_one.
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
    reckon_wr(OUT_REG3_DO_EPROP, 0);  // no e-prop: weights are not loaded yet

    // --- prime half 0: it must be full before NEW_EPOCH, and it is NOT part of
    //     the epoch window (in_epoch is still 0) ---
    if (rk_grant_half(s, 0)) {
        reckon_fail("timeout waiting for fill_cnt after the priming grant");
        return 1;
    }

    reckon_step(RECKON_STEP_ARMED, "half 0 primed, ReckOn armed");

    // Everything below this line is inside the measured window: no printf, no
    // UART flush, no scratch writes until the window closes.
    reckon_step(RECKON_STEP_STREAM, "START STREAM");

    uint64_t t_epoch0 = get_mcycle();
    reckon_wr(OUT_REG4_NEW_EPOCH, 1);
    reckon_wr(OUT_REG4_NEW_EPOCH, 0);  // strobe: 1 then 0
    s->in_epoch = 1;

    unsigned next = 1, halves_sent = 1;
    int exhausted_sent = 0, failed = 0;

    // Timestamp every increment of `consumed`, i.e. every BATCH_DONE. This
    // MEASURES what ReckOn takes per half instead of deriving it from an epoch
    // model. Caveat: the edge is observed by this polling loop, which stops
    // polling while it fills a half, so an edge falling inside a fill is
    // reported late by up to one fill time (negligible with the iDMA at
    // ~0.7 ms, coarse with the CVA6 copy at ~60 ms).
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
