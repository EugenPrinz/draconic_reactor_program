import json, base64, glob, os, io
from PIL import Image
tex={}
for f in sorted(glob.glob('tex/*.png')):
    tex[os.path.basename(f)[:-4]]='data:image/png;base64,'+base64.b64encode(open(f,'rb').read()).decode()
im=Image.open('/home/claude/draconic_reactor_program/docs/screen-main.png').convert('RGB').resize((960,600),Image.LANCZOS)
b=io.BytesIO(); im.save(b,'JPEG',quality=85)
scr='data:image/jpeg;base64,'+base64.b64encode(b.getvalue()).decode()
s=open('template.html').read()
s=s.replace('__MODELS__',open('models.json').read()).replace('__TEX__',json.dumps(tex)).replace('__SCREEN__',scr)
open('/home/claude/draconic_reactor_program/docs/build.html','w').write(s)
print(len(s)//1024,'KB')
