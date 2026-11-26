import 'dart:io';

class SharedApk {
  const SharedApk({
    required this.file,
    required this.size,
    required this.modifiedAt,
    required this.sha256,
    this.identifier,
  });

  final File file;
  final int size;
  final DateTime modifiedAt;
  final String sha256;
  final String? identifier;

  String get id => identifier ?? sha256;

  String get fileName => file.uri.pathSegments.last;

  Map<String, Object> toManifest({bool catalog = false}) => {
        'id': id,
        'available': true,
        'fileName': fileName,
        'size': size,
        'sizeLabel': formatBytes(size),
        'modifiedAt': modifiedAt.toUtc().toIso8601String(),
        'sha256': sha256,
        'downloadPath':
            catalog ? 'apks/$id/download?sha256=$sha256' : 'download',
      };
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kib = bytes / 1024;
  if (kib < 1024) return '${kib.toStringAsFixed(1)} KB';
  final mib = kib / 1024;
  if (mib < 1024) return '${mib.toStringAsFixed(1)} MB';
  return '${(mib / 1024).toStringAsFixed(2)} GB';
}
