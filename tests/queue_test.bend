import Base
import ../src/queue.bend as Q

# A scenario through client-go's workqueue rules, one worker slot.

type Out is Data:
  Out{q: Q.Queue, line: String}

def q(o: Out) -> Q.Queue:
  match o:
    case Out{x, l}:
      x

def pop.fin(r: Q.Queue & Maybe<&2, String>) -> Out:
  match r:
    case (q, Some{k}):
      Out{q, "pop " ++ k}
    case (q, None{}):
      Out{q, "pop none"}

def pop(q: Q.Queue) -> Out:
  pop.fin(Q.Queue.pop(q))

def done.fin(r: Q.Queue & List<&2, Q.Timer>) -> Out:
  match r:
    case (q, Nil{}):
      Out{q, "no timer"}
    case (q, Con{Q.Timer{k, g, ms}, t}):
      Out{q, "timer " ++ k ++ " gen " ++ U32.show(g) ++ " after " ++ U32.show(ms) ++ "ms"}

def done(q: Q.Queue, k: String, a: Q.Action) -> Out:
  done.fin(Q.Queue.done(q, k, a))

def line(o: Out) -> String:
  match o:
    case Out{q, l}:
      l

def main() -> IO(Unit):
  +q0 = Q.Queue.add(Q.Queue.add(Q.Queue.add(Q.Queue.new(1), "a"), "b"), "a")
  +o1 = pop(q0)
  +o2 = pop(q(o1))
  +q2 = Q.Queue.add(q(o2), "a")
  +o3 = done(q2, "a", Q.Requeue{1000})
  +o4 = pop(q(o3))
  +o5 = done(q(o4), "b", Q.Retry{"boom"})
  +o6 = done(q(o5), "a", Q.Retry{"boom"})
  +o7 = pop(q(o6))
  +o8 = done(q(o7), "a", Q.Retry{"again"})
  +q7 = Q.Queue.wake(q(o8), "a", 1)
  +q8 = Q.Queue.wake(q(o8), "a", 6)
  do IO<Unit>:
    IO.print(line(o1))
    IO.print(line(o2))
    IO.print("a running: " ++ Bool.show(Q.Queue.running(q2, "a")))
    IO.print("a waiting while running: " ++ Bool.show(Q.Queue.waiting(q2, "a")))
    IO.print(line(o3))
    IO.print("a queued again after done (dirty): " ++ Bool.show(Q.Queue.waiting(q(o3), "a")))
    IO.print(line(o4))
    IO.print(line(o5))
    IO.print(line(o6) ++ " (a was not running)")
    IO.print(line(o7))
    IO.print(line(o8))
    IO.print("stale wake queues a: " ++ Bool.show(Q.Queue.waiting(q7, "a")))
    IO.print("current wake queues a: " ++ Bool.show(Q.Queue.waiting(q8, "a")))
    IO.print("backoff: " ++ U32.show(Q.Queue.backoff(0)) ++ " " ++ U32.show(Q.Queue.backoff(1))
      ++ " " ++ U32.show(Q.Queue.backoff(2)) ++ " " ++ U32.show(Q.Queue.backoff(30)))
