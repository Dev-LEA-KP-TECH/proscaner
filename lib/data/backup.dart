import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/diagnosis/diagnosis.dart';
import '../core/obd/ext_pid.dart';
import 'garage_store.dart';
import 'history_store.dart';
import 'log_store.dart';
import 'remap_store.dart';

/// ค่าตั้งค่าของแอปแบบที่สำรอง/กู้คืนได้ (แยกจาก SharedPreferences เพื่อให้เทสต์ได้)
abstract class BackupPrefs {
  /// ทุกค่า: String, bool, int, double หรือ `List<String>`
  Map<String, Object> readAll();

  bool has(String key);

  Future<void> write(String key, Object value);
}

class SharedPrefsBackup implements BackupPrefs {
  SharedPrefsBackup(this.p);

  final SharedPreferences p;

  @override
  Map<String, Object> readAll() {
    final out = <String, Object>{};
    for (final k in p.getKeys()) {
      final v = p.get(k);
      if (v is List) {
        out[k] = [for (final e in v) '$e'];
      } else if (v != null) {
        out[k] = v;
      }
    }
    return out;
  }

  @override
  bool has(String key) => p.containsKey(key);

  @override
  Future<void> write(String key, Object value) async {
    if (value is String) {
      await p.setString(key, value);
    } else if (value is bool) {
      await p.setBool(key, value);
    } else if (value is int) {
      await p.setInt(key, value);
    } else if (value is double) {
      await p.setDouble(key, value);
    } else if (value is List) {
      await p.setStringList(key, [for (final e in value) '$e']);
    }
  }
}

/// ข้อมูลทั้งแอปในไฟล์สำรองไฟล์เดียว (JSON)
class BackupData {
  BackupData({
    required this.created,
    required this.appVersion,
    required this.prefs,
    required this.vehicles,
    required this.history,
    required this.driveLogs,
    required this.remapRuns,
    this.logoName,
    this.logoBytes,
  });

  /// เครื่องหมายว่าเป็นไฟล์สำรองของ ProScaner และรุ่นของรูปแบบไฟล์
  static const format = 'proscaner_backup';
  static const formatVersion = 1;

  /// ชุดค่าเฉพาะยี่ห้อ ("ชุดของฉัน") เก็บอยู่ในค่าตั้งค่านี้
  static const packsKey = 'ext_packs';

  final DateTime created;
  final String appVersion;
  final Map<String, Object> prefs;
  final List<Map<String, dynamic>> vehicles;
  final List<Map<String, dynamic>> history;

  /// บันทึกการขับ id -> CSV
  final Map<String, String> driveLogs;

  /// ผลทดสอบรีแมพ id -> JSON
  final Map<String, String> remapRuns;

  /// โลโก้อู่ (ชื่อไฟล์เดิมและข้อมูลรูป)
  final String? logoName;
  final Uint8List? logoBytes;

  /// ชุดค่าเฉพาะยี่ห้อในไฟล์ (ยังไม่ได้ตรวจ)
  List<Map<String, dynamic>> get packs {
    final list = decodeJsonList(prefs[packsKey]);
    return [if (list != null) for (final e in list) if (e is Map<String, dynamic>) e];
  }

  String get shopName {
    final v = prefs['shop_name'];
    return v is String ? v.trim() : '';
  }

  /// รายการสั้นๆ ว่าในไฟล์มีอะไรบ้าง
  List<String> contentsTh() => [
        'รถในโรงรถ ${vehicles.length} คัน',
        'ประวัติการสแกน ${history.length} ครั้ง',
        'ชุดค่าเฉพาะยี่ห้อ ${packs.length} ชุด',
        'บันทึกการขับ ${driveLogs.length} ครั้ง',
        'ผลทดสอบรีแมพ ${remapRuns.length} ครั้ง',
        if (shopName.isNotEmpty || logoBytes != null)
          'ข้อมูลอู่${shopName.isEmpty ? '' : ' "$shopName"'}${logoBytes != null ? ' พร้อมโลโก้' : ''}',
      ];

