import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/analysis/odometer_check.dart' show CheckLevel;
import '../../core/elm/elm327.dart';
import '../../core/obd/pids.dart';
import '../../core/transport/demo_transport.dart';
import '../../state/live_poller.dart';
import '../../state/providers.dart';
import '../home_screen.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/gauges.dart';

/// ประเมินเปอร์เซ็นต์ประจุแบตตะกั่วกรดจากแรงดันพัก (เครื่องดับ)
int batterySoc(double v) {
  const table = [(11.9, 0.0), (12.06, 25.0), (12.24, 50.0), (12.45, 75.0), (12.65, 100.0)];
  if (v <= table.first.$1) return 0;
  if (v >= table.last.$1) return 100;
  for (var i = 1; i < table.length; i++) {
    final (v1, p1) = table[i];
    final (v0, p0) = table[i - 1];
    if (v <= v1) return (p0 + (v - v0) / (v1 - v0) * (p1 - p0)).round();
  }
  return 100;
}

class BatteryResult {
  const BatteryResult(this.level, this.value, this.title, this.detail);
  final CheckLevel level;
  final double value;
  final String title;
  final String detail;
}

BatteryResult judgeRest(double v) {
  final soc = batterySoc(v);
  if (v >= 12.4) return BatteryResult(CheckLevel.ok, v, 'แบตเตอรี่ประจุเต็ม ($soc%)', 'แรงดันพักปกติ 12.4–12.8 V');
  if (v >= 12.2) {
    return BatteryResult(CheckLevel.warn, v, 'ประจุต่ำ ($soc%)', 'ควรขับต่อเนื่อง 30 นาที หรือชาร์จ แล้ววัดใหม่');
  }
  return BatteryResult(CheckLevel.bad, v, 'แบตเตอรี่อ่อน ($soc%)', 'ชาร์จเต็มแล้ววัดใหม่ ถ้ายังต่ำกว่า 12.2 V ควรเปลี่ยนแบตเตอรี่');
}

BatteryResult judgeCrank(double minV) {
  if (minV >= 9.6) return BatteryResult(CheckLevel.ok, minV, 'สตาร์ทผ่าน', 'แรงดันต่ำสุด ${minV.toStringAsFixed(2)} V (ควรไม่ต่ำกว่า 9.6 V)');
  if (minV >= 9.0) {
    return BatteryResult(CheckLevel.warn, minV, 'แบตเริ่มเสื่อม', 'แรงดันตกถึง ${minV.toStringAsFixed(2)} V ตอนสตาร์ท ควรเตรียมเปลี่ยนแบต');
  }
  return BatteryResult(CheckLevel.bad, minV, 'แบตเสื่อม / ไดสตาร์ทกินไฟ',
      'แรงดันตกถึง ${minV.toStringAsFixed(2)} V อาจสตาร์ทไม่ติดในวันที่อากาศเย็นหรือจอดนาน');
}

BatteryResult judgeCharge(double v, {required bool loaded}) {
  final low = loaded ? 13.2 : 13.6;
  if (v > 15.0) {
    return BatteryResult(CheckLevel.bad, v, 'ไฟชาร์จสูงเกิน', 'คัทเอาท์/เร็กกูเลเตอร์อาจเสีย ทำให้แบตบวมและอุปกรณ์ไฟฟ้าเสียหาย');
  }
  if (v >= low) {
    return BatteryResult(CheckLevel.ok, v, loaded ? 'ชาร์จพอขณะมีโหลด' : 'ระบบชาร์จปกติ',
        loaded ? 'ไดชาร์จจ่ายไฟพอเมื่อเปิดไฟหน้า แอร์ และพัดลม' : 'ปกติ 13.6–14.8 V');
  }
  if (v >= 12.8) {
    return BatteryResult(CheckLevel.warn, v, 'ไฟชาร์จค่อนข้างต่ำ',
        'รถรุ่นใหม่ที่มีระบบชาร์จอัจฉริยะอาจชาร์จต่ำได้ ถ้าเป็นรถรุ่นเก่า ให้ตรวจไดชาร์จและสายพาน');
  }
  return BatteryResult(CheckLevel.bad, v, 'ไดชาร์จไม่ชาร์จ', 'แรงดันไม่สูงกว่าแบต ตรวจไดชาร์จ สายพาน ฟิวส์ และขั้วสายไฟ');
}

