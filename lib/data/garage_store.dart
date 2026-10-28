import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../core/analysis/vin.dart';

/// บันทึกเลขไมล์หนึ่งครั้ง
class OdoEntry {
  const OdoEntry({required this.time, this.ecuKm, this.dashKm, this.engineHours, this.ignitions});

  final DateTime time;
  final double? ecuKm;
  final double? dashKm;
  final double? engineHours;
  final int? ignitions;

  double? get km => dashKm ?? ecuKm;

  Map<String, dynamic> toJson() => {
        't': time.toIso8601String(),
        if (ecuKm != null) 'e': ecuKm,
        if (dashKm != null) 'd': dashKm,
        if (engineHours != null) 'h': engineHours,
        if (ignitions != null) 'i': ignitions,
      };

  factory OdoEntry.fromJson(Map<String, dynamic> j) => OdoEntry(
        time: DateTime.parse(j['t'] as String),
        ecuKm: (j['e'] as num?)?.toDouble(),
        dashKm: (j['d'] as num?)?.toDouble(),
        engineHours: (j['h'] as num?)?.toDouble(),
        ignitions: j['i'] as int?,
      );
}

/// รายการบำรุงรักษาตามระยะ
class MaintItem {
  MaintItem({required this.name, this.intervalKm, this.intervalMonths, this.lastKm, this.lastDate});

  String name;
  int? intervalKm;
  int? intervalMonths;
  double? lastKm;
  DateTime? lastDate;

  /// ระยะ (กม.) ที่เหลือก่อนถึงกำหนด ติดลบ = เลยกำหนด
  double? kmLeft(double? currentKm) {
    if (intervalKm == null || lastKm == null || currentKm == null) return null;
    return lastKm! + intervalKm! - currentKm;
  }

  /// จำนวนวันที่เหลือก่อนถึงกำหนด ติดลบ = เลยกำหนด
  int? daysLeft(DateTime now) {
    if (intervalMonths == null || lastDate == null) return null;
    final due = DateTime(lastDate!.year, lastDate!.month + intervalMonths!, lastDate!.day);
    return due.difference(now).inDays;
  }

  bool isDue(double? currentKm, DateTime now) {
    final k = kmLeft(currentKm);
    final d = daysLeft(now);
    return (k != null && k <= 500) || (d != null && d <= 14);
  }

  Map<String, dynamic> toJson() => {
        'n': name,
        if (intervalKm != null) 'ik': intervalKm,
        if (intervalMonths != null) 'im': intervalMonths,
        if (lastKm != null) 'lk': lastKm,
        if (lastDate != null) 'ld': lastDate!.toIso8601String(),
      };

  factory MaintItem.fromJson(Map<String, dynamic> j) => MaintItem(
        name: j['n'] as String,
        intervalKm: j['ik'] as int?,
        intervalMonths: j['im'] as int?,
        lastKm: (j['lk'] as num?)?.toDouble(),
        lastDate: j['ld'] == null ? null : DateTime.parse(j['ld'] as String),
      );

  static List<MaintItem> defaults() => [
        MaintItem(name: 'น้ำมันเครื่อง + กรองน้ำมันเครื่อง', intervalKm: 10000, intervalMonths: 6),
        MaintItem(name: 'กรองอากาศ', intervalKm: 20000, intervalMonths: 12),
        MaintItem(name: 'กรองเชื้อเพลิง / กรองโซล่า', intervalKm: 40000, intervalMonths: 24),
        MaintItem(name: 'น้ำมันเบรก', intervalMonths: 24),
        MaintItem(name: 'น้ำมันเกียร์', intervalKm: 40000, intervalMonths: 24),
        MaintItem(name: 'น้ำยาหล่อเย็น', intervalKm: 40000, intervalMonths: 24),
        MaintItem(name: 'หัวเทียน (เบนซิน)', intervalKm: 100000),
      ];
}

/// รหัสหัวฉีดที่บันทึกไว้ (สแกน QR หรือพิมพ์เอง) — ไม่ได้เขียนลงกล่อง
class InjectorCode {
  const InjectorCode({required this.cylinder, required this.code, required this.time, this.note});

  final int cylinder;
  final String code;
  final DateTime time;
  final String? note;

  Map<String, dynamic> toJson() =>
      {'c': cylinder, 'v': code, 't': time.toIso8601String(), if (note != null) 'n': note};

