import Base

# Queue
# =====
#
# The controller's work queue, with client-go's workqueue semantics and
# kube-runtime's scheduler folded in:
#
# - A key waits in the queue at most once (dedup).
# - A key is processed by at most one worker at a time: adding a key that
#   is running marks it dirty, and it is queued again when its run ends.
# - At most max keys run at once.
# - A run ends with an Action: requeue after a delay, wait for a change, or
#   retry after an error with per-key exponential backoff (client-go's
#   ItemExponentialFailureRateLimiter: 5ms doubling, at most 1000s); a
#   success forgets the key's failures.
# - Delayed requeues are timers the driver sleeps on; each carries the
#   key's generation, and an add (or a newer timer) bumps it, so a stale
#   timer wakes to nothing.

type Action is Data:
  Requeue{ms: U32}
  AwaitChange{}
  Retry{msg: String}

type Queue is Data:
  Queue{front: List<&2, String>, back: List<&2, String>, inq: Map<&2, U32>,
    running: Map<&2, U32>, dirty: Map<&2, U32>, gens: Map<&2, U32>, fails: Map<&2, U32>,
    nrun: U32, max: U32}

# A timer for the driver to start: wake key after ms with this generation.
type Timer is Data:
  Timer{key: String, gen: U32, ms: U32}

def Queue.new(+max: U32) -> Queue:
  Queue{Nil{}, Nil{}, Map.new(&2, U32), Map.new(&2, U32), Map.new(&2, U32), Map.new(&2, U32),
    Map.new(&2, U32), 0, max}

# Maps
# ----

def Mp.has.fin(r: Map<&2, U32> & Bool) -> Bool:
  match r:
    case (m, b):
      b

def Mp.has(+m: Map<&2, U32>, key: String) -> Bool:
  Mp.has.fin(Map.has(&2, U32, m, key))

def Mp.get.fin(r: Map<&2, U32> & U32) -> U32:
  match r:
    case (m, v):
      v

def Mp.get(+m: Map<&2, U32>, key: String) -> U32:
  Mp.get.fin(Map.get(U32, 0, m, key))

def Mp.on(m: Map<&2, U32>, key: String) -> Map<&2, U32>:
  Map.set(&2, U32, m, key, 1)

def Mp.off(m: Map<&2, U32>, key: String) -> Map<&2, U32>:
  Map.del(&2, U32, m, key)

def Mp.bump(+m: Map<&2, U32>, +key: String) -> Map<&2, U32>:
  Map.set(&2, U32, m, key, (Mp.get(m, key) + 1 : U32))

def Queue.add.go(f: List<&2, String>, b: List<&2, String>, inq: Map<&2, U32>,
  run: Map<&2, U32>, d: Map<&2, U32>, g: Map<&2, U32>, fl: Map<&2, U32>, n: U32, mx: U32,
  +key: String, running: Bool, waiting: Bool) -> Queue:
  match running waiting:
    case True{} _:
      Queue{f, b, inq, run, Mp.on(d, key), g, fl, n, mx}
    case False{} True{}:
      Queue{f, b, inq, run, d, g, fl, n, mx}
    case False{} False{}:
      Queue{f, key <> b, Mp.on(inq, key), run, d, g, fl, n, mx}

# Adding
# ------

# Queues key unless it waits already; a running key is marked dirty
# instead. Either way its pending timer, if any, goes stale.
def Queue.add(q: Queue, +key: String) -> Queue:
  match q:
    case Queue{f, b, +inq, +run, d, +g, fl, n, mx}:
      Queue.add.go(f, b, inq, run, d, Mp.bump(g, key), fl, n, mx, key, Mp.has(run, key),
        Mp.has(inq, key))

def Queue.add_all(ks: List<&2, String>, q: Queue) -> Queue:
  match ks:
    case Nil{}:
      q
    case Con{k, t}:
      Queue.add_all(t, Queue.add(q, k))

def Queue.pop.flip(f: List<&2, String>, i: Map<&2, U32>, r: Map<&2, U32>, d: Map<&2, U32>,
  g: Map<&2, U32>, fl: Map<&2, U32>, +n: U32, mx: U32) -> Queue & Maybe<&2, String>:
  match f:
    case Con{+k, t}:
      (Queue{t, Nil{}, Mp.off(i, k), Mp.on(r, k), d, g, fl, (n + 1 : U32), mx}, Some{k})
    case Nil{}:
      (Queue{Nil{}, Nil{}, i, r, d, g, fl, n, mx}, None{})

def Queue.pop.go(f: List<&2, String>, b: List<&2, String>, i: Map<&2, U32>, r: Map<&2, U32>,
  d: Map<&2, U32>, g: Map<&2, U32>, fl: Map<&2, U32>, +n: U32, mx: U32, free: Bool) ->
  Queue & Maybe<&2, String>:
  match f free:
    case Con{+k, t} True{}:
      (Queue{t, b, Mp.off(i, k), Mp.on(r, k), d, g, fl, (n + 1 : U32), mx}, Some{k})
    case Nil{} True{}:
      Queue.pop.flip(List.reverse(&2, String, b), i, r, d, g, fl, n, mx)
    case xs False{}:
      (Queue{xs, b, i, r, d, g, fl, n, mx}, None{})

# Taking
# ------

# The next waiting key, if a worker slot is free: it leaves the queue and
# starts running.
def Queue.pop(q: Queue) -> Queue & Maybe<&2, String>:
  match q:
    case Queue{f, b, i, r, d, g, fl, +n, +mx}:
      Queue.pop.go(f, b, i, r, d, g, fl, n, mx, U32.is_lt(n, mx))

