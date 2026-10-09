import sys, pickle, time; sys.path.insert(0,'.')
import hybrid
from directed2 import Directed2, callers_chain, str_sites
hybrid.Hybrid = Directed2
from hybrid import prepare
from runcmd2 import explore_rc
path = sys.argv[1]; root_pub = sys.argv[2]; outp = sys.argv[3]
specs = sys.argv[4:]   # each "funchex:string"
p, h, pubs = prepare(path)
root = pubs[root_pub]
res = {}
for sp in specs:
    fh, s = sp.split(':', 1); f = int(fh, 16)
    fs = [int(x,16) for x in s[1:].split(',')] if s.startswith('@') else str_sites(p, h.base, s, f)
    if not fs: print('no site', sp); continue
    lv = callers_chain(p, root, f) if f != root else {}
    if lv is None: print('no chain', sp); continue
    lv = dict(lv); lv[f] = fs
    h.set_chain(lv, fs)
    t0 = time.time()
    paths = explore_rc(h, root, 3000)
    hits = [tr for tr in paths if any(ev[0] == 'hit' for ev in tr)]
    print('%-55s chain=%s paths=%d hits=%d %.1fs' % (sp[:55], [hex(x) for x in lv], len(paths), len(hits), time.time()-t0))
    res[sp] = (fs, hits, f)
pickle.dump((res, bytes(h.base)), open(outp, 'wb'))
