/// ตรวจความสมเหตุสมผลของเลขไมล์ โดยเทียบหลายแหล่งที่หมุนกลับยาก
///
/// แหล่งข้อมูล:
/// - เลขไมล์ในกล่อง ECU (PID A6) — รถรุ่นใหม่บางรุ่นเท่านั้น
/// - ชั่วโมงเครื่องยนต์สะสม (PID 7F) — ส่วนใหญ่เป็นรถดีเซล/รถรุ่นใหม่
/// - จำนวนครั้งที่บิดกุญแจ (Mode 09 IUPR) — สะสมตั้งแต่กล่องใหม่ ลบโค้ดไม่หาย
/// - เลขไมล์ที่เห็นบนหน้าปัด (ผู้ใช้กรอก) และประวัติที่เคยบันทึกของรถคันเดียวกัน
///
/// ผลลัพธ์เป็นข้อสังเกตประกอบการตัดสินใจ ไม่ใช่หลักฐานยืนยัน
library;

enum CheckLevel { ok, warn, bad, info }

class OdoCheck {
  const OdoCheck(this.level, this.title, this.detail);
  final CheckLevel level;
  final String title;
  final String detail;
}

enum OdoVerdict {
  consistent('เลขไมล์สอดคล้องกัน'),
  checkMore('ควรตรวจสอบเพิ่มเติม'),
  suspicious('น่าสงสัยว่าเลขไมล์ถูกแก้'),
  insufficient('ข้อมูลไม่พอจะสรุป');

  const OdoVerdict(this.labelTh);
  final String labelTh;
}

class OdoRecord {
  const OdoRecord(this.time, this.km);
  final DateTime time;
  final double km;
}

class OdometerInput {
  const OdometerInput({
    this.ecuKm,
    this.dashboardKm,
    this.engineHours,
    this.ignitionCycles,
    this.modelYear,
    this.history = const [],
    this.now,
  });

  final double? ecuKm;
  final double? dashboardKm;
  final double? engineHours;
  final int? ignitionCycles;
  final int? modelYear;
  final List<OdoRecord> history;
  final DateTime? now;
}

class OdometerResult {
  const OdometerResult({
    required this.verdict,
    required this.checks,
    this.referenceKm,
    this.estimateFromHours,
    this.estimateFromIgnitions,
  });

  final OdoVerdict verdict;
  final List<OdoCheck> checks;
  final double? referenceKm;

  /// ช่วงระยะทางที่ประมาณจากชั่วโมงเครื่อง (ต่ำ, สูง)
  final (double, double)? estimateFromHours;

  /// ช่วงระยะทางที่ประมาณจากจำนวนครั้งที่สตาร์ท (ต่ำ, สูง)
  final (double, double)? estimateFromIgnitions;
}

String _km(double v) {
  final s = v.round().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return '$b กม.';
}

