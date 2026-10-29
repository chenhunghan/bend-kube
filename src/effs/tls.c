// TLS
// ===

// A TLS client over OpenSSL 3 (or 1.1.1), loaded with dlopen so the program
// builds with Bend's plain clang line and needs no OpenSSL headers. A TLS
// connection is a Socket handle whose fd indexes tls_conn; Bend code holds
// it inside a Tls value, so the raw TCP effects never touch it.
//
// Tls.dial resolves the host (DNS, IPv4 or IPv6) and connects on a helper
// thread; Tls.secure handshakes on such a connection, also on a helper
// thread, with the socket blocking under a deadline. Otherwise the socket
// is non-blocking, and Tls.send and Tls.recv park on the loop: before
// Tls.secure they carry plain bytes (net.bend's CONNECT to a proxy), after
// it TLS records. The server is always verified: against the PEM roots
// given, or the system's when none are, and by name (or by IP for an IP
// literal). Which host to dial, and whether through a proxy, is decided in
// Bend (proxy.bend), not here.
//
// BEND_KUBE_LIBSSL and BEND_KUBE_LIBCRYPTO name the libraries when the
// default search misses them.

#include <dlfcn.h>
#include <netdb.h>
#include <netinet/tcp.h>
#include <strings.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>

typedef struct {
  int           (*init_ssl)(uint64_t, const void*);
  const void*   (*client_method)(void);
  void*         (*ctx_new)(const void*);
  void          (*ctx_free)(void*);
  long          (*ctx_ctrl)(void*, int, long, void*);
  void          (*ctx_set_verify)(void*, int, void*);
  int           (*ctx_default_paths)(void*);
  void*         (*ctx_cert_store)(void*);
  int           (*ctx_use_cert)(void*, void*);
  int           (*ctx_use_key)(void*, void*);
  int           (*ctx_check_key)(void*);
  int           (*ctx_alpn)(void*, const unsigned char*, unsigned);
  void*         (*ssl_new)(void*);
  void          (*ssl_free)(void*);
  int           (*ssl_set_fd)(void*, int);
  long          (*ssl_ctrl)(void*, int, long, void*);
  int           (*ssl_set1_host)(void*, const char*);
  void*         (*ssl_param)(void*);
  int           (*param_ip)(void*, const char*);
  int           (*ssl_connect)(void*);
  int           (*ssl_read)(void*, void*, int);
  int           (*ssl_write)(void*, const void*, int);
  int           (*ssl_get_error)(const void*, int);
  int           (*ssl_shutdown)(void*);
  int           (*ssl_pending)(const void*);
  long          (*ssl_verify_result)(const void*);
  const char*   (*verify_text)(long);
  void*         (*store_add)(void*, void*);
  void*         (*bio_mem)(const void*, int);
  int           (*bio_free)(void*);
  void*         (*pem_x509)(void*, void**, void*, void*);
  void          (*x509_free)(void*);
  void*         (*pem_key)(void*, void**, void*, void*);
  void          (*key_free)(void*);
  unsigned long (*err_get)(void);
  void          (*err_text)(unsigned long, char*, size_t);
  void          (*err_clear)(void);
} TlsLib;

static TlsLib          tls_lib;
static int             tls_ready;  // 0 untried, 1 loaded, -1 missing
static char            tls_why[256];
static pthread_mutex_t tls_gate = PTHREAD_MUTEX_INITIALIZER;
static void*           tls_conn[65536];  // an SSL*, TLS_PLAIN, or NULL

#define TLS_PLAIN ((void*)1)

#define TLS_CTRL_MIN_PROTO     123
#define TLS_CTRL_EXTRA_CHAIN   14
#define TLS_CTRL_SNI           55
#define TLS_1_2                0x0303
#define TLS_WANT_READ          2
#define TLS_WANT_WRITE         3
#define TLS_ZERO_RETURN        6

