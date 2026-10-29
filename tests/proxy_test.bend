import Base
import ../src/utf8.bend as U
import ../src/proxy.bend as P

def show(r: P.Route) -> String:
  match r:
    case P.Direct{}:
      "direct"
    case P.Via{P.Proxy{h, p, a}}:
      "via " ++ h ++ ":" ++ U32.show(p) ++ " auth=" ++ a
    case P.NoRoute{w}:
      "error: " ++ w

def tun(t: P.Tunnel) -> String:
  match t:
    case P.TMore{h}:
      "more"
    case P.TOpen{}:
      "open"
    case P.TFail{w}:
      "fail: " ++ w

def go(no: String, host: String, port: U32) -> String:
  show(P.Proxy.route("http://proxy.corp:3128", no, host, port))

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print("== routes")
    IO.print(show(P.Proxy.route("", "", "api.corp", 443)))
    IO.print(show(P.Proxy.route("   ", "", "api.corp", 443)))
    IO.print(go("", "api.corp", 443))
    IO.print(go("", "localhost", 443))
    IO.print(go("", "LocalHost", 443))
    IO.print(go("", "127.8.9.10", 443))
    IO.print(go("", "::1", 443))
    IO.print(go("", "128.0.0.1", 443))
    IO.print("== no_proxy")
    IO.print(go("*", "api.corp", 443))
    IO.print(go("corp", "api.corp", 443))
    IO.print(go("corp", "corp", 443))
    IO.print(go("corp", "evilcorp", 443))
    IO.print(go(".corp", "corp", 443))
    IO.print(go(".corp", "a.corp", 443))
    IO.print(go("*.corp", "a.b.corp", 443))
    IO.print(go("API.Corp", "api.CORP", 443))
    IO.print(go("api.corp:6443", "api.corp", 443))
    IO.print(go("api.corp:6443", "api.corp", 6443))
    IO.print(go("x, y api.corp,z", "api.corp", 443))
    IO.print(go("10.0.0.0/8", "10.1.2.3", 443))
    IO.print(go("10.0.0.0/8", "11.1.2.3", 443))
    IO.print(go("0.0.0.0/0", "8.8.8.8", 443))
    IO.print(go("10.0.0.0/33", "10.1.2.3", 443))
    IO.print(go("192.168.1.5", "192.168.1.5", 443))
    IO.print(go("fd00::1", "fd00::1", 443))
    IO.print("== urls")
    IO.print(show(P.Proxy.route("proxy:8080", "", "api.corp", 443)))
    IO.print(show(P.Proxy.route("http://proxy", "", "api.corp", 443)))
    IO.print(show(P.Proxy.route("HTTP://proxy:1/", "", "api.corp", 443)))
    IO.print(show(P.Proxy.route("http://user:s3cret@[fd00::9]:3128", "", "api.corp", 443)))
    IO.print(show(P.Proxy.route("http://us%40er:p%3Ass@proxy:3128", "", "api.corp", 443)))
    IO.print(show(P.Proxy.route("http://a@b:c@proxy:3128", "", "api.corp", 443)))
    IO.print(show(P.Proxy.route("http://u:100%@proxy:3128", "", "api.corp", 443)))
    IO.print(show(P.Proxy.route("https://proxy:3128", "", "api.corp", 443)))
    IO.print(show(P.Proxy.route("socks5://proxy:1080", "", "api.corp", 443)))
    IO.print(show(P.Proxy.route("http://:3128", "", "api.corp", 443)))
    IO.print("== connect")
    IO.print(P.Proxy.connect("api.corp", 6443, ""))
    IO.print(P.Proxy.connect("fd00::1", 443, "dTpw"))
    IO.print("== tunnel")
    IO.print(tun(P.Tunnel.feed(P.Tunnel.init(), U.Utf8.encode("HTTP/1.1 200 Connection established\r\n\r\n"))))
    IO.print(tun(P.Tunnel.feed(P.Tunnel.feed(P.Tunnel.init(), U.Utf8.encode("HTTP/1.0 200 OK\r")),
      U.Utf8.encode("\nVia: x\r\n\r\n"))))
    IO.print(tun(P.Tunnel.feed(P.Tunnel.init(), U.Utf8.encode("HTTP/1.1 200 OK\r\n"))))
    IO.print(tun(P.Tunnel.feed(P.Tunnel.init(), U.Utf8.encode("HTTP/1.1 407 Proxy Authentication Required\r\n\r\n"))))
    IO.print(tun(P.Tunnel.feed(P.Tunnel.init(), U.Utf8.encode("HTTP/1.1 200 OK\r\n\r\n\u{16}"))))
    IO.print(tun(P.Tunnel.feed(P.Tunnel.feed(P.Tunnel.init(), U.Utf8.encode("HTTP/1.1 2")), Nil{})))
    IO.print(tun(P.Tunnel.feed(P.Tunnel.init(), U.Utf8.encode("SSH-2.0-OpenSSH\r\n\r\n"))))
    IO.print(tun(P.Tunnel.feed(P.Tunnel.init(), U.Utf8.encode(String.repeat("x", 17000n)))))