  Map<String, dynamic> toJson() => {
        format: formatVersion,
        'created': created.toIso8601String(),
        'app': appVersion,
        'prefs': {for (final e in prefs.entries) e.key: _encodePref(e.value)},
        'garage': vehicles,
        'history': history,
        'drive_logs': driveLogs,
        'remap_runs': remapRuns,
        if (logoBytes != null) 'shop_logo': {'name': logoName ?? 'shop_logo.png', 'b64': base64Encode(logoBytes!)},
      };

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  /// อ่านไฟล์สำรอง ถ้าไม่ใช่ไฟล์ของ ProScaner จะโยน [FormatException] พร้อมข้อความภาษาไทย
  static BackupData parse(List<int> bytes) {
    const notBackup = FormatException('ไฟล์นี้ไม่ใช่ไฟล์สำรองของ ProScaner');
    Object? j;
    try {
      var text = utf8.decode(bytes);
      if (text.startsWith('\uFEFF')) text = text.substring(1);
      j = jsonDecode(text);
    } catch (_) {
      throw notBackup;
    }
    if (j is! Map<String, dynamic>) throw notBackup;
    final v = j[format];
    if (v is! int) throw notBackup;
    if (v > formatVersion) {
      throw const FormatException('ไฟล์สำรองนี้มาจาก ProScaner รุ่นใหม่กว่า อัปเดตแอปก่อนแล้วค่อยกู้คืน');
    }
    final prefs = <String, Object>{};
    final rawPrefs = j['prefs'];
    if (rawPrefs is Map) {
      rawPrefs.forEach((k, e) {
        final value = _decodePref(e);
        if (k is String && value != null) prefs[k] = value;
      });
    }
    List<Map<String, dynamic>> maps(Object? raw) => [
          if (raw is List)
            for (final e in raw)
              if (e is Map<String, dynamic>) e,
        ];
    Map<String, String> texts(Object? raw) => {
          if (raw is Map)
            for (final e in raw.entries)
              if (e.key is String && e.value is String) e.key as String: e.value as String,
        };
    String? logoName;
    Uint8List? logoBytes;
    final logo = j['shop_logo'];
    if (logo is Map && logo['b64'] is String) {
      try {
        logoBytes = base64Decode(logo['b64'] as String);
        logoName = logo['name'] is String ? logo['name'] as String : null;
      } catch (_) {
        logoBytes = null;
      }
    }
    return BackupData(
      created: DateTime.tryParse('${j['created']}') ?? DateTime.fromMillisecondsSinceEpoch(0),
      appVersion: j['app'] is String ? j['app'] as String : '',
      prefs: prefs,
      vehicles: maps(j['garage']),
      history: maps(j['history']),
      driveLogs: texts(j['drive_logs']),
      remapRuns: texts(j['remap_runs']),
      logoName: logoName,
      logoBytes: logoBytes,
    );
  }

  static Map<String, Object> _encodePref(Object v) => switch (v) {
        String s => {'t': 's', 'v': s},
        bool b => {'t': 'b', 'v': b},
        int i => {'t': 'i', 'v': i},
        double d => {'t': 'd', 'v': d},
        List<Object?> l => {
            't': 'l',
            'v': [for (final e in l) '$e'],
          },
        _ => {'t': 's', 'v': '$v'},
      };

  static Object? _decodePref(Object? e) {
    if (e is! Map) return null;
    final v = e['v'];
    return switch (e['t']) {
      's' => v is String ? v : null,
      'b' => v is bool ? v : null,
      'i' => v is num ? v.toInt() : null,
      'd' => v is num ? v.toDouble() : null,
      'l' => v is List ? [for (final x in v) '$x'] : null,
      _ => null,
    };
  }
}

/// อ่านค่าตั้งค่าที่เป็น JSON แบบรายการ คืน null ถ้าไม่ใช่รายการหรืออ่านไม่ออก
List<dynamic>? decodeJsonList(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  try {
    final list = jsonDecode(raw);
    return list is List ? list : null;
  } catch (_) {
    return null;
  }
}

/// ผลการกู้คืน
class RestoreSummary {
  const RestoreSummary({
    this.vehiclesAdded = 0,
    this.vehiclesUpdated = 0,
    this.historyAdded = 0,
    this.packsAdded = 0,
    this.packItemsBlocked = 0,
    this.logsAdded = 0,
    this.remapAdded = 0,
    this.settingsFilled = 0,
    this.logoRestored = false,
  });

  final int vehiclesAdded;
  final int vehiclesUpdated;
  final int historyAdded;
  final int packsAdded;

