import '../elm/elm327.dart';
import '../elm/response_parser.dart';
import '../obd/dtc.dart';

/// รหัสปัญหาจากกล่องอื่น (UDS 3 ไบต์ หรือ KWP2000 2 ไบต์)
class ModuleDtc {
  const ModuleDtc({required this.code, this.ftb = 0, this.status = 0, this.kwp = false});

  /// รหัสหลัก เช่น C0035
  final String code;

  /// Failure Type Byte บอกลักษณะความผิดปกติ (UDS เท่านั้น)
  final int ftb;
  final int status;
  final bool kwp;

  String get display => ftb == 0 ? code : '$code-${ftb.toRadixString(16).padLeft(2, '0').toUpperCase()}';

  /// UDS status bit 3 = confirmed, bit 2 = pending, bit 0 = testFailed
  bool get confirmed => kwp ? true : status & 0x08 != 0;
  bool get pending => !kwp && status & 0x04 != 0;
  bool get activeNow => !kwp && status & 0x01 != 0;
  bool get warningLamp => !kwp && status & 0x80 != 0;

  String get statusTh {
    if (kwp) return 'บันทึกไว้';
    final parts = <String>[
      if (activeNow) 'เกิดอยู่ตอนนี้',
      if (confirmed) 'ยืนยันแล้ว',
      if (pending) 'รอยืนยัน',
      if (warningLamp) 'สั่งไฟเตือน',
    ];
    if (parts.isEmpty && status & 0x20 != 0) return 'เคยเกิดหลังลบรหัสครั้งล่าสุด (ประวัติ)';
    return parts.isEmpty ? 'เคยเกิด (ประวัติ)' : parts.join(' · ');
  }

  /// ความหมายของ FTB ที่พบบ่อย (ISO 15031-6 / SAE J2012 ภาคผนวก)
  String? get ftbTh => switch (ftb) {
        0x00 => null,
        0x01 => 'ความผิดปกติทางไฟฟ้าทั่วไป',
        0x11 => 'วงจรลัดลงกราวด์',
        0x12 => 'วงจรลัดกับไฟบวก',
        0x13 => 'วงจรขาด',
        0x14 => 'ลัดลงกราวด์หรือขาด',
        0x15 => 'ลัดกับไฟบวกหรือขาด',
        0x16 => 'แรงดันต่ำกว่าเกณฑ์',
        0x17 => 'แรงดันสูงกว่าเกณฑ์',
        0x1C => 'แรงดันอยู่นอกช่วง',
        0x1F => 'วงจรเป็นๆ หายๆ',
        0x29 => 'สัญญาณไม่ถูกต้อง',
        0x2F => 'สัญญาณผิดปกติ',
        0x31 => 'ไม่มีสัญญาณ',
        0x62 => 'สัญญาณเปรียบเทียบไม่ตรงกัน',
        0x64 => 'สัญญาณไม่สมเหตุสมผล',
        0x71 => 'ตัวขับเคลื่อนติดขัด',
        0x87 => 'ไม่ได้รับข้อความ',
        0x96 => 'ความผิดปกติภายในชิ้นส่วน',
        _ => null,
      };

  Map<String, dynamic> toJson() => {'c': code, 'f': ftb, 's': status, 'k': kwp};

  factory ModuleDtc.fromJson(Map<String, dynamic> j) => ModuleDtc(
        code: j['c'] as String,
        ftb: j['f'] as int? ?? 0,
        status: j['s'] as int? ?? 0,
        kwp: j['k'] as bool? ?? false,
      );
}

/// กล่องควบคุมหนึ่งกล่องในรถ
class EcuModule {
  EcuModule({required this.tx, required this.rx, this.name, List<ModuleDtc>? dtcs, this.error})
      : dtcs = dtcs ?? [];

  final String tx;
  final String rx;
  String? name;
  List<ModuleDtc> dtcs;

  /// ข้อความเมื่ออ่านกล่องนี้ไม่สำเร็จ
  String? error;

  String get title => name ?? 'กล่อง $tx';

  Map<String, dynamic> toJson() => {
        'tx': tx,
        'rx': rx,
        'name': name,
        'dtcs': dtcs.map((d) => d.toJson()).toList(),
        'err': error,
      };

  factory EcuModule.fromJson(Map<String, dynamic> j) => EcuModule(
        tx: j['tx'] as String,
        rx: j['rx'] as String,
        name: j['name'] as String?,
        dtcs: (j['dtcs'] as List<dynamic>? ?? const [])
            .map((e) => ModuleDtc.fromJson(e as Map<String, dynamic>))
            .toList(),
        error: j['err'] as String?,
      );
}

class UdsNegative implements Exception {
  UdsNegative(this.sid, this.nrc);
  final int sid;
  final int nrc;

