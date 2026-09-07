import 'dart:io';

Future<File?> findNewestApk(String directoryPath) async {
  final directory = Directory(directoryPath);
  if (!await directory.exists()) return null;

  File? newest;
  DateTime? newestModified;
  await for (final entity in directory.list(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is! File || !entity.path.toLowerCase().endsWith('.apk')) {
      continue;
    }
    final stat = await entity.stat();
    if (newestModified == null || stat.modified.isAfter(newestModified)) {
      newest = entity;
      newestModified = stat.modified;
    }
  }
  return newest;
}
