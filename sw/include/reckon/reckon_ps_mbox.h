// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// PS <-> CVA6 mailbox in PL DDR4, shared contract between:
//   * the firmware       sw/tests/reckon_stream_ps.c   (RISC-V, reads the data)
//   * the PS producer    util/reckon/ps/reckon_feed.c  (aarch64, writes the data)
//
// Keep this header free of any RISC-V- or Linux-specific include: it is compiled
// by both toolchains. stdint.h only.
//
// THE ADDRESS OFFSET (read this before debugging anything)
// -------------------------------------------------------
// The two sides see the same DRAM cells at DIFFERENT addresses.
//
//   PS  0xA000_0000  ==  CVA6 0x8000_0000     (same physical DDR4 cell)
//
// Why: the ZynqMP M_AXI_HPM0_FPD low aperture is 0xA000_0000..0xAFFF_FFFF and the
// PS puts the *physical* address on the bus with no base subtraction. Cheshire
// routes 0x8000_0000..0x1_0000_0000 to the DRAM port (cheshire_pkg.sv gen_axi_out),
// so 0xA000_0000 is decoded as DRAM; the PL DDR4 is 512 MiB (AxiAddressWidth=29)
// and dram_wrapper_xilinx.sv:250-251 truncates to addr[28:0], so 0xA000_0000 and
// 0x8000_0000 alias onto the same offset 0. The 256 MiB aperture therefore covers
// CVA6 0x8000_0000..0x8FFF_FFFF, which contains both the dataset halves and the
// firmware image at 0x8080_0000.
//
// Rule of thumb: PS address = CVA6 address + 0x2000_0000.
//
// COHERENCE
// ---------
// Nothing is cacheable on the CVA6 side (gen_cva6_noCache_cfg, NrCachedRegionRules
// = 0), and the PS maps the aperture with O_SYNC (Device-nGnRnE). No flush or
// invalidate is needed in either direction; only ordering, which is why the
// producer writes RK_MBOX_MAGIC last and reads it back.

#pragma once

#include <stdint.h>

// ---------------------------------------------------------------------------
// Addresses
// ---------------------------------------------------------------------------
#define RK_PS_APERTURE_BASE   0xA0000000ull  // what the PS sees
#define RK_CVA6_DRAM_BASE     0x80000000ull  // what the CVA6 sees
#define RK_PS_TO_CVA6_OFFSET  (RK_PS_APERTURE_BASE - RK_CVA6_DRAM_BASE)  // 0x2000_0000

// Dataset payload lives at DRAM offset 0: CVA6 0x8000_0000, PS 0xA000_0000.
// N_HALVES_TOTAL * HALF_BYTES = 4 * 128 KiB = 512 KiB, ending at offset 0x8_0000.
#define RK_DATA_OFF   0x00000000ull

// Mailbox at DRAM offset 1 MiB: CVA6 0x8010_0000, PS 0xA010_0000.
// Clear of the dataset (ends at 0x8_0000) and of the firmware image, which the
// linker places at 0x8080_0000 with the stack at the top of the 8 MiB region
// (sw/link/common.ldh, sw/link/dram.ld).
#define RK_MBOX_OFF   0x00100000ull

#define RK_MBOX_CVA6_ADDR  (RK_CVA6_DRAM_BASE   + RK_MBOX_OFF)  // 0x8010_0000
#define RK_MBOX_PS_ADDR    (RK_PS_APERTURE_BASE + RK_MBOX_OFF)  // 0xA010_0000

// How much of the aperture the producer needs to map: mailbox end, rounded up.
#define RK_PS_MAP_BYTES  0x00200000ull  // 2 MiB

// ---------------------------------------------------------------------------
// Mailbox layout (32-bit words, little endian on both sides)
// ---------------------------------------------------------------------------
//   word  byte  dir      field
//     0   0x00  PS->CVA6 magic            RK_MBOX_MAGIC, written LAST
//     1   0x04  PS->CVA6 seq              incremented by the producer each epoch
//     2   0x08  PS->CVA6 n_halves         must match N_HALVES_TOTAL
//     3   0x0c  PS->CVA6 samples_per_half must match SAMPLES_PER_HALF
//     4   0x10  PS->CVA6 half_words       must match HALF_WORDS
//     5   0x14  PS->CVA6 checksum         sum32 of the payload words (full)
//     6   0x18  PS->CVA6 sample_sum       rk_sum32_sampled of the payload words
//     7   0x1c  --       reserved
//     8   0x20  CVA6->PS ack              RK_MBOX_ACK_BASE | rc
//     9   0x24  CVA6->PS ack_seq          echo of word 1
//    10   0x28  CVA6->PS ack_status       stream_status at EPOCH_DONE
//    11   0x2c  CVA6->PS ack_epoch_cy     epoch duration in core cycles
//    12   0x30  CVA6->PS ack_chk_cy       cycles the CVA6 spent checking the payload.
//                                         Published because there is no PS console
//                                         and the UART is not always wired: it is how
//                                         you confirm from Linux that the handover
//                                         check stayed cheap. Compare against
//                                         ack_epoch_cy - it must be a small fraction.
#define RK_MBOX_W_MAGIC        0u
#define RK_MBOX_W_SEQ          1u
#define RK_MBOX_W_N_HALVES     2u
#define RK_MBOX_W_SAMPLES      3u
#define RK_MBOX_W_HALF_WORDS   4u
#define RK_MBOX_W_CHECKSUM     5u
#define RK_MBOX_W_SAMPLE_SUM   6u
#define RK_MBOX_W_ACK          8u
#define RK_MBOX_W_ACK_SEQ      9u
#define RK_MBOX_W_ACK_STATUS  10u
#define RK_MBOX_W_ACK_EPOCH   11u
#define RK_MBOX_W_ACK_CHK_CY  12u
#define RK_MBOX_W_PROBE       15u  // scratch cell for the PS-side liveness probe
#define RK_MBOX_WORDS         16u

