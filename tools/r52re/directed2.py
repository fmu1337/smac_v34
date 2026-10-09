import sys, re; sys.path.insert(0,'.')
from emu2 import Emu2, Kill
from hybrid import Hybrid
from cfg import build, can_reach
_cfgc = {}
def cfg_of(p, f):
    if f not in _cfgc: _cfgc[f] = build(p, f)
    return _cfgc[f]
class Directed2(Hybrid):
    def set_chain(self, levels, final_sites):
        """levels: dict func -> list of target sites inside func (call sites or final sites)"""
        p = self.p
        self.lv = {}
        self.franges = []
        for f, sites in levels.items():
            succ = cfg_of(p, f); R = set()
            for s in sites: R |= can_reach(succ, s)
            a0, e = p.func_range(f)
            self.lv[f] = (succ, R, a0, e)
            self.franges.append((a0, e, f))
        self.watch = set(final_sites)
        self.prune = self._prune
    def _lv(self, a):
        for a0, e, f in self.franges:
            if a0 <= a < e: return self.lv[f]
        return None
    def on_watch(self, cip):
        if not self.reached:
            self.trace.append(('hit', cip)); self.reached = True
    def _prune(self, a, nxt):
        if self.reached: return
        L = self._lv(a)
        if L and a in L[0] and nxt not in L[1]: raise Kill('pruned')
    def branch(self, cip, cond, taken, work, alt_cip, here, state):
        if self.reached:
            self.trace.append(('br', cip, cond, taken)); return here
        L = self._lv(cip)
        if L and cip in L[0]:
            succ, R = L[0], L[1]
            okh = here in R; oka = alt_cip in R
            if okh and oka: return Emu2.branch(self, cip, cond, taken, work, alt_cip, here, state)
            if okh: self.trace.append(('br', cip, cond, taken)); return here
            if oka: self.trace.append(('br', cip, cond, not taken)); return alt_cip
            raise Kill('unreachable')
        return Emu2.branch(self, cip, cond, taken, work, alt_cip, here, state)
def callers_chain(p, root, target_func, maxdepth=6):
    """find a call chain root -> ... -> target_func; returns dict func -> call sites to next"""
    from collections import defaultdict, deque
    calls = defaultdict(list)  # f -> [(site, callee)]
    for a, n, pp in p.ins:
        if n == 'CALL': calls[p.func_of(a)].append((a, pp[0]))
    # BFS
    prev = {root: None}; dq = deque([root])
    while dq:
        f = dq.popleft()
        if f == target_func: break
        for site, c in calls[f]:
            if c not in prev:
                prev[c] = (f, site); dq.append(c)
    if target_func not in prev: return None
    lv = defaultdict(list); f = target_func
    while prev[f] is not None:
        pf, site = prev[f]
        # include all call sites in pf that call f
        lv[pf] = [s for s, c in calls[pf] if c == f]
        f = pf
    return dict(lv)
def str_sites(p, base, s, func):
    a0, e = p.func_range(func)
    bs = s.encode() + b'\0'
    addrs = [m.start() for m in re.finditer(re.escape(bs), bytes(base[:len(p.data)]))]
    out = []
    i = p.idx[a0]
    while i < len(p.ins) and p.ins[i][0] < e:
        a, n, pp = p.ins[i]
        if any(x in addrs for x in pp): out.append(a)
        i += 1
    return out
