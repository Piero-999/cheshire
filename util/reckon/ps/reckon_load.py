#!/usr/bin/env python3
"""Load the Cheshire bitstream into the PL from PS Linux.

Runs on the ZCU102 PS. First step of the flow: the board holds the bitstream and
the training set, the PS configures the fabric over PCAP, writes the samples into
PL DDR4 (reckon_feed), and only then does JTAG come in from outside to load and
start the CVA6 firmware. See README.md section 5.1 in the repository root.

Two paths to the same PCAP. The default strips the .bit header, byte-swaps the
32-bit words and hands the result to the kernel FPGA manager - which is what PYNQ
does internally as well. It is the default because it depends on nothing but the
kernel: no venv, no environment variables, no XRT.

--pynq uses PYNQ instead. It needs two things that a non-login shell does not
have, and without them PYNQ fails with "AttributeError: 'NoneType' object has no
attribute 'xclOpen'" / "RuntimeError: No Devices Found", which looks like a
missing XRT and is not:
  * XILINX_XRT in the environment (set by /etc/profile.d/xrt_setup.sh, which
    `ssh host 'cmd'` never sources; the libraries themselves are in /usr/lib);
  * the venv interpreter /usr/local/share/pynq-venv/bin/python3 - the system
    python3 cannot import pynq (missing pydantic).
--pynq satisfies both by re-executing itself, so it works from a plain ssh too.

Caveat for anyone adding an .hwh: PYNQ 3.0's download() calls set_axi_port_width(),
which rewrites the FPD AFI registers from the design metadata. With a bare .bit
the call returns immediately and leaves the 128-bit HPM0_FPD setting this design
relies on untouched. With metadata present it may not, and it breaks the PS->DDR4
bridge silently.

Usage (on the board, as root):
    reckon_load.py cheshire.zcu102.bit               # fpga_manager, the default
    reckon_load.py cheshire.zcu102.bit --pynq        # try PYNQ first, fall back
    reckon_load.py cheshire.zcu102.bit --check       # parse and report, load nothing
Usage (on the dev host, to check a .bit before shipping it):
    reckon_load.py cheshire.zcu102.bit --check
"""

import argparse
import os
import struct
import sys
import time

FPGA_MAN = "/sys/class/fpga_manager/fpga0"
FIRMWARE_DIR = "/lib/firmware"


def die(msg):
    sys.exit("reckon_load: " + msg)


# Faithful to pynq.pl_server.device.parse_bit_header, so --raw and PYNQ produce
# byte-identical .bin files.
def parse_bit_header(path):
    with open(path, "rb") as f:
        contents = f.read()

    offset = 0
    length = struct.unpack(">h", contents[offset:offset + 2])[0]
    offset += 2 + length          # (2+n)-byte first field
    offset += 2                   # two-byte unknown field, usually 1

    info = {}
    while True:
        desc = contents[offset]
        offset += 1

        if desc != 0x65:
            length = struct.unpack(">h", contents[offset:offset + 2])[0]
            offset += 2
            data = struct.unpack(">{}s".format(length),
                                 contents[offset:offset + length])[0]
            data = data.decode("ascii")[:-1]
            offset += length

        if desc == 0x61:
            parts = data.split(";")
            info["design"], info["version"] = parts[0], parts[-1]
        elif desc == 0x62:
            info["part"] = data
        elif desc == 0x63:
            info["date"] = data
        elif desc == 0x64:
            info["time"] = data
        elif desc == 0x65:
            length = struct.unpack(">i", contents[offset:offset + 4])[0]
            offset += 4
            if length + offset != len(contents):
                die("{}: header says {} bytes of data but the file has {} left"
                    .format(path, length, len(contents) - offset))
            info["length"] = length
            info["data"] = contents[offset:offset + length]
            return info
        else:
            die("{}: unknown header field {:#x} - is this a .bit?".format(path, desc))


def bit_to_bin(data):
    """Byte-swap each 32-bit word, which is what the ZynqMP PCAP path expects."""
    n = len(data) // 4
    words = struct.unpack("<{}I".format(n), data[:n * 4])
    return struct.pack(">{}I".format(n), *words)


def fpga_state():
    try:
        with open(os.path.join(FPGA_MAN, "state")) as f:
            return f.read().strip()
    except OSError:
        return "<no fpga_manager>"