static void* tls_open_lib(const char* env, const char* const* names) {
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

#define TLS_SYM(h, field, name) \
  if ((*(void**)&tls_lib.field = dlsym(h, name)) == NULL) { \
    snprintf(tls_why, sizeof tls_why, "TLS: %s is missing", name); \
    return -1; \
  }

static int tls_load_now(void) {
  static const char* const ssl_names[] = {
    "libssl.so.3", "libssl.so.1.1", "libssl.so",
    "/opt/homebrew/opt/openssl@3/lib/libssl.3.dylib",
    "/usr/local/opt/openssl@3/lib/libssl.3.dylib",
    "libssl.3.dylib", NULL };
  static const char* const crypto_names[] = {
    "libcrypto.so.3", "libcrypto.so.1.1", "libcrypto.so",
    "/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib",
    "/usr/local/opt/openssl@3/lib/libcrypto.3.dylib",
    "libcrypto.3.dylib", NULL };
  void* c = tls_open_lib("BEND_KUBE_LIBCRYPTO", crypto_names);
  void* s = c == NULL ? NULL : tls_open_lib("BEND_KUBE_LIBSSL", ssl_names);
  if (s == NULL) {
    snprintf(tls_why, sizeof tls_why,
      "TLS: OpenSSL not found (set BEND_KUBE_LIBSSL and BEND_KUBE_LIBCRYPTO)");
    return -1;
  }
  TLS_SYM(s, init_ssl, "OPENSSL_init_ssl");
  TLS_SYM(s, client_method, "TLS_client_method");
  TLS_SYM(s, ctx_new, "SSL_CTX_new");
  TLS_SYM(s, ctx_free, "SSL_CTX_free");
  TLS_SYM(s, ctx_ctrl, "SSL_CTX_ctrl");
  TLS_SYM(s, ctx_set_verify, "SSL_CTX_set_verify");
  TLS_SYM(s, ctx_default_paths, "SSL_CTX_set_default_verify_paths");
  TLS_SYM(s, ctx_cert_store, "SSL_CTX_get_cert_store");
  TLS_SYM(s, ctx_use_cert, "SSL_CTX_use_certificate");
  TLS_SYM(s, ctx_use_key, "SSL_CTX_use_PrivateKey");
  TLS_SYM(s, ctx_check_key, "SSL_CTX_check_private_key");
  TLS_SYM(s, ctx_alpn, "SSL_CTX_set_alpn_protos");
  TLS_SYM(s, ssl_new, "SSL_new");
  TLS_SYM(s, ssl_free, "SSL_free");
  TLS_SYM(s, ssl_set_fd, "SSL_set_fd");
  TLS_SYM(s, ssl_ctrl, "SSL_ctrl");
  TLS_SYM(s, ssl_set1_host, "SSL_set1_host");
  TLS_SYM(s, ssl_param, "SSL_get0_param");
  TLS_SYM(s, ssl_connect, "SSL_connect");
  TLS_SYM(s, ssl_read, "SSL_read");
  TLS_SYM(s, ssl_write, "SSL_write");
  TLS_SYM(s, ssl_get_error, "SSL_get_error");
  TLS_SYM(s, ssl_shutdown, "SSL_shutdown");
  TLS_SYM(s, ssl_pending, "SSL_pending");
  TLS_SYM(s, ssl_verify_result, "SSL_get_verify_result");
  TLS_SYM(c, param_ip, "X509_VERIFY_PARAM_set1_ip_asc");
  TLS_SYM(c, verify_text, "X509_verify_cert_error_string");
  TLS_SYM(c, store_add, "X509_STORE_add_cert");
  TLS_SYM(c, bio_mem, "BIO_new_mem_buf");
  TLS_SYM(c, bio_free, "BIO_free");
  TLS_SYM(c, pem_x509, "PEM_read_bio_X509");
  TLS_SYM(c, x509_free, "X509_free");
  TLS_SYM(c, pem_key, "PEM_read_bio_PrivateKey");
  TLS_SYM(c, key_free, "EVP_PKEY_free");
  TLS_SYM(c, err_get, "ERR_get_error");
  TLS_SYM(c, err_text, "ERR_error_string_n");
  TLS_SYM(c, err_clear, "ERR_clear_error");
  tls_lib.init_ssl(0, NULL);
  return 1;
}

static int tls_load(void) {
  pthread_mutex_lock(&tls_gate);
  if (tls_ready == 0) {
    tls_ready = tls_load_now();
  }
  int r = tls_ready;
  pthread_mutex_unlock(&tls_gate);
  return r;
}

// The open's arguments and outcome, owned by w->data.
typedef struct {
  char* host;
  char* ca;
  char* cert;
  char* key;
  u32   port;
  u32   ms;
  int   fd;
  int   sock;  // Tls.secure's connection, closed if the handshake fails
  void* ssl;
  u32   code;
  char  text[320];
} TlsOpen;

static void tls_fail(TlsOpen* o, u32 code, const char* what) {
  char err[200] = "";
  if (tls_ready == 1) {
    unsigned long e = tls_lib.err_get();
    if (e != 0) {
      tls_lib.err_text(e, err, sizeof err);
    }
    tls_lib.err_clear();
  }
  o->code = code;
  snprintf(o->text, sizeof o->text, "%s%s%s", what, *err ? ": " : "", err);
}

// Adds every certificate of a PEM bundle to the context's trust store.
static int tls_add_roots(TlsOpen* o, void* ctx) {
  void* bio = tls_lib.bio_mem(o->ca, -1);
  void* store = tls_lib.ctx_cert_store(ctx);
  int   n = 0;
  for (void* x; (x = tls_lib.pem_x509(bio, NULL, NULL, NULL)) != NULL; n += 1) {
    tls_lib.store_add(store, x);
    tls_lib.x509_free(x);
  }
  tls_lib.err_clear();
  tls_lib.bio_free(bio);
  return n;
}

// The client certificate (with its chain) and key, both PEM.
static int tls_use_client(TlsOpen* o, void* ctx) {
  void* bio = tls_lib.bio_mem(o->cert, -1);
  void* x   = tls_lib.pem_x509(bio, NULL, NULL, NULL);
  int   ok  = x != NULL && tls_lib.ctx_use_cert(ctx, x) == 1;
  if (x != NULL) {
    tls_lib.x509_free(x);
  }
  for (void* c; ok && (c = tls_lib.pem_x509(bio, NULL, NULL, NULL)) != NULL;) {
    tls_lib.ctx_ctrl(ctx, TLS_CTRL_EXTRA_CHAIN, 0, c);
  }
  tls_lib.err_clear();
  tls_lib.bio_free(bio);
  if (!ok) {
    return 0;
  }
  bio = tls_lib.bio_mem(o->key, -1);
  void* k = tls_lib.pem_key(bio, NULL, NULL, NULL);
  ok = k != NULL && tls_lib.ctx_use_key(ctx, k) == 1
    && tls_lib.ctx_check_key(ctx) == 1;
  if (k != NULL) {
    tls_lib.key_free(k);
  }
  tls_lib.bio_free(bio);
  return ok;
}

static int tls_dial_to(TlsOpen* o, const char* host, u32 port_n) {
  struct addrinfo hint = { .ai_family = AF_UNSPEC, .ai_socktype = SOCK_STREAM };
  struct addrinfo* res = NULL;
  char port[16];
  snprintf(port, sizeof port, "%u", port_n);
  int g = getaddrinfo(host, port, &hint, &res);
  if (g != 0) {
    o->code = EHOSTUNREACH;
    snprintf(o->text, sizeof o->text, "resolve %s: %s", host, gai_strerror(g));
    return -1;
  }
  struct timeval tv = { .tv_sec = o->ms / 1000, .tv_usec = (o->ms % 1000) * 1000 };
  int fd = -1, err = 0;
  for (struct addrinfo* a = res; a != NULL && fd < 0; a = a->ai_next) {
    fd = socket(a->ai_family, a->ai_socktype, a->ai_protocol);
    if (fd < 0) {
      err = errno;
      continue;
    }
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof one);
#ifdef SO_NOSIGPIPE
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
    if (connect(fd, a->ai_addr, a->ai_addrlen) != 0) {
      err = errno;
      close(fd);
      fd = -1;
    }
  }
  freeaddrinfo(res);
  if (fd < 0) {
    o->code = err ? (u32)err : ECONNREFUSED;
    snprintf(o->text, sizeof o->text, "connect %s:%u: %s", host, port_n,
      strerror((int)o->code));
    return -1;
  }
  if (fd >= (int)(sizeof tls_conn / sizeof *tls_conn)) {
    close(fd);
    o->code = EMFILE;
    snprintf(o->text, sizeof o->text, "TLS: descriptor %d is past the table", fd);
    return -1;
  }
  return fd;
}


