import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/obd/pids.dart';
import '../../data/log_store.dart';
import '../../report/pdf_report.dart';
import '../../state/live_poller.dart';
import '../../state/providers.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/time_chart.dart';

/// ชุด PID สำเร็จรูปสำหรับการบันทึก
const recordPresets = <(String, List<int>)>[
  ('พื้นฐานเครื่องยนต์', [Pid.rpm, Pid.speed, Pid.coolantTemp, Pid.engineLoad, Pid.throttle, Pid.moduleVoltage]),
  ('ส่วนผสม / ปรับจูน', [Pid.rpm, Pid.engineLoad, Pid.stftB1, Pid.ltftB1, Pid.maf, Pid.map, Pid.intakeTemp, Pid.timingAdvance]),
  ('ดีเซล / เทอร์โบ', [Pid.rpm, Pid.speed, Pid.engineLoad, Pid.map, Pid.boost, Pid.fuelRailPressure, Pid.fuelRailAbs, Pid.egtB1]),
  ('ความร้อน', [Pid.rpm, Pid.speed, Pid.coolantTemp, Pid.oilTemp, Pid.intakeTemp, Pid.ambientTemp]),
];

const chartColors = [
  Color(0xFFFF4D5A),
  Color(0xFF3DA5FF),
  Color(0xFF22C474),
  Color(0xFFFFA824),
  Color(0xFFA06BFF),
  Color(0xFF2BD9D9),
];

/// เลือกค่าที่จะบันทึก แล้วเริ่มบันทึก
Future<void> showStartRecording(BuildContext context, WidgetRef ref) async {
  final service = ref.read(sessionProvider).service;
  if (service == null) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('เชื่อมต่อรถก่อนเริ่มบันทึก')));
    return;
  }
  final selected = <int>{...recordPresets.first.$2.where(service.supports)};
  final pids = await showModalBottomSheet<List<int>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (c) => StatefulBuilder(builder: (c, setSheet) {
      final all = pidTable.values.where((d) => d.live && service.supports(d.pid)).toList();
      return DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        builder: (c, scroll) => ListView(
            controller: scroll, padding: EdgeInsets.fromLTRB(16, 0, 16, 24 + MediaQuery.paddingOf(c).bottom), children: [
          const Text('เลือกค่าที่จะบันทึก', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
          const SizedBox(height: 4),
          Text('ยิ่งเลือกน้อย ยิ่งบันทึกได้ถี่ (ตัวสแกนทั่วไปอ่านได้ ~10–20\u00A0ค่า/วินาที)',
              style: TextStyle(fontSize: 12.5, color: Theme.of(c).colorScheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final (name, list) in recordPresets)
              ActionChip(
                avatar: const Icon(Icons.auto_awesome_rounded, size: 16),
                label: FitText(name),
                onPressed: () => setSheet(() {
                  selected
                    ..clear()
                    ..addAll(list.where(service.supports));
                }),
              ),
          ]),
          const Divider(height: 28),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final d in all)
              FilterChip(
                label: FitText(d.nameTh),
                selected: selected.contains(d.pid),
                onSelected: (v) => setSheet(() => v ? selected.add(d.pid) : selected.remove(d.pid)),
              ),
          ]),
          const SizedBox(height: 18),
          FilledButton.icon(
            icon: const Icon(Icons.fiber_manual_record_rounded),
            label: Text('เริ่มบันทึก ${selected.length}\u00A0ค่า'),
            onPressed: selected.isEmpty ? null : () => Navigator.pop(c, selected.toList()),
          ),
        ]),
      );
    }),
  );
  if (pids == null || pids.isEmpty) return;
  ref.read(recorderProvider.notifier).start(pids);
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('เริ่มบันทึกแล้ว ใช้แอปหน้าอื่นได้ตามปกติ กดหยุดที่แถบด้านบน')),
    );
  }
}

Future<void> shareLogCsv(BuildContext context, DriveLog log) async {
  final dir = await getTemporaryDirectory();
  final safe = log.name.replaceAll(RegExp(r'[^\w฀-๿\- ]'), '_');
  final f = File('${dir.path}/$safe.csv');
  // ใส่ BOM ให้ Excel อ่านภาษาไทยถูก
  await f.writeAsString('﻿${log.toCsv()}', flush: true);
  if (context.mounted) await shareFile(context, f.path, mime: 'text/csv', subject: log.name);
}

