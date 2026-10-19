import json,sys,math
T="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
D={c:i for i,c in enumerate(T)}
def uvars(s):
    r=0;sh=0
    for c in s:
        v=D[c]; r|=(v&0x1f)<<sh
        if v&0x20: sh+=5
        else: yield r; r=0; sh=0
def decode(s):
    it=uvars(s); ver=next(it); h=next(it)
    prec=h&15; td=(h>>4)&7; tprec=(h>>7)&15
    f=10**prec; lat=lon=z=0; out=[]
    def zz(u): return ~(u>>1) if u&1 else u>>1
    while True:
        try: a=next(it)
        except StopIteration: break
        b=next(it); lat+=zz(a); lon+=zz(b)
        if td: z+=zz(next(it))
        out.append((lat/f,lon/f) if not td else (lat/f,lon/f,z/10**tprec))
    return ver,prec,td,out
def hav(a,b):
    R=6371000;p1,p2=math.radians(a[0]),math.radians(b[0]);dp=p2-p1;dl=math.radians(b[1]-a[1])
    x=math.sin(dp/2)**2+math.cos(p1)*math.cos(p2)*math.sin(dl/2)**2
    return 2*R*math.asin(math.sqrt(x))
if __name__=="__main__":
    s=json.load(open(sys.argv[1]))['data']
    ver,prec,td,pts=decode(s)
    print("ver",ver,"prec",prec,"3rd",td,"points",len(pts))
    print(pts[:3],pts[-2:])
    L=sum(hav(pts[i],pts[i+1]) for i in range(len(pts)-1)); print("length m",round(L))
    json.dump([p[:2] for p in pts],open(sys.argv[2],'w'))
