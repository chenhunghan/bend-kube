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

// A decoder: its kind (1 gzip, 2 zstd), zlib's stream or zstd's,
// whether the input so far ends at the end of a member or frame, and the
// file its output goes to (from Unz.sink), or -1.
typedef struct { u32 kind; UnzZ z; void* zs; int ended; int fd; } UnzSlot;

#define UNZ_SLOTS 1024
static UnzSlot* unz_slot[UNZ_SLOTS];

static UnzSlot* unz_get(u32 id) {
  return id < UNZ_SLOTS ? unz_slot[id] : NULL;
}

// Starts a decoder of kind 0 (gzip or zlib: the header says which) or 1
// (zstd); NULL with *why set when it cannot.
static UnzSlot* unz_new(u32 kind, u32* code, const char** why) {
  UnzSlot* s = calloc(1, sizeof *s);
  if (s == NULL) {
    *code = ENOMEM;
    *why = NULL;
    return NULL;
  }
  s->fd = -1;
  if (kind == 0) {
    if (!unz_load_zlib()) {
      free(s);
      *code = ENOENT;
      *why = "unz: zlib (libz) is not installed";
      return NULL;
    }
    if (unz_lib.inflateInit2_(&s->z, 15 + 32, unz_lib.zlibVersion(), (int)sizeof(UnzZ)) != 0) {
      free(s);
      *code = ENOMEM;
      *why = "unz: inflateInit2 failed";
      return NULL;
    }
    s->kind = 1;
  } else {
    if (!unz_load_zstd()) {
      free(s);
      *code = ENOENT;
      *why = "unz: zstd (libzstd) is not installed";
      return NULL;
    }
    s->zs = unz_lib.ZSTD_createDStream();
    if (s->zs == NULL || unz_lib.ZSTD_isError(unz_lib.ZSTD_initDStream(s->zs))) {
      if (s->zs != NULL) {
        unz_lib.ZSTD_freeDStream(s->zs);
      }
      free(s);
      *code = ENOMEM;
      *why = "unz: ZSTD_initDStream failed";
      return NULL;
    }
    s->kind = 2;
  }
  return s;
}

// Frees a decoder; its output file is the caller's to close.
static void unz_free(UnzSlot* s) {
  if (s->kind == 1) {
    unz_lib.inflateEnd(&s->z);
  } else {
    unz_lib.ZSTD_freeDStream(s->zs);
  }
  free(s);
}

// Unz.open(kind): a new decoder, 0 for gzip (or zlib: the header says
// which), 1 for zstd.
Term unz_open_run(Env e, Term* f, IoWork* w) {
  u32 id = 0;
  while (id < UNZ_SLOTS && unz_slot[id] != NULL) {
    id += 1;
  }
  if (id == UNZ_SLOTS) {
    return io_fail(e, EMFILE, "unz: too many decoders open");
  }
  u32 code = 0;
  const char* why = NULL;
  UnzSlot* s = unz_new((u32)f[0], &code, &why);
  if (s == NULL) {
    return io_fail(e, code, why);
  }
  unz_slot[id] = s;
  return io_done(e, (Term)id);
}

// Output on its way: a buffer, and when fd is a file, everything past
// UNZ_FLUSH bytes is written there. base counts what was written, and
// base + used may not pass max. why and code say what went wrong.
typedef struct {
  unsigned char* out;
  size_t cap, used;
  u64 base, max;
  int fd;
  u32 code;
  const char* why;
} UnzBuf;

#define UNZ_FLUSH (4u << 20)

static int unz_flush(UnzBuf* b) {
  size_t at = 0;
  while (at < b->used) {
    ssize_t k = write(b->fd, b->out + at, b->used - at);
    if (k < 0 && errno == EINTR) {
      continue;
    }
    if (k <= 0) {
      b->code = k < 0 ? (u32)errno : EIO;
      b->why = "unz: writing the output failed";
      return 0;
    }
    at += (size_t)k;
  }
  b->base += b->used;
  b->used = 0;
  return 1;
}

