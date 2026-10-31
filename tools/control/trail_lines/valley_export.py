import json, numpy as np, math
from valley_ground import creek_x
d=json.load(open('m20_lines.json'))
g=d['gravel']
while len(g)>2 and math.hypot(g[-2][0]-g[0][0],g[-2][1]-g[0][1])<1.0: g.pop(-2)
g[-1]=g[0]
def fmt(name,pts):
    rows=[]; line=""
    for i,(x,z) in enumerate(pts):
        line+=f"{x:.1f}, {z:.1f}, "
        if (i+1)%10==0: rows.append("\t"+line.rstrip()); line=""
    if line: rows.append("\t"+line.rstrip())
    return f"const {name} := [\n"+"\n".join(rows)+"\n]\n"
open('lines20.gd','w').write(fmt("GRAVEL_LINE",g)+fmt("MTB_LINE",d['mtb']))
G=np.array(g); M=np.array(d['mtb'])
sG=np.concatenate([[0],np.cumsum(np.hypot(*np.diff(G,axis=0).T))]); sM=np.concatenate([[0],np.cumsum(np.hypot(*np.diff(M,axis=0).T))])
out={'cross':[], 'mtb_creek':[], 'gravel_creek':[]}
for i in range(len(M)-1):
    for j in range(len(G)-1):
        p1,p2,q1,q2=M[i],M[i+1],G[j],G[j+1]; r=p2-p1; s=q2-q1; den=r[0]*s[1]-r[1]*s[0]
        if abs(den)<1e-9: continue
        t=((q1-p1)[0]*s[1]-(q1-p1)[1]*s[0])/den; u=((q1-p1)[0]*r[1]-(q1-p1)[1]*r[0])/den
        if 0<=t<=1 and 0<=u<=1: out['cross'].append((round(sM[i]+t*np.linalg.norm(r),1), round(sG[j]+u*np.linalg.norm(s),1)))
for P,S,key in [(M,sM,'mtb_creek'),(G,sG,'gravel_creek')]:
    prev=None
    for i,(x,z) in enumerate(P):
        if 60<z<465:
            side=np.sign(x-creek_x(z))
            if prev is not None and side!=prev: out[key].append(round(float(S[i])))
            prev=side
        else: prev=None
print(out, 'len', round(sG[-1],1), round(sM[-1],1))
json.dump(out,open('m20_marks.json','w'))
