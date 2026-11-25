#!/usr/bin/env python3
"""Checks what tests/fixtures/zip.bend stored, for tests/zip.sh.

  zip_check.py blocks SRC OFF LEN BLOCK DST AT FILL WORDS [--raw N] [--quick]
  zip_check.py pack SRC DST WORDS [--raw N]
  zip_check.py data OUT      the test data (one file; see data())
  zip_check.py corpus OUT MIB  files of /usr, one after another, for the speed check
  zip_check.py speed WORDS BYTES RUNS CMD...  CMD's best CPU time of RUNS, as MiB/s

WORDS is the fixture's output, "ok" and a word a block. Each block of
SRC must be stored in DST in order from AT: raw (bit 24) as it is, or as
an LZ4 block shorter than it. An LZ4 block is decoded here by decode(),
which refuses what the block format forbids, and by liblz4's
LZ4_decompress_safe where the library is installed (the decoder the
Linux kernel's lib/lz4 comes from). DST was FILL bytes of 0xA5 before:
nothing else in it may have changed. --raw N wants exactly N raw blocks;
--quick leaves decode() out when liblz4 is there (the speed check's
data). Prints "ok ..." and exits 0, or what is wrong and exits 1.
"""
import ctypes
import ctypes.util
import os
import random
import sys

RAW = 1 << 24


def lz4lib():
    names = [ctypes.util.find_library("lz4"), "liblz4.so.1", "/opt/homebrew/lib/liblz4.1.dylib",
             "/usr/local/lib/liblz4.1.dylib"]
    for name in names:
        if not name:
            continue
        try:
            lib = ctypes.CDLL(name)
            lib.LZ4_decompress_safe.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int, ctypes.c_int]
            lib.LZ4_compress_default.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int, ctypes.c_int]
            return lib
        except (OSError, AttributeError):
            pass
    return None


