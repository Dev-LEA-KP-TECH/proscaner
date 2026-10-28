import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/diagnosis/diagnosis.dart';
import '../core/diagnosis/report_text.dart';
import '../core/obd/dtc_database.dart';
import '../core/obd/pids.dart';
import '../core/uds/uds_client.dart';
import '../report/pdf_report.dart';
import '../state/providers.dart';
import 'home_screen.dart';
import 'theme.dart';
import 'tools/odometer_screen.dart';
import 'widgets/common.dart';
import 'widgets/gauges.dart';
import 'widgets/severity_style.dart';

class DiagnosisTab extends ConsumerWidget {
  const DiagnosisTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final scan = ref.watch(scanProvider);
    final mode = ref.watch(appModeProvider);
    final cs = Theme.of(context).colorScheme;

    if (!session.isConnected) {
      return const ConnectPrompt(message: 'เชื่อมต่อตัวสแกนเพื่อเริ่มวินิจฉัย');
    }

    if (scan.running) {
      final steps = scan.steps.length > 7 ? scan.steps.sublist(scan.steps.length - 7) : scan.steps;
      return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
        PremiumCard(
          glow: cs.primary,
          child: Column(children: [
            SizedBox(
              width: 120,
              height: 120,
              child: Stack(alignment: Alignment.center, children: [
                SizedBox.expand(
                  child: CircularProgressIndicator(
                    value: scan.progress > 0 ? scan.progress : null,
                    strokeWidth: 7,
                    strokeCap: StrokeCap.round,
                    color: cs.primary,
                    backgroundColor: cs.surfaceContainerHighest,
                  ),
                ),
                Text('${(scan.progress * 100).round()}%',
                    style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
              ]),
            ),
            const SizedBox(height: 18),
            Text('กำลังตรวจรถ', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(scan.step ?? '', textAlign: TextAlign.center, style: TextStyle(color: cs.onSurfaceVariant)),
          ]),
        ),
        const SizedBox(height: 12),
        PremiumCard(child: StepList(steps: [for (final st in steps) (st.label, st.done)])),
      ]);
    }

    final report = scan.report;
    if (report == null) {
      return _ReadyToScan(
        error: scan.error,
        mechanic: mode == AppMode.mechanic,
        onScan: (all, deep) => ref.read(scanProvider.notifier).run(allModules: all, deep: deep),
      );
    }