static int tls_is_ip(const char* host) {
  unsigned char buf[16];
  return inet_pton(AF_INET, host, buf) == 1 || inet_pton(AF_INET6, host, buf) == 1;
}

static void tls_free_open(TlsOpen* o) {
  free(o->host);
  free(o->ca);
  free(o->cert);
  free(o->key);
  free(o);
}

// Runs on a helper thread: resolve and connect.
static void tls_dial_call(IoWork* w) {
  TlsOpen* o = (TlsOpen*)w->data;
  o->fd = tls_dial_to(o, o->host, o->port);
  if (o->fd >= 0) {
    fcntl(o->fd, F_SETFL, fcntl(o->fd, F_GETFL) | O_NONBLOCK);
  }
}

static Term tls_dial_pack(Env e, IoWork* w) {
  TlsOpen* o = (TlsOpen*)w->data;
  Term r;
  if (o->fd >= 0) {
    tls_conn[o->fd] = TLS_PLAIN;
    r = io_done(e, io_hand(o->fd));
  } else {
    r = io_fail(e, o->code, o->text);
  }
  tls_free_open(o);
  return r;
}

// Tls.dial(host, port, ms)
Term tls_dial_run(Env e, Term* f, IoWork* w) {
  TlsOpen* o = io_mem(calloc(1, sizeof *o));
  u64 n;
  o->host = io_cstr(e, f[0], &n);
  o->port = (u32)f[1];
  o->ms   = (u32)f[2] == 0 ? 30000 : (u32)f[2];
  w->data = (char*)o;
  return io_work(w, tls_dial_call, tls_dial_pack);
}

