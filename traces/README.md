# traces/

Golden reference data: register and bus traces of the reference driver (RD), run in the `gc573-ref` VM. Evidence behind `spec/` tags `T1`..`T3`; expected values for regression tests.

## Files
| File | Input | Scenarios (MARK lines) |
|---|---|---|
| `T1.tsv.xz` | none | S01 load · S01 30 s idle · S02 query + YUYV 1080p stream · S03 unload |
| `T2.tsv.xz` | none | S10 load · S11-`<fmt>` 1080p stream per pixel format · S12 720p · S13 audio · S14 unload |
| `T3.tsv.xz` | Roku Ultra → HDCP stripper → GC573 | S20 load with 2160p59.94 4:2:0 (BT.709) present · S21–S23 4K YUYV/NV12/YV12 · S24–S26 4K→1080p YUYV/BGR24/XBGR32 · S27 audio · S30 cable unplug/replug · S31 source 2160p→1080p · S32-`<fmt>` 1080p59.94 all formats · S33 1080p→720p · S34 audio · S36 unload |

## Format
TSV, `#` comment lines. Read: `xz -dc traces/T3.tsv.xz | ...`

Columns: `t_us` (µs from first event) · `op` · args.

| op | args | meaning |
|---|---|---|
| `MARK` | text | scenario boundary |
| `MR32` / `MW32` | off val | BAR0 32-bit read / write (hex) |
| `MR8` | off val | BAR0 8-bit read |
| `IRQ` | — | interrupt handler entry; status = next `MR32 00010` |
| `I2C` | R\|W dev bank reg val ok | completed bus-1 transfer. dev: 8-bit address. bank: `-` unbanked device, `*` access to bank register 0x0f, else bank in effect (last value written to that device's 0x0f & 7; devices 0x90, 0x58, 0x70). val: hex bytes, multi-byte transfers concatenated. ok: 1 = success |
| `DLY` | m\|M\|u n | RD delay: m = sleep ms, M = busy-wait ms, u = busy-wait µs (decimal) |
| `ALLOC` / `FREE` | buf size | RD coherent DMA allocation (size hex) |
| `DREF` | off buf+delta | the preceding MMIO write at `off` loaded a DMA address inside `buf` |

Bus-1 engine registers 0x180–0x1a4 are omitted from MMIO; their transfers appear as `I2C` lines.

## Sanitization
- Removed: caller addresses, process names, RD-internal events, DMA buffer contents.
- EDID contents redacted (`xx`): EDID RAM devices 0xa8 / 0xd8, and splitter TX-port DDC FIFO reg 0x30 (devices 0x68–0x6e).
- DMA addresses are guest-physical and meaningless outside the session; buffers renumbered `bufN`.
- Raw captures stay private.

## Use
- Spec evidence: `T<n>/<scenario>` tags refer to the MARK windows here.
- Tests: compare register state per scenario (values, not order) against these.
