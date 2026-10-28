import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/analysis/odometer_check.dart' show CheckLevel;
import '../../core/analysis/remap_sampler.dart';
import '../../core/analysis/remap_test.dart';
import '../../core/elm/elm327.dart';
import '../../core/obd/ext_pid.dart';
import '../../core/obd/obd_service.dart';
import '../../core/obd/pids.dart';
import '../../core/transport/demo_transport.dart';
import '../../core/voice/voice_service.dart';
import '../../report/pdf_report.dart';
import '../../state/ext_packs.dart';
import '../../state/live_poller.dart';
import '../../state/providers.dart';
import '../../state/remap_providers.dart';
import '../home_screen.dart';
import '../splash_screen.dart' show kAppVersion;
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/time_chart.dart';
import '../widgets/xy_chart.dart';
import 'ext_common.dart';

// ---------------------------------------------------------------- ส่วนที่ใช้ร่วมกัน

const _beforeColor = StatusColors.info;
const _afterColor = Color(0xFFFF8A1F);

Color remapStageColor(RemapStage s) => switch (s) {
      RemapStage.before => _beforeColor,
      RemapStage.after => _afterColor,
      RemapStage.other => const Color(0xFF8A95A5),
    };

Color remapLevelColor(RemapLevel l) => switch (l) {
      RemapLevel.ok => StatusColors.good,
      RemapLevel.warn => StatusColors.warn,
      RemapLevel.bad => StatusColors.bad,
    };

CheckLevel _check(RemapLevel l) => switch (l) {
      RemapLevel.ok => CheckLevel.ok,
      RemapLevel.warn => CheckLevel.warn,
      RemapLevel.bad => CheckLevel.bad,
    };

/// เกณฑ์วิเคราะห์จากการตั้งค่าแจ้งเตือน (ความร้อนสูงสุด และบูสต์สูงสุดแบบเกจที่ร้านตั้งไว้)
RemapLimits remapLimitsFor(AppSettings s) => RemapLimits(
      coolantMax: s.alerts.coolantMax > 0 ? s.alerts.coolantMax : 105,
      boostCapGauge: s.alerts.boostMax,
    );

final _analysisCache = Expando<(String, RemapAnalysis)>('remap_analysis');

/// ผลวิเคราะห์ (จำไว้ ไม่คำนวณซ้ำทุกครั้งที่วาดหน้าจอ)
RemapAnalysis remapAnalysisOf(RemapRun run, RemapLimits limits) {
  final key = '${limits.coolantMax}|${limits.boostCapGauge}|${run.rows.length}|${run.dtcAfter.length}|${run.milAfter}';
  final hit = _analysisCache[run];
  if (hit != null && hit.$1 == key) return hit.$2;
  final a = analyzeRemapRun(run, limits: limits);
  _analysisCache[run] = (key, a);
  return a;
}

String _fmt(double? v, [int d = 0]) => v == null ? '—' : v.toStringAsFixed(d);

String _durText(double s) {
  final m = s ~/ 60;
  final r = (s % 60).round();
  return m == 0 ? '$r\u00A0วินาที' : '$m\u00A0นาที $r\u00A0วินาที';
}

/// ลำดับก่อน/หลัง: รอบ "ก่อนรีแมพ" อยู่ซ้ายเสมอ ถ้าไม่ระบุใช้รอบที่เก่ากว่า
(RemapRun, RemapRun) remapPair(RemapRun a, RemapRun b) {
  if (a.stage == RemapStage.after && b.stage != RemapStage.after) return (b, a);
  if (b.stage == RemapStage.after && a.stage != RemapStage.after) return (a, b);
  if (a.stage == RemapStage.before && b.stage != RemapStage.before) return (a, b);
  if (b.stage == RemapStage.before && a.stage != RemapStage.before) return (b, a);
  return a.start.isBefore(b.start) ? (a, b) : (b, a);
}

bool _sameCar(RemapRun a, RemapRun b) {
  if (a.vin != null && b.vin != null) return a.vin == b.vin;
  if (a.vehicleId != null && b.vehicleId != null) return a.vehicleId == b.vehicleId;
  return a.vehicleLabel == b.vehicleLabel;
}

Future<void> _shareCsv(BuildContext context, RemapRun run) async {
  final dir = await getTemporaryDirectory();
  final safe = run.name.replaceAll(RegExp(r'[^\w฀-๿\- ]'), '_');
  final f = File('${dir.path}/$safe.csv');
  // ใส่ BOM ให้ Excel อ่านภาษาไทยถูก
  await f.writeAsString('﻿${run.toCsv()}', flush: true);
  if (context.mounted) await shareFile(context, f.path, mime: 'text/csv', subject: run.name);
}

class _StagePill extends StatelessWidget {
  const _StagePill(this.stage);

  final RemapStage stage;

  @override
  Widget build(BuildContext context) => Pill(text: stage.labelTh, color: remapStageColor(stage));
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

/// ช่องตัวเลขใหญ่ (อัตราเร่ง/ค่าสด)
class _Tile extends StatelessWidget {
  const _Tile({required this.label, required this.value, this.unit = '', this.sub, this.color, this.big = false});

  final String label;
  final String value;
  final String unit;
  final String? sub;
  final Color? color;
  final bool big;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
      decoration: BoxDecoration(
        color: (color ?? cs.primary).withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: (color ?? cs.outline).withValues(alpha: color == null ? 1 : 0.4)),
      ),
      child: Column(children: [
        // ชื่อช่องและหน่วยแสดงครบเสมอ: ช่องแคบย่อตัวอักษรลงแทนการตัดคำ
        FitText(label, alignment: Alignment.center, style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant)),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(value,
              style: TextStyle(
                fontSize: big ? 34 : 22,
                fontWeight: FontWeight.w800,
                color: color,
                fontFeatures: const [FontFeature.tabularFigures()],
              )),
        ),
        FitText(sub ?? unit, alignment: Alignment.center, style: TextStyle(fontSize: 10.5, color: cs.onSurfaceVariant)),
      ]),
    );
  }
}

Widget _tileRow(List<Widget> tiles) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (var i = 0; i < tiles.length; i++) ...[
        if (i > 0) const SizedBox(width: 8),
        Expanded(child: tiles[i]),
      ],
    ]);

Widget _accelTiles(RemapAnalysis a, {Color? color}) => _tileRow([
      for (final (from, to) in remapAccelRanges)
        _Tile(
          label: '${from.round()}–${to.round()}',
          value: _fmt(a.accelFor(from, to)?.seconds, 2),
          unit: 'วินาที',
          color: a.accelFor(from, to) == null ? null : color,
        ),
    ]);

class _EventList extends StatelessWidget {
  const _EventList({required this.events, this.emptyText = 'ไม่พบสิ่งผิดปกติ'});

