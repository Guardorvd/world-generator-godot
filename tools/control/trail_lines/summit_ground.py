import numpy as np, matplotlib, re
matplotlib.use("Agg")
import matplotlib.pyplot as plt
A=np.array([250.,458.]); B=np.array([438.,214.])
def ground(x,z):
    dx=(x-250)/1.0; dz=(z-458)
    d=np.sqrt(dx*dx+dz*dz)
    cone=150/(1+(d/200)**1.5)
    ab=B-A; L2=(ab**2).sum()
    u=np.clip(((x-A[0])*ab[0]+(z-A[1])*ab[1])/L2,0,1)
    px=A[0]+u*ab[0]; pz=A[1]+u*ab[1]; w=np.hypot(x-px,z-pz)
    top=146-72*u
    ridge=top*np.exp(-(w/95)**2)
    apron=50+32*np.exp(-((x-430)/70)**2-((z-140)/62)**2)
    h=np.maximum(np.maximum(cone,ridge),apron-8-0.0*z)
    gx=165+15*np.sin(z/70)
    gully=-5*np.exp(-((x-gx)/8)**2)*np.clip((z-120)/150,0,1)*np.clip((440-z)/60,0,1)
    hills=2.6*np.sin(x/41)*np.sin(z/37)+1.2*np.sin((x+z)/23)+1.5*np.sin((x-2*z)/53)
    return 8+h+gully+hills
DH=[(250,462,0),(238,420,20),(196,394,8),(258,364,8),(204,334,8),(262,304,8),(218,276,10),(255,236,26),(205,196,26),(250,156,24),(205,116,24),(240,75,20),(226,36,0)]
XC=[(262,462,0),(292,412,30),(318,368,40),(352,318,30),(392,290,12),(330,262,12),(378,228,14),(352,196,18),(400,176,24),(440,150,20),(470,112,24),(400,92,24),(440,62,20),(350,58,40),(268,40,0)]
def draw():
    xs=np.linspace(0,512,257); X,Z=np.meshgrid(xs,xs); H=ground(X,Z)
    fig,ax=plt.subplots(figsize=(10,10))
    cs=ax.contour(X,Z,H,levels=np.arange(0,170,5),colors='k',linewidths=0.4)
    ax.clabel(cs,fmt='%d',fontsize=6)
    for line,c in [(DH,'r'),(XC,'b')]:
        p=np.array([(a,b) for a,b,_ in line]); ax.plot(p[:,0],p[:,1],c+'-o',ms=3)
        out=[]
        for i,(a,b,_) in enumerate(line):
            ax.text(a,b,str(i),color=c,fontsize=8)
            if i:
                L=np.hypot(a-line[i-1][0],b-line[i-1][1]); g=(ground(a,b)-ground(*line[i-1][:2]))/L
                out.append(f"{i}:{L:.0f}m {g*100:+.0f}%")
        print(c,' '.join(out))
    ax.set_aspect('equal'); ax.set_xlim(0,512); ax.set_ylim(0,512)
    plt.savefig('m19.png',dpi=80)
if __name__=="__main__": draw()
