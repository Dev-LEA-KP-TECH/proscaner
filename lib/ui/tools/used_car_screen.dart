import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/analysis/odometer_check.dart';
import '../../core/analysis/used_car.dart';
import '../../core/analysis/vin.dart';
import '../../core/obd/obd_service.dart';
import '../../report/pdf_report.dart';
import '../../state/providers.dart';
import '../home_screen.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'odometer_screen.dart';

/// ตรวจรถมือสองแบบครบขั้นตอน: สแกนทั้งคัน + เลขไมล์ + ร่องรอยการลบโค้ด + Mode 06
class UsedCarScreen extends ConsumerStatefulWidget {
  const UsedCarScreen({super.key});

  @override
  ConsumerState<UsedCarScreen> createState() => _UsedCarScreenState();
}

class _UsedCarScreenState extends ConsumerState<UsedCarScreen> {
  final _dash = TextEditingController();
  bool _busy = false;
  String _stage = '';
  UsedCarReport? _result;
  OdometerResult? _odo;
  List<Mode06Result> _mode06 = const [];
  String? _error;

  @override
  void dispose() {
    _dash.dispose();
    super.dispose();
  }

  double? get _dashKm {
    final t = _dash.text.replaceAll(',', '').trim();
    return t.isEmpty ? null : double.tryParse(t);
  }

