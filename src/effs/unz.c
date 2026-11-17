// Unz
// ===

// Streaming decompression for gzip (and zlib) through zlib, and zstd
// through libzstd, both loaded with dlopen as tls.c loads OpenSSL: a
// program that never decompresses never needs either. UNZ_ZLIB and
// UNZ_ZSTD name a library to load instead. A decoder is a slot in a
// table, named by its index, since Bend has no user handle types.

#include <dlfcn.h>

typedef struct {
  const unsigned char* next_in;
  unsigned avail_in;
  unsigned long total_in;
  unsigned char* next_out;
  unsigned avail_out;
  unsigned long total_out;
  const char* msg;
  void* state;
  void* zalloc;
  void* zfree;
  void* opaque;
  int data_type;
  unsigned long adler;
  unsigned long reserved;
} UnzZ;

typedef struct { const void* src; size_t size; size_t pos; } UnzIn;
typedef struct { void* dst; size_t size; size_t pos; } UnzOut;

static struct {
  int z_tried, zs_tried;
  void* z;
  void* zs;
  const char* (*zlibVersion)(void);
  int (*inflateInit2_)(UnzZ*, int, const char*, int);
  int (*inflate)(UnzZ*, int);
  int (*inflateReset)(UnzZ*);
  int (*inflateEnd)(UnzZ*);
  void* (*ZSTD_createDStream)(void);
  size_t (*ZSTD_initDStream)(void*);
  size_t (*ZSTD_decompressStream)(void*, UnzOut*, UnzIn*);
  unsigned (*ZSTD_isError)(size_t);
  const char* (*ZSTD_getErrorName)(size_t);
  size_t (*ZSTD_freeDStream)(void*);
} unz_lib;

static void* unz_open_lib(const char* env, const char* const* names) {
  const char* own = getenv(env);
  if (own != NULL && *own != 0) {
    return dlopen(own, RTLD_NOW | RTLD_LOCAL);
  }
  for (u32 i = 0; names[i] != NULL; i += 1) {
    void* h = dlopen(names[i], RTLD_NOW | RTLD_LOCAL);
    if (h != NULL) {
      return h;
    }
  }
  return NULL;
}

#define UNZ_SYM(h, name) ((*(void**)&unz_lib.name = dlsym(h, #name)) != NULL)

static int unz_load_zlib(void) {
  if (!unz_lib.z_tried) {
    static const char* const names[] = {
      "libz.so.1", "libz.so", "libz.1.dylib", "/usr/lib/libz.1.dylib", NULL
    };
    unz_lib.z_tried = 1;
    void* h = unz_open_lib("UNZ_ZLIB", names);
    if (h != NULL && UNZ_SYM(h, zlibVersion) && UNZ_SYM(h, inflateInit2_) && UNZ_SYM(h, inflate) &&
        UNZ_SYM(h, inflateReset) && UNZ_SYM(h, inflateEnd)) {
      unz_lib.z = h;
    }
  }
  return unz_lib.z != NULL;
}

static int unz_load_zstd(void) {
  if (!unz_lib.zs_tried) {
    static const char* const names[] = {
      "libzstd.so.1", "libzstd.so", "libzstd.1.dylib", "/opt/homebrew/lib/libzstd.1.dylib",
      "/usr/local/lib/libzstd.1.dylib", NULL
    };
    unz_lib.zs_tried = 1;
    void* h = unz_open_lib("UNZ_ZSTD", names);
    if (h != NULL && UNZ_SYM(h, ZSTD_createDStream) && UNZ_SYM(h, ZSTD_initDStream) &&
        UNZ_SYM(h, ZSTD_decompressStream) && UNZ_SYM(h, ZSTD_isError) && UNZ_SYM(h, ZSTD_getErrorName) &&
        UNZ_SYM(h, ZSTD_freeDStream)) {
      unz_lib.zs = h;
    }
  }
  return unz_lib.zs != NULL;
}

// A decoder: its kind (1 gzip, 2 zstd), zlib's stream or zstd's, and
// whether the input so far ends at the end of a member or frame.
typedef struct { u32 kind; UnzZ z; void* zs; int ended; } UnzSlot;

#define UNZ_SLOTS 1024
static UnzSlot* unz_slot[UNZ_SLOTS];

static UnzSlot* unz_get(u32 id) {
  return id < UNZ_SLOTS ? unz_slot[id] : NULL;
}

// Unz.open(kind): a new decoder, 0 for gzip (or zlib: the header says
// which), 1 for zstd.
Term unz_open_run(Env e, Term* f, IoWork* w) {
  u32 kind = (u32)f[0];
  u32 id = 0;
  while (id < UNZ_SLOTS && unz_slot[id] != NULL) {
    id += 1;
  }
  if (id == UNZ_SLOTS) {
    return io_fail(e, EMFILE, "unz: too many decoders open");
  }
  UnzSlot* s = calloc(1, sizeof *s);
  if (s == NULL) {
    return io_fail(e, ENOMEM, NULL);
  }
  if (kind == 0) {
    if (!unz_load_zlib()) {
      free(s);
      return io_fail(e, ENOENT, "unz: zlib (libz) is not installed");
    }
    if (unz_lib.inflateInit2_(&s->z, 15 + 32, unz_lib.zlibVersion(), (int)sizeof(UnzZ)) != 0) {
      free(s);
      return io_fail(e, ENOMEM, "unz: inflateInit2 failed");
    }
    s->kind = 1;
  } else {
    if (!unz_load_zstd()) {
      free(s);
      return io_fail(e, ENOENT, "unz: zstd (libzstd) is not installed");
    }
    s->zs = unz_lib.ZSTD_createDStream();
    if (s->zs == NULL || unz_lib.ZSTD_isError(unz_lib.ZSTD_initDStream(s->zs))) {
      if (s->zs != NULL) {
        unz_lib.ZSTD_freeDStream(s->zs);
      }
      free(s);
      return io_fail(e, ENOMEM, "unz: ZSTD_initDStream failed");
    }
    s->kind = 2;
  }
  unz_slot[id] = s;
  return io_done(e, (Term)id);
}

