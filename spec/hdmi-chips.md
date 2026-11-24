# HDMI front-end: overview

Two ITE chips sit between the HDMI input and the FPGA: an HDMI splitter (chip ID 0x6663) and an IT6805 HDMI receiver. The host drives both over I2C bus 1. This file covers topology, control model, bring-up order, lock timing, the FPGA hand-off, EDID policy and HDCP. Register-level detail:
- `hdmi-splitter.md`: splitter, device 0x58 and its sub-devices.
- `hdmi-it6805.md`: receiver, device 0x90 and its sub-devices.
- `seq/*.tsv`: machine-readable register sequences (format in each file's header).

All I2C addresses are 8-bit (7-bit address << 1).

## Signal path
```
HDMI IN ─► splitter RX core (0x70) ─► splitter TX port 1 (0x6a) ─► IT6805 port 0 (0x90) ─► parallel video + audio ─► FPGA
                                   └► TX ports 0/2/3 (0x68/0x6c/0x6e): one drives HDMI OUT (pass-through)
```
- TX port 1 feeds the IT6805. DDC reads through 0x6a return the IT6805's EDID, and TX port 1 HPD follows GPIO bit 2 (below). (`T3/S20`,`S30`,`S31`; C)
- IT6805 port 0 status follows the input: `0x13` = 0xbf locked, 0x00 unplugged. Port 1 is initialised but unused. (`T3`,`S`; C)
- Pass-through output: probably TX port 2 (0x6c), by elimination only: the only other port with status changes and serviced events. Nothing was plugged into HDMI OUT during the traces. (`T3/S20`,`S`; U)

## Devices on bus 1
| Addr | Block | Enabled by | Chapter |
|---|---|---|---|
| 0x58 | splitter main; regs 0x00–0x03 = `54 49 63 66` | fixed | splitter |
| 0x70 | splitter RX core (same register design as the IT6805 receiver) | 0x58 reg 0xf0 = 0x71 | splitter |
| 0x96 | splitter TX common | 0x58 reg 0xf1 = 0x97 | splitter |
| 0x68 / 0x6a / 0x6c / 0x6e | splitter TX ports 0–3 | 0x96 regs 0x2c–0x2f = address \| 1 | splitter |
| 0xd8 | splitter RX EDID RAM (what the source reads) | 0x70 reg 0x4b = 0xd9 | splitter |
| 0x90 | IT6805; regs 0x00–0x03 = `54 49 05 68`, 0x04 = revision (0xb1) | fixed | IT6805 |
| 0xa8 | IT6805 EDID RAM | 0x90 reg 0x4b = 0xa9 | IT6805 |
| 0xe0 | IT6805 sub-block (one calibration access at init) | 0x90 reg 0x49 = 0xe1 | IT6805 |
| 0xe0 | splitter RX sub-block (RD never accesses it) | 0x70 reg 0x49 = 0xe1 | splitter |

Rule for sub-device enables: value = 8-bit address | 1. (`T1/S01`,`T3/S20`,`S`; C)

Address 0xe0 is mapped by both chips. RD's only 0xe0 access, the IT6805 calibration write, happens before the splitter maps its own block, and nothing accesses 0xe0 afterwards. Keep that order. (`T1/S01`; C)

Banked devices: 0x90, 0x58 and 0x70 each select a register bank with their own reg 0x0f. The bank is per-device state, so a driver must hold a per-device lock across a bank select and the accesses that depend on it. Interleaving transfers to different devices is harmless. (`S`,`T1`; C)

## Control model
- No chip interrupt reaches the host. Across all traces the only interrupt is INT bit 11 (I2C done). (`T1`,`T3`; C)
- RD polls each chip from a periodic task: nominally every 50 ms (20 ms after a power-on), observed every 60–68 ms because each cycle's I2C time adds to the delay. (`S`,`T3`; C)
- Transfers per IT6805 poll cycle depend on its state: no 5 V 9 (24 every 4th cycle), waiting for sync 38 (53), stable 56 (61) (`hdmi-it6805.md` §7.1). The splitter takes a few reads per cycle when idle, bursts on events, plus a periodic RX equaliser routine. At RD's ≈0.3 ms per transfer polling occupies roughly a quarter of the bus time; at the 0.13–0.15 ms our driver measured (`i2c.md`), about an eighth. (`T3`,`D`; L)
- GPIO bit 10 (`regmap.md`) may be a chip interrupt line. If confirmed, a driver could skip I2C polling while it is inactive. (U, open question 21)

## FPGA GPIO lines used by the front-end
| GPIO (0x040) bit | Role | Ev | Conf |
|---|---|---|---|
| 4, 6 | enables, set during FPGA init (`init.md`) | `S`,`T1` | L |
| 5, 8 | active-low reset pulses (`init.md`). One of them resets the IT6805: its registers read reset values at every load. Which bit drives which chip is unresolved | `T1`,`T3/S20` | L |
| 2 | **HPD input of splitter TX port 1**, i.e. the IT6805-side hot-plug line. 1 = high. RD drives it low when the IT6805 loses 5 V and high when 5 V returns and the receiver is powered. Once after load RD pulses it: 1, 10 ms, 0, 100 ms, 1. Evidence: TX port 1 latched its HPD event 84–104 ms after bit 2 went high (bounded by polls; first status reads showing high at 108 and 110 ms); it stayed low while bit 2 was low (9 s, 3.8 s); after a splitter TX reset with bit 2 still high, HPD was re-detected 70–133 ms later (`hdmi-splitter.md` §2.2). Fall latency unmeasured: the status still read high 60 ms after bit 2 went low, then the splitter's own TX reset (≈73 ms) forced it low | `S`,`T3/S30`,`S31` | C (fall latency U) |
| 10 | input, not driven by the host. Correlates with pending chip events: candidate interrupt output of the splitter or the IT6805 (`regmap.md`, open question 21) | `T1`,`T2`,`T3` | U |

## Bring-up order (RD, no input and with input)
1. FPGA init including the GPIO steps (`init.md` steps 1–11).
2. IT6805 init, ≈220 ms. It includes loading its EDID RAM and ends in power-saving (no 5 V) or standby (5 V present). `hdmi-it6805.md`. (`T1/S01`,`T3/S20`; C)
3. Splitter init, in RD's own task starting ≈190 ms after load and interleaved with step 2. `hdmi-splitter.md`. (`T1/S01`; C)
4. GPIO bit 2 HPD pulse (above), then periodic polling of both chips. (`T1`,`T3/S20`; C)
5. With a source present, the splitter detects TX port 1 HPD. It then reads the IT6805 EDID over DDC, copies it into its own EDID RAM (0xd8), and toggles HPD toward the source low (≈0.5 s) then high. (`T3/S20`,`S`; C) RD had already raised the source HPD at ≈454 ms, before that RAM was loaded (≈540–593 ms); the toggle made the source read the EDID again. (`T3/S20`; C)

Ordering a driver must keep: the IT6805's 0xe0 access before the splitter maps 0xe0; load the EDID RAMs before raising any HPD the source can see; keep the bank lock per device.

## Lock timing (observed)
| Step | 2160p 4:2:0 replug (`T3/S30`), ms | 1080p after 5 V cycle (`T3/S31`), ms |
|---|---|---|
| splitter RX 5 V detected | 31272 | 33540 |
| IT6805 5 V detected | 31285 | 33550 |
| splitter RX clock detected | 31648 | 37171 |
| splitter RX stable | 32007 | 37526 |
| IT6805 video sync detected | 32508 | 38130 |
| IT6805 stable (0x13 = 0xbf) | 32570 | 38192 |

RX clock to IT6805 stable takes ≈0.9–1.0 s. The source's own delay from 5 V to sending TMDS ranged from 0.4 s to 3.6 s. (`T3`; C) A driver should use timeouts of several seconds, not fixed delays.

Cross-chip rules:
- The IT6805 receives Clear-AVMUTE only after the splitter unmutes TX port 1 (TX port 1 reg 0xc1 bit 0 cleared; `hdmi-splitter.md`). In all 4 traced locks the IT6805 event appeared at its first poll after that write, never before. A driver must complete the splitter TX output enable, or the IT6805 output stays muted. (`T3/S20`,`S30`,`S31`; C)
- Decide on individual status bits (for example 5 V = bit 0 of the 0x13 status registers), not on whole-register values: intermediate values differ between unplug events (IT6805 0x13: bf→20→00 in `S30`, bf→00 in `S31`; splitter RX 0x13: 0xa0 in `S30`, 0x80 in `S31`). (`T3`; C)

## FPGA hand-off at stream start
RD derives the FPGA configuration from the IT6805 state when streaming starts (`video-pipeline.md` has the registers):
- **Input size:** IT6805 active width/height (`hdmi-it6805.md`). For 4:2:0 input the IT6805 horizontal count is in TMDS clocks, half the pixels, so width = 2 × count. Clip = input size. (`S`,`T3/S21`,`S32`; C)
- **Frame rate:** FPGA IN_FRAME_PERIOD (0x1010). Do not use the IT6805 clock estimates: RD assumes a 20.5 MHz reference, which makes them ≈13 % low, and RD's 52 fps for 59.94 Hz input came from this. (`S`,`T3`; C)
- **Colour:** the IT6805 performs no colour conversion. Its output colour space and sampling equal the input, which is known from the AVI InfoFrame. (`S`,`T3`; C)
- **Bus mode:** the IT6805 chooses it itself:
  - single-pixel SDR for 1080p60-class input;
  - dual-pixel SDR for any 4:2:0 input;
  - dual-pixel DDR for other large or fast modes.
  The FPGA must match: COLOR_CTRL[5] = dual, PIX_MODE = dual | (DDR << 1), COLOR_CTRL[0] = 4:2:2 input, COLOR_CTRL[19] = 4:2:0 input. (`S`,`T3`; C for single SDR and dual SDR as traced; dual DDR U, never traced)
- The FPGA's own input-measurement registers 0x1004/0x1008/0x100c were never read by RD. Their values with live input are unknown (open question 14 lists the experiment).

## EDID policy
- The source reads the splitter RX EDID RAM (0xd8). RD loads its EDID image into the IT6805 RAM (0xa8), and the splitter copies it over DDC. Both RAMs end up holding the same image. (`T3/S20`; C)
- RD's image advertises:
  - 2160p60 as the preferred timing, with 4:2:0 at 2160p50/60;
  - a 600 Mcsc HF-VSDB with SCDC, deep colour, BT.2020 colorimetry;
  - LPCM 2 ch at 32/44.1/48 kHz;
  - no HDR static-metadata block.

  (`T1/S01`; C) A Roku in automatic mode therefore chose 2160p59.94 4:2:0, the one mode that captured black (open question 14).
- Driver policy (design decision, not a hardware fact):
  - ship an own EDID image with its own manufacturer/product identity (do not reuse RD's);
  - advertise only verified capture modes: initially 1080p60 and below, RGB and YCbCr 4:4:4/4:2:2, LPCM 2 ch 48 kHz. Add 2160p modes once open question 14 is resolved;
  - load the same image into both RAMs (mechanisms in the chapters);
  - expose `VIDIOC_G_EDID` / `VIDIOC_S_EDID`; on change, drop and re-raise the source HPD.

## HDCP
- No HDCP programming is needed for an unencrypted source. In every trace the HDCP paths stayed idle: splitter RX encryption status 0, IT6805 encryption event never set, splitter TX HDCP never started. (`S`,`T3`; C)
- The test setup used an external HDCP stripper. Behaviour with an encrypting source and no stripper is untested. (U)

## 2160p status
- 2160p59.94 4:2:0 input locks cleanly through both chips (unencrypted, 8-bit, coherent timing), but the FPGA delivered exact-black frames under RD's configuration. Analysis and experiments: `video-pipeline.md`, open question 14. (`T3`; C for the observation)

## Driver notes
- One polling work item per chip (or one combined), every 50 ms. Event registers are write-1-to-clear: read, then write back the value read (exceptions per chip chapter).
- All observed I2C timeouts were on the IT6805 bank register; retry and bank-resync rules in `i2c.md`.
- On unload RD writes nothing to the chips or the GPIO register: the chips keep running and HPD stays as it was. (`T3/S36`; C) Whether a driver should drop HPD or enter power saving on remove is a design choice; untested.
- Report lock and unlock as `V4L2_EVENT_SOURCE_CHANGE`. Report DV timings from the IT6805 timing registers plus FPGA 0x1010. Stop streaming on unlock.
- The chips are separate I2C devices on the bus-1 adapter. Implement them as v4l2 subdevices or internal helpers. All their I2C goes through the bus-1 adapter.
