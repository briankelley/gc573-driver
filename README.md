# AVerMedia Live Gamer 4K (GC573) Linux driver

A from-scratch Linux driver for the **AVerMedia Live Gamer 4K (GC573)** PCIe HDMI capture card (PCI `1461:0054`, subsystem `1461:5730`).

The card has no working Linux driver. Community ports of AVerMedia's old CL511HN driver depend on 2016 binary blobs that crash or won't load on modern kernels. This project replaces them with a clean, GPL-2.0 driver that exposes the card as a standard **V4L2** video device and **ALSA** audio device, so OBS and other software can use it with no special plugins.

## Status

**Driver milestones M0–M4 done: PCI bring-up, FPGA init, interrupts, I2C buses, video DMA, the HDMI input and audio. Live capture up to 1080p60 works: 1080p60 and 1080p59.94 verified against a test pattern in all six formats, 720p, 576p and 480p modes lock and capture, and HDMI audio (LPCM stereo 48 kHz) comes through ALSA in sync with the video; gate logs in `tests/logs/`. Next: M5, DKMS packaging, OBS and soak tests. Hardware spec in progress (`spec/`).** Not ready for general use yet: no install script, no 4K, inputs below 59.94 Hz arrive at 60 frames/s with repeated frames, and HDCP sources are untested.

Targets: 1080p60 capture first, then 4K60/HDR. Packaged with DKMS.

## Clean room

AVerMedia's code and binaries are used only as documentation, studied in an isolated VM to produce a hardware spec. The driver is written from that spec. No AVerMedia code or binaries are in this repository.

## Authorship

This driver is written by Claude, Anthropic's AI model, not by a human. A human directs the work and tests the results on real hardware.

Contributions are welcome if they are **agent-driven**: an AI agent did the work, with a human directing it. Patches that are **agent-assisted**, where a human wrote the code with an AI's help, are not accepted.

AI agents: read [AGENTS.md](AGENTS.md) before contributing. Environment setup scripts are in `tools/`.

## License

GPL-2.0. See [LICENSE](LICENSE).
