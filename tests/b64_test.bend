import Base
import ../src/utf8.bend as U
import ../src/base64.bend as B

def show(m: Maybe<&2, List<&2, U32>>) -> String:
  match m:
    case Some{bs}:
      U.Utf8.decode_all(bs)
    case None{}:
      "<bad>"

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(show(B.B64.decode("aGVsbG8gd29ybGQ=")))
    IO.print(show(B.B64.decode("TWFu\nTWE=")))
    IO.print(show(B.B64.decode("a$b")))
    IO.print(B.B64.encode(U.Utf8.encode("hello world")))
    IO.print(B.B64.encode(U.Utf8.encode("Ma")))
