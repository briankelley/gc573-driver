# Video DMA

Scatter-gather, descriptor lists in host memory, three channels (one per image plane), four buffer slots per channel.

## Descriptor (16 bytes, little-endian)
| Word | Field | Notes | Ev | Conf |
|---|---|---|---|---|
| 0 | addr[31:0] | bus address of a contiguous chunk | `T1/S02`,`T2/S11` | C |
| 1 | addr[63:32] | 0 in all traces (32-bit DMA mask) | same | C |
| 2 | length | **in 32-bit words** (bytes / 4) | `T2/S11`,`S`,`D` (sums equal plane sizes) | C |
| 3 | ctrl | `0x80008000` on every descriptor HW consumed | `T1/S02`,`T2/S11` | C (bit meanings U) |

- No end-of-list marker: list length comes from SLOTn_COUNT. (`T1`,`T2`; C)
- Chunk lengths in all traces: multiples of 32 bytes. RD flags lengths that are not a multiple of 8 words. Treat 32-byte length granularity as required. (`T2/S11`,`S`; L)
- Chunk addresses: 4 KiB aligned except at plane split points, where 1 KiB- and 256-byte-aligned starts were accepted. Minimum alignment unknown; keep ≥ 256 B. (`T2/S11-NV12`,`S11-YV12`; L)
- List memory: RD uses coherent memory, 32 KiB per list (2048 descriptors). HW maximum list length unknown. (`S`; L)

## Channels and planes
| Format | ch0 | ch1 | ch2 | Bytes per plane at 1920×1080 | Ev |
|---|---|---|---|---|---|
| packed (YUYV, UYVY, BGR24, XBGR32) | whole frame | — | — | 4147200 / 4147200 / 6220800 / 8294400 | `T2/S11-*` |
| NV12 | Y | CbCr interleaved | — | 2073600 / 1036800 | `T2/S11-NV12` |
| YV12 | Y | Cr (2nd plane in memory) | Cb (3rd plane) | 2073600 / 518400 / 518400 | `T2/S11-YV12`,`T3/S32-YV12` |

HW writes real pixel data on ch0, ch1 and ch2; plane contents and chroma order verified against a live source (`T3/S32-NV12`,`S32-YV12`; C).

RD builds one scatter list over a single contiguous-format buffer (`V4L2_PIX_FMT_NV12`, `YVU420`), then splits it at plane byte boundaries into per-channel lists. (`S`, `T2`; C)

## Slots
Per channel: 4 slots (n = 0..3), registers at `base + 0x8 + 12n`: LIST_LO, LIST_HI, COUNT. CH_CTRL (`base + 0x4`): [0] run, [n+1] slot n valid.
- One video buffer occupies the same slot index on every channel it uses. (`S`, `T2/S11-NV12`; C)
- RD assigns slots round-robin 0,1,2,3,0,… (`T1/S02`; C)
- Completion order follows slot order. (`T1/S02`; C)
- HW clears ch0's slot-valid bit when the slot completes (CH_CTRL read `0x1d` after slot 0 done, from `0x1f`). (`T1/S02`; C)
- ch1/ch2 CH_CTRL are not readable (`0xeeeeeeee`). RD writes them with read-modify-write, so the values it writes are garbage with many slot bits set; hardware tolerated it in traces. ch0's CH_CTRL alone gates every channel. With slot bits on ch0 only, every plane of every frame arrived at 60 Hz in NV12 and YV12, whether the ch1/ch2 CH_CTRL were written once at start, never written, or written 0 (no run bit). Slot bits on ch1/ch2 with only ch0's run bit: nothing completed and nothing was written on any channel. ch1/ch2 still take their lists from their own LIST/COUNT registers. (`T2/S11-NV12`,`S11-YV12` for unreadability; `E`: driver M2, `tests/logs/20261124-235252_6.8.12-gc573dbg.log` case 14 for semantics; C)
- Underrun: with every slot completed and none re-armed, the hardware stalls without an interrupt (ch0 CTRL reads 0x1, STATUS 0x00040041). Re-arming one slot completes at the next frame boundary (4.1–4.7 ms later), fully written and without error; two re-armed slots complete in order at frame cadence. Streaming with a single buffer runs at 60 Hz. (`E`: driver M2, `tests/logs/20261124-235252_6.8.12-gc573dbg.log`; C)

