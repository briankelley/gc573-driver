# Read-only BAR0 sweep across fresh locks (open question 41), 2026-11-27 01:48Z

Host, driver 471419EDEC56524224376F5 bound, PC loopback at 1080p60 (RGB full range), nothing else using the card. Tools: `bar0-sweep.c` (maps BAR0 read-only through sysfs and does aligned 32-bit reads only) and `q41-sweep.sh`.

- `stage1.txt`, `stage1.log`: one read of each offset in 0x1000–0x10fc that the driver does not read, 0.2 s apart, each logged and synced before the read. No fault and no effect on the card.
- `b1`–`b3`: the same offsets plus 0x1000, 0x1004, 0x1010 and 0x1080, sampled about every 1 ms for 6 s across an EDID serial change (a hot-plug, a fresh lock in the same timings) with no stream. Each line is a change: CLOCK_MONOTONIC ns, offset, old value, new value.
- `a1`–`a3`: the same with a stream running free across the change (`gc573-cap -X`, change-test mode, no per-frame log). `a4`, `a5`: the same with `gc573-cap -n 780 -F`, which logs every frame's timestamp (`FRAME ... ts_ms=`, CLOCK_MONOTONIC).
- The EDID images used (the driver's default and a serial variant from `tools/roku/edid-variant.py`) are not included.

Result (times relative to 0x1010 becoming valid again):
- 0x10a4[14:13] goes 3 → 0 at the input loss and back to 3, and RATE_CTRL (0x1080) bit 3 goes the other way.
  - With no stream: +1033 to +1034 ms (b1–b3).
  - With a stream running free across it: +115.9 to +116.6 ms (a1–a5).
- In a4/a5 the re-phase's short completion follows 3 ms later (+120.0 and +119.9 ms) and the long one at +149.7 ms.
- Of the offsets the driver does not use, no other changed. 0x1004 and 0x1010 showed their documented loss values, and in the stream trials the driver's own writes changed 0x1000 (VIP_CTRL) and RATE_CTRL's rate field.
