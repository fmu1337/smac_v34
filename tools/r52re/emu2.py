import struct, sys, math, re
sys.path.insert(0,'.')
from sym import *
class Kill(Exception): pass
FMT_RE = re.compile(r'%([-+ 0#]*)(\d*)(?:\.(\d+))?([dibufscxXtTNL%])')
FLOATNAT = {'FloatAdd':'fadd','FloatSub':'fsub','FloatMul':'fmul','FloatDiv':'fdiv'}
OUTP = {
 'GetClientEyePosition':[2], 'GetClientAbsOrigin':[2], 'GetClientAbsAngles':[2], 'GetClientEyeAngles':[2],
 'GetEntPropVector':[4], 'GetAngleVectors':[2,3,4], 'GetVectorAngles':[2], 'NormalizeVector':[2],
 'GetClientName':[2], 'GetClientAuthString':[2], 'GetClientIP':[2], 'GetEventString':[3], 'GetConVarString':[2],
 'GetClientWeapon':[2], 'GetClientModel':[2], 'TR_GetEndPosition':[1], 'GetClientMins':[2], 'GetCurrentMap':[1],
 'GetCmdArgString':[1], 'GetCmdArg':[2], 'GetEntDataVector':[3], 'ReadPackString':[2], 'GetArrayArray':[3],
 'GetArrayString':[3], 'GetTrieValue':[3], 'GetPluginFilename':[2], 'GetEntityNetClass':[2], 'ReadFileLine':[2],
 'GetClientMaxs':[2], 'GetCmdStr':[2], 'GetGameDescription':[1], 'GetConVarName':[2], 'GetConVarDefault':[2],
 'FormatTime':[1], 'ReadFileString':[2], 'GameConfGetKeyValue':[3], 'GetEdictClassname':[2], 'GetEntityClassname':[2],
 'SubtractVectors':[3], 'AddVectors':[3], 'MakeVectorFromPoints':[3], 'ScaleVector':[1], 'GetEventFloat':[],
}
STRNAT_OUT = {'GetClientName','GetClientAuthString','GetClientIP','GetEventString','GetConVarString','GetClientWeapon','GetClientModel','GetCurrentMap','GetCmdArgString','GetCmdArg','ReadPackString','GetArrayString','GetPluginFilename','GetEntityNetClass','ReadFileLine','GetCmdStr','GetGameDescription','GetConVarName','GetConVarDefault','FormatTime','ReadFileString','GameConfGetKeyValue','GetEdictClassname','GetEntityClassname'}