enum _Test {
  rest('1. แรงดันตอนดับเครื่อง', 'ดับเครื่อง เปิดกุญแจ ON (ไม่สตาร์ท) ปิดไฟทุกอย่าง รอ 1 นาทีแล้วกดวัด', Icons.battery_std_rounded),
  crank('2. ทดสอบตอนสตาร์ท', 'กดเริ่ม แล้วสตาร์ทเครื่องภายใน 10 วินาที', Icons.power_settings_new_rounded),
  idle('3. ระบบชาร์จ (เดินเบา)', 'ติดเครื่องเดินเบา ปิดแอร์และไฟทั้งหมด แล้วกดวัด', Icons.electric_bolt_rounded),
  load('4. ชาร์จขณะมีโหลด', 'เปิดไฟหน้า แอร์ พัดลมแรงสุด ไล่ฝ้าหลัง เร่งรอบค้างราว 1,500 รอบ แล้วกดวัด', Icons.flash_on_rounded);

  const _Test(this.title, this.howTo, this.icon);
  final String title;
  final String howTo;
  final IconData icon;
}

class BatteryScreen extends ConsumerStatefulWidget {
  const BatteryScreen({super.key});

  @override
  ConsumerState<BatteryScreen> createState() => _BatteryScreenState();
}

class _BatteryScreenState extends ConsumerState<BatteryScreen> {
  static const _pollKey = 'battery';
  final _results = <_Test, BatteryResult>{};
  final _series = <double>[];
  double? _volt;
  double? _rpm;
  _Test? _running;
  String? _note;
  bool _active = true;
  late final LivePoller _poller;

  @override
  void initState() {
    super.initState();
    _poller = ref.read(livePollerProvider);
    // หยุดตัวอ่านค่าสดตัวอื่นชั่วคราว เพื่อให้วัดแรงดันได้ถี่ที่สุด
    _poller.subscribe(_pollKey, const <int>[], priority: true);
    unawaited(_monitor());
  }

  @override
  void dispose() {
    _active = false;
    _poller.unsubscribe(_pollKey);
    super.dispose();
  }

  Elm327? get _elm => ref.read(sessionProvider).elm;
  DemoTransport? get _demo {
    final t = ref.read(sessionProvider).transport;
    return t is DemoTransport ? t : null;
  }

  void _push(double v) {
    _series.add(v);
    if (_series.length > 120) _series.removeAt(0);
  }

