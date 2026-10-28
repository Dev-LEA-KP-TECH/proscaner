import '../obd/dtc.dart';
import '../obd/dtc_database.dart';
import '../obd/freeze_frame.dart';
import '../obd/mode09.dart';
import '../obd/pids.dart';
import '../obd/readiness.dart';
import '../uds/uds_client.dart';

/// ข้อมูลทั้งหมดที่อ่านได้จากรถในการสแกนหนึ่งครั้ง
class VehicleSnapshot {
  VehicleSnapshot({
    required this.time,
    required this.dtcs,
    required this.pids,
    this.milOn = false,
    this.isDiesel = false,
    this.vin,
    this.readiness = const [],
    this.freezeFrame,
    this.modules = const [],
    this.ecuIds = const [],
    this.dashboardKm,
  });

  final DateTime time;
  final List<Dtc> dtcs;
  final Map<int, double> pids;
  final bool milOn;
  final bool isDiesel;
  final String? vin;
  final List<ReadinessMonitor> readiness;
  final FreezeFrame? freezeFrame;

  /// กล่องอื่นๆ ที่สแกนพบ (ABS, ถุงลม, เกียร์ ฯลฯ) พร้อมรหัสปัญหา — มีเมื่อสแกนทั้งคัน
  final List<EcuModule> modules;

  /// ข้อมูลกล่องจาก Mode 09 (ชื่อ, Calibration ID, CVN, ตัวนับ)
  final List<EcuIdentity> ecuIds;

  /// เลขไมล์บนหน้าปัดที่ผู้ใช้กรอก
  final double? dashboardKm;

  double? get ecuOdometerKm => pids[Pid.odometer];
  double? get engineHours => pids[Pid.engineRunTimeTotal];
  int? get ignitionCycles {
    for (final e in ecuIds) {
      if (e.ignitionCount != null) return e.ignitionCount;
    }
    return null;
  }

  /// ชนิดเชื้อเพลิงจาก PID 51 ถ้ามี ไม่เช่นนั้นเดาจาก PID 01
  String get fuelName {
    final ft = pids[Pid.fuelType];
    if (ft != null) return fuelTypeName(ft.round());
    return isDiesel ? 'ดีเซล' : 'เบนซิน';
  }

  bool get diesel => pids[Pid.fuelType] != null ? pids[Pid.fuelType]!.round() == 4 : isDiesel;

  /// ระบบที่ยังทดสอบไม่เสร็จ (ไม่นับระบบแบบต่อเนื่อง)
  Iterable<ReadinessMonitor> get incompleteMonitors => readiness.where((m) => !m.complete);

  /// พร้อมตรวจสภาพ/ตรวจมลพิษ: ไฟเตือนดับ และระบบยังไม่เสร็จไม่เกิน 1 รายการ
  bool get inspectionReady => !milOn && incompleteMonitors.length <= 1;

  Iterable<Dtc> ofKind(DtcKind k) => dtcs.where((d) => d.kind == k);
  Set<String> get codes => dtcs.map((d) => d.code).toSet();
  double? pid(int p) => pids[p];

  Map<String, dynamic> toJson() => {
        'time': time.toIso8601String(),
        'dtcs': dtcs.map((d) => d.toJson()).toList(),
        'pids': pids.map((k, v) => MapEntry(k.toString(), v)),
        'milOn': milOn,
        'isDiesel': isDiesel,
        'vin': vin,
        'readiness': readiness.map((m) => m.toJson()).toList(),
        if (freezeFrame != null) 'freeze': freezeFrame!.toJson(),
        if (modules.isNotEmpty) 'modules': modules.map((m) => m.toJson()).toList(),
        if (ecuIds.isNotEmpty) 'ecuIds': ecuIds.map((e) => e.toJson()).toList(),
        if (dashboardKm != null) 'dashKm': dashboardKm,
      };

