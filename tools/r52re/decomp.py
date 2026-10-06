"""
Mini decompiler for SourcePawn v1 (SP1) bytecode -> goto-style pseudo code,
with constant folding against post-init memory, boolean join reconstruction
and dead-branch removal (SmartPawn opaque predicates).

usage: python3 decomp.py <plugin.smx> <public name|hex addr> [--base hbase.bin] [--wr wr.pkl]
                         [--noinline] [--raw]
"""
import sys, struct, re, collections, pickle, math
sys.path.insert(0, '.')
from tools import P

def i2f(v):
    return struct.unpack('<f', struct.pack('<I', v & 0xffffffff))[0]

def f2i(f):
    try:
        return struct.unpack('<i', struct.pack('<f', f))[0]
    except (OverflowError, struct.error):
        return None

def s32(v):
    v &= 0xffffffff
    return v - (1 << 32) if v & 0x80000000 else v

def nice_float(v):
    if abs(v) < 0x400000:
        return None
    f = i2f(v)
    if f != f or abs(f) > 1e9 or abs(f) < 1e-6:
        return None
    s = ('%.6g' % f)
    if len(s.replace('-', '').replace('.', '').replace('e', '').lstrip('0')) > 7:
        return None
    return s

JUMPS = {'JUMP', 'JZER', 'JNZ', 'JEQ', 'JNEQ', 'JSLESS', 'JSLEQ', 'JSGRTR', 'JSGEQ'}
CMP = {'JEQ': '==', 'JNEQ': '!=', 'JSLESS': '<', 'JSLEQ': '<=', 'JSGRTR': '>', 'JSGEQ': '>='}
NEGCMP = {'==': '!=', '!=': '==', '<': '>=', '<=': '>', '>': '<=', '>=': '<'}
SWAPCMP = {'<': '>', '>': '<', '<=': '>=', '>=': '<=', '==': '==', '!=': '!='}
PURE = re.compile(r'^(Float|Get(?!ClientCookie|Cmd|EventString|ClientName|ClientAuth|ClientIP|ConVarString|ClientWeapon|EdictClassname|EntityNetClass|PluginFilename|CurrentMap|EntPropString|ArrayString|ArrayArray|TrieString|TrieArray|ClientEye|ClientAbs|ClientMins|ClientMaxs|EntPropVector|EntDataVector|AngleVectors|VectorAngles|PluginInfo|GameFolderName)|Is|Round|StringTo|Find(?!Entity)|Abs|SquareRoot|strlen|strcmp|StrEqual|StrContains|TR_(Get(?!EndPosition|PlaneNormal)|Did)|Vector(?!s)|Degto|DegToRad|RadToDeg|Sine|Cosine|Arc|Tangent|Pow|Logarithm|Exponential|float|Clamp|CharTo|IsChar)')
FLOATOPS = {'FloatAdd': '+.', 'FloatSub': '-.', 'FloatMul': '*.', 'FloatDiv': '/.'}

class Ctx:
    def __init__(self, p, base, inline=True, wr=None):
        self.p = p
        self.base = base
        self.inline = inline
        self.summ = {}
        self.rt = None
        self.names = {}
        if wr is not None:
            w, c, io = wr
            self.rt = set(b for b, fs in w.items() if not fs <= io)

    def cell(self, a):
        mem = self.base if self.base is not None else self.p.data
        if a is not None and 0 <= a and a + 4 <= len(mem):
            return struct.unpack_from('<i', mem, a)[0]
        return None

    def string_at(self, a):
        mems = ([self.base] if self.base is not None else []) + [self.p.data]
        for mem in mems:
            if not (0 <= a < len(mem)):
                continue
            e = mem.find(b'\0', a)
            if 1 <= e - a < 300:
                t = mem[a:e]
                if all(32 <= c < 127 or c >= 0x80 or c in (9, 10, 13) for c in t):
                    return t.decode('utf-8', 'replace')
        return None

    def is_const_base(self, b):
        if self.rt is None or self.base is None:
            return False
        return b not in self.rt

    def summary(self, f):
        if f in self.summ:
            return self.summ[f]
        self.summ[f] = None
        a, e = self.p.func_range(f)
        n = 0
        for (ad, nm, _) in self.p.ins[self.p.idx[a]:]:
            if ad >= e: break
            n += 1
        if n > 60:
            return None
        d = Decomp(self, f, nested=True)
        try:
            d.run()
            d.finish()
        except Exception:
            return None
        if d.single_return is not None:
            self.summ[f] = d.single_return
        return self.summ[f]

def subst(e, args):
    if isinstance(e, tuple):
        if e[0] == 'arg':
            return args[e[1]] if e[1] < len(args) else ('c', 0)
        if e[0] == 'argaddr':
            return ('reg', 'argaddr')
        if e[0] == 'call':
            return ('call', e[1], [subst(x, args) for x in e[2]], e[3])
        return tuple(subst(x, args) if isinstance(x, tuple) else x for x in e)
    return e

def subst_pri(e, cur):
    if not isinstance(e, tuple):
        return e
    if e == ('reg', 'pri'):
        return cur
    if e[0] == 'call':
        return ('call', e[1], [subst_pri(x, cur) for x in e[2]], e[3])
    return tuple(subst_pri(x, cur) if isinstance(x, tuple) else x for x in e)

