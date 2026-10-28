import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/elm/elm327.dart';
import '../../core/obd/pids.dart';
import '../../core/transport/demo_transport.dart';
import '../../state/live_poller.dart';
import '../../state/providers.dart';
import '../home_screen.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// ผลการจับเวลาหนึ่งรอบ (วินาที)
class PerfRun {
  PerfRun({required this.time});

  final DateTime time;
  double? t60;
  double? t100;
  double? quarter; // 402 ม.
  double? quarterSpeed;
  double maxSpeed = 0;
  double hz = 0;

  double? get t60to100 => t60 != null && t100 != null ? t100! - t60! : null;
}

/// คำนวณผลจากชุดตัวอย่าง (เวลา วินาที, ความเร็ว กม./ชม.) — แยกออกมาเพื่อทดสอบได้
class PerfCalculator {
  PerfCalculator();

  final samples = <(double, double)>[];
  double? startT;
  double _dist = 0; // เมตร
  PerfRun? run;

  /// เพิ่มตัวอย่าง คืน true เมื่อจับเวลาครบแล้ว
  bool add(double t, double v, DateTime now) {
    final prev = samples.isEmpty ? null : samples.last;
    samples.add((t, v));
    if (startT == null) {
      if (prev != null && prev.$2 < 0.5 && v >= 0.5) {
        // ออกตัวระหว่างตัวอย่างก่อนหน้ากับตัวนี้ ใช้จุดกึ่งกลาง
        startT = prev.$1 + (t - prev.$1) / 2;
        run = PerfRun(time: now);
        _dist = v / 3.6 * (t - startT!) / 2;
      }
      return false;
    }
    final r = run!;
    final p = prev!;
    final dt = t - p.$1;
    final segStart = _dist;
    _dist += (p.$2 + v) / 2 / 3.6 * dt;
    if (v > r.maxSpeed) r.maxSpeed = v;

    double cross(double target) {
      final f = (target - p.$2) / (v - p.$2);
      return p.$1 + dt * f.clamp(0, 1) - startT!;
    }

    if (r.t60 == null && p.$2 < 60 && v >= 60) r.t60 = cross(60);
    if (r.t100 == null && p.$2 < 100 && v >= 100) r.t100 = cross(100);
    if (r.quarter == null && _dist >= 402.3) {
      final f = (_dist - segStart) == 0 ? 1.0 : (402.3 - segStart) / (_dist - segStart);
      r.quarter = p.$1 + dt * f.clamp(0, 1) - startT!;
      r.quarterSpeed = p.$2 + (v - p.$2) * f.clamp(0, 1);
    }
    final elapsed = t - startT!;
    final done = (r.t100 != null && r.quarter != null) ||
        elapsed > 45 ||
        (r.maxSpeed > 20 && v < r.maxSpeed - 15); // ถอนคันเร่ง/เบรกแล้ว
    if (done) {
      final n = samples.where((s) => s.$1 >= startT!).length;
      r.hz = elapsed > 0 ? n / elapsed : 0;
    }
    return done;
  }

  double get distanceM => _dist;
}

class PerformanceScreen extends ConsumerStatefulWidget {
  const PerformanceScreen({super.key});

  @override
  ConsumerState<PerformanceScreen> createState() => _PerformanceScreenState();
}

enum _Phase { idle, armed, running }

class _PerformanceScreenState extends ConsumerState<PerformanceScreen> {
  static const _pollKey = 'performance';
  late final LivePoller _poller;
  bool _active = true;
  _Phase _phase = _Phase.idle;
  double? _speed;
  double _hz = 0;
  PerfCalculator? _calc;
  final _sw = Stopwatch();
  final _runs = <PerfRun>[];
  String? _error;

  @override
  void initState() {
    super.initState();
    _poller = ref.read(livePollerProvider);
    _poller.subscribe(_pollKey, const <int>[], priority: true);
    unawaited(_loop());
  }

  @override
  void dispose() {
    _active = false;
    _poller.unsubscribe(_pollKey);
    super.dispose();
  }

