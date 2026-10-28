/// นิยาม PID ของ Mode 01 (ข้อมูลสด) และสูตรแปลงค่าตาม SAE J1979
library;

/// หมวดของค่าสด ใช้จัดกลุ่มในหน้าจอ
enum PidGroup {
  engine('เครื่องยนต์'),
  fuel('เชื้อเพลิง'),
  air('อากาศและไอดี'),
  exhaust('ไอเสียและมลพิษ'),
  diesel('ดีเซล / เทอร์โบ'),
  electrical('ไฟฟ้า'),
  distance('ระยะทางและเวลา');

  const PidGroup(this.labelTh);
  final String labelTh;
}

class PidDef {
  const PidDef({
    required this.pid,
    required this.nameTh,
    required this.unit,
    required this.bytes,
    required this.decode,
    required this.group,
    this.min,
    this.max,
    this.decimals = 0,
    this.ownerVisible = false,
    this.live = true,
  });

  final int pid;
  final String nameTh;
  final String unit;

  /// จำนวนไบต์ข้อมูลขั้นต่ำที่ต้องมีจึงจะถอดค่าได้
  final int bytes;
  final double Function(List<int> d) decode;
  final PidGroup group;
  final double? min;
  final double? max;
  final int decimals;

  /// แสดงในโหมดเจ้าของรถด้วยหรือไม่ (โหมดช่างแสดงทุกตัว)
  final bool ownerVisible;

  /// ค่าที่เปลี่ยนตลอดเวลา (false = ค่าสะสม/สถานะ อ่านครั้งเดียวพอ)
  final bool live;

  String format(double v) => '${v.toStringAsFixed(decimals)}${unit.isEmpty ? '' : ' $unit'}';

  String get code => '01${pid.toRadixString(16).padLeft(2, '0').toUpperCase()}';
}

double _pct(List<int> d) => d[0] * 100 / 255;
double _temp(List<int> d) => d[0] - 40.0;
double _trim(List<int> d) => (d[0] - 128) * 100 / 128;
double _word(List<int> d) => (d[0] * 256 + d[1]).toDouble();
double _word2(List<int> d, int i) => (d[i] * 256 + d[i + 1]).toDouble();
double _dword(List<int> d, int i) =>
    ((d[i] << 24) + (d[i + 1] << 16) + (d[i + 2] << 8) + d[i + 3]).toDouble();
double _torque(List<int> d) => d[0] - 125.0;

/// รหัส PID ที่ใช้บ่อย ตั้งชื่อไว้เพื่ออ่านโค้ดง่าย
abstract final class Pid {
  static const monitorStatus = 0x01;
  static const engineLoad = 0x04;
  static const coolantTemp = 0x05;
  static const stftB1 = 0x06;
  static const ltftB1 = 0x07;
  static const stftB2 = 0x08;
  static const ltftB2 = 0x09;
  static const fuelPressure = 0x0A;
  static const map = 0x0B;
  static const rpm = 0x0C;
  static const speed = 0x0D;
  static const timingAdvance = 0x0E;
  static const intakeTemp = 0x0F;
  static const maf = 0x10;
  static const throttle = 0x11;
  static const o2B1S1 = 0x14;
  static const o2B1S2 = 0x15;
  static const o2B2S1 = 0x18;
  static const o2B2S2 = 0x19;
  static const runTime = 0x1F;
  static const distanceWithMil = 0x21;
  static const fuelRailPressureRel = 0x22;
  static const fuelRailPressure = 0x23;
  static const lambdaB1S1 = 0x24;
  static const commandedEgr = 0x2C;
  static const egrError = 0x2D;
  static const evapPurge = 0x2E;
  static const fuelLevel = 0x2F;
  static const warmupsSinceClear = 0x30;
  static const distanceSinceClear = 0x31;
  static const baro = 0x33;
  static const catTempB1S1 = 0x3C;
  static const catTempB2S1 = 0x3D;
  static const catTempB1S2 = 0x3E;
  static const moduleVoltage = 0x42;
  static const absoluteLoad = 0x43;
  static const commandedLambda = 0x44;
  static const relativeThrottle = 0x45;
  static const ambientTemp = 0x46;
  static const pedalD = 0x49;
  static const pedalE = 0x4A;
  static const commandedThrottle = 0x4C;
  static const timeWithMil = 0x4D;
  static const timeSinceClear = 0x4E;
  static const fuelType = 0x51;
  static const ethanol = 0x52;
  static const fuelRailAbs = 0x59;
  static const relativePedal = 0x5A;
  static const hybridBattery = 0x5B;
  static const oilTemp = 0x5C;
  static const injectionTiming = 0x5D;
  static const fuelRate = 0x5E;
  static const demandTorque = 0x61;
  static const actualTorque = 0x62;
  static const referenceTorque = 0x63;
  static const boost = 0x70;
  static const exhaustPressure = 0x73;
  static const chargeAirTemp = 0x77;
  static const egtB1 = 0x78;
  static const dpfB1 = 0x7A;
  static const engineRunTimeTotal = 0x7F;
  static const frictionTorque = 0x8E;
  static const cylinderFuelRate = 0xA2;
  static const gear = 0xA4;
  static const odometer = 0xA6;
}