  final List<RemapEvent> events;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty) {
      return CheckRow(level: CheckLevel.ok, title: emptyText, detail: 'บูสต์/ความดันรางตามที่กล่องต้องการ ไม่มีรหัสปัญหาใหม่ ความร้อนอยู่ในเกณฑ์');
    }
    return Column(children: [
      for (final e in events)
        CheckRow(
          level: _check(e.level),
          title: [e.kind.titleTh, if (e.whenTh != null) '· ${e.whenTh}'].join(' '),
          detail: e.detail,
        ),
    ]);
  }
}

// ---------------------------------------------------------------- หน้าหลัก

/// ทดสอบขับก่อน/หลังรีแมพ: เลือกเริ่มทดสอบ ดูผลที่บันทึกไว้ เลือกสองรอบมาเทียบ
class RemapTestScreen extends ConsumerStatefulWidget {
  const RemapTestScreen({super.key});

  @override
  ConsumerState<RemapTestScreen> createState() => _RemapTestScreenState();
}

class _RemapTestScreenState extends ConsumerState<RemapTestScreen> {
  final _selected = <String>{};
  Set<String>? _extOn;

  /// ค่าเฉพาะยี่ห้อจากชุดที่ทำไว้สำหรับรถคันนี้ ที่ใช้ในการทดสอบได้ (บูสต์/รางที่ต้องการ ปริมาณฉีด ไอเสีย)
  /// ชนิดละไม่เกิน 2 ตัว (ดู [pickRemapExt])
  List<RemapExtChannel> _candidates(SessionState session) {
    final elm = session.elm;
    final out = <RemapExtChannel>[];
    final seen = <String>{};
    for (final pack in ref.watch(extPacksProvider)) {
      if (!fitsCurrentVehicle(ref, brand: pack.brand, models: pack.models, years: pack.years)) continue;
      for (final p in pack.pids) {
        if (elm != null && ExtPidReader.incompatibility(elm, p) != null) continue;
        final c = classifyRemapExt(p);
        if (c == null || !seen.add(c.key) || !seen.add('${p.cmdKey}|${p.formula}')) continue;
        out.add(c);
      }
    }
    return pickRemapExt(out);
  }

  /// เลือกไว้ก่อนชนิดละหนึ่งตัว (ตัวที่เหมาะที่สุดที่ผ่าน [_defaultOn])
  static Set<String> _defaults(List<RemapExtChannel> candidates, ObdService? svc) {
    final on = <String>{};
    final kinds = <RemapSignal>{};
    for (final c in candidates) {
      if (kinds.contains(c.signal) || !_defaultOn(c, svc)) continue;
      on.add(c.key);
      kinds.add(c.signal);
    }
    return on;
  }

  /// เลือกไว้ก่อน: ค่าที่มีหลักฐานจากรถจริง และ PID มาตรฐานของรถคันนี้ไม่มีให้
  static bool _defaultOn(RemapExtChannel c, ObdService? svc) {
    if (c.pid.trust < 1) return false;
    bool sup(int pid) => svc?.supported.contains(pid) ?? false;
    return switch (c.signal) {
      RemapSignal.boostCmd => !sup(Pid.boost),
      RemapSignal.railCmd => !sup(0x6D),
      RemapSignal.injQty => true,
      RemapSignal.egt => !sup(Pid.egtB1),
      RemapSignal.boost => !sup(Pid.map) && !sup(Pid.boost),
      RemapSignal.rail => !sup(Pid.fuelRailPressure) && !sup(Pid.fuelRailAbs) && !sup(0x6D),
      _ => false,
    };
  }

