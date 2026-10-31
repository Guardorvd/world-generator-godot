import numpy as np, matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
def creek_x(z): return 256+24*np.sin(z/55.0)
def ground(x,z):
    base=10+0.10*z
    sides=42*(1-np.exp(-((x-256)/150)**2))
    head=14*np.clip((z-380)/110,0,1)**2*np.exp(-((x-256)/170)**2)
    cx=creek_x(z)
    creek=-3.2*np.exp(-((x-cx)/5.5)**2)*np.clip((z-50)/40,0,1)*np.clip((470-z)/30,0,1)
    hills=2.2*np.sin(x/43)*np.sin(z/39)+1.0*np.sin((x+z)/27)+1.4*np.sin((x-1.7*z)/61)
    return base+sides+head+creek+hills
