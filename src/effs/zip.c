// Zip
// ===

// Block compression for file system images: LZ4's block format, written
// here so no library is needed. Portable C: every multi-byte read is a
// memcpy, nothing depends on the byte order (a match is found by
// comparing bytes, the hash only picks where to look), and no compiler
// builtin is used.
//
// The block format (lz4 doc/lz4_Block_format.md) is a run of sequences:
// a token (literal count << 4 | match length - 4, each 15 when more
// follows in bytes of 255, the last below 255), the literals, a 2-byte
// little-endian offset back (1 to 65535) and the match. A decoder may
// rely on how a block ends, and LZ4_decompress_safe (the Linux kernel's
// lib/lz4 too) does:
// - the last sequence is literals only, and holds at least the last 5
//   bytes of the block (ZIP_LAST);
// - the last match starts at least 12 bytes before the block's end
//   (ZIP_MFLIMIT), so a block under 13 bytes is literals only.

#include <fcntl.h>
#include <unistd.h>

#define ZIP_LZ4 5u
#define ZIP_RAW (1u << 24)
#define ZIP_BLOCK_MAX (1u << 20)
#define ZIP_HASH_LOG 12
#define ZIP_MFLIMIT 12
#define ZIP_LAST 5
// The most a block of n bytes can compress to: n literals, their count,
// a token.
#define ZIP_BOUND(n) ((size_t)(n) + (size_t)(n) / 255 + 16)

static __attribute__((unused)) uint32_t zip_r32(const unsigned char* p) {
  uint32_t v;
  memcpy(&v, p, 4);
  return v;
}

// Where the table keeps the 5 bytes at p: a place that shares 5 bytes is
// a better guess than one that shares 4, which is all a match needs. Read
// the same way whatever the byte order.
static __attribute__((unused)) uint32_t zip_hash(const unsigned char* p) {
  uint64_t v = ((uint64_t)p[0] << 32) | ((uint64_t)p[1] << 24) | ((uint64_t)p[2] << 16) | ((uint64_t)p[3] << 8) | p[4];
  return (uint32_t)(((v << 24) * 889523592379ull) >> (64 - ZIP_HASH_LOG));
}

// How many bytes at a and b are the same, a stopping at end; b is before a.
// Eight at a time; where the compiler can count zero bits and the bytes
// are little-endian, the first differing byte comes from the XOR, else
// byte by byte (ZIP_PORTABLE picks that everywhere, for the tests).
static __attribute__((unused)) size_t zip_same(const unsigned char* a, const unsigned char* b, const unsigned char* end) {
  const unsigned char* a0 = a;
  while (end - a >= 8) {
    uint64_t x, y;
    memcpy(&x, a, 8);
    memcpy(&y, b, 8);
    if (x != y) {
#if defined(__GNUC__) && defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__ && !defined(ZIP_PORTABLE)
      return (size_t)(a - a0) + ((size_t)__builtin_ctzll(x ^ y) >> 3);
#else
      break;
#endif
    }
    a += 8;
    b += 8;
  }
  while (a < end && *a == *b) {
    a += 1;
    b += 1;
  }
  return (size_t)(a - a0);
}

// A count past 14: bytes of 255 and a last one below 255.
static __attribute__((unused)) unsigned char* zip_count(unsigned char* op, size_t n) {
  for (; n >= 255; n -= 255) {
    *op++ = 255;
  }
  *op++ = (unsigned char)n;
  return op;
}

// A token and n literals from p; the token, for the match length. With
// wild, the copy runs 8 bytes at a time and may pass n by up to 7, on
// both sides: before a match there are 12 more bytes to read, and the
// output has ZIP_BOUND's room.
static __attribute__((unused)) unsigned char* zip_lits(unsigned char** opp, const unsigned char* p, size_t n, int wild) {
  unsigned char* op = *opp;
  unsigned char* token = op++;
  if (n >= 15) {
    *token = 15 << 4;
    op = zip_count(op, n - 15);
  } else {
    *token = (unsigned char)(n << 4);
  }
  if (wild) {
    for (size_t i = 0; i < n; i += 8) {
      memcpy(op + i, p + i, 8);
    }
  } else {
    memcpy(op, p, n);
  }
  *opp = op + n;
  return token;
}