static int unz_limit(UnzBuf* b) {
  b->why = "unz: the output is past its limit";
  b->code = EFBIG;
  return 0;
}

// Makes room bytes free at the end of the buffer, writing it out first
// when it goes to a file; 0, with why set, when it cannot.
static int unz_room(UnzBuf* b, size_t room) {
  if (b->fd >= 0 && b->used >= UNZ_FLUSH && !unz_flush(b)) {
    return 0;
  }
  if (b->cap - b->used >= room) {
    return 1;
  }
  u64 left = b->max - b->base;
  size_t want = b->cap * 2 < b->used + room ? b->used + room : b->cap * 2;
  if ((u64)want > left + room) {
    want = (size_t)(left + room);
  }
  if (want <= b->cap) {
    return unz_limit(b);
  }
  unsigned char* p = realloc(b->out, want);
  if (p == NULL) {
    b->why = NULL;
    b->code = ENOMEM;
    return 0;
  }
  b->out = p;
  b->cap = want;
  return 1;
}

// Decompresses n bytes into b; gzip members and zstd frames one after
// another are one stream. Stops with b->why set on bad data, a full
// output or a failed write.
static void unz_run(UnzSlot* s, const unsigned char* in, size_t n, UnzBuf* b) {
  if (s->kind == 1) {
    s->z.next_in = in;
    s->z.avail_in = (unsigned)n;
    while (b->why == NULL && b->code == 0) {
      if (s->ended && s->z.avail_in > 0) {
        // the next gzip member
        unz_lib.inflateReset(&s->z);
        s->ended = 0;
      }
      if (s->z.avail_in == 0 || !unz_room(b, 65536)) {
        break;
      }
      size_t free_ = b->cap - b->used;
      s->z.next_out = b->out + b->used;
      s->z.avail_out = free_ > 0x40000000 ? 0x40000000 : (unsigned)free_;
      unsigned had = s->z.avail_out;
      int r = unz_lib.inflate(&s->z, 0);
      b->used += had - s->z.avail_out;
      if (r == 1) {
        s->ended = 1;
      } else if (r != 0 && r != -5) {
        b->why = s->z.msg != NULL ? s->z.msg : "unz: bad gzip data";
        b->code = EILSEQ;
      } else if (r == -5 && s->z.avail_in == 0) {
        break;
      }
      if (b->base + b->used > b->max) {
        unz_limit(b);
      }
    }
  } else {
    UnzIn zin = { in, n, 0 };
    while (b->why == NULL && b->code == 0) {
      if (!unz_room(b, 131072)) {
        break;
      }
      UnzOut zout = { b->out, b->cap, b->used };
      size_t r = unz_lib.ZSTD_decompressStream(s->zs, &zout, &zin);
      b->used = zout.pos;
      if (unz_lib.ZSTD_isError(r)) {
        b->why = unz_lib.ZSTD_getErrorName(r);
        b->code = EILSEQ;
        break;
      }
      s->ended = r == 0;
      if (b->base + b->used > b->max) {
        unz_limit(b);
        break;
      }
      if (zin.pos == zin.size && zout.pos < zout.size) {
        break;
      }
    }
  }
}

// The bytes of a List<U32>, each checked to be a byte; NULL past 255.
static unsigned char* unz_bytes(Env e, Term t, u64* n) {
  for (Term x = t; term_aux(x) == CID(Con);) {
    u64 l = term_peek(e.mem, x);
    if (e.mem[l] > 255) {
      return NULL;
    }
    x = e.mem[l + 1];
  }
  return (unsigned char*)io_cbuf(e, t, n, CID(Con));
}

