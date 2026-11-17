import Base
import ../src/pb.bend as P

def hex(bs: List<&2, U32>) -> String:
  match bs:
    case Nil{}:
      ""
    case Con{b, t}:
      U32.hex(b) ++ " " ++ hex(t)

# containerd's Mount: type 1, source 2, target 3, options 4 (repeated).
def mount(ty: String, src: String, opts: List<&2, String>) -> List<&2, P.PbField>:
  List.concat(&2, P.PbField, [P.Pb.str(1, ty), P.Pb.str(2, src), P.Pb.strs(4, opts)])

def show_mount.go(+m: List<&2, P.PbField>) -> String:
  P.Pb.get_str(m, 1) ++ " " ++ P.Pb.get_str(m, 2) ++ " " ++
    List.show(~&2, ~String, ~(s => s), P.Pb.all_str(m, 4))

def show_mount(m: List<&2, P.PbField>) -> String:
  show_mount.go(m)

def show_mounts(r: Result<&2, &2, String, List<&2, List<&2, P.PbField>>>) -> String:
  match r:
    case Fail{e}:
      "fail: " ++ e
    case Done{ms}:
      List.show(~&2, ~List<&2, P.PbField>, ~show_mount, ms)

def show_msgs(r: Result<&2, &2, String, List<&2, P.PbField>>) -> String:
  match r:
    case Fail{e}:
      "fail: " ++ e
    case Done{m}:
      show_mounts(P.Pb.all_msg(m, 1))

def show_kv(kv: P.PbStr) -> String:
  match kv:
    case P.PbStr{k, v}:
      k ++ "=" ++ v

def show_map(r: Result<&2, &2, String, List<&2, P.PbStr>>) -> String:
  match r:
    case Fail{e}:
      "fail: " ++ e
    case Done{kvs}:
      List.show(~&2, ~P.PbStr, ~show_kv, kvs)

def show_labels(r: Result<&2, &2, String, List<&2, P.PbField>>) -> String:
  match r:
    case Fail{e}:
      "fail: " ++ e
    case Done{m}:
      show_map(P.Pb.get_str_map(m, 5))

def main() -> IO(Unit):
  +resp = P.Pb.encode(P.Pb.msgs(1, [mount("overlay", "overlay", ["lowerdir=/a:/b", "upperdir=/c"]), mount("bind", "/x", ["ro", "rbind"])]))
  do IO<Unit>:
    IO.print(hex(resp))
    IO.print(show_msgs(P.Pb.decode(resp)))
    IO.print(show_labels(P.Pb.decode(P.Pb.encode(P.Pb.str_map(5, [P.PbStr{"containerd.io/gc.root", "x"}, P.PbStr{"k", ""}])))))
    IO.print(show_msgs(P.Pb.decode([10, 3, 8])))
