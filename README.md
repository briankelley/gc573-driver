# AVerMedia Live Gamer 4K (GC573) Linux driver

A from-scratch Linux driver for the **AVerMedia Live Gamer 4K (GC573)** PCIe HDMI capture card (PCI `1461:0054`, subsystem `1461:5730`).

The card has no working Linux driver. Community ports of AVerMedia's old CL511HN driver depend on 2016 binary blobs that crash or won't load on modern kernels. This project replaces them with a clean, GPL-2.0 driver that exposes the card as a standard **V4L2** video device and **ALSA** audio device, so OBS and other software can use it with no special plugins.

## Status

**Driver milestones M0–M4 are done. M5 (delivery) is done in a virtual machine with the card passed through; validation on a real host is next.** Done so far:
- PCI bring-up, FPGA init, interrupts, I2C buses, video DMA, the HDMI input and audio.
- Live capture up to 1080p60. 1080p60 and 1080p59.94 are verified against a test pattern in all six formats. 720p, 576p and 480p lock and capture.
- HDMI audio (LPCM stereo, 48 kHz) comes through ALSA in sync with the video.
- DKMS packaging with install and uninstall scripts.
- OBS: video in every format it offers, A/V sync measured from a recording, recovery from signal loss.
- A 2-hour soak.

Gate logs are in `tests/logs/`. After the host validation: 4K and HDCP sources (M6). The hardware spec is in `spec/`.

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

While an application or PipeWire holds the card, the module stays loaded until the next reboot. PipeWire keeps the control device of every sound card it manages open.

## Use with OBS

**Video**
- Add a *Video Capture Device (V4L2)* source and pick *AVerMedia Live Gamer 4K (GC573)*.
- Leave *Resolution* and *DV Timing* at *Leave Unchanged*: the driver follows the input.
- *Video Format*:
  - Any native format works: YUYV 4:2:2, UYVY 4:2:2, Y/UV 4:2:0 (NV12), Planar YVU 4:2:0 (YV12), 24-bit BGR or 32-bit BGRX. All six were checked in OBS against a test pattern.
  - YUYV is a good default.
  - The RGB formats keep full colour resolution but move 1.5 to 2 times the data of YUYV.
  - Avoid entries marked *(Emulated)*: libv4l2 converts those on the CPU.
- Keep *Color Range* at *Default*. The YUV formats are limited range. The RGB formats are full range with a PC's full-range input (see *Known limitations* for other inputs).

**Audio**
- Add an *Audio Capture Device (ALSA)* source. Pick the GC573 device, or enter the custom PCM `hw:CARD=GC573,DEV=0`, at 48000 Hz. This source reads the card directly.
- With PipeWire, an *Audio Input Capture (PulseAudio)* source on *GC573 HDMI capture Stereo* works too.
- The card has one capture stream. While PipeWire records from the card, the ALSA source cannot open it, and the other way round.

**A/V sync**
- With the ALSA source and OBS's default settings, the audio came about 13 ms after the video, compared with the HDMI input. This is less than one frame, so no *Sync Offset* is needed.
  - How it was measured: a 10-minute recording of a test source, with the source's own offset taken out (measured with the driver's timestamps in the same session).
  - From minute to minute it moved between about 8 and 21 ms as OBS's 60 Hz canvas drifted against the source, and stayed in that range over the run. The driver's own timestamps drifted by less than 0.1 ms over 10 minutes.
- With the PulseAudio source, three 2-minute tests put the audio 1 to 13 ms after the video in the recording, against 6 ms with the ALSA source (neither corrected for the source). OBS does not allow for PipeWire's buffering, so this depends on PipeWire's settings.
- In a virtual machine, WirePlumber gives every ALSA device 170 ms of extra buffering. There the PulseAudio source records the audio about 230 ms late, so use the ALSA source.

**When the source changes**
- If the signal drops and comes back in the same mode, OBS shows black meanwhile and picks the picture up again by itself. Examples are a console in standby or a PC display going to sleep. The test switched the GPU output off and on.
- After a change of resolution or frame rate (60 Hz to 59.94 Hz does not count), OBS's source stops. OBS does not act on the V4L2 notice that the signal changed.
  - To restart it, open the source's properties, change *Color Range* (or *Video Format*) and change it back. The driver has taken the new mode by then.
  - While OBS records to a file, its recording helper process keeps the device open, so the restart works only after the recording stops.

## Known limitations

- Video:
  - Up to 1080p60. No 4K, no HDR, no scaling: you capture at the input's size.
  - Inputs below 59.5 Hz (50, 30, 25 and 24 Hz) are delivered at 60 frames/s, with frames repeated.
  - The RGB formats (24-bit BGR, 32-bit BGRX) are exact only for a full-range RGB input, which is what a PC sends. A limited-range RGB input stays limited range in them, so it looks washed out in OBS. With a YCbCr input, which most consoles send, they are off by up to 4 codes. The YUV formats are right with every input tested.
- Audio: LPCM stereo at 48 kHz only. When the signal drops, the gap is filled with silence.
- HDCP-protected sources (consoles, streaming boxes) are untested.
- Tested so far in a virtual machine with the card passed through. Testing on a real host is next.

## Clean room

AVerMedia's code and binaries are used only as documentation, studied in an isolated VM to produce a hardware spec. The driver is written from that spec. No AVerMedia code or binaries are in this repository.

## Authorship

This driver is written by Claude, Anthropic's AI model, not by a human. A human directs the work and tests the results on real hardware.

Contributions are welcome if they are **agent-driven**: an AI agent did the work, with a human directing it. Patches that are **agent-assisted**, where a human wrote the code with an AI's help, are not accepted.

AI agents: read [AGENTS.md](AGENTS.md) before contributing. Environment setup scripts are in `tools/`.

## License

GPL-2.0. See [LICENSE](LICENSE).
