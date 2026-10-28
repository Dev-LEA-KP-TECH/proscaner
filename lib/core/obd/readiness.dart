/// สถานะความพร้อมของระบบตรวจสอบตัวเอง (Readiness monitors) จาก Mode 01 PID 01
///
/// ไบต์ B: ระบบตรวจแบบต่อเนื่อง (misfire / fuel / components) + บิต 3 = เครื่องดีเซล
/// ไบต์ C: ระบบที่ ECU รองรับ, ไบต์ D: ระบบที่ยังทดสอบไม่เสร็จ (1 = ยังไม่เสร็จ)
library;

class ReadinessMonitor {
  const ReadinessMonitor({required this.nameTh, required this.complete, this.continuous = false});

  final String nameTh;
  final bool complete;

  /// ระบบที่ตรวจตลอดเวลา (ไม่ต้องขับทดสอบรอบพิเศษ)
  final bool continuous;

  Map<String, dynamic> toJson() => {'n': nameTh, 'c': complete, 'k': continuous};

  factory ReadinessMonitor.fromJson(Map<String, dynamic> j) => ReadinessMonitor(
        nameTh: j['n'] as String,
        complete: j['c'] as bool,
        continuous: j['k'] as bool? ?? false,
      );
}

const _sparkNames = [
  'แคตาไลติก',
  'แคตาไลติกแบบอุ่น',
  'ระบบไอระเหยน้ำมัน (EVAP)',
  'ระบบอากาศรอง',
  'น้ำยาแอร์ (เลิกใช้)',
  'เซ็นเซอร์ออกซิเจน',
  'ฮีตเตอร์เซ็นเซอร์ออกซิเจน',
  'ระบบ EGR / VVT',
];

const _dieselNames = [
  'แคต NMHC',
  'ระบบลด NOx / SCR',
  '(สงวน)',
  'แรงดันบูสต์',
  '(สงวน)',
  'เซ็นเซอร์ไอเสีย',
  'กรองฝุ่น DPF',
  'ระบบ EGR / VVT',
];

/// แปลงไบต์ A–D ของ PID 01 เป็นรายการระบบที่รถรองรับ
List<ReadinessMonitor> decodeReadiness(List<int> d) {
  if (d.length < 4) return const [];
  final b = d[1], c = d[2], e = d[3];
  final diesel = b & 0x08 != 0;
  final out = <ReadinessMonitor>[];
  const cont = ['การจุดระเบิด (Misfire)', 'ระบบเชื้อเพลิง', 'ชิ้นส่วนรวม'];
  for (var i = 0; i < 3; i++) {
    if (b & (1 << i) != 0) {
      out.add(ReadinessMonitor(nameTh: cont[i], complete: b & (1 << (i + 4)) == 0, continuous: true));
    }
  }
  final names = diesel ? _dieselNames : _sparkNames;
  for (var i = 0; i < 8; i++) {
    if (i == 4 && !diesel) continue; // A/C ไม่ใช้แล้ว
    if (c & (1 << i) != 0) {
      out.add(ReadinessMonitor(nameTh: names[i], complete: e & (1 << i) == 0));
    }
  }
  return out;
}
