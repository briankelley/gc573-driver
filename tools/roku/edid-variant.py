#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Variants of a 2-block EDID (VESA E-EDID 1.3 base block plus a CTA-861
extension) for the source mode-change tests (tests/live.sh rokumodes):
  --serial N     the base block's serial number (bytes 12-15) set to N: the
                 same modes, but a source sees a different display and sets
                 its mode again after the hot-plug
  --only-720p    1280x720 only: the base block's first detailed timing
                 becomes CTA-861 VIC 4 (720p60, 74.25 MHz) and the CTA video
                 data block lists VICs 4 and 19 (720p50); every other data
                 block is kept. A source in automatic mode then sets 720p
Both checksums are recomputed.
Usage: tools/roku/edid-variant.py IN OUT (--serial N | --only-720p)
"""
import argparse
import sys

# CTA-861 VIC 4: 74.25 MHz; 1280 + 370 blanking (front 110, sync 40);
# 720 + 30 (front 5, sync 5); the image size bytes are the input's
DTD_720P60 = [0x01, 0x1d, 0x00, 0x72, 0x51, 0xd0, 0x1e, 0x20, 0x6e, 0x28, 0x55, 0x00]


def checksum(block):
    block[127] = -sum(block[:127]) & 0xff


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('inp')
    ap.add_argument('out')
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument('--serial', type=lambda v: int(v, 0))
    g.add_argument('--only-720p', action='store_true')
    a = ap.parse_args()
    d = bytearray(open(a.inp, 'rb').read())
    if len(d) != 256 or d[:8] != b'\x00\xff\xff\xff\xff\xff\xff\x00' or d[128] != 2:
        sys.exit('edid-variant: not a base block with one CTA-861 extension')
    if a.serial is not None:
        d[12:16] = a.serial.to_bytes(4, 'little')
    else:
        d[54:66] = bytes(DTD_720P60)        # flags, size and borders kept
        cta = d[128:256]
        off = cta[2]
        blocks, i = [], 4
        while i < off:
            tag, n = cta[i] >> 5, cta[i] & 0x1f
            blocks.append(bytes(cta[i:i + 1 + n]) if tag != 2 else bytes([0x42, 4, 19]))
            i += 1 + n
        body = b''.join(blocks)
        new = bytearray(128)
        new[0:4] = bytes([2, cta[1], 4 + len(body), cta[3]])
        new[4:4 + len(body)] = body
        d[128:256] = new
    checksum(memoryview(d)[0:128])
    blk = bytearray(d[128:256])
    checksum(blk)
    d[128:256] = blk
    open(a.out, 'wb').write(d)
    return 0


if __name__ == '__main__':
    sys.exit(main())
