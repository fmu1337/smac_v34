import struct, sys, math
sys.path.insert(0,'.')
from tools import P

def s32(x):
    x &= 0xffffffff
    return x - 0x100000000 if x & 0x80000000 else x
def f2i(f):
    try: return struct.unpack('<i', struct.pack('<f', f))[0]
    except OverflowError: return struct.unpack('<i', struct.pack('<f', math.copysign(float('inf'), f)))[0]
def i2f(i): return struct.unpack('<f', struct.pack('<i', s32(i)))[0]

class Kill(Exception): pass

class VM:
    def __init__(self, prog, log_natives=True):
        self.p = prog
        self.ins = prog.ins
        self.idx = prog.idx
        self.nat = prog.nat
        self.datasize = len(prog.data)
        self.memsize = prog.mem
        self.base = bytearray(self.memsize)
        self.base[:self.datasize] = prog.data
        self.reset()
        self.events = []
        self.hooks = {}
    def reset(self):
        self.mem = bytearray(self.base)
        self.taint = set()
        self.undo = []
        self.hea = self.datasize
        self.stk = self.memsize
        self.frm = 0
    # memory with undo
    def rd(self, a):
        return struct.unpack_from('<i', self.mem, a)[0]
    def wr(self, a, v, t=False):
        self.undo.append((a, bytes(self.mem[a:a+4]), a in self.taint))
        struct.pack_into('<i', self.mem, a, s32(v))
        if t: self.taint.add(a)
        else: self.taint.discard(a)
    def wrb(self, a, b):
        self.undo.append((a, bytes(self.mem[a:a+1]), None))
        self.mem[a] = b & 0xff
    def rollback(self, n):
        while len(self.undo) > n:
            a, old, t = self.undo.pop()
            self.mem[a:a+len(old)] = old
            if t is True: self.taint.add(a)
            elif t is False: self.taint.discard(a)
    def cstr(self, a, maxn=4096):
        if a < 0 or a >= self.memsize: return None
        e = self.mem.find(b'\0', a, a+maxn)
        if e < 0: return None
        return self.mem[a:e].decode('utf-8','replace')
    def wstr(self, a, s, maxlen):
        b = s.encode('utf-8')[:max(0,maxlen-1)] + b'\0'
        for i,c in enumerate(b): self.wrb(a+i, c)
        return len(b)-1

