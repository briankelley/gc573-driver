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
- The no-input cases (`10`, `12`, `13`, `14`, `15`, `17`) take the HDMI input
  away first (`gc573_input_off`: `VIDIOC_S_EDID` with 0 blocks, then no lock
  for 1 s), so the suite runs with the loopback source on or off. Live-input
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
  `KMSG_DRV_BAD` in `lib.sh`). A case that provokes such a message on
  purpose appends a regex for it to the file `$GC573_KMSG_ALLOW`; matching
  lines are logged as expected instead.
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
| `04-i2c-reads` | M1 | 2 parallel readers x 2000 read-only ID transfers via i2c-dev (`i2c-id-reads.py`), every byte checked, one IRQ per transfer (the driver's own transfer count read just before and after the interrupt count, in one process); plain read refused before hardware |
| `06-hdmi-bringup` | M3 | probe log: both chip IDs, the IT6805 factory trim, the splitter reference clock; EDID in both RAMs; `GC573_POLL_SECS` (default 5) of polling at >= 10 polls/s without I2C errors, retries, resyncs or poll errors (debugfs `hdmi`); with or without a source |
| `07-hdmi-edid` | M3 | `VIDIOC_G_EDID`: 256 bytes, LNX 0x5730 "GC573 Linux"; `edid-decode --check`: PASS, no warnings; `VIDIOC_S_EDID`: another serial number reads back, 3 blocks give E2BIG, the default restores, 0 blocks leave no EDID; SKIP without edid-decode |
| `05-dkms-build` | M0 | `dkms add` + `build` (never install) of a copy under a throwaway package name, for the running kernel |
| `10-video-capture` | M2 | no input, 6 formats x 120 frames at the default 1080p60, then 6 formats x 30 frames at every DV timing the default EDID offers (saved with `gc573-cap -t` before the EDID is cleared, swept with `-T @FILE`): every 32-byte block of every plane overwritten after a per-queueing pattern fill (`gc573-cap -p`); no sequence gaps; cadence mean 16.6-16.75 ms, every interval within half a period (8.4-25 ms: a lost or doubled frame fails); logs FPGA input registers 0x1004-0x1010 |
| `11-v4l2-compliance` | M2 | `v4l2-compliance -s`: 0 failures; SKIP if not installed |
| `12-video-stress` | M2 | `GC573_CYCLES` (default 100) start/stop cycles over the 6 formats with REQBUFS each cycle; underrun (all buffers held 500 ms, then requeued) and 1-buffer streaming, fully overwritten frames; I2C bus 1 IDs afterwards |
| `13-video-unbind` | M2 | unbind while streaming with mapped buffers: stream stops, unbind < 5 s, application exits; rebind probes and streams |
| `14-exp-slot-bits` | exp. | open question 8 result check via `exp_slot_mode` 1-5: ch0 CH_CTRL (run, slot-valid bits) gates all channels; ch1/ch2 CH_CTRL, even 0, has no visible effect |
| `15-video-returned-buffers` | M2 fix | `gc573-cap -R`: `GC573_RB_QBUFS` (default 6000) QBUFs at random points of the frame (NV12, 3 buffers, each dequeued buffer pattern-filled and held 0-20 ms): no DMA into a dequeued buffer, no completion for an unarmed slot |
| `16-probe-fail-hpd` | M3 review | a probe that fails after the HDMI chips came up (bpftrace overrides `gc573_video_init()` with -ENOMEM) leaves GPIO bit 2, the IT6805-side HPD, low (read through `resource0`); before that: bit 2 high while bound, low after a normal unbind. SKIP without bpftrace or function error injection |
| `17-audio` | M4 | no input: ALSA hw params (S16_LE, 2 channels, 48 kHz, periods from 480 frames); 3 s capture at 48 kHz +- 0.1 % against the clock, no overrun, all samples zero, every period silent, AUDIO_DONE in order (debugfs `audio`); 20 stop/start cycles (INT bit 4 each), audio across 3 video stream start/stops and across 30 video stop/start cycles in every format (while audio runs the video stop leaves out reset domain 8, which holds the audio DMA: no restart, nothing filled, AUDIO_DONE in order, rate within 0.1 %), rmmod refused while the PCM is open, unbind while capturing (< 5 s, the application exits), capture after the rebind. SKIP without the alsa-lib headers |

Experiment `exp-delivery.sh RATE [N] [TAG]` (host side like `live.sh`,
open question 33): a moving source (ffplay `testsrc2`) on the output at RATE,
then a capture with a hash of every frame and a BAR0 snapshot per completion
(`gc573-cap -F -M`); `exp-delivery.py` prints the completion rate, the repeat
pattern and which registers change with it. The driver's `exp_rate_fps` and
`exp_rate_bits` parameters set RATE_CTRL for such a stream. Result:
`logs/20261125-041700_6.8.0-151-generic_exp-delivery.log`.

Experiment `exp-reset.sh [-s MASK]` (in the VM as root, open question 13):
what each reset domain (RESET bits 0, 8, 9) resets and which one stops the
audio DMA. The driver's `exp_stop_domains` parameter sets the domains a
video stop resets (0: none, so a stream's configuration stays in the
registers), and its debugfs `exp_reset` file resets the domains written to
it (a mask) while video is idle. Per domain: the documented registers
before and after (`gc573-regs.c`), DMA_RUN and the audio periods with an
audio capture running; `-s MASK`: one audio capture across 3 video stops
resetting MASK. `exp-reset.py` summarises. Result:
`logs/20261125-075103_6.8.0-151-generic_exp-reset.log`.

Helpers: `gc573-aud.c` (ALSA capture tool, alsa-lib: per-read frame count and timestamp, raw samples, BAR0 snapshot, a V4L2 capture beside it for A/V timing, stop/start), `gc573-regs.c` (BAR0 registers through `resource0`, mapped read-only; documented offsets only), `gc573-cap.c` (V4L2 capture tool: pattern, cadence, DV timings sweep (`-T all`, or a list saved with `-t`), stop/start, underrun, wait and returned-buffer modes; live input: lock wait `-L`, frame save `-o`, input-change test `-X` (every event, the frames after them, the DQBUF or QBUF error, the last frame with `-o`; `-A` time after the last event, `-H` buffers held after STREAMOFF) with restart `-r`, per-frame log `-F`; built per case with gcc), `i2c-id-reads.py`, `kmemleak-canary/`, `live-compare.py` (saved frame vs `tools/testsrc/pattern.py`), `live-av.py` (a `gc573-aud` capture of `tools/testsrc/avsync.sh`: bursts, channel order and rate by frequency, frames against the clock, gaps, video cadence, A/V offset and drift; reads the samples through a memory map, hours of them fit), `obsws.py` (minimal obs-websocket v5 client, standard library only: `obsws.py REQUEST [JSON]`), `obs-check.py` (OBS set-up, format screenshots, recording, reopen; see its docstring), `obs-av.py` (A/V offset and drift in a recording of `avsync.sh`, per-segment flash counts), `obs-run.sh` (starts OBS on the VM's desktop with a minimal profile and obs-websocket on port 4455 without a password, or stops it). Env: `GC573_FRAMES` (`10-video-capture` frames per format at the default timings, default 120), `GC573_SWEEP_FRAMES` (per format and timing, default 30), `GC573_CYCLES`.

`scrub-check.sh` (host or VM, no device touched): `tools/testsrc/scrub.py`
and `scrub.sh` on made-up device names. Every log writer passes its text
through them: guard.py, obs-events.py, and the event lines of live.sh,
show.sh and avsync.sh, route-check.sh and state-check.sh. The serial in a
udev or PipeWire USB name (`usb-<vendor>_<model>_<serial>-00`,
`...-video-index0`) becomes `<serial>`. PCI names, such as the GC573's,
and path-based USB names stay as they are. The Python filter and the bash
function must agree, and scrubbing twice must change nothing.

## Live input (`live.sh`, host)
`tests/live.sh [STEP...]` runs on the host: it drives the loopback output
(`DVI-D-0`, never the primary) with `tools/testsrc/show.sh`, `avsync.sh` and xrandr, and runs
the checks in `gc573-dev` over ssh with the module built there
(`tools/vmbuild.sh`). Log: `tests/logs/<UTC stamp>_<kernel>_live.log`; prints
`RESULT` lines and a `SUMMARY`; checks the kernel log as `run.sh` does
(`kernel-log`) and runs kmemleak over the whole run where the kernel has it
(`kmemleak`, the debug kernel); leaves the pattern off, and checks that no
ffplay of `show.sh` or `avsync.sh` is left running (`testsrc-closed`) and that
the driver holds no buffer memory any more (`driver-mem`: debugfs `video`
line `mem (live, all cards)`, buffers, pages, kernel mappings and descriptor
lists all 0; SKIP for a module built before it).

Host-local mode (`GC573_LOCAL=1`): the driver runs on the host, bound by the
user (`tools/install.sh`), and the checks run there without ssh. `live.sh` never
loads, unloads, binds or unbinds the driver then (it refuses such commands),
leaves the GPU's colour settings and OBS's configuration alone, and runs only
the steps that allow that (`LOCAL_STEPS`; `obssoak` and `soak` on request).
sudo goes through `SUDO_ASKPASS`, or cached credentials. OBS is the user's:
`tests/obs-run.sh --keep-config` starts it minimized to the tray (no preview is
drawn) without writing its configuration, and `tests/obs-check.py verify`
checks the sources (setting them up would make OBS open every `/dev/video*`
node, cameras too). `GC573_OBS_BUFFERING` defaults to 0 there.

Roku mode (`GC573_SOURCE=roku GC573_LOCAL=1`, M6): the source is the Roku
through the HDCP filter. `tools/roku/ecp.py` drives it, and it plays
`tools/roku/pattern-video.sh`'s file, served by `tools/roku/serve.py` for the
run only. `DVI-D-0` is never touched. Actions on the Roku need
`GC573_ROKU_GO=1`; without it only `rokuwhich`, `rokulock`, `rokucompliance`,
`q25` and `q25back` run. On the saved Roku an action also needs it identified
as the one cabled to the card (`rokuwhich`). Its state before the run's first
action (the app in the foreground, the power mode) is saved for the record,
not restored (the user does that). The run's end only stops our video if
it still plays, and sends Home if a PowerOff of the run left the Roku
asleep. Steps that need no pattern judge the driver by its own numbers on
any picture: `gc573-aud -V` sequence numbers and intervals, the debugfs
frame-interrupt ring, the error counters. The default steps are `rokulock`,
`rokucompliance`, `rokusleep`, `rokumodes` and `rokuobsany`. Steps:
- `rokuwhich`: is the saved Roku the cabled one? No action; only the saved
  Roku is asked (`ecp.py survey --saved`, no SSDP): its ui-resolution
  follows a 720p-only EDID and back. `rokuwhichkey` (go; it surveys every
  Roku) was the fallback when two were candidates;
- `rokulock`: the lock, its timings and colour;
- `rokucompliance`;
- `rokucapture`: `live-av.py --exact` on the pattern video, the bursts'
  channels, the A/V offset, and the colour patches against BT.709 limited
  range;
- `rokuobs`: OBS screenshots, meters and a recording, with
  `tests/obs-events.py` in its Roku mode;
- `rokusleep` (any picture): PowerOff, then Home. It records what the card
  sees at each step and runs 10 s of `gc573-aud -V` before and after;
- `rokumodes` (any picture): EDID re-sets (720p only, another serial, the
  default), with the Roku's mode after each (INFO when it does not follow),
  the lock and 10 s of `gc573-aud -V`;
- `rokustart` (any picture): streams started at a fresh lock, 720p and
  1080p (`GC573_ROKU_TRIALS`, 6). Every interval must be within 10 % of
  IN_FRAME_PERIOD, and the first 40 at its rate within 0.05 %: the input's
  frames from the first frame after the published lock (`spec/hdmi-chips.md`
  "Lock policy", delivery settle). Each off interval is listed with its
  frames' phase, untouched blocks (`gc573-cap -p`), band signatures (`-B`),
  IN_FRAME_PERIOD (`-M`), the interrupt ring and the HDMI worker's activity
  (`tests/dbg-watch.py`). `GC573_ROKU_START_DELAY` starts the streams that
  many seconds after the lock. `GC573_ROKU_START_FIRST=serial` uses the
  other-serial EDID instead of the 720p one: streams started at a lock in
  the same timings;
- `rokurelock` (any picture): a stream across a relock in the same timings.
  The EDID alternates between the other serial and the default: setting
  the same EDID again brings no loss. From 0.1 s after the driver's live
  restart, the same checks. An INFO timeline from the stable entry gives
  the loss, the free-run restart, the published lock, the live restart,
  the FPGA's 0x1004/0x1010 changes, and the free-run frames' intervals
  between the stable entry and the live restart;
- `rokuobsany` (any picture): OBS through `tests/obs-any.py`. It takes
  screenshots, reads the meters and makes a 60 s recording, then deletes
  it. Alongside it checks the driver's stream, intervals and counters;
- `rokureboot` (`GC573_ROKU_REBOOT_KEYS`; SKIP without them: ECP has no
  restart, and menu keys would be blind navigation);
- `rokuobssoak`: obssoak with the Roku's pattern and changes;
- `rokusoakany` (any picture): the 2-hour soak without playback. OBS
  records while the Roku sleeps and wakes, the EDID is set again and OBS
  reopens its devices. At each change it checks the driver's stream,
  intervals, counters and memory, and OBS's counters and log;
- `q25` (the Roku without the filter: open question 25) and `q25back`.

Details are in `live.sh`'s header. The privacy rules are in AGENTS.md: no
identifiers, no pictures of what the Roku shows.

| Step | Checks |
|---|---|
| `bringup` | load; the host sees the output connected; its EDID (`xrandr --verbose`) equals `VIDIOC_G_EDID` byte for byte; `edid-decode --check` PASS |
| `lock` | 1080p60 and 1080p59.94 (1000/1001 flag): `QUERY_DV_TIMINGS` = CTA VIC 16 within 3 s of the switch; `power_present` = 1; `SOURCE_CHANGE` on lock, loss and mode change |
| `relock` | `GC573_RELOCKS` (25) x 2 switches 1080p60 <-> 1080p59.94 through `show.sh`: each locks to the new rate within 3 s |
| `fpgawait` | the lock policy (`spec/hdmi-chips.md` "Lock policy") with the FPGA's input measurement held not valid through the module parameter `exp_fpga_invalid` (0x1004[1:0] = 1 and 0x1010 = 0 for that many polls after each stable entry: the host's boot race of 2026-11-25): held for good, no lock and one `dev_warn` (debugfs hdmi `fpga_waits` + 1) (`fpgawait-no-lock`, `fpgawait-warning`); valid again, one lock within 3 s at CTA 1080p60 with an FPGA frame period (`fpgawait-lock`); valid 30 polls after the entry, one lock line, with a period (`fpgawait-late`). The self-heal (`fpgaheal`) is off for the step. VM only (it writes a module parameter) |
| `fpgaheal` | the self-heal of a measurement that stays not valid (`spec/hdmi-chips.md` "Lock policy", open question 40), with `exp_fpga_invalid` 4294967294 (not valid until the first attempt) and 4294967295 (never). The output is on without a test player, since the self-heal's hot-plugs can drop its mode. What the source sees: `monitor_present` in the ELD of the card's port (`/proc/asound`), every 50 ms. Valid after the first attempt: one receiver restart, logged at 90 polls, then one lock at CTA 1080p60; debugfs hdmi `fpga_heals` and `fpga_heal_fixes` + 1; no HPD drop (`fpgaheal-fixed`). Never valid: the restart, then two hot-plugs at least 20 s and 80 s after the attempt before, one `dev_warn` 5-20 s after the third, nothing more in 30 s, no lock; `fpga_heals` + 3, `fpga_heal_giveups` + 1; two HPD drops (`fpgaheal-never`). Valid again: one lock, which ends the session without a fix counted (`fpgaheal-never-lock`). `fpga_heal` 0: no attempt and no lock in 8 s; 1 again: the restart at once and the lock (`fpgaheal-off`). Through every case, in the VM: the splitter's 5 V (debugfs `rx 5v` and the published power, every 50 ms, each change logged: does the source drop 5 V at a hot-plug's HPD low?). Also a second handle's QUERY_DV_TIMINGS, G_FMT and G_EDID about 5 times a second. None may fail. QUERY_DV_TIMINGS and G_FMT must stay under 500 ms; G_EDID, which waits for a hot-plug's 500 ms toggle under the HDMI lock, must stay under 1500 ms. A driver without the self-heal fails every case: they are its failing-before test. About 4 min. VM only |
| `capture` | after the source has settled (90 identical, evenly spaced frames), 1080p60 and 1080p59.94, 6 formats x `GC573_LIVE_FRAMES` (600): last frame vs `pattern.py` (RGB 0..+1; YUV within 2 code values, chroma at flat sites), every frame identical (full-frame signature), no sequence gaps (`TAG-FMT`); G_PARM equal to the DV timings' nominal interval as an exact fraction, e.g. 1/60 and 1001/60000, and 1/60 for inputs below 59.5 Hz, which the card delivers at 60 Hz with repeated frames (`TAG-interval`; spec/video-pipeline.md "Delivery rate"); mean interval within 0.1 % of the interval G_PARM reports (`TAG-FMT-cadence`); the first frame of every stream dropped |
| `modes` | every mode the output offers (the card's EDID, as far as the GPU drives it), each entered from another, 1080p60 last: the lock within 15 s with the FPGA's measurement valid within 40 polls (debugfs hdmi `fpga_waits` unchanged; `fpga_rejects` gives the polls it took), the DV timings' rate against the mode's (within xrandr's rounding and 0.02 %: 60 and 59.94, 24 and 23.98 stay apart), and the same capture checks per format (`GC573_MODE_FRAMES`, 120: 2 s at the card's delivery rate) |
| `change` | input change while streaming (`gc573-cap -X`): `SOURCE_CHANGE` and no DMA outside the queued buffers every time; to other timings (1080p60 <-> 720p60) a `DQBUF` error (after the 1 s hold) and a restart at the new timings; 1080p60 -> 59.94 (the buffers still fit) the stream carries on, no error, frames after the last event; an application that never sets timings and keeps its buffers through a change to 720p (as OBS does) gets the new timings once its queue is free (`change-adopted`); every restart, which starts at the lock, has every interval within 10 % of the input's (`TAG-restart-intervals`: the delivery settle, `spec/hdmi-chips.md` "Lock policy") |
| `loss` | output off and on, idle and while streaming: the stream carries on through a loss, free-running limited-range black (`loss-streaming-black`: the last frame), and live again when the input returns in the stream's timings, from a free-running stream and through an output off and on (`loss-return-pattern`, `loss-off-on-pattern`: the last frame against `pattern.py`). TRY_FMT for every format, and G_FMT, keep the locked input's colorimetry while unlocked and after the relock (`loss-idle-colorimetry`, `loss-relock-colorimetry`), and so does G_FMT on a second handle while a stream runs unlocked (`loss-streaming-colorimetry`) |
| `colour` | RGB limited, YCbCr 4:4:4, YCbCr 4:2:2 (nvidia-settings): the published colour format and range follow the splitter RX's AVI copy; captures reported, not gating. The output's colour goes back to RGB full range at the end and on every exit (the EXIT trap, also at the guard's stop): read back, three tries, and the run stops if that fails (also in `avchange`) |
| `colorimetry` | VM only. The format's colorimetry follows the last input that locked (`spec/hdmi-chips.md` "Stream policy on input changes"). The source's colour is changed at runtime, on the test output only: RGB full range, YCbCr 4:4:4 limited, RGB limited. TRY_FMT for every format, and G_FMT, switch at each lock. A loss and the relock in RGB limited range keep them. Then RGB full range again, and 720x480 RGB (BT.601 by size) through a loss while streaming: G_FMT stays, and the free-run frames stay black through the RGB->YUV CSC in BT.601. Every output's colour settings are read before and after: the others unchanged, the test output back at RGB full range with dithering off |
| `audio` | `avsync.sh` (HDMI audio from the GPU, IT6805 audio state ON): 10 s capture; a burst a second; per burst the dominant frequency left 1 kHz and right 2 kHz within 1 %, the other tone >= 30 dB down (channel order and rate); 48 kHz +- 0.05 % against the clock; no gap (the per-second medians of the read timestamps, against a line, move < 3 ms from one second to the next: a lost period is a 10 ms step; the line's bend over the run, the clock's own rate changes, reported); no overrun |
| `exact` | frame by frame on the card: `GC573_EXACT_SECS` (60) of `gc573-aud -V -P` (the counter picture: flash box and 16-bit counter per frame) for `show.sh --counter` at 1080p60 and `avsync.sh --pattern` at 1080p60, 1080p59.94 and 720p59.94 (`live-av.py --exact`). FAIL only on a loss of the driver's: a sequence gap, or a frame interval outside half to one and a half periods. Counter repeats, skips and tears between regular frames are the source's: its player slips where its frame times cross the display's refresh. They go to `INFO source` with their clusters and their net against what the clocks predict, (source rate - capture rate) x duration. The source's rate is the nominal one on the system clock (show.sh), or times the audio rate over 48 kHz (avsync.sh, whose player follows the HDMI audio clock). The source is flagged `SOURCE BROKEN` when the net misses the prediction by more than 1.5 frames or the clusters outnumber the crossings |
| `avsync` | `GC573_AV_SECS` (600) of audio and video (1080p60 YUYV) together: no overrun, no gap, no video sequence gap or interval off by half a period; the driver's counters over the run: no interrupt late, no period out of turn (silent periods and source pauses filled reported); A/V offset = burst onset (ALSA timestamps) - flash frame (vb2 timestamp, end of frame), each flash moved by whole frames to the most common offset (ffplay shows a flash a frame or more early or late at times; raw offsets reported): within 1 ms of a line, drift < 10 ms (one audio period) over the run |
| `audioloss` | one 80 s audio capture across 5 video stream start/stops, an input loss while video streams (the stream carries on free-running), relock, video again, an idle loss and relock: no overrun, no stall (reads < 250 ms apart), no DMA restart at the video stops (they leave the audio DMA's reset domain alone), never a stop without INT bit 4, no gap and 48 kHz +- 0.05 % over the run (the driver fills the input losses' pauses with silence), 20 bursts with the right channels in the last 20 s |
| `obs` | OBS in `gc573-dev` (`obs-run.sh` starts it, `obs-check.py` drives it through obs-websocket; V4L2 source on the card's video device, ALSA source on its PCM at 48 kHz): every pixel format OBS offers for the device, a 1920x1080 source screenshot against `pattern.py` inside each flat region of the pattern (6 pixels in from its edges, below the corner markers): max error 6 code values for the YUV formats (OBS's conversion back to RGB), 2 for RGB |
| `obspw` | Not in the default steps. OBS with the card's audio through PipeWire, as on a desktop: lifts the VM's udev rule that keeps PipeWire off the card (`ACP_IGNORE`), restarts WirePlumber, and finds the card's PipeWire source; OBS records `GC573_PW_SECS` (120) of `avsync.sh` with an *Audio Input Capture (PulseAudio)* source on it (`obs-check.py pulse NODE`) in place of the ALSA source; `obs-av.py` as in `obsav`. Then the rule goes back, and nothing may hold the module (`refcnt` 0; PipeWire keeps the control device of a card it manages open). The `EXIT` trap puts the rule back too |
| `obsav` | `GC573_OBS_SECS` (600) of OBS recording `avsync.sh` (V4L2 source with OBS's defaults: buffering on, YUYV; ALSA source; MKV, x264, AAC): `obs-av.py` on the file: video intervals (OBS's 60 Hz canvas, none over 1.5 periods), every flash frame paired with a burst within 0.5 s (half the flash interval), A/V offset = burst onset - flash frame in the file's own times: mean within 45 ms (the ITU-R BT.1359 audio-lead detectability limit), std <= 10 ms (OBS shows a source frame in the next frame of its own canvas, so the offset takes two values a frame apart), drift: a line through the offsets moves less than a frame period over the run; OBS's skipped-frame counters reported; no `select timed out` or `failed to dequeue` in OBS's log. First, in the same `avsync.sh` session: 60 s of `gc573-aud -V` with `live-av.py` (`obsav-driver-*`: the source's own offset, which can move by whole frames between sessions), and the OBS offset minus it is printed |
| `obschange` | source changes while OBS records `avsync.sh`, the V4L2 source left alone: output off for 8 s and on again (`obschange-live-on`: flash frames in the recording after it, i.e. OBS live again by itself), then a change to 720p (`obschange-stopped-720p`: OBS's source stops, it ignores V4L2 source-change events); after the recording (whose muxer process holds the device too) the source reopened as a user would (`obs-check.py reopen`: Color Range changed and back) at 720p and again after a change to 1080p: the source at its new size against `pattern.py` |
| `soak` | not in the default steps: `GC573_SOAK_SECS` (7200) of audio and video (1080p60 YUYV) together with `avsync.sh`, the capture detached in the VM (`gc573-aud -V`): the `avsync` checks over the run (no overrun, no gap, no video sequence gap or interval off by half a period, channels, A/V drift) and the driver's period counters; every minute `/proc/meminfo` (MemAvailable, Slab, SUnreclaim) and the CPU time of the capture, of the driver's IRQ thread and of the VM: from minute 5 to the end SUnreclaim grows < 2 MB and Slab < 4 MB (`soak-memory`), CPU use reported |
| `blip` | a short lock in other timings while streaming, as after a hot-plug when the GPU shows its preferred mode before the desktop's: 1080p60 -> 720p and back as soon as the driver has locked at 720p (`xrandr`, no player). The stream carries on (`blip-continue`: no `DQBUF` error, frames after the last event), the driver locked at 720p meanwhile (`blip-other-lock`), and debugfs counts a hold and no stop (`blip-held`). Then 720p for good: the `DQBUF` error comes 0.9-1.6 s after the lock (`blip-hold-ms`) |
| `obssoak` | not in the default steps: the event soak with OBS, `GC573_OBSSOAK_SECS` (7200) recorded, a change every `GC573_OBSSOAK_EVERY` (180) s (`obs-events.py soak`), a screenshot every 2 s; the recording (pattern, counter steps, A/V offset per segment between changes), memory and CPU. Host form (local mode): the rotation `GC573_OBSSOAK_ROTATION` (output off/on, 60 <-> 59.94 Hz, 1080p <-> 720p with OBS's reopen, EDID re-sets), the recording in `GC573_REC_DIR` (`~/gc573-rec`, deleted after the analysis), OBS minimized, a sample a minute (memory, CPU, the driver's debugfs counters, kernel log lines), the memory check from before OBS starts to after OBS has exited and the recording is deleted (the recording's page cache grows SUnreclaim meanwhile), no change skipped, the recovery led by the input (`tests/obsbridge.py`: after each source-change event and 2 s of a still input, a reopen when the timings differ from the stream's or the driver ended the stream; `obsev-bridge`: a reopen in every res-* change and in no other), the picture as the fallback (before a change, and a 10 s watchdog between changes: reopens with backoff, 5, 10, 20, 40, then every 60 s, until good; `obsev-recoveries` counts these and the bridge's reopens outside the changes), the recording judged by the counter's motion (a 720p source stretched to the 1080p canvas is read at its own size), and 60 s of `gc573-aud -V -P` in the source sessions of the first and last segments: OBS's own part of the A/V offset at both ends (`obs-own`: each from a frame period early to 70 ms plus a frame period late, -16.7 to +86.7 ms: libobs lays an audio source's samples back to back while they stay within 70 ms of their timestamps, so OBS's offset wanders with the source's audio clock and comes back by 70 ms at a time). In the recording, per source session from 15 s after a change, the bursts' period against the media period and every interval off it by 4 ms or more (`audio-timeline`: OBS's 70 ms resets reported, any other step fails). Memory: the driver's own (`obssoak-memory`: debugfs `video` "mem" all 0 before OBS starts and after it has exited); the kmalloc caches' growth is `INFO memory-kmalloc`, every program's. `GC573_OBSSOAK_INJECT=T:MODE:RATE`: an outside change T s into the recording that the harness is not told of (a trial of the recovery; its player is retried until it has started). The rotation's kinds `idle`, `reopen-video` and `reopen-audio` act on OBS alone, so a soak of only those keeps one source session and OBS's own offset is known in every segment. `GC573_OBS_BRIDGE=0`: without the bridge |
| `apps` | not in the default steps: ffmpeg, GStreamer and VLC, each where present (GStreamer not on the host: its v4l2 plugin opens every /dev/video* node when it loads). Headless into a file, on the GC573's nodes named explicitly. Captures of `avsync.sh --pattern` with the card's audio, `GC573_APPS_SECS` (10) s: 1080p60 and 720p59.94 YUYV, 1080p60 NV12, checked by `tests/app-check.py` (counter steps and timestamp gaps, the pattern, channel order, the audio rate, the A/V offset from the file's timestamps against the driver's in the same source session). Then one of each change while it records 30 s: sleep/wake, a same-mode relock (EDID hot-plug), 60 -> 59.94 Hz, 1080p -> 720p. An `APP` line says whether it subscribed to events and dequeued any (strace, which does not decode the event type; the driver raises `V4L2_EVENT_SOURCE_CHANGE` at every change), carried on, errored out or froze, and whether a restart at the new mode brings it back. FAIL when it does not carry on through a change in the same timings, or a restart does not bring it back. GStreamer is judged at 60 -> 59.94 Hz as at a new resolution: the new frame rate is a caps change, which ends its Matroska file |
| `unload` | `rmmod` while streaming video and audio (refused, in use), unbind (< 5 s, both applications exit), rebind, lock |
| `reload` | `GC573_RELOADS` (50) unload/load cycles with the source on: host output back and input locked each time |
| `compliance` | `v4l2-compliance -s` with the live input |