static int tls_late(IoWork* w) {
  return w->time != 0 && io_tick() >= w->time;
}

// Fails Tls.secure: the connection closes, since the Socket was consumed.
static Term tls_secure_fail(Env e, IoWork* w) {
  TlsOpen* o = (TlsOpen*)w->data;
  if (o->ssl != NULL) {
    tls_lib.ssl_free(o->ssl);
  }
  tls_conn[o->sock] = NULL;
  close(o->sock);
  Term r = io_fail(e, o->code, o->text);
  tls_free_open(o);
  return r;
}

// Drives the handshake on the loop: SSL_connect on the non-blocking
// socket, parking while it waits, under one deadline for the whole of it.
static Term tls_secure_more(Env e, IoWork* w) {
  TlsOpen* o = (TlsOpen*)w->data;
  int ret = tls_lib.ssl_connect(o->ssl);
  if (ret == 1) {
    tls_conn[o->sock] = o->ssl;
    Term r = io_done(e, io_hand(o->sock));
    tls_free_open(o);
    return r;
  }
  long v = tls_lib.ssl_verify_result(o->ssl);
  int  k = tls_lib.ssl_get_error(o->ssl, ret);
  if (v != 0) {
    o->code = EPERM;
    snprintf(o->text, sizeof o->text, "TLS: server certificate rejected: %s",
      tls_lib.verify_text(v));
    tls_lib.err_clear();
  } else if (k == TLS_WANT_READ || k == TLS_WANT_WRITE) {
    if (!tls_late(w)) {
      return io_wait_on(w, o->sock, k == TLS_WANT_READ ? POLLIN : POLLOUT, w->time,
        tls_secure_more);
    }
    tls_lib.err_clear();
    o->code = ETIMEDOUT;
    snprintf(o->text, sizeof o->text, "TLS: handshake timed out");
  } else {
    tls_fail(o, ECONNRESET, "TLS: handshake failed");
  }
  return tls_secure_fail(e, w);
}

// Tls.secure(sock, host, ca_pem, cert_pem, key_pem, ms), on a socket from
// Tls.dial that is not yet secured.
Term tls_secure_run(Env e, Term* f, IoWork* w) {
  int fd = (int)io_hand_v(f[0]);
  if (fd < 0 || fd >= 65536 || tls_conn[fd] != TLS_PLAIN) {
    return io_fail(e, EBADF, "TLS: not a plain connection from Tls.dial");
  }
  TlsOpen* o = io_mem(calloc(1, sizeof *o));
  u64 n;
  o->sock = fd;
  o->host = io_cstr(e, f[1], &n);
  o->ca   = io_cstr(e, f[2], &n);
  o->cert = io_cstr(e, f[3], &n);
  o->key  = io_cstr(e, f[4], &n);
  w->data = (char*)o;
  w->time = io_until((u32)f[5] == 0 ? 30000 : f[5]);
  if (tls_load() != 1) {
    o->code = ENOTSUP;
    snprintf(o->text, sizeof o->text, "%s", tls_why);
    return tls_secure_fail(e, w);
  }
  void* ctx = tls_lib.ctx_new(tls_lib.client_method());
  if (ctx == NULL) {
    tls_fail(o, ENOMEM, "TLS: SSL_CTX_new");
    return tls_secure_fail(e, w);
  }
  tls_lib.ctx_ctrl(ctx, TLS_CTRL_MIN_PROTO, TLS_1_2, NULL);
  tls_lib.ctx_set_verify(ctx, 1, NULL);
  static const unsigned char alpn[] = "\x08http/1.1";
  tls_lib.ctx_alpn(ctx, alpn, sizeof alpn - 1);
  if (*o->ca == 0) {
    tls_lib.ctx_default_paths(ctx);
  } else if (tls_add_roots(o, ctx) == 0) {
    tls_lib.ctx_free(ctx);
    o->code = EINVAL;
    snprintf(o->text, sizeof o->text, "TLS: no certificate in the CA bundle");
    return tls_secure_fail(e, w);
  }
  if (*o->cert != 0 && !tls_use_client(o, ctx)) {
    tls_fail(o, EINVAL, "TLS: bad client certificate or key");
    tls_lib.ctx_free(ctx);
    return tls_secure_fail(e, w);
  }
  o->ssl = tls_lib.ssl_new(ctx);
  tls_lib.ctx_free(ctx);  // the SSL keeps its own reference
  if (o->ssl == NULL) {
    tls_fail(o, ENOMEM, "TLS: SSL_new");
    return tls_secure_fail(e, w);
  }
  tls_lib.ssl_set_fd(o->ssl, fd);
  if (tls_is_ip(o->host)) {
    tls_lib.param_ip(tls_lib.ssl_param(o->ssl), o->host);
  } else {
    tls_lib.ssl_ctrl(o->ssl, TLS_CTRL_SNI, 0, o->host);
    tls_lib.ssl_set1_host(o->ssl, o->host);
  }
  return tls_secure_more(e, w);
}