    return RefreshIndicator(
      onRefresh: () => ref.read(scanProvider.notifier).run(allModules: scan.fullScan),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          if (scan.error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(scan.error!, style: TextStyle(color: cs.error)),
            ),
          ReportView(report: report, mode: mode),
          const SizedBox(height: 12),
          PremiumCard(
            padding: const EdgeInsets.all(14),
            radius: 18,
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const OdometerScreen())),
            child: Row(children: [
              Icon(Icons.speed_rounded, color: cs.primary),
              const SizedBox(width: 12),
              const Expanded(child: Text('เช็คว่าเลขไมล์ถูกหมุนหรือไม่', style: TextStyle(fontWeight: FontWeight.w600))),
              const Icon(Icons.chevron_right_rounded),
            ]),
          ),
          const SizedBox(height: 16),
          ButtonPair(
            minWidth: 140,
            first: OutlinedButton.icon(
              icon: const Icon(Icons.refresh_rounded),
              label: FitText(scan.fullScan ? 'สแกนทั้งคันใหม่' : 'สแกนใหม่'),
              onPressed: () => ref.read(scanProvider.notifier).run(allModules: scan.fullScan),
            ),
            second: FilledButton.icon(
              icon: const Icon(Icons.picture_as_pdf_rounded),
              label: const FitText('รายงาน PDF'),
              onPressed: () => shareReportPdf(context, ref, report: report),
            ),
          ),
          const SizedBox(height: 10),
          Row(children: [
            if (!scan.fullScan)
              Expanded(
                child: TextButton.icon(
                  icon: const Icon(Icons.hub_rounded),
                  label: const FitText('สแกนทั้งคัน'),
                  onPressed: () => ref.read(scanProvider.notifier).run(allModules: true),
                ),
              ),
            Expanded(
              child: TextButton.icon(
                icon: const Icon(Icons.copy_all_rounded),
                label: const FitText('คัดลอกข้อความ'),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: buildReportText(report)));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('คัดลอกรายงานแล้ว วางส่งทาง LINE หรืออีเมลได้เลย')),
                    );
                  }
                },
              ),
            ),
          ]),
          if (report.snapshot.dtcs.isNotEmpty || report.snapshot.modules.any((m) => m.dtcs.isNotEmpty)) ...[
            const SizedBox(height: 4),
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: const Color(0xFFFF4D5A)),
              icon: const Icon(Icons.delete_sweep_rounded),
              label: Text(mode == AppMode.mechanic ? 'ลบรหัสปัญหา' : 'ลบรหัสปัญหา (หลังซ่อมเสร็จ)'),
              onPressed: () => _confirmClear(context, ref, report.snapshot.modules),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            'วิเคราะห์โดย ${report.engineName}\u00A0· ผลเป็นแนวทางเบื้องต้น ควรให้ช่างยืนยันก่อนเปลี่ยนอะไหล่',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmClear(BuildContext context, WidgetRef ref, List<EcuModule> modules) async {
    final withCodes = modules.where((m) => m.dtcs.isNotEmpty).toList();
    var includeModules = withCodes.isNotEmpty;
    final first = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('ลบรหัสปัญหา?'),
        content: const Text(
          'การลบรหัสจะ:\n'
          '• ดับไฟเตือนชั่วคราว แต่ถ้ายังไม่ได้ซ่อม รหัสจะกลับมา\n'
          '• รีเซ็ตผลทดสอบ readiness ทำให้ตรวจสภาพไม่ผ่านจนกว่าจะขับครบรอบ\n'
          '• ลบข้อมูล Freeze Frame ที่ช่างใช้วิเคราะห์\n\n'
          'ผลสแกนครั้งนี้ถูกบันทึกในประวัติแล้ว',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('ยกเลิก')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('ดำเนินการต่อ')),
        ],
      ),
    );
    if (first != true || !context.mounted) return;

    final second = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('ยืนยันอีกครั้ง'),
        content: StatefulBuilder(
          builder: (c, setD) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('จอดรถนิ่งแล้ว และต้องการลบรหัสทั้งหมดในกล่องเครื่องยนต์'),
            if (withCodes.isNotEmpty)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: includeModules,
                onChanged: (v) => setD(() => includeModules = v ?? false),
                title: Text('ลบรหัสกล่องอื่นด้วย (${withCodes.map((m) => m.title).join(', ')})'),
              ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('ยกเลิก')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFFF4D5A)),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('ลบรหัส'),
          ),
        ],
      ),
    );
    if (second != true || !context.mounted) return;

    final msg = await ref.read(scanProvider.notifier).clearCodes(modules: includeModules ? withCodes : const []);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }
}

class _ReadyToScan extends StatefulWidget {
  const _ReadyToScan({required this.onScan, required this.mechanic, this.error});

  final void Function(bool allModules, bool deep) onScan;
  final bool mechanic;
  final String? error;

  @override
  State<_ReadyToScan> createState() => _ReadyToScanState();
}

class _ReadyToScanState extends State<_ReadyToScan> {
  bool _deep = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
      PremiumCard(
        glow: cs.primary,
        padding: const EdgeInsets.fromLTRB(20, 28, 20, 22),
        child: Column(children: [
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(colors: [cs.primary.withValues(alpha: 0.35), cs.primary.withValues(alpha: 0.02)]),
            ),
            child: Icon(Icons.car_repair_rounded, size: 48, color: cs.primary),
          ),
          const SizedBox(height: 16),
          Text('พร้อมตรวจรถ', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(
            'สแกนด่วน: กล่องเครื่องยนต์ ~15\u00A0วินาที\nสแกนทั้งคัน: รวม ABS ถุงลม เกียร์ ฯลฯ ~30–60\u00A0วินาที',
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.onSurfaceVariant, height: 1.5),
          ),
          if (widget.error != null) ...[
            const SizedBox(height: 12),
            Text(widget.error!, textAlign: TextAlign.center, style: TextStyle(color: cs.error)),
          ],
          const SizedBox(height: 22),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              icon: const Icon(Icons.radar_rounded),
              label: const Text('สแกนด่วน'),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 58)),
              onPressed: () => widget.onScan(false, false),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              icon: const Icon(Icons.hub_rounded),
              label: const Text('สแกนทั้งคัน'),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 54)),
              onPressed: () => widget.onScan(true, _deep),
            ),
          ),
          if (widget.mechanic)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _deep,
              onChanged: (v) => setState(() => _deep = v),
              title: const Text('ค้นหากล่องแบบละเอียด', style: TextStyle(fontSize: 14)),
              subtitle: const Text('ไล่ทุกที่อยู่ ใช้เวลา ~2\u00A0นาที', style: TextStyle(fontSize: 12)),
            ),
        ]),
      ),
      const SizedBox(height: 14),
      const Row(children: [
        Expanded(child: _Feature(icon: Icons.translate_rounded, text: 'แปลรหัส\nเป็นภาษาไทย')),
        SizedBox(width: 10),
        Expanded(child: _Feature(icon: Icons.insights_rounded, text: 'ยืนยันด้วย\nค่าสด')),
        SizedBox(width: 10),
        Expanded(child: _Feature(icon: Icons.fact_check_rounded, text: 'เช็กพร้อม\nตรวจสภาพ')),
      ]),
    ]);
  }
}

