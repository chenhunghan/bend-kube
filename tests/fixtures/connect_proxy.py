# A minimal HTTP CONNECT proxy for tests/tls.sh: requires user:s3cret and
# logs every CONNECT. Usage: python3 connect_proxy.py PORT [NAME=IP ...]
# Each NAME=IP resolves NAME to IP, as a proxy's own DNS would.
import base64, socket, sys, threading
want = "Basic " + base64.b64encode(b"user:s3cret").decode()
def pipe(a, b):
    try:
        while (d := a.recv(65536)): b.sendall(d)
    except OSError: pass
    finally:
        for s in (a, b):
            try: s.close()
            except OSError: pass
def serve(c):
    head = b""
    while b"\r\n\r\n" not in head:
        d = c.recv(1)
        if not d: return
        head += d
    lines = head.decode().split("\r\n"); target = lines[0].split()[1]
    auth = next((l.split(":", 1)[1].strip() for l in lines if l.lower().startswith("proxy-authorization:")), "")
    print("CONNECT", target, "auth-ok" if auth == want else "auth-bad", flush=True)
    if auth != want:
        c.sendall(b"HTTP/1.1 407 Proxy Authentication Required\r\n\r\n"); c.close(); return
    host, port = target.rsplit(":", 1)
    host = names.get(host.strip("[]"), host.strip("[]"))
    try:
        u = socket.create_connection((host, int(port)))
    except OSError:
        c.sendall(b"HTTP/1.1 502 Bad Gateway\r\n\r\n"); c.close(); return
    c.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
    threading.Thread(target=pipe, args=(c, u), daemon=True).start(); pipe(u, c)
names = dict(a.split("=", 1) for a in sys.argv[2:])
ls = socket.socket(); ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); ls.bind(("127.0.0.1", int(sys.argv[1]))); ls.listen(16)
while True:
    c, _ = ls.accept(); threading.Thread(target=serve, args=(c,), daemon=True).start()