  factory InjectorCode.fromJson(Map<String, dynamic> j) => InjectorCode(
        cylinder: j['c'] as int,
        code: j['v'] as String,
        time: DateTime.parse(j['t'] as String),
        note: j['n'] as String?,
      );
}

/// รถหนึ่งคันในโรงรถ
class Vehicle {
  Vehicle({
    required this.id,
    this.vin,
    this.nickname = '',
    this.plate,
    this.customer,
    this.phone,
    this.make,
    this.model,
    this.year,
    this.fuel,
    this.idSource,
    List<OdoEntry>? odometer,
    List<MaintItem>? maintenance,
    List<InjectorCode>? injectors,
    DateTime? created,
  })  : odometer = odometer ?? [],
        maintenance = maintenance ?? MaintItem.defaults(),
        injectors = injectors ?? [],
        created = created ?? DateTime.now();

  final String id;
  String? vin;
  String nickname;
  String? plate;
  String? customer;
  String? phone;

  /// ยี่ห้อ รุ่น ปี เชื้อเพลิง (ระบุอัตโนมัติจาก VIN หรือผู้ใช้เลือก)
  String? make;
  String? model;
  int? year;

  /// 'ดีเซล' / 'เบนซิน' / 'ไฟฟ้า' / 'ไฮบริด'
  String? fuel;

  /// ที่มาของยี่ห้อ/รุ่น: 'vin' = ถอดจาก VIN, 'learned' = จำจากรถรุ่นเดียวกันในโรงรถ, 'manual' = ผู้ใช้ระบุ
  String? idSource;

  final List<OdoEntry> odometer;
  final List<MaintItem> maintenance;
  final List<InjectorCode> injectors;
  final DateTime created;

  /// ชื่อรถแบบเต็ม เช่น "Toyota Hilux Revo" (null ถ้ายังไม่รู้ยี่ห้อและรุ่น)
  String? get displayName {
    final parts = [make, model].whereType<String>().where((s) => s.trim().isNotEmpty).toList();
    return parts.isEmpty ? null : parts.join(' ');
  }

  /// ยังไม่รู้รุ่นรถ ควรให้ผู้ใช้เลือก
  bool get needsModel => model == null || model!.trim().isEmpty;

  String get title {
    if (nickname.isNotEmpty) return nickname;
    final dn = displayName;
    if (dn != null) return dn;
    if (plate != null && plate!.isNotEmpty) return plate!;
    if (vin != null) {
      final info = decodeVin17(vin!);
      if (info.valid && info.maker != null) return info.maker!.replaceAll(RegExp(r'\s*\(.*\)'), '');
      return vin!;
    }
    return 'รถไม่ระบุชื่อ';
  }

  /// เลขไมล์ล่าสุดที่รู้ (หน้าปัดก่อน ถ้าไม่มีใช้ของกล่อง)
  double? get latestKm {
    for (final e in odometer.reversed) {
      if (e.km != null) return e.km;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'vin': vin,
        'nick': nickname,
        'plate': plate,
        'cust': customer,
        'phone': phone,
        if (make != null) 'mk': make,
        if (model != null) 'md': model,
        if (year != null) 'yr': year,
        if (fuel != null) 'fu': fuel,
        if (idSource != null) 'src': idSource,
        'odo': odometer.map((e) => e.toJson()).toList(),
        'maint': maintenance.map((e) => e.toJson()).toList(),
        'inj': injectors.map((e) => e.toJson()).toList(),
        'created': created.toIso8601String(),
      };

  factory Vehicle.fromJson(Map<String, dynamic> j) => Vehicle(
        id: j['id'] as String,
        vin: j['vin'] as String?,
        nickname: j['nick'] as String? ?? '',
        plate: j['plate'] as String?,
        customer: j['cust'] as String?,
        phone: j['phone'] as String?,
        make: j['mk'] as String?,
        model: j['md'] as String?,
        year: (j['yr'] as num?)?.toInt(),
        fuel: j['fu'] as String?,
        idSource: j['src'] as String?,
        odometer: (j['odo'] as List<dynamic>? ?? const [])
            .map((e) => OdoEntry.fromJson(e as Map<String, dynamic>))
            .toList(),
        maintenance: (j['maint'] as List<dynamic>?)
            ?.map((e) => MaintItem.fromJson(e as Map<String, dynamic>))
            .toList(),
        injectors: (j['inj'] as List<dynamic>? ?? const [])
            .map((e) => InjectorCode.fromJson(e as Map<String, dynamic>))
            .toList(),
        created: j['created'] == null ? null : DateTime.parse(j['created'] as String),
      );
}

/// เก็บรถทั้งหมดเป็นไฟล์ JSON ไฟล์เดียว
///
/// กันข้อมูลลูกค้าหาย:
/// - อ่าน/เขียนไฟล์ทีละงานตามคิว ไม่ให้สองงานเขียนไฟล์ชั่วคราวเดียวกันพร้อมกัน
/// - เขียนไฟล์ชั่วคราวแล้วเปลี่ยนชื่อ และเก็บไฟล์ดีล่าสุดไว้เป็น .bak
/// - ถ้าไฟล์หลักเสีย เก็บไฟล์เสียไว้ (.bad-เวลา) แล้วกู้จาก .bak ไม่คืนรายการว่างไปให้บันทึกทับ
/// - รถที่ข้อมูลเสียทีละคันจะถูกข้าม คันอื่นยังอยู่
class GarageStore {
  GarageStore({Directory? directory}) : _directory = directory;

