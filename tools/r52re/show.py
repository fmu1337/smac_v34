import pickle,sys; sys.path.insert(0,'.')
from sym import fmt
def line(ev, w=220):
    if ev[0]=='br': return 'BR %06x %s -> %s' % (ev[1], fmt(ev[2])[:w], ev[3])
    if ev[0]=='sw': return 'SW %06x %s = %s' % (ev[1], fmt(ev[2])[:w], ev[3])
    if ev[0]=='nat': return 'NAT %06x %s(%s)' % (ev[1], ev[2], ', '.join(ev[3])[:w])
    if ev[0]=='fmt': return 'FMT %06x %r' % (ev[1], ev[2][:w])
    if ev[0]=='st': return 'ST %06x g%x = %s' % (ev[1], ev[2], fmt(ev[3])[:w])
    return str(ev)
def show(tr, n=10**9, w=220):
    for ev in tr[:n]: print('  '+line(ev, w))
