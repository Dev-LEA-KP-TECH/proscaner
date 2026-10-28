import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../core/obd/pids.dart';

/// การบันทึกการขับหนึ่งครั้ง
class DriveLog {
  DriveLog({
    required this.id,
    required this.name,
    required this.start,
    required this.pids,
    required this.times,
    required this.rows,
    this.vin,
  });

  final String id;
  String name;
  final DateTime start;
  final String? vin;

  /// PID ที่บันทึก ตามลำดับคอลัมน์
  final List<int> pids;

  /// เวลาของแต่ละแถว (วินาทีนับจากเริ่ม)
  final List<double> times;

  /// ค่าของแต่ละแถว ความยาวเท่ากับ [pids]; null = ไม่มีค่าในแถวนั้น
  final List<List<double?>> rows;

  double get durationS => times.isEmpty ? 0 : times.last;

  /// ค่าทั้งหมดของ PID หนึ่งตัว คู่กับเวลา
  List<(double, double)> series(int pid) {
    final c = pids.indexOf(pid);
    if (c < 0) return const [];
    return [
      for (var i = 0; i < rows.length; i++)
        if (rows[i][c] != null) (times[i], rows[i][c]!),
    ];
  }

  String toCsv() {
    final b = StringBuffer()
      ..writeln('# ProScaner drive log')
      ..writeln('# name=${name.replaceAll('\n', ' ')}')
      ..writeln('# start=${start.toIso8601String()}')
      ..writeln('# vin=${vin ?? ''}')
      ..writeln([
        'time_s',
        for (final p in pids) '${pidTable[p]?.code ?? p.toRadixString(16)} ${pidTable[p]?.nameTh ?? ''} (${pidTable[p]?.unit ?? ''})'
            .replaceAll(',', ' '),
      ].join(','));
    for (var i = 0; i < rows.length; i++) {
      b.writeln([
        times[i].toStringAsFixed(2),
        for (final v in rows[i]) v == null ? '' : v.toStringAsFixed(3),
      ].join(','));
    }
    return b.toString();
  }

  static DriveLog fromCsv(String id, String csv) {
    var name = id;
    DateTime start = DateTime.fromMillisecondsSinceEpoch(0);
    String? vin;
    final pids = <int>[];
    final times = <double>[];
    final rows = <List<double?>>[];
    for (final line in csv.replaceFirst('\uFEFF', '').split(RegExp(r'\r?\n'))) {
      if (line.isEmpty) continue;
      if (line.startsWith('# name=')) {
        name = line.substring(7);
      } else if (line.startsWith('# start=')) {
        start = DateTime.tryParse(line.substring(8)) ?? start;
      } else if (line.startsWith('# vin=')) {
        final v = line.substring(6).trim();
        vin = v.isEmpty ? null : v;
      } else if (line.startsWith('#')) {
        continue;
      } else if (line.startsWith('time_s')) {
        for (final h in line.split(',').skip(1)) {
          final code = h.trim().split(' ').first;
          pids.add(int.parse(code.length == 4 ? code.substring(2) : code, radix: 16));
        }
      } else {
        final cells = line.split(',');
        times.add(double.tryParse(cells[0]) ?? 0);
        rows.add([for (var i = 1; i <= pids.length; i++) i < cells.length ? double.tryParse(cells[i]) : null]);
      }
    }
    return DriveLog(id: id, name: name, start: start, pids: pids, times: times, rows: rows, vin: vin);
  }
}

/// เก็บไฟล์ CSV ในโฟลเดอร์ logs ของแอป
class LogStore {
  LogStore({Directory? directory}) : _directory = directory;

  Directory? _directory;

  Future<Directory> _dir() async {
    _directory ??= await getApplicationDocumentsDirectory();
    final d = Directory('${_directory!.path}/logs');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<File> fileFor(String id) async => File('${(await _dir()).path}/$id.csv');

  Future<List<DriveLog>> list() async {
    final d = await _dir();
    final out = <DriveLog>[];
    await for (final f in d.list()) {
      if (f is File && f.path.endsWith('.csv')) {
        final id = f.uri.pathSegments.last.replaceAll('.csv', '');
        try {
          out.add(DriveLog.fromCsv(id, await f.readAsString()));
        } catch (_) {
          // ไฟล์เสีย ข้ามไป
        }
      }
    }
    out.sort((a, b) => b.start.compareTo(a.start));
    return out;
  }

  Future<void> save(DriveLog log) async {
    final f = await fileFor(log.id);
    await f.writeAsString(log.toCsv());
  }

  Future<void> delete(String id) async {
    final f = await fileFor(id);
    if (await f.exists()) await f.delete();
  }

  /// ไฟล์บันทึกทั้งหมดเป็นข้อความ (ใช้สำรองข้อมูล) id -> CSV
  Future<Map<String, String>> exportAll() async {
    final d = await _dir();
    final out = <String, String>{};
    await for (final f in d.list()) {
      if (f is File && f.path.endsWith('.csv')) {
        try {
          out[f.uri.pathSegments.last.replaceAll('.csv', '')] = await f.readAsString();
        } catch (_) {
          // อ่านไม่ได้ ข้าม
        }
      }
    }
    return out;
  }

  /// เพิ่มบันทึกจากไฟล์สำรอง ถ้ายังไม่มี id นี้ในเครื่อง คืน true ถ้าเพิ่ม
  Future<bool> importRaw(String id, String csv) async {
    if (!safeFileId(id) || !_parses(id, csv)) return false;
    final f = await fileFor(id);
    if (await f.exists()) return false;
    await f.writeAsString(csv, flush: true);
    return true;
  }

  static bool _parses(String id, String csv) {
    try {
      DriveLog.fromCsv(id, csv);
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// ชื่อไฟล์ที่มาจากไฟล์สำรองต้องเป็นตัวอักษร/ตัวเลข/ขีดเท่านั้น (กันชื่อไฟล์แปลกๆ เช่น ../)
bool safeFileId(String id) => RegExp(r'^[A-Za-z0-9_\-]{1,100}$').hasMatch(id);

class MemoryLogStore extends LogStore {
  final _items = <String, String>{};

  @override
  Future<List<DriveLog>> list() async {
    final out = [for (final e in _items.entries) DriveLog.fromCsv(e.key, e.value)];
    out.sort((a, b) => b.start.compareTo(a.start));
    return out;
  }

  @override
  Future<void> save(DriveLog log) async => _items[log.id] = log.toCsv();

  @override
  Future<void> delete(String id) async => _items.remove(id);

  @override
  Future<Map<String, String>> exportAll() async => Map.of(_items);

  @override
  Future<bool> importRaw(String id, String csv) async {
    if (!safeFileId(id) || _items.containsKey(id) || !LogStore._parses(id, csv)) return false;
    _items[id] = csv;
    return true;
  }
}
