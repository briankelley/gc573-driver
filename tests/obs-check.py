#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""OBS checks for the GC573 (M5), driven through obs-websocket (tests/obsws.py).
Run in the VM, as the desktop user, with OBS running (tests/live.sh starts it).

  obs-check.py setup VIDEODEV PCM
      1920x1080 at 60 fps canvas and output; no Desktop Audio or Mic/Aux; a
      V4L2 source "GC573 video" (VIDEODEV, YUYV) and an ALSA source "GC573
      audio" (PCM, 48 kHz) in the current scene; simple-mode recording to
      ~/obs-rec, MKV, x264 (ultrafast, 6 Mb/s) and AAC 160 kb/s. Prints the
      formats, resolutions and frame rates OBS offers. OBS's recording
      muxer (obs-ffmpeg-mux) is a child process that inherits OBS's file
      descriptors, the V4L2 device's too (OBS opens it without O_CLOEXEC):
      while it records, the device stays open after OBS closes it, so OBS
      cannot set the device up again (S_FMT: EBUSY)
  obs-check.py formats PATTERN_PNG
      every pixel format OBS offers for the device in turn: a screenshot of
      the source (GetSourceScreenshot, 1920x1080 PNG) against the pattern
      (tools/testsrc/pattern.py), inside each flat region of the pattern 6
      pixels away from its edges and below the 8-pixel corner markers: max
      and mean |error| per channel. One RESULT line per format; PASS within
      6 codes (YUV formats are 4:2:2 or 4:2:0 and limited range, converted
      back by OBS), 2 for RGB formats. The source is left at YUYV.
  obs-check.py record SECS
      record SECS seconds; prints the file (RECORDING) and OBS's frame
      statistics over the recording (STATS)
  obs-check.py start | stop
      the same in two steps, for host actions in between
  obs-check.py shots SECS [EVERY]
      a screenshot every EVERY seconds (default 0.5) for SECS: prints the
      mean luma of each and whether it changed (is the source live?)
  obs-check.py set KEY=VALUE...
      SetInputSettings on the video source (integers as numbers)
  obs-check.py pattern W H PATTERN_PNG
      the source at its own size (GetSourceScreenshot) must be WxH and
      match the pattern as in "formats" (YUYV limit): one RESULT line
  obs-check.py reopen
      make OBS set its V4L2 source up again, as a user would: Color Range
      to another value and back (OBS reopens the device on a change of
      device, input, video format, standard, DV timing, resolution, frame
      rate or colour range)
