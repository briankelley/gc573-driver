# Audio capture DMA

HDMI audio is extracted by the IT6805 and delivered to the FPGA; the FPGA writes PCM periods into two host buffers alternately (ping-pong).

## Registers
See `regmap.md` §Audio DMA. Summary: AUD_BUF0 (0x208/0x20c), AUD_BUF1 (0x210/0x214), period length in dwords (0x204 and 0x21c, same value), DMA_RUN[1] (0x008), AUDIO_DONE (0x014), INT bits 4 and 5, AUDIO_SAMPLE_PERIOD (0x10a0).

## Sample rate detection
fs = 1e8 / AUDIO_SAMPLE_PERIOD (0x10a0), rounded to the nearest 100. `0xffffffff` = no audio. RD samples it up to 5 times and snaps to {32000, 44100, 48000, 88200, 96000, 176400, 192000}; falls back to 48000. (`S`,`T1`,`T2/S13`; L)

## Period
RD period = 10 ms of 16-bit stereo: `bytes = (fs / 100) × 4`, register value = bytes / 4. 48 kHz → 1920 bytes → `0x1e0`. (`T1/S01i`,`T2/S13`,`S`; C)

## Start (RD order)
1. Read 0x10a0 (detect fs).
2. 0x200 = 0.
3. 0x2b4 = 0, 0x2b8 = 1, 0x2bc = 2, 0x2c0 = 3.
4. 0x204 = 0x21c = period_bytes / 4.
5. 0x208/0x20c = buffer 0 address lo/hi; 0x210/0x214 = buffer 1 address lo/hi.
6. 0x218 = 0.
7. DMA_RUN (0x008) |= 2.
(`T1/S01i`,`T2/S13`,`S`; C)

## Running
INT bit 5 every period (10.00 ms ± 0.1 ms observed). AUDIO_DONE[1:0]: 1 → buffer 0 holds a new period, 2 → buffer 1. Alternates 1, 2, 1, 2. The driver must consume the completed buffer before the hardware returns to it (one period later). (`T2/S13`; C)

## Stop
DMA_RUN = 0 → INT bit 4. (`T1/S01i`,`S`; C)

## Unknown
- PCM layout inside a period (assumed S16_LE interleaved stereo, L/R order) — needs a real audio source. (U)
- Meaning of 0x200, 0x218, slot map 0x2b4–0x2c0, why two period registers. (U)
- Multichannel (> 2 ch) and high-rate behaviour. (U)
- Whether buffer addresses may change while running (would allow DMA straight into the ALSA ring). (U)

## Driver notes
- ALSA PCM capture, 1 substream. Simplest correct design: two coherent ping-pong buffers of one period each, copy each completed period into the ALSA ring in a threaded handler, `snd_pcm_period_elapsed` per period.
- Report rates from detection; reconfigure on rate change (period size depends on fs).
