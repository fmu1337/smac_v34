import struct, zlib, sys, re
def cstr(b, off):
    e = b.index(b'\0', off); return b[off:e].decode('latin1')
class SMX:
    def __init__(self, path):
        d = open(path,'rb').read()
        magic,ver,comp,disk,img,nsec,stab,doff = struct.unpack('<IHBIIBII', d[:24])
        assert magic == 0x53504646, hex(magic)
        self.version=ver; self.comp=comp
        if comp == 1:
            raw = d[:doff] + zlib.decompress(d[doff:])
        else:
            raw = d
        self.raw = raw
        self.sections = {}
        for i in range(nsec):
            no, do, sz = struct.unpack('<III', raw[24+i*12:36+i*12])
            name = cstr(raw, stab+no)
            self.sections[name] = (do, sz)
        self.names_off = self.sections.get('.names',(0,0))[0]
    def sec(self, n):
        o,s = self.sections[n]; return self.raw[o:o+s]
    def name(self, off):
        return cstr(self.raw, self.names_off+off)
    def natives(self):
        o,s = self.sections['.natives']
        return [self.name(struct.unpack('<I', self.raw[o+i*4:o+i*4+4])[0]) for i in range(s//4)]
    def publics(self):
        o,s = self.sections['.publics']
        r=[]
        for i in range(s//8):
            a,n = struct.unpack('<II', self.raw[o+i*8:o+i*8+8]); r.append((a,self.name(n)))
        return r
    def pubvars(self):
        if '.pubvars' not in self.sections: return []
        o,s = self.sections['.pubvars']
        r=[]
        for i in range(s//8):
            a,n = struct.unpack('<II', self.raw[o+i*8:o+i*8+8]); r.append((a,self.name(n)))
        return r
    def code(self):
        o,s = self.sections['.code']
        codesize, cellsize, codever, flags, main, codeoffs = struct.unpack('<IBBHII', self.raw[o:o+16])
        self.codever=codever
        return self.raw[o+codeoffs:o+codeoffs+codesize]
    def data(self):
        o,s = self.sections['.data']
        datasize, memsize, dataoffs = struct.unpack('<III', self.raw[o:o+12])
        return self.raw[o+dataoffs:o+dataoffs+datasize], memsize
