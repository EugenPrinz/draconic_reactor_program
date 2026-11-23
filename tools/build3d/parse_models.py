import re, json, sys
SRC='/tmp/de/src/main/java/com/brandon3055/draconicevolution/client/model/'
num=r'(-?[\d.]+)F?'
def parse(name):
    s=open(SRC+name+'.java').read()
    tw=int(re.search(r'textureWidth = (\d+)',s).group(1)); th=int(re.search(r'textureHeight = (\d+)',s).group(1))
    parts={}
    for m in re.finditer(r'this\.(\w+) = new ModelRenderer\(this, (\d+), (\d+)\)',s):
        parts[m.group(1)]={'uv':[int(m.group(2)),int(m.group(3))],'rp':[0,0,0],'rot':[0,0,0],'boxes':[],'children':[],'mirror':False}
    for m in re.finditer(r'this\.(\w+)\.setRotationPoint\('+num+', '+num+', '+num+r'\)',s):
        parts[m.group(1)]['rp']=[float(m.group(i)) for i in (2,3,4)]
    for m in re.finditer(r'this\.(\w+)\.addBox\('+num+', '+num+', '+num+r', (\d+), (\d+), (\d+)(?:, '+num+r')?\)',s):
        g=m.groups(); parts[g[0]]['boxes'].append([float(g[1]),float(g[2]),float(g[3]),int(g[4]),int(g[5]),int(g[6]),float(g[7] or 0)])
    for m in re.finditer(r'this\.setRotateAngle\((?:this\.)?(\w+), '+num+', '+num+', '+num+r'\)',s):
        parts[m.group(1)]['rot']=[float(m.group(i)) for i in (2,3,4)]
    for m in re.finditer(r'this\.(\w+)\.addChild\(this\.(\w+)\)',s):
        parts[m.group(1)]['children'].append(m.group(2))
    for m in re.finditer(r'this\.(\w+)\.mirror = true',s): parts[m.group(1)]['mirror']=True
    # render order (top-level)
    body=re.sub(r'//[^\n]*','',s[s.find('public void render('):])
    order=[]
    for m in re.finditer(r'this\.(\w+)\.render\(',body):
        if m.group(1) not in order: order.append(m.group(1))
    return {'tw':tw,'th':th,'parts':parts,'render':order}
out={n:parse(n) for n in ['ModelReactorEnergyInjector','ModelReactorStabilizerCore','ModelReactorStabilizerRing']}
for n,m in out.items():
    print(n, m['tw'], m['th'], 'parts', len(m['parts']), 'render', m['render'], file=sys.stderr)
    for k,p in m['parts'].items():
        if not p['boxes']: print('  no boxes', k, file=sys.stderr)
json.dump(out,open('/home/claude/build3d/models.json','w'))