  Future<void> _start(RemapStage stage, List<RemapExtChannel> candidates) async {
    final on = _extOn ?? const <String>{};
    final ext = [for (final c in candidates) if (on.contains(c.key)) c];
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => RemapLiveScreen(stage: stage, ext: ext)));
  }

  void _openCompare(RemapRun a, RemapRun b) {
    final (x, y) = remapPair(a, b);
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => RemapCompareScreen(before: x, after: y)));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final session = ref.watch(sessionProvider);
    final settings = ref.watch(settingsProvider);
    final limits = remapLimitsFor(settings);
    final runsAsync = ref.watch(remapRunsProvider);
    final runs = runsAsync.valueOrNull ?? const <RemapRun>[];
    final candidates = session.isConnected ? _candidates(session) : const <RemapExtChannel>[];
    if (_extOn == null && candidates.isNotEmpty) _extOn = _defaults(candidates, session.service);
    final latestAfter = runs.where((r) => r.stage == RemapStage.after).firstOrNull;
    final latestBefore = latestAfter == null
        ? null
        : runs.where((r) => r.stage == RemapStage.before && _sameCar(r, latestAfter)).firstOrNull;

    return Scaffold(
      appBar: AppBar(
        title: FitText(_selected.isEmpty ? 'ทดสอบก่อน/หลังรีแมพ' : 'เลือกแล้ว ${_selected.length}'),
        actions: [
          if (_selected.length == 2)
            TextButton.icon(
              icon: const Icon(Icons.compare_arrows_rounded),
              label: const Text('เทียบ'),
              onPressed: () {
                final pair = runs.where((r) => _selected.contains(r.id)).toList();
                if (pair.length == 2) _openCompare(pair[0], pair[1]);
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
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
        PremiumCard(
          glow: cs.primary,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.rocket_launch_rounded, color: cs.primary),
              const SizedBox(width: 10),
              const Expanded(
                child: Text('ขับทดสอบ แล้วเทียบก่อนกับหลังรีแมพ', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              ),
            ]),
            const SizedBox(height: 8),
            Text(
              'บันทึกค่าระหว่างขับ เทียบบูสต์และความดันรางจริงกับค่าที่กล่องต้องการ แจ้งเตือนทันทีเมื่อบูสต์เกิน '
              'หรือมีอาการเข้าโหมดป้องกันตัวเอง จับเวลาอัตราเร่ง แล้วออกรายงาน PDF เทียบก่อนกับหลัง',
              style: TextStyle(fontSize: 13, height: 1.5, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 6),
            for (final s in const [
              '1. ทดสอบก่อนรีแมพ: ออกตัว 0–100 หรือเร่ง 60–100 ต่อเนื่อง',
              '2. รีแมพ แล้วขับให้เครื่องร้อนเท่าเดิม',
              '3. ทดสอบหลังรีแมพ เส้นทาง น้ำหนักบรรทุก และอากาศใกล้เคียงกัน',
              '4. เลือกสองรอบมาเทียบ แล้วส่งรายงาน PDF',
            ])
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(s, style: const TextStyle(fontSize: 13, height: 1.4, fontWeight: FontWeight.w600)),
              ),
          ]),
        ),
        const SizedBox(height: 12),
        if (!session.isConnected)
          PremiumCard(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              Icon(Icons.link_off_rounded, color: cs.onSurfaceVariant),
              const SizedBox(width: 12),
              const Expanded(child: Text('เชื่อมต่อรถเพื่อเริ่มทดสอบ (ดูผลที่บันทึกไว้ได้โดยไม่ต้องเชื่อมต่อ)')),
              TextButton(onPressed: () => openConnect(context), child: const Text('เชื่อมต่อ')),
            ]),
          )
        else ...[
          // จอแคบวางปุ่มซ้อนกันเต็มความกว้าง ชื่อปุ่มอ่านครบบรรทัดเดียว
          ButtonPair(
            minWidth: 175,
            first: FilledButton.icon(
              icon: const Icon(Icons.flag_rounded),
              label: const FitText('เริ่มทดสอบ ก่อนรีแมพ'),
              style: FilledButton.styleFrom(backgroundColor: _beforeColor, minimumSize: const Size(0, 52)),
              onPressed: () => _start(RemapStage.before, candidates),
            ),
            second: FilledButton.icon(
              icon: const Icon(Icons.bolt_rounded),
              label: const FitText('เริ่มทดสอบ หลังรีแมพ'),
              style: FilledButton.styleFrom(backgroundColor: _afterColor, minimumSize: const Size(0, 52)),
              onPressed: () => _start(RemapStage.after, candidates),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.speed_rounded),
            label: const FitText('ทดสอบทั่วไป (ไม่ระบุก่อน/หลัง)'),
            onPressed: () => _start(RemapStage.other, candidates),
          ),
          if (candidates.isNotEmpty) ...[
            const SectionLabel('ค่าเฉพาะยี่ห้อที่อ่านเพิ่ม'),
            PremiumCard(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('จากชุดค่าของรถรุ่นนี้ อ่านทุก\u00A04\u00A0รอบของค่ามาตรฐาน (เลือกเฉพาะที่จำเป็น เพื่อให้อ่านค่าได้ถี่)',
                    style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant)),
                const SizedBox(height: 4),
                for (final c in candidates)
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: _extOn?.contains(c.key) ?? false,
                    onChanged: (v) => setState(() {
                      final on = _extOn ??= <String>{};
                      if (v ?? false) {
                        on.add(c.key);
                      } else {
                        on.remove(c.key);
                      }
                    }),
                    title: Text(c.pid.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text('ใช้เป็น: ${c.signal.labelTh}\u00A0· ${trustStyle(c.pid).$1}'),
                    secondary: TrustPill(pid: c.pid, compact: true),
                  ),
              ]),
            ),
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
            'ทดสอบในสนามหรือพื้นที่ปิดเท่านั้น ให้อีกคนดูจอ คนขับมองถนน แอปอ่านค่าอย่างเดียว ไม่เขียนหรือแก้ไขกล่อง '
            'เกณฑ์ความร้อน ${limits.coolantMax.round()}\u00A0°C'
            '${limits.boostCapGauge > 0 ? ' และบูสต์สูงสุด ${limits.boostCapGauge.round()}\u00A0kPa (เกจ)' : ''} '
            'ตั้งได้ที่ ตั้งค่า > แจ้งเตือน',
            style: TextStyle(fontSize: 12, height: 1.5, color: cs.onSurface),
          ),
        ),
        if (latestAfter != null && latestBefore != null) ...[
          const SectionLabel('เทียบล่าสุด'),
          PremiumCard(
            glow: _afterColor,
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            onTap: () => _openCompare(latestBefore, latestAfter),
            child: Builder(builder: (context) {
              final rows = compareRemap(remapAnalysisOf(latestBefore, limits), remapAnalysisOf(latestAfter, limits));
              return Row(children: [
                const Icon(Icons.compare_arrows_rounded, color: _afterColor),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(remapCompareHeadline(rows), style: const TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text('${latestBefore.name}  →  ${latestAfter.name}', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                  ]),
                ),
                Icon(Icons.chevron_right_rounded, color: cs.onSurfaceVariant),
              ]);
            }),
          ),
        ],
        const SectionLabel('ผลทดสอบที่บันทึกไว้'),
        if (runsAsync.isLoading && runs.isEmpty)
          const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
        else if (runs.isEmpty)
          const EmptyState(
            icon: Icons.speed_rounded,
            title: 'ยังไม่มีผลทดสอบ',
            text: 'เริ่มทดสอบก่อนรีแมพไว้เป็นจุดเทียบ แล้วทดสอบอีกครั้งหลังรีแมพ',
          )
        else ...[
          Text('แตะค้างเพื่อเลือก 2\u00A0รอบมาเทียบ', style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant)),
          const SizedBox(height: 8),
          for (final r in runs)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _RunTile(
                run: r,
                analysis: remapAnalysisOf(r, limits),
                selected: _selected.contains(r.id),
                onTap: () {
                  if (_selected.isNotEmpty) {
                    setState(() {
                      if (_selected.contains(r.id)) {
                        _selected.remove(r.id);
                      } else if (_selected.length < 2) {
                        _selected.add(r.id);
                      }
                    });
                  } else {
                    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => RemapResultScreen(run: r)));
                  }
                },
                onLongPress: () => setState(() {
                  if (_selected.contains(r.id)) {
                    _selected.remove(r.id);
                  } else if (_selected.length < 2) {
                    _selected.add(r.id);
                  }
                }),
              ),
            ),
        ],
      ]),
    );
  }
}

class _RunTile extends StatelessWidget {
  const _RunTile({required this.run, required this.analysis, required this.selected, required this.onTap, required this.onLongPress});

  final RemapRun run;
  final RemapAnalysis analysis;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final a = analysis;
    final color = remapLevelColor(a.level);
    final t100 = a.accelFor(0, 100) ?? a.accelFor(60, 100);
    final facts = [
      if (t100 != null) '${t100.label}: ${t100.seconds.toStringAsFixed(2)}\u00A0วิ',
      if (a.maxBoostGauge != null) 'บูสต์ ${a.maxBoostGauge!.round()}\u00A0kPa',
      if (a.max[RemapSignal.rail] != null) 'ราง ${a.max[RemapSignal.rail]!.round()}\u00A0MPa',
      a.events.isEmpty ? 'ไม่พบสิ่งผิดปกติ' : 'ผิดปกติ ${a.events.length}',
    ];
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
            decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(12)),
            child: Icon(
              selected ? Icons.check_rounded : _check(a.level).icon,
              color: selected ? cs.primary : color,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // ป้ายขั้นและชื่อรอบ: ที่ไม่พอให้ชื่อขึ้นบรรทัดใหม่ (ไม่ตัดท้าย)
              Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                _StagePill(run.stage),
                Text(run.name, style: const TextStyle(fontWeight: FontWeight.w700)),
              ]),
              const SizedBox(height: 4),
              Text(
                '${thaiDate(run.start)}\u00A0· ${_durText(run.durationS)}${run.vehicleLabel.isEmpty ? '' : '\u00A0· ${run.vehicleLabel}'}',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 2),
              Text(facts.join('\u00A0· '), style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
            ]),
          ),
          Icon(Icons.chevron_right_rounded, color: cs.onSurfaceVariant),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------- ระหว่างทดสอบ

