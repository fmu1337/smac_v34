import sys, struct, re
sys.path.insert(0,'.')
from smx import SMX
from dis import disasm
class P:
    def __init__(self, path):
        self.s = SMX(path)
        self.code = self.s.code()
        self.ins = disasm(self.code)
        self.idx = {a:i for i,(a,_,_) in enumerate(self.ins)}
        self.nat = self.s.natives()
        self.data, self.mem = self.s.data()
        self.pubs = {a:n for a,n in self.s.publics()}
        self.funcs = [a for a,n,_ in self.ins if n=='PROC']
        import bisect; self.bis = bisect
    def func_of(self, addr):
        i = self.bis.bisect_right(self.funcs, addr)-1
        return self.funcs[i]
    def func_range(self, f):
        i = self.funcs.index(f)
        end = self.funcs[i+1] if i+1 < len(self.funcs) else len(self.code)
        return f, end
    def dstr(self, a):
        if 0 <= a < len(self.data):
            e = self.data.find(b'\0', a)
            if e > a and e-a < 200:
                t = self.data[a:e]
                if all(32 <= c < 127 or c >= 0xc0 or 0x80<=c<0xc0 for c in t) and len(t)>=2:
                    return t.decode('utf-8','replace')
        return None
    def fmt(self, a, n, p):
        s = '%06x %-12s %s' % (a, n.lower(), ' '.join(hex(x) if abs(x)>9 else str(x) for x in p))
        if n in ('SYSREQ_N','SYSREQ_C'):
            s += '   ; ' + self.nat[p[0]]
        if n == 'CALL':
            s += '   ; ' + self.pubs.get(p[0], 'fn_%x'%p[0])
        for x in p:
            ds = self.dstr(x)
            if ds and n in ('PUSH_C','PUSH2_C','PUSH3_C','PUSH4_C','PUSH5_C','CONST_PRI','CONST_ALT','CONST'):
                s += '   ; "%s"' % ds[:60]
        if n in ('CONST_PRI','CONST_ALT','PUSH_C','PUSH2_C','PUSH3_C','PUSH4_C','PUSH5_C') :
            fl = [struct.unpack('<f', struct.pack('<i', x))[0] for x in p]
            fs = [f for f in fl if 1e-4 < abs(f) < 1e6 and abs(x)>0x1000000]
            if fs: s += '   ; f=' + ','.join('%g'%f for f in fs)
        return s
    def dump(self, f, maxn=100000, skip_break=True):
        a, e = self.func_range(f)
        i = self.idx[a]; out=[]
        while i < len(self.ins) and self.ins[i][0] < e and len(out) < maxn:
            ad, n, p = self.ins[i]
            if not (skip_break and n=='BREAK'):
                out.append(self.fmt(ad,n,p))
            i += 1
        return '\n'.join(out)
