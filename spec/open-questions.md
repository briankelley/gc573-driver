# Open questions and planned experiments

Ordered by impact on a first working driver. "Needs input" = requires an HDMI source on the card.

| # | Question | Plan | Needs input |
|---|---|---|---|
| 1 | Does HW write pixel data on every channel (incl. ch1/ch2)? | Our driver: pre-fill buffers with a pattern, stream with no input, diff | no |
| 2 | HDMI chip init + mode-change sequences (IT6805, splitter 0x6663) | trace RD: hotplug, lock 1080p60, 720p60, 2160p30/60, HDR, unplug; extract register tables → `hdmi-chips.md` | yes |
| 3 | Real scaling (in ≠ out) | trace RD: 1080p input → 1280×720 output; validate H/V scaler programming against `P:XV-*` | yes |
| 4 | YV12 chroma order on ch1/ch2; BGR24/XRGB32 byte order | capture known colour bars from a source | yes |
| 5 | Audio PCM layout, channel order, rate detection | capture known tone; vary rates if source allows | yes |
| 6 | INT bits 2, 3, 8, 9, 31 meanings | provoke: DMA underrun (no buffers queued), stop/start races; log status | no |
| 7 | CH0 STATUS (0x300) upper bits | log per frame with/without input, different sizes | partly |
| 8 | ch1/ch2 CH_CTRL slot semantics (write-only) | driver experiment: arm ch1 slot only vs ch0 only; observe completion and data | no |
| 9 | 64-bit DMA | allocate buffers above 4 GiB (VM with >4 GiB RAM, high mapping), stream, verify | no |
| 10 | GPIO roles: bit1, bit5 vs bit8 (which chip), bit2 HPD polarity, bits 11–16 | toggle individually with no stream; watch I2C ID reads fail/succeed, source behaviour, LEDs | partly |
| 11 | Front LEDs (stay red under RD) | GPIO bits 11–16 experiments; scan I2C bus 0 and bus 2 for devices | no |
| 12 | Devices on I2C bus 0 / bus 2 (auth chip expected on one) | address scan with OpenCores master (read-only probe) | no |
| 13 | Reset domain contents (0x00c bits 0/8/9), 0x00c bit 3 | reset one at a time; observe which blocks return to defaults | no |
| 14 | Dual-pixel threshold, COLOR_CTRL[19] (4:2:0) | trace RD with 4K60 4:2:0 source | yes (4K source) |
| 15 | HDCP state source | IT6805 registers during protected content (behind HDCP filter: expect "not encrypted") | yes |
| 16 | Descriptor limits: max COUNT, min address alignment, ctrl bits | driver experiment with crafted lists | no |
| 17 | TLP_ALIGN (0x004) need | sizes whose dword count is not a multiple of 32; check corruption with/without | no |
| 18 | FPGA part / firmware variants | board markings photo; VERSION register on other cards | — |

Status: traces so far cover load, idle, no-input streaming in all formats, audio start/stop, unload (`T1`, `T2`).
