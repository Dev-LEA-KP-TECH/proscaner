import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/obd/pids.dart';
import '../state/live_poller.dart';
import '../state/providers.dart';
import 'theme.dart';
import 'widgets/gauges.dart';

/// กราฟเต็มจอของค่าสดหนึ่งรายการ พร้อมค่าต่ำสุด/สูงสุด/เฉลี่ย
class PidChartScreen extends ConsumerStatefulWidget {
  const PidChartScreen({super.key, required this.pid});

  final int pid;

  @override
  ConsumerState<PidChartScreen> createState() => _PidChartScreenState();
}

class _PidChartScreenState extends ConsumerState<PidChartScreen> {
  late final LivePoller _poller;
  late final Object _key = Object();

  @override
  void initState() {
    super.initState();
    _poller = ref.read(livePollerProvider);
    // อ่านเฉพาะค่านี้ให้ถี่ที่สุดขณะเปิดกราฟ
    _poller.subscribe(_key, [widget.pid], priority: true);
  }

  @override
  void dispose() {
    _poller.unsubscribe(_key);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pid = widget.pid;
    final def = pidTable[pid]!;
    final live = ref.watch(liveDataProvider);
    final settings = ref.watch(settingsProvider);
    final cs = Theme.of(context).colorScheme;
    final series = (live.series[pid] ?? const <double>[]).map((v) => displayPid(def, v, settings).value).toList();
    final latest = live.latest[pid];
    final dv = latest == null ? null : displayPid(def, latest, settings);

    String f(double v) => v.toStringAsFixed(def.decimals);
    final minV = series.isEmpty ? null : series.reduce(math.min);
    final maxV = series.isEmpty ? null : series.reduce(math.max);
    final avg = series.isEmpty ? null : series.reduce((a, b) => a + b) / series.length;

    return Scaffold(
      appBar: AppBar(title: FitText(def.nameTh)),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
        PremiumCard(
          glow: cs.primary,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('ค่าปัจจุบัน', style: TextStyle(color: cs.onSurfaceVariant)),
            const SizedBox(height: 4),
            Text.rich(TextSpan(children: [
              TextSpan(
                text: dv?.text ?? '—',
                style: const TextStyle(fontSize: 44, fontWeight: FontWeight.w900, height: 1.1),
              ),
              TextSpan(text: '  ${dv?.unit ?? def.unit}', style: TextStyle(fontSize: 16, color: cs.onSurfaceVariant)),
            ])),
            const SizedBox(height: 18),
            Sparkline(values: series, color: cs.primary, height: 220, showAxis: true, decimals: def.decimals),
            const SizedBox(height: 6),
            Text('ย้อนหลัง ${series.length}\u00A0ค่าล่าสุด', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          ]),
        ),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(child: _Stat(label: 'ต่ำสุด', value: minV == null ? '—' : f(minV))),
          const SizedBox(width: 10),
          Expanded(child: _Stat(label: 'เฉลี่ย', value: avg == null ? '—' : f(avg))),
          const SizedBox(width: 10),
          Expanded(child: _Stat(label: 'สูงสุด', value: maxV == null ? '—' : f(maxV))),
        ]),
        const SizedBox(height: 14),
        PremiumCard(
          child: Row(children: [
            Icon(Icons.memory_rounded, color: cs.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'PID 01${pid.toRadixString(16).padLeft(2, '0').toUpperCase()}\u00A0· ${def.bytes}\u00A0ไบต์'
                '${def.min != null ? '\u00A0· ช่วง\u00A0${def.min} ถึง ${def.max} ${def.unit}' : ''}',
                style: TextStyle(color: cs.onSurfaceVariant),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return PremiumCard(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
      child: Column(children: [
        Text(label, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
        const SizedBox(height: 4),
        Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
      ]),
    );
  }
}
