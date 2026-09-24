#!/usr/bin/env python3
"""Emit the DDR4 dataset image that the PS writes over M_AXI_HPM0_FPD.

It packs the samples as rk_pack_half() does (sw/include/reckon/reckon_stream.h),
so the PS producer only copies bytes. The geometry and the samples are parsed out
of the firmware sources:

    HALF_WORDS                       sw/include/reckon/reckon_bringup.h
    SAMPLES_PER_HALF, N_HALVES_TOTAL sw/include/reckon/reckon_stream.h
    ref_sample[][], ref_sample_len[] sw/include/reckon/reckon_dataset_ref.h

Output: a 32-byte rk_dsfile_hdr_t (sw/include/reckon/reckon_ps_mbox.h) followed
by n_halves * half_words * 4 bytes of payload.

Usage:
    util/reckon/gen_ps_dataset.py [-o util/reckon/ps/reckon_dataset.bin]
    util/reckon/gen_ps_dataset.py --break-eos 3:20     # fault injection

--break-eos HALF:SAMPLE (or RK_BREAK_EOS in the environment, which also reaches
it through reckon.py build) turns that sample's end-of-sample word into a no-op
and recomputes the checksum, so the file stays valid and the handover reports
success. The half then never reaches END_B and the epoch stalls: ReckOn's data
comes through the iDMA and nowhere else. Regenerate a clean image afterwards.
"""

import argparse
import os
import re
import struct
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
INC = REPO / "sw" / "include" / "reckon"

DSFILE_MAGIC = 0x524B4453
DSFILE_VERSION = 1


def die(msg):
    sys.exit(f"gen_ps_dataset: {msg}")


def read(path):
    if not path.is_file():
        die(f"missing source file {path}")
    return path.read_text()


def grab_define(text, name, path):
    """#define NAME <int>, tolerating a trailing u/U and a comment."""
    m = re.search(rf"^\s*#define\s+{name}\s+(0[xX][0-9a-fA-F]+|\d+)[uU]?\b", text, re.M)
    if not m:
        die(f"could not find #define {name} in {path}")
    return int(m.group(1), 0)


def brace_groups(text, start):
    """Yield the top-level {...} groups of an initialiser starting at `start`."""
    depth = 0
    buf = []
    for ch in text[start:]:
        if ch == "{":
            depth += 1
            if depth == 2:
                buf = []
                continue
        elif ch == "}":
            depth -= 1
            if depth == 1:
                yield "".join(buf)
                continue
            if depth == 0:
                return
        if depth >= 2:
            buf.append(ch)


def parse_dataset(text, path):
    m = re.search(r"ref_sample_len\s*\[[^\]]*\]\s*=\s*\{([^}]*)\}", text)
    if not m:
        die(f"could not parse ref_sample_len[] in {path}")
    lens = [int(x, 0) for x in re.findall(r"0[xX][0-9a-fA-F]+|\d+", m.group(1))]

    m = re.search(r"ref_sample\s*\[[^\]]*\]\s*\[[^\]]*\]\s*=\s*", text)
    if not m:
        die(f"could not parse ref_sample[][] in {path}")
    samples = []
    for group in brace_groups(text, m.end()):
        samples.append([int(x, 0) for x in re.findall(r"0[xX][0-9a-fA-F]+|\d+", group)])

    if len(samples) != len(lens):
        die(f"ref_sample has {len(samples)} rows but ref_sample_len has {len(lens)}")
    for i, (row, n) in enumerate(zip(samples, lens)):
        if len(row) < n:
            die(f"ref_sample[{i}] holds {len(row)} words, ref_sample_len says {n}")
    return [row[:n] for row, n in zip(samples, lens)], lens


def pack_half(samples, lens, first, samples_per_half, half_words):
    """Faithful port of rk_pack_half() in sw/include/reckon/reckon_stream.h."""
    n_ref = len(lens)
    out = []
    packed = 0
    for n in range(samples_per_half):
        s = (first + n) % n_ref
        if len(out) + lens[s] > half_words:
            break  # never cross the half
        out.extend(samples[s])
        packed += 1
    used = len(out)
    out.extend([0] * (half_words - used))  # code 0 = no-op, ReckOn reads and drops it
    return out, packed, used


RK_SUM_STRIDE = 256  # keep in sync with reckon_ps_mbox.h