class Explorer(VM):
    MAX_STEPS = 400000
    MAX_PATHS = 400
    def explore(self, entry, args, tag=''):
        """args: list of (value, tainted). Returns nothing; appends to self.events."""
        self.reset()
        self.cur_tag = tag
        self.covered = set()
        self.calls_seen = {}
        # push args reversed
        stk = self.stk
        for v,t in reversed(args):
            stk -= 4; self.wr(stk, v, t)
        stk -= 4; self.wr(stk, len(args))
        stk -= 4; self.wr(stk, -1)    # return sentinel
        self.stk = stk
        start = (entry, 0, 0, False, False, self.frm, self.stk, self.hea, len(self.undo), 0)
        work = [start]
        paths = 0
        while work and paths < self.MAX_PATHS:
            st = work.pop()
            paths += 1
            try:
                self.run_path(st, work)
            except Kill as e:
                pass
        self.paths = paths
    def run_path(self, st, work):
        cip, pri, alt, pt, at, frm, stk, hea, ul, branch_hist = st
        self.rollback(ul)
        ins = self.ins; idx = self.idx; mem = self.mem
        rd = self.rd; wr = self.wr; taint = self.taint
        covered = self.covered
        steps = 0
        bcount = {}
        while True:
            steps += 1
            if steps > self.MAX_STEPS: raise Kill('steps')
            try:
                i = idx[cip]
            except KeyError:
                raise Kill('badcip %x' % cip)
            a, n, prm = ins[i]
            nxt = ins[i+1][0] if i+1 < len(ins) else -1
            if n == 'BREAK' or n == 'NOP':
                cip = nxt; continue
            if n == 'LOAD_PRI': pri = rd(prm[0]); pt = prm[0] in taint
            elif n == 'LOAD_ALT': alt = rd(prm[0]); at = prm[0] in taint
            elif n == 'LOAD_S_PRI': ad = frm+prm[0]; pri = rd(ad); pt = ad in taint
            elif n == 'LOAD_S_ALT': ad = frm+prm[0]; alt = rd(ad); at = ad in taint
            elif n == 'LOAD_BOTH':
                pri = rd(prm[0]); pt = prm[0] in taint; alt = rd(prm[1]); at = prm[1] in taint
            elif n == 'LOAD_S_BOTH':
                ad = frm+prm[0]; pri = rd(ad); pt = ad in taint
                ad = frm+prm[1]; alt = rd(ad); at = ad in taint
            elif n == 'LREF_S_PRI':
                ad = rd(frm+prm[0]); self.chk(ad); pri = rd(ad); pt = ad in taint or (frm+prm[0]) in taint
            elif n == 'LREF_S_ALT':
                ad = rd(frm+prm[0]); self.chk(ad); alt = rd(ad); at = ad in taint
            elif n == 'LOAD_I': self.chk(pri); ad = pri; pri = rd(ad); pt = pt or (ad in taint)
            elif n == 'LODB_I':
                self.chk(pri); ad = pri; sz = prm[0]
                pt = pt or ad in taint or (ad & ~3) in taint
                if sz == 1: pri = mem[ad]
                elif sz == 2: pri = struct.unpack_from('<H', mem, ad)[0]
                else: pri = rd(ad)
            elif n == 'CONST_PRI': pri = prm[0]; pt = False
            elif n == 'CONST_ALT': alt = prm[0]; at = False
            elif n == 'ADDR_PRI': pri = frm+prm[0]; pt = False
            elif n == 'ADDR_ALT': alt = frm+prm[0]; at = False
            elif n == 'STOR_PRI': wr(prm[0], pri, pt)
            elif n == 'STOR_ALT': wr(prm[0], alt, at)
            elif n == 'STOR_S_PRI': wr(frm+prm[0], pri, pt)
            elif n == 'STOR_S_ALT': wr(frm+prm[0], alt, at)
            elif n == 'SREF_S_PRI': ad = rd(frm+prm[0]); self.chk(ad); wr(ad, pri, pt)
            elif n == 'SREF_S_ALT': ad = rd(frm+prm[0]); self.chk(ad); wr(ad, alt, at)
            elif n == 'STOR_I': self.chk(alt); wr(alt, pri, pt)
            elif n == 'STRB_I':
                self.chk(alt); sz = prm[0]
                if sz == 1: self.wrb(alt, pri)
                elif sz == 2: self.wrb(alt, pri); self.wrb(alt+1, pri >> 8)
                else: wr(alt, pri, pt)
            elif n == 'LIDX':
                ad = alt + pri*4; self.chk(ad); t = pt or at or ad in taint; pri = rd(ad); pt = t
            elif n == 'IDXADDR': pri = alt + pri*4; pt = pt or at
            elif n == 'MOVE_PRI': pri = alt; pt = at
            elif n == 'MOVE_ALT': alt = pri; at = pt
            elif n == 'XCHG': pri, alt = alt, pri; pt, at = at, pt
            elif n == 'PUSH_PRI': stk -= 4; wr(stk, pri, pt)
            elif n == 'PUSH_ALT': stk -= 4; wr(stk, alt, at)
            elif n in ('PUSH_C','PUSH2_C','PUSH3_C','PUSH4_C','PUSH5_C'):
                for v in prm: stk -= 4; wr(stk, v, False)
            elif n in ('PUSH','PUSH2','PUSH3','PUSH4','PUSH5'):
                for v in prm: stk -= 4; wr(stk, rd(v), v in taint)
            elif n in ('PUSH_S','PUSH2_S','PUSH3_S','PUSH4_S','PUSH5_S'):
                for v in prm: stk -= 4; wr(stk, rd(frm+v), (frm+v) in taint)
            elif n in ('PUSH_ADR','PUSH2_ADR','PUSH3_ADR','PUSH4_ADR','PUSH5_ADR'):
                for v in prm: stk -= 4; wr(stk, frm+v, False)
            elif n == 'POP_PRI': pri = rd(stk); pt = stk in taint; stk += 4
            elif n == 'POP_ALT': alt = rd(stk); at = stk in taint; stk += 4
            elif n == 'STACK': stk += prm[0]; alt = stk; at = False
            elif n == 'HEAP': alt = hea; at = False; hea += prm[0]
            elif n == 'PROC': stk -= 4; wr(stk, frm); frm = stk
            elif n == 'RETN':
                frm = rd(stk); stk += 4
                cip = rd(stk); stk += 4
                cnt = rd(stk); stk += 4 + cnt*4
                if cip == -1:
                    self.on_return(pri, pt)
                    return
                continue
            elif n == 'CALL':
                tgt = prm[0]
                stk -= 4; wr(stk, nxt)
                cip = tgt; continue
            elif n == 'JUMP': cip = prm[0]; continue
            elif n in ('JZER','JNZ','JEQ','JNEQ','JSLESS','JSLEQ','JSGRTR','JSGEQ'):
                if n == 'JZER': c = (pri == 0); tt = pt
                elif n == 'JNZ': c = (pri != 0); tt = pt
                elif n == 'JEQ': c = (pri == alt); tt = pt or at
                elif n == 'JNEQ': c = (pri != alt); tt = pt or at
                elif n == 'JSLESS': c = (pri < alt); tt = pt or at
                elif n == 'JSLEQ': c = (pri <= alt); tt = pt or at
                elif n == 'JSGRTR': c = (pri > alt); tt = pt or at
                else: c = (pri >= alt); tt = pt or at
                tgt_t = prm[0]
                if tt:
                    self.on_tbranch(cip, n, pri, alt, pt, at)
                    bc = bcount.get(cip, 0) + 1; bcount[cip] = bc
                    dirs = [(c, tgt_t if c else nxt), (not c, nxt if c else tgt_t)]
                    unc = [d for d in dirs if (cip, d[0]) not in covered]
                    if bc > 40:
                        unc = []
                        if bc > 200: raise Kill('loop')
                    if len(unc) == 2:
                        covered.add((cip, unc[1][0]))
                        work.append((unc[1][1], pri, alt, pt, at, frm, stk, hea, len(self.undo), 0))
                        covered.add((cip, unc[0][0])); cip = unc[0][1]
                    elif len(unc) == 1:
                        covered.add((cip, unc[0][0])); cip = unc[0][1]
                    else:
                        cip = dirs[0][1]
                    continue
                cip = tgt_t if c else nxt; continue
            elif n == 'SHL': pri = s32(pri << (alt & 31)); pt = pt or at
            elif n == 'SHR': pri = s32((pri & 0xffffffff) >> (alt & 31)); pt = pt or at
            elif n == 'SSHR': pri = pri >> (alt & 31); pt = pt or at
            elif n == 'SHL_C_PRI': pri = s32(pri << prm[0])
            elif n == 'SHL_C_ALT': alt = s32(alt << prm[0])
            elif n == 'SMUL': pri = s32(pri*alt); pt = pt or at
            elif n == 'SMUL_C': pri = s32(pri*prm[0])
            elif n == 'SDIV_ALT':
                if pri == 0: raise Kill('div0')
                q = abs(alt)//abs(pri); q = q if (alt >= 0) == (pri > 0) else -q
                r = alt - q*pri
                pri, alt = s32(q), s32(r); pt = at = pt or at
            elif n == 'SDIV':
                if alt == 0: raise Kill('div0')
                q = abs(pri)//abs(alt); q = q if (pri >= 0) == (alt > 0) else -q
                r = pri - q*alt
                pri, alt = s32(q), s32(r); pt = at = pt or at
            elif n == 'ADD': pri = s32(pri+alt); pt = pt or at
            elif n == 'SUB': pri = s32(pri-alt); pt = pt or at
            elif n == 'SUB_ALT': pri = s32(alt-pri); pt = pt or at
            elif n == 'AND': pri = pri & alt; pt = pt or at
            elif n == 'OR': pri = pri | alt; pt = pt or at
            elif n == 'XOR': pri = pri ^ alt; pt = pt or at
            elif n == 'NOT': pri = 1 if pri == 0 else 0
            elif n == 'NEG': pri = s32(-pri)
            elif n == 'INVERT': pri = s32(~pri)
            elif n == 'ADD_C': pri = s32(pri + prm[0])
            elif n == 'ZERO_PRI': pri = 0; pt = False
            elif n == 'ZERO_ALT': alt = 0; at = False
            elif n == 'ZERO': wr(prm[0], 0)
            elif n == 'ZERO_S': wr(frm+prm[0], 0)
            elif n == 'EQ': pri = int(pri == alt); pt = pt or at
            elif n == 'NEQ': pri = int(pri != alt); pt = pt or at
            elif n == 'SLESS': pri = int(pri < alt); pt = pt or at
            elif n == 'SLEQ': pri = int(pri <= alt); pt = pt or at
            elif n == 'SGRTR': pri = int(pri > alt); pt = pt or at
            elif n == 'SGEQ': pri = int(pri >= alt); pt = pt or at
            elif n == 'EQ_C_PRI': pri = int(pri == prm[0])
            elif n == 'EQ_C_ALT': pri = int(alt == prm[0]); pt = at
            elif n == 'INC_PRI': pri = s32(pri+1)
            elif n == 'INC_ALT': alt = s32(alt+1)
            elif n == 'INC': wr(prm[0], rd(prm[0])+1, prm[0] in taint)
            elif n == 'INC_S': ad = frm+prm[0]; wr(ad, rd(ad)+1, ad in taint)
            elif n == 'INC_I': self.chk(pri); wr(pri, rd(pri)+1, pri in taint)
            elif n == 'DEC_PRI': pri = s32(pri-1)
            elif n == 'DEC_ALT': alt = s32(alt-1)
            elif n == 'DEC': wr(prm[0], rd(prm[0])-1, prm[0] in taint)
            elif n == 'DEC_S': ad = frm+prm[0]; wr(ad, rd(ad)-1, ad in taint)
            elif n == 'DEC_I': self.chk(pri); wr(pri, rd(pri)-1, pri in taint)
            elif n == 'MOVS':
                self.chk(pri); self.chk(alt)
                ln = prm[0]
                for k in range(0, ln, 4):
                    if k+4 <= ln: wr(alt+k, rd(pri+k), (pri+k) in taint)
                    else:
                        for j in range(k, ln): self.wrb(alt+j, mem[pri+j])
            elif n == 'FILL':
                self.chk(alt)
                for k in range(0, prm[0], 4): wr(alt+k, pri, pt)
            elif n == 'HALT': return
            elif n == 'BOUNDS':
                if not pt and (pri < 0 or pri > prm[0]): raise Kill('bounds')
            elif n == 'SWAP_PRI':
                v = rd(stk); t = stk in taint; wr(stk, pri, pt); pri = v; pt = t
            elif n == 'SWAP_ALT':
                v = rd(stk); t = stk in taint; wr(stk, alt, at); alt = v; at = t
            elif n == 'CONST': wr(prm[0], prm[1])
            elif n == 'CONST_S': wr(frm+prm[0], prm[1])
            elif n == 'TRACKER_PUSH_C' or n == 'TRACKER_POP_SETHEAP':
                pass
            elif n == 'STRADJUST_PRI': pri = (pri + 4) >> 2
            elif n == 'GENARRAY' or n == 'GENARRAY_Z':
                dims = prm[0]
                sizes = [rd(stk + 4*k) for k in range(dims)]
                # simple: 1-dim only
                if dims != 1: raise Kill('genarray dims')
                cells = sizes[0]
                ad = hea; hea += cells*4
                for k in range(cells): wr(ad+4*k, 0)
                wr(stk, ad)
            elif n == 'SWITCH':
                tbl = prm[0]
                ti = idx[tbl]; _, _, tp = ins[ti]
                num, dflt = tp[0], tp[1]
                cases = [(tp[2+2*k], tp[3+2*k]) for k in range(num)]
                if pt:
                    self.on_tbranch(cip, 'SWITCH', pri, 0, True, False)
                    opts = [('d', dflt)] + [(v, t) for v,t in cases]
                    unc = [o for o in opts if (cip, o[0]) not in covered]
                    for o in unc[1:]:
                        covered.add((cip, o[0]))
                        work.append((o[1], o[0] if o[0] != 'd' else -999999, alt, False, at, frm, stk, hea, len(self.undo), 0))
                    if unc:
                        covered.add((cip, unc[0][0])); cip = unc[0][1]
                    else:
                        cip = dflt
                    continue
                cip = dflt
                for v,t in cases:
                    if v == pri: cip = t; break
                continue
            elif n == 'CASETBL':
                raise Kill('casetbl fallthrough')
            elif n in ('SYSREQ_N', 'SYSREQ_C'):
                ni = prm[0]
                if n == 'SYSREQ_N':
                    nargs = prm[1]; stk -= 4; wr(stk, nargs)
                else:
                    nargs = rd(stk)
                params = stk
                self.frm_cache = frm
                self.hea_cur = hea
                pri, pt = self.native(cip, self.nat[ni], params, nargs)
                hea = self.hea_cur
                if n == 'SYSREQ_N': stk += 4 + nargs*4
            else:
                raise Kill('unhandled ' + n)
            cip = nxt
    _la = -1
    def last_addr_t(self, cip): return False
    def chk(self, a):
        if a < 0 or a + 4 > self.memsize: raise Kill('oob %x' % a)
        self._la = a
    def on_return(self, v, t): pass
    def on_tbranch(self, cip, n, pri, alt, pt, at): pass

