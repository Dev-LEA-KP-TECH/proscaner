import '../elm/elm327.dart';
import '../elm/response_parser.dart';
import 'dtc.dart';
import 'pids.dart';
import 'freeze_frame.dart';
import 'mode06.dart';
import 'mode09.dart';
import 'readiness.dart';

export 'freeze_frame.dart';
export 'mode06.dart';
export 'mode09.dart';
export 'readiness.dart';

/// คำสั่ง OBD-II ระดับสูง: อ่านโค้ด ลบโค้ด อ่านค่าสด อ่าน VIN
class ObdService {
  ObdService(this.elm);

  final Elm327 elm;

  Set<int> supported = {};

  /// อ่าน PID ที่รถรองรับจาก PID 00, 20, 40, … ตามลำดับ
  Future<Set<int>> loadSupportedPids() async {
    final result = <int>{};
    var base = 0x00;
    while (base <= 0xA0) {
      final r = await elm.query('01${_hex(base)}');
      var any = false;
      for (final m in r.messages) {
        if (m.data.length >= 6 && m.data[0] == 0x41 && m.data[1] == base) {
          result.addAll(decodeSupportMask(base, m.data.sublist(2)));
          any = true;
        }
      }
      if (!any || !result.contains(base + 0x20)) break;
      base += 0x20;
    }
    supported = result;
    return result;
  }

  bool supports(int pid) => supported.isEmpty || supported.contains(pid);

  /// ที่อยู่ของกล่องเครื่องยนต์: CAN 11 บิต 7E8, CAN 29 บิต 18DAF110, โปรโตคอลเก่า 10
  static const engineEcuIds = {'7E8', '18DAF110', '10'};

  /// เลือกคำตอบของกล่องเครื่องยนต์ก่อน (กล่องเกียร์อาจตอบมาก่อนและมีค่าคนละชุด)
  static EcuMessage? preferEngine(Iterable<EcuMessage> messages) {
    EcuMessage? first;
    for (final m in messages) {
      if (engineEcuIds.contains(m.ecu)) return m;
      first ??= m;
    }
    return first;
  }

  /// อ่านค่าดิบของ PID (ใช้คำตอบของกล่องเครื่องยนต์ก่อน ถ้าไม่มีใช้กล่องแรกที่ตอบ)
  Future<List<int>?> readPidRaw(int pid) async {
    final r = await elm.query('01${_hex(pid)}');
    final m = preferEngine(r.messages.where((m) => m.data.length >= 3 && m.data[0] == 0x41 && m.data[1] == pid));
    return m?.data.sublist(2);
  }

  Future<double?> readPid(int pid) async {
    final def = pidTable[pid];
    if (def == null) return null;
    final raw = await readPidRaw(pid);
    if (raw == null || raw.length < def.bytes) return null;
    return def.decode(raw);
  }

  /// ความยาวข้อมูลของ PID ที่ถามรวมกันในคำสั่งเดียวได้ (ต้องรู้ความยาวแน่นอนจึงแยกคำตอบออกจากกันได้)
  static const multiPidLengths = <int, int>{
    0x04: 1, 0x05: 1, 0x0B: 1, 0x0C: 2, 0x0D: 1, 0x0E: 1, 0x0F: 1, 0x10: 2, 0x11: 1,
    0x1F: 2, 0x22: 2, 0x23: 2, 0x2C: 1, 0x2D: 1, 0x2F: 1, 0x33: 1, 0x42: 2, 0x43: 2,
    0x45: 1, 0x46: 1, 0x49: 1, 0x4A: 1, 0x4C: 1, 0x59: 2, 0x5A: 1, 0x5C: 1, 0x5E: 2,
  };

  /// รถตอบคำสั่งหลาย PID ครบหรือไม่ (null = ยังไม่ได้ลอง)
  bool? multiPidOk;

  /// อ่านหลาย PID ในคำสั่งเดียว (สูงสุด 6 ตัว ตามมาตรฐาน ISO 15765-4 เฉพาะรถ CAN)
  /// คืนข้อมูลดิบของ PID ที่กล่องเครื่องยนต์ตอบ (PID ที่กล่องไม่รองรับจะไม่อยู่ในคำตอบ)
  Future<Map<int, List<int>>> readPidsMultiRaw(List<int> pids) async {
    if (pids.isEmpty || pids.length > 6) throw ArgumentError('ถามได้ 1–6 PID ต่อคำสั่ง');
    final r = await elm.query('01${pids.map(_hex).join()}');
    final msgs = r.messages.where((m) => m.data.length >= 3 && m.data[0] == 0x41).toList();
    final main = preferEngine(msgs);
    final out = <int, List<int>>{};
    if (main == null) return out;
    // บางกล่องแยกคำตอบเป็นหลายข้อความ ใช้ทุกข้อความของกล่องเดียวกัน
    for (final m in msgs.where((m) => m.ecu == main.ecu)) {
      final d = m.data;
      var i = 1;
      while (i < d.length) {
        final pid = d[i];
        final n = multiPidLengths[pid];
        if (n == null || !pids.contains(pid) || i + 1 + n > d.length) break;
        out[pid] = d.sublist(i + 1, i + 1 + n);
        i += 1 + n;
      }
    }
    return out;
  }

