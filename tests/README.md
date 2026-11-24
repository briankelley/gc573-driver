# tests/

Regression suite for the GC573 driver. Runs on the machine that holds the card:
the `gc573-dev` VM during bring-up, the host only for release validation.

## Run
- From the host: `tools/vmbuild.sh test [CASE...]` syncs, builds (W=1, zero
  warnings), runs the suite in the VM as root, and saves the log as
  `tests/logs/<UTC stamp>_<kernel release>.log`.
- On the target: `sudo tests/run.sh [CASE...]` with `gc573.ko` built in the
  repo root.
- Env: `GC573_ITER` (load/unload cycles, default 50), `GC573_INPUT` (HDMI input
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
- `run.sh` pauses kmemleak's automatic scan, clears old reports, and scans once
  after the last case: any unreferenced object fails the `kmemleak` result.

## Log
Header: date, kernel, debug options, card IDs, module srcversion, source rev,
input. Per case: case output, its kernel log, `RESULT <case> PASS|FAIL|SKIP`.
Footer: kernel, card firmware (FPGA VERSION), input, all results, `SUMMARY`.

## Cases
| Case | Gate | Checks |
|---|---|---|
| `01-probe` | M0 | binds, MSI, FPGA VERSION logged, INT_ENABLE 0 after remove |
| `02-load-unload` | M0 | 50 load/unload cycles, each probe binds and logs VERSION |