enum _Phase { preparing, running, stopping }

/// หน้าระหว่างขับทดสอบ: อ่านค่าต่อเนื่อง แสดงค่าสำคัญตัวใหญ่ แจ้งเตือนทันทีเมื่อพบสิ่งผิดปกติ
class RemapLiveScreen extends ConsumerStatefulWidget {
  const RemapLiveScreen({super.key, required this.stage, this.ext = const []});

  final RemapStage stage;
  final List<RemapExtChannel> ext;

  @override
  ConsumerState<RemapLiveScreen> createState() => _RemapLiveScreenState();
}

class _RemapLiveScreenState extends ConsumerState<RemapLiveScreen> {
  static const _pollKey = 'remap_test';
  late final LivePoller _poller;
  final _clock = Stopwatch();
  _Phase _phase = _Phase.preparing;
  String _prepStep = 'อ่านรหัสปัญหาก่อนทดสอบ…';
  RemapSampler? _sampler;
  RemapRun? _run;
  RemapAnalysis? _analysis;
  ObdService? _svc;
  RemapLimits _limits = const RemapLimits();
  String? _error;
  bool _active = true;
  bool _dtcOk = true;
  Future<void>? _loopDone;
  Timer? _ticker;
  DateTime _lastUi = DateTime(2000);
  final _alerted = <String>{};
  String? _banner;
  Color _bannerColor = StatusColors.warn;
  bool _milAlerted = false;

  @override
  void initState() {
    super.initState();
    _poller = ref.read(livePollerProvider);
    pausePoller(_poller, _pollKey);
    WakelockPlus.enable().catchError((Object _) {});
    unawaited(_prepare());
  }

  @override
  void dispose() {
    _active = false;
    _ticker?.cancel();
    resumePoller(_poller, _pollKey);
    WakelockPlus.disable().catchError((Object _) {});
    super.dispose();
  }

  double _now() => _clock.elapsedMicroseconds / 1e6;