  Future<void> _monitor() async {
    var tick = 0;
    while (_active && mounted) {
      final elm = _elm;
      if (elm == null || _running != null) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        continue;
      }
      try {
        final service = ref.read(sessionProvider).service;
        final v = await elm.readVoltage();
        if (tick++ % 3 == 0) {
          _rpm = await service?.readPid(Pid.rpm);
        }
        if (!mounted) return;
        setState(() {
          _volt = v;
          if (v != null) _push(v);
        });
      } catch (_) {
        // แสดงค่าเดิมไว้ (เช่น ตัวสแกนไม่ตอบชั่วคราว)
      }
      await Future<void>.delayed(const Duration(milliseconds: 350));
    }
  }

  Future<double?> _average(Duration d) async {
    final elm = _elm;
    if (elm == null) return null;
    final values = <double>[];
    final end = DateTime.now().add(d);
    while (DateTime.now().isBefore(end) && mounted) {
      final v = await elm.readVoltage();
      if (!mounted) return null;
      if (v != null) {
        values.add(v);
        setState(() {
          _volt = v;
          _push(v);
        });
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    if (values.isEmpty) return null;
    return values.reduce((a, b) => a + b) / values.length;
  }

  Future<void> _run(_Test t) async {
    final elm = _elm;
    final service = ref.read(sessionProvider).service;
    if (elm == null || service == null) return;
    setState(() {
      _running = t;
      _note = null;
    });
    final demo = _demo;
    try {
      switch (t) {
        case _Test.rest:
          demo?.engineOff();
          final rpm = await service.readPid(Pid.rpm);
          if (rpm != null && rpm > 300) {
            _note = 'เครื่องยังติดอยู่ ดับเครื่องก่อนแล้ววัดใหม่';
            break;
          }
          final v = await _average(const Duration(seconds: 3));
          if (v != null) _results[t] = judgeRest(v);
        case _Test.crank:
          demo?.engineOff();
          if (demo != null) {
            Future<void>.delayed(const Duration(milliseconds: 1800), demo.crank);
          }
          var minV = double.infinity;
          var started = false;
          final end = DateTime.now().add(const Duration(seconds: 10));
          var dipAt = DateTime.now();
          while (DateTime.now().isBefore(end) && mounted) {
            final v = await elm.readVoltage();
            if (!mounted) return;
            if (v != null) {
              if (v < minV) {
                minV = v;
                dipAt = DateTime.now();
              }
              setState(() {
                _volt = v;
                _push(v);
              });
              // แรงดันกลับขึ้นเกิน 13 V หลังตก = เครื่องติดแล้ว
              if (minV < 11.5 && v > 13.0 && DateTime.now().difference(dipAt).inMilliseconds > 300) {
                started = true;
                break;
              }
            }
          }
          if (minV == double.infinity || minV > 11.8) {
            _note = 'ไม่พบการสตาร์ท ลองใหม่และสตาร์ทหลังกดเริ่มทันที';
          } else {
            _results[t] = judgeCrank(minV);
            if (!started) _note = 'แรงดันไม่กลับขึ้นเกิน 13 V หลังสตาร์ท ตรวจระบบชาร์จในขั้นถัดไป';
          }
        case _Test.idle:
          demo?.setLoads(false);
          final rpm = await service.readPid(Pid.rpm);
          if (rpm != null && rpm < 400) {
            _note = 'เครื่องยังไม่ติด ติดเครื่องก่อนแล้ววัดใหม่';
            break;
          }
          final v = await _average(const Duration(seconds: 5));
          if (v != null) _results[t] = judgeCharge(v, loaded: false);
        case _Test.load:
          demo?.setLoads(true);
          final rpm = await service.readPid(Pid.rpm);
          if (rpm != null && rpm < 400) {
            _note = 'เครื่องยังไม่ติด ติดเครื่องก่อนแล้ววัดใหม่';
            break;
          }
          final v = await _average(const Duration(seconds: 6));
          demo?.setLoads(false);
          if (v != null) _results[t] = judgeCharge(v, loaded: true);
      }
    } on ElmException catch (e) {
      _note = 'อ่านแรงดันไม่ได้: ${e.message}';
    } catch (e) {
      _note = 'ทดสอบไม่สำเร็จ: $e';
    } finally {
      if (mounted) setState(() => _running = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('ทดสอบแบตเตอรี่และไดชาร์จ')),
      body: NeedsConnection(
        message: 'เชื่อมต่อรถเพื่อทดสอบแบตเตอรี่',
        builder: (context, service) {
          final v = _volt;
          final color = v == null
              ? cs.primary
              : (v < 12.0 || v > 15.0)
                  ? StatusColors.bad
                  : (v < 12.4 ? StatusColors.warn : StatusColors.good);
          return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
            PremiumCard(
              glow: color,
              child: Column(children: [
                Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text(v == null ? '—' : v.toStringAsFixed(2),
                      style: TextStyle(fontSize: 54, fontWeight: FontWeight.w800, color: color, height: 1)),
                  const SizedBox(width: 6),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text('V', style: TextStyle(fontSize: 20, color: cs.onSurfaceVariant)),
                  ),
                  const Spacer(),
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text(_rpm == null ? 'รอบเครื่อง —' : (_rpm! > 300 ? 'เครื่องติด' : 'เครื่องดับ'),
                        style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5)),
                    if (v != null && (_rpm ?? 0) < 300)
                      Text('ประจุ ~${batterySoc(v)}%', style: const TextStyle(fontWeight: FontWeight.w700)),
                  ]),
                ]),
                const SizedBox(height: 12),
                Sparkline(values: List.of(_series), color: color, height: 54, decimals: 1),
              ]),
            ),
            if (_note != null) ...[
              const SizedBox(height: 10),
              Pill(text: _note!, color: StatusColors.warn, icon: Icons.info_rounded),
            ],
            const SectionLabel('ขั้นตอนทดสอบ'),
            for (final t in _Test.values)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _TestCard(
                  test: t,
                  result: _results[t],
                  running: _running == t,
                  enabled: _running == null,
                  onRun: () => _run(t),
                ),
              ),
            if (_results.length == _Test.values.length) _Summary(results: _results.values.toList()),
            const SizedBox(height: 10),
            Text(
              'วัดผ่านขา 16 ของช่อง OBD ค่าอาจต่ำกว่าวัดที่ขั้วแบตจริง 0.1–0.3 V เกณฑ์นี้ใช้กับแบตตะกั่วกรด 12 V',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant, height: 1.45),
            ),
          ]);
        },
      ),
    );
  }
}

