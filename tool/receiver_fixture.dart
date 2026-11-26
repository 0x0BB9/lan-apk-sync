// Development-only fixture for the Android emulator integration test.
// Usage: dart run tool/receiver_fixture.dart <test-apk-path> <sha256> [<second-apk> <sha256>]
import 'dart:io';
import 'package:lan_apk_sync/src/apk_share_server.dart';
import 'package:lan_apk_sync/src/shared_apk.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.length.isOdd || args.length > 4) {
    throw ArgumentError('Expected a test APK path and SHA-256.');
  }
  final apks = <SharedApk>[];
  for (var index = 0; index < args.length; index += 2) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(args[index + 1])) {
      throw ArgumentError('Invalid SHA-256.');
    }
    final file = File(args[index]);
    final stat = await file.stat();
    apks.add(SharedApk(
        file: file,
        size: stat.size,
        modifiedAt: stat.modified,
        sha256: args[index + 1],
        identifier: (index == 0 ? 'a' : 'b') * 64));
  }
  final server = ApkShareServer(
    currentApks: () => apks,
    token: '0123456789abcdefghijklmn',
  );
  await server.start(port: 18787);
  stdout
      .writeln('Test fixture ready on port 18787. Stop after emulator checks.');
  ProcessSignal.sigint.watch().listen((_) async {
    await server.stop();
    exit(0);
  });
}