  factory VehicleSnapshot.fromJson(Map<String, dynamic> j) => VehicleSnapshot(
        time: DateTime.parse(j['time'] as String),
        dtcs: (j['dtcs'] as List<dynamic>).map((e) => Dtc.fromJson(e as Map<String, dynamic>)).toList(),
        pids: (j['pids'] as Map<String, dynamic>)
            .map((k, v) => MapEntry(int.parse(k), (v as num).toDouble())),
        milOn: j['milOn'] as bool? ?? false,
        isDiesel: j['isDiesel'] as bool? ?? false,
        vin: j['vin'] as String?,
        readiness: (j['readiness'] as List<dynamic>? ?? const [])
            .map((e) => ReadinessMonitor.fromJson(e as Map<String, dynamic>))
            .toList(),
        freezeFrame:
            j['freeze'] == null ? null : FreezeFrame.fromJson(j['freeze'] as Map<String, dynamic>),
        modules: (j['modules'] as List<dynamic>? ?? const [])
            .map((e) => EcuModule.fromJson(e as Map<String, dynamic>))
            .toList(),
        ecuIds: (j['ecuIds'] as List<dynamic>? ?? const [])
            .map((e) => EcuIdentity.fromJson(e as Map<String, dynamic>))
            .toList(),
        dashboardKm: (j['dashKm'] as num?)?.toDouble(),
      );

  VehicleSnapshot copyWith({double? dashboardKm}) => VehicleSnapshot(
        time: time,
        dtcs: dtcs,
        pids: pids,
        milOn: milOn,
        isDiesel: isDiesel,
        vin: vin,
        readiness: readiness,
        freezeFrame: freezeFrame,
        modules: modules,
        ecuIds: ecuIds,
        dashboardKm: dashboardKm ?? this.dashboardKm,
      );
}

/// ผลวินิจฉัยหนึ่งประเด็น (จากโค้ด หรือจากค่าเซ็นเซอร์ที่ผิดปกติ)
class Finding {
  Finding({
    required this.title,
    required this.severity,
    this.code,
    this.module,
    Set<DtcKind>? kinds,
    Set<String>? ecus,
    List<String>? causes,
    List<String>? checks,
    List<String>? evidence,
  })  : kinds = kinds ?? {},
        ecus = ecus ?? {},
        causes = causes ?? [],
        checks = checks ?? [],
        evidence = evidence ?? [];

  final String title;
  Severity severity;
  final String? code;

  /// ชื่อกล่องที่รายงาน (เฉพาะรหัสจากกล่องอื่นที่ไม่ใช่ OBD เครื่องยนต์)
  final String? module;
  final Set<DtcKind> kinds;
  final Set<String> ecus;
  final List<String> causes;
  final List<String> checks;

  /// หลักฐานจากค่าสดที่สนับสนุนหรือแย้งผลวินิจฉัย (แสดงในโหมดช่าง)
  final List<String> evidence;

  bool get pendingOnly => kinds.isNotEmpty && kinds.every((k) => k == DtcKind.pending);
}

class DiagnosisReport {
  DiagnosisReport({required this.snapshot, required this.findings, required this.engineName});

  final VehicleSnapshot snapshot;
  final List<Finding> findings;
  final String engineName;

  Severity get overall =>
      findings.fold(Severity.info, (s, f) => f.severity > s ? f.severity : s);

  /// คะแนนสุขภาพรถ 0–100 สำหรับแสดงเป็นวงแหวน
  int get healthScore {
    var score = 100;
    for (final f in findings) {
      score -= switch (f.severity) {
        Severity.high => 35,
        Severity.medium => 15,
        Severity.low => 5,
        Severity.info => 0,
      };
    }
    if (snapshot.milOn) score -= 5;
    score -= snapshot.incompleteMonitors.length * 2;
    return score.clamp(0, 100);
  }

  String get headlineTh => switch (overall) {
        Severity.info => 'ไม่พบปัญหาที่บันทึกไว้',
        Severity.low => 'พบปัญหาเล็กน้อย ยังขับได้',
        Severity.medium => 'พบปัญหาที่ควรให้ช่างตรวจ',
        Severity.high => 'พบปัญหาร้ายแรง ควรหยุดขับ',
      };
}

