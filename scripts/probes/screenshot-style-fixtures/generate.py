from PIL import Image, ImageDraw, ImageFont
from pathlib import Path
root=Path(__file__).resolve().parent
reg=ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc',38,index=0)
bold=ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc',38,index=1)
cn=ImageFont.truetype('/System/Library/Fonts/STHeiti Light.ttc',36,index=1)
cn_bold=ImageFont.truetype('/System/Library/Fonts/STHeiti Medium.ttc',36,index=1)
xs=[50,400,760,1150]; ys=[70,190,310,430,550]

def runs(d, x, y, parts):
 for text,font in parts:
  d.text((x,y),text,font=font,fill='black',stroke_width=1 if font==cn_bold else 0)
  x+=d.textlength(text,font=font)

def make(name,grid=True,cross=False):
 im=Image.new('RGB',(1200,610),'white'); d=ImageDraw.Draw(im)
 if grid:
  for x in xs:d.line((x,ys[0],x,ys[-1]),fill='black',width=3)
  for y in ys:d.line((xs[0],y,xs[-1],y),fill='black',width=3)
 for c,t in enumerate(['Name','Region','Notes']):runs(d,xs[c]+18,ys[0]+38,[(t,reg)])
 runs(d,68,228,[('A ',reg),('B',bold)])
 runs(d,418,228,[('New ',reg),('York',bold)])
 runs(d,778,228,[('slow',bold),(' response',reg)])
 runs(d,68,348,[('Beta',reg)]);runs(d,418,348,[('Los Angeles',reg)])
 runs(d,68,468,[('人工',cn),('智能',cn_bold),('系统',cn)])
 runs(d,418,468,[('大模型',cn)])
 runs(d,778,468,[('处理中',cn)])
 if cross:
  d.rectangle((55,193,398,306),fill='white')
  d.rectangle((403,193,755,306),fill='white')
  runs(d,325,228,[('Cross',bold),(' Border',reg)])
 im.save(root/name)
make('mixed-bold-grid.png')
make('mixed-bold-unruled.png',grid=False)
make('crossing-grid.png',cross=True)
print('\n'.join(str(p) for p in root.glob('*.png')))
