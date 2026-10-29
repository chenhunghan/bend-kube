import Base

# Time
# ====
#
# Unix time to RFC 3339 in UTC, as Kubernetes writes MicroTime
# ("2026-10-29T14:30:00.123456Z") and Time ("2026-10-29T14:30:00Z").
# Dates use Howard Hinnant's civil_from_days. A Wall counts days and the
# second within the day separately, so it is valid for millions of years;
# the plain-seconds forms (Time.rfc3339) end in 2106.

type Civil is Data:
  Civil{year: U32, month: U32, day: U32}

def Time.civil.month.go(+mp: U32, low: Bool) -> U32:
  match low:
    case True{}:
      (mp + 3 : U32)
    case False{}:
      (mp - 9 : U32)

def Time.civil.month(+mp: U32) -> U32:
  Time.civil.month.go(mp, U32.is_lt(mp, 10))

def Time.civil.year.go(+y: U32, early: Bool) -> U32:
  match early:
    case True{}:
      (y + 1 : U32)
    case False{}:
      y

def Time.civil.year(+y: U32, +m: U32) -> U32:
  Time.civil.year.go(y, U32.is_le(m, 2))

def Time.civil.fin(+y: U32, +doy: U32, +mp: U32) -> Civil:
  Civil{Time.civil.year(y, Time.civil.month(mp)), Time.civil.month(mp),
    (doy - (153 * mp + 2) / 5 + 1 : U32)}

def Time.civil.doy(+y: U32, +doy: U32) -> Civil:
  Time.civil.fin(y, doy, ((5 * doy + 2) / 153 : U32))

def Time.civil.yoe(+era: U32, +doe: U32, +yoe: U32) -> Civil:
  Time.civil.doy((yoe + era * 400 : U32), (doe - (365 * yoe + yoe / 4 - yoe / 100) : U32))

def Time.civil.doe(+era: U32, +doe: U32) -> Civil:
  Time.civil.yoe(era, doe, ((doe - doe / 1460 + doe / 36524 - doe / 146096) / 365 : U32))

def Time.civil.era(+z: U32) -> Civil:
  Time.civil.doe((z / 146097 : U32), (z - (z / 146097) * 146097 : U32))

# The date of a count of days since 1970-01-01.
def Time.civil(+days: U32) -> Civil:
  Time.civil.era((days + 719468 : U32))

def Time.pad.go(+s: String, width: Nat) -> String:
  String.repeat("0", Nat.sub(width, String.length(s))) ++ s

# n in at least width digits, zero-padded.
def Time.pad(+n: U32, width: Nat) -> String:
  Time.pad.go(U32.show(n), width)

def Time.date(c: Civil) -> String:
  match c:
    case Civil{y, m, d}:
      Time.pad(y, 4n) ++ "-" ++ Time.pad(m, 2n) ++ "-" ++ Time.pad(d, 2n)

def Time.clock(+secs: U32) -> String:
  Time.pad((secs / 3600 : U32), 2n) ++ ":" ++ Time.pad(((secs / 60) % 60 : U32), 2n) ++ ":"
    ++ Time.pad((secs % 60 : U32), 2n)

# "YYYY-MM-DDTHH:MM:SS"
def Time.stamp(+secs: U32) -> String:
  Time.date(Time.civil((secs / 86400 : U32))) ++ "T" ++ Time.clock((secs % 86400 : U32))

# metav1.Time: second precision.
def Time.rfc3339(+secs: U32) -> String:
  Time.stamp(secs) ++ "Z"

# metav1.MicroTime: microsecond precision.
def Time.rfc3339_micro(+secs: U32, +usecs: U32) -> String:
  Time.stamp(secs) ++ "." ++ Time.pad(usecs, 6n) ++ "Z"

# A wall-clock reading (sys.bend's Sys.wall).
type Wall is Data:
  Wall{days: U32, secs: U32, usecs: U32}

def Wall.of(w: U32 & (U32 & U32)) -> Wall:
  match w:
    case (d, (s, us)):
      Wall{d, s, us}

