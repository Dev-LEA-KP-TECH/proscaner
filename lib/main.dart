import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'data/demo_cleanup.dart';
import 'state/settings.dart';
import 'ui/splash_screen.dart';
import 'ui/theme.dart';

/// แอปเริ่มทำงานสำเร็จแล้ว หลังจากนี้ error ที่หลุดมาจะไม่แทนที่หน้าจอทั้งแอป
bool _started = false;

void main() {
  runZonedGuarded(_start, (error, stack) {
    debugPrint('ProScaner: uncaught $error\n$stack');
    if (!_started) runApp(StartupErrorApp(error: error, stack: stack));
  });
}

Future<void> _start() async {
  WidgetsFlutterBinding.ensureInitialized();
  // ในแอปจริงหน้าจอที่พังจะเป็นกล่องสีเทา แสดงข้อความแทน จะได้แคปหน้าจอส่งมาแก้ได้
  ErrorWidget.builder = (details) => _ErrorPanel(text: details.exceptionAsString());
  // วาดหน้าเริ่มทันที ไม่ปล่อยจอดำระหว่างโหลดข้อมูล
  runApp(const BootScreen());
  final SharedPreferences prefs;
  try {
    prefs = await SharedPreferences.getInstance().timeout(const Duration(seconds: 10));
  } catch (e, st) {
    debugPrint('ProScaner: SharedPreferences failed $e\n$st');
    runApp(StartupErrorApp(error: e, stack: st));
    return;
  }
  // ล้างรถจำลองที่แอปรุ่นก่อนบันทึกลงโรงรถ (ทำครั้งเดียว ไม่ให้ค้างตอนเปิดแอป)
  try {
    await removeOldDemoData(prefs).timeout(const Duration(seconds: 5));
  } catch (_) {
    // ไม่สำคัญพอจะหยุดแอป
  }
  _started = true;
  runApp(ProviderScope(
    overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
    child: const ObdDoctorApp(),
  ));
}

class ObdDoctorApp extends ConsumerWidget {
  const ObdDoctorApp({super.key, this.fontFamily = kFont});

  /// ฟอนต์หลักของแอป (Prompt ฝังมากับแอป อ่านภาษาไทยชัดทุกเครื่อง)
  final String fontFamily;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    return MaterialApp(
      title: 'ProScaner',
      debugShowCheckedModeBanner: false,
      themeMode: s.themeMode,
      theme: buildTheme(s.accent, Brightness.light, fontFamily: fontFamily),
      darkTheme: buildTheme(s.accent, Brightness.dark, fontFamily: fontFamily),
      // ตัวอักษรใหญ่ตามที่ตั้งในเครื่องได้ แต่ไม่เกิน kMaxTextScale เพื่อให้ทุกหน้าแสดงครบ ไม่ล้น ไม่ถูกตัด
      builder: (context, child) => MediaQuery.withClampedTextScaling(
        maxScaleFactor: kMaxTextScale,
        child: child ?? const SizedBox.shrink(),
      ),
      home: const SplashScreen(),
    );
  }
}

/// หน้าแรกระหว่างเริ่มแอป (ไม่ต้องพึ่งข้อมูลหรือปลั๊กอินใดๆ)
class BootScreen extends StatelessWidget {
  const BootScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: Color(0xFF07090C),
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ClipRRect(
              borderRadius: BorderRadius.all(Radius.circular(22)),
              child: Image(image: AssetImage('assets/brand/app_icon.png'), width: 96, height: 96),
            ),
            SizedBox(height: 18),
            Text(
              'กำลังเริ่ม ProScaner…',
              style: TextStyle(color: Color(0xFFE9EDF2), fontFamily: kFont, fontSize: 16, decoration: TextDecoration.none),
            ),
          ]),
        ),
      ),
    );
  }
}

/// แสดงเมื่อแอปเริ่มไม่สำเร็จ แทนจอดำ
class StartupErrorApp extends StatelessWidget {
  const StartupErrorApp({super.key, required this.error, this.stack});

  final Object error;
  final StackTrace? stack;

  @override
  Widget build(BuildContext context) {
    final lines = (stack?.toString() ?? '').split('\n').where((l) => l.trim().isNotEmpty).take(10).join('\n');
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: Brightness.dark, fontFamily: kFont),
      home: Scaffold(
        body: SafeArea(
          child: ListView(padding: const EdgeInsets.all(20), children: [
            const Text('ProScaner เปิดไม่สำเร็จ', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text(thaiKeep('แคปหน้าจอนี้ส่งให้ผู้พัฒนา จะแก้ได้ตรงจุด')),
            const SizedBox(height: 16),
            SelectableText('$error', style: const TextStyle(color: Color(0xFFFF6B73))),
            const SizedBox(height: 12),
            SelectableText(lines, style: const TextStyle(fontFamily: kMono, fontSize: 11)),
            const SizedBox(height: 20),
            FilledButton(onPressed: _start, child: const Text('ลองใหม่')),
          ]),
        ),
      ),
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF2A0D10),
      padding: const EdgeInsets.all(8),
      child: Text(
        'ส่วนนี้แสดงไม่ได้: $text',
        textDirection: TextDirection.ltr,
        style: const TextStyle(color: Color(0xFFFF8A92), fontSize: 12, decoration: TextDecoration.none),
      ),
    );
  }
}