class LogsScreen extends ConsumerStatefulWidget {
  const LogsScreen({super.key});

  @override
  ConsumerState<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends ConsumerState<LogsScreen> {
  final _selected = <String>{};

  @override
  Widget build(BuildContext context) {
    final logs = ref.watch(logsProvider);
    final rec = ref.watch(recorderProvider);
    final connected = ref.watch(sessionProvider.select((s) => s.isConnected));
    final cs = Theme.of(context).colorScheme;
    final items = logs.valueOrNull ?? const <DriveLog>[];

    return Scaffold(
      appBar: AppBar(
        title: FitText(_selected.isEmpty ? 'บันทึกการขับ' : 'เลือกแล้ว ${_selected.length}'),
        actions: [
          if (_selected.length == 2)
            TextButton.icon(
              icon: const Icon(Icons.compare_arrows_rounded),
              label: const Text('เปรียบเทียบ'),
              onPressed: () {
                final pair = items.where((l) => _selected.contains(l.id)).toList();
                Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => CompareLogsScreen(a: pair[0], b: pair[1]),
                ));
              },
            ),
          if (_selected.isNotEmpty)
            IconButton(
              tooltip: 'ยกเลิกการเลือก',
              icon: const Icon(Icons.close_rounded),
              onPressed: () => setState(_selected.clear),
            ),
        ],
      ),
      floatingActionButton: rec.recording || !connected
          ? null
          : FloatingActionButton.extended(
              icon: const Icon(Icons.fiber_manual_record_rounded),
              label: const Text('บันทึกใหม่'),
              onPressed: () => showStartRecording(context, ref),
            ),
      body: logs.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('อ่านบันทึกไม่ได้: $e')),
        data: (items) {
          if (items.isEmpty) {
            return EmptyState(
              icon: Icons.timeline_rounded,
              title: 'ยังไม่มีบันทึก',
              text: 'บันทึกค่าเซ็นเซอร์ขณะขับ เพื่อดูกราฟย้อนหลัง ส่งออกเป็น CSV\nหรือเทียบก่อน-หลังซ่อม/จูน',
              action: connected
                  ? FilledButton.icon(
                      icon: const Icon(Icons.fiber_manual_record_rounded),
                      label: const Text('เริ่มบันทึก'),
                      onPressed: () => showStartRecording(context, ref),
                    )
                  : null,
            );
          }
          return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 96), children: [
            Text('แตะค้างเพื่อเลือก 2\u00A0รายการแล้วเปรียบเทียบ (เช่น ก่อน-หลังซ่อม)',
                style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant)),
            const SizedBox(height: 10),
            for (final log in items)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _LogTile(
                  log: log,
                  selected: _selected.contains(log.id),
                  onTap: () {
                    if (_selected.isNotEmpty) {
                      setState(() => _selected.contains(log.id) ? _selected.remove(log.id) : _selected.add(log.id));
                    } else {
                      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => LogViewScreen(log: log)));
                    }
                  },
                  onLongPress: () => setState(() {
                    if (_selected.contains(log.id)) {
                      _selected.remove(log.id);
                    } else if (_selected.length < 2) {
                      _selected.add(log.id);
                    }
                  }),
                ),
              ),
          ]);
        },
      ),
    );
  }
}

class _LogTile extends StatelessWidget {
  const _LogTile({required this.log, required this.selected, required this.onTap, required this.onLongPress});

  final DriveLog log;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final d = log.durationS;
    final dur = d < 60 ? '${d.round()}\u00A0วินาที' : '${(d / 60).floor()}\u00A0นาที ${(d % 60).round()}\u00A0วินาที';
    return GestureDetector(
      onLongPress: onLongPress,
      child: PremiumCard(
        glow: selected ? cs.primary : null,
        onTap: onTap,
        padding: const EdgeInsets.all(14),
        radius: 18,
        child: Row(children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: cs.primary.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(12)),
            child: Icon(selected ? Icons.check_rounded : Icons.show_chart_rounded, color: cs.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(log.name, style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text('${thaiDate(log.start)}\u00A0· $dur\u00A0· ${log.pids.length}\u00A0ค่า\u00A0· ${log.rows.length}\u00A0แถว',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            ]),
          ),
          Icon(Icons.chevron_right_rounded, color: cs.onSurfaceVariant),
        ]),
      ),
    );
  }
}

