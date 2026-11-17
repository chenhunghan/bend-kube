import Base
import ./http.bend as H
import ./hpack.bend as Hp

# HTTP/2
# ======
#
# RFC 9113's framing, streams and flow control, as a pure state machine
# both ends of a connection share: H2.feed takes the bytes the peer sent,
# H2.open, H2.send and H2.reset what the application wants sent, and
# H2.take hands back the bytes to write and the events for the
# application. h2io.bend drives it over a socket; grpc.bend speaks gRPC on
# top. Plain h2 only (h2c, "prior knowledge"): no TLS, no Upgrade from
# HTTP/1.1, no server push.
#
# Flow control: our receive windows are given back as soon as DATA
# arrives (half a window at a time), so the peer is held back by TCP, not
# by the application. Our send windows follow the peer's SETTINGS and
# WINDOW_UPDATEs; DATA that does not fit waits in its stream's queue until
# they grow. A stream's send window can go below zero when the peer
# lowers SETTINGS_INITIAL_WINDOW_SIZE, so it is kept biased by 2^31.

# Error codes (RFC 9113 section 7).
def H2.no_error() -> U32:
  0

def H2.protocol_error() -> U32:
  1

def H2.internal_error() -> U32:
  2

def H2.flow_control_error() -> U32:
  3

def H2.stream_closed() -> U32:
  5

def H2.frame_size_error() -> U32:
  6

def H2.refused_stream() -> U32:
  7

def H2.cancel() -> U32:
  8

def H2.compression_error() -> U32:
  9

def H2.enhance_your_calm() -> U32:
  11

# Frames
# ------

type Frame is Data:
  Frame{ty: U32, flags: U32, sid: U32, payload: List<&2, U32>}

def H2.be32(+x: U32, rest: List<&2, U32>) -> List<&2, U32>:
  Con{U32.shrn(x, 24n), Con{U32.and(U32.shrn(x, 16n), 255), Con{U32.and(U32.shrn(x, 8n), 255),
    Con{U32.and(x, 255), rest}}}}

def H2.get32(bs: List<&2, U32>) -> U32:
  match bs:
    case Con{a, Con{b, Con{c, Con{d, t}}}}:
      U32.or(U32.shln(a, 24n), U32.or(U32.shln(b, 16n), U32.or(U32.shln(c, 8n), d)))
    case _:
      0

def H2.len(bs: List<&2, U32>) -> U32:
  U32.from_nat(List.length(&2, U32, bs))

# A frame's bytes: its 9-byte header, then its payload.
def H2.frame(+ty: U32, +flags: U32, +sid: U32, payload: List<&2, U32>) -> List<&2, U32>:
  +p = payload
  +n = H2.len(p)
  Con{U32.shrn(n, 16n), Con{U32.and(U32.shrn(n, 8n), 255), Con{U32.and(n, 255), Con{ty, Con{flags,
    H2.be32(U32.and(sid, 2147483647), p)}}}}}

# What a client sends first: "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".
def H2.preface() -> List<&2, U32>:
  [80, 82, 73, 32, 42, 32, 72, 84, 84, 80, 47, 50, 46, 48, 13, 10, 13, 10, 83, 77, 13, 10, 13, 10]

# Reading frames
# --------------
#
# A byte at a time, so a frame may come split over many reads and many
# frames in one.
#   FPre: preface bytes the server still expects
#   FHead: header bytes so far, reversed
#   FBody: left payload bytes of the frame to go, acc reversed
#   FBad: a connection error; it stays here
type FRd is Data:
  FPre{left: List<&2, U32>}
  FHead{n: U32, acc: List<&2, U32>}
  FBody{ty: U32, flags: U32, sid: U32, left: U32, acc: List<&2, U32>}
  FBad{code: U32, why: String}

type FStep is Data:
  FStep{rd: FRd, got: Maybe<&2, Frame>}

def H2.rd_new(server: Bool) -> FRd:
  match server:
    case True{}:
      FPre{H2.preface()}
    case False{}:
      FHead{0, Nil{}}

def H2.rd_pre(ok: Bool, t: List<&2, U32>) -> FStep:
  match ok t:
    case False{} x:
      FStep{FBad{H2.protocol_error(), "no HTTP/2 connection preface"}, None{}}
    case True{} Nil{}:
      FStep{FHead{0, Nil{}}, None{}}
    case True{} rest:
      FStep{FPre{rest}, None{}}

def H2.rd_body(+ty: U32, +flags: U32, +sid: U32, +len: U32, big: Bool, empty: Bool) -> FStep:
  match big empty:
    case True{} e:
      FStep{FBad{H2.frame_size_error(), "a frame of " ++ U32.show(len) ++ " bytes is past SETTINGS_MAX_FRAME_SIZE"}, None{}}
    case False{} True{}:
      FStep{FHead{0, Nil{}}, Some{Frame{ty, flags, sid, Nil{}}}}
    case False{} False{}:
      FStep{FBody{ty, flags, sid, len, Nil{}}, None{}}

# The ninth header byte: the frame's length, type, flags and stream.
def H2.rd_head(acc: List<&2, U32>, +max: U32) -> FStep:
  match acc:
    case [h8, h7, h6, h5, +flags, +ty, h2, h1, h0]:
      +len = U32.or(U32.shln(h0, 16n), U32.or(U32.shln(h1, 8n), h2))
      H2.rd_body(ty, flags,
        U32.or(U32.shln(U32.and(h5, 127), 24n), U32.or(U32.shln(h6, 16n), U32.or(U32.shln(h7, 8n), h8))),
        len, U32.is_gt(len, max), U32.is_zero(len))
    case _:
      FStep{FBad{H2.internal_error(), "a frame header of the wrong size"}, None{}}

def H2.rd_more(+n: U32, +acc: List<&2, U32>, +max: U32, last: Bool) -> FStep:
  match last:
    case True{}:
      H2.rd_head(acc, max)
    case False{}:
      FStep{FHead{U32.add(n, 1), acc}, None{}}

def H2.rd_pay(+ty: U32, +flags: U32, +sid: U32, +left: U32, acc: List<&2, U32>, last: Bool) -> FStep:
  match last:
    case True{}:
      FStep{FHead{0, Nil{}}, Some{Frame{ty, flags, sid, List.reverse(&2, U32, acc)}}}
    case False{}:
      FStep{FBody{ty, flags, sid, U32.sub(left, 1), acc}, None{}}

def H2.rd_step(rd: FRd, +b: U32, +max: U32) -> FStep:
  match rd:
    case FPre{left}:
      match left:
        case Nil{}:
          FStep{FHead{1, [b]}, None{}}
        case Con{+x, t}:
          H2.rd_pre(U32.is_eq(x, b), t)
    case FHead{+n, acc}:
      H2.rd_more(n, Con{b, acc}, max, U32.is_eq(n, 8))
    case FBody{+ty, +flags, +sid, +left, acc}:
      H2.rd_pay(ty, flags, sid, left, Con{b, acc}, U32.is_eq(left, 1))
    case FBad{code, why}:
      FStep{FBad{code, why}, None{}}

type FFed is Data:
  FFed{rd: FRd, frames: List<&2, Frame>}

def H2.rd_add(got: Maybe<&2, Frame>, out: List<&2, Frame>) -> List<&2, Frame>:
  match got:
    case None{}:
      out
    case Some{f}:
      Con{f, out}

