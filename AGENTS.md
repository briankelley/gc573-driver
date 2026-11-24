# AGENTS.md

Audience: AI agents. Humans → README.md.

## Project
- Target: AVerMedia GC573 (Live Gamer 4K). PCI 1461:0054, subsys 1461:5730. BAR0 32b MMIO 512K. PCIe Gen2 x4.
- Deliverable: single GPL-2.0 kernel module. V4L2 capture + ALSA PCM capture. DKMS.
- Priority: 1080p60 > 4K30 > 4K60 > HDR.
- Done = v4l2-compliance clean + OBS live A/V sync + 2h soak + reboot + DKMS rebuild on kernel bump.

## Contribution policy
- Agent-driven only. Agent writes code, runs tests, writes commit msg. Human directs/verifies.
- Agent-assisted (human-authored code w/ AI help) → rejected.
- Commit trailer: `Co-Authored-By: <model> <addr>` naming the agent model.

## Clean room — hard rules
- NO vendor (AVerMedia) source, blobs, headers, or verbatim tables in repo. Ever.
- Vendor material = documentation only. Lives outside repo (`vendor-ref/` gitignored; prefer outside tree).
- Spec session ≠ driver session. Driver code derives from `spec/` only.
- `spec/` = facts: offsets, bitfields, sequences, timings, evidence refs (trace file + line). No vendor code, no decompiler output pasted.
- Vendor-derived driver (lg4k-linux forks) runs ONLY in reference VM. Never insmod on host — crashes 6.x.

## Layout (target; created as work lands)
- `spec/` hw spec. regmap, irq, dma desc fmt, i2c master, it6805/it6664 seqs, audio, auth chip.
- `traces/` sanitized trace captures (offset/value/dir/ts). Scenario-named.
- `src/` driver.
- `dkms.conf`, `Makefile` kbuild.
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
- `tools/devvm/create.sh` — builds `gc573-dev` VM: Ubuntu 24.04 cloud img, kernel 6.8 GA + headers. dkms, sparse, v4l-utils (v4l2-ctl, v4l2-compliance), edid-decode, alsa-utils, trace-cmd, ffmpeg, python3-numpy, OBS (PPA latest), Xfce autologin. Same user/key as ref VM.
- `tools/devvm/debug-kernel.sh` — builds Ubuntu 6.8 source + kmemleak, lockdep, DEBUG_ATOMIC_SLEEP, KASAN, DMA_API_DEBUG on host; installs `6.8.12-gc573dbg` in `gc573-dev` as extra entry (default boot stays generic). Boot once: `sudo grub-reboot "$(cat /etc/gc573-dbg-entry)" && sudo reboot`. Leak/lock/DMA gates run on this kernel.
- checkpatch: `/lib/modules/$(uname -r)/build/scripts/checkpatch.pl --strict --no-tree -f <file>` (in `gc573-dev`).
- Regression VM matrix: Ubuntu, Mint, RHEL-family; one VM per distro version, named `gc573-<distro><ver>`, built by scripts in `tools/`. Retain all: never delete or rebuild over an existing regression VM; add new versions alongside. Current: `gc573-ref` (Ubuntu 20.04, vendor drv only), `gc573-dev` (Ubuntu 24.04).
- One VM owns the card at a time. `virsh shutdown` the other before `virsh start` (desktop guests may ignore ACPI shutdown: `ssh <vm> sudo poweroff`).
- Ghidra 12.x requires JDK 25. Headless: `ghidra-headless`.
- Tracing: patch vendor source layer (`pci_model_mmio_*`, i2c wrappers, isr, dma alloc) in VM; `trace_printk`/ftrace ring. Cross-check: mmiotrace.
- Tool ver changes → update scripts + this file same commit.

## Driver design constraints
- `pcim_*` managed resources. `pci_enable_device` + `pci_set_master` + iomap. (vendor drv omitted → dead BAR.)
- MSI if cap present else INTx. Threaded IRQ.
- No sleeping under spinlock. FPGA i2c master → `i2c_adapter`, sleepable. HDMI rx event handling in threaded irq / workqueue. (vendor drv: scheduling-while-atomic.)
- IT6805 / IT6664 → v4l2 subdevs preferred.
- vb2 (dma-sg or dma-contig per desc fmt). DV timings API + `V4L2_EVENT_SOURCE_CHANGE`.
- Formats: NV12, YUYV min. RGB24 only if verified in OBS.
- Style: kernel coding style, `scripts/checkpatch.pl --strict` clean. SPDX GPL-2.0 header every file.

## Milestones (driver)
Each gate passes in `gc573-dev` before the next starts.
- M0 skeleton: probe/remove, BAR map, FPGA init + quiesce (`spec/init.md`), MSI + threaded IRQ. Gate: load/unload ×50, clean dmesg, VERSION read.
- M1 I2C: bus-1 engine adapter; bus 0/2 OpenCores adapters. Gate: chip IDs (0x90 → `54 49 05 68`; 0x58 → `54 49 63 66`).
- M2 video DMA, no input: vb2 dma-sg, 3 channels, 6 formats, free-running frames. Gate: pre-filled buffers overwritten; `v4l2-compliance -s` 0 fail.
- M3 HDMI bring-up: splitter + IT6805 per `spec/hdmi-chips.md`, poll loop, DV timings, `V4L2_EVENT_SOURCE_CHANGE`. Gate: live 1080p59.94 capture, all formats, image verified.
- M4 audio: ALSA PCM capture. Gate: capture with live source, A/V sync in OBS.
- M5 EDID (`VIDIOC_G/S_EDID`), hotplug + mode-change stress, controls, scaling. Gate: test suite v1.
- M6 DKMS, host validation, OBS, 2 h soak. Gate: "Done" (see Project).
- Later: 2160p30, 2160p60 4:2:0 (open: black under RD), HDR.

## Tests
- `tests/` = regression suite. Every behavior change ships w/ test(s). Every bug fix ships w/ failing-before test.
- PR must include run log of full suite on real GC573 hw: pass/fail per case, kernel ver, card fw ver, input source + mode.
- Required gates per PR:
  - build: clean kbuild, zero warnings, W=1.
  - checkpatch --strict clean.
  - `v4l2-compliance -d <dev> -s` 0 fail.
  - load/unload x50, no leaks (kmemleak), no WARN/BUG in dmesg.
  - capture: each supported mode × fmt, frame cadence + checksum/pattern check where source allows.
  - hotplug + mode-change stress.
  - audio: capture, A/V drift bound.
  - soak: 2h continuous (release-tagged PRs; others: 10 min).
- Harness + case format: TBD in `tests/README` once driver probes. Until then: no driver PRs without manual equivalent log.
- New driver: bring-up + suite in `gc573-dev` VM (crash containment). Release validation on host. Vendor drv: `gc573-ref` VM only.

## Process
- Small commits. One concern each. Imperative subject ≤72 ch.
- Never commit: vendor material, credentials, raw unsanitized traces w/ PII, build artifacts.
- Hw facts uncertain → mark `UNVERIFIED` in spec + evidence needed. Don't guess regs.
- Ambiguity re hw behavior → trace it, don't infer.
