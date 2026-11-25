import Base

# Zip
# ===
#
# Block compression for file system images (effs/zip.c), beside Unz: data
# cut into blocks, each block compressed on its own, a block that does
# not shrink stored as it is. That is how squashfs stores a file's data
# and its tables, and what its writer needs back is one word a block.
#
# The compressor is LZ4's block format (the raw block squashfs's lz4
# stores: no frame, no checksum), written here in portable C: no library
# is loaded, so it is there on every host. Native lane only. A block
# decodes with LZ4_decompress_safe, the Linux kernel's included.
#
# A word says how one block was stored: its stored length in bytes, and
# bit 24 (Zip.raw()) set when those bytes are the block itself, not
# compressed. A compressed block is always shorter than the block it
# holds, and never empty. This is squashfs's data block size word
# (SQUASHFS_COMPRESSED_BIT_BLOCK) as it is.
#
#   (src, (dst, r)) <- Zip.blocks(Zip.lz4(), src, off_hi, off_lo,
#                                 len_hi, len_lo, block, dst, at_hi, at_lo)
#
# reads len bytes of src from offset off, block bytes at a time (the last
# block is what is left), and writes each block's stored bytes into dst
# from offset at, one after another with nothing between them; r is the
# blocks' words in order, so dst grew by the sum of their lengths. No
# bytes (len 0) is no block and no write. Offsets and len are 64-bit, as
# (high, low) halves; block is from 1 to 1048576 (squashfs's largest).
# Neither file's position moves (pread, pwrite), and the work runs on a
# helper thread. src ending inside the range fails with EIO; a failure
# may leave some blocks written, and dst is not synced.
#
#   (word, stored) <- Zip.pack(Zip.lz4(), bytes)
#
# is one block from memory, at most 1048576 bytes (a metadata block, a
# fragment): its word and its stored bytes, which are bytes themselves
# when the word has Zip.raw(). No bytes answer (Zip.raw(), []).

# The compressor's name, as squashfs's super block names it
# (LZ4_COMPRESSION).
def Zip.lz4() -> U32:
  5

# A word's bit for "stored as it is" (1 << 24).
def Zip.raw() -> U32:
  16777216

def Zip.blocks(kind: U32, src: File, off_hi: U32, off_lo: U32, len_hi: U32, len_lo: U32, block: U32, dst: File, at_hi: U32, at_lo: U32) ->
  IO(File & (File & Result<&1, &1, U32 & String, List<&2, U32>>)):
  import "./effs/zip.c"
  import "./effs/zip.js"

def Zip.pack(kind: U32, bytes: List<&2, U32>) -> IO(Result<&1, &1, U32 & String, U32 & List<&2, U32>>):
  import "./effs/zip.c"
  import "./effs/zip.js"
