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
- `tools/refvm/create.sh` — builds `gc573-ref` VM:
  - Ubuntu 20.04 cloud img, kernel 5.4 GA (`linux-generic`) + modules-extra + headers. Vendor blobs reject newer kernels.
  - UEFI, Secure Boot OFF (non-.ms OVMF). Required: unsigned modules + mmiotrace; lockdown must = none.
  - Card passthrough via hostdev. Card must be sole member of its IOMMU group.
  - SPICE + Xfce autologin user `dev`; OBS 29.1.3 (last PPA build for focal).
  - SSH key `~/.ssh/gc573-vm`; user `dev`, NOPASSWD sudo.
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
- Host kernel tests run on host w/ new driver only. Vendor drv tests VM only.

## Process
- Small commits. One concern each. Imperative subject ≤72 ch.
- Never commit: vendor material, credentials, raw unsanitized traces w/ PII, build artifacts.
- Hw facts uncertain → mark `UNVERIFIED` in spec + evidence needed. Don't guess regs.
- Ambiguity re hw behavior → trace it, don't infer.
