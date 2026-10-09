import smx,struct,sys,re
h=re.compile(r'^_?[A-Za-z0-9][0-9a-f]{30,34}[A-Za-z_]?$')
def syms(path):
    p=smx.SMX(path); raw=p.raw
    so,ss=p.sections['.dbg.strings']; st=raw[so:so+ss]
    o,s=p.sections['.dbg.symbols']
    names={}
    i=0
    while i<len(st):
        e=st.index(b'\0',i); names[i]=st[i:e].decode('latin1'); i=e+1
    res=[]
    sec=raw[o:o+s]
    for j in range(18,len(sec)-4):
        off=struct.unpack_from('<I',sec,j)[0]
        if off in names and names[off] and not h.match(names[off]):
            addr,tag,cs,ce,ident,vcls,dim=struct.unpack_from('<iHIIbbh',sec,j-18)
            if 0<=dim<=3 and ident in (1,2,3,4,8,9) and vcls in (0,1,2):
                dims=[struct.unpack_from('<HI',sec,j+4+6*d)[1] for d in range(dim)]
                res.append((names[off],addr,ident,vcls,dims,cs,ce))
    return res
if __name__=='__main__':
    for r in syms(sys.argv[1]):
        if r[3]==0 or (len(sys.argv)>2): print(r[0],hex(r[1]),r[2],r[3],r[4],hex(r[5]),hex(r[6]))