/// จุดเสียบตัววินิจฉัย: MVP ใช้กฎในเครื่อง เฟส 2 เปลี่ยนเป็น AI ได้โดยไม่แตะ UI
abstract interface class DiagnosisEngine {
  String get name;
  Future<DiagnosisReport> analyze(VehicleSnapshot snapshot);
}

/// ตัววินิจฉัยด้วยกฎ: แปลโค้ดจากฐานข้อมูล แล้วใช้ค่าสดยืนยันหรือจัดลำดับสาเหตุ
class RuleBasedDiagnosisEngine implements DiagnosisEngine {
  RuleBasedDiagnosisEngine(this.db);

  final DtcDatabase db;

  @override
  String get name => 'กฎวิเคราะห์ในเครื่อง';

  @override
  Future<DiagnosisReport> analyze(VehicleSnapshot s) async {
    final byCode = <String, Finding>{};

    // 1) หนึ่งประเด็นต่อหนึ่งรหัส รวมทุกประเภท (ยืนยันแล้ว/รอยืนยัน/ถาวร)
    for (final dtc in s.dtcs) {
      final existing = byCode[dtc.code];
      if (existing != null) {
        existing.kinds.add(dtc.kind);
        if (dtc.ecu.isNotEmpty) existing.ecus.add(dtc.ecu);
        continue;
      }
      final info = db.lookup(dtc.code);
      byCode[dtc.code] = Finding(
        title: info.descriptionTh,
        severity: info.severity,
        code: dtc.code,
        kinds: {dtc.kind},
        ecus: {if (dtc.ecu.isNotEmpty) dtc.ecu},
        causes: [...info.causes],
        checks: [...info.checks],
      );
    }

    // รหัสที่รอยืนยันอย่างเดียว ลดความรุนแรงลงหนึ่งระดับ
    for (final f in byCode.values) {
      if (f.pendingOnly) {
        // ลดหนึ่งระดับ แต่ไม่ต่ำกว่า "ขับต่อได้" เพราะยังมีรหัสอยู่จริง
        final lowered = f.severity.lower();
        f.severity = lowered == Severity.info ? Severity.low : lowered;
        f.evidence.add('ยังเป็นรหัสรอยืนยัน ECU พบครั้งเดียว อาจหายเองหรือกลายเป็นรหัสยืนยันในรอบขับถัดไป');
      }
      if (f.kinds.length == 1 && f.kinds.first == DtcKind.permanent) {
        f.evidence.add('เหลือเฉพาะรหัสถาวร: ซ่อมแล้วแต่ ECU ยังทดสอบระบบนี้ไม่ผ่านรอบขับ ลบด้วยเครื่องมือไม่ได้');
      }
    }

    final extra = <Finding>[];
    _fuelTrimRules(s, byCode);
    _misfireRules(s, byCode);
    _catalystRules(s, byCode);
    _coolantRules(s, byCode, extra);
    _voltageRules(s, extra);

    // รหัสจากกล่องอื่น (ABS, ถุงลม, เกียร์ ฯลฯ)
    for (final m in s.modules) {
      for (final d in m.dtcs) {
        final info = db.lookup(d.code);
        final ftb = d.ftbTh;
        extra.add(Finding(
          title: '${info.descriptionTh}${ftb != null ? ' ($ftb)' : ''}',
          severity: info.severity,
          code: d.display,
          module: m.title,
          ecus: {m.rx},
          causes: [...info.causes],
          checks: [...info.checks],
          evidence: ['สถานะ: ${d.statusTh}'],
        ));
      }
    }

    final ff = s.freezeFrame;
    if (ff != null && byCode[ff.dtc] != null) {
      final v = ff.values;
      final parts = <String>[
        if (v[Pid.rpm] != null) 'รอบ ${v[Pid.rpm]!.round()}',
        if (v[Pid.speed] != null) 'ความเร็ว ${v[Pid.speed]!.round()} กม./ชม.',
        if (v[Pid.engineLoad] != null) 'ภาระ ${v[Pid.engineLoad]!.round()}%',
        if (v[Pid.coolantTemp] != null) 'น้ำ ${v[Pid.coolantTemp]!.round()} °C',
      ];
      if (parts.isNotEmpty) {
        byCode[ff.dtc]!.evidence.insert(0, 'ตอนเกิดปัญหา (Freeze Frame): ${parts.join(', ')}');
      }
    }

    final incomplete = s.incompleteMonitors.toList();
    if (incomplete.length > 1) {
      extra.add(Finding(
        title: 'ระบบตรวจสอบตัวเองยังทดสอบไม่ครบ ${incomplete.length} ระบบ',
        severity: Severity.info,
        evidence: ['ยังไม่เสร็จ: ${incomplete.map((m) => m.nameTh).join(', ')}'],
        causes: ['เพิ่งลบรหัสหรือถอดแบตเตอรี่', 'ยังขับไม่ครบรอบทดสอบ (drive cycle)'],
        checks: ['ขับใช้งานปกติ 2–3 วัน ทั้งในเมืองและทางยาว แล้วสแกนอีกครั้งก่อนตรวจสภาพ'],
      ));
    }

    if (s.milOn && s.ofKind(DtcKind.stored).isEmpty) {
      extra.add(Finding(
        title: 'ไฟเตือนเครื่องยนต์ติด แต่ไม่พบรหัสในระบบเครื่องยนต์',
        severity: Severity.medium,
        causes: ['รหัสอาจอยู่ในกล่องอื่น เช่น เกียร์หรือ ABS ที่ OBD-II มาตรฐานอ่านไม่ได้'],
        checks: ['อ่านโค้ดด้วยคำสั่งเฉพาะยี่ห้อ (เฟส 3) หรือเครื่องมือของศูนย์'],
      ));
    }

    final findings = [...byCode.values, ...extra]
      ..sort((a, b) => b.severity.index.compareTo(a.severity.index));

    if (findings.isEmpty) {
      findings.add(Finding(
        title: 'ไม่พบรหัสปัญหาและค่าเซ็นเซอร์อยู่ในเกณฑ์',
        severity: Severity.info,
        evidence: ['ตรวจ ${s.pids.length} ค่าเซ็นเซอร์ ณ ขณะสแกน'],
      ));
    }

    return DiagnosisReport(snapshot: s, findings: findings, engineName: name);
  }