// Grows out so at least room bytes are free; 0 when past max.
static int unz_room(unsigned char** out, size_t* cap, size_t used, size_t room, size_t max) {
  if (*cap - used >= room) {
    return 1;
  }
  size_t want = *cap * 2 < used + room ? used + room : *cap * 2;
  if (want > max + room) {
    want = max + room;
  }
  if (want <= *cap) {
    return 0;
  }
  unsigned char* p = realloc(*out, want);
  if (p == NULL) {
    return 0;
  }
  *out = p;
  *cap = want;
  return 1;
}

// Unz.feed(id, bytes, max): what the bytes decompress to, failing past
// max bytes (a bomb) or on bad data. gzip members and zstd frames one
// after another are one stream.
Term unz_feed_run(Env e, Term* f, IoWork* w) {
  UnzSlot* s = unz_get((u32)f[0]);
  size_t max = (size_t)(u32)f[2];
  if (s == NULL) {
    return io_fail(e, EBADF, "unz: no such decoder");
  }
  for (Term t = f[1]; term_aux(t) == CID(Con);) {
    u64 l = term_peek(e.mem, t);
    if (e.mem[l] > 255) {
      return io_fail(e, EINVAL, "unz: a byte past 255");
    }
    t = e.mem[l + 1];
  }
  u64 n = 0;
  unsigned char* in = (unsigned char*)io_cbuf(e, f[1], &n, CID(Con));
  size_t cap = n * 4 + 4096, used = 0;
  unsigned char* out = malloc(cap);
  const char* why = NULL;
  u32 code = 0;
  if (out == NULL) {
    free(in);
    return io_fail(e, ENOMEM, NULL);
  }
  if (s->kind == 1) {
    s->z.next_in = in;
    s->z.avail_in = (unsigned)n;
    while (why == NULL) {
      if (s->ended && s->z.avail_in > 0) {
        // the next gzip member
        unz_lib.inflateReset(&s->z);
        s->ended = 0;
      }
      if (s->z.avail_in == 0) {
        break;
      }
      if (!unz_room(&out, &cap, used, 65536, max)) {
        why = "unz: the output is past its limit";
        code = EFBIG;
        break;
      }
      s->z.next_out = out + used;
      s->z.avail_out = (unsigned)(cap - used);
      int r = unz_lib.inflate(&s->z, 0);
      used = cap - s->z.avail_out;
      if (r == 1) {
        s->ended = 1;
      } else if (r != 0 && r != -5) {
        why = s->z.msg != NULL ? s->z.msg : "unz: bad gzip data";
        code = EILSEQ;
      } else if (r == -5 && s->z.avail_in == 0) {
        break;
      }
      if (used > max) {
        why = "unz: the output is past its limit";
        code = EFBIG;
      }
    }
  } else {
    UnzIn zin = { in, (size_t)n, 0 };
    while (why == NULL) {
      if (!unz_room(&out, &cap, used, 131072, max)) {
        why = "unz: the output is past its limit";
        code = EFBIG;
        break;
      }
      UnzOut zout = { out, cap, used };
      size_t r = unz_lib.ZSTD_decompressStream(s->zs, &zout, &zin);
      used = zout.pos;
      if (unz_lib.ZSTD_isError(r)) {
        why = unz_lib.ZSTD_getErrorName(r);
        code = EILSEQ;
        break;
      }
      s->ended = r == 0;
      if (used > max) {
        why = "unz: the output is past its limit";
        code = EFBIG;
        break;
      }
      if (zin.pos == zin.size && zout.pos < zout.size) {
        break;
      }
    }
  }
  free(in);
  Term res = why != NULL ? io_fail(e, code, why) : io_done(e, io_list(e, (const char*)out, (u64)used));
  free(out);
  return res;
}

// Unz.close(id): frees the decoder; Fail when its input ended inside a
// member or frame.
Term unz_close_run(Env e, Term* f, IoWork* w) {
  u32 id = (u32)f[0];
  UnzSlot* s = unz_get(id);
  if (s == NULL) {
    return io_fail(e, EBADF, "unz: no such decoder");
  }
  int ended = s->ended;
  if (s->kind == 1) {
    unz_lib.inflateEnd(&s->z);
  } else {
    unz_lib.ZSTD_freeDStream(s->zs);
  }
  free(s);
  unz_slot[id] = NULL;
  return ended ? io_done(e, term_pak(CID(Unit), 0)) : io_fail(e, EILSEQ, "unz: the stream ends early");
}

#ifdef CID(Unz.open)
static void __attribute__((constructor)) unz_open_use(void) {
  io_eff(CID(Unz.open), unz_open_run);
}
#endif

#ifdef CID(Unz.feed)
static void __attribute__((constructor)) unz_feed_use(void) {
  io_eff(CID(Unz.feed), unz_feed_run);
}
#endif

#ifdef CID(Unz.close)
static void __attribute__((constructor)) unz_close_use(void) {
  io_eff(CID(Unz.close), unz_close_run);
}
#endif
