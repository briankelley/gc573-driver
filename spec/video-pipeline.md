# Video pipeline (FPGA)

Flow (order of stages inferred from enable bits; exact internal order partly U):
HDMI RX (IT6805, parallel bus) → input measurement → clip → YUV→RGB CSC → colour adjust → scalers (RGB) → RGB→YUV CSC (YUV outputs only) → frame-rate limiter → pixel packer (format code) → DMA ch0..2.

## Input measurement
| Reg | Meaning | Ev | Conf |
|---|---|---|---|
| 0x1004[1:0] | timing stable | `S` | L |
| 0x1008[15:0] | active width | `S` | L |
| 0x100c[15:0] / [31:16] | active height / second measurement (field). RD treats heights 240, 288, 540 as interlaced | `S` | L |
| 0x1010 | frame period, 100 MHz ticks. fps = 1e8 / value. `0xffffffff` = no input | `T1/S02`,`S` | C |

## Clip
CLIP_LEFT 0x1020, CLIP_WIDTH 0x1024, CLIP_TOP 0x1028, CLIP_HEIGHT 0x102c. RD sets (0, 0, in_w, in_h) and waits 50 ms after writing. (`T1/S02`,`S`; C)

## Pixel format code (VIP_CTRL 0x1000[15:8])
Determined by streaming each format and reading the programmed value. (`T2/S11-*`; C)

| V4L2 format | Code | Memory layout (verified with live source, `T3/S32`) | Planes / channels | COLOR_CTRL 0x1040 (stream) | RATE_CTRL 0x1080[2:1] |
|---|---|---|---|---|---|
| YUYV | 0x00 | Y0 Cb Y1 Cr | 1 / ch0 | 0xe | 0b01 |
| UYVY | 0x09 | Cb Y0 Cr Y1 | 1 / ch0 | 0xe | 0b01 |
| BGR24 (`BGR3`) | 0x02 | B G R | 1 / ch0 | 0xc | 0b11 |
| **XBGR32 (`XR24`)** | 0x06 | B G R X | 1 / ch0 | 0xc | 0b11 |
| NV12 | 0x0f | Y plane; CbCr interleaved (Cb first) | 2 / ch0, ch1 | 0xe | 0b01 |
| YV12 (`YVU420`) | 0x10 | Y; Cr plane; Cb plane | 3 / ch0, ch1 (Cr), ch2 (Cb) | 0xe | 0b01 |