// The n bytes at src (n at most ZIP_BLOCK_MAX) as one LZ4 block at dst,
// which has ZIP_BOUND(n) bytes; its length. Greedy, one hash table of the
// last place each 5 bytes were seen (tab, 1 << ZIP_HASH_LOG entries), and
// a step that grows while nothing matches, so bytes that do not compress
// cost little: LZ4_compress_default's method.
static __attribute__((unused)) size_t zip_lz4(const unsigned char* src, size_t n, unsigned char* dst, uint32_t* tab) {
  unsigned char* op = dst;
  size_t anchor = 0;
  if (n > ZIP_MFLIMIT) {
    const size_t mflimit = n - ZIP_MFLIMIT;
    const unsigned char* const mend = src + n - ZIP_LAST;
    size_t ip = 1;
    memset(tab, 0, sizeof(uint32_t) << ZIP_HASH_LOG);
    for (;;) {
      // the next place whose 4 bytes were seen at most 65535 bytes back;
      // a table entry is always before ip
      size_t ref = 0, tries = 1u << 6;
      int found = 0;
      while (ip <= mflimit) {
        uint32_t seq = zip_r32(src + ip);
        uint32_t h = zip_hash(src + ip);
        ref = tab[h];
        tab[h] = (uint32_t)ip;
        if (ip - ref <= 65535 && zip_r32(src + ref) == seq) {
          found = 1;
          break;
        }
        ip += tries++ >> 6;
      }
      if (!found) {
        break;
      }
      while (ip > anchor && ref > 0 && src[ip - 1] == src[ref - 1]) {
        ip -= 1;
        ref -= 1;
      }
      unsigned char* token = zip_lits(&op, src + anchor, ip - anchor, 1);
      for (;;) {
        size_t off = ip - ref;
        size_t more = zip_same(src + ip + 4, src + ref + 4, mend);
        *op++ = (unsigned char)(off & 255);
        *op++ = (unsigned char)(off >> 8);
        if (more >= 15) {
          *token |= 15;
          op = zip_count(op, more - 15);
        } else {
          *token |= (unsigned char)more;
        }
        ip += 4 + more;
        anchor = ip;
        if (ip > mflimit) {
          break;
        }
        tab[zip_hash(src + ip - 2)] = (uint32_t)(ip - 2);
        // a match right after a match has no literals
        uint32_t seq = zip_r32(src + ip);
        uint32_t h = zip_hash(src + ip);
        ref = tab[h];
        tab[h] = (uint32_t)ip;
        if (ip - ref > 65535 || zip_r32(src + ref) != seq) {
          break;
        }
        token = op++;
        *token = 0;
      }
      if (ip > mflimit) {
        break;
      }
      ip += 1;
    }
  }
  zip_lits(&op, src + anchor, n - anchor, 0);
  return (size_t)(op - dst);
}

// One block stored at out (ZIP_BOUND(n) bytes): compressed when that is
// shorter, else as it is. Its word.
static __attribute__((unused)) uint32_t zip_store(const unsigned char* in, size_t n, unsigned char* out, uint32_t* tab) {
  size_t c = zip_lz4(in, n, out, tab);
  if (c < n) {
    return (uint32_t)c;
  }
  memcpy(out, in, n);
  return (uint32_t)n | ZIP_RAW;
}

// Zip.blocks
// ----------

#ifdef CID(Zip.blocks)

typedef struct {
  int src, dst;
  u64 off, len, at;
  u32 block;
  u32* words;
  u64 count;
  u32 code;
  const char* why;
} ZipJob;

// About this many bytes are read, compressed and written at a time.
#define ZIP_BATCH (1u << 20)

static void zip_blocks_call(IoWork* w) {
  ZipJob* j = (ZipJob*)w->data;
  size_t block = j->block;
  size_t cap = (ZIP_BATCH / block) * block;
  u64 room = 0;
  u64 left = j->len;
  unsigned char* in = malloc(cap);
  unsigned char* out = malloc(cap + ZIP_BOUND(block));
  uint32_t* tab = malloc(sizeof(uint32_t) << ZIP_HASH_LOG);
  if (in == NULL || out == NULL || tab == NULL) {
    j->code = ENOMEM;
  }
  while (left > 0 && j->code == 0) {
    size_t want = left < cap ? (size_t)left : cap;
    size_t got = 0;
    while (got < want) {
      ssize_t k = pread(j->src, in + got, want - got, (off_t)(j->off + got));
      if (k < 0 && errno == EINTR) {
        continue;
      }
      if (k <= 0) {
        j->code = k < 0 ? (u32)errno : EIO;
        j->why = k < 0 ? "zip: reading the source failed" : "zip: the source ends inside the range";
        break;
      }
      got += (size_t)k;
    }
    if (j->code != 0) {
      break;
    }
    u64 blocks = (want + block - 1) / block;
    if (j->count + blocks > room) {
      room = (j->count + blocks) * 2;
      u32* p = realloc(j->words, (size_t)room * sizeof(u32));
      if (p == NULL) {
        j->code = ENOMEM;
        break;
      }
      j->words = p;
    }
    // each block is stored in at most its own length, so the batch fits
    size_t used = 0;
    for (size_t at = 0; at < want; at += block) {
      size_t n = want - at < block ? want - at : block;
      u32 word = zip_store(in + at, n, out + used, tab);
      j->words[j->count++] = word;
      used += word & (ZIP_RAW - 1);
    }
    for (size_t at = 0; at < used;) {
      ssize_t k = pwrite(j->dst, out + at, used - at, (off_t)(j->at + at));
      if (k < 0 && errno == EINTR) {
        continue;
      }
      if (k <= 0) {
        j->code = k < 0 ? (u32)errno : EIO;
        j->why = "zip: writing the blocks failed";
        break;
      }
      at += (size_t)k;
    }
    j->off += want;
    j->at += used;
    left -= want;
  }
  free(in);
  free(out);
  free(tab);
}

