import Base
import ../src/gzip.bend as Z
import ../src/utf8.bend as U

# gzip.bend against streams Python's gzip module made: each kind of block,
# names, members one after another, and the refusals. (These are tests,
# not laws: the Lean kernel runs out of fuel building the decoder's 32 KiB
# window.) Then a stream fed a byte at a time decodes as it does whole:
# the decoder stops between any two bits.
def data() -> List<&2, U32>:
  [31, 139, 8, 0, 0, 0, 0, 0, 2, 255, 43, 201, 72, 85, 40, 44, 205, 76, 206, 86, 72, 42, 202, 47, 207, 83, 72, 203, 175, 80, 200, 42, 205, 45, 40, 86, 200, 47, 75, 45, 82, 40, 1, 74, 231, 36, 86, 85, 42, 164, 228, 167, 91, 131, 121, 163, 138, 71, 21, 143, 42, 166, 170, 98, 0, 164, 206, 253, 118, 132, 3, 0, 0]

def show(r: Result<&2, &2, String, Unit>, bs: List<&2, U32>) -> String:
  match r:
    case Fail{e}:
      "fail: " ++ e
    case Done{u}:
      +bs = bs
      Nat.show(List.length(&2, U32, bs)) ++ " bytes: " ++ U.Utf8.decode_all(List.take(&2, U32, bs, 60n))

def chunks(bs: List<&2, U32>, o: Z.GzOut, acc: List<&2, List<&2, U32>>) -> String:
  match bs o:
    case Nil{} Z.GzOut{g, out}:
      show(Z.Gz.finish(g), List.concat(&2, U32, List.reverse(&2, List<&2, U32>, Con{out, acc})))
    case Con{b, t} Z.GzOut{g, out}:
      chunks(t, Z.Gz.feed(g, [b]), Con{out, acc})

def whole(r: Result<&2, &2, String, List<&2, U32>>) -> String:
  match r:
    case Fail{e}:
      "fail: " ++ e
    case Done{bs}:
      show(Done{Unit{}}, bs)

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print("a fixed-Huffman block: " ++ whole(Z.Gz.inflate([31, 139, 8, 0, 0, 0, 0, 0, 2, 255, 203, 72, 205, 201, 201, 87, 200, 64, 34, 203, 243, 139, 114, 82, 184, 0, 136, 217, 91, 224, 24, 0, 0, 0])))
    IO.print("a stored block (gzip -0): " ++ whole(Z.Gz.inflate([31, 139, 8, 0, 0, 0, 0, 0, 0, 255, 1, 3, 0, 252, 255, 97, 98, 99, 194, 65, 36, 53, 3, 0, 0, 0])))
    IO.print("a member with a file name: " ++ whole(Z.Gz.inflate([31, 139, 8, 8, 0, 0, 0, 0, 2, 255, 108, 97, 121, 101, 114, 46, 116, 97, 114, 0, 171, 0, 0, 131, 22, 220, 140, 1, 0, 0, 0])))
    IO.print("a dynamic-Huffman block with back references: " ++ whole(Z.Gz.inflate([31, 139, 8, 0, 0, 0, 0, 0, 2, 255, 181, 203, 201, 17, 128, 48, 12, 67, 209, 86, 84, 1, 13, 80, 77, 2, 206, 194, 18, 103, 15, 80, 61, 30, 122, 224, 168, 249, 79, 213, 17, 82, 243, 203, 14, 157, 121, 4, 24, 190, 176, 181, 51, 22, 112, 167, 140, 42, 249, 80, 207, 141, 149, 237, 252, 173, 127, 112, 84, 226, 206, 27, 90, 208, 240, 213, 193, 248, 78, 146, 30, 10, 56, 124, 106, 156, 229, 107, 203, 244, 2, 79, 38, 81, 217, 175, 0, 0, 0])))
    IO.print("two members, one stream: " ++ whole(Z.Gz.inflate([31, 139, 8, 0, 0, 0, 0, 0, 2, 255, 203, 207, 75, 85, 0, 0, 73, 97, 172, 35, 4, 0, 0, 0, 31, 139, 8, 0, 0, 0, 0, 0, 2, 255, 43, 41, 207, 7, 0, 102, 138, 202, 17, 3, 0, 0, 0])))
    IO.print("a wrong CRC-32: " ++ whole(Z.Gz.inflate([31, 139, 8, 0, 0, 0, 0, 0, 2, 255, 203, 72, 205, 201, 201, 87, 200, 64, 34, 203, 243, 139, 114, 82, 184, 0, 137, 217, 91, 224, 24, 0, 0, 0])))
    IO.print("a stream cut short: " ++ whole(Z.Gz.inflate([31, 139, 8, 0, 0, 0, 0, 0, 2, 255, 203, 72, 205, 201, 201, 87, 200, 64, 34, 203, 243, 139, 114, 82, 184, 0, 136, 217, 91, 224, 24, 0, 0])))
    IO.print("not gzip: " ++ whole(Z.Gz.inflate([80, 75, 3, 4])))
    IO.print("whole: " ++ whole(Z.Gz.inflate(data())))
    IO.print("a byte at a time: " ++ chunks(data(), Z.GzOut{Z.Gz.new(), Nil{}}, Nil{}))
