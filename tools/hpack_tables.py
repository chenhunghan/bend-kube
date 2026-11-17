#!/usr/bin/env python3
"""Prints src/hpack.bend's tables from RFC 7541's text: the static table
(Appendix A) and the canonical Huffman code (Appendix B).

    curl -sO https://www.rfc-editor.org/rfc/rfc7541.txt
    python3 tools/hpack_tables.py rfc7541.txt
"""
import re
import sys

t = open(sys.argv[1]).read()
a = t[t.index("Appendix A.  Static Table Definition"):t.index("Appendix B.  Huffman Code")]
b = t[t.index("Appendix B.  Huffman Code"):t.index("Appendix C.  Examples")]

static = []
for m in re.finditer(r"^\s*\| (\d+) +\| (\S+) +\| ?([^|]*?) *\|$", a, re.M):
    static.append((int(m.group(1)), m.group(2), m.group(3)))
assert [i for i, _, _ in static] == list(range(1, 62)), static

codes = {}
for m in re.finditer(r"\(\s*(\d+)\)\s+\|([01|]+)\s+([0-9a-f]+)\s+\[\s*(\d+)\]", b):
    sym, bits, hx, ln = int(m.group(1)), m.group(2).replace("|", ""), int(m.group(3), 16), int(m.group(4))
    assert len(bits) == ln and int(bits, 2) == hx
    codes[sym] = (hx, ln)
assert sorted(codes) == list(range(257))

# The code is canonical: by length, then symbol, each code one more than
# the last, shifted left when the length grows.
order = sorted(codes, key=lambda s: (codes[s][1], s))
code, prev = 0, codes[order[0]][1]
for i, s in enumerate(order):
    l = codes[s][1]
    if i:
        code = (code + 1) << (l - prev)
    prev = l
    assert code == codes[s][0], s
first, count, offset = {}, {}, {}
for i, s in enumerate(order):
    hx, l = codes[s]
    if l not in first:
        first[l], offset[l], count[l] = hx, i, 0
    count[l] += 1

out = []
w = out.append
w("# Tables")
w("# ------")
w("#")
w("# Generated from RFC 7541 by tools/hpack_tables.py: do not edit by hand.")
w("")
w("# The static table (Appendix A), index 1 first.")
w("def Hp.statics() -> List<&2, H.Header>:")
w("  [" + ",\n    ".join('H.Header{"%s", "%s"}' % (n, v) for _, n, v in static) + "]")
w("")
w("# Each symbol's Huffman code and its length in bits (Appendix B).")
w("def Hp.code(s: U32) -> HCode:")
w("  match s:")
for s in range(256):
    hx, l = codes[s]
    w("    case %d:\n      HCode{%d, %d}" % (s, hx, l))
w("    case _:\n      HCode{%d, %d}" % codes[256])
w("")
w("# The symbols in canonical order: by code length, then by symbol.")
w("def Hp.sym(i: U32) -> U32:")
w("  match i:")
for i, s in enumerate(order[:-1]):
    w("    case %d:\n      %d" % (i, s))
w("    case _:\n      %d" % order[-1])
w("")
w("# For each code length: its first code, how many codes have it, and the")
w("# first's place in Hp.sym's order.")
w("def Hp.len(l: U32) -> HLen:")
w("  match l:")
for l in sorted(first):
    w("    case %d:\n      HLen{%d, %d, %d}" % (l, first[l], count[l], offset[l]))
w("    case _:\n      HLen{0, 0, 0}")
print("\n".join(out))
