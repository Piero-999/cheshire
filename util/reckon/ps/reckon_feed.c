// reckon_feed - push the training dataset from PS Linux into the PL DDR4, then
// hand it over to the CVA6 firmware and wait for the outcome.
//
// Runs on the ZCU102 PS (aarch64, PetaLinux). Counterpart of
// sw/tests/reckon_stream_ps.c on the RISC-V side; the shared contract - the
// address offset, the mailbox layout, the checksum, the dataset file format - is
// in reckon_ps_mbox.h, which both sides compile.
//
// HOW THE DATA GETS THERE
// ----------------------
// The Zynq master M_AXI_HPM0_FPD is bridged into the Cheshire AXI crossbar in
// hw/axi_reckon/rtl/xilinx_zcu102_reckon_chs_top.sv (id 16->2, then 128->64 bit).
// Cheshire decodes 0x8000_0000..0x1_0000_0000 to the DDR4 port, so the whole
// 0xA000_0000 aperture is DRAM; the PL DDR4 is 512 MiB and its wrapper truncates
// to addr[28:0], so 0xA000_0000 and 0x8000_0000 land on the same cell.
//
//     PS 0xA000_0000  ==  CVA6 0x8000_0000        (offset 0x2000_0000)
//
// TWO CONSTRAINTS
// ---------------
//  1. PROGRAM THE PL FIRST - reckon_load.py, right here on the PS. maxihpm0_fpd_aclk
//     comes from the PL clk_wiz: with an unprogrammed fabric that clock does not
//     run, the write never gets a response, and the GP master has no timeout - the
//     core hangs in the store, not in a signal handler. The liveness probe below
//     turns that into a diagnosis instead of a frozen shell, but it cannot undo it.
//  2. NO memcpy() ONTO THE APERTURE. /dev/mem with O_SYNC maps Device-nGnRnE
//     memory, where unaligned accesses fault and libc's memcpy is free to emit
//     them. Everything below moves data with aligned 32-bit stores on purpose.
//
// Usage:
//     reckon_feed [--data FILE] [--seq N] [--verify] [--no-wait]
//                 [--timeout SEC] [--probe]
//     reckon_feed --probe        aliasing check only, writes one word, no dataset

#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "reckon_ps_mbox.h"

#define PROBE_PATTERN  0xC0FFEE01u

// Only used to turn the cycle counts the firmware reports into milliseconds.
// This is the value the firmware measures against the RTC on every run, not a
// rounded 50.01: the cycles are the measurement, the milliseconds a convenience.
#define CORE_MHZ  50.0001

static const char *g_data = "reckon_dataset.bin";
static uint32_t    g_seq = 1;
static uint32_t    g_expect_seq = 0;   // 0 = no expectation (--status only)
static int         g_verify = 0, g_wait = 1, g_probe = 0, g_dry = 0, g_status = 0;
static double      g_timeout = 30.0;

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + 1e-9 * (double)ts.tv_nsec;
}

static void die(const char *what) {
    fprintf(stderr, "reckon_feed: %s: %s\n", what, strerror(errno));
    exit(1);
}

