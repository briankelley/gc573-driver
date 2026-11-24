# Bring-up and teardown

All timings are what RD uses; minimums are not known. Keep them until experiments show otherwise.

## Probe / init (RD order)
| # | Step | Detail | Ev | Conf |
|---|---|---|---|---|
| 1 | PCI enable | bus master, map BAR0, MSI | `pci.md` | C |
| 2 | Reset domains | for bit in (0x001, 0x100, 0x200): write RESET(0x00c) = bit; poll every 1 ms (≤ 11 tries) until `RESET & bit`; sleep 30 ms | `T1/S01`,`S` | C |
| 3 | DDR check | read DDR_STATUS (0x107c); bit0 must be 1. If 0: write 8, write 1, sleep 2 s, re-read; ≤ 3 tries; still 0 → fail probe | `T1/S01` (read 0x3),`S` | L |
| 4 | Version | read VERSION (0x000); log | `T1/S01` | C |
| 5 | I2C clocks | bus0: 0x120=0x3d, 0x124=0, 0x128=0x80 · bus1: 0x180=0x138 · bus2: 0x100=0xf9, 0x104=0, 0x108=0x80 | `T1/S01`,`S` | C |
| 6 | Interrupts | clear stale status, INT_ENABLE = 0xb33 | `T1/S01`,`S` | C |
| 7 | Scalers out of reset | SCALER_RESET (0x50000) = 3 | `T1/S01` | C |
| 8 | GPIO enables | GPIO|=bit4, sleep 5 ms, repeat until bit4 reads 1 (≤ 21); same for bit6 | `T1/S01`,`S` | C |
| 9 | GPIO | sleep 2 ms; clear bit1; sleep 2 ms | `S`,`T1/S01` | C |
| 10 | Chip reset A | bit5: 1, 5 ms, 0, 10 ms, 1, 5 ms | `T1/S01` | C |
| 11 | Chip reset B | bit8: 1, 2 ms, 0, 2 ms, 1, 2 ms | `T1/S01` | C |
| 12 | HDMI chips | splitter init, then IT6805 init over I2C bus 1 (sequences: TODO `hdmi-chips.md`) | `T1/S01` | — |

Observed GPIO value sequence for steps 8–11 (T1/S01): `0x1f850` → (bit4, bit6 already 1) → `0x1f870` → `0x1f850` → `0x1f870` → `0x1f970` → `0x1f870` → `0x1f970`.

## Stream start (video)
See `video-dma.md` §Start. Summary: configure pipeline (`video-pipeline.md`), program slots, set CH_CTRL run bit on each used channel, then VIP_CTRL[0] = 1.

## Stream stop (video)
1. VIP_CTRL (0x1000)[0] = 0.
2. Wait for INT bit 0 (termination), RD waits up to 2 s polling every 10 ms.
3. Reset domains (all three, as init step 2). RD does this on every stop.
4. Return all queued buffers.
(`S`; L)

## Remove / quiesce
RD performs **no** register access on unload: interrupts and DMA stay configured (`T1/S03`, `T2/S14`; C). The device has no FLR. Required teardown for our driver:
1. Stop video (above) and audio (DMA_RUN = 0) if running.
2. INT_ENABLE = 0; clear INT_STATUS.
3. Reset domains.
4. Free IRQ, then DMA memory.
