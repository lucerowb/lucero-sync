import 'package:flutter_test/flutter_test.dart';
import 'package:lucero_sync/core/hashing.dart';
import 'package:lucero_sync/core/models.dart';
import 'package:lucero_sync/receiver/receiver_storage.dart';

void main() {
  group('PairingPayload', () {
    test('round-trips a receiver', () {
      final raw = PairingPayload.encode(
        deviceId: 'abc123',
        name: 'Pixel',
        host: '192.168.1.20',
        port: 8765,
        pin: '042917',
      );
      final peer = PairingPayload.decode(raw)!;
      expect(peer.deviceId, 'abc123');
      expect(peer.host, '192.168.1.20');
      expect(peer.port, 8765);
      expect(peer.token, '042917');
    });

    test('rejects unrelated QR codes', () {
      expect(PairingPayload.decode('https://example.com'), isNull);
      expect(PairingPayload.decode('{"app":"other"}'), isNull);
    });
  });

  test('metaKey ignores filename case', () {
    expect(
      FileDescriptor.buildMetaKey('IMG_0001.HEIC', 1700000000000, 2048),
      FileDescriptor.buildMetaKey('img_0001.heic', 1700000000000, 2048),
    );
  });

  test('sanitizeFilename blocks path traversal', () {
    expect(sanitizeFilename('../../etc/passwd'), 'passwd');
    expect(sanitizeFilename(r'..\..\evil.jpg'), 'evil.jpg');
    expect(sanitizeFilename('..'), 'file');
    expect(sanitizeFilename(''), 'file');
    expect(sanitizeFilename('IMG_0001.HEIC'), 'IMG_0001.HEIC');
  });

  test('isSha256Hex', () {
    expect(isSha256Hex('a' * 64), isTrue);
    expect(isSha256Hex('A' * 64), isFalse); // server lower-cases first
    expect(isSha256Hex('../x'), isFalse);
  });
}
