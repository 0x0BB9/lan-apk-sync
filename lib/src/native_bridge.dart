import 'package:flutter/services.dart';

import 'share_settings.dart';

class NativeBridge {
  static const _channel = MethodChannel(
    'io.github.0x0bb9.lan_apk_sync/native',
  );

  Future<String?> pickApk() => _channel.invokeMethod<String>('pickApk');

  Future<List<String>> pickApks() async =>
      await _channel.invokeListMethod<String>('pickApks') ?? [];

  Future<Map<Object?, Object?>> removeSource(String path,
          {bool apk = false}) async =>
      await _channel.invokeMapMethod<Object?, Object?>(
          apk ? 'removeApk' : 'removeSource', {'path': path}) ??
      {};

  Future<String> pathId(String path) async {
    final value = await _channel.invokeMethod<String>('pathId', {'path': path});
    if (value == null || !RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
      throw StateError('无法生成 APK 标识。');
    }
    return value;
  }

  Future<String?> pickDirectory() =>
      _channel.invokeMethod<String>('pickDirectory');

  Future<Map<Object?, Object?>> loadSettings() async =>
      await _channel.invokeMapMethod<Object?, Object?>('loadSettings') ?? {};

  Future<void> saveSettings(ShareSettings settings) =>
      _channel.invokeMethod<void>('saveSettings', settings.toMap());

  Future<String> sha256(String path) async {
    final value = await _channel.invokeMethod<String>(
      'sha256',
      {'path': path},
    );
    if (value == null || value.length != 64) {
      throw StateError('无法计算 APK 的 SHA-256。');
    }
    return value;
  }

  Future<Uint8List> qrCode(String value) async {
    final bytes = await _channel.invokeMethod<Uint8List>(
      'qrCode',
      {'value': value},
    );
    if (bytes == null || bytes.isEmpty) {
      throw StateError('无法生成二维码。');
    }
    return bytes;
  }
}