def load_raw(bitfile, info):
    """The PYNQ mechanism, without PYNQ: convert, stage, hand to fpga_manager."""
    if not os.path.isdir(FPGA_MAN):
        die("{} not present - is CONFIG_FPGA_MGR enabled in this kernel?".format(FPGA_MAN))

    binname = os.path.basename(bitfile).replace(".bit", "") + ".bin"
    binpath = os.path.join(FIRMWARE_DIR, binname)
    try:
        os.makedirs(FIRMWARE_DIR, exist_ok=True)
        with open(binpath, "wb") as f:
            f.write(bit_to_bin(info["data"]))
    except OSError as e:
        die("cannot stage {}: {} (run as root)".format(binpath, e))

    try:
        with open(os.path.join(FPGA_MAN, "flags"), "w") as f:
            f.write("0")                     # 0 = full bitstream, 1 = partial
        with open(os.path.join(FPGA_MAN, "firmware"), "w") as f:
            f.write(binname)
    except OSError as e:
        die("fpga_manager rejected the bitstream: {}".format(e))
    return binpath


PYNQ_VENV_PY = "/usr/local/share/pynq-venv/bin/python3"
XRT_ROOT = "/usr"


def load_pynq(bitfile):
    """Only reachable with --pynq. Re-executes under the venv interpreter with
    XILINX_XRT set if we are not already there, because PYNQ needs both and a
    non-login ssh session provides neither."""
    need_reexec = os.environ.get("XILINX_XRT") is None
    try:
        from pynq import Bitstream
    except ImportError:
        need_reexec = True

    if need_reexec:
        if os.environ.get("RECKON_LOAD_REEXEC"):
            raise RuntimeError("already re-executed and pynq is still unusable")
        if not os.path.exists(PYNQ_VENV_PY):
            raise RuntimeError("no pynq venv at " + PYNQ_VENV_PY)
        env = dict(os.environ, XILINX_XRT=XRT_ROOT, RECKON_LOAD_REEXEC="1")
        print("  (re-exec under {} with XILINX_XRT={})".format(PYNQ_VENV_PY, XRT_ROOT))
        os.execve(PYNQ_VENV_PY, [PYNQ_VENV_PY, os.path.abspath(__file__)]
                  + sys.argv[1:], env)

    from pynq import Bitstream
    Bitstream(bitfile).download()


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("bitfile")
    ap.add_argument("--pynq", action="store_true",
                    help="try PYNQ first, fall back to fpga_manager (PYNQ 3.0.1 on "
                         "this image cannot work - see the module docstring)")
    ap.add_argument("--raw", action="store_true",
                    help="deprecated, now the default; accepted for compatibility")
    ap.add_argument("--check", action="store_true", help="parse and report only, load nothing")
    ap.add_argument("--settle", type=float, default=1.0,
                    help="seconds to wait after configuring, for clk_wiz lock and "
                         "DDR4 calibration (default 1.0)")
    args = ap.parse_args()

    if not os.path.isfile(args.bitfile):
        die("no such file: " + args.bitfile)

    info = parse_bit_header(args.bitfile)
    print("bitstream: {}".format(args.bitfile))
    print("  design {}   part {}".format(info.get("design", "?"), info.get("part", "?")))
    print("  built  {} {}   vivado {}".format(info.get("date", "?"), info.get("time", "?"),
                                              info.get("version", "?")))
    print("  data   {} bytes".format(info["length"]))

    # The design targets xczu9eg on the ZCU102; loading a bitstream for another
    # part is refused by the FPGA manager anyway, but saying so here is clearer.
    part = info.get("part", "")
    if part and not part.startswith("xczu9"):
        die("part {} is not the ZCU102's xczu9eg - wrong bitstream".format(part))

    if args.check:
        print("check only, nothing loaded (fpga state: {})".format(fpga_state()))
        return 0

    print("state before: {}".format(fpga_state()))

    loaded = False
    if args.pynq:
        try:
            load_pynq(args.bitfile)
            print("loaded via PYNQ")
            loaded = True
        except Exception as e:                                  # noqa: BLE001
            print("PYNQ path failed ({}: {}), falling back to fpga_manager"
                  .format(type(e).__name__, e))
    if not loaded:
        path = load_raw(args.bitfile, info)
        print("loaded via fpga_manager ({})".format(path))

    state = fpga_state()
    print("state after : {}".format(state))
    if state not in ("operating", "<no fpga_manager>"):
        die("fpga_manager reports '{}', expected 'operating' - the PL is NOT configured. "
            "Do not let anything touch 0xA0000000.".format(state))

    # clk_wiz lock is microseconds; the DDR4 MIG recalibrates after every
    # reconfiguration and that is the slow part. reckon_feed re-probes the
    # aperture anyway before writing, so this is belt and braces.
    time.sleep(args.settle)
    print("PL configured. Next: reckon_feed to push the dataset into DDR4.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
