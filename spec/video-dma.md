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
- ch1/ch2 CH_CTRL are not readable (`0xeeeeeeee`). RD writes them with read-modify-write, so the values it writes are garbage with many slot bits set; hardware tolerated it in traces. Whether ch1/ch2 slot bits are independently honoured is unknown. Our driver: keep shadows, write exact intended values. (`T2/S11-NV12`,`S11-YV12`; C for unreadability, U for semantics)

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

## Free-running with no input
With no HDMI input the pipeline still completes ch0 lists every 16.6–16.7 ms (60 Hz). (`T1/S02`, `T2/S11`; C)
Caveat: RD overwrites buffers with a CPU-drawn "no signal" image when there is no input, so no-input captures prove the slot/IRQ handshake but **not** that HW writes pixel data. First driver experiment: pre-fill buffers with a pattern, stream with no input, check whether HW overwrote them (all planes, all channels).

## Driver notes
- Use `vb2_dma_sg`. Coalesce adjacent DMA segments; split each plane at its byte boundary; emit one descriptor per contiguous run; length field = bytes / 4.
- Keep 4 slots full when buffers are available; the last free slot may stall the stream.
