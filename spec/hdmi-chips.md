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

With our driver and the PC loopback (`E`, driver M3; C): 1080p60 locked (lock published) 1451 ms after the GPU output came on and 1080p59.94 1646 ms after a mode switch; 50 of 50 mode switches relocked within 3 s (slowest 1794 ms); after a driver reload with the source on, the lock came within 1051 ms of the output returning (1248 ms on the debug kernel).

Cross-chip rules:
- The IT6805 receives Clear-AVMUTE only after the splitter unmutes TX port 1 (TX port 1 reg 0xc1 bit 0 cleared; `hdmi-splitter.md`). The IT6805 event appeared at its first poll after that write in all 4 `T3` locks and at its second poll (58–71 ms after) in all 7 `T4` locks, never before. A driver must complete the splitter TX output enable, or the IT6805 output stays muted. (`T3/S20`,`S30`,`S31`,`T4`; C)
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
  - ship an own EDID image (do not reuse RD's); load the same image into both RAMs (mechanisms in the chapters);
  - expose `VIDIOC_G_EDID` / `VIDIOC_S_EDID` (2 blocks max, `hdmi-it6805.md` §4); on change: HPD low, reload both RAMs, HPD high;
  - advertise only verified capture modes. Grow the image as modes are verified, never ahead of them.

### Default EDID (requirements for the driver's built-in image)
| Part | Content | Why |
|---|---|---|
| Identity | manufacturer ID `LNX`, product code 0x5730, serial 0, monitor name "GC573 Linux", EDID 1.3, digital input | own identity; the subsystem ID in the product code |
| Preferred timing | DTD 1920×1080p60, 148.5 MHz | the main capture mode; makes sources default to it |
| Range limits | V 23–61 Hz, H 15–68 kHz, max pixel clock 150 MHz | keeps sources at or below 1080p60 |
| CTA-861 extension | revision 3; flags: basic audio, YCbCr 4:4:4, YCbCr 4:2:2 | 4:4:4 and RGB traced at 1080p (`T3`, `T4`); 4:2:2 is decoded by the IT6805 (UNVERIFIED end to end) |
| Video data block | VIC 16 (native), 31, 34, 33, 32 (1080p 50/30/25/24), 4, 19 (720p 60/50), 2, 3 (480p), 17, 18 (576p), 1 (640×480p) | progressive CTA modes ≤ 1080p60. Interlaced and 2160p modes are left out (open questions 14, 24) |
| Audio data block | LPCM, 2 channels, 48 kHz only, 16/20/24-bit; speaker allocation FL/FR | 48 kHz is the only rate traced (`audio.md`) |
| HDMI VSDB | physical address 1.0.0.0, no deep colour, max TMDS 165 MHz | no HF-VSDB, so sources stay at HDMI 1.4 rates: no SCDC, scrambling or 4:2:0 |
| Video capability data block | QS = 1 (RGB quantisation selectable) | lets RGB sources signal full or limited range in the AVI InfoFrame |

Validate the image with `edid-decode` (no errors or warnings) in the test suite. A warning-free image also needs: the native mode signalled by the native-DTD count in CTA byte 3 (0xf1: underscan, basic audio, YCbCr 4:4:4 and 4:2:2, one native DTD) rather than the VIC 16 native flag; the sRGB bit in the feature byte; and the VCDB byte 0xca (QY = 1, QS = 1, IT always underscanned, CE always underscanned) (`E`, driver M3; C). The chips serve their own checksums, computed from the loaded bytes (`hdmi-it6805.md` §4, `hdmi-splitter.md` §6.5). Planned additions once verified with our driver: 2160p30 (VIC 95, 94, 93; dual-pixel DDR captures correctly under RD, `T4/S44`); 2160p60 4:2:0 only after open question 14. With this image the PC loopback source defaults to 1080p60.

## HDCP
- No HDCP programming is needed for an unencrypted source. In every trace the HDCP paths stayed idle: splitter RX encryption status 0, IT6805 encryption event never set, splitter TX HDCP never started. (`S`,`T3`; C)
- An encrypting source connected directly, with no stripper (the Roku Ultra, 2026-11-26, `tests/logs/20261126-155805_6.8.0-151-generic_live.log`): the splitter RX completed the HDCP 1.x handshake by itself, with the init as traced. That init turns off RX HDCP 2.x (70/0:e3 = 00, 58/1:10 bit6 = 0) and the TX ports' HDCP 1.x engines (0x41 bit0 = 0). (`E`; C)
  - RX events 0x09 read 07, never seen before. Bits 1 and 2 are documented as HDCP authenticated and encryption changed (`hdmi-splitter.md`); bit 0 is undocumented.
  - The stream reached the IT6805 and the FPGA in the clear: 1080p59.94 YCbCr 4:4:4 locked as from any source, the FPGA measured it at once, and the captures were normal pictures.
  - Unbinding (146 ms), rebinding (694 ms) and the lock after it (1.5 s) behaved as with any source.
- With RX HDCP 2.x off, a source that requires HDCP 2.2 for some content (typically 4K) presumably falls back or withholds that content; untested. (U)
- Driver policy: none. Beyond the traced init above, the driver reads and writes no HDCP state, and it captures whatever the chips pass on.

## 2160p status
- 2160p59.94 4:2:0 input locks cleanly through both chips (unencrypted, 8-bit, coherent timing), but the FPGA delivered exact-black frames under RD's configuration, from the Roku (`T3`) and from a PC source without HDCP (`T4/S41`). Analysis and experiments: `video-pipeline.md`, open question 14. (`T3`,`T4`; C for the observation)
- 2160p29.97 RGB 4:4:4 (dual-pixel DDR) captures correctly (`T4/S44`).

## PC loopback source (`T4`)
A host GPU output (GT 710, DVI-D, through a DVI-to-HDMI cable) feeds HDMI IN. Facts about this source, for tests (`T4`; C):
- With RD's EDID the GPU picked 2160p60 YCbCr 4:2:0 in HDMI mode (AVI InfoFrame present) by default: 297 MHz TMDS through a DVI connector.
- 1080p60 and 2160p29.97 arrived as RGB 4:4:4 8-bit in HDMI mode with an AVI InfoFrame (RGB, full range, IT content); both chips read 0x13 = 0xbf. During each mode change the IT6805 reports DVI (0x13 = 0xbd) from video detection until the splitter unmutes TX port 1, and HDMI 1–3 ms after the unmute. The splitter RX reports HDMI again at its first read after SCDT on, 0.55–0.87 s before the unmute (`hdmi-splitter.md` §9.8). RD logs the IT6805's transient.
- No audio in `T4`: the GPU sent no audio packets (the host's HDMI audio output was off). With our default EDID the GPU's ELD is valid (LPCM 2 ch 48 kHz) and its HDMI audio output plays to the card: while `tools/testsrc/avsync.sh` played, the IT6805 audio state reached ON (`E`, driver M3; capture not yet verified).
- Colour formats the GPU sends on request (NVIDIA `ColorSpace`/`ColorRange`; `E`, driver M3): RGB full or limited range (the switch keeps sync, `hdmi-it6805.md` §7.8) and YCbCr 4:4:4 limited range. A YCbCr 4:2:2 request still produces 4:4:4 (AVI PB1 0x40), so this source cannot test 4:2:2 input.
- Modes it offers with our default EDID: 1080p60/59.94/50/29.97/25/23.98, 720p60/59.94/50, 576p50, 480p59.94, 640×480p59.94 and p59.93. All lock and capture with our driver (`E`, M3).
- Mode changes at the source with 5 V held: sync is lost and regained (TMDS back after 0.8–1.1 s) with no HPD or power-mode change; stable again 1.4–1.7 s after the loss (`hdmi-it6805.md`).
- Frame rate 60.006 Hz at 1080p60 and 2160p60 (IN_FRAME_PERIOD 0x00196daf), 29.973 Hz at 2160p29.97.
- The GPU dithers its output by default; turn that off for exact tests (`tools/testsrc/show.sh` does).

## Driver notes
- One polling work item per chip (or one combined), every 50 ms. Event registers are write-1-to-clear: read, then write back the value read (exceptions per chip chapter).
- All observed I2C timeouts were on the IT6805 bank register; retry and bank-resync rules in `i2c.md`.
- On unload RD writes nothing to the chips or the GPIO register: the chips keep running and HPD stays as it was. (`T3/S36`; C) Whether a driver should drop HPD or enter power saving on remove is a design choice. With this driver's M5 build (2026-11-25), the source saw nothing of an unload or a load: with the PC loopback at 1080p60, the PC's ELD (polled every 10 ms) and its connector state (xrandr, every 100 ms) did not change at the unload or at the load, and the receiver locked again 1.5 s after the load returned (`tests/logs/20261125T172311Z-hpd-unload.log`).
- Report lock and unlock as `V4L2_EVENT_SOURCE_CHANGE`. Report DV timings from the IT6805 timing registers plus FPGA 0x1010. What a running stream does is driver policy (below).
- The chips are separate I2C devices on the bus-1 adapter. Implement them as v4l2 subdevices or internal helpers. All their I2C goes through the bus-1 adapter.

## Lock policy
Driver policy (design decision, not a hardware fact; `src/gc573_hdmi.c` gc573_hdmi_publish):
- The input is locked, and DV timings are reported, only when the IT6805 is STABLE with the AV mute released (`hdmi-it6805.md` §7.7, §7.10) and the FPGA's own measurement is valid and agrees with the IT6805:
  - 0x1004[1:0] = 3 (`regmap.md`);
  - 0x1008 = the IT6805's active width (halved for a dual-pixel bus and again for DDR), and 0x100c[15:0] = its active height for a progressive input;
  - 0x1010 in range (5 to 121 Hz), within 0.02 % of its value one poll earlier (two polls in a row agree), and within 5 % of the period the IT6805's coarse clock gives for the measured frame (§8.3 of `hdmi-it6805.md`: those counters are good for coarse decisions only).
- There is no lock without it, however long the IT6805 has been stable. The rate comes from 0x1010 only, never from the IT6805's clock counters, which are about 1 % off (one count is 1.2 % at 1080p).
- Why: at a host boot (2026-11-25, PC source arriving while X started), 0x1004 read 1 with 0x1008/0x100c valid, so the check failed for the 20 polls the earlier policy waited, and went on failing until the source set its mode again (0x1010's own value was not logged). That policy then locked on the IT6805's clock alone and reported 1080p60 as a 146.823 MHz custom mode, 59.32 Hz. 0x1004 = 1 is not documented (`regmap.md` has 3 and 2), nor is a way to re-arm the measurement: open question 40.
- After 40 polls (about 2.3 s) without a valid measurement the driver logs it once per stable entry (`dev_warn`, FPGA registers included) and counts it (debugfs hdmi `fpga_waits`).
- Self-heal (driver policy; module parameter `fpga_heal`, default on). It starts when all of these hold 90 polls (about 5 s) after the release: the FPGA's status is still not 3 (0x1004[1:0]), its active size equals the IT6805's, and there is no lock. The driver then tries, at most 3 times:
  1. a receiver restart, which open question 40 proposes as a pass through WAIT_SYNC. The driver runs the IT6805's WAIT_SYNC entry (`hdmi-it6805.md` §7.5: tristate) and audio off while the source still sends sync. It leaves out the sync loss's 0:40 write: its meaning is unknown, and it was never traced with sync present. The next poll takes the sync-on path, and the stable entry (§7.6) runs again, as after a mode change of the source. The source sees nothing: there is no HPD or power write;
  2. and 3. the hot-plug of an EDID change, with the image unchanged: the same as `VIDIOC_S_EDID` ("EDID policy": source HPD low, both RAMs loaded, RD's change toggle, HPD high). The second comes at least 20 s after the first, the third at least 80 s after the second. A hot-plug makes the source set its mode again, which ended the stuck measurement at that boot. The splitter's EQ search runs again after the change toggle (question 39, which failed in the same seconds).
- Each attempt is logged (`dev_info`). If there is still no lock 5 s after the third, the driver logs one `dev_warn` and makes no more attempts until the session ends: at a lock, or at a 5 V loss (splitter RX 0x13 bit 0) more than 10 s after the last attempt. A sync loss does not end it: both attempts cause one, and a source that keeps dropping sync must not get a hot-plug after each. A source the FPGA reports stable (status 3) gets no attempt, even when the policy rejects its measurement (a frame period that moves). Debugfs hdmi: `fpga_heals` (attempts), `fpga_heal_fixes` (locks after an attempt, before a give-up), `fpga_heal_giveups`, `heal_tries` (this session); it6805 `restarts`.
- UNVERIFIED: whether either attempt brings 0x1004 to 3 on the hardware. The boot race has not been reproduced, and the experiment parameter plays only its FPGA state (open question 40).
- Inputs the FPGA may never measure also get the restart and two hot-plugs per session, then the give-up: interlaced input (M9), deep colour, and 2160p60 4:2:0 if an EDID offers it. The driver supports none of them yet. That is accepted: the attempts are bounded, and the kernel log names each one. `fpga_heal=0` turns them off (README "Known limitations"). An encrypting source connected directly is measured at once and gets no attempt (§HDCP).
- A lock holds while the IT6805 stays stable at the same active size. Its timings change only when a valid frame period moves by more than 0.05 %, half the 1000/1001 step.
- Test: the experiment parameter `exp_fpga_invalid` and `tests/live.sh fpgawait` (the self-heal off) and `fpgaheal`. The parameter is the number of polls after each stable entry for which the poll sees 0x1004[1:0] = 1, as at that boot, and 0x1010 = 0. 4294967294 means until the self-heal's first attempt (a case the restart fixes), and 4294967295 always (a case nothing fixes).

## Stream policy on input changes
Driver policy (design decision, not a hardware fact; also in the header comment of `src/gc573_video.c`):
- Every lock, loss and mode change raises `V4L2_EVENT_SOURCE_CHANGE` at once. An application that handles it stops streaming, queries and sets the timings, and starts again.
- A running stream also follows the input by itself, for applications that ignore the event:
  - input lost: the stream restarts free-running (black at 60 Hz, `video-dma.md`);
  - input locked in the stream's timings: the stream restarts live;
  - input locked in other timings: the stream is held for up to 1 s: the hardware is stopped, the buffers stay queued, no frames arrive. If the input is lost or locks in the stream's timings within that second, the stream restarts as above. If the other timings last the whole second, the stream fails: its buffers are returned with an error and the queue is marked failed.
- Why the hold: a source that changes its mode can lock briefly in another mode first. After an EDID change the PC source came up in the EDID's preferred mode, 1080p60, until the harness set 720p. The driver locked at 1080p for 138 ms (host soak, `tests/logs/20261125-215755_6.8.0-151-generic_live.log`, 23:11:06Z), and `tests/live.sh blip` reproduces it (224 ms). Failing the stream at that lock ended OBS's capture for good. The lock in a passing mode comes 1.1–1.7 s after the mode is set, so a 1 s hold rides out a second mode set up to 2.1–2.7 s after the first. (`E`; C for the measurements)
- The hold does not free-run: free-running is documented with no input (`video-dma.md`). With a locked input in other timings it is untested.
- Colorimetry: G_FMT, TRY_FMT and S_FMT report, for each pixel format, the colorimetry of the last input that locked since the module loaded. Its colour space and range come from the AVI InfoFrame (`hdmi-it6805.md` AVI table). The YUV outputs' encoding is the input's for YCbCr input, and by size for RGB input (BT.601 below 720 lines). The RGB→YUV CSC uses that encoding. All of it follows that input through a loss and a hold. A lock in another colorimetry switches it at that lock, with the lock's `V4L2_EVENT_SOURCE_CHANGE`. Before the first lock since load it is the M2 setup: BT.709, limited-range YUV, full-range RGB.
  - Free-run frames during a loss are black in any of these. The no-input YUV→RGB CSC stays limited-range BT.709, as in RD's no-input setup (`T1/S02`), and the free-run black comes out of it as RGB 0 (`video-dma.md`). The RGB→YUV CSC maps RGB 0 to Y 16, Cb/Cr 128 in any encoding, tested with BT.601 at 720x480 (`tests/live.sh colorimetry`). RGB outputs carry 0 even where a limited-range RGB input made their range limited.
  - Why: GStreamer's v4l2src (1.24.2) sets its format again at every event: STREAMOFF, REQBUFS 0, QUERY_DV_TIMINGS, then TRY_FMT and S_FMT. It turns a changed colorimetry into new caps, which matroskamux refuses ("Caps changes are not supported by Matroska"). With the M2 colorimetry during a loss, its recording ended at the source's sleep (`tests/logs/20261126-052557_6.8.0-151-generic_live.log`). A real change of size or rate still ends it. (`E`; C)
