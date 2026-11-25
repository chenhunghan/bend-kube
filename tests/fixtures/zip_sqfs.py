#!/usr/bin/env python3
"""A squashfs 4.0 image with lz4 blocks made by src/zip.bend, for tests/zip.sh.

  zip_sqfs.py ZIP SRC IMG TMP

ZIP is the built tests/fixtures/zip.bend. IMG becomes an image holding
one file, "data", with SRC's bytes: the data blocks come from Zip.blocks
and every metadata block (inodes, directory, ids) from Zip.pack; TMP is
a scratch file. squashfs-tools' unsquashfs then reads the file back
(tests/zip.sh), which checks the block words and the lz4 blocks the way
a squashfs reader meets them. Layout (Linux fs/squashfs/squashfs_fs.h):

  0    super block: compression 5 (lz4), flags NO_FRAG | NO_XATTR |
       COMP_OPT
  96   the compression options, a metadata block that is never
       compressed: le16 8 | 0x8000, le32 version 1 (LZ4_LEGACY), le32
       flags 0. Linux refuses an lz4 image without it
       (fs/squashfs/lz4_wrapper.c).
  106  the file's data blocks
       inode table, directory table, id table, each one metadata block:
       le16 stored length (| 0x8000 when stored raw), the stored bytes
       the id table's index: le64 start of its block
"""
import os
import struct
import subprocess
import sys

RAW = 1 << 24
BLOCK = 131072


def run(args):
    # the answer is what counts: a build with LeakSanitizer exits 1 over
    # the runtime's own argument array (tests/zip.sh checks the reports)
    out = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout.decode().split()
    if not out or out[0] != "ok":
        sys.exit("FAIL the fixture said: " + " ".join(out)[:200])
    return [int(w) for w in out[1:]]


def main():
    zip_, src, img, tmp = sys.argv[1:5]
    size = os.path.getsize(src)
    with open(img, "wb") as f:
        f.write(bytes(106))
    words = run([zip_, "5", src, "0", "0", "0", str(size), str(BLOCK), img, "0", "106"])
    stored = sum(w & (RAW - 1) for w in words)
    packed = []

    def meta(raw):
        with open(tmp, "wb") as f:
            f.write(raw)
        word = run([zip_, "5", tmp, tmp + ".out"])[0]
        body = open(tmp + ".out", "rb").read()
        os.remove(tmp + ".out")
        packed.append(not word & RAW)
        return struct.pack("<H", (word & (RAW - 1)) | (0x8000 if word & RAW else 0)) + body

    # inode 1: the file (squashfs_reg_inode); inode 2: the root
    # (squashfs_dir_inode), whose listing is one header and one entry
    name = b"data"
    listing = struct.pack("<III", 0, 0, 1) + struct.pack("<HhHH", 0, 0, 2, len(name) - 1) + name
    reg = struct.pack("<HHHHII", 2, 0o644, 0, 0, 0, 1) + struct.pack("<IIII", 106, 0xFFFFFFFF, 0, size)
    reg += b"".join(struct.pack("<I", w) for w in words)
    root = struct.pack("<HHHHII", 1, 0o755, 0, 0, 0, 2) + struct.pack("<IIHHI", 0, 2, len(listing) + 3, 0, 3)
    inodes = meta(reg + root)
    dirs = meta(listing)
    ids = meta(struct.pack("<I", 0))
    itab = 106 + stored
    dtab = itab + len(inodes)
    idblock = dtab + len(dirs)
    idtab = idblock + len(ids)
    end = idtab + 8
    none = 0xFFFFFFFFFFFFFFFF
    sb = struct.pack("<IIIIIHHHHHHQQQQQQQQ", 0x73717368, 2, 0, BLOCK, 0, 5, 17, 0x10 | 0x200 | 0x400, 1, 4, 0,
                     len(reg), end, idtab, none, itab, dtab, idblock, none)
    opts = struct.pack("<HII", 8 | 0x8000, 1, 0)
    with open(img, "r+b") as f:
        f.write(sb + opts)
        f.seek(itab)
        f.write(inodes + dirs + ids + struct.pack("<Q", idblock))
        f.write(bytes(-end % 4096))
    os.remove(tmp)
    print("ok %d data blocks, %d raw; metadata blocks compressed: %s" % (
        len(words), sum(1 for w in words if w & RAW), " ".join("yes" if p else "no" for p in packed)))


if __name__ == "__main__":
    main()
