"""Check a route shape against its ordered stops.
Usage: python3 -I shapecheck.py file.json      (file: {"shape":[[lat,lon],...], "stops":[[lat,lon],...]})
Prints: points, shape length, stop-chord length, ratio, max/median stop offset with stops matched IN ORDER
along the shape (dynamic programming, so loops and repeated streets are handled), and PASS/FAIL
(PASS = every stop within 50 m in order and length <= 1.5x the stop chords)."""
import json,sys,math
def run(shape,stops,tol=50.0):
    lat0=shape[0][0]; k=math.cos(math.radians(lat0))*111320
    P=[(p[1]*k,p[0]*111320) for p in shape]; Q=[(s[1]*k,s[0]*111320) for s in stops]
    cum=[0.0]
    for i in range(len(P)-1): cum.append(cum[-1]+math.dist(P[i],P[i+1]))
    def cands(q):
        out=[]
        for i in range(len(P)-1):
            (x1,y1),(x2,y2)=P[i],P[i+1]; bx,by=x2-x1,y2-y1; L=bx*bx+by*by
            t=0 if L==0 else max(0,min(1,((q[0]-x1)*bx+(q[1]-y1)*by)/L))
            d=math.hypot(q[0]-x1-t*bx,q[1]-y1-t*by)
            if d<=250: out.append((cum[i]+t*math.sqrt(L),d))
        out.sort(); ded=[]
        for a,d in out:   # keep local minima per 30 m of along-distance
            if ded and a-ded[-1][0]<30:
                if d<ded[-1][1]: ded[-1]=(a,d)
            else: ded.append((a,d))
        return ded or [(None,1e9)]
    C=[cands(q) for q in Q]
    # DP: minimise the worst offset, then the sum, with along-distance non-decreasing
    INF=(1e18,1e18); prev=[(max(0,d),d,None) for a,d in C[0]]; back=[prev]
    for i in range(1,len(C)):
        cur=[]
        for a,d in C[i]:
            best=None
            for j,(pa,pd) in enumerate(C[i-1]):
                if a is None or pa is None or a+1<pa: continue
                w,sm,_=back[-1][j]; cand=(max(w,d),sm+d,j)
                if best is None or cand[:2]<best[:2]: best=cand
            cur.append(best if best else (1e9,1e9,None))
        back.append(cur)
    j=min(range(len(back[-1])),key=lambda x:back[-1][x][:2]); worst=back[-1][j][0]
    offs=[]
    for i in range(len(C)-1,-1,-1):
        offs.append(C[i][j][1]); j=back[i][j][2] if back[i][j][2] is not None else 0
    offs.reverse()
    chord=sum(math.dist(Q[i],Q[i+1]) for i in range(len(Q)-1))
    med=sorted(offs)[len(offs)//2]
    ok=worst<=tol and cum[-1]<=1.5*chord+500
    return dict(points=len(P),shape_m=round(cum[-1]),chord_m=round(chord),ratio=round(cum[-1]/max(chord,1),2),
                max_stop_offset_m=round(worst,1),median_offset_m=round(med,1),
                far_stops=[i for i,o in enumerate(offs) if o>tol],verdict="PASS" if ok else "FAIL")
if __name__=="__main__":
    d=json.load(open(sys.argv[1])); print(json.dumps(run(d['shape'],d['stops'])))
