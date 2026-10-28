import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../core/diagnosis/diagnosis.dart';
import 'garage_store.dart' show keepBrokenFile, writeWithBackup;

/// ประวัติการสแกน เก็บเป็นไฟล์ JSON ในเครื่อง (สูงสุด [maxEntries] รายการ)
///
/// MVP ใช้ไฟล์ JSON เพื่อลด dependency; เฟส 2 ย้ายไป SQLite (drift)
/// เมื่อต้องค้นตามลูกค้า/VIN และเก็บ log การขับ
///
/// กันประวัติหาย: เขียนทีละงานตามคิว เขียนไฟล์ชั่วคราวแล้วเปลี่ยนชื่อ เก็บ .bak
/// และถ้าไฟล์เสียจะเก็บไฟล์เสียไว้แล้วกู้จาก .bak (เหมือน GarageStore)
class HistoryStore {
  HistoryStore({Directory? directory}) : _directory = directory;

  static const maxEntries = 100;

  Directory? _directory;
  Future<void> _queue = Future<void>.value();

  Future<File> _file() async {
    _directory ??= await getApplicationDocumentsDirectory();
    return File('${_directory!.path}/scan_history.json');
  }

  Future<T> _serial<T>(Future<T> Function() body) {
    final next = _queue.then((_) => body());
    _queue = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  Future<List<VehicleSnapshot>> load() => _serial(_loadNow);

  Future<List<VehicleSnapshot>> _loadNow() async {
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
  }

  /// คืน null ถ้าไม่มีไฟล์หรืออ่านไม่ออกทั้งไฟล์ (รายการที่เสียทีละรายการจะถูกข้าม)
  static Future<List<VehicleSnapshot>?> _read(File f) async {
    try {
      if (!await f.exists()) return null;
      final list = jsonDecode(await f.readAsString()) as List<dynamic>;
      final out = <VehicleSnapshot>[];
      for (final e in list) {
        try {
          out.add(VehicleSnapshot.fromJson(e as Map<String, dynamic>));
        } catch (_) {
          // ข้ามรายการที่เสีย
        }
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(List<VehicleSnapshot> items) async {
    final f = await _file();
    await writeWithBackup(f, jsonEncode(items.map((e) => e.toJson()).toList()),
        isValid: (file) async => await _read(file) != null);
  }

  Future<void> add(VehicleSnapshot s) => _serial(() async {
        final all = await _loadNow();
        all.insert(0, s);
        await _write(all.take(maxEntries).toList());
      });

  /// ลบรายการที่ตรงเงื่อนไข คืนจำนวนที่ลบ (ใช้ล้างผลจากโหมดทดลองของแอปรุ่นก่อน)
  Future<int> removeWhere(bool Function(VehicleSnapshot s) test) => _serial(() async {
        final all = await _loadNow();
        final before = all.length;
        all.removeWhere(test);
        if (all.length != before) await _write(all);
        return before - all.length;
      });

  /// รวมประวัติจากไฟล์สำรอง: เพิ่มเฉพาะรายการที่ยังไม่มี (เวลาและ VIN ตรงกัน = รายการเดียวกัน)
  /// เรียงใหม่ตามเวลา เก็บไม่เกิน [maxEntries] รายการ คืนจำนวนรายการที่เพิ่มและยังอยู่ในประวัติ
  Future<int> merge(List<VehicleSnapshot> incoming) => _serial(() async {
        final all = await _loadNow();
        final mine = {for (final s in all) _identity(s)};
        final seen = {...mine};
        var added = 0;
        for (final s in incoming) {
          if (seen.add(_identity(s))) {
            all.add(s);
            added++;
          }
        }
        if (added == 0) return 0;
        all.sort((a, b) => b.time.compareTo(a.time));
        final kept = all.take(maxEntries).toList();
        final survived = kept.where((s) => !mine.contains(_identity(s))).length;
        if (survived == 0) return 0;
        await _write(kept);
        return survived;
      });

  static String _identity(VehicleSnapshot s) => '${s.time.toIso8601String()}|${s.vin ?? ''}';

  /// ล้างประวัติทั้งหมด (ผู้ใช้สั่ง) รวมไฟล์สำรอง ไม่เช่นนั้นประวัติจะถูกกู้กลับมา
  Future<void> clear() => _serial(() async {
        final f = await _file();
        for (final x in [f, File('${f.path}.bak')]) {
          if (await x.exists()) await x.delete();
        }
      });
}
