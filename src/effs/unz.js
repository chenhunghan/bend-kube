// Unz
// ===

// The JS lane has no zlib or libzstd: unz.c only. gzip.bend decodes gzip
// in pure Bend on every lane.
io_eff(CID(Unz.open), (kind) => io_fail(4000, "unz: decompression libraries need the native lane"));
io_eff(CID(Unz.feed), (id, bytes, max) => io_fail(4000, "unz: decompression libraries need the native lane"));
io_eff(CID(Unz.close), (id) => io_fail(4000, "unz: decompression libraries need the native lane"));
io_eff(CID(Unz.sink), (id, path) => io_fail(4000, "unz: decompression libraries need the native lane"));
io_eff(CID(Unz.write), (id, bytes, max) => io_fail(4000, "unz: decompression libraries need the native lane"));
io_eff(CID(Unz.file), (kind, src, dst, max) => io_fail(4000, "unz: decompression libraries need the native lane"));
io_eff(CID(Unz.file_sha256), (kind, src, dst, max) => io_fail(4000, "unz: decompression libraries need the native lane"));
