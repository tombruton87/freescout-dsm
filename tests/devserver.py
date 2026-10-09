#!/usr/bin/env python3
"""
Serves the window (panel.html, panel.js, images) and runs the real api.cgi
for /api.cgi, with a stub sign-in — so the page can be opened in a browser
on a laptop against a var dir (fixtures, or a live tests/e2e.sh run).

    tests/devserver.py [--var DIR] [--share DIR] [--pkg DIR] [--user NAME] [--port 8787]
"""
import argparse, os, subprocess, sys
from http.server import HTTPServer, SimpleHTTPRequestHandler

here = os.path.dirname(os.path.abspath(__file__))
ui = os.path.join(here, "..", "synology", "target", "ui")
ap = argparse.ArgumentParser()
ap.add_argument("--var", default=os.path.join(os.environ.get("TMPDIR", "/tmp"), "freescout-e2e", "var"))
ap.add_argument("--share", default=os.path.join(os.environ.get("TMPDIR", "/tmp"), "freescout-e2e", "share"))
ap.add_argument("--pkg", default=os.path.join(here, ".."))
ap.add_argument("--user", default=os.environ.get("USER", "tom"))
ap.add_argument("--port", type=int, default=8787)
ap.add_argument("--admins", default="", help="DSM group that counts as administrators (default: your own group); 'none' to view as a plain user")
a = ap.parse_args()

class H(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kw): super().__init__(*args, directory=ui, **kw)
    def cgi(self, method):
        qs = self.path.split("?", 1)[1] if "?" in self.path else ""
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        env = dict(os.environ, REQUEST_METHOD=method, QUERY_STRING=qs, CONTENT_LENGTH=str(length) if length else "",
                   FREESCOUT_VAR=a.var, FREESCOUT_SHARE=a.share, FREESCOUT_PKG=a.pkg,
                   FREESCOUT_AUTH_CGI=os.path.join(here, "stub-auth.sh"), STUB_USER=a.user,
                   FREESCOUT_ADMINS=(a.admins or subprocess.run(["id", "-gn"], capture_output=True, text=True).stdout.strip()))
        out = subprocess.run(["bash", os.path.join(ui, "api.cgi")], input=body, capture_output=True, env=env).stdout
        head, _, payload = out.partition(b"\r\n\r\n")
        status, headers = 200, []
        for line in head.decode(errors="replace").split("\r\n"):
            k, _, v = line.partition(": ")
            if k == "Status": status = int(v.split()[0])
            elif k: headers.append((k, v))
        self.send_response(status)
        for k, v in headers: self.send_header(k, v)
        self.end_headers(); self.wfile.write(payload)
    def do_GET(self):
        if self.path.startswith("/api.cgi"): return self.cgi("GET")
        return super().do_GET()
    def do_POST(self):
        if self.path.startswith("/api.cgi"): return self.cgi("POST")
        self.send_error(405)
    def log_message(self, *args): pass

print(f"http://127.0.0.1:{a.port}/panel.html  (var {a.var}, as {a.user})", flush=True)
HTTPServer(("127.0.0.1", a.port), H).serve_forever()