  Directory? _directory;
  Future<void> _queue = Future<void>.value();

  Future<File> _file() async {
    _directory ??= await getApplicationDocumentsDirectory();
    return File('${_directory!.path}/garage.json');
  }

  Future<T> _serial<T>(Future<T> Function() body) {
    final next = _queue.then((_) => body());
    _queue = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  Future<List<Vehicle>> load() => _serial(() async {
        final f = await _file();
        final bak = File('${f.path}.bak');
        if (!await f.exists()) return await _read(bak) ?? [];
        final main = await _read(f);
        if (main != null) return main;
        await keepBrokenFile(f);
        final backup = await _read(bak);
        if (backup != null) {
          try {
            await bak.copy(f.path);
          } catch (_) {}
        }
        return backup ?? [];
      });

  /// คืน null ถ้าไม่มีไฟล์หรืออ่านไม่ออกทั้งไฟล์
  static Future<List<Vehicle>?> _read(File f) async {
    try {
      if (!await f.exists()) return null;
      final list = jsonDecode(await f.readAsString()) as List<dynamic>;
      final out = <Vehicle>[];
      for (final e in list) {
        try {
          out.add(Vehicle.fromJson(e as Map<String, dynamic>));
        } catch (_) {
          // ข้ามรถคันที่ข้อมูลเสีย
        }
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  Future<void> save(List<Vehicle> vehicles) {
    // แปลงเป็น JSON ตอนเรียก (ข้อมูล ณ ตอนนั้น) แล้วค่อยเขียนตามคิว
    final json = jsonEncode(vehicles.map((v) => v.toJson()).toList());
    return _serial(() async {
      final f = await _file();
      await writeWithBackup(f, json, isValid: (file) async => await _read(file) != null);
    });
  }
}

/// เก็บไฟล์ที่อ่านไม่ออกไว้ข้างๆ (ไม่ลบ) เผื่อกู้ข้อมูลด้วยมือ
Future<void> keepBrokenFile(File f) async {
  try {
    await f.copy('${f.path}.bad-${DateTime.now().millisecondsSinceEpoch}');
  } catch (_) {}
}

/// เขียนไฟล์แบบปลอดภัย: เขียนไฟล์ชั่วคราว, เก็บไฟล์เดิมที่ยังดีเป็น .bak, แล้วเปลี่ยนชื่อทับ
Future<void> writeWithBackup(File f, String content, {required Future<bool> Function(File) isValid}) async {
  final tmp = File('${f.path}.tmp');
  await tmp.writeAsString(content, flush: true);
  if (await f.exists() && await isValid(f)) {
    try {
      await f.copy('${f.path}.bak');
    } catch (_) {}
  }
  await tmp.rename(f.path);
}

/// สำหรับเทสต์และภาพตัวอย่าง: เก็บในหน่วยความจำ
class MemoryGarageStore extends GarageStore {
  List<Vehicle> _items = [];

  @override
  Future<List<Vehicle>> load() async => [for (final v in _items) Vehicle.fromJson(v.toJson())];

  @override
  Future<void> save(List<Vehicle> vehicles) async {
    _items = [for (final v in vehicles) Vehicle.fromJson(v.toJson())];
  }
}