  Future<void> _loop() async {
    final rate = Stopwatch()..start();
    var count = 0;
    while (_active && mounted) {
      final service = ref.read(sessionProvider).service;
      if (service == null) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        continue;
      }
      try {
        final v = await service.readPid(Pid.speed);
        if (!mounted) return;
        count++;
        if (rate.elapsedMilliseconds > 1000) {
          _hz = count * 1000 / rate.elapsedMilliseconds;
          count = 0;
          rate.reset();
        }
        if (v != null) _onSample(v);
        setState(() => _error = null);
      } catch (e) {
        if (mounted) setState(() => _error = e is ElmException ? e.message : e.toString());
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      // ช่วงพักสั้นมาก ให้ได้อัตราสุ่มสูงสุดที่ตัวสแกนทำได้
      if (_phase == _Phase.idle) await Future<void>.delayed(const Duration(milliseconds: 120));
    }
  }

  void _onSample(double v) {
    _speed = v;
    final calc = _calc;
    if (calc == null || _phase == _Phase.idle) return;
    final t = _sw.elapsedMicroseconds / 1e6;
    final done = calc.add(t, v, DateTime.now());
    if (_phase == _Phase.armed && calc.startT != null) {
      _phase = _Phase.running;
      unawaited(HapticFeedback.mediumImpact().catchError((Object _) {}));
    }
    if (done) {
      _runs.insert(0, calc.run!);
      _phase = _Phase.idle;
      _calc = null;
      unawaited(HapticFeedback.heavyImpact().catchError((Object _) {}));
    }
  }

  void _arm() {
    if ((_speed ?? 0) > 0.5) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('จอดรถให้นิ่งก่อน แล้วกดเตรียมพร้อม')));
      return;
    }
    _sw
      ..reset()
      ..start();
    setState(() {
      _calc = PerfCalculator();
      _phase = _Phase.armed;
    });
  }

  void _cancel() => setState(() {
        _calc = null;
        _phase = _Phase.idle;
      });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final settings = ref.watch(settingsProvider);
    final transport = ref.watch(sessionProvider.select((s) => s.transport));
    final demo = transport is DemoTransport ? transport : null;
    final speedDef = pidTable[Pid.speed]!;
    final dv = _speed == null ? null : displayPid(speedDef, _speed!, settings);
    final calc = _calc;
    final elapsed = calc?.startT == null ? 0.0 : _sw.elapsedMicroseconds / 1e6 - calc!.startT!;
    final statusColor = switch (_phase) {
      _Phase.idle => cs.onSurfaceVariant,
      _Phase.armed => StatusColors.warn,
      _Phase.running => StatusColors.good,
    };
    final best100 = _runs.map((r) => r.t100).whereType<double>().fold<double?>(null, (a, b) => a == null || b < a ? b : a);

    return Scaffold(
      appBar: AppBar(title: const FitText('จับเวลาอัตราเร่ง')),
      body: NeedsConnection(
        message: 'เชื่อมต่อรถเพื่อจับเวลา',
        builder: (context, service) => ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
          PremiumCard(
            glow: statusColor,
            child: Column(children: [
              Text(
                switch (_phase) {
                  _Phase.idle => 'กดเตรียมพร้อมเมื่อจอดนิ่ง',
                  _Phase.armed => 'พร้อม! ออกตัวได้เลย',
                  _Phase.running => 'กำลังจับเวลา',
                },
                style: TextStyle(fontWeight: FontWeight.w800, color: statusColor, fontSize: 16),
              ),
              const SizedBox(height: 6),
              Text(dv?.text ?? '—',
                  style: const TextStyle(fontSize: 80, fontWeight: FontWeight.w800, height: 1.05, fontFeatures: [FontFeature.tabularFigures()])),
              Text(dv?.unit ?? speedDef.unit, style: TextStyle(color: cs.onSurfaceVariant)),
              const SizedBox(height: 8),
              Text(
                _phase == _Phase.running ? '${elapsed.toStringAsFixed(1)}\u00A0วินาที\u00A0· ${calc!.distanceM.round()}\u00A0ม.' : ' ',
                style: const TextStyle(fontFamily: kMono, fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 14),
              Row(children: [
                Expanded(
                  child: _phase == _Phase.idle
                      ? FilledButton.icon(
                          icon: const Icon(Icons.flag_rounded),
                          label: const Text('เตรียมพร้อม'),
                          onPressed: _arm,
                        )
                      : OutlinedButton.icon(
                          icon: const Icon(Icons.close_rounded),
                          label: const Text('ยกเลิก'),
                          onPressed: _cancel,
                        ),
                ),
                if (demo != null && _phase == _Phase.armed) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      icon: const Icon(Icons.rocket_launch_rounded),
                      label: const Text('จำลองออกตัว'),
                      onPressed: demo.startDrive,
                    ),
                  ),
                ],
              ]),
              const SizedBox(height: 10),
              Text('อัตราอ่านค่า ${_hz.toStringAsFixed(1)}\u00A0ครั้ง/วินาที${_error != null ? '\u00A0· $_error' : ''}',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            ]),
          ),
          if (_runs.isNotEmpty) ...[
            SectionLabel('ผลล่าสุด', trailing: best100 == null ? null : Pill(text: 'ดีที่สุด 0–100: ${best100.toStringAsFixed(2)}\u00A0วิ', color: cs.primary)),
            _RunCard(run: _runs.first, highlight: true),
            if (_runs.length > 1) ...[
              const SectionLabel('รอบก่อนหน้า'),
              for (final r in _runs.skip(1))
                Padding(padding: const EdgeInsets.only(bottom: 8), child: _RunCard(run: r)),
            ],
          ],
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: StatusColors.warn.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: StatusColors.warn.withValues(alpha: 0.4)),
            ),
            child: Text(
              'ทดสอบในสนามหรือพื้นที่ปิดเท่านั้น ห้ามทดสอบบนถนนสาธารณะ ความแม่นยำขึ้นกับความเร็วตัวสแกน '
              '(ตัวสแกนทั่วไป ±0.2–0.3\u00A0วินาที) และความเร็วจาก ECU อาจคลาดจากจริงเล็กน้อยตามขนาดยาง',
              style: TextStyle(fontSize: 12, height: 1.5, color: cs.onSurface),
            ),
          ),
        ]),
      ),
    );
  }
}

