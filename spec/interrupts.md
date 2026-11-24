# Interrupts

Single source: INT_STATUS (0x010), write-1-to-clear. Enable mask: INT_ENABLE (0x01c).

| Bit | Mask | Meaning | Service | Ev | Conf |
|---|---|---|---|---|---|
| 0 | 0x001 | video stream terminated: ch0 drained after VIP output disabled (0x1000[0]=0) | wake stream-stop waiter | `S` | L |
| 1 | 0x002 | video list done (ch0) | read CH0 STATUS (0x300); slot = ([2:0]) − 1 (valid 0..3); complete that slot's buffer; if 0x304 slot bit (1<<(slot+1)) still set, clear it; queue next buffer | `T1/S02`,`T2/S11`,`S` | C |
| 2 | 0x004 | video DMA error/abort condition | RD reads 0x300, logs, treats like termination | `S` | U |
| 3 | 0x008 | video DMA error/abort condition (second kind) | same as bit 2 | `S` | U |
| 4 | 0x010 | audio DMA stopped (after DMA_RUN[1] cleared) | ack | `T1/S01i`,`S` | C |
| 5 | 0x020 | audio period done | read AUDIO_DONE (0x014)[1:0]: 1 → buffer 0 full, 2 → buffer 1 full | `T1/S01i`,`T2/S13`,`S` | C |
| 8, 9 | 0x300 | enabled by RD, never observed, no RD handler | ack | `S` | U |
| 10 | 0x400 | not enabled, not handled | — | `S` | U |
| 11 | 0x800 | I2C bus-1 transaction complete | read 0x1a4 (8-bit): bit0 write OK, bit2 read OK; complete waiter | `T1`,`S` | C |
| 31 | 0x80000000 | unknown fatal condition; RD treats as termination | ack | `S` | U |

## Enable / disable
- Enable: read INT_STATUS, write back `status & 0xbff` (clear stale), write INT_ENABLE = `0xb33` (bits 0,1,4,5,8,9,11). (`T1/S01`, `S`; C)
- Disable: INT_ENABLE = 0. Then clear INT_STATUS by writing back the read value.

## Rates observed (no input)
- bit 1: every 16.6–16.7 ms while ch0 runs (60 Hz free-running timing with no input). (`T1/S02`; C)
- bit 5: every 10.00 ms ± 0.1 ms while audio runs. (`T2/S13`; C)
- bit 11: one per I2C bus-1 transaction (~0.3 ms each incl. latency); RD idle polling produced ~300/s. (`T1/S01i`; C)

## Driver notes
- Ack exactly the bits being serviced: write `(1 << bit)` to INT_STATUS. Do not read-modify-write INT_STATUS (that acks bits not yet serviced).
- Return IRQ_NONE when INT_STATUS reads 0 (INTx may be shared).
- Bit 11 completion must wake a sleeping I2C caller; no spinlock may be held across the wait.
