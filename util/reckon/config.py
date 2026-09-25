#!/usr/bin/env python3

"""Settings for the ReckOn flow.

reckon.py reads these as attributes; config.sh prints them as shell exports,
for the ILA scripts. Any of them can be overridden from the environment:

    PS_HOST=192.168.5.24 util/reckon/reckon.py load
"""

import os
import shlex
import sys
from pathlib import Path


def _env(name, default):
    return os.environ.get(name) or default


# Repository root, from the location of this file: util/reckon/config.py.
# The working directory is not reliable: Vivado and GDB are started from
# wherever the caller happened to be.
REPO = Path(_env("REPO", Path(__file__).resolve().parents[2]))
SCRIPT_DIR = Path(_env("SCRIPT_DIR", REPO / "util" / "reckon"))
OUT_DIR = Path(_env("OUT_DIR", SCRIPT_DIR / "out"))

# --- tools -----------------------------------------------------------------
OPENOCD = _env("OPENOCD", "/usr/bin/openocd")
GDB = _env("GDB", "/tools/riscv/bin/riscv64-unknown-elf-gdb")
GCC_BINROOT = _env("GCC_BINROOT", "/tools/riscv/bin")
OPENOCD_CFG = Path(_env("OPENOCD_CFG", REPO / "util/openocd.olimex.tcl"))

# --- artifacts -------------------------------------------------------------
BIT = Path(_env("BIT", REPO / "target/xilinx/out/cheshire.zcu102.bit"))

# The streaming tests. ELF_CVA6 and ELF_IDMA differ only in the DDR4 -> BRAM
# transport; ELF_PS takes the dataset from the PS (README.md section 4.3) and
# ELF_LOOP serves one epoch per handover (README.md section 5.10).
ELF_CVA6 = Path(_env("ELF_CVA6", REPO / "sw/tests/reckon_stream_cva6.dram.elf"))
ELF_IDMA = Path(_env("ELF_IDMA", REPO / "sw/tests/reckon_stream_idma.dram.elf"))
ELF_PS = Path(_env("ELF_PS", REPO / "sw/tests/reckon_stream_ps.dram.elf"))
ELF_LOOP = Path(_env("ELF_LOOP", REPO / "sw/tests/reckon_stream_ps_loop.dram.elf"))

# --- a run -----------------------------------------------------------------
DRAM_ENTRY = _env("DRAM_ENTRY", "0x80800000")
PS_SLEEP_MS = int(_env("PS_SLEEP_MS", "15000"))
# How long `loop` waits before asking the firmware whether it is listening.
LOOP_SETTLE_MS = int(_env("LOOP_SETTLE_MS", "3000"))

# --- the board -------------------------------------------------------------
PS_HOST = _env("PS_HOST", "192.168.5.10")
PS_USER = _env("PS_USER", "xilinx")
# The image's default password. sudo on the board asks for it (the user is in
# group sudo, not NOPASSWD); it is given to `sudo -S` on standard input.
PS_PASSWORD = _env("PS_PASSWORD", "xilinx")
PS_DIR = _env("PS_DIR", "/home/%s/reckon" % PS_USER)
PS_SRC_DIR = SCRIPT_DIR / "ps"
DATASET = Path(_env("DATASET", PS_SRC_DIR / "reckon_dataset.bin"))

_EXPORTED = [
    "REPO", "SCRIPT_DIR", "OUT_DIR",
    "OPENOCD", "GDB", "GCC_BINROOT", "OPENOCD_CFG", "BIT",
    "ELF_CVA6", "ELF_IDMA", "ELF_PS", "ELF_LOOP",
    "DRAM_ENTRY", "PS_HOST", "PS_USER", "PS_DIR",
]


def as_shell():
    """The exported values as `export NAME=...` lines, for config.sh to eval."""
    return "\n".join("export %s=%s" % (name, shlex.quote(str(globals()[name])))
                     for name in _EXPORTED)


def ensure_out_dir():
    OUT_DIR.mkdir(parents=True, exist_ok=True)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--sh":
        ensure_out_dir()
        print(as_shell())
    else:
        for name in _EXPORTED:
            print("%-12s %s" % (name, globals()[name]))