  Future<void> _prepare() async {
    final session = ref.read(sessionProvider);
    final svc = session.service;
    if (svc == null) {
      setState(() => _error = 'ยังไม่ได้เชื่อมต่อรถ');
      return;
    }
    _svc = svc;
    _limits = remapLimitsFor(ref.read(settingsProvider));
    var codes = <String>[];
    bool? mil;
    try {
      final r = await readRemapDtcs(svc);
      codes = r.$1;
      mil = r.$2;
    } catch (_) {
      _dtcOk = false;
    }
    if (!mounted || !_active) return;
    setState(() => _prepStep = 'ตรวจว่ารถรองรับค่าอะไรบ้าง…');
    final sampler = RemapSampler(svc, clock: _now, ext: widget.ext);
    try {
      await sampler.init(diesel: session.diesel);
    } on ElmException catch (e) {
      if (mounted) setState(() => _error = e.message);
      return;
    }
    if (!mounted || !_active) return;
    final now = DateTime.now();
    final vehicle = currentVehicle(ref, watch: false);
    _run = RemapRun(
      id: 'remap_${now.millisecondsSinceEpoch}',
      name: '${widget.stage.labelTh} ${thaiDate(now)}',
      stage: widget.stage,
      start: now,
      channels: List.of(sampler.channels),
      vin: session.vin,
      vehicleId: session.vehicleId,
      vehicleLabel: vehicleLabel(vehicle, vin: session.vin),
      dtcBefore: codes,
      milBefore: mil,
      turbo: sampler.turbo,
      multiPid: sampler.multiPid,
      note: _dtcOk ? '' : 'อ่านรหัสปัญหาก่อนทดสอบไม่ได้ จึงไม่ได้เทียบรหัสก่อน/หลัง',
      appVersion: kAppVersion,
    );
    _sampler = sampler;
    _clock.start();
    setState(() => _phase = _Phase.running);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _analyze());
    _loopDone = _loop();
  }

  Future<void> _loop() async {
    final sampler = _sampler!, run = _run!;
    while (_active && _phase == _Phase.running) {
      if (ref.read(sessionProvider).service != _svc) {
        _error = 'การเชื่อมต่อหลุด กดหยุดเพื่อบันทึกข้อมูลที่ได้';
        if (mounted) setState(() {});
        break;
      }
      try {
        await sampler.step(run.add);
        _error = null;
      } on ElmException catch (e) {
        _error = e.message;
        await Future<void>.delayed(const Duration(milliseconds: 600));
      } catch (e) {
        _error = '$e';
        await Future<void>.delayed(const Duration(milliseconds: 600));
      }
      final now = DateTime.now();
      if (mounted && _active && now.difference(_lastUi).inMilliseconds >= 250) {
        _lastUi = now;
        setState(() {});
      }
    }
  }

  void _analyze() {
    final run = _run;
    if (run == null || !mounted || _phase != _Phase.running) return;
    final a = analyzeRemapRun(run, limits: _limits);
    String? msg;
    RemapEvent? worst;
    for (final e in a.events) {
      if (e.level == RemapLevel.ok) continue;
      final key = '${e.kind.name}@${e.start?.toStringAsFixed(1)}';
      if (!_alerted.add(key)) continue;
      if (worst == null || e.level.index > worst.level.index) worst = e;
    }
    var color = StatusColors.warn;
    if (worst != null) {
      msg = worst.kind.titleTh;
      if (worst.level == RemapLevel.bad) color = StatusColors.bad;
    }
    if (!_milAlerted && _sampler?.milOn == true && run.milBefore == false) {
      _milAlerted = true;
      msg = 'ไฟเตือนเครื่องยนต์ติด อาจเข้าโหมดป้องกันตัวเอง';
      color = StatusColors.bad;
    }
    setState(() {
      _analysis = a;
      if (msg != null) {
        _banner = msg;
        _bannerColor = color;
      }
    });
    if (msg != null) {
      unawaited(HapticFeedback.heavyImpact().catchError((Object _) {}));
      final alerts = ref.read(settingsProvider).alerts;
      if (alerts.enabled && alerts.voice) unawaited(ref.read(voiceServiceProvider).speak('ระวัง $msg'));
    }
  }

  Future<void> _stop() async {
    if (_phase != _Phase.running) return;
    setState(() => _phase = _Phase.stopping);
    _ticker?.cancel();
    await _loopDone;
    _clock.stop();
    final run = _run!, sampler = _sampler!;
    final secs = _now();
    run.hz = secs > 0 ? sampler.requests / secs : 0;
    run.multiPid = sampler.multiPid;
    if (!mounted) return;
    if (run.rows.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('ไม่ได้ค่าจากรถเลย จึงไม่ได้บันทึก')));
      Navigator.of(context).pop();
      return;
    }
    final svc = _svc;
    if (_dtcOk && svc != null && ref.read(sessionProvider).service == svc) {
      try {
        final r = await readRemapDtcs(svc);
        run.dtcAfter.addAll(r.$1);
        run.milAfter = r.$2;
      } catch (_) {
        run.note = [if (run.note.isNotEmpty) run.note, 'อ่านรหัสปัญหาหลังทดสอบไม่ได้'].join('\u00A0· ');
      }
    }
    if (!mounted) return;
    final store = ref.read(remapStoreProvider);
    try {
      await store.save(run);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('บันทึกไม่สำเร็จ: $e')));
    }
    if (!mounted) return;
    ref.invalidate(remapRunsProvider);
    unawaited(Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => RemapResultScreen(run: run))));
  }

  Future<void> _askLeave() async {
    if (_phase == _Phase.stopping) return;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ออกจากการทดสอบ?'),
        content: const Text('บันทึกผลที่ได้ไว้ก่อน หรือทิ้งรอบนี้'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, 'discard'), child: const Text('ทิ้ง')),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('ทดสอบต่อ')),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'save'), child: const Text('หยุดและบันทึก')),
        ],
      ),
    );
    if (!mounted) return;
    if (choice == 'save') {
      await _stop();
    } else if (choice == 'discard') {
      _active = false;
      _phase = _Phase.stopping;
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final run = _run;
    final transport = ref.watch(sessionProvider.select((s) => s.transport));
    final demo = transport is DemoTransport ? transport : null;
    return PopScope<Object?>(
      canPop: _phase == _Phase.preparing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_askLeave());
      },
      child: Scaffold(
        appBar: AppBar(title: FitText('ทดสอบ: ${widget.stage.labelTh}')),
        body: run == null
            ? _preparing(cs)
            : ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
                if (_banner != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Material(
                      color: _bannerColor,
                      borderRadius: BorderRadius.circular(14),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
                        child: Row(children: [
                          const Icon(Icons.warning_rounded, color: Colors.white),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(_banner!, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                          ),
                          TextButton(
                            onPressed: () => setState(() => _banner = null),
                            child: const Text('รับทราบ', style: TextStyle(color: Colors.white)),
                          ),
                        ]),
                      ),
                    ),
                  ),
                _statusCard(cs, run, demo),
                const SizedBox(height: 10),
                ..._liveTiles(run),
                if (_analysis != null) ...[
                  const SectionLabel('อัตราเร่ง (วินาที)'),
                  _accelTiles(_analysis!, color: remapStageColor(widget.stage)),
                  SectionLabel('สิ่งที่พบ (${_analysis!.events.length})'),
                  PremiumCard(
                    padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
                    child: _EventList(events: _analysis!.events.reversed.toList(), emptyText: 'ยังไม่พบสิ่งผิดปกติ'),
                  ),
                ],
              ]),
      ),
    );
  }

  Widget _preparing(ColorScheme cs) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (_error == null) const CircularProgressIndicator() else const Icon(Icons.error_rounded, size: 48, color: StatusColors.bad),
            const SizedBox(height: 16),
            Text(_error ?? _prepStep, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text('ติดเครื่องยนต์ทิ้งไว้ อย่าเพิ่งออกรถ', style: TextStyle(color: cs.onSurfaceVariant)),
          ]),
        ),
      );

  Widget _statusCard(ColorScheme cs, RemapRun run, DemoTransport? demo) {
    final secs = _now();
    final mm = (secs ~/ 60).toString().padLeft(2, '0');
    final ss = (secs % 60).floor().toString().padLeft(2, '0');
    final rate = secs > 0 && _sampler != null ? _sampler!.requests / secs : 0.0;
    final stopping = _phase == _Phase.stopping;
    return PremiumCard(
      glow: stopping ? cs.onSurfaceVariant : StatusColors.bad,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(children: [
        Row(children: [
          Icon(Icons.fiber_manual_record_rounded, color: stopping ? cs.onSurfaceVariant : StatusColors.bad, size: 18),
          const SizedBox(width: 6),
          // ข้อความสถานะยาว (ตอนกำลังบันทึก) ขึ้นบรรทัดใหม่ได้ ไม่ดันเวลาจนล้นขอบ
          Expanded(
            child: Text(stopping ? 'กำลังอ่านรหัสปัญหาและบันทึก…' : 'กำลังบันทึก',
                style: const TextStyle(fontWeight: FontWeight.w800)),
          ),
          const SizedBox(width: 8),
          Text('$mm:$ss', style: const TextStyle(fontFamily: kMono, fontSize: 22, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 4),
        Row(children: [
          Expanded(
            child: Text(
              thaiKeep('${rate.toStringAsFixed(1)}\u00A0คำสั่ง/วินาที\u00A0· ${run.rows.length}\u00A0แถว'
                  '${_sampler?.multiPid ?? false ? '\u00A0· หลาย PID ต่อคำสั่ง' : ''}'),
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ),
        ]),
        if (_error != null) ...[
          const SizedBox(height: 4),
          Text(_error!, style: const TextStyle(fontSize: 12, color: StatusColors.warn)),
        ],
        const SizedBox(height: 12),
        Builder(builder: (context) {
          final stop = FilledButton.icon(
            icon: stopping
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
                : const Icon(Icons.stop_rounded),
            label: const FitText('หยุดและบันทึก'),
            style: FilledButton.styleFrom(backgroundColor: StatusColors.bad, minimumSize: const Size(0, 52)),
            onPressed: stopping ? null : _stop,
          );
          if (demo == null || stopping) return SizedBox(width: double.infinity, child: stop);
          // จอแคบวางปุ่มซ้อนกันเต็มความกว้าง ชื่อปุ่มอ่านครบบรรทัดเดียว
          return ButtonPair(
            minWidth: 150,
            first: stop,
            second: FilledButton.tonalIcon(
              icon: const Icon(Icons.rocket_launch_rounded),
              label: const FitText('จำลองออกตัว'),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
              onPressed: demo.startDrive,
            ),
          );
        }),
      ]),
    );
  }

  List<Widget> _liveTiles(RemapRun run) {
    final baro = _analysis?.baro ?? run.latest(RemapSignal.baro) ?? 101.3;
    double? gauge(double? v) => v == null ? null : v - baro;
    final speed = run.latest(RemapSignal.speed);
    final rpm = run.latest(RemapSignal.rpm);
    final boost = gauge(run.latest(RemapSignal.boost));
    final boostCmd = gauge(run.latest(RemapSignal.boostCmd));
    final rail = run.latest(RemapSignal.rail);
    final railCmd = run.latest(RemapSignal.railCmd);
    final hasRail = run.channels.any((c) => c.signal == RemapSignal.rail);
    final small = <Widget>[
      for (final (s, label) in [
        (RemapSignal.pedal, 'คันเร่ง'),
        (RemapSignal.load, 'ภาระ'),
        (RemapSignal.coolant, 'น้ำ'),
        (RemapSignal.iat, 'อากาศเข้า'),
        (RemapSignal.egt, 'ไอเสีย'),
        (RemapSignal.injQty, 'ปริมาณฉีด'),
      ])
        if (run.channels.any((c) => c.signal == s))
          _Tile(label: label, value: _fmt(run.latest(s), s.decimals), unit: s.unit),
    ];
    return [
      _tileRow([
        _Tile(label: 'ความเร็ว', value: _fmt(speed), unit: 'กม./ชม.', big: true),
        _Tile(label: 'รอบเครื่อง', value: _fmt(rpm), unit: 'รอบ/นาที', big: true),
      ]),
      const SizedBox(height: 8),
      _tileRow([
        _Tile(
          label: 'บูสต์ (เกจ)',
          value: _fmt(boost),
          unit: 'kPa',
          sub: boostCmd == null ? 'kPa' : 'ต้องการ ${boostCmd.round()}\u00A0kPa',
          color: boost != null && boostCmd != null && boost - boostCmd > _limits.overboostKpa ? StatusColors.bad : null,
          big: true,
        ),
        if (hasRail)
          _Tile(
            label: 'ความดันราง',
            value: _fmt(rail),
            unit: 'MPa',
            sub: railCmd == null ? 'MPa' : 'ต้องการ ${railCmd.round()}\u00A0MPa',
            big: true,
          ),
      ]),
      if (small.isNotEmpty) ...[
        const SizedBox(height: 8),
        for (var i = 0; i < small.length; i += 3) ...[
          if (i > 0) const SizedBox(height: 8),
          _tileRow([...small.skip(i).take(3), for (var k = small.skip(i).take(3).length; k < 3; k++) const SizedBox()]),
        ],
      ],
    ];
  }
}

// ---------------------------------------------------------------- ผลหนึ่งรอบ

class RemapResultScreen extends ConsumerStatefulWidget {
  const RemapResultScreen({super.key, required this.run});

  final RemapRun run;

  @override
  ConsumerState<RemapResultScreen> createState() => _RemapResultScreenState();
}

class _RemapResultScreenState extends ConsumerState<RemapResultScreen> {
  RemapRun get run => widget.run;

  Future<void> _save() async {
    await ref.read(remapStoreProvider).save(run);
    if (mounted) ref.invalidate(remapRunsProvider);
  }

  Future<void> _rename() async {
    final name = await askText(context, 'ชื่อรอบทดสอบ', initial: run.name);
    if (name == null || name.trim().isEmpty) return;
    setState(() => run.name = name.trim());
    await _save();
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ลบผลทดสอบนี้?'),
        content: Text(run.name),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('ยกเลิก')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('ลบ')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await ref.read(remapStoreProvider).delete(run.id);
    if (!mounted) return;
    ref.invalidate(remapRunsProvider);
    Navigator.of(context).pop();
  }

  Future<void> _pickCompare() async {
    final runs = await ref.read(remapRunsProvider.future);
    if (!mounted) return;
    final others = runs.where((r) => r.id != run.id).toList()
      ..sort((a, b) {
        // รถคันเดียวกันและคนละขั้น (ก่อน/หลัง) ขึ้นก่อน
        int score(RemapRun r) => (_sameCar(r, run) ? 0 : 2) + (r.stage != run.stage ? 0 : 1);
        final s = score(a).compareTo(score(b));
        return s != 0 ? s : b.start.compareTo(a.start);
      });
    if (others.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('ยังไม่มีรอบอื่นให้เทียบ')));
      return;
    }
    final other = await showModalBottomSheet<RemapRun>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('เลือกรอบที่จะเทียบ', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          ),
          for (final r in others.take(30))
            ListTile(
              leading: _StagePill(r.stage),
              title: Text(r.name),
              subtitle: Text('${thaiDate(r.start)}${r.vehicleLabel.isEmpty ? '' : '\u00A0· ${r.vehicleLabel}'}'),
              onTap: () => Navigator.pop(ctx, r),
            ),
        ]),
      ),
    );
    if (other == null || !mounted) return;
    final (x, y) = remapPair(run, other);
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => RemapCompareScreen(before: x, after: y)));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final limits = remapLimitsFor(ref.watch(settingsProvider));
    final a = remapAnalysisOf(run, limits);
    final (title, advice) = a.verdictTh;
    final color = remapLevelColor(a.level);
    final baro = a.baro;
    List<(double, double)> gauge(List<(double, double)> pts) => [for (final (t, v) in pts) (t, v - baro)];
    final boost = gauge(run.signal(RemapSignal.boost));
    final boostCmd = gauge(run.signal(RemapSignal.boostCmd));
    final rail = run.signal(RemapSignal.rail);
    final railCmd = run.signal(RemapSignal.railCmd);
    final boostRpm = binnedMax(versusRpm(a, RemapSignal.boost));

    return Scaffold(
      appBar: AppBar(
        title: FitText(run.name),
        actions: [
          IconButton(tooltip: 'เปลี่ยนชื่อ', icon: const Icon(Icons.edit_rounded), onPressed: _rename),
          IconButton(tooltip: 'ลบ', icon: const Icon(Icons.delete_outline_rounded), onPressed: _delete),
        ],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
        PremiumCard(
          glow: color,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(_check(a.level).icon, color: color, size: 30),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17, color: color)),
                  const SizedBox(height: 2),
                  Text(advice, style: TextStyle(fontSize: 13, height: 1.45, color: cs.onSurfaceVariant)),
                ]),
              ),
            ]),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 6, children: [
              _StagePill(run.stage),
              Pill(text: thaiDate(run.start), color: cs.onSurfaceVariant),
              Pill(text: _durText(run.durationS), color: cs.onSurfaceVariant),
              Pill(text: '${run.hz.toStringAsFixed(1)}\u00A0คำสั่ง/วิ', color: cs.onSurfaceVariant),
              if (a.limpSuspected) const Pill(text: 'สงสัยโหมดป้องกันตัวเอง', color: StatusColors.bad, icon: Icons.shield_rounded),
            ]),
            if (run.vehicleLabel.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(run.vehicleLabel, style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant)),
            ],
          ]),
        ),
        const SizedBox(height: 10),
        SegmentedButton<RemapStage>(
          segments: [for (final s in RemapStage.values) ButtonSegment(value: s, label: FitText(s.labelTh, alignment: Alignment.center))],
          selected: {run.stage},
          showSelectedIcon: false,
          onSelectionChanged: (v) async {
            setState(() => run.stage = v.first);
            await _save();
          },
        ),
        const SectionLabel('อัตราเร่ง (วินาที)'),
        _accelTiles(a, color: remapStageColor(run.stage)),
        if (a.accel.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('ไม่มีช่วงที่วัดได้: ออกตัวจากจอดนิ่ง หรือเร่งต่อเนื่องผ่านช่วงความเร็ว',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          ),
        const SectionLabel('ค่าสูงสุด'),
        PremiumCard(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Column(children: [
            if (a.maxBoostGauge != null) KvRow('บูสต์สูงสุด (เกจ)', '${_fmt(a.maxBoostGauge)}\u00A0kPa'),
            if (a.maxBoostCmdGauge != null) KvRow('บูสต์ที่ต้องการสูงสุด (เกจ)', '${_fmt(a.maxBoostCmdGauge)}\u00A0kPa'),
            if (a.max[RemapSignal.rail] != null) KvRow('ความดันรางสูงสุด', '${_fmt(a.max[RemapSignal.rail], 1)}\u00A0MPa'),
            if (a.max[RemapSignal.railCmd] != null) KvRow('ความดันรางที่ต้องการสูงสุด', '${_fmt(a.max[RemapSignal.railCmd], 1)}\u00A0MPa'),
            if (a.max[RemapSignal.injQty] != null) KvRow('ปริมาณฉีดสูงสุด', '${_fmt(a.max[RemapSignal.injQty], 1)}\u00A0mm³'),
            if (a.max[RemapSignal.maf] != null) KvRow('มวลอากาศสูงสุด', '${_fmt(a.max[RemapSignal.maf], 1)}\u00A0g/s'),
            if (a.max[RemapSignal.rpm] != null) KvRow('รอบเครื่องสูงสุด', '${_fmt(a.max[RemapSignal.rpm])}\u00A0รอบ/นาที'),
            if (a.max[RemapSignal.speed] != null) KvRow('ความเร็วสูงสุด', '${_fmt(a.max[RemapSignal.speed])}\u00A0กม./ชม.'),
            if (a.max[RemapSignal.egt] != null) KvRow('อุณหภูมิไอเสียสูงสุด', '${_fmt(a.max[RemapSignal.egt])}\u00A0°C'),
            if (a.max[RemapSignal.coolant] != null) KvRow('น้ำหล่อเย็นสูงสุด', '${_fmt(a.max[RemapSignal.coolant])}\u00A0°C'),
            if (a.max[RemapSignal.iat] != null) KvRow('อากาศเข้าสูงสุด', '${_fmt(a.max[RemapSignal.iat])}\u00A0°C'),
            if (a.min[RemapSignal.voltage] != null) KvRow('แรงดันไฟต่ำสุด', '${_fmt(a.min[RemapSignal.voltage], 1)}\u00A0V'),
          ]),
        ),
        SectionLabel('สิ่งที่พบ (${a.events.length})'),
        PremiumCard(padding: const EdgeInsets.fromLTRB(14, 6, 14, 6), child: _EventList(events: a.events)),
        const SectionLabel('รหัสปัญหาเครื่องยนต์'),
        PremiumCard(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            KvRow('ก่อนทดสอบ', run.dtcBefore.isEmpty ? 'ไม่มี' : run.dtcBefore.join(', ')),
            KvRow('หลังทดสอบ', run.dtcAfter.isEmpty ? 'ไม่มี' : run.dtcAfter.join(', '),
                valueColor: run.dtcAfter.any((c) => !run.dtcBefore.contains(c)) ? StatusColors.bad : null),
            if (run.milAfter != null) KvRow('ไฟเตือนหลังทดสอบ', run.milAfter! ? 'ติด' : 'ดับ',
                valueColor: run.milAfter! ? StatusColors.bad : StatusColors.good),
            if (run.note.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 4),
                child: Text(run.note, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              ),
          ]),
        ),
        if (boost.length >= 2) ...[
          const SectionLabel('บูสต์ (เกจ, kPa)'),
          PremiumCard(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(spacing: 12, children: [
                const _Legend(color: _afterColor, text: 'จริง'),
                if (boostCmd.length >= 2) const _Legend(color: _beforeColor, text: 'ที่กล่องต้องการ'),
              ]),
              const SizedBox(height: 8),
              TimeChart(height: 220, series: [
                ChartSeries(label: 'จริง', points: boost, color: _afterColor, decimals: 0),
                if (boostCmd.length >= 2) ChartSeries(label: 'ต้องการ', points: boostCmd, color: _beforeColor, decimals: 0),
              ]),
            ]),
          ),
        ],
        if (rail.length >= 2) ...[
          const SectionLabel('ความดันราง (MPa)'),
          PremiumCard(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(spacing: 12, children: [
                const _Legend(color: _afterColor, text: 'จริง'),
                if (railCmd.length >= 2) const _Legend(color: _beforeColor, text: 'ที่กล่องต้องการ'),
              ]),
              const SizedBox(height: 8),
              TimeChart(height: 200, series: [
                ChartSeries(label: 'จริง', points: rail, color: _afterColor),
                if (railCmd.length >= 2) ChartSeries(label: 'ต้องการ', points: railCmd, color: _beforeColor),
              ]),
            ]),
          ),
        ],
        if (boostRpm.length >= 2) ...[
          const SectionLabel('บูสต์สูงสุดตามรอบเครื่อง (เร่งหนัก)'),
          PremiumCard(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
            child: XyChart(
              height: 200,
              xUnit: 'รอบ',
              yUnit: 'kPa',
              series: [XySeries(label: 'บูสต์', points: boostRpm, color: remapStageColor(run.stage))],
            ),
          ),
        ],
        if (run.signal(RemapSignal.speed).length >= 2) ...[
          const SectionLabel('ความเร็ว (กม./ชม.)'),
          PremiumCard(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
            child: TimeChart(height: 180, series: [
              ChartSeries(label: 'ความเร็ว', points: run.signal(RemapSignal.speed), color: StatusColors.good, decimals: 0),
            ]),
          ),
        ],
        const SizedBox(height: 16),
        Wrap(spacing: 10, runSpacing: 10, children: [
          FilledButton.icon(
            icon: const Icon(Icons.picture_as_pdf_rounded),
            label: const Text('รายงาน PDF'),
            onPressed: () => shareRemapPdf(context, ref, before: a),
          ),
          FilledButton.tonalIcon(
            icon: const Icon(Icons.compare_arrows_rounded),
            label: const Text('เทียบกับรอบอื่น'),
            onPressed: _pickCompare,
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.table_view_rounded),
            label: const Text('ส่งออก CSV'),
            onPressed: () => _shareCsv(context, run),
          ),
        ]),
      ]),
    );
  }
}

