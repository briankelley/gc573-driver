# I2C

Three masters in the FPGA. Addresses below are 8-bit (7-bit address << 1); bit0 = R/W.

## Byte masters: bus 0 (0x120) and bus 2 (0x100)
Register-compatible with the OpenCores I2C master (`P:OC-I2C`), registers on a 4-byte stride. (`S`, `T1/S01`; C)

| Off (bus 2 / bus 0) | OpenCores reg | Use |
|---|---|---|
| 0x100 / 0x120 | PRERlo | prescale low |
| 0x104 / 0x124 | PRERhi | prescale high |
| 0x108 / 0x128 | CTR | [7] EN core enable, [6] IEN (not used by RD) |
| 0x10c / 0x12c | TXR (W) / RXR (R) | data byte |
| 0x110 / 0x130 | CR (W) / SR (R) | CR: [7] STA, [6] STO, [5] RD, [4] WR, [3] ACK (1 = send NACK), [0] IACK. SR: [7] RxACK (1 = no ack), [6] busy, [5] arbitration lost, [1] TIP, [0] IF |

- Prescale (`P:OC-I2C`): `prescale = f_clk / (5 × f_scl) − 1`. RD values: bus 0 `0x3d` (61), bus 2 `0xf9` (249). With f_clk = 125 MHz: bus 0 ≈ 403 kHz, bus 2 = 100 kHz. f_clk 125 MHz is inferred, not measured. (`D`; L)
- Byte write: TXR = byte; CR = WR [| STA for address byte] [| STO for last]; poll SR.TIP until 0 (RD: ≤ 200 polls); check SR.RxACK = 0.
- Byte read: CR = RD [| ACK(nack) | STO for last byte]; poll TIP; read RXR.
- RD command bytes: address = `STA|WR` (0x90); data write = `WR` (0x10), last `WR|STO` (0x50); data read = `RD` (0x20), last `RD|ACK|STO` (0x68). (`S`; C)
- Devices on bus 0 and bus 2: none accessed in any trace. RD exposes the bus-0 byte interface as its generic Linux I2C adapter. (`T1`,`T2`,`S`; C)
- Note: RD uses the bus-0 byte registers (0x12c/0x130) for both its "bus 0" and "bus 1" byte-level calls. Whether bus 0 and the bus-1 engine share wires is unknown. (`S`; U)

## Bus 1 transaction engine (0x180)
Carries all HDMI-chip traffic. One register-addressed transfer per command; completion via INT bit 11. (`T1`, `S`; C)

| Off | Name | Use |
|---|---|---|
| 0x180 | PRESCALE | RD 0x138 |
| 0x184 | ADDR | 8-bit device address; bit0 = 1 for read |
| 0x188 | ? | RD writes 0 every transfer |
| 0x18c | ? | RD writes 0 every transfer |
| 0x190 | SUBADDR | device register address (8-bit) |
| 0x194 | LEN | byte count |
| 0x198 | TXFIFO | write: push one byte per register write |
| 0x19c | RXFIFO | read: pop one byte per register read (low 8 bits) |
| 0x1a0 | CMD | 0x10 clear/flush · 0x04 start write · 0x08 start read |
| 0x1a4 | STATUS (8-bit read) | [0] write complete OK · [2] read complete OK |

### Write (LEN bytes)
`ADDR=addr&0xfe; 0x188=0; SUBADDR=reg; CMD=0x10; 0x18c=0; LEN=n; TXFIFO←byte × n; CMD=0x04;` wait INT bit 11; STATUS bit0 = success.
### Read (LEN bytes)
`ADDR=addr|1; 0x188=0; SUBADDR=reg; 0x18c=0; LEN=n; CMD=0x10; CMD=0x08;` wait INT bit 11; STATUS bit2 = success; `CMD=0x10`; RXFIFO → byte × n.

- RD timeout 20 ms, one retry. Observed transaction time ≈ 0.3 ms per single byte including interrupt latency (`T1/S01`; C).
- Max LEN: RD uses LEN 2 only for the splitter ID reads (0x58 regs 0x00, 0x02); everything else is LEN 1, including the EDID RAM load (254 single-byte writes, registers 0x00–0xfe). FIFO depth unknown (`U`).
- Exact register order matters? RD write path writes CMD=0x10 before LEN; read path after LEN. Both work. (`T1`; C)

## Device inventory (bus 1)
| Addr (8-bit) | Device | Evidence | Conf |
|---|---|---|---|
| 0x90 | ITE IT6805 HDMI 2.0 receiver, main register bank. Regs 0x00–0x03 = `54 49 05 68` (vendor "IT", device 0x6805) | `T1/S01` | C |
| 0xa8 | IT6805 EDID RAM (254 single-byte writes, regs 0x00–0xfe, during init) | `T1/S01` | C |
| 0x58 | HDMI splitter/repeater, main bank. Regs 0x00–0x03 = `54 49 63 66` → device 0x6663, revision reported "A1" | `T1/S01` | C |
| 0x68, 0x6a, 0x6c, 0x6e | splitter banks accessed identically (reg 0x01 read-modify-written through values 0x00/0x06/0x20; regs 0x02/0x03 read 0): likely four TX port banks | `T1/S01` | L |
| 0x70 | splitter bank, heavily polled (~36/s idle): likely RX/status bank | `T1/S01i` | L |
| 0x96, 0xe0 | splitter banks, few accesses | `T1/S01` | L |

Idle traffic (no input, RD): ~300 transactions/s, dominated by 0x90, 0x70, 0x58. (`T1/S01i`; C)

## Driver notes
- Expose bus 1 as a Linux `i2c_adapter` (register-addressed transfers map to `i2c_msg` pairs: write [reg] + read [n], or write [reg, data...]). Completion by interrupt + `wait_for_completion_timeout`; transfers serialized by a mutex; never hold a spinlock across a transfer.
- The OpenCores masters (bus 0/2) can be exposed as separate adapters once devices on them are identified.
