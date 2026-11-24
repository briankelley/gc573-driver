# Open questions and planned experiments

Ordered by impact on a first working driver. "Needs input" = requires an HDMI source on the card.

| # | Question | Plan | Needs input |
|---|---|---|---|
| 2 | HDMI chip init + mode-change sequences (IT6805, splitter 0x6663) | traces captured (`T3/S20` load with input, `S30` replug, `S31` 2160p→1080p); extract → `hdmi-chips.md` | done (capture) |
| 14 | **2160p60 YUV 4:2:0 input → exact-black frames under RD** (COLOR_CTRL[19]+[5], PIX_MODE=1). HDCP, AV mute, lock, depth ruled out; reproduced with a PC source without HDCP; 2160p30 RGB (dual DDR) works; FPGA input detector identical for both (`video-pipeline.md`, `T4`) | during 4:2:0 streaming vary PIX_MODE {0,1,3}, COLOR_CTRL[19], clip width 1920 vs 3840; compare IT6805 4:2:0 output settings | yes (PC loopback) |
| 19 | EDID seen by the source: composed by the splitter from its outputs and the IT6805. Which EDID makes the source pick a mode we can capture? | decode RD's EDID writes (`T1/S01`); design our own EDID; verify the source's chosen mode | yes |
| 5 | Audio PCM layout, channel order, multichannel | capture a known tone; vary rates if source allows | yes |
| 6 | INT bits 2, 3, 8, 9, 31 meanings | provoke: DMA underrun (no buffers queued), stop/start races; log status | no |
| 7 | CH0 STATUS (0x300) upper bits | log per frame with/without input, different sizes | partly |
| 8 | ch1/ch2 CH_CTRL slot semantics (write-only) | driver experiment: arm ch1 slot only vs ch0 only; observe completion and data | no |
| 9 | 64-bit DMA | allocate buffers above 4 GiB (VM with >4 GiB RAM, high mapping), stream, verify | no |
| 10 | GPIO roles: bit1, bit5 vs bit8 (which chip), bit2 HPD polarity, bits 11–16 | toggle individually with no stream; watch I2C ID reads fail/succeed, source behaviour, LEDs | partly |
| 11 | Front LEDs (stay red under RD) | GPIO bits 11–16 experiments; scan I2C bus 0 and bus 2 for devices | no |
| 12 | Devices on I2C bus 0 / bus 2 (auth chip expected on one) | address scan with OpenCores master (read-only probe) | no |
| 13 | Reset domain contents (0x00c bits 0/8/9), 0x00c bit 3 | reset one at a time; observe which blocks return to defaults | no |
| 15 | HDCP state source | IT6805/splitter registers during protected content | yes |
| 16 | Descriptor limits: max COUNT, min address alignment, ctrl bits | driver experiment with crafted lists | no |
| 17 | TLP_ALIGN (0x004) need | sizes whose dword count is not a multiple of 32; check corruption with/without | no |
| 18 | FPGA part / firmware variants | board markings photo; VERSION register on other cards | — |
| 21 | GPIO bit 10 (input): interrupt output of the splitter or the IT6805? Samples fit "high while chip events are pending" (`regmap.md`). If yes, that chip needs I2C polling only when the bit is set | our driver: sample 0x040 at every poll together with splitter 0x58 reg 0x05 and the IT6805 event registers, while hot-plugging and changing modes | yes |
| 20 | Input pixel clock: RD's estimate reads ~13 % low (129 MHz at 1080p60, 257 MHz at 2160p60 4:2:0) | find the IT6805 clock-measurement registers and reference clock; cross-check with FPGA IN_FRAME_PERIOD | yes |
| 22 | Missing I2C completions, all on IT6805 reg 0x0f (`i2c.md`): engine or chip? Did the timed-out transfer reach the chip? | our driver: count timeouts per device and register; on timeout read STATUS and the bank register before retrying | no |
| 23 | TX port 1 HPD fall latency after GPIO bit 2 goes low (masked by a splitter TX reset in every trace) | our driver: drop bit 2 while the splitter TX is idle; read TX port 1 status every 5 ms | yes |
| 24 | Input types never traced: RGB or full-range input, deep colour, interlaced (1080i, 480i/576i), native 720p, negative sync polarity, mode change while streaming, load with no source then plug-in | M3/M5 test suite with a PC source and the Roku | yes |
| 25 | Encrypting source without the external HDCP stripper: splitter RX and IT6805 behaviour | M5: Roku direct; the driver must report no signal, not hang | yes |
| 26 | Bus-1 engine on NACK or absent device: STATUS value, INT behaviour; does reading STATUS have side effects? | read IT6805 reg 0x4b; if bit 0 is clear (EDID RAM slave off), read 0xa8 reg 0x00, where nothing answers, and record STATUS and INT | no |
| 28 | Card frame store: size, which frames are held, can it be cleared; how many frames after a start can carry stale content (`video-dma.md`) | with the loopback: capture pattern A, stop, show pattern B, start; check the first frames | yes (PC loopback) |
| 29 | RGB input → BGR24: +1 on one pixel in four (`video-pipeline.md`). Which stage adds it? | with our driver and the loopback: toggle the splitter, IT6805 and FPGA colour settings one at a time | yes (PC loopback) |
| 27 | RESET (0x00c): what clears bits 0/3/8/9 besides a device reset; what bit 3 means; can a later domain reset be confirmed at all? | after a VM reboot, write the domains one at a time and read RESET plus the DMA/VIP registers each domain covers | no |

## Resolved
| # | Question | Answer | Ev |
|---|---|---|---|
| 1 | HW writes pixel data on all channels? | yes: ch0, ch1, ch2 carry real image data | `T3/S32-NV12`,`S32-YV12` |
| 3 | Real scaling | 1920×1080 → 1280×720 clean; programming values in `video-pipeline.md` | `T3/S33` |
| 4 | YV12 chroma order; RGB byte order | YV12 ch1 = Cr, ch2 = Cb. Code 0x02 = B,G,R. Code 0x06 = B,G,R,X (X = 0) → V4L2 XBGR32 | `T3/S32-*` |

Status: traces cover load, idle, no-input streaming in all formats, audio start/stop, unload (`T1`, `T2`); live 1080p59.94 and 2160p59.94 4:2:0 input, all formats, scaling, audio, replug, mode change (`T3`).
