// Sys
// ===

// Wall-clock time and termination signals, which Base does not offer:
// IO.now is monotonic, and a controller must stamp Leases and logs with
// the real time, and hear SIGTERM to hand its Lease back before the pod
// dies.

#include <netinet/in.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>

// Sys.wall(): (days since 1970-01-01, (second of the day, microseconds)),
// so no field overflows for millions of years.
Term sys_wall_run(Env e, Term* f, IoWork* w) {
  struct timeval tv;
  gettimeofday(&tv, NULL);
  uint64_t s = (uint64_t)tv.tv_sec;
  return io_tup(e, (Term)(u32)(s / 86400), io_tup(e, (Term)(u32)(s % 86400), (Term)(u32)tv.tv_usec));
}

// The self-pipe a signal handler writes its number to.
static int sys_sig_fd[2] = { -1, -1 };

static void sys_on_signal(int sig) {
  unsigned char b = (unsigned char)sig;
  ssize_t n = write(sys_sig_fd[1], &b, 1);
  (void)n;
}

static Term sys_signal_more(Env e, IoWork* w) {
  unsigned char b = 0;
  ssize_t n = read(sys_sig_fd[0], &b, 1);
  if (n != 1) {
    return io_wait_on(w, sys_sig_fd[0], POLLIN, 0, sys_signal_more);
  }
  return (Term)(u32)b;
}

// Sys.signal(): waits for SIGTERM or SIGINT and answers its number. The
// first call installs the handlers; until then the defaults apply.
Term sys_signal_run(Env e, Term* f, IoWork* w) {
  if (sys_sig_fd[0] < 0) {
    if (pipe(sys_sig_fd) != 0) {
      return (Term)0;
    }
    fcntl(sys_sig_fd[0], F_SETFL, fcntl(sys_sig_fd[0], F_GETFL) | O_NONBLOCK);
    fcntl(sys_sig_fd[1], F_SETFL, fcntl(sys_sig_fd[1], F_GETFL) | O_NONBLOCK);
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = sys_on_signal;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
  }
  return sys_signal_more(e, w);
}

// Sys.listen.dual(port): a non-blocking listener on every address of port:
// IPv6 and, through IPv4-mapped addresses, IPv4 (IPV6_V6ONLY off), so an
// IPv6-only or dual-stack pod is reachable; a host without IPv6 gets one
// on 0.0.0.0. Base's TCP.accept serves it like TCP.listen's.
Term sys_listen_run(Env e, Term* f, IoWork* w) {
  uint16_t port = (uint16_t)(u32)f[0];
  int one = 1, zero = 0, ok = 0;
  int fd = socket(AF_INET6, SOCK_STREAM, 0);
  if (fd >= 0) {
    struct sockaddr_in6 at;
    memset(&at, 0, sizeof at);
    at.sin6_family = AF_INET6;
    at.sin6_port = htons(port);
    at.sin6_addr = in6addr_any;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &zero, sizeof zero);
    ok = bind(fd, (struct sockaddr*)&at, sizeof at) == 0;
    if (!ok) {
      close(fd);
    }
  }
  if (!ok) {
    fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
      return io_fail(e, (uint32_t)errno, NULL);
    }
    struct sockaddr_in at4;
    memset(&at4, 0, sizeof at4);
    at4.sin_family = AF_INET;
    at4.sin_port = htons(port);
    at4.sin_addr.s_addr = htonl(INADDR_ANY);
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    if (bind(fd, (struct sockaddr*)&at4, sizeof at4) != 0) {
      uint32_t code = (uint32_t)errno;
      close(fd);
      return io_fail(e, code, NULL);
    }
  }
  if (listen(fd, 512) < 0 || fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) < 0) {
    uint32_t code = (uint32_t)errno;
    close(fd);
    return io_fail(e, code, NULL);
  }
  return io_done(e, io_hand(fd));
}

#ifdef CID(Sys.listen.dual)
static void __attribute__((constructor)) sys_listen_use(void) {
  io_eff(CID(Sys.listen.dual), sys_listen_run);
}
#endif

