# ReckOn debug/deploy scripts

Automates the full loop on the physical ZCU102: **build SW → (program) → clean
reset → arm ILA → run test → dump capture**, and a bare **deploy**.

See [`../../guides/DEBUG_RECKON.md`](../../guides/DEBUG_RECKON.md) for the ongoing
debug story and the memory map.

## ⚠️ Prerequisite
These run **headless** (their own Vivado batch process) and need the JTAG target.
**Close the Vivado GUI Hardware Manager** (or the whole GUI) before running them —
otherwise `open_hw_target` fails because the GUI already owns the target.
`hw_server` on `:3121` can keep running. To *view* a waveform, open the saved
`out/capture_*.ila` in the GUI afterwards.

Two JTAG adapters are used at once, no conflict:
- **Olimex** (RISC-V TAP) → OpenOCD/GDB, runs the test.
- **Digilent HS2** (Xilinx TAP) → Vivado/hw_server, programs + ILA/VIO.

## Files
| file | what |
|---|---|
| `config.sh`       | paths/vars (edit here); sourced by every `*.sh` |
| `build_sw.sh`     | rebuild the streaming ELFs (`reckon_stream_{cva6,idma,ps}.dram.elf`) |
| `run_test.sh`     | OpenOCD+GDB: load to DRAM, run, readback regs (standalone) |
| `program.tcl`     | Vivado: program `.bit` + `.ltx` |
| `ila_capture.tcl` | Vivado: connect → (program) → VIO reset → arm ILA → `exec run_test.sh` → upload |
| `debug.sh`        | orchestrates the instrumented debug loop |
| `deploy.sh`       | build → program → run |
| `summarize.sh`    | FLAT/CHANGED summary of a capture CSV |
| `gen_ps_dataset.py` | emit the DDR4 image the PS writes (replicates `rk_pack_half()`) |
| `ps_deploy.sh`    | ship + build + run the PS-side producer on the board |
| `ps/`             | the PS-side (aarch64) producer — see [`ps/README.md`](ps/README.md) |

## Debug loop
```bash
util/reckon/debug.sh                       # VIO reset, trigger new_batch_fsm, run, dump
util/reckon/debug.sh --build               # rebuild SW first
util/reckon/debug.sh --program             # reprogram bitstream first (fully clean)
util/reckon/debug.sh --trigger reckon_axi_top_0/TIME_TICK "eq1'b1"   # does TIME_TICK ever pulse?
util/reckon/debug.sh --trigger reckon_axi_top_0/CS        "eq1'b1"
```
Output: `out/capture_<ts>.csv` + `.ila`, a FLAT/CHANGED summary, and — if the
trigger never fired — a clear "TRIGGER NON SCATTATO" (itself a finding: that
signal never asserted).

**Trigger compare syntax** (Vivado): `eq1'b1`, `eq1'b0`, `neq32'h0000_0000`,
`eq12'h004`, don't-care `eq1'bX`.

## Deploy
```bash
util/reckon/deploy.sh                 # build + program + run
util/reckon/deploy.sh --no-run        # just build + program
```

## Standalone run (no ILA, board already programmed)
```bash
util/reckon/run_test.sh                          # default ELF, 8 s
util/reckon/run_test.sh <elf> <sleep_ms>
```

## PS-first flow (the board holds bitstream + training set)
```bash
util/reckon/ps_deploy.sh --load    # the PS configures the PL over PCAP (fpga_manager)
util/reckon/ps_deploy.sh --probe   # first time: prove PS 0xA0000000 == CVA6 0x80000000
util/reckon/ps_deploy.sh --run     # PL + dataset from the PS, then the ELF over JTAG
```
The PS configures the fabric, so the "unprogrammed PL hangs the ARM core" hazard cannot
happen, no VIO reset is needed, and this loop needs neither Vivado nor hw_server — only
OpenOCD on the Olimex. Full story in [`ps/README.md`](ps/README.md).

## Notes / knobs
- VIO reset drives the real `rst_n` → resets ReckOn (clk15). Use `--program`
  only when the bitstream changed, or if state looks wedged.
- `probe_out` map (in `ila_capture.tcl`): 0=reset, 1=boot_mode, 2=boot_mode_sel,
  3=uart_sel. If VIO reset is skipped with a name error, list the real names:
  `get_hw_probes -of_objects [get_hw_vios]`.
- First run may hit a Vivado tcl API quirk (property names differ by version) —
  the log is in `out/vivado.log`; easy to patch in `ila_capture.tcl`.
