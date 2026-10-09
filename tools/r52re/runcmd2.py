import sys, time, pickle; sys.path.insert(0,'.')
from tools import P
from emu2 import Emu2, Kill
from runcmd import setup_runcmd
def load(path):
    p = P(path)
    base = pickle.load(open('base_%s.bin' % path.split('/')[-1].split('.')[0], 'rb'))
    return p, base
def explore_rc(em, entry, maxp=3000, log_conc=False, client=1, pre=None):
    em.reset(); em.trace = None; em.log_conc = log_conc
    if pre: pre(em)
    stk, hea = setup_runcmd(em, em.memsize, em.datasize)
    args = list(em.rc_args); args[0] = (client, None)
    em.paths_out = []; em.covered = set()
    for v, s in reversed(args):
        stk -= 4; em.wr(stk, v, s)
    stk -= 4; em.wr(stk, len(args)); stk -= 4; em.wr(stk, -1)
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
    em.npaths = n; em.left = len(work)
    return em.paths_out
