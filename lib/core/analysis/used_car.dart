import '../diagnosis/diagnosis.dart';
import '../obd/dtc.dart';
import '../obd/dtc_database.dart';
import '../obd/mode06.dart';
import '../obd/pids.dart';
import '../uds/uds_client.dart';
import 'odometer_check.dart';

/// ข้อสังเกตหนึ่งข้อของการตรวจรถมือสอง
class UsedCarFlag {
  const UsedCarFlag(this.level, this.title, this.detail);
  final CheckLevel level;
  final String title;
  final String detail;
}

enum UsedCarRisk {
  low('ความเสี่ยงต่ำ', 'ไม่พบสัญญาณผิดปกติจากข้อมูล OBD'),
  medium('ความเสี่ยงปานกลาง', 'มีจุดที่ควรให้ช่างตรวจเพิ่มก่อนตัดสินใจ'),
  high('ความเสี่ยงสูง', 'พบสัญญาณที่ควรระวัง ควรต่อรองหรือตรวจละเอียดก่อนซื้อ');

  const UsedCarRisk(this.labelTh, this.adviceTh);
  final String labelTh;
  final String adviceTh;
}

class UsedCarReport {
  const UsedCarReport(this.risk, this.flags);
  final UsedCarRisk risk;
  final List<UsedCarFlag> flags;

  int get badCount => flags.where((f) => f.level == CheckLevel.bad).length;
  int get warnCount => flags.where((f) => f.level == CheckLevel.warn).length;
}

