import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../core/analysis/remap_test.dart';
import 'log_store.dart' show safeFileId;

/// เก็บผลทดสอบรีแมพเป็นไฟล์ JSON (หนึ่งไฟล์ต่อหนึ่งรอบ) ในโฟลเดอร์ remap_runs ของแอป
class RemapStore {
  RemapStore({Directory? directory}) : _directory = directory;

  Directory? _directory;

  Future<Directory> _dir() async {
    _directory ??= await getApplicationDocumentsDirectory();
    final d = Directory('${_directory!.path}/remap_runs');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<File> fileFor(String id) async => File('${(await _dir()).path}/$id.json');

  Future<List<RemapRun>> list() async {
    final d = await _dir();
    final out = <RemapRun>[];
    await for (final f in d.list()) {
      if (f is File && f.path.endsWith('.json')) {
        try {
          out.add(RemapRun.decode(await f.readAsString()));
        } catch (_) {
          // ไฟล์เสีย ข้ามไป
        }
      }
    }
    out.sort((a, b) => b.start.compareTo(a.start));
    return out;
  }

  Future<void> save(RemapRun run) async {
    final f = await fileFor(run.id);
    // เขียนไฟล์ชั่วคราวให้เสร็จก่อนแล้วจึงแทนที่ ไฟล์เดิมไม่เสียถ้าแอปปิดระหว่างเขียน
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(run.encode(), flush: true);
    if (await f.exists()) await f.delete();
    await tmp.rename(f.path);
  }

  Future<void> delete(String id) async {
    final f = await fileFor(id);
    if (await f.exists()) await f.delete();
  }

  /// ผลทดสอบทั้งหมดเป็นข้อความ (ใช้สำรองข้อมูล) id -> JSON
  Future<Map<String, String>> exportAll() async {
    final d = await _dir();
    final out = <String, String>{};
    await for (final f in d.list()) {
      if (f is File && f.path.endsWith('.json')) {
        try {
          out[f.uri.pathSegments.last.replaceAll('.json', '')] = await f.readAsString();
        } catch (_) {
          // อ่านไม่ได้ ข้าม
        }
      }
    }
    return out;
  }

  /// เพิ่มผลทดสอบจากไฟล์สำรอง ถ้ายังไม่มี id นี้และข้อมูลอ่านได้ (id ในไฟล์ตรงกับชื่อ) คืน true ถ้าเพิ่ม
  Future<bool> importRaw(String id, String json) async {
    if (!safeFileId(id) || !_decodes(id, json)) return false;
    final f = await fileFor(id);
    if (await f.exists()) return false;
    await f.writeAsString(json, flush: true);
    return true;
  }

  static bool _decodes(String id, String json) {
    try {
      return RemapRun.decode(json).id == id;
    } catch (_) {
      return false;
    }
  }
}

/// ที่เก็บในหน่วยความจำ (ใช้ในเทสต์และภาพหน้าจอ)
class MemoryRemapStore extends RemapStore {
  final _items = <String, String>{};

  @override
  Future<List<RemapRun>> list() async {
    final out = [for (final s in _items.values) RemapRun.decode(s)];
    out.sort((a, b) => b.start.compareTo(a.start));
    return out;
  }

  @override
  Future<void> save(RemapRun run) async => _items[run.id] = run.encode();

  @override
  Future<void> delete(String id) async => _items.remove(id);

  @override
  Future<Map<String, String>> exportAll() async => Map.of(_items);

  @override
  Future<bool> importRaw(String id, String json) async {
    if (!safeFileId(id) || _items.containsKey(id) || !RemapStore._decodes(id, json)) return false;
    _items[id] = json;
    return true;
  }
}
