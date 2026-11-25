// Zip
// ===

// The JS lane has no compressor: zip.c only. Zip.blocks hands its files
// back, as every effect on a handle does.
io_eff(CID(Zip.blocks), (kind, src, off_hi, off_lo, len_hi, len_lo, block, dst, at_hi, at_lo) =>
  io_tup(src, io_tup(dst, io_fail(4000, "zip: compression needs the native lane"))));
io_eff(CID(Zip.pack), (kind, bytes) => io_fail(4000, "zip: compression needs the native lane"));
