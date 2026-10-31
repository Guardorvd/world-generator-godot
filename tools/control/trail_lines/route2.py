import numpy as np, heapq, math
from route import rdp, fillet, resample, chaikin
STEP=4.0
DIRS=[]
for dx in range(-2,3):
    for dz in range(-2,3):
        if (dx,dz)!=(0,0) and math.gcd(abs(dx),abs(dz))==1: DIRS.append((dx,dz))
ANG=[math.atan2(dz,dx) for dx,dz in DIRS]
def astar(H,gx,gz,n,a,b,gmin,gmax,cross_w,turn_w,hairpin,avoid,d0=None):
    ia=(int(round(a[0]/STEP)),int(round(a[1]/STEP))); ib=(int(round(b[0]/STEP)),int(round(b[1]/STEP)))
    start=(ia,d0 if d0 is not None else -1)
    dist={start:0.0}; prev={}; pq=[(0.0,0.0,start)]; end=None
    while pq:
        f,d,s=heapq.heappop(pq)
        u,di=s
        if u==ib: end=s; break
        if d>dist.get(s,1e18): continue
        for k,(dx,dz) in enumerate(DIRS):
            v=(u[0]+dx,u[1]+dz)
            if not(6<=v[0]<n-6 and 6<=v[1]<n-6): continue
            L=STEP*math.hypot(dx,dz)
            g=(H[v]-H[u])/L
            ex=max(0.0,g-gmax,gmin-g)
            ux,uz=dx/math.hypot(dx,dz),dz/math.hypot(dx,dz)
            side=abs(-gx[v]*uz+gz[v]*ux)
            c=L*(1+(ex/0.02)**2+cross_w*side*side)
            if di>=0:
                dang=abs((ANG[k]-ANG[di]+math.pi)%(2*math.pi)-math.pi)
                c+=turn_w*dang*dang + (hairpin if dang>2.0 else 0.0)
            if avoid is not None: c+=L*avoid(v[0]*STEP,v[1]*STEP)
            t=(v,k); nd=d+c
            if nd<dist.get(t,1e18):
                dist[t]=nd; prev[t]=s
                h=STEP*math.hypot(ib[0]-v[0],ib[1]-v[1])
                heapq.heappush(pq,(nd+h,nd,t))
    path=[end]
    while path[-1]!=start: path.append(prev[path[-1]])
    path.reverse()
    return [(p[0][0]*STEP,p[0][1]*STEP) for p in path], end[1]
def route(ground,vias,gmin,gmax,cross_w=0.6,turn_w=6.0,hairpin=25.0,eps=2.5,rmin=8.0,rmax=40.0,avoid=None,size=512):
    n=int(size/STEP)+1; xs=np.arange(n)*STEP; X,Z=np.meshgrid(xs,xs,indexing='ij'); H=ground(X,Z); gx,gz=np.gradient(H,STEP)
    pts=[];d0=None
    for a,b in zip(vias[:-1],vias[1:]):
        seg,d0=astar(H,gx,gz,n,a,b,gmin,gmax,cross_w,turn_w,hairpin,avoid,d0)
        pts+= seg if not pts else seg[1:]
    pts[0]=vias[0]; pts[-1]=vias[-1]
    return resample(chaikin(rdp(pts,eps),5),2.0)
def radius_at(p,i,k=2):
    a=np.array(p[i-k]);b=np.array(p[i]);c=np.array(p[i+k])
    ab=b-a;bc=c-b
    ang=math.atan2(ab[0]*bc[1]-ab[1]*bc[0],ab@bc)
    return (np.linalg.norm(ab)+np.linalg.norm(bc))*0.5/max(abs(ang),1e-6)
def relax(pts,rmin=8.0,passes=200):
    p=[list(q) for q in pts]
    for _ in range(passes):
        bad=0
        for i in range(3,len(p)-3):
            if radius_at(p,i)<rmin:
                bad+=1
                for j in (i-1,i,i+1):
                    p[j][0]=0.5*p[j][0]+0.25*(p[j-1][0]+p[j+1][0]); p[j][1]=0.5*p[j][1]+0.25*(p[j-1][1]+p[j+1][1])
        if bad==0: break
    return resample([tuple(q) for q in p],2.0)
