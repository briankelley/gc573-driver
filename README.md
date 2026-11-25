# AVerMedia Live Gamer 4K (GC573) Linux driver

A from-scratch Linux driver for the **AVerMedia Live Gamer 4K (GC573)** PCIe HDMI capture card (PCI `1461:0054`, subsystem `1461:5730`).

The card has no working Linux driver. Community ports of AVerMedia's old CL511HN driver depend on 2016 binary blobs that crash or won't load on modern kernels. This project replaces them with a clean, GPL-2.0 driver that exposes the card as a standard **V4L2** video device and **ALSA** audio device, so OBS and other software can use it with no special plugins.

## Status

**Driver milestones M0–M4 are done. M5 (delivery) is done in a virtual machine with the card passed through; validation on a real host is next.** Done so far:
- PCI bring-up, FPGA init, interrupts, I2C buses, video DMA, the HDMI input and audio.
- Live capture up to 1080p60. 1080p60 and 1080p59.94 are verified against a test pattern in all six formats. 720p, 576p and 480p lock and capture.
- HDMI audio (LPCM stereo, 48 kHz) comes through ALSA in sync with the video.
- DKMS packaging with install and uninstall scripts.
- OBS: video in every format it offers, A/V sync measured from a recording, and every kind of source change, with OBS driven unattended through obs-websocket.
- A 2-hour soak: OBS recorded while the source changed every 3 minutes (40 changes, all recovered).

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
- Turn off *Use buffering* (through obs-websocket: `"buffering": false`).
  - With buffering on, OBS's default, OBS plays the frames by their timestamps against a clock of its own, and that clock stands still while no frame is waiting. Every pause in the frames shorter than 2 s therefore adds its length to the video's delay, for good.
  - The driver pauses 0.2–0.9 s at each source change, such as a signal loss or a colour-format change. After a few changes, the audio in a test recording ran up to 0.4 s ahead of the picture.
  - With buffering off, OBS shows each frame as it arrives, and the A/V offset stays put.

**Audio**
- Add an *Audio Capture Device (ALSA)* source. Pick the GC573 device, or enter the custom PCM `hw:CARD=GC573,DEV=0`, at 48000 Hz. This source reads the card directly.
- With PipeWire, an *Audio Input Capture (PulseAudio)* source on *GC573 HDMI capture Stereo* works too.
- The card has one capture stream. While PipeWire records from the card, the ALSA source cannot open it, and the other way round.

**A/V sync**

These were measured with the ALSA source and a test source on the HDMI input. The source's own offset was taken out, using the driver's timestamps in the same session. All results are against the HDMI input:
- *Use buffering* off: in a 3-minute recording, the audio came about 12 ms after the video, in the same frame period for 175 of 177 flashes.
- *Use buffering* on: a 10-minute recording put the audio about 13 ms after the video. From minute to minute it moved between about 8 and 21 ms as OBS's 60 Hz canvas drifted against the source. Two later 3-minute runs put it 27 ms and 5 ms before the video: OBS takes its timing from the first frames of a session. On top of that, every source change adds its pause (above).
- In steady state both stay inside what people notice (ITU-R BT.1359: audio 45 ms early or 125 ms late), so no *Sync Offset* is needed.
- The driver's own timestamps drifted by less than 0.1 ms over 10 minutes, and they keep their A/V offset through the stream restarts at source changes (within 0.2 ms).
- Through the 2-hour soak's 40 source changes (buffering off), each stretch between two changes stayed between 17 ms early and 74 ms late. These figures include the test source's own offset, which changes each time the source restarts.
- With the PulseAudio source, three 2-minute tests put the audio 1 to 13 ms after the video in the recording, against 6 ms with the ALSA source (neither corrected for the source). OBS does not allow for PipeWire's buffering, so this depends on PipeWire's settings.
- In a virtual machine, WirePlumber gives every ALSA device 170 ms of extra buffering. There the PulseAudio source records the audio about 230 ms late, so use the ALSA source.

**Device names that stay put**
- V4L2 source: set the device to `/dev/v4l/by-path/pci-<address>-video-index0` (`ls -l /dev/v4l/by-path/` shows yours) rather than `/dev/videoN`, whose number depends on the other video devices present. OBS's list shows only `/dev/videoN` names, but OBS accepts the path when it is set through obs-websocket (`SetInputSettings`, `device_id`) or in the scene collection file.
- With that path, OBS does not reconnect by itself after the driver is reloaded, because its reconnect looks for udev's `/dev/videoN` name. Reopen the source as described below.
- ALSA source: use the custom PCM `hw:CARD=GC573,DEV=0`, not a card number.

