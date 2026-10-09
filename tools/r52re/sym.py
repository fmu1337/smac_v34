import struct, math
def s32(x):
    x &= 0xffffffff
    return x - 0x100000000 if x & 0x80000000 else x
def i2f(i): return struct.unpack('<f', struct.pack('<i', s32(i)))[0]
def f2i(f):
    try: return struct.unpack('<i', struct.pack('<f', f))[0]
    except OverflowError: return struct.unpack('<i', struct.pack('<f', math.copysign(float('inf'), f)))[0]

# expression: None (concrete) or tuple
def is_c(e): return e is None
def mk(op, a, b, av, bv):
    """build symbolic expr for binary op where a/b are exprs (None means concrete av/bv)"""
    A = a if a is not None else ('k', av)
    B = b if b is not None else ('k', bv)
    # simplifications
    if op == 'xor':
        if A[0] == 'k' and A[1] == 0: return B
        if B[0] == 'k' and B[1] == 0: return A
        if A[0] == 'xor' and A[2][0] == 'k' and B[0] == 'k':
            v = A[2][1] ^ B[1]
            return A[1] if v == 0 else ('xor', A[1], ('k', v))
    if op == 'add':
        if B[0] == 'k' and B[1] == 0: return A
        if A[0] == 'k' and A[1] == 0: return B
        if A[0] == 'add' and A[2][0] == 'k' and B[0] == 'k':
            v = s32(A[2][1] + B[1])
            return A[1] if v == 0 else ('add', A[1], ('k', v))
    if op == 'sub':
        if B[0] == 'k' and B[1] == 0: return A
    if op == 'mul':
        if B[0] == 'k' and B[1] == 1: return A
        if A[0] == 'k' and A[1] == 1: return B
    return (op, A, B)
def un(op, a):
    if op == 'neg' and a[0] == 'neg': return a[1]
    if op == 'not' and a[0] == 'not' and a[1][0] in ('eq','neq','lt','le','gt','ge','not'): return a[1]
    return (op, a)

INFIX = {'add':'+','sub':'-','mul':'*','div':'/','mod':'%','xor':'^','and':'&','or':'|','shl':'<<','shr':'>>>','sshr':'>>',
         'eq':'==','neq':'!=','lt':'<','le':'<=','gt':'>','ge':'>=',
         'fadd':'+.','fsub':'-.','fmul':'*.','fdiv':'/.'}
def fmt(e, depth=0, flt=False):
    if e is None: return '?'
    if depth > 12: return '…'
    t = e[0]
    if t == 'k':
        v = e[1]
        if flt:
            f = i2f(v)
            return ('%g' % f) if abs(f) < 1e9 else str(v)
        if abs(v) > 0x1000000:
            f = i2f(v)
            if 1e-5 < abs(f) < 1e7: return '%gf' % f
        return str(v)
    if t == 'v': return e[1]
    if t in INFIX:
        isf = t.startswith('f')
        return '(%s %s %s)' % (fmt(e[1], depth+1, isf or flt and False), INFIX[t], fmt(e[2], depth+1, isf))
    if t == 'neg': return '-' + fmt(e[1], depth+1)
    if t == 'not': return '!' + fmt(e[1], depth+1)
    if t == 'inv': return '~' + fmt(e[1], depth+1)
    if t == 'call':
        fl = e[1] in ('float','FloatAbs','SquareRoot','RoundToNearest','RoundToCeil','RoundToFloor','FloatCompare','FloatAdd','FloatSub','FloatMul','FloatDiv','GetVectorDistance','GetVectorLength','GetVectorDotProduct')
        return '%s(%s)' % (e[1], ', '.join(fmt(x, depth+1, fl and e[1] not in ('float',)) for x in e[2]))
    if t == 'mem':
        return '%s[%s]' % (e[1], fmt(e[2], depth+1))
    if t == 'fcmp':
        return 'cmp(%s, %s)' % (fmt(e[1], depth+1, True), fmt(e[2], depth+1, True))
    return str(e)