OdometerResult checkOdometer(OdometerInput x) {
  final checks = <OdoCheck>[];
  final ref = x.dashboardKm ?? x.ecuKm;

  // 1) กล่อง ECU เทียบหน้าปัด
  if (x.ecuKm != null && x.dashboardKm != null) {
    final ecu = x.ecuKm!, dash = x.dashboardKm!;
    final diff = dash - ecu;
    final tol = (ecu * 0.01).clamp(50, double.infinity);
    if (diff.abs() <= tol) {
      checks.add(OdoCheck(CheckLevel.ok, 'หน้าปัดตรงกับกล่อง ECU', 'ต่างกัน ${_km(diff.abs())}'));
    } else if (diff < 0 && diff.abs() > ecu * 0.05) {
      checks.add(OdoCheck(CheckLevel.bad, 'หน้าปัดน้อยกว่ากล่อง ECU มาก',
          'หน้าปัด ${_km(dash)} แต่กล่องบันทึก ${_km(ecu)} (ขาดไป ${_km(-diff)}) เป็นสัญญาณของการหมุนไมล์'));
    } else if (diff < 0) {
      checks.add(OdoCheck(CheckLevel.warn, 'หน้าปัดน้อยกว่ากล่อง ECU',
          'ต่างกัน ${_km(-diff)} อาจเกิดจากเปลี่ยนหน้าปัดหรือแก้ไมล์'));
    } else {
      checks.add(OdoCheck(CheckLevel.warn, 'หน้าปัดมากกว่ากล่อง ECU',
          'ต่างกัน ${_km(diff)} อาจเปลี่ยนกล่อง ECU มาจากคันอื่น'));
    }
  } else if (x.ecuKm != null) {
    checks.add(OdoCheck(CheckLevel.info, 'กล่อง ECU บันทึกไว้ ${_km(x.ecuKm!)}',
        'กรอกเลขไมล์ที่เห็นบนหน้าปัดเพื่อเทียบ'));
  } else {
    checks.add(const OdoCheck(CheckLevel.info, 'รถคันนี้ไม่ส่งเลขไมล์ผ่าน OBD',
        'ใช้ชั่วโมงเครื่องและจำนวนครั้งที่สตาร์ทเทียบแทน'));
  }

  // 2) ความเร็วเฉลี่ยตลอดอายุ = ระยะทาง / ชั่วโมงเครื่อง
  (double, double)? estH;
  if (x.engineHours != null && x.engineHours! > 50) {
    final h = x.engineHours!;
    estH = (h * 18, h * 55);
    if (ref != null) {
      final avg = ref / h;
      final t = 'ความเร็วเฉลี่ยตลอดอายุ ${avg.toStringAsFixed(1)} กม./ชม. (ชั่วโมงเครื่อง ${h.toStringAsFixed(0)} ชม.)';
      if (avg < 10) {
        checks.add(OdoCheck(CheckLevel.bad, 'ระยะทางน้อยเกินไปเมื่อเทียบชั่วโมงเครื่อง',
            '$t ปกติรถใช้งานทั่วไปอยู่ราว 20–50 กม./ชม. เว้นแต่ใช้งานแบบจอดติดเครื่องนาน (แท็กซี่ รถส่งของ เครื่องปั่นไฟ)'));
      } else if (avg < 16) {
        checks.add(OdoCheck(CheckLevel.warn, 'ระยะทางค่อนข้างน้อยเมื่อเทียบชั่วโมงเครื่อง',
            '$t อาจเป็นรถใช้ในเมืองรถติดมาก หรือไมล์ถูกลด'));
      } else if (avg > 80) {
        checks.add(OdoCheck(CheckLevel.warn, 'ชั่วโมงเครื่องน้อยผิดปกติ', '$t อาจเปลี่ยนกล่อง ECU'));
      } else {
        checks.add(OdoCheck(CheckLevel.ok, 'สัมพันธ์กับชั่วโมงเครื่อง', t));
      }
    }
  }

  // 3) ระยะทางต่อการสตาร์ทหนึ่งครั้ง
  (double, double)? estI;
  final ign = x.ignitionCycles;
  if (ign != null && ign > 0) {
    if (ign >= 65535) {
      checks.add(const OdoCheck(CheckLevel.info, 'ตัวนับการสตาร์ทเต็มแล้ว', 'ตัวนับ 16 บิตเต็มที่ 65,535 ครั้ง ใช้เทียบไม่ได้'));
    } else {
      estI = (ign * 6.0, ign * 25.0);
      if (ref != null && ign > 200) {
        final per = ref / ign;
        final t = 'เฉลี่ย ${per.toStringAsFixed(1)} กม. ต่อการสตาร์ท 1 ครั้ง (สตาร์ทสะสม ${ign.toString()} ครั้ง)';
        if (per < 2) {
          checks.add(OdoCheck(CheckLevel.bad, 'ระยะทางน้อยเกินไปเมื่อเทียบจำนวนครั้งที่สตาร์ท',
              '$t ปกติอยู่ราว 6–25 กม. ต่อครั้ง'));
        } else if (per < 4) {
          checks.add(OdoCheck(CheckLevel.warn, 'ระยะทางต่อการสตาร์ทค่อนข้างน้อย', '$t อาจเป็นรถใช้ระยะสั้นมาก หรือไมล์ถูกลด'));
        } else if (per > 60) {
          checks.add(OdoCheck(CheckLevel.warn, 'จำนวนครั้งที่สตาร์ทน้อยผิดปกติ', '$t อาจเปลี่ยนกล่อง ECU'));
        } else {
          checks.add(OdoCheck(CheckLevel.ok, 'สัมพันธ์กับจำนวนครั้งที่สตาร์ท', t));
        }
      }
    }
  }

  // 4) ประวัติเดิมของรถคันนี้
  if (ref != null && x.history.isNotEmpty) {
    final maxPrev = x.history.reduce((a, b) => a.km >= b.km ? a : b);
    if (maxPrev.km > ref + 100) {
      final d = maxPrev.time;
      checks.add(OdoCheck(CheckLevel.bad, 'เลขไมล์ลดลงจากที่เคยบันทึก',
          'เคยบันทึก ${_km(maxPrev.km)} เมื่อ ${d.day}/${d.month}/${d.year + 543} แต่ตอนนี้ ${_km(ref)}'));
    } else {
      checks.add(OdoCheck(CheckLevel.ok, 'ไม่ลดลงจากประวัติที่บันทึกไว้', 'ตรวจ ${x.history.length} ครั้งก่อนหน้า'));
    }
  }

  // 5) อายุรถ
  final now = x.now ?? DateTime.now();
  if (ref != null && x.modelYear != null && x.modelYear! <= now.year) {
    final age = (now.year - x.modelYear!).clamp(1, 60);
    final perYear = ref / age;
    if (age >= 4 && perYear < 4000) {
      // ปีรุ่นจาก VIN ไม่แน่นอนสำหรับรถบางตลาด จึงเป็นข้อสังเกต ไม่ใช่ข้อตัดสิน
      checks.add(OdoCheck(CheckLevel.info, 'ไมล์น้อยเมื่อเทียบอายุรถ (ข้อสังเกต)',
          'เฉลี่ย ${_km(perYear)}/ปี จากรถอายุประมาณ $age ปี (รถทั่วไปในไทยราว 15,000–25,000 กม./ปี)'));
    } else {
      checks.add(OdoCheck(CheckLevel.info, 'การใช้งานต่อปี', 'เฉลี่ย ${_km(perYear)}/ปี จากรถอายุประมาณ $age ปี'));
    }
  }

  final hasBad = checks.any((c) => c.level == CheckLevel.bad);
  final hasWarn = checks.any((c) => c.level == CheckLevel.warn);
  final hasOk = checks.any((c) => c.level == CheckLevel.ok);
  final verdict = hasBad
      ? OdoVerdict.suspicious
      : hasWarn
          ? OdoVerdict.checkMore
          : hasOk
              ? OdoVerdict.consistent
              : OdoVerdict.insufficient;

  return OdometerResult(
    verdict: verdict,
    checks: checks,
    referenceKm: ref,
    estimateFromHours: estH,
    estimateFromIgnitions: estI,
  );
}

String formatKm(double v) => _km(v);
