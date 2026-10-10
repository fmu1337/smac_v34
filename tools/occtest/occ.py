# Reference model of the SP occluder code: parse VBSP, keep opaque world brushes, point->leaf, segment-vs-brush.
import struct, sys, random

SOLID, WINDOW, GRATE, WATER, SLIME, TRANSLUCENT = 0x1, 0x2, 0x8, 0x20, 0x10, 0x10000000
SURF_TRANS, SURF_NODRAW = 0x10, 0x80
SHRINK = 1.0

class BSP:
    def __init__(s, path):
        d = open(path, 'rb').read()
        s.d = d
        ident, s.ver = struct.unpack_from('<4si', d, 0)
        s.lumps = [struct.unpack_from('<iiii', d, 8 + 16 * i) for i in range(64)]
        def words(l):
            o, n, v, fourcc = s.lumps[l]
            assert fourcc == 0
            return struct.unpack_from('<%di' % (n // 4), d, o)
        s.words = words
        w = words(1); s.planes = [(struct.unpack('<4f', struct.pack('<4i', *w[i*5:i*5+4]))) for i in range(len(w)//5)]
        w = words(6); s.texflags = [w[i*18+16] for i in range(len(w)//18)]
        w = words(5); s.nodes = [(w[i*8], w[i*8+1], w[i*8+2]) for i in range(len(w)//8)]
        o, n, v, _ = s.lumps[10]; size = 56 if v == 0 else 32; ws = size // 4
        w = words(10)
        s.leafs = []
        for i in range(n // size):
            b = w[i*ws:(i+1)*ws]
            contents = b[0]
            fb = b[6] & 0xFFFF; nb = (b[6] >> 16) & 0xFFFF   # firstleafbrush, numleafbrushes at byte 24
            s.leafs.append((contents, fb, nb))
        w = words(17); s.leafbrush = []
        for x in w: s.leafbrush += [x & 0xFFFF, (x >> 16) & 0xFFFF]
        w = words(18); brushes = [(w[i*3], w[i*3+1], w[i*3+2]) for i in range(len(w)//3)]
        w = words(19); sides = []
        for i in range(len(w)//2):
            a, b = w[i*2] & 0xFFFFFFFF, w[i*2+1] & 0xFFFFFFFF
            tex = (a >> 16) & 0xFFFF
            if tex >= 0x8000: tex -= 0x10000
            sides.append((a & 0xFFFF, tex, (b >> 16) & 0xFFFF))
        s.headnode = struct.unpack_from('<i', d, s.lumps[14][0] + 36)[0]
        s.occ = {}
        for bi, (first, num, cont) in enumerate(brushes):
            if not (cont & SOLID) or cont & (WINDOW | GRATE | WATER | SLIME | TRANSLUCENT): continue
            planes = []; visible = False; bad = False
            for k in range(first, first + num):
                p, tex, bevel = sides[k]
                if bevel: continue
                f = s.texflags[tex] if tex >= 0 else SURF_NODRAW
                if f & SURF_TRANS: bad = True
                if not f & SURF_NODRAW: visible = True
                planes.append(p)
            if bad or not visible or len(planes) < 4: continue
            s.occ[bi] = planes
    def leaf(s, p):
        n = s.headnode
        while n >= 0:
            pl, c0, c1 = s.nodes[n]
            a = s.planes[pl]
            n = c0 if a[0]*p[0]+a[1]*p[1]+a[2]*p[2]-a[3] >= 0 else c1
        return -1 - n
    def blocked(s, bi, a, b):
        t0, t1 = 0.0, 1.0
        for pl in s.occ[bi]:
            n = s.planes[pl]
            da = n[0]*a[0]+n[1]*a[1]+n[2]*a[2]-n[3]+SHRINK
            db = n[0]*b[0]+n[1]*b[1]+n[2]*b[2]-n[3]+SHRINK
            if da > 0 and db > 0: return False
            if da <= 0 and db <= 0: continue
            t = da / (da - db)
            if da > 0: t0 = max(t0, t)
            else: t1 = min(t1, t)
            if t0 > t1: return False
        return True
    def inside(s, bi, p, eps=0.0):
        for pl in s.occ[bi]:
            n = s.planes[pl]
            if n[0]*p[0]+n[1]*p[1]+n[2]*p[2]-n[3]+eps > 0: return False
        return True

if __name__ == '__main__':
    b = BSP(sys.argv[1])
    print('ver', b.ver, 'planes', len(b.planes), 'nodes', len(b.nodes), 'leafs', len(b.leafs), 'leafversion', b.lumps[10][2], 'kept', len(b.occ), 'headnode', b.headnode)