  Future<void> _run(ObdService service) async {
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
      _stage = 'สแกนทุกกล่องในรถ';
    });
    try {
      final scan = ref.read(scanProvider.notifier);
      if (ref.read(scanProvider).running) throw Exception('มีการสแกนอื่นกำลังทำงานอยู่ รอให้เสร็จก่อน');
      final ok = await scan.run(allModules: true, dashboardKm: _dashKm);
      final s = ref.read(scanProvider);
      final report = s.report;
      // ต้องเป็นผลของการสแกนครั้งนี้เท่านั้น ห้ามใช้ผลเก่า
      if (!ok || report == null || s.error != null) throw Exception(s.error ?? 'สแกนไม่สำเร็จ');

      if (mounted) setState(() => _stage = 'อ่านผลทดสอบเซ็นเซอร์ (Mode 06)');
      List<Mode06Result> m6;
      try {
        m6 = await service.readMode06();
      } catch (_) {
        m6 = const [];
      }

      if (mounted) setState(() => _stage = 'ตรวจเลขไมล์');
      final snap = report.snapshot;
      final vehicle = ref.read(garageProvider.notifier).byVin(snap.vin);
      // ประวัติไม่รวมรายการที่เพิ่งบันทึกจากการสแกนนี้
      final history = odoHistoryFor(vehicle).where((r) => r.time.isBefore(snap.time)).toList();
      final vin = snap.vin == null ? null : decodeVin17(snap.vin!);
      final odo = checkOdometer(OdometerInput(
        ecuKm: snap.ecuOdometerKm,
        dashboardKm: _dashKm,
        engineHours: snap.engineHours,
        ignitionCycles: snap.ignitionCycles,
        modelYear: vin != null && vin.valid ? vin.modelYear : null,
        history: history,
      ));

      final r = evaluateUsedCar(
        report: report,
        odometer: odo,
        modules: snap.modules,
        mode06: m6,
        modulesScanned: service.elm.isCan,
      );
      if (!mounted) return;
      setState(() {
        _result = r;
        _odo = odo;
        _mode06 = m6;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'ตรวจไม่สำเร็จ: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final scan = ref.watch(scanProvider);
    return Scaffold(
      appBar: AppBar(title: const FitText('ตรวจรถมือสอง')),
      body: NeedsConnection(
        message: 'เชื่อมต่อรถที่ต้องการตรวจ',
        builder: (context, service) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
          children: [
            PremiumCard(
              glow: cs.primary,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('ตรวจก่อนซื้อในครั้งเดียว', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                const SizedBox(height: 10),
                for (final t in const [
                  'รหัสปัญหาทุกกล่อง (เครื่อง เกียร์ ABS ถุงลม ฯลฯ)',
                  'ร่องรอยการลบโค้ดก่อนขาย',
                  'ความพร้อมตรวจสภาพ และรหัสถาวร',
                  'เลขไมล์ถูกหมุนหรือไม่',
                  'การจุดระเบิดไม่สมบูรณ์สะสม',
                ])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(children: [
                      Icon(Icons.check_rounded, size: 16, color: cs.primary),
                      const SizedBox(width: 8),
                      Expanded(child: Text(t, style: const TextStyle(fontSize: 13))),
                    ]),
                  ),
                const SizedBox(height: 12),
                TextField(
                  controller: _dash,
                  enabled: !_busy,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9,]'))],
                  decoration: const InputDecoration(
                    labelText: 'เลขไมล์บนหน้าปัด (กม.)',
                    prefixIcon: Icon(Icons.dashboard_customize_rounded),
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.policy_rounded),
                    label: Text(_busy ? 'กำลังตรวจ…' : 'เริ่มตรวจ (ประมาณ 1\u00A0นาที)'),
                    onPressed: _busy ? null : () => _run(service),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text(_error!, style: TextStyle(color: cs.error)),
                ],
              ]),
            ),
            if (_busy) ...[
              SectionLabel(_stage),
              PremiumCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  LinearProgressIndicator(value: scan.running ? scan.progress : null),
                  const SizedBox(height: 12),
                  StepList(steps: [
                    for (final st in scan.steps.length > 6 ? scan.steps.sublist(scan.steps.length - 6) : scan.steps)
                      (st.label, st.done),
                    if (!scan.running) (_stage, false),
                  ]),
                ]),
              ),
            ],
            if (_result != null) ...[
              _RiskCard(result: _result!),
              const SectionLabel('รายละเอียด'),
              PremiumCard(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Column(children: [
                  for (final f in _result!.flags) CheckRow(level: f.level, title: f.title, detail: f.detail),
                ]),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                icon: const Icon(Icons.picture_as_pdf_rounded),
                label: const Text('ส่งรายงาน PDF'),
                onPressed: () {
                  final report = ref.read(scanProvider).report;
                  if (report == null) return;
                  shareReportPdf(
                    context,
                    ref,
                    report: report,
                    usedCar: _result,
                    odometer: _odo,
                    mode06: _mode06,
                  );
                },
              ),
              const SizedBox(height: 12),
              Text(
                'OBD ตรวจได้เฉพาะระบบอิเล็กทรอนิกส์ ยังต้องตรวจสภาพตัวถัง ช่วงล่าง รอยชน น้ำท่วม และขับทดสอบจริงประกอบ',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant, height: 1.45),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RiskCard extends StatelessWidget {
  const _RiskCard({required this.result});

  final UsedCarReport result;

  @override
  Widget build(BuildContext context) {
    final color = switch (result.risk) {
      UsedCarRisk.low => StatusColors.good,
      UsedCarRisk.medium => StatusColors.warn,
      UsedCarRisk.high => StatusColors.bad,
    };
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: PremiumCard(
        glow: color,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(
              result.risk == UsedCarRisk.low ? Icons.thumb_up_alt_rounded : Icons.report_rounded,
              color: color,
              size: 34,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(result.risk.labelTh,
                  style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800, color: color)),
            ),
          ]),
          const SizedBox(height: 8),
          Text(result.risk.adviceTh, style: TextStyle(color: cs.onSurfaceVariant, height: 1.45)),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            Pill(text: 'ควรระวัง ${result.badCount}', color: StatusColors.bad, icon: Icons.cancel_rounded),
            Pill(text: 'ควรตรวจเพิ่ม ${result.warnCount}', color: StatusColors.warn, icon: Icons.error_rounded),
          ]),
        ]),
      ),
    );
  }
}