def break_eos(payload, spec, n_halves, half_words, samples_per_half):
    """Fault injection: blank one end-of-sample word. See the module docstring."""
    try:
        h_s, s_s = spec.split(":")
        half, nth = int(h_s), int(s_s)
    except ValueError:
        die(f"--break-eos wants HALF:SAMPLE (e.g. 3:20), got '{spec}'")
    if not 0 <= half < n_halves:
        die(f"--break-eos: half {half} out of range (0..{n_halves - 1})")
    if not 0 <= nth < samples_per_half:
        die(f"--break-eos: sample {nth} out of range (0..{samples_per_half - 1})")

    base = half * half_words
    eos = [i for i in range(base, base + half_words)
           if (payload[i] >> 24) & 0xF == 1]
    if len(eos) != samples_per_half:
        die(f"--break-eos: half {half} has {len(eos)} EOS words, expected {samples_per_half}")

    off = eos[nth]
    old = payload[off]
    payload[off] = old & ~(0xF << 24)  # code 1 -> 0: read and dropped in READM

    # Whether the firmware's sampled hash happens to read this word decides
    # whether the fault is silent or caught, so say which one this is.
    sampled = (off % RK_SUM_STRIDE == 0) or (off == len(payload) - 1)
    print(f"BREAK-EOS: payload word {off} (half {half}, sample {nth}): "
          f"{old:08X} -> {payload[off]:08X}")
    print(f"           half {half} now has {len(eos) - 1}/{samples_per_half} complete samples "
          f"-> END_B can never fire on it")
    print("           this word IS sampled by the firmware hash: the handover will be REJECTED"
          if sampled else
          f"           word index % {RK_SUM_STRIDE} = {off % RK_SUM_STRIDE} -> not sampled: "
          "the handover check will PASS, unchanged")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-o", "--output", type=Path,
                    default=REPO / "util" / "reckon" / "ps" / "reckon_dataset.bin")
    ap.add_argument("--break-eos", metavar="HALF:SAMPLE",
                    help="fault injection: blank that sample's end-of-sample word "
                         "(also read from RK_BREAK_EOS). See the module docstring.")
    args = ap.parse_args()

    bringup_p, stream_p, ds_p = (INC / "reckon_bringup.h",
                                 INC / "reckon_stream.h",
                                 INC / "reckon_dataset_ref.h")
    bringup, stream, ds = read(bringup_p), read(stream_p), read(ds_p)

    half_words = grab_define(bringup, "HALF_WORDS", bringup_p)
    samples_per_half = grab_define(stream, "SAMPLES_PER_HALF", stream_p)
    n_halves = grab_define(stream, "N_HALVES_TOTAL", stream_p)
    samples, lens = parse_dataset(ds, ds_p)
    n_ref = len(lens)

    print(f"geometry : HALF_WORDS={half_words} SAMPLES_PER_HALF={samples_per_half} "
          f"N_HALVES_TOTAL={n_halves}")
    print(f"dataset  : {n_ref} reference samples, lengths {lens}")

    payload = []
    min_used, max_used = half_words, 0
    for b in range(n_halves):
        words, packed, used = pack_half(samples, lens, (b * samples_per_half) % n_ref,
                                        samples_per_half, half_words)
        # Same guard as reckon_prepare_ddr(): a short half leaves ReckOn waiting at
        # END_B for an EOS that was never written, i.e. a hang instead of an error.
        if packed != samples_per_half:
            die(f"half {b}: only {packed}/{samples_per_half} samples fit ({used} words). "
                f"Lower SAMPLES_PER_HALF in {stream_p}.")
        payload.extend(words)
        min_used, max_used = min(min_used, used), max(max_used, used)
        print(f"  half {b}: {packed} samples, {used}/{half_words} words "
              f"({100.0 * used / half_words:.1f}% full)")

    spec = args.break_eos or os.environ.get("RK_BREAK_EOS")
    if spec:
        break_eos(payload, spec, n_halves, half_words, samples_per_half)

    blob = struct.pack("<%dI" % len(payload), *payload)
    checksum = sum(payload) & 0xFFFFFFFF

    hdr = struct.pack("<8I", DSFILE_MAGIC, DSFILE_VERSION, n_halves, half_words,
                      samples_per_half, len(blob), checksum, 0)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(hdr + blob)

    print(f"occupancy: {min_used}-{max_used}/{half_words} words")
    print(f"checksum : 0x{checksum:08X}")
    print(f"written  : {args.output}  ({len(hdr) + len(blob)} bytes, "
          f"{len(blob)} of payload)")
    print(f"the PS writes the payload at 0xA0000000 (= CVA6 0x80000000)")


if __name__ == "__main__":
    main()
