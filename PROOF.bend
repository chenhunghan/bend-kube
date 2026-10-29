import Base
import ./LAWS.bend as Laws
import ./src/queue.bend as Q

# PROOF
# =====
#
# A proof of every law in LAWS.bend. `bend PROOF.bend` must print
# ALL PROOFS CHECK before a commit.

def Laws.watch_gone_relists(rv, f, first, r, m):
  {==}

def Laws.watch_request_gone_relists(rv, f, first):
  {==}

def Laws.list_gone_relists(c, f, first):
  {==}

def Laws.watch_error_backs_off(rv, f, first):
  {==}

def Laws.watch_end_resumes(rv, f, first):
  {==}

def Laws.bookmark_advances(rv, v, f, first):
  {==}

def Laws.last_page_watches(c, f, first, items, rv):
  {==}

def Laws.first_page_inits(items):
  {==}

def Laws.watch_backoff_capped():
  {==}

def Laws.init_clears_buffer(objs, buf, r):
  {==}

def Laws.init_done_swaps(objs, buf, r):
  {==}

def Laws.retry_backoff_capped():
  {==}

# The hypothesis rewrites the running test to True; the rest computes.
def Laws.add_running_marks_dirty(f, b, inq, run, d, g, fl, n, mx, key, running):
  %Equal.sym(Bool, Q.Mp.has(run, key), True{}, running) :
    {Q.Queue.add.go(f, b, inq, run, d, Q.Mp.bump(g, key), fl, n, mx, key, _, Q.Mp.has(inq, key))
      == Q.Queue{f, b, inq, run, Q.Mp.on(d, key), Q.Mp.bump(g, key), fl, n, mx} : Q.Queue}
  {==}

def Laws.add_waiting_dedups(f, b, inq, run, d, g, fl, n, mx, key, idle, waiting):
  %Equal.sym(Bool, Q.Mp.has(run, key), False{}, idle) :
    {Q.Queue.add.go(f, b, inq, run, d, Q.Mp.bump(g, key), fl, n, mx, key, _, Q.Mp.has(inq, key))
      == Q.Queue{f, b, inq, run, d, Q.Mp.bump(g, key), fl, n, mx} : Q.Queue}
  %Equal.sym(Bool, Q.Mp.has(inq, key), True{}, waiting) :
    {Q.Queue.add.go(f, b, inq, run, d, Q.Mp.bump(g, key), fl, n, mx, key, False{}, _)
      == Q.Queue{f, b, inq, run, d, Q.Mp.bump(g, key), fl, n, mx} : Q.Queue}
  {==}

# With no free slot, pop.go answers None whatever the front holds.
def Proof.pop_full(f: List<&2, String>, b: List<&2, String>, inq: Map<&2, U32>,
  run: Map<&2, U32>, d: Map<&2, U32>, g: Map<&2, U32>, fl: Map<&2, U32>, n: U32, mx: U32) ->
  {Q.Queue.pop.go(f, b, inq, run, d, g, fl, n, mx, False{})
    == (Q.Queue{f, b, inq, run, d, g, fl, n, mx}, None{}) : Q.Queue & Maybe<&2, String>}:
  match f:
    case Nil{}:
      {==}
    case Con{h, t}:
      {==}

def Laws.pop_respects_limit(f, b, inq, run, d, g, fl, n, mx, full):
  %Equal.sym(Bool, U32.is_lt(n, mx), False{}, full) :
    {Q.Queue.pop.go(f, b, inq, run, d, g, fl, n, mx, _)
      == (Q.Queue{f, b, inq, run, d, g, fl, n, mx}, None{}) : Q.Queue & Maybe<&2, String>}
  Proof.pop_full(f, b, inq, run, d, g, fl, n, mx)

def Laws.done_idle_noop(q, key, a, idle):
  %Equal.sym(Bool, Q.Queue.running(q, key), False{}, idle) :
    {Q.Queue.done.go(q, key, a, _) == (q, Nil{}) : Q.Queue & List<&2, Q.Timer>}
  {==}

# A busy key leaves any queue as it is.
def Proof.forget_busy(q: Q.Queue, key: String) -> {Q.Queue.forget.go(q, key, True{}) == q : Q.Queue}:
  match q:
    case Q.Queue{f, b, i, r, d, g, fl, n, mx}:
      {==}

def Laws.forget_running_keeps(q, key, running):
  %Equal.sym(Bool, Q.Queue.running(q, key), True{}, running) :
    {Q.Queue.forget.go(q, key, Bool.or(_, Q.Queue.waiting(q, key))) == q : Q.Queue}
  Proof.forget_busy(q, key)

def Laws.fin_live_applies(fs, name, i):
  {==}

def Laws.fin_gone_done(fs, name):
  {==}

def Laws.fin_cleanup_tests(fs, name, i):
  {==}

def Laws.eof_before_response_is_lost(t, h, o):
  {==}

def Laws.eof_mid_response_is_broken(b, bs, t, h, o):
  {==}

def Laws.proxy_skips_localhost(url, no, port):
  {==}

def Laws.proxy_skips_loopback(url, no, port):
  {==}

def Laws.no_proxy_star_bypasses(url, port):
  {==}

def Laws.no_proxy_url_is_direct(port):
  {==}

def Laws.unsupported_proxy_fails(port):
  {==}

def Laws.no_proxy_dot_is_subdomains_only():
  {==}

def Laws.no_proxy_respects_labels():
  {==}

def Laws.no_proxy_port_narrows():
  {==}

def Laws.tunnel_needs_200():
  {==}

def Laws.tunnel_rejects_early_bytes(b, bs):
  {==}

def Laws.tunnel_end_before_answer(h):
  {==}
