import sys
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
LOG = sys.argv[1]
PAGE = """<!doctype html><title>Drag Test</title><style>body{font-family:sans-serif;margin:20px}
#pad{width:500px;height:120px;background:#eef;border:1px solid #88a}#src{width:80px;height:40px;background:#c66;color:#fff;margin:10px 0}
#dst{width:200px;height:80px;border:2px dashed #888}</style>
<h1>Drag Test</h1><p>Pad (pointer drag):</p><div id=pad></div>
<p>Slider:</p><input id=rng type=range min=0 max=100 value=0 style="width:500px">
<p>HTML5 drag source and drop target:</p><div id=src draggable=true>Drag me</div><div id=dst>Drop here</div><pre id=out></pre>
<script>
const log=(k,d)=>{fetch('/log',{method:'POST',body:JSON.stringify(Object.assign({k},d))});document.getElementById('out').textContent+=k+' '+JSON.stringify(d)+'\\n'};
let moves=0;pad.onmousedown=e=>{moves=0;log('pad_down',{x:e.offsetX,y:e.offsetY,t:e.isTrusted})};
let mv={b0:0,b1:0};pad.onmousemove=e=>{if(e.buttons&1){moves++;mv.b1++}else mv.b0++};pad.onpointermove=e=>{};document.addEventListener('mousemove',e=>{if(e.target.id==='rng')(e.buttons&1?mv.b1++:mv.b0++)});setInterval(()=>{if(mv.b0||mv.b1){log('moves',mv);mv={b0:0,b1:0}}},1000);pad.onmouseup=e=>log('pad_up',{x:e.offsetX,y:e.offsetY,moves,t:e.isTrusted});
rng.onchange=e=>log('range',{v:rng.value,t:e.isTrusted});
src.ondragstart=e=>{e.dataTransfer.setData('text','x');log('dragstart',{t:e.isTrusted})};
dst.ondragover=e=>e.preventDefault();dst.ondrop=e=>{e.preventDefault();log('drop',{t:e.isTrusted})};
log('load',{});
</script>"""
class H(BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_GET(self):
        b=PAGE.encode(); self.send_response(200); self.send_header('Content-Type','text/html'); self.send_header('Content-Length',str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_POST(self):
        d=self.rfile.read(int(self.headers.get('Content-Length',0))); open(LOG,'a').write(d.decode()+'\n'); self.send_response(200); self.end_headers()
ThreadingHTTPServer(('127.0.0.1',8768),H).serve_forever()