"""
import base64
import io
import json
import os
import struct
import sys
import time

from obsws import OBS

VSRC, ASRC = 'GC573 video', 'GC573 audio'
YUYV = 0x56595559


def items(obs, name, prop):
    return obs.call('GetInputPropertiesListPropertyItems', inputName=name,
                    propertyName=prop)['propertyItems']


def scene(obs):
    return obs.call('GetCurrentProgramScene')['currentProgramSceneName']


def setup(obs, vdev, pcm):
    names = {i['inputName'] for i in obs.call('GetInputList')['inputs']}
    for n in ('Desktop Audio', 'Mic/Aux'):
        if n in names:
            obs.call('RemoveInput', inputName=n)
    obs.call('SetVideoSettings', baseWidth=1920, baseHeight=1080,
             outputWidth=1920, outputHeight=1080, fpsNumerator=60, fpsDenominator=1)
    for cat, key, val in (('Output', 'Mode', 'Simple'),
                          ('SimpleOutput', 'RecFormat2', 'mkv'),
                          ('SimpleOutput', 'RecQuality', 'Stream'),
                          ('SimpleOutput', 'StreamEncoder', 'x264'),
                          ('SimpleOutput', 'RecEncoder', 'x264'),
                          ('SimpleOutput', 'Preset', 'ultrafast'),
                          ('SimpleOutput', 'VBitrate', '6000'),
                          ('SimpleOutput', 'ABitrate', '160'),
                          ('Audio', 'SampleRate', '48000')):
        obs.call('SetProfileParameter', parameterCategory=cat, parameterName=key,
                 parameterValue=val)
    rec = os.path.expanduser('~/obs-rec')
    os.makedirs(rec, exist_ok=True)
    obs.call('SetRecordDirectory', recordDirectory=rec)
    sc = scene(obs)
    if VSRC not in names:
        obs.call('CreateInput', sceneName=sc, inputName=VSRC, inputKind='v4l2_input',
                 inputSettings={}, sceneItemEnabled=True)
    devs = items(obs, VSRC, 'device_id')
    dev = next((d['itemValue'] for d in devs if os.path.realpath(d['itemValue']) ==
                os.path.realpath(vdev)), None)
    if dev is None:
        sys.exit(f'OBS does not list {vdev}: {devs}')
    # YUYV: native (an "(Emulated)" format is libv4l2 converting on the
    # CPU). Buffering on is OBS's default; a scene collection keeps what an
    # earlier run set
    obs.call('SetInputSettings', inputName=VSRC,
             inputSettings={'device_id': dev, 'pixelformat': YUYV, 'buffering': True})
    if ASRC not in names:
        obs.call('CreateInput', sceneName=sc, inputName=ASRC, inputKind='alsa_input_capture',
                 inputSettings={}, sceneItemEnabled=True)
    adevs = items(obs, ASRC, 'device_id')
    adev = next((d['itemValue'] for d in adevs if d['itemValue'] == pcm), None)
    if adev is None:
        adev = '__custom__'
    obs.call('SetInputSettings', inputName=ASRC,
             inputSettings={'device_id': adev, 'custom_pcm': pcm, 'rate': 48000})
    # the video source fills the canvas
    sid = obs.call('GetSceneItemId', sceneName=sc, sourceName=VSRC)['sceneItemId']
    obs.call('SetSceneItemTransform', sceneName=sc, sceneItemId=sid,
             sceneItemTransform={'positionX': 0, 'positionY': 0, 'boundsType': 'OBS_BOUNDS_STRETCH',
                                 'boundsWidth': 1920, 'boundsHeight': 1080})
    time.sleep(2)
    print('OBS', obs.call('GetVersion')['obsVersion'])
    print('video device', dev, '| audio device', adev, pcm)
    for prop in ('pixelformat', 'resolution', 'framerate'):
        print(f'{prop}:', ', '.join(f"{i['itemName']}={i['itemValue']}" for i in items(obs, VSRC, prop)))
    print('settings', json.dumps(obs.call('GetInputSettings', inputName=VSRC)['inputSettings']))


def shot(obs, w=1920, h=1080):
    from PIL import Image
    d = obs.call('GetSourceScreenshot', sourceName=VSRC, imageFormat='png',
                 imageWidth=w, imageHeight=h)['imageData']
    return Image.open(io.BytesIO(base64.b64decode(d.split(',', 1)[1]))).convert('RGB')


def regions(W, H, m=6):
    """Flat regions of tools/testsrc/pattern.py, m pixels inside their edges
    (the colour bars start below the 8-pixel corner markers)"""
    h1, h2, h3 = H * 4 // 10, H * 6 // 10, H * 8 // 10
    out = []
    for i in range(8):
        out.append((i * W // 8 + m, 8 + m, (i + 1) * W // 8 - m, h1 - m))
    for i in range(16):
        out.append((i * W // 16 + m, h1 + m, (i + 1) * W // 16 - m, h2 - m))
    for i in range(8):
        out.append((i * W // 8 + m, h2 + m, (i + 1) * W // 8 - m, h3 - m))
    return out


def compare(img, ref):
    import numpy as np
    a = np.asarray(img, dtype=np.int16)
    b = np.asarray(ref, dtype=np.int16)
    errs = []
    for x0, y0, x1, y1 in regions(ref.width, ref.height):
        errs.append(np.abs(a[y0:y1, x0:x1] - b[y0:y1, x0:x1]).reshape(-1, 3))
    e = np.concatenate(errs)
    return e.max(axis=0), e.mean(axis=0)


def formats(obs, pattern):
    from PIL import Image
    ref = Image.open(pattern).convert('RGB')
    ok = True
    for it in items(obs, VSRC, 'pixelformat'):
        name, val = it['itemName'], it['itemValue']
        obs.call('SetInputSettings', inputName=VSRC, inputSettings={'pixelformat': val})
        time.sleep(3)
        img = shot(obs)
        mx, mean = compare(img, ref)
        cc = struct.pack('<I', val).decode(errors='replace')
        lim = 2 if cc in ('BGR3', 'XR24', 'RGB3', 'XB24') else 6
        good = int(mx.max()) <= lim
        ok &= good
        print(f"RESULT format-{cc} {'PASS' if good else 'FAIL'} "
              f"({name}: max |error| R/G/B {mx[0]}/{mx[1]}/{mx[2]}, mean "
              f"{mean[0]:.2f}/{mean[1]:.2f}/{mean[2]:.2f}, limit {lim})")
        img.save(f'/tmp/obs-shot-{val}.png')
    obs.call('SetInputSettings', inputName=VSRC, inputSettings={'pixelformat': YUYV})
    return ok


def pattern(obs, w, h, png):
    from PIL import Image
    d = obs.call('GetSourceScreenshot', sourceName=VSRC, imageFormat='png')['imageData']
    img = Image.open(io.BytesIO(base64.b64decode(d.split(',', 1)[1]))).convert('RGB')
    if img.size != (w, h):
        print(f'RESULT pattern-{w}x{h} FAIL (the source is {img.width}x{img.height})')
        return False
    mx, mean = compare(img, Image.open(png).convert('RGB'))
    good = int(mx.max()) <= 6
    print(f"RESULT pattern-{w}x{h} {'PASS' if good else 'FAIL'} (source {w}x{h}: max "
          f"|error| R/G/B {mx[0]}/{mx[1]}/{mx[2]}, mean {mean[0]:.2f}/{mean[1]:.2f}/"
          f"{mean[2]:.2f}, limit 6)")
    return good


STATS_FILE = '/tmp/obs-check-stats.json'


def start(obs):
    if obs.call('GetRecordStatus')['outputActive']:
        obs.call('StopRecord')
        time.sleep(2)
    with open(STATS_FILE, 'w') as f:
        json.dump(obs.call('GetStats'), f)
    obs.call('StartRecord')
    for _ in range(50):
        if obs.call('GetRecordStatus')['outputActive']:
            print('STARTED')
            return
        time.sleep(0.1)
    sys.exit('the recording did not start')


def stop(obs):
    with open(STATS_FILE) as f:
        s0 = json.load(f)
    path = obs.call('StopRecord')['outputPath']
    s1 = obs.call('GetStats')
    d = {k: s1[k] - s0[k] for k in ('renderSkippedFrames', 'renderTotalFrames',
                                    'outputSkippedFrames', 'outputTotalFrames')}
    print('RECORDING', path)
    print('STATS', json.dumps(d), 'cpu', f"{s1['cpuUsage']:.1f}%", 'fps', f"{s1['activeFps']:.2f}")


def shots(obs, secs, every):
    import numpy as np
    prev = None
    t0 = time.monotonic()
    while time.monotonic() - t0 < secs:
        a = np.asarray(shot(obs, 192, 108), dtype=np.int16)
        y = float(a.mean())
        ch = 'first' if prev is None else ('changed' if np.abs(a - prev).max() > 8 else 'same')
        print(f'SHOT t={time.monotonic() - t0:.2f} luma={y:.1f} {ch}', flush=True)
        prev = a
        time.sleep(every)


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    obs = OBS()
    cmd = sys.argv[1]
    if cmd == 'setup':
        setup(obs, sys.argv[2], sys.argv[3])
    elif cmd == 'formats':
        sys.exit(0 if formats(obs, sys.argv[2]) else 1)
    elif cmd == 'record':
        start(obs)
        time.sleep(float(sys.argv[2]))
        stop(obs)
    elif cmd == 'start':
        start(obs)
    elif cmd == 'stop':
        stop(obs)
    elif cmd == 'shots':
        shots(obs, float(sys.argv[2]), float(sys.argv[3]) if len(sys.argv) > 3 else 0.5)
    elif cmd == 'pattern':
        sys.exit(0 if pattern(obs, int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]) else 1)
    elif cmd == 'reopen':
        cr = obs.call('GetInputSettings', inputName=VSRC)['inputSettings'].get('color_range', 0)
        obs.call('SetInputSettings', inputName=VSRC, inputSettings={'color_range': 1 if cr != 1 else 2})
        time.sleep(1)
        obs.call('SetInputSettings', inputName=VSRC, inputSettings={'color_range': cr})
    elif cmd == 'set':
        kv = dict(a.split('=', 1) for a in sys.argv[2:])
        kv = {k: (int(v) if v.lstrip('-').isdigit() else v) for k, v in kv.items()}
        obs.call('SetInputSettings', inputName=VSRC, inputSettings=kv)
    else:
        sys.exit(__doc__)
    obs.close()


if __name__ == '__main__':
    main()