static void fail(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void fail(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fputs("reckon_feed: ", stderr);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
    exit(1);
}

// ---------------------------------------------------------------------------
// Device-memory accessors. Aligned 32-bit only; see note 2 in the header.
// ---------------------------------------------------------------------------
static inline void wr32(volatile uint32_t *p, uint32_t v) { *p = v; }
static inline uint32_t rd32(const volatile uint32_t *p) { return *p; }

// A read-back is the only thing that proves a burst of posted writes has landed;
// the same rule applies on the RISC-V side (README.md §2.4).
static inline void drain(const volatile uint32_t *p) {
    __sync_synchronize();
    (void)rd32(p);
    __sync_synchronize();
}

// ---------------------------------------------------------------------------
// Liveness probe: turn a silent hang into a diagnosis
// ---------------------------------------------------------------------------
// A write to the aperture cannot fail cleanly. If the PL is unconfigured its
// clk_wiz is dead, and if the DDR4 MIG has not finished calibrating its AXI shim
// holds ready low: either way the store never completes, there is no timeout on
// the GP master and no signal is raised - the core just stops retiring.
//
// So the probe runs in a child process: if it does not come back in time, the
// parent reports what happened instead of hanging with it. The child stays
// wedged and that CPU is lost until the board is rebooted.
static int probe_with_timeout(volatile uint32_t *cell, uint32_t pattern, double timeout_s) {
    pid_t pid = fork();
    if (pid < 0) die("fork for the liveness probe");

    if (pid == 0) {
        wr32(cell, pattern);
        __sync_synchronize();
        _exit(rd32(cell) == pattern ? 0 : 3);
    }

    double t0 = now_s();
    for (;;) {
        int status = 0;
        pid_t r = waitpid(pid, &status, WNOHANG);
        if (r == pid)
            return WIFEXITED(status) ? WEXITSTATUS(status) : 4;
        if (r < 0) die("waitpid on the liveness probe");
        if (now_s() - t0 > timeout_s) return -1;
        nanosleep(&(struct timespec){.tv_sec = 0, .tv_nsec = 5000000}, NULL);
    }
}

static void probe_or_explain(volatile uint32_t *cell, uint32_t pattern) {
    int rc = probe_with_timeout(cell, pattern, 5.0);
    if (rc == 0) return;

    if (rc == -1) {
        fprintf(stderr,
            "reckon_feed: the aperture did not answer within 5 s - the access is wedged.\n"
            "  Almost always one of:\n"
            "    * the PL is not configured   -> reckon_load.py <bitstream> first\n"
            "    * the DDR4 MIG is still calibrating after a fresh download\n"
            "                                 -> give it ~1 s (reckon_load.py --settle)\n"
            "  A CPU core is now stuck in that store and stays stuck until reboot.\n");
    } else if (rc == 3) {
        fprintf(stderr,
            "reckon_feed: the aperture answered but read back the wrong value.\n"
            "  The fabric is alive, so this is an addressing problem, not a hang.\n");
    } else {
        fprintf(stderr, "reckon_feed: liveness probe failed (rc=%d)\n", rc);
    }
    exit(3);
}

static void parse_args(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--data") && i + 1 < argc)        g_data = argv[++i];
        else if (!strcmp(argv[i], "--seq") && i + 1 < argc)    g_seq = (uint32_t)strtoul(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--timeout") && i + 1 < argc) g_timeout = strtod(argv[++i], NULL);
        else if (!strcmp(argv[i], "--verify"))                 g_verify = 1;
        else if (!strcmp(argv[i], "--no-verify"))              g_verify = 0;  // now the default
        else if (!strcmp(argv[i], "--no-wait"))                g_wait = 0;
        else if (!strcmp(argv[i], "--probe"))                  g_probe = 1;
        else if (!strcmp(argv[i], "--status"))                 g_status = 1;
        else if (!strcmp(argv[i], "--expect-seq") && i + 1 < argc)
            g_expect_seq = (uint32_t)strtoul(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--dry-run"))                g_dry = 1;
        else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
            printf("usage: %s [--data FILE] [--seq N] [--verify] [--no-wait]\n"
                   "          [--timeout SEC] [--probe] [--dry-run]\n"
                   "  --verify   read the 512 KiB back and compare word by word.\n"
                   "             Off by default: it costs ~85 ms against 8.7 ms of\n"
                   "             writing, and the firmware already samples the payload\n"
                   "             on its side. Turn it on when a run looks wrong.\n"
                   "  --probe    write one word at 0xA0000000 and read it back, no dataset\n"
                   "  --status   dump the mailbox (incl. the firmware's ack), change nothing\n"
                   "  --expect-seq N  with --status: fail unless the ack is for seq N\n"
                   "  --dry-run  validate the dataset file only, never touch /dev/mem\n", argv[0]);
            exit(0);
        } else fail("unknown argument '%s' (try --help)", argv[i]);
    }
}

// Reads the image emitted by util/reckon/gen_ps_dataset.py and validates its
// self-description before a single byte reaches the fabric.
static uint32_t *load_dataset(const char *path, rk_dsfile_hdr_t *hdr) {
    FILE *f = fopen(path, "rb");
    if (!f) die(path);

    if (fread(hdr, sizeof(*hdr), 1, f) != 1) fail("%s: truncated header", path);
    if (hdr->magic != RK_DSFILE_MAGIC)
        fail("%s: bad magic %08X (expected %08X) - not a gen_ps_dataset.py image",
             path, hdr->magic, RK_DSFILE_MAGIC);
    if (hdr->version != RK_DSFILE_VERSION)
        fail("%s: file version %u, this build speaks %u", path, hdr->version, RK_DSFILE_VERSION);
    if (hdr->payload_bytes != hdr->n_halves * hdr->half_words * 4u)
        fail("%s: payload_bytes %u inconsistent with %u halves x %u words",
             path, hdr->payload_bytes, hdr->n_halves, hdr->half_words);
    if (hdr->payload_bytes > RK_PS_MAP_BYTES - RK_MBOX_OFF)
        fail("%s: payload %u B would run into the mailbox at offset 0x%llx",
             path, hdr->payload_bytes, (unsigned long long)RK_MBOX_OFF);

    uint32_t *buf = malloc(hdr->payload_bytes);
    if (!buf) fail("out of memory for %u B of payload", hdr->payload_bytes);
    if (fread(buf, 1, hdr->payload_bytes, f) != hdr->payload_bytes)
        fail("%s: payload shorter than the header claims", path);
    fclose(f);

    uint32_t sum = 0, n = hdr->payload_bytes / 4u;
    for (uint32_t i = 0; i < n; i++) sum += buf[i];
    if (sum != hdr->checksum)
        fail("%s: checksum %08X does not match the header's %08X - file is corrupt",
             path, sum, hdr->checksum);
    return buf;
}

int main(int argc, char **argv) {
    parse_args(argc, argv);

    // Checking the image is worth doing without a board attached, so this path
    // runs before anything that needs /dev/mem or a programmed fabric.
    if (g_dry) {
        rk_dsfile_hdr_t h;
        uint32_t *b = load_dataset(g_data, &h);
        printf("dry-run  : %s is valid - %u halves x %u samples, %u words/half, "
               "%u KiB, checksum %08X\n",
               g_data, h.n_halves, h.samples_per_half, h.half_words,
               h.payload_bytes >> 10, h.checksum);
        printf("           would write PS 0x%08llX..0x%08llX (CVA6 0x%08llX..0x%08llX)\n",
               (unsigned long long)RK_PS_APERTURE_BASE,
               (unsigned long long)(RK_PS_APERTURE_BASE + h.payload_bytes),
               (unsigned long long)RK_CVA6_DRAM_BASE,
               (unsigned long long)(RK_CVA6_DRAM_BASE + h.payload_bytes));
        free(b);
        return 0;
    }

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) die("open /dev/mem (run as root)");

    // O_SYNC gives Device-nGnRnE: strongly ordered, no gathering, no caching.
    // This removes any need for cache maintenance against the CVA6, which has no
    // cacheable regions either.
    volatile uint32_t *ap = mmap(NULL, RK_PS_MAP_BYTES, PROT_READ | PROT_WRITE,
                                 MAP_SHARED, fd, (off_t)RK_PS_APERTURE_BASE);
    if (ap == MAP_FAILED) die("mmap of the HPM0 aperture");
    close(fd);

    volatile uint32_t *payload = ap + RK_DATA_OFF / 4;
    volatile uint32_t *mb      = ap + RK_MBOX_OFF / 4;

    printf("aperture : PS 0x%08llX -> CVA6 0x%08llX (%llu KiB mapped)\n",
           (unsigned long long)RK_PS_APERTURE_BASE,
           (unsigned long long)RK_CVA6_DRAM_BASE,
           (unsigned long long)RK_PS_MAP_BYTES >> 10);

    // -----------------------------------------------------------------------
    // --probe: the Phase 1 aliasing check, no dataset involved
    // -----------------------------------------------------------------------
    if (g_probe) {
        probe_or_explain(payload, PROBE_PATTERN);
        uint32_t got = rd32(payload);
        printf("probe    : wrote %08X at PS 0x%08llX, read back %08X -> %s\n",
               PROBE_PATTERN, (unsigned long long)RK_PS_APERTURE_BASE, got,
               got == PROBE_PATTERN ? "PS side OK" : "MISMATCH");
        printf("           now confirm from the dev host that CVA6 0x%08llX reads %08X:\n"
               "             monitor mdw 0x%08llX  (GDB over JTAG)\n",
               (unsigned long long)RK_CVA6_DRAM_BASE, PROBE_PATTERN,
               (unsigned long long)RK_CVA6_DRAM_BASE);
        return got == PROBE_PATTERN ? 0 : 1;
    }

    // -----------------------------------------------------------------------
    // --status: dump the mailbox after a run, without touching anything
    // -----------------------------------------------------------------------
    // This exists because there is no other safe way to read it from the PS.
    // devmem is not installed on this image, and a Python mmap slice is worse
    // than useless: the aperture is Device-nGnRnE, so the bulk memcpy behind
    // m[0:64] issues unaligned / multi-register loads and returns a scrambled
    // mix of neighbouring words. Every read below is a single aligned 32-bit
    // volatile load, which is the only access width this mapping supports.
    if (g_status) {
        static const char *nm[RK_MBOX_WORDS] = {
            [RK_MBOX_W_MAGIC]      = "MAGIC",
            [RK_MBOX_W_SEQ]        = "SEQ",
            [RK_MBOX_W_N_HALVES]   = "N_HALVES",
            [RK_MBOX_W_SAMPLES]    = "SAMPLES",
            [RK_MBOX_W_HALF_WORDS] = "HALF_WORDS",
            [RK_MBOX_W_CHECKSUM]   = "CHECKSUM",
            [RK_MBOX_W_SAMPLE_SUM] = "SAMPLE_SUM",
            [RK_MBOX_W_ACK]        = "ACK",
            [RK_MBOX_W_ACK_SEQ]    = "ACK_SEQ",
            [RK_MBOX_W_ACK_STATUS] = "ACK_STATUS",
            [RK_MBOX_W_ACK_EPOCH]  = "ACK_EPOCH",
            [RK_MBOX_W_ACK_CHK_CY] = "ACK_CHK_CY",
            [RK_MBOX_W_PROBE]      = "PROBE",
        };
        printf("mailbox  : PS 0x%08llX (CVA6 0x%08llX)\n",
               (unsigned long long)RK_MBOX_PS_ADDR,
               (unsigned long long)RK_MBOX_CVA6_ADDR);
        for (uint32_t i = 0; i < RK_MBOX_WORDS; i++) {
            if (!nm[i]) continue;
            printf("  w%-2u %-11s = 0x%08X  (%u)\n", i, nm[i], rd32(&mb[i]), rd32(&mb[i]));
        }

        uint32_t magic  = rd32(&mb[RK_MBOX_W_MAGIC]);
        uint32_t ack    = rd32(&mb[RK_MBOX_W_ACK]);
        uint32_t aseq   = rd32(&mb[RK_MBOX_W_ACK_SEQ]);
        uint32_t status = rd32(&mb[RK_MBOX_W_ACK_STATUS]);
        uint32_t epoch  = rd32(&mb[RK_MBOX_W_ACK_EPOCH]);
        uint32_t chkcy  = rd32(&mb[RK_MBOX_W_ACK_CHK_CY]);

        printf("\nreading  : magic %s (%s)\n",
               magic == RK_MBOX_MAGIC ? "STILL SET" : "cleared",
               magic == RK_MBOX_MAGIC ? "the firmware has not consumed the handover yet"
                                      : "the firmware consumed the handover");
        if ((ack & 0xFFFF0000u) == RK_MBOX_ACK_BASE) {
            printf("           ack   %08X for seq %u, rc=%u\n", ack, aseq, ack & 0xFFFFu);
            printf("           stream_status %08X -> fill_cnt=%u consumed=%u "
                   "underrun=%u overrun=%u\n", status,
                   (status >> 16) & 0xFFu, (status >> 8) & 0xFFu,
                   (status >> 5) & 1u, (status >> 6) & 1u);
            printf("           epoch cycles %u (%.2f ms at %g MHz)\n",
                   epoch, epoch / (CORE_MHZ * 1e3), CORE_MHZ);
            // The handover check must stay a rounding error next to the epoch it
            // guards. If this ever climbs back to a sizeable fraction, someone
            // rebuilt with -DRECKON_PS_FULL_CHECKSUM=1.
            if (chkcy)
                printf("           handover check %u cycles (%.2f ms, %.1f%% of the epoch)\n",
                       chkcy, chkcy / (CORE_MHZ * 1e3),
                       epoch ? 100.0 * chkcy / epoch : 0.0);
        } else {
            printf("           ack   %08X - no valid ack present (expected %08Xxxxx)\n",
                   ack, RK_MBOX_ACK_BASE >> 16);
        }

        // The check that makes --no-wait safe. Without it, a run that consumed a
        // stale handover is indistinguishable from a healthy one: same rc, same
        // counters, same checksum - only the sequence number differs.
        if (g_expect_seq) {
            int ok = ((ack & 0xFFFF0000u) == RK_MBOX_ACK_BASE) && (aseq == g_expect_seq);
            printf("           expected seq %u -> %s\n", g_expect_seq,
                   ok ? "MATCH" : "MISMATCH");
            if (!ok) {
                fprintf(stderr,
                    "reckon_feed: the firmware did not acknowledge this handover.\n"
                    "  acked seq %u, this feed sent %u.\n"
                    "  Either the run consumed a STALE handover left by an earlier\n"
                    "  feed whose consumer never showed up, or it never reached STEP 2.\n"
                    "  The data streamed was NOT necessarily the data you just pushed.\n",
                    aseq, g_expect_seq);
                return 3;
            }
        }
        return 0;
    }

    // -----------------------------------------------------------------------
    // Load, push, verify
    // -----------------------------------------------------------------------
    rk_dsfile_hdr_t hdr;
    uint32_t *src = load_dataset(g_data, &hdr);
    uint32_t nwords = hdr.payload_bytes / 4u;

    printf("dataset  : %s, %u halves x %u samples, %u KiB, checksum %08X\n",
           g_data, hdr.n_halves, hdr.samples_per_half, hdr.payload_bytes >> 10,
           hdr.checksum);

    // Touch one word before committing to 512 KiB of stores: if the fabric is
    // not there, this is where it is reported, rather than halfway through the
    // payload.
    probe_or_explain(&mb[RK_MBOX_W_PROBE], PROBE_PATTERN);

    // A magic still standing means the PREVIOUS handover was never consumed -
    // the firmware timed out, or was never started. The next run to reach STEP 2
    // would consume it and stream the old buffer while reporting success: the
    // checksum cannot catch that, since payload and checksum both come from the
    // same stale feed. Only the sequence number distinguishes them.
    uint32_t stale = rd32(&mb[RK_MBOX_W_MAGIC]);
    if (stale == RK_MBOX_MAGIC) {
        fprintf(stderr,
            "reckon_feed: WARNING - handover seq %u was never consumed.\n"
            "  A run started before this feed would have used THAT data, not this.\n"
            "  Overwriting it now; check the ack reports seq %u when the run ends.\n",
            rd32(&mb[RK_MBOX_W_SEQ]), g_seq);
    }

    // Retract any standing handover before touching the payload: for the whole
    // time we are rewriting those 512 KiB, the old magic would otherwise still
    // be advertising a buffer that is being overwritten underneath a consumer.
    wr32(&mb[RK_MBOX_W_MAGIC], 0);
    drain(&mb[RK_MBOX_W_MAGIC]);

    // Clear the ack before publishing anything, so a stale ack from a previous
    // run cannot be mistaken for this one's.
    wr32(&mb[RK_MBOX_W_ACK], 0);
    wr32(&mb[RK_MBOX_W_ACK_CHK_CY], 0);
    drain(&mb[RK_MBOX_W_ACK]);

    double t0 = now_s();
    for (uint32_t i = 0; i < nwords; i++) wr32(&payload[i], src[i]);
    drain(&payload[nwords - 1]);
    double t_wr = now_s() - t0;

    printf("write    : %u KiB in %.1f ms (%.1f MiB/s)\n", hdr.payload_bytes >> 10,
           t_wr * 1e3, (double)hdr.payload_bytes / t_wr / (1024.0 * 1024.0));

    if (g_verify) {
        t0 = now_s();
        uint32_t sum = 0, bad = 0, first_bad = 0;
        for (uint32_t i = 0; i < nwords; i++) {
            uint32_t v = rd32(&payload[i]);
            sum += v;
            if (v != src[i] && !bad++) first_bad = i;
        }
        double t_rd = now_s() - t0;
        if (bad)
            fail("read-back: %u/%u words differ, first at word %u "
                 "(PS 0x%08llX): wrote %08X, read %08X",
                 bad, nwords, first_bad,
                 (unsigned long long)(RK_PS_APERTURE_BASE + 4ull * first_bad),
                 src[first_bad], rd32(&payload[first_bad]));
        if (sum != hdr.checksum)
            fail("read-back sum %08X != %08X although every word matched", sum, hdr.checksum);
        printf("verify   : %u words identical, checksum %08X confirmed (%.1f ms)\n",
               nwords, sum, t_rd * 1e3);
    }

    // -----------------------------------------------------------------------
    // Hand over: fields first, MAGIC last. On Device memory the stores cannot be
    // reordered, but the read-back also guarantees they have left the PS before
    // the CVA6 can observe the magic.
    // -----------------------------------------------------------------------
    wr32(&mb[RK_MBOX_W_SEQ],        g_seq);
    wr32(&mb[RK_MBOX_W_N_HALVES],   hdr.n_halves);
    wr32(&mb[RK_MBOX_W_SAMPLES],    hdr.samples_per_half);
    wr32(&mb[RK_MBOX_W_HALF_WORDS], hdr.half_words);
    wr32(&mb[RK_MBOX_W_CHECKSUM],   hdr.checksum);
    // The sum the firmware will actually compare against. Computed here over the
    // source buffer in ordinary cached RAM - microseconds - so that the CVA6 can
    // do its side with 513 uncached reads instead of 131072. rk_sum32_sampled in
    // reckon_ps_mbox.h documents what that trades away.
    wr32(&mb[RK_MBOX_W_SAMPLE_SUM], rk_sum32_sampled(src, nwords));
    drain(&mb[RK_MBOX_W_SAMPLE_SUM]);

    wr32(&mb[RK_MBOX_W_MAGIC], RK_MBOX_MAGIC);
    drain(&mb[RK_MBOX_W_MAGIC]);

    printf("handover : mailbox at PS 0x%08llX (CVA6 0x%08llX), seq=%u, magic %08X\n",
           (unsigned long long)RK_MBOX_PS_ADDR, (unsigned long long)RK_MBOX_CVA6_ADDR,
           g_seq, RK_MBOX_MAGIC);

    if (!g_wait) {
        printf("         : --no-wait, not polling for the ack. Now run on the dev host:\n"
               "             util/reckon/reckon.py start\n");
        free(src);
        return 0;
    }

    // -----------------------------------------------------------------------
    // Wait for the firmware. The PS cannot read stream_status itself in this
    // bitstream (HPM0 only reaches DRAM, not the 0x4000_0000 window), so the
    // firmware mirrors the outcome into the mailbox for us.
    // -----------------------------------------------------------------------
    printf("waiting  : for the CVA6 ack, up to %.0f s "
           "(start the ELF on the dev host now if you have not)\n", g_timeout);
    fflush(stdout);

    t0 = now_s();
    uint32_t ack = 0;
    for (;;) {
        ack = rd32(&mb[RK_MBOX_W_ACK]);
        if (RK_MBOX_IS_ACK(ack)) break;
        if (now_s() - t0 > g_timeout) {
            uint32_t magic = rd32(&mb[RK_MBOX_W_MAGIC]);
            fprintf(stderr, "reckon_feed: timeout after %.0f s with no ack.\n", g_timeout);
            fprintf(stderr, "  mailbox magic now %08X: %s\n", magic,
                    magic == RK_MBOX_MAGIC
                        ? "still set -> the firmware never got there (was the ELF run?)"
                        : "cleared -> the firmware took the data but did not finish");
            free(src);
            return 2;
        }
        nanosleep(&(struct timespec){.tv_sec = 0, .tv_nsec = 2000000}, NULL);
    }

    uint32_t rc     = RK_MBOX_ACK_RC(ack);
    uint32_t aseq   = rd32(&mb[RK_MBOX_W_ACK_SEQ]);
    uint32_t status = rd32(&mb[RK_MBOX_W_ACK_STATUS]);
    uint32_t epoch  = rd32(&mb[RK_MBOX_W_ACK_EPOCH]);

    // stream_status layout, stream_ctrl_fsm2.sv (also documented in
    // README.md §6).
    printf("ack      : rc=%u seq=%u (sent %u) after %.1f s\n",
           rc, aseq, g_seq, now_s() - t0);
    printf("status   : %08X  ver=%02X fill_cnt=%u consumed=%u "
           "underrun=%u overrun=%u owner=%u\n",
           status, (status >> 24) & 0xFF, (status >> 16) & 0xFF, (status >> 8) & 0xFF,
           (status >> 5) & 1, (status >> 6) & 1, status & 3);
    printf("epoch    : %u core cycles\n", epoch);
    if (aseq != g_seq)
        printf("NOTE     : the ack echoes seq %u, not %u - this is an older run's ack\n",
               aseq, g_seq);

    free(src);
    return rc == 0 ? 0 : 1;
}
