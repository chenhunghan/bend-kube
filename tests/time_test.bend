import Base
import ../src/time.bend as T

def opt(m: Maybe<&2, U32>) -> String:
  match m:
    case Some{+n}:
      U32.show(n) ++ " " ++ T.Time.rfc3339(n)
    case None{}:
      "none"

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(T.Time.rfc3339(0))
    IO.print(T.Time.rfc3339_micro(1793284200, 1234))
    IO.print(T.Time.rfc3339(951782400))
    IO.print(T.Time.rfc3339(4102444799))
    IO.print(T.Wall.micro(T.Wall{20755, 52200, 1234}))
    IO.print(T.Wall.rfc3339(T.Wall{100000, 86399, 0}))
    IO.print(opt(T.Time.parse("2000-03-01T00:00:00Z")))
    IO.print(opt(T.Time.parse("2099-12-31T23:59:59Z")))
    IO.print(opt(T.Time.parse("2026-10-29T15:48:25.123456Z")))
    IO.print(opt(T.Time.parse("1970-01-01T00:00:00Z")))
    IO.print(opt(T.Time.parse("2024-02-29T12:00:00Z")))
    IO.print(opt(T.Time.parse("2026-10-29 15:48:25Z")))
    IO.print(opt(T.Time.parse("2026-10-29T15:48:25")))
    IO.print(opt(T.Time.parse("")))
    IO.print(U32.show(T.Wall.secs(T.Wall{20755, 52200, 1234})))