  /// รายการในชุดค่าที่ไม่ถูกนำเข้า (คำสั่งที่ไม่ใช่การอ่านค่า หรือรูปแบบผิด) เหมือนตอนนำเข้าชุดค่าด้วยมือ
  final int packItemsBlocked;
  final int logsAdded;
  final int remapAdded;
  final int settingsFilled;
  final bool logoRestored;

  bool get nothing => linesTh().isEmpty;

  List<String> linesTh() => [
        if (vehiclesAdded > 0) 'เพิ่มรถ $vehiclesAdded คัน',
        if (vehiclesUpdated > 0) 'เติมข้อมูลให้รถที่มีอยู่แล้ว $vehiclesUpdated คัน',
        if (historyAdded > 0) 'เพิ่มประวัติการสแกน $historyAdded ครั้ง',
        if (packsAdded > 0) 'เพิ่มชุดค่าเฉพาะยี่ห้อ $packsAdded ชุด',
        if (packItemsBlocked > 0) 'ข้ามคำสั่งในชุดค่า $packItemsBlocked รายการ (ไม่ใช่คำสั่งอ่านค่า หรือรูปแบบผิด)',
        if (logsAdded > 0) 'เพิ่มบันทึกการขับ $logsAdded ครั้ง',
        if (remapAdded > 0) 'เพิ่มผลทดสอบรีแมพ $remapAdded ครั้ง',
        if (settingsFilled > 0) 'ตั้งค่าที่ยังไม่ได้ตั้ง $settingsFilled รายการ',
        if (logoRestored) 'ใส่โลโก้อู่',
      ];
}

/// ผลการรวมรายการรถ
class VehicleMerge {
  const VehicleMerge(this.vehicles, this.added, this.updated);

  final List<Vehicle> vehicles;
  final int added;
  final int updated;
}

String _vinKey(String? vin) => (vin ?? '').trim().toUpperCase();

/// รวมรถจากไฟล์สำรองเข้ากับรถในเครื่อง ไม่ลบและไม่ทับข้อมูลที่มีอยู่
///
/// - รถคันเดียวกัน = VIN ตรงกัน หรือ id ตรงกันและ VIN ไม่ขัดกัน
/// - id ตรงกันแต่ VIN คนละเลข = คนละคัน: เพิ่มคันที่มาจากไฟล์ด้วย id ใหม่
/// - รถคันเดียวกัน: เติมช่องที่ยังว่าง (ทะเบียน ลูกค้า รุ่น ฯลฯ) และรวมประวัติเลขไมล์ รหัสหัวฉีด รายการบำรุงรักษา
VehicleMerge mergeVehicles(List<Vehicle> local, List<Vehicle> incoming) {
  final out = [...local];
  var added = 0;
  var updated = 0;
  for (var inc in incoming) {
    final vin = _vinKey(inc.vin);
    var i = vin.isEmpty ? -1 : out.indexWhere((v) => _vinKey(v.vin) == vin);
    if (i < 0) {
      final j = out.indexWhere((v) => v.id == inc.id);
      if (j >= 0) {
        if (vin.isEmpty || _vinKey(out[j].vin).isEmpty) {
          i = j;
        } else {
          final ids = {for (final v in out) v.id};
          var k = 2;
          while (ids.contains('${inc.id}_$k')) {
            k++;
          }
          inc = Vehicle.fromJson({...inc.toJson(), 'id': '${inc.id}_$k'});
        }
      }
    }
    if (i < 0) {
      out.add(inc);
      added++;
    } else if (_fillVehicle(out[i], inc)) {
      updated++;
    }
  }
  return VehicleMerge(out, added, updated);
}

bool _blank(String? s) => s == null || s.trim().isEmpty;

