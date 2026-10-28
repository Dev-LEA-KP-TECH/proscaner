/// Mode 06: ผลการทดสอบระบบที่ ECU ทำเอง (On-board monitoring test results) ตาม SAE J1979 แบบ CAN
///
/// คำตอบหนึ่งรายการยาว 9 ไบต์: MID, TID, UASID, ค่า(2), ต่ำสุด(2), สูงสุด(2)
library;

class Mode06Result {
  const Mode06Result({
    required this.mid,
    required this.tid,
    required this.uasid,
    required this.value,
    required this.min,
    required this.max,
    required this.unit,
  });

  final int mid;
  final int tid;
  final int uasid;
  final double value;
  final double min;
  final double max;
  final String unit;

  bool get passed => value >= min && value <= max;

  String get midName => mode06MidName(mid);
  String get tidName => mode06TidName(mid, tid);

  /// สูบที่ 1–12 ถ้าเป็นข้อมูลการจุดระเบิดรายสูบ
  int? get misfireCylinder => mid >= 0xA2 && mid <= 0xAD ? mid - 0xA1 : null;

  String fmt(double v) {
    final d = v.abs() >= 100 || v == v.roundToDouble() ? 0 : (v.abs() >= 10 ? 1 : 3);
    return v.toStringAsFixed(d);
  }
}

/// สเกลและหน่วยของ Unit and Scaling ID (J1979 Appendix E) ที่พบบ่อย
/// คืน (ตัวคูณ, ออฟเซ็ต, หน่วย, มีเครื่องหมายบวกลบ)
(double, double, String, bool) uasidScale(int id) {
  switch (id) {
    case 0x01: return (1, 0, '', false);
    case 0x02: return (0.1, 0, '', false);
    case 0x03: return (0.01, 0, '', false);
    case 0x04: return (0.001, 0, '', false);
    case 0x05: return (0.0000305, 0, '', false);
    case 0x06: return (0.000305, 0, '', false);
    case 0x07: return (0.25, 0, 'รอบ/นาที', false);
    case 0x08: return (0.01, 0, 'กม./ชม.', false);
    case 0x09: return (1, 0, 'กม./ชม.', false);
    case 0x0A: return (0.122, 0, 'mV', false);
    case 0x0B: return (0.001, 0, 'V', false);
    case 0x0C: return (0.01, 0, 'V', false);
    case 0x0D: return (0.00390625, 0, 'mA', false);
    case 0x0E: return (0.001, 0, 'A', false);
    case 0x0F: return (0.01, 0, 'A', false);
    case 0x10: return (1, 0, 'ms', false);
    case 0x11: return (100, 0, 'ms', false);
    case 0x12: return (1, 0, 'วินาที', false);
    case 0x13: return (1, 0, 'mΩ', false);
    case 0x14: return (1, 0, 'Ω', false);
    case 0x15: return (1, 0, 'kΩ', false);
    case 0x16: return (0.1, -40, '°C', false);
    case 0x17: return (0.01, 0, 'kPa', false);
    case 0x18: return (0.0117, 0, 'kPa', false);
    case 0x19: return (0.079, 0, 'kPa', false);
    case 0x1A: return (1, 0, 'kPa', false);
    case 0x1B: return (10, 0, 'kPa', false);
    case 0x1C: return (0.01, 0, '°', false);
    case 0x1D: return (0.5, 0, '°', false);
    case 0x1E: return (0.0000305, 0, 'λ', false);
    case 0x1F: return (0.05, 0, 'AFR', false);
    case 0x20: return (0.0039062, 0, '', false);
    case 0x21: return (1, 0, 'mHz', false);
    case 0x22: return (1, 0, 'Hz', false);
    case 0x23: return (1, 0, 'kHz', false);
    case 0x24: return (1, 0, 'ครั้ง', false);
    case 0x25: return (1, 0, 'กม.', false);
    case 0x26: return (0.1, 0, 'mV/ms', false);
    case 0x27: return (0.01, 0, 'g/s', false);
    case 0x28: return (1, 0, 'g/s', false);
    case 0x29: return (0.25, 0, 'Pa/s', false);
    case 0x2A: return (0.001, 0, 'kg/h', false);
    case 0x2B: return (1, 0, 'ครั้ง', false);
    case 0x2C: return (0.01, 0, 'g/สูบ', false);
    case 0x2D: return (0.01, 0, 'mg/จังหวะ', false);
    case 0x2E: return (1, 0, '', false);
    case 0x2F: return (0.01, 0, '%', false);
    case 0x30: return (0.001526, 0, '%', false);
    case 0x31: return (0.001, 0, 'L', false);
    case 0x33: return (0.00024414, 0, 'λ', false);
    case 0x34: return (1, 0, 'นาที', false);
    case 0x35: return (10, 0, 'ms', false);
    case 0x81: return (1, 0, '', true);
    case 0x82: return (0.1, 0, '', true);
    case 0x83: return (0.01, 0, '', true);
    case 0x84: return (0.001, 0, '', true);
    case 0x85: return (0.0000305, 0, '', true);
    case 0x86: return (0.000305, 0, '', true);
    case 0x8A: return (0.122, 0, 'mV', true);
    case 0x8B: return (0.001, 0, 'V', true);
    case 0x8C: return (0.01, 0, 'V', true);
    case 0x8D: return (0.00390625, 0, 'mA', true);
    case 0x8E: return (0.001, 0, 'A', true);
    case 0x90: return (1, 0, 'ms', true);
    case 0x96: return (0.1, 0, '°C', true);
    case 0x9C: return (0.01, 0, '°', true);
    case 0x9D: return (0.5, 0, '°', true);
    case 0xA8: return (1, 0, 'g/s', true);
    case 0xA9: return (0.25, 0, 'Pa/s', true);
    case 0xAF: return (0.01, 0, '%', true);
    case 0xB0: return (0.003052, 0, '%', true);
    case 0xB1: return (2, 0, 'mV/s', true);
    case 0xFC: return (0.01, 0, 'kPa', true);
    case 0xFD: return (0.001, 0, 'kPa', true);
    case 0xFE: return (0.25, 0, 'Pa', true);
    default: return (1, 0, '', false);
  }
}

