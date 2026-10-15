/// Wire protocol v2, shared by every Lucero Sync device.
///
/// HTTPS on the local network. Each device presents its own self-signed
/// certificate; peers pin its SHA-256 fingerprint (see `security/`). After
/// pairing, requests carry `Authorization: Bearer <token>`.
///
///   GET  /v2/info                       device id, name, platform, fingerprint   (no auth)
///   POST /v2/pair/start                 begin pairing (commit to client nonce)   (no auth)
///   POST /v2/pair/finish                reveal nonce; approve → tokens exchanged (no auth)
///   POST /v2/unpair                     forget the caller
///   POST /v2/backup/check               dedup pre-check for backup files
///   PUT  /v2/backup/files/<sha256>      resumable backup upload
///   POST /v2/share/offer                offer files or text; waits for accept
///   PUT  /v2/share/<offer>/<file>       resumable shared-file upload
///   POST /v2/share/<offer>/cancel       sender cancelled
///
/// Uploads are resumable: the receiver keeps `.part` files and reports the byte
/// offset it already has; the full SHA-256 is verified before a file is saved.
class Protocol {
  static const version = 2;
  static const defaultPort = 8765;
  static const serviceType = '_lucerosync._tcp';

  // Headers
  static const hDeviceId = 'x-lucero-device';
  static const hFilename = 'x-lucero-filename';
  static const hSize = 'x-lucero-size';
  static const hCreated = 'x-lucero-created';
  static const hOffset = 'x-lucero-offset';
  static const hSha256 = 'x-lucero-sha256';

  // Upload / offer statuses
  static const stored = 'stored';
  static const skipped = 'skipped';
  static const partial = 'partial';
  static const offsetMismatch = 'offset_mismatch';
  static const hashMismatch = 'hash_mismatch';
  static const sizeMismatch = 'size_mismatch';
  static const busy = 'busy';
  static const accepted = 'accepted';
  static const declined = 'declined';
  static const cancelled = 'cancelled';
}
