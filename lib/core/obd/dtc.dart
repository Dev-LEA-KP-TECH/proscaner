import '../elm/response_parser.dart';

/// ประเภทของรหัสปัญหาตามโหมดที่อ่าน
enum DtcKind {
  stored, // Mode 03: ยืนยันแล้ว ไฟเตือนอาจติด
  pending, // Mode 07: พบครั้งแรก รอยืนยันในรอบขับถัดไป
  permanent; // Mode 0A: ลบด้วยเครื่องมือไม่ได้ ECU จะลบเองเมื่อทดสอบผ่าน

  String get labelTh => switch (this) {
        DtcKind.stored => 'ยืนยันแล้ว',
        DtcKind.pending => 'รอยืนยัน',
        DtcKind.permanent => 'ถาวร',
      };

  int get mode => switch (this) {
        DtcKind.stored => 0x03,
        DtcKind.pending => 0x07,
        DtcKind.permanent => 0x0A,
      };
}

class Dtc {
  const Dtc(this.code, this.kind, {this.ecu = ''});

  final String code;
  final DtcKind kind;
  final String ecu;

  Map<String, dynamic> toJson() => {'code': code, 'kind': kind.name, 'ecu': ecu};

  factory Dtc.fromJson(Map<String, dynamic> j) =>
      Dtc(j['code'] as String, DtcKind.values.byName(j['kind'] as String), ecu: j['ecu'] as String? ?? '');

  @override
  bool operator ==(Object other) =>
      other is Dtc && other.code == code && other.kind == kind && other.ecu == ecu;

  @override
  int get hashCode => Object.hash(code, kind, ecu);

  @override
  String toString() => '$code(${kind.name})';
}

/// แปลง 2 ไบต์เป็นรหัส เช่น 0x01 0x71 → P0171 (SAE J2012)
String decodeDtcBytes(int a, int b) {
  const letters = ['P', 'C', 'B', 'U'];
  final letter = letters[a >> 6];
  final d1 = (a >> 4) & 0x03;
  final d2 = (a & 0x0F).toRadixString(16).toUpperCase();
  final rest = b.toRadixString(16).padLeft(2, '0').toUpperCase();
  return '$letter$d1$d2$rest';
}

/// อ่านรหัสจากคำตอบ Mode 03/07/0A
///
/// บน CAN ไบต์ที่สองคือจำนวนโค้ด ส่วนโปรโตคอลเก่าไม่มีไบต์จำนวน
/// และแต่ละบรรทัดมี 3 โค้ด (เติม 0000 ถ้าไม่ครบ)
List<Dtc> parseDtcMessages(List<EcuMessage> messages, DtcKind kind, {required bool isCan}) {
  final responseId = kind.mode + 0x40;
  final out = <Dtc>[];
  for (final m in messages) {
    if (m.data.isEmpty || m.data[0] != responseId) continue;
    var payload = m.data.sublist(1);
    if (isCan) {
      if (payload.isEmpty) continue;
      final count = payload[0];
      payload = payload.sublist(1);
      final n = (count * 2).clamp(0, payload.length);
      payload = payload.sublist(0, n);
    }
    for (var i = 0; i + 1 < payload.length; i += 2) {
      final a = payload[i];
      final b = payload[i + 1];
      if (a == 0 && b == 0) continue;
      final dtc = Dtc(decodeDtcBytes(a, b), kind, ecu: m.ecu);
      if (!out.contains(dtc)) out.add(dtc);
    }
  }
  return out;
}
