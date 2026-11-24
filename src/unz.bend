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
#
# Output can go straight to a file instead, so it never becomes a Bend
# list (a layer's payload at the libraries' speed):
#
#   id <- Unz.open(Unz.gzip())
#   Unz.sink(id, path)              creates (0644) or truncates the file
#   n <- Unz.write(id, chunk, max)  for each chunk: how many bytes it wrote
#   Unz.close(id)                   fsyncs and closes the file too
#
# or a whole compressed file at once, on a helper thread:
#
#   (hi, lo) <- Unz.file(Unz.gzip(), src, dst, max_mib)
#
# which writes dst (0644), fsyncs it and answers its size in two 32-bit
# halves; past max_mib MiB of output (0: no limit), bad data, or input
# that ends early fails and removes dst.
#
#   ((hi, lo), hex) <- Unz.file_sha256(Unz.gzip(), src, dst, max_mib)
#
# is Unz.file that also hashes the bytes as it writes them: hex is the
# SHA-256 of dst's contents, 64 lowercase digits (a layer's diffID, with
# no second read of the tar). The hash is computed here, in C, so it
# needs no OpenSSL. A failure removes dst and answers no digest.

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

def Unz.sink(id: U32, path: String) -> IO(Result<&1, &1, U32 & String, Unit>):
  import "./effs/unz.c"
  import "./effs/unz.js"

def Unz.write(id: U32, bytes: List<&2, U32>, max: U32) -> IO(Result<&1, &1, U32 & String, U32>):
  import "./effs/unz.c"
  import "./effs/unz.js"

def Unz.file(kind: U32, src: String, dst: String, max_mib: U32) -> IO(Result<&1, &1, U32 & String, U32 & U32>):
  import "./effs/unz.c"
  import "./effs/unz.js"

def Unz.file_sha256(kind: U32, src: String, dst: String, max_mib: U32) -> IO(Result<&1, &1, U32 & String, (U32 & U32) & String>):
  import "./effs/unz.c"
  import "./effs/unz.js"
