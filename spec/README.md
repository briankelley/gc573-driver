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
| `T3/<scn>` | trace session 3, **live source** (Roku Ultra → HDCP splitter → GC573). `S20` load with 2160p59.94 YUV 4:2:0 input · `S21/S22/S23` 4K YUYV/NV12/YV12 · `S24–S26` 4K→1080p scaled YUYV/BGR24/XBGR32 · `S27` audio · `S30` cable unplug/replug · `S31` source switched 2160p→1080p · `S32-<fmt>` native 1080p59.94 all formats · `S33` 1080p→720p scaled · `S34` audio · `S36` unload. Frames checked visually |
| `T4/<scn>` | trace session 4, **PC loopback** (host GT 710 DVI-D → DVI-to-HDMI cable → GC573 HDMI IN; RD's EDID). `S40` load (GPU picks 2160p60 4:2:0) · `S41` 2160p60 4:2:0 YUYV · `S42` 1080p60 full-range RGB BGR24, GPU dithering on · `S43` same, dithering off · `S44` 2160p29.97 full-range RGB YUYV · `S45` 2160p60 then 2160p29.97, not streaming (FPGA input-detector values read from userspace at these MARKs: evidence `E`, not in the file) · `S46` unload. No init: I2C events of the first 2.35 s after the S40 MARK are missing. Frames compared with a known pattern (`tools/testsrc/`) |
| `S` | static analysis of reference binaries (behavioural conclusion only) |
| `P:<doc>` | public documentation (see References) |
| `D` | derived: arithmetic/standards applied to traced values |
| `E` | direct experiment on hardware |

Trace times in the spec (e.g. `T3/S30` 22055.1 ms) are ms after the first `I2C` line that follows the scenario's MARK in `traces/T<n>.tsv.xz`. Public-trace time = quoted time + that line's time: `T1/S01` +380.1 ms, `T2/S10` +380.1, `T3/S20` +358.8, `T3/S30` +279342.6, `T3/S31` +327422.6, `T4/S40` +2348.1, `T4/S41` +33545.8, `T4/S42` +150510.9, `T4/S43` +197088.1, `T4/S44` +294541.7, `T4/S45` +352357.6, `T4/S46` +391362.4. Durations need no conversion.

Confidence: **C** confirmed (observed directly, or two independent evidence types agree) · **L** likely (one evidence type, consistent) · **U** unverified.

## Files
| File | Content |
|---|---|
| `pci.md` | PCI identity, config space, interrupts, reset |
| `regmap.md` | BAR0 map, every known register |
| `init.md` | bring-up and teardown sequences |
| `interrupts.md` | status/enable/ack |
| `i2c.md` | three I2C masters, device inventory |
| `hdmi-chips.md` | HDMI front-end overview: topology, sub-devices, GPIO lines, bring-up order, lock timing, FPGA hand-off, EDID policy, cross-chip rules |
| `hdmi-it6805.md` | IT6805 HDMI receiver: registers, init, EDID RAM, power modes, polling, state machine, output bus, audio, 1080p60 recipe |
| `hdmi-splitter.md` | HDMI splitter (ITE 0x6663): sub-devices, init, scheduling, RX (source HPD, EDID RAM, EQ), TX ports (power, AFE, output enable, DDC master), EDID copy path, observed event sequences, 1080p60 polling driver |
| `seq/*.tsv` | machine-readable register sequences for the HDMI chips (format in each file's header) |
| `video-dma.md` | descriptor format, channels, slots, start/stop |
| `video-pipeline.md` | input measurement, clip, colour, pixel formats, scalers, frame-rate limiter |
| `audio.md` | audio capture DMA |
| `open-questions.md` | unknowns, planned experiments |

## References
- `P:OC-I2C` — OpenCores "I2C-Master Core Specification" (Richard Herveille), i2c_master_top register map.
- `P:XV-HSC`, `P:XV-VSC` — Xilinx Video Processing Subsystem (PG231) and Xilinx `embeddedsw` drivers `v_hscaler` / `v_vscaler` (`xv_hscaler_hw.h`, `xv_vscaler_hw.h`): register map of the HLS horizontal/vertical scaler cores.
- `P:BT709`, `P:BT601`, `P:BT2020` — ITU-R colour matrices.
