import sys, signal, re
sys.path.insert(0,'.')
from decomp import *
path, base, wr, out = sys.argv[1:5]
ctx = make_ctx(path, base, wr)
p = ctx.p
class TO(Exception): pass
def h(*a): raise TO()
signal.signal(signal.SIGALRM, h)
fo = open(out, 'w')
for f in p.funcs:
    name = p.pubs.get(f, 'fn_%x' % f)
    try:
        signal.alarm(8)
        d = Decomp(ctx, f); d.run(); d.finish(); txt = d.render()
        signal.alarm(0)
    except TO:
        fo.write('// %s @%x TIMEOUT\n\n' % (name, f)); continue
    except Exception as ex:
        signal.alarm(0)
        fo.write('// %s @%x FAILED %s\n\n' % (name, f, ex)); continue
    if txt.count('%c') > 3 and 'Format' in txt:   # string decryptors
        fo.write('// %s @%x (string decryptor)\n\n' % (name, f)); continue
    fo.write('// %s @%x\n%s\n\n' % (name, f, txt))
