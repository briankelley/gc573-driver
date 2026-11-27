#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Is a raw frame (gc573-cap -o) one value throughout?

usage: frame-uniform.py FILE

Prints "uniform words=N distinct=D top=HEX:COUNT,..." over the frame's
32-bit words (a YUYV pixel pair each; free-running black is one word
repeated). Exit 0 if every word is the same, 1 if not, 2 on error.
"""
import collections
import sys


def main():
    if len(sys.argv) != 2:
        print(__doc__.strip().split('\n\n')[1], file=sys.stderr)
        return 2
    data = open(sys.argv[1], 'rb').read()
    if not data or len(data) % 4:
        print(f'uniform error: {len(data)} bytes')
        return 2
    words = collections.Counter(data[i:i + 4] for i in range(0, len(data), 4))
    top = ','.join(f'{w.hex()}:{n}' for w, n in words.most_common(4))
    print(f'uniform words={len(data) // 4} distinct={len(words)} top={top}')
    return 0 if len(words) == 1 else 1


if __name__ == '__main__':
    sys.exit(main())
