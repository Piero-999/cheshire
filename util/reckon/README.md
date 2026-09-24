# `util/reckon` — the loop on the dev host

These drive the board from the development machine. The system they drive is described in the
[root README](../../README.md); the commands themselves are listed in its section 5.

They fall into two groups. **The flow** is what a session uses: build, ship, configure the PL, feed
the data, start the firmware, read the result. **The measurements** are the Vivado and ILA
machinery, which produced the evidence in the documentation and takes no part in a normal run.

## The flow

| file | what |
|---|---|
| `reckon.py` | the whole flow: `build sync load probe feed start ack loop status all`. `--help` lists them |
| `config.py` | paths, defaults, and the board's address and credentials; everything overridable from the environment |
| `gen_ps_dataset.py` | emits `ps/reckon_dataset.bin`, the DDR4 image the PS writes; `--break-eos` injects the fault of the documentation |
| `ps/` | the PS-side (aarch64) producer: `reckon_feed.c`, `reckon_load.py`, the dataset image |

## The measurements

| file | what |
|---|---|
| `config.sh` | what the scripts below need; takes the shared values from `config.py` |
| `run_both.sh` | one run on the iDMA variant and one on the CVA6 one, same read-back: the transport comparison |
| `debug.sh` | orchestrates the instrumented debug loop around `ila_capture.tcl` |
| `ila_capture.tcl` | Vivado: connect, optionally program, VIO reset, arm the ILA, run, upload the capture |
| `snapshot.tcl` | Vivado: dump the frozen state when a trigger does not fire |
| `program.tcl` | Vivado: program `.bit` and `.ltx` |
| `deploy.sh` | build, program, run |
| `summarize.sh` | FLAT / CHANGED summary of a capture CSV |
| `out/` | captures and Vivado logs (`capture_<ts>.csv`, `.ila`, `vivado.log`) — not committed |

`run_test.sh` and `build_sw.sh` are two lines each: they call `reckon.py` and exist because the
Vivado scripts start a run and a rebuild by those names.

## Prerequisite for anything that uses Vivado

These run headless, in their own Vivado batch process, and need the JTAG target. **Close the Vivado
GUI Hardware Manager** first, otherwise `open_hw_target` fails because the GUI already owns the
target. `hw_server` on `:3121` may stay up. To view a waveform afterwards, open the saved
`out/capture_*.ila` in the GUI.

## Knobs that are not documented elsewhere

- The VIO reset drives the real `rst_n`, so it resets ReckOn's `clk_15` domain as well. Use
  `debug.sh --program` only when the bitstream changed, or when the state looks wedged. In the
  PS-first flow it is not needed at all: every round starts from a fresh PCAP configuration.
- `probe_out` map in `ila_capture.tcl`: `0` = reset, `1` = `boot_mode`, `2` = `boot_mode_sel`,
  `3` = `uart_sel`. If the VIO reset is skipped with a name error, list the real names with
  `get_hw_probes -of_objects [get_hw_vios]`.
- Vivado's tcl property names differ between versions; the first run on a new install may need a
  small patch in `ila_capture.tcl`. The log is `out/vivado.log`.
- When a trigger never fires, `debug.sh` says so explicitly rather than producing an empty capture.
