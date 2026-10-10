# How often can one brush prove a hidden pair? Random player pairs on nav areas of a real map.
# Usage: python3 sim.py map.bsp map.nav [peek_units=11] [pairs=1000]   (needs numpy)
#
# "Hidden" = every trace the plugin would make (real eye and both peek eyes to all 10 samples) hits an opaque world
# brush. For hidden pairs it reports the share proven by one brush found the plugin's way (first 8 brushes along
# the centre ray) and the ceiling for any single world brush. Props and displacements aren't modelled.
import os, random, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from occ import BSP, SHRINK
import nav

b = BSP(sys.argv[1]); areas = nav.load(sys.argv[2])
peek = float(sys.argv[3]) if len(sys.argv) > 3 else 11.0
N = int(sys.argv[4]) if len(sys.argv) > 4 else 1000

world = set(); st = [b.headnode]
while st:
    n = st.pop()
    if n < 0:
        c, fb, nb = b.leafs[-1 - n]; world.update(b.leafbrush[fb:fb + nb])
    else:
        st += [b.nodes[n][1], b.nodes[n][2]]
w18 = b.words(18); w19 = b.words(19)
ids = np.array(sorted(x for x in b.occ if x in world))
P = {bi: np.array([b.planes[p] for p in b.occ[bi]]) for bi in ids}
box = []
for bi in ids:
    first, num = w18[bi * 3], w18[bi * 3 + 1]
    mn = [-1e9] * 3; mx = [1e9] * 3
    for k in range(first, first + num):
        n = b.planes[w19[k * 2] & 0xFFFF]
        for a in range(3):
            if n[a] == 1.0: mx[a] = n[3]
            elif n[a] == -1.0: mn[a] = -n[3]
    box.append((mn, mx))
mins = np.array([x[0] for x in box]); maxs = np.array([x[1] for x in box])

def clip(bi, a, e, shrink):
    pl = P[bi]; da = pl[:, :3] @ a - pl[:, 3] + shrink; de = pl[:, :3] @ e - pl[:, 3] + shrink
    t0, t1 = 0.0, 1.0
    for x, y in zip(da, de):
        if x > 0 and y > 0: return False
        if x <= 0 and y <= 0: continue
        t = x / (x - y)
        if x > 0: t0 = max(t0, t)
        else: t1 = min(t1, t)
        if t0 > t1: return False
    return True

def near(a, e):
    lo = np.minimum(a, e); hi = np.maximum(a, e)
    return ids[np.all(mins <= hi, axis=1) & np.all(maxs >= lo, axis=1)]

def blocked(a, e):
    return any(clip(bi, a, e, 0.0) for bi in near(a, e))

def samples(eye, org):
    # Same points as IsAbleToSee for a standing target at the same level: centre, outer rect, head, inner rect.
    h = 64 / 2.2; c = org + [0, 0, h]
    f = eye - c; f[2] = 0; f /= np.linalg.norm(f); r = np.array([-f[1], f[0], 0])
    def rect(sc):
        w = 64 / 7 * sc; z = np.array([0, 0, h * sc])
        return [c + z + r * w, c + z - r * w, c - z + r * w, c - z - r * w]
    return [c] + rect(1.3) + [org + [0, 0, 64]] + rect(0.65)

def proves(bi, eyes, sm):
    return all(clip(bi, e, s, SHRINK) for e in eyes for s in sm)

random.seed(3)
wts = [abs(a[2][0] - a[1][0]) * abs(a[2][1] - a[1][1]) + 1 for a in areas]
def pos():
    a = random.choices(areas, wts)[0]
    return np.array([random.uniform(a[1][0], a[2][0]), random.uniform(a[1][1], a[2][1]), a[1][2] + 1.0])

hidden = ceiling = found = tries = 0
for _ in range(N):
    o1 = pos(); o2 = pos(); eye = o1 + [0, 0, 64]
    if np.linalg.norm((o2 - o1)[:2]) < 64: continue
    sm = samples(eye, o2)
    f = o2 - o1; f[2] = 0; f /= np.linalg.norm(f); side = np.array([-f[1], f[0], 0]) * peek
    eyes = [eye + side, eye - side] if peek > 0 else [eye]
    if not all(blocked(e, s) for e in [eye] + eyes for s in sm): continue
    hidden += 1
    ceiling += any(proves(bi, eyes, sm) for bi in near(eye, sm[0]))
    cand = b.ray_candidates(eye, sm[0], 8)
    for i, bi in enumerate(cand):
        if proves(bi, eyes, sm):
            found += 1; tries += i + 1; break
    else:
        tries += len(cand)
print(f'hidden pairs {hidden}; proven by one brush: {100 * found / hidden:.0f}% '
      f'(any single brush: {100 * ceiling / hidden:.0f}%), brush proofs per hidden pair {tries / hidden:.1f}')
