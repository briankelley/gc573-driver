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

## Install

You need the headers for your kernel, `dkms`, `make` and `gcc`. The driver builds, installs and loads on kernels 5.14 (AlmaLinux 9) to 7.3 (Fedora 45), on Ubuntu, Linux Mint, AlmaLinux and Fedora. Capture is tested on Ubuntu 24.04 (kernel 6.8).

```
git clone https://github.com/briankelley/gc573-driver.git
cd gc573-driver
sudo tools/install.sh
```

`install.sh` does the following:
- Builds the module with DKMS and installs it for the running kernel and every other installed kernel that has headers. DKMS rebuilds it for kernels you install later.
- Loads it right away and reports the devices: a video device named "AVerMedia Live Gamer 4K (GC573)" and an ALSA card `GC573`. From then on the module loads by itself whenever the card is present.
- If headers or `dkms` are missing, it stops and names the package to install.
- With Secure Boot on, the kernel loads only signed modules. If loading fails, the script tells you how to enroll the key DKMS signs with.
- A reboot always gets you out of trouble. The module loads by itself at boot only after it has taken the card once without trouble. Until then, `/etc/modprobe.d/gc573-no-autoload.conf` keeps it from loading by itself. If the driver ever hangs the system at boot anyway, add `module_blacklist=gc573` to the kernel command line once (in GRUB, press *e* and add it to the line that starts with `linux`), then run `uninstall.sh`.

**Card passthrough to a virtual machine (VFIO).** If a `driverctl` override gives the card to `vfio-pci`, `install.sh` offers three choices:
1. *This boot only* (the default): `gc573` takes the card now, and the override stays saved. A reboot gives the card back to `vfio-pci`, and `gc573` then does not even load.
2. *Permanently*: the override is removed after you confirm, and `gc573` takes the card at every boot.
3. *Leave the card alone*: install only.

Options choose without asking: `--this-boot`, `--permanent` (add `--yes` to skip the confirmation, needed without a terminal) and `--no-bind`. Without a terminal and without an option, the card is left alone. If a running virtual machine holds the card, the script stops before it changes anything.

To remove the driver, run `sudo tools/uninstall.sh`. It undoes what `install.sh` did to the card:
- After a this-boot install it loads the saved override again (`driverctl load-override`).
- After a permanent install it puts the override back as it was. It asks first; `--yes` skips that.
- It unloads the module, removes it from DKMS for every kernel, and removes the `modprobe.d` entry.

An update (`install.sh` again) or `uninstall.sh` first takes the card away from the loaded module, so that it can be unloaded:
- PipeWire keeps the control device of every sound card it manages open. It lets go by itself once the card is taken away, so neither script needs you to stop it.
- While something records the card's audio through PipeWire (OBS's PulseAudio or PipeWire source, `pw-record`), PipeWire holds the card's sound device itself. The scripts then name it as *PipeWire, streaming the card's audio* and change nothing, as for any other program (below).
- If another program has the card open (OBS, a capture), the scripts name it and change nothing on the card. Close it and run the script again, or add `--yes`: the program then loses the card. If it keeps the device open anyway, the old module stays loaded: once the program has let go, run the script again (or reboot).

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