OUTP = {  # native -> list of out-param indices (1-based) that receive tainted data
 'GetClientEyePosition':[2], 'GetClientAbsOrigin':[2], 'GetClientAbsAngles':[2], 'GetClientEyeAngles':[2],
 'GetEntPropVector':[4], 'GetAngleVectors':[2,3,4], 'GetVectorAngles':[2], 'NormalizeVector':[2],
 'GetClientName':[2], 'GetClientAuthString':[2], 'GetClientIP':[2], 'GetEventString':[3], 'GetConVarString':[2],
 'GetClientWeapon':[2], 'GetClientModel':[2], 'TR_GetEndPosition':[1], 'GetClientMins':[2], 'GetCurrentMap':[1],
 'GetCmdArgString':[1], 'GetCmdArg':[2], 'GetEntDataVector':[3], 'ReadPackString':[2], 'GetArrayArray':[3],
 'GetArrayString':[3], 'GetTrieValue':[3], 'GetPluginFilename':[2], 'GetEntityNetClass':[2], 'ReadFileLine':[2],
 'GetClientMaxs':[2], 'GetCmdStr':[2], 'GetGameDescription':[1], 'GetConVarName':[2], 'GetConVarDefault':[2],
 'FormatTime':[1], 'ReadFileString':[2], 'GameConfGetKeyValue':[3], 'GetEdictClassname':[2], 'GetEntityClassname':[2],
}
FMT_RE = re.compile(r'%([-+ 0#]*)(\d*)(?:\.(\d+))?([dibufscxXtTNL%])') if False else None
import re
FMT_RE = re.compile(r'%([-+ 0#]*)(\d*)(?:\.(\d+))?([dibufscxXtTNL%])')