def Queue.pop_all.q(r: Queue & Maybe<&2, String>) -> Queue:
  match r:
    case (q, m):
      q

def Queue.pop_all.acc(r: Queue & Maybe<&2, String>, acc: List<&2, String>) -> List<&2, String>:
  match r:
    case (q, Some{k}):
      k <> acc
    case (q, None{}):
      acc

# Every key that may start now, in queue order (fuel bounds the count).
def Queue.pop_all(fuel: Nat, +q: Queue, acc: List<&2, String>) -> Queue & List<&2, String>:
  match fuel:
    case 0n:
      (q, List.reverse(&2, String, acc))
    case 1n+p:
      Queue.pop_all(p, Queue.pop_all.q(Queue.pop(q)), Queue.pop_all.acc(Queue.pop(q), acc))

def Queue.backoff.go(+fails: U32, capped: Bool) -> U32:
  match capped:
    case True{}:
      1000000
    case False{}:
      U32.min((5 << U32.to_nat(fails) : U32), 1000000)

# Finishing
# ---------

# The delay after fails failures: 5ms doubling, at most 1000s.
def Queue.backoff(+fails: U32) -> U32:
  Queue.backoff.go(fails, U32.is_ge(fails, 18))

def Queue.done.fails(+fl: Map<&2, U32>, +key: String, a: Action) -> Map<&2, U32>:
  match a:
    case Retry{m}:
      Mp.bump(fl, key)
    case _:
      Mp.off(fl, key)

def Queue.done.dirty(q: Queue, +key: String, dirty: Bool) -> Queue:
  match dirty:
    case True{}:
      Queue.add(q, key)
    case False{}:
      q

# Starts a timer for key, staling any earlier one.
def Queue.arm(q: Queue, +key: String, ms: U32) -> Queue & List<&2, Timer>:
  match q:
    case Queue{f, b, i, r, d, +g, fl, n, mx}:
      (Queue{f, b, i, r, d, Mp.bump(g, key), fl, n, mx},
        [Timer{key, (Mp.get(g, key) + 1 : U32), ms}])

def Queue.done.timer(q: Queue, +key: String, a: Action, +fails: U32) -> Queue & List<&2, Timer>:
  match a:
    case Requeue{ms}:
      Queue.arm(q, key, ms)
    case AwaitChange{}:
      (q, Nil{})
    case Retry{m}:
      Queue.arm(q, key, Queue.backoff(fails))

def Queue.done.run(q: Queue, +key: String, +a: Action) -> Queue & List<&2, Timer>:
  match q:
    case Queue{f, b, i, r, +d, g, +fl, +n, mx}:
      Queue.done.timer(
        Queue.done.dirty(Queue{f, b, i, Mp.off(r, key), Mp.off(d, key), g,
          Queue.done.fails(fl, key, a), (n - 1 : U32), mx}, key, Mp.has(d, key)),
        key, a, Mp.get(fl, key))

def Queue.done.go(q: Queue, +key: String, +a: Action, running: Bool) -> Queue & List<&2, Timer>:
  match running:
    case True{}:
      Queue.done.run(q, key, a)
    case False{}:
      (q, Nil{})

# Observers
# ---------

def Queue.running(q: Queue, key: String) -> Bool:
  match q:
    case Queue{f, b, i, r, d, g, fl, n, mx}:
      Mp.has(r, key)

# A run of key ended with an action. The key stops running; a dirty key is
# queued again at once; the action may ask for a timer. A key that is not
# running changes nothing.
def Queue.done(+q: Queue, +key: String, +a: Action) -> Queue & List<&2, Timer>:
  Queue.done.go(q, key, a, Queue.running(q, key))

def Queue.wake.go(q: Queue, +key: String, current: Bool) -> Queue:
  match current:
    case True{}:
      Queue.add(q, key)
    case False{}:
      q

# A timer woke: the key is queued if the timer is still current.
def Queue.wake(q: Queue, +key: String, +gen: U32) -> Queue:
  match q:
    case Queue{f, b, i, r, d, +g, fl, n, mx}:
      Queue.wake.go(Queue{f, b, i, r, d, g, fl, n, mx}, key, U32.is_eq(Mp.get(g, key), gen))

def Queue.waiting(q: Queue, key: String) -> Bool:
  match q:
    case Queue{f, b, i, r, d, g, fl, n, mx}:
      Mp.has(i, key)

def Queue.nrun(q: Queue) -> U32:
  match q:
    case Queue{f, b, i, r, d, g, fl, n, mx}:
      n

# Forgetting
# ----------

def Queue.forget.go(q: Queue, +key: String, busy: Bool) -> Queue:
  match q busy:
    case x True{}:
      x
    case Queue{f, b, i, r, d, g, fl, n, mx} False{}:
      Queue{f, b, i, r, d, Mp.off(g, key), Mp.off(fl, key), n, mx}

# Drops what the queue remembers of a key whose object is gone (its timer
# generation and failures, as client-go's Forget does), so memory follows
# the live objects. A key still waiting or running keeps its state.
def Queue.forget(+q: Queue, +key: String) -> Queue:
  Queue.forget.go(q, key, Bool.or(Queue.running(q, key), Queue.waiting(q, key)))

def Queue.forget_all(ks: List<&2, String>, q: Queue) -> Queue:
  match ks:
    case Nil{}:
      q
    case Con{k, t}:
      Queue.forget_all(t, Queue.forget(q, k))