def decode(b, want):
    """An LZ4 block's bytes, or ValueError: the format, and its end rules."""
    out = bytearray()
    i, n = 0, len(b)
    last_match = None
    while True:
        if i >= n:
            raise ValueError("no token")
        tok = b[i]
        i += 1
        lit = tok >> 4
        if lit == 15:
            while True:
                if i >= n:
                    raise ValueError("literal count cut short")
                c = b[i]
                i += 1
                lit += c
                if c != 255:
                    break
        if i + lit > n:
            raise ValueError("literals cut short")
        out += b[i:i + lit]
        i += lit
        if i == n:
            if tok & 15:
                raise ValueError("the last sequence has a match length")
            if last_match is not None and lit < 5:
                raise ValueError("fewer than 5 literals at the end")
            break
        if i + 2 > n:
            raise ValueError("offset cut short")
        off = b[i] | b[i + 1] << 8
        i += 2
        if off == 0 or off > len(out):
            raise ValueError("offset %d at output %d" % (off, len(out)))
        ml = tok & 15
        if ml == 15:
            while True:
                if i >= n:
                    raise ValueError("match length cut short")
                c = b[i]
                i += 1
                ml += c
                if c != 255:
                    break
        ml += 4
        last_match = len(out)
        if off >= ml:
            out += out[len(out) - off:len(out) - off + ml]
        else:
            piece = bytes(out[len(out) - off:])
            out += (piece * (ml // off + 1))[:ml]
        if len(out) > want:
            raise ValueError("more than %d bytes" % want)
    if len(out) != want:
        raise ValueError("%d bytes, not %d" % (len(out), want))
    if last_match is not None and last_match > want - 12:
        raise ValueError("the last match starts %d bytes before the end" % (want - last_match))
    return bytes(out)


def check_block(lib, chunk, word, stored, quick, where):
    """One block; (is raw, liblz4's own stored size or None)."""
    size = word & (RAW - 1)
    if word >> 25 or size != len(stored):
        raise ValueError("%s: word %d" % (where, word))
    ref = None
    if lib is not None and chunk:
        buf = ctypes.create_string_buffer(len(chunk) + len(chunk) // 255 + 16)
        c = lib.LZ4_compress_default(chunk, buf, len(chunk), len(buf))
        ref = c if 0 < c < len(chunk) else len(chunk)
    if word & RAW:
        if stored != chunk:
            raise ValueError("%s: a raw block is not its bytes" % where)
        # raw is only for a block that does not shrink: on a block of
        # some size liblz4 may do a little better, never much
        if ref is not None and len(chunk) >= 4096 and ref < len(chunk) * 9 // 10:
            raise ValueError("%s: raw, but liblz4 stores it in %d of %d" % (where, ref, len(chunk)))
        return True, ref
    if size == 0 or size >= len(chunk):
        raise ValueError("%s: a compressed block of %d bytes for %d" % (where, size, len(chunk)))
    if lib is None or not quick:
        try:
            got = decode(stored, len(chunk))
        except ValueError as e:
            raise ValueError("%s: %s" % (where, e))
        if got != chunk:
            raise ValueError("%s: decodes to other bytes" % where)
    if lib is not None:
        buf = ctypes.create_string_buffer(len(chunk))
        r = lib.LZ4_decompress_safe(stored, buf, len(stored), len(chunk))
        if r != len(chunk) or buf.raw != chunk:
            raise ValueError("%s: LZ4_decompress_safe answers %d" % (where, r))
    return False, ref


def words_of(path):
    parts = open(path).read().split()
    if not parts or parts[0] != "ok":
        raise ValueError("the fixture said: " + " ".join(parts)[:200])
    return [int(p) for p in parts[1:]]


def summary(lib, blocks, raws, stored, total, refs, want_raw):
    if want_raw is not None and raws != want_raw:
        raise ValueError("%d raw blocks, wanted %d" % (raws, want_raw))
    s = "ok %d blocks, %d raw, %d of %d bytes" % (blocks, raws, stored, total)
    if lib is not None and total:
        s += " (liblz4: %d)" % refs
    else:
        s += " (no liblz4)" if lib is None else ""
    print(s)


def opts(rest):
    want_raw = int(rest[rest.index("--raw") + 1]) if "--raw" in rest else None
    return want_raw, "--quick" in rest


def blocks(args):
    src, off, length, block, dst, at, fill, wpath = args[:8]
    off, length, block, at, fill = int(off), int(length), int(block), int(at), int(fill)
    want_raw, quick = opts(args[8:])
    lib = lz4lib()
    words = words_of(wpath)
    if len(words) != (length + block - 1) // block:
        raise ValueError("%d words for %d blocks" % (len(words), (length + block - 1) // block))
    raws = stored = refs = 0
    with open(src, "rb") as f, open(dst, "rb") as g:
        f.seek(off)
        g.seek(at)
        left = length
        for k, word in enumerate(words):
            chunk = f.read(min(block, left))
            left -= len(chunk)
            data = g.read(word & (RAW - 1))
            raw, ref = check_block(lib, chunk, word, data, quick, "block %d" % k)
            raws += raw
            stored += len(data)
            refs += ref or 0
        size = os.fstat(g.fileno()).st_size
        if size != max(fill, at + stored):
            raise ValueError("the output is %d bytes, not %d" % (size, max(fill, at + stored)))
        # what was there before, around the blocks
        for a, b in ((0, min(at, fill)), (at + stored, fill)):
            g.seek(a)
            while a < b:
                piece = g.read(min(1 << 20, b - a))
                if piece != b"\xa5" * len(piece):
                    raise ValueError("bytes outside the blocks changed near %d" % a)
                a += len(piece)
    summary(lib, len(words), raws, stored, length, refs, want_raw)


def pack(args):
    src, dst, wpath = args[:3]
    want_raw, quick = opts(args[3:])
    lib = lz4lib()
    words = words_of(wpath)
    if len(words) != 1:
        raise ValueError("%d words for one block" % len(words))
    chunk = open(src, "rb").read()
    data = open(dst, "rb").read()
    raw, ref = check_block(lib, chunk, words[0], data, quick, "the block")
    summary(lib, 1, int(raw), len(data), len(chunk), ref or 0, want_raw)


# The test data, one file. tests/zip.sh names these ranges:
#   0        1200000 bytes of words: compresses
#   1200000  1000000 random bytes: does not
#   2200000  1048576 zeros: one match, a long length
#   3248576  65535 random bytes, twice: the second copy is 65535 back, the
#            farthest an offset reaches
#   3379646  65536 random bytes, twice: one byte too far
#   3510718  8192 bytes of "ab" at random: matches everywhere, so blocks
#            cut from it end in the middle of one
#   3518910  the end
def data(out):
    r = random.Random(7)
    w = ["layer", "tar", "usr", "bin", "lib", "etc", "share"]
    text = " ".join(r.choice(w) for _ in range(300000)).encode()[:1200000]
    near = r.randbytes(65535)
    far = r.randbytes(65536)
    ab = bytes(r.choice(b"ab") for _ in range(8192))
    with open(out, "wb") as f:
        f.write(text + r.randbytes(1000000) + bytes(1048576) + near + near + far + far + ab)


def corpus(out, mib):
    want = int(mib) << 20
    have = 0
    with open(out, "wb") as f:
        while have < want:
            before = have
            for top in ("/usr/bin", "/usr/lib", "/usr/share"):
                for d, dirs, names in os.walk(top):
                    dirs.sort()
                    for name in sorted(names):
                        p = os.path.join(d, name)
                        if have >= want:
                            break
                        if os.path.islink(p) or not os.path.isfile(p):
                            continue
                        try:
                            piece = open(p, "rb").read(want - have)
                        except OSError:
                            continue
                        f.write(piece)
                        have += len(piece)
            if have == before:
                raise ValueError("nothing to read under /usr")


# CMD (the fixture storing BYTES bytes) run RUNS times, its output in
# WORDS: the least CPU time (user and system, the whole process: reading,
# compressing, writing), and the wall time of that run.
def speed(args):
    import resource
    import subprocess
    import time
    wpath, size, runs, cmd = args[0], int(args[1]), int(args[2]), args[3:]
    best = None
    for _ in range(runs):
        before = resource.getrusage(resource.RUSAGE_CHILDREN)
        t = time.monotonic()
        with open(wpath, "w") as f:
            subprocess.run(cmd, stdout=f, check=True)
        wall = time.monotonic() - t
        after = resource.getrusage(resource.RUSAGE_CHILDREN)
        cpu = after.ru_utime + after.ru_stime - before.ru_utime - before.ru_stime
        if best is None or cpu < best[0]:
            best = (cpu, wall)
    mib = size / 1048576
    print("%d MiB in %.3f s of CPU (%.3f s wall): %d MiB/s" % (mib, best[0], best[1], mib / max(best[0], 0.001)))


def main():
    mode, args = sys.argv[1], sys.argv[2:]
    try:
        {"blocks": blocks, "pack": pack, "data": lambda a: data(*a), "corpus": lambda a: corpus(*a),
         "speed": speed}[mode](args)
    except ValueError as e:
        print("FAIL", e)
        sys.exit(1)


if __name__ == "__main__":
    main()