// Sys.memo_get(key, now) / Sys.memo_put(key, value, until): a process-wide
// table of short strings that expire (times in wall-clock seconds), for
// what must outlive one request, such as an exec plugin's token. Effects
// run on the loop thread, so the table needs no lock. A lookup of a key
// that is missing or expired answers "".
typedef struct SysMemo { char* key; char* val; u32 until; struct SysMemo* next; } SysMemo;
static SysMemo* sys_memo;

Term sys_memo_get_run(Env e, Term* f, IoWork* w) {
  u64 n;
  char* key = io_cstr(e, f[0], &n);
  u32 now = (u32)f[1];
  const char* got = "";
  for (SysMemo* m = sys_memo; m != NULL; m = m->next) {
    if (strcmp(m->key, key) == 0) {
      got = now < m->until ? m->val : "";
      break;
    }
  }
  free(key);
  return io_str(e, got, strlen(got));
}

Term sys_memo_put_run(Env e, Term* f, IoWork* w) {
  u64 n;
  char* key = io_cstr(e, f[0], &n);
  char* val = io_cstr(e, f[1], &n);
  for (SysMemo* m = sys_memo; m != NULL; m = m->next) {
    if (strcmp(m->key, key) == 0) {
      free(m->val);
      free(key);
      m->val = val;
      m->until = (u32)f[2];
      return term_pak(CID(Unit), 0);
    }
  }
  SysMemo* m = io_mem(calloc(1, sizeof *m));
  m->key = key;
  m->val = val;
  m->until = (u32)f[2];
  m->next = sys_memo;
  sys_memo = m;
  return term_pak(CID(Unit), 0);
}

#ifdef CID(Sys.memo_get)
static void __attribute__((constructor)) sys_memo_get_use(void) {
  io_eff(CID(Sys.memo_get), sys_memo_get_run);
}
#endif

#ifdef CID(Sys.memo_put)
static void __attribute__((constructor)) sys_memo_put_use(void) {
  io_eff(CID(Sys.memo_put), sys_memo_put_run);
}
#endif

#ifdef CID(Sys.wall)
static void __attribute__((constructor)) sys_wall_use(void) {
  io_eff(CID(Sys.wall), sys_wall_run);
}
#endif

#ifdef CID(Sys.signal)
static void __attribute__((constructor)) sys_signal_use(void) {
  io_eff(CID(Sys.signal), sys_signal_run);
}
#endif

// Sys.unix_listen(path, mode): a non-blocking listener on a Unix socket
// at path, as containerd's plugins and gRPC services serve. A socket file
// left by a server that is gone (connecting is refused) is replaced; a
// live one fails with EADDRINUSE, and anything else at path with EEXIST,
// so no regular file is ever removed. A mode other than 0 is chmod'ed on
// the socket file. Base's TCP.accept serves the listener.
static int sys_unix_addr(const char* path, size_t n, struct sockaddr_un* at) {
  memset(at, 0, sizeof *at);
  at->sun_family = AF_UNIX;
  if (n == 0 || n >= sizeof at->sun_path || memchr(path, 0, n) != NULL) {
    errno = n == 0 || memchr(path, 0, n) != NULL ? EINVAL : ENAMETOOLONG;
    return -1;
  }
  memcpy(at->sun_path, path, n);
  return 0;
}

static int sys_unix_socket(void) {
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd >= 0 && (fcntl(fd, F_SETFD, FD_CLOEXEC) < 0 ||
      fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) < 0)) {
    int code = errno;
    close(fd);
    errno = code;
    return -1;
  }
  return fd;
}

// Clears path for a new socket: 0 when nothing is there or a dead socket
// was removed, else -1 with errno set.
static int sys_unix_clear(struct sockaddr_un* at) {
  struct stat st;
  if (lstat(at->sun_path, &st) != 0) {
    return errno == ENOENT ? 0 : -1;
  }
  if (!S_ISSOCK(st.st_mode)) {
    errno = EEXIST;
    return -1;
  }
  int probe = socket(AF_UNIX, SOCK_STREAM, 0);
  if (probe < 0) {
    return -1;
  }
  int live = connect(probe, (struct sockaddr*)at, sizeof *at) == 0;
  int code = errno;
  close(probe);
  if (live || (code != ECONNREFUSED && code != ENOENT)) {
    errno = live ? EADDRINUSE : code;
    return -1;
  }
  return unlink(at->sun_path) == 0 || errno == ENOENT ? 0 : -1;
}

