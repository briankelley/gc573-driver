# HDMI splitter (ITE, chip ID 0x6663)

The splitter sits between the HDMI input connector and the IT6805 receiver. Its RX core receives the source, its TX port 1 re-transmits the stream to the IT6805, and a second TX port probably drives the pass-through connector. There is no firmware on the board: the host programs every register below over I2C bus 1 (`i2c.md`).

Related files:
- `hdmi-chips.md`: topology, GPIO lines, cross-chip bring-up order, lock timing, EDID policy. Cross-chip topics are not repeated here.
- `hdmi-it6805.md`: the receiver.
- `seq/splitter-*.tsv`: register sequences referenced below (index in §12). Format in each file's header.

## 1. Conventions
- I2C addresses are 8-bit (write form). Register references are `dd/b:rr` (device 0xdd, bank b, register 0xrr) or `dd:rr` for unbanked devices. Values are hex without prefix. Examples: `70/3:ab`, `6a:03`.
- "M reg mask value": read-modify-write, new = (old & ~mask) | (value & mask). RD reads before every masked write, including mask 0xff; for a full mask a plain write is equivalent.
- W1C: event bits clear when 1 is written. RD writes back the value it read.
- "Port n": TX port n, I2C address 0x68 + 2n. "RX": the splitter's input core at 0x70, not the IT6805.
- Times: ms from the first I2C transfer of the scenario (T1: of the load; `T1/S01i` times use the same base). To find them in `traces/T*.tsv.xz`, add the scenario offset and compare with t_us/1000: T1 380.076, T3/S20 358.811, T3/S30 279342.561, T3/S31 327422.591; T4/S40 2348.133, S41 33545.842, S42 150510.850, S43 197088.129, S44 294541.650, S45 352357.611, S46 391362.363 (same convention as `hdmi-chips.md` and `README.md`; a T4 event is quoted in the scenario whose MARK precedes it). An event's time is that of the 58/0:05 read that starts RD's event pass; a step inside a pass is timed by its own transfer.
- `T4/S40` gap: the capture lost every I2C record of the first 2348 ms after the S40 MARK, and 69 transfers at S40 t=0.7–12.9. For each lost transfer the public trace keeps an IRQ line, and the raw capture also keeps its direction (the I2C controller's completion status: read or write). §9.7 places RD's steps in the gap by aligning this direction sequence with `T3/S20`. Such facts are tagged `T4/S40 (aligned)`, have confidence L at most, and are timed in `pub` ms: public-trace time, i.e. ms after the S40 MARK (S40 time = pub − 2348.1).
- Bank labels in the traces come from RD's bank-select writes, so after an I2C retry they can be wrong (one known case, on the IT6805: `traces/README.md`, `i2c.md`). No retry ever involved a splitter device. In `T4/S40` t=13.0–20.9 the public trace labels RX bank-2 reads (AVI) as bank 0, because their bank select was among the lost transfers.
- Delays: values RD uses, as busy-waits or sleeps. Minimum values are unknown; keep them until an experiment shows otherwise.
- Every register or bit called "unknown" is replayed by value. Changing or omitting it has unknown effect.

## 2. Identity, topology, address map

### 2.1 Identity
| Fact | Ev | Conf |
|---|---|---|
| 58/0:00–01 = `54 49` (vendor ID 0x4954, low byte first), 58/0:02–03 = `63 66` (device ID 0x6663) | `T1/S01`,`T3/S20` | C |
| 58/0:15 bit0 = 1 on this card; RD treats it as chip revision A1 | `T1/S01`,`S` | C (value), L (meaning) |
| RD reads the ID with two 2-byte reads (LEN 2 at regs 0x00 and 0x02, done twice) and continues even if the ID does not match | `T1/S01`,`S` | C |

### 2.2 Topology
`HDMI IN → RX core (0x70) → TX port 1 (0x6a) → IT6805 port 0`

| Fact | Ev | Conf |
|---|---|---|
| Port 1 feeds the IT6805. The 256 bytes read through port 1's DDC master equal the image RD loaded into the IT6805 EDID RAM (0xa8), including the checksum bytes served at offsets 0x7f/0xff | `T3/S20` | C |
| Port 1's HPD input is the IT6805-side hot-plug line, driven by FPGA GPIO 0x040 bit 2 (`hdmi-chips.md`). After the line went high, port 1 latched its HPD event within 84–104 ms. The polls bound it to 84–144 ms (S20), 48–104 ms (S30), 49–105 ms (S31) and 60–124 ms (`T4/S40`, aligned); the first 6a:03 reads showing bit0 = 1 came at +108 and +110 ms (S30, S31). While the line was low (9.2 s in S30, 3.8 s in S31, no port soft reset in between) no HPD event was latched | `T3/S20`,`S30`,`S31`,`T4/S40` | C |
| A port soft reset (0x01 bits 1:0, §7.2) clears the HPD status at once: 6a:03 read 10 within 0.3 ms in every case. With the line still high, HPD was re-detected 88.8–93.2 ms after the reset: at `T4/S44` t=50559.2 the poll 88.8 ms after the reset showed no port event, and a 6a:03 read at 93.2 ms showed bit0 = 1. The windows of the six other resets contain this interval (T3/S31: 70–133 ms; T4 S41, S43, S44, S45 ×2: from 61–73 ms to 133–156 ms). The port power-down and port reset procedures do not clear it (6a:03 = 13 after both, S30 t=22114.7) | `T3/S30`,`S31`,`T4` | C |
| HPD fall latency without a soft reset is unmeasured. The status still read 1 64 ms after the line went low; RD's own soft reset, 74 ms after the line went low, then forced it to 0 (S30, S31). Open question 23 | `T3/S30`,`S31` | U |
| Port 1 RxSense (6a:03 bit1) followed HPD by 68–80 ms with a source (S30, S31), each time after RD's power-down/power-on of the port. After the T4 mode-change soft resets, which leave the port powered, RxSense rose in the same poll interval as HPD in five of six cases (port event 0x10 = 03 or 83). In the sixth, RD's power-on came first and RxSense was set ≤ 64 ms after it (`T4/S43` t=90281.4). It stayed 0 in the no-source idle (6a:03 = 11) and stayed 1 for at least 65 ms after the IT6805 lost 5 V, until the soft reset. It probably reflects the IT6805 input termination | `T1/S01i`,`T3/S30`,`S31`,`T4` | C (values), U (meaning) |
| The IT6805 port's 5 V follows the input connector without software: the IT6805 saw 5 V loss 41–42 ms before the splitter's next poll did (S30 t=22053.6 vs 22095.0; S31 29729.6 vs 29770.7) | `T3/S30`,`S31` | L |
| With no source the IT6805 does not answer DDC: all 12 port 1 EDID attempts after the no-source load ended in no-ACK status (§7.7). An EDID copy through port 1 therefore needs a source | `T1/S01i` | C |
| Port 2 (0x6c) is probably the pass-through output, by elimination only: it is the only other port RD initialises and services, and its HPD never set (6c:03 only 00/10/14; nothing was connected) | `T1`,`T3`,`S` | U |
| Ports 0 (0x68) and 3 (0x6e) are unused: RD parks them at init and never powers them on; 0x03 always reads 10 | `T1`,`T3`,`S` | L |

### 2.3 Devices and enables
| Addr | Block | Enabled by | Banks | Ev | Conf |
|---|---|---|---|---|---|
| 0x58 | main block: ID, resets, OTP window, clock calibration, event summary, timers, per-port source select, CSC, HDCP repeater engine (bank 1) | fixed address | reg 0x0f bit0: banks 0, 1 | `T1/S01`,`S` | C |
| 0x70 | RX core | 58/0:f0 = 71 | reg 0x0f bits 1:0: banks 0–3 | `T1/S01`,`S` | C |
| 0x96 | TX common: reference-clock value, TX common reset, port address registers | 58/0:f1 = 97 | none | `T1/S01` | C |
| 0x68, 0x6a, 0x6c, 0x6e | TX ports 0–3, identical register sets | 96:2c–2f = 69, 6b, 6d, 6f | none | `T1/S01` | C |
| 0xd8 | RX EDID RAM, 256 bytes, served to the source on the input DDC | 70/0:4b = d9 | none | `T3/S20` | C |
| 0xe0 | RX sub-block; RD uses it only for MHL inputs and never accesses it | 70/0:49 = e1 | none | `T1/S01`,`S` | C (enable written), L (use) |

- Enable rule: value = address | 1 (`T1/S01`; C). Whether a sub-device answers before its enable write is unknown (U). RD writes 58/0:f0 twice.
- 70/0:28 is not an address register, although its final value d9 looks like one. The calibration step (§3.4) zeroes 0x25–0x28; RX init then sets bits of 0x28 with two masked writes (59, then 88), ending at d9, with or without a source. The EDID RAM enable is 70/0:4b. Neither the code nor the traces name the 0x28 bits. In the IT6805, whose receiver has the same register design, 0x24–0x2a is the port-0 calibration group, and 0x28 ends at 88 while its EDID RAM sits at 0xa8. (`T1/S01`,`T2/S10`,`T3/S20`,`S`; C for values and for 0x4b, U for meaning)
- Bank 0x70/1 is never selected in any trace (it belongs to the HDCP repeater path). Banks used: 0x70 banks 0, 2, 3; 0x58 banks 0, 1. (`T1`,`T3`; C)

### 2.4 Access rules
| Rule | Ev | Conf |
|---|---|---|
| Register address is 1 byte. Transfers are single-byte except: ID reads (LEN 2), CSC writes 58/0:70 and 88 (3 bytes) and 58/0:73 and 93 (18 bytes), DDC FIFO reads of port reg 0x30 (32 bytes, or 1 byte for SCDC), 70/3:ea (2 bytes) | `T1`,`T3` | C |
| Bank select: 0x58 `M 0f 01 b`, 0x70 `M 0f 03 b`. RD also writes the bank register directly (0x58 init, 0x70 HPD-pin setup). The bank register is accessible from every bank | `T1`,`T3`,`S` | C |
| RD returns to bank 0 after every banked sequence, and every other access assumes bank 0 without selecting it | `T1`,`T3` | C |
| Driver: hold a per-device lock across a bank select and the accesses that depend on it (`hdmi-chips.md`). Select bank 0 explicitly before reading 70/0:d0: RD's board code reads it without a bank select, and in bank 3 the same offset reads 3f, which would look like "HDCP active" (T3/S20 t=3805.6) | `T3`,`S` | C |
| After a failed or timed-out transfer to 0x58 or 0x70, re-read and rewrite the bank register before the next banked access (`i2c.md`; all observed timeouts were on the IT6805) | `T3/S32-BGR3` | C |
| W1C event registers: 58/0:06, 07; 58/1:21–23; 70/0:05–09, 10–12; port 0x10–0x14 (0x15 is written at port power-on). 58/0:05 is read-only | `T1`,`T3`,`S` | C |
| Address 0xe0 is shared: the IT6805 maps its own sub-block there (`hdmi-it6805.md`). RD's IT6805 init accesses 0xe0 at T1 t=89.8, before the splitter maps its 0xe0 block (t=226.6); nothing accesses 0xe0 afterwards. Driver: run the IT6805's 0xe0 access before splitter phase H, and never access 0xe0 after it. Skipping the 70/0:49 = e1 write is UNVERIFIED (evidence needed: init without it, then a lock at 1080p60) | `T1/S01`,`S` | C (order), U (skip) |

## 3. Initialisation

### 3.1 Preconditions
- FPGA init done, including the GPIO reset pulses (`init.md` steps 1–11). Which GPIO line resets the splitter, and the minimum delay from reset release to the first splitter transfer, are unknown (open question 10). In T3/S20 the first I2C transfer came 52 ms after the last reset release, and the splitter init started 188 ms after that. (`T3/S20`; C for times, U for requirements)
- The IT6805's 0xe0 access is done (§2.4).
- Hint for open question 10: GPIO bit 10, a candidate splitter interrupt output (§5.1), read 0 from the time bit 5 went low until after the resets. In T3/S20 it read 1 at t=181.8, before the splitter's first access, while an RX 5 V event was pending. If bit 10 is the splitter's output, bit 5 is the splitter's reset. In `T4/S40` RD's read-modify-writes of GPIO 0x040 (recorded) saw bit 10 = 0 at pub 593.3 and 1 at pub 609.3. By alignment these fall during init phase F (RX reset) and right after phase H (RX init), with the input's 5 V present. That fits an interrupt output that the RX reset clears and the re-initialised RX's 5 V event sets again. (`T3/S20`,`T4/S40`; U)
- RD runs the splitter init in its own task, interleaved with the IT6805 init. Only the order within each device matters, because the two chips share no addresses. (`T1/S01`; C)

### 3.2 Sequence
Table `seq/splitter-init.tsv` (424 rows). It reproduces all 641 splitter transfers of `T1/S01` and all 625 of `T3/S20` with identical order and values; the masks come from `S` and agree with every traced read/write pair. (`T1/S01`,`T3/S20`,`S`; C)

| Phase | Content | Conf |
|---|---|---|
| A | bank 0; ID and revision reads | C |
| B | soft-reset pulse 58/0:0a bit0. Protected window: unlock key `c3`, `a5` into 58/0:ff, writes to 5f and 58, lock with `ff`. 58/0:10 = 6e | C (values), U (meaning) |
| C | 58/0:f0 = 71 (RX core), port enable bits 58/0:08 = 0f, 58/0:f1 = 97 (TX common) | C |
| D | reference clock from OTP (§3.3); program 96:11–13 and 58/0:1e–1f | C |
| E | 96:50 bit2 = 0; port addresses 96:2c–2f | C |
| F | RX reset: 70/0:22, 23, 24 writes around a 10 ms delay | C |
| G | RX analog offset calibration (§3.4) | C |
| H | RX init: register list, EQ defaults 9f, sub-block 0xe0 mapping, RX HDCP 2.x off (70/0:e3 = 00), HPD-pin register in its low state (70/3:ab = 4a, ac = 40) | C (values), U (most meanings) |
| I | RX power-down (§6.3), including source HPD low and EQ defaults; then 70/0:c5 bit0 = 1 (no EDID loaded yet) | C |
| J | TX common reset pulse 96:20 = 02, 00; ports 0 and 3: power-down and port reset (§7.2) | C |
| K | ports 1 then 2: AV mute on (0xc1 bit0), soft reset (0x01 bit0), port init list, port reset, power-down | C |
| L | 96:15 bit3 = 1; park ports 0 and 3 (0x84 = 60, 0x86 = 00, 0x88 = 0b; port 0 also 0x03 = 03); main-block settings including 58/1:10 (RX HDCP 2.x bit off) and timer gate 58/0:19 = 0f; 10 ms; on all four ports: HDCP 1.x engine off (0x41 bit0 = 0), AV mute on (0xc1 bit0 = 1), 0x88 bit0 = 1 | C |

- The only difference between loads: rows marked `cond:` (a timer-1 arm inside each port power-down, done only when neither 6a:03 nor 6c:03 shows HPD; four times in T1; twice in S20, where GPIO bit 2 (port 1's HPD line, §2.2) had been high since before the load, so port 1 showed HPD during the phase J pair; four times in `T4/S40` (aligned), where bit 2 had been low before the load and was high for only 16 ms before the init's low pulse). Init ends with 58/0:19 = 0f, after which this armed timer never fired (`T1/S01i`: 533 polls in 30 s, no timer event). A driver may skip these rows. (`T1/S01`,`T3/S20`,`T1/S01i`; C for the trace, L for skipping)
- RD's init takes ≈99 ms and ≈640 transfers. (`T1/S01`; C)
- After a later port soft reset (§7.2) the port's init values return to power-on defaults, and RD never rewrites them; video still worked (1080p capture after T3/S31). Whether these values matter is unknown. (`T3/S31`,`T3/S32-*`; C for the observation, U for the effect)

### 3.3 Reference clock (RCLK)
Per-unit calibration, performed in phase D. The OTP is a 16-bit-word memory read through the main block.

1. Read word w (inside the unlocked OTP window of phase D): `W 58:50 = w[11:8]`, `W 58:51 = w[7:0]`, `W 58:54 = 04`; data = 58:61 (bits 7:0) | 58:62 << 8.
2. Read words 0x000 and 0x001. If they are ffff and 0000 the calibration record is at `base` = 0x4b0, otherwise at `base` = 0x0b0. This card: 0101/0101, so 0x0b0.
3. A = word(`base`), B = word(`base` + 1). If B[15:14] = 11b: count = A | (B[7:0] << 16) and `rclk` [kHz] = count / 100 (integer division). This card: A = 4434, B = c020, count = 0x204434, rclk = 21146.
4. If B[15:14] ≠ 11b, or rclk is outside 10000–34000: measure instead. M 58:11 80 80, wait 99 ms, M 58:11 80 00, count = 58:12 | 58:13 << 8 | 58:14 << 16, rclk = count / 100. (`S` only; L)
5. Program, with rclk10 = rclk × 10: 96:11 = rclk10[7:0], 96:12 = rclk10[15:8], 96:13[1:0] = rclk10[17:16]; 58/0:1e[5:0] = rclk / 1000; 58/0:1f = ((rclk mod 1000) × 32) / 125. 58/0:1e–1f is rclk in MHz with 8 fraction bits. This card: 04, 3a, 3; 15, 25.

(`T1/S01`,`T3/S20`,`S`; C for steps 1–3 and 5, L for step 4)

Use: rclk is the time base of the TX clock measurement (§7.3) and the RX TMDS measurement (§6.7). It may also clock the timers (§5.3; U).

Accuracy: clocks computed from rclk = 21146 kHz read 4–8 % low. At 1080p60 (148.5 MHz) port 1 measured 138.4 and 142.9 MHz and the RX 137.0–138.8 MHz. At 297 MHz (2160p 4:2:0) port 1 measured 281 and 286 MHz and the RX 277.6 MHz. If the formulas are exact, the effective reference is 22.0–22.9 MHz. RD's nominal value for this oscillator is 22000 kHz (the centre of the accepted range); with it the same counts give −4 % to +0.1 %. Which part is off (OTP decode, formula or counter) is unknown. (`T3/S20`,`S30`,`S31`,`D`; L)

### 3.4 RX offset calibration wait
Phase G starts the calibration (M 70/3:3a 80 80), then polls 70/0:08 until bits 5:4 ≠ 0:
- at most 32 reads, no delay between reads;
- from the 4th retry on, each retry first pulses 70/0:2a bit6 (M 2a 40 40, M 2a 40 00);
- on timeout: M 70/3:3a 80 00 and a 70/0:2a bit6 pulse, then continue as if it had succeeded.

Then read 70/3:5a and 59 twice (results; RD discards them; traced ff, 8f), stop the calibration, and W1C 70/0:08 bits 5:4. Both traced loads saw 70/0:08 = 10 on the first read. (`T1/S01`,`T3/S20`,`S`; C for the traced path, L for the retry rule)

### 3.5 State after init (no source)
| Register | Value | Meaning | Conf |
|---|---|---|---|
| 58/0:08 | 0f | port enable bits (ports stay powered down regardless) | C (value) |
| 58/0:0d | 00 | all ports: source = original | C |
| 58/0:19, 1a, 1d | 0f, 02, af | timer 1 loaded but gated (§5.3); same in both loads | C |
| 58/1:10, 1d, 20 | 81, 80, 78 | bit6 of 1:10 = RX HDCP 2.x related, 0 | C (values), U (meaning) |
| 70/3:ab, ac | 4a, 40 | source HPD low | C |
| 70/0:26, 55 | ff, 00 | values of the HPD-low state | C |
| 70/0:c5 | 03 | also its value at the first read; RD clears bit0 after its first EDID load | C (value), U (meaning) |
| ports 1, 2: 0x01, 0x18, 0x84, 0x86, 0x88, 0xc1 | 00, 03, e4, 00, 57, c1 | powered down, HPD/RxSense event enables on, TMDS off, AV mute on | C |
| ports 0, 3: 0x84, 0x86, 0x88 | 60, 00, 0b | parked | C |

(`T1/S01`,`T3/S20`)

## 4. Scheduling

### 4.1 RD's task
| Fact | Ev | Conf |
|---|---|---|
| RD polls the splitter from its own work item, re-queued 50 ms after each run ends (20 ms after a resume) | `S` | L |
| Observed cycle: 56.6 ms without a source (533 cycles in 30.2 s), 62–65 ms with a locked input (S30 mean 64.2 ms; S24/S32 63–64 ms). Most of the difference is a 10 ms busy-wait in RD's EQ monitor state. It follows the 70/0:13 read in most locked cycles (35 of 51 in S32; §6.6) | `T1/S01i`,`T3`,`S` | C |
| Start-up: one idle tick, one 30 ms sleep, the init (§3), one tick of software state reset, then the cycle below | `S`,`T1/S01` | L |
| The splitter and IT6805 tasks share one worker: a long splitter tick stalls IT6805 polling. During RD's 500 ms EDID sleep (S20 t=597–1106) the IT6805 had no transfers. In `T4/S40` (aligned) the bus had no transfer at all for 535.2 ms (pub 1002.4–1537.6) | `T3/S20`,`T4/S40` | C |

### 4.2 RD's poll cycle
1. Read 58/0:05 (event summary, §5.1). If non-zero, run the event passes in this order: RX (bit4) → main block (bits 5, 6) → port 1 (bit1) → port 2 (bit2). (`T3/S31` t=29770; C)
2. EQ step: read 70/0:14, then 70/0:13, then advance the EQ state machine (§6.6).
3. Port 1 and port 2 video state machines (§7.5). No transfers while idle.
4. Housekeeping counters (§4.3).

Idle cost: 3 reads per cycle (58/0:05, 70/0:14, 70/0:13). With a locked input: ≈7 transfers per cycle on average. (`T1/S01i`,`T3/S30`; C)

### 4.3 RD's periodic extras
| Period | Action | Ev | Conf |
|---|---|---|---|
| every 6th cycle while the EQ monitor runs (locked input) | bit-error check, `seq/splitter-rx-biterr.tsv` (§6.6) | `T3/S30` (spacing 6 cycles in 75 of 84 intervals) | C |
| every 30 cycles (plus once at the 258 wrap) | read 70/0:13; if bit4 = 1 read 70/0:1a; if non-zero and (first time or 70/0:12 bit7 = 1): FIFO reset (§6.8) and W 70/0:12 = ff. RD reads 0x1a three times per check. Never triggered: 0x1a = 00 at every check | `T3/S30`,`S` | C (reads), L (action) |
| every 258 cycles (≈16.5 s) | if any lock bit (70/0:14 bits 5:3 ≠ 0): read 70/3:27–29, then the bit-error read with a 2-byte read of 70/3:ea (counts accumulate, logging only) | `T3/S20`,`S30`,`S31` | C |

### 4.4 What a driver must poll
- Per cycle: 58/0:05, 70/0:13, 70/0:14 (RD's three reads). On 58/0:05 bit4, the RX event pass (§6.2). On bits 5 or 6, the main-block pass (§5.2). On bit1 or bit2, the port event pass (§7.1). (`T3`; C for RD; the set is the minimum that reproduces RD's triggers)
- While port 1 is being brought up (§7.5), also 6a:03 each cycle. (`D`; L)
- Period 50 ms. RD's 10 ms EQ busy-wait and the 500 ms EDID sleep are not needed for correctness: sleep instead of busy-waiting, and do not hold the bus between steps. (`D`; L)
- GPIO 0x040 bit 10 may be the splitter's interrupt output (§5.1, open question 21). Until confirmed, poll.

## 5. Main block (0x58)

### 5.1 Event summary 58/0:05 (read-only)
| Bit | Source | Ev | Conf |
|---|---|---|---|
| 1 | port 1 events (6a:10–14) | `T3` | C |
| 2 | port 2 events (6c:10–14) | `S` | L |
| 4 | RX events (70/0:05–12), enabled bits only (§6.2) | `T3` | C |
| 5 | main-block status; which register feeds it (58/0:06 or 58/1:21–23) is unknown | `S` | L |
| 6 | main-block status; traced with 58/0:07 bit5 (timer 1) | `T3/S30`,`S31` | C |
| 0, 3, 7 | never set; RD ignores them (perhaps ports 0 and 3) | `T1`,`T3` | C (never set), U (meaning) |

- The summary clears when its sources are acknowledged: S30 t=34660.9 read 40, written back 58/0:07 = 20, next poll 00. Observed values: 00, 02, 10, 12, 40, 52. (`T3`; C)
- Interrupt output: no register in the analysed code configures an interrupt pin (enable, polarity, mask); none is known. GPIO 0x040 bit 10 (`regmap.md`) matches "high while splitter events are pending":
  - In T2/S10 its only fall (1 at raw trace time 612.3 ms, 0 at 631.5 ms) came while the IT6805 had no transfers and the splitter was soft-resetting port 1, which clears latched port events.
  - In T3/S20 it read 1 at t=181.8, before the splitter's first access (t=188.1), while the RX 5 V event was latched (the first poll found 58/0:05 = 10).
  - In `T4/S40` (aligned) it read 0 during init phase F and 1 right after phase H, with 5 V present (§3.1).
  - Candidate configuration registers, written at init with unknown purpose: 58/0:0e[2:0], 58/0:18 bit4, 58/0:2b, 2d, 2e, 30.
  - Open question 21. (`T2/S10`,`T3/S20`,`S`; U)

### 5.2 Main-block status (W1C)
RD's pass (`seq/splitter-main-event.tsv`): R 58/0:06, R 07, W 06, W 07 (values read); bank 1: R 21, 22, 23, write each back; bank 0; then act. (`T3/S30` t=34661, `S31` t=29807.6, 40224; C)

| Bit | RD action | Likely meaning | Ev | Conf |
|---|---|---|---|---|
| 06.0 | arm timer 0 with af | HDCP authentication start watchdog | `S` | U |
| 06.1 | stop timer 0 | HDCP authenticated | `S` | U |
| 06.2, 06.3 | internal HDCP flags (06.3 reads 58/1:23 bit4) | HDCP state change | `S` | U |
| 06.4 with 58/1:21 bit7 | read the HDCP 2.x stream type (58/1:17 = 3a, R 58/1:25) | HDCP 2.x stream type | `S` | U |
| 07.4 | timer 0 expired: stop it; 70/0:26 = ff; source HPD low, 100 ms, high; 70/0:26 = 00 | watchdog retry | `S` | L |
| 07.5 | timer 1 expired (§5.3) | — | `T3` | C |

Observed: 06 = 00, 58/1:21–23 = 00 in every pass; 07 = 20 three times. (`T3`; C)

### 5.3 Timers
| Reg | Use | Ev | Conf |
|---|---|---|---|
| 58/0:1a | bit0 timer 0 enable, bit1 timer 1 enable | `T3`,`S` | C (bit1), L (bit0) |
| 58/0:1c | timer 0 count (00 = stop) | `S` | L |
| 58/0:1d | timer 1 count (00 = stop) | `T3`,`S` | C |
| 58/0:19 | 3f while arming, 0f otherwise. With 0f written after an arm, the timer never fired (§3.2) | `T1`,`T3` | C (values), U (meaning) |
| 58/0:07 bit4 / bit5 | timer 0 / timer 1 expired (W1C) | `T3`,`S` | C (bit5) |

- Arm timer k: M 1a (bit k) 00; W 19 = 0f; W count register = N; W 19 = 3f; W 07 = ff; M 1a (bit k) (bit k). Stop: M 1a (bit k) 00; W 19 = 0f; W count register = 00. (`T3`,`S`; C for timer 1)
- Count a0 expired about 3 s after arming, but not after a fixed time. The poll-bounded windows of the three T3 arm/expiry pairs (S30 t=31658.5, S31 26742.4 and 37178.0) intersect at 2.98–3.00 s. The seven T4 pairs (S40 and the six mode changes) range from 2957.6–3021.8 ms (`T4/S44`, armed at t=50554.3) to 3065.3–3129.3 ms (`T4/S41`, armed at t=91534.4). The delay therefore varied by at least 65 ms between arms. Whether time is linear in the count (≈18.7 ms per count) is unknown. Count af (armed at init, gated) never fired, and count 81 was never armed. (`T3/S30`,`S31`,`T4`; C for a0 within 2.96–3.13 s, U for others)
- RD's uses:
  1. Count a0, armed at RX clock-stable (§6.3). On expiry (`seq/splitter-main-event.tsv`) RD stops it and reads 70/0:14. If no lock bit is set (bits 5:3 = 0) it also reads 70/0:13; if bit4 = 1 there, it toggles 70/3:e5 bits 3:2, sets e5 bit4 and re-arms with 81. Then it reads 70/0:14 again. The three traced expiries found lock (S30, S31 t=40224) or no input (S31 t=29807.6, 0x13 bit4 = 0), so only the stop path ran.
  2. Count af, armed by a port power-down when no port has HPD; on expiry the source HPD follows the port HPD. Gated by 19 = 0f; never fired.

  (`T3`,`S`; C for the stop path, L for the rest)
- A driver can replace both uses with host timers or omit them; nothing in the 1080p60 path depends on the chip timers. (`D`; L)

### 5.4 Other main-block registers
| Reg | Use as observed | Ev | Conf |
|---|---|---|---|
| 0x08 | bit n = port n enable: power-on sets, power-down clears | `T1`,`T3` | C |
| 0x0a | bit0 pulse at init (soft reset); bit2 pulse with 1 ms high in RX power-down | `T1`,`T3` | C (writes), U (names) |
| 0x0b | ff → 00 pulse: video path/FIFO reset (§6.8). Bits 7:2 pulse before port path setup. Bits 4:2 / 7:5 pulse when the last user of the chroma converter / down-scaler powers down (`S`, untraced) | `T3`,`S` | C (writes), U (names) |
| 0x0c | bit(4+n) pulse: port n reset. bit3 pulse: FIFO reset (§6.8, RX 0x12 bit7). bit2: set around the 5 V-on 0x10 bit6 pulse | `T1`,`T3` | C (writes), U (names) |
| 0x0d | 2 bits per port at [2n+1:2n]: port source. 0 original (bypass), 1 CSC, 2 4:2:0 → 4:4:4, 3 down-scale. Only 0 is ever written | `T3`,`S` | C (0), L (others) |
| 0x0e | bits 2:0 cleared at init | `T1` | U |
| 0x10 | 6e at init; bit6 pulsed low on 5 V-on | `T1`,`T3` | U |
| 0x11–0x14 | bit7 of 0x11 starts the RCLK measurement; count in 0x12–0x14 (§3.3) | `S` | L |
| 0x15 | bit0 = revision A1 | `T1` | C |
| 0x18 | bit4 set at init | `T1` | U |
| 0x1e, 0x1f | rclk in MHz, 8 fraction bits (§3.3) | `T1`,`S` | C |
| 0x2b, 0x2d, 0x2e, 0x30 | written ff, 0f, ff, 0f at init | `T1` | U |
| 0x31 | bits 1:0 cleared on RX SCDT off | `T3` | U |
| 0x4e | bits 3:0 = f during the FIFO reset; = c for 10 ms before port path setup | `T3` | U |
| 0x50, 0x51, 0x54, 0x61, 0x62 | OTP word address high/low, command (04 = read), data low/high | `T1`,`S` | C |
| 0x57, 0x58, 0x5f, 0xff | OTP window setup; 0xff = protection key (c3, a5 unlock; ff lock) | `T1` | C (values), U (names) |
| 0x67, 0x68 | converter options: 0x67 bits 3:0 and 0x68 cleared on SCDT on | `T3`,`S` | U |
| 0x69 | bits 5, 3:0 cleared when 5 V appears with an HDMI (not MHL) input | `T3` | U |
| 0x6b, 0x6c, 0x6d | CSC routing, written after each AVI change (§6.7); 0x6d bits 5:4 cleared at init | `T3`,`S` | U |
| 0x70–0x84, 0x88–0xa4 | two CSC blocks: 3 offset bytes + nine 16-bit coefficients each (§6.7) | `T3`,`S` | L |
| 0xf0, 0xf1 | sub-device enables (§2.3) | `T1` | C |
| bank 1 0x10 | bit0 set and bit3 cleared at init; bit6 = 0 at init, set by RD after loading an EDID with an HDMI VSDB (81 → c1). Meaning of bit6 unknown (RX HDCP 2.x capability?) | `T1`,`T3/S20` | C (values), U (meaning) |
| bank 1 0x11 | bit1 set by RD on RX link-error events (§6.2) | `S` | L |
| bank 1 0x1d, 0x20 | bit7; bits 6:3 set at init | `T1` | U |
| bank 1 0x17, 0x25, 0x1e–0x1f, 0x28–0x2d, 0x52–0x65, 0x81 | HDCP repeater (stream type, KSV, SHA) engine; never accessed in traces | `S` | L |

## 6. RX side (0x70)

### 6.1 Level registers (bank 0)
Decide on single bits, not whole values: values differ between unplug events (`hdmi-chips.md` cross-chip rules).

| Reg | Bits | Observed | Ev | Conf |
|---|---|---|---|---|
| 0x13 | bit0 input 5 V · bit1 HDMI (1) / DVI (0) · bit3 input clock present (RD's clock-change decision) · bit4 input clock stable (gates EQ start, housekeeping, the timer retry) · bit6 MHL · bit7 required by RD's lock action · bits 2, 5: unknown | bf locked; bd from lock until bit1 sets (0.1–0.36 s in S30/S31; S20 and `T4/S40` read bf before SCDT on; in the six T4 mode changes bd, once briefly bf, from the lock until the first 0x13 read after SCDT on, which RD makes after port 1's full power-on, 0.22–0.48 s after the change's first pass, RGB and 4:2:0 alike); 01, 81, a1 with 5 V and no TMDS; a0 (S30) or 80 (S31) without 5 V | `T3`,`T4`,`S` | C (bit0, bit1, values), L (bits 3, 4, 7), U (bits 2, 5) |
| 0x14 | bits 5:3 per-channel lock (38 = all three) · bit6 RD's HDMI 2.0 EQ path selector · bit7 HDMI 2.0-related (selects RD's HDMI 2.0 search and CSC path) · bit0 copied to 70/3:a7 bit6 at SCDT on | 3b locked (bits 6, 7 = 0 at 1080p60 and at 2160p 4:2:0 / 297 MHz); 00/01 unlocked | `T3`,`S` | C (bits 5:3), U (bits 6, 7, 0) |
| 0x15 | bits 5:2 HDMI 2.0 detect state | c0 with 5 V, 00 without (T3); in T4 also 00 twice with 5 V and a locked input, each time with event 0x09 = 20 | `T3`,`T4`,`S` | U |
| 0x19 | bit7 SCDT (video stable) | b0 stable; 30 TMDS present before SCDT; 20 or 00 without TMDS. Once in T4 (`T4/S44` t=1988.0, change to 1080p60), 0x19 read b0 one poll (100 ms) before the SCDT event (0x10 bit1) latched; RD acts on the event | `T3`,`T4/S44` | C |
| 0x1a, 0x1b | detail of event 0x12 bit7; cleared by writing ff / 07 | 1a = 01 at arrival, 00 later; 1b = 08 | `T3` | C (values), U (meaning) |
| 0x1d | read by RD in every event pass, never written | always ff | `T3` | C |
| 0x98 | bits 5:4 input colour depth (0 = 8 bit, 1 = 10, 2 = 12) | 48 at 1080p60 and 2160p (8 bit); 40 once, at the first read after a 1080p lock; 08 in every T4 mode (PC source): bit6 depends on the source, meaning unknown | `T3`,`T4`,`S` | C (values), L (field) |
| 0xd0 | bit0 = source HDCP active (bank 0!) | 14 at every lock | `T3`,`S` | L |
| 0xd6 | bit6 = HDCP 2.x when active | not read | `S` | L |

Note: the names of bits 3 and 4 follow `hdmi-it6805.md`; some analyses swap them. Both bits were set together in every trace, so the traces cannot separate them. Port the logic by bit number. (`T3`,`S`; C for the conflict)

### 6.2 Event registers (bank 0, W1C)
RD's RX event pass, run when 58/0:05 bit4 is set (`T3`; C):
1. Read 05, 06, 07, 08, 09, 10, 11, 12, 13, 14, 15, 19, 1a, 1b, 1d.
2. Write back 05–09, 10, 11 at once.
3. Act on the bits in register order.
4. Write back 0x12 last.

The rows are in every event table (`seq/splitter-rx-*.tsv`).

| Bit | Event | RD action | Seen | Ev | Conf |
|---|---|---|---|---|---|
| 05.0 | 5 V changed (level 0x13 bit0) | 5 V on or 5 V off (§6.3) | every plug/unplug | `T3` | C |
| 05.1 | bus mode changed | R 0x13 (bus check): MHL if bit6; always HDMI here | with TMDS changes | `T3`,`T4`,`S` | C |
| 05.2 | clock changed | clock stable or clock lost, by 0x13 bit3 (§6.3) | every TMDS change | `T3` | C |
| 05.3 | — | none | at the S31 losses (0d, 4e) | `T3/S31` | C (seen) |
| 05.4 | HDMI/DVI mode changed (0x13 bit1) | R 0x13 for RD's log; no action | with the first AVI event of each lock (S20; all six T4 mode changes), while 0x13 read bd (once bf, `T4/S44` t=50548.0) | `T3`,`T4`,`S` | C |
| 05.5 | link error | only if no EQ search runs: set 58/1:11 bit1 and count; above 50 events: source HPD low, 100 ms, high, count reset. Untraced | never | `S` | L |
| 05.6 | deskew error | none (log) | S31 arrivals and loss (56, 4e) | `T3/S31`,`S` | C |
| 05.7 | — | cleared by the clock procedures | — | `S` | L |
| 06.0 | lock changed | 0x13 bit7 = 1: lock action (§6.3). 0x13 bit7 = 0 (non-MHL input): lock lost (§6.3), with fixed EQ 81 if no search runs | 01 at every arrival; b1 or 31 at every T4 TMDS loss (0x13 = 01); a1, b1 at the two T4 re-locks within one poll (0x13 = bf, bd) | `T3`,`T4`,`S` | C |
| 06.4, 06.5, 06.7 | — | none | with 06.0 in T4 (b1, 31, a1) | `T4` | C (seen) |
| 07.4, 07.6, 07.7 | EQ search done | apply the result (§6.6) | 40 after every search | `T3`,`S` | C |
| 07.0–07.2 | — | none. They re-latch every cycle while 5 V is present without TMDS and 0x55 bits 2:0 are set; RD's HPD-high routine writes 0x55 = ff (S31 t=24728.6–26732.5: 0x07 = 07 in every pass). 04 once, at a lock | yes | `T3/S31` | C |
| 08.0 | EQ fault | EQ defaults, restart the search | never | `S` | L |
| 08.4, 08.5 | offset calibration done (§3.4) | — | init | `T1` | C |
| 08.6 | — | none | 40 with EQ done | `T3` | C (seen) |
| 08.7 | HDMI 2.0 detect state changed (0x15) | M 70/0:4c 80 80 | never | `S` | L |
| 09.1, 09.2, 09.3 | HDCP authenticated / encryption changed (level 0xcf bit5) / HDCP off | internal state; "on" also re-arms main timer 0 | never | `S` | L |
| 09.5 | — (probably 0x15 changed) | none | 20 each time 0x15 read 00: at a 5 V loss (S31), and twice with 5 V (`T4/S40` t=89.6, `T4/S44` t=50823.9) | `T3/S31`,`T4` | C (seen), L (pairing) |
| 10.1 | SCDT changed (level 0x19 bit7) | SCDT on or SCDT off (§6.3) | every stable/loss | `T3` | C |
| 10.2 | — | M 70/0:40 03 00 | with SCDT on (S20: 06; T4: 06, four times); one poll after SCDT on (S31: 04, twice; T4: 04, three times) | `T3`,`T4` | C |
| 10.4, 10.5 | — | none | T4: 0x10 = 10, 12, 22, 30 with lock or SCDT events | `T4` | C (seen) |
| 11.2 | packet change | read bank 2 regs 2a, 29, 28, 2c (unused) | never | `S` | L |
| 11.3 | colour depth change | read 0x98 | 08 at arrivals | `T3` | C |
| 12.0 | AVI InfoFrame changed | AVI read and CSC setup (§6.7) | 91 at arrivals (T3); 01 or 81 once per T4 lock, RGB modes included | `T3`,`T4` | C |
| 12.4 | — | none | inside 91 | `T3` | C (seen) |
| 12.7 | error/status event, detail in 0x1a/0x1b | R 1a, R 1b; W 1a = ff; W 1b = 07; pulse 58/0:0c bit3 | 91 at arrivals, 80 at the S31 losses | `T3` | C |

Event enables (inferred pairing: enable for 0x05–0x09 in 0x53–0x57, for 0x10–0x12 in 0x5d–0x5f):
- RD toggles these bit for bit with the events it handles: init 0x53 = 0f, 0x56 = 0x57 = ff; lock action sets 0x53 bits 7:5, 0x55 bits 2:0, 0x57 bits 3:0, 0x5d bits 2:1, 0x5e bit3, 0x5f bit0; clock procedures and power-down clear them; HPD high writes 0x55 = ff, HPD low 0x55 = 00. (`T3`,`S`; C for the writes, L for the pairing)
- They gate only the summary bit 58/0:05 bit4, not the latch: 0x06 bit0 latched while 0x54 bit0 = 0 (S30 t=31649.6), and 0x05 bit4 latched while 0x53 bit4 = 0. A driver may read 0x05–0x12 directly, but replaying RD's enable writes keeps the summary usable. (`T3/S30`; C)

### 6.3 Event procedures
All procedures assume bank 0 and return to it.

| Event | Procedure | Table | Ev | Conf |
|---|---|---|---|---|
| **5 V on** (05.0, 0x13 bit0 = 1) | pulse 58/0:0c bit2 around a 58/0:10 bit6 low pulse; check HDMI bus (0x13 bit6 = 0); M 70/3:3a 06 02; M 70/0:29 01 00; M 70/0:26 0c 00; M 58/0:69 2f 00; source HPD high if an EDID is loaded (§6.4) | `seq/splitter-rx-5v-on.tsv` | `T3/S20` t=391.8, `S30` 31272.5, `S31` 33540.5 | C |
| **5 V off** (05.0, bit0 = 0) | RX power-down (below), then power-down of all four ports (§7.2) | `seq/splitter-rx-5v-off.tsv` | `T3/S30` t=22094.9, `S31` 29770.6 | C |
| **RX power-down** | clear event enables (53 bits 7:5, 54, 55 bits 2:0, 57 bits 3:0); pulse 0xc5 bit4; pulse 58/0:0a bit2 for 1 ms; source HPD low (§6.4); EQ defaults (70/3:27–29 = 9f, 20 = 1b, 21 = 03); RD also forgets stored EQ results | `seq/splitter-rx-power-down.tsv` | `T1/S01`, `T3/S20` t=594.6, `S30` 22097.5, `S31` 29773.2 | C |
| **clock lost** (05.2, 0x13 bit3 = 0) | W 05 = 04; clear enables 53 bits 7:5, 54, 55 bits 2:0; W 05 = e8; W 06 = fe; M 54 01 00; pulse 0x23 bit4 (1 ms high); all four ports 0x88 bits 1:0 = 11 (TMDS off); M 70/3:e5 1c 00; pulse 0x23 bit1 | rows in `splitter-rx-5v-off.tsv`, `splitter-rx-signal-loss.tsv` | `T3/S30` t=22122.2, `S31` 24731.6, 29797.6 | C |
| **lock lost** (06.0, 0x13 bit7 = 0) | M 53 e0 00; M 55 07 00; M 5d 06 00; M 5e 08 00; M 5f 01 00; if no EQ search runs: bank 3, W 27, 28, 29 = 81 | rows in `splitter-rx-signal-loss.tsv` | `T4/S41` t=91447.7, `S43` 90041.4, `S44` 1832.2, `S45` 7767.9 | C |
| **clock stable** (05.2, bit3 = 1) | same first step; M 0x23 02 00; RD reads every port's 0x03 (RxSense snapshot); M 54 01 01; arm timer 1 with a0 (optional, §5.3) | `seq/splitter-rx-lock.tsv` | `T3/S20` t=3592.2, `S30` 31648.5, `S31` 26732.5, 37171.0 | C |
| **lock** (06.0 with 0x13 bit7 = 1) | set enables 53 bits 7:5, 55 bits 2:0, 57 bits 3:0, 5d bits 2:1, 5e bit3, 5f bit0; start the HDMI 1.x EQ search or re-apply a stored result (§6.6) | `seq/splitter-rx-lock.tsv` | same | C |
| **SCDT on** (10.1, 0x19 bit7 = 1) | M 0x40 03 00; FIFO reset (§6.8); full power-on of every port 1/2 that has HPD (§7.2); M 58/0:67 0f 00; 58/0:68 = 00; 70/3:a7 bit6 = 0x14 bit0 | `seq/splitter-rx-scdt-on.tsv` | `T3/S20` t=3684.1, `S30` 31884.5, `S31` 26828.4, 37240.1 | C |
| **SCDT off** (10.1, bit7 = 0) | M 0x40 03 02; 58/0:0d = 00; M 58/0:31 03 00; ports 1 and 2: event enables 0x18 bit7 and 0x19–0x1c off, TMDS off, **port soft reset** (0x01 bits 1:0 set then cleared) | rows in `splitter-rx-5v-off.tsv`, `splitter-rx-signal-loss.tsv` | `T3/S30` t=22127.1, `S31` 24737.1, 29802.6 | C |
| **AVI change** (12.0) | read the AVI InfoFrame (§6.7); program the CSC blocks (unused by the capture path) | X rows in `splitter-rx-lock.tsv`, `splitter-rx-scdt-on.tsv` | `T3` | C |
| **12.7** | R 1a, R 1b, W 1a = ff, W 1b = 07, pulse 58/0:0c bit3 | rows in `splitter-rx-lock.tsv`, `splitter-rx-signal-loss.tsv`, `splitter-rx-5v-off.tsv`, `splitter-rx-scdt-on.tsv` | `T3` | C |

Notes:
- Events arrive together when the link changes at once: S30 unplug latched 05 = 05 and 10 = 02 together, so RD ran 5 V off, clock lost and SCDT off in one pass. Composition varies between scenarios: S31's second lock delivered the 0x11/0x12 (AVI) events one poll later, with SCDT on, and S31's 5 V loss came with 0x12 = 80 and a timer expiry. The tables carry the traced variants as `cond:` rows named after the event bit. A driver should handle each bit on its own, in register order. (`T3`; C)
- In S31's mode change (5 V held), the source HPD stays high, clock lost and SCDT off reset ports 1 and 2, and the link comes back through the same lock/SCDT-on path (§9.5). The six T4 mode changes did the same, with the lock-lost rows in the loss pass (§9.8). (`T3/S31`,`T4`; C)
- A source mode change can keep the RX locked across a poll. At `T4/S44` t=50548.0 (1080p60 → 2160p60 4:2:0) and `T4/S45` t=236.2 (2160p60 4:2:0 → 2160p30 RGB, both 297 MHz), the first pass already showed clock stable (05.2 with bit3 = 1), lock (06.0 with bit7 = 1) and SCDT off (10.1 with 0x19 = 30). RD ran, in register order, clock stable, the lock action with the stored EQ codes, then SCDT off with the port 1/2 soft reset (`seq/splitter-rx-lock.tsv`, SCDT-off rows). SCDT came back 100 and 164 ms later. (`T4`; C)

### 6.4 HPD toward the source
| Fact | Ev | Conf |
|---|---|---|
| Register 70/3:ab. ca = HPD asserted, 4a = deasserted (init state). Bit7 is the level. The source started TMDS only after ab = ca, in all three traced cases | `T1`,`T3/S20`,`S30`,`S31`,`S` | C (values), L (bit7 = level) |
| Assert (`seq/splitter-rx-hpd-high.tsv`): R 0x13; continue only if bit0 (5 V) = 1. Bank 3: R ab; if not ca, W ab = ca. Bank 0: W 26 = 00, W 55 = ff | ab = ca at `T3/S20` t=454.21 and 1105.47, `S30` 31283.07, `S31` 33549.05; `S` | C |
| Deassert (`seq/splitter-rx-hpd-low.tsv`): bank 3: R ab; if ca: W ab = 4a, W ab = 00, W ac = 00. Bank 0: W 26 = ff, W 55 = 00 | ab = 4a at `T3/S20` t=593.90, `S30` 22100.83, `S31` 29776.29 | C |
| After the first deassert ab/ac stay 00/00 instead of 4a/40. Later asserts still worked. Roles of ab bits 6, 3, 1 and of ac: unknown | `T3/S30`,`S31` | C (observation), U (roles) |
| 70/0:26 is ff with HPD low and 00 with HPD high; 5 V-on clears its bits 3:2. Meaning unknown (RX termination control is one candidate). 70/0:55 is the 0x07 event enable. Replay both with every HPD change | `T3`,`S` | C (values), U (meaning) |
| RD asserts only while 5 V is present (0x13 bit0) and its routine writes nothing otherwise. With no source HPD stays low (T1: 0x13 = 00 throughout) | `T1/S01i`,`T3`,`S` | C |

RD's triggers (`S`; traced cases noted):
- 5 V appears and some port EDID was parsed: assert (S30, S31; with no EDID parsed, S20, no assert).
- Port 1/2 HPD or RxSense rises: assert (S20 t=454.2; S30, S31 rewrite 26/55 only, since ab already reads ca).
- 5 V lost: deassert inside RX power-down (S30, S31).
- EDID RAM content changed: deassert, RX power-down, sleep 500 ms, assert (S20: low 593.9–1105.5 ms).
- Timer 0 expiry, more than 50 link errors: 100 ms low pulse. Timer 1 (af): follow port HPD. (`S` only)

Ordering facts:
- RD raised HPD at 454.21 ms, before the EDID RAM was loaded (540–593 ms), then repaired it with the 500 ms toggle. A driver must load the RAM first (`hdmi-chips.md`). (`T3/S20`; C)
- RD raised HPD before loading the RAM in `T4/S40` too (aligned: HPD high at pub 846.4, RAM load 909.7–995.5, toggle low 996.8–1538.5). (`T4/S40`; L)
- HPD high to first TMDS: 2.49 s (S20), 0.37 s (S30), 3.62 s (S31), 0.74 s (`T4/S40`, PC source; lock pass at pub 2280.1). Source-dependent. (`T3`,`T4`; C, L for T4/S40)
- After the load, T4 has no write to 70/3:ab: RD's HPD routine ran at every port 1 HPD/RxSense event and found ab = ca. Mode changes at the source never moved the source HPD. (`T4`; C)

### 6.5 EDID RAM (0xd8)
| Fact | Ev | Conf |
|---|---|---|
| 256-byte RAM at I2C 0xd8 after `W 70/0:4b = d9`, written with single-byte writes | `T3/S20` | C |
| RD writes offsets 00–7e and 80–fe only (254 writes). The checksum bytes go to 70/0:c9 (block 0) and 70/0:ca (block 1). Both images sum to 0 mod 256 with these bytes in place | `T3/S20` | C |
| RD's order: M 34 01 00; W c6 = 00; W c7, c8 = physical address bytes AB, CD of the image's HDMI VSDB (traced 10, 00); W 4b = d9; W c9; block 0; block 1; W ca; bank 1: M 58/1:10 40 (40 if the image has an HDMI VSDB); if the content changed: M c5 01 01, HPD low, RX power-down, 500 ms, HPD high; M c5 01 00; M 34 01 01 | `T3/S20` t=511.4–1107.6 (4b at 511.94, c9 at 540.33, block 0 at 540.42–551.95, block 1 at 580.92–592.53, ca at 592.62) | C |
| 70/0:34 bit0 read 1 before the first load and is held 0 during the update. 70/0:c5 bit0 reads 1 at the first access (init writes 1 again) until the first load, and is 1 during RD's HPD toggle. Roles (DDC gating?) unknown | `T1`,`T2/S10`,`T3/S20` | C (values), U (roles) |
| 70/0:c6 = 00 in every RD path; c7/c8 = sink physical address (copy path) or 00/ff (other paths, untraced). In the IT6805, c6 holds the offset of the physical address inside the image. With c6 = 00 the splitter apparently substitutes nothing: the served image was valid and the source used it | `T3/S20`,`S` | C (values), U (function) |
| The RAM content before the first load is unknown; RD's no-source load leaves the RAM unwritten, with HPD low | `T1/S01` | C (no writes), U (content) |
| Each 127-write block took ≈11.5 ms, ≈0.09 ms per write (S20 t=540.4–551.9 and 580.9–592.5; `T4/S40` aligned: 12.5 and 11.9 ms). RD re-read block 1 over DDC between the two blocks | `T3/S20`,`T4/S40` | C |

Driver procedure: `seq/splitter-rx-edid-load.tsv`. Image limits: at most 2 blocks (256 bytes). Block 1 is a CTA-861 extension, and the checksums are computed by the driver. The image should be the same as the one loaded into the IT6805 RAM (`hdmi-chips.md` EDID policy). Writing RAM offsets 7f/ff as well is untested (U); follow RD and leave them out.

### 6.6 Equaliser (EQ)
Registers (bank 3 unless noted):
| Reg | Use | Values | Ev | Conf |
|---|---|---|---|---|
| 27, 28, 29 | EQ code, channels 0/1/2 | default 9f; search start 1f; applied = result \| 80. Fixed 87 when clock-stable finds no lock and no stored result (code only); fixed 81 from the lock-lost path (every T4 TMDS loss, §6.3) | `T1`,`T3`,`T4`,`S` | C (9f, 1f, applied, 81), L (87) |
| 20, 21 | EQ mode | 1b/03 default; 36/0e during and after an HDMI 1.x search | `T3` | C |
| 22 | bits 5:3 per-channel search enable; bit2 start pulse; bit6 set by apply | `T3` | C |
| 26 (bank 3) | 00 at search start | `T3` | C |
| d0 | 2 bits per channel, 3 = result valid | 3f | `T3` | C |
| d5, d6, d7 | search result per channel, bits 6:0 | 2160p 4:2:0: 7f/7f/7e (S20), 7e/7e/3f (S30), 3e/1f/3e (`T4/S40`, PC source); 1080p: 7e/3f/3f (S31) | `T3`,`T4` | C |
| e9 | bits 6:5 error-counter channel; 80 = end | `T3` | C |
| ea, eb | error count [7:0]; eb bit7 = valid, bits 6:0 = count [14:8] | ea = 00, eb = 80 in every read of every T3 scenario and in all 3000 channel reads of T4 | `T3`,`T4` | C |
| 70/0:07 | bits 4, 6, 7: search done | 40 | `T3` | C |

HDMI 1.x search (TMDS ≤ 340 MHz), rows in `seq/splitter-rx-lock.tsv` and `seq/splitter-rx-eq-apply.tsv`:
1. Start (EQ step of the lock cycle): W 70/0:07 = ff; W 70/0:23 = b0, a0. Bank 3: W 20 = 36, 21 = 0e, 26 = 00, 27–29 = 1f; M 22 38 38; M 22 04 04; 1 ms; M 22 04 00.
2. The hardware searches per channel. Done (70/0:07 bit6) was set at the first poll after the start in all three searches, 55–58 ms later; the true duration is shorter.
3. Apply (`seq/splitter-rx-eq-apply.tsv`): read d5–d7 and d0. Valid channel: code = result | 80. Invalid channel: the first valid channel's code. No valid channel: 9f on all and restart (at most 3 attempts). Bank 3: M 22 44 40. Bank 0: M 07 30 30. Bank 3: M 22 38 00; W 27–29 = codes; W e9 = 80; 10 ms. Bank 0: M 53 20 20; W 05 = 20.
4. Check, next poll: once 0x14 bits 5:3 = 111, run the bit-error check (`seq/splitter-rx-biterr.tsv`). Pass per channel: eb bit7 = 1 and ea ≤ 50. RD compares the low byte only.
5. Monitor: RD repeats the check every 6th cycle. For channels that fail (only when 0x14 bit6 = 0) it steps the code through a fixed list of seven codes. That list is code only, never used in the traces, and not reproduced here. A driver can re-run the search instead.

(`T3/S20`,`S30`,`S31`,`S`; C for steps 1–4 as traced, L for failure branches)

Re-use: if a result for the current mode is stored, RD re-applies it at lock instead of searching (`cond:` rows in `seq/splitter-rx-lock.tsv`). Bank 3: W 20 = 36, W 21 = 0e, M 22 40 00, W 27–29 = stored codes. Seen in S31 t=26745.7: the 1080p arrival after the mode change re-used the 2160p codes fe/fe/bf, and the bit-error check in the same cycle passed. RX power-down (5 V loss) discards stored results. (`T3/S31`; C)

In T4 the session's only search (`T4/S40`, applied at t=23.9: be/9f/be) was re-used at all six mode changes, for 1080p60, 2160p30 RGB and 2160p60 4:2:0, and all 1000 T4 bit-error checks read zero errors. The stored result is kept per HDMI 1.x/2.0 EQ path, not per video mode. (`T4`,`S`; C for the re-use, L for the keying)

Is the search needed at ≤ 340 MHz?
- With the fixed defaults (27–29 = 9f, 20 = 1b, 21 = 03, 22 = 00/40) all three channels showed lock immediately at TMDS arrival, at 297 MHz (S30, after power-down) and at 148.5 MHz (S31): 0x14 = 3b, 0x13 = bd. (`T3/S30`,`S31`; C)
- SCDT was set at the first poll after the lock pass in all four T3 locks: before any search had finished (S20, S30, S31 #2) and with re-used codes (S31 #1). In T4 it came 100–180 ms after the lock pass (at the first or second poll after it in the six mode changes), with re-used codes or, at S40, after the search. So SCDT does not depend on the search. (`T3`,`T4`; C)
- Bit errors were measured only with searched or re-used codes (all zero), never with the fixed 9f. (`T3`; C)
- Minimal fixed configuration (RD's init and power-down values): bank 3 20 = 1b, 21 = 03, 27 = 28 = 29 = 9f, with 22 and 26 at their reset value 00 (both read 00 before first use). Locks at 1080p60 (traced); error rate untested. (`T1`,`T3`; C for lock, U for errors)
- Recommendation: run the HDMI 1.x search once per lock (≈20 transfers plus one poll) and keep the bit-error check as a health check. Whether fixed 9f is enough on long or poor cables: UNVERIFIED. Evidence needed: bit-error counts with fixed 9f over a 2 h soak. (`D`; L)

HDMI 2.0 search (0x14 bit6 = 1, TMDS > 340 MHz): code only, never traced.
- Setup writes bank 3 regs 20, 22, 26–29, 2d, 30–39, 4a, 4b, 54, 55; then a search, DFE values in bank 3 4b–53, an amplitude sweep, and a skew step.
- RD polls 70/0:07 bit4 for the skew step with no timeout. A driver must bound it (proposal: 100 ms, then keep the searched codes and skip the skew step).
- Status: UNVERIFIED (open question 14 path). (`S`; L for the register list, U for behaviour)

### 6.7 Video information
Timing measurement (bank 0), read by RD before port path setup (X step `timing-read` in `seq/splitter-tx1-output-enable.tsv`):

| Regs | Field | 1080p60 (S31) | 2160p60 4:2:0 (S30) | Ev | Conf |
|---|---|---|---|---|---|
| 0x9a[1:0]:0x99 | TMDS clock count; TMDS kHz = rclk × 512 / count (RD averages 100 reads) | 04e/04f | 027 | `T3`,`S` | C (values), L (formula), U (0x9a[1:0] as upper bits) |
| 0x9a bit7 | unknown | 1 | 1 | `T3` | U |
| 0x9c[5:0]:0x9b | H total | 898 = 2200 | 898 (TMDS clocks, half of 4400) | `T3` | C |
| 0x9e[5:0]:0x9d | H active | 780 = 1920 | 780 (half of 3840) | `T3` | C |
| 0xa1:0xa0 | H front porch | 0058 = 88 | 88 | `T3` | C (low byte), U (upper bits) |
| 0x9f | H sync | 2c = 44 | 44 | `T3` | C |
| 0xa3[5:0]:0xa2 | V total | 465 = 1125 | 8ca = 2250 | `T3` | C |
| 0xa5[5:0]:0xa4 | V active | 438 = 1080 | 870 = 2160 | `T3` | C |
| 0xa8:0xa7 | V front porch | 4 | 8 | `T3` | C (low byte), U (upper bits) |
| 0xa6 | V sync | 5 | 0a = 10 | `T3` | C |
| 0xaa | flags; bits 6:5 probably sync polarity (both modes positive) | 60 | 60 | `T3` | U |
| 0x43 | bit5 differs between modes | 01 | 21 | `T3` | U |
| 0x48 | read 100 times before the measurement | 13 | 13 | `T3` | U |

- Front-porch upper bits: every traced value had them 0. In the IT6805 the upper nibble sits at bits 11:8 (`hdmi-it6805.md`); assume the same here, UNVERIFIED (evidence: a mode with front porch ≥ 256, e.g. 1080p50). (U)
- The capture path does not use these values; the IT6805 measures its own. Use them only as a cross-check. (`S`; L)
- 2160p30 RGB (`T4/S43` t=90668.4, `S45` 906.8): count 027, H total 4400, H active 3840, H front porch 176, H sync 88, V total 2250, V active 2160, V front porch 8, V sync 10, 0xaa = 61, 0x43 = 21, 0x48 = 13. This is the full-width timing at the same TMDS clock as 2160p60 4:2:0. 1080p60 and 2160p60 4:2:0 from the PC source read as in T3, apart from 0x98 (§6.1). (`T4`; C)
- 0x43 bit5 = 1 in both 297 MHz modes (4:2:0 and RGB) and 0 at 148.5 MHz: it follows the TMDS clock, not the colour format. 0xaa bit0 = 1 only at 2160p30. Meanings unknown. (`T3`,`T4`; C for values, U for meanings)

AVI InfoFrame (bank 2), read on 0x12 bit0:
| Reg | Content | Ev | Conf |
|---|---|---|---|
| 0x12 | length (0d) | `T3`,`D` | C |
| 0x13 | version (02) | `T3`,`D` | C |
| 0x14 | checksum (PB0) | `T3`,`D` | C |
| 0x15–0x23 | PB1–PB15. PB1 bits 6:5 colour format (0 RGB, 1 4:2:2, 2 4:4:4, 3 4:2:0), PB2 bits 7:6 colorimetry, PB4 VIC | `T3`,`D` | C |

- Check: 0x82 + the 18 register bytes ≡ 0 mod 256 in all traced frames (1080p: 0d 02 77 40 a8 00 10, rest 0; 2160p: 0d 02 06 60 a8 00 61, rest 0). (`T3/S20`,`S30`,`S31`,`D`; C)
- PC source (T4), same check, rest 0: 1080p60 0d 02 af 00 28 88 10 (RGB, no colorimetry, 16:9, full range, IT content, VIC 16); 2160p30 0d 02 60 00 28 88 5f (VIC 95); 2160p60 0d 02 82 60 a8 84 61 (4:2:0, BT.709, limited range, IT content, VIC 97). Every T4 mode, RGB included, carried an AVI InfoFrame, and the IT6805 received the same frames (`hdmi-it6805.md`). (`T4`,`D`; C)
- RD's stability wait: if the frame equals the stored copy, re-read every 5 ms (at most 20 times) until it changes. Then re-read every 1 ms until 5 consecutive reads agree, with no timeout. Both phases are traced at `T4/S43` t=90118.6. The AVI event came before the new frame. The first two reads, 7.1 ms apart, still returned the old one (VIC 16), the third (7.5 ms later) the new one (VIC 95), and five agreeing reads followed 3.2–3.4 ms apart: 8 reads in all. The five other T4 mode changes read the new frame at once: 6 reads, 3.2–3.5 ms apart. A driver must bound the second phase (proposal: 50 reads, then use the last value). (`S`,`T3/S31`,`T4`; C)

Internal CSC (58/0:70–84 block A, 88–a4 block B; 3 offset bytes then nine 16-bit coefficients):
- RD reprograms it after every AVI change. Block B is written only for 4:2:0 input (or with 0x14 bit7). The control bytes 58/0:6b/6c follow (4:2:0: 28/28; 1080p 4:4:4: 63/00; RGB: 6a/00, T4). For RGB input RD loads block A with an RGB-to-YCbCr table. With the AVI colorimetry field not set to BT.709 (T4: PB2 = 28) it picks its BT.601 table.
- Port 1 always selects "original" (58/0:0d port 1 field = 0), so this conversion is not in the capture path. A driver may skip it (X step `csc-program`). (`T3`,`T4`,`S`; C for the traced writes and for the bypass, L for skipping)
- Input without AVI (DVI mode): untraced; the PC source sent an AVI InfoFrame in every mode. In RD's code the stability wait and the CSC setup run only from the AVI event (12.0), from the AVI registers. Without AVI neither runs, and the CSC keeps its previous setting; that setting does not reach the capture path. What the RX reports when a source stops sending AVI is untraced. Port 1 takes its HDMI/DVI mode from 0x13 bit1 at output enable (§7.5), so a DVI source reaches the IT6805 as DVI; the IT6805's colour handling for that case is in `hdmi-it6805.md`. UNVERIFIED. Evidence needed: a DVI-mode source, for example the PC loopback with an EDID that has no HDMI VSDB. (`S`; L)

### 6.8 FIFO and datapath resets (main block)
| When (RD) | Writes | Ev | Conf |
|---|---|---|---|
| SCDT on; HDMI 2.0 EQ apply; 30-cycle check | W 58/0:0b = ff, 00; M 4e 0f 0f; pulse 0c bit3; M 4e 0f 00 | 4e = ff at `T3/S20` t=3688.7, `S30` 31891.0, `S31` 26835.6, 37244.6; `S` | C |
| before port path setup (no port running) | M 0b fc fc, M 0b fc 00; M 4e 0f 0c; 10 ms; M 4e 0f 00 | 4e = fc at `T3/S20` t=3881.3, `S30` 32085.8, `S31` 27040.7, 37605.2 | C |
| RX 0x12 bit7 | pulse 58/0:0c bit3 | `T3` | C |
| 5 V on | 58/0:0c bit2 set around a 58/0:10 bit6 low pulse | `T3` | C |
| RX power-down | 58/0:0a bit2 high for 1 ms | `T1`,`T3` | C |

### 6.9 HDCP on the RX
| Fact | Ev | Conf |
|---|---|---|
| RX HDCP 2.x stays disabled: 70/0:e3 = 00 at init; 58/1:10 bit6 = 0 at init, set by RD after loading an HDMI EDID (meaning U) | `T1`,`T3/S20` | C |
| The test source was behind an HDCP stripper: no 70/0:09 HDCP event, no main-block HDCP event, 70/0:d0 bit0 = 0 at every lock, bank 0x70/1 never selected | `T3` | C |
| RD contains a sequence that disables RX HDCP (58/0:0a bit2 set, M 70/0:23 42 42, 58/0:0c bit2 set, then an HPD pulse). Its trigger is never set, so it never runs | `S` | L |
| Keeping HDCP off needs no writes beyond the init values. Behaviour with an encrypting source is unknown (open question 25) | `T3`,`S` | C (no writes needed for the test source), U (encrypting source) |

## 7. TX side (ports 0x68–0x6e; capture path = port 1, 0x6a)

### 7.1 Status and events
Level register 0x03 (read when needed; one transfer):
| Bit | Meaning (from behaviour) | Ev | Conf |
|---|---|---|---|
| 0 | HPD from the downstream sink (port 1: GPIO 0x040 bit 2 line, §2.2) | `T1`,`T3`,`S` | C |
| 1 | RxSense (sink termination) | `T3`,`S` | C |
| 2 | video stable: rises after power-on, AFE and video-clock reset, together with event 0x10 bit7 | `T3` | L |
| 3 | TX clock/PLL locked (name from behaviour), part of RD's link-OK test. Already 1 at lock time at 297 MHz (S20, S30: 9b before the full power-on); at 148.5 MHz 1 only after the full power-on (S31: 93 → 9b). Lost once right after output enable and restored by a video-clock reset (S31 t=38020) | `T3`,`S` | C (values), U (meaning) |
| 4 | set on every port after init, then constant 1 | `T1`,`T3` | U |
| 7 | input video clock present: set by the time RD handles the RX lock, before the port's full power-on (93 or 9b in every lock pass) | `T3` | L |
| 3:0 = f | RD's "link OK" condition after output enable | `T3`,`S` | C |

Port 1 sequences (`T3`; C):
- S20: 03 (before init) → 00 (init soft reset) → 11 (HPD) → 13 (RxSense) → 9b (RX lock) → 9f (video stable after the full power-on).
- S30 unplug and replug: 97 → 13 (after the power-down) → 10 (soft reset) → 11 → 13 → 9b → 9f.
- S31 mode change: 10 (soft reset) → 11 → 13 → 93 (lock) → 9b (power-on) → 9f; second lock: 93 → 9b → 97 (PLL lost after output enable) → 9f.
- RxSense followed HPD by 68–80 ms.
- T4 mode changes: 9f → 10 (soft reset) → 90 (input clock back) → 91/93 (HPD, RxSense) → 9b (power-on) → 9f. `T4/S40` (aligned) as S20.

Events (0x10–0x14, W1C). RD's pass when 58/0:05 bit1 (port 1) or bit2 (port 2) is set: read 0x10–0x14, write each back, then act. (`T3`; C)
| Bit | Event | RD action | Enable | Ev | Conf |
|---|---|---|---|---|---|
| 10.0 | HPD changed | read 0x03. HPD = 0: power-down, forget the port's EDID. HPD = 1: source HPD high; if the port was known plugged, power-down then power-on (partial, or full when the RX has stable video); if its EDID is unparsed, read it over DDC (§8.1) | 0x18 bit0 | `T3/S20` t=451.9, `S30` 31396.5, `S31` 24872.1, 33660.5; `T4` (6); `S` | C |
| 10.1 | RxSense changed | read 0x03. RxSense = 0: power-down. RxSense = 1: power-down, power-on (as for 10.0), source HPD high, read 0x03 again. With 10.0 in the same pass, the HPD handling runs first (T4) | 0x18 bit1 | `T3/S20` t=1164.1, `S30` 31464.4, `S31` 24952.5, 33728.4; `T4` (6) | C |
| 10.2 | DDC error | R 0x2f; abort (§7.7) | 0x18 bit2 | `S` | L |
| 10.3 | DDC FIFO | FIFO clear | 0x18 bit3 | `S` | L |
| 10.7 | video stable changed | read 0x03; if bits 0, 2 and 7 are set: read 70/0:13 and 0x03 again, then run the path setup (§7.5) after the EQ step of the same cycle | 0x18 bit7 | `T3`,`T4` | C |
| 11.0–2, 11.7 | TX HDCP events | HDCP handling (never runs) | 0x19 | `S` | L |
| 12.0, 12.1 | SCDC update flag / read request from the sink | SCDC status reads | 0x1a bits 0, 1 | `S` | L |
| 12.3 | DDC bus hang | W 0x2e = 0a | 0x1a bit3 | `S` | L |
| 13.6 | HDCP 2 receiver ID list | — | 0x1b | `S` | L |

- Enable pairing 0x18–0x1d ↔ 0x10–0x15 is inferred from the write pattern; HPD and RxSense enables (0x18 bits 1:0) stay set through power-down. (`T3`,`S`; L)
- Port events latched before a soft reset are lost. At S30 t=22094.9 and S31 t=24728.6, 58/0:05 bit1 showed a pending port 1 event, but the port pass after the SCDT-off soft reset read 6a:10–14 = 00. The HPD drop caused by the reset raised no event either. RD therefore kept port 1's EDID marked as parsed and never re-read it after a replug (no EDID DDC reads in S30, S31). Track the 0x03 levels, not only the events. All six T4 losses behaved the same. (`T3/S30`,`S31`,`T4`; C)

### 7.2 Port procedures
| Procedure | Steps | Table | Ev | Conf |
|---|---|---|---|---|
| **Port init** (once, after a soft reset) | value list in init phase K | `seq/splitter-init.tsv` | `T1`,`T3/S20` | C |
| **Soft reset** | M 0x01 01 01, M 0x01 01 00 (init); M 0x01 03 03, M 0x01 03 00 (SCDT off). After the init write bit0 read back 0 (self-clearing). Afterwards the port registers read power-on defaults (0x88 11, 0x94 06, 0x93 80, 0xc0 20, 0x3a 80, 0x87 05, 0x89 c0, 0x8b 01) and HPD/RxSense status reads 0 until re-detected | rows in `splitter-rx-5v-off.tsv` | `T1`,`T3/S20`,`S30`,`S31` | C |
| **Video-clock reset** | W 0x01 = 06; M 0x94 01 01; M 0x94 01 00; W 0x01 = 04; W 0x01 = 00 | in every TX table | `T1`,`T3` | C |
| **Port reset** | video-clock reset; pulse 0x01 bit5; W 58/0:0c = 1 << (4 + n), then 00; M 0x18 80 00; W 0x19–0x1c = 00; pulse 0x35 bit4 | in `splitter-tx1-power-down.tsv` | `T1`,`T3` | C |
| **Power-down** | M 58/0:08 (1 << n) 00; M 0x18 dc 00; M 0x19 07 00; W 0x1a–0x1c = 00; M 0x84 60 60; M 0x86 08 00; M 0x88 03 03 (TMDS off); M 0x01 26 26; M 58/0:0d (3 << 2n) 00; R 6a:03, 6c:03 (optional timer arm, §5.3); port reset | `seq/splitter-tx1-power-down.tsv` | `T1`,`T3/S20`,`S30` | C |
| **Power-on, partial** (no RX video) | M 58/0:08 (1 << n) (1 << n); M 0xc1 f0 80; M 0x84 e0 80; M 0x86 08 08; M 0x02 01 00; M 0x19 07 07 | rows in `splitter-tx1-hpd-event.tsv` | `T3/S30` t=31407.2 | C |
| **Power-on, full** (RX SCDT on) | partial steps; W 0x10 = c0, 0x11–0x15 = ff; W 0x01 = 24, 00; clock measurement (§7.3); R 70/0:98; M 0xaf c0 00; AFE (§7.4); 100 ms; video-clock reset; M 0x18 80 80 | `seq/splitter-tx1-power-on.tsv` | `T3/S20` t=3689.7, `S30` 31892.3, `S31` 26837.2, 37245.6; `T4` (12) | C |

RD's triggers: an HPD or RxSense rise runs power-down plus power-on: partial with no RX video, full when the RX already has stable video. In three T4 changes, port 1's HPD/RxSense events came with or after SCDT on, and RD ran two or three full power-ons in a row, ≈120 ms each (`T4/S43` t=90281.4, `S44` 50823.9, `S45` 400.2). RX SCDT on runs the full power-on for each of ports 1 and 2 that has HPD. RD remembers per port whether the AFE has been set up, and forgets it on power-down, 5 V on, clock loss and SCDT changes. (`T3`,`S`; C for the traced triggers, L for the per-port state)

After a port soft reset 0x88 reads 11 (bit1 = 0, bit0 = 1). Of the two procedures, only the power-down sets bits 1:0 = 11. In T4 changes 4 and 5 the SCDT-on power-on came before any port 1 event. Its AFE row therefore wrote 0x88 = 15, and port 1 ran with bits 1:0 = 01 until the next power-down (`T4/S44` t=50664.0, `S45` 416.1). Effect unknown; replay by value. (`T4`; C for the values, U for the effect)

### 7.3 TX clock measurement
Per-port, per-mode measurement; run inside the full power-on, with RX video stable.
1. Pulse 0x07 bit7: M 07 80 80, wait 1 ms, M 07 80 00. coarse = (((0x07 & 0f) << 8) | 0x06) × 2.
2. Divider exponent d: 7 if coarse < 16, 6 if < 32, 5 if < 64, 4 if < 128, 3 if < 256, 2 if < 512, 1 if < 1024, else 0.
3. Ten samples, no delay: M 07 f0 ((8 | d) << 4) (start), M 07 f0 (d << 4) (stop), read 0x06 and 0x07; sample = (((0x07 & 0f) << 8) | 0x06) × 2. Sum the samples.
4. avg = sum / (10 × 2^d) (at least 1). clk [kHz] = rclk × 4096 / avg.
5. Input deep colour from 70/0:98 bits 5:4: 1 → clk × 5/4, 2 → clk × 3/2.
6. clk > 620999 → treated as 0, i.e. the lowest AFE row.

Traced:
| Mode | coarse | d | samples | clk |
|---|---|---|---|---|
| 1080p60 (S31 ×2) | 0x139 × 2 = 626 | 1 | 0x272 ×10; 0x272 ×7, 0x25b, 0x20b, 0x228 | 138.4 MHz; 142.9 MHz |
| 2160p60 4:2:0 (S20, S30) | 0x09c × 2 = 312; 0x09d × 2 = 314 | 2 | 0x271 ×7, 0x25f, 0x230, 0x217; 0x272/0x273 ×9, 0x20b | 285 MHz; 281 MHz |
| 1080p60 (T4 ×3) | 0x139 × 2 = 626 | 1 | 0x218–0x2ff; 0x272/0x273 in 14 of 30 | 140.2, 141.8, 142.0 MHz |
| 2160p60 4:2:0 (T4 ×4) | 0x09c/0x09d × 2; 0x272 × 2 = 1252 after a re-power (below) | 2; 0 | 0x271–0x273, single samples 0x238, 0x250, 0x2dd, 0x2fa (d 2); 0x09c/0x09d (d 0) | 280.3, 274.1, 277.6, 271.5 MHz |
| 2160p30 RGB (T4 ×5) | 0x09d × 2 = 314; 0x273 × 2 = 1254 after a re-power | 2; 0 | 0x273/0x274, single samples 0x21f, 0x2fd (d 2); 0x09c/0x09d (d 0) | 276.7 ×4, 274.1 MHz |

Single samples can be up to 17 % short or 22 % long; the ten-sample average absorbs it. The result reads 4–9 % below the nominal clock (§3.3). Every traced mode still fell in the AFE row of its nominal clock. (`T3/S20`,`S30`,`S31`,`T4`,`S`; C for traced steps and values, L for steps 5–6)

The coarse step writes only bit7 of 0x07, so it runs with whatever divider the previous measurement left in bits 6:4. After a soft reset (and at the first power-on) they are 0. When RD re-powers the port without a soft reset (T4: port events after SCDT on), they hold the previous d: the coarse count comes out 2^d times larger and the ten samples use d = 0. The average, and so clk, does not change (276.7 MHz both ways at `T4/S43` t=90287.5 and 90409.3). A third measurement in a row starts again from d = 0 and uses d = 2 (`T4/S44` t=50956.2). A driver may clear bits 6:4 before the coarse step; the AFE row is the same. (`T4`; C)

Driver: replicate this measurement, because the AFE thresholds below were applied by RD to this low-reading value. The 1080p60 row (100–150 MHz) holds with either the measured or the nominal clock. (`D`; L)

### 7.4 AFE settings by measured clock
| clk (kHz) | 0x84[2:0] | 0x88 bit2 | 0x87[4:0] | 0x89 (mask bf) | 0x8a[3:0] | 0x8b[3:0] | link | Ev | Conf |
|---|---|---|---|---|---|---|---|---|---|
| ≤ 100000 | 3 | 0 | 03 | 80 | 0 | 3 | 1.4 | `S` | L |
| 100001–150000 | 4 | 0 | 03 | 80 | 0 | 3 | 1.4 | `S`,`T3/S31`,`T4` (1080p: 87 = 03, 89 = c0, 8b = 03, 88 = 13) | C |
| 150001–162000 | 4 | 0 | 09 | 21 | 0 | 9 | 1.4 | `S` | L |
| 162001–310000 | 4 | 1 | 09 | 21 | 0 | 9 | 1.4 | `S`,`T3/S20`,`S30`,`T4` (87 = 09, 89 = 61, 8b = 09; 2160p30 RGB and 2160p60 4:2:0 alike) | C |
| 310001–375000 | 4 | 1 | 0d | 25 | 0 | b | 2.0 | `S` | L |
| ≥ 375001 | 4 | 1 | 0e | 25 | 0 | d | 2.0 | `S` | L |

- 0x89 bit6 is preserved; it reads 1, so the traced values are c0 and 61. (`T3`; C)
- RGB and 4:2:0 at 297 MHz select the same row: the AFE depends on the measured clock only. The other port 1 differences between the PC source's modes (0x88 bit6, 0xc0 bit4) come from the port init and the soft reset, not from the mode (§7.5). (`T4`; C)
- RD's override for port 2 only: 0x87/0x8b = 3/3 below 150001 and 9/9 above. (`S`; L)
- Variables in `seq/splitter-tx1-power-on.tsv`: afe84, afe88 (bit2 value 04 or 00), afe87, afe89, afe8b.
- "link 2.0" selects the HDMI 2.0 link setup (§7.6).

### 7.5 Path select, output enable, unmute (HDMI 1.4 link)
Trigger: RD runs this when port 1 reports video stable (event 0x10 bit7, confirmed by 0x03 bits 0, 2 and 7) after the full power-on, in the same poll cycle after the EQ step (§7.1). The event was seen at the first poll after the power-on in all four T3 cases, 68–234 ms after 0x18 bit7 was set. In T4 changes 2, 4 and 5 the check failed at first. It ran at the 0x10 = 82/83 event, after RD had re-powered port 1, and in changes 2 and 5 at one more event (`T4/S43` t=90585.5, `S45` 824.3). Each time 0x03 read 9b (bit2 = 0), and RD started at the next event, which read 9f. (`T3`,`T4`; C)

`seq/splitter-tx1-output-enable.tsv`. It replays all eleven traced bring-ups: four in T3 (S20, S30 at 2160p; S31 twice at 1080p, the second with the PLL recovery) and seven in T4 (S40 and six mode changes: 1080p60, 2160p30 RGB, 2160p60 4:2:0; no PLL recovery). (`T3`,`T4`; C)
1. Path pre-step (no port running yet and 58/0:0d = 00): pulse 58/0:0b bits 7:2; M 4e 0f 0c; 10 ms; M 4e 0f 00. RD then reads the RX timing (§6.7), informative.
2. M 0xc0 01 (70/0:13 bit1): HDMI or DVI mode.
3. 8-bit input: M 0xc1 f0 00. Deep-colour flag: M 0xc1 04 (04 if 70/0:98 shows deep colour; traced 0).
4. Bypass: M 58/0:0d (3 << 2n) 00; M 0xad 81 00; M 0xa0 30 00.
5. W 0x93 = 40; M 0x18 0c 0c; W 0x85 = 19; M 0x1a 0b 0b. 0x85 and 0x93: meaning unknown.
6. Link setup (HDMI 1.4): M 0x83 08 00; M 0xc0 46 00; 50 ms; M 0x3a 03 00; SCDC write offset 20 = 00; SCDC read offset 20 (§7.7).
7. 100 ms. M 0xc1 08 00, M 0xc1 08 08; M 0xc2 80 80; M 0xc3 30 30; **M 0x88 03 00: TMDS output on**.
8. 150 ms. Link setup again (step 6).
9. R 0x03. If bit3 = 0 (PLL recovery, traced once): video-clock reset, M 0xc1 f0 80, 100 ms, R 0x03 (S31 t=38020–38120: 97 → 9f).
10. Success if (0x03 & 0f) = 0f. RD then clears 0xc0 bit1 if it is set (clk < 340 MHz, or 4:2:0 8-bit input); traced as reads only. W 0x12 = ff.
11. Next poll cycle, **unmute**: M 0x91 10 00; M 0xc1 01 00 (AV mute off).

Failure (0x03 bits 1:0 ≠ 11): RD returns to waiting for video stable; otherwise it repeats the bring-up next cycle. (`S`; L)

Facts:
| Fact | Ev | Conf |
|---|---|---|
| Clearing 0x88 bits 1:0 turns TMDS on: S20 57 → 54, S30 17 → 14, S31 13 → 10; T4: 57 → 54 at S40, then 17 → 14 (297 MHz) and 13 → 10 (1080p60) after soft resets. The IT6805 reported video 207 ms later in S20, S30 and S31 #1; in S31 #2, 2 ms after the PLL recovery | `T3`,`T4` | C |
| 0xc1 bit0 is the TX AV mute. The IT6805 receives Clear-AVMUTE only after step 11: in all four traced locks its event appeared at its first poll after the 0xc1 write (S20 4363.2 → 4365.6, S30 32568.4 → 32640.9, S31 27520.5 → 27592.5, 38191.3 → 38193.2), never before. Without step 11 the IT6805 output stays muted (`hdmi-chips.md`) | `T3` | C |
| After a port soft reset (S30, S31; all six T4 mode changes) the IT6805 reported DVI (its 0x13 = bd) from video detection until the unmute, and HDMI (bf) at its first poll after it (≤ 2.3 ms; T4: 1.2–2.0 ms). In S20 and `T4/S40`, with no soft reset since init, it reported bf 66 and 65.5 ms before the unmute. The source sent HDMI with AVI InfoFrames in every case. Likely cause: a port-init value that the soft reset drops, 0xc0 bit4 first (next row) | `T3`,`T4` | C (observation), U (cause) |
| Port init sets 0xc0 bit4 (phase K: M c0 10 10); a soft reset clears it (0xc0 reads 20). Step 2 therefore wrote c0 = 31 in the two bring-ups without a soft reset since init (`T3/S20`, `T4/S40`) and 21 in the nine after one (`T3/S30`, `S31` ×2, `T4` ×6). The IT6805's early HDMI report occurred exactly in the first group. Whether bit4 is the cause is UNVERIFIED. Evidence needed: set 0xc0 bit4 again after a soft reset and watch IT6805 0x13 bit1 before the unmute | `T1`,`T3`,`T4` | C (values, correlation), U (cause) |
| 0x91 bit4 was already 0 in every trace; 0xc2 bit7 stays set (c2 = 88). Neither blanks video. Meanings unknown | `T3` | C (values) |
| 0xc1 bits 7:4 = 8 at power-on, 0 for 8-bit input, 8 after the PLL recovery; hardware also set bit6 (final c1 = c8 in S31) | `T3` | C (values), U (meaning) |
| Time from RX SCDT on to unmute: 0.68–0.95 s in T3, 0.67–0.99 s in T4 (sum of RD's waits 100 + 50 + 100 + 150 + 50 ms plus poll cycles; each extra full power-on after SCDT on adds ≈120 ms, §7.2) | `T3`,`T4` | C |
| RD's other paths, code only. If 0x03 bit2 drops while running: M 0x1a 4f 00, TMDS off, video-clock reset. If the PLL is lost while running, or the AVI changes: TMDS off, video-clock reset, W1C 0x12 bit2, 100 ms. Both then wait for video stable again. Untraced | `S` | L |

### 7.6 HDMI 2.0 link (clk > 310 MHz): UNVERIFIED
- Code only. M 0x83 08 08 (1/40 clock ratio); M 0xc0 46 46 (scrambling and ratio enables); 50 ms; M 0x3a 03 00. SCDC write offset 02 = 01 (source version), read it back. Then up to 11 times: SCDC write offset 20 = 03 and read back until bits 1:0 = 11; stop if HPD drops. (`S`; L)
- If the handshake fails: below 340 MHz RD clears 0xc0 bit1 and keeps the link; at 340 MHz and above it retries the bring-up next cycle. (`S`; L)
- RD enables scrambling and the 1/40 ratio together from 310 MHz measured (≈330 MHz true, §3.3), although HDMI 2.0 requires them only above 340 MHz. No trace exercised this path: every traced mode measured ≤ 286 MHz. At 297 MHz, 2160p30 RGB and 2160p60 4:2:0 both stayed on the HDMI 1.4 link (`T4`: 271.5–280.3 MHz measured; SCDC offset 20 = 00 only). (`S`,`T3`,`T4`; C for "never traced")
- Not needed for 1080p60. Needed for 2160p60 RGB/4:4:4, 4:2:0 at 10/12 bit, and 1080p144. Evidence needed: a 594 MHz source and a trace of the IT6805's SCDC state.

### 7.7 DDC master (per port)
| Reg | Use | Ev | Conf |
|---|---|---|---|
| 0x28 bit0 | 1 during EDID reads, 0 for SCDC/HDCP transfers; pulsed in recovery. The register reads 96 (97 with bit0 set); other bits unknown | `T1`,`T3` | C (use), U (meaning) |
| 0x29 | target address: a0 EDID, a8 SCDC, 74 HDCP | `T3`,`S` | C (a0, a8) |
| 0x2a | offset (EDID: (block × 128 + chunk offset) & ff) | `T3` | C |
| 0x2b, 0x2c[1:0] | byte count [7:0], [9:8] | `T3`,`S` | C |
| 0x2d | E-DDC segment = block >> 1 (EDID only) | `T3` | C (0) |
| 0x2e | command (below) | `T1`,`T3` | C |
| 0x2f | status (below) | `T1`,`T3` | C |
| 0x30 | FIFO data: write pushes one byte; a burst read pops N bytes. Depth 32 | `T3` | C |
| 0x19 bit2, 0x1d bit3 | set before each EDID read (purpose unknown) | `T3` | C (writes) |
| 0x35 bit4 | pulsed in recovery and between failed EDID parses | `T1`,`T3` | C (writes) |

Commands (W 0x2e): 00 burst read; 01 burst write; 03 EDID read with segment; 09 FIFO clear; 0a generate SCL clocks (bus-hang recovery, `S` only); 0f abort. (`T1`,`T3`,`S`; C except 0a)

Status 0x2f: bit7 done; bit6 busy; bit5 no ACK; bit4 bus wait/arbitration (U); bit3 arbitration lost (`S` only); bit2 FIFO full; bit1 FIFO empty; bit0 always 1 in traces. RD treats bits 5:3 as errors. Traced: 41 busy, 85 done + full after a 32-byte read, 83 done + empty after a write or abort, 81 done after an SCDC read, 23/33/63 no ACK, 43 aborting. (`T1`,`T3`; C for values, L for bit names)

Sequences:
- EDID chunk (32 bytes): `seq/splitter-tx-ddc-edid-read.tsv`. 0x28 bit0 = 1; 0x19 bit2 = 1; 0x1d bit3 = 1; W 2e = 09; W 29 = a0; W 2a = offset; W 2b = 20; W 2c = 00; W 2d = segment; R 0x03 (abort if no HPD); W 2e = 03; poll 2f bit7; read 32 bytes from 0x30; 0x28 bit0 = 0. A 128-byte block is 4 chunks; RD retries a failed block up to 4 times. From the read command to done ≈4.5 ms (status 41 three times, then 85); one chunk with setup and FIFO read ≈7 ms; one block ≈28 ms. (`T3/S20`; C)
- SCDC write / read: `seq/splitter-tx-scdc-write.tsv`, `seq/splitter-tx-scdc-read.tsv`. 0x28 bit0 = 0, W 2e = 09, W 29 = a8, offset, count 1; write: W 30 = data, W 2e = 01; read: W 2e = 00, then read 0x30. Status at the first poll, 1.25–1.47 ms after the command: 83 (write), 81 (read). Only offset 20 is traced: 16 accesses in T3 and 28 in T4 (14 writes of 00, 14 reads returning 00); the IT6805 acknowledged all. (`T3`,`T4`; C)
- Completion wait: poll 0x2f bit7 every 1 ms, at most 20 polls (≈22 ms). On timeout: R 2f; pulse 0x35 bit4; pulse 0x28 bit0; then twice: W 2e = 0f (abort) and poll 2f every 1 ms (at most 200) until bit7 or any of bits 5:3. Report failure. In the no-source trace every abort read 43 at the first poll and 83 at the second. (`T1/S01i`,`S`; C for the traced path, L for limits)
- No-source behaviour (`T1/S01i` t=511–819, after the port 1 HPD event at 507.5): every port 1 EDID chunk read returned no-ACK status (23/33/63) until the poll limit, followed by two aborts. RD gave up after 12 block attempts at 27.7–28.6 ms intervals. (`T1/S01i`; C)
- HDCP port read (W 29 = 74, two aborts with 3 ms waits first): code only, never run. (`S`; L)

### 7.8 TMDS-off paths
| Trigger | Writes | Ev | Conf |
|---|---|---|---|
| RX clock lost | all four ports M 0x88 03 03 | `T3/S30`,`S31`,`T4` | C |
| RX SCDT off | ports 1, 2: M 0x18 80 00; W 0x19–0x1c = 00; M 0x88 03 03; soft reset (§7.2). RD would rerun the SCDC setup for a port that had an HDMI 2.0 link; it first clears that state, so only the HDMI 1.4 write (SCDC 20 = 00) can follow | `T3/S30`,`S31`,`T4`,`S` | C |
| RX 5 V off | RX power-down, then power-down of ports 0, 1, 2, 3 | `T3/S30`,`S31` | C |
| port HPD or RxSense off | power-down | `S` | L |

### 7.9 HDCP on the TX
- RD's TX HDCP state machine is never called; no trace accesses port registers 0x40–0x7f except 0x41 at init (read 08, written back with bit0 = 0, so unchanged). The TX links are unencrypted, and the IT6805 captured them. (`T1`,`T3`,`S`; C)
- Driver: keep 0x41 bit0 = 0 and do not touch 0x40–0x7f. (C)

## 8. EDID handling

### 8.1 RD's copy path (used on the GC573)
RD's build selects its "compose" mode. With exactly one plugged port it falls back to copying that port's EDID; the GC573 case is port 1, the IT6805. (`S`,`T3/S20`; C)
1. Trigger: an HPD or RxSense event on port 1 or 2 whose EDID is not yet parsed. The parsed mark survives replugs, because the HPD-fall event is lost to the port soft reset (§7.1). So RD copies once per driver load (T4: no EDID RAM write after the load, through six mode changes). (`T3`,`T4`; C)
2. Parse: read block 0 through the port's DDC master (§7.7). Extension count 1 → block 1. Extension count 3 → blocks 1–3, using block 2 as the CTA block. Valid = 8-byte header plus a CTA block starting `02 03`. Up to 3 parse attempts, with the 0x35/0x28 pulses in between. (`S`,`T3/S20`; C for the traced 2-block case)
3. Copy: read blocks 0 and 1 again. In block 1, clear the "48-bit deep colour" flags (HDMI VSDB byte 6 bit6; HDMI Forum VSDB byte 7 bit2) and recompute the checksum. Write the RAM as in §6.5 with c7/c8 = the sink's physical address. Retry the copy at most twice. (`S`,`T3/S20`; C for the traced writes, L for the edits: the traced image had no such flags)
4. If the content differs from the previous load: HPD toggle with a 500 ms low (§6.4).
5. Timing: S20 parse 455–511 ms, copy 511–593 ms, HPD low 593.9–1105.5 ms. `T4/S40` (aligned, pub ms): parse 847.5–909.0, copy 909.7–995.5 (blocks 940.5–953.0 and 983.5–995.4), HPD low 996.8–1538.5 (541.8 ms), with S20's transfer count. With no source the parse fails (§7.7) and the RAM stays unwritten until a later plug-in. That case is untraced (UNVERIFIED, open question 24).

### 8.2 RD's compose path (both ports plugged; mechanism only, never traced)
When ports 1 and 2 both have parsed EDIDs, RD builds a new image (`S`; L):
- Block 0: a fixed header and identity of RD's own, with port 2's established timings, standard timings and descriptors; a monitor-name descriptor is replaced by RD's own.
- Block 1: port 2's CTA block, filtered:
  - video data block restricted to a fixed list of VICs, which equals the VIC set of RD's own capture EDID;
  - audio descriptors intersected across ports and limited to 2-channel LPCM, 32–48 kHz;
  - speaker allocation ANDed;
  - port 2's HDMI VSDB (some HDMI_VIC and 3D fields removed) and HF-VSDB (if port 2 supports 4K60);
  - 4:2:0 blocks rebuilt for the 2160p50/60 VICs;
  - colorimetry, VCDB and HDR static metadata copied; other extended tags dropped;
  - port 2's DTDs while they fit.
- RAM load as §6.5 with c7/c8 = 00/ff, then the 500 ms HPD toggle if changed.
- Effect: a monitor on HDMI OUT sees its own EDID restricted to the capture path's modes. Pass-through with a sink: UNVERIFIED (never traced).
- RD also contains two built-in default images and a loader that nothing calls. They are not reproduced here.

### 8.3 Driver: loading its own EDID
- Load the RAM directly (`seq/splitter-rx-edid-load.tsv`); do not depend on the IT6805's DDC, which does not answer without a source (§2.2). (`T1/S01i`; C)
- At init: after init phase L, with source HPD low: load, clear 70/0:c5 bit0, set 70/0:34 bit0. Raise HPD on 5 V only. (`D`; L: RD never loaded with HPD low before raising it)
- On `VIDIOC_S_EDID` while HPD is high: HPD low, load, keep HPD low ≥ 100 ms (RD: 500 ms, with an RX power-down), then raise it if 5 V is present. (`T3/S20`,`D`; C for RD's sequence, L for the 100 ms minimum)
- c7/c8: the physical address bytes of the image's HDMI VSDB, as in the only traced (and working) configuration, with c6 = 00. (`T3/S20`; C)
- 58/1:10 bit6: RD sets it after loading an image with an HDMI VSDB. Replicate RD; meaning unknown. (`T3/S20`; C for RD, U for meaning)
- No-source load, then plug-in: with its own image loaded at init, a driver needs no DDC copy, and the plug-in should follow the replug sequence (§9.2). Untraced: UNVERIFIED, open question 24.
- Content policy (modes, deep colour, 4:2:0, audio) is in `hdmi-chips.md`. For this chapter's verified path, advertise only modes whose TMDS clock stays ≤ 297 MHz until §7.6 is verified. (`D`; L)

## 9. Observed event sequences
Times in ms (§1).

### 9.1 Driver load with a source present (T3/S20, 2160p59.94 4:2:0)
| t | Event | Splitter action |
|---|---|---|
| 188–281 | init (§3) | — |
| 199.6–307.7 | GPIO bit 2 low pulse (port 1 HPD line) | — |
| 241.0 | port 1 soft reset (init phase K; line low) | 6a:03 03 → 00 |
| 391.8 | first poll: RX 05 = 01, 0x13 = 01 | 5 V on, no HPD (no EDID parsed) |
| 451.9 | port 1 event 10 = 01, 0x03 = 11 | source HPD high (454.21); EDID parse and copy (§8.1) |
| 593.9 | — | HPD low, RX power-down, 500 ms |
| 1105.5 | — | HPD high, c5 bit0 = 0, 34 bit0 = 1 |
| 1164.1 | port 1 event 10 = 02 (RxSense) | power-down, partial power-on |
| 3592.2 | RX 05 = 16, 06 = 01, 11 = 08, 12 = 91; 0x13 bf, 0x14 3b | clock stable, timer a0, lock, AVI (4:2:0, VIC 97), CSC, EQ search (3629) |
| 3684.1 | RX 07 = 40, 08 = 40, 10 = 06; 0x19 b0 | SCDT on: FIFO reset, port 1 full power-on (AFE 162–310 MHz row) |
| 3804.8 | same poll cycle, EQ step | EQ apply ff/ff/fe |
| 3872.1 | port 1 event 10 = 80, 0x03 = 9f | bit-error check (0 errors); path select, output enable; TMDS on 4090.2 |
| 4363.2 | — | unmute; IT6805 sees Clear-AVMUTE at 4365.6 |

### 9.2 Source 5 V on (T3/S30 replug, T3/S31 after 5 V cycle)
| Step | S30 | S31 | Table |
|---|---|---|---|
| RX 5 V event (58/0:05 = 10, 70/0:05 = 01) | 31272.5 | 33540.5 | `splitter-rx-5v-on.tsv` |
| source HPD high (ab = ca) | 31283.1 | 33549.1 | same |
| GPIO bit 2 high (RD, from the IT6805's 5 V) | 31292.4 | 33555.6 | `hdmi-chips.md` |
| port 1 HPD event (10 = 01), 0x03 = 11 | 31396.5 | 33660.5 | `splitter-tx1-hpd-event.tsv` |
| port 1 RxSense event (10 = 02), 0x03 = 13 | 31464.4 | 33728.4 | same table; source HPD after the power-on |
| RX clock stable + lock | 31648.5 | 37171.0 | `splitter-rx-lock.tsv` |

The EDID RAM is not rewritten on replug (zero 0xd8 writes in S30 and S31). (`T3`; C)

### 9.3 Source 5 V off (T3/S30 unplug, T3/S31 5 V cycle)
| Step | S30 | S31 | Table |
|---|---|---|---|
| IT6805 sees 5 V loss | 22053.6 | 29729.6 | `hdmi-it6805.md` |
| GPIO bit 2 low (RD) | 22055.1 | 29731.0 | `hdmi-chips.md` |
| splitter poll: 58/0:05 = 12 (S31: 52, timer expiry in the same pass); 70/0:05 = 05 (S31: 0d), 10 = 02 | 22094.9 | 29770.6 | `splitter-rx-5v-off.tsv` |
| source HPD low (ab ca → 4a → 00) | 22100.8 | 29776.3 | same |
| ports 0–3 powered down (58/0:08 → 00) | 22102.4–22122.0 | 29777.9–29797.4 | same |
| clock lost, SCDT off (port 1/2 soft reset; 6a:03 → 10) | 22122.2–22131.0 | 29797.6–29806.6 | same |

S31's pass also handled 70/0:12 = 80 (12.7 rows) and the timer-1 expiry (§9.6); the table has both as `cond:` rows. (`T3`; C)

### 9.4 RX lock to TX output (T3 locks; T4 in §9.7 and §9.8)
| Step | S20 | S30 | S31 (1080p) | S31 (1080p, 2nd) | Table |
|---|---|---|---|---|---|
| clock stable + lock | 3592.2 | 31648.5 | 26732.5 (EQ re-use) | 37171.0 | `splitter-rx-lock.tsv` |
| SCDT on, port 1 power-on | 3684.1 | 31884.5 | 26828.4 | 37240.1 | `splitter-rx-scdt-on.tsv`, `splitter-tx1-power-on.tsv` |
| EQ apply | 3804.8 | 32006.9 | — | 37525.9 | `splitter-rx-eq-apply.tsv` |
| port 1 video stable (10 = 80) | 3872.1 | 32076.4 | 27020.4 | 37592.4 | `splitter-tx1-output-enable.tsv` |
| TMDS on (0x88 bits 1:0 cleared) | 4090.2 | 32294.8 | 27249.3 | 37814.5 | same |
| PLL recovery; second video-stable event | — | — | — | 38020.3; 38176.4 | same (cond rows) |
| unmute (0xc1 bit0 = 0) | 4363.2 | 32568.4 | 27520.5 | 38191.3 | same |
| timer 1 expiry (a0) | after the window | 34660.9 | 29770.6 | 40224.0 | §9.6 |

### 9.5 Mode change with 5 V held (T3/S31, 2160p → 1080p at the source)
| t | Observation | Splitter action |
|---|---|---|
| 24717.0 | IT6805 loses TMDS (0x13 bf → 01) | — |
| 24728.6 | 58/0:05 = 12; RX 05 = 4e, 07 = 07, 10 = 02, 12 = 80; 0x13 = 01 (5 V kept) | clock lost, SCDT off (port 1/2 soft reset), 12.7: `splitter-rx-signal-loss.tsv`. Source HPD stays high |
| 24872.1 | port 1 HPD event (re-detected 70–133 ms after the reset; ≈90 ms per §2.2) | source HPD routine (already high), power-down, partial power-on |
| 24952.5 | port 1 RxSense event, in the same cycle as an RX pass (07 = 07) | same table, RxSense variant |
| 24952.5–26732.5 | RX 07 = 07 in every pass | W1C only |
| 26732.5 | clock stable + lock, EQ codes re-used, AVI = 4:4:4 BT.709 VIC 16 | `splitter-rx-lock.tsv` (re-use rows), then `splitter-rx-biterr.tsv` |
| 26828.4 | SCDT on; port 1 full power-on, AFE 100–150 MHz row (clk 138.4 MHz) | `splitter-rx-scdt-on.tsv` |
| 27020.4–27520.5 | video stable, output enable, TMDS on 27249.3, unmute | `splitter-tx1-output-enable.tsv` |

### 9.6 Timer 1 expiry
58/0:05 = 40 (or 52 together with other events) → main-block pass (§5.2, `seq/splitter-main-event.tsv`) reads 07 = 20 → stop timer 1 (M 1a 02 00, W 19 = 0f, W 1d = 00) → R 70/0:14. S30 t=34660.9, S31 t=40224.0 and all seven T4 expiries (`T4/S40` t=3029.8 and one per mode change) found 3b (locked): nothing more. S31 t=29807.6 found 01 and read 70/0:13 = 80 (bit4 = 0, no input): nothing more. (`T3`,`T4`; C)

### 9.7 Driver load with a PC source present (T4/S40, 2160p60 4:2:0)
Up to S40 t=0 the steps are placed by aligning transfer directions with `T3/S20` (§1). The first 2991 of the 3126 lost transfers, up to the lock pass, match S20's first 2975 in order, plus 16 extra transfers: the timer-1 arm rows of the init's phase J pair, which S20 skipped (§3.2). The offset to S20 is 385.6 ms at the start and 433 ms at the source HPD rise after the EDID sleep. Idle polls all look alike, so between the RxSense event and the lock pass the alignment places events, not individual polls. From the lock pass on, the sequences differ. (`T4/S40`; L up to t=0, C after)

| Step | `T3/S20` t | `T4/S40` | Basis |
|---|---|---|---|
| IT6805 EDID RAM load (0xa8, 254 writes; `hdmi-it6805.md`) | 96.1–120.3 | pub 490.3–516.3 | aligned |
| splitter init (§3) | 188.1–281.2 | pub 573.7–666.4 | aligned |
| GPIO bit 2 high, low, high (port 1 HPD line) | 181.8, 199.6, 307.7 | pub 593.3, 609.3, 717.6 | recorded MMIO |
| port 1 soft reset (init phase K) | 241.0 | pub 626.1 | aligned |
| first poll: 5 V on, no HPD (no EDID parsed) | 391.8 | pub 777.6 | aligned |
| port 1 HPD event; source HPD high (70/3:ab = ca) | 451.9; 454.2 | pub 841.8; 846.4 | aligned |
| EDID parse over port 1 DDC | 455–511 | pub 847.5–909.0 | aligned |
| EDID copy: 4b, c9, block 0, block 1, ca | 511.9, 540.3, 540.4–552.0, 580.9–592.5, 592.6 | pub 909.7, 940.3, 940.5–953.0, 983.5–995.4, 995.5 | aligned |
| source HPD low, RX power-down, RD sleep, source HPD high | 593.9–1105.5 | pub 996.8–1538.5 | aligned |
| port 1 RxSense event: power-down, partial power-on, source HPD | 1164.1 | pub 1593.7 | aligned |
| clock stable, timer a0, lock action, EQ search start | 3592.2 (AVI in the same pass) | −68.1 (pub 2280.1) | aligned |
| AVI (4:2:0, VIC 97) and CSC; EQ done, EQ apply be/9f/be | in the lock pass; EQ apply 3804.8 | pass at −2.5 (recorded from t=0); EQ apply 23.9 | recorded |
| SCDT on: FIFO reset, port 1 full power-on (clk 280.3 MHz, 162–310 MHz row) | 3684.1 | 89.6 | recorded |
| port 1 video stable; path setup | 3872.1; 3879.1 | 265.6; 278.9 | recorded |
| TMDS on | 4090.2 | 492.7 | recorded |
| IT6805 0x13 = bf (HDMI) | 4297.2 | 699.3 | recorded |
| unmute | 4363.2 | 764.8 | recorded |
| timer 1 expiry (stop only, lock found) | after the window | 3029.8 | recorded |

- Up to the first TMDS, RD's sequence is the same with both sources, including the EDID copy and the source HPD toggle: HPD raised before the RAM load, then 512 ms (S20) and 542 ms (T4) low (§6.4, §8.1). (`T3/S20`; C. `T4/S40`; L)
- The PC sent TMDS 0.74 s after the source HPD rose (S20's source: 2.49 s), and RD handled its AVI event 66 ms after the lock pass. Source HPD high to unmute: 1.57 s (S20: 3.26 s). (`T4/S40`; L for the lock-pass time, C after)

### 9.8 Mode changes with 5 V held (T4, PC source)
The PC switched modes six times with 5 V held. RD never touched the source HPD (no 70/3:ab write) or the EDID RAM, and re-used the S40 EQ codes each time. Times are ms after the change's first event pass; the first column gives that pass in scenario time. Path setup is the first row of `seq/splitter-tx1-output-enable.tsv`. (`T4`; C)

| Change (first pass) | lock | AVI | port 1 event (0x10) | SCDT on | port 1 full power-ons | video stable; path setup | TMDS on | unmute |
|---|---|---|---|---|---|---|---|---|
| 2160p60 4:2:0 → 1080p60 RGB (`T4/S41` t=91447.7) | +80.1 | +152.0 | +152.0 (03) | +260.0 | +266.5 | +444.1; +449.1 | +662.8 | +936.6 |
| 1080p60 → 2160p30 RGB (`T4/S43` t=90041.4) | +68.1 | +68.1 | +168.0 (01); +240.1 (82) | +240.1 | +246.1, +367.9 | +612.1; +624.8 | +836.6 | +1107.8 |
| 2160p30 RGB → 1080p60 (`T4/S44` t=1832.2) | +80.1 | +155.8 | +155.8 (03) | +256.1 | +263.2 | +439.8; +451.9 | +662.4 | +930.4 |
| 1080p60 → 2160p60 4:2:0 (`T4/S44` t=50548.0) | 0, with SCDT off | 0 | +275.9 (83) | +100.0 | +106.3, +288.1, +406.4 | +584.1; +596.6 | +807.9 | +1080.0 |
| 2160p60 4:2:0 → 2160p30 RGB (`T4/S45` t=236.2) | 0, with SCDT off | +79.8 | +164.0 (83) | +164.0 | +170.5, +293.6, +411.8 | +656.0; +668.9 | +880.7 | +1151.2 |
| 2160p30 RGB → 1080p60 (`T4/S45` t=7767.9) | +144.2 | +144.2 | +144.2 (03) | +256.3 | +263.2 | +432.2; +444.5 | +656.4 | +927.3 |

Two patterns (`T4`; C):
1. TMDS lost (changes 1, 2, 3, 6). The first pass read 58/0:05 = 12, RX 05 = 04, 06 = b1 or 31, 10 = 02, 0x13 = 01. RD ran clock lost, lock lost (enables off, EQ 81) and SCDT off with the port 1/2 soft reset; the port 1 pass then read 00 (`seq/splitter-rx-signal-loss.tsv`). The lock pass came 68–144 ms later: clock stable, timer a0, lock action with the stored codes, and the bit-error check in its EQ step (`seq/splitter-rx-lock.tsv`).
2. Re-locked within one poll (changes 4, 5). The first pass already carried clock stable, lock and SCDT off (§6.3), and SCDT came back 100–164 ms later.

In both patterns:
- Port 1 re-detected HPD ≈90 ms after the soft reset (§2.2), with RxSense in the same pass in five changes (0x10 = 03 or 83). Each HPD/RxSense event re-powered port 1 (`seq/splitter-tx1-hpd-event.tsv`): partially before SCDT on (changes 1, 3, 6, and change 2's HPD event), in full with or after it (change 2's RxSense event, changes 4 and 5).
- SCDT on to unmute: 0.67–0.68 s with one full power-on, 0.87 s with two, 0.98–0.99 s with three.
- The splitter's 0x13 read bf again at its first read after SCDT on, which RD makes only after port 1's full power-on (0.22–0.48 s after the first pass). The IT6805 read bd until the unmute and bf 1.2–2.0 ms after it (§7.5).
- Timer a0, armed in the lock pass, expired 2.96–3.13 s later and found the lock (§5.3).

## 10. Minimal polling driver for 1080p60
Derived from §3–§9. It reproduces RD's register writes for every traced transition, without RD's busy-waits and with bounded waits. Driver-side limits are design choices, marked "limit". (`D`; L unless a step cites C above)

State kept per poll: `v5` (70/0:13 bit0), `clk` (bit3), `lock` (70/0:14 bits 5:3 = 111), `scdt` (70/0:19 bit7), port 1 levels (6a:03), port 1 state OFF / POWERED / RUNNING, `edid_loaded`, `eq_state`.

Bring-up:
1. Probe order (`hdmi-chips.md`): FPGA init, IT6805 init (including its 0xe0 access), then `seq/splitter-init.tsv`. rclk: §3.3. A driver may skip the `cond:` timer rows.
2. Load the EDID: `seq/splitter-rx-edid-load.tsv` without the conditional HPD rows (§8.3). `edid_loaded` = 1.
3. GPIO bit 2 (port 1 HPD line): follow `hdmi-chips.md`. Port 1 needs HPD for RD's DDC/SCDC steps and for the "link OK" check.

Every 50 ms:
1. Read 58/0:05.
   - Bit4: RX event pass (§6.2): read 05–1d, write back 05–11, handle bits (2–4 below), write back 0x12 last.
   - Bits 5/6: main-block pass (§5.2, `seq/splitter-main-event.tsv`); on 07 bit5 stop timer 1.
   - Bit1/bit2: port pass (§7.1): read and write back 0x10–0x14 of that port.
2. Read 70/0:13 and 70/0:14 (also the EQ step).
3. 5 V:
   - 0 → 1: `splitter-rx-5v-on.tsv`, with HPD high since `edid_loaded`.
   - 1 → 0: `splitter-rx-5v-off.tsv` (RX power-down, ports 0–3 down; clock-lost and SCDT-off rows as the events show). Port 1 → OFF; forget EQ results.
4. RX link:
   - 05.2 with bit3 = 1: clock-stable rows of `splitter-rx-lock.tsv` (timer optional).
   - 06.0 with 0x13 bit7: lock rows, then the EQ search start (or re-apply stored codes). `eq_state` = SEARCH.
   - 05.2 with bit3 = 0: clock-lost rows (all ports TMDS off).
   - 06.0 with 0x13 bit7 = 0: lock-lost rows of `splitter-rx-signal-loss.tsv` (event enables off; RD writes EQ 81, which the next lock replaces).
   - 10.1 with 0x19 bit7 = 0: SCDT-off rows (port 1/2 soft reset). Port 1 → OFF; its HPD reads 0 for ≈90 ms (88.8–93.2 ms in T4) while the line stays high. These rows can come in the same pass as clock stable and lock, when the source changed mode without losing lock (§6.3): handle the bits in register order.
   - 10.1 with 0x19 bit7 = 1: SCDT-on rows: FIFO reset; if 6a:03 bit0 = 1, `splitter-tx1-power-on.tsv` with the AFE row for the measured clock (1080p60: afe84 = 4, afe88 = 0, afe87 = 03, afe89 = 80, afe8b = 3). Port 1 → POWERED.
   - 12.0: read the AVI InfoFrame (§6.7); limit the stability wait. CSC optional. 12.7: acknowledge rows. 11.3: read 0x98.
   - 05.5 (link error): RD bounces the source HPD after more than 50 events, with no time window; untraced. Limit: if copied, count per lock and bounce at most once per 10 s.
5. EQ: in SEARCH, when an event pass shows 07 bit6 (or bit4/bit7): `splitter-rx-eq-apply.tsv`; next poll with lock, run `splitter-rx-biterr.tsv` once. Limit: 3 search attempts, then fixed 9f.
6. Port 1:
   - POWERED and 6a:03 has bits 0, 2, 7 set: `splitter-tx1-output-enable.tsv` up to the success check. Limit: if bits 2/7 do not appear within 1 s of the power-on, repeat the power-on once, then report no signal.
   - On success ((0x03 & 0f) = 0f): unmute on the next poll → RUNNING. The IT6805 then reports Clear-AVMUTE (§7.5).
   - Bits 1:0 ≠ 11: stay POWERED and retry next poll.
   - RUNNING and 0x03 bit3 = 0: PLL recovery rows (traced once, right after output enable). Limit: after 3 recoveries in a row, power-down and full power-on instead.
   - Port 1 HPD rises while scdt = 1 and the port is OFF: full power-on (RD: `splitter-tx1-hpd-event.tsv`, then the SCDT-on power-on path).
   - RD re-runs power-down and full power-on for every port 1 HPD/RxSense event while scdt = 1 (T4: up to three full power-ons in a row, the SCDT-on one included, ≈120 ms each). Limit: after an SCDT-off soft reset, wait until 6a:03 shows HPD and RxSense (≈90 ms) and SCDT is on, then run one full power-on.
7. Never block the bus for RD's long waits: split the 100/50/100/150 ms waits of §7.5 across polls or sleep between transfers, with the bank lock released.

Remove and suspend: RD writes nothing to the splitter at unload, so the chip keeps running and the source HPD stays as it was (`T3/S36`,`T4/S46`; C). What a driver should do instead (HPD low, ports down) is a design choice; see `hdmi-chips.md`. Resume behaviour is untraced (U).

Expected timings at 1080p60 (T3/S31): 5 V → HPD high ≈9 ms; HPD high → TMDS: source-dependent (0.4–3.6 s in T3); clock stable → SCDT on 70–100 ms; SCDT on → unmute 0.69 s (0.95 s with the PLL recovery); unmute → IT6805 0x13 = bf within 2.3 ms, its Clear-AVMUTE event at its next event poll (`hdmi-chips.md`). PC source (T4): HPD high → TMDS 0.74 s; lock pass → SCDT on 100–180 ms; mode change with 5 V held, first pass → unmute 0.93–1.15 s (§9.8).

## 11. Unverified items
| # | Item | Evidence needed | Ref |
|---|---|---|---|
| 1 | Which GPIO line resets the splitter; minimum delay before the first transfer | toggle bit 5 / bit 8 alone, read 58/0:00 | §3.1, OQ 10 |
| 2 | Meanings of most init values (phases B–L), 58/0:0e, 10, 18, 2b–30, 58/1:1d, 20, 6a:85, 93, 94, c2, c3, 70/0:26, 28, 34, c5. Effect of the port values lost in a soft reset: 0xc0 bit4 correlates with the IT6805's early HDMI report in all eleven traced bring-ups (T3, T4) | per-register experiments; set 0xc0 bit4 again after a soft reset and watch IT6805 0x13 bit1 before the unmute; for now replay by value | §3, §5.4, §7.5 |
| 3 | Timer time base and linearity; role of 58/0:19; why a0 expired 2.96–3.13 s after arming, varying by at least 65 ms | arm counts 10/40/a0/ff, time the expiry with fast polling | §5.3 |
| 4 | Splitter interrupt output on GPIO 0x040 bit 10 (`T4/S40` adds a consistent data point); its configuration registers | sample bit 10 with 58/0:05 every poll | §5.1, OQ 21 |
| 5 | Port 1 HPD fall latency without a soft reset | drop GPIO bit 2 while the TX is idle, read 6a:03 every 5 ms | §2.2, OQ 23 |
| 6 | Port 2 = pass-through; compose path and port 2 AFE override with a sink attached | monitor on HDMI OUT | §2.2, §8.2 |
| 7 | 70/0:c6 function (no substitution at 00?); roles of 34 bit0 and c5 bit0; whether writing RAM 7f/ff matters; RAM content before the first load | read the EDID from the source side (DDC sniff or a PC source) | §6.5 |
| 8 | 58/1:10 bit6 meaning | toggle it, watch an HDCP 2.x-capable source | §5.4, §8.3 |
| 9 | Fixed EQ 9f sufficient on long cables; meaning of EQ code bit7, 20/21, 22 bit6 | bit-error counts with fixed 9f vs searched codes, 2 h soak | §6.6 |
| 10 | HDMI 2.0 RX EQ and TX link (> 310/340 MHz), SCDC handshake with the IT6805. Settled at 297 MHz: RGB and 4:2:0 both use the HDMI 1.4 link (T4) | 594 MHz source | §6.6, §7.6, OQ 14 |
| 11 | rclk accuracy (clocks read 4–9 % low; T4 adds 2160p30 RGB at 274–277 MHz) and AFE rows near 150/162/310 MHz | compare 6a:06/07 counts with FPGA 0x1010 for several modes | §3.3, §7.3 |
| 12 | RX 0x13 bits 2, 5, 7; 0x14 bits 0, 6, 7; 0x15 (00 twice with 5 V in T4) and event 09.5; 0x19 bits 5:4; 0xaa (bit0 = 1 at 2160p30); 0x43 (bit5 follows the TMDS clock, T4); 0x98 bit6; event bits 06.4, 06.5, 06.7, 10.4, 10.5; front-porch upper bits | sources with other modes, polarities, HDMI 2.0 | §6.1, §6.2, §6.7 |
| 13 | Encrypting source: RX HDCP, 70/0:09 events, timer 0 HPD pulses | Roku without stripper | §6.9, OQ 25 |
| 14 | Load with no source, then plug-in (first lock after a no-source load) | trace our driver | §8.1, OQ 24 |
| 15 | RD's recovery paths: more than 50 link errors (HPD bounce), the TX paths for loss of video stable or of the PLL while running (§7.5), AVI change while running, EQ fault 08.0 (all untraced); TX PLL recovery after output enable (traced once); lock lost (traced, T4). The limits proposed in §10 are untested | provoke with cable faults, source colour-space changes and repeated mode changes | §6.2, §7.5, §10 |
| 16 | Whether 70/0:49 = e1 (0xe0 mapping) can be skipped | init without it, lock at 1080p60 | §2.4 |
| 17 | Unbounded RD waits (AVI stability phase 2, HDMI 2.0 skew poll): the limits proposed here are untested. Both AVI phases are traced (T4: at most 8 reads) | — | §6.6, §6.7 |
| 18 | Input without AVI (DVI mode): RX CSC setup and port 1 DVI output. T4's PC source sent AVI in every mode | PC loopback with an EDID that has no HDMI VSDB | §6.7, §7.5 |
| 19 | When exactly 0x13 bit1 (HDMI) returns after a lock (T4: between the SCDT-on pass and the next 0x13 read, which follows port 1's full power-on), and why 0x19 bit7 can lead the 0x10 bit1 event by a poll | read 0x13 and 0x19 every 5 ms after a lock | §6.1 |

## 12. Sequence files
| File | Content | Replayed against |
|---|---|---|
| `seq/splitter-init.tsv` | power-on to idle | `T1/S01`, `T3/S20` (all transfers); `T4/S40` directions (aligned) |
| `seq/splitter-rx-edid-load.tsv` | EDID RAM load (with the conditional HPD toggle) | `T3/S20` 511.4–1107.6 (DDC reads excluded); `T4/S40` directions (aligned) |
| `seq/splitter-rx-hpd-high.tsv`, `-hpd-low.tsv` | source HPD | `T3/S20`, `S30`, `S31`; `T4` (high, inside port events); `T4/S40` directions (aligned) |
| `seq/splitter-rx-power-down.tsv` | RX power-down | `T3/S20`, `S30`, `S31`; `T4/S40` directions (aligned) |
| `seq/splitter-rx-5v-on.tsv` | 5 V appears | `T3/S20`, `S30`, `S31`; `T4/S40` directions (aligned) |
| `seq/splitter-rx-5v-off.tsv` | 5 V lost | `T3/S30`, `S31` |
| `seq/splitter-rx-signal-loss.tsv` | TMDS lost, 5 V held: clock lost, lock lost, SCDT off | `T3/S31`; `T4` ×4 |
| `seq/splitter-rx-lock.tsv` | clock stable, lock, AVI, EQ search start or re-use; SCDT off in the same pass | `T3/S20`, `S30`, `S31` ×2; `T4` ×6 |
| `seq/splitter-rx-eq-apply.tsv` | EQ result apply | `T3/S20`, `S30`, `S31`; `T4/S40` |
| `seq/splitter-rx-biterr.tsv` | bit-error check | `T3/S20`, `S30`, `S31` ×2; `T4` (13 of 1000) |
| `seq/splitter-rx-scdt-on.tsv` | SCDT on, port 1 power-on | `T3/S20`, `S30`, `S31` ×2; `T4` ×7 |
| `seq/splitter-tx1-power-down.tsv` | port 1 power-down + reset | `T3/S20`, `S30` ×2; `T4` ×12 |
| `seq/splitter-tx1-power-on.tsv` | port 1 full power-on | `T3/S20`, `S30`, `S31` ×2; `T4` ×12 |
| `seq/splitter-tx1-hpd-event.tsv` | port 1 event pass: HPD and/or RxSense rise, video-stable check | `T3/S20`, `S30` ×2, `S31` ×3, 4 video-stable passes; `T4` ×7, 9 video-stable passes |
| `seq/splitter-main-event.tsv` | main-block pass, timer-1 expiry | `T3/S30`, `S31` (and inside the S31 5 V-off pass); `T4` ×7 |
| `seq/splitter-tx1-output-enable.tsv` | path select, output enable, unmute | `T3/S20`, `S30`, `S31` ×2; `T4` ×7 |
| `seq/splitter-tx-ddc-edid-read.tsv` | one 32-byte EDID chunk | `T3/S20` (4 chunks); `T4/S40` directions (aligned) |
| `seq/splitter-tx-scdc-write.tsv`, `-scdc-read.tsv` | SCDC transfer | `T3/S30`; `T4/S40` (2 write/read pairs; all 28 T4 accesses fall inside the seven output enables) |

"Replayed" means every traced transfer in the window was matched in order and value, with masks checked against the traced read/write pairs. `X` steps stand for traced transfers whose content is per unit or per mode (clock measurement, AVI reads, timing reads, CSC, EDID data); `cond:` rows are matched when present. T4's complete record (from S40 t=12.9 on) replays without error in all 89 windows. A port pass that follows an RX pass in the same poll is replayed from its first port read. "Directions (aligned)" means that only the read/write sequence of the lost S40 window was compared (§9.7). (`T1`,`T3`,`T4`; C)
