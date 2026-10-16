import 'package:flutter_test/flutter_test.dart';
import 'package:lucero_sync/app/updates.dart';

void main() {
  test('compares versions numerically', () {
    expect(isNewerVersion('0.3.10', '0.3.9'), isTrue);
    expect(isNewerVersion('1.0.0', '0.9.9'), isTrue);
    expect(isNewerVersion('0.3.2', '0.3.2'), isFalse);
    expect(isNewerVersion('0.3.1', '0.3.2'), isFalse);
    expect(isNewerVersion('0.4', '0.3.9'), isTrue);
  });
}