  String get messageTh => switch (nrc) {
        0x10 => 'กล่องปฏิเสธคำสั่ง',
        0x11 => 'กล่องไม่รองรับคำสั่งนี้',
        0x12 => 'กล่องไม่รองรับคำสั่งย่อยนี้',
        0x13 => 'รูปแบบข้อความไม่ถูกต้อง',
        0x22 => 'เงื่อนไขไม่พร้อม (เช่น ต้องดับเครื่อง หรือจอดรถ)',
        0x31 => 'ค่าที่ขออยู่นอกช่วง',
        0x33 => 'ต้องปลดล็อกความปลอดภัย (Security Access) ก่อน',
        0x7E || 0x7F => 'ต้องเข้าโหมดวินิจฉัยพิเศษก่อน',
        _ => 'กล่องตอบปฏิเสธ (รหัส 0x${nrc.toRadixString(16).toUpperCase()})',
      };

  @override
  String toString() => messageTh;
}

/// ตัวคุยกับกล่องอื่นๆ ในรถผ่าน UDS (ISO 14229) และ KWP2000 บน CAN
/// ใช้ได้กับ ELM327 เพราะคำสั่งที่ส่งยาวไม่เกิน 1 เฟรม (คำตอบยาวได้)
class UdsClient {
  UdsClient(this.elm);

  final Elm327 elm;

  /// ที่อยู่ที่พบบ่อยในรถญี่ปุ่น/ยุโรป (11 บิต) — ตอบกลับที่ +8
  static const quick11 = <int>[
    0x7E0, 0x7E1, 0x7E2, 0x7E3, 0x7E4, 0x7E5, 0x7E6, 0x7E7,
    0x7B0, 0x7B2, 0x7C0, 0x7C4, 0x7C6, 0x780, 0x781, 0x750, 0x752, 0x760, 0x770,
    0x7A0, 0x7A2, 0x7D0, 0x7D2, 0x720, 0x730, 0x740, 0x744, 0x710, 0x700, 0x790,
  ];

  /// ที่อยู่ที่พบบ่อย (29 บิต แบบ 18DA xx F1)
  static const quick29 = <int>[
    0x00, 0x10, 0x11, 0x17, 0x18, 0x19, 0x1A, 0x1E, 0x20, 0x21, 0x28, 0x29, 0x2A,
    0x30, 0x3A, 0x40, 0x41, 0x58, 0x59, 0x60, 0x70, 0x7A, 0xA0, 0xC0, 0xE0,
  ];

  /// ชื่อที่คาดเดาได้จากมาตรฐาน OBD (ใช้เมื่อกล่องไม่บอกชื่อตัวเอง)
  static String? guessName(String tx) => switch (tx.toUpperCase()) {
        '7E0' || '18DA10F1' => 'เครื่องยนต์ (ECM)',
        '7E1' || '18DA18F1' => 'เกียร์ (TCM)',
        '7E2' => 'ไฮบริด / มอเตอร์',
        _ => null,
      };

  static String _hx(int v, int w) => v.toRadixString(16).padLeft(w, '0').toUpperCase();

  List<(String, String)> candidates({bool deep = false}) {
    if (elm.is29Bit) {
      final ids = deep ? List<int>.generate(256, (i) => i) : quick29;
      return [for (final i in ids) ('18DA${_hx(i, 2)}F1', '18DAF1${_hx(i, 2)}')];
    }
    final ids = deep
        ? [for (var a = 0x700; a <= 0x7F7; a++) if (a & 0x0F < 8 && a != 0x7DF) a]
        : quick11;
    return [for (final i in ids) (_hx(i, 3), _hx(i + 8, 3))];
  }

  /// ส่งคำขอไปยังกล่องที่ตั้ง target ไว้แล้ว คืนข้อมูลคำตอบแรกที่ไม่ใช่ "รอสักครู่" (0x78)
  Future<List<int>?> _request(String rx, String hex, {Duration timeout = const Duration(seconds: 4)}) async {
    final ParseResult r = await elm.query(hex, timeout: timeout);
    for (final m in r.messages) {
      if (m.ecu.toUpperCase() != rx.toUpperCase() || m.data.isEmpty) continue;
      if (m.data[0] == 0x7F && m.data.length >= 3 && m.data[2] == 0x78) continue;
      return m.data;
    }
    return null;
  }

  /// ส่งคำขอและแปลงคำตอบปฏิเสธเป็น [UdsNegative]
  Future<List<int>?> _call(EcuModule m, String hex, int sid) async {
    final d = await _request(m.rx, hex);
    if (d == null) return null;
    if (d[0] == 0x7F && d.length >= 3 && d[1] == sid) throw UdsNegative(sid, d[2]);
    if (d[0] != sid + 0x40) return null;
    return d;
  }

