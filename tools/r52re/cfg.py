import sys; sys.path.insert(0,'.')
from collections import defaultdict
COND = ('JZER','JNZ','JEQ','JNEQ','JSLESS','JSLEQ','JSGRTR','JSGEQ')
def build(p, f):
    a0, e = p.func_range(f)
    i = p.idx[a0]; succ = {}; addrs = []
    while i < len(p.ins) and p.ins[i][0] < e:
        a, n, pp = p.ins[i]
        nxt = p.ins[i+1][0] if i+1 < len(p.ins) else None
        addrs.append(a)
        if n == 'JUMP': s = [pp[0]]
        elif n in COND: s = [pp[0], nxt]
        elif n == 'SWITCH':
            _, _, tp = p.ins[p.idx[pp[0]]]
            s = [tp[1]] + [tp[3+2*k] for k in range(tp[0])]
        elif n in ('RETN', 'HALT', 'CASETBL', 'ENDPROC'): s = []
        else: s = [nxt]
        succ[a] = [x for x in s if x is not None]
        i += 1
    return succ
def can_reach(succ, target):
    pred = defaultdict(list)
    for a, ss in succ.items():
        for s in ss: pred[s].append(a)
    seen = {target}; st = [target]
    while st:
        x = st.pop()
        for y in pred[x]:
            if y not in seen: seen.add(y); st.append(y)
    return seen
