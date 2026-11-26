#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# tools/testsrc/scrub.py and scrub.sh on made-up device names (no real
# serial): the serial in every usb-<vendor>_<model>_<serial>-<suffix> name
# becomes <serial>; PCI names (the GC573's, the NVIDIA HDMI sink's) and
# path-based USB names stay as they are; scrubbing twice changes nothing.
# The Python filter (guard.py, obs-events.py) and the bash function (the
# shell writers) must agree. Host or VM, no device touched.
# Usage: tests/scrub-check.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tools/testsrc/scrub.sh
. "$ROOT/tools/testsrc/scrub.sh"
pass=0 fail=0
res() {
	echo "RESULT $1 $2 ($3)"
	if [ "$2" = PASS ]; then pass=$((pass + 1)); else fail=$((fail + 1)); fi
}
# input|expected
cases=(
	'alsa_output.usb-Acme_Fake_Speaker_A1B2C3D4E5-00.analog-stereo|alsa_output.usb-Acme_Fake_Speaker_<serial>-00.analog-stereo'
	'alsa_input.usb-046d_Fake_Webcam_C999_0123ABCD-02.analog-stereo|alsa_input.usb-046d_Fake_Webcam_C999_<serial>-02.analog-stereo'
	'/dev/v4l/by-id/usb-046d_Fake_Webcam_C999_0123ABCD-video-index0|/dev/v4l/by-id/usb-046d_Fake_Webcam_C999_<serial>-video-index0'
	'/dev/snd/by-id/usb-Acme_Fake_Speaker_A1B2C3D4E5-00|/dev/snd/by-id/usb-Acme_Fake_Speaker_<serial>-00'
	'usb-Acme_USB-Audio_ZZ9-01|usb-Acme_USB-Audio_<serial>-01'
	'link alsa_output.usb-A_B_S1-00.analog-stereo:playback_FL <- alsa_input.usb-C_D_S2-02.analog-stereo:capture_FR|link alsa_output.usb-A_B_<serial>-00.analog-stereo:playback_FL <- alsa_input.usb-C_D_<serial>-02.analog-stereo:capture_FR'
	'pactl set-default-sink alsa_output.usb-Acme_Fake_Speaker_A1B2C3D4E5-00.analog-stereo;1 pactl x|pactl set-default-sink alsa_output.usb-Acme_Fake_Speaker_<serial>-00.analog-stereo;1 pactl x'
	'v4l2_input.pci-0000_00_14.0-usb-0_9_1.0|v4l2_input.pci-0000_00_14.0-usb-0_9_1.0'
	'/dev/v4l/by-path/pci-0000:00:14.0-usb-0:9:1.0-video-index0|/dev/v4l/by-path/pci-0000:00:14.0-usb-0:9:1.0-video-index0'
	'alsa_input.pci-0000_07_00.0.stereo-fallback|alsa_input.pci-0000_07_00.0.stereo-fallback'
	'alsa_output.pci-0000_01_00.1.hdmi-stereo|alsa_output.pci-0000_01_00.1.hdmi-stereo'
	'no device name here|no device name here'
)
n=0
for c in "${cases[@]}"; do
	n=$((n + 1))
	in=${c%%|*} want=${c#*|}
	py=$(printf '%s\n' "$in" | python3 "$ROOT/tools/testsrc/scrub.py")
	sh=$(gc573_scrub "$in")
	again=$(gc573_scrub "$sh")
	if [ "$py" = "$want" ] && [ "$sh" = "$want" ] && [ "$again" = "$want" ]; then
		res "scrub-$n" PASS "$want"
	else
		res "scrub-$n" FAIL "in '$in': python '$py', bash '$sh', again '$again', want '$want'"
	fi
done
echo "SUMMARY pass=$pass fail=$fail"
[ "$fail" = 0 ]
