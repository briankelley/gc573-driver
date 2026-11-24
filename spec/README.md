# GC573 hardware spec

Clean-room hardware description of the AVerMedia Live Gamer 4K (GC573). The driver in `src/` is written from these files only.

## Rules
- Facts only. No vendor source, no decompiler output, no vendor symbol names, no copied tables.
- Every fact carries evidence + confidence. Unknowns stay marked; never guessed.
- Offsets are byte offsets into BAR0 unless stated. All registers 32-bit, little-endian, unless stated.
- "RD" = reference driver (vendor-derived driver, run only inside a VM during research). RD behaviour is evidence of how the hardware is driven, not a requirement.

## Evidence tags
| Tag | Meaning |
|---|---|
| `T1/<scn>` | MMIO/I2C/IRQ trace, session 1 (RD in VM). Scenarios: `S01` load, `S01i` 30 s idle (no input), `S02` stream YUYV 1080p (no input), `S03` unload |
| `T2/<scn>` | trace session 2. `S10` load, `S11-<fmt>` stream 10 frames 1080p per pixel format (no input), `S12` 1280×720 (no input), `S13` audio capture 2 s (no input), `S14` unload |
| `S` | static analysis of reference binaries (behavioural conclusion only) |
| `P:<doc>` | public documentation (see References) |
| `D` | derived: arithmetic/standards applied to traced values |
| `E` | direct experiment on hardware |

Confidence: **C** confirmed (observed directly, or two independent evidence types agree) · **L** likely (one evidence type, consistent) · **U** unverified.

## Files
| File | Content |
|---|---|
| `pci.md` | PCI identity, config space, interrupts, reset |
| `regmap.md` | BAR0 map, every known register |
| `init.md` | bring-up and teardown sequences |
| `interrupts.md` | status/enable/ack |
| `i2c.md` | three I2C masters, device inventory |
| `video-dma.md` | descriptor format, channels, slots, start/stop |
| `video-pipeline.md` | input measurement, clip, colour, pixel formats, scalers, frame-rate limiter |
| `audio.md` | audio capture DMA |
| `open-questions.md` | unknowns, planned experiments |

## References
- `P:OC-I2C` — OpenCores "I2C-Master Core Specification" (Richard Herveille), i2c_master_top register map.
- `P:XV-HSC`, `P:XV-VSC` — Xilinx Video Processing Subsystem (PG231) and Xilinx `embeddedsw` drivers `v_hscaler` / `v_vscaler` (`xv_hscaler_hw.h`, `xv_vscaler_hw.h`): register map of the HLS horizontal/vertical scaler cores.
- `P:BT709`, `P:BT601`, `P:BT2020` — ITU-R colour matrices.
