import pickle, sys, re; sys.path.insert(0,'.')
from show import line
from ann import annotate
from directed2 import cfg_of, callers_chain
from cfg import can_reach
from tools import P
NOISE = re.compile(r'ReplyToCommand|SBBanPlayer|GetClientAuthString|GetClientIP|WritePack|CreateDataPack|CreateTimer|GetFeatureStatus|SMAC_Tag|<client>|IsClientInGame\(1\) == 0|GetUserFlagBits|SMAC_LogAction|g1cbd8|ST 148808')
def crep(p, res, base, key, root, after=30, window=0x2000, w=240, k=0):
    sites, hits, f = res[key]
    if not hits: return ['NO HITS']
    tr = hits[min(k, len(hits)-1)]
    hi = [i for i, ev in enumerate(tr) if ev[0] == 'hit'][0]
    lv = callers_chain(p, root, f) if f != root else {}
    lv = dict(lv or {}); lv[f] = sites
    info = {}
    for fn, ss in lv.items():
        succ = cfg_of(p, fn); R = set()
        for s in ss: R |= can_reach(succ, s)
        a0, e = p.func_range(fn); info[fn] = (succ, R, a0, e, ss)
    fa0, fe = p.func_range(f)
    out = []
    for i, ev in enumerate(tr[:hi + after]):
        if ev[0] not in ('br', 'sw', 'st', 'nat', 'fmt', 'hit'): continue
        a = ev[1]; req = False; local = False
        for fn, (succ, R, a0, e, ss) in info.items():
            if a0 <= a < e:
                if ev[0] == 'br' and a in succ and len(succ[a]) == 2 and i < hi:
                    r = [s in R for s in succ[a]]; req = r[0] != r[1]
                if fn == f and (min(ss) - window <= a <= max(ss) + 0x800): local = True
        if i > hi: local = True
        if req or local:
            s = '>>> HIT %06x' % a if ev[0] == 'hit' else annotate(line(ev, w), base)
            if NOISE.search(s): continue
            out.append(('* ' if req else '  ') + s)
    return out
if __name__ == '__main__':
    p = P(sys.argv[1]); res, base = pickle.load(open(sys.argv[2], 'rb'))
    pubs = {n: a for a, n in p.s.publics()}
    root = pubs[sys.argv[3]]
    keys = sys.argv[4:] or list(res.keys())
    for key in keys:
        print('=' * 20, key)
        for l in crep(p, res, base, key, root): print(l)
