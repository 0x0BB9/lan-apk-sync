import 'package:flutter_test/flutter_test.dart';
import 'package:lan_apk_sync/main.dart';

void main() {
  testWidgets('shows the local APK sharing workflow', (tester) async {
    await tester.pumpWidget(const LanApkSyncApp());
    await tester.pumpAndSettle();

    expect(find.text('隔离网络内同步 APK'), findsOneWidget);
    expect(find.text('选择 APK'), findsOneWidget);
    expect(find.text('开始同步'), findsOneWidget);
    expect(find.text('3. 手机扫码下载'), findsOneWidget);
  });
}
