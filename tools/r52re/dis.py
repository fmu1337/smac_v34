import struct, json, sys
sys.path.insert(0,'.')
from smx import SMX
OPS = json.load(open('ops.json'))
OPN = {o[0]:i for i,o in enumerate(OPS)}
def disasm(code):
    n = len(code)//4
    cells = struct.unpack('<%di'%n, code[:n*4])
    out = []
    i = 0
    while i < n:
        op = cells[i]
        if op < 0 or op >= len(OPS):
            out.append((i*4, 'BAD%d'%op, ())); i+=1; continue
        name, mn, size, kind = OPS[op]
        if name == 'CASETBL':
            num = cells[i+1]
            size = 3 + 2*num
        if size is None:
            out.append((i*4, 'U_'+name, ())); i+=1; continue
        out.append((i*4, name, cells[i+1:i+size]))
        i += size
    return out
if __name__ == '__main__':
    s = SMX(sys.argv[1])
    ins = disasm(s.code())
    from collections import Counter
    c = Counter(x[1] for x in ins)
    print(len(ins), c.most_common(60))