UsedCarReport evaluateUsedCar({
  required DiagnosisReport report,
  OdometerResult? odometer,
  List<EcuModule> modules = const [],
  List<Mode06Result> mode06 = const [],
  bool modulesScanned = true,
}) {
  final s = report.snapshot;
  final flags = <UsedCarFlag>[];
  double? p(int pid) => s.pids[pid];

  // 1) ร่องรอยการลบโค้ดก่อนขาย
  final dist = p(Pid.distanceSinceClear);
  final warm = p(Pid.warmupsSinceClear);
  final mins = p(Pid.timeSinceClear);
  final incomplete = s.incompleteMonitors.length;
  final recentClear = (dist != null && dist < 80) || (warm != null && warm < 8) || (mins != null && mins < 240);
  if (recentClear) {
    final parts = [
      if (dist != null) 'ขับมาแล้ว ${dist.round()} กม.',
      if (warm != null) 'อุ่นเครื่อง ${warm.round()} ครั้ง',
      if (mins != null) 'ติดเครื่องรวม ${mins.round()} นาที',
    ].join(', ');
    flags.add(UsedCarFlag(
      incomplete > 1 ? CheckLevel.bad : CheckLevel.warn,
      'เพิ่งมีการลบรหัสปัญหาไม่นาน',
      'หลังลบโค้ด $parts${incomplete > 1 ? ' และระบบตรวจสอบตัวเองยังไม่เสร็จ $incomplete ระบบ' : ''} '
          'ผู้ขายบางรายลบโค้ดเพื่อซ่อนปัญหา ให้ขับทดสอบ 2–3 วันแล้วสแกนใหม่',
    ));
  } else if (dist != null) {
    flags.add(UsedCarFlag(CheckLevel.ok, 'ไม่มีร่องรอยการลบโค้ดเร็วๆ นี้',
        'ขับมาแล้ว ${dist.round()} กม. ตั้งแต่ลบโค้ดครั้งล่าสุด'));
  }

  if (incomplete > 1 && !recentClear) {
    flags.add(UsedCarFlag(CheckLevel.warn, 'ระบบตรวจสอบตัวเองยังไม่เสร็จ $incomplete ระบบ',
        'อาจเพิ่งถอดแบตหรือลบโค้ด ยังไม่พร้อมตรวจสภาพ'));
  }

  // 2) รหัสปัญหาในกล่องเครื่องยนต์
  final permanent = s.ofKind(DtcKind.permanent).map((d) => d.code).toSet();
  if (permanent.isNotEmpty) {
    flags.add(UsedCarFlag(CheckLevel.bad, 'มีรหัสถาวร ${permanent.join(', ')}',
        'รหัสถาวรลบด้วยเครื่องมือไม่ได้ แปลว่าปัญหาเคยเกิดจริงและกล่องยังไม่ยืนยันว่าแก้หายแล้ว'));
  }
  final worst = report.findings.where((f) => f.code != null).fold<Severity>(
      Severity.info, (a, f) => f.severity > a ? f.severity : a);
  final codes = s.codes.difference(permanent);
  if (codes.isNotEmpty) {
    flags.add(UsedCarFlag(
      worst == Severity.high ? CheckLevel.bad : CheckLevel.warn,
      'พบรหัสปัญหาเครื่องยนต์ ${codes.length} รหัส',
      '${codes.join(', ')} ดูรายละเอียดในหน้าวินิจฉัย',
    ));
  } else if (permanent.isEmpty) {
    flags.add(const UsedCarFlag(CheckLevel.ok, 'ไม่มีรหัสปัญหาเครื่องยนต์', 'ทั้งแบบยืนยันแล้ว รอยืนยัน และถาวร'));
  }

  final milKm = p(Pid.distanceWithMil);
  if (milKm != null && milKm > 0) {
    flags.add(UsedCarFlag(CheckLevel.warn, 'เคยขับขณะไฟเตือนติด ${milKm.round()} กม.',
        'ปัญหาถูกปล่อยไว้ระยะหนึ่ง อาจมีความเสียหายต่อเนื่อง เช่น แคทหรือหัวเทียน'));
  }

  // 3) กล่องอื่น (ABS, ถุงลม, เกียร์)
  if (!modulesScanned) {
    flags.add(const UsedCarFlag(CheckLevel.warn, 'ตรวจได้เฉพาะกล่องเครื่องยนต์',
        'รถใช้โปรโตคอลรุ่นเก่า (ไม่ใช่ CAN) ตัวสแกน PRO SCANNER อ่าน ABS ถุงลม เกียร์ ของรถคันนี้ไม่ได้ ควรให้อู่ตรวจด้วยเครื่องมือเฉพาะยี่ห้อ'));
  }
  for (final m in modules) {
    if (m.error != null) {
      flags.add(UsedCarFlag(CheckLevel.info, '${m.title}: อ่านรหัสไม่ได้', '${m.error} — ไม่ได้แปลว่าไม่มีปัญหา'));
      continue;
    }
    if (m.dtcs.isEmpty) continue;
    final airbag = (m.name ?? '').toLowerCase().contains('air') ||
        (m.name ?? '').contains('ถุงลม') ||
        m.dtcs.any((d) => d.code.startsWith('B00'));
    flags.add(UsedCarFlag(
      airbag ? CheckLevel.bad : CheckLevel.warn,
      '${m.title}: พบ ${m.dtcs.length} รหัส',
      '${m.dtcs.map((d) => d.display).join(', ')}${airbag ? ' — ระบบถุงลมมีปัญหา อาจเคยชนหนัก' : ''}',
    ));
  }

  // 4) เลขไมล์
  if (odometer != null) {
    final lvl = switch (odometer.verdict) {
      OdoVerdict.suspicious => CheckLevel.bad,
      OdoVerdict.checkMore => CheckLevel.warn,
      OdoVerdict.consistent => CheckLevel.ok,
      OdoVerdict.insufficient => CheckLevel.info,
    };
    flags.add(UsedCarFlag(lvl, 'เลขไมล์: ${odometer.verdict.labelTh}',
        () {
          final problems = odometer.checks.where((c) => c.level == CheckLevel.bad || c.level == CheckLevel.warn);
          final src = problems.isNotEmpty ? problems : odometer.checks.where((c) => c.level == CheckLevel.ok);
          return src.map((c) => c.title).join(' · ');
        }()));
  }

  // 5) Mode 06: misfire สะสมรายสูบ
  final mis = mode06.where((r) => r.misfireCylinder != null && r.tid == 0x0B && r.value > 20).toList();
  if (mis.isNotEmpty) {
    flags.add(UsedCarFlag(CheckLevel.warn, 'มีการจุดระเบิดไม่สมบูรณ์สะสม',
        mis.map((r) => 'สูบ ${r.misfireCylinder}: ${r.value.round()} ครั้ง').join(', ')));
  }

  final bad = flags.where((f) => f.level == CheckLevel.bad).length;
  final warn = flags.where((f) => f.level == CheckLevel.warn).length;
  final risk = bad > 0 ? UsedCarRisk.high : (warn > 0 ? UsedCarRisk.medium : UsedCarRisk.low);
  flags.sort((a, b) => _rank(a.level).compareTo(_rank(b.level)));
  return UsedCarReport(risk, flags);
}

int _rank(CheckLevel l) => switch (l) {
      CheckLevel.bad => 0,
      CheckLevel.warn => 1,
      CheckLevel.ok => 2,
      CheckLevel.info => 3,
    };