bool _fillVehicle(Vehicle v, Vehicle inc) {
  var changed = false;
  String? fill(String? mine, String? theirs) {
    if (_blank(mine) && !_blank(theirs)) {
      changed = true;
      return theirs;
    }
    return mine;
  }

  v.vin = fill(v.vin, inc.vin);
  v.nickname = fill(v.nickname, inc.nickname) ?? '';
  v.plate = fill(v.plate, inc.plate);
  v.customer = fill(v.customer, inc.customer);
  v.phone = fill(v.phone, inc.phone);
  v.make = fill(v.make, inc.make);
  if (_blank(v.model) && !_blank(inc.model)) {
    v.model = inc.model;
    v.idSource = inc.idSource ?? v.idSource;
    changed = true;
  }
  if (v.year == null && inc.year != null) {
    v.year = inc.year;
    changed = true;
  }
  v.fuel = fill(v.fuel, inc.fuel);

  final times = {for (final e in v.odometer) e.time.toIso8601String()};
  var odoAdded = false;
  for (final e in inc.odometer) {
    if (times.add(e.time.toIso8601String())) {
      v.odometer.add(e);
      odoAdded = true;
    }
  }
  if (odoAdded) {
    v.odometer.sort((a, b) => a.time.compareTo(b.time));
    changed = true;
  }

  final codes = {for (final e in v.injectors) '${e.cylinder}|${e.code}'};
  for (final e in inc.injectors) {
    if (codes.add('${e.cylinder}|${e.code}')) {
      v.injectors.add(e);
      changed = true;
    }
  }

  for (final m in inc.maintenance) {
    MaintItem? mine;
    for (final x in v.maintenance) {
      if (x.name == m.name) {
        mine = x;
        break;
      }
    }
    if (mine == null) {
      v.maintenance.add(m);
      changed = true;
      continue;
    }
    if (mine.lastKm == null && m.lastKm != null) {
      mine.lastKm = m.lastKm;
      changed = true;
    }
    if (mine.lastDate == null && m.lastDate != null) {
      mine.lastDate = m.lastDate;
      changed = true;
    }
  }
  return changed;
}

/// ผลการรวมชุดค่าเฉพาะยี่ห้อ
class PackMerge {
  const PackMerge(this.added, this.blocked);

  /// ชุดที่จะเพิ่ม (ตรวจแล้ว)
  final List<ExtPidPack> added;

  /// รายการในชุดที่ไม่ถูกนำเข้า
  final int blocked;
}

/// รายการที่นำเข้าได้: คำสั่งอ่านค่าและรูปแบบถูกต้อง (เกณฑ์เดียวกับการนำเข้าชุดค่าด้วยมือ)
bool _importable(ExtPid x) => (x.requestIsHex ? x.safetyBlock : null) == null && x.validate() == null;

/// ชุดเดียวกันหรือไม่ ดูจากเนื้อหาที่นำเข้าได้ ไม่สน id และผลยืนยัน (ชุดที่เคยย้ายด้วยการนำเข้าจะได้ id ใหม่)
String _packSignature(ExtPidPack p) {
  final keys = [
    for (final x in p.pids)
      if (_importable(x)) x.key,
  ]..sort();
  return '${p.name.trim()}|${p.brand}|${p.lib ?? ''}|${keys.join(';')}';
}

/// เลือกชุดค่าจากไฟล์สำรองที่จะเพิ่ม: ข้ามชุดที่มีอยู่แล้ว (id เดียวกัน, มาจากชุดเดียวกันในคลัง, หรือเนื้อหาเดียวกัน)
/// และตรวจทุกรายการแบบเดียวกับการนำเข้าชุดค่าด้วยมือ: คำสั่งที่ไม่ใช่การอ่านค่า หรือรูปแบบผิด จะไม่ถูกนำเข้า
PackMerge mergePacks(List<dynamic> local, List<Map<String, dynamic>> incoming) {
  final ids = <String>{};
  final libs = <String>{};
  final sigs = <String>{};
  for (final e in local) {
    if (e is! Map<String, dynamic>) continue;
    try {
      final p = ExtPidPack.fromJson(e);
      ids.add(p.id);
      if (p.lib != null) libs.add(p.lib!);
      sigs.add(_packSignature(p));
    } catch (_) {
      final id = e['id'];
      if (id is String) ids.add(id);
    }
  }
  final added = <ExtPidPack>[];
  var blocked = 0;
  for (final j in incoming) {
    final ExtPidPack p;
    try {
      p = ExtPidPack.fromJson(j);
    } catch (_) {
      continue;
    }
    if (ids.contains(p.id) || (p.lib != null && libs.contains(p.lib)) || sigs.contains(_packSignature(p))) {
      continue;
    }
    final before = p.pids.length;
    p.pids.removeWhere((x) => !_importable(x));
    blocked += before - p.pids.length;
    // ทั้งชุดเป็นคำสั่งที่นำเข้าไม่ได้: ไม่เพิ่มชุดว่าง
    if (p.pids.isEmpty && before > 0) continue;
    ids.add(p.id);
    if (p.lib != null) libs.add(p.lib!);
    sigs.add(_packSignature(p));
    added.add(p);
  }
  return PackMerge(added, blocked);
}

