"""Full-page click target on :8766; logs every click with its isTrusted flag."""
import json, sys, time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
LOG = sys.argv[1]
PAGE = b"""<!doctype html><title>Click Test</title><body style="margin:0;height:100vh;background:#dfe">
<div id=s style="font:28px sans-serif;padding:40px">clicks: 0</div><script>let n=0;
document.addEventListener('mousedown',e=>fetch('/c',{method:'POST',body:JSON.stringify({ev:'down',x:e.clientX,y:e.clientY,trusted:e.isTrusted})}));
document.addEventListener('click',e=>{n++;document.getElementById('s').textContent='clicks: '+n;
fetch('/c',{method:'POST',body:JSON.stringify({ev:'click',x:e.clientX,y:e.clientY,trusted:e.isTrusted,ua:navigator.userActivation.hasBeenActive})})});</script>"""
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Type", "text/html"); self.end_headers(); self.wfile.write(PAGE)
    def do_POST(self):
        d = json.loads(self.rfile.read(int(self.headers["Content-Length"]))); d["t"] = time.time()
        open(LOG, "a").write(json.dumps(d) + "\n"); self.send_response(200); self.end_headers()
ThreadingHTTPServer(("127.0.0.1", 8766), H).serve_forever()
