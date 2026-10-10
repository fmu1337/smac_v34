# Minimal CS:S .nav (version 5-9) reader: area id and corners.
import struct
def load(path):
    d = open(path, 'rb').read(); o = 0
    def r(fmt):
        nonlocal o
        v = struct.unpack_from('<' + fmt, d, o); o += struct.calcsize('<' + fmt); return v
    magic, ver = r('II'); assert magic == 0xFEEDFACE and 5 <= ver <= 9, ver
    r('I')  # bsp size
    n, = r('H')
    for _ in range(n):
        l, = r('H'); o += l
    count, = r('I'); areas = []
    for _ in range(count):
        aid, = r('I'); r('B' if ver <= 8 else 'H')
        nw = r('3f'); se = r('3f'); nez, swz = r('2f')
        for _ in range(4):
            c, = r('I'); o += 4 * c
        c, = r('B'); o += c * (4 + 12 + 1)
        c, = r('B'); o += c * 14
        c, = r('I')
        for _ in range(c):
            r('IBIB'); s, = r('B'); o += s * 5
        r('H')
        if ver >= 7:
            for _ in range(2):
                c, = r('I'); o += 4 * c
        if ver >= 8: r('2f')
        areas.append((aid, nw, se, nez, swz))
    return areas
