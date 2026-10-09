import sys, re, struct, pickle, math; sys.path.insert(0,'.')
from emu2 import Emu2, Kill
from sym import s32, f2i, i2f
def load_cfg(path):
    cv = {}
    for line in open(path, encoding='utf-8', errors='replace'):
        line = line.strip()
        if not line or line.startswith('//'): continue
        m = re.match(r'(\S+)\s+"?([^"]*)"?', line)
        if m: cv[m.group(1).lower()] = m.group(2)
    return cv
SERVER_CVARS = {'sv_cheats':'0','hostip':str(struct.unpack('>i', bytes([46,174,52,246]))[0]),'hostport':'22222','hostname':'test',
  'sv_maxupdaterate':'100','sv_minupdaterate':'100','sv_maxcmdrate':'100','sv_mincmdrate':'100','sv_maxrate':'40000','sv_minrate':'15000',
  'sv_client_predict':'1','sv_client_interpolate':'1','sv_client_interp':'0.01','mp_friendlyfire':'0','sv_gravity':'800','sv_maxspeed':'320',
  'sv_airaccelerate':'10','sv_accelerate':'5','sv_enablebunnyhopping':'0','sm_nextmap':'de_dust2','sv_contact':'','sv_allowupload':'1',
  'sv_allowdownload':'1','phys_pushscale':'1','mp_teamplay':'0','sv_enableoldqueries':'0','mp_forcerespawn':'1','mp_weaponstay':'0',
  'sv_logblocks':'0','host_timescale':'1','sv_footsteps':'1','mp_flashlight':'1','sv_competitive_minspec':'1','sv_alltalk':'0'}
