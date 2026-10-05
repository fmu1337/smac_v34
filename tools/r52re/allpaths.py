import pickle
def load_all(files):
    paths=[]
    for f in files:
        obj=pickle.load(open(f,'rb'))
        if isinstance(obj,tuple):
            res,base=obj
            for k,v in res.items(): paths.extend(v[1])
        else: paths.extend(obj)
    return paths
