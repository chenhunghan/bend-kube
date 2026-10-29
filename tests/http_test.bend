import Base
import ../src/utf8.bend as U
import ../src/http.bend as H

def show(r: Result<&2, &1, String, H.Head & String>) -> String:
  match r:
    case Done{(H.Head{c, reason, hs}, body)}:
      "ok " ++ U32.show(c) ++ " [" ++ body ++ "]"
    case Fail{e}:
      "err " ++ e

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(show(H.Http.decode(U.Utf8.encode("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhé\nl\r\n3;x=y\r\nabc\r\n0\r\n\r\n"))))
    IO.print(show(H.Http.decode(U.Utf8.encode("HTTP/1.1 404 Not Found\r\nContent-Length: 4\r\n\r\nnope"))))
    IO.print(show(H.Http.decode(U.Utf8.encode("HTTP/1.1 200 OK\r\n\r\nuntil close"))))
    IO.print(show(H.Http.decode(U.Utf8.encode("HTTP/1.1 204 No Content\r\n\r\n"))))
    IO.print(show(H.Http.decode(U.Utf8.encode("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort"))))
    IO.print(H.Http.render(H.Req{"GET", "/api/v1/pods?labelSelector=" ++ H.Http.encode("app=web,tier in (a)"), [H.Header{"Accept", "application/json"}], ""}, "10.0.0.1"))