class Host(Emu2):
    def __init__(self, prog, base, cfg):
        super().__init__(prog, base)
        self.cfg = cfg
        self.cvars = {}      # handle -> [name, value]
        self.byname = {}
        self.hooks = []; self.timers = []; self.events = []; self.cmds = []; self.sdkhooks = []
        self.next_h = 0x1000
    def newh(self):
        self.next_h += 1; return self.next_h
    def cvar(self, name, default):
        ln = name.lower()
        if ln in self.byname: return self.byname[ln]
        h = self.newh()
        val = self.cfg.get(ln, SERVER_CVARS.get(ln, default))
        self.cvars[h] = [name, val, default]; self.byname[ln] = h
        return h
    def native(self, cip, name, params, nargs):
        A = lambda k: self.A(params, k)
        if name in ('Format','FormatEx','strcopy','StringToInt','StringToFloat','IntToString','strlen','float','FloatAdd','FloatSub','FloatMul','FloatDiv','FloatCompare','RoundToNearest','RoundToCeil','RoundToFloor','RoundToZero','SquareRoot','FloatAbs','GetTickInterval'):
            v, s = Emu2.native(self, cip, name, params, nargs)
            return v, None
        cs = lambda k: self.cstr(A(k)) or ''
        self.trace.append(('nat', cip, name, [self.argdesc(params, k) for k in range(1, nargs+1)]))
        if name in ('CreateConVar', 'SMAC_CreateConVar'):
            return self.cvar(cs(1), cs(2)), None
        if name == 'FindConVar':
            n = cs(1).lower()
            if n in self.byname: return self.byname[n], None
            if n in SERVER_CVARS or n in self.cfg: return self.cvar(n, SERVER_CVARS.get(n, '0')), None
            return 0, None
        if name in ('GetConVarInt', 'GetConVarBool'):
            c = self.cvars.get(A(1))
            if not c: return 0, None
            try: v = int(float(c[1]))
            except Exception: v = 0
            return (int(bool(v)) if name == 'GetConVarBool' else s32(v)), None
        if name == 'GetConVarFloat':
            c = self.cvars.get(A(1))
            try: return f2i(float(c[1])), None
            except Exception: return 0, None
        if name in ('GetConVarString', 'GetConVarDefault', 'GetConVarName'):
            c = self.cvars.get(A(1))
            v = '' if not c else {'GetConVarString': c[1], 'GetConVarDefault': c[2], 'GetConVarName': c[0]}[name]
            self.wstr(A(2), v, A(3)); return len(v), None
        if name in ('SetConVarInt', 'SetConVarFloat', 'SetConVarString', 'SetConVarBool'):
            c = self.cvars.get(A(1))
            if c:
                c[1] = str(A(2)) if name in ('SetConVarInt','SetConVarBool') else ('%g' % i2f(A(2)) if name == 'SetConVarFloat' else cs(2))
            return 0, None
        if name == 'HookConVarChange': self.hooks.append((A(1), A(2))); return 0, None
        if name == 'HookEvent': self.events.append((cs(1), A(2), A(3) if nargs >= 3 else 1)); return 1, None
        if name == 'HookEventEx': self.events.append((cs(1), A(2), A(3) if nargs >= 3 else 1)); return 1, None
        if name == 'CreateTimer': self.timers.append(('%g' % i2f(A(1)), A(2), A(3), A(4) if nargs >= 4 else 0)); return self.newh(), None
        if name in ('RegConsoleCmd', 'RegAdminCmd', 'RegServerCmd', 'AddCommandListener'): self.cmds.append((name, cs(1) if name != 'AddCommandListener' else cs(2), A(2) if name != 'AddCommandListener' else A(1))); return 1, None
        if name in ('SDKHook',): self.sdkhooks.append((A(1), A(2), A(3))); return 1, None
        if name in ('CreateTrie', 'CreateArray', 'CreateDataPack', 'CreateKeyValues', 'OpenFile', 'LoadGameConfigFile', 'CreateGlobalForward', 'CreateForward', 'GetMyHandle', 'GetPluginIterator', 'StartMessage', 'StartMessageEx', 'CreateStack'):
            return self.newh(), None
        if name == 'GetFunctionByName':
            nm = cs(2)
            for i, (pa, pn) in enumerate(self.p.s.publics()):
                if pn == nm: return (i << 1) | 1, None
            return 0, None
        if name == 'GetGameFolderName': self.wstr(A(1), 'cstrike', A(2)); return 7, None
        if name == 'GetGameDescription': self.wstr(A(1), 'Counter-Strike: Source', A(2)); return 1, None
        if name == 'GetEngineVersion': return 2, None
        if name == 'GetFeatureStatus': return 0, None
        if name == 'GetExtensionFileStatus': return 1, None
        if name in ('FileExists', 'DirExists'): return 1, None
        if name == 'FileSize':
            pth = cs(1)
            if pth.endswith('.dll'): return 79360, None
            if pth.endswith('.so'): return 126896, None
            return 100, None
        if name == 'GetFileTime': return 1523300000, None
        if name == 'GetTime': return 1523300000, None
        if name == 'GetMaxClients': return 2, None
        if name in ('GetTickCount', 'GetGameTickCount'): return 777777, None
        if name in ('GetGameTime', 'GetEngineTime'): return f2i(12345.5), None
        if name == 'GetCurrentMap': self.wstr(A(1), 'de_dust2', A(2)); return 8, None
        if name == 'FindSendPropOffs' or name == 'FindSendPropInfo' or name == 'FindDataMapOffs': return 100, None
        if name in ('GetRandomInt',): return A(1), None
        if name in ('GetRandomFloat', 'GetURandomFloat'): return f2i(0.5) if name == 'GetURandomFloat' else A(1), None
        if name == 'GetURandomInt': return 12345, None
        if name in ('IsClientInGame', 'IsClientConnected', 'IsPlayerAlive', 'IsClientAuthorized'): return 1, None
        if name in ('IsFakeClient', 'IsClientObserver', 'IsClientInKickQueue', 'IsClientSourceTV', 'IsClientReplay'): return 0, None
        if name == 'GetClientTeam': return 2, None
        if name == 'GetClientUserId': return 2, None
        if name == 'GetClientOfUserId': return 1, None
        if name in ('GetClientName', 'GetClientAuthString', 'GetClientIP', 'GetClientWeapon', 'GetClientModel', 'GetCmdArgString', 'GetCmdArg', 'GetEventString', 'GetPluginFilename', 'ReadFileLine', 'GetCmdStr', 'GetEntityNetClass', 'GetEdictClassname', 'GetEntityClassname', 'GameConfGetKeyValue', 'FormatTime', 'ReadPackString', 'GetArrayString', 'ReadFileString'):
            v = {'GetClientIP': '1.2.3.4', 'GetClientAuthString': 'STEAM_0:1:1', 'GetClientName': 'player', 'GetClientWeapon': 'weapon_ak47'}.get(name, '')
            k = 1 if name in ('GetCmdArgString','GetCmdStr','FormatTime') else (2 if name not in ('GetEventString','GameConfGetKeyValue','GetArrayString','ReadPackString') else 3)
            if name in ('ReadPackString','ReadFileLine','ReadFileString','GetPluginFilename','GetEntityNetClass','GetEdictClassname','GetEntityClassname','GetClientName','GetClientAuthString','GetClientIP','GetClientWeapon','GetClientModel','GetCmdArg'): k = 2
            try: self.wstr(A(k), v, A(k+1))
            except Exception: pass
            return 1, None
        if name == 'GetVectorDistance' or name == 'GetVectorLength' or name == 'GetVectorDotProduct': return f2i(0.0), None
        if name == 'MorePlugins': return 0, None
        if name == 'GetPluginStatus': return 0, None
        if name == 'GetTrieValue': return 0, None
        if name == 'GetArraySize': return 0, None
        if name in ('ReadPlugin',): return 0, None
        return 0, None
def run_concrete(h, entry, args, tag, maxsteps=50000000):
    h.MAX_STEPS = maxsteps
    h.sym_all_globals = False
    h.concrete_mode = True
    h.mem = h.mem  # keep
    stk = h.memsize - 0x100; hea = h.hea_base if hasattr(h, 'hea_base') else h.datasize + 0x40000
    for v in reversed(args):
        stk -= 4; h.wr(stk, v)
    stk -= 4; h.wr(stk, len(args)); stk -= 4; h.wr(stk, -1)
    h.trace = []
    work = []
    st = (entry, 0, None, 0, None, 0, stk, hea, len(h.undo), [])
    try:
        h.run_path(st, work)
        res = 'ok'
    except Kill as k:
        res = 'kill ' + str(k)
    return res, h.trace, len(work)
