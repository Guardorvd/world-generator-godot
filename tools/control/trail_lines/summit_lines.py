from summit_ground import ground, plt, np
from route import report
from route2 import route, relax
import matplotlib
DHV=[(250,462),(215,400),(140,330),(215,262),(120,190),(200,130),(120,80),(230,40)]
XCV=[(262,462),(330,400),(395,300),(478,250),(432,148),(400,80),(330,60),(268,40)]
dh=route(ground,DHV,-0.30,0.03,cross_w=0.4,turn_w=8.0,hairpin=40.0,eps=3.0)
import numpy as _np
_D=_np.array(dh)
def near_dh(x,z):
    d=_np.min(_np.hypot(_D[:,0]-x,_D[:,1]-z)); return 0.0 if d>35 else 8.0*(35-d)/35
xc=route(ground,XCV,-0.11,0.12,cross_w=0.8,turn_w=10.0,hairpin=60.0,eps=4.0,avoid=near_dh)
dh=relax(dh,8.0,600); xc=relax(xc,13.0,1500)
report(ground,dh,'DH'); report(ground,xc,'XC')
xs=np.linspace(0,512,257); X,Z=np.meshgrid(xs,xs); H=ground(X,Z)
fig,ax=plt.subplots(figsize=(10,10))
cs=ax.contour(X,Z,H,levels=np.arange(0,170,5),colors='k',linewidths=0.4); ax.clabel(cs,fmt='%d',fontsize=6)
for p,c in [(dh,'r'),(xc,'b')]:
    a=np.array(p); ax.plot(a[:,0],a[:,1],c+'-',lw=2)
ax.set_aspect('equal'); ax.set_xlim(0,512); ax.set_ylim(0,512); plt.savefig('m19b.png',dpi=80)
import json; json.dump({'dh':dh,'xc':xc},open('m19_lines.json','w'))
