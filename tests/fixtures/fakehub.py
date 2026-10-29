# A local stand-in for hub.bend-lang.com (tests/package.sh): publish,
# name, and serve packages the way `bend` fetches them. Usage: fakehub.py PORT
import hashlib, json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
pkgs, names = {}, {}
def sha(s): return hashlib.sha256(s.encode()).hexdigest()
class H(BaseHTTPRequestHandler):
    def send(self, code, body, ctype="text/plain"):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code); self.send_header("content-type", ctype)
        self.send_header("content-length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): sys.stderr.write("hub: %s %s\n" % (self.command, self.path))
    def do_GET(self):
        p = self.path
        if p == "/pow.json": return self.send(200, json.dumps({"pow": 1}), "application/json")
        if p.startswith("/publish-check"): return self.send(200, json.dumps({"name": "free", "version_ok": True}), "application/json")
        if p.startswith("/name/"):
            nv = p[6:]
            return self.send(200, names[nv]) if nv in names else self.send(404, "no")
        h, _, rest = p[1:].partition("/")
        if h in pkgs:
            if rest == "manifest": return self.send(200, pkgs[h][0])
            if rest in pkgs[h][1]: return self.send(200, pkgs[h][1][rest])
        self.send(404, "no")
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["content-length"])) or b"{}")
        if self.path == "/":
            files = body["files"]
            man = "".join(sha(files[p]) + " " + p + "\n" for p in sorted(files))
            h = "0x" + sha(man)[:32]
            pkgs[h] = (man, files)
            return self.send(200, h)
        if self.path == "/link":
            names[body["name"] + "@" + body["version"]] = next(k for k in pkgs if k.startswith(body["hash"]))
        self.send(200, "{}", "application/json")
ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