/// สำรอง/กู้คืนข้อมูลทั้งแอป: โรงรถ ประวัติสแกน ชุดค่าเฉพาะยี่ห้อ ค่าตั้งค่า ข้อมูลอู่+โลโก้ บันทึกการขับ ผลทดสอบรีแมพ
///
/// การกู้คืนเป็นการ "รวม" เสมอ: ไม่ลบข้อมูลในเครื่อง รายการที่มีอยู่แล้วไม่ถูกทับ (เติมเฉพาะช่องที่ว่าง)
/// และก่อนกู้คืนให้เรียก [safetyCopy] เก็บสำเนาข้อมูลเดิมไว้ก่อน
class BackupService {
  BackupService({
    required this.prefs,
    required this.garage,
    required this.history,
    required this.logs,
    required this.remaps,
    Directory? directory,
  }) : _directory = directory;

  final BackupPrefs prefs;
  final GarageStore garage;
  final HistoryStore history;
  final LogStore logs;
  final RemapStore remaps;
  Directory? _directory;

  /// สำเนาข้อมูลเดิมก่อนกู้คืน เก็บไว้กี่ไฟล์
  static const keepSafetyCopies = 3;

  /// ค่าที่ไม่ย้ายข้ามแอป/เครื่อง (โลโก้ย้ายเป็นไฟล์แยก, ค่าล้างข้อมูลครั้งเดียวของแต่ละแอป)
  static bool _skipPref(String key) => key == 'shop_logo' || key.startsWith('cleanup_');

  Future<Directory> _docs() async => _directory ??= await getApplicationDocumentsDirectory();

  /// รวบรวมข้อมูลทั้งหมดในเครื่องตอนนี้
  Future<BackupData> collect({required String appVersion, DateTime? now}) async {
    final all = prefs.readAll();
    String? logoName;
    Uint8List? logoBytes;
    final logoPath = all['shop_logo'];
    if (logoPath is String && logoPath.isNotEmpty) {
      try {
        final f = File(logoPath);
        if (await f.exists()) {
          logoBytes = await f.readAsBytes();
          logoName = f.uri.pathSegments.last;
        }
      } catch (_) {
        logoBytes = null;
      }
    }
    return BackupData(
      created: now ?? DateTime.now(),
      appVersion: appVersion,
      prefs: {
        for (final e in all.entries)
          if (!_skipPref(e.key)) e.key: e.value,
      },
      vehicles: [for (final v in await garage.load()) v.toJson()],
      history: [for (final s in await history.load()) s.toJson()],
      driveLogs: await logs.exportAll(),
      remapRuns: await remaps.exportAll(),
      logoName: logoName,
      logoBytes: logoBytes,
    );
  }

