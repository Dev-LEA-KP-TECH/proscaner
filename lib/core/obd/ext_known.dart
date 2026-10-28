import 'ext_pid.dart';

/// ค่าที่ค้นพบเองและยังไม่รู้ว่าเป็นค่าอะไร
///
/// หน้า "ค้นหาค่าที่กล่องตอบ" บันทึกเลขที่กล่องตอบเป็น "ค่าใหม่ <กล่อง> <คำสั่ง>" เพราะกล่องส่งมาแค่ตัวเลข
/// ค่าที่ช่างเริ่มเทียบ (มีจุดเทียบ) หรือยืนยันแล้ว หรือเปลี่ยนชื่อแล้ว ไม่นับ
bool isUnnamedDiscovered(ExtPid p) => p.name.startsWith('ค่าใหม่') && !p.verified && p.points.isEmpty;

/// ชุดในคลังเป็นของรถรุ่นเดียวกันหรือไม่ (ใช้ตั้งชื่อค่าที่ค้นพบเอง)
///
/// เข้มกว่า [packFitsVehicle]: เลขคำสั่งของแต่ละรุ่น/รุ่นกล่องไม่เหมือนกัน เลขเดียวกันอาจเป็นคนละค่า
/// จึงต้องรู้ยี่ห้อ รุ่น และปี และปีต้องอยู่ในช่วงปีของชุดในคลังจริงๆ (ไม่เผื่อ ±1 ปี)
bool sameCarForNames({
  required String libBrand,
  List<String> libModels = const [],
  List<int> libYears = const [],
  String? make,
  String? model,
  int? year,
}) {
  final brand = libBrand.trim().toLowerCase();
  if (brand.isEmpty || make == null || make.trim().toLowerCase() != brand) return false;
  if (libModels.isNotEmpty) {
    final m = (model ?? '').trim().toLowerCase();
    final hit = m.length >= 3 &&
        libModels.any((x) {
          final l = x.trim().toLowerCase();
          return l.length >= 3 && (m.contains(l) || l.contains(m));
        });
    if (!hit) return false;
  }
  if (libYears.length == 2 && (year == null || year < libYears[0] || year > libYears[1])) return false;
  return true;
}

/// ค่าที่ค้นพบเองหนึ่งค่า กับค่าที่รู้แล้วในคลัง (คำสั่งเดียวกัน)
class KnownMatch {
  const KnownMatch({required this.discovered, required this.known, required this.source});

  /// ค่าในชุดของผู้ใช้ ("ค่าใหม่ …")
  final ExtPid discovered;

  /// ค่าที่รู้แล้วของคำสั่งเดียวกัน (คำตอบเดียวอาจมีหลายค่า)
  final List<ExtPid> known;

  /// ชื่อชุดในคลังที่ให้ชื่อ
  final String source;

  String get names => known.map((k) => k.name).join(', ');
}

/// หาชื่อให้ค่าที่ค้นพบเอง: กล่องและคำสั่งเดียวกับค่าในชุดคลังของรถรุ่นเดียวกัน
/// ([library] ควรกรองด้วย [sameCarForNames] มาแล้ว) ชุดแรกที่มีคำสั่งนั้นได้ก่อน
List<KnownMatch> findKnown(ExtPidPack pack, List<ExtPidPack> library) {
  final out = <KnownMatch>[];
  for (final p in pack.pids) {
    if (!isUnnamedDiscovered(p)) continue;
    for (final lib in library) {
      final hits = [
        for (final k in lib.pids)
          if (k.cmdKey == p.cmdKey && !isUnnamedDiscovered(k)) k,
      ];
      if (hits.isNotEmpty) {
        out.add(KnownMatch(discovered: p, known: hits, source: lib.name));
        break;
      }
    }
  }
  return out;
}

/// ตั้งชื่อ สูตร หน่วย และกลุ่มจากคลังให้ค่าที่ค้นพบเอง คืนชุดใหม่ (ชุดเดิมไม่ถูกแก้)
///
/// ค่าที่ค้นพบถูกแทนที่ด้วยทุกค่าของคำสั่งนั้นในคลัง ตรงตำแหน่งเดิม ค่าที่มีในชุดอยู่แล้วไม่เพิ่มซ้ำ
/// และถ้าชุดเลือกอ่านเฉพาะบางกลุ่มไว้ กลุ่มของค่าที่ได้ชื่อจะถูกเปิดอ่านด้วย
ExtPidPack applyKnown(ExtPidPack pack, List<KnownMatch> matches) {
  final copy = pack.copyWithId(pack.id);
  final byCmd = {for (final m in matches) m.discovered.cmdKey: m};
  final have = {
    for (final p in copy.pids)
      if (!isUnnamedDiscovered(p)) p.key,
  };
  final out = <ExtPid>[];
  final groups = <String>[];
  for (final p in copy.pids) {
    final m = isUnnamedDiscovered(p) ? byCmd[p.cmdKey] : null;
    if (m == null) {
      out.add(p);
      continue;
    }
    for (final k in m.known) {
      final c = k.copy();
      if (!have.add(c.key)) continue;
      c.source ??= m.source;
      out.add(c);
      final g = c.group.isEmpty ? 'ทั่วไป' : c.group;
      if (!groups.contains(g)) groups.add(g);
    }
  }
  copy.pids
    ..clear()
    ..addAll(out);
  final on = copy.activeGroups;
  if (on != null) {
    for (final g in groups) {
      if (!on.contains(g)) on.add(g);
    }
  }
  return copy;
}
