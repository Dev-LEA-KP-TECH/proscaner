import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// การเชื่อมต่อหนึ่งครั้งที่บันทึกไว้
class CommLogSession {
  const CommLogSession({required this.file, required this.start, required this.bytes, required this.title});

  final File file;
  final DateTime start;
  final int bytes;

  /// ชื่อตัวสแกน/การเชื่อมต่อ เช่น "Bluetooth OBDII"
  final String title;

  String get name => file.uri.pathSegments.last;
}

class _Session {
  _Session(this.name, this.header);

  final String name;

  /// หัวไฟล์ (เขียนก่อนบรรทัดแรก และเขียนใหม่ถ้าไฟล์ถูกลบระหว่างบันทึก)
  final String header;
  final buf = StringBuffer();
}

/// บันทึกการสื่อสารระหว่างแอปกับตัวสแกน: ทุกคำสั่งที่ส่ง ทุกคำตอบ พร้อมเวลา และข้อผิดพลาด
///
/// - เก็บเป็นไฟล์ข้อความ 1 ไฟล์ต่อการเชื่อมต่อ 1 ครั้ง ในโฟลเดอร์ comm_logs ของแอป
///   (เก็บไว้ไม่เกิน [maxSessions] ไฟล์ล่าสุด และรวมกันไม่เกิน [maxTotalBytes])
/// - ใช้ส่งให้ผู้พัฒนาเวลาลองกับรถจริงแล้วเจอปัญหา (ค่าเพี้ยน เชื่อมต่อไม่ได้ ฯลฯ)
/// - [start] [add] [end] ไม่ต้องรอ (ไม่มีบรรทัดหายระหว่างรอเปิดไฟล์) ส่วนการเขียนไฟล์ทำเป็นช่วงๆ ทุก [flushEvery]
///   ตามคิว เพื่อไม่ให้แอปช้าตอนอ่านค่าสด
/// - เขียนไฟล์ไม่ได้ (เช่น ที่เก็บเต็ม) จะข้ามไปเงียบๆ ไม่ทำให้การเชื่อมต่อล้ม
class CommLog {
  CommLog({
    Directory? directory,
    this.maxSessions = 30,
    this.maxTotalBytes = 50 * 1024 * 1024,
    this.flushEvery = const Duration(seconds: 1),
    DateTime Function()? clock,
  })  : _directory = directory,
        _clock = clock ?? DateTime.now;

  /// ค่าตั้งค่าเปิด/ปิดการบันทึก (ไม่มีค่า = เปิด)
  static const prefKey = 'comm_log_on';

  final int maxSessions;
  final int maxTotalBytes;
  final Duration flushEvery;
  final DateTime Function() _clock;
  Directory? _directory;

  _Session? _session;
  Timer? _timer;

  /// งานเขียน/ลบไฟล์ทั้งหมดทำตามคิวนี้ทีละงาน (งานในคิวจัดการข้อผิดพลาดเอง คิวจึงไม่ค้างเพราะ error)
  Future<void> _io = Future<void>.value();

  /// กำลังบันทึกการเชื่อมต่อครั้งหนึ่งอยู่
  bool get active => _session != null;

  /// ชื่อไฟล์ของการเชื่อมต่อที่กำลังบันทึก
  String? get currentName => _session?.name;

