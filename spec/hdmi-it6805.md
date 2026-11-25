# IT6805 HDMI receiver

The IT6805 receives HDMI from splitter TX port 1 and drives the parallel video bus and the audio lines into the FPGA (topology, bring-up order across both chips, lock timing and EDID policy: `hdmi-chips.md`). The host does all of the following over I2C bus 1 (`i2c.md`): identification, a fixed register setup, analog calibration, an oscillator trim from factory data, EDID RAM loading, power-mode changes, polling of event registers, and per-mode programming of the output bus. No IT6805 interrupt reaches the host. The hot-plug line on the IT6805 side is FPGA GPIO 0x040 bit 2, not an IT6805 register (§5).

Conventions:
- I2C addresses are 8-bit. `B:RR` = bank B, register 0xRR (hex). "Bank 0" unless stated. W1C = write 1 to clear.
- RD = reference driver (`README.md`). Register meanings come from how RD uses a register (`S`) and from traced values (`T…`). Unlisted registers and bits are unknown: write them only as the sequences do.
- Trace times are ms after the first `I2C` line that follows the scenario's MARK in `traces/T<n>.tsv.xz`. Scenarios used most: `T1/S01` load with no input (first load after power-up); `T2/S10` load with no input (reload); `T3/S20` load with 2160p59.94 4:2:0 input (reload); `T3/S30` cable unplug at ≈22 s and replug at ≈31 s; `T3/S31` source switch 2160p→1080p through a 2.7 s signal loss, then a 5 V cycle and 1080p re-lock at ≈38 s; `T3/S21`… and `T3/S32` streaming.
- `T4` is the PC loopback: a GPU output (DVI-D connector, DVI-to-HDMI cable) through the splitter, 5 V present throughout, with the GPU switching modes (`hdmi-chips.md`). Its I2C capture starts 2.35 s after the `S40` load MARK: the IT6805 init and the first polls are not in `T4` (3126 bus-1 completion interrupts in that gap carry no transfer data); MMIO, including the HPD pulse, is. Modes and stable entries: 2160p60 YCbCr 4:2:0 (`T4/S40` 953 ms, first lock after load; `T4/S44` 51820 ms), 1080p60 RGB (`T4/S41` 92588 ms, `T4/S44` 2956 ms, `T4/S45` 8890 ms), 2160p29.97 RGB (`T4/S43` 91337 ms, `T4/S45` 1580 ms). Every mode change kept 5 V and went through a sync loss (§7.9).

## Sequence files
| File | Content |
|---|---|
| `seq/it6805-init.tsv` | probe initialisation (§3) |
| `seq/it6805-unplug.tsv` | "no 5 V" state entry (§7.5) |
| `seq/it6805-power-saving.tsv`, `-power-standby.tsv`, `-power-normal.tsv` | power modes (§6) |
| `seq/it6805-lock.tsv` | stable entry, single-pixel SDR: output bus, colour, mute, video logic reset, unblank. 1080p59.94 YCbCr 4:4:4 values; MODE notes give RGB values (§7.6, §10) |
| `seq/it6805-lock-dual-sdr.tsv` | stable entry, dual-pixel SDR (rule a): 2160p60 YCbCr 4:2:0 values (§10) |
| `seq/it6805-lock-dual-ddr.tsv` | stable entry, dual-pixel DDR (rule d): 2160p29.97 RGB values (§10) |

Columns `n op dev bank reg mask value note`. Ops: W write; M read-modify-write `new = (old & ~mask) | value`; D delay (ms); P poll; R read (informative); X step described here (the note names the section). Small sequences (AV-mute release, audio on/off, sync loss) are given inline in §7 and §11.

Replay check (`D`): applying the tables to the read values in the traces reproduces, in order, value and bank, every IT6805 register write of the `T1/S01` load (209 writes) and the `T3/S20` load (182), all power transitions in `T3/S20`/`S30`/`S31`, and the 1080p stable entry at `T3/S31` 38385 ms (46 writes). Not counted: bank selects (checked through the bank column; RD often re-selects the bank already selected, and the tables omit those repeats), EDID RAM bytes, X-step writes (checked separately). The second 1080p entry (`T3/S31` 27718 ms) differs in one intermediate write (row note in `it6805-lock.tsv`). At the first lock after a load (`T3/S20` 4557 ms) RD omits the first 0:6b write of the bus setting; the final register state is the same.

Replay against `T4` (`D`): the init, unplug, SAVING and STANDBY tables are not exercised (init not captured; no 5 V loss). NORMAL reproduces `T4/S40` 700.7 ms (22 writes). All 7 stable entries replay without error with the table of their bus mode and the MODE values of their input (46–47 writes each), apart from RD's bus-setting 0:6b write, which carries the previous lock's output colour (`T4/S41` 92588, `S44` 51820, `S45` 1580) or is omitted at the first lock after load (`T4/S40` 953). The published single-pixel table with its YCbCr 4:4:4 values differs from the RGB entries in exactly its three 0:6b MODE rows. The inline sequences of §7 (sync off, sync on, AV-mute release) reproduce all `T4` instances (6, 7, 7). Every IT6805 write in `T4` belongs to one of these sequences or to the poll's write-backs.

## 1. Device and access model

### 1.1 Identity and sub-devices
| Item | Fact | Ev | Conf |
|---|---|---|---|
| Address | 0x90 on bus 1 | `T1/S01` | C |
| ID | regs 0x00–0x03 = `54 49 05 68` | `T1/S01`,`T3/S20` | C |
| Revision | reg 0x04 = 0xb1, the only value seen. RD has branches for other revisions: 0xb0 puts the 20.5 MHz value into 3:fa instead of 1:fd/1:fe; 0xa0/0xa1 add EDID-control pulses (0:c5 and 4:c5 = 0x12 then 0x02) at unplug and reset. None ran. A driver should warn on any other revision: its init path is untested | `T1`,`T2/S10`,`T3/S20`,`S` | C (0xb1); U (others) |
| ID mismatch | RD only waits 10 ms and continues. A driver should fail the probe | `S` | L |
| EDID RAM at 0xa8 | enabled by 0:4b = 0xa9 (8-bit address \| 1) | `T1/S01`,`T3/S20` | C |
| Sub-block at 0xe0 | enabled by 0:49 = 0xe1 (fixed table). One access ever: reg 0x01 bits 6:4 = 4 (read 0x40, wrote 0x40) during the oscillator step. Function unknown. The splitter later maps a block of its own at 0xe0 (`hdmi-splitter.md`): do this access before the splitter init maps it (RD: `T1/S01` 89.8 ms vs 226.6 ms) and never access 0xe0 afterwards | `T1/S01`,`T3/S20` | C (access, order); U (function) |
| Other sub-devices | none enabled or accessed | `T1`,`T3` | C |

### 1.2 Transfers
- RD uses only single-byte register reads and writes (LEN 1) on 0x90, 0xa8 and 0xe0, including the 254-byte EDID load. Whether the IT6805 auto-increments on multi-byte transfers is unknown; use single bytes. (`T1`,`T3`; C for the observation, U for bursts)
- Every IT6805 transfer completed, except 4 timeouts, all on the bank register 0x0f (§1.7). (`T1`,`T2`,`T3`; C)

### 1.3 Banks
- Reg 0x0f bits 2:0 select the bank used by all other registers; 0x0f itself is reachable in every bank. Bits 7:3 always read 0 (0xaa written → 0x02 read). RD selects banks with a read-modify-write of bits 2:0; its power-mode sequences write 0x0f directly; both work. (`T1`,`T3`; C)
- The bank is device state that persists between transfers. After reset it is 0: RD reads the ID registers before any bank select. (`T1/S01`,`T3/S20`; C)
- Hold one lock across a bank select and every access that depends on it. Transfers to other devices may interleave. (`hdmi-chips.md`; `S`,`T1`; C)

| Bank | Content | Ev | Conf |
|---|---|---|---|
| 0 | ID; event and status registers; reset and power control; timing measurement; output format; audio control and status; EDID control for port 0 | `S`,`T` | C |
| 1 | output bus (0xb0, 0xbd, 0xbe, 0xc0–0xca, 0xfd, 0xfe); colour converter (0x70–0x86); factory-data access (0x50–0x62); 0x10–0x13 and 0x28–0x2c (written 0 at init) | `S`,`T` | C |
| 2 | received packets: AVI InfoFrame, audio InfoFrame, SPD, vendor InfoFrame; audio N/CTS | `S`,`T3` | C (AVI, N/CTS); L (others) |
| 3 | port-0 receiver PHY: equaliser, calibration, power bits, oscillator trim (0xaa) | `S`,`T` | C |
| 4 | port-1 copy of the per-port bank-0 registers (used: 0x3a, 0x3b, 0x3c, 0x43, 0xc5, 0xc7–0xca, 0xce) | `S`,`T1` | C |
| 5 | pixel-path registers (0x20, 0xd0, 0xd1, 0xda), power-related (0xc1–0xcb), internal down-scaler (0x21–0x41, unused) | `S`,`T` | C (writes); U (meaning) |
| 6 | DRM (HDR) InfoFrame buffer from 0x10; read-only | `S`,`T3` (1625 reads, 0 writes) | L |
| 7 | port-1 copy of bank 3 | `S`,`T1` | C |

- Bank bit 2 means "port 1" only for the pairs 0→4 and 3→7; banks 1/5 and 2/6 are unrelated. Whether every bank-0 register has a bank-4 twin is unknown. Some port-1 functions are separate bank-0 addresses instead: events 0x0a–0x0e, status 0x16–0x18, reset 0x2b, calibration 0x2c–0x32. (`S`; L)

### 1.4 Read-modify-write and write-1-to-clear
- RD changes most bits by read-modify-write. The sequence files give these as M rows. RD often also reads a register before a full-byte write; such reads have no effect and are omitted. (`S`,`T`; C)
- Event registers are W1C: a 1 clears the bit, a 0 leaves it. 0:05 read 0x56, written 0x56, read 0x00 next poll; 0:07 read 0x03, written 0x00, read 0x03 again on every later poll. (`T3/S30`,`S31`; C)
- A read-modify-write of an event register therefore clears every bit that read 1. RD relies on this after the video logic reset: 0:10 read 0x42, written 0x42. (`T3`; C)

### 1.5 Ports
- The chip has two HDMI inputs. GC573 uses port 0, fed by splitter TX port 1. The port select (0:35 bit 0) is never written; the reset value selects port 0. (`T`,`S`; C)
- RD initialises and calibrates port 1 along with port 0, programs its EDID registers and puts it in its saving values; its status (0:16) and events (0:0a, 0:0d) stay 0. The sequence files include these port-1 rows. Whether they can be omitted is untested. (`T1`,`T3`,`S`; C)

### 1.6 Reset and persistence
- The FPGA init's GPIO reset pulses (`init.md`) reset the IT6805. Evidence: the first reads of 3:aa, 1:c0 and 0:49 return 0xec, 0x00, 0xc0 at every load, although every load writes other values there (0xf3, 0x42 or 0x43, 0xe1). A few registers survive the pulse: 1:28–1:2c, 3:f0 and 0:59 read e0 21 e0 e8 0a, 0x54, 0x09 at the first load after power-up (`T1/S01`) but the values the previous load wrote (all 0x00, 0xc0, 0x00) at the reloads (`T2/S10`, `T3/S20`). The init rewrites all of them. Which GPIO bit (5 or 8) drives the IT6805 reset is unknown (open question 10). (`T1/S01`,`T2/S10`,`T3/S20`; C)
- Time from the last reset release (GPIO bit 8) to the first IT6805 access in RD: 52 ms. The minimum is unknown; keep ≥ 50 ms. (`T2/S10`,`T3/S20`; C for the value)
- RD makes no IT6805 access at unload or suspend; the chip keeps running and GPIO bit 2 keeps its level. At resume RD re-runs FPGA init (reset pulses), the full IT6805 init, then the HPD pulse (§5). Run the full init at every probe and resume. (`T3/S36`; C · `S` for resume; L)

### 1.7 Bus robustness
- All 4 observed bus-1 timeouts were transfers to IT6805 reg 0x0f. In `T3/S32-BGR3` RD's retry of a bank select sent 0xaa instead of 0x00: the chip switched to bank 2, and the next two accesses meant for 0:12 hit 2:12 (the read returned the AVI length 0x0d; the write-back went into the packet buffer). The trace's bank column is wrong for those two transfers (`traces/README.md`). Retry and bank-resync rules: `i2c.md`; open question 22. (`T3/S32-BGR3`; C)
- Driver rule: cache the bank per device and skip unchanged selects (this removes most traffic to 0x0f); after any failed or retried transfer, rewrite and read back 0x0f before the next banked access.

## 2. Register map
Ev/Conf apply to the meaning as stated. "RD" columns describe what RD does with the register.