- Code 0x06 writes B,G,R,X per pixel = V4L2 `XBGR32` ('XR24'). RD advertises it as `RGB32` ('RGB4', defined as X,R,G,B in memory): wrong label, wrong colours in applications. Advertise 'XR24'. (`T3/S32-1080-RGB4`; C)
- All six formats produce correct images at 1080p59.94 from a live source. (`T3/S32-*`; C)
- Other codes exist in the hardware (RD's code table is sparse); untested codes: do not use.

## COLOR_CTRL (0x1040)
| Bit | Meaning | Ev | Conf |
|---|---|---|---|
| 0 | input sampling 4:2:2. RD sets it only for 4:2:2 input (0 for RGB, 4:4:4, 4:2:0) | `S`,`T3/S32` | L |
| 1 | RGB→YUV CSC enable (set for YUV outputs) | `T2/S11` | C |
| 2 | colour adjust (brightness/contrast/hue/saturation) enable | `T2/S11`,`S` | C |
| 3 | YUV→RGB CSC enable | `T2/S11` | C |
| 5 | dual-pixel input bus (2 pixels per clock). RD copies the IT6805 output-bus decision (`hdmi-chips.md`) | `S`,`T3/S21` | C |
| 10:8 | RGB→YUV table index (RD writes 0 with BT.709 coefficients) | `S`,`T2` | U (whether HW uses it) |
| 14:12 | YUV→RGB table index (RD writes 0) | same | U |
| 19 | input sampling 4:2:0. RD sets it for 4:2:0 input (with bit0 = 0) | `S`,`T3/S21` | L |

## CSC coefficient banks
RGB→YUV: 0x10c0–0x10d8. YUV→RGB: 0x10e0–0x10f8. 7 words each. (`T1/S02`,`D`; C)

Format (derived from traced values against ITU-R BT.709):
- 12 entries, row-major: row r ∈ {0,1,2}, entries `c0, c1, c2, offset`.
- Component order for both rows and columns: 0 = G / Y, 1 = B / Cb, 2 = R / Cr.
  - RGB→YUV: rows Y, Cb, Cr; columns G, B, R.
  - YUV→RGB: rows G, B, R; columns Y, Cb, Cr.
- Coefficient: unsigned magnitude, Q2.14 (1.0 = 0x4000, max < 4.0).
- Offset: unsigned magnitude of the offset in 8-bit code values × 16 (e.g. 16 → 0x100, 128 → 0x800).
- Signs: word 0 bits [11:0], bit i = 1 → entry i is negative.
- Packing: word 0 = sign mask; word k (k = 1..6) = entry[2k−2] | entry[2k−1] << 16.
- CSC enables for YUV input → YUV output: RD's choice depends on an uninitialised value; every traced run had both CSCs on (YUV→RGB→YUV, BT.709 both ways) and produced correct images. The both-off YUV path is untested: use both-on. (`S`,`T2`,`T3`; C for both-on)
- Output-side meaning of offset: YUV→RGB offsets are the constant term after folding the input offsets (e.g. G = 1.164·Y − 0.213·Cb − 0.533·Cr + 76.88).

Worked example (`D`; matches traced values within ±1 LSB):

BT.709 limited RGB→YUV — mask 0x350:
| row | c0 (G) | c1 (B) | c2 (R) | offset |
|---|---|---|---|---|
| Y | 0.61423 → 0x2750 | 0.06201 → 0x03f8 | 0.18259 → 0x0baf | +16 → 0x0100 |
| Cb | −0.33857 → 0x15ab | +0.43922 → 0x1c1c | −0.10064 → 0x0671 | +128 → 0x0800 |
| Cr | −0.39894 → 0x1988 | −0.04027 → 0x0294 | +0.43922 → 0x1c1c | +128 → 0x0800 |

BT.709 limited YUV→RGB — mask 0x886:
| row | c0 (Y) | c1 (Cb) | c2 (Cr) | offset |
|---|---|---|---|---|
| G | 1.16438 → 0x4a85 | −0.21325 → 0x0da6 | −0.53291 → 0x221b | +76.88 → 0x04ce |
| B | 1.16438 → 0x4a85 | +2.11240 → 0x8732 | 0 | −289.02 → 0x1210 |
| R | 1.16438 → 0x4a85 | 0 | +1.79274 → 0x72bc | −248.10 → 0x0f82 |

Values above: round-to-nearest from the standard. RD-written values differ by ≤ 1 LSB in places (RD rounding differs); either works.
Compute other standards (BT.601, BT.2020; full/limited range) with the same format.

## Colour adjust
CONTRAST 0x105c (default 0x100), BRIGHTNESS 0x1060 (default 0x200), HUE 0x1064 (default 0), SATURATION 0x1068 (default 0x80). Effective only with COLOR_CTRL[2] = 1. RD's V4L2 ranges: brightness 0–1023, contrast 0–511, saturation 0–511, hue 0–360 (unit and wrap U). Sharpness: VIP_CTRL[23:16]. (`T1/S02`,`S`; L)

## Scalers
Xilinx HLS cores; layouts and programming per `P:XV-HSC` / `P:XV-VSC` (public driver code computes coefficients and phases). (`T1/S02`; C for layout)
Sequence used by RD before every stream start:
1. SCALER_RESET (0x50000) = 0; 5 ms; = 3; 5 ms.
2. V scaler: coefficients (+0x800, 192 words) → HEIGHT_IN (+0x10) → WIDTH (+0x18) → HEIGHT_OUT (+0x20) → LINE_RATE (+0x28) = in_h × 65536 / out_h.
3. H scaler: coefficients (+0x800, 192 words) → phases (+0x2000, 2048 words) → HEIGHT (+0x10, = out_h) → WIDTH_IN (+0x18) → WIDTH_OUT (+0x20) → COLOR_MODE (+0x28) = 0 → PIXEL_RATE (+0x30) = in_w × 65536 / out_w.
4. Start each: AP_CTRL = 0x80 (auto-restart), then 0x81 (start). V before H.
5. VIP_CTRL[7] = 1 if scaling (in ≠ out), 0 to bypass.
Observed AP_CTRL read before start: 0x84 (idle). Colour mode 0 = RGB in Xilinx numbering → scalers run on RGB data. (`T1/S02`,`P:XV-*`; L)
With no input, RD sets in = out (scaler bypassed). (`T2/S12`; C)
Live downscale 1920×1080 → 1280×720 (`T3/S33`; C, image clean): V: HEIGHT_IN 0x438, WIDTH 0x780, HEIGHT_OUT 0x2d0, LINE_RATE 0x18000 · H: HEIGHT 0x2d0, WIDTH_IN 0x780, WIDTH_OUT 0x500, COLOR_MODE 0, PIXEL_RATE 0x18000 · VIP_CTRL 0x80 → 0x81.

## Observed configurations with live input (`T3`)
| Input | IN_FRAME_PERIOD 0x1010 | COLOR_CTRL 0x1040 (YUYV out) | PIX_MODE 0x1088 | Result |
|---|---|---|---|---|
| none | 0xffffffff | 0x0000000e | 0x2 | free-running 60 Hz, black (RD draws image) |
| 1080p59.94 | 0x0019745b (59.94 Hz) | 0x0000000e | 0x0 | correct images, all formats |
| 2160p59.94 YUV 4:2:0 (AVI: VIC 97, BT.709, limited; no HDR packet) | 0x0019745b | 0x0008002e (bit19 4:2:0, bit5 dual-pixel) | 0x1 (dual, SDR) | **all frames black** (Y=16, C=128; RGB 0) at native and downscaled sizes |

- 2160p60 4:2:0 capture is not working with RD's configuration. Ruled out: HDCP (no encryption at any chip), AV mute, signal lock (IT6805 locked with coherent timing), colour depth (8-bit, unscrambled). Black is exact YUV black (an all-zero bus would give green in RGB formats). Leading candidate: the FPGA 4:2:0 dual-pixel SDR input path as RD configures it (clip 3840 wide while the bus carries 1920 TMDS slots per line). Second: genuinely black upstream picture. Open: `open-questions.md` #14. Target 1080p first. (`S`,`T3`; L)
- RD sets the frame-rate limiter from a wrong pixel-clock-based estimate (52 fps for 59.94 Hz input); frames still arrive. Use IN_FRAME_PERIOD for the true rate. (`T3/S20`,`S32`; C)

## Frame-rate limiter
RATE_CTRL (0x1080)[31:16] = output frame rate in fps; RD clamps 5..60 and writes 5 with no input (`T1/S02`,`S`; L). It did not limit delivery in any trace: 52 programmed → ~59.94 frames/s delivered; 5 programmed (no input) → 60/s (`T3`; C). Effect unverified.
RATE_CTRL[1] = input is YUV; [2] = output is RGB; [3] not written by RD (preserve) (`S`,`T2`; L).
Frame rate source: IN_FRAME_PERIOD (0x1010), not the IT6805 clock estimate (RD's estimate reads ~13 % low because it assumes a 20.5 MHz reference) (`S`,`T3`; C).

## Pixel mode
PIX_MODE (0x1088) = dual | (DDR << 1), copied from the IT6805 output-bus decision: single-pixel SDR for ≤1080p60-class input, dual-pixel SDR for 4:2:0 input, dual-pixel DDR for other large/fast modes (`hdmi-chips.md`). Observed: 0 (1080p), 1 (2160p 4:2:0), 2 (no input: RD writes a flag not derived from an input) (`S`,`T1`,`T3`; L).

## Driver notes
- V4L2: advertise only the six verified formats. Implement DV timings from input measurement + IT6805 status; emit `V4L2_EVENT_SOURCE_CHANGE` on change.
- Compute CSC matrices; select BT.601/709/2020 and range from the HDMI AVI InfoFrame (via IT6805).