  Future<Directory> _dir() async {
    _directory ??= await getApplicationDocumentsDirectory();
    final d = Directory('${_directory!.path}/comm_logs');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// เริ่มบันทึกการเชื่อมต่อครั้งใหม่ (จบครั้งก่อนให้ก่อนถ้ายังค้างอยู่)
  void start(String title, {Map<String, String> info = const {}}) {
    end();
    final now = _clock();
    final h = StringBuffer()
      ..writeln('# ProScaner communication log')
      ..writeln('# title=${_oneLine(title)}')
      ..writeln('# start=${now.toIso8601String()}');
    info.forEach((k, v) => h.writeln('# ${_oneLine(k)}=${_oneLine(v)}'));
    final s = _Session('comm_${_stamp(now)}_${now.millisecond.toString().padLeft(3, '0')}.txt', h.toString());
    _session = s;
    _write(s, create: true);
    _io = _io.then((_) => _prune(keep: s.name));
  }

  /// เพิ่มหนึ่งบรรทัด (ไม่ทำอะไรถ้าไม่ได้บันทึกอยู่)
  void add(String line) {
    final s = _session;
    if (s == null) return;
    s.buf
      ..write(_time(_clock()))
      ..write('  ')
      ..writeln(_oneLine(line, sep: ' | '));
    _timer ??= Timer(flushEvery, () {
      _timer = null;
      final cur = _session;
      if (cur != null) _write(cur);
    });
  }

  /// จบการบันทึกครั้งนี้ (ไม่ทำอะไรถ้าไม่ได้บันทึกอยู่)
  void end([String? note]) {
    final s = _session;
    if (s == null) return;
    if (note != null) add('== $note');
    _session = null;
    _timer?.cancel();
    _timer = null;
    _write(s);
  }

  /// เขียนบรรทัดที่ค้างทั้งหมดลงไฟล์แล้วรอจนเสร็จ
  Future<void> flush() {
    final s = _session;
    if (s != null) _write(s);
    return _io;
  }

  void _write(_Session s, {bool create = false}) {
    if (s.buf.isEmpty && !create) return;
    final text = s.buf.toString();
    s.buf.clear();
    _io = _io.then((_) async {
      try {
        final d = await _dir();
        final f = File('${d.path}/${s.name}');
        // ไฟล์ยังไม่มี (เพิ่งเริ่ม หรือถูกลบระหว่างบันทึก): ใส่หัวไฟล์ก่อน
        final head = await f.exists() ? '' : s.header;
        await f.writeAsString('$head$text', mode: FileMode.append, flush: true);
      } catch (_) {
        // เขียนไม่ได้ ข้ามไป (บันทึกนี้ใช้ช่วยแก้ปัญหาเท่านั้น)
      }
    });
  }

  /// รายการบันทึก ใหม่สุดก่อน
  Future<List<CommLogSession>> sessions() async {
    await flush();
    try {
      return await _list();
    } catch (_) {
      return const [];
    }
  }

  Future<List<CommLogSession>> _list() async {
    final d = await _dir();
    final out = <CommLogSession>[];
    await for (final e in d.list()) {
      if (e is! File || !e.path.endsWith('.txt')) continue;
      try {
        final stat = await e.stat();
        var title = '';
        DateTime? start;
        for (final l in await _head(e)) {
          if (l.startsWith('# title=')) title = l.substring(8).trim();
          if (l.startsWith('# start=')) start = DateTime.tryParse(l.substring(8).trim());
        }
        out.add(CommLogSession(file: e, start: start ?? stat.modified, bytes: stat.size, title: title));
      } catch (_) {
        // ไฟล์อ่านไม่ได้ ข้าม
      }
    }
    out.sort((a, b) => b.start.compareTo(a.start));
    return out;
  }

  static Future<List<String>> _head(File f) async {
    final raf = await f.open();
    try {
      final bytes = await raf.read(2048);
      return utf8.decode(bytes, allowMalformed: true).split('\n');
    } finally {
      await raf.close();
    }
  }

  /// ข้อความทั้งหมดของบันทึกหนึ่งครั้ง
  Future<String> read(CommLogSession s) async {
    await flush();
    return utf8.decode(await s.file.readAsBytes(), allowMalformed: true);
  }

  /// ลบบันทึกทั้งหมด (ถ้ากำลังบันทึกอยู่ จะเริ่มไฟล์ใหม่ต่อจากบรรทัดถัดไป)
  Future<void> deleteAll() {
    final cur = _session;
    if (cur != null) _write(cur);
    final done = _io.then((_) async {
      try {
        final d = await _dir();
        await for (final e in d.list()) {
          if (e is File) {
            try {
              await e.delete();
            } catch (_) {}
          }
        }
      } catch (_) {}
    });
    _io = done;
    return done;
  }

  /// ลบบันทึกเก่า (ใหม่สุดเก็บไว้ก่อน) เมื่อเกิน [maxSessions] ไฟล์ หรือรวมกันเกิน [maxTotalBytes]
  Future<void> _prune({String? keep}) async {
    try {
      final all = await _list();
      var total = 0;
      for (var i = 0; i < all.length; i++) {
        final s = all[i];
        total += s.bytes;
        if (s.name == keep || (i < maxSessions && total <= maxTotalBytes)) continue;
        try {
          await s.file.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    final s = _session;
    if (s != null) _write(s);
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  static String _stamp(DateTime t) =>
      '${t.year}${_two(t.month)}${_two(t.day)}_${_two(t.hour)}${_two(t.minute)}${_two(t.second)}';

  static String _time(DateTime t) =>
      '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}.${t.millisecond.toString().padLeft(3, '0')}';

  static String _oneLine(String s, {String sep = ' '}) => s.replaceAll(RegExp(r'[\r\n]+'), sep);
}