final Map<int, PidDef> pidTable = {
  for (final d in <PidDef>[
    // ---- เครื่องยนต์
    PidDef(pid: Pid.rpm, nameTh: 'รอบเครื่องยนต์', unit: 'รอบ/นาที', bytes: 2, decode: (d) => _word(d) / 4, group: PidGroup.engine, min: 0, max: 8000, ownerVisible: true),
    PidDef(pid: Pid.speed, nameTh: 'ความเร็วรถ', unit: 'กม./ชม.', bytes: 1, decode: (d) => d[0].toDouble(), group: PidGroup.engine, min: 0, max: 220, ownerVisible: true),
    PidDef(pid: Pid.coolantTemp, nameTh: 'อุณหภูมิน้ำหล่อเย็น', unit: '°C', bytes: 1, decode: _temp, group: PidGroup.engine, min: -40, max: 130, ownerVisible: true),
    PidDef(pid: Pid.oilTemp, nameTh: 'อุณหภูมิน้ำมันเครื่อง', unit: '°C', bytes: 1, decode: _temp, group: PidGroup.engine, min: -40, max: 150, ownerVisible: true),
    PidDef(pid: Pid.engineLoad, nameTh: 'ภาระเครื่องยนต์', unit: '%', bytes: 1, decode: _pct, group: PidGroup.engine, min: 0, max: 100, ownerVisible: true),
    PidDef(pid: Pid.absoluteLoad, nameTh: 'ภาระเครื่องยนต์สัมบูรณ์', unit: '%', bytes: 2, decode: (d) => _word(d) * 100 / 255, group: PidGroup.engine, min: 0, max: 100),
    PidDef(pid: Pid.throttle, nameTh: 'ตำแหน่งลิ้นเร่ง', unit: '%', bytes: 1, decode: _pct, group: PidGroup.engine, min: 0, max: 100),
    PidDef(pid: Pid.relativeThrottle, nameTh: 'ลิ้นเร่งสัมพัทธ์', unit: '%', bytes: 1, decode: _pct, group: PidGroup.engine, min: 0, max: 100),
    PidDef(pid: Pid.commandedThrottle, nameTh: 'ลิ้นเร่งที่สั่ง', unit: '%', bytes: 1, decode: _pct, group: PidGroup.engine, min: 0, max: 100),
    PidDef(pid: Pid.pedalD, nameTh: 'คันเร่ง (เซ็นเซอร์ D)', unit: '%', bytes: 1, decode: _pct, group: PidGroup.engine, min: 0, max: 100),
    PidDef(pid: Pid.pedalE, nameTh: 'คันเร่ง (เซ็นเซอร์ E)', unit: '%', bytes: 1, decode: _pct, group: PidGroup.engine, min: 0, max: 100),
    PidDef(pid: Pid.relativePedal, nameTh: 'คันเร่งสัมพัทธ์', unit: '%', bytes: 1, decode: _pct, group: PidGroup.engine, min: 0, max: 100),
    PidDef(pid: Pid.timingAdvance, nameTh: 'องศาไฟจุดระเบิด', unit: '°', bytes: 1, decode: (d) => d[0] / 2 - 64, group: PidGroup.engine, min: -20, max: 60, decimals: 1),
    PidDef(pid: Pid.demandTorque, nameTh: 'แรงบิดที่ผู้ขับต้องการ', unit: '%', bytes: 1, decode: _torque, group: PidGroup.engine, min: 0, max: 100),
    PidDef(pid: Pid.actualTorque, nameTh: 'แรงบิดจริง', unit: '%', bytes: 1, decode: _torque, group: PidGroup.engine, min: 0, max: 100),
    PidDef(pid: Pid.frictionTorque, nameTh: 'แรงเสียดทานเครื่องยนต์', unit: '%', bytes: 1, decode: _torque, group: PidGroup.engine, min: 0, max: 100),
    PidDef(pid: Pid.referenceTorque, nameTh: 'แรงบิดอ้างอิง', unit: 'Nm', bytes: 2, decode: _word, group: PidGroup.engine, live: false),
    PidDef(pid: Pid.gear, nameTh: 'เกียร์ปัจจุบัน', unit: '', bytes: 2, decode: (d) => (d[1] >> 4).toDouble(), group: PidGroup.engine, min: 0, max: 10),
    PidDef(pid: Pid.hybridBattery, nameTh: 'แบตเตอรี่ไฮบริด', unit: '%', bytes: 1, decode: _pct, group: PidGroup.electrical, min: 0, max: 100, ownerVisible: true),

    // ---- เชื้อเพลิง
    PidDef(pid: Pid.fuelLevel, nameTh: 'ระดับน้ำมันในถัง', unit: '%', bytes: 1, decode: _pct, group: PidGroup.fuel, min: 0, max: 100, ownerVisible: true),
    PidDef(pid: Pid.stftB1, nameTh: 'Short Term Fuel Trim B1', unit: '%', bytes: 1, decode: _trim, group: PidGroup.fuel, min: -25, max: 25, decimals: 1),
    PidDef(pid: Pid.ltftB1, nameTh: 'Long Term Fuel Trim B1', unit: '%', bytes: 1, decode: _trim, group: PidGroup.fuel, min: -25, max: 25, decimals: 1),
    PidDef(pid: Pid.stftB2, nameTh: 'Short Term Fuel Trim B2', unit: '%', bytes: 1, decode: _trim, group: PidGroup.fuel, min: -25, max: 25, decimals: 1),
    PidDef(pid: Pid.ltftB2, nameTh: 'Long Term Fuel Trim B2', unit: '%', bytes: 1, decode: _trim, group: PidGroup.fuel, min: -25, max: 25, decimals: 1),
    PidDef(pid: Pid.fuelPressure, nameTh: 'แรงดันน้ำมันเชื้อเพลิง', unit: 'kPa', bytes: 1, decode: (d) => d[0] * 3.0, group: PidGroup.fuel, min: 0, max: 765),
    PidDef(pid: Pid.fuelRailPressureRel, nameTh: 'แรงดันรางหัวฉีด (เทียบท่อไอดี)', unit: 'kPa', bytes: 2, decode: (d) => _word(d) * 0.079, group: PidGroup.fuel, min: 0, max: 5177, decimals: 1),
    PidDef(pid: Pid.fuelRailPressure, nameTh: 'แรงดันรางหัวฉีด', unit: 'kPa', bytes: 2, decode: (d) => _word(d) * 10, group: PidGroup.fuel, min: 0, max: 200000),
    PidDef(pid: Pid.fuelRailAbs, nameTh: 'แรงดันรางหัวฉีด (สัมบูรณ์)', unit: 'kPa', bytes: 2, decode: (d) => _word(d) * 10, group: PidGroup.fuel, min: 0, max: 200000),
    PidDef(pid: Pid.fuelRate, nameTh: 'อัตราการใช้น้ำมัน', unit: 'ลิตร/ชม.', bytes: 2, decode: (d) => _word(d) / 20, group: PidGroup.fuel, min: 0, max: 30, decimals: 2, ownerVisible: true),
    PidDef(pid: Pid.cylinderFuelRate, nameTh: 'ปริมาณน้ำมันต่อจังหวะ', unit: 'mg/จังหวะ', bytes: 2, decode: (d) => _word(d) / 32, group: PidGroup.fuel, min: 0, max: 100, decimals: 1),
    PidDef(pid: Pid.injectionTiming, nameTh: 'จังหวะฉีดน้ำมัน', unit: '°', bytes: 2, decode: (d) => _word(d) / 128 - 210, group: PidGroup.fuel, min: -20, max: 30, decimals: 1),
    PidDef(pid: Pid.ethanol, nameTh: 'สัดส่วนเอทานอล', unit: '%', bytes: 1, decode: _pct, group: PidGroup.fuel, min: 0, max: 100, live: false),
    PidDef(pid: Pid.evapPurge, nameTh: 'วาล์ว Purge ที่สั่ง', unit: '%', bytes: 1, decode: _pct, group: PidGroup.fuel, min: 0, max: 100),
    PidDef(pid: Pid.commandedLambda, nameTh: 'Lambda ที่สั่ง', unit: 'λ', bytes: 2, decode: (d) => _word(d) * 2 / 65536, group: PidGroup.fuel, min: 0.5, max: 1.5, decimals: 3),

    // ---- อากาศและไอดี
    PidDef(pid: Pid.map, nameTh: 'แรงดันท่อไอดี (MAP)', unit: 'kPa', bytes: 1, decode: (d) => d[0].toDouble(), group: PidGroup.air, min: 0, max: 255),
    PidDef(pid: Pid.maf, nameTh: 'มวลอากาศ (MAF)', unit: 'g/s', bytes: 2, decode: (d) => _word(d) / 100, group: PidGroup.air, min: 0, max: 200, decimals: 2),
    PidDef(pid: Pid.intakeTemp, nameTh: 'อุณหภูมิอากาศเข้า', unit: '°C', bytes: 1, decode: _temp, group: PidGroup.air, min: -40, max: 100),
    PidDef(pid: Pid.ambientTemp, nameTh: 'อุณหภูมิภายนอก', unit: '°C', bytes: 1, decode: _temp, group: PidGroup.air, min: -40, max: 60),
    PidDef(pid: Pid.baro, nameTh: 'แรงดันบรรยากาศ', unit: 'kPa', bytes: 1, decode: (d) => d[0].toDouble(), group: PidGroup.air, min: 60, max: 110),
    PidDef(pid: Pid.chargeAirTemp, nameTh: 'อุณหภูมิอากาศหลังอินเตอร์คูลเลอร์', unit: '°C', bytes: 2, decode: (d) => d[1] - 40.0, group: PidGroup.air, min: -40, max: 150),

    // ---- ไอเสียและมลพิษ
    PidDef(pid: Pid.o2B1S1, nameTh: 'O2 แบงก์ 1 ตัวหน้า', unit: 'V', bytes: 2, decode: (d) => d[0] / 200, group: PidGroup.exhaust, min: 0, max: 1.275, decimals: 3),
    PidDef(pid: Pid.o2B1S2, nameTh: 'O2 แบงก์ 1 ตัวหลัง', unit: 'V', bytes: 2, decode: (d) => d[0] / 200, group: PidGroup.exhaust, min: 0, max: 1.275, decimals: 3),
    PidDef(pid: Pid.o2B2S1, nameTh: 'O2 แบงก์ 2 ตัวหน้า', unit: 'V', bytes: 2, decode: (d) => d[0] / 200, group: PidGroup.exhaust, min: 0, max: 1.275, decimals: 3),
    PidDef(pid: Pid.o2B2S2, nameTh: 'O2 แบงก์ 2 ตัวหลัง', unit: 'V', bytes: 2, decode: (d) => d[0] / 200, group: PidGroup.exhaust, min: 0, max: 1.275, decimals: 3),
    PidDef(pid: Pid.lambdaB1S1, nameTh: 'Lambda ไวด์แบนด์ B1S1', unit: 'λ', bytes: 4, decode: (d) => _word(d) * 2 / 65536, group: PidGroup.exhaust, min: 0.5, max: 1.5, decimals: 3),
    PidDef(pid: Pid.catTempB1S1, nameTh: 'อุณหภูมิแคท B1 ตัวหน้า', unit: '°C', bytes: 2, decode: (d) => _word(d) / 10 - 40, group: PidGroup.exhaust, min: 0, max: 1000),
    PidDef(pid: Pid.catTempB2S1, nameTh: 'อุณหภูมิแคท B2 ตัวหน้า', unit: '°C', bytes: 2, decode: (d) => _word(d) / 10 - 40, group: PidGroup.exhaust, min: 0, max: 1000),
    PidDef(pid: Pid.catTempB1S2, nameTh: 'อุณหภูมิแคท B1 ตัวหลัง', unit: '°C', bytes: 2, decode: (d) => _word(d) / 10 - 40, group: PidGroup.exhaust, min: 0, max: 1000),
    PidDef(pid: Pid.commandedEgr, nameTh: 'EGR ที่สั่ง', unit: '%', bytes: 1, decode: _pct, group: PidGroup.exhaust, min: 0, max: 100),
    PidDef(pid: Pid.egrError, nameTh: 'ความคลาดเคลื่อน EGR', unit: '%', bytes: 1, decode: (d) => d[0] * 100 / 128 - 100, group: PidGroup.exhaust, min: -100, max: 100, decimals: 1),

    // ---- ดีเซล / เทอร์โบ (ข้อมูลหลายไบต์ ไบต์แรกเป็นบิตบอกเซ็นเซอร์ที่มี)
    PidDef(pid: Pid.boost, nameTh: 'แรงดันบูสต์จริง', unit: 'kPa', bytes: 5, decode: (d) => _word2(d, 3) * 0.03125, group: PidGroup.diesel, min: 0, max: 350, ownerVisible: true),
    PidDef(pid: Pid.exhaustPressure, nameTh: 'แรงดันไอเสีย', unit: 'kPa', bytes: 3, decode: (d) => _word2(d, 1) * 0.01, group: PidGroup.diesel, min: 0, max: 300, decimals: 1),
    PidDef(pid: Pid.egtB1, nameTh: 'อุณหภูมิไอเสีย (EGT) B1', unit: '°C', bytes: 3, decode: (d) => _word2(d, 1) / 10 - 40, group: PidGroup.diesel, min: 0, max: 900),
    PidDef(pid: Pid.dpfB1, nameTh: 'ความดันต่างคร่อม DPF', unit: 'kPa', bytes: 3, decode: (d) => _word2(d, 1) * 0.01, group: PidGroup.diesel, min: 0, max: 50, decimals: 2),

    // ---- ไฟฟ้า
    PidDef(pid: Pid.moduleVoltage, nameTh: 'แรงดันไฟระบบ', unit: 'V', bytes: 2, decode: (d) => _word(d) / 1000, group: PidGroup.electrical, min: 10, max: 16, decimals: 1, ownerVisible: true),

    // ---- ระยะทางและเวลา
    PidDef(pid: Pid.runTime, nameTh: 'เวลาตั้งแต่ติดเครื่อง', unit: 'วินาที', bytes: 2, decode: _word, group: PidGroup.distance),
    PidDef(pid: Pid.odometer, nameTh: 'เลขไมล์ในกล่อง ECU', unit: 'กม.', bytes: 4, decode: (d) => _dword(d, 0) / 10, group: PidGroup.distance, decimals: 1, live: false),
    PidDef(pid: Pid.engineRunTimeTotal, nameTh: 'ชั่วโมงเครื่องยนต์สะสม', unit: 'ชม.', bytes: 5, decode: (d) => _dword(d, 1) / 3600, group: PidGroup.distance, decimals: 1, live: false),
    PidDef(pid: Pid.distanceWithMil, nameTh: 'ระยะทางที่ไฟเตือนติด', unit: 'กม.', bytes: 2, decode: _word, group: PidGroup.distance, live: false),
    PidDef(pid: Pid.distanceSinceClear, nameTh: 'ระยะทางตั้งแต่ลบโค้ด', unit: 'กม.', bytes: 2, decode: _word, group: PidGroup.distance, live: false),
    PidDef(pid: Pid.warmupsSinceClear, nameTh: 'จำนวนรอบอุ่นเครื่องตั้งแต่ลบโค้ด', unit: 'ครั้ง', bytes: 1, decode: (d) => d[0].toDouble(), group: PidGroup.distance, live: false),
    PidDef(pid: Pid.timeWithMil, nameTh: 'เวลาที่ไฟเตือนติด', unit: 'นาที', bytes: 2, decode: _word, group: PidGroup.distance, live: false),
    PidDef(pid: Pid.timeSinceClear, nameTh: 'เวลาตั้งแต่ลบโค้ด', unit: 'นาที', bytes: 2, decode: _word, group: PidGroup.distance, live: false),
    PidDef(pid: Pid.fuelType, nameTh: 'ชนิดเชื้อเพลิง (รหัส)', unit: '', bytes: 1, decode: (d) => d[0].toDouble(), group: PidGroup.fuel, live: false),
  ])
    d.pid: d,
};

