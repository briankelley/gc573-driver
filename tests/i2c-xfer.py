#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""One register-addressed I2C transfer through i2c-dev (I2C_RDWR).

usage: i2c-xfer.py DEV read ADDR REG [N]
       i2c-xfer.py DEV write ADDR REG BYTE...

read: write [REG], then read N bytes (default 1) from the 7-bit address
ADDR; write: one message [REG, BYTE...]. Numbers in any Python base
(0x..). Prints "read ADDR REG: XX XX ..." or "write ADDR REG: ok", or the
same with "errno=NAME" on failure; exit 0 on success, 1 on failure.
"""
import ctypes
import errno
import fcntl
import os
import sys

I2C_RDWR = 0x0707
I2C_M_RD = 0x0001


class I2cMsg(ctypes.Structure):
    _fields_ = [("addr", ctypes.c_uint16), ("flags", ctypes.c_uint16),
                ("len", ctypes.c_uint16), ("buf", ctypes.POINTER(ctypes.c_uint8))]


class I2cRdwr(ctypes.Structure):
    _fields_ = [("msgs", ctypes.POINTER(I2cMsg)), ("nmsgs", ctypes.c_uint32)]


def rdwr(fd, msgs):
    arr = (I2cMsg * len(msgs))(*msgs)
    fcntl.ioctl(fd, I2C_RDWR, I2cRdwr(arr, len(msgs)))


def main():
    if len(sys.argv) < 5 or sys.argv[2] not in ('read', 'write'):
        print(__doc__.strip().split('\n\n')[1], file=sys.stderr)
        return 2
    dev, op = sys.argv[1], sys.argv[2]
    addr, reg = int(sys.argv[3], 0), int(sys.argv[4], 0)
    rest = [int(v, 0) for v in sys.argv[5:]]
    what = f'{op} {addr:#04x} {reg:#04x}'
    fd = os.open(dev, os.O_RDWR)
    try:
        if op == 'read':
            n = rest[0] if rest else 1
            wbuf = (ctypes.c_uint8 * 1)(reg)
            rbuf = (ctypes.c_uint8 * n)()
            rdwr(fd, [I2cMsg(addr, 0, 1, wbuf), I2cMsg(addr, I2C_M_RD, n, rbuf)])
            print(f'{what}: {bytes(rbuf).hex(" ")}')
        else:
            data = bytes([reg] + rest)
            wbuf = (ctypes.c_uint8 * len(data))(*data)
            rdwr(fd, [I2cMsg(addr, 0, len(data), wbuf)])
            print(f'{what}: ok')
    except OSError as e:
        print(f'{what}: errno={errno.errorcode.get(e.errno, e.errno)}')
        return 1
    finally:
        os.close(fd)
    return 0


if __name__ == '__main__':
    sys.exit(main())