class _Feature extends StatelessWidget {
  const _Feature({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return PremiumCard(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
      radius: 18,
      child: Column(children: [
        Icon(icon, color: cs.primary),
        const SizedBox(height: 8),
        Text(text, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, height: 1.35)),
      ]),
    );
  }
}

/// สรุปผลและรายการประเด็น ใช้ทั้งหน้าวินิจฉัยและหน้าประวัติ
class ReportView extends StatelessWidget {
  const ReportView({super.key, required this.report, required this.mode});

  final DiagnosisReport report;
  final AppMode mode;

  @override
  Widget build(BuildContext context) {
    final s = report.snapshot;
    final mech = mode == AppMode.mechanic;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _HeroCard(report: report, mode: mode),
      if (s.readiness.isNotEmpty) ...[
        SectionLabel('ความพร้อมตรวจสภาพ', trailing: _ReadyBadge(ready: s.inspectionReady)),
        _ReadinessCard(snapshot: s),
      ],
      if (mech && s.freezeFrame != null) ...[
        SectionLabel('ข้อมูลตอนเกิดปัญหา\u00A0· ${s.freezeFrame!.dtc}'),
        _FreezeFrameCard(snapshot: s),
      ],
      if (s.modules.isNotEmpty) ...[
        SectionLabel('กล่องที่สแกน (${s.modules.length + 1})'),
        _ModulesCard(snapshot: s),
      ],
      SectionLabel('ผลวิเคราะห์ (${report.findings.length})'),
      for (final f in report.findings)
        Padding(padding: const EdgeInsets.only(bottom: 10), child: _FindingCard(finding: f, mode: mode)),
    ]);
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({required this.report, required this.mode});

  final DiagnosisReport report;
  final AppMode mode;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = report.snapshot;
    final color = report.overall.color(cs);
    return PremiumCard(
      glow: color,
      padding: const EdgeInsets.all(18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // จอแคบ (มือถือ/ตัวอักษรใหญ่): วงคะแนนเล็กลง หัวข้ออยู่ข้างวง คำแนะนำเต็มความกว้างใต้วง
        // ข้อความจึงไม่ถูกบีบจนขึ้นบรรทัดใหม่ทีละคำ
        LayoutBuilder(builder: (context, box) {
          final narrow = box.maxWidth / (MediaQuery.textScalerOf(context).scale(100) / 100) < 330;
          final status = Row(children: [
            Icon(report.overall.icon, color: color, size: 18),
            const SizedBox(width: 6),
            Flexible(child: Text(report.overall.labelTh, style: TextStyle(color: color, fontWeight: FontWeight.w800))),
          ]);
          final headline = Text(thaiKeep(report.headlineTh),
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w900, height: 1.25, fontSize: narrow ? 19 : null));
          // คำแนะนำแสดงครบทุกบรรทัด ไม่ตัดท้าย (เป็นข้อความสำคัญต่อความปลอดภัย)
          final advice = Text(thaiKeep(report.overall.ownerAdvice),
              style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant, height: 1.4));
          if (narrow) {
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                ScoreRing(score: report.healthScore, color: color, size: 80),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    status,
                    const SizedBox(height: 6),
                    headline,
                  ]),
                ),
              ]),
              const SizedBox(height: 10),
              advice,
            ]);
          }
          return Row(children: [
            ScoreRing(score: report.healthScore, color: color, size: 108),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                status,
                const SizedBox(height: 6),
                headline,
                const SizedBox(height: 6),
                advice,
              ]),
            ),
          ]);
        }),
        const SizedBox(height: 16),
        Wrap(spacing: 8, runSpacing: 8, children: [
          _Pill(
            icon: Icons.warning_amber_rounded,
            text: 'ไฟเตือน ${s.milOn ? 'ติด' : 'ดับ'}',
            color: s.milOn ? const Color(0xFFFFA824) : const Color(0xFF22C474),
          ),
          _Pill(icon: Icons.qr_code_2_rounded, text: 'รหัส\u00A0${s.codes.length}', color: cs.primary),
          if (mode == AppMode.mechanic)
            _Pill(icon: Icons.local_gas_station_rounded, text: s.fuelName, color: cs.onSurfaceVariant),
          if (mode == AppMode.mechanic && s.vin != null)
            _Pill(icon: Icons.badge_rounded, text: s.vin!, color: cs.onSurfaceVariant, mono: true),
        ]),
      ]),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.text, required this.color, this.mono = false});

  final IconData icon;
  final String text;
  final Color color;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 6),
        Flexible(
          child: Text(text,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: color,
                fontFamily: mono ? kMono : null,
                fontFamilyFallback: const [kFont],
              )),
        ),
      ]),
    );
  }
}

