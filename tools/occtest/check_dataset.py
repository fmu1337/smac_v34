# Checks a dataset written by occ_dataset.sp against the map and the Python reference.
# Usage: python3 check_dataset.py map.bsp occ_dataset_<map>.csv [geometry_records=2000]
#
# 1. Safety: a pair the occluder proved hidden must have no segment the engine lets through.
# 2. Geometry: for every recorded segment (about N records spread over the file), if any kept world brush (shrunk like in the plugin)
#    blocks it, the engine trace must be blocked too. A failure names a brush the plugin must not trust.
# 3. Same answer as the reference: the brush the plugin proved with also proves in Python.
# 4. Usefulness: how many engine-hidden pairs one brush proves, what blocks the rest, time per record.
import csv, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from occ import BSP

bsp = BSP(sys.argv[1])
geom_limit = int(sys.argv[3]) if len(sys.argv) > 3 else 2000

def vec(s):
    return [float(x) for x in s.split()]

def vecs(s):
    return [vec(x) for x in s.split(';')]

def proves(brush, eyes, samples, all_eyes=()):
    # Same rule as Occ_Proves: no proof while an eye is inside solid (engine traces from there see through walls).
    if any(bsp.in_solid(e) for e in all_eyes):
        return False
    return all(bsp.blocked(brush, e, s) for e in eyes for s in samples)

rows = list(csv.DictReader(open(sys.argv[2], newline='')))
n = len(rows)
# Geometry check on about geom_limit records spread over the whole file.
geom_step = max(1, n // max(geom_limit, 1))
hidden = proven = unsafe = mismatch = 0
geom_segments = geom_bad = 0
no_world = by_entity = 0
trace_us = occ_us = 0.0
bad_brushes = {}
unsafe_rows = []

for idx, r in enumerate(rows):
    eye = vec(r['eye'])
    pa, pb = vec(r['peek_a']), vec(r['peek_b'])
    ok_a, ok_b = r['peek_a_ok'] == '1', r['peek_b_ok'] == '1'
    samples = vecs(r['samples'])
    vis = [int(r['vis_eye']), int(r['vis_peek_a']), int(r['vis_peek_b'])]
    brush = int(r['proof_brush'])
    trace_us += float(r['trace_us']); occ_us += float(r['occ_us'])
    is_hidden = not any(vis)
    hidden += is_hidden
    eyes_all = [(eye, True), (pa, ok_a), (pb, ok_b)]

    if brush >= 0:
        proven += 1
        if not is_hidden:
            unsafe += 1; unsafe_rows.append(idx + 2)
        # The plugin's proof uses the two outermost valid eyes.
        ea = pa if ok_a else eye; eb = pb if ok_b else eye
        if brush not in bsp.occ or not proves(brush, [ea, eb], samples, [p for p, ok in eyes_all if ok]):
            mismatch += 1
    elif is_hidden:
        if int(r['centre_ent']) > 0: by_entity += 1
        elif r['candidates'] == '': no_world += 1

    if idx % geom_step == 0:
        for e, (p, ok) in enumerate(eyes_all):
            # A trace that starts inside solid sees through walls; Occ_Proves never uses such an eye.
            if not ok or bsp.in_solid(p): continue
            for i, s in enumerate(samples):
                geom_segments += 1
                if not (vis[e] >> i) & 1:
                    continue   # engine blocked: anything goes
                for c in bsp.ray_candidates(p, s, 64):
                    if bsp.blocked(c, p, s):
                        geom_bad += 1; bad_brushes[c] = bad_brushes.get(c, 0) + 1
                        break

print(f'{os.path.basename(sys.argv[2])}: {n} records, engine-hidden {hidden} ({100 * hidden / max(n, 1):.0f}%)')
print(f'  1. proven by a brush: {proven}; PROVEN BUT ENGINE SEES: {unsafe}' + (f' (csv lines {unsafe_rows[:10]})' if unsafe else ''))
print(f'  2. geometry: {geom_segments} segments checked, brush blocks but engine sees: {geom_bad}' + (f' (brushes {sorted(bad_brushes.items(), key=lambda x: -x[1])[:10]})' if geom_bad else ''))
print(f'  3. plugin proof not reproduced by the Python reference: {mismatch}')
if hidden:
    print(f'  4. engine-hidden pairs proven by one brush: {100 * sum(1 for r in rows if int(r["proof_brush"]) >= 0 and not any(int(r[k]) for k in ("vis_eye", "vis_peek_a", "vis_peek_b"))) / hidden:.0f}%; '
          f'of the rest, centre blocked by an entity first: {by_entity}, no world brush on the centre line (props/displacements): {no_world}')
print(f'     per record: engine traces {trace_us / max(n, 1):.1f} us (all 30 segments), occluder search + proofs {occ_us / max(n, 1):.1f} us')
ok = unsafe == 0 and geom_bad == 0 and mismatch == 0
print('  RESULT:', 'OK' if ok else 'PROBLEMS - send this output and the csv')
sys.exit(0 if ok else 1)