double _scaled(int raw, int uasid) {
  final (k, off, _, signed) = uasidScale(uasid);
  final v = signed && raw >= 0x8000 ? raw - 0x10000 : raw;
  return v * k + off;
}

/// แปลงคำตอบ Mode 06 (ไม่รวมไบต์ 0x46) เป็นรายการผล
List<Mode06Result> parseMode06(List<int> payload) {
  final out = <Mode06Result>[];
  for (var i = 0; i + 9 <= payload.length; i += 9) {
    final mid = payload[i], tid = payload[i + 1], u = payload[i + 2];
    int w(int o) => payload[i + o] * 256 + payload[i + o + 1];
    out.add(Mode06Result(
      mid: mid,
      tid: tid,
      uasid: u,
      value: _scaled(w(3), u),
      min: _scaled(w(5), u),
      max: _scaled(w(7), u),
      unit: uasidScale(u).$3,
    ));
  }
  return out;
}

String mode06MidName(int mid) {
  if (mid >= 0xA2 && mid <= 0xAD) return 'การจุดระเบิด สูบที่ ${mid - 0xA1}';
  const o2 = ['B1S1', 'B1S2', 'B1S3', 'B1S4', 'B2S1', 'B2S2', 'B2S3', 'B2S4', 'B3S1', 'B3S2', 'B3S3', 'B3S4', 'B4S1', 'B4S2', 'B4S3', 'B4S4'];
  if (mid >= 0x01 && mid <= 0x10) return 'เซ็นเซอร์ O2 ${o2[mid - 1]}';
  if (mid >= 0x41 && mid <= 0x50) return 'ฮีตเตอร์ O2 ${o2[mid - 0x41]}';
  return switch (mid) {
    0x21 => 'แคตาไลติก แบงก์ 1',
    0x22 => 'แคตาไลติก แบงก์ 2',
    0x23 => 'แคตาไลติก แบงก์ 3',
    0x24 => 'แคตาไลติก แบงก์ 4',
    0x31 => 'EGR / VVT แบงก์ 1',
    0x32 => 'EGR / VVT แบงก์ 2',
    0x33 => 'EGR / VVT แบงก์ 3',
    0x34 => 'EGR / VVT แบงก์ 4',
    0x35 => 'VVT แบงก์ 1',
    0x36 => 'VVT แบงก์ 2',
    0x39 => 'EVAP รั่ว (ปิดท่อ)',
    0x3A => 'EVAP รั่ว 0.090"',
    0x3B => 'EVAP รั่ว 0.040"',
    0x3C => 'EVAP รั่ว 0.020"',
    0x3D => 'อัตราการไหลของ Purge',
    0x61 => 'แคตาไลติกแบบอุ่น แบงก์ 1',
    0x62 => 'แคตาไลติกแบบอุ่น แบงก์ 2',
    0x71 => 'ระบบอากาศรอง 1',
    0x72 => 'ระบบอากาศรอง 2',
    0x81 => 'ระบบเชื้อเพลิง แบงก์ 1',
    0x82 => 'ระบบเชื้อเพลิง แบงก์ 2',
    0x85 => 'แรงดันบูสต์ แบงก์ 1',
    0x86 => 'แรงดันบูสต์ แบงก์ 2',
    0x90 => 'เซ็นเซอร์ NOx แบงก์ 1',
    0x91 => 'เซ็นเซอร์ NOx แบงก์ 2',
    0x98 => 'แคตลด NOx แบงก์ 1',
    0x99 => 'แคตลด NOx แบงก์ 2',
    0xA1 => 'การจุดระเบิด (รวม)',
    0xB0 => 'กรองฝุ่น DPF แบงก์ 1',
    0xB1 => 'กรองฝุ่น DPF แบงก์ 2',
    _ => 'ระบบ MID ${mid.toRadixString(16).toUpperCase().padLeft(2, '0')}',
  };
}

String mode06TidName(int mid, int tid) {
  final isMisfire = mid >= 0xA1 && mid <= 0xAD;
  if (isMisfire) {
    return switch (tid) {
      0x0B => 'ค่าเฉลี่ย 10 รอบขับล่าสุด',
      0x0C => 'รอบขับล่าสุด/ปัจจุบัน',
      _ => 'ทดสอบ ${_hx(tid)}',
    };
  }
  return switch (tid) {
    0x01 => 'เกณฑ์เปลี่ยนจากหนาเป็นบาง',
    0x02 => 'เกณฑ์เปลี่ยนจากบางเป็นหนา',
    0x03 => 'แรงดันต่ำสำหรับคำนวณเวลา',
    0x04 => 'แรงดันสูงสำหรับคำนวณเวลา',
    0x05 => 'เวลาเปลี่ยนหนา→บาง',
    0x06 => 'เวลาเปลี่ยนบาง→หนา',
    0x07 => 'แรงดันต่ำสุด',
    0x08 => 'แรงดันสูงสุด',
    0x09 => 'เวลาระหว่างการสลับ',
    _ => tid >= 0x80 ? 'ทดสอบเฉพาะผู้ผลิต ${_hx(tid)}' : 'ทดสอบ ${_hx(tid)}',
  };
}

String _hx(int v) => '0x${v.toRadixString(16).toUpperCase().padLeft(2, '0')}';