def H2.rd_go(bs: List<&2, U32>, ev: FStep, +max: U32, out: List<&2, Frame>) -> FFed:
  match bs ev:
    case Nil{} FStep{rd, got}:
      FFed{rd, List.reverse(&2, Frame, H2.rd_add(got, out))}
    case Con{+b, t} FStep{rd, got}:
      H2.rd_go(t, H2.rd_step(rd, b, max), max, H2.rd_add(got, out))

# Feeds bytes to the reader: its next state and the frames they finished,
# refusing a frame longer than max.
def H2.read(rd: FRd, bs: List<&2, U32>, +max: U32) -> FFed:
  H2.rd_go(bs, FStep{rd, None{}}, max, Nil{})

# The connection
# --------------

# What we advertise (our SETTINGS) and hold to: the largest frame we read
# (16384, the default, since we never raise it), each stream's initial
# receive window (at least 65535), the connection's receive window, how
# many streams the peer may open at once, and the header list's cap.
type H2Cfg is Data:
  H2Cfg{server: Bool, max_frame: U32, init: U32, cwin: U32, max_streams: U32, list_cap: U32}

# What the peer's SETTINGS allow us.
type H2Peer is Data:
  H2Peer{max_frame: U32, init: U32, max_streams: U32}

# What a stream has still to send, in order.
type Chunk is Data:
  CHead{hs: List<&2, H.Header>, end: Bool}
  CData{bs: List<&2, U32>, end: Bool}

# A stream: its send window (biased by 2^31), the bytes received since we
# last gave its window back, whether each side has ended it (lend: we sent
# END_STREAM; rend: the peer did), and what waits to be sent.
type Strm is Data:
  Strm{id: U32, sw: U32, rused: U32, lend: Bool, rend: Bool, q: List<&2, Chunk>}

# A header block still waiting for CONTINUATION frames.
type HCont is Data:
  HCont{sid: U32, end: Bool, acc: List<&2, U32>}

# What the application hears.
#   EvHeaders: a header block on sid (a request, a response or trailers)
#   EvData: data on sid; end is END_STREAM
#   EvRst: sid was reset, by the peer or by us
#   EvGoaway: the peer will take no stream past last
#   EvFatal: a connection error; the GOAWAY is queued, then close
type H2Ev is Data:
  EvHeaders{sid: U32, hs: List<&2, H.Header>, end: Bool}
  EvData{sid: U32, bs: List<&2, U32>, end: Bool}
  EvRst{sid: U32, code: U32}
  EvGoaway{last: U32, code: U32}
  EvFatal{code: U32, why: String}

# A connection: our settings and the peer's, the HPACK tables, the
# connection's send window and the bytes received since we gave its
# window back, the streams, a header block in progress, the highest
# stream the peer opened, the next one we open, whether it is over (a
# GOAWAY sent or a connection error), and what waits for H2.take: bytes
# to write and events, both reversed.
type H2 is Data:
  H2{cfg: H2Cfg, peer: H2Peer, rd: FRd, dec: Hp.HDec, enc: Hp.HEnc, csw: U32, crused: U32,
    streams: List<&2, Strm>, cont: Maybe<&2, HCont>, last: U32, next: U32, dead: Bool,
    out: List<&2, List<&2, U32>>, evs: List<&2, H2Ev>}

def H2.bias() -> U32:
  2147483648

def H2.max_window() -> U32:
  2147483647

# Our default settings: 100 streams at once, 1 MiB windows for each
# stream and 16 MiB for the connection, a 1 MiB header list.
def H2.cfg(server: Bool) -> H2Cfg:
  H2Cfg{server, 16384, 1048576, 16777216, 100, 1048576}

def H2.setting(+id: U32, +v: U32) -> List<&2, U32>:
  [U32.shrn(id, 8n), U32.and(id, 255), U32.shrn(v, 24n), U32.and(U32.shrn(v, 16n), 255),
    U32.and(U32.shrn(v, 8n), 255), U32.and(v, 255)]

def H2.push_off(server: Bool) -> List<&2, U32>:
  match server:
    case True{}:
      Nil{}
    case False{}:
      H2.setting(2, 0)

def H2.wu(+sid: U32, +inc: U32) -> List<&2, U32>:
  H2.frame(8, 0, sid, H2.be32(inc, Nil{}))

