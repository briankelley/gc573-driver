#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Read-only I2C reads of the GC573 HDMI chip IDs through i2c-dev.

usage: i2c-id-reads.py DEV COUNT
       i2c-id-reads.py DEV --plain-read

COUNT rounds, each: IT6805 (0x48) registers 0x00-0x03 one byte per I2C_RDWR
transfer, splitter (0x2c) registers 0x00 and 0x02 two bytes per transfer, and
IT6805 registers 0x00-0x03 as SMBus read-byte-data (emulated by the I2C core).
Every byte is checked against spec/i2c.md. Prints a summary; exit 1 on any
error or mismatch.

--plain-read sends one read message with no register write, a shape the bus-1
engine cannot do: the driver must refuse it with EOPNOTSUPP before touching
the hardware. Exit 0 if refused that way.
"""
import ctypes
import errno
import fcntl
import os
import sys

I2C_SLAVE = 0x0703
I2C_RDWR = 0x0707
I2C_SMBUS = 0x0720
I2C_M_RD = 0x0001
I2C_SMBUS_READ = 1
I2C_SMBUS_BYTE_DATA = 2

IT6805, SPLITTER = 0x48, 0x2C
IDS = {IT6805: bytes([0x54, 0x49, 0x05, 0x68]), SPLITTER: bytes([0x54, 0x49, 0x63, 0x66])}


class I2cMsg(ctypes.Structure):
    _fields_ = [("addr", ctypes.c_uint16), ("flags", ctypes.c_uint16),
                ("len", ctypes.c_uint16), ("buf", ctypes.POINTER(ctypes.c_uint8))]


class I2cRdwr(ctypes.Structure):
    _fields_ = [("msgs", ctypes.POINTER(I2cMsg)), ("nmsgs", ctypes.c_uint32)]


class I2cSmbusData(ctypes.Union):
    _fields_ = [("byte", ctypes.c_uint8), ("word", ctypes.c_uint16),
                ("block", ctypes.c_uint8 * 34)]


class I2cSmbusIoctl(ctypes.Structure):
    _fields_ = [("read_write", ctypes.c_uint8), ("command", ctypes.c_uint8),
                ("size", ctypes.c_uint32), ("data", ctypes.POINTER(I2cSmbusData))]


def rdwr(fd, msgs):
    arr = (I2cMsg * len(msgs))(*msgs)
    fcntl.ioctl(fd, I2C_RDWR, I2cRdwr(arr, len(msgs)))


def reg_read(fd, addr, reg, n):
    wbuf = (ctypes.c_uint8 * 1)(reg)
    rbuf = (ctypes.c_uint8 * n)()
    rdwr(fd, [I2cMsg(addr, 0, 1, wbuf), I2cMsg(addr, I2C_M_RD, n, rbuf)])
    return bytes(rbuf)


def smbus_read_byte(fd, addr, reg):
    fcntl.ioctl(fd, I2C_SLAVE, addr)
    data = I2cSmbusData()
    fcntl.ioctl(fd, I2C_SMBUS, I2cSmbusIoctl(I2C_SMBUS_READ, reg, I2C_SMBUS_BYTE_DATA,
                                             ctypes.pointer(data)))
    return data.byte


def rounds(fd, count):
    xfers = bad = 0
    for _ in range(count):
        got = {
            "rdwr 1-byte 0x48": bytes(reg_read(fd, IT6805, r, 1)[0] for r in range(4)),
            "rdwr 2-byte 0x2c": reg_read(fd, SPLITTER, 0, 2) + reg_read(fd, SPLITTER, 2, 2),
            "smbus byte 0x48": bytes(smbus_read_byte(fd, IT6805, r) for r in range(4)),
        }
        xfers += 10
        for what, val in got.items():
            want = IDS[SPLITTER if "0x2c" in what else IT6805]
            if val != want:
                bad += 1
                print(f"mismatch {what}: {val.hex(' ')} != {want.hex(' ')}")
    print(f"{count} rounds, {xfers} transfers, {bad} mismatches")
    return bad == 0


def plain_read(fd):
    rbuf = (ctypes.c_uint8 * 1)()
    try:
        rdwr(fd, [I2cMsg(IT6805, I2C_M_RD, 1, rbuf)])
    except OSError as e:
        print(f"plain read: {errno.errorcode.get(e.errno, e.errno)}")
        return e.errno == errno.EOPNOTSUPP
    print("plain read: accepted (expected EOPNOTSUPP)")
    return False


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    fd = os.open(sys.argv[1], os.O_RDWR)
    try:
        if sys.argv[2] == "--plain-read":
            ok = plain_read(fd)
        else:
            ok = rounds(fd, int(sys.argv[2]))
    except OSError as e:
        print(f"error: {e}")
        ok = False
    finally:
        os.close(fd)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
