import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_apk_sync/src/home_page.dart';

void main() {
  const channel = MethodChannel('io.github.0x0bb9.lan_apk_sync/native');
  TestWidgetsFlutterBinding.ensureInitialized();
  late Map<String, Object> saved;

  setUp(() {
    saved = {'token': 'a' * 24, 'port': 8888, 'autoStart': false};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'loadSettings':
          return saved;
        case 'saveSettings':
          saved = {
            ...saved,
            ...Map<String, Object>.from(call.arguments as Map),
          };
          return null;
        default:
          throw PlatformException(code: 'unexpected_method');
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> showHome(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: HomePage(loadNetworkInterfaces: () async => []),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('shows the local APK sharing workflow', (tester) async {
    await showHome(tester);

    expect(find.text('隔离网络内同步 APK'), findsOneWidget);
    expect(find.text('选择 APK'), findsOneWidget);
    expect(find.text('开始同步'), findsOneWidget);
    expect(find.text('3. 手机固定入口'), findsOneWidget);
    expect(find.text('8888'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('retains the token and persists the auto start preference',
      (tester) async {
    await showHome(tester);
    expect(saved['token'], 'a' * 24);
    final toggle = find.byType(SwitchListTile);
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(saved['autoStart'], isTrue);
    expect(saved['token'], 'a' * 24);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('requires confirmation before replacing the saved link',
      (tester) async {
    await showHome(tester);
    final reset = find.text('重置分享链接');
    await tester.ensureVisible(reset);
    await tester.tap(reset);
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(saved['token'], 'a' * 24);

    await tester.tap(reset);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认重置'));
    await tester.pumpAndSettle();
    expect(saved['token'], isNot('a' * 24));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
