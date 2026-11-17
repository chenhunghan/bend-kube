import Base

# Unz
# ===
#
# Fast streaming decompression for image layers (effs/unz.c): gzip through
# zlib, zstd through libzstd, each loaded with dlopen when first used (set
# UNZ_ZLIB or UNZ_ZSTD to a library's path to choose it). gzip.bend is the
# pure-Bend gzip decoder, on every lane but about 5 MB/s; this runs at the
# libraries' speed, on the native lane only.
#
#   id <- Unz.open(Unz.gzip())      (or Unz.zstd())
#   out <- Unz.feed(id, chunk, max) for each chunk of the layer
#   Unz.close(id)                   Fail if the stream ended early
#
# Members (gzip) and frames (zstd) one after another are one stream. A
# feed whose output passes max bytes fails, so a small input cannot
# expand without bound. A decoder must be closed, even after a failure.

def Unz.gzip() -> U32:
  0

def Unz.zstd() -> U32:
  1

def Unz.open(kind: U32) -> IO(Result<&1, &1, U32 & String, U32>):
  import "./effs/unz.c"
  import "./effs/unz.js"

def Unz.feed(id: U32, bytes: List<&2, U32>, max: U32) -> IO(Result<&1, &1, U32 & String, List<&2, U32>>):
  import "./effs/unz.c"
  import "./effs/unz.js"

def Unz.close(id: U32) -> IO(Result<&1, &1, U32 & String, Unit>):
  import "./effs/unz.c"
  import "./effs/unz.js"
