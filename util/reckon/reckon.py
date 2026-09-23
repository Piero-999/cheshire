#!/usr/bin/env python3

"""Drive the ReckOn streaming flow from the development host.

    1. the PS configures the PL over PCAP       [reckon_load.py, on the PS]
    2. the PS writes the samples into PL DDR4   [reckon_feed,    on the PS]
    3. JTAG loads and starts the CVA6 firmware  [OpenOCD + GDB,  from here]

Steps 1 and 2 are issued over ssh; only step 3 comes from outside. The order
matters: writing into the aperture with an unprogrammed fabric hangs the ARM
core in the store (README.md section 5.1).

    reckon.py build           the firmware ELFs and the dataset image
    reckon.py sync            ship them, build reckon_feed on the board
    reckon.py load            the PS configures the PL
    reckon.py probe           check that PS 0xA000_0000 is CVA6 0x8000_0000
    reckon.py feed            one handover
    reckon.py start           load and start the firmware over JTAG
    reckon.py ack             which handover the firmware acknowledged
    reckon.py all             sync, load, feed, start, check the ack

    reckon.py loop            start the looping firmware, leave it listening
    reckon.py feed --epochs N N handovers, one epoch each
    reckon.py status          the session state

ssh uses a key when there is one (`ssh-copy-id $PS_USER@$PS_HOST`), otherwise
the password in config.py.
"""

import argparse
import hashlib
import os
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import config  # noqa: E402


def say(msg):
    print("\n== %s ==" % msg, flush=True)


def die(msg, code=1):
    # stdout is block-buffered when piped, stderr is not: flush, or the failure
    # appears before the line it follows.
    sys.stdout.flush()
    print(msg, file=sys.stderr, flush=True)
    sys.exit(code)


def run(cmd, **kwargs):
    kwargs.setdefault("check", False)
    return subprocess.run(cmd, **kwargs)


def clean_env():
    """An environment without Vivado's Python and library paths.

    ila_capture.tcl reaches this script through Vivado's `exec`, and the
    inherited PYTHONHOME/PYTHONPATH/LD_LIBRARY_PATH break GDB.
    """
    env = os.environ.copy()
    for name in ("PYTHONHOME", "PYTHONPATH", "LD_LIBRARY_PATH"):
        env.pop(name, None)
    return env


# --- the board -------------------------------------------------------------