  String _pct(double v) => '${v >= 0 ? '+' : ''}${v.toStringAsFixed(1)}%';

  void _fuelTrimRules(VehicleSnapshot s, Map<String, Finding> byCode) {
    final banks = [
      ('P0171', 'P0172', Pid.stftB1, Pid.ltftB1, 'แบงก์ 1'),
      ('P0174', 'P0175', Pid.stftB2, Pid.ltftB2, 'แบงก์ 2'),
    ];
    for (final (lean, rich, st, lt, bank) in banks) {
      final ltft = s.pid(lt);
      final stft = s.pid(st);
      if (ltft == null) continue;
      final total = ltft + (stft ?? 0);
      final leanF = byCode[lean];
      if (leanF != null) {
        if (ltft > 10) {
          leanF.evidence.add('Long Term Fuel Trim $bank ${_pct(ltft)} ECU กำลังเติมน้ำมันชดเชย ยืนยันว่าส่วนผสมบางจริง');
        } else if (total.abs() < 5) {
          leanF.evidence.add('Fuel Trim ขณะนี้ปกติ (${_pct(total)}) อาการอาจเกิดเฉพาะบางช่วง เช่น ตอนเร่งหรือรอบสูง ให้ทดสอบขณะขับ');
        }
        if (s.pid(Pid.rpm) != null && s.pid(Pid.rpm)! < 1000 && ltft > 10) {
          leanF.evidence.add('วัดขณะเดินเบา: ถ้าเร่งค้างที่ 2,500 รอบแล้ว Fuel Trim ลดลงชัดเจน แสดงว่ารั่วสุญญากาศเป็นสาเหตุหลัก');
        }
      }
      final richF = byCode[rich];
      if (richF != null && ltft < -10) {
        richF.evidence.add('Long Term Fuel Trim $bank ${_pct(ltft)} ECU กำลังลดน้ำมัน ยืนยันว่าส่วนผสมหนาจริง');
      }
      // ยังไม่มีโค้ดแต่ค่าเริ่มเบี่ยง: เตือนล่วงหน้า (เฉพาะเครื่องเบนซิน)
      if (leanF == null && richF == null && !s.isDiesel && total.abs() >= 20) {
        byCode['_trim_$bank'] = Finding(
          title: total > 0 ? 'ส่วนผสมเริ่มบาง ($bank) แต่ยังไม่ขึ้นโค้ด' : 'ส่วนผสมเริ่มหนา ($bank) แต่ยังไม่ขึ้นโค้ด',
          severity: Severity.low,
          evidence: ['Fuel Trim รวม ${_pct(total)} (ปกติไม่ควรเกิน ±10%)'],
          causes: total > 0
              ? ['รอยรั่วสุญญากาศ', 'MAF สกปรก', 'แรงดันน้ำมันต่ำ']
              : ['หัวฉีดรั่ว', 'แรงดันน้ำมันสูง', 'กรองอากาศตัน'],
        );
      }
    }
  }

