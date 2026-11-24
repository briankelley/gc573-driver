# BAR0 register map

Blocks: `0x00000` core/IRQ/GPIO/I2C · `0x00200` audio DMA · `0x00300`/`0x00500`/`0x00600` video DMA ch0/ch1/ch2 · `0x01000` video input processing (VIP) · `0x40000` H scaler · `0x50000` scaler reset · `0x60000` V scaler.
Unlisted offsets: unknown. Do not touch.

## Core (0x00000)

| Off | Name (ours) | Acc | Fields | Ev | Conf |
|---|---|---|---|---|---|
| 0x000 | VERSION | RO | FPGA build date, BCD `YYYYMMDD`. Read: `0x20200811` | `T1/S01` | C |
| 0x004 | TLP_ALIGN | RW | [1:0] alignment mode chosen from frame size in dwords (`w*h*2/4` for 16-bpp): 0 if multiple of 32 dwords, 1 if multiple of 16 only, 2 if multiple of 8 only. Other bits preserve | `S` | L |
| 0x008 | DMA_RUN | RW | [1] audio DMA run. Write 0 stops audio (raises INT bit 4). Other bits unknown, RD writes 0 | `T1/S01i`,`T2/S13`,`S` | C |
| 0x00c | RESET | RW | Three reset domains: bits 0, 8, 9. Write the single bit → domain resets; bit reads back 1 when done. Reads after full sequence: `0x009`→`0x109`→`0x309` (bit 3 also set after bit 0). See `init.md` | `T1/S01`,`S` | C (domain contents U) |
| 0x010 | INT_STATUS | RW1C | see `interrupts.md` | `T1`,`T2`,`S` | C |
| 0x014 | AUDIO_DONE | RO | [1:0] which audio buffer completed: 1 = buffer 0, 2 = buffer 1 | `T1/S01i`,`T2/S13` | C |
| 0x01c | INT_ENABLE | RW | enable mask; RD value `0xb33` | `T1/S01`,`S` | C |
| 0x040 | GPIO | RW | see GPIO below | `T1/S01`,`S` | C (bit roles partly U) |

### GPIO (0x040)
Reset value read at first probe: `0x0001f850`.