**When the source changes**

These were measured with OBS 32.2 in the VM, with the V4L2 source in YUYV at 1080p60, driven through obs-websocket with nobody at the controls. The runs covered 2 rounds of every change, and a 2-hour recording with a change every 3 minutes. "Back after" is the time from when the PC's output came back or changed to the first screenshot of the source that shows the new picture. It includes the GPU's own mode set.

| Change | What OBS does by itself | Back after |
|---|---|---|
| Signal lost, then back in the same mode (a console in standby, a PC display asleep; tested: the GPU output off for 8 s, then on) | Shows black meanwhile, then the picture again | 1.6–1.9 s |
| 60 Hz ↔ 59.94 Hz | Follows | 2.1–2.4 s |
| Colour format or range at the same timings (RGB full ↔ limited range, RGB ↔ YCbCr 4:4:4) | Follows | 0.3–1.1 s |
| EDID set again: the same image (no hot-plug) or a new one (hot-plug) | Follows | 0.3–0.7 s or 2.8–4.2 s |
| Another resolution or frame rate (tested: 1080p60 ↔ 720p59.94) | The source stops | After a reopen: 0.2–0.3 s |

At another resolution or frame rate, the driver ends the stream, because the format must not change under an application that is streaming, and it reports the change with a V4L2 source-change event. OBS ignores the event, and its source stops when the stream ends. Reopen the source by changing a setting that makes OBS set the device up again; the driver's new mode then comes up.
- By hand: in the source's properties, change *Color Range* and change it back.
- Through obs-websocket: send `SetInputSettings` with `inputName` set to the V4L2 source and `inputSettings` set to `{"color_range": 1}`. Next time, send `{"color_range": 0}`. For the YUV formats both values mean limited range, so the picture stays the same. Setting the value the source already has does nothing.

While OBS records, the reopen works only with *Hybrid MP4* (tested; OBS 32's default) or *Hybrid MOV*, which OBS writes itself. The other formats (MKV, MP4, MOV, ...) run OBS's `obs-ffmpeg-mux` helper. The helper inherits OBS's open handle on the device, so the device stays busy and the reopen fails until the recording stops. OBS sets up its recording output when it starts and when the output settings change in its Settings window. A format set through obs-websocket (`SetProfileParameter`) takes effect only at the next start.

**Driving OBS from a program (obs-websocket)**
- Set `"buffering": false` on the V4L2 source (see *Video*).
- `GetSourceScreenshot` of the V4L2 source:
  - PNG at 1920x1080 takes 55–70 ms per request and comes within 2 codes of the source's picture.
  - PNG at 960x540 takes about 18 ms.
  - JPG is lossy (errors of about 25 codes). Use PNG to compare pictures.
- `InputVolumeMeters` events (subscribe with `1 << 16`) arrive every 50 ms with the levels of OBS's last audio tick. A sound shorter than that, such as a one-frame beep, shows in only about half of the events.
- A rule that worked in the tests: reopen the source (above) after any change of the source's mode, or whenever its screenshots stay black for more than a few seconds while the source should show a picture. A reopen when nothing changed costs a fraction of a second.
- When no frame arrives for 5 frame periods, which happens during a source change, OBS logs `select timed out` and asks the driver to log its status (`VIDIOC_LOG_STATUS`). That adds about 70 lines to the kernel log per change.

## Known limitations

- Video:
  - Up to 1080p60. No 4K, no HDR, no scaling: you capture at the input's size.
  - Inputs below 59.5 Hz (50, 30, 25 and 24 Hz) are delivered at 60 frames/s, with frames repeated.
  - The RGB formats (24-bit BGR, 32-bit BGRX) are exact only for a full-range RGB input, which is what a PC sends. A limited-range RGB input stays limited range in them, so it looks washed out in OBS. With a YCbCr input, which most consoles send, they are off by up to 4 codes. The YUV formats are right with every input tested.
- Audio: LPCM stereo at 48 kHz only. When the signal drops, the gap is filled with silence.
- OBS does not follow a change of resolution or frame rate by itself: reopen the source (see *When the source changes*).
- Unloading or reloading the driver does not look like an unplug to the source: the test PC (NVIDIA GPU) kept its output on and the card's EDID in use.
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
