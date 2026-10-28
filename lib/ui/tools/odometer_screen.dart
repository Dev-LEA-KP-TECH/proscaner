import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/analysis/odometer_check.dart';
import '../../core/analysis/vin.dart';
import '../../core/obd/obd_service.dart';
import '../../core/obd/pids.dart';
import '../../data/garage_store.dart';
import '../../state/providers.dart';
import '../home_screen.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// ข้อมูลดิบที่อ่านจากรถเพื่อใช้ตรวจเลขไมล์
class OdoReading {
  const OdoReading({this.ecuKm, this.engineHours, this.ignitions, this.modelYear, this.vin});

  final double? ecuKm;
  final double? engineHours;
  final int? ignitions;
  final int? modelYear;
  final String? vin;
}

/// อ่านข้อมูลที่ใช้ตรวจเลขไมล์จากรถ (ใช้ทั้งหน้านี้และหน้าตรวจรถมือสอง)
Future<OdoReading> readOdometerData(ObdService service, String? vin) async {
  final pids = await service.readPids([Pid.odometer, Pid.engineRunTimeTotal]);
  int? ign;
  try {
    for (final e in await service.readEcuIdentities()) {
      if (e.ignitionCount != null && e.ignitionCount! > 0) {
        ign = e.ignitionCount;
        break;
      }
    }
  } catch (_) {
    ign = null;
  }
  final info = vin == null ? null : decodeVin17(vin);
  return OdoReading(
    ecuKm: pids[Pid.odometer],
    engineHours: pids[Pid.engineRunTimeTotal],
    ignitions: ign,
    modelYear: info?.valid == true ? info!.modelYear : null,
    vin: vin,
  );
}

/// ประวัติเลขไมล์ของรถคันนี้จากโรงรถ (ใช้ตรวจว่าเลขไมล์เคยลดลงหรือไม่)
List<OdoRecord> odoHistoryFor(Vehicle? v) => [
      for (final e in v?.odometer ?? const <OdoEntry>[])
        if (e.km != null) OdoRecord(e.time, e.km!),
    ];

class OdometerScreen extends ConsumerStatefulWidget {
  const OdometerScreen({super.key});

  @override
  ConsumerState<OdometerScreen> createState() => _OdometerScreenState();
}

class _OdometerScreenState extends ConsumerState<OdometerScreen> {
  final _dash = TextEditingController();
  bool _busy = false;
  OdoReading? _reading;
  OdometerResult? _result;
  String? _error;
  bool _saved = false;

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
      _saved = false;
    });
    try {
      final session = ref.read(sessionProvider);
      final reading = await readOdometerData(service, session.vin);
      final vehicle = ref.read(garageProvider.notifier).byVin(session.vin);
      final result = checkOdometer(OdometerInput(
        ecuKm: reading.ecuKm,
        dashboardKm: _dashKm,
        engineHours: reading.engineHours,
        ignitionCycles: reading.ignitions,
        modelYear: reading.modelYear,
        history: odoHistoryFor(vehicle),
      ));
      if (!mounted) return;
      setState(() {
        _reading = reading;
        _result = result;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'อ่านข้อมูลไม่สำเร็จ: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final r = _reading;
    if (r == null) return;
    if (ref.read(sessionProvider).isPractice) {
      setState(() => _saved = true);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('โหมดทดลอง: รถจำลองไม่ถูกบันทึกลงโรงรถ'),
      ));
      return;
    }
    final ok = await ref.read(garageProvider.notifier).addOdometer(
          r.vin,
          OdoEntry(
            time: DateTime.now(),
            ecuKm: r.ecuKm,
            dashKm: _dashKm,
            engineHours: r.engineHours,
            ignitions: r.ignitions,
          ),
        );
    if (!mounted) return;
    if (ok) {
      setState(() => _saved = true);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('รถคันนี้ไม่ส่ง VIN จึงระบุรถไม่ได้ ให้เพิ่มรถในโรงรถและใส่ VIN/ทะเบียนเอง'),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const FitText('เช็คเลขไมล์จริง')),
      body: NeedsConnection(
        message: 'เชื่อมต่อรถเพื่อเช็คเลขไมล์',
        builder: (context, service) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
          children: [
            PremiumCard(
              glow: cs.primary,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(Icons.speed_rounded, color: cs.primary),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text('ตรวจว่าเลขไมล์ถูกหมุนหรือไม่',
                        style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                  ),
                ]),
                const SizedBox(height: 8),
                Text(
                  'แอปเทียบเลขไมล์หน้าปัดกับข้อมูลที่กล่อง ECU เก็บไว้ (เลขไมล์ในกล่อง ชั่วโมงเครื่อง '
                  'จำนวนครั้งที่สตาร์ท อายุรถจาก VIN และประวัติที่เคยบันทึก)',
                  style: TextStyle(color: cs.onSurfaceVariant, height: 1.5, fontSize: 13),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _dash,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9,]'))],
                  decoration: const InputDecoration(
                    labelText: 'เลขไมล์บนหน้าปัด (กม.)',
                    hintText: 'เช่น 98,500',
                    prefixIcon: Icon(Icons.dashboard_customize_rounded),
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: _busy
                        ? const SizedBox(
                            width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
                        : const Icon(Icons.fact_check_rounded),
                    label: Text(_busy ? 'กำลังอ่านข้อมูลจากรถ…' : 'อ่านข้อมูลและตรวจ'),
                    onPressed: _busy ? null : () => _run(service),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text(_error!, style: TextStyle(color: cs.error)),
                ],
              ]),
            ),
            if (_result != null && _reading != null) ...[
              _VerdictCard(result: _result!),
              const SectionLabel('ข้อมูลที่อ่านได้'),
              _DataCard(reading: _reading!, dashKm: _dashKm),
              const SectionLabel('ผลการเทียบ'),
              PremiumCard(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Column(children: [
                  for (final c in _result!.checks) CheckRow(level: c.level, title: c.title, detail: c.detail),
                ]),
              ),
              if (_result!.estimateFromHours != null || _result!.estimateFromIgnitions != null) ...[
                const SectionLabel('ประมาณการระยะทางจากการใช้งานเครื่อง'),
                PremiumCard(
                  child: Column(children: [
                    if (_result!.estimateFromHours != null)
                      KvRow('จากชั่วโมงเครื่อง',
                          '${formatKm(_result!.estimateFromHours!.$1)} – ${formatKm(_result!.estimateFromHours!.$2)}'),
                    if (_result!.estimateFromIgnitions != null)
                      KvRow('จากจำนวนครั้งที่สตาร์ท',
                          '${formatKm(_result!.estimateFromIgnitions!.$1)} – ${formatKm(_result!.estimateFromIgnitions!.$2)}'),
                    const SizedBox(height: 6),
                    Text('ช่วงกว้างเพราะรูปแบบการใช้รถแต่ละคันต่างกัน ใช้ดูว่าเลขไมล์อยู่ในช่วงที่สมเหตุสมผลหรือไม่',
                        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant, height: 1.4)),
                  ]),
                ),
              ],
              const SizedBox(height: 14),
              OutlinedButton.icon(
                icon: Icon(_saved ? Icons.check_rounded : Icons.save_alt_rounded),
                label: Text(_saved ? 'บันทึกในโรงรถแล้ว' : 'บันทึกเลขไมล์นี้ไว้ในโรงรถ'),
                onPressed: _saved ? null : _save,
              ),
              const SizedBox(height: 14),
              const _Disclaimer(),
            ],
          ],
        ),
      ),
    );
  }
}

