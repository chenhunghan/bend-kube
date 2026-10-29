import Base
import ../src/json.bend as J

def show_res(r: Result<&2, &2, String, J.Json>) -> String:
  match r:
    case Done{v}:
      "ok " ++ J.Json.show(v)
    case Fail{e}:
      "err " ++ e

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(show_res(J.Json.parse("{\"a\": [1, 2.5e3, -3], \"b\": {\"c\": null, \"d\": true}, \"e\": \"x\\\"y\\u0041\\n\"}")))
    IO.print(show_res(J.Json.parse("[]")))
    IO.print(show_res(J.Json.parse("{}")))
    IO.print(show_res(J.Json.parse(" 42 ")))
    IO.print(show_res(J.Json.parse("[1,]")))
    IO.print(show_res(J.Json.parse("{\"a\" 1}")))
    IO.print(show_res(J.Json.parse("[1 2]")))
    IO.print(show_res(J.Json.parse("tru")))
    IO.print(show_res(J.Json.parse("[1")))
    IO.print(J.Json.str_or(J.Json.at(J.Json.obj([J.KV{"m", J.Json.obj([J.KV{"n", J.Json.str("deep")}])}]), ["m", "n"]), "?"))