// ---------------------------------------------------------------- เทียบก่อน/หลัง

class RemapCompareScreen extends ConsumerStatefulWidget {
  const RemapCompareScreen({super.key, required this.before, required this.after});

  final RemapRun before;
  final RemapRun after;

  @override
  ConsumerState<RemapCompareScreen> createState() => _RemapCompareScreenState();
}

class _RemapCompareScreenState extends ConsumerState<RemapCompareScreen> {
  late RemapRun _a = widget.before;
  late RemapRun _b = widget.after;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final limits = remapLimitsFor(ref.watch(settingsProvider));
    final a = remapAnalysisOf(_a, limits), b = remapAnalysisOf(_b, limits);
    final rows = compareRemap(a, b);
    final accelRow = rows.where((r) => r.unit == 'วินาที' && r.diff != null).firstOrNull;
    final headColor = switch (accelRow?.better) {
      true => StatusColors.good,
      false => StatusColors.warn,
      null => StatusColors.info,
    };
    (AccelResult, AccelResult)? trace;
    for (final (from, to) in remapAccelRanges) {
      final x = a.accelFor(from, to), y = b.accelFor(from, to);
      if (x != null && y != null) {
        trace = (x, y);
        break;
      }
    }
    final boostA = binnedMax(versusRpm(a, RemapSignal.boost)), boostB = binnedMax(versusRpm(b, RemapSignal.boost));
    final railA = binnedMax(versusRpm(a, RemapSignal.rail)), railB = binnedMax(versusRpm(b, RemapSignal.rail));