  /// อ่านหลาย PID ในคำสั่งเดียวแล้วแปลงเป็นค่า
  Future<Map<int, double>> readPidsMulti(List<int> pids) async {
    final raw = await readPidsMultiRaw(pids);
    return {
      for (final e in raw.entries)
        if (pidTable[e.key] case final def? when e.value.length >= def.bytes) e.key: def.decode(e.value),
    };
  }

  /// อ่านหลาย PID ตามลำดับ ข้ามตัวที่รถไม่รองรับ
  Future<Map<int, double>> readPids(Iterable<int> pids) async {
    final out = <int, double>{};
    for (final pid in pids) {
      if (!supports(pid) || !pidTable.containsKey(pid)) continue;
      final v = await readPid(pid);
      if (v != null) out[pid] = v;
    }
    return out;
  }

  /// สถานะไฟเตือน (PID 01) จากกล่องเครื่องยนต์ แต่ถือว่าไฟเตือนติดถ้ามีกล่องใดสั่งให้ติด
  Future<MonitorStatus?> readMonitorStatus() async {
    final r = await elm.query('01${_hex(Pid.monitorStatus)}');
    final all = r.messages
        .where((m) => m.data.length >= 3 && m.data[0] == 0x41 && m.data[1] == Pid.monitorStatus)
        .toList();
    final main = preferEngine(all);
    if (main == null) return null;
    final s = MonitorStatus.decode(main.data.sublist(2));
    if (s.milOn || !all.any((m) => m.data[2] & 0x80 != 0)) return s;
    return MonitorStatus(milOn: true, dtcCount: s.dtcCount, isDiesel: s.isDiesel);
  }

  Future<List<ReadinessMonitor>> readReadiness() async {
    final raw = await readPidRaw(Pid.monitorStatus);
    if (raw == null) return const [];
    return decodeReadiness(raw);
  }

  /// Mode 02: ค่าเซ็นเซอร์ที่ ECU เก็บไว้ตอนเกิดรหัสปัญหา (frame 0)
  /// คืน null ถ้าไม่มี freeze frame
  Future<FreezeFrame?> readFreezeFrame(Iterable<int> pids) async {
    final dtcRaw = await _mode02(0x02);
    if (dtcRaw == null || dtcRaw.length < 2) return null;
    if (dtcRaw[0] == 0 && dtcRaw[1] == 0) return null;
    final values = <int, double>{};
    for (final pid in pids) {
      final def = pidTable[pid];
      if (def == null || !def.live || !supports(pid)) continue;
      final raw = await _mode02(pid);
      if (raw != null && raw.length >= def.bytes) values[pid] = def.decode(raw);
    }
    return FreezeFrame(decodeDtcBytes(dtcRaw[0], dtcRaw[1]), values);
  }

  Future<List<int>?> _mode02(int pid) async {
    final r = await elm.query('02${_hex(pid)}00');
    for (final m in r.messages) {
      // คำตอบ: 42 <pid> <frame> <data…>
      if (m.data.length >= 4 && m.data[0] == 0x42 && m.data[1] == pid) {
        return m.data.sublist(3);
      }
    }
    return null;
  }

  /// อ่านรหัสปัญหา: NO DATA = ไม่มีรหัส ส่วน error อื่น (CAN ERROR, STOPPED, BUS ERROR ฯลฯ)
  /// = อ่านไม่สำเร็จ ต้องโยน error ห้ามตีความว่าไม่มีรหัส ไม่เช่นนั้นรายงานจะบอกว่ารถปกติ
  Future<List<Dtc>> readDtcs(DtcKind kind) async {
    final r = await elm.query(_hex(kind.mode), timeout: const Duration(seconds: 8));
    if (!r.isOk) {
      if (r.error == null || r.error == ElmError.noData) return const [];
      throw ElmException('อ่านรหัสปัญหา (${kind.labelTh}) ไม่สำเร็จ: ${r.errorText ?? r.error!.name}');
    }
    return parseDtcMessages(r.messages, kind, isCan: elm.isCan);
  }

  /// Mode 04: ลบรหัสและรีเซ็ตสถานะ readiness ทั้งหมด
  /// (ด่านอ่านอย่างเดียวปล่อยคำสั่งนี้เฉพาะเมื่อเรียกผ่านฟังก์ชันนี้ ซึ่งใช้จากปุ่มลบรหัสที่ยืนยันแล้ว)
  Future<bool> clearDtcs() async {
    final r = await elm.allowClearing(() => elm.query('04', timeout: const Duration(seconds: 8)));
    return r.messages.any((m) => m.data.isNotEmpty && m.data[0] == 0x44);
  }

