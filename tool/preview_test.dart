// Local preview of the real HomePage with sanitized preferences and no sharing.
// Run on macOS: flutter test --no-pub tool/preview_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_apk_sync/main.dart';
import 'package:lan_apk_sync/src/home_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders the fixed-entry workflow for visual inspection',
      (tester) async {
    const channel = MethodChannel('io.github.0x0bb9.lan_apk_sync/native');
    tester.view.physicalSize = const Size(1200, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'loadSettings') {
        return {'token': 'a' * 24, 'port': 8787, 'autoStart': true};
      }
      if (call.method == 'saveSettings') return null;
      throw PlatformException(code: 'unexpected_preview_method');
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));

    await tester.runAsync(() async {
      final bytes = await File(
        '/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
      ).readAsBytes();
      await (FontLoader('PreviewCJK')
            ..addFont(Future.value(ByteData.sublistView(bytes))))
          .load();
      await (FontLoader('MaterialIcons')
            ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
          .load();
    });
    final app = const LanApkSyncApp().build(tester.element(find.byType(View)))
        as MaterialApp;
    final theme = app.theme!;
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
      key: boundaryKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme.copyWith(
          textTheme: theme.textTheme.apply(fontFamily: 'PreviewCJK'),
          primaryTextTheme:
              theme.primaryTextTheme.apply(fontFamily: 'PreviewCJK'),
        ),
        home: HomePage(loadNetworkInterfaces: () async => []),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('3. 手机固定入口'), findsOneWidget);
    final boundary = boundaryKey.currentContext!.findRenderObject()!
        as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final picture = await boundary.toImage();
      final png = (await picture.toByteData(format: ui.ImageByteFormat.png))!;
      await Directory('dist').create(recursive: true);
      await File('dist/fixed-entry-preview.png').writeAsBytes(
        png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
      );
      picture.dispose();
    });
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