#define RK_MBOX_MAGIC      0xDA7AC0DEu  // "data code": payload is complete and valid
#define RK_MBOX_ACK_BASE   0xD09E0000u  // "done": | rc in the low 16 bits
#define RK_MBOX_ACK_RC(a)  ((a) & 0xFFFFu)
#define RK_MBOX_IS_ACK(a)  (((a) & 0xFFFF0000u) == RK_MBOX_ACK_BASE)

// ---------------------------------------------------------------------------
// Dataset file header (util/reckon/gen_ps_dataset.py -> reckon_feed.c)
// ---------------------------------------------------------------------------
// The producer does NOT pack samples: the host generator emits the exact image
// to be copied into DDR4, so the packing logic cannot drift between the two
// sides. The file is this 32-byte header followed by payload_bytes of payload.
#define RK_DSFILE_MAGIC    0x524B4453u  // 'R','K','D','S' as a LE u32
#define RK_DSFILE_VERSION  1u

typedef struct {
    uint32_t magic;            // RK_DSFILE_MAGIC
    uint32_t version;          // RK_DSFILE_VERSION
    uint32_t n_halves;         // == N_HALVES_TOTAL
    uint32_t half_words;       // == HALF_WORDS
    uint32_t samples_per_half; // == SAMPLES_PER_HALF
    uint32_t payload_bytes;    // n_halves * half_words * 4
    uint32_t checksum;         // sum32 of the payload words
    uint32_t reserved;
} rk_dsfile_hdr_t;

// The one checksum definition both sides use: plain 32-bit wrapping sum of the
// payload words. On the PS this runs over ordinary cached RAM and costs nothing;
// it is what validates the dataset FILE. Do not run it over the aperture on
// either side unless you are debugging - see rk_sum32_sampled below for why.
static inline uint32_t rk_sum32(const volatile uint32_t *p, uint32_t nwords) {
    uint32_t s = 0;
    for (uint32_t i = 0; i < nwords; i++) s += p[i];
    return s;
}

// ---------------------------------------------------------------------------
// The handover check, and why it samples instead of scanning
// ---------------------------------------------------------------------------
// Reading DDR4 is the expensive operation on this system: nothing is cacheable on
// the CVA6 (gen_cva6_noCache_cfg, NrCachedRegionRules = 0), so a full sum32 over
// the 512 KiB payload is 131072 words x ~91.8 cycles = ~240 ms at 50 MHz - MORE
// than the 192.85 ms epoch it is guarding. That is the wrong shape for a
// handshake: the check must not cost more than the work.
//
// What the check actually has to catch is a payload that did not land where the
// mailbox says it did: a wrong aperture offset, a truncated write, a half that
// never arrived. All of those are gross, contiguous failures, so sampling one
// word per RK_SUM_STRIDE finds them just as reliably as scanning every word -
// 512 samples still put 128 probes in each of the four halves. 513 reads instead
// of 131072: ~1 ms instead of ~240 ms.
//
// It is a rolling hash, not a sum, and that is deliberate. A sum - even one that
// XORs each word with its index - cannot see two halves swapped: the halves are a
// power of two apart, so a swap maps the sampled index set onto itself and the
// index terms cancel exactly. Measured, not assumed: the XOR-with-index version
// returned the identical value for the swapped buffer. FNV-1a makes the ORDER of
// the samples part of the result, so any permutation shows up.
//
// What it gives up: a single flipped word in one of the RK_SUM_STRIDE-1 gaps.
// That is a corruption mode this link has never shown. Build the firmware with
// -DRECKON_PS_FULL_CHECKSUM=1 to get the exhaustive scan back when hunting one.
//
// What NEITHER version can see - be honest about it: this payload ends in 543
// zero words (the last half is under-occupied), so a write truncated inside that
// tail leaves content identical to a correct one. No content check can catch
// that. Completeness is guaranteed by the ORDERING instead: the producer reads
// the last payload word back before it publishes the magic, so a consumer that
// sees the magic knows the burst has left the PS. The checksum is there for
// placement, not for completeness.
#define RK_SUM_STRIDE  256u  // words between samples

static inline uint32_t rk_sum32_sampled(const volatile uint32_t *p, uint32_t nwords) {
    uint32_t h = 0x811C9DC5u ^ nwords;  // bind the length in too
    for (uint32_t i = 0; i < nwords; i += RK_SUM_STRIDE) h = (h ^ p[i]) * 0x01000193u;
    if (nwords) h = (h ^ p[nwords - 1]) * 0x01000193u;
    return h;
}
