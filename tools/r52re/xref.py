import sys, re, pickle; sys.path.insert(0,'.')
from run_apl import boot
from collections import defaultdict
p, e, pubs = boot(sys.argv[1])
pickle.dump(bytes(e.base), open('base_%s.bin' % sys.argv[1].split('/')[-1].split('.')[0], 'wb'))
mem = e.base
ds = len(p.data)
# map string start addresses in data
strs = {}
for m in re.finditer(rb'[\x20-\x7e]{3,}\x00', bytes(mem[:ds])):
    strs[m.start()] = m.group()[:-1].decode()
# code refs: any param equal to a string address
refs = defaultdict(set)
for a, n, pp in p.ins:
    for x in pp:
        if x in strs: refs[x].add(a)
# call graph
callers = defaultdict(set)
for a, n, pp in p.ins:
    if n == 'CALL': callers[pp[0]].add(p.func_of(a))
pubaddr = {a: nm for a, nm in p.s.publics()}
def up(f, depth=0, seen=None):
    seen = seen or set()
    if f in seen or depth > 12: return []
    seen.add(f)
    if f in pubaddr: return [[pubaddr[f]]]
    out = []
    for c in callers.get(f, ()):
        for ch in up(c, depth+1, seen):
            out.append(ch + ['%x' % f])
    return out
pickle.dump((strs, dict(refs), dict(callers)), open('xref_%s.pkl' % sys.argv[1].split('/')[-1].split('.')[0], 'wb'))
pat = re.compile(sys.argv[2]) if len(sys.argv) > 2 else None
for addr in sorted(strs):
    s = strs[addr]
    if pat and not pat.search(s): continue
    fs = set(p.func_of(r) for r in refs.get(addr, ()))
    chains = []
    for f in fs:
        for ch in up(f)[:3]: chains.append('->'.join(ch))
    print('%06x %-40s funcs=%s chains=%s' % (addr, s[:40], ['%x' % f for f in fs], chains[:4]))