| Bit | Role | Ev | Conf |
|---|---|---|---|
| 1 | cleared during init (purpose unknown) | `S`,`T1` | U |
| 2 | HPD input of splitter TX port 1 (the IT6805-side hot-plug line), 1 = high. RD pulse to force re-detect: 1, 10 ms, 0, 100 ms, 1. RD clears it when the IT6805 loses 5 V and sets it when 5 V returns (before video lock). Evidence and latency: `hdmi-chips.md` | `S`,`T3/S30`,`S31` | C |
| 4 | enable; set during init, poll until it reads back 1 (≤ 21 × 5 ms) | `S`,`T1` | L |
| 6 | enable; same handling as bit 4 | `S`,`T1` | L |
| 5 | active-low reset of an on-board chip (pulse 1→0 10 ms→1) | `S`,`T1` | L (which chip U) |
| 8 | active-low reset of an on-board chip (pulse 1→0 2 ms→1) | `S`,`T1` | L (which chip U) |
| 10 | **input** (changes with no write; sampled only during RD's read-modify-writes). `T3` (source present): 1 at load, 0 after bit 5 went low, 1 after chip init; 1 when RD handled the IT6805's 5 V loss (before the splitter task ran), 0 when 5 V returned. `T1`/`T2` (no source): 0 in every sample except one (1 at 612 ms after load in `T2`, 0 again 19 ms later). Fits a level output that is high while chip events are pending. Candidates: the splitter's interrupt output (its events were unserviced at every 1-sample), or the IT6805's (bit 10 dropped while the bit-5 reset was low). Open question 21 | `T1`,`T2`,`T3/S20`,`S30`,`S31` | U |
| 11–16 | set at power-up, never written by RD | `T1` | U |

Write via read-modify-write. Bit roles not listed: preserve.

## I2C (0x100–0x1a4)
| Off | Block | Ev | Conf |
|---|---|---|---|
| 0x100–0x110 | I2C bus 2, OpenCores-compatible byte master (`i2c.md`) | `S`,`P:OC-I2C`,`T1/S01` | C |
| 0x120–0x130 | I2C bus 0, OpenCores-compatible byte master | `S`,`P:OC-I2C`,`T1/S01` | C |
| 0x180–0x1a4 | I2C bus 1 transaction engine (all HDMI-chip traffic) | `T1`,`S` | C |

Field-level detail in `i2c.md`.

## Audio DMA (0x200)
| Off | Name | Acc | Fields | Ev | Conf |
|---|---|---|---|---|---|
| 0x200 | AUD_CFG0 | W | RD writes 0 before start | `T1`,`T2/S13` | U |
| 0x204 | AUD_PERIOD_A | W | period length in dwords | `T2/S13`,`S` | C |
| 0x208 | AUD_BUF0_LO | W | buffer 0 bus address [31:0] | `T2/S13` | C |
| 0x20c | AUD_BUF0_HI | W | buffer 0 bus address [63:32] | `T2/S13` | C |
| 0x210 | AUD_BUF1_LO | W | buffer 1 bus address [31:0] | `T2/S13` | C |
| 0x214 | AUD_BUF1_HI | W | buffer 1 bus address [63:32] | `T2/S13` | C |
| 0x218 | AUD_CFG1 | W | RD writes 0 | `T2/S13` | U |
| 0x21c | AUD_PERIOD_B | W | period length in dwords; RD writes same value as 0x204 | `T2/S13`,`S` | C (why two: U) |
| 0x2b4–0x2c0 | AUD_SLOT0..3 | W | RD writes 0,1,2,3 (channel/slot mapping) | `T2/S13` | U |

## Video DMA channels (0x300 / 0x500 / 0x600)
`base` = 0x300 (ch0), 0x500 (ch1), 0x600 (ch2). One channel per plane.

| Off | Name | Acc | Fields | Ev | Conf |
|---|---|---|---|---|---|
| base+0x0 | CH_STATUS | RO | ch0: [2:0] = (completed slot index + 1), valid 1..4; upper bits unknown (vary per frame). ch1/ch2: not observed | `T1/S02`,`T2/S11`,`S` | C ([2:0]) |
| base+0x4 | CH_CTRL | RW (ch0) / WO (ch1, ch2) | [0] run, [4:1] slot n valid (bit n+1). HW clears a slot bit when that slot's list completes. ch1/ch2 read back `0xeeeeeeee`: keep a software shadow, never read-modify-write | `T1/S02`,`T2/S11-NV12`,`T2/S11-YV12`,`S` | C |
| base+0x8+12n | SLOTn_LIST_LO | W | list bus address [31:0], n = 0..3 | `T1/S02`,`T2/S11` | C |
| base+0xc+12n | SLOTn_LIST_HI | W | list bus address [63:32] | same | C |
| base+0x10+12n | SLOTn_COUNT | W | number of descriptors in the list | same | C |

Descriptor format and protocol: `video-dma.md`.

## Video input processing (0x01000)
| Off | Name | Acc | Fields | Ev | Conf |
|---|---|---|---|---|---|
| 0x1000 | VIP_CTRL | RW | [0] output enable (gates frames into DMA) · [3:2] flip (always 0) · [6] cleared when enabling output · [7] 1 = scaler in path, 0 = bypass · [15:8] output pixel format code (`video-pipeline.md`) · [23:16] sharpness | `T2/S11`,`S` | C ([0],[7],[15:8]); L (rest) |
| 0x1004 | IN_STATUS | RO | [1:0] input timing stable: 3 with a stable input (1080p60, 2160p60 4:2:0, 2160p29.97), also while not streaming. No-input value not yet read | `S`,`T4/S45` | C |
| 0x1008 | IN_WIDTH | RO | [15:0] bus clocks per active line, not pixels: 0x780 (1920) at single-pixel 1080p60; 0x3c0 (960) at dual-pixel 2160p, both 4:2:0 SDR (60 Hz) and RGB DDR (29.97 Hz). Read while not streaming (PIX_MODE 0) | `S`,`T4/S45` | C |
| 0x100c | IN_HEIGHT | RO | [15:0] detected active lines (0x438 at 1080p, 0x870 at 2160p); [31:16] second measurement (field), 0 for progressive input | `S`,`T4/S45` | C |
| 0x1010 | IN_FRAME_PERIOD | RO | input frame period in 100 MHz ticks; fps = 1e8/val. `0xffffffff` with no input | `T1/S02`,`S` | C |
| 0x1020 | CLIP_LEFT | RW | | `T1/S02`,`S` | C |
| 0x1024 | CLIP_WIDTH | RW | | same | C |
| 0x1028 | CLIP_TOP | RW | | same | C |
| 0x102c | CLIP_HEIGHT | RW | progressive: height. RD interlaced: `(h/2)<<16 \| (h/2)` | same | C (interlaced U) |
| 0x1040 | COLOR_CTRL | RW | [0] input is YUV 4:2:2 (0 = 4:4:4/RGB) · [1] RGB→YUV CSC enable · [2] colour adjust (BCHS) enable · [3] YUV→RGB CSC enable · [5] dual-pixel (2 pixels/clock, 4K) · [10:8] RGB→YUV table index · [14:12] YUV→RGB table index · [19] input colour mode 3 (likely YUV 4:2:0) | `T2/S11`,`S` | C ([1],[2],[3]); L (rest) |
| 0x105c | CONTRAST | RW | default 0x100 | `T1/S02`,`S` | C |
| 0x1060 | BRIGHTNESS | RW | default 0x200 | same | C |
| 0x1064 | HUE | RW | default 0 | same | C |
| 0x1068 | SATURATION | RW | default 0x80 | same | C |
| 0x107c | DDR_STATUS | RW | [0] on-board DDR ready. Recovery write sequence: 8, then 1, wait 2 s, re-check. Read at init: `0x3` | `T1/S01`,`S` | L |
| 0x1080 | RATE_CTRL | RW | [31:16] output frame-rate limit in fps (RD clamps 5..60; 5 with no input) · [2:1] CSC range/table select (YUV out `0b01`, RGB out `0b11` in bits [2:1]) · [3] set at reset, preserve | `T1/S02`,`T2/S11`,`S` | L |
| 0x1088 | PIX_MODE | RW | [0] dual-pixel input bus · [1] DDR input bus (see `video-pipeline.md`) | `S`,`T1`,`T3` | L |
| 0x10a0 | AUDIO_SAMPLE_PERIOD | RO | audio sample period in 100 MHz ticks; fs = 1e8/val. `0xffffffff` with no input | `T1`,`T2/S13`,`S` | C |
| 0x10c0–0x10d8 | CSC_RGB2YUV | RW | 7 words, format in `video-pipeline.md` | `T1/S02`,`D` | C |
| 0x10e0–0x10f8 | CSC_YUV2RGB | RW | 7 words | same | C |

## Scalers
| Off | Block | Ev | Conf |
|---|---|---|---|
| 0x40000 | Horizontal scaler, Xilinx HLS `v_hscaler` register layout: +0x00 AP_CTRL ([0] start, [2] idle, [7] auto-restart) · +0x10 height · +0x18 width in · +0x20 width out · +0x28 colour mode · +0x30 pixel rate (16.16, 1.0 = 0x10000) · +0x800–0xafc filter coefficients (192 words) · +0x2000–0x3ffc phase table (2048 words) | `T1/S02`,`P:XV-HSC` | C |
| 0x50000 | SCALER_RESET | [1:0] scaler cores run (1) / reset (0). RD: write 0, 5 ms, write 3, 5 ms before configuring scalers; 3 at init | `T1`,`S` | L (bit→core U) |
| 0x60000 | Vertical scaler, Xilinx HLS `v_vscaler` layout: +0x00 AP_CTRL · +0x10 height in · +0x18 width · +0x20 height out · +0x28 line rate (16.16) · +0x800–0xafc coefficients (192 words) | `T1/S02`,`P:XV-VSC` | C |
