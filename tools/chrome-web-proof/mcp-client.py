"""Minimal stdio MCP client for the proof: start `peekaboo mcp serve` and call tools in order.

Usage: python3 -I mcp-client.py <peekaboo-binary> list
       python3 -I mcp-client.py <peekaboo-binary> call '<json list of {"name":..., "arguments":...}>'
Each call's arguments may reference the previous call: "$prev.<dotted.path>" reads its _meta and
"$text:<regex>" takes the first capture group of the regex in its text.
"""
import json
import re
import subprocess
import sys


def rpc(proc, msg_id, method, params):
    proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": msg_id, "method": method, "params": params}) + "\n")
    proc.stdin.flush()
    while True:
        line = proc.stdout.readline()
        if not line:
            raise SystemExit("server closed: " + proc.stderr.read()[-2000:])
        reply = json.loads(line)
        if reply.get("id") == msg_id:
            return reply


def lookup(obj, path):
    for part in path.split("."):
        obj = obj[part]
    return obj


def main():
    binary, mode = sys.argv[1], sys.argv[2]
    proc = subprocess.Popen([binary, "mcp", "serve"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True)
    rpc(proc, 1, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                "clientInfo": {"name": "pb-chrome-web-proof", "version": "1"}})
    proc.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
    proc.stdin.flush()
    if mode == "list":
        tools = rpc(proc, 2, "tools/list", {})["result"]["tools"]
        for tool in tools:
            if tool["name"] in sys.argv[3:]:
                print(json.dumps(tool, indent=1)[:3000])
    else:
        prev, prev_text = {}, ""

        def resolve(value):
            if isinstance(value, str) and value.startswith("$prev."):
                return lookup(prev, value[6:])
            if isinstance(value, str) and value.startswith("$text:"):
                match = re.search(value[6:], prev_text)
                return match.group(1) if match else ""
            return value

        for index, call in enumerate(json.loads(sys.argv[3])):
            args = {k: resolve(v) for k, v in call["arguments"].items()}
            reply = rpc(proc, 10 + index, "tools/call", {"name": call["name"], "arguments": args})
            result = reply.get("result", {})
            prev = result.get("_meta", {}) or {}
            texts = [c.get("text", "") for c in result.get("content", []) if c.get("type") == "text"]
            prev_text = "\n".join(texts)
            print(json.dumps({"tool": call["name"], "arguments": args, "isError": result.get("isError"),
                              "text": "\n".join(texts), "error": reply.get("error")}, indent=1))
    proc.stdin.close()
    proc.terminate()


main()