class _TestCard extends StatelessWidget {
  const _TestCard({required this.test, required this.result, required this.running, required this.enabled, required this.onRun});

  final _Test test;
  final BatteryResult? result;
  final bool running;
  final bool enabled;
  final VoidCallback onRun;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final r = result;
    return PremiumCard(
      glow: r?.level.color,
      padding: const EdgeInsets.all(14),
      radius: 18,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(test.icon, color: r?.level.color ?? cs.primary),
          const SizedBox(width: 10),
          Expanded(child: Text(test.title, style: const TextStyle(fontWeight: FontWeight.w700))),
          if (r != null) Text('${r.value.toStringAsFixed(2)} V', style: TextStyle(fontWeight: FontWeight.w800, color: r.level.color)),
        ]),
        const SizedBox(height: 6),
        Text(test.howTo, style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant, height: 1.4)),
        if (r != null) CheckRow(level: r.level, title: r.title, detail: r.detail),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.tonalIcon(
            icon: running
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(r == null ? Icons.play_arrow_rounded : Icons.replay_rounded),
            label: Text(running ? (test == _Test.crank ? 'สตาร์ทเครื่องเลย…' : 'กำลังวัด…') : (r == null ? 'เริ่ม' : 'วัดใหม่')),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 42)),
            onPressed: enabled ? onRun : null,
          ),
        ),
      ]),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.results});

  final List<BatteryResult> results;

  @override
  Widget build(BuildContext context) {
    final worst = results.map((r) => r.level).reduce((a, b) {
      int rank(CheckLevel l) => switch (l) {
            CheckLevel.bad => 3,
            CheckLevel.warn => 2,
            CheckLevel.info => 1,
            CheckLevel.ok => 0,
          };
      return rank(a) >= rank(b) ? a : b;
    });
    final text = switch (worst) {
      CheckLevel.ok => 'แบตเตอรี่และระบบชาร์จปกติดี',
      CheckLevel.warn => 'มีจุดที่ควรเฝ้าดู',
      CheckLevel.bad => 'ควรแก้ไขก่อนรถสตาร์ทไม่ติด',
      CheckLevel.info => 'ทดสอบครบแล้ว',
    };
    return PremiumCard(
      glow: worst.color,
      child: Row(children: [
        Icon(worst.icon, color: worst.color, size: 32),
        const SizedBox(width: 12),
        Expanded(child: Text(text, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: worst.color))),
        Text('${math.max(0, results.where((r) => r.level == CheckLevel.ok).length)}/${results.length} ผ่าน'),
      ]),
    );
  }
}