  /// รวมข้อมูลจากไฟล์สำรองเข้ากับข้อมูลในเครื่อง
  Future<RestoreSummary> restore(BackupData b) async {
    // โรงรถ
    final incoming = <Vehicle>[];
    for (final j in b.vehicles) {
      try {
        incoming.add(Vehicle.fromJson(j));
      } catch (_) {
        // รถคันที่ข้อมูลเสีย ข้าม
      }
    }
    var vehiclesAdded = 0;
    var vehiclesUpdated = 0;
    if (incoming.isNotEmpty) {
      final m = mergeVehicles(await garage.load(), incoming);
      if (m.added > 0 || m.updated > 0) await garage.save(m.vehicles);
      vehiclesAdded = m.added;
      vehiclesUpdated = m.updated;
    }

    // ประวัติการสแกน
    final snaps = <VehicleSnapshot>[];
    for (final j in b.history) {
      try {
        snaps.add(VehicleSnapshot.fromJson(j));
      } catch (_) {
        // ข้ามรายการที่เสีย
      }
    }
    final historyAdded = snaps.isEmpty ? 0 : await history.merge(snaps);

    // ชุดค่าเฉพาะยี่ห้อ: เพิ่มเฉพาะชุดที่ยังไม่มี (ชุดที่มีอยู่แล้วไม่ทับ เพราะอาจแก้ไขหรือยืนยันไปแล้ว)
    var packsAdded = 0;
    var packItemsBlocked = 0;
    final incomingPacks = b.packs;
    if (incomingPacks.isNotEmpty) {
      final rawLocal = prefs.readAll()[BackupData.packsKey];
      final local = rawLocal == null ? <dynamic>[] : decodeJsonList(rawLocal);
      // ถ้าชุดในเครื่องอ่านไม่ออก ไม่แตะ (กันเขียนทับข้อมูลที่ยังกู้ด้วยมือได้)
      if (local != null) {
        final m = mergePacks(local, incomingPacks);
        if (m.added.isNotEmpty) {
          await prefs.write(BackupData.packsKey, jsonEncode([...local, for (final p in m.added) p.toJson()]));
        }
        packsAdded = m.added.length;
        packItemsBlocked = m.blocked;
      }
    }

    // ค่าตั้งค่า: ตั้งเฉพาะค่าที่เครื่องนี้ยังไม่ได้ตั้ง
    var settingsFilled = 0;
    for (final e in b.prefs.entries) {
      if (_skipPref(e.key) || e.key == BackupData.packsKey || prefs.has(e.key)) continue;
      await prefs.write(e.key, e.value);
      settingsFilled++;
    }

    // โลโก้อู่: ใส่เฉพาะเมื่อเครื่องนี้ยังไม่มีโลโก้
    final logoRestored = await _restoreLogo(b);

    // บันทึกการขับ และผลทดสอบรีแมพ: เพิ่มเฉพาะ id ที่ยังไม่มี
    var logsAdded = 0;
    for (final e in b.driveLogs.entries) {
      try {
        if (await logs.importRaw(e.key, e.value)) logsAdded++;
      } catch (_) {
        // ข้าม
      }
    }
    var remapAdded = 0;
    for (final e in b.remapRuns.entries) {
      try {
        if (await remaps.importRaw(e.key, e.value)) remapAdded++;
      } catch (_) {
        // ข้าม
      }
    }

    return RestoreSummary(
      vehiclesAdded: vehiclesAdded,
      vehiclesUpdated: vehiclesUpdated,
      historyAdded: historyAdded,
      packsAdded: packsAdded,
      packItemsBlocked: packItemsBlocked,
      logsAdded: logsAdded,
      remapAdded: remapAdded,
      settingsFilled: settingsFilled,
      logoRestored: logoRestored,
    );
  }

  Future<bool> _restoreLogo(BackupData b) async {
    final bytes = b.logoBytes;
    if (bytes == null || bytes.isEmpty) return false;
    try {
      final current = prefs.readAll()['shop_logo'];
      if (current is String && current.isNotEmpty && await File(current).exists()) return false;
      final name = (b.logoName ?? '').toLowerCase();
      final dot = name.lastIndexOf('.');
      final ext = dot >= 0 && RegExp(r'^\.[a-z0-9]{1,4}$').hasMatch(name.substring(dot)) ? name.substring(dot) : '.png';
      final f = File('${(await _docs()).path}/shop_logo_${DateTime.now().millisecondsSinceEpoch}$ext');
      await f.writeAsBytes(bytes, flush: true);
      await prefs.write('shop_logo', f.path);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// เก็บสำเนาข้อมูลตอนนี้ไว้ในแอป (โฟลเดอร์ backups) ก่อนกู้คืน เก็บไว้ [keepSafetyCopies] ไฟล์ล่าสุด
  /// คืน null ถ้าเก็บไม่สำเร็จ
  Future<File?> safetyCopy({required String appVersion, DateTime? now}) async {
    try {
      final t = now ?? DateTime.now();
      final data = await collect(appVersion: appVersion, now: t);
      final d = Directory('${(await _docs()).path}/backups');
      if (!await d.exists()) await d.create(recursive: true);
      final f = File('${d.path}/before_restore_${t.millisecondsSinceEpoch}.json');
      await f.writeAsBytes(data.encode(), flush: true);
      final files = <File>[];
      await for (final e in d.list()) {
        if (e is File && e.uri.pathSegments.last.startsWith('before_restore_') && e.path.endsWith('.json')) {
          files.add(e);
        }
      }
      files.sort((a, b) => b.path.compareTo(a.path));
      for (final old in files.skip(keepSafetyCopies)) {
        try {
          await old.delete();
        } catch (_) {}
      }
      return f;
    } catch (_) {
      return null;
    }
  }
}
