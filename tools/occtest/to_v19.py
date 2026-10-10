# Rewrites the leaf lump of a v20 map into the old 56-byte layout (lump version 0) and marks the file v19.
import struct, sys
d = bytearray(open(sys.argv[1], 'rb').read())
o, n, v, cc = struct.unpack_from('<iiii', d, 8 + 16 * 10)
assert v == 1
new = bytearray()
for i in range(n // 32):
    leaf = d[o + i*32: o + i*32 + 32]
    new += leaf[:30] + bytes(range(1, 25)) + b'\xAB\xCD'   # junk ambient lighting + padding
pad = -len(d) % 4
d += b'\0' * pad
off = len(d); d += new
struct.pack_into('<iiii', d, 8 + 16 * 10, off, len(new), 0, 0)
struct.pack_into('<i', d, 4, 19)
open(sys.argv[2], 'wb').write(d)
