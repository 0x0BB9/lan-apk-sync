import 'dart:io';

import 'apk_locator.dart';
import 'apk_monitor.dart';
import 'shared_apk.dart';

class ApkSource {
  const ApkSource(this.path, {required this.isDirectory});

  final String path;
  final bool isDirectory;

  static List<ApkSource> fromSettings(Map<Object?, Object?> values) {
    final sources = values['sources'];
    if (sources is List) {
      return [
        for (final source in sources)
          if (source is Map && source['path'] is String)
            ApkSource(source['path'] as String,
                isDirectory: source['kind'] == 'directory'),
      ];
    }
    final path = values['sourcePath'];
    return path is String
        ? [ApkSource(path, isDirectory: values['sourceKind'] == 'directory')]
        : [];
  }
}

/// Independent stability/hash state per file: adding B never withdraws A.
class ApkCatalog {
  ApkCatalog({required this.sha256, required this.identifier, this.now});

  final Future<String> Function(String) sha256;
  final Future<String> Function(String) identifier;
  final DateTime Function()? now;
  List<ApkSource> sources = [];
  Set<String> excludedPaths = {};
  final Map<String, ApkMonitor> _monitors = {};
  final Map<String, String> _ids = {};
  int _revision = 0;

  bool get hasSource => sources.isNotEmpty;

  bool _included(String path) =>
      !excludedPaths.contains(path) &&
      sources.any((source) =>
          source.path == path ||
          (source.isDirectory && path.startsWith('${source.path}/')));

  List<SharedApk> get apks {
    final result = <SharedApk>[
      for (final entry in _monitors.entries)
        if (_included(entry.key) &&
            entry.value.apk != null &&
            _ids.containsKey(entry.key))
          SharedApk(
            file: entry.value.apk!.file,
            size: entry.value.apk!.size,
            modifiedAt: entry.value.apk!.modifiedAt,
            sha256: entry.value.apk!.sha256,
            identifier: _ids[entry.key],
          ),
    ];
    result.sort((a, b) {
      final byName = a.fileName.compareTo(b.fileName);
      return byName != 0 ? byName : a.id.compareTo(b.id);
    });
    return result;
  }

  void restore(Map<Object?, Object?> values) {
    sources = ApkSource.fromSettings(values);
    excludedPaths =
        (values['excludedPaths'] as List? ?? []).whereType<String>().toSet();
    _revision++;
    _monitors.removeWhere((path, _) => !_included(path));
    _ids.removeWhere((path, _) => !_included(path));
  }

  Future<void> refresh() async {
    final revision = _revision;
    final files = <String, File>{};
    final errors = <Object>[];
    for (final source in List<ApkSource>.of(sources)) {
      try {
        final found = source.isDirectory
            ? await findAllApks(source.path)
            : [File(source.path)];
        for (final file in found) {
          if (_included(file.path)) files[file.path] = file;
        }
      } on Object catch (error) {
        errors.add(error);
      }
      if (revision != _revision) return;
    }
    _monitors.removeWhere((path, _) => !files.containsKey(path));
    _ids.removeWhere((path, _) => !files.containsKey(path));
    for (final path in files.keys) {
      final monitor = _monitors.putIfAbsent(
          path,
          () => ApkMonitor(sha256: sha256, now: now)
            ..select(path, directory: false));
      try {
        final id = _ids[path] ?? await identifier(path);
        if (revision != _revision) return;
        _ids[path] = id;
        await monitor.refresh();
      } on Object catch (error) {
        errors.add(error);
      }
      if (revision != _revision) return;
    }
    if (errors.isNotEmpty) throw StateError('部分 APK 无法读取：${errors.first}');
  }
}
