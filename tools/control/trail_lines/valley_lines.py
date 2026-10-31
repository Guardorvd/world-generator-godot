import sys; sys.path.insert(0,'.')
from valley_ground import ground, creek_x, plt, np
from route import report
from route2 import route, relax
import json
GV=[(330,82),(400,110),(445,250),(400,330),(430,420),(330,462),(200,462),(90,420),(120,330),(70,230),(110,120),(256,64),(330,82)]
gr=route(ground,GV,-0.10,0.10,cross_w=1.2,turn_w=10.0,hairpin=30.0,eps=4.0)
gr=relax(gr,14.0,1500)
G=np.array(gr)
def near_gr(x,z):
    d=np.min(np.hypot(G[:,0]-x,G[:,1]-z)); return 0.0 if d>24 else 5.0*(24-d)/24
MV=[(480,476),(400,400),(300,385),(220,330),(290,262),(190,205),(130,160),(40,56)]
mt=route(ground,MV,-0.20,0.08,cross_w=1.5,turn_w=6.0,hairpin=20.0,eps=3.0,avoid=near_gr)
mt=relax(mt,8.0,1500)
report(ground,gr,'грэвел'); report(ground,mt,'МТБ')
xs=np.linspace(0,512,257); X,Z=np.meshgrid(xs,xs); H=ground(X,Z)
fig,ax=plt.subplots(figsize=(10,10))
cs=ax.contour(X,Z,H,levels=np.arange(0,120,3),colors='k',linewidths=0.4); ax.clabel(cs,fmt='%d',fontsize=6)
zz=np.linspace(50,470,100); ax.plot(creek_x(zz),zz,'c-',lw=3)
for p,c in [(gr,'orange'),(mt,'b')]:
    a=np.array(p); ax.plot(a[:,0],a[:,1],'-',color=c,lw=2)
ax.set_aspect('equal'); ax.set_xlim(0,512); ax.set_ylim(0,512); plt.savefig('m20.png',dpi=80)
json.dump({'gravel':gr,'mtb':mt},open('m20_lines.json','w'))