// The error of an SSL call that did not finish: 0 with *evts set when it
// must wait for the socket, else an errno.
static u32 tls_why_not(void* ssl, int ret, short* evts) {
  int k = tls_lib.ssl_get_error(ssl, ret);
  if (k == TLS_WANT_READ) {
    *evts = POLLIN;
    return 0;
  }
  if (k == TLS_WANT_WRITE) {
    *evts = POLLOUT;
    return 0;
  }
  tls_lib.err_clear();
  return k == TLS_ZERO_RETURN ? 0 : errno != 0 && errno != EAGAIN ? (u32)errno
    : ECONNRESET;
}

// Send: w->data holds the UTF-8 bytes, w->made how many are sent.
static Term tls_send_more(Env e, IoWork* w) {
  int   fd  = (int)w->hand;
  void* ssl = tls_conn[fd];
  u32   code = 0;
  while ((u64)w->made < w->size) {
    if (tls_late(w)) {
      code = ETIMEDOUT;
      break;
    }
    u64 left = w->size - (u64)w->made;
    int cap = left > INT32_MAX ? INT32_MAX : (int)left;
    if (ssl == TLS_PLAIN) {
      ssize_t n = write(fd, w->data + w->made, (size_t)cap);
      if (n > 0) {
        w->made += n;
        continue;
      }
      if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
        return io_wait_on(w, fd, POLLOUT, w->time, tls_send_more);
      }
      code = n < 0 ? (u32)errno : EPIPE;
      break;
    }
    int n = tls_lib.ssl_write(ssl, w->data + w->made, cap);
    if (n > 0) {
      w->made += n;
      continue;
    }
    short evts = 0;
    errno = 0;
    code = tls_why_not(ssl, n, &evts);
    if (code == 0 && evts != 0) {
      return io_wait_on(w, fd, evts, w->time, tls_send_more);
    }
    code = code == 0 ? EPIPE : code;
    break;
  }
  free(w->data);
  return io_tup(e, io_hand(w->hand), code == 0
    ? io_done(e, term_pak(CID(Unit), 0)) : io_fail(e, code, NULL));
}

// Tls.send(sock, text, ms)
Term tls_send_run(Env e, Term* f, IoWork* w) {
  w->hand = (intptr_t)io_hand_v(f[0]);
  w->data = io_cstr(e, f[1], &w->size);
  w->made = 0;
  w->time = (u32)f[2] == 0 ? 0 : io_until(f[2]);
  if (w->hand < 0 || w->hand >= 65536 || tls_conn[w->hand] == NULL) {
    free(w->data);
    return io_tup(e, f[0], io_fail(e, EBADF, "TLS: not a TLS socket"));
  }
  return tls_send_more(e, w);
}

