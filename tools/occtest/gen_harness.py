# Writes sptest/data.inc: the BSP as int32 words plus random point/segment queries and the Python answers.
import sys, struct, random
sys.path.insert(0, sys.argv[3])
from occ import BSP
b = BSP(sys.argv[1]); out = sys.argv[2]
d = b.d + b'\0' * (-len(b.d) % 4)
words = struct.unpack('<%di' % (len(d) // 4), d)
random.seed(7)
# Python-side planes per kept brush, with the same AABB sanity filter as the SP loader.
w18 = b.words(18); w19 = b.words(19)
kept = []
for bi, planes in sorted(b.occ.items()):
    first, num = w18[bi*3], w18[bi*3+1]
    mins = [1,1,1]; maxs = [-1,-1,-1]
    for k in range(first, first+num):
        n = b.planes[w19[k*2] & 0xFFFF]
        for a in range(3):
            if n[a] == 1.0: maxs[a] = n[3]
            elif n[a] == -1.0: mins[a] = -n[3]
    if any(mins[a] > maxs[a] for a in range(3)): continue
    c = [(mins[a]+maxs[a])/2 for a in range(3)]
    if not b.inside(bi, c, -0.01): continue
    kept.append((bi, mins, maxs))
# Query points: around kept brushes.
pts = []; segs = []
for _ in range(400):
    bi, mn, mx = random.choice(kept)
    lo = [mn[a]-48 for a in range(3)]; hi = [mx[a]+48 for a in range(3)]
    p = [random.uniform(lo[a], hi[a]) for a in range(3)]
    q = [random.uniform(lo[a], hi[a]) for a in range(3)]
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
print('words', len(words), 'kept', len(kept), 'blocked segs', sum(s[3] for s in segs))
