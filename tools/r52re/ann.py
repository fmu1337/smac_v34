import re, struct
from sym import i2f
def annotate(s, base):
    def rep(m):
        a = int(m.group(1), 16)
        if a + 4 <= len(base):
            v = struct.unpack_from('<i', base, a)[0]
            if v != 0:
                f = i2f(v)
                if 1e-4 < abs(f) < 1e7 and abs(v) > 0x100000: return '%s{=%gf}' % (m.group(0), f)
                return '%s{=%d}' % (m.group(0), v)
        return m.group(0)
    return re.sub(r'\bg([0-9a-f]{3,6})\b', rep, s)