// Unz.feed(id, bytes, max): what the bytes decompress to, failing past
// max bytes (a bomb) or on bad data.
Term unz_feed_run(Env e, Term* f, IoWork* w) {
  UnzSlot* s = unz_get((u32)f[0]);
  if (s == NULL) {
    return io_fail(e, EBADF, "unz: no such decoder");
  }
  u64 n = 0;
  unsigned char* in = unz_bytes(e, f[1], &n);
  if (in == NULL) {
    return io_fail(e, EINVAL, "unz: a byte past 255");
  }
  UnzBuf b = { malloc(n * 4 + 4096), n * 4 + 4096, 0, 0, (u64)(u32)f[2], -1, 0, NULL };
  if (b.out == NULL) {
    free(in);
    return io_fail(e, ENOMEM, NULL);
  }
  unz_run(s, in, (size_t)n, &b);
  free(in);
  Term res = b.why != NULL || b.code != 0 ? io_fail(e, b.code, b.why)
                                          : io_done(e, io_list(e, (const char*)b.out, (u64)b.used));
  free(b.out);
  return res;
}

// Unz.sink(id, path): from now on the decoder's output goes to the file
// at path, created (mode 0644) or truncated, through Unz.write.
Term unz_sink_run(Env e, Term* f, IoWork* w) {
  UnzSlot* s = unz_get((u32)f[0]);
  u64 n;
  char* path = io_cstr(e, f[1], &n);
  if (s == NULL || s->fd >= 0) {
    free(path);
    return io_fail(e, s == NULL ? EBADF : EBUSY, s == NULL ? "unz: no such decoder" : "unz: the decoder has a file");
  }
  int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
  u32 code = (u32)errno;
  free(path);
  if (fd < 0) {
    return io_fail(e, code, NULL);
  }
  s->fd = fd;
  return io_done(e, term_pak(CID(Unit), 0));
}

// Unz.write(id, bytes, max): decompresses the bytes into the decoder's
// file (Unz.sink), failing past max bytes or on bad data; how many bytes
// it wrote.
Term unz_write_run(Env e, Term* f, IoWork* w) {
  UnzSlot* s = unz_get((u32)f[0]);
  if (s == NULL || s->fd < 0) {
    return io_fail(e, EBADF, s == NULL ? "unz: no such decoder" : "unz: the decoder has no file (Unz.sink)");
  }
  u64 n = 0;
  unsigned char* in = unz_bytes(e, f[1], &n);
  if (in == NULL) {
    return io_fail(e, EINVAL, "unz: a byte past 255");
  }
  size_t cap = n * 4 + 4096 < UNZ_FLUSH ? n * 4 + 4096 : UNZ_FLUSH;
  UnzBuf b = { malloc(cap), cap, 0, 0, (u64)(u32)f[2], s->fd, 0, NULL };
  if (b.out == NULL) {
    free(in);
    return io_fail(e, ENOMEM, NULL);
  }
  unz_run(s, in, (size_t)n, &b);
  free(in);
  if (b.why == NULL && b.code == 0) {
    unz_flush(&b);
  }
  free(b.out);
  return b.why != NULL || b.code != 0 ? io_fail(e, b.code, b.why) : io_done(e, (Term)(u32)b.base);
}

// fsync and close; the errno, or 0.
static u32 unz_sync(int fd) {
  u32 code = fsync(fd) != 0 ? (u32)errno : 0;
  if (close(fd) != 0 && code == 0) {
    code = (u32)errno;
  }
  return code;
}

// Unz.close(id): frees the decoder, and fsyncs and closes its file; Fail
// when its input ended inside a member or frame, or the file did not
// sync.
Term unz_close_run(Env e, Term* f, IoWork* w) {
  u32 id = (u32)f[0];
  UnzSlot* s = unz_get(id);
  if (s == NULL) {
    return io_fail(e, EBADF, "unz: no such decoder");
  }
  int ended = s->ended;
  u32 code = s->fd >= 0 ? unz_sync(s->fd) : 0;
  unz_free(s);
  unz_slot[id] = NULL;
  if (!ended) {
    return io_fail(e, EILSEQ, "unz: the stream ends early");
  }
  return code != 0 ? io_fail(e, code, "unz: syncing the output failed") : io_done(e, term_pak(CID(Unit), 0));
}

// Unz.file's work, done on a helper thread.
typedef struct {
  UnzSlot* s;
  char* src;
  char* dst;
  u64 max, total;
  u32 code;
  const char* why;
} UnzFile;

