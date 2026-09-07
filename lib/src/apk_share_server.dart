import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'shared_apk.dart';

class DownloadEvent {
  const DownloadEvent({
    required this.fileName,
    required this.remoteAddress,
    required this.completedAt,
  });

  final String fileName;
  final String remoteAddress;
  final DateTime completedAt;
}

class ApkShareServer {
  ApkShareServer({
    required SharedApk? Function() currentApk,
    void Function(DownloadEvent event)? onDownload,
  })  : _currentApk = currentApk,
        _onDownload = onDownload;

  final SharedApk? Function() _currentApk;
  final void Function(DownloadEvent event)? _onDownload;
  final String token = _newToken();
  HttpServer? _server;

  bool get isRunning => _server != null;
  int? get port => _server?.port;

  Future<void> start({int port = 8787}) async {
    if (_server != null) return;
    final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _server = server;
    unawaited(_listen(server));
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  String urlFor(String address) => 'http://$address:${port ?? 8787}/$token/';

  Future<void> _listen(HttpServer server) async {
    try {
      await for (final request in server) {
        unawaited(_handle(request));
      }
    } on Object {
      // Closing the server interrupts the request stream.
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    response.headers
      ..set(HttpHeaders.cacheControlHeader, 'no-store')
      ..set('X-Content-Type-Options', 'nosniff');

    try {
      if (request.method != 'GET' && request.method != 'HEAD') {
        response.statusCode = HttpStatus.methodNotAllowed;
        response.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
        return;
      }

      final base = '/$token';
      final path = request.uri.path;
      if (path == base || path == '$base/') {
        await _writeText(
          response,
          _landingPage(),
          'text/html; charset=utf-8',
          headOnly: request.method == 'HEAD',
        );
      } else if (path == '$base/manifest.json') {
        final apk = _currentApk();
        final body = jsonEncode(apk?.toManifest() ?? {'available': false});
        await _writeText(
          response,
          body,
          'application/json; charset=utf-8',
          headOnly: request.method == 'HEAD',
        );
      } else if (path == '$base/download') {
        await _serveApk(request);
      } else {
        response.statusCode = HttpStatus.notFound;
        await _writeText(
          response,
          'Not found',
          'text/plain; charset=utf-8',
          headOnly: request.method == 'HEAD',
        );
      }
    } on FileSystemException {
      _trySetStatus(response, HttpStatus.conflict);
    } on Object {
      _trySetStatus(response, HttpStatus.internalServerError);
    } finally {
      try {
        await response.close();
      } on Object {
        // The client may disconnect during a large APK transfer.
      }
    }
  }

  Future<void> _serveApk(HttpRequest request) async {
    final apk = _currentApk();
    if (apk == null || !await apk.file.exists()) {
      request.response.statusCode = HttpStatus.notFound;
      await _writeText(
        request.response,
        'No APK is ready.',
        'text/plain; charset=utf-8',
        headOnly: request.method == 'HEAD',
      );
      return;
    }

    final stat = await apk.file.stat();
    if (stat.size != apk.size || stat.modified != apk.modifiedAt) {
      request.response.statusCode = HttpStatus.conflict;
      await _writeText(
        request.response,
        'The APK is still being updated. Please retry.',
        'text/plain; charset=utf-8',
        headOnly: request.method == 'HEAD',
      );
      return;
    }

    final response = request.response;
    final range = _parseRange(
      request.headers.value(HttpHeaders.rangeHeader),
      apk.size,
    );
    if (range == _invalidRange) {
      response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      response.headers
          .set(HttpHeaders.contentRangeHeader, 'bytes */${apk.size}');
      return;
    }

    final start = range?.start ?? 0;
    final end = range?.end ?? apk.size - 1;
    final length = end - start + 1;
    if (range != null) {
      response.statusCode = HttpStatus.partialContent;
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/${apk.size}',
      );
    }

    response.headers
      ..set(
        HttpHeaders.contentTypeHeader,
        'application/vnd.android.package-archive',
      )
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..set(HttpHeaders.contentLengthHeader, '$length')
      ..set(
        'Content-Disposition',
        "attachment; filename*=UTF-8''${Uri.encodeComponent(apk.fileName)}",
      );

    if (request.method == 'HEAD') return;
    await response.addStream(apk.file.openRead(start, end + 1));
    _onDownload?.call(
      DownloadEvent(
        fileName: apk.fileName,
        remoteAddress: request.connectionInfo?.remoteAddress.address ?? '未知设备',
        completedAt: DateTime.now(),
      ),
    );
  }

  Future<void> _writeText(
    HttpResponse response,
    String value,
    String contentType, {
    required bool headOnly,
  }) async {
    final bytes = utf8.encode(value);
    response.headers
      ..set(HttpHeaders.contentTypeHeader, contentType)
      ..set(HttpHeaders.contentLengthHeader, '${bytes.length}');
    if (!headOnly) response.add(bytes);
  }

  void _trySetStatus(HttpResponse response, int status) {
    try {
      response.statusCode = status;
    } on StateError {
      // A streaming response may already have sent its headers.
    }
  }

  _ByteRange? _parseRange(String? value, int size) {
    if (value == null) return null;
    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(value.trim());
    if (match == null || size <= 0) return _invalidRange;

    final startText = match.group(1)!;
    final endText = match.group(2)!;
    if (startText.isEmpty && endText.isEmpty) return _invalidRange;

    int start;
    int end;
    if (startText.isEmpty) {
      final suffix = int.tryParse(endText);
      if (suffix == null || suffix <= 0) return _invalidRange;
      start = max(0, size - suffix);
      end = size - 1;
    } else {
      start = int.tryParse(startText) ?? -1;
      end = endText.isEmpty ? size - 1 : int.tryParse(endText) ?? -1;
    }
    if (start < 0 || start >= size || end < start) return _invalidRange;
    return _ByteRange(start, min(end, size - 1));
  }

  String _landingPage() => r'''<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>LAN APK Sync</title>
  <style>
    :root { color-scheme: light; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    body { margin: 0; background: #eff6ff; color: #0f172a; }
    main { max-width: 560px; margin: 0 auto; padding: 32px 20px 48px; }
    .hero { background: linear-gradient(135deg,#1d4ed8,#0ea5e9); color: white; border-radius: 24px; padding: 28px; box-shadow: 0 18px 48px #1d4ed833; }
    h1 { margin: 0 0 8px; font-size: 28px; }
    .hero p { margin: 0; opacity: .9; }
    .card { margin-top: 18px; background: white; border-radius: 20px; padding: 22px; box-shadow: 0 10px 30px #0f172a12; }
    .label { color: #64748b; font-size: 13px; }
    .name { margin-top: 6px; font-size: 18px; font-weight: 700; overflow-wrap: anywhere; }
    .meta { margin-top: 8px; color: #475569; }
    .hash { margin-top: 14px; padding: 12px; border-radius: 12px; background: #f8fafc; font: 12px ui-monospace, monospace; overflow-wrap: anywhere; }
    a { display: block; margin-top: 18px; padding: 15px 18px; border-radius: 14px; background: #2563eb; color: white; text-align: center; text-decoration: none; font-weight: 700; }
    a.disabled { pointer-events: none; background: #94a3b8; }
    ol { margin: 12px 0 0; padding-left: 22px; color: #475569; line-height: 1.8; }
    #state { margin-top: 10px; color: #64748b; }
  </style>
</head>
<body>
<main>
  <section class="hero"><h1>LAN APK Sync</h1><p>APK 直接来自同一 Wi‑Fi 内的 Mac，不经过外网。</p></section>
  <section class="card">
    <div class="label">当前可下载版本</div>
    <div id="name" class="name">正在读取…</div>
    <div id="meta" class="meta"></div>
    <div id="hash" class="hash" hidden></div>
    <a id="download" class="disabled">等待 APK</a>
    <div id="state">页面会自动检测 Mac 上的新构建。</div>
  </section>
  <section class="card">
    <div class="name">安装步骤</div>
    <ol><li>点击下载 APK。</li><li>下载完成后打开文件。</li><li>按 Android 系统提示确认安装或更新。</li></ol>
  </section>
</main>
<script>
const base = location.pathname.endsWith('/') ? location.pathname : location.pathname + '/';
let lastSha = '';
async function refresh() {
  try {
    const response = await fetch(base + 'manifest.json', {cache: 'no-store'});
    const data = await response.json();
    if (!data.available) throw new Error('Mac 暂未准备 APK');
    document.querySelector('#name').textContent = data.fileName;
    document.querySelector('#meta').textContent = data.sizeLabel + ' · ' + new Date(data.modifiedAt).toLocaleString();
    const hash = document.querySelector('#hash');
    hash.hidden = false;
    hash.textContent = 'SHA-256  ' + data.sha256;
    const button = document.querySelector('#download');
    button.href = base + data.downloadPath;
    button.classList.remove('disabled');
    button.textContent = '下载 APK';
    document.querySelector('#state').textContent = lastSha && lastSha !== data.sha256 ? '检测到新构建，可以重新下载。' : '已连接到 Mac。';
    lastSha = data.sha256;
  } catch (error) {
    document.querySelector('#state').textContent = error.message || '暂时无法连接 Mac。';
  }
}
refresh();
setInterval(refresh, 2500);
</script>
</body>
</html>''';
}

class _ByteRange {
  const _ByteRange(this.start, this.end);

  final int start;
  final int end;
}

const _invalidRange = _ByteRange(-1, -1);

String _newToken() {
  final random = Random.secure();
  final bytes = List<int>.generate(18, (_) => random.nextInt(256));
  return base64UrlEncode(bytes).replaceAll('=', '');
}