def has_reg(e):
    if not isinstance(e, tuple):
        return False
    if e[0] == 'reg':
        return True
    if e[0] == 'call':
        return any(has_reg(x) for x in e[2])
    return any(has_reg(x) for x in e if isinstance(x, tuple))

class Decomp:
    def __init__(self, ctx, f, nested=False):
        self.ctx = ctx
        self.p = ctx.p
        self.f = f
        self.nested = nested
        self.a0, self.e = self.p.func_range(f)
        self.single_return = None
        self.used_temps = set()
        self.label_pri = {}
        self.budget = 200000

    # ---------------- naming / addresses ----------------
    def name_frm(self, off):
        if off >= 0xc:
            return 'a%d' % ((off - 0xc) // 4)
        return 'l%x' % (-off)

    def gn(self, a):
        return self.ctx.names.get(a, 'g%x' % a)

    def parse_addr(self, e):
        if e[0] == 'c':
            return ('g%x' % e[1], [])
        if e[0] == 'frm':
            return (self.name_frm(e[1]), [])
        if e[0] == 'ld' and e[1][0] == 'frm' and e[1][1] >= 0xc:
            return (self.name_frm(e[1][1]), [])
        if e[0] == 'arg':
            return ('a%d' % e[1], [])
        if e[0] == 'bin' and e[1] == 'idx':
            b = self.parse_addr(e[2])
            if b:
                ix = list(b[1])
                if ix and ix[-1] == 'ROW':
                    ix[-1] = e[3]
                    return (b[0], ix)
                return (b[0], ix + [e[3]])
        if e[0] == 'bin' and e[1] == '+':
            x, y = e[2], e[3]
            for X, Y in ((x, y), (y, x)):
                if Y[0] == 'ld' and Y[1] == X:
                    b = self.parse_addr(X)
                    if b:
                        ix = list(b[1]) or [('c', 0)]
                        return (b[0], ix + ['ROW'])
                if Y[0] == 'c' and Y[1] % 4 == 0:
                    b = self.parse_addr(X)
                    if b:
                        ix = list(b[1])
                        k = Y[1] // 4
                        if ix and ix[-1] == 'ROW':
                            ix[-1] = ('c', k)
                            return (b[0], ix)
                        if ix:
                            ix[-1] = self.addc(ix[-1], k)
                            return (b[0], ix)
                        return (b[0], [('c', k)])
        return None

    def addc(self, e, k):
        if e[0] == 'c':
            return ('c', e[1] + k)
        return ('bin', '+', e, ('c', k))

    # ---------------- constant evaluation ----------------
    def ev_addr(self, e, depth=0):
        if depth > 30: return None
        k = e[0]
        if k == 'c': return e[1]
        if k == 'bin' and e[1] == '+':
            a = self.ev_addr(e[2], depth + 1); b = self.ev(e[3], depth + 1) if e[3][0] != 'ld' else self.ev_addr_ld(e[3], depth + 1)
            if a is None:
                return None
            if b is None:
                b2 = self.ev_addr(e[3], depth + 1)
                if b2 is None: return None
                b = b2
            return a + b
        if k == 'bin' and e[1] == 'idx':
            a = self.ev_addr(e[2], depth + 1); i = self.ev(e[3], depth + 1)
            return None if a is None or i is None else a + 4 * i
        if k == 'ld':
            return self.ev_addr_ld(e, depth)
        return None

    def ev_addr_ld(self, e, depth):
        a = self.ev_addr(e[1], depth + 1)
        return self.ctx.cell(a) if a is not None else None

    def ev(self, e, depth=0):
        """concrete int value of a pure expression over constant memory, else None"""
        if depth > 40: return None
        k = e[0]
        if k == 'c': return e[1]
        if k == 'ld':
            pa = self.parse_addr(e[1])
            if not pa or not pa[0].startswith('g'):
                return None
            if not self.ctx.is_const_base(int(pa[0][1:], 16)):
                return None
            a = self.ev_addr(e[1], depth + 1)
            return self.ctx.cell(a)
        if k == 'un':
            v = self.ev(e[2], depth + 1)
            if v is None: return None
            if e[1] == '-': return s32(-v)
            if e[1] == '~': return s32(~v)
            if e[1] == '!': return int(v == 0)
            return None
        if k == 'bin':
            op = e[1]
            if op == 'idx': return None
            a = self.ev(e[2], depth + 1)
            if a is None: return None
            if op == '&&' and a == 0: return 0
            if op == '||' and a != 0: return 1
            b = self.ev(e[3], depth + 1)
            if b is None: return None
            try:
                if op == '+': return s32(a + b)
                if op == '-': return s32(a - b)
                if op == '*': return s32(a * b)
                if op == '/': return s32(int(a / b)) if b else None
                if op == '%': return s32(a - b * int(a / b)) if b else None
                if op == '&': return s32(a & b)
                if op == '|': return s32(a | b)
                if op == '^': return s32(a ^ b)
                if op == '<<': return s32(a << (b & 31))
                if op == '>>': return s32(a >> (b & 31))
                if op == '>>>': return s32((a & 0xffffffff) >> (b & 31))
                if op == '&&': return int(bool(a) and bool(b))
                if op == '||': return int(bool(a) or bool(b))
                if op in ('==', '!=', '<', '<=', '>', '>='):
                    return int(eval('%d %s %d' % (a, op, b)))
                if op.endswith('.') and op[:-1] in ('==', '!=', '<', '<=', '>', '>='):
                    fa, fb = i2f(a), i2f(b)
                    return int(eval('%r %s %r' % (fa, op[:-1], fb)))
            except Exception:
                return None
            return None
        if k == 'ite':
            c = self.ev(e[1], depth + 1)
            if c is None: return None
            return self.ev(e[2] if c else e[3], depth + 1)
        if k == 'call' and e[3] == 'nat':
            name = e[1]
            vals = [self.ev(x, depth + 1) for x in e[2]]
            if any(v is None for v in vals): return None
            try:
                if name in FLOATOPS and len(vals) == 2:
                    fa, fb = i2f(vals[0]), i2f(vals[1])
                    r = {'FloatAdd': fa + fb, 'FloatSub': fa - fb, 'FloatMul': fa * fb,
                         'FloatDiv': fa / fb if fb else None}[name]
                    return f2i(r) if r is not None else None
                if name == 'float': return f2i(float(vals[0]))
                if name == 'FloatCompare':
                    fa, fb = i2f(vals[0]), i2f(vals[1])
                    return (fa > fb) - (fa < fb)
                if name == 'FloatAbs': return f2i(abs(i2f(vals[0])))
                if name in ('RoundToZero', 'RoundFloat'): return int(i2f(vals[0]))
                if name == 'RoundToNearest': return int(round(i2f(vals[0])))
                if name == 'RoundToFloor': return int(math.floor(i2f(vals[0])))
                if name == 'RoundToCeil': return int(math.ceil(i2f(vals[0])))
                if name == 'SquareRoot': return f2i(math.sqrt(i2f(vals[0])))
            except Exception:
                return None
        return None

    def fold(self, e):
        """fold composite constant subexpressions"""
        if not isinstance(e, tuple):
            return e
        k = e[0]
        if k == 'bin' and e[1] in ('+', 'idx'):
            pa = self.parse_addr(e)
            if pa and pa[1]:
                return self.fold_addr(e)
        if k in ('bin', 'un', 'call', 'ite') and not (k == 'bin' and e[1] == 'idx'):
            if k != 'call' or e[3] == 'nat':
                v = self.ev(e)
                if v is not None:
                    return ('c', v)
        if k == 'call':
            return ('call', e[1], [self.fold(x) for x in e[2]], e[3])
        if k in ('ld', 'ldb'):
            # never fold the address itself; fold index expressions inside it
            return (k, self.fold_addr(e[1])) + tuple(e[2:])
        return tuple(self.fold(x) if isinstance(x, tuple) else x for x in e)

    def fold_addr(self, a):
        if not isinstance(a, tuple):
            return a
        if a[0] == 'bin' and a[1] == 'idx':
            return ('bin', 'idx', self.fold_addr(a[2]), self.fold(a[3]))
        if a[0] == 'bin' and a[1] == '+':
            x, y = a[2], a[3]
            if y[0] == 'ld' and y[1] == x:
                fx = self.fold_addr(x)
                return ('bin', '+', fx, ('ld', fx))
            if x[0] == 'ld' and x[1] == y:
                fy = self.fold_addr(y)
                return ('bin', '+', ('ld', fy), fy)
            return ('bin', '+', self.fold_addr(x), self.fold(y) if y[0] != 'ld' else self.fold_addr_ld(y))
        if a[0] == 'ld':
            return self.fold_addr_ld(a)
        return a

    def fold_addr_ld(self, a):
        return ('ld', self.fold_addr(a[1]))

    # ---------------- printing ----------------
    def fmt_addr(self, e, deref=True):
        pa = self.parse_addr(e)
        if pa:
            name, ix = pa
            s = self.gn(int(name[1:], 16)) if name.startswith('g') else name
            for j, i in enumerate(ix):
                if i == 'ROW':
                    s += '[0]'
                else:
                    s += '[%s]' % self.fmt(i)
            if not deref:
                return '&' + s
            if name.startswith('g') and all(i == 'ROW' or self.ev(i) is not None for i in ix):
                b = int(name[1:], 16)
                a = self.ev_addr(e) if ix else b
                v = self.ctx.cell(a) if a is not None else None
                if v and (self.ctx.is_const_base(b) or not ix):
                    fl = nice_float(v)
                    return '%s{=%s}' % (s, fl if fl else v)
            return s
        return ('*(%s)' if deref else '%s') % self.fmt(e)

    def fmt(self, e, strok=False):
        e = self.fold(e)
        k = e[0]
        if strok and k in ('bin',) and e[1] in ('+', 'idx'):
            pa = self.parse_addr(e)
            if pa and pa[0].startswith('g') and all(i == 'ROW' or self.ev(i) is not None for i in pa[1]):
                A = self.ev_addr(e)
                st = self.ctx.string_at(A) if A is not None else None
                if st is not None:
                    return '"%s"' % st.replace('\n', '\\n')[:90]
        if k == 'c':
            v = e[1]
            fl = nice_float(v)
            if fl:
                return fl
            st = self.ctx.string_at(v) if (v > 64 and strok is True) else None
            if st is not None and len(st) >= 1:
                return '"%s"' % st.replace('\n', '\\n')[:90]
            return str(v) if abs(v) < 4096 else hex(v & 0xffffffff) if v > 0 else '-' + hex(-v)
        if k == 'frm':
            return '&' + self.name_frm(e[1])
        if k == 'arg':
            return 'a%d' % e[1]
        if k == 'ld':
            if e[1][0] == 'frm':
                return self.name_frm(e[1][1])
            return self.fmt_addr(e[1])
        if k == 'ldb':
            return 'byte(%s)' % self.fmt_addr(e[1], deref=False)
        if k == 't':
            self.used_temps.add(e[1])
            return 't%d' % e[1]
        if k == 'reg':
            return e[1]
        if k == 'ite':
            return '(%s ? %s : %s)' % (self.fmt(e[1]), self.fmt(e[2]), self.fmt(e[3]))
        if k == 'un':
            if e[1] == '!':
                return '!%s' % self.fmt(e[2])
            return '%s%s' % (e[1], self.fmt(e[2]))
        if k == 'bin':
            op = e[1]
            if op == 'idx':
                return self.fmt_addr(e, deref=False)
            if op == '+':
                pa = self.parse_addr(e)
                if pa and pa[1]:
                    return self.fmt_addr(e, deref=False)
            return '(%s %s %s)' % (self.fmt(e[2]), op, self.fmt(e[3]))
        if k == 'call':
            name, args = e[1], e[2]
            fa = [self.fmt(a, strok=(True if e[3] == 'nat' else 'addr')) for a in args]
            if name in FLOATOPS and len(fa) == 2:
                return '(%s %s %s)' % (fa[0], FLOATOPS[name], fa[1])
            return '%s(%s)' % (name, ', '.join(fa))
        return str(e)

    # ---------------- simplification ----------------
    def simp(self, e):
        if e[0] == 'bin':
            op, a, b = e[1], e[2], e[3]
            if op == '+' and a[0] == 'c' and b[0] == 'c':
                return ('c', s32(a[1] + b[1]))
            if op == '*' and b == ('c', 1):
                return a
            if op in NEGCMP:
                if a[0] == 'call' and a[1] == 'FloatCompare' and b == ('c', 0):
                    return ('bin', op + '.', a[2][0], a[2][1])
                if b[0] == 'call' and b[1] == 'FloatCompare' and a == ('c', 0):
                    return ('bin', SWAPCMP[op] + '.', b[2][0], b[2][1])
        return e

    def neg(self, c):
        if c[0] == 'bin':
            op = c[1]
            base = op.rstrip('.')
            if base in NEGCMP and (op == base or op == base + '.'):
                if op.endswith('.'):
                    return ('un', '!', c)      # NaN-safe: keep explicit negation for floats
                return ('bin', NEGCMP[base], c[2], c[3])
            if op == '&&':
                return ('bin', '||', self.neg(c[2]), self.neg(c[3]))
            if op == '||':
                return ('bin', '&&', self.neg(c[2]), self.neg(c[3]))
        if c[0] == 'un' and c[1] == '!':
            return c[2]
        if c[0] == 'c':
            return ('c', int(c[1] == 0))
        return ('un', '!', c)

    def truth(self, e):
        """expression used as boolean"""
        if e[0] == 'bin' and (e[1].rstrip('.') in NEGCMP or e[1] in ('&&', '||')):
            return e
        if e[0] == 'un' and e[1] == '!':
            return e
        return e

    # ---------------- emission pass ----------------
    def emit_pass(self):
        p = self.p
        ins = []
        for x in p.ins[p.idx[self.a0]:]:
            if x[0] >= self.e: break
            ins.append(x)
        targets = set()
        for ad, n, prm in ins:
            if n in JUMPS: targets.add(prm[0])
            if n == 'SWITCH': targets.add(prm[0])
            if n == 'CASETBL':
                targets.add(prm[1])
                for i in range(prm[0]): targets.add(prm[3 + 2 * i])
        self.targets = targets
        out = []
        pri = ('reg', 'pri'); alt = ('reg', 'alt'); stk = []
        self.tn = 0
        dead = False
        def emit(ad, s):
            out.append([ad, s])
        def push(x): stk.append(x)
        def pop(): return stk.pop() if stk else ('reg', 'stk')
        def temp(e, ad):
            self.tn += 1
            emit(ad, ('assign_t', self.tn, e))
            return ('t', self.tn)
        def ld(a): return ('ld', a)
        def store(ad, a, v): emit(ad, ('store', a, v))
        for ad, n, prm in ins:
            if ad in targets:
                emit(ad, ('label', ad, None if dead else pri))
                pri = self.label_pri.get(ad, ('reg', 'pri'))
                alt = ('reg', 'alt')
                dead = False
            if n in ('BREAK', 'PROC', 'BOUNDS', 'TRACKER_POP_SETHEAP'):
                continue
            if n == 'STRADJUST_PRI': pri = ('un', 'stradj', pri); continue
            if n == 'LOAD_PRI': pri = ld(('c', prm[0]))
            elif n == 'LOAD_ALT': alt = ld(('c', prm[0]))
            elif n == 'LOAD_BOTH': pri = ld(('c', prm[0])); alt = ld(('c', prm[1]))
            elif n == 'LOAD_S_PRI': pri = ld(('frm', prm[0]))
            elif n == 'LOAD_S_ALT': alt = ld(('frm', prm[0]))
            elif n == 'LOAD_S_BOTH': pri = ld(('frm', prm[0])); alt = ld(('frm', prm[1]))
            elif n == 'LREF_S_PRI': pri = ld(ld(('frm', prm[0])))
            elif n == 'LOAD_I': pri = ld(pri)
            elif n == 'LODB_I': pri = ('ldb', pri, prm[0])
            elif n == 'CONST_PRI': pri = ('c', prm[0])
            elif n == 'CONST_ALT': alt = ('c', prm[0])
            elif n == 'ADDR_PRI': pri = ('frm', prm[0])
            elif n == 'ADDR_ALT': alt = ('frm', prm[0])
            elif n == 'STOR_PRI': store(ad, ('c', prm[0]), pri)
            elif n == 'STOR_S_PRI': store(ad, ('frm', prm[0]), pri)
            elif n == 'SREF_S_PRI': store(ad, ld(('frm', prm[0])), pri)
            elif n == 'STOR_I': store(ad, alt, pri)
            elif n == 'STRB_I': emit(ad, ('storeb', alt, pri, prm[0]))
            elif n == 'CONST': store(ad, ('c', prm[0]), ('c', prm[1]))
            elif n == 'CONST_S': store(ad, ('frm', prm[0]), ('c', prm[1]))
            elif n == 'ZERO': store(ad, ('c', prm[0]), ('c', 0))
            elif n == 'ZERO_S': store(ad, ('frm', prm[0]), ('c', 0))
            elif n == 'ZERO_PRI': pri = ('c', 0)
            elif n == 'ZERO_ALT': alt = ('c', 0)
            elif n == 'MOVE_PRI': pri = alt
            elif n == 'MOVE_ALT': alt = pri
            elif n == 'XCHG': pri, alt = alt, pri
            elif n == 'SWAP_PRI': t = pop(); push(pri); pri = t
            elif n == 'SWAP_ALT': t = pop(); push(alt); alt = t
            elif n == 'PUSH_PRI': push(pri)
            elif n == 'PUSH_ALT': push(alt)
            elif n == 'POP_PRI': pri = pop()
            elif n == 'POP_ALT': alt = pop()
            elif n in ('PUSH_C', 'PUSH2_C', 'PUSH3_C', 'PUSH4_C', 'PUSH5_C'):
                for v in prm: push(('c', v))
            elif n in ('PUSH', 'PUSH2', 'PUSH3', 'PUSH4', 'PUSH5'):
                for v in prm: push(ld(('c', v)))
            elif n in ('PUSH_S', 'PUSH2_S', 'PUSH3_S', 'PUSH4_S', 'PUSH5_S'):
                for v in prm: push(ld(('frm', v)))
            elif n in ('PUSH_ADR', 'PUSH2_ADR', 'PUSH3_ADR', 'PUSH4_ADR', 'PUSH5_ADR'):
                for v in prm: push(('frm', v))
            elif n == 'STACK':
                k = prm[0] // 4
                if k < 0:
                    for _ in range(-k): push(('reg', 'slot'))
                else:
                    for _ in range(k): pop()
            elif n == 'HEAP': alt = ('reg', 'heap')
            elif n == 'ADD': pri = self.simp(('bin', '+', pri, alt))
            elif n == 'ADD_C': pri = self.simp(('bin', '+', pri, ('c', prm[0])))
            elif n == 'SUB_ALT': pri = ('bin', '-', alt, pri)
            elif n == 'SMUL': pri = self.simp(('bin', '*', pri, alt))
            elif n == 'SMUL_C': pri = self.simp(('bin', '*', pri, ('c', prm[0])))
            elif n == 'SDIV_ALT': pri, alt = ('bin', '/', alt, pri), ('bin', '%', alt, pri)
            elif n == 'AND': pri = ('bin', '&', pri, alt)
            elif n == 'OR': pri = ('bin', '|', pri, alt)
            elif n == 'XOR': pri = ('bin', '^', pri, alt)
            elif n == 'SHL': pri = ('bin', '<<', pri, alt)
            elif n == 'SHR': pri = ('bin', '>>>', pri, alt)
            elif n == 'SSHR': pri = ('bin', '>>', pri, alt)
            elif n == 'NEG': pri = ('un', '-', pri)
            elif n == 'INVERT': pri = ('un', '~', pri)
            elif n == 'NOT': pri = self.neg(pri)
            elif n == 'EQ': pri = self.simp(('bin', '==', pri, alt))
            elif n == 'NEQ': pri = self.simp(('bin', '!=', pri, alt))
            elif n == 'SLESS': pri = self.simp(('bin', '<', pri, alt))
            elif n == 'SLEQ': pri = self.simp(('bin', '<=', pri, alt))
            elif n == 'SGRTR': pri = self.simp(('bin', '>', pri, alt))
            elif n == 'SGEQ': pri = self.simp(('bin', '>=', pri, alt))
            elif n == 'EQ_C_PRI': pri = ('bin', '==', pri, ('c', prm[0]))
            elif n == 'IDXADDR': pri = ('bin', 'idx', alt, pri)
            elif n == 'LIDX': pri = ld(('bin', 'idx', alt, pri))
            elif n == 'INC': emit(ad, ('inc', ('c', prm[0]), '++'))
            elif n == 'DEC': emit(ad, ('inc', ('c', prm[0]), '--'))
            elif n == 'INC_S': emit(ad, ('inc', ('frm', prm[0]), '++'))
            elif n == 'DEC_S': emit(ad, ('inc', ('frm', prm[0]), '--'))
            elif n == 'INC_I': emit(ad, ('inc', pri, '++'))
            elif n == 'DEC_I': emit(ad, ('inc', pri, '--'))
            elif n == 'INC_PRI': pri = ('bin', '+', pri, ('c', 1))
            elif n == 'DEC_PRI': pri = ('bin', '+', pri, ('c', -1))
            elif n == 'INC_ALT': alt = ('bin', '+', alt, ('c', 1))
            elif n == 'DEC_ALT': alt = ('bin', '+', alt, ('c', -1))
            elif n == 'MOVS': emit(ad, ('movs', alt, pri, prm[0]))
            elif n == 'FILL': emit(ad, ('fill', alt, pri, prm[0]))
            elif n == 'GENARRAY':
                for _ in range(prm[0]): pop()
                push(('reg', 'newarray'))
            elif n == 'SYSREQ_N':
                name = p.nat[prm[0]]
                args = [pop() for _ in range(prm[1])]
                e = ('call', name, args, 'nat')
                pri = e if PURE.match(name) else temp(e, ad)
            elif n == 'CALL':
                f = prm[0]
                cnt = pop()
                na = cnt[1] if cnt[0] == 'c' else 0
                args = [pop() for _ in range(na)]
                s = self.ctx.summary(f) if self.ctx.inline else None
                if s is not None:
                    pri = self.simp(subst(s, args))
                else:
                    pri = temp(('call', p.pubs.get(f, 'fn_%x' % f), args, 'fn'), ad)
            elif n == 'SWITCH':
                emit(ad, ('switch', pri, prm[0])); dead = True
            elif n == 'CASETBL':
                emit(ad, ('casetbl', prm))
            elif n == 'JUMP':
                emit(ad, ('goto', prm[0], pri)); dead = True
            elif n == 'JZER':
                emit(ad, ('if', self.neg(pri), prm[0], pri))
            elif n == 'JNZ':
                emit(ad, ('if', pri, prm[0], pri))
            elif n in CMP:
                emit(ad, ('if', self.simp(('bin', CMP[n], pri, alt)), prm[0], pri))
            elif n == 'RETN':
                emit(ad, ('return', pri)); dead = True
            elif n == 'HALT':
                emit(ad, ('halt', prm[0] if prm else 0)); dead = True
            else:
                emit(ad, ('raw', '%s %s' % (n, prm)))
        return out

    # ---------------- boolean join reconstruction ----------------
    def compute_label_pri(self, out):
        lab = {}
        for i, (ad, s) in enumerate(out):
            if s[0] == 'label':
                lab[s[1]] = i
        incoming = collections.defaultdict(list)   # label -> [(src_idx, pri)]
        for i, (ad, s) in enumerate(out):
            if s[0] == 'goto':
                incoming[s[1]].append((i, s[2]))
            elif s[0] == 'if':
                incoming[s[2]].append((i, s[3]))
            elif s[0] == 'label' and s[2] is not None:
                incoming[s[1]].append((i - 1, s[2]))
            elif s[0] in ('switch',):
                pass
        res = {}
        for L, i_L in lab.items():
            edges = incoming.get(L, [])
            if not edges:
                continue
            vals = [v for _, v in edges]
            if all(v == vals[0] for v in vals):
                if vals[0] != ('reg', 'pri') and not has_reg(vals[0]):
                    res[L] = vals[0]
                continue
            # boolean region: try the closest valid start first
            lo = i_L - 1
            while lo >= 0 and out[lo][1][0] in ('if', 'goto', 'label', 'assign_t'):
                lo -= 1
            lo += 1
            for S in range(i_L - 1, max(lo, i_L - 60) - 1, -1):
                if self.budget <= 0:
                    break
                if not self.region_ok(out, incoming, S, i_L):
                    continue
                v = self.eval_region(out, lab, S, i_L, L)
                if v is not None and not has_reg(v):
                    res[L] = v
                    break
        return res

    def region_ok(self, out, incoming, S, i_L):
        for j in range(S, i_L + 1):
            st = out[j][1]
            if st[0] != 'label':
                continue
            for src, _ in incoming.get(st[1], []):
                if S <= src < i_L:
                    continue
                if j == S:
                    continue        # entry of the region
                return False
        return True

    def eval_region(self, out, lab, S, i_L, L):
        steps = [0]
        def edge_into_L_fall(cur):
            v = out[i_L][1][2]
            return subst_pri(v, cur) if v is not None else cur
        def B(n, cur):
            steps[0] += 1
            self.budget -= 1
            if steps[0] > 4000 or self.budget <= 0:
                raise RecursionError
            s = out[n][1]
            k = s[0]
            if k == 'label':
                if n + 1 == i_L:
                    return edge_into_L_fall(cur)
                return B(n + 1, cur)
            if k == 'assign_t':
                if n + 1 == i_L:
                    return edge_into_L_fall(cur)
                return B(n + 1, cur)
            if k == 'goto':
                v = subst_pri(s[2], cur)
                if s[1] == L:
                    return v
                if s[1] not in lab or not (S <= lab[s[1]] < i_L):
                    raise ValueError
                return B(lab[s[1]], v)
            if k == 'if':
                C = subst_pri(s[1], cur)
                vt = subst_pri(s[3], cur)
                if s[2] == L:
                    taken = vt
                else:
                    if s[2] not in lab or not (S <= lab[s[2]] < i_L):
                        raise ValueError
                    taken = B(lab[s[2]], vt)
                fall = edge_into_L_fall(cur) if n + 1 == i_L else B(n + 1, cur)
                return self.mk_ite(C, taken, fall)
            raise ValueError
        try:
            return B(S, ('reg', 'pri'))
        except (ValueError, RecursionError, IndexError):
            return None

    def mk_ite(self, C, x, y):
        # FloatAbs idiom: !(X >=. 0) ? (X ^ 0x80000000) : X
        if x[0] == 'bin' and x[1] == '^' and x[3] == ('c', -0x80000000) and x[2] == y:
            return ('call', 'FloatAbs', [y], 'nat')
        if y[0] == 'bin' and y[1] == '^' and y[3] == ('c', -0x80000000) and y[2] == x:
            return ('call', 'FloatAbs', [x], 'nat')
        cv = self.ev(C)
        if cv is not None:
            return x if cv else y
        if x == y:
            return x
        if x[0] == 'c' and y[0] == 'c':
            xv, yv = x[1] != 0, y[1] != 0
            if xv and not yv: return self.truth(C)
            if not xv and yv: return self.neg(C)
            if xv and yv: return ('c', 1)
            return ('c', 0)
        if x[0] == 'c':
            return ('bin', '||', C, y) if x[1] else ('bin', '&&', self.neg(C), y)
        if y[0] == 'c':
            return ('bin', '&&', C, x) if not y[1] else ('bin', '||', self.neg(C), x)
        return ('ite', C, x, y)

    # ---------------- driver ----------------
    def run(self):
        out = self.emit_pass()
        for _ in range(6):
            lp = self.compute_label_pri(out)
            if lp == self.label_pri:
                break
            self.label_pri = lp
            out = self.emit_pass()
        self.lines = out
        return out

    def finish(self):
        """dead-code elimination using folded conditions; single-return summary"""
        out = self.lines
        lab = {s[1]: i for i, (ad, s) in enumerate(out) if s[0] == 'label'}
        n = len(out)
        succ = {}
        for i, (ad, s) in enumerate(out):
            k = s[0]
            nx = [i + 1] if i + 1 < n else []
            if k == 'goto':
                succ[i] = [lab[s[1]]] if s[1] in lab else []
            elif k == 'if':
                v = self.ev(s[1])
                t = [lab[s[2]]] if s[2] in lab else []
                if v is None: succ[i] = nx + t
                elif v: succ[i] = t; s_new = ('goto', s[2], s[3]); out[i][1] = s_new
                else: succ[i] = nx; out[i][1] = ('nop',)
            elif k == 'switch':
                succ[i] = [lab[s[2]]] if s[2] in lab else []
                ct = None
                if s[2] in lab and lab[s[2]] + 1 < n and out[lab[s[2]] + 1][1][0] == 'casetbl':
                    ct = out[lab[s[2]] + 1][1][1]
                if ct:
                    v = self.ev(s[1])
                    tg = [ct[1]] + [ct[3 + 2 * j] for j in range(ct[0])]
                    if v is not None:
                        hit = ct[1]
                        for j in range(ct[0]):
                            if ct[2 + 2 * j] == v: hit = ct[3 + 2 * j]
                        tg = [hit]
                    succ[i] = [lab[t] for t in tg if t in lab]
            elif k in ('return', 'halt'):
                succ[i] = []
            elif k == 'casetbl':
                succ[i] = []
            else:
                succ[i] = nx
        seen = set(); st = [0]
        while st:
            x = st.pop()
            if x in seen or x >= n: continue
            seen.add(x); st.extend(succ.get(x, []))
        live = [out[i] for i in range(n) if i in seen and out[i][1][0] != 'nop']
        # drop goto to immediately following label, drop unreferenced labels
        changed = True
        while changed:
            changed = False
            refs = collections.Counter()
            for ad, s in live:
                if s[0] in ('goto',): refs[s[1]] += 1
                if s[0] == 'if': refs[s[2]] += 1
                if s[0] == 'switch': refs[s[2]] += 1
                if s[0] == 'casetbl':
                    refs[s[1][1]] += 1
                    for j in range(s[1][0]): refs[s[1][3 + 2 * j]] += 1
            nl = []
            for j, (ad, s) in enumerate(live):
                if s[0] == 'label' and refs[s[1]] == 0:
                    changed = True; continue
                if s[0] == 'if':
                    k2 = j + 1
                    while k2 < len(live) and live[k2][1][0] == 'label' and live[k2][1][1] != s[2]:
                        k2 += 1
                    if k2 < len(live) and live[k2][1][0] == 'label' and live[k2][1][1] == s[2] and all(live[m][1][0] == 'label' for m in range(j + 1, k2)) and not self.has_side(s[1]):
                        changed = True; continue
                if s[0] == 'goto':
                    k2 = j + 1
                    while k2 < len(live) and live[k2][1][0] == 'label' and live[k2][1][1] != s[1]:
                        k2 += 1
                    if k2 < len(live) and live[k2][1][0] == 'label' and live[k2][1][1] == s[1] and all(live[m][1][0] == 'label' for m in range(j + 1, k2)):
                        changed = True; continue
                nl.append((ad, s))
            live = nl
        self.live = live
        if self.nested:
            stmts = [s for (_, s) in live if s[0] != 'label']
            if len(stmts) == 1 and stmts[0][0] == 'return':
                self.single_return = self.to_args(stmts[0][1])
        return live

    def has_side(self, e):
        if not isinstance(e, tuple): return False
        if e[0] == 't': return True
        if e[0] == 'call': return not PURE.match(e[1]) or any(self.has_side(x) for x in e[2])
        return any(self.has_side(x) for x in e if isinstance(x, tuple))

    def to_args(self, e):
        if not isinstance(e, tuple):
            return e
        if e[0] == 'ld' and e[1][0] == 'frm' and e[1][1] >= 0xc:
            return ('arg', (e[1][1] - 0xc) // 4)
        if e[0] == 'frm':
            raise ValueError('address')
        if e[0] in ('reg', 't'):
            raise ValueError('nonpure')
        if e[0] == 'call':
            if e[3] == 'fn':
                raise ValueError('call')
            return ('call', e[1], [self.to_args(x) for x in e[2]], e[3])
        return tuple(self.to_args(x) if isinstance(x, tuple) else x for x in e)

    def stmt(self, s):
        k = s[0]
        if k == 'assign_t':
            return 't%d = %s;' % (s[1], self.fmt(s[2]))
        if k == 'store':
            return '%s = %s;' % (self.fmt_addr(s[1]).split('{=')[0], self.fmt(s[2]))
        if k == 'storeb':
            return 'byte(%s) = %s;' % (self.fmt_addr(s[1], deref=False), self.fmt(s[2]))
        if k == 'inc':
            return '%s%s;' % (self.fmt_addr(s[1]).split('{=')[0], s[2])
        if k == 'movs':
            return 'memcpy(%s, %s, %d);' % (self.fmt_addr(s[1], False), self.fmt_addr(s[2], False), s[3])
        if k == 'fill':
            return 'memset(%s, %s, %d);' % (self.fmt_addr(s[1], False), self.fmt(s[2]), s[3])
        if k == 'goto':
            return 'goto L%x;' % s[1]
        if k == 'if':
            return 'if (%s) goto L%x;' % (self.fmt(s[1]), s[2])
        if k == 'switch':
            return 'switch (%s) -> L%x' % (self.fmt(s[1]), s[2])
        if k == 'casetbl':
            prm = s[1]
            cs = ', '.join('%d: L%x' % (prm[2 + 2 * i], prm[3 + 2 * i]) for i in range(prm[0]))
            return 'casetbl { %s; default: L%x }' % (cs, prm[1])
        if k == 'return':
            return 'return %s;' % self.fmt(s[1])
        if k == 'halt':
            return 'halt %s;' % s[1]
        if k == 'raw':
            return '/* %s */' % s[1]
        return str(s)

    def render(self, raw=False):
        lines = self.lines if raw else self.live
        texts = []
        for ad, s in lines:
            if s[0] == 'label':
                texts.append(('L', 'L%x:' % s[1]))
            else:
                texts.append((s, '  %06x  ' % ad + self.stmt(s)))
        out = []
        for s, t in texts:
            if s != 'L' and s[0] == 'assign_t' and s[1] not in self.used_temps:
                t = t.split('t%d = ' % s[1], 1)
                t = t[0] + t[1]
            out.append(t)
        return '\n'.join(out)

def resolve(p, arg):
    pubs = {n: a for a, n in p.s.publics()}
    if arg in pubs:
        return pubs[arg]
    return int(arg, 16)

def make_ctx(path, base=None, wr=None, inline=True):
    p = P(path)
    b = pickle.load(open(base, 'rb')) if base else None
    w = pickle.load(open(wr, 'rb')) if wr else None
    c = Ctx(p, b, inline, w)
    return c

if __name__ == '__main__':
    a = sys.argv
    path = a[1]; fn = a[2]
    base = a[a.index('--base') + 1] if '--base' in a else None
    wr = a[a.index('--wr') + 1] if '--wr' in a else None
    ctx = make_ctx(path, base, wr, '--noinline' not in a)
    if '--names' in a:
        for ln in open(a[a.index('--names') + 1]):
            ln = ln.split('#')[0].split()
            if len(ln) >= 2: ctx.names[int(ln[0], 16)] = ln[1]
    f = resolve(ctx.p, fn)
    d = Decomp(ctx, f)
    d.run(); d.finish()
    print('// %s @%x' % (ctx.p.pubs.get(f, 'fn_%x' % f), f))
    print(d.render(raw='--raw' in a))