#define UNZ_CHUNK (1u << 20)

static void unz_file_call(IoWork* w) {
  UnzFile* j = (UnzFile*)w->data;
  int in = open(j->src, O_RDONLY | O_CLOEXEC);
  if (in < 0) {
    j->code = (u32)errno;
    j->why = "unz: cannot open the input";
    return;
  }
  int out = open(j->dst, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
  if (out < 0) {
    j->code = (u32)errno;
    j->why = "unz: cannot create the output";
    close(in);
    return;
  }
  unsigned char* chunk = malloc(UNZ_CHUNK);
  UnzBuf b = { malloc(UNZ_FLUSH + 131072), UNZ_FLUSH + 131072, 0, 0, j->max, out, 0, NULL };
  if (chunk == NULL || b.out == NULL) {
    b.code = ENOMEM;
  }
  while (b.why == NULL && b.code == 0) {
    ssize_t k = read(in, chunk, UNZ_CHUNK);
    if (k < 0 && errno == EINTR) {
      continue;
    }
    if (k < 0) {
      b.code = (u32)errno;
      b.why = "unz: reading the input failed";
    } else if (k == 0) {
      break;
    } else {
      unz_run(j->s, chunk, (size_t)k, &b);
    }
  }
  if (b.why == NULL && b.code == 0) {
    unz_flush(&b);
  }
  if (b.why == NULL && b.code == 0 && !j->s->ended) {
    b.code = EILSEQ;
    b.why = "unz: the stream ends early";
  }
  close(in);
  u32 sync = unz_sync(out);
  if (b.why == NULL && b.code == 0 && sync != 0) {
    b.code = sync;
    b.why = "unz: syncing the output failed";
  }
  if (b.why != NULL || b.code != 0) {
    unlink(j->dst);
  }
  free(chunk);
  free(b.out);
  j->total = b.base;
  j->code = b.code;
  j->why = b.why;
}

static Term unz_file_pack(Env e, IoWork* w) {
  UnzFile* j = (UnzFile*)w->data;
  Term r = j->why != NULL || j->code != 0
    ? io_fail(e, j->code, j->why)
    : io_done(e, io_tup(e, (Term)(u32)(j->total >> 32), (Term)(u32)j->total));
  unz_free(j->s);
  free(j->src);
  free(j->dst);
  free(j);
  return r;
}

// Unz.file(kind, src, dst, max_mib): decompresses the file at src into
// a new file at dst (mode 0644, fsynced), on a helper thread, failing
// past max_mib MiB of output (0: no limit); dst is removed on a failure.
// The size it wrote, as (high, low) 32-bit halves.
Term unz_file_run(Env e, Term* f, IoWork* w) {
  u32 code = 0;
  const char* why = NULL;
  UnzSlot* s = unz_new((u32)f[0], &code, &why);
  if (s == NULL) {
    return io_fail(e, code, why);
  }
  UnzFile* j = calloc(1, sizeof *j);
  if (j == NULL) {
    unz_free(s);
    return io_fail(e, ENOMEM, NULL);
  }
  u64 n;
  j->s = s;
  j->src = io_cstr(e, f[1], &n);
  j->dst = io_cstr(e, f[2], &n);
  j->max = (u32)f[3] == 0 ? ~(u64)0 >> 1 : (u64)(u32)f[3] << 20;
  w->data = (char*)j;
  return io_work(w, unz_file_call, unz_file_pack);
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

#ifdef CID(Unz.sink)
static void __attribute__((constructor)) unz_sink_use(void) {
  io_eff(CID(Unz.sink), unz_sink_run);
}
#endif

#ifdef CID(Unz.write)
static void __attribute__((constructor)) unz_write_use(void) {
  io_eff(CID(Unz.write), unz_write_run);
}
#endif

#ifdef CID(Unz.file)
static void __attribute__((constructor)) unz_file_use(void) {
  io_eff(CID(Unz.file), unz_file_run);
}
#endif
