import struct
def _rd(d, a): return struct.unpack_from('<i', d, a)[0]
def _is_vec(d, a, ds):
    if a + 8 > ds: return False
    v0 = _rd(d, a); v1 = _rd(d, a+4)
    return v0 > 0 and v0 % 4 == 0 and a + v0 < ds and v1 > 0 and v1 % 4 == 0 and (a + 4 + v1) > (a + v0)
def region_end(d, a, n, ds, depth=0):
    """a: address of vector with n entries. returns end address of data"""
    if depth > 4 or not _is_vec(d, a, ds): return a + 4*n
    starts = [a + 4*k + _rd(d, a + 4*k) for k in range(n)]
    rl = starts[1] - starts[0]
    if rl <= 0: return a + 4*n
    sub_n = rl // 4
    last = starts[-1]
    if _is_vec(d, last, ds):
        # rows are vectors; their count = (first data start - row start)/4
        inner = _rd(d, starts[0])
        m = inner // 4
        return max(last + rl, region_end(d, last, m, ds, depth+1))
    return last + rl
def client_arrays(p, maxidx=(0x40, 0x41)):
    ins = p.ins; ds = len(p.data); d = p.data
    bases = {}
    for i, (a, n, pp) in enumerate(ins):
        if n == 'BOUNDS' and pp[0] in maxidx:
            for j in range(i-1, max(0, i-10), -1):
                aa, nn, qq = ins[j]
                if nn in ('CONST_ALT', 'CONST_PRI') and 0 < qq[0] < ds:
                    bases[qq[0]] = pp[0] + 1; break
                if nn in ('PROC', 'CALL', 'RETN'): break
    cells = set()
    for b, n in bases.items():
        e = region_end(d, b, n, ds)
        if e - b > 0x200000: e = b + 4*n
        for c in range(b, e, 4): cells.add(c)
    return bases, cells
