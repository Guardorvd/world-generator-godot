import numpy as np, heapq, math
STEP=2.0
DIRS=[]
for dx in range(-2,3):
    for dz in range(-2,3):
        if (dx,dz)!=(0,0) and math.gcd(abs(dx),abs(dz))==1: DIRS.append((dx,dz))
def astar(ground, a, b, gmin, gmax, size=512, cross_w=0.6, avoid=None):
    n=int(size/STEP)+1
    xs=np.arange(n)*STEP
    X,Z=np.meshgrid(xs,xs,indexing='ij')
    H=ground(X,Z)
    gx,gz=np.gradient(H,STEP)
    ia=(int(round(a[0]/STEP)),int(round(a[1]/STEP))); ib=(int(round(b[0]/STEP)),int(round(b[1]/STEP)))
    dist={ia:0.0}; prev={}; pq=[(0.0,0.0,ia)]
    while pq:
        f,d,u=heapq.heappop(pq)
        if u==ib: break
        if d>dist.get(u,1e18): continue
        for dx,dz in DIRS:
            v=(u[0]+dx,u[1]+dz)
            if not(2<=v[0]<n-2 and 2<=v[1]<n-2): continue
            L=STEP*math.hypot(dx,dz)
            g=(H[v]-H[u])/L
            ex=max(0.0,g-gmax,gmin-g)
            # поперечный склон к направлению: тропа на крутом боку хуже
            ux,uz=dx/math.hypot(dx,dz),dz/math.hypot(dx,dz)
            side=abs(-gx[v]*uz+gz[v]*ux)
            c=L*(1+ (ex/0.02)**2 + cross_w*side*side)
            if avoid is not None: c+=L*avoid(v[0]*STEP,v[1]*STEP)
            nd=d+c+0.0
            if nd<dist.get(v,1e18):
                dist[v]=nd; prev[v]=u
                h=STEP*math.hypot(ib[0]-v[0],ib[1]-v[1])
                heapq.heappush(pq,(nd+h*0.999,nd,v))
    path=[ib]
    while path[-1]!=ia: path.append(prev[path[-1]])
    return [(p[0]*STEP,p[1]*STEP) for p in reversed(path)]
def chaikin(pts,it=3):
    for _ in range(it):
        out=[pts[0]]
        for p,q in zip(pts[:-1],pts[1:]):
            out.append((0.75*p[0]+0.25*q[0],0.75*p[1]+0.25*q[1])); out.append((0.25*p[0]+0.75*q[0],0.25*p[1]+0.75*q[1]))
        out.append(pts[-1]); pts=out
    return pts
def resample(pts,step=2.0):
    out=[pts[0]]; acc=0.0
    for p,q in zip(pts[:-1],pts[1:]):
        seg=math.hypot(q[0]-p[0],q[1]-p[1]); t=0.0
        while acc+seg-t>=step:
            t+=step-acc; acc=0.0
            out.append((p[0]+(q[0]-p[0])*t/seg,p[1]+(q[1]-p[1])*t/seg))
        acc+=seg-t
    if math.hypot(out[-1][0]-pts[-1][0],out[-1][1]-pts[-1][1])>0.5: out.append(pts[-1])
    return out
def route(ground, vias, gmin, gmax, **kw):
    pts=[]
    for a,b in zip(vias[:-1],vias[1:]):
        seg=astar(ground,a,b,gmin,gmax,**kw)
        pts+= seg if not pts else seg[1:]
    return resample(chaikin(pts,4),2.0)
def report(ground,pts,name):
    L=0;hs=[float(ground(*pts[0]))];g=[]
    for p,q in zip(pts[:-1],pts[1:]):
        L+=math.hypot(q[0]-p[0],q[1]-p[1])
    arr=np.array(pts); h=ground(arr[:,0],arr[:,1])
    gr=(h[2:]-h[:-2])/4.0
    # curvature radius
    rad=[]
    for i in range(2,len(pts)-2):
        a=np.array(pts[i-2]);b=np.array(pts[i]);c=np.array(pts[i+2])
        ab=b-a;bc=c-b; ang=math.atan2(ab[0]*bc[1]-ab[1]*bc[0],ab@bc); 
        rad.append(4.0/max(abs(ang),1e-6))
    rad=np.array(rad)
    print(f"{name}: {L:.0f} м, перепад {h[0]-h.min():.0f}, уклон p5 {np.percentile(gr,5)*100:.0f}% p95 {np.percentile(gr,95)*100:.0f}%, мин радиус {rad.min():.1f} м, радиусов<12: {(rad<12).sum()}")
def rdp(pts,eps):
    if len(pts)<3: return pts
    a=np.array(pts[0]);b=np.array(pts[-1]); ab=b-a; L=np.linalg.norm(ab)+1e-9
    dmax=0;idx=0
    for i in range(1,len(pts)-1):
        p=np.array(pts[i]); d=abs(ab[0]*(p-a)[1]-ab[1]*(p-a)[0])/L
        if d>dmax: dmax=d;idx=i
    if dmax>eps: return rdp(pts[:idx+1],eps)[:-1]+rdp(pts[idx:],eps)
    return [pts[0],pts[-1]]
def fillet(pts,rmin=7.0,rmax=40.0):
    out=[pts[0]]
    for i in range(1,len(pts)-1):
        p=np.array(out[-1]);c=np.array(pts[i]);n=np.array(pts[i+1])
        u=(c-p);lu=np.linalg.norm(u);v=(n-c);lv=np.linalg.norm(v)
        if lu<1e-6 or lv<1e-6: continue
        u/=lu;v/=lv; turn=math.atan2(u[0]*v[1]-u[1]*v[0],u@v)
        if abs(turn)<0.02: out.append(tuple(c)); continue
        t_need=lambda r: r*math.tan(abs(turn)/2)
        r=rmax
        tmax=min(lu*0.5 if i>1 else lu*0.9, lv*0.5)
        while r>rmin and t_need(r)>tmax: r*=0.9
        r=max(r,rmin); t=t_need(r)
        a=c-u*t
        center=a+np.array([-u[1],u[0]])*math.copysign(r,turn)
        k=max(2,int(abs(turn)*r/1.5))
        av=a-center
        for j in range(k+1):
            ang=turn*j/k
            rot=np.array([av[0]*math.cos(ang)-av[1]*math.sin(ang),av[0]*math.sin(ang)+av[1]*math.cos(ang)])
            out.append(tuple(center+rot))
    out.append(pts[-1]); return out
def route2(ground, vias, gmin, gmax, eps=3.0, rmin=7.0, **kw):
    pts=[]
    for a,b in zip(vias[:-1],vias[1:]):
        seg=astar(ground,a,b,gmin,gmax,**kw)
        pts+= seg if not pts else seg[1:]
    return resample(fillet(rdp(pts,eps),rmin),2.0)