  Future<String?> readVin() async {
    final r = await elm.query('0902', timeout: const Duration(seconds: 8));
    if (!r.isOk) return null;
    return decodeVin(r.messages, isCan: elm.isCan);
  }

  // ---------------- Mode 06 ----------------

  /// อ่านผลการทดสอบทั้งหมดของ Mode 06 (รองรับเฉพาะ CAN)
  Future<List<Mode06Result>> readMode06({void Function(String step)? onStep}) async {
    if (!elm.isCan) return const [];
    final mids = <int>{};
    var base = 0x00;
    while (base <= 0xE0) {
      final r = await elm.query('06${_hex(base)}');
      var any = false;
      for (final m in r.messages) {
        if (m.data.length >= 6 && m.data[0] == 0x46 && m.data[1] == base) {
          mids.addAll(decodeSupportMask(base, m.data.sublist(2)));
          any = true;
        }
      }
      if (!any || !mids.contains(base + 0x20)) break;
      base += 0x20;
    }
    final out = <Mode06Result>[];
    for (final mid in mids.where((m) => m % 0x20 != 0).toList()..sort()) {
      onStep?.call(mode06MidName(mid));
      final r = await elm.query('06${_hex(mid)}', timeout: const Duration(seconds: 6));
      for (final m in r.messages) {
        if (m.data.length >= 10 && m.data[0] == 0x46 && m.data[1] == mid) {
          out.addAll(parseMode06(m.data.sublist(1)));
          break; // ใช้คำตอบจากกล่องแรก (กล่องเครื่องยนต์)
        }
      }
    }
    return out;
  }

  // ---------------- Mode 09 ----------------

  /// อ่านข้อมูลกล่องทุกกล่องที่ตอบ: ชื่อ, Calibration ID, CVN, ตัวนับการใช้งาน
  Future<List<EcuIdentity>> readEcuIdentities() async {
    final sup = <String, Set<int>>{};
    final r0 = await elm.query('0900');
    for (final m in r0.messages) {
      if (m.data.length >= 6 && m.data[0] == 0x49 && m.data[1] == 0x00) {
        sup[m.ecu] = decodeSupportMask(0, m.data.sublist(2));
      }
    }
    if (sup.isEmpty) return const [];

    final perEcu = <String, Map<int, List<int>>>{};
    for (final pid in [0x04, 0x06, 0x08, 0x0A, 0x0B]) {
      if (!sup.values.any((s) => s.contains(pid))) continue;
      final r = await elm.query('09${_hex(pid)}', timeout: const Duration(seconds: 8));
      for (final m in r.messages) {
        if (m.data.length >= 3 && m.data[0] == 0x49 && m.data[1] == pid) {
          (perEcu[m.ecu] ??= {})[pid] = m.data.sublist(2);
        }
      }
    }
    return [
      for (final ecu in sup.keys)
        () {
          final d = perEcu[ecu] ?? const <int, List<int>>{};
          final iupr = parseIupr(d[0x08] ?? d[0x0B] ?? const []);
          return EcuIdentity(
            ecu: ecu,
            name: d[0x0A] == null ? null : parseEcuName(d[0x0A]!),
            calIds: d[0x04] == null ? const [] : parseCalIds(d[0x04]!),
            cvns: d[0x06] == null ? const [] : parseCvns(d[0x06]!),
            obdConditionCount: iupr.isNotEmpty ? iupr[0] : null,
            ignitionCount: iupr.length > 1 ? iupr[1] : null,
          );
        }(),
    ];
  }

  static String _hex(int b) => b.toRadixString(16).padLeft(2, '0').toUpperCase();
}

/// ประกอบ VIN จากคำตอบ Mode 09 PID 02
///
/// CAN: ข้อความเดียว [49 02 01 + 17 ตัวอักษร]
/// โปรโตคอลเก่า: หลายข้อความ [49 02 seq + 4 ไบต์] ต้องเรียงตาม seq
String? decodeVin(List<EcuMessage> messages, {required bool isCan}) {
  final bytes = <int>[];
  if (isCan) {
    for (final m in messages) {
      if (m.data.length > 3 && m.data[0] == 0x49 && m.data[1] == 0x02) {
        bytes.addAll(m.data.sublist(3));
        break;
      }
    }
  } else {
    final parts = messages
        .where((m) => m.data.length >= 4 && m.data[0] == 0x49 && m.data[1] == 0x02)
        .toList()
      ..sort((a, b) => a.data[2].compareTo(b.data[2]));
    for (final m in parts) {
      bytes.addAll(m.data.sublist(3));
    }
  }
  final text = String.fromCharCodes(bytes.where((b) => b >= 0x30 && b <= 0x5A));
  if (text.length < 17) return text.isEmpty ? null : text;
  return text.substring(text.length - 17);
}