class _VerdictCard extends StatelessWidget {
  const _VerdictCard({required this.result});

  final OdometerResult result;

  @override
  Widget build(BuildContext context) {
    final (color, icon) = switch (result.verdict) {
      OdoVerdict.consistent => (StatusColors.good, Icons.verified_rounded),
      OdoVerdict.checkMore => (StatusColors.warn, Icons.help_rounded),
      OdoVerdict.suspicious => (StatusColors.bad, Icons.gpp_bad_rounded),
      OdoVerdict.insufficient => (StatusColors.info, Icons.info_rounded),
    };
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: PremiumCard(
        glow: color,
        child: Row(children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(color: color.withValues(alpha: 0.15), shape: BoxShape.circle),
            child: Icon(icon, color: color, size: 36),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(result.verdict.labelTh,
                  style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: color, height: 1.3)),
              if (result.referenceKm != null) ...[
                const SizedBox(height: 4),
                Text('อ้างอิง ${formatKm(result.referenceKm!)}', style: TextStyle(color: cs.onSurfaceVariant)),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}

class _DataCard extends StatelessWidget {
  const _DataCard({required this.reading, required this.dashKm});

  final OdoReading reading;
  final double? dashKm;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    const none = 'รถไม่ส่งค่านี้';
    return PremiumCard(
      child: Column(children: [
        KvRow('เลขไมล์หน้าปัด (กรอก)', dashKm == null ? 'ไม่ได้กรอก' : formatKm(dashKm!)),
        KvRow('เลขไมล์ในกล่อง ECU', reading.ecuKm == null ? none : formatKm(reading.ecuKm!),
            valueColor: reading.ecuKm == null ? cs.onSurfaceVariant : null),
        KvRow('ชั่วโมงเครื่องสะสม',
            reading.engineHours == null ? none : '${groupDigits(reading.engineHours!)}\u00A0ชม.',
            valueColor: reading.engineHours == null ? cs.onSurfaceVariant : null),
        KvRow('จำนวนครั้งที่สตาร์ท', reading.ignitions == null ? none : '${groupDigits(reading.ignitions!)}\u00A0ครั้ง',
            valueColor: reading.ignitions == null ? cs.onSurfaceVariant : null),
        KvRow('ปีรุ่นจาก VIN', reading.modelYear == null ? 'ไม่ทราบ' : '${reading.modelYear}'),
      ]),
    );
  }
}

class _Disclaimer extends StatelessWidget {
  const _Disclaimer();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(
        'ผลนี้เป็นหลักฐานประกอบการตัดสินใจ ไม่ใช่ข้อพิสูจน์ทางกฎหมาย รถรุ่นก่อนปี\u00A02019 ส่วนใหญ่ไม่ส่งเลขไมล์ผ่าน OBD '
        'และบางยี่ห้อเก็บเลขไมล์สำรองไว้ในกล่องอื่น (ABS, กล่องเกียร์, กล่องกุญแจ) ซึ่งต้องใช้เครื่องมือเฉพาะยี่ห้ออ่าน '
        'ควรดูประกอบกับสมุดเช็กระยะ สภาพพวงมาลัย เบาะ แป้นเหยียบ',
        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant, height: 1.5),
      ),
    );
  }
}
