import sys, pickle, time; sys.path.insert(0,'.')
import hybrid
from directed2 import Directed2, callers_chain, str_sites
hybrid.Hybrid = Directed2
from hybrid import prepare
from emu2 import Kill
def explore_pub(em, entry, args, maxp=3000):
    em.reset(); em.trace = None
    stk = em.memsize - 0x9000; hea = em.datasize
    for v, s in reversed(args):
        stk -= 4; em.wr(stk, v, s)
    stk -= 4; em.wr(stk, len(args)); stk -= 4; em.wr(stk, -1)
    em.paths_out = []; em.covered = set()
    work = [(entry, 0, None, 0, None, 0, stk, hea, len(em.undo), [])]
    n = 0
    while work and n < maxp:
        st = work.pop(); n += 1
        em.trace = list(st[9])
        try:
            em.run_path(st, work); em.trace.append(('end',))
        except Kill as k:
            em.trace.append(('kill', str(k)))
        em.paths_out.append(em.trace)
    return em.paths_out
if __name__ == '__main__':
    path = sys.argv[1]; root_pub = sys.argv[2]; outp = sys.argv[3]; nargs = int(sys.argv[4])
    specs = sys.argv[5:]
    p, h, pubs = prepare(path)
    root = pubs[root_pub]
    args = [(1, None)] + [(0, ('v', 'arg%d' % k)) for k in range(1, nargs)]
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
        paths = explore_pub(h, root, args, 3000)
        hits = [tr for tr in paths if any(ev[0] == 'hit' for ev in tr)]
        print('%-55s chain=%s paths=%d hits=%d %.1fs' % (sp[:55], [hex(x) for x in lv], len(paths), len(hits), time.time()-t0))
        res[sp] = (fs, hits, f)
    pickle.dump((res, bytes(h.base)), open(outp, 'wb'))