class _ReadyBadge extends StatelessWidget {
  const _ReadyBadge({required this.ready});

  final bool ready;

  @override
  Widget build(BuildContext context) {
    final c = ready ? const Color(0xFF22C474) : const Color(0xFFFFA824);
    return _Pill(
      icon: ready ? Icons.verified_rounded : Icons.hourglass_top_rounded,
      text: ready ? 'พร้อม' : 'ยังไม่พร้อม',
      color: c,
    );
  }
}

class _ReadinessCard extends StatelessWidget {
  const _ReadinessCard({required this.snapshot});

  final VehicleSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final mons = snapshot.readiness;
    final done = mons.where((m) => m.complete).length;
    return PremiumCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('$done/${mons.length}', style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(snapshot.milOn ? 'เสร็จแล้ว แต่ไฟเตือนติดอยู่ จึงยังไม่ผ่านตรวจสภาพ' : 'ระบบทดสอบตัวเองเสร็จแล้ว',
                style: TextStyle(color: cs.onSurfaceVariant)),
          ),
        ]),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: mons.isEmpty ? 0 : done / mons.length,
            minHeight: 8,
            color: const Color(0xFF22C474),
            backgroundColor: cs.surfaceContainerHighest,
          ),
        ),
        const SizedBox(height: 14),
        for (final m in mons)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(children: [
              Icon(
                m.complete ? Icons.check_circle_rounded : Icons.pending_rounded,
                size: 19,
                color: m.complete ? const Color(0xFF22C474) : const Color(0xFFFFA824),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(thaiKeep(m.nameTh))),
              Text(
                m.complete ? 'เสร็จ' : 'ยังไม่เสร็จ',
                style: TextStyle(
                  fontSize: 12.5,
                  color: m.complete ? cs.onSurfaceVariant : const Color(0xFFFFA824),
                  fontWeight: m.complete ? FontWeight.w500 : FontWeight.w700,
                ),
              ),
            ]),
          ),
      ]),
    );
  }
}

class _FreezeFrameCard extends ConsumerWidget {
  const _FreezeFrameCard({required this.snapshot});

  final VehicleSnapshot snapshot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final settings = ref.watch(settingsProvider);
    final ff = snapshot.freezeFrame!;
    final entries = ff.values.entries.where((e) => pidTable[e.key] != null).toList();
    return PremiumCard(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
      child: Column(children: [
        for (var i = 0; i < entries.length; i++) ...[
          if (i > 0) Divider(color: cs.outline, height: 18),
          Builder(builder: (context) {
            final def = pidTable[entries[i].key]!;
            final dv = displayPid(def, entries[i].value, settings);
            final now = snapshot.pids[def.pid];
            // ชื่อค่าได้ที่มากสุด ค่าตอนเกิดปัญหาและค่าตอนนี้ซ้อนกันชิดขวา (จอแคบชื่อไม่ถูกบีบจนหักกลางคำ)
            return Row(children: [
              Expanded(child: Text(thaiKeep(def.nameTh), style: const TextStyle(height: 1.3))),
              const SizedBox(width: 10),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(dv.withUnit.replaceAll(' ', '\u00A0'), style: const TextStyle(fontWeight: FontWeight.w800)),
                if (now != null)
                  Text('ตอนนี้\u00A0${displayPid(def, now, settings).text}',
                      style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
              ]),
            ]);
          }),
        ],
      ]),
    );
  }
}

