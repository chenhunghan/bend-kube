import Base
import ../src/time.bend as T

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(T.Time.rfc3339(0))
    IO.print(T.Time.rfc3339_micro(1793284200, 1234))
    IO.print(T.Time.rfc3339(951782400))
    IO.print(T.Time.rfc3339(4102444799))
    IO.print(T.Wall.micro(T.Wall{20755, 52200, 1234}))
    IO.print(T.Wall.rfc3339(T.Wall{100000, 86399, 0}))

