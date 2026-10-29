// Sys
// ===

// The JavaScript lane: wall time from Date; signals never arrive.

io_eff(CID(Sys.wall), () => {
  const ms = Date.now();
  const s = Math.floor(ms / 1000);
  return io_tup(Math.floor(s / 86400) >>> 0, io_tup((s % 86400) >>> 0, ((ms % 1000) * 1000) >>> 0));
});
io_eff(CID(Sys.signal), (k) => {
  io_park_on(undefined, false, k, () => undefined, Infinity);
  return undefined;
});
