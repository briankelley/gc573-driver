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
- While something records the card's audio through PipeWire (OBS's PulseAudio or PipeWire source, `pw-record`), PipeWire holds the card's sound device itself. The scripts then name it as *PipeWire, streaming the card's audio* and change nothing, as for any other program (below). PulseAudio and pipewire-media-session are handled the same way. The scripts tell these sound servers by the program file they run from `/usr/bin` or `/bin`.
- If another program has the card open (OBS, a capture), the scripts name it and change nothing on the card. Close it and run the script again, or add `--yes`: the program then loses the card. If it keeps the device open anyway, the old module stays loaded: once the program has let go, run the script again (or reboot).
- A program other than the sound server that has the card's sound devices open is never overridden, not even with `--yes`. Neither is a program that has its I2C devices open (`/dev/i2c-*`: ddcutil, i2c-tools); these exist only with the module parameters `i2c_bus1` or `i2c_bus02`. Taking the card would wait until the program closes them: always for the I2C devices, and for the sound devices with a `gc573` older than this version. Close it and run the script again.
- If taking the card has not finished after 10 s anyway, the script says so and stops. That happens when a program opened the card in the meantime, or holds it where the scripts cannot see it. The card goes once that program closes it. Until then, both scripts refuse to run, so that they do not wait for it too.

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
- On a weak GPU, run OBS minimized to the tray while it records (`obs --minimize-to-tray`), so that it draws no preview. On the test PC's GeForce GT 710, drawing the preview made OBS lag while it recorded.

