# PCI

| Item | Value | Ev | Conf |
|---|---|---|---|
| Vendor:Device | `1461:0054` | `E` lspci | C |
| Subsystem | `1461:5730` (GC573) | `E` | C |
| Class | `0400` multimedia video controller | `E` | C |
| BAR0 | 32-bit, non-prefetchable MMIO, 512 KiB. No other BARs, no I/O BARs | `E` | C |
| Capabilities | PM v3 @0x40 · MSI @0x48 · PCIe v2 endpoint @0x60 · DSN @0x100 (ext). No MSI-X, no AER, no VSEC | `E` lspci -vvv/-xxxx | C |
| MSI | 1 vector, 64-bit address, not per-vector maskable | `E` | C |
| INTx | pin A | `E` | C |
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
- Prefer MSI (single vector); fall back to INTx (shared).
- Use a 32-bit DMA mask until 64-bit is verified by experiment (see `open-questions.md`).
- A VM reboot (VFIO resets the device) does restore power-on values: the first probe after one read GPIO 0x0001f850 and RESET 0x00000001. Across driver reloads without it, the registers keep their last values (GPIO 0x0001f970/0x0001f974, RESET 0x00000309). (`tests/logs/20261124-215628_6.8.0-151-generic.log`, `T1`,`T2`,`T3`; C)
- There is no function-level reset: device state persists across driver unload/reload. The driver must quiesce the device on remove and must not assume power-on register state at probe (run the full init sequence every probe).