  void _misfireRules(VehicleSnapshot s, Map<String, Finding> byCode) {
    final cylinders = s.codes.where((c) => RegExp(r'^P03(0[1-9]|1[0-2])$').hasMatch(c)).toList();
    final random = s.codes.contains('P0300');
    final misfires = [...cylinders, if (random) 'P0300'];
    if (misfires.isEmpty) return;

    final leanCodes = s.codes.intersection({'P0171', 'P0174'});
    for (final code in misfires) {
      final f = byCode[code];
      if (f == null) continue;
      if (cylinders.length >= 2 || random) {
        f.evidence.add('จุดระเบิดไม่สมบูรณ์หลายสูบพร้อมกัน มักมีสาเหตุร่วม (เชื้อเพลิง สุญญากาศ) มากกว่าคอยล์หรือหัวเทียนตัวเดียว');
      }
      if (leanCodes.isNotEmpty) {
        f.evidence.add('มีรหัสส่วนผสมบาง (${leanCodes.join(', ')}) ร่วมด้วย ให้ตรวจรอยรั่วสุญญากาศและแรงดันน้ำมันก่อนเปลี่ยนหัวเทียนหรือคอยล์');
        f.causes.insert(0, 'ส่วนผสมบางจากรอยรั่วสุญญากาศหรือแรงดันน้ำมันต่ำ');
      }
    }
  }

  void _catalystRules(VehicleSnapshot s, Map<String, Finding> byCode) {
    final hasRootCause = s.codes.any((c) =>
        c.startsWith('P030') || c.startsWith('P031') || const {'P0171', 'P0172', 'P0174', 'P0175'}.contains(c));
    for (final code in ['P0420', 'P0430']) {
      final f = byCode[code];
      if (f == null || !hasRootCause) continue;
      f.evidence.add('มีปัญหาการจุดระเบิดหรือส่วนผสมร่วมด้วย ให้แก้ปัญหานั้นก่อน แคทอาจยังไม่เสีย ลบโค้ดแล้วขับทดสอบอีกครั้ง');
      f.checks.insert(0, 'แก้รหัสจุดระเบิดหรือส่วนผสมให้เรียบร้อยก่อนตัดสินใจเปลี่ยนแคท');
    }
  }

