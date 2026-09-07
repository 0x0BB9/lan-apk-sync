import 'package:flutter/material.dart';

import 'src/home_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LanApkSyncApp());
}

class LanApkSyncApp extends StatelessWidget {
  const LanApkSyncApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF2563EB);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'LAN APK Sync',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: seed,
          brightness: Brightness.light,
          surface: const Color(0xFFF8FAFC),
        ),
        scaffoldBackgroundColor: const Color(0xFFF1F5F9),
        cardTheme: const CardTheme(elevation: 0, margin: EdgeInsets.zero),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          isDense: true,
        ),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}
