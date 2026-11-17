# native
import Base
import ../src/http.bend as H
import ../src/h2.bend as T

def show_h(h: H.Header) -> String:
  match h:
    case H.Header{n, v}:
      n ++ "=" ++ v

def show_ev(e: T.H2Ev) -> String:
  match e:
    case T.EvHeaders{sid, hs, end}:
      "headers " ++ U32.show(sid) ++ " " ++ List.show(~&2, ~H.Header, ~show_h, hs) ++ " end=" ++ Bool.show(end)
    case T.EvData{sid, bs, end}:
      "data " ++ U32.show(sid) ++ " " ++ Nat.show(List.length(&2, U32, bs)) ++ " bytes end=" ++ Bool.show(end)
    case T.EvRst{sid, code}:
      "rst " ++ U32.show(sid) ++ " code " ++ U32.show(code)
    case T.EvGoaway{last, code}:
      "goaway last " ++ U32.show(last) ++ " code " ++ U32.show(code)
    case T.EvFatal{code, why}:
      "fatal " ++ U32.show(code) ++ " " ++ why

def tag(+who: String, es: List<&2, T.H2Ev>) -> List<&2, String>:
  match es:
    case Nil{}:
      Nil{}
    case Con{e, t}:
      Con{who ++ ": " ++ show_ev(e), tag(who, t)}

type Duo is Data:
  Duo{c: T.H2, s: T.H2, log: List<&2, String>, wire: U32}

def pump.c(t: T.H2Take, s: T.H2, log: List<&2, String>, +wire: U32) -> Duo:
  match t:
    case T.H2Take{c, bs, es}:
      +bs = bs
      Duo{c, T.H2.feed(s, bs), List.append(&2, String, log, tag("client", es)), U32.add(wire, T.H2.len(bs))}

def pump.s(t: T.H2Take, c: T.H2, log: List<&2, String>, +wire: U32) -> Duo:
  match t:
    case T.H2Take{s, bs, es}:
      +bs = bs
      Duo{T.H2.feed(c, bs), s, List.append(&2, String, log, tag("server", es)), U32.add(wire, T.H2.len(bs))}

def pump.back(p: Duo) -> Duo:
  match p:
    case Duo{c2, s2, log2, +w2}:
      pump.s(T.H2.take(s2), c2, log2, w2)

def pump.one(p: Duo) -> Duo:
  match p:
    case Duo{c, s, log, +wire}:
      pump.back(pump.c(T.H2.take(c), s, log, wire))

def pump(n: Nat, p: Duo) -> Duo:
  match n:
    case 0n:
      p
    case 1n+k:
      pump(k, pump.one(p))

def bytes(n: Nat) -> List<&2, U32>:
  List.replicate(U32, n, 97)

def req() -> List<&2, H.Header>:
  [H.Header{":method", "POST"}, H.Header{":scheme", "http"}, H.Header{":path", "/x"}, H.Header{":authority", "h"}]

def print_all(ls: List<&2, String>) -> IO(Unit):
  match ls:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case Con{l, t}:
      do IO<Unit>:
        IO.print(l)
        print_all(t)

def stage4(o: T.H2Opened, s7: T.H2, log2: List<&2, String>, +w2: U32) -> Duo:
  match o:
    case T.H2Opened{c5, +sid2}:
      pump(3n, Duo{T.H2.close(T.H2.reset(c5, sid2, T.H2.cancel()), 0), s7, log2, w2})

def stage3(p: Duo) -> Duo:
  match p:
    case Duo{c4, s7, log2, +w2}:
      stage4(T.H2.open(c4, req(), True{}), s7, log2, w2)

def stage2(p: Duo, +sid: U32) -> Duo:
  match p:
    case Duo{c3, s3, log, +w}:
      s4 = T.H2.send(s3, sid, T.CHead{[H.Header{":status", "200"}], False{}})
      s5 = T.H2.send(s4, sid, T.CData{bytes(20000n), False{}})
      s6 = T.H2.send(s5, sid, T.CHead{[H.Header{"grpc-status", "0"}], True{}})
      stage3(pump(3n, Duo{c3, s6, log, w}))

# 70000 bytes go past the default 65535 window until the server's
# SETTINGS and WINDOW_UPDATE arrive.
def stage1(o: T.H2Opened, s0: T.H2) -> Duo:
  match o:
    case T.H2Opened{c1, +sid}:
      stage2(pump(4n, Duo{T.H2.send(c1, sid, T.CData{bytes(70000n), True{}}), s0, Nil{}, 0}), sid)

def scenario() -> Duo:
  stage1(T.H2.open(T.H2.new(T.H2.cfg(False{})), req(), False{}), T.H2.new(T.H2.cfg(True{})))

def report(p: Duo) -> IO(Unit):
  match p:
    case Duo{c, s, log, w}:
      do IO<Unit>:
        print_all(log)
        IO.print("wire bytes " ++ U32.show(w))
        IO.print("client over " ++ Bool.show(T.H2.over(c)) ++ ", server over " ++ Bool.show(T.H2.over(s)))

def main() -> IO(Unit):
  report(scenario())
