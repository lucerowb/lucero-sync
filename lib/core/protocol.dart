/// Wire protocol shared by sender and receiver.
///
/// Plain HTTP/1.1 on the LAN, authenticated with a per-receiver PIN.
///
///   GET  /v1/info                 -> {deviceId, name, version}            (no auth)
///   POST /v1/check                -> {results: [{sha256, state, offset}]} (batch pre-check)
///   PUT  /v1/files/<sha256>       -> {status: stored|skipped|partial, ...}
///        headers: filename, size, created, offset; body = bytes [offset, size)
///
/// Resume model: the receiver keeps `<sha256>.part` files. A sender that was
/// interrupted asks /v1/check, gets `partial` + the byte offset on disk, and
/// PUTs only the remainder. The receiver verifies the full SHA-256 before
/// moving the file into place, so a corrupted resume can never be committed.
class Protocol {
  static const version = 1;
  static const defaultPort = 8765;
  static const serviceType = '_lucerosync._tcp';

  static const hToken = 'x-lucero-token';
  static const hDeviceId = 'x-lucero-device';
  static const hFilename = 'x-lucero-filename';
  static const hSize = 'x-lucero-size';
  static const hCreated = 'x-lucero-created';
  static const hOffset = 'x-lucero-offset';

  // Upload response statuses.
  static const stored = 'stored';
  static const skipped = 'skipped';
  static const partial = 'partial';
  static const offsetMismatch = 'offset_mismatch';
  static const hashMismatch = 'hash_mismatch';
  static const sizeMismatch = 'size_mismatch';
  static const busy = 'busy';
}
