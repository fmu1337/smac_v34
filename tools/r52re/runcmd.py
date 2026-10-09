import sys, time, pickle; sys.path.insert(0,'.')
from run_apl import boot
from emu2 import Emu2
from sym import fmt
def setup_runcmd(em, stk, hea):
    base = em.memsize - 0x8000
    em.args_addr = {}
    def cell(name, n=1):
        nonlocal base
        ad = base
        for j in range(n):
            nm = name if n == 1 else '%s%d' % (name, j)
            em.wr(base, 0, ('v', nm)); base += 4
        em.args_addr[name] = ad
        return ad
    a = {}
    a['buttons'] = cell('btn'); a['impulse'] = cell('impulse'); a['vel'] = cell('vel', 3); a['ang'] = cell('ang', 3)
    a['weapon'] = cell('wpn'); a['subtype'] = cell('subtype'); a['cmdnum'] = cell('cmdnum'); a['tick'] = cell('tick')
    a['seed'] = cell('seed'); a['mouse'] = cell('mouse', 2)
    em.rc_args = [(1, None), (a['buttons'], None), (a['impulse'], None), (a['vel'], None), (a['ang'], None), (a['weapon'], None),
                  (a['subtype'], None), (a['cmdnum'], None), (a['tick'], None), (a['seed'], None), (a['mouse'], None)]
    return em.memsize - 0x9000, hea
if __name__ == '__main__':
    path = sys.argv[1]; pub = sys.argv[2] if len(sys.argv) > 2 else 'OnPlayerRunCmd'
    p, e, pubs = boot(path)
    em = Emu2(p, e.base)
    em.MAX_PATHS = int(sys.argv[3]) if len(sys.argv) > 3 else 3000
    t = time.time()
    # two-phase: setup creates arrays, then args
    def setup(em_, stk, hea):
        r = setup_runcmd(em_, stk, hea)
        return r
    em.reset()
    # explore with setup that also defines args: we need args after setup -> wrap
    em.rc_args = None
    def explore_rc():
        em.reset()
        em.trace = None
        stk, hea = setup_runcmd(em, em.memsize, em.datasize)
        args = em.rc_args
        em.tag = pub; em.paths_out = []; em.covered = set()
        for v, s in reversed(args):
            stk -= 4; em.wr(stk, v, s)
        stk -= 4; em.wr(stk, len(args)); stk -= 4; em.wr(stk, -1)
        work = [(pubs[pub], 0, None, 0, None, 0, stk, hea, len(em.undo), [])]
        n = 0
        from emu2 import Kill
        while work and n < em.MAX_PATHS:
            st = work.pop(); n += 1
            em.trace = list(st[9])
            try:
                em.run_path(st, work); em.trace.append(('end',))
            except Kill as k:
                em.trace.append(('kill', str(k)))
            em.paths_out.append(em.trace)
        em.npaths = n; em.left = len(work)
    explore_rc()
    print('paths', em.npaths, 'left', em.left, 'time %.1f' % (time.time()-t))
    pickle.dump(em.paths_out, open('paths_%s_%s.pkl' % (path.split('/')[-1].split('.')[0], pub), 'wb'))
    from collections import Counter
    kills = Counter(tr[-1][1].split('@')[0] if tr[-1][0]=='kill' else tr[-1][0] for tr in em.paths_out)
    print(kills)
    nats = Counter(ev[2] for tr in em.paths_out for ev in tr if ev[0]=='nat')
    print(nats.most_common(50))
    fm = Counter(ev[2] for tr in em.paths_out for ev in tr if ev[0]=='fmt')
    print([x for x in fm.most_common(200)])