class _RunCard extends StatelessWidget {
  const _RunCard({required this.run, this.highlight = false});

  final PerfRun run;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    String f(double? v) => v == null ? '—' : v.toStringAsFixed(2);
    // ช่องละ 1 ใน 4 ของความกว้าง: ชื่อ ตัวเลข และหน่วยอยู่บรรทัดเดียวเสมอ (ช่องแคบย่อตัวอักษรลง)
    Widget tile(String label, String value, String unit) => Expanded(
          child: Column(children: [
            FitText(label, alignment: Alignment.center, style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant)),
            const SizedBox(height: 2),
            FitText(value,
                alignment: Alignment.center, style: TextStyle(fontSize: highlight ? 24 : 18, fontWeight: FontWeight.w800)),
            FitText(unit, alignment: Alignment.center, style: TextStyle(fontSize: 10.5, color: cs.onSurfaceVariant)),
          ]),
        );
    return PremiumCard(
      glow: highlight ? cs.primary : null,
      padding: const EdgeInsets.fromLTRB(10, 14, 10, 12),
      radius: 18,
      child: Column(children: [
        Row(children: [
          tile('0–60', f(run.t60), 'วินาที'),
          tile('0–100', f(run.t100), 'วินาที'),
          tile('60–100', f(run.t60to100), 'วินาที'),
          tile('402\u00A0ม.', f(run.quarter), run.quarterSpeed == null ? 'วินาที' : '@ ${run.quarterSpeed!.round()}\u00A0กม./ชม.'),
        ]),
        const SizedBox(height: 8),
        Text('${thaiDate(run.time)}\u00A0· สูงสุด ${run.maxSpeed.round()}\u00A0กม./ชม.\u00A0· ${run.hz.toStringAsFixed(1)}\u00A0Hz',
            style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant)),
      ]),
    );
  }
}
