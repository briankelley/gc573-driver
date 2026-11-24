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
- `tools/devvm/create.sh` — builds `gc573-dev` VM: Ubuntu 24.04 cloud img, kernel 6.8 GA + headers. dkms, sparse, v4l-utils (v4l2-ctl, v4l2-compliance), edid-decode, alsa-utils, trace-cmd, ffmpeg, python3-numpy, OBS (PPA latest), Xfce autologin. Same user/key as ref VM.
- `tools/devvm/debug-kernel.sh` — builds Ubuntu 6.8 source + kmemleak, lockdep, DEBUG_ATOMIC_SLEEP, KASAN, DMA_API_DEBUG on host; installs `6.8.12-gc573dbg` in `gc573-dev` as extra entry (default boot stays generic). Boot once: `sudo grub-reboot "$(cat /etc/gc573-dbg-entry)" && sudo reboot`. Leak/lock/DMA gates run on this kernel.
- checkpatch: `/lib/modules/$(uname -r)/build/scripts/checkpatch.pl --strict --no-tree -f <file>` (in `gc573-dev`).
- `tools/vmbuild.sh [load|unload|check|test [CASE..]]` — host side. rsyncs Makefile, Kbuild, dkms.conf, `src/`, `tests/` to `gc573-dev:~/gc573-driver` (env VM/VMDIR), clean `W=1` build against the VM's running kernel; any warning fails (one exempt: `6.8.12-gc573dbg` headers lack `ubuntu/include`). `load` (re)loads with INSMOD_ARGS and prints the probe's dmesg; `unload`; `check` = checkpatch --strict on `src/` + sparse `C=2`; `test` runs `tests/run.sh` as root in the VM, log → `tests/logs/<UTC>_<krel>.log` (commit it). Never loads on the host.
- Regression VM matrix: Ubuntu, Mint, RHEL-family; one VM per distro version, named `gc573-<distro><ver>`, built by scripts in `tools/`. Retain all: never delete or rebuild over an existing regression VM; add new versions alongside.
  - `tools/vms/create.sh <profile> [IP]` (cloud images; profiles in `tools/vms/profiles/`), `tools/vms/mint.sh <ver> [edition] [IP]` (ISO unattended install + virt-customize). Disks standalone (no shared backing). No persistent card.
  - `tools/vms/matrix-build.sh [-r REF] [-j N] [--load] [--dkms] [VM...]` builds REF (git archive) in each VM against every kernel with headers: W=1, any warning fails; `--load` = insmod/rmmod smoke test (no card: init/exit + symbols); `--dkms` = dkms add/build per kernel. Starts/stops VMs. Logs + `summary.tsv` → `tests/logs/matrix/<UTC>-<sha>/` (commit them). Default VMs: all but `gc573-ref`, `gc573-dev`. No tty: set `SUDO_ASKPASS` to a helper printing the sudo password.
  - `tools/vms/card.sh <vm>` moves the card between running VMs (live PCI unplug/plug; detach fails if the guest driver does not release it). `--where` shows the holder.
  - Current (VM: distro, kernel, IP): `gc573-ref` Ubuntu 20.04, 5.4, .39 (vendor drv only) · `gc573-dev` Ubuntu 24.04, 6.8.0 (+ debug 6.8.12), .40 · `gc573-alma9` AlmaLinux 9.9, 5.14, .41 · `gc573-alma10` AlmaLinux 10.3, 6.12, .42 · `gc573-fedora45` Fedora 45, 7.3, .43 · `gc573-ubuntu2604` Ubuntu 26.04, 7.0, .44 · `gc573-mint223` Mint 22.3, 6.14 HWE, .45. Host: Mint 22, 6.8.0. ssh aliases = VM names.
  - Gaps: EL10 has no v4l2-compliance package (build v4l-utils from source there). EL9 kernel lacks videobuf2-dma-sg/-dma-contig (see design constraints).
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
- M3 HDMI bring-up: splitter + IT6805 per `spec/hdmi-chips.md`, poll loop, DV timings, `V4L2_EVENT_SOURCE_CHANGE`. Gate: live 1080p59.94 capture, all formats, image verified.
- M4 audio: ALSA PCM capture. Gate: capture with live source, A/V sync in OBS.
- M5 EDID (`VIDIOC_G/S_EDID`), hotplug + mode-change stress, controls, scaling. Gate: test suite v1.
- M6 DKMS, host validation, OBS, 2 h soak. Gate: "Done" (see Project).
- Later: 2160p30, 2160p60 4:2:0 (open: black under RD), HDR.

## Tests
- `tests/` = regression suite. Every behavior change ships w/ test(s). Every bug fix ships w/ failing-before test.
- PR must include run log of full suite on real GC573 hw: pass/fail per case, kernel ver, card fw ver, input source + mode.
- Required gates per PR:
  - build: clean kbuild, zero warnings, W=1, on every matrix VM kernel (`tools/vms/matrix-build.sh --load --dkms`).
  - checkpatch --strict clean.
  - `v4l2-compliance -d <dev> -s` 0 fail.
  - load/unload x50, no leaks (kmemleak), no WARN/BUG in dmesg.
  - capture: each supported mode × fmt, frame cadence + checksum/pattern check where source allows.
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
