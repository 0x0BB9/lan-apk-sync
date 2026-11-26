import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lan_apk_sync/src/apk_share_server.dart';
import 'package:lan_apk_sync/src/share_settings.dart';
import 'package:lan_apk_sync/src/shared_apk.dart';

void main() {
  late Directory directory;
  late File file;
  late SharedApk apk;
  late ApkShareServer server;
  late HttpClient client;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('lan-apk-server-');
    file = File('${directory.path}/demo app.apk');
    await file.writeAsBytes(List<int>.generate(64, (index) => index));
    final stat = await file.stat();
    apk = SharedApk(
      file: file,
      size: stat.size,
      modifiedAt: stat.modified,
      sha256: 'a' * 64,
    );
    server = ApkShareServer(currentApk: () => apk);
    await server.start(port: 0);
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.stop();
    await directory.delete(recursive: true);
  });

  Uri uri(String path) => Uri.parse(
        'http://127.0.0.1:${server.port}/${server.token}/$path',
      );

  test('protects routes with an unguessable share token', () async {
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:${server.port}/manifest.json'),
    );
    final response = await request.close();
    await response.drain<void>();

    expect(response.statusCode, HttpStatus.notFound);
  });

  test('a saved URL works after replacing the server on the same port',
      () async {
    final settings = ShareSettings.fromMap({});
    await server.stop();
    server = ApkShareServer(currentApk: () => apk, token: settings.token);
    await server.start(port: 0);
    final savedUrl = uri('manifest.json');
    final port = server.port!;
    await server.stop();

    final restored = ShareSettings.fromMap(settings.toMap());
    server = ApkShareServer(currentApk: () => apk, token: restored.token);
    await server.start(port: port);
    final response = await (await client.getUrl(savedUrl)).close();
    final body = await utf8.decoder.bind(response).join();
    expect(response.statusCode, HttpStatus.ok);
    expect((jsonDecode(body) as Map)['fileName'], 'demo app.apk');
  });

  test('reset revokes old links immediately without restarting the service',
      () async {
    final oldUrl = uri('manifest.json');
    server.replaceToken(newShareToken());
    final revoked = await (await client.getUrl(oldUrl)).close();
    await revoked.drain<void>();
    expect(revoked.statusCode, HttpStatus.notFound);

    final current = await (await client.getUrl(uri('manifest.json'))).close();
    await current.drain<void>();
    expect(current.statusCode, HttpStatus.ok);
  });

  test('an empty share stays available while waiting for the first build',
      () async {
    await server.stop();
    server = ApkShareServer(currentApk: () => null);
    await server.start(port: 0);
    final response = await (await client.getUrl(uri('manifest.json'))).close();
    final body = await utf8.decoder.bind(response).join();
    expect(jsonDecode(body), {'available': false});

    final download = await (await client.getUrl(uri('download'))).close();
    await download.drain<void>();
    expect(download.statusCode, HttpStatus.notFound);
  });

  test('a saved page switches to the newly built APK', () async {
    var currentApk = apk;
    await server.stop();
    server = ApkShareServer(currentApk: () => currentApk);
    await server.start(port: 0);
    final savedUrl = uri('manifest.json');
    final next =
        await File('${directory.path}/next.apk').writeAsString('new build');
    final stat = await next.stat();
    currentApk = SharedApk(
      file: next,
      size: stat.size,
      modifiedAt: stat.modified,
      sha256: 'b' * 64,
    );
    final response = await (await client.getUrl(savedUrl)).close();
    final body = await utf8.decoder.bind(response).join();
    expect((jsonDecode(body) as Map)['fileName'], 'next.apk');
    final download = await (await client.getUrl(uri('download'))).close();
    expect(await utf8.decoder.bind(download).join(), 'new build');
  });

  test('returns the current APK manifest', () async {
    final request = await client.getUrl(uri('manifest.json'));
    final response = await request.close();
    final body = await utf8.decoder.bind(response).join();
    final manifest = jsonDecode(body) as Map<String, dynamic>;

    expect(response.statusCode, HttpStatus.ok);
    expect(manifest['fileName'], 'demo app.apk');
    expect(manifest['size'], 64);
    expect(manifest['sha256'], 'a' * 64);
  });

  test('streams a resumable APK download', () async {
    final request = await client.getUrl(uri('download'));
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=10-19');
    final response = await request.close();
    final bytes = await response.fold<List<int>>(
      [],
      (all, chunk) => all..addAll(chunk),
    );

    expect(response.statusCode, HttpStatus.partialContent);
    expect(response.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 10-19/64');
    expect(bytes, List<int>.generate(10, (index) => index + 10));
  });

  Future<SharedApk> anotherApk() async {
    final otherDir = await Directory('${directory.path}/other').create();
    final other =
        await File('${otherDir.path}/demo app.apk').writeAsString('APK B');
    final stat = await other.stat();
    return SharedApk(
        file: other,
        size: stat.size,
        modifiedAt: stat.modified,
        sha256: 'b' * 64);
  }

  test('lists and separately serves same-named APKs without leaking paths',
      () async {
    final b = await anotherApk();
    await server.stop();
    server = ApkShareServer(currentApks: () => [apk, b]);
    await server.start(port: 0);
    final response = await (await client.getUrl(uri('catalog.json'))).close();
    final text = await utf8.decoder.bind(response).join();
    final catalog = jsonDecode(text) as Map;
    final items = catalog['apks'] as List;
    expect(items.length, 2);
    expect(text.contains(directory.path), isFalse);
    expect(items[0]['fileName'], items[1]['fileName']);
    expect(items[0]['id'], isNot(items[1]['id']));
    final bytesA =
        await (await client.getUrl(uri(items[0]['downloadPath'] as String)))
            .close();
    expect(await bytesA.fold<int>(0, (size, chunk) => size + chunk.length), 64);
    final bytesB =
        await (await client.getUrl(uri(items[1]['downloadPath'] as String)))
            .close();
    expect(await utf8.decoder.bind(bytesB).join(), 'APK B');
  });

  test('adding and removing entries preserves the shared entry point',
      () async {
    final b = await anotherApk();
    var apks = [apk];
    await server.stop();
    server = ApkShareServer(currentApks: () => apks);
    await server.start(port: 0);
    final saved = uri('catalog.json');
    final aUrl = uri(apk.toManifest(catalog: true)['downloadPath'] as String);
    apks = [apk, b];
    final listing = await (await client.getUrl(saved)).close();
    expect(
        ((jsonDecode(await utf8.decoder.bind(listing).join()) as Map)['apks']
                as List)
            .length,
        2);
    apks = [b];
    final removed = await (await client.getUrl(aUrl)).close();
    await removed.drain<void>();
    expect(removed.statusCode, HttpStatus.notFound);
    expect(await file.exists(), isTrue);
    final remaining = await (await client
            .getUrl(uri(b.toManifest(catalog: true)['downloadPath'] as String)))
        .close();
    expect(await utf8.decoder.bind(remaining).join(), 'APK B');
  });

  test(
      'pins catalog downloads to the advertised revision instead of another APK',
      () async {
    final b = await anotherApk();
    var current = apk;
    await server.stop();
    server = ApkShareServer(currentApks: () => [current, b]);
    await server.start(port: 0);
    final old = uri(apk.toManifest(catalog: true)['downloadPath'] as String);
    current = SharedApk(
        file: apk.file,
        size: apk.size,
        modifiedAt: apk.modifiedAt,
        sha256: 'c' * 64,
        identifier: apk.id);
    final changed = await (await client.getUrl(old)).close();
    await changed.drain<void>();
    expect(changed.statusCode, HttpStatus.conflict);
    final unknown =
        await (await client.getUrl(uri('apks/${'d' * 64}/download'))).close();
    await unknown.drain<void>();
    expect(unknown.statusCode, HttpStatus.notFound);
  });

  test('empty catalogs and revoked catalog links are safe', () async {
    await server.stop();
    server = ApkShareServer(currentApks: () => []);
    await server.start(port: 0);
    final saved = uri('catalog.json');
    final response = await (await client.getUrl(saved)).close();
    expect(
        (jsonDecode(await utf8.decoder.bind(response).join()) as Map)['apks'],
        isEmpty);
    server.replaceToken(newShareToken());
    final revoked = await (await client.getUrl(saved)).close();
    await revoked.drain<void>();
    expect(revoked.statusCode, HttpStatus.notFound);
  });
}
