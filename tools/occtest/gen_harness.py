# Writes data.inc: the BSP as int32 words plus random point/segment queries and the Python answers.
import sys, struct, random
sys.path.insert(0, sys.argv[3])
from occ import BSP
b = BSP(sys.argv[1]); out = sys.argv[2]
d = b.d + b'\0' * (-len(b.d) % 4)
words = struct.unpack('<%di' % (len(d) // 4), d)
random.seed(7)
def f32(x):
    return struct.unpack('<f', struct.pack('<f', x))[0]
# Kept brushes with their boxes (for placing queries); occ.py applies the same filters as the plugin.
w18 = b.words(18); w19 = b.words(19)
kept = []
for bi in sorted(b.occ):
    first, num = w18[bi*3], w18[bi*3+1]
    mins = [1,1,1]; maxs = [-1,-1,-1]
    for k in range(first, first+num):
        n = b.planes[w19[k*2] & 0xFFFF]
        for a in range(3):
            if n[a] == 1.0: maxs[a] = n[3]
            elif n[a] == -1.0: mins[a] = -n[3]
    kept.append((bi, mins, maxs))
# Query points: around kept brushes.
pts = []; segs = []
for _ in range(400):
    bi, mn, mx = random.choice(kept)
    lo = [mn[a]-48 for a in range(3)]; hi = [mx[a]+48 for a in range(3)]
    # Rounded to float32 like the SourcePawn side, so both start from the same points.
    p = [f32(random.uniform(lo[a], hi[a])) for a in range(3)]
    q = [f32(random.uniform(lo[a], hi[a])) for a in range(3)]
    pts.append((p, b.leaf(p)))
    segs.append((bi, p, q, b.blocked(bi, p, q)))
f = open(out, 'w')
f.write('new g_iFileWords = %d;\nnew g_iFile[] = {%s};\n' % (len(words), ','.join(map(str, words))))
f.write('new g_iExpectKept = %d;\n' % len(kept))
f.write('new g_iExpectBrush[] = {%s};\n' % ','.join(str(k[0]) for k in kept))
f.write('new g_iNumQ = %d;\n' % len(pts))
f.write('new Float:g_fQ[][3] = {%s};\n' % ','.join('{%r,%r,%r}' % tuple(p) for p, _ in pts))
f.write('new g_iQLeaf[] = {%s};\n' % ','.join(str(l) for _, l in pts))
f.write('new g_iSBrush[] = {%s};\n' % ','.join(str(s[0]) for s in segs))
f.write('new Float:g_fSA[][3] = {%s};\n' % ','.join('{%r,%r,%r}' % tuple(s[1]) for s in segs))
f.write('new Float:g_fSB[][3] = {%s};\n' % ','.join('{%r,%r,%r}' % tuple(s[2]) for s in segs))
f.write('new bool:g_bSBlocked[] = {%s};\n' % ','.join('true' if s[3] else 'false' for s in segs))
# Long rays between random query points: the brushes the walk along them should list, padded with -1.
rays = []
for i in range(len(pts)):
    a = pts[i][0]; e = pts[(i * 7 + 3) % len(pts)][0]
    c = b.ray_candidates(a, e, 8)
    rays.append(c + [-1] * (8 - len(c)))
f.write('new g_iRayEnd[] = {%s};\n' % ','.join(str((i * 7 + 3) % len(pts)) for i in range(len(pts))))
f.write('new g_iRayExpect[][8] = {%s};\n' % ','.join('{%s}' % ','.join(map(str, r)) for r in rays))
print('rays with candidates', sum(r[0] >= 0 for r in rays), 'total candidates', sum(sum(x >= 0 for x in r) for r in rays))
print('words', len(words), 'kept', len(kept), 'blocked segs', sum(s[3] for s in segs))
