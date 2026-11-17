import 'dart:io';

import 'apk_locator.dart';
import 'shared_apk.dart';

/// Publishes an APK only after its size and modification time have settled.
class ApkMonitor {
  ApkMonitor({
    required this.sha256,
    DateTime Function()? now,
    this.settleDuration = const Duration(seconds: 2),
  }) : _now = now ?? DateTime.now;

  final Future<String> Function(String path) sha256;
  final DateTime Function() _now;
  final Duration settleDuration;
  String? sourcePath;
  bool isDirectory = false;
  SharedApk? apk;
  _Candidate? _candidate;
  DateTime? _stableSince;
  int _revision = 0;

  bool get hasSource => sourcePath != null;

  void select(String path, {required bool directory}) {
    sourcePath = path;
    isDirectory = directory;
    apk = null;
    _candidate = null;
    _stableSince = null;
    _revision++;
  }

  Future<void> refresh() async {
    final revision = _revision;
    final path = sourcePath;
    if (path == null) return;
    try {
      final file = isDirectory ? await findNewestApk(path) : File(path);
      if (revision != _revision) return;
      if (file == null || !await file.exists()) {
        if (revision == _revision) {
          apk = null;
          _candidate = null;
          _stableSince = null;
        }
        return;
      }
      final before = await file.stat();
      if (revision != _revision) return;
      final candidate = _Candidate(file.path, before.size, before.modified);
      if (candidate != _candidate) {
        apk = null;
        _candidate = candidate;
        _stableSince = _now();
        return;
      }
      if (apk != null ||
          before.size == 0 ||
          _now().difference(_stableSince!) < settleDuration) {
        return;
      }
      final digest = await sha256(file.path);
      final after = await file.stat();
      if (revision != _revision) return;
      if (before.size != after.size || before.modified != after.modified) {
        _candidate = null;
        _stableSince = null;
        return;
      }
      apk = SharedApk(
        file: file,
        size: after.size,
        modifiedAt: after.modified,
        sha256: digest,
      );
    } on Object {
      if (revision == _revision) {
        apk = null;
        _candidate = null;
        _stableSince = null;
        rethrow;
      }
    }
  }
}

class _Candidate {
  const _Candidate(this.path, this.size, this.modified);

  final String path;
  final int size;
  final DateTime modified;

  @override
  bool operator ==(Object other) =>
      other is _Candidate &&
      other.path == path &&
      other.size == size &&
      other.modified == modified;

  @override
  int get hashCode => Object.hash(path, size, modified);
}
