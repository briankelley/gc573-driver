# tests/

Regression suite for the GC573 driver. Runs on the machine that holds the card:
the `gc573-dev` VM during bring-up, the host only for release validation.

## Run
- From the host: `tools/vmbuild.sh test [CASE...]` syncs, builds (W=1, zero
  warnings), runs the suite in the VM as root, and saves the log as
  `tests/logs/<UTC stamp>_<kernel release>.log`.
- On the target: `sudo tests/run.sh [CASE...]` with `gc573.ko` built in the
  repo root.
- Env: `GC573_ITER` (load/unload cycles, default 50), `GC573_I2C_ROUNDS`
  (`04-i2c-reads` rounds per reader, default 200), `GC573_INPUT` (HDMI input
  source and mode for the log, default `none`), `GC573_KO` (module path).
- Leak, lockdep, KASAN and DMA-API gates need the debug kernel
  (`6.8.12-gc573dbg`); on other kernels the kmemleak result is SKIP.

## Case format
- `cases/NN-name.sh`: bash, run as root in numeric order, sourcing `lib.sh`.
- Exit 0 = PASS, 77 = SKIP, anything else = FAIL. Print what was checked.
- A case must leave the module unloaded (`run.sh` unloads it if not).
- `run.sh` marks the kernel log before each case and fails the case if its log
  holds a kernel warning, oops, KASAN/UBSAN, lockdep, atomic-sleep or DMA-API
  report, or a driver error/timeout/MISMATCH message (`KMSG_BAD`,
  `KMSG_DRV_BAD` in `lib.sh`).
- `run.sh` pauses kmemleak's automatic scan, reports and clears old leaks,
  and checks once after the last case: any unreferenced object fails the
  `kmemleak` result. kmemleak only reports an object after two consecutive
  scans found it unreferenced and unchanged, so every check scans twice
  (`kml_reset`, `kml_report` in `lib.sh`); a single scan reports no new leak.
- `debug-checkers` result: lockdep must still be on (`debug_locks=1`) and the
  DMA-API debug error count unchanged after the last case.

## Log
Header: date, kernel, debug options, card IDs, module srcversion, source rev,
input. Per case: case output, its kernel log, `RESULT <case> PASS|FAIL|SKIP`.
Footer: kernel, card firmware (FPGA VERSION), input, all results, `SUMMARY`.

## Cases
| Case | Gate | Checks |
|---|---|---|
| `00-kmemleak-selftest` | harness | builds `kmemleak-canary/` (8 x 128 B leaked at load, 0xa5 fill); the suite's report step must list them; SKIP without kmemleak |
| `01-probe` | M0 | binds, MSI, FPGA VERSION logged, INT_ENABLE 0 after remove |
| `02-load-unload` | M0 | 50 load/unload cycles; each probe binds, logs VERSION and reads both chip IDs OK |
| `03-chip-id` | M1 | bus 1 chip IDs: 0x90 `54 49 05 68`, 0x58 `54 49 63 66`; 3 adapters; bus 0/2 transfers off |
| `04-i2c-reads` | M1 | 2 parallel readers x 2000 read-only ID transfers via i2c-dev (`i2c-id-reads.py`), every byte checked, one IRQ per transfer; plain read refused before hardware |
| `05-dkms-build` | M0 | `dkms add` + `build` (never install) of a copy under a throwaway package name, for the running kernel |
| `10-video-capture` | M2 | no input, 6 formats x 120 frames at the default 1080p60, then 6 formats x 30 frames at every enumerated DV timing (`gc573-cap -T all`): every 32-byte block of every plane overwritten after a per-queueing pattern fill (`gc573-cap -p`); no sequence gaps; cadence mean 16.6-16.75 ms, all intervals 15-18.4 ms; logs FPGA input registers 0x1004-0x1010 |
| `11-v4l2-compliance` | M2 | `v4l2-compliance -s`: 0 failures; SKIP if not installed |
| `12-video-stress` | M2 | `GC573_CYCLES` (default 100) start/stop cycles over the 6 formats with REQBUFS each cycle; underrun (all buffers held 500 ms, then requeued) and 1-buffer streaming, fully overwritten frames; I2C bus 1 IDs afterwards |
| `13-video-unbind` | M2 | unbind while streaming with mapped buffers: stream stops, unbind < 5 s, application exits; rebind probes and streams |
| `14-exp-slot-bits` | exp. | open question 8 result check via `exp_slot_mode`: ch0 slot-valid bits gate all channels; ch1/ch2 CH_CTRL has no visible effect |

Helpers: `gc573-cap.c` (V4L2 capture tool: pattern, cadence, DV timings sweep, stop/start, underrun, wait modes; built per case with gcc), `i2c-id-reads.py`, `kmemleak-canary/`. Env: `GC573_FRAMES` (`10-video-capture` frames per format at the default timings, default 120), `GC573_SWEEP_FRAMES` (per format and timing, default 30), `GC573_CYCLES`.
