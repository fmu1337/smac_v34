import sys,time,pickle; sys.path.insert(0,'.')
from tools import P
from emu import Emu, Kill
def boot(path):
    p=P(path)
    e=Emu(p)
    pubs={n:a for a,n in p.s.publics()}
    e.MAX_STEPS=20000000
    errbuf = e.memsize - 0x20000
    e.explore(pubs['AskPluginLoad2'], [(1,False),(0,False),(errbuf,False),(256,False)], 'APL2')
    # commit memory as new base
    e.base = bytearray(e.mem)
    e.undo = []
    return p, e, pubs