# "YYYY-MM-DDTHH:MM:SS.ffffffZ" (metav1.MicroTime).
def Wall.micro(w: Wall) -> String:
  match w:
    case Wall{d, +s, +us}:
      Time.date(Time.civil(d)) ++ "T" ++ Time.clock(s) ++ "." ++ Time.pad(us, 6n) ++ "Z"

# "YYYY-MM-DDTHH:MM:SSZ" (metav1.Time).
def Wall.rfc3339(w: Wall) -> String:
  match w:
    case Wall{d, +s, us}:
      Time.date(Time.civil(d)) ++ "T" ++ Time.clock(s) ++ "Z"

# Milliseconds, modulo 2^32: only for differences under 49 days, which
# wrap correctly in U32 subtraction.
def Wall.ms(w: Wall) -> U32:
  match w:
    case Wall{+d, +s, +us}:
      ((d * 86400 + s) * 1000 + us / 1000 : U32)

# A decimal stamp unique to the microsecond, for names.
def Wall.id(w: Wall) -> String:
  match w:
    case Wall{d, +s, +us}:
      U32.show(d) ++ Time.pad(s, 5n) ++ Time.pad(us, 6n)

# Parsing
# -------

# Days since 1970-01-01 of a civil date (Howard Hinnant's days_from_civil),
# for years from 1970.
def Time.days.go(+y: U32, +m: U32, +d: U32, +mp: U32) -> U32:
  ((y / 400) * 146097 + (y % 400) * 365 + (y % 400) / 4 - (y % 400) / 100 +
    (153 * mp + 2) / 5 + d - 1 - 719468 : U32)

def Time.days.early(+y: U32, +m: U32, +d: U32, early: Bool) -> U32:
  match early:
    case True{}:
      Time.days.go((y - 1 : U32), m, d, (m + 9 : U32))
    case False{}:
      Time.days.go(y, m, d, (m - 3 : U32))

def Time.days(+y: U32, +m: U32, +d: U32) -> U32:
  Time.days.early(y, m, d, U32.is_le(m, 2))

def Time.sub(s: String, i: Nat, n: Nat) -> String:
  String.take(String.drop(s, i), n)

def Time.parse.go(y: Maybe<&2, U32>, mo: Maybe<&2, U32>, d: Maybe<&2, U32>, h: Maybe<&2, U32>,
  mi: Maybe<&2, U32>, se: Maybe<&2, U32>, ok: Bool) -> Maybe<&2, U32>:
  match y mo d h mi se ok:
    case Some{+y1} Some{+mo1} Some{+d1} Some{h1} Some{mi1} Some{se1} True{}:
      Some{(Time.days(y1, mo1, d1) * 86400 + h1 * 3600 + mi1 * 60 + se1 : U32)}
    case _ _ _ _ _ _ _:
      None{}

def Time.parse.seps(+s: String) -> Bool:
  Bool.and(Bool.and(String.eq(Time.sub(s, 4n, 1n), "-"), String.eq(Time.sub(s, 7n, 1n), "-")),
    Bool.and(Bool.and(String.eq(Time.sub(s, 10n, 1n), "T"), String.eq(Time.sub(s, 13n, 1n), ":")),
      Bool.and(String.eq(Time.sub(s, 16n, 1n), ":"), String.ends_with(s, "Z"))))

# Seconds since the epoch of "YYYY-MM-DDTHH:MM:SS[.fff]Z" (metav1.Time and
# MicroTime; the fraction is dropped), or None.
def Time.parse(+s: String) -> Maybe<&2, U32>:
  Time.parse.go(U32.read(Time.sub(s, 0n, 4n)), U32.read(Time.sub(s, 5n, 2n)),
    U32.read(Time.sub(s, 8n, 2n)), U32.read(Time.sub(s, 11n, 2n)), U32.read(Time.sub(s, 14n, 2n)),
    U32.read(Time.sub(s, 17n, 2n)), Time.parse.seps(s))

# Seconds since the epoch of a wall-clock reading.
def Wall.secs(w: Wall) -> U32:
  match w:
    case Wall{d, s, us}:
      (d * 86400 + s : U32)