def H2.start.go(server: Bool, first: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match server:
    case True{}:
      List.reverse(&2, List<&2, U32>, first)
    case False{}:
      List.reverse(&2, List<&2, U32>, Con{H2.preface(), first})

def H2.start(cfg: H2Cfg) -> List<&2, List<&2, U32>>:
  match cfg:
    case H2Cfg{+server, mf, +init, +cwin, +ms, +cap}:
      H2.start.go(server, [H2.frame(4, 0, 0, List.concat(&2, U32, [H2.push_off(server), H2.setting(3, ms),
        H2.setting(4, init), H2.setting(6, cap)])), H2.wu(0, U32.sub(cwin, 65535))])

def H2.next_first(server: Bool) -> U32:
  match server:
    case True{}:
      2
    case False{}:
      1

# A new connection: a client's preface, SETTINGS and window update wait in
# its output; a server's SETTINGS and window update wait for the client's
# preface to be read, but may go at once (RFC 9113 3.4).
def H2.new(cfg: H2Cfg) -> H2:
  match cfg:
    case H2Cfg{+server, +mf, +init, +cwin, +ms, +cap}:
      H2{H2Cfg{server, mf, init, cwin, ms, cap}, H2Peer{16384, 65535, 4294967295}, H2.rd_new(server),
        Hp.Hp.dec_new(4096, cap), Hp.Hp.enc_new(4096, True{}), 65535, 0, Nil{}, None{}, 0,
        H2.next_first(server), False{}, H2.start(H2Cfg{server, mf, init, cwin, ms, cap}), Nil{}}

# Fields
# ------

def H2.s_id(s: Strm) -> U32:
  match s:
    case Strm{id, sw, ru, le, re, q}:
      id

def H2.s_pick(s: Strm, other: Maybe<&2, Strm>, hit: Bool) -> Maybe<&2, Strm>:
  match hit:
    case True{}:
      Some{s}
    case False{}:
      other

def H2.s_keep(s: Strm, rest: List<&2, Strm>, keep: Bool) -> List<&2, Strm>:
  match keep:
    case True{}:
      Con{s, rest}
    case False{}:
      rest

def H2.s_put.go(old: Strm, t: List<&2, Strm>, +s: Strm, rec: List<&2, Strm>, hit: Bool) -> List<&2, Strm>:
  match hit:
    case True{}:
      Con{s, t}
    case False{}:
      Con{old, rec}

def H2.out1(c: H2, bs: List<&2, U32>) -> H2:
  match c:
    case H2{cfg, peer, rd, dec, enc, csw, crused, ss, cont, last, next, dead, out, evs}:
      H2{cfg, peer, rd, dec, enc, csw, crused, ss, cont, last, next, dead, Con{bs, out}, evs}

def H2.ev1(c: H2, e: H2Ev) -> H2:
  match c:
    case H2{cfg, peer, rd, dec, enc, csw, crused, ss, cont, last, next, dead, out, evs}:
      H2{cfg, peer, rd, dec, enc, csw, crused, ss, cont, last, next, dead, out, Con{e, evs}}

def H2.streams(c: H2) -> List<&2, Strm>:
  match c:
    case H2{cfg, peer, rd, dec, enc, csw, crused, ss, cont, last, next, dead, out, evs}:
      ss

def H2.with_streams(c: H2, nss: List<&2, Strm>) -> H2:
  match c:
    case H2{cfg, peer, rd, dec, enc, csw, crused, ss, cont, last, next, dead, out, evs}:
      H2{cfg, peer, rd, dec, enc, csw, crused, nss, cont, last, next, dead, out, evs}

def H2.is_dead(c: H2) -> Bool:
  match c:
    case H2{cfg, peer, rd, dec, enc, csw, crused, ss, cont, last, next, dead, out, evs}:
      dead

def H2.cfg_of(c: H2) -> H2Cfg:
  match c:
    case H2{cfg, peer, rd, dec, enc, csw, crused, ss, cont, last, next, dead, out, evs}:
      cfg

def H2.peer_of(c: H2) -> H2Peer:
  match c:
    case H2{cfg, peer, rd, dec, enc, csw, crused, ss, cont, last, next, dead, out, evs}:
      peer

def H2.cont_of(c: H2) -> Maybe<&2, HCont>:
  match c:
    case H2{cfg, peer, rd, dec, enc, csw, crused, ss, cont, last, next, dead, out, evs}:
      cont

def H2.with_cont(c: H2, k: Maybe<&2, HCont>) -> H2:
  match c:
    case H2{cfg, peer, rd, dec, enc, csw, crused, ss, cont, last, next, dead, out, evs}:
      H2{cfg, peer, rd, dec, enc, csw, crused, ss, k, last, next, dead, out, evs}

def H2.last_of(c: H2) -> U32:
  match c:
    case H2{cfg, peer, rd, dec, enc, csw, crused, ss, cont, last, next, dead, out, evs}:
      last

def H2.cfg_server(cfg: H2Cfg) -> Bool:
  match cfg:
    case H2Cfg{server, mf, init, cwin, ms, cap}:
      server

def H2.server(c: H2) -> Bool:
  H2.cfg_server(H2.cfg_of(c))

# A connection error: GOAWAY with code, the application told, and nothing
# more read or sent but what is queued.
def H2.fail(c: H2, +code: U32, +why: String) -> H2:
  match c:
    case H2{cfg, peer, rd, dec, enc, csw, crused, ss, cont, last, next, dead, out, evs}:
      match dead:
        case True{}:
          H2{cfg, peer, rd, dec, enc, csw, crused, ss, cont, last, next, True{}, out, evs}
        case False{}:
          +l = last
          H2{cfg, peer, rd, dec, enc, csw, crused, ss, cont, l, next, True{}, Con{H2.frame(7, 0, 0, H2.be32(l, H2.be32(code, Hp.Hp.bytes(why)))), out}, Con{EvFatal{code, why}, evs}}

# Streams
# -------

def H2.s_get(ss: List<&2, Strm>, +sid: U32) -> Maybe<&2, Strm>:
  match ss:
    case Nil{}:
      None{}
    case Con{Strm{+id, sw, ru, le, re, q}, t}:
      H2.s_pick(Strm{id, sw, ru, le, re, q}, H2.s_get(t, sid), U32.is_eq(id, sid))

def H2.s_del(ss: List<&2, Strm>, +sid: U32) -> List<&2, Strm>:
  match ss:
    case Nil{}:
      Nil{}
    case Con{Strm{+id, sw, ru, le, re, q}, t}:
      H2.s_keep(Strm{id, sw, ru, le, re, q}, H2.s_del(t, sid), Bool.not(U32.is_eq(id, sid)))

# Puts s in place of the stream with its id, or last when none has it.
def H2.s_put(ss: List<&2, Strm>, +s: Strm) -> List<&2, Strm>:
  match ss:
    case Nil{}:
      [s]
    case Con{Strm{+id, sw, ru, le, re, q}, +t}:
      H2.s_put.go(Strm{id, sw, ru, le, re, q}, t, s, H2.s_put(t, s), U32.is_eq(id, H2.s_id(s)))

def H2.s_count(ss: List<&2, Strm>, +server: Bool) -> U32:
  match ss:
    case Nil{}:
      0
    case Con{Strm{id, sw, ru, le, re, q}, t}:
      U32.add(Bool.to_u32(Bool.xor(server, U32.is_even(id))), H2.s_count(t, server))

# A stream both sides ended, with nothing left to send, is gone.
def H2.s_done(s: Strm) -> Bool:
  match s:
    case Strm{id, sw, ru, le, re, q}:
      le && re && List.is_empty(&2, Chunk, q)

# Sending
# -------

def H2.hty(first: Bool) -> U32:
  match first:
    case True{}:
      1
    case False{}:
      9

def H2.flag(b: Bool, +bit: U32) -> U32:
  match b:
    case True{}:
      bit
    case False{}:
      0

# A header block as HEADERS, then CONTINUATIONs of at most mf bytes;
# END_STREAM on the HEADERS frame, END_HEADERS on the last.
def H2.hblock(fuel: Nat, +sid: U32, +first: Bool, +end: Bool, +bs: List<&2, U32>, +mf: U32,
  out: List<&2, List<&2, U32>>, fits: Bool) -> List<&2, List<&2, U32>>:
  match fuel fits:
    case 0n x:
      out
    case 1n+f True{}:
      Con{H2.frame(H2.hty(first), U32.or(4, H2.flag(first && end, 1)), sid, bs), out}
    case 1n+f False{}:
      H2.hblock(f, sid, False{}, end, List.drop(&2, U32, bs, U32.to_nat(mf)), mf,
        Con{H2.frame(H2.hty(first), H2.flag(first && end, 1), sid, List.take(&2, U32, bs, U32.to_nat(mf))), out},
        U32.is_le(H2.len(List.drop(&2, U32, bs, U32.to_nat(mf))), mf))

# DATA frames of at most mf bytes, END_STREAM on the last if end.
def H2.dsplit(fuel: Nat, +sid: U32, +end: Bool, +bs: List<&2, U32>, +mf: U32,
  out: List<&2, List<&2, U32>>, fits: Bool) -> List<&2, List<&2, U32>>:
  match fuel fits:
    case 0n x:
      out
    case 1n+f True{}:
      Con{H2.frame(0, H2.flag(end, 1), sid, bs), out}
    case 1n+f False{}:
      H2.dsplit(f, sid, end, List.drop(&2, U32, bs, U32.to_nat(mf)), mf,
        Con{H2.frame(0, 0, sid, List.take(&2, U32, bs, U32.to_nat(mf))), out},
        U32.is_le(H2.len(List.drop(&2, U32, bs, U32.to_nat(mf))), mf))

def H2.frames(+n: U32, +mf: U32) -> Nat:
  U32.to_nat(U32.add(U32.div(n, mf), 1))

# A stream being drained, with the connection's send window, encoder,
# the peer's largest frame and the bytes to write.
type DEv is Data:
  DEv{id: U32, sw: U32, ru: U32, le: Bool, re: Bool, csw: U32, enc: Hp.HEnc, mf: U32, out: List<&2, List<&2, U32>>}

type DStep is Data:
  DGo{ev: DEv}
  DStop{ev: DEv, left: Chunk}

def H2.avail(+csw: U32, +sw: U32) -> U32:
  U32.min(csw, U32.sub(U32.max(sw, H2.bias()), H2.bias()))

def H2.d_head(b: Hp.HEBlock, +id: U32, +sw: U32, +ru: U32, +end: Bool, +re: Bool, +csw: U32, +mf: U32,
  out: List<&2, List<&2, U32>>) -> DStep:
  match b:
    case Hp.HEBlock{e2, +bs}:
      DGo{DEv{id, sw, ru, end, re, csw, e2, mf,
        H2.hblock(H2.frames(H2.len(bs), mf), id, True{}, end, bs, mf, out, U32.is_le(H2.len(bs), mf))}}

def H2.d_data(+id: U32, +sw: U32, +ru: U32, +le: Bool, +re: Bool, +csw: U32, enc: Hp.HEnc, +mf: U32,
  out: List<&2, List<&2, U32>>, +bs: List<&2, U32>, +end: Bool, +n: U32, +av: U32, all: Bool, some: Bool) -> DStep:
  match all some:
    case True{} x:
      DGo{DEv{id, U32.sub(sw, n), ru, end, re, U32.sub(csw, n), enc, mf,
        H2.dsplit(H2.frames(n, mf), id, end, bs, mf, out, U32.is_le(n, mf))}}
    case False{} True{}:
      DStop{DEv{id, U32.sub(sw, av), ru, le, re, U32.sub(csw, av), enc, mf,
        H2.dsplit(H2.frames(av, mf), id, False{}, List.take(&2, U32, bs, U32.to_nat(av)), mf, out, U32.is_le(av, mf))},
        CData{List.drop(&2, U32, bs, U32.to_nat(av)), end}}
    case False{} False{}:
      DStop{DEv{id, sw, ru, le, re, csw, enc, mf, out}, CData{bs, end}}

# One chunk of a stream's queue: headers always go; data as far as the
# windows allow.
def H2.d_one(ch: Chunk, ev: DEv) -> DStep:
  match ch ev:
    case CHead{hs, +end} DEv{+id, +sw, +ru, le, +re, +csw, enc, +mf, out}:
      H2.d_head(Hp.Hp.encode(enc, hs), id, sw, ru, end, re, csw, mf, out)
    case CData{+bs, +end} DEv{+id, +sw, +ru, +le, +re, +csw, enc, +mf, out}:
      H2.d_data(id, sw, ru, le, re, csw, enc, mf, out, bs, end, H2.len(bs), H2.avail(csw, sw),
        U32.is_le(H2.len(bs), H2.avail(csw, sw)), U32.is_gt(H2.avail(csw, sw), 0))

type DOut is Data:
  DOut{s: Strm, csw: U32, enc: Hp.HEnc, out: List<&2, List<&2, U32>>}

def H2.d_fin(ev: DEv, q: List<&2, Chunk>) -> DOut:
  match ev:
    case DEv{id, sw, ru, le, re, csw, enc, mf, out}:
      DOut{Strm{id, sw, ru, le, re, q}, csw, enc, out}

def H2.drain(q: List<&2, Chunk>, st: DStep) -> DOut:
  match q st:
    case rest DStop{ev, left}:
      H2.d_fin(ev, Con{left, rest})
    case Nil{} DGo{ev}:
      H2.d_fin(ev, Nil{})
    case Con{ch, rest} DGo{ev}:
      H2.drain(rest, H2.d_one(ch, ev))

type FEv is Data:
  FEv{csw: U32, enc: Hp.HEnc, mf: U32, out: List<&2, List<&2, U32>>, kept: List<&2, Strm>}

def H2.f_merge(d: DOut, +mf: U32, kept: List<&2, Strm>) -> FEv:
  match d:
    case DOut{+s, csw, enc, out}:
      FEv{csw, enc, mf, out, H2.s_keep(s, kept, Bool.not(H2.s_done(s)))}

def H2.f_one(s: Strm, ev: FEv) -> FEv:
  match s ev:
    case Strm{id, sw, ru, le, re, q} FEv{csw, enc, +mf, out, kept}:
      H2.f_merge(H2.drain(q, DGo{DEv{id, sw, ru, le, re, csw, enc, mf, out}}), mf, kept)

def H2.f_go(ss: List<&2, Strm>, ev: FEv) -> FEv:
  match ss:
    case Nil{}:
      ev
    case Con{s, t}:
      H2.f_go(t, H2.f_one(s, ev))

def H2.peer_mf(p: H2Peer) -> U32:
  match p:
    case H2Peer{mf, init, ms}:
      mf

def H2.f_fin(c: H2, ev: FEv) -> H2:
  match c ev:
    case H2{cfg, peer, rd, dec, e0, c0, crused, ss, cont, last, next, dead, o0, evs} FEv{csw, enc, mf, out, kept}:
      H2{cfg, peer, rd, dec, enc, csw, crused, List.reverse(&2, Strm, kept), cont, last, next, dead, out, evs}

# Sends what every stream has queued, as far as the windows allow.
def H2.flush(c: H2) -> H2:
  match c:
    case H2{cfg, +peer, rd, dec, +enc, +csw, crused, +ss, cont, last, next, dead, +out, evs}:
      H2.f_fin(H2{cfg, peer, rd, dec, enc, csw, crused, ss, cont, last, next, dead, out, evs}, H2.f_go(ss, FEv{csw, enc, H2.peer_mf(peer), out, Nil{}}))

# Receiving
# ---------

def H2.with_dec(c: H2, d: Hp.HDec) -> H2:
  match c:
    case H2{cfg, peer, rd, dec, enc, csw, crused, ss, cont, last, next, dead, out, evs}:
      H2{cfg, peer, rd, d, enc, csw, crused, ss, cont, last, next, dead, out, evs}

def H2.with_enc(c: H2, e: Hp.HEnc) -> H2:
  match c:
    case H2{cfg, peer, rd, dec, enc, csw, crused, ss, cont, last, next, dead, out, evs}:
      H2{cfg, peer, rd, dec, e, csw, crused, ss, cont, last, next, dead, out, evs}

def H2.enc_of(c: H2) -> Hp.HEnc:
  match c:
    case H2{cfg, peer, rd, dec, enc, csw, crused, ss, cont, last, next, dead, out, evs}:
      enc

def H2.with_peer(c: H2, p: H2Peer) -> H2:
  match c:
    case H2{cfg, peer, rd, dec, enc, csw, crused, ss, cont, last, next, dead, out, evs}:
      H2{cfg, p, rd, dec, enc, csw, crused, ss, cont, last, next, dead, out, evs}

def H2.with_last(c: H2, +l: U32) -> H2:
  match c:
    case H2{cfg, peer, rd, dec, enc, csw, crused, ss, cont, last, next, dead, out, evs}:
      H2{cfg, peer, rd, dec, enc, csw, crused, ss, cont, l, next, dead, out, evs}

def H2.with_next(c: H2, +n: U32) -> H2:
  match c:
    case H2{cfg, peer, rd, dec, enc, csw, crused, ss, cont, last, next, dead, out, evs}:
      H2{cfg, peer, rd, dec, enc, csw, crused, ss, cont, last, n, dead, out, evs}

def H2.with_csw(c: H2, +w: U32) -> H2:
  match c:
    case H2{cfg, peer, rd, dec, enc, csw, crused, ss, cont, last, next, dead, out, evs}:
      H2{cfg, peer, rd, dec, enc, w, crused, ss, cont, last, next, dead, out, evs}

def H2.csw_of(c: H2) -> U32:
  match c:
    case H2{cfg, peer, rd, dec, enc, csw, crused, ss, cont, last, next, dead, out, evs}:
      csw

def H2.cfg_init(cfg: H2Cfg) -> U32:
  match cfg:
    case H2Cfg{server, mf, init, cwin, ms, cap}:
      init

def H2.cfg_cwin(cfg: H2Cfg) -> U32:
  match cfg:
    case H2Cfg{server, mf, init, cwin, ms, cap}:
      cwin

def H2.cfg_ms(cfg: H2Cfg) -> U32:
  match cfg:
    case H2Cfg{server, mf, init, cwin, ms, cap}:
      ms

def H2.cfg_cap(cfg: H2Cfg) -> U32:
  match cfg:
    case H2Cfg{server, mf, init, cwin, ms, cap}:
      cap

def H2.cfg_mf(cfg: H2Cfg) -> U32:
  match cfg:
    case H2Cfg{server, mf, init, cwin, ms, cap}:
      mf

# Resets sid: RST_STREAM sent, the stream gone, the application told.
def H2.rst(+c: H2, +sid: U32, +code: U32) -> H2:
  H2.ev1(H2.with_streams(H2.out1(c, H2.frame(3, 0, sid, H2.be32(code, Nil{}))),
    H2.s_del(H2.streams(c), sid)), EvRst{sid, code})

def H2.put_strm.go(+c: H2, +s: Strm, done: Bool) -> H2:
  match done:
    case True{}:
      H2.with_streams(c, H2.s_del(H2.streams(c), H2.s_id(s)))
    case False{}:
      H2.with_streams(c, H2.s_put(H2.streams(c), s))

# Stores s, or drops it once both sides ended it and nothing waits.
def H2.put_strm(c: H2, +s: Strm) -> H2:
  H2.put_strm.go(c, s, H2.s_done(s))

def H2.bit(+flags: U32, +b: U32) -> Bool:
  Bool.not(U32.is_zero(U32.and(flags, b)))

# A payload less its padding (PADDED, 0x8); None when the padding is as
# long as the payload.
def H2.unpad.go(t: List<&2, U32>, +n: U32, bad: Bool) -> Maybe<&2, List<&2, U32>>:
  match bad:
    case True{}:
      None{}
    case False{}:
      +t = t
      Some{List.take(&2, U32, t, U32.to_nat(U32.sub(H2.len(t), n)))}

def H2.unpad(padded: Bool, p: List<&2, U32>) -> Maybe<&2, List<&2, U32>>:
  match padded p:
    case False{} q:
      Some{q}
    case True{} Nil{}:
      None{}
    case True{} Con{+n, +t}:
      H2.unpad.go(t, n, U32.is_gt(n, H2.len(t)))

# A HEADERS payload less its priority fields (PRIORITY, 0x20).
def H2.unprio(prio: Bool, m: Maybe<&2, List<&2, U32>>) -> Maybe<&2, List<&2, U32>>:
  match prio m:
    case False{} x:
      x
    case True{} None{}:
      None{}
    case True{} Some{Con{a, Con{b, Con{d, Con{e, Con{g, t}}}}}}:
      Some{t}
    case True{} Some{q}:
      None{}

def H2.crused_of(c: H2) -> U32:
  match c:
    case H2{cfg, peer, rd, dec, enc, csw, crused, ss, cont, last, next, dead, out, evs}:
      crused

def H2.c_replenish.go(full: Bool, c: H2) -> H2:
  match full c:
    case True{} H2{cfg, peer, rd, dec, enc, csw, +crused, ss, cont, last, next, dead, out, evs}:
      H2{cfg, peer, rd, dec, enc, csw, 0, ss, cont, last, next, dead, Con{H2.wu(0, crused), out}, evs}
    case False{} x:
      x

def H2.add_crused(c: H2, +n: U32) -> H2:
  match c:
    case H2{cfg, peer, rd, dec, enc, csw, crused, ss, cont, last, next, dead, out, evs}:
      H2{cfg, peer, rd, dec, enc, csw, U32.add(crused, n), ss, cont, last, next, dead, out, evs}

# Gives the connection's window back once half of it is used.
def H2.c_replenish(+c: H2) -> H2:
  H2.c_replenish.go(U32.is_ge(H2.crused_of(c), U32.div(H2.cfg_cwin(H2.cfg_of(c)), 2)), c)

def H2.s_replenish.go(c: H2, +id: U32, +sw: U32, +ru: U32, +le: Bool, +re: Bool, q: List<&2, Chunk>, full: Bool) -> H2:
  match full:
    case True{}:
      H2.put_strm(H2.out1(c, H2.wu(id, ru)), Strm{id, sw, 0, le, re, q})
    case False{}:
      H2.put_strm(c, Strm{id, sw, ru, le, re, q})

# Stores s, giving its window back once half of it is used.
def H2.s_replenish(c: H2, s: Strm, +half: U32) -> H2:
  match s:
    case Strm{+id, sw, +ru, le, +re, q}:
      H2.s_replenish.go(c, id, sw, ru, le, re, q, U32.is_ge(ru, half) && Bool.not(re))

# DATA
# ----

def H2.data_ok(+c: H2, d: Maybe<&2, List<&2, U32>>, s: Strm, +sid: U32, +end: Bool, +n: U32) -> H2:
  match d s:
    case None{} x:
      H2.fail(c, H2.protocol_error(), "DATA padding as long as its payload")
    case Some{bs} Strm{id, sw, ru, le, re, q}:
      H2.s_replenish(H2.ev1(c, EvData{sid, bs, end}), Strm{id, sw, U32.add(ru, n), le, end, q},
        U32.div(H2.cfg_init(H2.cfg_of(c)), 2))

def H2.data_s.go(+c: H2, s: Strm, +sid: U32, +flags: U32, p: List<&2, U32>, +n: U32, closed: Bool, over: Bool) -> H2:
  match closed over:
    case True{} x:
      H2.rst(c, sid, H2.stream_closed())
    case False{} True{}:
      H2.rst(c, sid, H2.flow_control_error())
    case False{} False{}:
      H2.data_ok(c, H2.unpad(H2.bit(flags, 8), p), s, sid, H2.bit(flags, 1), n)

def H2.data_s(+c: H2, m: Maybe<&2, Strm>, +sid: U32, +flags: U32, p: List<&2, U32>, +n: U32) -> H2:
  match m:
    case None{}:
      H2.rst(c, sid, H2.stream_closed())
    case Some{Strm{id, sw, +ru, le, +re, q}}:
      H2.data_s.go(c, Strm{id, sw, ru, le, re, q}, sid, flags, p, n, re,
        U32.is_gt(U32.add(ru, n), H2.cfg_init(H2.cfg_of(c))))

def H2.data_in.go(+c: H2, +sid: U32, +flags: U32, p: List<&2, U32>, +n: U32, zero: Bool, over: Bool) -> H2:
  match zero over:
    case True{} x:
      H2.fail(c, H2.protocol_error(), "DATA on stream 0")
    case False{} True{}:
      H2.fail(c, H2.flow_control_error(), "DATA past the connection's window")
    case False{} False{}:
      H2.c_replenish(H2.data_s(H2.add_crused(c, n), H2.s_get(H2.streams(c), sid), sid, flags, p, n))

def H2.data_in(+c: H2, +sid: U32, +flags: U32, +p: List<&2, U32>) -> H2:
  H2.data_in.go(c, sid, flags, p, H2.len(p), U32.is_zero(sid),
    U32.is_gt(U32.add(H2.crused_of(c), H2.len(p)), H2.cfg_cwin(H2.cfg_of(c))))

# HEADERS and CONTINUATION
# ------------------------

def H2.dec_of(c: H2) -> Hp.HDec:
  match c:
    case H2{cfg, peer, rd, dec, enc, csw, crused, ss, cont, last, next, dead, out, evs}:
      dec

def H2.hdrs_old(c: H2, s: Strm, +sid: U32, hs: List<&2, H.Header>, +end: Bool) -> H2:
  match s:
    case Strm{id, sw, ru, le, re, q}:
      match re:
        case True{}:
          H2.rst(c, sid, H2.stream_closed())
        case False{}:
          H2.put_strm(H2.ev1(c, EvHeaders{sid, hs, end}), Strm{id, sw, ru, le, end, q})

def H2.peer_init(p: H2Peer) -> U32:
  match p:
    case H2Peer{mf, init, ms}:
      init

# A peer's new stream: taken while under our limit, else refused.
def H2.hdrs_new(+c: H2, +sid: U32, hs: List<&2, H.Header>, +end: Bool, full: Bool) -> H2:
  match full:
    case True{}:
      H2.rst(H2.with_last(c, sid), sid, H2.refused_stream())
    case False{}:
      H2.ev1(H2.put_strm(H2.with_last(c, sid),
        Strm{sid, U32.add(H2.bias(), H2.peer_init(H2.peer_of(c))), 0, False{}, end, Nil{}}),
        EvHeaders{sid, hs, end})

def H2.hdrs_none(+c: H2, +sid: U32, hs: List<&2, H.Header>, +end: Bool, opens: Bool, closed: Bool) -> H2:
  match opens closed:
    case True{} x:
      H2.hdrs_new(c, sid, hs, end,
        U32.is_ge(H2.s_count(H2.streams(c), H2.server(c)), H2.cfg_ms(H2.cfg_of(c))))
    case False{} True{}:
      H2.rst(c, sid, H2.stream_closed())
    case False{} False{}:
      H2.fail(c, H2.protocol_error(), "HEADERS on stream " ++ U32.show(sid) ++ ", which no one opened")

# A header block is whole: a new stream's request, or headers or trailers
# on an open one.
def H2.hdrs(+c: H2, m: Maybe<&2, Strm>, +sid: U32, hs: List<&2, H.Header>, +end: Bool) -> H2:
  match m:
    case Some{st}:
      H2.hdrs_old(c, st, sid, hs, end)
    case None{}:
      H2.hdrs_none(c, sid, hs, end,
        H2.server(c) && Bool.not(U32.is_even(sid)) && U32.is_gt(sid, H2.last_of(c)),
        U32.is_le(sid, H2.last_of(c)))

def H2.block.got(+c: H2, r: Result<&2, &2, String, Hp.HBlock>, +sid: U32, +end: Bool) -> H2:
  match r:
    case Fail{e}:
      H2.fail(c, H2.compression_error(), e)
    case Done{Hp.HBlock{d2, hs}}:
      H2.hdrs(H2.with_dec(c, d2), H2.s_get(H2.streams(c), sid), sid, hs, end)

def H2.block(+c: H2, +sid: U32, +end: Bool, bs: List<&2, U32>) -> H2:
  H2.block.got(c, Hp.Hp.decode(H2.dec_of(c), bs), sid, end)

def H2.frag(+c: H2, +sid: U32, +end: Bool, +bs: List<&2, U32>, big: Bool, done: Bool) -> H2:
  match big done:
    case True{} x:
      H2.fail(c, H2.enhance_your_calm(), "a header block past the header list's limit")
    case False{} True{}:
      H2.block(H2.with_cont(c, None{}), sid, end, bs)
    case False{} False{}:
      H2.with_cont(c, Some{HCont{sid, end, bs}})

def H2.frag_in(+c: H2, +sid: U32, +end: Bool, +bs: List<&2, U32>, done: Bool) -> H2:
  H2.frag(c, sid, end, bs, U32.is_gt(H2.len(bs), H2.cfg_cap(H2.cfg_of(c))), done)

def H2.headers_in.go(+c: H2, +sid: U32, +flags: U32, m: Maybe<&2, List<&2, U32>>) -> H2:
  match m:
    case None{}:
      H2.fail(c, H2.protocol_error(), "HEADERS padding or priority past its payload")
    case Some{bs}:
      H2.frag_in(c, sid, H2.bit(flags, 1), bs, H2.bit(flags, 4))

def H2.headers_in(+c: H2, +sid: U32, +flags: U32, p: List<&2, U32>, zero: Bool) -> H2:
  match zero:
    case True{}:
      H2.fail(c, H2.protocol_error(), "HEADERS on stream 0")
    case False{}:
      H2.headers_in.go(c, sid, flags, H2.unprio(H2.bit(flags, 32), H2.unpad(H2.bit(flags, 8), p)))

def H2.cont_in.go(+c: H2, +ksid: U32, +end: Bool, acc: List<&2, U32>, +flags: U32, p: List<&2, U32>, ok: Bool) -> H2:
  match ok:
    case True{}:
      H2.frag_in(c, ksid, end, List.append(&2, U32, acc, p), H2.bit(flags, 4))
    case False{}:
      H2.fail(c, H2.protocol_error(), "a frame inside a header block")

def H2.cont_in(+c: H2, k: HCont, +ty: U32, +sid: U32, +flags: U32, p: List<&2, U32>) -> H2:
  match k:
    case HCont{+ksid, +end, acc}:
      H2.cont_in.go(c, ksid, end, acc, flags, p, U32.is_eq(ty, 9) && U32.is_eq(sid, ksid))

# SETTINGS
# --------

def H2.s_shift(ss: List<&2, Strm>, +old: U32, +new: U32) -> List<&2, Strm>:
  match ss:
    case Nil{}:
      Nil{}
    case Con{Strm{id, sw, ru, le, re, q}, t}:
      Con{Strm{id, U32.add(U32.sub(sw, old), new), ru, le, re, q}, H2.s_shift(t, old, new)}

def H2.set_window.go(+c: H2, +v: U32, p: H2Peer) -> H2:
  match p:
    case H2Peer{mf, +init, ms}:
      H2.with_peer(H2.with_streams(c, H2.s_shift(H2.streams(c), init, v)), H2Peer{mf, v, ms})

def H2.set_window(+c: H2, +v: U32, big: Bool) -> H2:
  match big:
    case True{}:
      H2.fail(c, H2.flow_control_error(), "SETTINGS_INITIAL_WINDOW_SIZE past 2^31-1")
    case False{}:
      H2.set_window.go(c, v, H2.peer_of(c))

def H2.set_frame.go(c: H2, +v: U32, p: H2Peer) -> H2:
  match p:
    case H2Peer{mf, init, ms}:
      H2.with_peer(c, H2Peer{v, init, ms})

def H2.set_frame(+c: H2, +v: U32, bad: Bool) -> H2:
  match bad:
    case True{}:
      H2.fail(c, H2.protocol_error(), "SETTINGS_MAX_FRAME_SIZE out of range")
    case False{}:
      H2.set_frame.go(c, v, H2.peer_of(c))

def H2.set_streams.go(c: H2, +v: U32, p: H2Peer) -> H2:
  match p:
    case H2Peer{mf, init, ms}:
      H2.with_peer(c, H2Peer{mf, init, v})

def H2.set_streams(+c: H2, +v: U32) -> H2:
  H2.set_streams.go(c, v, H2.peer_of(c))

def H2.set_push(+c: H2, bad: Bool) -> H2:
  match bad:
    case True{}:
      H2.fail(c, H2.protocol_error(), "SETTINGS_ENABLE_PUSH neither 0 nor 1")
    case False{}:
      c

# One setting from the peer.
def H2.set1(+c: H2, id: U32, +v: U32) -> H2:
  match id:
    case 1:
      H2.with_enc(c, Hp.Hp.enc_resize(H2.enc_of(c), U32.min(v, 4096)))
    case 2:
      H2.set_push(c, U32.is_gt(v, 1))
    case 3:
      H2.set_streams(c, v)
    case 4:
      H2.set_window(c, v, U32.is_gt(v, H2.max_window()))
    case 5:
      H2.set_frame(c, v, U32.is_lt(v, 16384) || U32.is_gt(v, 16777215))
    case _:
      c

def H2.set_all(p: List<&2, U32>, c: H2) -> H2:
  match p:
    case Con{a, Con{b, Con{w, Con{x, Con{y, Con{z, t}}}}}}:
      H2.set_all(t, H2.set1(c, U32.or(U32.shln(a, 8n), b),
        U32.or(U32.shln(w, 24n), U32.or(U32.shln(x, 16n), U32.or(U32.shln(y, 8n), z)))))
    case _:
      c

def H2.ack_settings.go(c: H2, dead: Bool) -> H2:
  match dead:
    case True{}:
      c
    case False{}:
      H2.out1(c, H2.frame(4, 1, 0, Nil{}))

def H2.ack_settings(+c: H2) -> H2:
  H2.ack_settings.go(c, H2.is_dead(c))

def H2.settings_in.go(+c: H2, p: List<&2, U32>, zero: Bool, ack: Bool, empty: Bool, whole: Bool) -> H2:
  match zero ack empty whole:
    case False{} a e w:
      H2.fail(c, H2.protocol_error(), "SETTINGS on a stream")
    case True{} True{} True{} w:
      c
    case True{} True{} False{} w:
      H2.fail(c, H2.frame_size_error(), "a SETTINGS ACK with a payload")
    case True{} False{} e False{}:
      H2.fail(c, H2.frame_size_error(), "SETTINGS not a multiple of 6 bytes")
    case True{} False{} e True{}:
      H2.flush(H2.ack_settings(H2.set_all(p, c)))

def H2.settings_in(+c: H2, +sid: U32, +flags: U32, +p: List<&2, U32>) -> H2:
  H2.settings_in.go(c, p, U32.is_zero(sid), H2.bit(flags, 1), List.is_empty(&2, U32, p),
    U32.is_zero(U32.mod(H2.len(p), 6)))

# PING, GOAWAY, WINDOW_UPDATE, RST_STREAM, PRIORITY
# -------------------------------------------------

def H2.ping_in(+c: H2, zero: Bool, eight: Bool, ack: Bool, p: List<&2, U32>) -> H2:
  match zero eight ack:
    case False{} e a:
      H2.fail(c, H2.protocol_error(), "PING on a stream")
    case True{} False{} a:
      H2.fail(c, H2.frame_size_error(), "a PING not of 8 bytes")
    case True{} True{} True{}:
      c
    case True{} True{} False{}:
      H2.out1(c, H2.frame(6, 1, 0, p))

def H2.mine(+id: U32, server: Bool) -> Bool:
  Bool.xor(server, Bool.not(U32.is_even(id)))

def H2.refused.pick(+id: U32, rest: List<&2, U32>, hit: Bool) -> List<&2, U32>:
  match hit:
    case True{}:
      Con{id, rest}
    case False{}:
      rest

# The ids of our streams past last, which the peer's GOAWAY refused.
def H2.refused(ss: List<&2, Strm>, +last: U32, +server: Bool) -> List<&2, U32>:
  match ss:
    case Nil{}:
      Nil{}
    case Con{Strm{+id, sw, ru, le, re, q}, t}:
      H2.refused.pick(id, H2.refused(t, last, server), H2.mine(id, server) && U32.is_gt(id, last))

def H2.refuse_all(ids: List<&2, U32>, +c: H2) -> H2:
  match ids:
    case Nil{}:
      c
    case Con{+id, t}:
      H2.refuse_all(t, H2.ev1(H2.with_streams(c, H2.s_del(H2.streams(c), id)), EvRst{id, H2.refused_stream()}))

def H2.goaway_in(+c: H2, zero: Bool, short: Bool, +p: List<&2, U32>) -> H2:
  match zero short:
    case False{} s:
      H2.fail(c, H2.protocol_error(), "GOAWAY on a stream")
    case True{} True{}:
      H2.fail(c, H2.frame_size_error(), "a GOAWAY under 8 bytes")
    case True{} False{}:
      +last = U32.and(H2.get32(p), H2.max_window())
      H2.refuse_all(H2.refused(H2.streams(c), last, H2.server(c)),
        H2.ev1(H2.with_next(c, 4294967295), EvGoaway{last, H2.get32(List.drop(&2, U32, p, 4n))}))

def H2.wu_conn(+c: H2, +inc: U32, zero: Bool, over: Bool) -> H2:
  match zero over:
    case True{} o:
      H2.fail(c, H2.protocol_error(), "a WINDOW_UPDATE of 0")
    case False{} True{}:
      H2.fail(c, H2.flow_control_error(), "the connection's window past 2^31-1")
    case False{} False{}:
      H2.flush(H2.with_csw(c, U32.add(H2.csw_of(c), inc)))

def H2.wu_strm.go(+c: H2, +inc: U32, zero: Bool, over: Bool, s: Strm) -> H2:
  match zero over s:
    case True{} o Strm{+id, sw, ru, le, re, q}:
      H2.rst(c, id, H2.protocol_error())
    case False{} True{} Strm{+id, sw, ru, le, re, q}:
      H2.rst(c, id, H2.flow_control_error())
    case False{} False{} Strm{id, sw, ru, le, re, q}:
      H2.flush(H2.put_strm(c, Strm{id, U32.add(sw, inc), ru, le, re, q}))

def H2.wu_strm(+c: H2, m: Maybe<&2, Strm>, +inc: U32) -> H2:
  match m:
    case None{}:
      c
    case Some{Strm{id, +sw, ru, le, re, q}}:
      H2.wu_strm.go(c, inc, U32.is_zero(inc), U32.is_gt(inc, U32.sub(4294967295, sw)),
        Strm{id, sw, ru, le, re, q})

def H2.wu_in.go(+c: H2, +sid: U32, +inc: U32, conn: Bool) -> H2:
  match conn:
    case True{}:
      H2.wu_conn(c, inc, U32.is_zero(inc), U32.is_gt(inc, U32.sub(H2.max_window(), H2.csw_of(c))))
    case False{}:
      H2.wu_strm(c, H2.s_get(H2.streams(c), sid), inc)

def H2.wu_in(+c: H2, +sid: U32, four: Bool, +p: List<&2, U32>) -> H2:
  match four:
    case False{}:
      H2.fail(c, H2.frame_size_error(), "a WINDOW_UPDATE not of 4 bytes")
    case True{}:
      H2.wu_in.go(c, sid, U32.and(H2.get32(p), H2.max_window()), U32.is_zero(sid))

def H2.rst_in.go(+c: H2, m: Maybe<&2, Strm>, +sid: U32, +code: U32) -> H2:
  match m:
    case None{}:
      c
    case Some{x}:
      H2.ev1(H2.with_streams(c, H2.s_del(H2.streams(c), sid)), EvRst{sid, code})

def H2.rst_in(+c: H2, +sid: U32, zero: Bool, four: Bool, +p: List<&2, U32>) -> H2:
  match zero four:
    case True{} f:
      H2.fail(c, H2.protocol_error(), "RST_STREAM on stream 0")
    case False{} False{}:
      H2.fail(c, H2.frame_size_error(), "a RST_STREAM not of 4 bytes")
    case False{} True{}:
      H2.rst_in.go(c, H2.s_get(H2.streams(c), sid), sid, H2.get32(p))

def H2.prio_in(+c: H2, +sid: U32, zero: Bool, five: Bool) -> H2:
  match zero five:
    case True{} f:
      H2.fail(c, H2.protocol_error(), "PRIORITY on stream 0")
    case False{} False{}:
      H2.rst(c, sid, H2.frame_size_error())
    case False{} True{}:
      c

# A frame
# -------

def H2.on.ty(+c: H2, ty: U32, +flags: U32, +sid: U32, +p: List<&2, U32>) -> H2:
  match ty:
    case 0:
      H2.data_in(c, sid, flags, p)
    case 1:
      H2.headers_in(c, sid, flags, p, U32.is_zero(sid))
    case 2:
      H2.prio_in(c, sid, U32.is_zero(sid), U32.is_eq(H2.len(p), 5))
    case 3:
      H2.rst_in(c, sid, U32.is_zero(sid), U32.is_eq(H2.len(p), 4), p)
    case 4:
      H2.settings_in(c, sid, flags, p)
    case 5:
      H2.fail(c, H2.protocol_error(), "PUSH_PROMISE, though push is off")
    case 6:
      H2.ping_in(c, U32.is_zero(sid), U32.is_eq(H2.len(p), 8), H2.bit(flags, 1), p)
    case 7:
      H2.goaway_in(c, U32.is_zero(sid), U32.is_lt(H2.len(p), 8), p)
    case 8:
      H2.wu_in(c, sid, U32.is_eq(H2.len(p), 4), p)
    case 9:
      H2.fail(c, H2.protocol_error(), "CONTINUATION outside a header block")
    case _:
      c

def H2.on.go(dead: Bool, k: Maybe<&2, HCont>, +c: H2, f: Frame) -> H2:
  match dead k f:
    case True{} x y:
      c
    case False{} Some{kk} Frame{+ty, +flags, +sid, p}:
      H2.cont_in(c, kk, ty, sid, flags, p)
    case False{} None{} Frame{ty, +flags, +sid, +p}:
      H2.on.ty(c, ty, flags, sid, p)

# One frame from the peer.
def H2.on(+c: H2, f: Frame) -> H2:
  H2.on.go(H2.is_dead(c), H2.cont_of(c), c, f)

# Bytes in
# --------

def H2.on_all(fs: List<&2, Frame>, c: H2) -> H2:
  match fs:
    case Nil{}:
      c
    case Con{f, t}:
      H2.on_all(t, H2.on(c, f))

def H2.rd_err(+c: H2, rd: FRd) -> H2:
  match rd:
    case FBad{code, why}:
      H2.fail(c, code, why)
    case _:
      c

def H2.rd_of(c: H2) -> FRd:
  match c:
    case H2{cfg, peer, rd, dec, enc, csw, crused, ss, cont, last, next, dead, out, evs}:
      rd

def H2.with_rd(c: H2, r: FRd) -> H2:
  match c:
    case H2{cfg, peer, rd, dec, enc, csw, crused, ss, cont, last, next, dead, out, evs}:
      H2{cfg, peer, r, dec, enc, csw, crused, ss, cont, last, next, dead, out, evs}

def H2.feed.got(c: H2, fed: FFed) -> H2:
  match fed:
    case FFed{+r, frames}:
      H2.rd_err(H2.on_all(frames, H2.with_rd(c, r)), r)

# Bytes from the peer: the frames they finish, acted on in order.
def H2.feed(+c: H2, bs: List<&2, U32>) -> H2:
  H2.feed.got(c, H2.read(H2.rd_of(c), bs, H2.cfg_mf(H2.cfg_of(c))))

# The application's side
# ----------------------

type H2Opened is Data:
  H2Opened{c: H2, sid: U32}

def H2.next_of(c: H2) -> U32:
  match c:
    case H2{cfg, peer, rd, dec, enc, csw, crused, ss, cont, last, next, dead, out, evs}:
      next

def H2.open.go(+c: H2, hs: List<&2, H.Header>, +end: Bool, +sid: U32, ok: Bool) -> H2Opened:
  match ok:
    case True{}:
      H2Opened{H2.flush(H2.put_strm(H2.with_next(c, U32.add(sid, 2)),
        Strm{sid, U32.add(H2.bias(), H2.peer_init(H2.peer_of(c))), 0, False{}, False{}, [CHead{hs, end}]})), sid}
    case False{}:
      H2Opened{c, 0}

# A client's new stream: its request headers (end: no body follows) and
# its id; 0 when the connection is over or a GOAWAY came.
def H2.open(+c: H2, hs: List<&2, H.Header>, +end: Bool) -> H2Opened:
  H2.open.go(c, hs, end, H2.next_of(c),
    Bool.not(H2.is_dead(c) || H2.server(c)) && U32.is_le(H2.next_of(c), H2.max_window()))

def H2.send.go(c: H2, m: Maybe<&2, Strm>, ch: Chunk) -> H2:
  match m:
    case None{}:
      c
    case Some{Strm{id, sw, ru, le, re, q}}:
      match le:
        case True{}:
          c
        case False{}:
          H2.flush(H2.put_strm(c, Strm{id, sw, ru, le, re, List.append(&2, Chunk, q, [ch])}))

# Queues headers (a response, or trailers: end) or data on sid, sent as
# soon as the windows allow; nothing on a stream that is gone or ended.
def H2.send(+c: H2, +sid: U32, ch: Chunk) -> H2:
  H2.send.go(c, H2.s_get(H2.streams(c), sid), ch)

def H2.reset.go(+c: H2, m: Maybe<&2, Strm>, +sid: U32, +code: U32) -> H2:
  match m:
    case None{}:
      c
    case Some{x}:
      H2.with_streams(H2.out1(c, H2.frame(3, 0, sid, H2.be32(code, Nil{}))), H2.s_del(H2.streams(c), sid))

# Resets sid with code (CANCEL, say), unless it is gone.
def H2.reset(+c: H2, +sid: U32, +code: U32) -> H2:
  H2.reset.go(c, H2.s_get(H2.streams(c), sid), sid, code)

# Ends the connection: GOAWAY with code (NO_ERROR to close cleanly), after
# which nothing more is read or sent.
def H2.close(c: H2, +code: U32) -> H2:
  match c:
    case H2{cfg, peer, rd, dec, enc, csw, crused, ss, cont, +last, next, dead, out, evs}:
      match dead:
        case True{}:
          H2{cfg, peer, rd, dec, enc, csw, crused, ss, cont, last, next, dead, out, evs}
        case False{}:
          H2{cfg, peer, rd, dec, enc, csw, crused, ss, cont, last, next, True{}, Con{H2.frame(7, 0, 0, H2.be32(last, H2.be32(code, Nil{}))), out}, evs}

type H2Take is Data:
  H2Take{c: H2, bytes: List<&2, U32>, evs: List<&2, H2Ev>}

# What waits: the bytes to write, in order, and the events.
def H2.take(c: H2) -> H2Take:
  match c:
    case H2{cfg, peer, rd, dec, enc, csw, crused, ss, cont, last, next, dead, out, evs}:
      H2Take{H2{cfg, peer, rd, dec, enc, csw, crused, ss, cont, last, next, dead, Nil{}, Nil{}}, List.concat(&2, U32, List.reverse(&2, List<&2, U32>, out)),
        List.reverse(&2, H2Ev, evs)}

# Whether the connection is over: once its bytes are written, close it.
def H2.over(c: H2) -> Bool:
  H2.is_dead(c)

def H2.take_bytes(t: H2Take) -> List<&2, U32>:
  match t:
    case H2Take{c, bs, es}:
      bs

def H2.take_evs(t: H2Take) -> List<&2, H2Ev>:
  match t:
    case H2Take{c, bs, es}:
      es

def H2.opened(o: H2Opened) -> H2:
  match o:
    case H2Opened{c, sid}:
      c

def H2.opened_sid(o: H2Opened) -> U32:
  match o:
    case H2Opened{c, sid}:
      sid