// Tls.send_bytes(sock, bytes, ms): the same, for raw bytes; a value past
// 255 fails with EINVAL before any byte is sent.
Term tls_send_bytes_run(Env e, Term* f, IoWork* w) {
  w->hand = (intptr_t)io_hand_v(f[0]);
  if (w->hand < 0 || w->hand >= 65536 || tls_conn[w->hand] == NULL) {
    return io_tup(e, f[0], io_fail(e, EBADF, "TLS: not a TLS socket"));
  }
  for (Term s = f[1]; term_aux(s) == CID(Con);) {
    u64 l = term_peek(e.mem, s);
    if (e.mem[l] > 255) {
      return io_tup(e, f[0], io_fail(e, EINVAL, "TLS: a byte past 255"));
    }
    s = e.mem[l + 1];
  }
  w->data = io_cbuf(e, f[1], &w->size, CID(Con));
  w->made = 0;
  w->time = (u32)f[2] == 0 ? 0 : io_until(f[2]);
  return tls_send_more(e, w);
}

// Recv: up to w->size bytes into w->data. An empty list is the end.
static Term tls_recv_more(Env e, IoWork* w) {
  int   fd  = (int)w->hand;
  void* ssl = tls_conn[fd];
  u32   code = 0;
  int   n;
  if (ssl == TLS_PLAIN) {
    ssize_t r = read(fd, w->data, (size_t)w->size);
    if (r < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
      if (tls_late(w)) {
        code = ETIMEDOUT;
      } else {
        return io_wait_on(w, fd, POLLIN, w->time, tls_recv_more);
      }
    } else if (r < 0) {
      code = (u32)errno;
    }
    n = r < 0 ? 0 : (int)r;
  } else if ((n = tls_lib.ssl_read(ssl, w->data, (int)w->size)) <= 0) {
    short evts = 0;
    errno = 0;
    code = tls_why_not(ssl, n, &evts);
    if (code == 0 && evts != 0) {
      if (tls_late(w)) {
        code = ETIMEDOUT;
      } else {
        return io_wait_on(w, fd, evts, w->time, tls_recv_more);
      }
    }
    n = 0;
  }
  Term r = code != 0 ? io_fail(e, code, NULL) : io_done(e, io_list(e, w->data, (u64)n));
  free(w->data);
  return io_tup(e, io_hand(w->hand), r);
}

// Tls.recv(sock, max, ms)
Term tls_recv_run(Env e, Term* f, IoWork* w) {
  w->hand = (intptr_t)io_hand_v(f[0]);
  if (w->hand < 0 || w->hand >= 65536 || tls_conn[w->hand] == NULL) {
    return io_tup(e, f[0], io_fail(e, EBADF, "TLS: not a TLS socket"));
  }
  w->size = (u32)f[1] == 0 ? 16384 : (u32)f[1] > (1u << 20) ? (1u << 20) : (u32)f[1];
  w->data = io_mem(malloc(w->size));
  w->time = (u32)f[2] == 0 ? 0 : io_until(f[2]);
  return tls_recv_more(e, w);
}

// Tls.close(sock): a best-effort close_notify, then the fd closes.
Term tls_close_run(Env e, Term* f, IoWork* w) {
  int fd = (int)io_hand_v(f[0]);
  if (fd >= 0 && fd < 65536 && tls_conn[fd] != NULL && tls_conn[fd] != TLS_PLAIN) {
    tls_lib.ssl_shutdown(tls_conn[fd]);
    tls_lib.err_clear();
    tls_lib.ssl_free(tls_conn[fd]);
  }
  if (fd >= 0 && fd < 65536) {
    tls_conn[fd] = NULL;
  }
  if (fd >= 0) {
    close(fd);
  }
  return term_pak(CID(Unit), 0);
}

#ifdef CID(Tls.dial)
static void __attribute__((constructor)) tls_dial_use(void) {
  // A write to a peer that hung up must fail with EPIPE, not kill us.
  signal(SIGPIPE, SIG_IGN);
  io_eff(CID(Tls.dial), tls_dial_run);
}
#endif

#ifdef CID(Tls.secure)
static void __attribute__((constructor)) tls_secure_use(void) {
  io_eff(CID(Tls.secure), tls_secure_run);
}
#endif

#ifdef CID(Tls.send)
static void __attribute__((constructor)) tls_send_use(void) {
  io_eff(CID(Tls.send), tls_send_run);
}
#endif

#ifdef CID(Tls.send_bytes)
static void __attribute__((constructor)) tls_send_bytes_use(void) {
  io_eff(CID(Tls.send_bytes), tls_send_bytes_run);
}
#endif

#ifdef CID(Tls.recv)
static void __attribute__((constructor)) tls_recv_use(void) {
  io_eff(CID(Tls.recv), tls_recv_run);
}
#endif

#ifdef CID(Tls.close)
static void __attribute__((constructor)) tls_close_use(void) {
  io_eff(CID(Tls.close), tls_close_run);
}
#endif
