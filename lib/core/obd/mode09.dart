/// Mode 09: ข้อมูลตัวรถและกล่อง ECU (CAN) — VIN, Calibration ID, CVN, ชื่อกล่อง, ตัวนับการใช้งาน
library;

/// ข้อมูลกล่องจาก Mode 09 หนึ่งกล่อง
class EcuIdentity {
  const EcuIdentity({
    required this.ecu,
    this.name,
    this.calIds = const [],
    this.cvns = const [],
    this.obdConditionCount,
    this.ignitionCount,
  });

  final String ecu;
  final String? name;
  final List<String> calIds;
  final List<String> cvns;

  /// จำนวนรอบขับที่เข้าเงื่อนไข OBD (สะสมตั้งแต่กล่องใหม่ ลบโค้ดแล้วไม่หาย)
  final int? obdConditionCount;

  /// จำนวนครั้งที่บิดกุญแจสตาร์ท (สะสมตั้งแต่กล่องใหม่ ลบโค้ดแล้วไม่หาย)
  final int? ignitionCount;

  Map<String, dynamic> toJson() => {
        'ecu': ecu,
        'name': name,
        'calIds': calIds,
        'cvns': cvns,
        'obdCond': obdConditionCount,
        'ign': ignitionCount,
      };

  factory EcuIdentity.fromJson(Map<String, dynamic> j) => EcuIdentity(
        ecu: j['ecu'] as String,
        name: j['name'] as String?,
        calIds: (j['calIds'] as List<dynamic>? ?? const []).cast<String>(),
        cvns: (j['cvns'] as List<dynamic>? ?? const []).cast<String>(),
        obdConditionCount: j['obdCond'] as int?,
        ignitionCount: j['ign'] as int?,
      );
}

String _ascii(Iterable<int> bytes) =>
    String.fromCharCodes(bytes.map((b) => b >= 0x20 && b < 0x7F ? b : 0x20)).trim().replaceAll(RegExp(r'\s+'), ' ');

/// [payload] = ข้อมูลหลัง 49 04 (ไบต์แรกคือจำนวนรายการ)
List<String> parseCalIds(List<int> payload) {
  if (payload.isEmpty) return const [];
  final body = payload.sublist(1);
  return [
    for (var i = 0; i + 16 <= body.length; i += 16)
      if (_ascii(body.sublist(i, i + 16)).isNotEmpty) _ascii(body.sublist(i, i + 16)),
  ];
}

/// [payload] = ข้อมูลหลัง 49 06
List<String> parseCvns(List<int> payload) {
  if (payload.isEmpty) return const [];
  final body = payload.sublist(1);
  return [
    for (var i = 0; i + 4 <= body.length; i += 4)
      body.sublist(i, i + 4).map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(),
  ];
}

/// [payload] = ข้อมูลหลัง 49 0A เช่น "ECM\0-EngineControl"
String? parseEcuName(List<int> payload) {
  if (payload.length < 2) return null;
  final s = _ascii(payload.sublist(1)).replaceAll(' -', ' - ');
  return s.isEmpty ? null : s;
}

/// [payload] = ข้อมูลหลัง 49 08 หรือ 49 0B → ตัวนับ 16 บิต
/// ตัวที่ 0 = OBD condition counter, ตัวที่ 1 = ignition counter
List<int> parseIupr(List<int> payload) {
  if (payload.isEmpty) return const [];
  final body = payload.sublist(1);
  return [for (var i = 0; i + 2 <= body.length; i += 2) body[i] * 256 + body[i + 1]];
}
