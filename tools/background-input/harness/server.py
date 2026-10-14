"""Local benchmark site: a form plus a canvas target; every event is logged with the current run id."""
import hashlib, json, os, sys, time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
BENCH = sys.argv[1]
PAGE = r"""<!doctype html><html><head><meta charset="utf-8"><title>Bench Form</title>
<style>body{font-family:-apple-system,sans-serif;max-width:640px;margin:24px auto;padding:0 16px}
label{display:block;margin:10px 0 4px}input[type=text],input[type=email],select,textarea{width:100%;padding:6px;font-size:15px}
button{margin:6px 6px 6px 0;padding:6px 12px;font-size:15px}#adv{display:none;border:1px solid #ccc;padding:8px;margin:8px 0}
#tags li{display:inline-block;background:#eef;margin:2px;padding:2px 8px;border-radius:10px}
#result{margin-top:14px;font-size:20px;font-weight:600;color:#0a6}canvas{border:1px solid #999;display:block;margin:6px 0}</style></head>
<body><h1>Bench Form</h1>
<label for="name">Full name</label><input id="name" type="text">
<label for="email">Email</label><input id="email" type="email">
<label for="plan">Plan</label><select id="plan"><option value="">Choose a plan</option><option>Basic</option><option>Pro</option><option>Team</option></select>
<label for="tag">Tag</label><input id="tag" type="text"><button id="addtag" type="button">Add tag</button><ul id="tags"></ul>
<button id="toggleadv" type="button">Show advanced options</button>
<div id="adv" role="group" aria-label="Priority"><span>Priority:</span>
<label><input type="radio" name="prio" value="Low">Low</label><label><input type="radio" name="prio" value="Normal">Normal</label><label><input type="radio" name="prio" value="High">High</label></div>
<p>Canvas target: click the green circle.</p><canvas id="cv" width="320" height="140"></canvas><div id="cvstatus">Canvas: not clicked</div>
<label><input id="agree" type="checkbox"> I agree to the terms</label>
<button id="submit" type="button">Submit</button><div id="result"></div>
<script>
const ev=(kind,data)=>fetch('/event',{method:'POST',body:JSON.stringify({kind,data})});
const tags=[];const cv=document.getElementById('cv'),cx=cv.getContext('2d');
cx.fillStyle='#c33';cx.fillRect(40,40,60,60);cx.fillStyle='#2a2';cx.beginPath();cx.arc(240,70,26,0,7);cx.fill();
cv.addEventListener('click',e=>{const r=cv.getBoundingClientRect(),x=e.clientX-r.left,y=e.clientY-r.top;
 const hit=Math.hypot(x-240,y-70)<=26;document.getElementById('cvstatus').textContent=hit?'Canvas: green circle hit':'Canvas: missed';ev(hit?'canvas_hit':'canvas_miss',{x,y,trusted:e.isTrusted});});
document.getElementById('addtag').onclick=e=>{const t=document.getElementById('tag');if(t.value.trim()){tags.push(t.value.trim());
 const li=document.createElement('li');li.textContent=t.value.trim();document.getElementById('tags').appendChild(li);t.value='';ev('tag',{tags,trusted:e.isTrusted});}};
document.getElementById('toggleadv').onclick=e=>{const a=document.getElementById('adv');a.style.display=a.style.display==='block'?'none':'block';ev('adv',{trusted:e.isTrusted});};
document.getElementById('submit').onclick=async e=>{const p=document.querySelector('input[name=prio]:checked');
 const body={name:document.getElementById('name').value,email:document.getElementById('email').value,plan:document.getElementById('plan').value,
 tags,priority:p?p.value:null,agree:document.getElementById('agree').checked,canvas:document.getElementById('cvstatus').textContent,trusted:e.isTrusted};
 const r=await fetch('/submit',{method:'POST',body:JSON.stringify(body)});const j=await r.json();
 document.getElementById('result').textContent=j.ok?('Confirmation: '+j.code):('Error: '+j.error);};
ev('load',{});
</script></body></html>"""
def log(rec):
    run = open(os.path.join(BENCH, "current_run")).read().strip() if os.path.exists(os.path.join(BENCH, "current_run")) else "none"
    rec.update(run=run, t=time.time())
    with open(os.path.join(BENCH, "events.jsonl"), "a") as f: f.write(json.dumps(rec) + "\n")
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, body, ctype):
        b = body.encode(); self.send_response(code); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        log({"kind": "get", "path": self.path}); self._send(200, PAGE, "text/html; charset=utf-8")
    def do_POST(self):
        data = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        if self.path == "/submit":
            missing = [k for k in ("name", "email", "plan") if not data.get(k)] + ([] if data.get("agree") else ["agree"])
            code = "CONF-" + hashlib.sha1((data.get("name", "") + data.get("plan", "")).encode()).hexdigest()[:6].upper()
            resp = {"ok": not missing, "code": code} if not missing else {"ok": False, "error": "missing " + ", ".join(missing)}
            log({"kind": "submit", "data": data, "resp": resp}); self._send(200, json.dumps(resp), "application/json")
        else:
            log(data); self._send(200, "{}", "application/json")
ThreadingHTTPServer(("127.0.0.1", 8765), H).serve_forever()
