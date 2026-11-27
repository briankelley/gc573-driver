# PCI

| Item | Value | Ev | Conf |
|---|---|---|---|
| Vendor:Device | `1461:0054` | `E` lspci | C |
| Subsystem | `1461:5730` (GC573) | `E` | C |
| Class | `0400` multimedia video controller | `E` | C |
| BAR0 | 32-bit, non-prefetchable MMIO, 512 KiB. No other BARs, no I/O BARs | `E` | C |
| Capabilities | PM v3 @0x40 · MSI @0x48 · PCIe v2 endpoint @0x60 · DSN @0x100 (ext). No MSI-X, no AER, no VSEC | `E` lspci -vvv/-xxxx | C |
| MSI | 1 vector, 64-bit address, not per-vector maskable | `E` | C |
| INTx | pin A. Under VFIO it stormed and delivered nothing (open question 43) | `E` | C (pin); U (behaviour) |
| Link | Gen2 (5 GT/s) x4 | `E` | C |
| MPS / MRRS | MaxPayload cap 256; MRRS set 512 by host | `E` | C |
| DevCtl | relaxed ordering +, no-snoop + | `E` | C |
| FLR | not supported (`FLReset-`) | `E` | C |
| PM reset | `NoSoftRst+` → D3hot→D0 does not reset | `E` | C |
| Reset available | secondary bus reset only (kernel `reset_method` = `bus`) | `E` sysfs | C |
| DSN | `00-00-00-01-01-00-0a-35`; contains Xilinx OUI 00-0A-35 → Xilinx hard PCIe block | `E` | C |
| FPGA family | Gen2 x4 hard block fits Xilinx 7-series (Artix-7 likely). Exact part from board markings | `D` | U |
| DMA addressing | RD forces a 32-bit DMA mask. Descriptors carry a high address word (`video-dma.md`). 64-bit DMA not tested | `T1`, `S` | U |

## Driver notes
- Probe: `pcim_enable_device`, `pci_set_master`, map BAR0 (512 KiB).
- Use MSI (single vector). INTx is unverified. Under VFIO, a probe that fell back to it got none of its completions, and the line stormed in host and guest until the kernels disabled it (open question 43). Use INTx only when asked to.
- Use a 32-bit DMA mask until 64-bit is verified by experiment (see `open-questions.md`).
- A VM reboot (VFIO resets the device) does restore power-on values: the first probe after one read GPIO 0x0001f850 and RESET 0x00000001. Across driver reloads without it, the registers keep their last values (GPIO 0x0001f970/0x0001f974, RESET 0x00000309). (`tests/logs/20261124-215628_6.8.0-151-generic.log`, `T1`,`T2`,`T3`; C)
- There is no function-level reset: device state persists across driver unload/reload. The driver must quiesce the device on remove and must not assume power-on register state at probe (run the full init sequence every probe).
- **Never turn bus mastering off while the card's DMA may be running.** Twice a test did exactly that: a forced "unconfirmed stop" cleared PCI_COMMAND_MASTER in the middle of a free-running capture, and the driver's next probe turned mastering on again. The card sits behind an Alder Lake-S PCH root port, with the root port's completion timeout at 50 µs–50 ms.
  - 2026-11-27 03:01Z, in gc573-dev: from the first read after `pci_set_master()`, the card read all-ones for about 15 s (VERSION after 168 ms instead of µs), and one vCPU stalled 14.5 s. Then normal. (`tests/logs/20261127-025603_6.8.0-151-generic.log`, case 22.)
  - 04:15Z, the same test: the whole host hung. Nothing more was logged, USB (keyboard, KVM switch) stopped responding, and the reset button had no effect; it needed a power cycle. (`tests/logs/20261127-041434_6.8.0-151-generic.log` ends at case 22.)
  - On an idle card (VIP_CTRL out-enable and the audio DMA off), clearing mastering had no effect. That covers case 26's modes 3 and 4 in the 041434 log, and every unbind since M0, where the managed pci_disable_device clears it after the quiesce.
  - UNVERIFIED mechanism. The completion timeout bounds one read at 50 ms, so the stall is not a single unanswered read. A card that stops accepting TLPs (flow-control credits) would back up the PCH, which also carries USB and the reset path. The runs do not separate the mastering-off, its re-enable and the reads in between.
  - Consequences:
    - stop the DMA and confirm it before mastering goes off;
    - if the stop cannot be confirmed, leave mastering on and keep all memory the card can address until reboot;
    - a VM using the card must be shut down, not destroyed, while it streams (vfio-pci clears mastering at release).
  - A probe that finds mastering off cannot tell from the registers whether it was cut mid-DMA.
    - Before test 22's rebind turned mastering on, the card answered normally and showed no engine running: no "DMA running at probe" line. The stop had cleared OUT_EN itself before the cut.
    - A cleanly unbound card reads the same: GPIO 0x0001f970/0x0001f974, RESET 0x00000309, mastering off, OUT_EN and the audio DMA off.
    - Only RESET's sticky done bits (3, 8, 9) show whether a device reset has come since a driver last brought the card up (`init.md`): 0x00000001 after a VM's (VFIO) reset, 0x00000309 after any bring-up. The value at a host cold boot is not yet recorded.
    - So a driver should leave mastering on after a confirmed stop. It should turn mastering on over a card found with it off only when RESET shows such a reset. (`tests/logs/20261127-025603_6.8.0-151-generic.log` on the driver branch; delta and final reviews; C for the observation, L for the policy.)
