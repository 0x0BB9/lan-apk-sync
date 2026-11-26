import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_apk_sync/src/apk_catalog.dart';

void main() {
  late Directory directory;
  late DateTime now;
  late ApkCatalog catalog;
  Map<Object?, Object?> settings(List<Map<String, String>> sources,
          [List<String> excluded = const []]) =>
      {'sources': sources, 'excludedPaths': excluded};
  Map<String, String> source(String path, {bool directory = false}) =>
      {'path': path, 'kind': directory ? 'directory' : 'file'};

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('lan-apk-catalog-');
    now = DateTime.utc(2026);
    catalog = ApkCatalog(
      sha256: (path) async =>
          (await File(path).readAsString()).startsWith('next')
              ? 'c' * 64
              : 'a' * 64,
      identifier: (path) async => path.endsWith('b.apk') ? 'b' * 64 : 'a' * 64,
      now: () => now,
    );
  });
  tearDown(() => directory.delete(recursive: true));

  Future<void> settle() async {
    await catalog.refresh();
    now = now.add(const Duration(seconds: 2));
    await catalog.refresh();
  }

  test('publishes every APK in a directory, not only the newest', () async {
    await File('${directory.path}/a.apk').writeAsString('A');
    await File('${directory.path}/b.apk').writeAsString('B');
    catalog.restore(settings([source(directory.path, directory: true)]));
    await settle();
    expect(catalog.apks.map((apk) => apk.fileName), ['a.apk', 'b.apk']);
    expect(catalog.apks.map((apk) => apk.id).toSet().length, 2);
  });

  test('appending a source retains published files and deduplicates overlaps',
      () async {
    final a = await File('${directory.path}/a.apk').writeAsString('A');
    final b = await File('${directory.path}/b.apk').writeAsString('B');
    catalog.restore(settings([source(a.path)]));
    await settle();
    catalog.restore(settings([
      source(a.path),
      source(b.path),
      source(directory.path, directory: true)
    ]));
    expect(catalog.apks.map((apk) => apk.fileName), ['a.apk']);
    await settle();
    expect(catalog.apks.map((apk) => apk.fileName), ['a.apk', 'b.apk']);
  });

  test('a changing file does not withdraw another APK and keeps its ID',
      () async {
    final a = await File('${directory.path}/a.apk').writeAsString('A');
    await File('${directory.path}/b.apk').writeAsString('B');
    catalog.restore(settings([source(directory.path, directory: true)]));
    await settle();
    final id = catalog.apks.first.id;
    await a.writeAsString('next version');
    await catalog.refresh();
    expect(catalog.apks.map((apk) => apk.fileName), ['b.apk']);
    now = now.add(const Duration(seconds: 2));
    await catalog.refresh();
    expect(catalog.apks.first.id, id);
    expect(catalog.apks.first.sha256, 'c' * 64);
    expect(catalog.apks.last.fileName, 'b.apk');
  });

  test('exclusion survives restore, does not delete files, and can be undone',
      () async {
    final a = await File('${directory.path}/a.apk').writeAsString('A');
    await File('${directory.path}/b.apk').writeAsString('B');
    final sources = [source(directory.path, directory: true)];
    catalog.restore(settings(sources));
    await settle();
    catalog.restore(settings(sources, [a.path]));
    await settle();
    expect(catalog.apks.map((apk) => apk.fileName), ['b.apk']);
    expect(await a.exists(), isTrue);
    catalog.restore(settings(sources));
    await settle();
    expect(catalog.apks.length, 2);
  });

  test('removing sources clears entries without deleting files', () async {
    final a = await File('${directory.path}/a.apk').writeAsString('A');
    catalog.restore(settings([source(a.path)]));
    await settle();
    catalog.restore(settings([]));
    expect(catalog.apks, isEmpty);
    await catalog.refresh();
    expect(await a.exists(), isTrue);
  });

  test('withdraws deleted files independently', () async {
    final a = await File('${directory.path}/a.apk').writeAsString('A');
    await File('${directory.path}/b.apk').writeAsString('B');
    catalog.restore(settings([source(directory.path, directory: true)]));
    await settle();
    await a.delete();
    await catalog.refresh();
    expect(catalog.apks.map((apk) => apk.fileName), ['b.apk']);
  });

  test('supports legacy single-source settings and authoritative empty lists',
      () {
    expect(
        ApkSource.fromSettings(
            {'sourcePath': '/test.apk', 'sourceKind': 'file'}).single.path,
        '/test.apk');
    expect(ApkSource.fromSettings({'sources': [], 'sourcePath': '/test.apk'}),
        isEmpty);
  });

  test('ignores an in-flight hash after the user removes a source', () async {
    final hash = Completer<String>();
    final hashing = Completer<void>();
    final a = await File('${directory.path}/a.apk').writeAsString('A');
    catalog = ApkCatalog(
        identifier: (_) async => 'a' * 64,
        sha256: (_) {
          hashing.complete();
          return hash.future;
        },
        now: () => now);
    catalog.restore(settings([source(a.path)]));
    await catalog.refresh();
    now = now.add(const Duration(seconds: 2));
    final refresh = catalog.refresh();
    await hashing.future;
    catalog.restore(settings([]));
    hash.complete('a' * 64);
    await refresh;
    expect(catalog.apks, isEmpty);
  });
}
