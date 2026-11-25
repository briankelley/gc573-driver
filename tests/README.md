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
- The suite runs with the HDMI source off: the no-input cases (`10`, `12`,
  `13`, `14`) SKIP when the input locks within 4 s of the load. Live-input
  checks are in `live.sh` (below).
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
| `06-hdmi-bringup` | M3 | probe log: both chip IDs, the IT6805 factory trim, the splitter reference clock; EDID in both RAMs; `GC573_POLL_SECS` (default 5) of polling at >= 10 polls/s without I2C errors, retries, resyncs or poll errors (debugfs `hdmi`); with or without a source |
| `07-hdmi-edid` | M3 | `VIDIOC_G_EDID`: 256 bytes, LNX 0x5730 "GC573 Linux"; `edid-decode --check`: PASS, no warnings; `VIDIOC_S_EDID`: another serial number reads back, 3 blocks give E2BIG, the default restores, 0 blocks leave no EDID; SKIP without edid-decode |
| `05-dkms-build` | M0 | `dkms add` + `build` (never install) of a copy under a throwaway package name, for the running kernel |
| `10-video-capture` | M2 | no input, 6 formats x 120 frames at the default 1080p60, then 6 formats x 30 frames at every enumerated DV timing (`gc573-cap -T all`): every 32-byte block of every plane overwritten after a per-queueing pattern fill (`gc573-cap -p`); no sequence gaps; cadence mean 16.6-16.75 ms, every interval within half a period (8.4-25 ms: a lost or doubled frame fails); logs FPGA input registers 0x1004-0x1010 |
| `11-v4l2-compliance` | M2 | `v4l2-compliance -s`: 0 failures; SKIP if not installed |
| `12-video-stress` | M2 | `GC573_CYCLES` (default 100) start/stop cycles over the 6 formats with REQBUFS each cycle; underrun (all buffers held 500 ms, then requeued) and 1-buffer streaming, fully overwritten frames; I2C bus 1 IDs afterwards |
| `13-video-unbind` | M2 | unbind while streaming with mapped buffers: stream stops, unbind < 5 s, application exits; rebind probes and streams |
| `14-exp-slot-bits` | exp. | open question 8 result check via `exp_slot_mode` 1-5: ch0 CH_CTRL (run, slot-valid bits) gates all channels; ch1/ch2 CH_CTRL, even 0, has no visible effect |
| `15-video-returned-buffers` | M2 fix | `gc573-cap -R`: `GC573_RB_QBUFS` (default 6000) QBUFs at random points of the frame (NV12, 3 buffers, each dequeued buffer pattern-filled and held 0-20 ms): no DMA into a dequeued buffer, no completion for an unarmed slot |

Helpers: `gc573-cap.c` (V4L2 capture tool: pattern, cadence, DV timings sweep, stop/start, underrun, wait and returned-buffer modes; live input: lock wait `-L`, frame save `-o`, input-change test `-X` with restart `-r`, per-frame log `-F`; built per case with gcc), `i2c-id-reads.py`, `kmemleak-canary/`, `live-compare.py` (saved frame vs `tools/testsrc/pattern.py`). Env: `GC573_FRAMES` (`10-video-capture` frames per format at the default timings, default 120), `GC573_SWEEP_FRAMES` (per format and timing, default 30), `GC573_CYCLES`.

## Live input (`live.sh`, host)
`tests/live.sh [STEP...]` runs on the host: it drives the loopback output
(`DVI-D-0`, never the primary) with `tools/testsrc/show.sh` and xrandr, and runs
the checks in `gc573-dev` over ssh with the module built there
(`tools/vmbuild.sh`). Log: `tests/logs/<UTC stamp>_<kernel>_live.log`; prints
`RESULT` lines and a `SUMMARY`; leaves the pattern off.

| Step | Checks |
|---|---|
| `bringup` | load; the host sees the output connected; its EDID (`xrandr --verbose`) equals `VIDIOC_G_EDID` byte for byte; `edid-decode --check` PASS |
| `lock` | 1080p60 and 1080p59.94 (1000/1001 flag): `QUERY_DV_TIMINGS` = CTA VIC 16 within 3 s of the switch; `power_present` = 1; `SOURCE_CHANGE` on lock, loss and mode change |
| `relock` | `GC573_RELOCKS` (25) x 2 switches 1080p60 <-> 1080p59.94 through `show.sh`: each locks to the new rate within 3 s |
| `capture` | 1080p60 and 1080p59.94, 6 formats x `GC573_LIVE_FRAMES` (600): last frame vs `pattern.py` (RGB 0..+1; YUV within 2 code values, chroma at flat sites), every frame identical (full-frame signature), no sequence gaps, mean interval within 0.1 % of the measured frame period, first frame dropped |
| `modes` | every other mode the output offers: timings and the same capture checks (`GC573_MODE_FRAMES`, 120) |
| `change` | input change while streaming: `SOURCE_CHANGE`, `DQBUF` error, no DMA outside the queued buffers, restart at the new timings |
| `loss` | output off and on, idle and while streaming |
| `colour` | RGB limited, YCbCr 4:4:4, YCbCr 4:2:2 (report only) |
| `unload` | `rmmod` while streaming |
| `reload` | `GC573_RELOADS` (50) unload/load cycles with the source on: host output back and input locked each time |
| `compliance` | `v4l2-compliance -s` with the live input |