Term sys_unix_listen_run(Env e, Term* f, IoWork* w) {
  u64 n;
  char* path = io_cstr(e, f[0], &n);
  u32 mode = (u32)f[1];
  struct sockaddr_un at;
  int fd = -1;
  if (sys_unix_addr(path, (size_t)n, &at) == 0 && sys_unix_clear(&at) == 0) {
    fd = sys_unix_socket();
  }
  if (fd >= 0 && (bind(fd, (struct sockaddr*)&at, sizeof at) != 0 ||
      (mode != 0 && chmod(at.sun_path, (mode_t)mode) != 0) || listen(fd, 512) != 0)) {
    int code = errno;
    close(fd);
    fd = -1;
    errno = code;
  }
  uint32_t code = (uint32_t)errno;
  free(path);
  return fd < 0 ? io_fail(e, code, NULL) : io_done(e, io_hand(fd));
}

#ifdef CID(Sys.unix_listen)
static void __attribute__((constructor)) sys_unix_listen_use(void) {
  io_eff(CID(Sys.unix_listen), sys_unix_listen_run);
}
#endif

// Sys.unix_connect(path): a non-blocking socket connected to the Unix
// socket at path, for Base's TCP.send and TCP.recv. A connect that is in
// progress parks until the socket is writable, as Base's TCP.connect does.
static Term sys_unix_connect_more(Env e, IoWork* w) {
  int fd = (int)w->made;
  int err = (int)w->code;
  socklen_t len = sizeof err;
  if (err == EINPROGRESS && getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) != 0) {
    err = errno;
  }
  if (err != 0 && fd >= 0) {
    close(fd);
  }
  return err != 0 ? io_fail(e, (u32)err, NULL) : io_done(e, io_hand(fd));
}

Term sys_unix_connect_run(Env e, Term* f, IoWork* w) {
  u64 n;
  char* path = io_cstr(e, f[0], &n);
  struct sockaddr_un at;
  int fd = -1;
  if (sys_unix_addr(path, (size_t)n, &at) == 0) {
    fd = sys_unix_socket();
  }
  free(path);
  w->made = fd;
  if (fd < 0) {
    w->code = (u32)errno;
    return sys_unix_connect_more(e, w);
  }
  int r = connect(fd, (struct sockaddr*)&at, sizeof at);
  w->code = r == 0 ? 0 : (u32)errno;
  if (w->code == EINTR) {
    w->code = EINPROGRESS;
  }
  return w->code == EINPROGRESS
    ? io_wait_on(w, fd, POLLOUT, 0, sys_unix_connect_more) : sys_unix_connect_more(e, w);
}

#ifdef CID(Sys.unix_connect)
static void __attribute__((constructor)) sys_unix_connect_use(void) {
  io_eff(CID(Sys.unix_connect), sys_unix_connect_run);
}
#endif

// Sys.dup(sock): a second handle on sock's connection (dup(2)), so one
// computation can read while another writes, each owning its handle. The
// connection lasts until both are closed; Sys.shutdown ends it for both.
Term sys_dup_run(Env e, Term* f, IoWork* w) {
  int fd = (int)io_hand_v(f[0]);
  int got = fcntl(fd, F_DUPFD_CLOEXEC, 0);
  uint32_t code = (uint32_t)errno;
  return io_tup(e, io_hand(fd), got < 0 ? io_fail(e, code, NULL) : io_done(e, io_hand(got)));
}

#ifdef CID(Sys.dup)
static void __attribute__((constructor)) sys_dup_use(void) {
  io_eff(CID(Sys.dup), sys_dup_run);
}
#endif

// Sys.shutdown(sock): shutdown(2) both ways, which wakes a computation
// reading the connection on another handle (its recv ends). The handle
// stays open until closed.
Term sys_shutdown_run(Env e, Term* f, IoWork* w) {
  int fd = (int)io_hand_v(f[0]);
  shutdown(fd, SHUT_RDWR);
  return io_hand(fd);
}

#ifdef CID(Sys.shutdown)
static void __attribute__((constructor)) sys_shutdown_use(void) {
  io_eff(CID(Sys.shutdown), sys_shutdown_run);
}
#endif
