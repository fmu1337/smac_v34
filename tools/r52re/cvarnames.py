import sys, collections
sys.path.insert(0,'.')
from decomp import *
path, base, wr, fn, tbl = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5],16)
ctx = make_ctx(path, base, wr)
f = resolve(ctx.p, fn)
d = Decomp(ctx, f); d.run(); d.finish()
lines = d.live
# find first casetbl after first switch on loop index
ct = None
for ad, s in d.lines:
    if s[0] == 'casetbl' and s[1][0] > 20:
        ct = s[1]; break
lab2idx = {}
for j in range(ct[0]):
    lab2idx.setdefault(ct[3+2*j], []).append(ct[2+2*j])
cur = None
writes = collections.defaultdict(list)
for ad, s in lines:
    if s[0] == 'label' and s[1] in lab2idx:
        cur = lab2idx[s[1]]
    if s[0] == 'casetbl': cur = None
    if cur and s[0] == 'store':
        pa = d.parse_addr(s[1])
        if pa and pa[0].startswith('g') and not pa[1]:
            for c in cur: writes[c].append(pa[0])
for i in sorted(writes):
    A = d.ev_addr(('bin','+',('bin','idx',('c',tbl),('c',i)),('ld',('bin','idx',('c',tbl),('c',i)))))
    nm = ctx.string_at(A) if A else None
    print(i, nm, sorted(set(writes[i])))
