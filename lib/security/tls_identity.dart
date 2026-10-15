import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// The device's long-lived TLS identity: a self-signed ECDSA P-256 certificate.
///
/// The SHA-256 of the certificate's DER encoding is the device's
/// *fingerprint*. Peers pin it: after pairing, a connection to a device is only
/// accepted if it presents exactly this certificate, so nobody else on the
/// network can impersonate it. No certificate authority is involved.
class TlsIdentity {
  TlsIdentity._(this.certPem, this.keyPem, this.certDer)
      : fingerprint = fingerprintOf(certDer);

  final String certPem;
  final String keyPem;
  final Uint8List certDer;

  /// Lowercase hex SHA-256 of the certificate DER (64 chars).
  final String fingerprint;

  static const _certFile = 'identity_cert.pem';
  static const _keyFile = 'identity_key.pem';

  /// Loads the identity from [dir], generating and saving a new one on first run.
  static Future<TlsIdentity> loadOrCreate(Directory dir, {required String deviceId}) async {
    final certFile = File(p.join(dir.path, _certFile));
    final keyFile = File(p.join(dir.path, _keyFile));
    if (await certFile.exists() && await keyFile.exists()) {
      final certPem = await certFile.readAsString();
      return TlsIdentity._(certPem, await keyFile.readAsString(), _derFromPem(certPem));
    }

    // Pure-Dart key generation and signing is CPU-bound; keep it off the UI thread.
    final (certPem, keyPem) = await Isolate.run(() => _generate(deviceId));
    await dir.create(recursive: true);
    await keyFile.writeAsString(keyPem, flush: true);
    await _restrictToOwner(keyFile);
    await certFile.writeAsString(certPem, flush: true);
    return TlsIdentity._(certPem, keyPem, _derFromPem(certPem));
  }

  /// Server-side TLS context presenting this identity. No trusted roots: peers
  /// are authenticated by fingerprint, never by a CA.
  SecurityContext serverContext() => SecurityContext(withTrustedRoots: false)
    ..useCertificateChainBytes(utf8.encode(certPem))
    ..usePrivateKeyBytes(utf8.encode(keyPem));

  static (String, String) _generate(String deviceId) {
    final pair = CryptoUtils.generateEcKeyPair();
    final privateKey = pair.privateKey as ECPrivateKey;
    final publicKey = pair.publicKey as ECPublicKey;
    final csr = X509Utils.generateEccCsrPem(
      {'CN': 'Lucero Sync $deviceId', 'O': 'Lucero Sync'},
      privateKey,
      publicKey,
    );
    final certPem = X509Utils.generateSelfSignedCertificate(privateKey, csr, 365 * 25);
    return (certPem, CryptoUtils.encodeEcPrivateKeyToPem(privateKey));
  }

  static Uint8List _derFromPem(String pem) => CryptoUtils.getBytesFromPEMString(pem);

  static Future<void> _restrictToOwner(File f) async {
    if (Platform.isLinux || Platform.isMacOS) {
      try {
        await Process.run('chmod', ['600', f.path]);
      } catch (_) {/* best effort; app sandboxes protect it on mobile */}
    }
  }
}

String fingerprintOf(List<int> der) => sha256.convert(der).toString();

/// `AB12 CD34 …` grouping for humans comparing fingerprints.
String formatFingerprint(String fp, {int groups = 8}) {
  final upper = fp.toUpperCase();
  final parts = <String>[];
  for (var i = 0; i < upper.length && parts.length < groups; i += 4) {
    parts.add(upper.substring(i, i + 4 > upper.length ? upper.length : i + 4));
  }
  return parts.join(' ');
}
