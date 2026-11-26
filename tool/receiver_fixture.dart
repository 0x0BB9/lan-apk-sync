// Development-only fixture for the Android emulator integration test.
// Usage: dart run tool/receiver_fixture.dart <test-apk-path> <sha256>
import 'dart:io';
import 'package:lan_apk_sync/src/apk_share_server.dart';
import 'package:lan_apk_sync/src/shared_apk.dart';

Future<void> main(List<String> args) async {
  if (args.length != 2 || !RegExp(r'^[a-f0-9]{64}$').hasMatch(args[1])) {
    throw ArgumentError('Expected a test APK path and SHA-256.');
  }
  final file = File(args[0]);
  final stat = await file.stat();
  final apk = SharedApk(
    file: file,
    size: stat.size,
    modifiedAt: stat.modified,
    sha256: args[1],
  );
  final server = ApkShareServer(
    currentApk: () => apk,
    token: '0123456789abcdefghijklmn',
  );
  await server.start(port: 18787);
  stdout.writeln('Test fixture ready on port 18787. Stop after emulator checks.');
  ProcessSignal.sigint.watch().listen((_) async {
    await server.stop();
    exit(0);
  });
}