(double, double, double)? _stats(List<(double, double)> pts) {
  if (pts.isEmpty) return null;
  var lo = double.infinity, hi = -double.infinity, sum = 0.0;
  for (final p in pts) {
    lo = math.min(lo, p.$2);
    hi = math.max(hi, p.$2);
    sum += p.$2;
  }
  return (lo, sum / pts.length, hi);
}

class LogViewScreen extends ConsumerStatefulWidget {
  const LogViewScreen({super.key, required this.log});

  final DriveLog log;

  @override
  ConsumerState<LogViewScreen> createState() => _LogViewScreenState();
}

class _LogViewScreenState extends ConsumerState<LogViewScreen> {
  late final Set<int> _shown = widget.log.pids.take(3).toSet();

  Future<void> _rename() async {
    final c = TextEditingController(text: widget.log.name);
    final name = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('ตั้งชื่อบันทึก'),
        content: TextField(controller: c, autofocus: true, decoration: const InputDecoration(hintText: 'เช่น ก่อนล้างหัวฉีด')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('ยกเลิก')),
          FilledButton(onPressed: () => Navigator.pop(d, c.text.trim()), child: const Text('บันทึก')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    widget.log.name = name;
    await ref.read(logStoreProvider).save(widget.log);
    ref.invalidate(logsProvider);
    if (mounted) setState(() {});
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('ลบบันทึกนี้?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('ยกเลิก')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: StatusColors.bad),
            onPressed: () => Navigator.pop(d, true),
            child: const Text('ลบ'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(logStoreProvider).delete(widget.log.id);
    ref.invalidate(logsProvider);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final log = widget.log;
    final settings = ref.watch(settingsProvider);
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: FitText(log.name),
        actions: [
          IconButton(tooltip: 'ตั้งชื่อ', icon: const Icon(Icons.edit_rounded), onPressed: _rename),
          Builder(
            builder: (b) => IconButton(
              tooltip: 'ส่งออก CSV',
              icon: const Icon(Icons.ios_share_rounded),
              onPressed: () => shareLogCsv(b, log),
            ),
          ),
          IconButton(tooltip: 'ลบ', icon: const Icon(Icons.delete_outline_rounded), onPressed: _delete),
        ],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final p in log.pids)
            FilterChip(
              label: FitText(pidTable[p]?.nameTh ?? p.toRadixString(16)),
              selected: _shown.contains(p),
              onSelected: (v) => setState(() => v ? _shown.add(p) : _shown.remove(p)),
            ),
        ]),
        const SizedBox(height: 6),
        Text('แตะหรือลากบนกราฟเพื่อดูค่า แตะสองครั้งเพื่อซ่อนเส้นเล็ง',
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
        for (final (i, p) in log.pids.indexed)
          if (_shown.contains(p) && pidTable[p] != null)
            Builder(builder: (context) {
              final def = pidTable[p]!;
              final pts = [for (final (t, v) in log.series(p)) (t, displayPid(def, v, settings).value)];
              final unit = displayPid(def, 0, settings).unit;
              final st = _stats(pts);
              final color = chartColors[i % chartColors.length];
              return Padding(
                padding: const EdgeInsets.only(top: 14),
                child: PremiumCard(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                      const SizedBox(width: 8),
                      Expanded(child: Text(thaiKeep('${def.nameTh} ($unit)'), style: const TextStyle(fontWeight: FontWeight.w700))),
                    ]),
                    const SizedBox(height: 10),
                    TimeChart(
                      height: 170,
                      series: [ChartSeries(label: def.nameTh, points: pts, color: color, decimals: def.decimals)],
                    ),
                    if (st != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        'ต่ำสุด ${st.$1.toStringAsFixed(def.decimals)}\u00A0· เฉลี่ย ${st.$2.toStringAsFixed(def.decimals)}\u00A0· สูงสุด ${st.$3.toStringAsFixed(def.decimals)}',
                        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                      ),
                    ],
                  ]),
                ),
              );
            }),
      ]),
    );
  }
}