class _FindingCard extends StatelessWidget {
  const _FindingCard({required this.finding, required this.mode});

  final Finding finding;
  final AppMode mode;

  @override
  Widget build(BuildContext context) {
    final f = finding;
    final mech = mode == AppMode.mechanic;
    final cs = Theme.of(context).colorScheme;
    final color = f.severity.color(cs);
    final causes = mech ? f.causes : f.causes.take(3).toList();
    final label = TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: cs.onSurface);

    return PremiumCard(
      glow: f.severity == Severity.high ? color : null,
      padding: EdgeInsets.zero,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: f.severity == Severity.high,
          tilePadding: const EdgeInsets.fromLTRB(14, 6, 12, 6),
          leading: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(12)),
            child: Icon(f.severity.icon, color: color),
          ),
          title: Text(thaiKeep(f.title), style: const TextStyle(fontWeight: FontWeight.w700, height: 1.35)),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              SeverityChip(f.severity),
              if (f.code != null)
                Text(f.code!, style: const TextStyle(fontFamily: kMono, fontWeight: FontWeight.w800)),
              if (f.module != null)
                Text(f.module!, style: TextStyle(fontSize: 12, color: cs.primary, fontWeight: FontWeight.w700)),
              if (mech && f.kinds.isNotEmpty)
                Text(f.kinds.map((k) => k.labelTh).join('\u00A0· '), style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              if (mech && f.ecus.isNotEmpty)
                Text('ECU ${f.ecus.join(', ')}', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            ]),
          ),
          childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!mech) ...[
              Text('ควรทำอย่างไร', style: label),
              const SizedBox(height: 4),
              Text(thaiKeep(f.severity.ownerAdvice), style: const TextStyle(height: 1.45)),
              const SizedBox(height: 12),
            ],
            if (f.evidence.isNotEmpty) ...[
              Text(mech ? 'หลักฐานจากค่าสด' : 'ข้อสังเกต', style: label),
              for (final e in mech ? f.evidence : f.evidence.take(1)) _bullet(e, Icons.insights_rounded, cs.primary),
              const SizedBox(height: 12),
            ],
            if (causes.isNotEmpty) ...[
              Text(mech ? 'สาเหตุที่เป็นไปได้ (เรียงตามความน่าจะเป็น)' : 'สาเหตุที่พบบ่อย', style: label),
              for (var i = 0; i < causes.length; i++) _numbered(i + 1, causes[i], color),
              const SizedBox(height: 12),
            ],
            if (mech && f.checks.isNotEmpty) ...[
              Text('ขั้นตอนตรวจเช็ก', style: label),
              for (final c in f.checks) _bullet(c, Icons.check_box_outline_blank_rounded, cs.onSurfaceVariant),
            ],
          ],
        ),
      ),
    );
  }

  Widget _bullet(String text, IconData icon, Color color) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(top: 2, right: 8), child: Icon(icon, size: 16, color: color)),
          Expanded(child: Text(thaiKeep(text), style: const TextStyle(height: 1.45))),
        ]),
      );

  Widget _numbered(int n, String text, Color color) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 20,
            height: 20,
            margin: const EdgeInsets.only(right: 8, top: 1),
            alignment: Alignment.center,
            decoration: BoxDecoration(color: color.withValues(alpha: 0.16), shape: BoxShape.circle),
            child: Text('$n', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: color)),
          ),
          Expanded(child: Text(thaiKeep(text), style: const TextStyle(height: 1.45))),
        ]),
      );
}

class _ModulesCard extends StatelessWidget {
  const _ModulesCard({required this.snapshot});

  final VehicleSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget row(String name, int codes, String? err) {
      final color = err != null ? StatusColors.info : (codes == 0 ? StatusColors.good : StatusColors.warn);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          Icon(err != null ? Icons.help_rounded : (codes == 0 ? Icons.check_circle_rounded : Icons.error_rounded),
              size: 19, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text(name)),
          Text(err != null ? 'อ่านไม่ได้' : (codes == 0 ? 'ปกติ' : '$codes\u00A0รหัส'),
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: codes == 0 && err == null ? cs.onSurfaceVariant : color)),
        ]),
      );
    }

    return PremiumCard(
      child: Column(children: [
        row('เครื่องยนต์ (OBD)', snapshot.codes.length, null),
        for (final m in snapshot.modules) row(m.title, m.dtcs.length, m.error),
      ]),
    );
  }
}
