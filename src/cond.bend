import Base
import ./json.bend as J
import ./core.bend as C

# Conditions
# ==========
#
# status.conditions as Kubernetes' API conventions define them, and as
# apimachinery's meta.SetStatusCondition keeps them: a list of objects,
# one per type, each with status ("True", "False" or "Unknown"), reason,
# message, observedGeneration and lastTransitionTime. Setting a condition
# replaces the one of the same type in place (or appends it); its
# lastTransitionTime changes only when its status does. Pure: a reconcile
# builds the list and writes it with Client.patch_status (a merge patch
# replaces the whole list; server-side apply merges by type when the CRD
# says x-kubernetes-list-type: map).

# The conditions an object's status carries.
def Cond.list(o: J.Json) -> List<&2, J.Json>:
  J.Json.items(J.Json.at(o, ["status", "conditions"]))

def Cond.type_of(c: J.Json) -> String:
  J.Json.str_or(J.Json.get(c, "type"), "")

def Cond.status_of(c: J.Json) -> String:
  J.Json.str_or(J.Json.get(c, "status"), "")

def Cond.get.go(+c: J.Json, +t: String, hit: Bool, rest: Maybe<&2, J.Json>) -> Maybe<&2, J.Json>:
  match hit:
    case True{}:
      Some{c}
    case False{}:
      rest

# The condition of a type, if present.
def Cond.get(cs: List<&2, J.Json>, +t: String) -> Maybe<&2, J.Json>:
  match cs:
    case Nil{}:
      None{}
    case Con{+c, rest}:
      Cond.get.go(c, t, String.eq(Cond.type_of(c), t), Cond.get(rest, t))

def Cond.is.go(m: Maybe<&2, J.Json>, +status: String) -> Bool:
  match m:
    case Some{c}:
      String.eq(Cond.status_of(c), status)
    case None{}:
      False{}

# Whether the condition of a type has this status ("True", "False").
def Cond.is(cs: List<&2, J.Json>, +t: String, +status: String) -> Bool:
  Cond.is.go(Cond.get(cs, t), status)

def Cond.is_true(cs: List<&2, J.Json>, +t: String) -> Bool:
  Cond.is(cs, t, "True")

def Cond.gen(+gen: String, none: Bool) -> J.Json:
  match none:
    case True{}:
      J.JNum{"0"}
    case False{}:
      J.JNum{gen}

# A condition; gen is metadata.generation as the object carries it (its
# number text, "" for none), now an RFC 3339 time (T.Wall.rfc3339).
def Cond.make(t: String, status: String, reason: String, message: String, +gen: String,
  now: String) -> J.Json:
  J.Json.obj([J.KV{"type", J.JStr{t}}, J.KV{"status", J.JStr{status}},
    J.KV{"observedGeneration", Cond.gen(gen, String.is_empty(gen))},
    J.KV{"lastTransitionTime", J.JStr{now}}, J.KV{"reason", J.JStr{reason}},
    J.KV{"message", J.JStr{message}}])

def Cond.keep.go(+old: J.Json, +new: J.Json, keep: Bool) -> J.Json:
  match keep:
    case True{}:
      J.Json.set(new, "lastTransitionTime", J.Json.get(old, "lastTransitionTime"))
    case False{}:
      new

# The new condition, keeping the old one's transition time when the status
# is unchanged.
def Cond.keep(+old: J.Json, +new: J.Json, same: Bool) -> J.Json:
  Cond.keep.go(old, new, Bool.and(same, Bool.not(J.Json.is_null(J.Json.get(old, "lastTransitionTime")))))

def Cond.set.put(+c: J.Json, +new: J.Json, hit: Bool, rest: List<&2, J.Json>, done: Bool) ->
  List<&2, J.Json> & Bool:
  match hit:
    case True{}:
      (Cond.keep(c, new, String.eq(Cond.status_of(c), Cond.status_of(new))) <> rest, True{})
    case False{}:
      (c <> rest, done)

def Cond.set.step(+c: J.Json, +new: J.Json, r: List<&2, J.Json> & Bool) -> List<&2, J.Json> & Bool:
  match r:
    case (rest, done):
      Cond.set.put(c, new, String.eq(Cond.type_of(c), Cond.type_of(new)), rest, done)

def Cond.set.go(cs: List<&2, J.Json>, +new: J.Json) -> List<&2, J.Json> & Bool:
  match cs:
    case Nil{}:
      (Nil{}, False{})
    case Con{+c, t}:
      Cond.set.step(c, new, Cond.set.go(t, new))

def Cond.set.fin(r: List<&2, J.Json> & Bool, +new: J.Json) -> List<&2, J.Json>:
  match r:
    case (cs, True{}):
      cs
    case (cs, False{}):
      List.append(&2, J.Json, cs, [new])

# Sets a condition (meta.SetStatusCondition): replaces the one of its
# type, keeping lastTransitionTime when the status is unchanged, or appends
# it.
def Cond.set(cs: List<&2, J.Json>, +new: J.Json) -> List<&2, J.Json>:
  Cond.set.fin(Cond.set.go(cs, new), new)

def Cond.del.put(+c: J.Json, +t: String, rest: List<&2, J.Json>, hit: Bool) -> List<&2, J.Json>:
  match hit:
    case True{}:
      rest
    case False{}:
      c <> rest

# Removes the condition of a type.
def Cond.del(cs: List<&2, J.Json>, +t: String) -> List<&2, J.Json>:
  match cs:
    case Nil{}:
      Nil{}
    case Con{+c, rest}:
      Cond.del.put(c, t, Cond.del(rest, t), String.eq(Cond.type_of(c), t))

# A status patch body setting conditions: {"status": {"conditions": cs}}.
def Cond.patch(cs: List<&2, J.Json>) -> J.Json:
  J.Json.obj([J.KV{"status", J.Json.obj([J.KV{"conditions", J.Json.arr(cs)}])}])
