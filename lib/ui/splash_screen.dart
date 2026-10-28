import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_info.dart';
import '../state/providers.dart';
import 'home_screen.dart';
import 'orientation.dart';
import 'theme.dart';
import 'widgets/common.dart';

export '../core/app_info.dart' show kAppVersion;

enum _St { wait, busy, done, fail }

class _Step {
  _Step(this.label);
  final String label;
  _St st = _St.wait;
  String meta = '';
}

/// หน้าโหลดก่อนเข้าแอป: โลโก้และชื่อ ProScaner (และชื่อ/โลโก้อู่ถ้าตั้งไว้)
/// พร้อมรายการที่กำลังเตรียมจริง แล้วเข้าหน้าหลักเอง
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key, this.minDuration = const Duration(milliseconds: 1400)});

  /// เวลาขั้นต่ำที่แสดง (ไม่ให้กระพริบผ่านเร็วเกินไปบนเครื่องแรง)
  final Duration minDuration;

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  final _steps = [
    _Step('โหลดการตั้งค่า'),
    _Step('ฐานข้อมูลรหัสภาษาไทย'),
    _Step('ข้อมูลโรงรถ'),
    _Step('ประวัติการสแกน'),
    _Step('ตรวจ Bluetooth'),
  ];

  @override
  void initState() {
    super.initState();
    unawaited(_boot());
  }

  bool _orientationSet = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // การหมุนจอปกติของแอป (iPhone ใช้แนวตั้ง ที่เหลือหมุนตามเครื่อง) ตั้งครั้งเดียวตอนเปิดแอป
    if (!_orientationSet) {
      _orientationSet = true;
      unawaited(applyAppOrientation(iPhone: isIPhone(context)));
    }
  }

  Future<void> _run(int i, Future<String> Function() work) async {
    if (!mounted) return;
    setState(() => _steps[i].st = _St.busy);
    String meta;
    var ok = true;
    try {
      meta = await work().timeout(const Duration(seconds: 4));
    } catch (_) {
      meta = '—';
      ok = false;
    }
    if (!mounted) return;
    setState(() {
      _steps[i]
        ..st = ok ? _St.done : _St.fail
        ..meta = meta;
    });
  }

  Future<void> _boot() async {
    final sw = Stopwatch()..start();
    await _run(0, () async {
      ref.read(settingsProvider);
      ref.read(appModeProvider);
      return 'OK';
    });
    await _run(1, () async => '${(await ref.read(dtcDatabaseProvider.future)).length}');
    await _run(2, () async => '${(await ref.read(garageProvider.future)).length} คัน');
    await _run(3, () async => '${(await ref.read(historyProvider.future)).length} ครั้ง');
    await _run(4, () async {
      if (!(Platform.isAndroid || Platform.isIOS)) return 'ไม่มี';
      // iOS: แค่ถามสถานะ Bluetooth ระบบก็ขึ้นหน้าต่างขอสิทธิ์ทันที จึงไม่ถามตอนเปิดแอป
      // ให้ขอสิทธิ์ตอนเข้าหน้าเชื่อมต่อแทน ผู้ใช้จะเข้าใจว่าขอไปใช้ทำอะไร (ตามแนวทางของ Apple)
      if (Platform.isIOS) return 'ตอนเชื่อมต่อ';
      if (!await FlutterBluePlus.isSupported) return 'ไม่รองรับ';
      final s = await FlutterBluePlus.adapterState
          .where((s) => s != BluetoothAdapterState.unknown)
          .first
          .timeout(const Duration(seconds: 2), onTimeout: () => BluetoothAdapterState.unknown);
      return switch (s) {
        BluetoothAdapterState.on => 'เปิด',
        BluetoothAdapterState.off => 'ปิดอยู่',
        _ => 'ไม่ทราบ',
      };
    });
    final left = widget.minDuration - sw.elapsed;
    if (left > Duration.zero) {
      // ใช้ Timer ที่ยกเลิกได้ ถ้าปิดหน้านี้ก่อนครบเวลาจะไม่ค้าง
      _wait = Timer(left, _goHome);
    } else {
      _goHome();
    }
  }

  Timer? _wait;

  @override
  void dispose() {
    _wait?.cancel();
    super.dispose();
  }

  void _goHome() {
    if (!mounted) return;
    unawaited(Navigator.of(context).pushReplacement(PageRouteBuilder<void>(
      transitionDuration: const Duration(milliseconds: 450),
      pageBuilder: (_, __, ___) => const HomeScreen(),
      transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
    )));
  }

  @override
  Widget build(BuildContext context) {
    // หน้าโหลดใช้ธีมมืดเสมอ ให้โลโก้ (ตัวอักษรโครเมียม) เด่นและต่อเนื่องกับหน้าจอตอนเปิดแอป
    final accent = ref.watch(settingsProvider.select((s) => s.accent));
    final shop = ref.watch(settingsProvider.select((s) => s.shop));
    return Theme(
      data: buildTheme(accent, Brightness.dark, fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily ?? kFont),
      child: Builder(builder: (context) => _body(context, shop)),
    );
  }

  Widget _body(BuildContext context, ShopProfile shop) {
    final cs = Theme.of(context).colorScheme;
    final done = _steps.where((s) => s.st == _St.done || s.st == _St.fail).length;
    final progress = done / _steps.length;
    final logo = shop.logoPath;
    final hasLogo = logo != null && File(logo).existsSync();

    return Scaffold(
      backgroundColor: Carbon.bg,
      body: SafeArea(
        // จอเตี้ย (มือถือแนวนอน) หรือตัวอักษรใหญ่: ย่อทั้งหน้าลงให้พอดีจอ ไม่ล้น ไม่ถูกตัด
        child: LayoutBuilder(
          builder: (context, box) => Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: SizedBox(
                width: math.min(440.0, box.maxWidth),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                // โลโก้และชื่อแอป ProScaner (ไฟล์เดียวกับไอคอนแอป)
                const Center(child: BrandMark(size: 104)),
                const SizedBox(height: 20),
                Center(
                  child: Image.asset('assets/brand/wordmark.png',
                      width: 230, filterQuality: FilterQuality.high, semanticLabel: 'ProScaner'),
                ),
                const SizedBox(height: 6),
                Text('กำลังเริ่มระบบ', textAlign: TextAlign.center, style: TextStyle(fontSize: 13.5, color: cs.onSurfaceVariant)),
                if (shop.name.isNotEmpty || hasLogo) ...[
                  const SizedBox(height: 14),
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    if (hasLogo)
                      Container(
                        width: 34,
                        height: 34,
                        margin: const EdgeInsets.only(right: 10),
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(9)),
                        child: Image.file(File(logo), fit: BoxFit.contain),
                      ),
                    Flexible(
                      child: Text(
                        shop.name.isEmpty ? 'อู่ของคุณ' : 'ให้บริการโดย ${shop.name}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: cs.onSurfaceVariant),
                      ),
                    ),
                  ]),
                ],
                const SizedBox(height: 28),
                PremiumCard(
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
                  radius: 20,
                  child: Column(children: [
                    for (final s in _steps) _StepRow(step: s, accent: cs.primary),
                  ]),
                ),
                const SizedBox(height: 32),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(end: progress),
                    duration: const Duration(milliseconds: 300),
                    builder: (_, v, __) => LinearProgressIndicator(
                      value: v,
                      minHeight: 6,
                      color: cs.primary,
                      backgroundColor: Carbon.cardHigh,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(children: [
                  Text(progress >= 1 ? 'พร้อมใช้งาน' : 'เตรียมพร้อม',
                      style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                  const Spacer(),
                  Text('${(progress * 100).round()}%',
                      style: TextStyle(fontSize: 12, fontFamily: kMono, color: cs.onSurfaceVariant)),
                ]),
                const SizedBox(height: 40),
                Text('v$kAppVersion',
                    textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant.withValues(alpha: 0.7))),
              ]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({required this.step, required this.accent});

  final _Step step;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final Widget icon = switch (step.st) {
      _St.done => const Icon(Icons.check_circle_rounded, size: 22, color: StatusColors.good),
      _St.fail => const Icon(Icons.error_rounded, size: 22, color: StatusColors.warn),
      _St.busy => SizedBox(
          width: 22,
          height: 22,
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: CircularProgressIndicator(strokeWidth: 2.6, color: accent, backgroundColor: cs.outline),
          ),
        ),
      _St.wait => Icon(Icons.radio_button_unchecked_rounded, size: 22, color: cs.outline),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(children: [
        icon,
        const SizedBox(width: 12),
        Expanded(
          child: Text(step.label,
              style: TextStyle(fontSize: 15, color: step.st == _St.wait ? cs.onSurfaceVariant : cs.onSurface)),
        ),
        Text(step.meta,
            style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()])),
      ]),
    );
  }
}