class Board:
    """The ZCU102's PS, over ssh."""

    def __init__(self):
        self.host = config.PS_HOST
        self.user = config.PS_USER
        self.dir = config.PS_DIR
        self.password = config.PS_PASSWORD
        self._askpass = None
        self._key_works = None
        self._link_checked = False
        self.opts = ["-o", "ConnectTimeout=8", "-o", "StrictHostKeyChecking=accept-new"]

    def _askpass_env(self):
        # ssh reads a password only from a helper program, never from a pipe.
        # The helper prints what it finds in the environment, so the password
        # is not in the file either.
        if self._askpass is None:
            handle = tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False)
            handle.write('#!/bin/sh\nprintf "%s\\n" "$PS_PASSWORD"\n')
            handle.close()
            os.chmod(handle.name, 0o700)
            self._askpass = handle.name
        env = clean_env()
        env.update(SSH_ASKPASS=self._askpass, SSH_ASKPASS_REQUIRE="force",
                   DISPLAY=env.get("DISPLAY", ":0"), PS_PASSWORD=self.password)
        return env

    def _have_key(self):
        """Whether a key logs us in. PS_FORCE_PASSWORD=1 skips the question."""
        if os.environ.get("PS_FORCE_PASSWORD"):
            return False
        if self._key_works is None:
            probe = run(["ssh"] + self.opts + ["-o", "BatchMode=yes",
                                               "%s@%s" % (self.user, self.host), "true"],
                        capture_output=True, env=clean_env())
            self._key_works = probe.returncode == 0
        return self._key_works

    def _transport(self, tty=False):
        if self.password and not self._have_key():
            env = self._askpass_env()
            prefix = ["setsid", "-w", "ssh"] + self.opts + [
                "-o", "PreferredAuthentications=password",
                "-o", "PubkeyAuthentication=no"]
        else:
            env = clean_env()
            prefix = ["ssh"] + self.opts
        if tty:
            prefix.append("-t")
        return prefix, env

    def sh(self, command, *, tty=False, capture=False, stdin=None):
        prefix, env = self._transport(tty=tty)
        argv = prefix + ["%s@%s" % (self.user, self.host), command]
        return subprocess.run(argv, env=env, text=True, input=stdin,
                              capture_output=capture)

    def sudo(self, command, *, capture=False):
        """Run a command as root, from the flow's directory on the board.

        The password goes to `sudo -S` on standard input, so it is not on a
        command line. Without one, ask for a tty and let the caller type it.
        """
        where = shlex.quote(self.dir)
        if self.password:
            return self.sh("cd %s && sudo -S -p '' %s" % (where, command),
                           capture=capture, stdin=self.password + "\n")
        return self.sh("cd %s && sudo %s" % (where, command),
                       tty=True, capture=capture)

    def put(self, *paths):
        prefix, env = self._transport()
        argv = [("scp" if a == "ssh" else a) for a in prefix]
        argv += [str(p) for p in paths]
        argv.append("%s@%s:%s/" % (self.user, self.host, self.dir))
        return subprocess.run(argv, env=env, text=True)

    def cleanup(self):
        if self._askpass:
            os.unlink(self._askpass)
            self._askpass = None

    def check_link(self):
        """The board must be on a directly attached link, not behind a gateway.

        A gateway in the route means the adapter has lost its address and
        something else is answering at that address; a ping cannot tell.
        """
        if self._link_checked:
            return
        self._link_checked = True
        say("Checking %s" % self.host)
        route = run(["ip", "-o", "route", "get", self.host],
                    capture_output=True, text=True).stdout.strip()
        if " via " in route:
            die("%s is not on a directly attached link - it routes through a "
                "gateway:\n    %s\nRefusing to continue: the adapter should "
                "hold 192.168.5.20/24." % (self.host, route))

        parts = route.split()
        iface = parts[parts.index("dev") + 1] if "dev" in parts else ""
        ping = ["ping", "-c1", "-W2"] + (["-I", iface] if iface else []) + [self.host]
        if run(ping, capture_output=True).returncode != 0:
            die("%s does not answer%s. Board powered, SD inserted, SW6 on SD "
                "boot? Another address? Override with PS_HOST=... and PS_USER=..."
                % (self.host, " on %s" % iface if iface else ""))
        print("%s is up on %s" % (self.host, iface or "the default route"))


# --- JTAG ------------------------------------------------------------------

SCRATCH_LEGEND = ("=== s0=fill/half s1=epoch s3=step s4,s5,s7,s8=cons/half "
                  "s6=fill-in-epoch s9=cy per 100ms sA=status@bringup "
                  "sB=status@done ===")


