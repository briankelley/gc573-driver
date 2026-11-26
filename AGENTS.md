# AGENTS.md

Audience: AI agents. Humans → README.md.

## Project
- Target: AVerMedia GC573 (Live Gamer 4K). PCI 1461:0054, subsys 1461:5730. BAR0 32b MMIO 512K. PCIe Gen2 x4.
- Deliverable: single GPL-2.0 kernel module. V4L2 capture + ALSA PCM capture. DKMS.
- Priority: 1080p60 > 4K30 > 4K60 > HDR.
- Done = v4l2-compliance clean + OBS live A/V sync + 2h soak + reboot + DKMS rebuild on kernel bump. The user's own use (an agent driving a Roku through OBS and obs-websocket) needs this first (M5, M6).
- Fully adapted = the whole card supported (M7–M9): every hardware function a Linux capture driver should expose works, or is documented as unsupported with the reason. The user wants this; "Done" is a waypoint, not the end.

## Contribution policy
- Agent-driven preferred (README): agent writes code, runs tests, writes commit msg; human directs/verifies.
- Contributions are welcome; the owner prefers agent-driven ones over agent-assisted (human-authored code w/ AI help).
- Commit trailer: `Co-Authored-By: <model> <addr>` naming the agent model.

## Clean room — hard rules
- NO vendor (AVerMedia) source, blobs, headers, or verbatim tables in repo. Ever.
- Vendor material = documentation only. Lives outside repo (`vendor-ref/` gitignored; prefer outside tree).
- Spec session ≠ driver session. Driver code derives from `spec/` only.
- `spec/` = facts: offsets, bitfields, sequences, timings, evidence refs (trace file + line). No vendor code, no decompiler output pasted.
- Vendor-derived driver (lg4k-linux forks) runs ONLY in reference VM. Never insmod on host — crashes 6.x.

## Layout (target; created as work lands)
- `spec/` hw spec. regmap, irq, dma desc fmt, i2c master, it6805/splitter seqs, audio, auth chip.
- `traces/` sanitized trace captures (offset/value/dir/ts). Scenario-named.
- `src/` driver.
- `dkms.conf`, `Makefile` + `Kbuild` (out-of-tree kbuild).
- `tests/` regression suite. See Tests.
- `tools/` env setup. See Tooling.

## Tooling (canonical; use these, don't substitute)
Host: Linux Mint 22 / Ubuntu 24.04, kernel 6.8, x86_64, VT-d on.
- `tools/host-setup.sh` — idempotent. qemu/libvirt/virt-manager/OVMF, driverctl, v4l-utils, OBS (obsproject PPA, latest), OpenJDK 25, Ghidra (pinned ver, sha256 verified) → /opt/ghidra. Binds card → vfio-pci (persistent).
- `tools/refvm/create.sh` — builds `gc573-ref` VM (env NAME/RELEASE/OSINFO/USERDATA/START; START=0 = provision only):
  - Ubuntu 20.04 cloud img, kernel 5.4 GA (`linux-generic`) + modules-extra + headers. Vendor blobs reject newer kernels.
  - UEFI, Secure Boot OFF (non-.ms OVMF). Required: unsigned modules + mmiotrace; lockdown must = none.
  - Card passthrough via hostdev. Card must be sole member of its IOMMU group.
  - SPICE + Xfce autologin user `dev`; OBS 29.1.3 (last PPA build for focal).
  - SSH key `~/.ssh/gc573-vm`; user `dev`, NOPASSWD sudo.