    Widget cell(String s, {Color? color, FontWeight w = FontWeight.w700, TextAlign align = TextAlign.right}) => Padding(
          padding: EdgeInsets.fromLTRB(align == TextAlign.right ? 6 : 0, 7, 0, 7),
          child: Text(s, textAlign: align, style: TextStyle(fontWeight: w, color: color, fontSize: 13)),
        );

    // ส่วนต่างสองบรรทัด: ตัวเลข แล้วเปอร์เซ็นต์ (ไม่ให้ติดกับค่า "หลัง")
    Widget diffCell(RemapCompareRow r) {
      final color = switch (r.better) {
        true => StatusColors.good,
        false => StatusColors.bad,
        null => cs.onSurfaceVariant,
      };
      return Padding(
        padding: const EdgeInsets.fromLTRB(10, 7, 0, 7),
        child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(r.diffValueText, style: TextStyle(fontWeight: FontWeight.w700, color: color, fontSize: 13)),
          if (r.pctText != null) Text(r.pctText!, style: TextStyle(color: color, fontSize: 11)),
        ]),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const FitText('เทียบก่อน/หลัง'),
        actions: [
          IconButton(
            tooltip: 'สลับก่อน/หลัง',
            icon: const Icon(Icons.swap_horiz_rounded),
            onPressed: () => setState(() {
              final t = _a;
              _a = _b;
              _b = t;
            }),
          ),
          IconButton(
            tooltip: 'รายงาน PDF',
            icon: const Icon(Icons.picture_as_pdf_rounded),
            onPressed: () => shareRemapPdf(context, ref, before: a, after: b),
          ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
        PremiumCard(
          glow: headColor,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(remapCompareHeadline(rows), style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: headColor)),
            const SizedBox(height: 10),
            for (final (label, r, color) in [('ก่อน', _a, _beforeColor), ('หลัง', _b, _afterColor)])
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 9),
                    child: Container(width: 14, height: 4, color: color),
                  ),
                  const SizedBox(width: 8),
                  Text('$label: ', style: const TextStyle(fontWeight: FontWeight.w700)),
                  Expanded(
                    child: Text('${r.name}\u00A0· ${thaiDate(r.start, time: false)}', style: TextStyle(color: cs.onSurfaceVariant)),
                  ),
                ]),
              ),
            if (!_sameCar(_a, _b))
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text('สองรอบนี้อาจเป็นรถคนละคัน', style: TextStyle(color: StatusColors.warn, fontWeight: FontWeight.w600)),
              ),
          ]),
        ),
        const SectionLabel('เทียบตัวเลข'),
        PremiumCard(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
          child: Table(
            columnWidths: const {0: FlexColumnWidth(2.2), 1: FlexColumnWidth(1), 2: FlexColumnWidth(1), 3: FlexColumnWidth(1.5)},
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            children: [
              TableRow(children: [
                cell('', align: TextAlign.left),
                cell('ก่อน', color: _beforeColor),
                cell('หลัง', color: _afterColor),
                cell('ต่าง', color: cs.onSurfaceVariant),
              ]),
              for (final r in rows)
                TableRow(children: [
                  cell('${r.label}${r.unit.isEmpty ? '' : ' (${r.unit})'}', w: FontWeight.w400, align: TextAlign.left),
                  cell(r.fmt(r.before)),
                  cell(r.fmt(r.after)),
                  diffCell(r),
                ]),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text('เขียว = ดีขึ้น แดง = แย่ลง ค่าที่ไม่มีสีไม่ได้ตัดสิน (บูสต์สูงขึ้นไม่ได้แปลว่าดีเสมอ)',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
        ),
        if (trace != null) ...[
          SectionLabel('ความเร็วช่วง\u00A0${trace.$1.label}\u00A0กม./ชม.'),
          PremiumCard(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(spacing: 12, children: [
                _Legend(color: _beforeColor, text: 'ก่อน ${trace.$1.seconds.toStringAsFixed(2)}\u00A0วิ'),
                _Legend(color: _afterColor, text: 'หลัง ${trace.$2.seconds.toStringAsFixed(2)}\u00A0วิ'),
              ]),
              const SizedBox(height: 8),
              TimeChart(height: 220, series: [
                ChartSeries(label: 'ก่อน', points: accelTrace(a, trace.$1), color: _beforeColor, decimals: 0),
                ChartSeries(label: 'หลัง', points: accelTrace(b, trace.$2), color: _afterColor, decimals: 0),
              ]),
            ]),
          ),
        ],
        for (final (title, pa, pb, unit) in [
          ('บูสต์สูงสุดตามรอบเครื่อง (เกจ)', boostA, boostB, 'kPa'),
          ('ความดันรางสูงสุดตามรอบเครื่อง', railA, railB, 'MPa'),
        ])
          if (pa.length >= 2 || pb.length >= 2) ...[
            SectionLabel(title),
            PremiumCard(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Wrap(spacing: 12, children: [
                  _Legend(color: _beforeColor, text: 'ก่อน'),
                  _Legend(color: _afterColor, text: 'หลัง'),
                ]),
                const SizedBox(height: 8),
                XyChart(height: 210, xUnit: 'รอบ', yUnit: unit, series: [
                  XySeries(label: 'ก่อน', points: pa, color: _beforeColor),
                  XySeries(label: 'หลัง', points: pb, color: _afterColor),
                ]),
              ]),
            ),
          ],
        SectionLabel('สิ่งที่พบ: หลัง (${b.events.length})'),
        PremiumCard(padding: const EdgeInsets.fromLTRB(14, 6, 14, 6), child: _EventList(events: b.events)),
        SectionLabel('สิ่งที่พบ: ก่อน (${a.events.length})'),
        PremiumCard(padding: const EdgeInsets.fromLTRB(14, 6, 14, 6), child: _EventList(events: a.events)),
        const SizedBox(height: 16),
        FilledButton.icon(
          icon: const Icon(Icons.picture_as_pdf_rounded),
          label: const Text('ส่งรายงาน PDF เทียบก่อน/หลัง'),
          style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
          onPressed: () => shareRemapPdf(context, ref, before: a, after: b),
        ),
      ]),
    );
  }
}