/// เทียบสองบันทึก เช่น ก่อนและหลังซ่อม
class CompareLogsScreen extends ConsumerStatefulWidget {
  const CompareLogsScreen({super.key, required this.a, required this.b});

  final DriveLog a;
  final DriveLog b;

  @override
  ConsumerState<CompareLogsScreen> createState() => _CompareLogsScreenState();
}

class _CompareLogsScreenState extends ConsumerState<CompareLogsScreen> {
  late final List<int> _common = widget.a.pids.where(widget.b.pids.contains).toList();
  late int? _pid = _common.isEmpty ? null : _common.first;

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final cs = Theme.of(context).colorScheme;
    final a = widget.a, b = widget.b;
    final pid = _pid;
    return Scaffold(
      appBar: AppBar(title: const FitText('เปรียบเทียบบันทึก')),
      body: _common.isEmpty || pid == null
          ? const EmptyState(icon: Icons.compare_arrows_rounded, title: 'สองบันทึกนี้ไม่มีค่าที่ตรงกัน')
          : ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final p in _common)
                  ChoiceChip(
                    label: FitText(pidTable[p]?.nameTh ?? '$p'),
                    selected: p == pid,
                    onSelected: (_) => setState(() => _pid = p),
                  ),
              ]),
              const SizedBox(height: 14),
              Builder(builder: (context) {
                final def = pidTable[pid]!;
                List<(double, double)> pts(DriveLog l) =>
                    [for (final (t, v) in l.series(pid)) (t, displayPid(def, v, settings).value)];
                final pa = pts(a), pb = pts(b);
                final sa = _stats(pa), sb = _stats(pb);
                final unit = displayPid(def, 0, settings).unit;
                String f(double? v) => v == null ? '—' : v.toStringAsFixed(def.decimals);
                String diff(double? x, double? y) {
                  if (x == null || y == null) return '—';
                  final d = y - x;
                  return '${d >= 0 ? '+' : ''}${d.toStringAsFixed(def.decimals)}';
                }

                return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  PremiumCard(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(thaiKeep('${def.nameTh} ($unit)'), style: const TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      Wrap(spacing: 12, children: [
                        _Legend(color: chartColors[1], text: 'ก: ${a.name}'),
                        _Legend(color: chartColors[0], text: 'ข: ${b.name}'),
                      ]),
                      const SizedBox(height: 10),
                      TimeChart(height: 230, series: [
                        ChartSeries(label: 'ก', points: pa, color: chartColors[1], decimals: def.decimals),
                        ChartSeries(label: 'ข', points: pb, color: chartColors[0], decimals: def.decimals),
                      ]),
                    ]),
                  ),
                  const SectionLabel('สรุปตัวเลข'),
                  PremiumCard(
                    child: Table(
                      columnWidths: const {0: FlexColumnWidth(1.3)},
                      children: [
                        TableRow(children: [
                          const SizedBox(),
                          for (final h in ['ก', 'ข', 'ต่าง'])
                            Text(h, textAlign: TextAlign.right, style: TextStyle(color: cs.onSurfaceVariant, fontWeight: FontWeight.w700)),
                        ]),
                        for (final (label, idx) in [('ต่ำสุด', 0), ('เฉลี่ย', 1), ('สูงสุด', 2)])
                          TableRow(children: [
                            Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Text(label)),
                            for (final s in [sa, sb])
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 6),
                                child: Text(f(s == null ? null : [s.$1, s.$2, s.$3][idx]),
                                    textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w700)),
                              ),
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Text(
                                diff(sa == null ? null : [sa.$1, sa.$2, sa.$3][idx], sb == null ? null : [sb.$1, sb.$2, sb.$3][idx]),
                                textAlign: TextAlign.right,
                                style: TextStyle(fontWeight: FontWeight.w800, color: cs.primary),
                              ),
                            ),
                          ]),
                      ],
                    ),
                  ),
                ]);
              }),
            ]),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.text});

  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 14, height: 4, color: color),
        const SizedBox(width: 6),
        Flexible(child: Text(text, style: const TextStyle(fontSize: 12.5))),
      ]);
}
