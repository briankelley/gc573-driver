# AVerMedia Live Gamer 4K (GC573) Linux driver

A from-scratch Linux driver for the **AVerMedia Live Gamer 4K (GC573)** PCIe HDMI capture card (PCI `1461:0054`, subsystem `1461:5730`).

The card has no working Linux driver. Community ports of AVerMedia's old CL511HN driver depend on 2016 binary blobs that crash or won't load on modern kernels. This project replaces them with a clean, GPL-2.0 driver that exposes the card as a standard **V4L2** video device and **ALSA** audio device, so OBS and other software can use it with no special plugins.

## Status

**Driver milestones M0–M4 are done. M5 (delivery) is done in a virtual machine with the card passed through, and the validation on a real host is under way (Linux Mint 22, kernel 6.8).** Done so far:
- PCI bring-up, FPGA init, interrupts, I2C buses, video DMA, the HDMI input and audio.
- Live capture up to 1080p60. 1080p60 and 1080p59.94 are verified against a test pattern in all six formats. 720p, 576p and 480p lock and capture.
- HDMI audio (LPCM stereo, 48 kHz) comes through ALSA in sync with the video.
- DKMS packaging with install and uninstall scripts.
- OBS: video in every format it offers, A/V sync measured from a recording, and every kind of source change, with OBS driven unattended through obs-websocket.
- A 2-hour soak: OBS recorded while the source changed every 3 minutes (40 changes, all recovered).
- 30 minutes of the same on a debug kernel (kmemleak, lockdep, KASAN, DMA-API debugging): no leak and no kernel warning.

Gate logs are in `tests/logs/`. After the host validation comes a Roku through an HDCP filter (M6). Then picture controls and scaling, 4K, and the rest of the card (M7–M9). The hardware spec is in `spec/`.

Targets: 1080p60 capture first, then 4K60/HDR.

## Clean room

AVerMedia's code and binaries are used only as documentation, studied in an isolated VM to produce a hardware spec. The driver is written from that spec. No AVerMedia code or binaries are in this repository.

## Hardware tooling

An HDCP stripper / splitter was used in the Roku HDMI chain to facilitate accurate frame capture. The one I used was ASIN:B0CLL5GQXT (link: https://www.amazon.com/CORSAHD-60Hz-HDMI-Splitter-1x2/dp/B0CLL5GQXT)

## Authorship

This driver is written by Claude, not by a human. The human has directed the work and tests the results on real hardware and has articulated parts of this readme to make it clear who is doing the heavy lifting here. As the repo owner, I'm *not even a little bit* shy about telling the reader that I not only didn't write a line of code for this driver, but didn't review any of it because I can't read kernel C. My specific need for this driver is limited, but the code in this repo is as *complete and thorough as I can direct it* with models from the late 2026 claude-opus-5-5@max / claude-fable-5-2@max / gpt-6-astra@max era. This driver package and repo are open to future improvements as model capabilities improve over time.

Contributions are welcome and preferred if they are **agent-driven**: an AI agent did the work, with a human directing it.

AI agents: read [AGENTS.md](AGENTS.md) before contributing. Environment setup scripts are in `tools/`.

## License

GPL-2.0. See [LICENSE](LICENSE).
