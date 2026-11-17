import 'package:flutter_test/flutter_test.dart';
import 'package:lan_apk_sync/src/share_settings.dart';

void main() {
  test('retains the same link identity across saved settings and restarts', () {
    final first = ShareSettings.fromMap({}).copyWith(
      port: 8888,
      preferredAddress: '192.168.1.20',
      autoStart: false,
    );
    final restored = ShareSettings.fromMap(first.toMap());

    expect(restored.token, first.token);
    expect(restored.port, 8888);
    expect(restored.autoStart, isFalse);
    expect(restored.preferredAddress, '192.168.1.20');
  });

  test('repairs invalid settings without accepting unsafe route tokens', () {
    final settings = ShareSettings.fromMap({
      'token': '../download?x=1',
      'port': 80,
      'autoStart': 'true',
    });

    expect(isValidShareToken(settings.token), isTrue);
    expect(settings.port, 8787);
    expect(settings.autoStart, isTrue);
    expect(newShareToken(), isNot(settings.token));
  });
}
