// For tls_avail.bend: Env.set(name, value) sets (or, for "", unsets) a
// variable of this process, so one run can see OpenSSL's loader before
// and after a variable changes.

Term env_set_run(Env e, Term* f, IoWork* w) {
  u64 n;
  char* name = io_cstr(e, f[0], &n);
  char* value = io_cstr(e, f[1], &n);
  if (*value == 0) {
    unsetenv(name);
  } else {
    setenv(name, value, 1);
  }
  free(name);
  free(value);
  return term_pak(CID(Unit), 0);
}

#ifdef CID(Env.set)
static void __attribute__((constructor)) env_set_use(void) {
  io_eff(CID(Env.set), env_set_run);
}
#endif
