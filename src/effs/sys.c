// Sys
// ===

// Wall-clock time and termination signals, which Base does not offer:
// IO.now is monotonic, and a controller must stamp Leases and logs with
// the real time, and hear SIGTERM to hand its Lease back before the pod
// dies.

#include <signal.h>
#include <sys/time.h>

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