/// PID ที่อ่านเก็บไว้ตอนสแกนวินิจฉัย (อ่านเฉพาะตัวที่รถรองรับ)
const snapshotPids = <int>[
  Pid.rpm, Pid.speed, Pid.coolantTemp, Pid.engineLoad, Pid.stftB1, Pid.ltftB1,
  Pid.stftB2, Pid.ltftB2, Pid.map, Pid.maf, Pid.intakeTemp, Pid.throttle,
  Pid.runTime, Pid.moduleVoltage, Pid.oilTemp, Pid.distanceWithMil, Pid.fuelRailPressure,
  Pid.fuelRailAbs, Pid.boost, Pid.egtB1, Pid.dpfB1, Pid.fuelRate, Pid.ambientTemp, Pid.baro,
  Pid.odometer, Pid.engineRunTimeTotal, Pid.distanceSinceClear, Pid.warmupsSinceClear,
  Pid.timeSinceClear, Pid.timeWithMil, Pid.fuelType,
];

/// ชื่อชนิดเชื้อเพลิงจาก PID 51
String fuelTypeName(int code) => switch (code) {
      1 => 'เบนซิน',
      2 => 'เมทานอล',
      3 => 'เอทานอล',
      4 => 'ดีเซล',
      5 => 'LPG',
      6 => 'CNG',
      7 => 'โพรเพน',
      8 => 'ไฟฟ้า',
      9 => 'เบนซิน/ก๊าซ (bi-fuel)',
      >= 10 && <= 15 => 'สองเชื้อเพลิง (bi-fuel)',
      16 || 17 || 18 || 19 || 20 || 21 => 'ไฮบริด',
      _ => 'ไม่ระบุ ($code)',
    };

/// แปลงบิตแมสก์ PID ที่รองรับ (คำตอบของ PID 00/20/40…) เป็นเซ็ตของ PID
Set<int> decodeSupportMask(int basePid, List<int> d) {
  final out = <int>{};
  for (var byte = 0; byte < 4 && byte < d.length; byte++) {
    for (var bit = 0; bit < 8; bit++) {
      if (d[byte] & (0x80 >> bit) != 0) out.add(basePid + byte * 8 + bit + 1);
    }
  }
  return out;
}

/// สถานะไฟเตือน (MIL) และจำนวนโค้ดจาก PID 01
class MonitorStatus {
  const MonitorStatus({required this.milOn, required this.dtcCount, required this.isDiesel});

  final bool milOn;
  final int dtcCount;
  final bool isDiesel;

  static MonitorStatus decode(List<int> d) => MonitorStatus(
        milOn: d[0] & 0x80 != 0,
        dtcCount: d[0] & 0x7F,
        isDiesel: d.length > 1 && d[1] & 0x08 != 0,
      );
}