**Audio**
- Use the ALSA source below. It reads the card directly and opens the GC573 alone. The PulseAudio source behaves the same over a long recording (see *A/V sync*). On top of that, it adds PipeWire's buffering, which OBS does not allow for.
- Add an *Audio Capture Device (ALSA)* source at 48000 Hz, with the custom PCM `hw:CARD=/dev/snd/by-path/pci-<address>,DEV=0` (`ls -l /dev/snd/by-path/` shows yours, the link to the GC573's `controlC` node). This source reads the card directly.
  - `hw:CARD=GC573,DEV=0`, or picking the GC573 in the list, works too, but alsa-lib finds a card by its name by opening the control device of every sound card before it, a webcam's microphone included. By its path, alsa-lib opens the GC573 alone.
- With PipeWire, an *Audio Input Capture (PulseAudio)* source on *GC573 HDMI capture Stereo* works too. PipeWire passes the card's samples on unchanged, at the card's clock (measured: exactly 48000 samples per second of the source), so over a long recording it behaves as the ALSA source does (see *A/V sync*).
- The card has one capture stream. While PipeWire records from the card, the ALSA source cannot open it, and the other way round.

**A/V sync**

These were measured with the ALSA source and a test source on the HDMI input. The source's own offset was taken out, using the driver's timestamps in the same session. All results are against the HDMI input:
- *Use buffering* off: in a 3-minute recording, the audio came about 12 ms after the video, in the same frame period for 175 of 177 flashes.
- *Use buffering* on: a 10-minute recording put the audio about 13 ms after the video. From minute to minute it moved between about 8 and 21 ms as OBS's 60 Hz canvas drifted against the source. Two later 3-minute runs put it 27 ms and 5 ms before the video: OBS takes its timing from the first frames of a session. On top of that, every source change adds its pause (above).
- In steady state both stay inside what people notice (ITU-R BT.1359: audio 45 ms early or 125 ms late), so no *Sync Offset* is needed.
- The driver's own timestamps drifted by less than 0.1 ms over 10 minutes, and they keep their A/V offset through the stream restarts at source changes (within 0.2 ms).
- Through the 2-hour soak's 40 source changes (buffering off), each stretch between two changes stayed between 17 ms early and 74 ms late. These figures include the test source's own offset, which changes each time the source restarts.
- Over a long recording, OBS's own A/V offset wanders in a sawtooth of up to about 70 ms. This happens with any capture source whose clock differs from the computer's, so it is not this driver's doing:
  - It comes from libobs's 70 ms timestamp smoothing. OBS lays an audio source's samples back to back for as long as their timestamps stay within 70 ms of where it expects them.
  - The card's audio runs on the source's clock. The test PC's HDMI audio ran about 25 ppm fast against the computer's clock, so the sound fell behind the picture by about 1.5 ms a minute on average.
  - When the gap reaches 70 ms, OBS puts the sound back at its timestamps, and 70 ms of it are lost. In the 2-hour host soak that happened after 56 and 101 minutes. With a source whose clock runs slow, the sound moves ahead of the picture instead, and the reset inserts 70 ms of silence.
  - Reopening the video source does not reset it. Reopening the audio source does not reset it either: in a test, two audio reopens moved the offset by 10.5 ms one way and 10.7 ms the other.
  - Where the offset starts also varies from one OBS start to the next: 0 ms and 27 ms in two tests.
  - The PulseAudio source gets the same samples on the same clock (above), so it shows the same sawtooth.
- With the PulseAudio source, three 2-minute tests put the audio 1 to 13 ms after the video in the recording, against 6 ms with the ALSA source (neither corrected for the source). OBS does not allow for PipeWire's buffering, so this depends on PipeWire's settings.
- In a virtual machine, WirePlumber gives every ALSA device 170 ms of extra buffering. There the PulseAudio source records the audio about 230 ms late, so use the ALSA source.

**Device names that stay put**
- V4L2 source: set the device to `/dev/v4l/by-path/pci-<address>-video-index0` (`ls -l /dev/v4l/by-path/` shows yours) rather than `/dev/videoN`, whose number depends on the other video devices present. OBS's list shows only `/dev/videoN` names, but OBS accepts the path when it is set through obs-websocket (`SetInputSettings`, `device_id`) or in the scene collection file.
- With that path, OBS does not reconnect by itself after the driver is reloaded, because its reconnect looks for udev's `/dev/videoN` name. Reopen the source as described below.
- ALSA source: use the custom PCM `hw:CARD=/dev/snd/by-path/pci-<address>,DEV=0`, not a card number, which can change from one boot to the next.

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

A source can pass through another mode on its way to its own: after a hot-plug, a PC shows its preferred mode until the desktop sets the one it was in. The driver does not end the stream for that. It holds the stream (no frames) for up to 1 s, and carries on if the source comes back to the stream's mode or drops the signal within that time. It ends the stream only when the other mode lasts the whole second.
- By hand: in the source's properties, change *Color Range* and change it back.
- Through obs-websocket: send `SetInputSettings` with `inputName` set to the V4L2 source and `inputSettings` set to `{"color_range": 1}`. Next time, send `{"color_range": 0}`. For the YUV formats both values mean limited range, so the picture stays the same. Setting the value the source already has does nothing.

While OBS records, the reopen works only with *Hybrid MP4* (tested; OBS 32's default) or *Hybrid MOV*, which OBS writes itself. The other formats (MKV, MP4, MOV, ...) run OBS's `obs-ffmpeg-mux` helper. The helper inherits OBS's open handle on the device, so the device stays busy and the reopen fails until the recording stops. OBS sets up its recording output when it starts and when the output settings change in its Settings window. A format set through obs-websocket (`SetProfileParameter`) takes effect only at the next start.

**Driving OBS from a program (obs-websocket)**
- Expect OBS to die now and then, and start it again. On the test PC, 1 of 10 OBS starts crashed 0.2 s in, inside the NVIDIA driver's OpenGL library, before OBS had loaded any source.
  - Watch OBS's process, and start OBS again when it exits.
  - Start OBS with `--multi`. OBS 32 then neither writes nor reads its crash markers. Without it, a start after a crash waits on an *unclean shutdown* dialog until someone clicks it.
  - The test harness's `tests/obs-run.sh` starts OBS with `--multi`, and starts it once more when it crashes at start.
- Set `"buffering": false` on the V4L2 source (see *Video*).
- `GetSourceScreenshot` of the V4L2 source:
  - PNG at 1920x1080 takes 55–70 ms per request and comes within 2 codes of the source's picture.
  - PNG at 960x540 takes about 18 ms.
  - JPG is lossy (errors of about 25 codes). Use PNG to compare pictures.
- `InputVolumeMeters` events (subscribe with `1 << 16`) arrive every 50 ms with the levels of OBS's last audio tick. A sound shorter than that, such as a one-frame beep, shows in only about half of the events.
- Decide when to reopen the source (above) from the card's input, not from the picture. A black or still picture, such as a screen saver, looks the same as a source that has stopped. The test harness does this with `tests/obsbridge.py`, which you can run as it is: `python3 tests/obsbridge.py --source 'GC573 video'` (`--help` for the rest). What it does:
  - It opens the video device a second time, never streams on it, and subscribes to `V4L2_EVENT_SOURCE_CHANGE`. This handle never requests buffers, so it does not keep the device busy and OBS can still reopen it.
  - After each event it waits until the input has been still for 2 s, longer than the driver's 1 s hold. It then compares the input (`VIDIOC_QUERY_DV_TIMINGS`) with what the stream runs at (`VIDIOC_G_DV_TIMINGS` on the same handle, which reports the stream's timings while OBS streams).
  - It reopens OBS's source only when the timings differ (in practice, a new resolution), or when the input sat in other timings for about a second since the last check, so the driver ended the stream even if the source came back. Nothing else needs a reopen: the driver carries the stream through the other changes in the table.
  - It checks the reopen: `VIDIOC_G_DV_TIMINGS` takes the new timings when OBS closes the device. If that does not happen within 3 s, it reopens again after 2, 4, 8 ... s. It logs every step.
- Keep a check on the picture as the fallback, and keep watching between your own actions. The test harness uses this pattern (`tests/obs-events.py`):
  - A screenshot every 2 s. A good one shows a new frame: the picture moved since the last one. A frozen picture can look perfect in a single screenshot, so compare two.
  - Watchdog: no new frame for more than 10 s while the card has a signal (and no reopen by the bridge in that time): reopen the source. If the picture still does not move, reopen again after 10, 20 and 40 s, then every 60 s, until it does. Log each attempt. `v4l2-ctl -d /dev/v4l/by-path/pci-<address>-video-index0 --query-dv-timings` succeeds when the card has a signal, and it works while OBS streams.
  - Before each action on the source, check the picture. If it is not moving while the card has a signal, reopen first, then carry on with the action.
  - Never stop driving the source because the picture is bad. In the first 2-hour host soak, the harness skipped its source changes while OBS's source was stopped. The input then never changed again, and the recording stayed black for its last 48 minutes.
  - Check a recording by its motion over time, not by stills.
- When no frame arrives for 5 frame periods, which happens during a source change, OBS logs `select timed out` and asks the driver to log its status (`VIDIOC_LOG_STATUS`). That adds about 70 lines to the kernel log per change.

## Use with other applications

The card is a plain V4L2 video device and ALSA sound card, so applications need no special support. ffmpeg and VLC were tested on the host (Linux Mint 22) and GStreamer in the test virtual machine with the card (Ubuntu 24.04), each by recording the card's picture and sound into a file with a test pattern on the input. Each file was checked for the picture, every frame (from a counter in the picture), the sound's channels and rate, and the A/V offset against the driver's own.

| Application | Picture and sound | Signal lost and back, EDID set again | 60 ↔ 59.94 Hz | Another resolution |
|---|---|---|---|---|
| ffmpeg 6.1 | Every frame, the right picture and sound. A/V within 1 ms of the driver's | Carries on | Carries on | Stops taking frames, without an error: start it again |
| VLC 3.0 | The right picture and sound. A/V 14 ms later than the driver's. Recording 1080p60 with lossless x264, it lost up to 36 of 1490 frames after taking them from the driver. The driver delivered them all, and VLC always had a buffer queued | Carries on | Carries on | Stops taking frames: start it again |
| GStreamer 1.24 | Every frame, the right picture and sound. A/V within 10 ms of the driver's. Its file's timestamps follow the audio clock, in 10 ms steps | Carries on | A Matroska recording ends: start it again, or record with fixed caps (below) | As at 60 ↔ 59.94 Hz |

ffmpeg and VLC do not listen to the driver's source-change event. At another resolution or frame rate (60 ↔ 59.94 Hz aside), the driver ends their stream, because the format must not change under an application that is streaming (see *When the source changes* under *Use with OBS*). Start the application again.

GStreamer's `v4l2src` does listen: at each change it stops, sets its format again and starts again. After a loss of the signal, a relock or an EDID change it gets the format it had, because the driver keeps the colour format of the last input that locked, and the recording goes on. A new frame rate or resolution changes its caps, and Matroska (`matroskamux`) takes no caps change ("Caps changes are not supported by Matroska"), so the recording ends there. To keep one recording through such changes, convert to fixed caps before the encoder:

```
gst-launch-1.0 -e v4l2src device=/dev/v4l/by-path/pci-<address>-video-index0 ! videorate ! videoscale ! videoconvert ! video/x-raw,format=I420,width=1920,height=1080,framerate=60/1 ! <encoder> ! queue ! mux. alsasrc device=hw:CARD=/dev/snd/by-path/pci-<address>,DEV=0 ! audioconvert ! queue ! mux. matroskamux name=mux ! filesink location=capture.mkv
```

`videorate`, `videoscale` and `videoconvert` take the source's changes, so the encoder and the muxer always see the same caps. This was tested with `jpegenc` at 1280x720 and 30 frames/s, through 60 → 59.94 Hz → 720p → 1080p60: one recording, one video stream throughout.

Name the devices explicitly. Then nothing else is opened, and the names stay put (see *Device names that stay put* under *Use with OBS*):
- ffmpeg: `ffmpeg -f v4l2 -ts mono2abs -input_format yuyv422 -video_size 1920x1080 -framerate 60 -i /dev/v4l/by-path/pci-<address>-video-index0 -f alsa -channels 2 -sample_rate 48000 -i hw:CARD=/dev/snd/by-path/pci-<address>,DEV=0 ...`. With `-ts mono2abs` the picture and the sound share a clock.
- GStreamer: `v4l2src device=/dev/v4l/by-path/pci-<address>-video-index0` and `alsasrc device=hw:CARD=/dev/snd/by-path/pci-<address>,DEV=0`. Even so, its v4l2 plugin opens every video device when it loads (cameras too), to see what each one is.
- VLC: `cvlc "v4l2:///dev/videoN" --v4l2-dev=/dev/videoN --v4l2-chroma=YUYV --v4l2-width=1920 --v4l2-height=1080 --v4l2-fps=60 --input-slave="alsa://hw:CARD=/dev/snd/by-path/pci-<address>,DEV=0" --sout ...`.
  - Use the `/dev/videoN` node that the by-path name points to (`readlink -f /dev/v4l/by-path/pci-<address>-video-index0`). VLC takes everything after `v4l2://` up to the first `:` as the device, and the by-path name has colons in it.
  - If nothing comes before that `:`, VLC opens its default device, `/dev/video0`, which may be another camera.

## Known limitations

- Video:
  - Up to 1080p60. No 4K, no HDR, no scaling: you capture at the input's size.
  - Inputs below 59.5 Hz (50, 30, 25 and 24 Hz) are delivered at 60 frames/s, with frames repeated.
  - The RGB formats (24-bit BGR, 32-bit BGRX) are exact only for a full-range RGB input, which is what a PC sends. A limited-range RGB input stays limited range in them, so it looks washed out in OBS. With a YCbCr input, which most consoles send, they are off by up to 4 codes. The YUV formats are right with every input tested.
- Audio: LPCM stereo at 48 kHz only. When the signal drops, the gap is filled with silence.
- OBS does not follow a change of resolution or frame rate by itself: reopen the source (see *When the source changes*).
- Unloading or reloading the driver does not look like an unplug to the source: the test PC (NVIDIA GPU) kept its output on and the card's EDID in use.
- The driver reports a lock only once the card's own measurement of the input is valid. Once, at a boot, that measurement did not start while the source came up, and the card showed no signal although the source was on. The cause is open (`spec/open-questions.md`, question 40). The driver now tries to fix this by itself, and the kernel log (`sudo dmesg | grep HDMI`) shows each step:
  - after about 2 s: `the FPGA has no valid measurement`;
  - at about 5 s: `self-heal 1 of 3, receiver restart`, which the source does not see;
  - 20 s later: `self-heal 2 of 3, hot-plug`, and 80 s after that `self-heal 3 of 3, hot-plug`. Each hot-plug looks to the source like an unplug and a replug, as when the EDID changes;
  - if the card still has no measurement: `self-heal gave up`. The driver tries again only after a lock or after the source's 5 V goes away (unplug, source off).

  A source whose signal the card cannot measure gets the same restart and two hot-plugs each time it is plugged in. That may be the case for an interlaced or deep-colour signal or 4K, which the driver does not support yet. To turn the self-heal off until the next load: `echo N | sudo tee /sys/module/gc573/parameters/fpga_heal`. For good: `options gc573 fpga_heal=0` in a file in `/etc/modprobe.d/`. By hand, set the source's mode again or unplug and replug the HDMI cable.
- Any program that may open the video device (the `video` group, or the desktop user through the seat's access list) can set the EDID that the card shows the source (`VIDIOC_S_EDID`, `v4l2-ctl --set-edid`), as with the kernel's own HDMI receiver drivers. Each change looks to the source like an unplug and a replug, and the source then reads the new EDID. In the PC loopback (a GPU output cabled to the card), that is the host's own GPU driver reading an EDID that any such program chose.
- Module parameters named `exp_*` are experiments and tests for development (`exp_slot_mode`, `exp_rate_fps`, `exp_rate_bits`, `exp_stop_domains`, `exp_stop_fault`, `exp_mmio_ones`, `exp_audio_raw`, `exp_audio_fill`, `exp_fpga_invalid`, `exp_intx`). Only root can set them, and several turn off the driver's safety checks. Leave them at their defaults.
  - `exp_stop_fault` makes the driver count a DMA stop as failed once the card has confirmed it, so the card is unusable until reboot (below). It is for tests only.
  - `exp_stop_domains` changes which parts of the card a stop resets. It is for tests only and can corrupt memory.
  - `exp_mmio_ones` makes the card look as if it does not answer.
  - Setting any of these three taints the kernel.
- If the card does not confirm that its DMA stopped, the driver leaves the card as it is until the next reboot. Turning a card's bus mastering off while its DMA may still run can hang the whole computer (it did, twice, in tests), so the driver leaves bus mastering on and keeps all the memory it gave the card. The kernel log says `... the card keeps bus mastering and gets no driver until reboot; reboot before using the card again` and `... KiB of DMA memory kept until reboot`. Until the reboot:
  - the card has no driver: gc573 refuses it, and no other driver (vfio-pci either) can take it;
  - the gc573 module cannot be unloaded, and `/sys/module/gc573/parameters/dead_cards` lists the card;
  - system sleep (suspend, hibernate) is refused.

  A normal reboot of the computer is safe: the kernel does not turn bus mastering off for a plain reboot, and the platform's reset then resets the card.
- Not handled: kexec (as kdump or a fast reboot uses) and a write to the card's sysfs `enable` file can still turn bus mastering off on such a card. Do neither before the reboot.
- In a virtual machine, such a card cannot be let go safely: a reboot of the guest (QEMU resets the card) and its shutdown (vfio-pci releases the card) both turn bus mastering off. Expect the host to need a power cycle.
- Shut a virtual machine that uses the card down normally while it captures, never kill it (`virsh destroy`): at a shutdown the driver stops the card's DMA first. A crashed or killed VM can hang the host, because vfio-pci then turns bus mastering off under the running DMA.
- System sleep (suspend, hibernate) is refused while the card captures: the kernel would turn its bus mastering off under the running DMA. Suspend and resume are not supported yet (M9): after a sleep taken while the card was idle, rebind the driver or reboot before you use the card again.
- HDCP-protected sources (consoles, streaming boxes) are untested.
- Tested in a virtual machine with the card passed through, and on a real host (Linux Mint 22, kernel 6.8): a 2-hour OBS recording with a source change every 3 minutes, and frame-exact captures at 1080p60, 1080p59.94 and 720p59.94.

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