  void _coolantRules(VehicleSnapshot s, Map<String, Finding> byCode, List<Finding> extra) {
    final ect = s.pid(Pid.coolantTemp);
    if (ect == null) return;
    if (ect >= 110) {
      extra.add(Finding(
        title: 'เครื่องยนต์ร้อนเกิน (${ect.round()} °C)',
        severity: Severity.high,
        evidence: ['อุณหภูมิน้ำหล่อเย็น ${ect.round()} °C ปกติอยู่ราว 85–100 °C'],
        causes: ['น้ำหล่อเย็นรั่วหรือต่ำ', 'พัดลมหม้อน้ำไม่ทำงาน', 'ปั๊มน้ำเสีย', 'เทอร์โมสตัทค้างปิด', 'หม้อน้ำตัน'],
        checks: ['จอดดับเครื่อง รอให้เย็นก่อนเปิดฝาหม้อน้ำ', 'เช็กระดับน้ำหล่อเย็นและรอยรั่ว', 'ดูว่าพัดลมหม้อน้ำหมุนเมื่อร้อน'],
      ));
    } else if (ect >= 104) {
      extra.add(Finding(
        title: 'อุณหภูมิเครื่องยนต์ค่อนข้างสูง (${ect.round()} °C)',
        severity: Severity.medium,
        evidence: ['อุณหภูมิน้ำหล่อเย็น ${ect.round()} °C สูงกว่าช่วงปกติเล็กน้อย'],
        causes: ['น้ำหล่อเย็นต่ำ', 'พัดลมหม้อน้ำทำงานไม่เต็มที่', 'หม้อน้ำสกปรก'],
        checks: ['เช็กระดับน้ำหล่อเย็น', 'สังเกตเกจความร้อนขณะรถติด'],
      ));
    }

    final runtime = s.pid(Pid.runTime);
    if (runtime != null && runtime > 900 && ect < 70) {
      final existing = byCode['P0128'] ?? byCode['P0125'];
      final note = 'ติดเครื่องมาแล้ว ${(runtime / 60).round()} นาทีแต่น้ำหล่อเย็นยังแค่ ${ect.round()} °C';
      if (existing != null) {
        existing.evidence.add('$note สนับสนุนว่าเทอร์โมสตัทค้างเปิด');
      } else {
        extra.add(Finding(
          title: 'เครื่องยนต์อุ่นช้ากว่าปกติ',
          severity: Severity.low,
          evidence: [note],
          causes: ['เทอร์โมสตัทค้างเปิด', 'เซ็นเซอร์อุณหภูมิเสื่อม'],
          checks: ['ขับต่อเนื่อง 15 นาทีแล้วดูว่าอุณหภูมิถึง 85–95 °C หรือไม่'],
        ));
      }
    }
  }

  void _voltageRules(VehicleSnapshot s, List<Finding> extra) {
    final v = s.pid(Pid.moduleVoltage);
    final rpm = s.pid(Pid.rpm);
    if (v == null) return;
    final running = rpm != null && rpm > 500;
    if (running && v < 12.8) {
      extra.add(Finding(
        title: 'ระบบไฟอาจไม่ชาร์จ (${v.toStringAsFixed(1)} V ขณะติดเครื่อง)',
        severity: Severity.medium,
        evidence: ['แรงดัน ${v.toStringAsFixed(1)} V ขณะเครื่องทำงาน ปกติควรอยู่ 13.5–14.7 V'],
        causes: ['ไดชาร์จเสีย', 'สายพานหน้าเครื่องหย่อนหรือขาด', 'ขั้วแบตหลวม'],
        checks: ['วัดแรงดันที่ขั้วแบตด้วยมัลติมิเตอร์ขณะติดเครื่อง', 'ตรวจสายพาน'],
      ));
    } else if (running && v > 15.2) {
      extra.add(Finding(
        title: 'แรงดันชาร์จสูงเกิน (${v.toStringAsFixed(1)} V)',
        severity: Severity.medium,
        evidence: ['แรงดัน ${v.toStringAsFixed(1)} V สูงกว่า 15 V อาจทำให้แบตบวมและอุปกรณ์ไฟฟ้าเสีย'],
        causes: ['เรกกูเลเตอร์ไดชาร์จเสีย'],
        checks: ['วัดแรงดันขณะติดเครื่องรอบ 2,000'],
      ));
    } else if (!running && v < 12.0) {
      extra.add(Finding(
        title: 'แบตเตอรี่อ่อน (${v.toStringAsFixed(1)} V)',
        severity: Severity.low,
        evidence: ['แรงดันขณะดับเครื่อง ${v.toStringAsFixed(1)} V แบตที่ชาร์จเต็มควรราว 12.6 V'],
        causes: ['แบตเตอรี่เสื่อม', 'มีไฟรั่วขณะจอด'],
        checks: ['ทดสอบแบตเตอรี่ด้วยเครื่องวัด CCA'],
      ));
    }
  }
}