class Jtag:
    """OpenOCD on the Olimex adapter, and GDB talking to it.

    Started and stopped per command. It drives a different adapter and TAP from
    Vivado's hw_server, so both can be connected at once.
    """

    def __enter__(self):
        config.ensure_out_dir()
        log = open(config.OUT_DIR / "openocd.log", "w")
        self.proc = subprocess.Popen([config.OPENOCD, "-f", str(config.OPENOCD_CFG)],
                                     stdout=log, stderr=subprocess.STDOUT,
                                     env=clean_env())
        self._wait_for_port(3333)
        return self

    def __exit__(self, *exc):
        self.proc.terminate()
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        return False

    def _wait_for_port(self, port, timeout=5.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            with socket.socket() as probe:
                probe.settimeout(0.2)
                if probe.connect_ex(("localhost", port)) == 0:
                    return
            if self.proc.poll() is not None:
                die("OpenOCD exited immediately - see %s/openocd.log. Olimex "
                    "plugged in, board powered?" % config.OUT_DIR)
            time.sleep(0.1)
        die("OpenOCD did not open port %d - see %s/openocd.log"
            % (port, config.OUT_DIR))

    def gdb(self, elf, *commands):
        """One batch GDB session; each element becomes an -ex argument."""
        argv = [config.GDB, str(elf), "-batch",
                "-ex", "target extended-remote localhost:3333"]
        for command in commands:
            argv += ["-ex", command]
        argv += ["-ex", "detach", "-ex", "quit"]
        return subprocess.run(argv, env=clean_env())


def echo(text):
    """A GDB -ex printing one line; GDB's echo does not add the newline."""
    return "echo %s\\n" % text


def read_epoch():
    return [
        echo(""),
        echo("=== stream_status 0x40000018 (ver|fill|consumed|underrun/overrun) ==="),
        "monitor mdw 0x40000018",
        echo("=== scratch3 0x0300000c: B00B0002=done B00B0001=streaming "
             "B00B0012=in STEP 2 B00B00EE=error ==="),
        "monitor mdw 0x0300000c",
        echo("=== BRAM 0x48000000 / 0x4803fffc ==="),
        "monitor mdw 0x48000000",
        "monitor mdw 0x4803fffc",
        echo(SCRATCH_LEGEND),
        "monitor mdw 0x03000000 12",
    ]


def read_session():
    return [
        echo("=== scratch3 0x0300000c: B00B0012=listening B00B0001=streaming "
             "B00B0002=done B00B00EE=error ==="),
        "monitor mdw 0x0300000c",
        echo("=== loop state (100B0001=listening 100B0002=ended) and epochs "
             "served, mailbox words 13-14 ==="),
        "monitor mdw 0x80100034 2",
        echo(SCRATCH_LEGEND),
        "monitor mdw 0x03000000 12",
    ]


# --- commands --------------------------------------------------------------

def bender():
    """The first bender that runs on this host.

    cheshire.mk calls bender while it is being read, so the build needs one
    that works; the binary in the repository is linked against a newer glibc
    than some hosts have, and then it does not start at all. BENDER in the
    environment wins.
    """
    if os.environ.get("BENDER"):
        return os.environ["BENDER"]
    for candidate in (str(config.REPO / "bender"), shutil.which("bender"),
                      "/tools/bender"):
        if not candidate or not os.access(candidate, os.X_OK):
            continue
        try:
            probe = run([candidate, "--version"], capture_output=True, timeout=10)
        except OSError:
            continue
        if probe.returncode == 0:
            return candidate
    return "bender"


def cmd_build(args, board):
    """Rebuild the firmware ELFs and the dataset image. The board takes no part."""
    targets = [Path(args.elf)] if args.elf else [
        config.ELF_CVA6, config.ELF_IDMA, config.ELF_PS, config.ELF_LOOP]

    env = clean_env()
    env["PATH"] = "%s:%s" % (config.GCC_BINROOT, env.get("PATH", ""))
    make_bender = "BENDER=%s -d %s" % (bender(), config.REPO)

    for elf in targets:
        say("Building %s" % elf.name)
        # sw.mk does not track header dependencies, so a stale object would
        # survive an edited header and the next run would measure the previous
        # firmware. Two seconds of compilation is cheaper than that.
        source = Path(str(elf).replace(".dram.elf", ""))
        for stale in (source.with_suffix(".o"), elf):
            if stale.exists():
                stale.unlink()
        if run(["make", "-C", str(config.REPO), "sw/tests/%s" % elf.name,
                "CHS_SW_GCC_BINROOT=%s" % config.GCC_BINROOT, make_bender],
               env=env).returncode != 0:
            die("build failed: %s" % elf.name)
        header = run([os.path.join(config.GCC_BINROOT, "riscv64-unknown-elf-readelf"),
                      "-h", str(elf)], capture_output=True, text=True).stdout
        for line in header.splitlines():
            if "Entry point" in line:
                print(line.strip())

    say("Generating the dataset image")
    if run([str(config.SCRIPT_DIR / "gen_ps_dataset.py"), "-o", str(config.DATASET)],
           env=env).returncode != 0:
        die("dataset generation failed")
    print("\nNext: util/reckon/reckon.py sync")
    return 0


def cmd_sync(args, board):
    """Put the bitstream, the dataset and the PS sources on the board."""
    if not config.DATASET.exists():
        die("dataset not found: %s (run `reckon.py build` first)" % config.DATASET)
    if not config.BIT.exists():
        die("bitstream not found: %s" % config.BIT)
    board.check_link()

    say("Syncing to %s@%s:%s" % (board.user, board.host, board.dir))
    board.sh("mkdir -p %s" % shlex.quote(board.dir))

    # The bitstream is 26 MiB and rarely changes: copy it only if the board
    # holds a different one.
    local_md5 = hashlib.md5(config.BIT.read_bytes()).hexdigest()
    remote = board.sh("md5sum %s 2>/dev/null | cut -d' ' -f1"
                      % shlex.quote("%s/%s" % (board.dir, config.BIT.name)),
                      capture=True)
    if remote.stdout.strip() == local_md5:
        print("bitstream already there (md5 %s), not re-copying" % local_md5[:12])
    else:
        print("copying %s (%.1f MiB)..." % (config.BIT.name,
                                            config.BIT.stat().st_size / 1048576))
        if board.put(config.BIT).returncode != 0:
            die("copying the bitstream failed")

    files = [config.PS_SRC_DIR / "reckon_feed.c",
             config.PS_SRC_DIR / "reckon_load.py",
             config.PS_SRC_DIR / "Makefile",
             config.REPO / "sw/include/reckon/reckon_ps_mbox.h",
             config.DATASET]
    if board.put(*files).returncode != 0:
        die("copying the PS sources failed")

    say("Building reckon_feed on the board")
    if board.sh("cd %s && make CPPFLAGS=-I. && chmod +x reckon_load.py"
                % shlex.quote(board.dir)).returncode != 0:
        die("build failed on the board; cross-compile instead:\n"
            "  make -C %s CC=aarch64-linux-gnu-gcc" % config.PS_SRC_DIR)
    print("\nNext: util/reckon/reckon.py load   (or `all` for the whole flow)")
    return 0


def cmd_load(args, board):
    """The PS configures the PL over PCAP."""
    board.check_link()
    say("Configuring the PL from the PS (fpga_manager over PCAP)")
    if board.sudo("./reckon_load.py %s"
                  % shlex.quote(config.BIT.name)).returncode != 0:
        die("PL configuration failed, before anything touched the aperture.\n"
            "  cat /sys/class/fpga_manager/fpga0/state")
    print("\nNext: util/reckon/reckon.py probe, or feed")
    return 0


def cmd_probe(args, board):
    """Write one word from the PS and read it back."""
    board.check_link()
    say("Aliasing probe on the PS")
    done = board.sudo("./reckon_feed --probe")
    if done.returncode == 0:
        # The PS has seen its own write; the other side of the alias is what a
        # run reads back at CVA6 0x80000000.
        print("\nNext: util/reckon/reckon.py feed")
    return done.returncode


def cmd_feed(args, board):
    """Publish one handover, or a series of them for a looping session.

    The sequence number is generated here, not on the board, so that afterwards
    the firmware can be asked which handover it consumed. Without it, a run that
    picked up a stale one looks exactly like a healthy one.
    """
    board.check_link()
    # Seconds since the epoch increase on their own and survive a restart of
    # everything; --seq overrides it, which is how a deliberately stale
    # handover is published.
    first = int(args.seq) if args.seq else int(time.time())

    if args.epochs > 1:
        # One handover per epoch, each waiting for its own ack. The series runs
        # under one sudo: the timestamp is per session, and the password
        # reaches only the first of them on standard input.
        last = first + args.epochs - 1
        seqs = " ".join(str(s) for s in range(first, last + 1))
        say("Feeding %d handovers (seq %d..%d)" % (args.epochs, first, last))
        inner = "for s in %s; do ./reckon_feed --seq $s || break; done" % seqs
        done = board.sudo("sh -c %s" % shlex.quote(inner))
        print("\nNext: util/reckon/reckon.py status")
        return done.returncode

    say("Pushing the dataset from the PS (seq %d)" % first)
    # Without --wait the producer plants the payload and the mailbox and
    # returns, so the firmware can be started afterwards and finds the magic
    # already set; with it, it stays for its own ack, which is what a session
    # already listening wants.
    done = board.sudo("./reckon_feed %s--seq %d"
                      % ("" if args.wait else "--no-wait ", first))
    if done.returncode != 0:
        return done.returncode
    args.last_seq = first
    if not args.wait:
        print("\nStart the firmware:  util/reckon/reckon.py start\n"
              "Then check the ack:  util/reckon/reckon.py ack --seq %d" % first)
    return 0


def cmd_ack(args, board):
    """Ask the board which handover the firmware acknowledged."""
    board.check_link()
    say("Checking the firmware's ack%s" % (" (seq %s)" % args.seq if args.seq else ""))
    expect = " --expect-seq %s" % args.seq if args.seq else ""
    return board.sudo("./reckon_feed --status%s" % expect).returncode


def cmd_start(args, board):
    """Load the firmware into DRAM over JTAG, run it, read the result back."""
    elf = Path(args.elf) if args.elf else config.ELF_PS
    if not elf.exists():
        die("ELF not found: %s (run `reckon.py build`)" % elf)

    say("Running %s on the CVA6 (Olimex RISC-V TAP)" % elf.name)
    with Jtag() as jtag:
        done = jtag.gdb(elf,
                        "monitor halt",
                        "load",
                        "monitor reg pc %s" % config.DRAM_ENTRY,
                        "monitor resume",
                        "monitor sleep %d" % (args.sleep_ms or config.PS_SLEEP_MS),
                        "monitor halt",
                        *read_epoch())
    print("\nNext: util/reckon/reckon.py ack --seq <the seq that was fed>")
    return done.returncode


def cmd_loop(args, board):
    """Start the looping firmware, or read the state of a running session.

    Reading halts the core for a moment: between epochs, never during one.
    """
    elf = config.ELF_LOOP
    if not elf.exists():
        die("ELF not found: %s (run `reckon.py build --elf %s`)" % (elf, elf))

    with Jtag() as jtag:
        if args.status:
            say("Session state")
            # An explicit resume: with the gdb-detach handler in
            # util/openocd.common.tcl, detaching alone leaves the core halted,
            # and a halted loop never sees the next handover.
            return jtag.gdb(elf, *read_session(), "monitor resume").returncode

        say("Starting %s (entry %s)" % (elf.name, config.DRAM_ENTRY))
        done = jtag.gdb(elf,
                        "monitor halt",
                        "load",
                        "monitor reg pc %s" % config.DRAM_ENTRY,
                        "monitor resume",
                        "monitor sleep %d" % config.LOOP_SETTLE_MS,
                        "monitor halt",
                        *read_session(),
                        "monitor resume")
    print("\nSession running. Feed from the PS:  "
          "util/reckon/reckon.py feed --epochs 10")
    return done.returncode


def cmd_all(args, board):
    """The whole one-shot flow."""
    for step in (cmd_sync, cmd_load):
        if step(args, board) != 0:
            return 1
    args.wait = False
    args.epochs = 1
    if cmd_feed(args, board) != 0:
        return 1
    seq = getattr(args, "last_seq", None)
    rc = cmd_start(args, board)
    args.seq = seq
    return cmd_ack(args, board) or rc


COMMANDS = {
    "build": cmd_build, "sync": cmd_sync, "load": cmd_load, "probe": cmd_probe,
    "feed": cmd_feed, "ack": cmd_ack, "start": cmd_start, "loop": cmd_loop,
    "status": cmd_loop, "all": cmd_all,
}


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="reckon.py", description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=sorted(COMMANDS))
    parser.add_argument("--elf", help="the ELF to build or start")
    parser.add_argument("--seq", help="sequence number to publish or to expect")
    parser.add_argument("--epochs", type=int, default=1,
                        help="how many handovers to publish in a row")
    parser.add_argument("--wait", action="store_true",
                        help="feed: stay for the acknowledgement")
    parser.add_argument("--sleep-ms", type=int,
                        help="how long to run before reading back")
    args = parser.parse_args(argv)
    args.status = args.command == "status"

    board = Board()
    try:
        return COMMANDS[args.command](args, board)
    finally:
        board.cleanup()


if __name__ == "__main__":
    sys.exit(main())
