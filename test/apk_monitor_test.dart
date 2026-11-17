import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lan_apk_sync/src/apk_monitor.dart';

void main() {
  late Directory directory;
  late DateTime now;
  late ApkMonitor monitor;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('lan-apk-monitor-');
    now = DateTime.utc(2026, 1, 1);
    monitor = ApkMonitor(sha256: (_) async => 'a' * 64, now: () => now);
    monitor.select(directory.path, directory: true);
  });

  tearDown(() => directory.delete(recursive: true));

  test('an empty directory can wait for a build, then publish its APK',
      () async {
    await monitor.refresh();
    expect(monitor.hasSource, isTrue);
    expect(monitor.apk, isNull);

    final file = await File('${directory.path}/app.apk').writeAsString('apk');
    await monitor.refresh();
    expect(monitor.apk, isNull);
    now = now.add(const Duration(seconds: 2));
    await monitor.refresh();
    expect(monitor.apk?.file.path, file.path);
  });

  test('waits for writes to settle and withdraws a removed APK', () async {
    final file = await File('${directory.path}/app.apk').writeAsString('part');
    await monitor.refresh();
    now = now.add(const Duration(seconds: 2));
    await file.writeAsString('complete apk');
    await monitor.refresh();
    expect(monitor.apk, isNull);

    now = now.add(const Duration(seconds: 2));
    await monitor.refresh();
    expect(monitor.apk?.size, 12);
    await file.delete();
    await monitor.refresh();
    expect(monitor.apk, isNull);
  });

  test('does not publish a file changed while its hash was computed', () async {
    final file = await File('${directory.path}/app.apk').writeAsString('first');
    monitor = ApkMonitor(
      now: () => now,
      sha256: (_) async {
        await file.writeAsString('second build');
        return 'a' * 64;
      },
    )..select(directory.path, directory: true);
    await monitor.refresh();
    now = now.add(const Duration(seconds: 2));
    await monitor.refresh();
    expect(monitor.apk, isNull);
  });

  test('ignores an old hash when the source changes during hashing', () async {
    final completedHash = Completer<String>();
    await File('${directory.path}/app.apk').writeAsString('first');
    monitor = ApkMonitor(sha256: (_) => completedHash.future, now: () => now)
      ..select(directory.path, directory: true);
    await monitor.refresh();
    now = now.add(const Duration(seconds: 2));
    final refresh = monitor.refresh();
    // Allow the file stat to complete and the digest to begin.
    await Future<void>.delayed(Duration.zero);
    monitor.select('${directory.path}/other.apk', directory: false);
    completedHash.complete('a' * 64);
    await refresh;
    expect(monitor.apk, isNull);
    expect(monitor.sourcePath, endsWith('other.apk'));
  });
}