  /// ค้นหากล่องที่ตอบในรถ
  Future<List<EcuModule>> discover({
    bool deep = false,
    void Function(double progress, String step)? onProgress,
  }) {
    return elm.exclusive(() async {
      final found = <EcuModule>[];
      final cands = candidates(deep: deep);
      try {
        await elm.setResponseTimeout(deep ? 60 : 100);
        for (var i = 0; i < cands.length; i++) {
          final (tx, rx) = cands[i];
          onProgress?.call(i / cands.length, 'ค้นหากล่อง $tx');
          await elm.send('ATSH$tx');
          await elm.send('ATCRA$rx');
          var d = await _request(rx, '3E00', timeout: const Duration(seconds: 2));
          d ??= await _request(rx, '1001', timeout: const Duration(seconds: 2));
          if (d != null) found.add(EcuModule(tx: tx, rx: rx));
        }
        await elm.setResponseTimeout(200);
        for (var i = 0; i < found.length; i++) {
          final m = found[i];
          onProgress?.call(1, 'อ่านชื่อกล่อง ${m.tx}');
          await elm.setTarget(m.tx, m.rx);
          m.name = await _readAscii(m, 0xF197) ?? guessName(m.tx);
        }
      } finally {
        await elm.resetTarget();
      }
      return found;
    });
  }

  Future<String?> _readAscii(EcuModule m, int did) async {
    try {
      final d = await _call(m, '22${_hx(did, 4)}', 0x22);
      if (d == null || d.length <= 3) return null;
      final s = String.fromCharCodes(d.sublist(3).where((b) => b >= 0x20 && b < 0x7F)).trim();
      return s.isEmpty ? null : s;
    } on UdsNegative {
      return null;
    }
  }

  /// อ่าน Data Identifier ใดๆ (สำหรับช่าง) คืนไบต์ข้อมูลหลัง DID
  Future<List<int>?> readDid(EcuModule m, int did) {
    return elm.exclusive(() async {
      try {
        await elm.setTarget(m.tx, m.rx);
        final d = await _call(m, '22${_hx(did, 4)}', 0x22);
        if (d == null || d.length < 3) return null;
        return d.sublist(3);
      } finally {
        await elm.resetTarget();
      }
    });
  }

  /// อ่านรหัสปัญหาของกล่อง ลอง UDS ก่อน ถ้ากล่องไม่รองรับใช้ KWP2000
  Future<List<ModuleDtc>> readDtcs(EcuModule m) {
    return elm.exclusive(() async {
      try {
        await elm.setTarget(m.tx, m.rx);
        try {
          List<int>? d;
          try {
            d = await _call(m, '1902FF', 0x19);
          } on UdsNegative catch (e) {
            if (e.nrc == 0x11) rethrow;
            d = await _call(m, '1902AF', 0x19);
          }
          if (d == null) throw ElmException('กล่องไม่ตอบคำขออ่านรหัส');
          return parseUdsDtcs(d);
        } on UdsNegative catch (e) {
          if (e.nrc != 0x11) rethrow;
          final d = await _call(m, '1802FF00', 0x18);
          if (d == null) throw ElmException('กล่องไม่ตอบคำขออ่านรหัส');
          return parseKwpDtcs(d);
        }
      } finally {
        await elm.resetTarget();
      }
    });
  }

  /// ลบรหัสปัญหาของกล่อง (UDS 14 FFFFFF หรือ KWP 14 FF00)
  /// (ด่านอ่านอย่างเดียวปล่อยคำสั่ง 14 เฉพาะเมื่อเรียกผ่านฟังก์ชันนี้)
  Future<bool> clearDtcs(EcuModule m) {
    return elm.allowClearing(() => elm.exclusive(() async {
          try {
            await elm.setTarget(m.tx, m.rx);
            try {
              return await _call(m, '14FFFFFF', 0x14) != null;
            } on UdsNegative catch (e) {
              if (e.nrc != 0x11 && e.nrc != 0x13) rethrow;
              return await _call(m, '14FF00', 0x14) != null;
            }
          } finally {
            await elm.resetTarget();
          }
        }));
  }
}

/// UDS 59 02 [mask] (DTC 3 ไบต์ + สถานะ) ...
List<ModuleDtc> parseUdsDtcs(List<int> d) {
  final out = <ModuleDtc>[];
  if (d.length < 3 || d[0] != 0x59) return out;
  for (var i = 3; i + 4 <= d.length; i += 4) {
    final hi = d[i], mid = d[i + 1], ftb = d[i + 2], st = d[i + 3];
    if (hi == 0 && mid == 0 && ftb == 0) continue;
    // เก็บเฉพาะรหัสที่เคยทดสอบไม่ผ่านจริง (testFailed, pending, confirmed, failedSinceClear)
    // ตัดรายการที่มีแค่บิต "ยังไม่ได้ทดสอบ" ซึ่งบางกล่องส่งมาทั้งรายการหลังลบรหัส
    if (st & 0x2D == 0) continue;
    out.add(ModuleDtc(code: decodeDtcBytes(hi, mid), ftb: ftb, status: st));
  }
  return out;
}

/// KWP2000 58 [n] (DTC 2 ไบต์ + สถานะ) ...
List<ModuleDtc> parseKwpDtcs(List<int> d) {
  final out = <ModuleDtc>[];
  if (d.length < 2 || d[0] != 0x58) return out;
  for (var i = 2; i + 3 <= d.length; i += 3) {
    if (d[i] == 0 && d[i + 1] == 0) continue;
    out.add(ModuleDtc(code: decodeDtcBytes(d[i], d[i + 1]), status: d[i + 2], kwp: true));
  }
  return out;
}
