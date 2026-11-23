"""Serve tools/out on 127.0.0.1:8791 and keep w98_latest.png/status.txt fresh from the newest w98_*.ppm."""
import glob, http.server, os, re, socketserver, threading, time
from PIL import Image

root = os.path.dirname(os.path.abspath(__file__))
out = os.path.join(root, "out")
log = os.path.join(out, "run_live.txt")

def refresh():
    last = None
    while True:
        try:
            ppms = sorted(glob.glob(os.path.join(out, "w98_*.ppm")), key=os.path.getmtime)
            if ppms and ppms[-1] != last:
                last = ppms[-1]
                Image.open(last).save(os.path.join(out, "w98_latest.png"))
            if os.path.exists(log):
                with open(log, errors="replace") as f:
                    lines = f.read().splitlines()[-12:]
                with open(os.path.join(out, "status.txt"), "w") as f:
                    f.write("\n".join(lines))
        except Exception:
            pass
        time.sleep(3)

threading.Thread(target=refresh, daemon=True).start()
os.chdir(out)
class H(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", 8791), H) as s:
    s.serve_forever()