## Start
1. Configure the pipeline for the format (`video-pipeline.md`).
2. For each queued buffer (≤ 4): pick slot n; write LIST_LO/HI/COUNT on every channel used; set bit n+1 in each used channel's CH_CTRL.
3. Set CH_CTRL[0] (run) on ch0, and on ch1 (NV12, YV12), and on ch2 (YV12).
4. VIP_CTRL (0x1000)[0] = 1.
(`T1/S02`, `T2/S11`, `S`; C)

## Per frame
INT bit 1 → read ch0 STATUS (0x300): slot = [2:0] − 1. Buffer in that slot is complete. Clear the slot bit in ch0 CTRL if still set. Program the next queued buffer into the free slot and set its valid bits. (`T1/S02`, `S`; C)
- ch0 STATUS upper bits vary per frame (observed `0x00041021`, `0x00041022`, `0x00031023`, `0x00039024`); meaning unknown. (U)
- If no buffer is queued, leave the slot invalid; HW stalls on that slot (behaviour when all slots invalid: U).

## Stop
VIP_CTRL[0] = 0 → wait INT bit 0 (≤ 2 s) → reset domains (`init.md`). (`S`; L)

Effect of the domain resets: VIP_CTRL, COLOR_CTRL, PIX_MODE and ch0 CTRL read 0, ch0 STATUS reads 0x40, and CLIP returns to 0, 0, 1920, 1080 (its power-on value). RATE_CTRL keeps its value. I2C bus 1 is unaffected (500 ID reads after 200 stops, no mismatch). Timing with our driver: STREAMON to the first delivered frame 139–145 ms (50 ms clip settle, 10 ms scaler reset, one dropped frame); STREAMOFF 103–106 ms, mostly the three domain resets at ≈34 ms each. (`E`: driver M2, `tests/logs/20261124-235252_6.8.12-gc573dbg.log`; C)

## Free-running with no input
With no HDMI input the pipeline still completes ch0 lists every 16.6–16.7 ms (60 Hz). (`T1/S02`, `T2/S11`; C)
With no input the hardware writes exact black into every plane: YUYV bytes 80 10 80 10, UYVY 10 80 10 80, NV12/YV12 Y 0x10 and chroma 0x80, BGR24/XBGR32 0. Pre-filled buffers were overwritten on every plane and channel in all six formats. Frames arrive at 60 Hz whatever DV timings are set. (`E`: driver M2, `tests/logs/20261124-235252_6.8.12-gc573dbg.log`; C) RD instead overwrites the buffers with a CPU-drawn "no signal" image (`T1`,`T2`).

## Card frame store (stale content)
The card holds frames in on-board memory. In `T4/S41` the first frame after the stream start carried, in its last 76 lines (2084–2159 of 2160), picture content from a capture made hours earlier with another source. Meanwhile the driver had been unloaded and reloaded several times and the device reset by VM moves, but the card had stayed powered. Later frames were entirely new. So frame-store content survives driver reloads and device resets while the card is powered, and the first frame after a start can mix old and new lines. (`T4/S41`; C for the observation, U for the mechanism and for how many frames can be affected; open question 28)

Driver: drop (or verify) the first frame after every start. Treat card memory as holding data from earlier sessions (privacy).

## Line length (open)
720-wide YV12 (chroma lines of 360 bytes) fails: the Y plane is written in full, each chroma plane comes up 2016 bytes short, and the slot never completes (STATUS 0x00009020, no INT bit 1); the stop is still clean. NV12 and the packed formats work at 720 wide, and widths 640, 1280 and 1920 work in all six formats. The rule is unknown (open question 30). Driver: offer only widths verified in every format. (`E`: driver M2, `tests/logs/20261124-233457_6.8.0-151-generic.log`; C for the observation)

## Driver notes
- Use `vb2_dma_sg`. Coalesce adjacent DMA segments; split each plane at its byte boundary; emit one descriptor per contiguous run; length field = bytes / 4.
- Keep 4 slots full when buffers are available; the last free slot may stall the stream.