class Emu(Explorer):
    def __init__(self, prog, maxclients=2):
        super().__init__(prog)
        self.maxclients_addr = dict((n,a) for a,n in prog.s.pubvars()).get('MaxClients')
        if self.maxclients_addr is not None:
            struct.pack_into('<i', self.base, self.maxclients_addr, maxclients)
        self.strings = []
        self.fcmp = []
        self.tbr = []
    def arg(self, params, k): return self.rd(params + 4*k)
    def argt(self, params, k): return (params + 4*k) in self.taint
    def is_tainted_str(self, a):
        return (a & ~3) in self.taint
    def desc(self, v, t):
        s = None
        if 0 < v < self.memsize:
            s = self.cstr(v, 300)
            if s is not None and (len(s) == 0 or not all(ch.isprintable() for ch in s)): s = None
        if t: tag = '~'
        else: tag = ''
        if s is not None and len(s) >= 1 and v >= 64:
            return tag + repr(s)
        if abs(v) > 0x100000 :
            f = i2f(v)
            if 1e-6 < abs(f) < 1e7: return tag + '%gf' % f
        return tag + str(v)
    def sp_format(self, fmt, params, start, nargs):
        out = []; k = start; pos = 0
        for m in FMT_RE.finditer(fmt):
            out.append(fmt[pos:m.start()]); pos = m.end()
            c = m.group(4)
            if c == '%': out.append('%'); continue
            if k > nargs: out.append('<?>'); continue
            ad = self.arg(params, k); k += 1
            try:
                if c in 'di': out.append(str(self.rd(ad)) if not (ad in self.taint) else '<%d~>' % self.rd(ad))
                elif c == 'u': out.append(str(self.rd(ad) & 0xffffffff))
                elif c == 'b': out.append(bin(self.rd(ad) & 0xffffffff)[2:])
                elif c == 'f':
                    pr = m.group(3)
                    v = i2f(self.rd(ad))
                    out.append(('%.' + (pr or '6') + 'f') % v if ad not in self.taint else '<f~>')
                elif c == 's': out.append(self.cstr(ad) or '')
                elif c == 'c':
                    ch = self.rd(ad) & 0xff
                    out.append(chr(ch) if ad not in self.taint else '?')
                elif c in 'xX': out.append('%x' % (self.rd(ad) & 0xffffffff))
                elif c == 't':
                    out.append('{t:%s}' % (self.cstr(ad) or ''))
                elif c == 'T':
                    out.append('{T:%s}' % (self.cstr(ad) or '')); k += 1
                elif c in 'NL': out.append('<client>')
            except Exception:
                out.append('<err>')
        out.append(fmt[pos:])
        return ''.join(out)
    def native(self, cip, name, params, nargs):
        A = lambda k: self.arg(params, k)
        T = lambda k: self.argt(params, k)
        F = lambda k: i2f(self.arg(params, k))
        ret, rt = 0, True
        if name in ('Format', 'FormatEx'):
            buf, maxlen, fa = A(1), A(2), A(3)
            fmt = self.cstr(fa) or ''
            s = self.sp_format(fmt, params, 4, nargs)
            if buf + maxlen <= self.memsize and buf >= 0:
                self.wstr(buf, s, maxlen)
            # mark buffer cell taint if any arg tainted
            self.strings.append((self.cur_tag, cip, s))
            return len(s), False
        if name == 'strcopy':
            d, ml, sa = A(1), A(2), A(3)
            s = self.cstr(sa) or ''
            n = self.wstr(d, s, ml)
            return n, False
        if name == 'StringToInt':
            s = self.cstr(A(1)) or ''; base = A(2) if nargs >= 2 else 10
            m = re.match(r'\s*([-+]?[0-9a-fA-F]+)', s)
            try: v = int(m.group(1), base) if m else 0
            except ValueError:
                m2 = re.match(r'\s*([-+]?\d+)', s); v = int(m2.group(1)) if m2 else 0
            return s32(v), self.is_tainted_str(A(1))
        if name == 'StringToFloat':
            s = self.cstr(A(1)) or ''
            m = re.match(r'\s*([-+]?\d*\.?\d*)', s)
            try: v = float(m.group(1))
            except Exception: v = 0.0
            return f2i(v), self.is_tainted_str(A(1))
        if name == 'IntToString':
            n = self.wstr(A(2), str(A(1)), A(3)); return n, False
        if name == 'FloatToString':
            n = self.wstr(A(2), '%f' % F(1), A(3)); return n, False
        if name == 'strlen':
            return len((self.cstr(A(1)) or '').encode()), self.is_tainted_str(A(1))
        if name == 'strcmp':
            a, b = self.cstr(A(1)) or '', self.cstr(A(2)) or ''
            cs = A(3) if nargs >= 3 else 1
            if not cs: a, b = a.lower(), b.lower()
            self.events.append((self.cur_tag, cip, name, [repr(a), repr(b)], None))
            r = (a > b) - (a < b)
            return r, self.is_tainted_str(A(1)) or self.is_tainted_str(A(2)) or True
        if name == 'StrContains':
            a, b = self.cstr(A(1)) or '', self.cstr(A(2)) or ''
            self.events.append((self.cur_tag, cip, name, [repr(a), repr(b)], None))
            return a.find(b), True
        if name == 'float':
            return f2i(float(A(1))), T(1)
        if name in ('FloatAdd','FloatSub','FloatMul','FloatDiv'):
            x, y = F(1), F(2)
            try:
                r = {'FloatAdd': x+y, 'FloatSub': x-y, 'FloatMul': x*y, 'FloatDiv': x/y if y else float('inf')}[name]
            except Exception: r = 0.0
            t = T(1) or T(2)
            if t and not (T(1) and T(2)):
                const = y if T(1) else x
                self.fcmp.append((self.cur_tag, cip, name, ('X' if T(1) else '%g' % x), ('X' if T(2) else '%g' % y)))
            return f2i(r), t
        if name == 'FloatCompare':
            x, y = F(1), F(2)
            if T(1) or T(2):
                self.fcmp.append((self.cur_tag, cip, 'FloatCompare', ('X' if T(1) else '%g' % x), ('X' if T(2) else '%g' % y)))
            return ((x > y) - (x < y)), T(1) or T(2)
        if name in ('RoundToNearest','RoundToCeil','RoundToFloor','RoundToZero'):
            x = F(1)
            try:
                r = {'RoundToNearest': lambda v: int(math.floor(v+0.5)), 'RoundToCeil': math.ceil, 'RoundToFloor': math.floor, 'RoundToZero': int}[name](x)
            except Exception: r = 0
            return s32(r), T(1)
        if name == 'SquareRoot':
            x = F(1); return f2i(math.sqrt(x) if x >= 0 else 0.0), T(1)
        if name == 'GetTickInterval':
            return f2i(1/66.0), False
        if name in ('GetGameTime','GetEngineTime','GetTickedTime'):
            return f2i(100.0), True
        # generic: record call and taint out-params
        args = []
        for k in range(1, nargs+1):
            args.append(self.desc(A(k), T(k)))
        self.events.append((self.cur_tag, cip, name, args, None))
        for k in OUTP.get(name, []):
            if k <= nargs:
                ad = A(k)
                if 0 <= ad < self.memsize - 16:
                    for j in range(0, 16, 4):
                        self.wr(ad+j, 0, True)
        return 0, True
