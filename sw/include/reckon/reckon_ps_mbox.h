// PS <-> CVA6 mailbox in PL DDR4, shared by the firmware (sw/tests/reckon_stream_ps*.c,
// RISC-V) and the PS producer (util/reckon/ps/reckon_feed.c, aarch64). Both
// toolchains compile it: stdint.h only.
//
// The two sides see the same DDR4 cells at different addresses:
//
//   PS 0xA000_0000 == CVA6 0x8000_0000
//
// The PS puts its HPM0 address on the bus unchanged, Cheshire decodes it as DRAM,
// and the DDR4 controller keeps only addr[28:0]: both land on offset 0.
//
// Nothing is cacheable on the CVA6 and the PS maps the aperture with O_SYNC, so no
// cache maintenance is needed; only ordering: the producer writes the magic last.

#pragma once

#include <stdint.h>

// ---------------------------------------------------------------------------
// Addresses
// ---------------------------------------------------------------------------
#define RK_PS_APERTURE_BASE   0xA0000000ull  // what the PS sees
#define RK_CVA6_DRAM_BASE     0x80000000ull  // what the CVA6 sees
#define RK_PS_TO_CVA6_OFFSET  (RK_PS_APERTURE_BASE - RK_CVA6_DRAM_BASE)  // 0x2000_0000

// Dataset payload at DRAM offset 0: 4 halves x 128 KiB = 512 KiB.
#define RK_DATA_OFF   0x00000000ull

// Mailbox at offset 1 MiB, clear of the dataset and of the firmware at 0x8080_0000.
#define RK_MBOX_OFF   0x00100000ull

#define RK_MBOX_CVA6_ADDR  (RK_CVA6_DRAM_BASE   + RK_MBOX_OFF)  // 0x8010_0000
#define RK_MBOX_PS_ADDR    (RK_PS_APERTURE_BASE + RK_MBOX_OFF)  // 0xA010_0000

// How much of the aperture the producer maps: up to the mailbox, rounded up.
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
//    12   0x30  CVA6->PS ack_chk_cy       cycles spent checking the payload
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
// The file is this 32-byte header followed by the payload exactly as it goes into
// DDR4: the producer copies it and does not pack anything.
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

// Plain 32-bit wrapping sum of the payload words. It validates the dataset file on
// the PS; the firmware runs it only with -DRECKON_PS_FULL_CHECKSUM=1.
static inline uint32_t rk_sum32(const volatile uint32_t *p, uint32_t nwords) {
    uint32_t s = 0;
    for (uint32_t i = 0; i < nwords; i++) s += p[i];
    return s;
}

// The handover check. A full sum over the uncached DDR4 would take ~240 ms, more
// than the epoch; this reads one word every RK_SUM_STRIDE plus the last, ~1 ms.
// FNV-1a, so the order of the samples counts and two swapped halves are caught.
#define RK_SUM_STRIDE  256u  // words between samples

static inline uint32_t rk_sum32_sampled(const volatile uint32_t *p, uint32_t nwords) {
    uint32_t h = 0x811C9DC5u ^ nwords;  // bind the length in too
    for (uint32_t i = 0; i < nwords; i += RK_SUM_STRIDE) h = (h ^ p[i]) * 0x01000193u;
    if (nwords) h = (h ^ p[nwords - 1]) * 0x01000193u;
    return h;
}
