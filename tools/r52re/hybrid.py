import sys, pickle, time; sys.path.insert(0,'.')
from tools import P
from host import Host, load_cfg, run_concrete
from emu2 import Emu2, Kill
CVARNAT = {'GetConVarInt','GetConVarBool','GetConVarFloat','GetConVarString','GetConVarDefault','GetConVarName','FindConVar'}
class Hybrid(Host):
    def native(self, cip, name, params, nargs):
        if self.concrete_mode or name in CVARNAT:
            return Host.native(self, cip, name, params, nargs)
        return Emu2.native(self, cip, name, params, nargs)
def prepare(path, cfgpath='r52/cfg/sourcemod/smac.cfg', client_init=('OnClientConnected','OnClientPutInServer')):
    name = path.split('/')[-1].split('.')[0]
    p = P(path)
    base = pickle.load(open('base_%s.bin' % name, 'rb'))
    h = Hybrid(p, base, load_cfg(cfgpath)); h.reset()
    pubs = {n: a for a, n in p.s.publics()}
    for pub in ('OnPluginStart', 'OnConfigsExecuted', 'OnMapStart'):
        if pub in pubs:
            res, tr, f = run_concrete(h, pubs[pub], [], pub)
            print(pub, res, file=sys.stderr)
    cfgw = set(a & ~3 for (a, _, _, _) in h.undo if a < h.datasize)
    mark = len(h.undo)
    for pub in client_init:
        if pub in pubs:
            args = [1] if pub != 'OnClientConnected' else [1]
            res, tr, f = run_concrete(h, pubs[pub], args, pub)
            print(pub, res, file=sys.stderr)
    cs = set(a & ~3 for (a, _, _, _) in h.undo[mark:] if a < h.datasize)
    h.base = bytearray(h.mem)
    h.cfg_written = cfgw - cs
    h.client_state = cs
    from carrays import client_arrays
    h.client_bases, h.client_cells = client_arrays(p)
    import struct as _st
    pool = set()
    d = p.data
    for a in range(0, len(d)-3, 4):
        v0 = _st.unpack_from('<i', d, a)[0]
        if v0 in (-2, -1090519040, -1110651699) and h.base[a:a+4] != d[a:a+4]:
            pool.add(a)
    # include -1 filled neighbours of pool cells
    for a in list(pool):
        for nb in (a+4, a-4):
            if 0 <= nb < len(d)-3 and _st.unpack_from('<i', d, nb)[0] == -1 and h.base[nb:nb+4] != d[nb:nb+4]: pool.add(nb)
    il = set()
    for a in range(0, len(d)-3, 4):
        v = _st.unpack_from('<i', d, a)[0]
        if v > 0 and v % 4 == 0 and a + v < len(d) and v < 0x40000:
            il.add(a)
    h.const_globals = h.const_globals | pool | il
    from sym import f2i as _f2i
    timecells = set()
    for a in range(0, len(d)-3, 4):
        v = _st.unpack_from('<i', h.base, a)[0]
        if v in (777777, _f2i(12345.5)): timecells.add(a)
    h.client_state = h.client_state | timecells
    print('time cells', len(timecells), file=sys.stderr)
    h.client_cells = h.client_cells - il
    h.client_cells = h.client_cells - pool
    print('const pool', len(pool), file=sys.stderr)
    h.hybrid = True; h.concrete_mode = False
    h.reset()
    return p, h, pubs