- `tools/devvm/create.sh` — builds `gc573-dev` VM: Ubuntu 24.04 cloud img, kernel 6.8 GA + headers. dkms, sparse, v4l-utils (v4l2-ctl, v4l2-compliance), edid-decode, alsa-utils, libasound2-dev, trace-cmd, ffmpeg, python3-numpy, OBS (PPA latest), Xfce autologin. Same user/key as ref VM.
- `tools/devvm/debug-kernel.sh` — builds Ubuntu 6.8 source + kmemleak, lockdep, DEBUG_ATOMIC_SLEEP, KASAN, DMA_API_DEBUG on host (+ vivid, which keeps the videobuf2 stack through localmodconfig); installs `6.8.12-gc573dbg` in `gc573-dev` as extra entry (default boot stays generic). Boot once: `sudo grub-reboot "$(cat /etc/gc573-dbg-entry)" && sudo reboot`. Leak/lock/DMA gates run on this kernel.
- checkpatch: `/lib/modules/$(uname -r)/build/scripts/checkpatch.pl --strict --no-tree -f <file>` (in `gc573-dev`).
- `tools/vmbuild.sh [load|unload|check|test [CASE..]]` — host side. rsyncs Makefile, Kbuild, dkms.conf, `src/`, `tests/` to `gc573-dev:~/gc573-driver` (env VM/VMDIR), clean `W=1` build against the VM's running kernel; any warning fails. `load` (re)loads with INSMOD_ARGS and prints the probe's dmesg; `unload`; `check` = checkpatch --strict on `src/` + sparse `C=2`; `test` runs `tests/run.sh` as root in the VM, log → `tests/logs/<UTC>_<krel>.log` (commit it). Never loads on the host.
- Regression VM matrix: Ubuntu, Mint, RHEL-family; one VM per distro version, named `gc573-<distro><ver>`, built by scripts in `tools/`. Retain all: never delete or rebuild over an existing regression VM; add new versions alongside.
  - `tools/vms/create.sh <profile> [IP]` (cloud images; profiles in `tools/vms/profiles/`), `tools/vms/mint.sh <ver> [edition] [IP]` (ISO unattended install + virt-customize). Disks standalone (no shared backing). No persistent card.
  - `tools/vms/matrix-build.sh [-r REF] [-j N] [--load] [--dkms] [VM...]` builds REF (git archive) in each VM against every kernel with headers: W=1, any warning fails; `--load` = insmod/rmmod smoke test (no card: init/exit + symbols); `--dkms` = dkms add/build per kernel. Starts/stops VMs. Logs + `summary.tsv` → `tests/logs/matrix/<UTC>-<sha>/` (commit them). Default VMs: all but `gc573-ref`, `gc573-dev`. No tty: set `SUDO_ASKPASS` to a helper printing the sudo password.
  - `tools/vms/card.sh <vm>` moves the card between running VMs (live PCI unplug/plug; detach fails if the guest driver does not release it). `--where` shows the holder.
  - `tools/vms/install-test.sh [-r REF] [VM...]` runs `tools/install.sh` / `uninstall.sh` (the user's DKMS install) at REF in each matrix VM: missing-headers and missing-dkms errors, install for every kernel with headers, the card's modalias resolving, DKMS AUTOINSTALL via the kernel hook, a reboot, uninstall leaving nothing. Logs + `summary.tsv` → `tests/logs/install/<UTC>-<sha>/` (commit them). Never `gc573-dev` (card) or `gc573-ref`.
  - `tools/vms/install-card-test.sh [-r REF]`: the same scripts in `gc573-dev`, with the card. A persistent driverctl override to vfio-pci plays a host that passes the card to a VM (in the VM vfio-pci cannot bind: no IOMMU). Steps:
    - without a terminal (card left alone), and `--permanent` refused without `--yes`;
    - menu choice 3, then 1 (this boot), then a reboot (gc573 not loaded, the override holds the card);
    - `--this-boot` with streaming, and the uninstall (override loaded again);
    - `--permanent --yes`, a reboot (alias load, lock, 30 frames), and the uninstall (override put back);
    - with no override: bind at once, autoload only after that first probe;
    - cleanup (driverctl purged, reboot; then `tools/vmbuild.sh load`). Log → `tests/logs/install/<UTC>-<sha>/gc573-dev-card.log`.
- User install: `tools/install.sh [--this-boot | --permanent | --no-bind] [--yes]` (DKMS add/build/install for every kernel with headers; refuses while a VM uses the card) and `tools/uninstall.sh [--yes]` (undoes the binding, then removes everything). Rule: a crash at probe must never repeat at boot (the user's recovery is a reboot). So `/etc/modprobe.d/gc573-no-autoload.conf` (`blacklist gc573`: no load by alias; `modprobe gc573` and driverctl still work) stays until gc573 has taken the card once, and for as long as a driverctl override keeps the card for another driver. With a persistent override (vfio-pci) there are three choices. The default is this boot only: `driverctl --nosave set-override <dev> gc573`, so a reboot returns the card. Uninstall runs `driverctl load-override`. Permanent asks, records the removed override, and uninstall puts it back. The third is leave alone. Never run them on the host: host validation is the spec session's, with the user.
  - Current (VM: distro, kernel, IP): `gc573-ref` Ubuntu 20.04, 5.4, .39 (vendor drv only) · `gc573-dev` Ubuntu 24.04, 6.8.0 (+ debug 6.8.12), .40 · `gc573-alma9` AlmaLinux 9.9, 5.14, .41 · `gc573-alma10` AlmaLinux 10.3, 6.12, .42 · `gc573-fedora45` Fedora 45, 7.3, .43 · `gc573-ubuntu2604` Ubuntu 26.04, 7.0, .44 · `gc573-mint223` Mint 22.3, 6.14 HWE, .45. Host: Mint 22, 6.8.0. ssh aliases = VM names.
  - Gaps: EL10 has no v4l2-compliance package (build v4l-utils from source there). EL9 kernel lacks videobuf2-dma-sg/-dma-contig (see design constraints).
- Live source: PC loopback, cabled permanently. Host GT 710 DVI-D-0 → DVI-to-HDMI cable → GC573 HDMI IN. Test windows never go on HDMI-0 (the user's screen), not even hidden.
  - Every test player (ffplay) runs with `tools/testsrc/place.so` (`place.c`, built by `place.sh`, LD_PRELOAD).
    - Its window is created override-redirect at DVI-D-0's geometry and never has another, mapped or not.
    - It is mapped only after a check under a server grab: the geometry inside DVI-D-0's RandR monitor and overlapping no other.
    - Plain SDL would create it hidden on the primary output and move it before the map.
  - `window-check.sh` verifies the window after the map.
  - A watchdog (`watchdog.sh`, 0.2 s) closes the player when DVI-D-0 stops showing that geometry.
  - The scripts close every player before any check or mode change: stop the source before turning the output off or changing its mode.
  - Proof: `tests/window-proof.sh` (528 starts across modes, output off/on and EDID hot-plugs, with no map outside DVI-D-0). `tools/testsrc/show.sh [--counter] [OUTPUT [MODE [RATE]]]` (host only) shows `tools/testsrc/pattern.py`'s exact-value pattern full-screen on that output (`--counter`: with a 16-bit frame counter and a flash box in the bottom band, `counter-graph.sh`) and turns GPU dithering off; `--off` closes it. The output is visible to the host only while a driver runs the HDMI chips (EDID loaded, HPD high); after `rmmod gc573` it stays connected, and a reload shows the source nothing either (open: the HPD drop at remove is not seen; `tests/hpd-unload.sh` polls the host's ELD and xrandr across an unload and load). 1080p60 arrives as full-range RGB with an AVI InfoFrame; no audio packets unless avsync.sh runs; expect ≤ +1 per channel. `tools/testsrc/avsync.sh [--pattern] [--amplitude A] [OUTPUT [MODE [RATE]]]` (host only): black clip with a one-frame white flash every N frames (N = nominal rate; `--pattern`: the counter pattern, flash in its box) and a tone burst of one frame's length at the same instant (1 kHz left, 2 kHz right; `--amplitude 0` is silent). The counter picture's frames are timed at n/FPS (`counter-graph.sh`: `settb=AVTB` before `setpts`; through the PNG's own 1/25 s time base ffplay got the frames in 40 ms bunches and showed 5 of every 6, until 2026-11-25). On the card, every source frame then arrives once (`tests/live.sh exact`). DVI-D-0's 60 Hz mode and the GPU's HDMI audio both run +24 ppm against CLOCK_MONOTONIC, so `avsync.sh` (ffplay paced by the audio clock) holds its phase to the display; `show.sh --counter` (system clock) slips a frame about every 12 min, and at 59.94 Hz (display +13 ppm) `avsync.sh` about every 25 min. The audio plays through PipeWire's own API (SDL) as node gc573-avsync, targeted at the NVIDIA HDMI sink of the capture card's port with node.dont-reconnect: WirePlumber 0.4.17 destroys the stream instead of moving it when that sink goes, so it never reaches another sink (`route-check.sh`). The card profile is switched for the session only (pw-cli, save=false), and nothing WirePlumber stores is changed (`state-check.sh`). avsync.sh needs the card's ELD before it sets its mode. After an output off/on (xrandr), the NVIDIA driver sometimes reports no ELD until the next mode set (3 of 84 cycles in `tests/window-proof.sh`), so start show.sh first, or set the mode again, before avsync.sh. The source's own A/V offset is +24 to +45 ms (audio late) and changes between sessions: measure it with the driver in the same session (live.sh avsync, obsav). WirePlumber turns the NVIDIA HDMI profile on by itself when the card's ELD appears if its stored profile for that card says so: stored `output:hdmi-stereo` since 2026-11-25 (written by avsync.sh before 853ccdf; AGENTS.md had `off`); whether to put back `off` is the user's call. `tools/testsrc/guard.py` watches whole runs (live.sh, obs-events.py, window-proof.sh).
  - Windows are watched through X events: `tools/testsrc/xwatch.py`, which also runs standalone. Every test window's create, configure and map arrives in the X server's order, with its geometry.
  - Do not poll window geometry and map state in two requests. guard.py's old poll paired a position from before ffplay's move with a map state from after it: the false breach at 17:49:21.807Z on 2026-11-25 (`tests/logs/20261125T180804Z-window-rootcause.log`).
  - Audio links are polled every 50 ms.
  - Cameras: `tools/testsrc/camwatch.py` (fanotify, root; guard.py starts it through `sudo -A`/`-n` with `--guard` on every run, and it also runs standalone with `--log FILE`). It logs every open of a /dev/video*, /dev/media* or /dev/snd node that is not the GC573's or the NVIDIA HDMI audio's, with the device's ID_SERIAL_SHORT. An opener is ours when CLAUDECODE=1 (set by Claude Code for every command it runs; it survives daemonizing) is in its environment or an ancestor's. Ours: BREACH, with pid, comm, command line and parents. PipeWire's own processes and udev's work, and anything not ours within 10 s of a node appearing (hot-plug): INFO. Anyone else's (the user's own programs): OTHER, pid and comm only, never a breach. An opener that exited before it could be looked up, outside a hot-plug window: UNKNOWN standalone, BREACH with `--guard`. It reports file handles (FAN_REPORT_FID), never fds: in fd mode the kernel would open the node for the watcher at every event. New nodes are marked as they appear (inotify on /dev and /dev/snd): a KVM switch brings the face camera and takes it away. `GC573_CAMWATCH=0` runs the guard without it (logged).
  - A test window mapped outside DVI-D-0, test audio linked to any other sink, an open of a camera or other sound card's node by one of ours, or a watcher that fails closes every player and stops the run. `GC573_EVENT_LOG=FILE`: every action that changes the card's input (output, mode, colour, EDID, players, driver load, streams, OBS) with UTC ms; live.sh writes `tests/logs/<run>-events.log`. HDCP-source tests need the Roku (pending). `spec/hdmi-chips.md` §PC loopback.
- Never on the host, by an agent or a tool, anything that enumerates or probes devices (each of these has opened a camera's node here):
  - any GStreamer use that can load its v4l2 plugin: `v4l2src`, `gst-inspect-1.0` on it, a registry rebuild. Its plugin_init runs the M2M probe ("Probing devices"), which opens every /dev/video* and issues QUERYCAP. `GST_REGISTRY_UPDATE=no` does not stop that probe. GStreamer is tested in gc573-dev only (the same 1.24.2 and the same card);
  - OBS `GetInputPropertiesListPropertyItems` on a V4L2 or ALSA source's property;
  - `arecord -l`/`-L`, `aplay -l`/`-L`;
  - VLC help or listings (`-p`, `-H`): its ALSA choices enumerate every card;
  - `ffmpeg -sources`, `-list_devices`;
  - `v4l2-ctl` or `v4l2-compliance` without `-d <by-path>`, and `--list-devices`;
  - qv4l2, cheese, guvcview;
  - an ALSA PCM named by the card's id (`hw:CARD=GC573,DEV=0`, `hw:GC573,0`, in any tool, OBS's ALSA source included): alsa-lib looks an id up by opening the control node of every card before it (snd_card_get_index), the C920's here. camwatch caught it at gc573-aud's start on 2026-11-26 (`tests/logs/20261126-031656_6.8.0-151-generic_live-events.log`); every capture by that name had done it before.
  For discovery use `/proc/asound/cards`, `/sys/class/video4linux/*/name`, sysfs links and `udevadm info`: none of them opens a node. Name the GC573's nodes explicitly: `/dev/v4l/by-path/pci-0000:07:00.0-video-index0`, and the PCM by its control node's path, `hw:CARD=/dev/snd/by-path/pci-0000:07:00.0,DEV=0` (alsa-lib opens a path or an index, `hw:N,0`, alone). `tests/obs-run.sh --keep-config` refuses to start OBS while the gc573 collection's ALSA source names the card by its id.
- OBS in `gc573-dev` (PPA, 32.2.0 now): `tests/obs-run.sh start|stop` (minimal profile, obs-websocket on *:4455 without a password; recording format from `GC573_OBS_RECFORMAT`, default hybrid_mp4, written to the profile before OBS starts: OBS sets up its recording output only at start or in its Settings window), set up by `tests/obs-check.py` through `tests/obsws.py` with stable names (V4L2 `/dev/v4l/by-path/pci-0000:07:00.0-video-index0`, ALSA `hw:CARD=/dev/snd/by-path/pci-0000:07:00.0,DEV=0`). `tests/obs-events.py` drives it from the host (OBS_HOST, default 192.168.122.40; PIL only; `GC573_VM=local`: the driver and OBS on this machine): screenshots, meters, every source change with time to the first good frame, the event soak. `tests/live.sh obs obsav obschange obsws obsevents avchange`, and not by default `obssoak` (2 h) and `obspw` (the card's audio through PipeWire; lifts the udev rule `90-gc573-pulse-ignore.rules` and installs `tests/obspw.lua` for the step, since WirePlumber gives every ALSA node 8192 frames of headroom in a VM). OBS 32's V4L2 source ignores V4L2 events, ends its capture thread at the first DQBUF error, and opens the device again only when a compared setting changes (toggle `color_range` 0 ↔ 1 with SetInputSettings). obs-ffmpeg-mux (MKV and OBS's other ffmpeg formats) inherits OBS's file descriptors, the V4L2 device's too (opened without O_CLOEXEC): while it records, that reopen gets EBUSY. Hybrid MP4 is written in OBS's process, and the reopen works. OBS's V4L2 "buffering" (default on) plays frames by timestamp against a clock that stands still while no frame is queued (libobs get_closest_frame/ready_async_frame): every frame gap under 2 s (the driver's restarts at source changes: 0.2-0.9 s) adds to the video delay for good. The README recommends buffering off; live.sh takes it from GC573_OBS_BUFFERING (default 1, OBS's default; the event soaks ran with 0). The driver's own A/V offset holds through restarts (live.sh avchange).
  - A lock in other timings holds a stream for up to 1 s before it fails (`spec/hdmi-chips.md` "Stream policy on input changes"; `live.sh blip`): after an EDID change the GPU shows the EDID's preferred mode until the desktop's mode set. Failing at once ended OBS's capture in the first host soak (23:11:06Z, `tests/logs/20261125-215755_6.8.0-151-generic_live.log`).
  - obs-events never skips a change: a picture that is not good before one is reopened first while the driver is locked (RECOVER), and between changes a 10 s watchdog does the same; RESULT obsev-recoveries fails if either was needed. A skipped change leaves the input as it is, so every later change was skipped too. `recheck` judges each sample by the counter's progress over 0.5 s (live, frozen, jumpy): a frozen pattern passes a still.
- Host-local mode, for the host validation (`GC573_LOCAL=1 tests/live.sh STEP..`; `tests/README.md`): the checks run where the driver runs, without ssh. `live.sh` refuses to load, unload, bind or unbind the driver there and runs only `LOCAL_STEPS`; OBS is the user's (`obs-run.sh --keep-config`: started minimized to the tray, its configuration not written; `obs-check.py verify` reads the sources, as `setup` would make OBS open every `/dev/video*` node, cameras too). `obssoak` on the host: no colour changes, the recording in `GC573_REC_DIR` (default `~/gc573-rec`; deleted after the analysis), and the driver's own A/V offset (`gc573-aud -V -P`) in the first and last segments' source sessions. Its memory check compares SUnreclaim before OBS starts with after OBS has exited and the recording is deleted: written file data grows SUnreclaim on any file system (memcg obj_cgroup vectors for buffer_head slab pages, about 600 x 512 bytes per 100 MiB, freed with the page cache; `tests/logs/20261126T0017Z-host-slab-attribution.log`).
- One VM owns the card at a time. `virsh shutdown` the other before `virsh start` (desktop guests may ignore ACPI shutdown: `ssh <vm> sudo poweroff`).
- Ghidra 12.x requires JDK 25. Headless: `ghidra-headless`.
- Tracing: patch vendor source layer (`pci_model_mmio_*`, i2c wrappers, isr, dma alloc) in VM; `trace_printk`/ftrace ring. Cross-check: mmiotrace.
- Tool ver changes → update scripts + this file same commit.

## Driver design constraints
- `pcim_*` managed resources. `pci_enable_device` + `pci_set_master` + iomap. (vendor drv omitted → dead BAR.)
- MSI if cap present else INTx. Threaded IRQ.
- No sleeping under spinlock. FPGA i2c master → `i2c_adapter`, sleepable. HDMI rx event handling in threaded irq / workqueue. (vendor drv: scheduling-while-atomic.)
- IT6805 / splitter (ITE 0x6663) → v4l2 subdevs preferred.
- vb2 memory: driver-private `vb2_mem_ops` (EL9 5.14 ships neither videobuf2-dma-sg nor -dma-contig). Pages from `alloc_pages(GFP_KERNEL | __GFP_DMA32)` while the DMA mask is 32-bit; `vmap` for kernel access; `sg_table` → `dma_map_sgtable` → descriptor lists; mmap by page insertion. Not videobuf2-vmalloc: its pages land above 4 GB, which a 32-bit mask bounces through swiotlb when no IOMMU translates (VM, `iommu=pt`): small pool, a copy per frame. MMAP first; USERPTR/DMABUF import later. Mem-ops signature differences across kernels in `src/compat.h`. DV timings API + `V4L2_EVENT_SOURCE_CHANGE`.
- Formats: NV12, YUYV min. RGB24 only if verified in OBS.
- Style: kernel coding style, `scripts/checkpatch.pl --strict` clean. SPDX GPL-2.0 header every file.
- Kernel range: every regression-matrix VM kernel (today 5.14 EL9 → 7.3 Fedora 45). Kernel-version differences only in `src/compat.h` (`LINUX_VERSION_CODE` / `RHEL_RELEASE_CODE`); no #ifdef elsewhere.

## Milestones (driver)
Each gate passes in `gc573-dev` before the next starts.
- M0 skeleton: probe/remove, BAR map, FPGA init + quiesce (`spec/init.md`), MSI + threaded IRQ. Gate: load/unload ×50, clean dmesg, VERSION read.
- M1 I2C: bus-1 engine adapter; bus 0/2 OpenCores adapters. Gate: chip IDs (0x90 → `54 49 05 68`; 0x58 → `54 49 63 66`).
- M2 video DMA, no input: vb2 with driver mem ops (see design constraints), 3 channels, 6 formats, free-running frames. Gate: pre-filled buffers overwritten; `v4l2-compliance -s` 0 fail.
- M3 HDMI bring-up: splitter + IT6805 per `spec/hdmi-chips.md`, default EDID in both RAMs (`spec/hdmi-chips.md` §Default EDID), poll loop, DV timings, `V4L2_EVENT_SOURCE_CHANGE`. Gate: live 1080p60 and 1080p59.94 capture from the PC loopback, all formats, image verified against `tools/testsrc/pattern.py`. Done (merge 8319fcd); open: delivery below 59.94 Hz (`spec/open-questions.md` #33).
- M4 audio: ALSA PCM capture. Gate: capture with live source (`tools/testsrc/avsync.sh` on the PC loopback): channel order and rate verified, 10 min without xruns or gaps, A/V offset and drift measured from the video and audio timestamps. The OBS A/V check is in M5. Done (merge 90c9d13).
- M5 delivery: DKMS packaging and an install/uninstall script for the user; OBS (video formats, A/V sync measured from a recording, source changes) and a 2 h soak in `gc573-dev`; then host validation by the spec session with the user (v4l2-compliance, OBS, 2 h soak, unload/reload, reboot, DKMS rebuild after a kernel update). The EDID ioctls, hotplug and mode-change tests landed in M3.
- M6 Roku: the Roku through the HDCP filter (the user moves the input cable). OBS capture driven through obs-websocket, unattended recovery from Roku sleep/wake, reboot and mode changes; behaviour without the filter (open question 25). Gate: "Done" (see Project).
- M7 picture controls and scaling: brightness, contrast, saturation and hue on the colour-adjust block; hardware scaling to sizes other than the input's (`spec/video-pipeline.md` scalers). Gate: v4l2-compliance with controls; scaled captures verified against the pattern.
- M8 4K: 2160p30 (dual-pixel DDR, works under RD), then 2160p60 4:2:0 (open question 14, including the IT6805 conversion and down-scaler paths), and an EDID option that offers 4K. Gate: 2160p30 from the PC loopback and 2160p60 from the Roku captured and verified.
- M9 complete: HDMI passthrough output; HDR and 10-bit (InfoFrame colorimetry and transfer reported, 10-bit output formats if the FPGA has them); interlaced and deep-colour input; audio beyond LPCM 2.0 48 kHz; suspend/resume; several cards; front LEDs (open question 11); remaining open questions closed or documented. Gate: "fully adapted" (see Project).
- Later: 2160p30, 2160p60 4:2:0 (open: black under RD), HDR.

## Tests
- `tests/` = regression suite. Every behavior change ships w/ test(s). Every bug fix ships w/ failing-before test.
- PR must include run log of full suite on real GC573 hw: pass/fail per case, kernel ver, card fw ver, input source + mode.
- Required gates per PR:
  - build: clean kbuild, zero warnings, W=1, on every matrix VM kernel (`tools/vms/matrix-build.sh --load --dkms`).
  - checkpatch --strict clean.
  - `v4l2-compliance -d <dev> -s` 0 fail.
  - load/unload x50, no leaks (kmemleak), no WARN/BUG in dmesg.
  - capture: each supported mode × fmt, frame cadence + pattern check (PC loopback: allow +1 per channel; skip the first frame after start, see `spec/video-dma.md`).
  - hotplug + mode-change stress.
  - audio: capture, A/V drift bound.
  - soak: 2h continuous (release-tagged PRs; others: 10 min).
- Harness + case format: `tests/README.md` (`tests/run.sh`, cases in `tests/cases/`, logs in `tests/logs/`).
- New driver: bring-up + suite in `gc573-dev` VM (crash containment). Release validation on host. Vendor drv: `gc573-ref` VM only.

## Process
- Small commits. One concern each. Imperative subject ≤72 ch.
- Never commit: vendor material, credentials, raw unsanitized traces w/ PII, build artifacts.
- Hw facts uncertain → mark `UNVERIFIED` in spec + evidence needed. Don't guess regs.
- Ambiguity re hw behavior → trace it, don't infer.
