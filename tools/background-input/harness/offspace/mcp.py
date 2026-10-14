# Minimal stdio MCP client for the fork's `peekaboo mcp` (same env as harness/pb-fork-mcp.json).
import json, os, subprocess, time
PB = "/Users/abhi/Desktop/Work/projects/peekaboo/bin/peekaboo"
class MCP:
    def __init__(self):
        env = dict(os.environ, PEEKABOO_NO_REMOTE="1", PEEKABOO_DISABLE_TOOLS="browser")
        self.p = subprocess.Popen([PB, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env, text=True, bufsize=1)
        self.n = 0
        self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "offspace", "version": "1"}})
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
    def rpc(self, method, params):
        self.n += 1; self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params}) + "\n")
        while True:
            msg = json.loads(self.p.stdout.readline())
            if msg.get("id") == self.n: return msg
    def call(self, name, args):
        """Returns (ok, text, meta, seconds)."""
        t = time.time(); r = self.rpc("tools/call", {"name": name, "arguments": args}).get("result", {})
        text = " ".join(c.get("text", "") for c in r.get("content", []) if c.get("type") == "text")
        return (not r.get("isError"), text, r.get("_meta", {}) or {}, time.time() - t)
    def close(self): self.p.stdin.close(); self.p.wait(timeout=10)
