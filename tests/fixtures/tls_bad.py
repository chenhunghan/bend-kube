# Misbehaving servers for tests/tls.sh. Usage:
#   python3 tls_bad.py PORT MODE [CERT KEY]
# MODE is one of:
#   hangup       accept, then close at once
#   plain        answer the ClientHello with a plain HTTP error
#   silent       accept and never answer
#   drip         answer one byte a second, forever (a slow loris)
#   truncated    handshake (CERT KEY), read the request, then send half a
#                record and close
#   oversized    handshake (CERT KEY), then send a record header claiming
#                more than TLS allows
#   proxy-extra  answer CONNECT with 200 and bytes after the head
#   proxy-close  read CONNECT, then close
import socket, ssl, sys, threading, time

port, mode = int(sys.argv[1]), sys.argv[2]

def head(c):
    h = b""
    while b"\r\n\r\n" not in h:
        d = c.recv(1)
        if not d:
            break
        h += d
    return h

def serve(c):
    try:
        if mode == "hangup":
            pass
        elif mode == "plain":
            c.recv(4096)
            c.sendall(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
        elif mode == "silent":
            time.sleep(60)
        elif mode == "drip":
            c.recv(4096)
            for _ in range(60):
                c.sendall(b"\x16")
                time.sleep(1)
        elif mode in ("truncated", "oversized"):
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            ctx.load_cert_chain(sys.argv[3], sys.argv[4])
            t = ctx.wrap_socket(c, server_side=True)
            t.recv(4096)
            raw = socket.socket(fileno=t.detach())
            if mode == "truncated":
                raw.sendall(b"\x17\x03\x03\x40\x00" + b"\x00" * 100)
            else:
                raw.sendall(b"\x17\x03\x03\xff\xff" + b"\x00" * 4096)
            raw.close()
            return
        elif mode == "proxy-extra":
            head(c)
            c.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n\x16\x03\x01")
            time.sleep(1)
        elif mode == "proxy-close":
            head(c)
    except (OSError, ssl.SSLError):
        pass
    finally:
        try:
            c.close()
        except OSError:
            pass

ls = socket.socket()
ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
ls.bind(("127.0.0.1", port))
ls.listen(16)
while True:
    c, _ = ls.accept()
    threading.Thread(target=serve, args=(c,), daemon=True).start()
