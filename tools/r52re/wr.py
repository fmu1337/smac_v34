"""Writers analysis: which functions write which global bases; init-only set.
Interprocedural: a function writes its array argument i only if it stores through it,
passes it to an output parameter of a native, or to a callee argument that is written."""
import sys, pickle, time, collections, re
sys.path.insert(0, '.')
from tools import P
from decomp import Ctx, Decomp

# natives whose address arguments are outputs (conservative list; index None = all address args)
OUT_NATIVES = re.compile(r'^(Format|FormatEx|VFormat|strcopy|StrCat|ReplaceString|ReplaceStringEx|ExplodeString|ImplodeStrings|SplitString|BreakString|TrimString|StripQuotes|String(ToLower|ToUpper)|IntToString|FloatToString|'
                         r'Get(ClientName|ClientAuthString|ClientAuthId|ClientIP|ClientWeapon|ClientInfo|ClientEyePosition|ClientEyeAngles|ClientAbsOrigin|ClientAbsAngles|ClientMins|ClientMaxs|'
                         r'EntPropVector|EntPropString|EntDataVector|EntDataString|EdictClassname|EntityNetClass|EntityClassname|ConVarString|ConVarDefault|CmdArg|CmdArgString|CmdArgs|EventString|'
                         r'CurrentMap|NextMap|PluginFilename|PluginInfo|PluginStatus|ArrayString|ArrayArray|ArrayCell|TrieValue|TrieString|TrieArray|Time|ClientCookie|AngleVectors|VectorAngles|'
                         r'GameFolderName|GameDescription|ServerIP|LanguageInfo|PlayerWeaponSlot|FileTime|MapHistory|Extension|FeatureStatus|Command|CommandFlags|ConVarBounds|UserMessage|ClientAvg|ClientLatency)|'
                         r'ReadPack(String|Float|Cell)|ReadFile(Line|String|)|Read(Plugin|String)|TR_GetEndPosition|TR_GetPlaneNormal|NormalizeVector|ScaleVector|AddVectors|SubtractVectors|NegateVector|'
                         r'MakeVectorFromPoints|FormatTime|GetVector|KvGet|BfRead|PbRead|GetNativeString|GetNativeArray|QueryClientConVar|FindFirstConCommand|FindNextConCommand|GetCommandIterator|ReadCommandIterator|'
                         r'ReadMapList|GetEntityNetClass|NetClass|SQL_Fetch|SQL_Get|SQL_Quote|SQL_Escape|GetClientCookie|IsMapValid|FindMap|GetMapDisplayName|ReadFile)')

def addr_base(d, e):
    pa = d.parse_addr(e)
    if pa:
        if pa[0].startswith('g'):
            return ('g', int(pa[0][1:], 16))
        if pa[0].startswith('a'):
            return ('a', int(pa[0][1:]))
    if e[0] == 'c':
        return ('g', e[1])
    return None

def analyze(path):
    p = P(path)
    ctx = Ctx(p, None, inline=False)
    direct = collections.defaultdict(set)     # f -> set(('g',base)|('a',i))
    callargs = collections.defaultdict(list)  # f -> [(callee, argi, base)]
    calls = collections.defaultdict(set)
    t0 = time.time()
    for f in p.funcs:
        d = Decomp(ctx, f)
        try:
            d.run()
        except Exception:
            continue
        for ad, s in d.lines:
            k = s[0]
            if k in ('store', 'inc', 'storeb', 'movs', 'fill'):
                b = addr_base(d, s[1])
                if b: direct[f].add(b)
            if k == 'assign_t' or k == 'store' or k == 'if' or k == 'return':
                pass
        # collect calls with their args from raw expressions (including pure ones inside expressions)
        def walk(e):
            if not isinstance(e, tuple): return
            if e[0] == 'call':
                if e[3] == 'nat':
                    if OUT_NATIVES.match(e[1]):
                        for a in e[2]:
                            b = addr_base(d, a) if a[0] in ('bin', 'frm', 'c') else None
                            if b and (b[0] == 'a' or (b[0] == 'g' and a[0] != 'c') or (a[0] == 'c' and a[1] > 0x400)):
                                direct[f].add(b)
                else:
                    for i, a in enumerate(e[2]):
                        if a[0] in ('bin', 'frm') or (a[0] == 'c' and a[1] > 0x400) or (a[0] == 'ld' and a[1][0] == 'frm' and a[1][1] >= 0xc):
                            b = addr_base(d, a)
                            if b: callargs[f].append((e[1], i, b))
                for a in e[2]: walk(a)
                return
            for x in e:
                if isinstance(x, tuple): walk(x)
        for ad, s in d.lines:
            for x in s:
                if isinstance(x, tuple): walk(x)
        for ad, n, prm in p.ins[p.idx[f]:]:
            if ad >= p.func_range(f)[1]: break
            if n == 'CALL': calls[f].add(prm[0])
    name2f = {}
    for f in p.funcs:
        name2f[p.pubs.get(f, 'fn_%x' % f)] = f
    # fixed point: which args each function writes
    wargs = collections.defaultdict(set)
    for f, bs in direct.items():
        for b in bs:
            if b[0] == 'a': wargs[f].add(b[1])
    changed = True
    while changed:
        changed = False
        for f, lst in callargs.items():
            for cname, i, b in lst:
                cf = name2f.get(cname)
                if cf is not None and i in wargs.get(cf, ()) and b[0] == 'a' and b[1] not in wargs[f]:
                    wargs[f].add(b[1]); changed = True
    writes = collections.defaultdict(set)
    for f, bs in direct.items():
        for b in bs:
            if b[0] == 'g': writes[b[1]].add(f)
    for f, lst in callargs.items():
        for cname, i, b in lst:
            cf = name2f.get(cname)
            if b[0] == 'g' and (cf is None or i in wargs.get(cf, ())):
                writes[b[1]].add(f)
    print('analyzed in %.1fs' % (time.time() - t0))
    pubs = {n: a for a, n in p.s.publics()}
    def reach(roots):
        seen = set(); st = list(roots)
        while st:
            x = st.pop()
            if x in seen: continue
            seen.add(x); st.extend(calls.get(x, ()))
        return seen
    init_roots = [pubs[n] for n in ('AskPluginLoad2', 'OnPluginStart') if n in pubs]
    other_roots = [a for n, a in pubs.items() if n not in ('AskPluginLoad2', 'OnPluginStart')]
    init_only = reach(init_roots) - reach(other_roots)
    return dict(writes), dict(calls), init_only

if __name__ == '__main__':
    path = sys.argv[1]; out = sys.argv[2]
    w, c, io = analyze(path)
    pickle.dump((w, c, io), open(out, 'wb'))
    rt = [b for b, fs in w.items() if not fs <= io]
    print('bases written:', len(w), 'runtime-written:', len(rt), 'init_only funcs:', len(io))