static Term zip_blocks_pack(Env e, IoWork* w) {
  ZipJob* j = (ZipJob*)w->data;
  Term r;
  if (j->code != 0) {
    r = io_fail(e, j->code, j->why);
  } else {
    Term xs = term_pak(CID(Nil), 0);
    for (u64 i = j->count; i > 0; i -= 1) {
      xs = io_node(e, CID(Con), (Term)j->words[i - 1], xs);
    }
    r = io_done(e, xs);
  }
  Term out = io_tup(e, io_hand(j->src), io_tup(e, io_hand(j->dst), r));
  free(j->words);
  free(j);
  return out;
}

// Zip.blocks(kind, src, off_hi, off_lo, len_hi, len_lo, block, dst, at_hi,
// at_lo): that range of src stored block by block at that offset of dst,
// on a helper thread; each block's word.
Term zip_blocks_run(Env e, Term* f, IoWork* w) {
  ZipJob* j = io_mem(calloc(1, sizeof *j));
  w->data = (char*)j;
  j->src = (int)io_hand_v(f[1]);
  j->off = ((u64)(u32)f[2] << 32) | (u64)(u32)f[3];
  j->len = ((u64)(u32)f[4] << 32) | (u64)(u32)f[5];
  j->block = (u32)f[6];
  j->dst = (int)io_hand_v(f[7]);
  j->at = ((u64)(u32)f[8] << 32) | (u64)(u32)f[9];
  if ((u32)f[0] != ZIP_LZ4) {
    j->code = ENOTSUP;
    j->why = "zip: no such compressor (Zip.lz4)";
  } else if (j->block == 0 || j->block > ZIP_BLOCK_MAX) {
    j->code = EINVAL;
    j->why = "zip: a block is from 1 to 1048576 bytes";
  } else if ((int64_t)j->off < 0 || (int64_t)j->len < 0 || (int64_t)j->at < 0 ||
             (int64_t)(j->off + j->len) < 0 || (int64_t)(j->at + j->len) < 0) {
    j->code = EINVAL;
    j->why = "zip: the range passes 2^63";
  }
  if (j->code != 0) {
    return zip_blocks_pack(e, w);
  }
  return io_work(w, zip_blocks_call, zip_blocks_pack);
}

static void __attribute__((constructor)) zip_blocks_use(void) {
  io_eff(CID(Zip.blocks), zip_blocks_run);
}

#endif

// Zip.pack
// --------

#ifdef CID(Zip.pack)

// Zip.pack(kind, bytes): one block from memory; its word and its stored
// bytes.
Term zip_pack_run(Env e, Term* f, IoWork* w) {
  if ((u32)f[0] != ZIP_LZ4) {
    return io_fail(e, ENOTSUP, "zip: no such compressor (Zip.lz4)");
  }
  u64 n = 0;
  for (Term x = f[1]; term_aux(x) == CID(Con); n += 1) {
    u64 l = term_peek(e.mem, x);
    if (e.mem[l] > 255) {
      return io_fail(e, EINVAL, "zip: a byte past 255");
    }
    if (n == ZIP_BLOCK_MAX) {
      return io_fail(e, EINVAL, "zip: a block is at most 1048576 bytes");
    }
    x = e.mem[l + 1];
  }
  unsigned char* in = (unsigned char*)io_cbuf(e, f[1], &n, CID(Con));
  unsigned char* out = malloc(ZIP_BOUND(n));
  uint32_t* tab = malloc(sizeof(uint32_t) << ZIP_HASH_LOG);
  if (out == NULL || tab == NULL) {
    free(in);
    free(out);
    free(tab);
    return io_fail(e, ENOMEM, NULL);
  }
  u32 word = zip_store(in, (size_t)n, out, tab);
  Term r = io_done(e, io_tup(e, (Term)word, io_list(e, (const char*)out, (u64)(word & (ZIP_RAW - 1)))));
  free(in);
  free(out);
  free(tab);
  return r;
}

static void __attribute__((constructor)) zip_pack_use(void) {
  io_eff(CID(Zip.pack), zip_pack_run);
}

#endif
