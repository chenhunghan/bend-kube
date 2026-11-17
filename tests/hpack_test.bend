import Base
import ../src/http.bend as H
import ../src/hpack.bend as Hp

def show_h(h: H.Header) -> String:
  match h:
    case H.Header{n, v}:
      n ++ ": " ++ v

def show_hs(hs: List<&2, H.Header>) -> String:
  List.show(~&2, ~H.Header, ~show_h, hs)

def show_seq(r: Result<&2, &2, String, Hp.HSeq>) -> String:
  match r:
    case Fail{e}:
      "fail: " ++ e
    case Done{Hp.HSeq{bs, t, s}}:
      List.show(~&2, ~List<&2, H.Header>, ~show_hs, bs) ++ " table " ++ U32.show(s)

def req(path: String) -> List<&2, H.Header>:
  [H.Header{":method", "POST"}, H.Header{":scheme", "http"}, H.Header{":path", path},
    H.Header{":authority", "localhost"}, H.Header{"content-type", "application/grpc"},
    H.Header{"te", "trailers"}, H.Header{"grpc-timeout", "10S"}]

def size(bs: List<&2, U32>) -> String:
  Nat.show(List.length(&2, U32, bs))

def sizes(bss: List<&2, List<&2, U32>>) -> String:
  List.show(~&2, ~List<&2, U32>, ~size, bss)

def main() -> IO(Unit):
  +blocks = {[req("/containerd.services.snapshots.v1.Snapshots/Prepare"),
    req("/containerd.services.snapshots.v1.Snapshots/Mounts"),
    req("/containerd.services.snapshots.v1.Snapshots/Prepare")] : List<&2, List<&2, H.Header>>}
  +wire = Hp.Hp.encode_seq(Hp.Hp.enc_new(4096, True{}), blocks)
  +raw = Hp.Hp.encode_seq(Hp.Hp.enc_new(4096, False{}), blocks)
  do IO<Unit>:
    IO.print("huffman block sizes " ++ sizes(wire))
    IO.print("raw block sizes " ++ sizes(raw))
    IO.print(show_seq(Hp.Hp.decode_seq(Hp.Hp.dec_new(4096, 65536), wire)))
    IO.print(show_seq(Hp.Hp.decode_seq(Hp.Hp.dec_new(4096, 65536), raw)))
    IO.print(show_seq(Hp.Hp.decode_seq(Hp.Hp.dec_new(4096, 65536), [[0, 3, 97, 98, 99, 131, 198, 115, 255]])))
