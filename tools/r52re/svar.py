import pickle, sys, re; sys.path.insert(0,'.')
from show import line
from ann import annotate
from sym import fmt
def collect(paths_list):
    allp = []
    for pl in paths_list: allp.extend(pl)
    return allp
def svar(paths, base, addr, ctx=4, maxn=12):
    seen = set(); out = []
    for tr in paths:
        brs = []
        for ev in tr:
            if ev[0] == 'br': brs.append(ev)
            if ev[0] == 'st' and ev[2] == addr:
                key = (ev[1], fmt(ev[3]))
                if key in seen: continue
                seen.add(key)
                out.append('ST @%06x  %s' % (ev[1], annotate('g%x = %s' % (addr, fmt(ev[3])), base)))
                for b in brs[-ctx:]: out.append('      if ' + annotate(line(b, 200), base))
                if len(seen) >= maxn: return out
    return out
if __name__ == '__main__':
    paths = []
    for f in sys.argv[1].split(','):
        obj = pickle.load(open(f, 'rb'))
        if isinstance(obj, tuple):
            res, base = obj
            for k, (s, h) in res.items(): paths.extend(h)
        else:
            paths.extend(obj); base = pickle.load(open(f + '.base', 'rb'))
    for a in sys.argv[2:]:
        print('#### g' + a)
        for l in svar(paths, base, int(a, 16)): print(l)