### 2.1 Event registers (bank 0, W1C)
| Reg | Bit | Meaning | RD action | Ev | Conf |
|---|---|---|---|---|---|
| 0x05 | 0 | port-0 5 V changed | 5 V handler (§7.4) | `T3/S30`,`S31`,`S` | C |
| | 1 | set when the TMDS clock arrives (0x56, 0x16): after a 5 V return and after a sync loss with 5 V held | first one after a 5 V return → NORMAL power (§6); otherwise none | `T3/S20`,`S30`,`S31`,`T4`,`S` | C (when set); U (meaning) |
| | 2 | input clock changed | clears its symbol-loss counters; reads 0:13 | `S`,`T3` | L |
| | 3 | set at signal loss (0x0c, 0x0d; 0x4c, 0x4e at the `T4` sync losses) | none | `T3/S30`,`S31`,`T4` | U |
| | 4 | HDMI/DVI mode changed (RD's usage). Traced: set at every TMDS arrival; not set when 0:13 bit 1 later went 0 → 1 (`T4`, 6 of 6) | if 0:13 bit 3: HDMI → restart audio when stable; DVI → audio off and re-run the output enable when stable | `S`,`T3`,`T4` | L (meaning); C (observations) |
| | 5 | ECC error | counted; recovery §7.9 | `S` | L (never seen) |
| | 6 | deskew error | counted only | `S` | L |
| 0x06 | 0 | symbol lock changed | log | `S`,`T3` | L |
| | 4, 5, 6 | symbol lock lost on channel 0, 1, 2 | counted; §7.9 | `S`,`T3` (0xf1 at 5 V loss), `T4` (0xf1 at every sync loss) | L |
| 0x07 | 3 | link mode (HDMI/MHL) changed | if 0:13 bit 6: NORMAL power. Written back alone (`value & 0x08`) | `S`,`T` | L |
| | 0, 1, 2 | set at signal loss, then read on every poll while unlocked (0x01 `S30`, 0x03 `S31`, 0x07 after every `T4` sync loss); 0x00 before the first signal after a load (`T4/S40`) | never cleared | `T3`,`T4` | U |
| | 4–7 | adaptive-equaliser done/fail flags | none (adaptive EQ unused) | `S` | L |
| 0x08 | 0 | — | → WAIT_SYNC | `S` | L (never seen) |
| | 2 | — | written 1 in the no-5 V entry | `T` | U |
| | 4, 5 | port-0 calibration done | init only (§3.3) | `T1`,`T3/S20` | C |
| | 7 | HDMI 2.x detection state changed | M 0:4c 80 80 | `S` | L (never seen) |
| 0x09 | 0, 3 | — | reset the ECC counter | `S` | U (never seen) |
| 0x0a | 0 | port-1 5 V changed | written back alone (`value & 0x01`) | `S`,`T` | C (always 0) |
| 0x0d | 4, 5 | port-1 calibration done | init only | `T1`,`T3/S20` | C |
| | 2 | — | written 1 in the no-5 V entry | `T` | U |
| 0x10 | 1 | sync detect (0:19 bit 7) changed. Also set once after each video logic reset with sync unchanged: first seen 127–136 ms after the reset at 60 Hz (still clear at 63–66 ms), 190–191 ms after it at 29.97 Hz (still clear at 127–129 ms) | edge handler (§7.4): acts only if 0:19 bit 7 differs from the stored value | `T3`,`T4`,`S` | C |
| | 2 | — | none; seen at signal arrival (0x16), in the poll before audio on (`T3`), and near the splitter unmute (0x04, 0x24; `T4`) | `T3`,`T4` | U |
| | 4 | Set_AVMUTE received. Seen at every TMDS arrival (`T3`, `T4`), while the splitter's TX port 1 is still muted, and at the `T3/S31` sync loss (0x52); not at the `T4` sync losses (0x02) | when STABLE: AV mute on | `S`,`T3`,`T4` | L |
| | 5 | Clear_AVMUTE received. Arrives only after the splitter unmutes TX port 1 (`hdmi-chips.md` cross-chip rules): 1.9–72.5 ms after it in `T3`; 58–71 ms in `T4`, where the first poll after the unmute (its 0:10 read 1.8–3.1 ms after it) never had it | when STABLE: AV mute off | `S`,`T3`,`T4` | C (arrival rule); L (action) |
| | 6 | — | none. `T3` (source with audio): set by every video logic reset (0x42 read right after it) and at sync edges (0x52, 0x56, 0xc2). `T4` (no audio): never set; 0x02 after every reset | `T3`,`T4` | U |
| | 7 | audio event | when STABLE: audio logic reset and audio enable; also blocks "audio ready" | `S`,`T3` (0xc2 at unplug) | L |
| 0x11 | 0, 1 | — | RD writes 0x11 = 0x01 / 0x02 | `S` | U |
| | 2 | — | reads 2:28–2:2c and discards them | `S` | U |
| | 3 | — | none (0x08 seen in `S31`) | `T3` | U |
| | 6 | — | excluded from the write-back | `S` | U (never seen) |
| 0x12 | 0 | AVI InfoFrame changed | reads 2:14/2:15 and compares with the stored copy (§7.8) | `S`,`T3` | C |
| | 4 | — | none; seen at signal arrival in `T3` (0x91), not in `T4` (0x81) | `T3`,`T4` | U |
| | 5 | DRM InfoFrame received | DRM check (§9.2) | `S` | L (never seen) |
| | 7 | video parameters changed. Also reads 1 at the first poll after every video logic reset | read 0:1a, 0:1b; write 0x12 = 0x80; re-read HActive (§7.8) | `S`,`T3` | C |
| 0x1d | 3 | HDCP encryption state changed (then 0:d6 bit 3 = encrypted) | log | `S` | L (never seen) |
| 0xd4, 0xd5 | — | — | read and written back | `T3` | U (always 0) |

Port-1 equivalents: 0x0a–0x0e for 0x05–0x09. (`S`; L)

### 2.2 Status registers (bank 0, read only)
Decide on single bits, not on whole values: intermediate values differ between events (0x13 went bf→20→00 at the `S30` unplug and bf→00 at the `S31` one). (`T3`; C)

| Reg | Bit | Meaning | Observed | Ev | Conf |
|---|---|---|---|---|---|
| 0x13 | 0 | port-0 5 V present | 1 whenever the cable is powered | `T3`,`S` | C |
| | 1 | HDMI (1) / DVI (0) | After a splitter TX port soft reset it reads 0 from TMDS arrival until the splitter unmutes TX port 1, then 1 at the first poll after the unmute, within 2.3 ms (`T3/S30`,`S31`; all 6 `T4` mode changes, each with a soft reset: 1.2–2.0 ms). With no soft reset since init it read 1 from TMDS arrival, 65–66 ms before the unmute (`T3/S20`, `T4/S40`). Cause unknown (`hdmi-splitter.md` §7.5). 1 at every traced stable entry, PC source included (§9.1) | `T3`,`T4`,`S` | C |
| | 3 | input clock present (RD's usage; RD bases its decisions on this bit) | set with signal | `S`,`T3` | L |
| | 4 | input clock stable (RD's usage; RD only logs it). Bits 3 and 4 were set together in every trace, so the two names are not separable; code against the bit numbers | set with signal | `S`,`T3` | L |
| | 6 | MHL link mode | 0 | `S`,`T` | L |
| | 2, 5, 7 | — | set with signal; bit 5 alone for ≈100 ms after one unplug and for < 177 ms after one `T4` sync loss (0x21) | `T3`,`T4` | U |
| | whole | 0x00 no cable · 0x01 5 V only · 0xbd clock and sync, HDMI not yet detected · 0xbf locked HDMI | | `T3`,`T4` | C |
| 0x14 | 5:3 | symbol lock, channels 0–2 | 111 locked | `S`,`T3` | C |
| | 6 | HDMI 2.0 mode (1/40 TMDS clock ratio) | 0 | `S` | U |
| | 7 | scrambling active | 0 | `S` | U |
| | 0 | — | always 1 | `T` | U |
| | 1 | — | 1 with a 297 MHz link (2160p 4:2:0, 2160p29.97 RGB), 0 with 148.5 MHz. After a loss it stayed 1 in `T3/S31` (0x03 until the 5 V loss) but cleared at every `T4` sync loss (0x01) | `T3`,`T4` | C (values); U (meaning) |
| | whole | 0x01 no signal · 0x03 signal lost after 2160p (`T3/S31` only) · 0x39 1080p · 0x3b 2160p (297 MHz link) | | `T3`,`T4` | C |
| 0x15 | 5:2 | HDMI 2.x detection state | 0 | `S` | U |
| | 7:6 | — | 11 in all reads (1996 in `T3`, 5987 in `T4`) | `T` | U |
| 0x16–0x18 | | port-1 copies of 0x13–0x15 | 0 | `S`,`T` | L |
| 0x19 | 7 | video sync detected ("sync") | 1 with sync | `S`,`T3` | C |
| | 6:0 | — | 0x3e with sync (0x3c in 2 of 1993 `T4` reads). Without sync 0x20 (with or without 5 V) or 0x30 (bit 4 toggling, only seen with 5 V) | `T3`,`T4` | U |
| 0x1a | 6, 3, 1 | any set at a parameter change → reconfigure | 0x01 with signal, 0x00 after loss | `S`,`T3` | L |
| 0x1b | 1 | set at a parameter change → reconfigure | 0x08 always | `S`,`T3` | L |
| | 5:4 | pixel repetition: 0 none, 1 → ×2, 3 → ×4 | 0 | `S`,`T3` | L (repetition never traced) |
| 0x43 | 7:5 | TMDS-counter window, set by hardware (§8.2). RD writes 0x01 once at init | 0x21 at 297 MHz (2160p 4:2:0, 2160p29.97 RGB), 0x01 at 148.5 MHz | `T3`,`T4`,`S` | C |
| 0x48 | all | TMDS-clock count (§8.2) | 0x13/0x14 | `T3`,`S` | C |
| 0x98 | 1 | interlaced | 0 | `S`,`T3` | L (interlace never traced) |
| | 7:4 | deep-colour code from the source's GCP: 4 = 24 bit, 5 = 30, 6 = 36, other = 24 | 0x48 at 1080p from the Roku (`T3`); 0x08 (no code) at 2160p and in every mode of the PC source (`T4`); 0x00 right after the video logic reset | `S`,`T3`,`T4` | C (4 and 0); U (5, 6) |
| | 3 | — | 1 during measurement | `T3` | U |
| 0x99, 0x9a | | pixel-clock counter (§8.2) | | `S`,`T3` | C |
| 0x9b–0xa8 | | timing registers (§8.1) | | `S`,`T3` | C |
| 0xaa | 3 | source AV mute (GCP Set_AVMUTE state) | 0 | `S`,`T3` | L |
| | 5 | HSYNC polarity, 1 = positive | 1 | `S`,`T3`,`T4`,`D` | L |
| | 6 | VSYNC polarity, 1 = positive | 1 | `S`,`T3`,`T4`,`D` | L |
| | 0 | — | 1 only at 2160p29.97 (0x61; `T4/S43`, `S45`); 0 in the other traced modes (0x60) | `T4` | U |
| 0xb0–0xb9 | | audio status (§2.7) | | | |
| 0xd6 | 3 | HDCP encryption active | never read in traces | `S` | U |

Polarity: all traced modes (VIC 16, 95 and 97) have positive syncs per CTA-861 and read bits 6:5 = 11 (`T3`,`T4`,`D`). No negative-polarity source was traced (open question 24).

### 2.3 Reset, power and PHY control
| Reg | Use | Values | Ev | Conf |
|---|---|---|---|---|
| 0:20, 0:21 | power control | SAVING 0:21 = 0xfb, 0:20 = 0xed; STANDBY and NORMAL 0:21 = 0x40, 0:20 = 0x00 | `T`,`S` | C (values); U (bits) |
| 0:22 | logic resets: bit 0 video logic, bit 1 audio logic (pulse 1→0); bit 3 self-clears; resting value 0x10 | | `T`,`S` | C (values); L (meaning) |
| 0:23 | port-0 resets; resting 0xa0; bits 3:2 pulsed (0xac→0xa0) in the no-5 V entry; bit 1 pulsed in SAVING; bit 4 pulsed in the equaliser reset (§7.9) | | `T`,`S` | C |
| 0:2b | port-1 version of 0:23 | | `T` | C |
| 0:24–0:2a | port-0 calibration (§3.3) and power: 0:25–0:27 = df ff ff in SAVING, 00 otherwise; 0:2a = 0x3a in SAVING, 0x01 otherwise, bit 6 = calibration trigger | | `T`,`S` | C (values); U (bits) |
| 0:2c–0:30, 0:32 | port-1 equivalents (0:32 bit 6 = port-1 trigger; 0x3e in SAVING) | | `T`,`S` | C |
| 0:35 | port select, bit 0; never written | | `T`,`S` | C |
| 0:40 | bits 1:0 = 2 written when sync is lost, 0 when it returns | | `T3` | C (writes); U (meaning) |
| 0:4f | AV-mute control: resting 0x84; bit 5 (with bit 7) set for mute (§7.7) | | `T3`,`S` | C |
| 0:90 | 0x8f written at every stable entry; never read | | `T3` | C (write); U (meaning) |
| 0:ee | bit 7: 0 in SAVING, 1 in STANDBY/NORMAL | | `T` | C |
| 0:f8 | access unlock: 0xc3 then 0xa5 before accessing 1:50–1:5f; RD later writes 0xff or 0x00, or leaves it at 0xa5 | | `T`,`S` | C (sequence); U (meaning) |
| 1:58, 1:5f | 1:58 = 0x03 in SAVING, 0x02 in NORMAL; 1:5f = 0x04 in both | | `T` | C |
| 3:a8, 7:a8 | bit 3: 0 in SAVING, 1 in STANDBY/NORMAL | | `T` | C |
| 3:aa | bits 4:0 oscillator trim (§3.4); bits 6:5 set in STANDBY/NORMAL | | `T` | C |
| 3:ac | bits 1:0: 11 in SAVING, 00 in STANDBY/NORMAL | | `T` | C |
| 3:27–3:29, 7:27–7:29 | static receiver equaliser per channel: 0x9f. No adaptive equalisation runs | | `T`,`S` | C |
| 3:e5 | bits 4:2 equaliser override: cleared in the no-5 V entry; set to 111 after persistent symbol-lock loss (§7.9) | | `T`,`S` | C (clear); L (set) |
| 5:c1–5:cb | power-related; values per mode in §6 | | `T` | C (values) |

### 2.4 Timing measurement and clock counters
Formulas and values in §8.

| Reg | Content | Ev | Conf |
|---|---|---|---|
| 0x9b, 0x9c[5:0] | HTotal low, high | `S`,`T3` | C |
| 0x9d, 0x9e[5:0] | HActive low, high | `S`,`T3` | C |
| 0x9f, 0xa1[0] | HSync width low, bit 8 | `S` | L |
| 0xa0, 0xa1[7:4] | HFrontPorch low, bits 11:8 | `S` | L |
| 0xa2, 0xa3[5:0] | VTotal low, high | `S`,`T3` | C |
| 0xa4, 0xa5[5:0] | VActive low, high | `S`,`T3` | C |
| 0xa6, 0xa8[0] | VSync width low, bit 8 | `S` | L |
| 0xa7, 0xa8[7:4] | VFrontPorch low, bits 11:8 | `S` | L |
| 0x98, 0xaa | interlace, deep colour, sync polarity (§2.2) | `S`,`T3` | L |
| 0x99, 0x9a[2:0] | pixel-clock count (11 bits); 0x9a bit 7 = 1 at rest, cleared while reading | `S`,`T3` | C |
| 0x48, 0x43[7:5] | TMDS-clock count; counter window | `S`,`T3` | C |

Traced porches were < 256, so the upper-bit fields of 0xa1/0xa8 read 0 in every trace. They matter for modes such as 1080p50 (HFrontPorch 528) and 1080p24 (638) per CTA-861. (`S`,`D`; L)

### 2.5 Packet buffers (read only)
| Reg | Content | Ev | Conf |
|---|---|---|---|
| 2:12 | AVI length (0x0d) | `T3`,`S` | C |
| 2:13 | AVI version | `S` | L |
| 2:14 | AVI PB0 (checksum) | `T3`,`D` | C |
| 2:15–2:23 | AVI PB1–PB15 | `T3`,`D` | C |
| 2:43, 2:4a, 2:44–2:49 | audio InfoFrame: version, length, PB0–PB5 | `S` | L |
| 2:24, 2:25… | SPD: type (0x83), then payload | `S` | U |
| 2:da, 2:db, 2:dc–2:f7 | vendor InfoFrame: version, length, payload (OUI at 2:dd–2:df) | `S` | U |
| 2:be–2:c2 | audio N and CTS (§11.3) | `S`,`T3` | C |
| 6:10, 6:11, 6:12 | DRM HB0 (type 0x87), HB1 (version), HB2 (length) | `S` | L |
| 6:13… | DRM PB0 (checksum), PB1… | `S` | L |

Layout check (`D`, `T3/S30`, `S31`, `T4`): with HB = 82 02 0d and PB0 at 2:14, PB1 at 2:15, all five traced AVI frames sum to 0 mod 256. PB0–PB5: Roku 2160p 06 60 a8 00 61 00; Roku 1080p 77 40 a8 00 10 00; PC 1080p60 af 00 28 88 10 00; PC 2160p29.97 60 00 28 88 5f 00; PC 2160p60 82 60 a8 84 61 00. PB6–PB13 = 0 (for the PC frames read from the splitter's copy, `hdmi-splitter.md` §6.7, whose PB0–PB5 are the same).

### 2.6 Output path
| Reg | Field | Meaning and values | Ev | Conf |
|---|---|---|---|---|
| 0:64 | bit 2 | dual-pixel split: 0 = even/odd pixels (RD), 1 = left/right halves | `S` | L |
| | bit 1 | pulsed 1→0 before and after every bus setting (0x81→0x83→0x81) | `T3` | C (writes); U |
| 0:6b | bit 6 | 1 (reset value 0x40) | `T3` | C |
| | 5:4 | input colour format: 0 RGB, 1 YCbCr 4:2:2, 2 YCbCr 4:4:4, 3 YCbCr 4:2:0 (AVI Y). DVI: 1 | `S`,`T3`,`T4` | C (0, 2, 3); L (1) |
| | 3:2 | output colour format, same coding. RD: = input | `S`,`T3`,`T4` | C (0, 2, 3); L (1) |
| | 1:0 | output depth: 0 = 8, 1 = 10, 2 = 12 bit (from 0:98[7:4]) | `S`,`T3` | C (0); U (1, 2) |
| | 0 | 0 = HDMI, 1 = DVI (shares bit 0 with the depth field in RD's usage; RD writes both) | `S` | U |
| 0:6c | 1:0 | colour converter: 0 bypass (RD), 2 RGB→YCbCr, 3 YCbCr→RGB | `S`,`T3` | C (0); U (2, 3) |
| 0:6e | | 0x80 after init; RD's first poll sets bit 1 (0x82); every output enable writes 0xa2 (bit 5 plus that bit 1) | `T`,`S` | C (values); U (bits) |
| 1:70–1:85 | | colour-converter coefficients (22 bytes); RD writes 1:85 = 0 at every output enable, never the others | `S`,`T3` | L |
| 1:86 | | written 0 at every output enable | `T3` | C |
| 1:b0 | 0 | 1 when pixel clock ÷ repetition ≥ 25 MHz | `S`,`T3` | C (1 at 148.5/297 MHz) |
| 1:bd | 5:4 | 00 single pixel, 01 dual pixel (0x05 / 0x15) | `S`,`T3` | C |
| 1:be | | 0x00 at every bus setting | `T3` | C |
| 1:c0 | 0 | dual-pixel output | `S`,`T3` | C |
| | 2:1 | 01 = parallel output path | `S`,`T` | C |
| | 7:6 | 01 from init; selects the 1:c5 unblank value (§10.5) | `S`,`T` | L |
| 1:c1 | 1 | DDR (data on both clock edges): 1 at 2160p29.97 RGB, frames correct | `S`,`T`,`T4/S43`,`S45` | C |
| | 0 | half-bus DDR; never selected | `S` | U |
| | 5 | embedded sync (0 = separate syncs, RD) | `S` | L |
| 1:c4 | | 0x10 for dual-pixel DDR, 0x00 otherwise; init clears bits 7:4 | `S`,`T3`,`T4` | C |
| 1:c5, 1:c6 | | output enable / tristate groups (§10.5); exact bit groups unknown | `S`,`T3` | C (values) |
| 1:fe | 4 | set at every bus setting; 1:fe also holds reference-clock bits (§3.5) | `T` | C (writes) |
| 5:20 | 6 | 1 = internal down-scaler bypassed (set at every bus setting) | `S`,`T3` | L |
| 5:d0, 5:d1, 5:da | | 0xf3; bit 0 = 0 and bits 3:2 = 01; bit 4 = 0 (results 0xf3, 0x04, 0x01); rewritten at every bus setting. Probably settings of an output type this board does not use | `T3`,`S` | C (values); U (meaning) |

### 2.7 Audio
| Reg | Field | Meaning | Observed | Ev | Conf |
|---|---|---|---|---|---|
| 0:81 | 7 | set at init | 0xa0 | `T` | C (value) |
| | 6 | forced sample rate enable (RD clears it at every audio off) | 0 | `S`,`T3` | L |
| 0:86 | 0 | audio output enable; set at the first audio on, never cleared by RD | 0x08 → 0x09 | `S`,`T3` | L |
| | 3:2 | 10 from init | | `T` | C (value) |
| 0:8a | 5:0 | forced sample-rate code | never written | `S` | U |
| 0:8c | 4 | pulsed when audio is requested | | `T3`,`S` | C (writes) |
| | 3 | copy of 0:b2 bit 1, written at the first audio check | | `T3`,`S` | L |
| 0:77, 0:7b, 0:8f | | init values 0x87, bit 4, 0x41 | | `T` | C (values); U (meaning) |
| 0:b0 | 7:4 | audio type: bit 6 high-bit-rate, bit 5 multi-stream, bit 4 3D audio | 0x00 | `S`,`T3` | L |
| 0:b1 | 7 | audio samples present | 0x81 with audio | `S`,`T3` | C |
| | 5:0 | channel-pair layout; channels = 2 × (index of the highest set bit + 1) | bit 0 → 2 ch | `S`,`T3` | L |
| 0:b2 | 1 | channel-status flag, mirrored into 0:8c bit 3 | 0x04 | `S`,`T3` | U |
| 0:b5, 0:b6 | b5[3:0], b6[7:6] | sampling-frequency code from IEC 60958 channel status: code = b5[3:0] \| (b6[7:6] >> 2). 2 = 48 kHz, 0 = 44.1, 3 = 32, 8 = 88.2, 0x0a = 96, 0x0c = 176.4, 0x0e = 192 | b5 = 0x02, b6 = 0x0b → 48 kHz | `S`,`T3` | C (48 kHz) |
| 0:b9 | 7:6 | audio error → audio logic reset | 0x00, 0x10 | `S`,`T3` | L |
| 1:c7 | | audio outputs: 0x00 driven, 0x7f tristated | | `S`,`T3` | C |
| 1:c8–1:ca | | init values 0x00, 0x99, 0x99 | | `T` | C (values); U (meaning) |
| 2:be–2:c2 | | N and CTS (§11.3) | | `S`,`T3` | C |

### 2.8 EDID control
| Reg | Meaning | Ev | Conf |
|---|---|---|---|
| 0:4b | EDID RAM enable: 0xa9 places the RAM at I2C 0xa8 | `T1`,`T3/S20` | C |
| 0:c5, 4:c5 | EDID control, port 0 / port 1: bit 0 cleared after the load (0x03 → 0x02); bit 4 pulsed (1, 1 ms, 0) | `T1`,`T3/S20` | C (writes); U (meaning) |
| 0:c6 | offset of the first physical-address byte within the 256-byte image (RD 0xaf); bank 0 only | `T1`,`S` | C |
| 0:c7, 0:c8 | port-0 physical address bytes AB, CD (RD 0x10 0x00 = 1.0.0.0) | `T1`,`S` | C |
| 4:c7, 4:c8 | port-1 physical address (RD 2.0.0.0) | `T1`,`S` | C |
| 0:c9, 4:c9 | block-0 checksum, served as image byte 0x7f | `T1`,`T3/S20`,`S` | C |
| 0:ca, 4:ca | block-1 checksum for that port's physical address, served as byte 0xff | `T1`,`T3/S20`,`S` | C |

### 2.9 Factory data, oscillator and reference clock
| Reg | Meaning | Ev | Conf |
|---|---|---|---|
| 1:50, 1:51 | factory-data address high, low | `S`,`T` | C (writes) |
| 1:54 | 0x04 starts a read | `S`,`T` | C |
| 1:61, 1:62 | read data (two bytes per address) | `S`,`T` | C |
| 1:57, 1:58, 1:5f | access setup (§3.4) | `T` | C (values) |
| 3:aa[4:0] | oscillator trim | `S`,`T` | C |
| e0:01[6:4] | 4 (see §1.1) | `T` | C (value) |
| 0:91[5:0], 0:92 | reference setting: integer MHz and 1/256 MHz of 1.1 × the assumed reference (§3.5) | `S`,`T` | C (values); U (use) |
| 1:fd | assumed reference in 100 kHz units (revision 0xb1) | `S`,`T` | C (value) |
| 1:fe | reference-related bits (7, 5, 3:0); bit 4 also set at bus settings | `T` | C (values) |
| 0:44–0:47 | rewritten after the reference setting: 0x1a, 0x83, 0x11, 0x07 | `T` | C (values); U (meaning) |

## 3. Initialisation
### 3.1 Preconditions
1. FPGA init done, including the GPIO reset pulses (`init.md` steps 1–11), and ≥ 50 ms elapsed (§1.6).
2. Bus-1 adapter running (`i2c.md`).
3. Recommended, not RD: GPIO 0x040 bit 2 = 0 (HPD low) until the EDID is loaded (§5). RD leaves bit 2 at its previous level during init: 0 after power-up, 1 on a reload. (`T1/S01`,`T3/S20`; C)

### 3.2 Ordered steps (`seq/it6805-init.tsv`)
| # | Step | Rows | `T1/S01` time (ms) | Ev | Conf |
|---|---|---|---|---|---|
| 1 | Read ID (0x00–0x03) and revision (0x04) | 0–4 | 0–1.4 | `T1`,`T3/S20` | C |
| 2 | Fixed register table: resets, PHY, equaliser, output and audio defaults, sub-block enable | 5–115 | 1.7–28.5 | `T1`,`T3/S20` | C |
| 3 | Analog calibration of both ports (§3.3) | 116–188 | 28.7–83.9 | `T1`,`T3/S20`,`S` | C |
| 4 | 0:28 = 0x88; video outputs tristated (1:c5 = 1:c6 = 0xff) | 189–194 | 84.0–85.2 | `T1`,`T3/S20` | C |
| 5 | Factory data read and oscillator trim (§3.4) | 195–210 | 85.4–89.5 | `T1`,`T3/S20`,`S` | C |
| 6 | Sub-block access and reference-clock registers (§3.5) | 211–225 | 89.5–91.9 | `T1`,`T3/S20` | C |
| 7 | EDID RAM (§4) | 226–240 | 92.0–168.0 | `T1`,`T3/S20` | C |
| 8 | Static output path: 1:c0[2:1] = 01, 1:c1 bit 1 = 1, 1:c1 bit 5 = 0 | 241–244 | 168.3–170.3 | `T1`,`T3/S20` | C |
| 9 | 5 V evaluation and end state (§3.6) | 245–246 | 170.4–219.5 | `T1`,`T3/S20` | C |
| 10 | Start polling (§7); RD's first poll sets 0:6e bit 1 | 247 | 295.7 | `T1`,`T3/S20`,`S` | C |

Row numbers refer to the file as published; check the file if they drift. Durations: whole init 219.5 ms (`T1/S01`) and 214.1 ms (`T2/S10`) with no input; 159.9 ms with 5 V present (`T3/S20`; last access, the power and tristate writes ended at 149.5 ms). RD's sleeps are nominal 10 + 10 (calibration triggers), 1 + 1 (EDID control), 2 per HPD request; real sleeps were 9–20 ms each. No minimum is known. RD queues its first poll 10 ms after the init; it ran 76 ms (`T1/S01`) and 121 ms (`T3/S20`) after the init's last access, delayed by other work of RD. (`T1`,`T2/S10`,`T3/S20`; C)

The 1:c1 bit 1 = 1 left by step 8 marks DDR until the first lock rewrites it. RD's FPGA code copies this flag: with no input it writes PIX_MODE = 2 (dual 0, DDR 1), which is the value `video-pipeline.md` lists for no input. (`T1`,`T2`,`S`; L)

### 3.3 Analog calibration (both ports)
Trigger (rows in the file, `T1/S01`,`T3/S20`; C):
1. Port 0 setup in bank 3: 0x3a bit 7 = 0; 0xa0, 0xa1, 0xa2 bit 7 = 1; 0xa4 bit 3 = 1; 0x3b bits 7:6 = 0; 0xa7 bit 4 = 1; 0x48 bit 7 = 1.
2. Port 0 trigger in bank 0: 0:29 bit 0 = 1; 0:2a bits 6 and 0 = 1; 10 ms; 0:2a bit 6 = 0; then 0:24 bit 2 = 1; 0:25–0:28 = 0; 0:3c bit 4 = 0.
3. Port 1 setup: step 1 in bank 7.
4. Port 1 trigger: 0:32 bits 6 and 0 = 1; 10 ms; 0:32 bit 6 = 0; then 0:2c bit 2 = 1; 0:2d–0:30 = 0; 4:3c bit 4 = 0 (no 0:29 equivalent).
5. 3:3a bit 7 = 1, then 7:3a bit 7 = 1.

Measured trigger widths 16.7–20.2 ms.

Wait (X step):
- A port is done when its flags are non-zero: (0:08 & 0x30) for port 0, (0:0d & 0x30) for port 1. Both read 0x10 at the first check in every trace. (`T1/S01`,`T3/S20`; C)
- RD when not done (`S`; L, never exercised): read both flags every 10 ms. After 5 reads without completion, pulse the trigger bit of each unfinished port again (set, 10 ms, clear) and restart the count. After the 6th re-trigger stop waiting; for each port still unfinished clear 3:3a (or 7:3a) bit 7 and pulse its trigger once more. RD then continues the init without an error. Worst case ≈0.4 s with nominal sleeps (RD's real sleeps ran up to twice as long).
- Driver: same bounds; log a calibration failure. The effect of a failed calibration on reception is unknown (U).

Clean-up (`T1/S01`,`T3/S20`; C): RD reads 3:5a, 3:59, 7:5a, 7:59 for a log line only (0xff, 0x8f); W1C 0:08 and 0:0d bits 5:4 (read-modify-write writes 0x30); 0:29 bit 0 = 0; 0:24 bit 2 = 0; 0:3c bit 4 = 1; 0:2c bit 2 = 0; 4:3c bit 4 = 1; 3:3a, 3:a0, 3:a1, 3:a2 bit 7 = 0; same in bank 7.

### 3.4 Factory data and oscillator trim (X steps)
The chip holds a factory-measured oscillator value that RD reads and turns into a 5-bit trim. The trim is unit-specific: compute it, never copy the traced value.

Read (`T1/S01`,`T3/S20` for the sequence and values; `S` for the decoding; C):
1. Setup rows: 0:f8 = 0xc3, 0xa5; 0:34 = 0; bank 1: 5f = 0x04, 5f = 0x05, 58 = 0x12, 58 = 0x02, 57 = 0x01.
2. One read cycle for address (hi, lo): write 1:50 = hi, 1:51 = lo, 1:54 = 0x04, then read 1:61 (byte A) and 1:62 (byte B). No completion poll was used; the data was valid at the next transfer (≈0.1 ms).
3. Cycle (00, 00) and cycle (00, 01). Base = 0x04 if the first returned A = B = 0xff and the second A = B = 0x00; otherwise base = 0x00. Traced: 00 00, then ff ff → base 0x00.
4. Cycle (base, 0xb0) → A0, B0; cycle (base, 0xb1) → A1, B1. Traced: 16 ea, 39 c0.
5. raw = A1 << 16 | B0 << 8 | A0 (traced 0x39ea16). If (B1 & 0xc0) = 0xc0 the value is valid and f = raw / 100, integer, in kHz (traced 37 954). If the flag is not set, or f is outside 25 000–70 000, use f = 43 000.
6. Close: 1:5f = 0x00, 0:f8 = 0x00.

Trim (`D`; L):
- field = clamp(⌊(⌊6 560 000 / f⌋ − 93) / 4⌋, 3, 29), i.e. the nearest integer to 1 640 000 / f − 23.75. Write it with M 3:aa 1f field.
- Traced: f = 37 954 → field 0x13; 3:aa 0xec → 0xf3. Fallback f = 43 000 → 0x0e.
- The formula is ours. RD picks the field from a range table. Over 25 000–65 535 kHz the formula gives RD's field for 62.8 % of the integer f values and differs by one code (either direction) for the rest; never by more. It matches RD for the traced value and for the 43 000 fallback. Both never increase as f rises. For f ≥ 65 536 RD's result is not meaningful (it works on the low 16 bits of f); no such unit has been seen.
- What f represents physically is unknown: RD's counters behave as if the reference were ≈23.4 MHz on this unit (§8.3), which does not follow from f or the trim. (U)

### 3.5 Reference-clock registers
RD programs these from a fixed assumed oscillator of 41 000 kHz and reference of 20 500 kHz (half of it); the factory value only selects the trim. (`T1/S01`,`T3/S20`; C for values · `S` for the derivation; L)
- 0:91 bits 5:0 = 22 and 0:92 = 0x8c: 1.1 × 20 500 kHz = 22 550 kHz, as integer MHz (22) plus the remainder in 1/256 MHz (550 × 256 / 1000 → 0x8c). Bit 6 of 0:91 comes from the fixed table: 0x54 → 0x56.
- 1:fd = 0xcd: 20 500 kHz in 100 kHz units (revision 0xb1 path).
- 1:fe: bit 5 = 0, bits 3:0 = 0xc, bit 4 = 1, bit 7 = 1 (0x00 → 0x9c).
- 0:45 = 0x83, 0:44 = 0x1a, 0:46 = 0x11, 0:47 = 0x07.
- e0:01 bits 6:4 = 4. RD derives the 4 from its assumed oscillator (≤ 49 MHz → 4, above → 5), so with its constant it is always 4. (`T`; C · `S` for the rule; L)

These values gave working 1080p59.94 video and 48 kHz audio. The counter reference measured in the traces is ≈23.4 MHz, not 20.5 MHz (§8.3). Whether these registers ought to carry the true reference, and what depends on them (DDC, HDCP or packet timers), is unknown. Use RD's values. (`T3`; C for the result · U for the meaning)

### 3.6 5 V evaluation and end state
Read 0:13 (RD also checks bit 6, MHL: always 0).
- Bit 0 = 0 (`T1/S01`): `seq/it6805-unplug.tsv`, then `seq/it6805-power-saving.tsv`. Video state NO_5V. RD requests HPD low here; the request is dropped at load. Audio outputs stay driven (1:c7 = 0x00 from the fixed table). (`T1/S01`,`S`; C)
- Bit 0 = 1 (`T3/S20`): `seq/it6805-power-standby.tsv` (RD's power-mode state starts as SAVING, so STANDBY is entered without a preceding SAVING sequence); arm "NORMAL on the next 0:05 bit 1"; video state WAIT_SYNC: tristate (W 1:c5 ff, W 1:c6 ff). RD requests HPD high here; the request is dropped at load. (`T3/S20`,`S`; C)
- Then RD queues the poll (§3.2). Events pending since the reset are handled by the first poll: in `T3/S20` it found 0:05 = 0x01 and 0:06 = 0x40, re-ran the 5 V handler (no power writes, already STANDBY; tristate written again) and requested HPD high; no GPIO write followed, the load pulse (§5) was still running. (`T3/S20`; C)

## 4. EDID RAM
Mechanism (`T1/S01`,`T3/S20`; C · `S` for the physical-address search; L):
1. 0:4b = 0xa9: the RAM answers at I2C 0xa8.
2. Hold HPD low (§5). RD issues HPD-low requests here (2 with no 5 V, 1 with 5 V), each followed by a 2 ms sleep; at load they have no effect.
3. Write image bytes 0x00–0x7e to 0xa8 offsets 0x00–0x7e, one byte per transfer, ascending. Offset 0x7f is not written.
4. ck0 = (−Σ bytes 0x00–0x7e) mod 256. Write 0:c9 = ck0 and 4:c9 = ck0.
5. Write bytes 0x80–0xfe to offsets 0x80–0xfe. Offset 0xff is not written. ck1 = (−Σ bytes 0x80–0xfe) mod 256.
6. Physical address (PA). RD searches only when block 1 starts with `02 03` (CTA-861 extension, revision 3). It walks the data blocks from offset 0x84 up to 0x80 + byte 0x82. The first vendor-specific block (tag 3) whose next three bytes are `03 0c 00` (HDMI OUI) holds the PA at block start + 4. Linux `v4l2_get_edid_phys_addr()` returns the same offset.
7. Port 0: 0:c6 = PA offset; 0:c7, 0:c8 = PA bytes AB, CD; 0:ca = (ck1 + img[PA] + img[PA+1] − 0:c7 − 0:c8) mod 256, the block-1 checksum as it must be with this port's PA in place. Port 1: 4:c7, 4:c8, 4:ca likewise (4:c6 is not written). RD: offset 0xaf, port 0 PA 1.0.0.0, port 1 PA 2.0.0.0. The traced 0:ca and 4:ca differ by 0x10, the difference of the two PAs' first bytes, as the formula predicts.
8. 0:c5 bit 0 = 0, then 4:c5 bit 0 = 0 (both read 0x03 → 0x02). Then 0:c5 bit 4 pulse (1, 1 ms, 0), then 4:c5 likewise (measured 9–13 ms).

- Timing: 254 single-byte writes took 24–25 ms. (`T1/S01`,`T3/S20`; C)
- The checksums live in registers. Bytes 0x7f and 0xff are never written to the RAM, yet the splitter's DDC read of this EDID through TX port 1 returned the RD image with ck0 and ck1 at 0x7f and 0xff. (`T3/S20`; C)
- With no source attached the IT6805 did not answer DDC at all (splitter reads ended in no-ACK; `hdmi-splitter.md`). The EDID can be read back over DDC only while the input has 5 V. (`T1/S01`; C)
- The chip presumably substitutes each port's PA (0:c7/0:c8) at the PA offset on DDC reads. Not observable: the port-0 PA equalled the stored bytes. Write the image's own PA bytes to 0:c7/0:c8; then nothing depends on substitution. (U)
- With no PA found RD writes none of 0:c6–0:ca, which leaves block 1 without a checksum. A driver loading an image without an HDMI VSDB must still write 0:ca = ck1 (and 4:ca). (`S`; UNVERIFIED: needs an EDID without a VSDB read back over DDC)
- The RAM is addressed with an 8-bit offset: 256 bytes, two blocks. Whether the chip supports E-DDC segments for longer images is unknown; use two blocks. (`T`,`S`; L)
- What the source sees: the splitter copies this EDID into its own RAM (`hdmi-chips.md`, EDID policy). Content policy (own image, verified modes only, no deep colour or 2160p until verified) is in `hdmi-chips.md`; open question 19. Do not reuse RD's image.
- To change the EDID at runtime: HPD low (§5); steps 1–8; HPD high. RD does this only at init and resume. (`S`; L)

## 5. Hot-plug detect (HPD)
| Item | Fact | Ev | Conf |
|---|---|---|---|
| Line | FPGA GPIO 0x040 bit 2 drives the HPD input of splitter TX port 1, i.e. the IT6805 side. No IT6805 register is involved: RD's HPD requests only raise an event that the board code maps to this bit | `S`,`T3/S20`,`S30`,`S31` | C |
| Polarity | 1 = asserted (high). TX port 1 latched its HPD event 84–104 ms after bit 2 went high (`hdmi-splitter.md` §2.2). The fall latency is unmeasured (open question 23). Evidence: `hdmi-chips.md`, `hdmi-splitter.md` | `T3` | C (rise); U (fall) |
| Access | read-modify-write of 0x040; preserve the other bits | `T`,`S` | C |
| Load pulse | after the IT6805 init RD writes bit 2 = 1, waits 10 ms, writes 0, waits 100 ms, writes 1 (measured 16.0–19.2 ms and 108.1–108.2 ms; `T1/S01` 240.6/259.3/367.5 ms, `T2/S10` 232.2/251.4/359.5 ms, `T3/S20` 181.8/199.6/307.7 ms, `T4/S40` −1754.8/−1738.8/−1630.6 ms, i.e. before its first captured transfer). End state 1, even with no input | `T1/S01`,`T2/S10`,`T3/S20`,`T4/S40` | C |
| 5 V loss | bit 2 = 0, written twice 9.4 ms apart (`T3/S30` 22055.1/22064.5, `S31` 29731.0/29740.4), before the no-5 V entry | `T3/S30`,`S31` | C |
| 5 V return | bit 2 = 1, written once, after the STANDBY sequence, 5.5–7.5 ms after the 0:05 read (`T3/S30` 31292.5, `S31` 33555.6) | `T3/S30`,`S31` | C |
| During init | RD's requests are dropped (no GPIO write during IT6805 init) | `T1/S01`,`T3/S20` | C |
| Unload, suspend | no write; bit 2 keeps its level | `T3/S36`,`S` | C (unload); L (suspend) |
| Other RD triggers | EDID reload at resume; full logic reset (§7.9) | `S` | L |

Driver rules (derived from RD's intent; `D`; L):
- HPD low while loading or changing the EDID, and while the receiver is in SAVING.
- HPD high after the EDID is loaded and the receiver is in STANDBY or NORMAL.
- To force the splitter to re-read the EDID, keep HPD low ≥ 100 ms (RD's pulse); a shorter pulse is untested.
- Bit 10 of the same register is an input that may signal pending chip events (open question 21); poll the IT6805 regardless.

## 6. Power modes
Three modes, selected by port-0 5 V and by the TMDS clock arriving. Sequences: `seq/it6805-power-*.tsv`. (`T1/S01`,`T3/S20`,`S30`,`S31`,`S`; C)

| Register | SAVING | STANDBY | NORMAL |
|---|---|---|---|
| 0:23 | bit 1 pulse | — | — |
| 0:25 / 0:26 / 0:27 | df / ff / ff | 00 / 00 / 00 | 00 / 00 / 00 |
| 0:2a | 3a | 01 | 01 |
| 0:2d / 0:2e / 0:2f / 0:32 (port 1) | ff / ff / ff / 3e | — | — |
| 0:ee bit 7 | 0 | 1 | 1 |
| 0:f8 | c3, a5 (left unlocked) | — | c3, a5 (left unlocked) |
| 1:5f / 1:58 | 04 / 03 | — | 04 / 02 |
| 3:a8 bit 3 | 0 | 1 | 1 |
| 3:aa bits 6:5 | — | 11 | 11 |
| 3:ac bits 1:0 | 11 | 00 | 00 |
| 5:c1, 5:c2 bits 1:0 | 0 | — | 0 |
| 5:c6 bit 5 | 0 | — | 1 |
| 5:c7 | 80 | — | 00 |
| 5:c8 / 5:c9 / 5:ca | 00 | — | 00 |
| 5:cb bits 3:0 | 0 | — | 0 |
| 7:a8 bit 3 (port 1) | 0 | — | — |
| 0:21 / 0:20 | fb / ed | 40 / 00 | 40 / 00 |

"—" = not written; the value from the previous mode stays (bank 5 and 1:58 keep their SAVING values through STANDBY).

| Transition | Condition (RD) | Traced | Ev | Conf |
|---|---|---|---|---|
| → SAVING | port-0 5 V absent: at init, or 0:05 bit 0 with 0:13 bit 0 = 0 | `T1/S01` init; `T3/S30` 22081; `S31` 29758 | `T`,`S` | C |
| SAVING → STANDBY | 5 V present (init, the NO_5V state's poll of 0:13, or 0:05 bit 0) and the current mode is SAVING. Every 5 V-on also arms "NORMAL on the next 0:05 bit 1" | `T3/S20` init; `S30` 31288; `S31` 33552 | `T`,`S` | C |
| STANDBY → NORMAL | first 0:05 bit 1 while armed; then disarmed | `T3/S20` 4298; `S30` 32503; `S31` 38124; `T4/S40` 700.7 | `T`,`S` | C |
| none | sync lost and found with 5 V held | `T3/S31` 24713–27455; all 6 `T4` mode changes (§7.9) | `T` | C |
| → NORMAL | link-mode (MHL) change: 0:07 bit 3 with 0:13 bit 6 = 1 | never | `S` | L |

- Port 1 keeps its SAVING values after the first SAVING entry; STANDBY and NORMAL touch port-0 registers only. (`S`,`T`; C)
- STANDBY → NORMAL took 4.2 s (`S20`), 1.2 s (`S30`) and 4.6 s (`S31`). The delay is set by the splitter bring-up, not by the IT6805 (`hdmi-chips.md`). (`T3`; C)

## 7. Runtime
### 7.1 Poll loop
- RD re-queues its poll 50 ms after each cycle ends (20 ms after a resume). Measured interval in `T3/S30`: median 64.5 ms, 10–90 % range 62.4–67.8 ms, minimum 57.6 ms; in `T4/S42`, `S43` (STABLE, no audio): median 63.9 ms, 10–90 % 60.0–64.5 ms. A cycle containing the stable entry takes ≈0.3 s (§7.6); other work of RD delayed single cycles by up to 0.7 s (`T3/S20` 416–1108 ms). (`S`,`T3`; C)
- Transfers per cycle, bank selects included: NO_5V 9 (24 every 4th cycle); WAIT_SYNC 38 (53 every 4th); STABLE 56 (61 every 4th with audio ON; 68 every 3rd while audio waits in WAIT_READY, §11.1). (`T1/S01`,`T3`,`T4`; C)
- RD's IT6805 code has no unbounded register wait; its only loop, the calibration wait, gives up after ≈0.4 s (§3.3). RD has no timeout for "5 V but no sync": it stays in WAIT_SYNC indefinitely. Driver: keep polling, report "no signal" while waiting, and give every wait it adds its own limit. (`S`,`T3`; L)

### 7.2 Poll order (RD)
| # | When | Accesses (bank 0 unless noted) | Ev | Conf |
|---|---|---|---|---|
| 1 | first cycle after init | M 0:6e 02 02 | `T1`,`T3/S20` | C |
| 2 | STABLE | DRM check: read 0:12, write back `value & 0x20`; read 6:10 (§9.2) | `T3`,`S` | C |
| 3 | not NO_5V | read and write back 0:05, 0:06, 0:08, 0:09; read 0:13, 0:14, 0:15; handle (§7.4) | `T3`,`S` | C |
| 4 | not NO_5V | read and write back 0:10, 0:11 (`& 0xbf`), 0:12 (`& 0x7f`), 0:1d, 0:d4, 0:d5; handle (§7.4) | `T3`,`S` | C |
| 5 | always | read 0:0a, write back `& 0x01` | `T`,`S` | C |
| 6 | NO_5V | read 0:13; bit 0 = 1 → 5 V handler | `T1`,`S` | C |
| | WAIT_SYNC | read 0:19; bit 7 = 1 → DEBOUNCE | `T3`,`S` | C |
| | NO_5V, WAIT_SYNC | then read 0:07, write back `& 0x08`; bit 3 → link-mode check | `T`,`S` | C |
| | DEBOUNCE | count down (no access); at 0 → stable entry (§7.6) | `T3`,`S` | C |
| | STABLE | read 0:4f; AV-mute release check (§7.7) | `T3`,`S` | C |
| 7 | always | audio state step (§11) | `T3`,`S` | C |
| 8 | STABLE every cycle, other states every 4th | lock-report reads 0:9e, 0:9d, 0:a5, 0:a4, 0:6b; bank 1 select with no access; 0:b0, 0:b1 | `T`,`S` | C |

### 7.3 Event write-back rules
| Register | Write-back | Ev | Conf |
|---|---|---|---|
| 0:05, 0:06, 0:08, 0:09, 0:10, 0:1d, 0:d4, 0:d5 | the value read | `T3` | C |
| 0:11 | `value & 0xbf` (bit 6 left pending; never seen set) | `S`,`T3` | C |
| 0:12 | `value & 0x7f` in step 4; bit 7 is cleared by writing 0x80 after reading 0:1a and 0:1b (§7.4); in the DRM step `value & 0x20` | `T3` | C |
| 0:07 | `value & 0x08` (bits 0/1 stay set) | `T3` | C |
| 0:0a | `value & 0x01` | `S`,`T` | C |

Traced pairs: 0:12 read 0x91 → wrote 0x11, then 0x80; 0:12 read 0x80 → wrote 0x00; 0:07 read 0x03 → wrote 0x00. Explicit 0:12 = 0x80 writes: 3 in `S20`, 3 in `S30`, 8 in `S31`. (`T3`; C)

### 7.4 Event handling (RD)
| Event | Action | Ev | Conf |
|---|---|---|---|
| 0:05 bit 0, 0:13 bit 0 = 0 | HPD low (§5); `seq/it6805-unplug.tsv`; SAVING; state NO_5V | `T3/S30`,`S31`,`S` | C |
| 0:05 bit 0, 0:13 bit 0 = 1 | if SAVING: STANDBY; arm NORMAL; state WAIT_SYNC (tristate); HPD high | `T3/S30`,`S31`,`S` | C |
| 0:05 bit 1 | reset the ECC counter; if NORMAL is armed: NORMAL, disarm | `T3`,`S` | C |
| 0:05 bit 2 | reset the symbol-loss counters; read 0:13 | `S` | L |
| 0:05 bit 4 | see §2.1 | `S` | L |
| 0:05 bit 5, 0:06 bits 4–6 | counters; §7.9 | `S` | L |
| 0:08 bit 0 | state WAIT_SYNC | `S` | L |
| 0:08 bit 7 | M 0:4c 80 80 | `S` | L |
| 0:10 bit 1 | read 0:19; compare bit 7 with the stored value; act only on a change (the event also fires once after each video logic reset with sync unchanged, §2.1: `T3/S20` 4985, `S30` 33200, `S31` 28147, 38808, and after all 7 `T4` entries). On: M 0:40 03 00, state DEBOUNCE (count 4). Off: M 0:40 03 02, state WAIT_SYNC (tristate), audio off (§11) | `T3`,`T4`,`S` | C |
| 0:10 bit 4, STABLE | AV mute on (§7.7) | `T3/S31`,`S` | L |
| 0:10 bit 5, STABLE | AV mute off (§7.7) | `S` | L |
| 0:10 bit 7, STABLE | audio logic reset, then audio enable (§11) | `S` | L |
| 0:12 bit 0 | read 2:14, 2:15; before STABLE store them; while STABLE a difference marks the AVI as changed (§7.8) | `T3`,`S` | C |
| 0:12 bit 5 | DRM flag (§9.2) | `S` | L |
| 0:12 bit 7 | read 0:1a, 0:1b; write 0:12 = 0x80; read 0:9e, 0:9d; while STABLE §7.8 | `T3`,`S` | C |
| 0:1d bit 3 | read 0:d6 (log) | `S` | L |
| 0:0a bit 0 | port-1 5 V: ignored on GC573 | `S` | L |

### 7.5 Video state machine
| State | Entry actions | Leave when | Next | Ev | Conf |
|---|---|---|---|---|---|
| NO_5V | `seq/it6805-unplug.tsv`: 3:e5[4:2] = 0; W1C 0:08 = 0x04, 0:0d = 0x04; audio-logic pulse 0:22 = 0x12 → 0x10; port resets 0:23 and 0:2b = 0xac → 0xa0; tristate. Clears all video and audio flags | 5 V: 0:13 bit 0 polled, or 0:05 bit 0 | WAIT_SYNC via the 5 V handler | `T`,`S` | C |
| WAIT_SYNC | tristate (1:c5 = 1:c6 = 0xff); clear the stable flags | 0:19 bit 7 = 1 (polled), or the 0:10 bit 1 handler with sync on | DEBOUNCE | `T3`,`S` | C |
| DEBOUNCE | count = 4 | count reaches 0: the stable entry runs in the 4th poll after the one that saw sync (246–266 ms after the sync-on write in all 11 traced locks, 4 in `T3`, 7 in `T4`) | STABLE | `T3`,`T4`,`S` | C |
| STABLE | stable entry (§7.6) | sync off (0:10 bit 1) → WAIT_SYNC; 5 V off → NO_5V; 0:08 bit 0 → WAIT_SYNC | | `T3`,`S` | C |

- After a 5 V loss RD runs the NO_5V entry and then, in the same poll, handles the sync-off event, which moves it to WAIT_SYNC. It then polls all event registers until 5 V returns. Harmless. (`T3/S30` 22077–22094; C)
- A sync loss during DEBOUNCE returns to WAIT_SYNC (`S`; L). Driver: also require 0:13 bit 0 and bits 3/4 set and 0:14 bits 5:3 = 111 before the stable entry (all held at every traced entry; `T3`,`T4`; C for the observation, L as a rule).

### 7.6 Stable entry (`seq/it6805-lock*.tsv`)
Runs once per lock. One table per bus mode (§10.2): `it6805-lock.tsv` single SDR, `it6805-lock-dual-sdr.tsv`, `it6805-lock-dual-ddr.tsv`. RD order (`T3/S20` 4557–4855, `S30` 32766–33068, `S31` 27718–28016 and 38385–38680; the 7 `T4` entries listed under Conventions; C):
1. 0:90 = 0x8f (purpose unknown; replay it).
2. Measurement (§8): RD samples the TMDS counter (10 × 10 ms) and the pixel counter (5 × 3 ms), then reads the timing registers. Only the timing registers are needed, plus a coarse clock class (§10.1).
3. 1:b0 bit 0 from the pixel clock (§10.2).
4. Read the AVI InfoFrame (§9.1).
5. Output-bus setting (§10.2). Its 0:6b write carries the output colour of the previous lock (none at the first lock after a load); step 6 writes the final value while the outputs are still tristated. A driver can write the new value here.
6. Output enable: colour format, converter bypass, depth (§10.3).
7. AV mute on: 0:4f bits 7, 5 = 1; 1:c5 bit 7 = 1.
8. Audio off (state REQUEST): 0:81 bit 6 = 0; 1:c7 = 0x7f.
9. Video logic reset: 0:22 bit 0 = 1, ≥ 1 ms (measured 9–13 ms), = 0. Then M 0:10 02 02 (clears every pending 0:10 bit) and M 0:12 80 80.
10. Unblank (§10.5): 1:c5 bit 7 = 0, 1:c6 bit 7 = 0; single pixel: 1:c5 = 0x18; dual pixel: 1:c6 = 0x00.
11. Audio WAIT_READY: 0:8c bit 4 pulse (§11).

Step 1 to step 10 took 293–305 ms in RD (`T3/S20` 297.7, `S30` 301.5, `S31` 297.3 and 293.5; `T4` 293.3–304.2), nearly all of it the counter sleeps of step 2. After the video logic reset, 0:12 bit 7 reads 1 again at the next poll; RD ignores this first event after an entry (§7.8). (`T3`; C)

### 7.7 AV mute
- On (RD), at every stable entry and on 0:10 bit 4 while STABLE: M 0:4f a0 a0 (0x84 → 0xa4); M 1:c5 80 80. (`T3`,`T4`; C)
- Release (RD), checked every STABLE poll: when 0:4f bit 5 = 1 and the source AV mute 0:aa bit 3 = 0:

  | op | reg | mask | value | note |
  |---|---|---|---|---|
  | M | 1:c5 | 01 | 01 | |
  | M | 1:c5 | 01 | 00 | |
  | M | 1:c5 | 01 | 01 | dual pixel only (1:c0 bit 0 = 1) |
  | M | 0:4f | a0 | a0 | |
  | M | 0:4f | a0 | 80 | 0xa4 → 0x84 |

  Traced: single pixel 1:c5 18 → 19 → 18 (`T3/S31` 38746; `T4/S41` 92961, `S44` 3320, `S45` 9250); dual 7f → 7e → 7f (`T3/S20` 4920.9–4922.2, `S30` 33136; `T4/S40` 1315, `S43` 91698, `S44` 52181, `S45` 1941). `T4` times are those of the final 0:4f write. First release one poll after the stable entry (≈65 ms; 65–69 ms after the unblank in `T4`). (`T3`,`T4`; C)
- The source's AV mute clears only after the splitter unmutes TX port 1 (`hdmi-chips.md`, cross-chip rules). Until then 0:aa bit 3 stays 1 and the output stays muted. (`T3`,`T4`; C for the order in 11 of 11 locks.) In every traced lock the Clear_AVMUTE arrived before the stable entry, so the release ran at the first STABLE poll.
- RD's release does not clear 1:c5 bit 7. After a source AV mute while STABLE, 1:c5 bit 7 would stay set until the next stable entry; this never happened in the traces. Driver: after the release, rewrite the unblank value of §10.5. UNVERIFIED: needs a source that toggles AV mute while locked. (`S`; U)

### 7.8 Changes while STABLE
- AVI change (0:12 bit 0 with a new 2:14/2:15): RD reconfigures in the next poll: re-measure, re-read AVI, 1:b0, bus setting, output enable, video logic reset, unblank. No AV-mute cycle. (`S`; L, never traced)
- Parameter change (0:12 bit 7): the first one after a stable entry is self-induced (video logic reset) and ignored. For a later one RD distinguishes two cases. If a reconfiguration has run since the stable entry, it reconfigures when HActive (0x9d/0x9e) changed, or 0:1a & 0x4a ≠ 0, or 0:1b & 0x02 ≠ 0. Otherwise it re-evaluates only the DDR rule (§10.1; this rewrites 1:c0[2:1], 1:c1 and 1:c4) and reconfigures only if DDR is now required; in that re-evaluation HActive = 2880 also counts as SDR. (`S`,`T3` for the self-induced event; L)
- In the traces every source mode change went through sync loss: `T3/S31` (sync lost at 24713, found at 27455, new stable entry at 27718) and all 6 GPU mode changes of `T4` (§7.9). The AVI-change and parameter-change paths above were never exercised. (`T3`,`T4`; C)
- Driver: while STABLE, re-read the timing registers on 0:12 bit 7 or bit 0; if HTotal, VTotal, HActive, VActive, interlace or AVI Y differ from the values programmed, run the stable entry again and emit a source change. Mode change while streaming is untested (open question 24). (`D`; U)

### 7.9 Loss, re-lock and recovery
| Case | Events and status | RD actions | Ev | Conf |
|---|---|---|---|---|
| Sync loss, 5 V held | 0:12 bit 7; 0:05 = 0x0c; 0:10 = 0x52; 0:13 0xbf → 0x01; 0:14 → 0x03 | AV mute on (0:10 bit 4); sync off: 0:40 = 2, WAIT_SYNC, tristate, audio off. No power change | `T3/S31` 24713 | C |
| Signal returns, 5 V held | 0:05 = 0x56; 0:06 = 0x01; 0:13 → 0xbd; 0:14 → 0x39; 0:10 = 0x56; 0:12 = 0x91; 0:19 = 0xbe | no power change; sync on: 0:40 = 0, DEBOUNCE; stable entry 4 polls later | `T3/S31` 27455 | C |
| 5 V loss | 0:05 bit 0 (0x05, 0x0d); 0:06 = 0xf1; 0:13 bit 0 = 0; 0:10 = 0xc2, read later in the same poll | HPD low; NO_5V entry; SAVING; then sync-off handling | `T3/S30` 22051; `S31` 29728 | C |
| 5 V return | 0:05 = 0x01; 0:13 = 0x01 | STANDBY; WAIT_SYNC; HPD high | `T3/S30` 31285; `S31` 33550 | C |
| TMDS arrival after a 5 V return | 0:05 = 0x56 (0x16 in `T4/S40`); 0:06 = 0x01; 0:13 → 0xbd (0xbf at the first signal after a load: `T3/S20`, `T4/S40`); then in the same poll 0:10 = 0x12 or 0x16, 0:12 = 0x91 (0x81 in `T4`), 0:19 = 0xbe | NORMAL, then sync on as above | `T3/S20` 4296; `S30` 32501; `S31` 38122; `T4/S40` 698 | C |
| Sync loss at a source mode change, 5 V held (PC source) | in one poll: 0:05 = 0x4c or 0x4e; 0:06 = 0xf1; 0:07 = 0x07; 0:10 = 0x02 (no Set_AVMUTE); 0:13 0xbf → 0x01 (0x21 once); 0:14 → 0x01; 0:19 = 0x20 or 0x30. Once (`T4/S41` 91428) the poll before already read 0:19 = 0x20 with 0:13 = 0xbf and no event | sync off: 0:40 = 2, WAIT_SYNC, tristate, audio off. No power change, no HPD write | `T4/S41` 91492, `S43` 90078, `S44` 1860, 50594, `S45` 262, 7812 | C |
| Signal returns after the mode change (PC source) | 0.81–1.06 s after the loss, in one poll: 0:05 = 0x56; 0:06 = 0x01; 0:13 = 0xbd; 0:14 = 0x39 (1080p) or 0x3b (2160p); 0:10 = 0x12 or 0x16; 0:12 = 0x81; 0:19 = 0xbe (0xbc once). Then 0:13 → 0xbf at the first poll after the splitter's TX port 1 unmute (64–68 ms after TMDS) and Clear_AVMUTE (0:10 = 0x20, 0x24) one poll later | sync on in the same poll: 0:40 = 0, DEBOUNCE. Stable entry 248–265 ms after sync on, unblank 293–304 ms after the entry, AV-mute release one poll later (§7.7). Loss to release 1.43–1.67 s. No power change | `T4/S41` 92318, `S43` 91084, `S44` 2699, 51562, `S45` 1324, 8629 | C |
| ECC errors | more than 10 ECC events (0:05 bit 5) count one round; action at the 3rd round. The event count restarts on 0:05 bit 1, on 0:09 bit 0 or 3, and at the no-5 V entry | equaliser reset: 3:2c = 0, 3:2d = 7, 0:07 = 0xff, 0:23 = 0xb0, 1 ms, 0:23 = 0xa0, 3:27–3:29 = 0x9f, 3:22 = 0, 3:4b bit 7 = 0; then full logic reset: HPD low, 0:08 = 0x04, 0:22 = 0x12 → 0x10, 0:23 = 0xac → 0xa0; then the 5 V handler | `S` | L (never traced) |
| Persistent symbol-lock loss | all three channel counters (0:06 bits 4–6) above 20, HDMI 1.x, no override yet; the counters restart on 0:05 bit 2 | 3:e5 bits 4:2 = 111 | `S` | L (never traced) |

- The Roku source switch (`T3/S31` 24713) and the GPU mode changes (`T4`) differ only in the events: at the loss 0:05 = 0x0c, 0:10 = 0x52 (Set_AVMUTE first) and 0:14 = 0x03 in `T3`; at the return 0:10 = 0x56 and 0:12 = 0x91. RD wrote the same registers. (`T3`,`T4`; C)
- The timing registers keep their last values after a loss (`T3/S30`: 1920 × 2160 read with no signal) and read garbage before the first lock (`T1/S01`: HActive 180). Read them only in STABLE. (`T`; C)
- No adaptive equalisation runs; the static values and the calibration are the only link training. HDMI 2.0 rates (> 340 MHz, scrambling) need no host action in RD and were never traced. (`S`,`T`; C for the traces, U for HDMI 2.0)
- The recovery paths are code-only. If implemented, bound them: at most one full logic reset per few seconds, and report "no signal" while recovering. (`D`; U)

### 7.10 Lock reporting
RD's "locked" = STABLE and the stable entry done. Lock is reported at the start of the poll after the entry. Unlock is latched only after 3 further unstable polls, i.e. ≈250–290 ms after the loss at the traced poll rate. For V4L2: emit `V4L2_EVENT_SOURCE_CHANGE` at unblank and on leaving STABLE; stop streaming on unlock (`hdmi-chips.md` driver notes). (`S`,`T3`; L)

## 8. Video timing measurement
### 8.1 Timing registers
Valid in STABLE only (§7.9). Bank 0.

| Quantity | Formula | 1080p59.94 (`T3/S31`) | 2160p59.94 4:2:0 (`T3/S30`) | 2160p29.97 RGB (`T4/S43`,`S45`) |
|---|---|---|---|---|
| HTotal | 0x9b + 256 × (0x9c & 0x3f) | 2200 | 2200 | 4400 |
| HActive | 0x9d + 256 × (0x9e & 0x3f) | 1920 | 1920 | 3840 |
| HFrontPorch | 0xa0 + 256 × (0xa1 >> 4) | 88 | 88 | 176 |
| HSync | 0x9f + 256 × (0xa1 & 1) | 44 | 44 | 88 |
| HBackPorch | HTotal − HActive − HFrontPorch − HSync | 148 | 148 | 296 |
| VTotal | 0xa2 + 256 × (0xa3 & 0x3f) | 1125 | 2250 | 2250 |
| VActive | 0xa4 + 256 × (0xa5 & 0x3f) | 1080 | 2160 | 2160 |
| VFrontPorch | 0xa7 + 256 × (0xa8 >> 4) | 4 | 8 | 8 |
| VSync | 0xa6 + 256 × (0xa8 & 1) | 5 | 10 | 10 |
| VBackPorch | VTotal − VActive − VFrontPorch − VSync | 36 | 72 | 72 |
| Interlaced | 0x98 bit 1 | 0 | 0 | 0 |
| H / V sync positive | 0xaa bit 5 / bit 6 | 1 / 1 | 1 / 1 | 1 / 1 |

- The columns match CTA-861 VIC 16, VIC 97 (horizontal values halved for 4:2:0) and VIC 95 (`D`). HTotal 4400 uses 0x9c bit 4. The PC source's 1080p60 and 2160p60 4:2:0 read the same values as the `T3` columns (`T4`). (`T3`,`T4`,`S`; C)
- 4:2:0 input: horizontal values count TMDS clocks, half the pixels; multiply by 2 for the picture (RD doubles HActive). (`T3/S30`,`S`; C)
- Interlaced input: RD doubles the field height. Pixel repetition (0:1b[5:4]): RD divides. Neither was traced; UNVERIFIED (open question 24). (`S`; U)
- RD programs no sync polarity anywhere (IT6805 output or FPGA); it only reads 0:aa. Negative-polarity sources are UNVERIFIED (open question 24). (`S`,`T3`; U)

### 8.2 Clock counters
- Pixel clock: per sample, M 0:9a 80 00; read 0:9a and 0:99; M 0:9a 80 80. count = (0:9a & 7) << 8 | 0:99 = reference cycles per 512 counted clocks, so f = f_ref × 512 / count. RD takes 5 samples 3 ms apart: f = f_ref × 2560 / Σcount. For 4:2:0 the counted clock is the TMDS clock (half the pixel rate). (`S`,`T3`; C)
- TMDS clock: per sample read 0:48; RD sums (value + 1) over 10 samples 10 ms apart. The window is 128 × 2^k TMDS clocks, with k = 3 if 0:43 bit 7, else 2 if bit 6, else 1 if bit 5, else 0; the hardware sets these bits. f_TMDS = f_ref × 128 × 2^k × 10 / Σ(value + 1). (`S`,`T3`; C)
- Traced counts: 1080p59.94 pixel 0x51/0x52 (Σ 405, 407), TMDS 0x13 (Σ(value + 1) 200, 201; 0:43 = 0x01, window 128); 2160p 4:2:0 pixel 0x28/0x29 (Σ 200, 204), TMDS 0x13/0x14 (Σ 201, 202; 0:43 = 0x21, window 256). (`T3/S20`,`S30`,`S31`; C) PC source: 1080p60 RGB pixel Σ 405, 405, 409, TMDS Σ 200, 200, 201 (0:43 = 0x01); 2160p60 4:2:0 pixel Σ 201, 204, TMDS Σ 203, 204; 2160p29.97 RGB pixel Σ 203, 202, TMDS Σ 200, 203 (both 0:43 = 0x21). (`T4`; C)

### 8.3 Do not take the frame rate from the IT6805
- RD assumes f_ref = 20 500 kHz (§3.5). The traced counts at known rates give f_ref = 23.2–23.7 MHz on this unit, about 23.4 MHz. Roku (`T3`): from 1080p59.94 (148.35 MHz) the pixel counts give 23.47 and 23.59 MHz and the TMDS counts 23.18 and 23.30 MHz; from 2160p 4:2:0 (296.70 MHz TMDS) 23.18–23.64 MHz. PC source (`T4`, clocks from 0x1010): 1080p60 (148.52 MHz) 23.21–23.73 MHz, 2160p60 4:2:0 (297.03 MHz TMDS) 23.32–23.67 MHz, 2160p29.97 (296.73 MHz) 23.18–23.53 MHz; mean of the 14 `T4` samples 23.45 MHz. (`T3`,`T4`,`D`; C)
- So every RD clock figure is ≈0.876 × the true value: 129.58 MHz instead of 148.35 at 1080p, 257.25 instead of 296.70 at 2160p, 258.5–259.8 instead of 296.73 at 2160p29.97 (`T4`). RD's frame rate, pixel clock / (HTotal × VTotal) rounded, comes out as 52 Hz for 59.94 Hz input in both modes, which is what RD reported. (`T3`,`S`,`D`; C)
- Even with a calibrated f_ref, one count is 1.2 % (1080p) or 2.5 % (2160p 4:2:0) of a pixel-counter sample, and 0.25 % / 0.5 % of RD's 5-sample sum: too coarse to tell 60 Hz from 59.94 Hz (0.1 %). The spread between units is unknown. (`D`; C)
- Frame rate: FPGA IN_FRAME_PERIOD 0x1010 (`video-pipeline.md`): 0x0019745b → 59.945 Hz in both modes (`T3/S21`–`S26`, `S32`); PC source 0x00196dad–0x00196daf → 60.0068 Hz at 1080p60 and 2160p60, 0x0032e886 → 29.9731 Hz at 2160p29.97 (`T4`). Pixel clock: HTotal × VTotal × frame rate (2200 × 1125 × 59.945 = 148.36 MHz). (`T3`,`T4`; C)
- The IT6805 counters remain usable for coarse decisions before the output runs, e.g. 148.5 vs 297 MHz (§10.1), using f_ref ≈ 23.4 MHz or a value calibrated against 0x1010 at a previous lock. (`D`; L)

## 9. InfoFrames
### 9.1 AVI (bank 2)
Field decoding follows CTA-861 (`D`). RD uses Y, C, EC, Q, VIC and YQ. (`S`,`T3`; C for the traced fields)

| Byte | Reg | Bits | Field |
|---|---|---|---|
| PB1 | 2:15 | 6:5 | Y colour format: 0 RGB, 1 4:2:2, 2 4:4:4, 3 4:2:0 |
| PB2 | 2:16 | 7:6 | C colorimetry: 0 none, 1 BT.601, 2 BT.709, 3 extended (see EC) |
| | | 5:4 | picture aspect ratio |
| PB3 | 2:17 | 7 | ITC: IT content (RD ignores it) |
| | | 6:4 | EC extended colorimetry; 5 or 6 = BT.2020 |
| | | 3:2 | Q RGB quantisation: 0 default, 1 limited, 2 full |
| PB4 | 2:18 | 7:0 | VIC (RD keeps only bits 6:0, which misreads VIC ≥ 128; use all 8 bits) |
| PB5 | 2:19 | 7:6 | YQ YCbCr quantisation: 0 limited, 1 full |
| | | 3:0 | pixel repetition |

| Input | PB0–PB5 | Decoded |
|---|---|---|
| 2160p59.94 (`T3/S20`,`S30`) | 06 60 a8 00 61 00 | YCbCr 4:2:0, BT.709, 16:9, EC 0, Q default, VIC 97, YQ limited |
| 1080p59.94 (`T3/S31`) | 77 40 a8 00 10 00 | YCbCr 4:4:4, BT.709, 16:9, VIC 16 |
| 1080p60, PC source (`T4/S41`,`S44`,`S45`) | af 00 28 88 10 00 | RGB, no colorimetry, 16:9, IT content, Q full, VIC 16 |
| 2160p29.97, PC source (`T4/S43`,`S45`) | 60 00 28 88 5f 00 | RGB, no colorimetry, 16:9, IT content, Q full, VIC 95 |
| 2160p60, PC source (`T4/S40`,`S44`) | 82 60 a8 84 61 00 | YCbCr 4:2:0, BT.709, 16:9, IT content, EC 0, Q limited (unused for YCbCr), VIC 97, YQ limited |

- RGB default range: RD treats Q = 0 as limited unless VIC < 2 (then full), which matches CTA-861's default for VIC 1 and IT formats. (`S`,`D`; L)
- Change detection: RD compares 2:14 (checksum) and 2:15 with its stored copy on 0:12 bit 0. (`S`,`T3`; C)
- The PC source was not in DVI mode: through the DVI-to-HDMI cable the GPU sent HDMI with an AVI InfoFrame in every mode (0:13 bit 1 = 1 at every entry, valid AVI checksums). The only DVI reading was the transient 0:13 bit 1 = 0 before the splitter unmute (§2.2), which the Roku showed too. Its RGB therefore took RD's HDMI branch: 0:6b = 0x40 (input and output RGB, 8 bit), 0:6c = 0x00 and 1:85 = 0x00 (converter bypassed). Q = 2 (full) was explicit. The IT6805 applies no range conversion: full-range RGB reaches the FPGA unchanged, and the FPGA's handling is in `video-pipeline.md`. (`T4`; C)
- DVI sources send no AVI. RD then keeps the stale AVI values and sets 0:6b[5:4] = 1 (§10.3). Still untested: no traced source was in DVI mode. For DVI assume RGB full range. (`S`; U)

### 9.2 DRM / HDR (bank 6)
- Layout: 6:10 HB0 (type, 0x87 when present), 6:11 HB1 (version), 6:12 HB2 (length), 6:13 PB0 (checksum), then PB1… RD reads HB2 + 1 bytes from 6:13. (`S`; L)
- RD acceptance, STABLE only: each poll read 0:12 (write back bit 5 only) and 6:10. On bit 5 with HB0 = 0, RD drops any stored packet; with HB0 ≠ 0 it counts; after more than 6 such events it treats DRM as present and from then on re-reads the packet on every bit-5 event. RD never passes DRM data on. (`S`; L)
- Traced: 0:12 bit 5 never set, 6:10 always 0x00 (1625 reads in `T3`, 5932 in `T4`; 0 writes). The EDID RD loaded advertises no HDR, so none was sent. HDR is UNVERIFIED end to end. (`T3`,`T4`; C for the absence)
- Decoding of PB1… follows CTA-861.3 (EOTF in PB1 bits 2:0, 2 = PQ). (`D`; U on this chip)

### 9.3 Other packets
Audio InfoFrame, SPD and vendor InfoFrame buffers (§2.5) are read only by RD's debug paths; the audio InfoFrame PB2 read 0x00. (`S`,`T3`; L)

## 10. Output bus to the FPGA
### 10.1 Decision (RD, at every stable entry and reconfiguration)
H = HActive (×2 for 4:2:0); PCLK = RD's pixel-clock figure (≈0.876 × true, §8.3). First matching rule:

| Rule | Condition | Bus | Traced | Ev | Conf |
|---|---|---|---|---|---|
| a | input YCbCr 4:2:0 (AVI Y = 3) | dual pixel, SDR | 2160p59.94 4:2:0 (Roku), 2160p60 4:2:0 (PC) | `S`,`T3/S20`,`S30`,`T4/S40`,`S44` | C |
| b | H ≤ 1920 and PCLK ≤ 150 000 kHz | single pixel, SDR | 1080p59.94 4:4:4, 1080p60 RGB (RD's PCLK 128.3–129.6 MHz) | `S`,`T3/S31`,`T4/S41`,`S44`,`S45` | C |
| c | H < 1920 and VActive < 2160 | single pixel, SDR | — | `S` | L |
| d | otherwise (e.g. 2160p30 4:4:4, 1080p120, 1440p60) | dual pixel, DDR | 2160p29.97 RGB (H = 3840, RD's PCLK 258.5–259.8 MHz) | `S`,`T4/S43`,`S45` | C |

- Because RD's PCLK reads low, rule b in true terms is "pixel clock ≤ ≈171 MHz" on this unit. Use 170 MHz on the true or calibrated clock: it keeps every 148.5 MHz mode single-pixel with margin, and 1080p120 (297 MHz) goes to rule d. (`D`; L)
- 1080p60 and every mode up to 1920 × 1200 reduced blanking (154 MHz) select single-pixel SDR. (`D`; L)
- RD's re-check after a parameter change has one more SDR case: H = 2880. (`S`; L)
- RD's board layer also computes an output format for the IT6805, but that request has no register effect (empty handler; its clock comparison is never true). The chip-level rules above are the only ones that act. (`S`; L)

### 10.2 IT6805 programming per bus mode
Rows of `seq/it6805-lock.tsv` marked MODE. Order: 0:64 bit 2 = 0 and bit 1 pulse; 5:20 bit 6 = 1; 1:c0 bit 0 = 0; 1:c0[2:1] = 01; 1:c1 bit 1 = DDR; 1:c1 bit 5 = 0; 0:6b[3:2] = output colour; 1:c0 bit 0 = 1 if dual; 5:d1 bit 0 = 0, 5:d1[3:2] = 01, 5:da bit 4 = 0, 5:d0 = 0xf3; 1:bd[5:4]; 1:be = 0; 1:fe bit 4 = 1; 1:c4; 0:64 bit 1 pulse again.

| Register | Single SDR (1080p) | Dual SDR (2160p 4:2:0) | Dual DDR (2160p29.97 RGB) |
|---|---|---|---|
| 1:c0 | 0x42 | 0x43 | 0x43 |
| 1:c1 | 0x00 | 0x00 | 0x02 |
| 1:c4 | 0x00 | 0x00 | 0x10 |
| 1:bd | 0x05 | 0x15 | 0x15 |
| 1:be, 1:fe | 0x00, 0x9c | same | same |
| 0:64, 5:20 | 0x81, 0x71 | same | same |
| 5:d0, 5:d1, 5:da | 0xf3, 0x04, 0x01 | same | same |
| 1:b0 bit 0 | 1 | 1 | 1 |
| 1:c5 / 1:c6 after unblank | 0x18 / 0x7f | 0x7f / 0x00 | 0x7f / 0x00 |
| Ev | `T3/S31`,`S32`; `T4/S41`,`S44`,`S45` | `T3/S20`,`S30`,`S21`; `T4/S40`,`S44` | `S`; `T4/S43`,`S45` |
| Conf | C | C | C |

- 1:b0 bit 0 = 1 when pixel clock ÷ repetition ≥ 25 MHz (repetition from 0:1b[5:4]: 1 → 2, 3 → 4). RD applies its low clock figure: 25.175 MHz VGA would get 0 under RD. Use the true clock. Below 1080p UNVERIFIED. (`S`,`D`; L)
- 0:64 bit 2 = 0 selects even/odd pixel distribution on the two pixel lanes; left/right halves (1) is never used. (`S`; L)
- Rule d as traced: the dual-SDR writes plus 1:c1 bit 1 = 1 (in the bus setting and again in the output enable) and 1:c4 = 0x10; nothing else differs. The FPGA captured correct frames (§10.4). (`T4/S43`,`S45`; C)
- The PC source's 2160p60 4:2:0 entries (`T4/S40`, `S44`) wrote the same sequence and final values as the Roku's (`T3/S20`, `S30`); the dual-SDR table replays all four. Only the input differed: AVI PB3 0x84 (IT content, Q limited) instead of 0x00, 60.0068 instead of 59.945 Hz, no HDCP. The FPGA captured black frames with both sources (open question 14). (`T3`,`T4`; C)

### 10.3 Colour format and depth (output enable)
1. HDMI (0:13 bit 1 = 1): 0:6b[5:4] = AVI Y; 0:6b bit 0 = 0 (traced with Y = 0, 2 and 3). DVI: 0:6b[5:4] = 1, bit 0 = 1 (`S`; U).
2. 0:6b[3:2] = same as the input: the IT6805 converts nothing. Re-apply 1:c0[2:1] = 01, 1:c1 bits 1/5 as in §10.2.
3. W 0:6e 0xa2; W 1:86 0x00.
4. Converter bypass: M 0:6c 03 00; W 1:85 0x00.
5. Depth: 0:6b[1:0] = 1 if 0:98[7:4] = 5, 2 if 6, else 0.

Results: 0:6b = 0x68 at 1080p 4:4:4 8 bit, 0x7c at 2160p 4:2:0 8 bit (`T3`, `T4`), 0x40 at RGB 8 bit (1080p60, 2160p29.97; `T4`); 0:6c = 0x00 in all. (`T3`,`T4`; C)
- The IT6805 has a colour converter (0:6c select, 1:70–1:85 coefficients) and an internal down-scaler (bank 5 0x21–0x41, 0:33 bit 3, 5:20 bit 6 = 0). RD never uses either. Both are possible alternatives for the 2160p path (open question 14); programming in §10.6, UNVERIFIED. (`S`; U)
- Deep colour (10/12 bit) output, and what the FPGA does with it: UNVERIFIED (open question 24). Do not advertise deep colour in the EDID (`hdmi-chips.md`).

### 10.4 Matching FPGA configuration
FPGA registers: `video-pipeline.md`. The FPGA must mirror the IT6805 bus. (`S`,`T3`,`T4`; C where traced)

| Input | IT6805 bus | COLOR_CTRL bit 0 | bit 5 | bit 19 | PIX_MODE | Clip width | Result | Conf |
|---|---|---|---|---|---|---|---|---|
| 1080p59.94 YCbCr 4:4:4 | single SDR | 0 | 0 | 0 | 0 | 1920 | correct images, all formats (`T3/S32`) | C |
| ≤ 1080p60 YCbCr 4:2:2 | single SDR | 1 | 0 | 0 | 0 | H | never traced | U |
| 1080p60 RGB (PC source) | single SDR | 0 | 0 | 0 | 0 | 1920 | correct: BGR24 equal to the source within +1 (`T4/S42`,`S43`; `video-pipeline.md`) | C |
| 2160p59.94/60 YCbCr 4:2:0 | dual SDR | 0 | 1 | 1 | 1 | 3840 | black frames with both sources (`T3/S21`, `T4/S41`; open question 14) | C (values) |
| 2160p29.97 RGB (PC source, rule d) | dual DDR | 0 | 1 | 0 | 3 | 3840 | correct (`T4/S44`, YUYV out: COLOR_CTRL = 0x26, adding bit 1 RGB→YUV and bit 2 colour adjust) | C |
| other rule d modes | dual DDR | 0 / 1 per Y | 1 | 0 | 3 | H | never traced | U |
| no input | outputs tristated; flags from init (dual 0, DDR 1) | 0 | 0 | 0 | 2 | — | free-running frames | C |

- PIX_MODE = dual \| (DDR << 1); COLOR_CTRL bit 5 = dual; bit 0 = input 4:2:2; bit 19 = input 4:2:0. (`video-pipeline.md`; `S`,`T3`; C)
- The colour space reaching the FPGA is the source's (no conversion in the IT6805), so FPGA CSC selection depends on AVI Y, C/EC and Q/YQ (§9.1). (`S`,`T3`; C)

### 10.5 Tristate, unblank and video logic reset
- Tristate on (init, NO_5V entry, every WAIT_SYNC entry): W 1:c5 0xff; W 1:c6 0xff. RD reads 0:98 first (no effect). (`T`; C)
- Unblank, after the video logic reset: M 1:c5 80 00; M 1:c6 80 00; then single pixel W 1:c5 0x18, or dual pixel W 1:c6 0x00 (1:c5 stays 0x7f). Final values: single 0x18 / 0x7f, dual 0x7f / 0x00, SDR and DDR alike. (`T3`,`T4`; C)
- RD picks the single-pixel value by 1:c0[7:6] (01 → 0x18; 10 would give 0x03) and has variants (0x78, 0x38) for 0:98[7:4] = 1 or 2, codes that do not occur (0:98 reads 0 right after the reset). Use 0x18. (`S`,`T3`; L)
- The bit groups of 1:c5/1:c6 are unknown. Dual-pixel DDR used the same final values (1:c5 = 0x7f, 1:c6 = 0x00) and captured correctly (`T4/S44`), so 0x7f does not leave the dual-pixel DDR bus undriven. Whether dual SDR needs lanes that 0x7f leaves off remains a candidate in open question 14. (`S`,`T4`; U)
- Audio outputs are separate: 1:c7 (§11).

### 10.6 Blocks RD leaves unused: format conversion and the down-scaler (UNVERIFIED)
RD keeps the converter bypassed and the output format equal to the input format (§10.3). RD's library is built with its option "convert 4:2:0 to RGB while the converter is bypassed" turned off; the library's notes say the choice depends on whether the chip after the IT6805 accepts 4:2:0. Nothing in this section was traced. (`S`; U)

Output format different from the input:
- 0:6b[3:2] (output format) is written separately from 0:6b[5:4] (input format, from the AVI at every output enable). Same coding: 0 RGB, 1 YCbCr 4:2:2, 2 YCbCr 4:4:4, 3 YCbCr 4:2:0. (`S`; L)
- Converter select in the library: output RGB with YCbCr input (4:2:2, 4:4:4 or 4:2:0) → 0:6c[1:0] = 3 and 22 bytes burst-written to 1:70–1:85 (one set per colorimetry and range); RGB input with YCbCr output → 0:6c[1:0] = 2; same family on both sides → 0:6c[1:0] = 0 and 1:85 = 0x00. (`S`; U)
- Converter registers, derived from the library's eleven coefficient sets checked against BT.601 and BT.709 (`S`,`D`; L, never traced):
  - Channel order on both sides: 0 = G / Y, 1 = R / Cr, 2 = B / Cb. Not the FPGA CSC's order (`video-pipeline.md`).
  - 1:73–1:84: nine coefficients, row-major (rows = output channels 0, 1, 2; columns = input channels 0, 1, 2), each 16-bit little-endian, 14-bit two's complement, 1.0 = 0x800 (range −4 to < 4).
  - Checks: RGB→YCbCr BT.709, full-range RGB in: Y row 0.6142 G, 0.1826 R, 0.0620 B (= Kg, Kr, Kb × 219/255); YCbCr→RGB BT.709 limited in, full out: Y column 255/219, R row Cr 1.7927, B row Cb 2.1124, G row Cr −0.5329, Cb −0.2132. All library sets agree with the standards to rounding.
  - 1:70, 1:71, 1:72: offsets. Library values: RGB→YCbCr with limited RGB in 0x00, 0x80, 0x10; with full RGB in 0x10, 0x80, 0x10 (1:70 = Y offset 16 for full-range input, 1:71 = chroma offset 128); YCbCr→RGB limited→limited 0x00, 0x00, 0x00; limited YCbCr → full RGB 0x04, 0x00, 0xa7 (encoding not understood; use as given for that conversion). RGB→RGB range sets put the offset (+16 or −19) in 1:70, 1:71 and 1:85.
  - 1:85: 0x00 except in the RGB→RGB range sets (see above); RD writes 0x00 at every output enable.
- Whether the chip upsamples 4:2:0 when 0:6b[5:4] = 3 and [3:2] = 2 (4:4:4) or 0 (RGB) is not known. The library's own bus decision (§10.1 rule a) looks only at the input format, so a 4:2:0 input always gets dual pixel SDR. A 2160p60 4:4:4 output carries 594 Mpixel/s and needs dual pixel DDR at a 148.5 MHz bus clock: rule d's register values (`seq/it6805-lock-dual-ddr.tsv`) at twice the clock traced for 2160p29.97. Whether the IT6805 output and the FPGA input run at that rate is UNVERIFIED; RD's EDID advertises 600 MHz TMDS, i.e. 2160p60 4:4:4 input.

Down-scaler (2:1 in both directions). RD's library has the routine but never calls it. (`S`; U)
1. 0:33 bit 3 = 1.
2. Bank 5. 16-bit values, low byte first; the high byte of each target-timing field uses bits 5:0.
   - 0x21/0x22 = H, the source active width in pixels (for 4:2:0 input: twice the measured HActive, which counts TMDS clocks).
   - 0x23/0x24 = source active height.
   - 0x25/0x26 = H − 2.
   - 0x27/0x28 and 0x29/0x2a = H/2 − 1.
   - 0x2b = 0xff, 0x2c = 0x00, 0x2d = 0x0f, 0x2e = 0xff, 0x2f = 0x00, 0x30 = 0x0f.
   - 0x31 = 0x18 + 2·a + b, where a and b are the input's sync polarity flags. Which flag is which, and whether 1 means positive, is not known; for a CTA 2160p source (both syncs positive) try 0x1b first.
   - Target timing, half the source timing in output pixels: 0x32/0x33 H front porch, 0x34/0x35 H sync, 0x36/0x37 H back porch, 0x38/0x39 H active, 0x3a/0x3b V front porch, 0x3c/0x3d V sync, 0x3e/0x3f V back porch, 0x40/0x41 V active.
3. 5:20 bit 6 = 0 (down-scaler in the path; RD sets it to 1 at every bus setting, §2.6 table).
4. 0:33 bit 3 = 0.

Worked example, 2160p60 4:2:0 source (measured HActive 1920 TMDS clocks): 0x21/0x22 = 3840, 0x23/0x24 = 2160, 0x25/0x26 = 3838, 0x27–0x2a = 1919; target H 88/44/148/1920, V 4/5/36/1080, which is CTA 1080p60 (2200 × 1125 at 148.5 MHz). The output format and bus mode to use with the down-scaler are not in RD's library path; single pixel SDR with output 4:4:4 (§10.1 rule b, 0:6b[3:2] = 2) is the natural first try. If it works, a 4K source can be captured at 1080p with the FPGA in its traced 1080p configuration.

## 11. Audio
### 11.1 State machine (RD)
| State | Entry | Per poll | Ev | Conf |
|---|---|---|---|---|
| OFF | M 0:81 40 00; W 1:c7 0x7f | — | `T3`,`S` | C |
| REQUEST | same as OFF; reset the sample-rate mismatch count | next step in the same poll: clear stored status → WAIT_READY | `T3`,`S` | C |
| WAIT_READY | M 0:8c 10 10; M 0:8c 10 00; count = 2 | count down; at 0: read 0:b9, bits 7:6 ≠ 0 → audio logic reset; if ready → ON, else count = 2 | `T3`,`S` | C |
| ON | audio enable (§11.2); log reads | every 4th poll read 0:b0, 0:b1, 0:b2. First time: store them and copy 0:b2 bit 1 to 0:8c bit 3. Later: any change of 0:b0[7:4], 0:b1 or 0:b2 bit 1 → REQUEST | `T3`,`S` | C |

- Ready = sync (0:19 bit 7) and 0:b1 bit 7 = 1 and 0:10 bit 7 = 0. (`S`,`T3`; C)
- Entries: stable entry → REQUEST; sync off or DVI → OFF; HDMI/DVI change while STABLE → REQUEST; 0:10 bit 7 while STABLE → audio logic reset + enable. (`S`; L)
- Audio logic reset: 0:22 bit 1 pulse; RD then reads 0:8a and writes it back 4 times. Never traced. (`S`; L)
- Timing: WAIT_READY to ON took 3 polls; audio on 127–137 ms after the AV-mute release (`T3/S20` 4923.0 → 5056.0, `S30` 33138.6 → 33275.7, `S31` 28085.1 → 28221.5 and 38748.1 → 38875.3). (`T3/S20`,`S30`,`S31`; C)
- Streaming and FPGA audio DMA start/stop cause no IT6805 access. (`T3/S21`–`S27`,`S32`–`S34`; C)
- Source without audio (`T4`: 0:b1 = 0x00 in every read, FPGA 0x10a0 = 0xffffffff): RD stayed in WAIT_READY. The ready check (0:b9, 0:19, 0:10, 0:b1) ran every 3rd poll and failed on 0:b1 bit 7; 1:c7 stayed 0x7f and 0:86 was never written. (`T4`; C)

### 11.2 Audio on and off
On (`T3/S31` 38875.2–38877.5; C):

| op | reg | mask | value | note |
|---|---|---|---|---|
| M | 0:86 | 01 | 01 | audio output enable; stays set |
| R | 2:be, 2:bf, 2:c0, 2:c0, 2:c1, 2:c2 | | | N and CTS (§11.3) |
| R | 0:b5, 0:b6 | | | channel-status sample rate |
| W | 1:c7 | ff | 00 | audio outputs driven |

Off: M 0:81 40 00; W 1:c7 0x7f. (`T3`; C)

### 11.3 Sample rate and channels
- Channel status: code = 0:b5[3:0] \| (0:b6[7:6] >> 2); traced 2 = 48 kHz. (`S`,`T3`; C)
- N = 2:be << 12 \| 2:bf << 4 \| (2:c0 & 0x0f); CTS = 2:c1 << 12 \| 2:c2 << 4 \| (2:c0 >> 4). RD reads 2:c0 twice, once per nibble. fs = f_TMDS × N / (128 × CTS). Traced N = 5824 with CTS 281 249 (2160p, 296.70 MHz) and 140 624 (1080p, 148.35 MHz): 48.0 kHz. (`S`,`T3`,`D`; C)
- RD computed f_TMDS with its low reference (§8.3), got 42 kHz and counted a mismatch against the channel status every time. After more than 15 consecutive mismatches RD would force the rate (0:81 bit 6 = 1, 0:8a[5:0] = code, audio logic reset). The count restarts at every REQUEST, so forcing never happened. Driver: do not force the rate. (`S`,`T3`; C)
- Use the FPGA measurement (0x10a0, `audio.md`) for the rate: 0x823 → 48 kHz with this input. (`T3`; C)
- Channels: 0:b1[5:0] layout; 2 × (index of the highest set bit + 1); traced 2 channels. (`S`,`T3`; L)

### 11.4 Output toward the FPGA
RD never programs the audio interface format (I2S/S/PDIF, word length, clock ratio). It relies on the init values (0:81 = 0xa0, 0:86 = 0x08, 0:8f = 0x41, 0:77 = 0x87, 0:7b bit 4, 1:c8–1:ca) plus 0:86 bit 0 and 1:c7. With these the FPGA measured 48 kHz and captured audio samples (`audio.md`). The format itself is UNVERIFIED (open question 5). (`S`,`T3`; C for "works at 48 kHz 2 ch", U for the format)

## 12. Driver recipe: 1080p60 bring-up
Everything below was traced, except items marked D (derived from RD).
1. FPGA init with reset pulses (`init.md`); wait ≥ 50 ms; bus-1 adapter (`i2c.md`).
2. D: HPD low (GPIO bit 2 = 0).
3. `seq/it6805-init.tsv` with the X steps: calibration wait (§3.3), factory data and trim (§3.4), own EDID (§4). Finish it, or at least its 0xe0 access, before the splitter init maps its own 0xe0 block (§1.1).
4. 5 V evaluation (§3.6): NO_5V + SAVING, or STANDBY + WAIT_SYNC.
5. HPD high (RD: pulse 1, 10 ms, 0, 100 ms, 1; end state high). Splitter bring-up per `hdmi-splitter.md` and the order in `hdmi-chips.md`.
6. Poll every 50 ms (§7.2, §7.3). Handle 5 V (§7.4): loss → HPD low, unplug, SAVING; return → STANDBY, HPD high; then the first 0:05 bit 1 → NORMAL.
7. Sync (0:19 bit 7) → DEBOUNCE 4 polls → stable entry (`seq/it6805-lock.tsv`). Check before it: AVI Y = 2 (4:4:4) or 0 (RGB, `T4`; 4:2:2 untested), HActive ≤ 1920, VActive ≤ 1080, coarse clock ≤ 170 MHz (§10.1) → single-pixel SDR, with the MODE values of §10.3. Otherwise report the mode unsupported.
8. FPGA: COLOR_CTRL bits 0/5/19 = 0 (CSC bits per input and output format, `video-pipeline.md`), PIX_MODE = 0, clip = HActive × VActive (§10.4). Frame rate from 0x1010 (§8.3). DV timings from §8.1 plus that rate.
9. Next poll: AV-mute release (§7.7); requires the splitter TX port 1 unmute (`hdmi-chips.md`). Then audio WAIT_READY → ON (§11).
10. Sync loss: M 0:40 03 02, tristate, audio off, WAIT_SYNC, source-change event (§7.9, §7.10).

## 13. Unverified and open
| Item | Evidence needed |
|---|---|
| Revisions other than 0xb1 | another card |
| Calibration retry path; effect of a failed calibration (§3.3) | fault injection or a marginal unit |
| Meaning of the factory value and of the ≈23.4 MHz counter reference; whether 0:91/0:92/1:fd should carry the true reference (§3.5, §8.3; open question 20) | vary the trim and reference registers and read the counters against 0x1010 |
| Trim formula on other units (§3.4) | factory values from more cards |
| PA substitution, and 0:ca without a VSDB (§4) | DDC readback of a test EDID through the splitter |
| TX port 1 HPD fall latency (§5; open question 23) | drop bit 2 with the splitter TX idle |
| AV-mute release leaving 1:c5 bit 7 set (§7.7) | a source that toggles AV mute while locked |
| Reconfiguration while STABLE: AVI or timing change without sync loss (§7.8). All 6 `T4` GPU mode changes dropped sync | a source that changes the colour format or timing without dropping sync; open question 24 |
| YCbCr 4:2:2, limited-range RGB and DVI input (§9.1, §10.4). Full-range RGB over HDMI is traced (`T4`) | a source in DVI mode (EDID without the HDMI block) or sending 4:2:2 or limited RGB; open question 24 |
| Interlaced input, pixel repetition, 720p, < 25 MHz clocks, negative sync polarity (§8.1, §10.2) | sources with these modes; open question 24 |
| Deep colour output and FPGA acceptance (§10.3) | 10/12-bit source with an EDID that allows it |
| Rule d with other inputs: 1080p120, 1440p60, YCbCr at 2160p30 (§10.1); only 2160p29.97 RGB is traced | sources with these modes |
| 2160p 4:2:0 black frames (Roku and PC source); 1:c5 = 0x7f in dual SDR; converter or down-scaler as alternatives (§10) | open question 14 |
| Source-dependent status bits of unknown meaning: 0:10 bit 6 (`T3` only), 0:14 bit 1 after a loss, 0:aa bit 0 (2160p29.97 only) (§2.1, §2.2) | more sources and modes |
| HDMI 2.0 rates (> 340 MHz, scrambling); 0:14 bits 6/7, 0:15 | 2160p60 4:4:4 source with a 600 MHz upstream path |
| HDCP (0:1d, 0:d6) with an encrypting source | open questions 15, 25 |
| DRM / HDR InfoFrames (§9.2) | HDR source and an EDID with an HDR block |
| ECC recovery, equaliser override (§7.9) | marginal cable or link |
| Audio interface format, multichannel, rates other than 48 kHz (§11) | open question 5 |
| Registers replayed by value only, purpose unknown: 0:24, 0:36, 0:3a/4:3a, 0:43/4:43, 0:59, 0:77, 0:8f, 0:d9, 0:f0, 0:f1, 0:f6, 1:10–1:13, 1:28–1:2c, 1:c9, 1:ca, 3:e3, 0:40, 0:6e bit 1, 0:90. Omitting or reordering any of them has unknown effect: replay them | register-by-register experiments, low priority |
| Missing I2C completions on 0x0f (§1.7) | open question 22 |
| Which GPIO bit (5 or 8) resets the IT6805; minimum delay after reset (§1.6) | open question 10 |
| GPIO bit 10 as an interrupt line (§5) | open question 21 |
| FPGA 0x1010 validity while the IT6805 outputs are still tristated, i.e. whether the frame rate is known before unblank (§8.3) | read 0x1010 during the stable entry |

Settled by `T4` and moved out of this list: dual-pixel DDR programming (rule d, §10.2) with its FPGA configuration (§10.4); full-range RGB input over HDMI (§9.1, §10.3); source mode changes with 5 V held, which went through sync loss every time (§7.9).
