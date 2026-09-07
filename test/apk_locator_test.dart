import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lan_apk_sync/src/apk_locator.dart';

void main() {
  test('finds the most recently modified APK recursively', () async {
    final directory = await Directory.systemTemp.createTemp('lan-apk-locator-');
    addTearDown(() => directory.delete(recursive: true));

    final oldApk = File('${directory.path}/old.apk');
    final nested = await Directory('${directory.path}/nested').create();
    final newApk = File('${nested.path}/new.APK');
    await oldApk.writeAsString('old');
    await newApk.writeAsString('new');
    await oldApk.setLastModified(DateTime.utc(2026, 1, 1));
    await newApk.setLastModified(DateTime.utc(2026, 1, 2));

    expect((await findNewestApk(directory.path))?.path, newApk.path);
  });

  test('returns null when the directory has no APK', () async {
    final directory = await Directory.systemTemp.createTemp('lan-apk-empty-');
    addTearDown(() => directory.delete(recursive: true));
    await File('${directory.path}/notes.txt').writeAsString('none');

    expect(await findNewestApk(directory.path), isNull);
  });
}
