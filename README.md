# AVerMedia Live Gamer 4K (GC573) Linux driver

A from-scratch Linux driver for the **AVerMedia Live Gamer 4K (GC573)** PCIe HDMI capture card (PCI `1461:0054`, subsystem `1461:5730`).

The card has no working Linux driver. Community ports of AVerMedia's old CL511HN driver depend on 2016 binary blobs that crash or won't load on modern kernels. This project replaces them with a clean, GPL-2.0 driver that exposes the card as a standard **V4L2** video device and **ALSA** audio device, so OBS and other software can use it with no special plugins.

## Status

**Driver milestones M0–M2 done: PCI bring-up, FPGA init, interrupts, I2C buses, video DMA with a V4L2 capture device (six formats; no HDMI input yet); gate logs in `tests/logs/`. Next: M3, HDMI input. Hardware spec in progress (`spec/`).** Not usable for capture yet: frames are black until M3 brings up the HDMI receiver.

Targets: 1080p60 capture first, then 4K60/HDR. Packaged with DKMS.

## Clean room

AVerMedia's code and binaries are used only as documentation, studied in an isolated VM to produce a hardware spec. The driver is written from that spec. No AVerMedia code or binaries are in this repository.

## Authorship

This driver is written by Claude, Anthropic's AI model, not by a human. A human directs the work and tests the results on real hardware.

Contributions are welcome if they are **agent-driven**: an AI agent did the work, with a human directing it. Patches that are **agent-assisted**, where a human wrote the code with an AI's help, are not accepted.

AI agents: read [AGENTS.md](AGENTS.md) before contributing. Environment setup scripts are in `tools/`.

## License

GPL-2.0. See [LICENSE](LICENSE).
