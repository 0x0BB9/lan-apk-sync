import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lan_apk_sync/src/apk_share_server.dart';
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

  test('protects routes with an unguessable session token', () async {
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:${server.port}/manifest.json'),
    );
    final response = await request.close();
    await response.drain<void>();

    expect(response.statusCode, HttpStatus.notFound);
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
}