class Emu2:
    MAX_STEPS = 2000000
    MAX_PATHS = 3000
    def __init__(self, prog, base_mem, maxclients=2):
        self.p = prog; self.ins = prog.ins; self.idx = prog.idx; self.nat = prog.nat
        self.datasize = len(prog.data); self.memsize = prog.mem
        self.base = bytearray(base_mem)
        mc = dict((n,a) for a,n in prog.s.pubvars()).get('MaxClients')
        if mc is not None: struct.pack_into('<i', self.base, mc, maxclients)
        self.mc_addr = mc
        self.const_globals = set()
        self.recording = True
        self.trace = None
        self.log_conc = False
        self.sym_all_globals = False
        self.boot_written = set()
        self.concrete_mode = False
        self.prune = None
        self.watch = None
        self.reached = False
        self.hybrid = False
        self.client_cells = set()
        self.client_state = set()
        self.cfg_written = set()
        self.covered = set()
        self.bcount = {}
    # ---- memory
    def reset(self):
        self.mem = bytearray(self.base); self.sym = {}; self.written = set(); self.undo = []
    def rd(self, a):
        if a < 0 or a + 4 > self.memsize: raise Kill('oob rd %x' % a)
        return struct.unpack_from('<i', self.mem, a)[0]
    def rds(self, a):
        """read (val, sym) with global-symbolization"""
        v = self.rd(a)
        s = self.sym.get(a)
        if s is None and not self.concrete_mode and a < self.datasize and a not in self.written and a != self.mc_addr and a not in self.const_globals:
            if self.hybrid:
                if a in self.client_state or a in self.client_cells or v == 0 or v == -1:
                    s = ('v', 'g%x' % a)
            elif v == 0:
                s = ('v', 'g%x' % a)
            elif self.sym_all_globals and a not in self.boot_written:
                s = ('v', 'g%x' % a)
        return v, s
    def wr(self, a, v, s=None):
        if a < 0 or a + 4 > self.memsize: raise Kill('oob wr %x' % a)
        self.undo.append((a, bytes(self.mem[a:a+4]), self.sym.get(a, 0), a in self.written))
        struct.pack_into('<i', self.mem, a, s32(v))
        if s is None: self.sym.pop(a, None)
        else: self.sym[a] = s
        self.written.add(a)
        if a < self.datasize and self.trace is not None and (s is not None) and self.recording:
            self.trace.append(('st', self.cip, a, s))
    def wrb(self, a, b):
        self.undo.append((a, bytes(self.mem[a:a+1]), 0, None))
        self.mem[a] = b & 0xff
    def rollback(self, n):
        while len(self.undo) > n:
            a, old, s, w = self.undo.pop()
            self.mem[a:a+len(old)] = old
            if w is None: continue
            if s == 0: self.sym.pop(a, None)
            else: self.sym[a] = s
            if w: self.written.add(a)
            else: self.written.discard(a)
    def cstr(self, a, maxn=2048):
        if a is None or a <= 0 or a >= self.memsize: return None
        e = self.mem.find(b'\0', a, a+maxn)
        if e < 0: return None
        return self.mem[a:e].decode('utf-8', 'replace')
    def wstr(self, a, s, maxlen):
        b = s.encode('utf-8')[:max(0, maxlen-1)] + b'\0'
        for i, c in enumerate(b): self.wrb(a+i, c)
        return len(b) - 1
    # ---- exploration
    def explore(self, entry, args, tag='', setup=None):
        self.reset()
        self.tag = tag; self.paths_out = []; self.covered = set()
        self.trace = None; self.recording = True
        stk = self.memsize; hea = self.datasize
        if setup: stk, hea = setup(self, stk, hea)
        for v, s in reversed(args):
            stk -= 4; self.wr(stk, v, s)
        stk -= 4; self.wr(stk, len(args)); stk -= 4; self.wr(stk, -1)
        work = [(entry, 0, None, 0, None, 0, stk, hea, len(self.undo), [])]
        n = 0
        while work and n < self.MAX_PATHS:
            st = work.pop(); n += 1
            self.trace = list(st[9])
            try:
                self.run_path(st, work)
                self.trace.append(('end',))
            except Kill as k:
                self.trace.append(('kill', str(k)))
            self.paths_out.append(self.trace)
        self.npaths = n; self.left = len(work)
    def branch(self, cip, cond, taken, work, alt_cip, here, state):
        """cond: symbolic boolean expression true when jump is taken. returns next cip"""
        bc = self.bcount.get(cip, 0) + 1; self.bcount[cip] = bc
        if bc > 300: raise Kill('loop@%x' % cip)
        dirs = [(taken, here), (not taken, alt_cip)]
        unc = [d for d in dirs if (cip, d[0]) not in self.covered]
        if bc > 30: unc = []
        if len(unc) == 2:
            self.covered.add((cip, unc[1][0]))
            tr = list(self.trace); tr.append(('br', cip, cond, unc[1][0]))
            work.append((unc[1][1],) + state + (len(self.undo), tr))
            self.covered.add((cip, unc[0][0]))
            self.trace.append(('br', cip, cond, unc[0][0]))
            return unc[0][1]
        if len(unc) == 1:
            self.covered.add((cip, unc[0][0]))
            self.trace.append(('br', cip, cond, unc[0][0]))
            return unc[0][1]
        self.trace.append(('br', cip, cond, taken))
        return here
    def run_path(self, st, work):
        cip, pri, ps, alt, as_, frm, stk, hea, ul, _tr = st
        self.rollback(ul)
        self.reached = any(ev[0] == 'hit' for ev in self.trace)
        ins = self.ins; idx = self.idx
        rd = self.rd; rds = self.rds; wr = self.wr
        self.bcount = {}
        steps = 0
        while True:
            steps += 1
            if steps > self.MAX_STEPS: raise Kill('steps')
            i = idx.get(cip)
            if i is None: raise Kill('badcip %x' % cip)
            a, n, prm = ins[i]
            nxt = ins[i+1][0] if i+1 < len(ins) else -1
            self.cip = cip
            if self.watch is not None and cip in self.watch: self.on_watch(cip)
            if n == 'BREAK' or n == 'NOP': cip = nxt; continue
            if n == 'LOAD_PRI': pri, ps = rds(prm[0])
            elif n == 'LOAD_ALT': alt, as_ = rds(prm[0])
            elif n == 'LOAD_S_PRI': pri, ps = rds(frm+prm[0])
            elif n == 'LOAD_S_ALT': alt, as_ = rds(frm+prm[0])
            elif n == 'LOAD_BOTH': pri, ps = rds(prm[0]); alt, as_ = rds(prm[1])
            elif n == 'LOAD_S_BOTH': pri, ps = rds(frm+prm[0]); alt, as_ = rds(frm+prm[1])
            elif n == 'LREF_S_PRI': pri, ps = rds(rd(frm+prm[0]))
            elif n == 'LREF_S_ALT': alt, as_ = rds(rd(frm+prm[0]))
            elif n == 'LOAD_I':
                ad = pri; v, s = rds(ad)
                if s is None and ps is not None: s = ('mem', 'M', ps)
                pri, ps = v, s
            elif n == 'LODB_I':
                ad = pri; sz = prm[0]
                if sz == 1: pri = self.mem[ad]
                elif sz == 2: pri = struct.unpack_from('<H', self.mem, ad)[0]
                else: pri = rd(ad)
                ps = self.sym.get(ad & ~3)
            elif n == 'CONST_PRI': pri = prm[0]; ps = None
            elif n == 'CONST_ALT': alt = prm[0]; as_ = None
            elif n == 'ADDR_PRI': pri = frm+prm[0]; ps = None
            elif n == 'ADDR_ALT': alt = frm+prm[0]; as_ = None
            elif n == 'STOR_PRI': wr(prm[0], pri, ps)
            elif n == 'STOR_ALT': wr(prm[0], alt, as_)
            elif n == 'STOR_S_PRI': wr(frm+prm[0], pri, ps)
            elif n == 'STOR_S_ALT': wr(frm+prm[0], alt, as_)
            elif n == 'SREF_S_PRI': wr(rd(frm+prm[0]), pri, ps)
            elif n == 'SREF_S_ALT': wr(rd(frm+prm[0]), alt, as_)
            elif n == 'STOR_I': wr(alt, pri, ps)
            elif n == 'STRB_I':
                sz = prm[0]
                if sz == 1: self.wrb(alt, pri)
                elif sz == 2: self.wrb(alt, pri); self.wrb(alt+1, pri >> 8)
                else: wr(alt, pri, ps)
            elif n == 'LIDX':
                ad = alt + pri*4; v, s = rds(ad)
                if s is None and ps is not None: s = ('mem', 'A', ps)
                pri, ps = v, s
            elif n == 'IDXADDR': pri = alt + pri*4; ps = None
            elif n == 'MOVE_PRI': pri, ps = alt, as_
            elif n == 'MOVE_ALT': alt, as_ = pri, ps
            elif n == 'XCHG': pri, alt = alt, pri; ps, as_ = as_, ps
            elif n == 'PUSH_PRI': stk -= 4; wr(stk, pri, ps)
            elif n == 'PUSH_ALT': stk -= 4; wr(stk, alt, as_)
            elif n in ('PUSH_C','PUSH2_C','PUSH3_C','PUSH4_C','PUSH5_C'):
                for v in prm: stk -= 4; wr(stk, v)
            elif n in ('PUSH','PUSH2','PUSH3','PUSH4','PUSH5'):
                for v in prm:
                    vv, ss = rds(v); stk -= 4; wr(stk, vv, ss)
            elif n in ('PUSH_S','PUSH2_S','PUSH3_S','PUSH4_S','PUSH5_S'):
                for v in prm:
                    vv, ss = rds(frm+v); stk -= 4; wr(stk, vv, ss)
            elif n in ('PUSH_ADR','PUSH2_ADR','PUSH3_ADR','PUSH4_ADR','PUSH5_ADR'):
                for v in prm: stk -= 4; wr(stk, frm+v)
            elif n == 'POP_PRI': pri, ps = rd(stk), self.sym.get(stk); stk += 4
            elif n == 'POP_ALT': alt, as_ = rd(stk), self.sym.get(stk); stk += 4
            elif n == 'STACK': stk += prm[0]; alt = stk; as_ = None
            elif n == 'HEAP': alt = hea; as_ = None; hea += prm[0]
            elif n == 'PROC': stk -= 4; wr(stk, frm); frm = stk
            elif n == 'RETN':
                frm = rd(stk); stk += 4; cip = rd(stk); stk += 4
                cnt = rd(stk); stk += 4 + cnt*4
                if cip == -1:
                    self.trace.append(('ret', pri, ps)); return
                continue
            elif n == 'CALL':
                stk -= 4; wr(stk, nxt); cip = prm[0]; continue
            elif n == 'JUMP': cip = prm[0]; continue
            elif n in ('JZER','JNZ','JEQ','JNEQ','JSLESS','JSLEQ','JSGRTR','JSGEQ'):
                if n == 'JZER': c = (pri == 0); sy = ps is not None; cond = ('eq', ps or ('k',pri), ('k',0)) if sy else None
                elif n == 'JNZ': c = (pri != 0); sy = ps is not None; cond = ('neq', ps or ('k',pri), ('k',0)) if sy else None
                else:
                    op = {'JEQ':'eq','JNEQ':'neq','JSLESS':'lt','JSLEQ':'le','JSGRTR':'gt','JSGEQ':'ge'}[n]
                    c = {'eq':pri==alt,'neq':pri!=alt,'lt':pri<alt,'le':pri<=alt,'gt':pri>alt,'ge':pri>=alt}[op]
                    sy = ps is not None or as_ is not None
                    cond = (op, ps or ('k',pri), as_ or ('k',alt)) if sy else None
                if sy:
                    tgt = prm[0]
                    here = tgt if c else nxt; other = nxt if c else tgt
                    cip = self.branch(a, cond, c, work, other, here, (pri, ps, alt, as_, frm, stk, hea))
                    continue
                if self.log_conc: self.trace.append(('cb', a, c))
                cip = prm[0] if c else nxt
                if self.prune is not None: self.prune(a, cip)
                continue
            elif n in ('SHL','SHR','SSHR','SMUL','ADD','SUB','SUB_ALT','AND','OR','XOR','EQ','NEQ','SLESS','SLEQ','SGRTR','SGEQ'):
                x, y, xs, ys = pri, alt, ps, as_
                if n == 'SHL': r = s32(x << (y & 31)); op='shl'
                elif n == 'SHR': r = s32((x & 0xffffffff) >> (y & 31)); op='shr'
                elif n == 'SSHR': r = x >> (y & 31); op='sshr'
                elif n == 'SMUL': r = s32(x*y); op='mul'
                elif n == 'ADD': r = s32(x+y); op='add'
                elif n == 'SUB': r = s32(x-y); op='sub'
                elif n == 'SUB_ALT': r = s32(y-x); op='sub'; x, y, xs, ys = y, x, ys, xs
                elif n == 'AND': r = x & y; op='and'
                elif n == 'OR': r = x | y; op='or'
                elif n == 'XOR': r = x ^ y; op='xor'
                elif n == 'EQ': r = int(x == y); op='eq'
                elif n == 'NEQ': r = int(x != y); op='neq'
                elif n == 'SLESS': r = int(x < y); op='lt'
                elif n == 'SLEQ': r = int(x <= y); op='le'
                elif n == 'SGRTR': r = int(x > y); op='gt'
                else: r = int(x >= y); op='ge'
                ps = mk(op, xs, ys, x, y) if (xs is not None or ys is not None) else None
                pri = r
            elif n == 'SHL_C_PRI': pri = s32(pri << prm[0]); ps = mk('shl', ps, None, 0, prm[0]) if ps else None
            elif n == 'SHL_C_ALT': alt = s32(alt << prm[0]); as_ = mk('shl', as_, None, 0, prm[0]) if as_ else None
            elif n == 'SMUL_C': pri = s32(pri*prm[0]); ps = mk('mul', ps, None, 0, prm[0]) if ps else None
            elif n in ('SDIV_ALT','SDIV'):
                if n == 'SDIV_ALT': x, y, xs, ys = alt, pri, as_, ps
                else: x, y, xs, ys = pri, alt, ps, as_
                if y == 0: raise Kill('div0')
                q = abs(x)//abs(y); q = q if (x >= 0) == (y > 0) else -q
                r = x - q*y
                sq = mk('div', xs, ys, x, y) if (xs is not None or ys is not None) else None
                sr = mk('mod', xs, ys, x, y) if (xs is not None or ys is not None) else None
                pri, alt, ps, as_ = s32(q), s32(r), sq, sr
            elif n == 'NOT': pri = 1 if pri == 0 else 0; ps = un('not', ps) if ps else None
            elif n == 'NEG': pri = s32(-pri); ps = un('neg', ps) if ps else None
            elif n == 'INVERT': pri = s32(~pri); ps = un('inv', ps) if ps else None
            elif n == 'ADD_C': pri = s32(pri + prm[0]); ps = mk('add', ps, None, 0, prm[0]) if ps else None
            elif n == 'ZERO_PRI': pri = 0; ps = None
            elif n == 'ZERO_ALT': alt = 0; as_ = None
            elif n == 'ZERO': wr(prm[0], 0)
            elif n == 'ZERO_S': wr(frm+prm[0], 0)
            elif n == 'EQ_C_PRI': ps = mk('eq', ps, None, pri, prm[0]) if ps else None; pri = int(pri == prm[0])
            elif n == 'EQ_C_ALT': ps = mk('eq', as_, None, alt, prm[0]) if as_ else None; pri = int(alt == prm[0])
            elif n == 'INC_PRI': pri = s32(pri+1); ps = mk('add', ps, None, 0, 1) if ps else None
            elif n == 'INC_ALT': alt = s32(alt+1); as_ = mk('add', as_, None, 0, 1) if as_ else None
            elif n == 'DEC_PRI': pri = s32(pri-1); ps = mk('add', ps, None, 0, -1) if ps else None
            elif n == 'DEC_ALT': alt = s32(alt-1); as_ = mk('add', as_, None, 0, -1) if as_ else None
            elif n in ('INC','INC_S','INC_I','DEC','DEC_S','DEC_I'):
                ad = prm[0] if n in ('INC','DEC') else (frm+prm[0] if n.endswith('_S') else pri)
                v, s = rds(ad); d = 1 if n.startswith('INC') else -1
                wr(ad, v+d, mk('add', s, None, 0, d) if s else None)
            elif n == 'MOVS':
                ln = prm[0]
                for k in range(0, ln, 4):
                    if k+4 <= ln:
                        v, s = rds(pri+k); wr(alt+k, v, s)
                    else:
                        for j in range(k, ln): self.wrb(alt+j, self.mem[pri+j])
            elif n == 'FILL':
                for k in range(0, prm[0], 4): wr(alt+k, pri, ps)
            elif n == 'HALT': self.trace.append(('halt',)); return
            elif n == 'BOUNDS':
                if ps is None and (pri < 0 or pri > prm[0]): raise Kill('bounds')
            elif n == 'SWAP_PRI':
                v, s = rd(stk), self.sym.get(stk); wr(stk, pri, ps); pri, ps = v, s
            elif n == 'SWAP_ALT':
                v, s = rd(stk), self.sym.get(stk); wr(stk, alt, as_); alt, as_ = v, s
            elif n == 'CONST': wr(prm[0], prm[1])
            elif n == 'CONST_S': wr(frm+prm[0], prm[1])
            elif n in ('TRACKER_PUSH_C','TRACKER_POP_SETHEAP'): pass
            elif n == 'STRADJUST_PRI': pri = (pri + 4) >> 2
            elif n in ('GENARRAY','GENARRAY_Z'):
                if prm[0] != 1: raise Kill('genarray')
                cells = rd(stk); ad = hea; hea += cells*4
                for k in range(cells): wr(ad+4*k, 0)
                wr(stk, ad)
            elif n == 'SWITCH':
                tbl = prm[0]; _, _, tp = ins[idx[tbl]]
                num, dflt = tp[0], tp[1]
                cases = [(tp[2+2*k], tp[3+2*k]) for k in range(num)]
                tgt = dflt
                for v, t in cases:
                    if v == pri: tgt = t; break
                if ps is not None:
                    # fork over cases
                    opts = [('d', dflt)] + cases
                    for v, t in opts:
                        if t == tgt: continue
                        if (a, v) in self.covered: continue
                        if self.prune is not None:
                            try: self.prune(a, t)
                            except Kill: continue
                        self.covered.add((a, v))
                        tr = list(self.trace); tr.append(('sw', a, ps, v))
                        work.append((t, v if v != 'd' else -12345, ps, alt, as_, frm, stk, hea, len(self.undo), tr))
                    self.trace.append(('sw', a, ps, pri))
                elif self.log_conc: self.trace.append(('csw', a, pri))
                cip = tgt
                if self.prune is not None: self.prune(a, cip)
                continue
            elif n == 'CASETBL': raise Kill('casetbl')
            elif n in ('SYSREQ_N','SYSREQ_C'):
                ni = prm[0]
                if n == 'SYSREQ_N':
                    nargs = prm[1]; stk -= 4; wr(stk, nargs)
                else:
                    nargs = rd(stk)
                self.hea_cur = hea
                pri, ps = self.native(a, self.nat[ni], stk, nargs)
                hea = self.hea_cur
                if n == 'SYSREQ_N': stk += 4 + nargs*4
            else:
                raise Kill('unhandled ' + n)
            cip = nxt
    # ---- natives
    def A(self, params, k): return self.rd(params + 4*k)
    def S(self, params, k): return self.sym.get(params + 4*k)
    def strarg(self, v):
        s = self.cstr(v, 400)
        if s is not None and len(s) >= 1 and all(ch.isprintable() for ch in s) and v >= 32: return s
        return None
    def argdesc(self, params, k):
        v, s = self.A(params, k), self.S(params, k)
        if s is not None: return fmt(s)
        st = self.strarg(v)
        if st is not None: return repr(st)
        if abs(v) > 0x1000000:
            f = i2f(v)
            if 1e-5 < abs(f) < 1e7: return '%gf' % f
        return str(v)
    def vecsym(self, ad, n=3):
        return [self.sym.get(ad + 4*j) for j in range(n)]
    def native(self, cip, name, params, nargs):
        A = lambda k: self.A(params, k); S = lambda k: self.S(params, k)
        if name in ('Format', 'FormatEx'):
            buf, ml, fa = A(1), A(2), A(3)
            f = self.cstr(fa) or ''
            out = []; k = 4; pos = 0
            for m in FMT_RE.finditer(f):
                out.append(f[pos:m.start()]); pos = m.end(); c = m.group(4)
                if c == '%': out.append('%'); continue
                if k > nargs: out.append('<?>'); continue
                ad = A(k); k += 1
                v, s = self.rd(ad), self.sym.get(ad)
                if s is not None and c in 'difucxX': out.append('{%s}' % fmt(s, flt=(c=='f'))); continue
                if c in 'di': out.append(str(v))
                elif c == 'f': out.append(('%.' + (m.group(3) or '6') + 'f') % i2f(v))
                elif c == 's': out.append(self.cstr(ad) or '')
                elif c == 'c': out.append(chr(v & 0xff))
                elif c in 'xX': out.append('%x' % (v & 0xffffffff))
                elif c == 't': out.append('{t:%s}' % (self.cstr(ad) or ''))
                elif c == 'T': out.append('{T:%s}' % (self.cstr(ad) or '')); k += 1
                elif c in 'NL': out.append('<client>')
                else: out.append('<%s>' % c)
            out.append(f[pos:])
            s = ''.join(out)
            if 0 <= buf and buf + 1 < self.memsize: self.wstr(buf, s, ml)
            self.trace.append(('fmt', cip, s))
            return len(s), None
        if name == 'strcopy':
            s = self.cstr(A(3)) or ''; return self.wstr(A(1), s, A(2)), None
        if name == 'StringToInt':
            s = self.cstr(A(1)) or ''
            m = re.match(r'\s*([-+]?\d+)', s)
            return (s32(int(m.group(1))) if m else 0), None
        if name == 'StringToFloat':
            s = self.cstr(A(1)) or ''
            m = re.match(r'\s*([-+]?\d*\.?\d*)', s)
            try: v = float(m.group(1))
            except Exception: v = 0.0
            return f2i(v), None
        if name == 'IntToString': return self.wstr(A(2), str(A(1)), A(3)), None
        if name == 'strlen': return len((self.cstr(A(1)) or '').encode()), None
        if name in ('strcmp','StrContains','StrEqual'):
            a_, b_ = self.cstr(A(1)) or '', self.cstr(A(2)) or ''
            self.trace.append(('nat', cip, name, [repr(a_), repr(b_)]))
            if name == 'StrContains': return a_.find(b_), ('call', name, [('v', repr(a_)), ('v', repr(b_))])
            return (a_ > b_) - (a_ < b_), ('call', name, [('v', repr(a_)), ('v', repr(b_))])
        if name == 'float':
            v, s = A(1), S(1)
            return f2i(float(v)), (('call', 'float', [s]) if s is not None else None)
        if name in FLOATNAT:
            x, y = i2f(A(1)), i2f(A(2)); sx, sy = S(1), S(2)
            try: r = {'FloatAdd': x+y, 'FloatSub': x-y, 'FloatMul': x*y, 'FloatDiv': (x/y if y else float('inf'))}[name]
            except Exception: r = 0.0
            sr = mk(FLOATNAT[name], sx, sy, A(1), A(2)) if (sx is not None or sy is not None) else None
            return f2i(r), sr
        if name == 'FloatCompare':
            x, y = i2f(A(1)), i2f(A(2)); sx, sy = S(1), S(2)
            r = (x > y) - (x < y)
            if sx is not None or sy is not None:
                return r, ('fcmp', sx or ('k', A(1)), sy or ('k', A(2)))
            return r, None
        if name in ('RoundToNearest','RoundToCeil','RoundToFloor','RoundToZero','SquareRoot','FloatAbs'):
            x = i2f(A(1)); s = S(1)
            try:
                r = {'RoundToNearest': lambda v: int(math.floor(v+0.5)), 'RoundToCeil': math.ceil, 'RoundToFloor': math.floor, 'RoundToZero': int,
                     'SquareRoot': lambda v: f2i(math.sqrt(v) if v >= 0 else 0.0), 'FloatAbs': lambda v: f2i(abs(v))}[name](x)
            except Exception: r = 0
            return s32(r), (('call', name, [s]) if s is not None else None)
        if name == 'GetTickInterval': return f2i(1/66.0), None
        # generic natives
        args = [self.argdesc(params, k) for k in range(1, nargs+1)]
        self.trace.append(('nat', cip, name, args))
        callexpr = ('call', name, [S(k) if S(k) is not None else (('v', repr(self.strarg(A(k)))) if self.strarg(A(k)) else ('k', A(k))) for k in range(1, nargs+1)])
        for k in OUTP.get(name, []):
            if k <= nargs:
                ad = A(k)
                if name in STRNAT_OUT:
                    if 0 < ad < self.memsize - 8: self.wstr(ad, '<%s>' % name, 32)
                    continue
                if 0 <= ad < self.memsize - 16:
                    for j in range(3):
                        self.wr(ad + 4*j, 0, ('v', '%s[%d]' % (fmt(callexpr), j)))
        if name in ('GetGameTime', 'GetEngineTime', 'GetTickedTime'):
            return f2i(100.0), ('v', 'now')
        if name == 'GetClientOfUserId': return 1, ('call', name, callexpr[2])
        if name in ('IsClientInGame','IsClientConnected','IsPlayerAlive'):
            return 1, callexpr
        return 0, callexpr

class Emu2C(Emu2):
    """records concrete conditional branch decisions too"""
    def run_path(self, st, work):
        self.conc = getattr(self, 'conc', {})
        return Emu2.run_path(self, st, work)
