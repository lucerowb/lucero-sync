import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Cryptographic pieces of the pairing handshake (protocol v2).
///
/// Pairing runs over TLS where the client has already observed the server's
/// certificate fingerprint (`serverFp`). It is a numeric-comparison scheme like
/// Bluetooth Secure Simple Pairing:
///
///   1. client → server: clientFp, commit = H(clientNonce, clientFp, serverFp)
///   2. server → client: serverNonce              (only after the commitment)
///   3. client → server: clientNonce              (server checks the commitment)
///   4. both show code = SAS(serverFp, clientFp, clientNonce, serverNonce)
///   5. BOTH users confirm the codes match. The receiver taps Accept; the
///      sender taps "Codes match" before it hands over its own token. Neither
///      side stores the other until both have confirmed.
///
/// A man in the middle terminates TLS with its own certificate, so the two
/// sides compute codes over different `serverFp`s. Because each side's nonce is
/// fixed (committed or sent) before it learns the other's, the attacker can't
/// grind keys or nonces to make the codes collide: each attempt succeeds with
/// probability 10⁻⁶ and needs a human to approve it.
///
/// When pairing via QR code, the client learns `serverFp` out-of-band from the
/// QR itself and pins it, which already rules out a man in the middle; the QR's
/// one-time secret then lets the receiver approve automatically.
class PairingCrypto {
  static final _rng = Random.secure();

  static Uint8List randomBytes(int n) => Uint8List.fromList(List.generate(n, (_) => _rng.nextInt(256)));

  static String randomHex(int bytes) => hex(randomBytes(bytes));

  /// URL-safe random bearer token (256 bits).
  static String newToken() => base64Url.encode(randomBytes(32)).replaceAll('=', '');

  static String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  /// Binds the client's nonce to both fingerprints, so a commitment made to
  /// an impostor's certificate fails verification at the real server.
  static String commit({required String nonceHex, required String clientFp, required String serverFp}) =>
      sha256.convert(utf8.encode('lucero-commit-v2|$nonceHex|$clientFp|$serverFp')).toString();

  static bool verifyCommit({
    required String nonceHex,
    required String clientFp,
    required String serverFp,
    required String commitment,
  }) =>
      constantTimeEquals(commit(nonceHex: nonceHex, clientFp: clientFp, serverFp: serverFp), commitment);

  /// Six-digit short authentication string, formatted `123 456`.
  static String sas({
    required String serverFp,
    required String clientFp,
    required String clientNonce,
    required String serverNonce,
  }) {
    final d = sha256.convert(utf8.encode('lucero-sas-v2|$serverFp|$clientFp|$clientNonce|$serverNonce')).bytes;
    final n = ((d[0] << 24) | (d[1] << 16) | (d[2] << 8) | d[3]) & 0x7fffffff;
    final s = (n % 1000000).toString().padLeft(6, '0');
    return '${s.substring(0, 3)} ${s.substring(3)}';
  }

  /// Tokens are stored hashed so a leaked database can't be replayed.
  static String hashToken(String token) => sha256.convert(utf8.encode('lucero-token-v2|$token')).toString();

  static bool tokenMatches(String token, String storedHash) => constantTimeEquals(hashToken(token), storedHash);

  static bool constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
