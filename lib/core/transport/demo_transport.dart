import 'dart:async';
import 'dart:math' as math;

import 'obd_transport.dart';

/// รหัสปัญหาของกล่องจำลอง (UDS)
class DemoDtc {
  const DemoDtc(this.code, this.ftb, this.status);
  final String code;
  final int ftb;
  final int status;
}

class _DemoModule {
  _DemoModule(this.tx, this.name, this.dtcs);
  final int tx;
  final String name;
  final List<DemoDtc> dtcs;
  int get rx => tx + 8;
}

/// ตัวจำลอง ELM327 + รถทั้งคัน ใช้พัฒนา UI และทดสอบโดยไม่ต้องอยู่ในรถ
///
/// รถเบนซิน CAN 11 บิต 500 kbps (Toyota ไทย ปี 2008, ไมล์ในกล่อง 186,420 กม.)
/// - กล่องเครื่อง 7E0/7E8: P0171 + P0301 (ยืนยัน), P0420 (รอยืนยัน), P0171 (ถาวร)
/// - กล่องเกียร์ 7E1/7E9: ไม่มีโค้ด
/// - ABS 7B0/7B8: C0035-31 (เซ็นเซอร์ความเร็วล้อหน้าซ้าย ไม่มีสัญญาณ)
/// - ถุงลม 780/788 และหน้าปัด 7C0/7C8: ไม่มีโค้ด
/// รองรับ Mode 01/02/03/04/06/07/09/0A และ UDS 10/14/19/22/3E
/// มีโหมดจำลองการขับ (ออกตัว 0–100 ใน ~9 วินาที) และจำลองการสตาร์ทเครื่องสำหรับทดสอบแบตเตอรี่
/// เปิด [turboDiesel] เพื่อจำลองดีเซลเทอร์โบคอมมอนเรล (บูสต์/ความดันรางที่ต้องการกับค่าจริง) ใช้กับหน้าทดสอบรีแมพ
class DemoTransport implements ObdTransport {
  DemoTransport({
    this.responseDelay = const Duration(milliseconds: 25),
    Set<String>? storedDtcs,
    Set<String>? pendingDtcs,
    Set<String>? permanentDtcs,
    this.vin = defaultVin,
    this.odometerKm = 186420.5,
    this.engineHoursTotal = 5120,
    this.ignitionCycles = 14310,
    this.practice = false,
  })  : stored = storedDtcs ?? {'P0171', 'P0301'},
        pending = pendingDtcs ?? {'P0420'},
        permanent = permanentDtcs ?? {'P0171'} {
    _modules = {
      0x7E1: _DemoModule(0x7E1, 'Transmission ECU', []),
      0x7B0: _DemoModule(0x7B0, 'ABS/VSC', [const DemoDtc('C0035', 0x31, 0x09)]),
      0x780: _DemoModule(0x780, 'Airbag SRS', []),
      0x7C0: _DemoModule(0x7C0, 'Combination Meter', []),
    };
  }

  final Duration responseDelay;
  final Set<String> stored;
  final Set<String> pending;
  final Set<String> permanent;
  final String vin;

  /// VIN ของรถจำลอง
  static const defaultVin = 'MR0FZ22G801234567';

  /// โหมดทดลองที่ผู้ใช้กดจากหน้าเชื่อมต่อ: ผลสแกน/รถจำลองไม่ถูกบันทึกลงโรงรถและประวัติจริง
  final bool practice;
  final double odometerKm;
  final double engineHoursTotal;
  final int ignitionCycles;
  late final Map<int, _DemoModule> _modules;

  final _controller = StreamController<List<int>>.broadcast();
  final _inBuffer = StringBuffer();
  final _start = DateTime.now();
  bool _connected = false;

  // สถานะของ ELM327 จำลอง
  bool _echo = true;
  bool _spaces = true;
  bool _headers = false;
  bool _cleared = false;
  int _header = 0x7DF;

  // สถานะรถจำลอง
  bool _engineRunning = true;
  bool _loadsOn = false;
  DateTime? _crankUntil;
  DateTime? _driveStart;
  double _drivenKm = 0;
  DateTime _lastOdoTick = DateTime.now();

  /// ค่าเริ่มต้นเปลี่ยนได้ในเทสต์ เช่น จำลองความร้อนสูง
  double? coolantOverride;
  double? speedOverride;

  /// กำหนดรอบเครื่องเอง (ใช้ในเทสต์ให้ค่าคงที่แน่นอน)
  double? rpmOverride;

  /// จำลองปิดสวิตช์กุญแจ: ตัวสแกนยังตอบคำสั่ง AT แต่ไม่มีกล่องไหนในรถตอบ
  bool ignitionOff = false;

  /// จำลองเครื่องดีเซลเทอร์โบคอมมอนเรล (เพิ่ม PID 23, 6D, 70, 78) ใช้ทดลองหน้า "ทดสอบรีแมพ"
  bool turboDiesel = false;

  /// บูสต์จริงเกินค่าที่กล่องต้องการตอนเร่ง (kPa) จำลองรถที่คุมบูสต์ไม่อยู่
  double overboostKpa = 0;

  /// รองรับคำสั่งหลาย PID ในคำสั่งเดียว (ปิดเพื่อจำลองกล่องที่ตอบได้ทีละ PID)
  bool multiPid = true;

  /// Freeze frame ของรหัส P0301 (ค่าตอนเกิดปัญหา: เร่งขึ้นเนิน 62 กม./ชม.)
  static const Map<int, List<int>> _freezeData = {
    0x04: [181],
    0x05: [128],
    0x06: [140],
    0x07: [147],
    0x0B: [68],
    0x0C: [0x21, 0x98],
    0x0D: [62],
    0x0F: [78],
    0x10: [0x07, 0x30],
    0x11: [82],
    0x1F: [0x02, 0x80],
    0x42: [0x36, 0x4C],
    0x5C: [126],
  };

  List<int>? _freeze(int pid) {
    if (_cleared || stored.isEmpty) return null;
    if (pid == 0x02) return encodeDtc(stored.contains('P0301') ? 'P0301' : stored.first);
    return _freezeData[pid];
  }

  // ---------- ควบคุมรถจำลอง (ใช้ในหน้าทดสอบสมรรถนะ/แบตเตอรี่ และในเทสต์) ----------

  /// เริ่มจำลองการออกตัวเต็มที่ แล้ววิ่งต่อ ~30 วินาที ก่อนชะลอจอด
  void startDrive() {
    _engineRunning = true;
    _driveStart = DateTime.now();
  }

  void stopDrive() => _driveStart = null;

  void engineOff() {
    _engineRunning = false;
    _driveStart = null;
  }

  /// จำลองการสตาร์ท: แรงดันตก ~1.5 วินาที แล้วเครื่องติด
  void crank() {
    _crankUntil = DateTime.now().add(const Duration(milliseconds: 1500));
    _engineRunning = true;
  }

  void setLoads(bool on) => _loadsOn = on;

  bool get engineRunning => _engineRunning;

  @override
  TransportKind get kind => TransportKind.demo;

  @override
  String get displayName => 'โหมดทดลอง (รถจำลอง)';

  @override
  Stream<List<int>> get incoming => _controller.stream;

  @override
  bool get isConnected => _connected;

  @override
  Future<void> connect() async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    _connected = true;
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
  }

  @override
  Future<void> write(List<int> bytes) async {
    if (!_connected) throw TransportException('ยังไม่ได้เชื่อมต่อ');
    _inBuffer.write(String.fromCharCodes(bytes));
    var text = _inBuffer.toString();
    var idx = text.indexOf('\r');
    while (idx >= 0) {
      final cmd = text.substring(0, idx).trim();
      text = text.substring(idx + 1);
      if (cmd.isNotEmpty) _respond(cmd);
      idx = text.indexOf('\r');
    }
    _inBuffer
      ..clear()
      ..write(text);
  }

  void _respond(String rawCmd) {
    final cmd = rawCmd.toUpperCase().replaceAll(' ', '');
    final String body;
    if (cmd.startsWith('AT')) {
      body = _handleAt(cmd);
    } else if (cmd.startsWith('ST')) {
      body = '?'; // ไม่ใช่ชิป STN
    } else {
      body = _handleRequest(cmd);
    }
    final out = StringBuffer();
    if (_echo) out.write('$rawCmd\r');
    out.write(body);
    out.write('\r\r>');
    final bytes = out.toString().codeUnits;
    Future<void>.delayed(responseDelay, () {
      if (!_connected) return;
      // ส่งเป็นชิ้นเล็กๆ เหมือน BLE จริง เพื่อทดสอบการรวมบัฟเฟอร์
      for (var i = 0; i < bytes.length; i += 20) {
        _controller.add(bytes.sublist(i, math.min(i + 20, bytes.length)));
      }
    });
  }

  String _handleAt(String cmd) {
    if (cmd.startsWith('ATSH')) {
      final h = int.tryParse(cmd.substring(4), radix: 16);
      if (h == null) return '?';
      _header = h;
      return 'OK';
    }
    if (cmd.startsWith('ATCRA') || cmd.startsWith('ATFC') || cmd.startsWith('ATST') || cmd.startsWith('ATSP')) {
      return 'OK';
    }
    switch (cmd) {
      case 'ATZ':
        _echo = true;
        _spaces = true;
        _headers = false;
        _header = 0x7DF;
        return '\rELM327 v1.5';
      case 'ATI':
        return 'ELM327 v1.5 SIM';
      case 'AT@1':
        return 'ProScaner Simulator';
      case 'ATE0':
        _echo = false;
        return 'OK';
      case 'ATE1':
        _echo = true;
        return 'OK';
      case 'ATS0':
        _spaces = false;
        return 'OK';
      case 'ATS1':
        _spaces = true;
        return 'OK';
      case 'ATH0':
        _headers = false;
        return 'OK';
      case 'ATH1':
        _headers = true;
        return 'OK';
      case 'ATDPN':
        return 'A6';
      case 'ATDP':
        return 'AUTO, ISO 15765-4 (CAN 11/500)';
      case 'ATRV':
        return '${_voltage.toStringAsFixed(1)}V';
      default:
        return 'OK';
    }
  }

  // ---------- รถจำลอง ----------

  double get _t => DateTime.now().difference(_start).inMilliseconds / 1000.0;
  double _wave(double period, double amp) => amp * math.sin(_t * 2 * math.pi / period);

  bool get _cranking => _crankUntil != null && DateTime.now().isBefore(_crankUntil!);

  double get _driveT => _driveStart == null ? -1 : DateTime.now().difference(_driveStart!).inMilliseconds / 1000.0;

  double get _speed {
    if (speedOverride != null) return speedOverride!;
    final t = _driveT;
    if (t < 0 || !_engineRunning) return 0;
    if (t <= 30) return 132 * (1 - math.exp(-t / 6.2));
    if (t <= 42) return math.max(0, 132 * (1 - math.exp(-30 / 6.2)) * (1 - (t - 30) / 12));
    return 0;
  }

  int get _gear {
    final v = _speed;
    if (v < 1) return 0;
    if (v < 22) return 1;
    if (v < 42) return 2;
    if (v < 68) return 3;
    if (v < 95) return 4;
    return 5;
  }

  double get _rpm {
    if (rpmOverride != null) return rpmOverride!;
    if (!_engineRunning) return 0;
    if (_cranking) return 220 + _wave(0.3, 40);
    const ratio = [0.0, 118.0, 70.0, 47.0, 35.0, 28.0];
    final g = _gear;
    if (g == 0) return 780 + _wave(3, 35);
    return math.max(900, _speed * ratio[g]);
  }

  bool get _accelerating => _driveT >= 0 && _driveT < 18;

  double get _load {
    if (!_engineRunning) return 0;
    if (_accelerating) return 86 + _wave(1.3, 4);
    if (_speed > 1) return 34 + _wave(4, 3);
    return 22 + _wave(5, 1);
  }

  double get _coolant => coolantOverride ?? math.min(92.0, 62 + _t * 0.5);

  double get _voltage {
    if (_cranking) return 10.1 + _wave(0.4, 0.15);
    if (!_engineRunning) return 12.45 + _wave(9, 0.02);
    return (_loadsOn ? 13.85 : 14.1) + _wave(5, 0.06);
  }

  double get _odometer {
    final now = DateTime.now();
    final dt = now.difference(_lastOdoTick).inMilliseconds / 3600000.0;
    _drivenKm += _speed * dt;
    _lastOdoTick = now;
    return odometerKm + _drivenKm;
  }

  static const Set<int> supportedPids = {
    0x01, 0x04, 0x05, 0x06, 0x07, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11,
    0x14, 0x15, 0x1F, 0x21, 0x2F, 0x30, 0x31, 0x33, 0x42, 0x43, 0x46, 0x49, 0x4D, 0x4E, 0x51,
    0x5C, 0x7F, 0xA4, 0xA6,
  };

  /// PID ที่เพิ่มเมื่อจำลองดีเซลเทอร์โบ
  static const Set<int> dieselPids = {0x23, 0x6D, 0x70, 0x78};

  Set<int> get _supported => turboDiesel ? {...supportedPids, ...dieselPids} : supportedPids;

  // ---------- เทอร์โบ/คอมมอนเรลจำลอง (ค่าจริงไล่ตามค่าที่กล่องต้องการแบบหน่วงเวลา) ----------

  double _boostAct = 101;
  double _railAct = 30;
  double _egt = 220;
  DateTime? _turboTick;

  /// บูสต์ที่กล่องต้องการ (kPa สัมบูรณ์): เดินเบา ~101, เร่งเต็มที่ขึ้นตามรอบถึง ~225
  double get _boostCmd {
    if (!_engineRunning) return 100;
    if (_accelerating) return 100 + 125 * ((_rpm - 1100) / 1500).clamp(0.0, 1.0);
    return _speed > 1 ? 112 : 101;
  }

  /// ความดันรางที่ต้องการ (MPa): เดินเบา 30, เร่งเต็มที่ ~160
  double get _railCmd {
    if (!_engineRunning) return 0;
    return 30 + 130 * (_load / 100) * (_rpm / 3000).clamp(0.3, 1.0);
  }

  void _turboStep() {
    final now = DateTime.now();
    final last = _turboTick ?? now;
    _turboTick = now;
    final dt = now.difference(last).inMilliseconds / 1000.0;
    double follow(double cur, double target, double tau) => cur + (target - cur) * (1 - math.exp(-dt / tau));
    final over = _accelerating && _boostCmd > 150 ? overboostKpa : 0.0;
    _boostAct = follow(_boostAct, _boostCmd + over, 0.7);
    _railAct = follow(_railAct, _railCmd, 0.25);
    _egt = follow(_egt, _engineRunning ? 200 + 470 * _load / 100 : 60, 3.0);
  }

  List<int> _parseHex(String cmd) =>
      [for (var i = 0; i < cmd.length; i += 2) int.parse(cmd.substring(i, i + 2), radix: 16)];

  String _handleRequest(String cmd) {
    if (!RegExp(r'^[0-9A-F]+$').hasMatch(cmd) || cmd.length.isOdd) return '?';
    if (ignitionOff) return 'NO DATA';
    final bytes = _parseHex(cmd);
    final ext = _hiluxLike['${_header.toRadixString(16).toUpperCase()}:$cmd'];
    if (ext != null) {
      final i = (DateTime.now().difference(_start).inSeconds ~/ 3) % ext.length;
      return _frames(_header + 8, _parseHex(ext[i])).join('\r');
    }
    if (_header == 0x7DF) return _handleObd(bytes, functional: true);
    if (_header == 0x7E0) {
      return bytes.first < 0x10 ? _handleObd(bytes, functional: false) : _handleUds(0x7E0, bytes);
    }
    if (_modules.containsKey(_header)) {
      return bytes.first < 0x10 ? 'NO DATA' : _handleUds(_header, bytes);
    }
    return 'NO DATA';
  }

  String _handleObd(List<int> bytes, {required bool functional}) {
    final mode = bytes.first;
    final tcm = functional;
    switch (mode) {
      case 0x01:
        if (bytes.length < 2) return 'NO DATA';
        if (bytes.length > 2) {
          // หลาย PID ในคำสั่งเดียว (ISO 15765-4: สูงสุด 6 PID) ตอบรวมในข้อความเดียว ข้าม PID ที่ไม่รองรับ
          if (!multiPid || bytes.length > 7) return 'NO DATA';
          final data = <int>[0x41];
          for (final pid in bytes.skip(1)) {
            final v = _mode01(pid);
            if (v != null) data.addAll([pid, ...v]);
          }
          return data.length == 1 ? 'NO DATA' : _frames(0x7E8, data).join('\r');
        }
        final pid = bytes[1];
        final engine = _mode01(pid);
        final frames = <String>[];
        if (engine != null) frames.addAll(_frames(0x7E8, [0x41, pid, ...engine]));
        // กล่องเกียร์ตอบเฉพาะ PID 00 เพื่อจำลองการตอบจากหลาย ECU
        if (tcm && pid == 0x00) {
          frames.addAll(_frames(0x7E9, [0x41, 0x00, 0x98, 0x18, 0x00, 0x01]));
        }
        return frames.isEmpty ? 'NO DATA' : frames.join('\r');
      case 0x03:
        return [
          ..._frames(0x7E8, [0x43, ..._dtcPayload(stored)]),
          if (tcm) ..._frames(0x7E9, [0x43, 0x00]),
        ].join('\r');
      case 0x07:
        return _frames(0x7E8, [0x47, ..._dtcPayload(pending)]).join('\r');
      case 0x0A:
        return _frames(0x7E8, [0x4A, ..._dtcPayload(permanent)]).join('\r');
      case 0x02:
        if (bytes.length < 2) return 'NO DATA';
        final ff = _freeze(bytes[1]);
        return ff == null ? 'NO DATA' : _frames(0x7E8, [0x42, bytes[1], 0x00, ...ff]).join('\r');
      case 0x04:
        _clearEngine();
        return _frames(0x7E8, [0x44]).join('\r');
      case 0x06:
        if (bytes.length < 2) return 'NO DATA';
        final r = _mode06(bytes[1]);
        return r == null ? 'NO DATA' : _frames(0x7E8, [0x46, ...r]).join('\r');
      case 0x09:
        if (bytes.length < 2) return 'NO DATA';
        final pid = bytes[1];
        final frames = <String>[];
        final e = _mode09Engine(pid);
        if (e != null) frames.addAll(_frames(0x7E8, [0x49, pid, ...e]));
        final t = tcm ? _mode09Tcm(pid) : null;
        if (t != null) frames.addAll(_frames(0x7E9, [0x49, pid, ...t]));
        return frames.isEmpty ? 'NO DATA' : frames.join('\r');
      default:
        return 'NO DATA';
    }
  }

  void _clearEngine() {
    stored.clear();
    pending.clear();
    _cleared = true;
    // รหัสถาวร (permanent) ลบด้วย Mode 04 ไม่ได้ ต้องให้ ECU ยืนยันเองว่าหาย
  }

  // ---------- UDS ----------

  String _handleUds(int tx, List<int> b) {
    final rx = tx + 8;
    final sid = b.first;
    List<int> neg(int nrc) => [0x7F, sid, nrc];
    List<int> resp;
    switch (sid) {
      case 0x3E:
        resp = [0x7E, b.length > 1 ? b[1] & 0x7F : 0];
      case 0x10:
        resp = b.length > 1 ? [0x50, b[1], 0x00, 0x32, 0x01, 0xF4] : neg(0x13);
      case 0x19:
        if (b.length < 3 || b[1] != 0x02) {
          resp = neg(0x12);
        } else {
          resp = [0x59, 0x02, 0xFF, for (final d in _udsDtcs(tx)) ..._udsDtcBytes(d)];
        }
      case 0x14:
        if (tx == 0x7E0) {
          _clearEngine();
        } else {
          _modules[tx]!.dtcs.clear();
        }
        resp = [0x54];
      case 0x22:
        if (b.length < 3) {
          resp = neg(0x13);
          break;
        }
        final did = b[1] << 8 | b[2];
        final name = tx == 0x7E0 ? 'Engine ECU' : _modules[tx]!.name;
        resp = switch (did) {
          0xF197 => [0x62, 0xF1, 0x97, ...name.codeUnits],
          0xF190 => [0x62, 0xF1, 0x90, ...vin.codeUnits],
          0xF18C => [0x62, 0xF1, 0x8C, ...'SN${tx.toRadixString(16).toUpperCase()}0042'.codeUnits],
          _ => _demoDid(tx, did) ?? neg(0x31),
        };
      case 0x21:
        // KWP แบบเก่า: กล่องเครื่องตอบ local ID 01 และ 02 เท่านั้น (ใช้ทดลองหน้าค้นหาค่า)
        if (b.length < 2) {
          resp = neg(0x13);
          break;
        }
        resp = tx == 0x7E0 && (b[1] == 0x01 || b[1] == 0x02)
            ? [0x61, b[1], ...(b[1] == 0x01 ? [0x5A, 0x1F, 0x40, 0x7B] : [0x03, 0xE8])]
            : neg(0x12);
      default:
        resp = neg(0x11);
    }
    return _frames(rx, resp).join('\r');
  }

  /// คำตอบของกล่องแบบ Toyota Hilux 2.8 (ค่าจริงจากชุดทดสอบ OBDb) ใช้ทดลองคลังชุดค่าเฉพาะยี่ห้อ
  /// เวลาผ่านไปจะสลับคำตอบให้ค่าเปลี่ยน (เพื่อทดลองดูไบต์สด)
  static const _hiluxLike = <String, List<String>>{
    '700:22112B': ['62112B807E7F81', '62112B807E8080', '62112B807E8081', '62112B807F7F80'],
    '700:221131': ['6211317F8280D97FC67FA2', '62113180638036805780BF', '621131808C7F90807382C1', '621131809980B080128035'],
    '700:221105': ['62110513', '62110514', '62110515', '6211050E'],
    '700:22119B': ['62119B00'],
    '700:221F7A': ['621F7A01000100000000', '621F7A01FFDC00000000', '621F7A01FFFB00000000', '621F7A01005C00000000'],
    '700:221620': ['62162000', '62162001'],
    '700:221621': ['62162101', '62162102', '62162103', '62162104'],
    '700:221627': ['62162732A0', '62162733E0', '6216273700', '6216276860'],
    '700:221628': ['62162850A0', '6216285500', '62162860E0', '6216286F40'],
    '700:221002': ['6210022654', '6210022BFC', '6210022C00', '621002209C'],
    '700:220103': ['62010301009855', '62010301009863', '62010301011330', '620103010168FF'],
    '700:221F6D': ['621F6D1B0DAC0D33000DAC0D5900', '621F6D1B0DAC0D38000DAC0D7000', '621F6D1B0DAC0D5F000DAC0D5600', '621F6D1B0DAC0D5F000DAC0D6F00'],
    '700:221074': ['6210740593', '62107406FE', '6210740D01', '6210741AA9'],
    '700:221041': ['6210414E4F', '621041C6C6', '621041A7A7', '621041B4B4'],
    '7E0:2182': ['61825AA05DC0', '61825D205E60', '61825E605F00', '618260E062C0'],
    '7E0:2185': ['6185010010', '6185020010', '6185022010', '6185032010'],
  };

  /// ค่าเฉพาะยี่ห้อของรถจำลอง (สมมติขึ้นเพื่อทดลองหน้า "ค่าเฉพาะยี่ห้อ")
  /// 7E0 22 1101–1104 ชดเชยหัวฉีดสูบ 1–4 (S16/100 mm³) สูบ 3 เพี้ยนชัด
  /// 7E0 22 1110 เขม่า DPF (U16/100 g), 22 1111 ระยะจากการเผาครั้งล่าสุด (กม.)
  /// 7E1 22 1201 อุณหภูมิน้ำมันเกียร์ (A-40 °C)
  List<int>? _demoDid(int tx, int did) {
    final t = DateTime.now().difference(_start).inMilliseconds / 1000.0;
    List<int> u16(int v) => [(v >> 8) & 0xFF, v & 0xFF];
    if (tx == 0x7E0) {
      const base = [0.42, -0.31, 2.85, -0.18];
      if (did >= 0x1101 && did <= 0x1104) {
        final i = did - 0x1101;
        final v = ((base[i] + 0.06 * math.sin(t * 1.3 + i)) * 100).round();
        return [0x62, did >> 8, did & 0xFF, ...u16(v & 0xFFFF)];
      }
      if (did == 0x1110) return [0x62, 0x11, 0x10, ...u16((18.4 + 0.02 * t).clamp(0, 600) * 100 ~/ 1)];
      if (did == 0x1111) return [0x62, 0x11, 0x11, ...u16(412)];
      // ค่าที่กล่องเก็บแบบเดียวกับ OBD มาตรฐาน (ใช้ทดลอง "จับคู่กับค่า OBD มาตรฐาน")
      // 22 1210 = ความร้อนน้ำหล่อเย็น (เหมือน PID 05), 22 1203 = รอบเครื่อง ×4 (เหมือน PID 0C), 22 1240 = อากาศเข้า (เหมือน PID 0F)
      if (did == 0x1210) return [0x62, 0x12, 0x10, (_coolant + 40).round().clamp(0, 255)];
      if (did == 0x1203) return [0x62, 0x12, 0x03, ...u16((_rpm * 4).round().clamp(0, 65535))];
      if (did == 0x1240) return [0x62, 0x12, 0x40, (36.0 + 40).round()];
    }
    if (tx == 0x7E1 && did == 0x1201) {
      return [0x62, 0x12, 0x01, (40 + 78 + 4 * math.sin(t / 8)).round()];
    }
    return null;
  }

  List<DemoDtc> _udsDtcs(int tx) {
    if (tx == 0x7E0) {
      return [
        for (final c in stored) DemoDtc(c, 0x00, 0x2F),
        for (final c in pending.difference(stored)) DemoDtc(c, 0x00, 0x24),
      ];
    }
    return _modules[tx]?.dtcs ?? const [];
  }

  List<int> _udsDtcBytes(DemoDtc d) => [...encodeDtc(d.code), d.ftb, d.status];

  // ---------- Mode 01 ----------

  List<int>? _mode01(int pid) {
    if (pid % 0x20 == 0 && pid <= 0xC0) return _supportMask(pid);
    if (!_supported.contains(pid)) return null;
    if (turboDiesel) _turboStep();
    int b(double v) => v.round().clamp(0, 255);
    List<int> w(double v) {
      final r = v.round().clamp(0, 65535);
      return [r >> 8 & 0xFF, r & 0xFF];
    }

    List<int> dw(double v) {
      final r = v.round();
      return [r >> 24 & 0xFF, r >> 16 & 0xFF, r >> 8 & 0xFF, r & 0xFF];
    }

    final run = _engineRunning;
    switch (pid) {
      case 0x01:
        final mil = stored.isNotEmpty ? 0x80 : 0x00;
        // หลังลบรหัส ระบบตรวจสอบตัวเองกลับเป็น "ยังไม่เสร็จ" จนกว่าจะขับทดสอบครบ
        return [mil | stored.length, _cleared ? 0x07 | 0x20 : 0x07, 0x65, _cleared ? 0x65 : 0x00];
      case 0x04:
        return [b(_load * 255 / 100)];
      case 0x05:
        return [b(_coolant + 40)];
      case 0x06: // STFT แบงก์ 1 ประมาณ +6%
        return [b(128 + (run ? 6 + _wave(2, 3) : 0) * 128 / 100)];
      case 0x07: // LTFT แบงก์ 1 ประมาณ +14% สอดคล้องกับ P0171
        return [b(128 + 14 * 128 / 100)];
      case 0x0B:
        if (turboDiesel) return [b(_boostAct)]; // ดีเซล: ท่อไอดีคือความดันบูสต์
        return [b(run ? (_accelerating ? 92 + _wave(1, 3) : 33 + _wave(3, 2)) : 100)];
      case 0x0C:
        return w(_rpm * 4);
      case 0x0D:
        return [b(_speed)];
      case 0x0E:
        return [b((10.0 + 64) * 2)];
      case 0x0F:
        return [b(36.0 + 40)];
      case 0x10:
        final maf = run ? math.max(2.6, _rpm * _load / 100 * 0.0125) + _wave(3, 0.15) : 0.0;
        return w(maf * 100);
      case 0x11:
        return [b((run ? (_accelerating ? 88 : (_speed > 1 ? 24 : 15)) : 0) * 255 / 100)];
      case 0x14:
        return [b(run ? (0.45 + _wave(1.2, 0.35)) * 200 : 0), 0xFF];
      case 0x15:
        return [b(run ? (0.62 + _wave(9, 0.04)) * 200 : 0), 0xFF];
      case 0x1F:
        return w(_t + 300);
      case 0x21:
        return w(stored.isNotEmpty ? 37 : 0);
      case 0x2F:
        return [b(63 * 255 / 100)];
      case 0x30:
        return [_cleared ? 0 : 85];
      case 0x31:
        return w(_cleared ? 0 : 1240);
      case 0x33:
        return [100];
      case 0x42:
        return w(_voltage * 1000);
      case 0x43:
        return w(_load * 255 / 100);
      case 0x46:
        return [b(33.0 + 40)];
      case 0x49:
        return [b((run ? (_accelerating ? 95 : (_speed > 1 ? 20 : 0)) : 0) * 255 / 100)];
      case 0x4D:
        return w(stored.isNotEmpty ? 52 : 0);
      case 0x4E:
        return w(_cleared ? 0 : 2950);
      case 0x51:
        return [1];
      case 0x5C:
        return [b(math.min(88.0, 60 + _t * 0.4) + 40)];
      case 0x23: // ความดันราง ×10 kPa
        return w(_railAct * 100);
      case 0x6D: // ความดันรางที่ต้องการ/จริง ×10 kPa + อุณหภูมิน้ำมัน
        return [0x03, ...w(_railCmd * 100), ...w(_railAct * 100), b(45.0 + 40), 0, 0, 0, 0, 0];
      case 0x70: // บูสต์ที่ต้องการ/จริง ×0.03125 kPa (ไบต์แรก = บิตบอกว่ามีค่าไหน)
        return [0x03, ...w(_boostCmd * 32), ...w(_boostAct * 32), 0, 0, 0, 0, 0];
      case 0x78: // อุณหภูมิไอเสีย เซ็นเซอร์ 1 (×0.1 − 40 °C)
        return [0x01, ...w((_egt + 40) * 10), 0, 0, 0, 0, 0, 0];
      case 0x7F:
        final total = engineHoursTotal * 3600 + _t;
        return [0x07, ...dw(total), ...dw(900 * 3600), ...dw(0)];
      case 0xA4:
        return [0x02, _gear << 4, 0, 0];
      case 0xA6:
        return dw(_odometer * 10);
    }
    return null;
  }

  /// บิตแมสก์ PID ที่รองรับ (PID 00, 20, 40, …)
  List<int> _supportMask(int base) => _mask(base, _supported);

  static List<int> _mask(int base, Set<int> set) {
    var mask = 0;
    for (var i = 1; i <= 32; i++) {
      final pid = base + i;
      final hasNext = i == 32 && set.any((p) => p > base + 32);
      if (set.contains(pid) || hasNext) mask |= 1 << (32 - i);
    }
    return [mask >> 24 & 0xFF, mask >> 16 & 0xFF, mask >> 8 & 0xFF, mask & 0xFF];
  }

  // ---------- Mode 06 ----------

  static const Set<int> _mids = {0x01, 0x21, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5};

  List<int> _rec(int mid, int tid, int u, int v, int mn, int mx) =>
      [mid, tid, u, v >> 8, v & 0xFF, mn >> 8, mn & 0xFF, mx >> 8, mx & 0xFF];

  List<int>? _mode06(int mid) {
    if (mid % 0x20 == 0) return [mid, ..._mask(mid, _mids)];
    switch (mid) {
      case 0x01: // O2 B1S1: เกณฑ์หนา→บาง 0.45 V, เวลาสลับ 72 ms
        return [
          ..._rec(0x01, 0x01, 0x0A, 3689, 0, 65535),
          ..._rec(0x01, 0x05, 0x10, 72, 0, 160),
        ];
      case 0x21: // แคต B1 (ทดสอบเฉพาะผู้ผลิต) ใกล้เกณฑ์ สอดคล้องกับ P0420 รอยืนยัน
        return _rec(0x21, 0x80, 0x01, 412, 0, 450);
      case 0xA1:
        return _rec(0xA1, 0x0B, 0x24, 41, 0, 65535);
      case 0xA2: // สูบ 1 สะสมสูง สอดคล้องกับ P0301
        return [..._rec(0xA2, 0x0B, 0x24, _cleared ? 0 : 38, 0, 65535), ..._rec(0xA2, 0x0C, 0x24, _cleared ? 0 : 12, 0, 65535)];
      case 0xA3:
        return [..._rec(0xA3, 0x0B, 0x24, 1, 0, 65535), ..._rec(0xA3, 0x0C, 0x24, 0, 0, 65535)];
      case 0xA4:
        return [..._rec(0xA4, 0x0B, 0x24, 2, 0, 65535), ..._rec(0xA4, 0x0C, 0x24, 0, 0, 65535)];
      case 0xA5:
        return [..._rec(0xA5, 0x0B, 0x24, 0, 0, 65535), ..._rec(0xA5, 0x0C, 0x24, 1, 0, 65535)];
    }
    return null;
  }

  // ---------- Mode 09 ----------

  static List<int> _pad(String s, int n) => [...s.codeUnits.take(n), ...List.filled(n - math.min(n, s.length), 0)];

  List<int>? _mode09Engine(int pid) {
    switch (pid) {
      case 0x00:
        return _mask(0, {0x02, 0x04, 0x06, 0x08, 0x0A});
      case 0x02:
        return [0x01, ...vin.codeUnits];
      case 0x04:
        return [0x01, ..._pad('89663-0K540', 16)];
      case 0x06:
        return [0x01, 0x1A, 0x2B, 0x3C, 0x4D];
      case 0x08:
        final c = <int>[6820, ignitionCycles, 2100, 6800, 1900, 6800, 0, 0, 2400, 6800, 2200, 6800, 0, 0, 1800, 6800];
        return [0x10, for (final v in c) ...[v >> 8 & 0xFF, v & 0xFF]];
      case 0x0A:
        return [0x01, ..._pad('ECM', 4).sublist(0, 3), 0x00, ..._pad('-EngineControl', 16)];
    }
    return null;
  }

  List<int>? _mode09Tcm(int pid) {
    switch (pid) {
      case 0x00:
        return _mask(0, {0x04, 0x0A});
      case 0x04:
        return [0x01, ..._pad('89530-0K160', 16)];
      case 0x0A:
        return [0x01, ..._pad('TCM', 4).sublist(0, 3), 0x00, ..._pad('-TransmisCtrl', 16)];
    }
    return null;
  }

  static List<int> _dtcPayload(Set<String> codes) {
    final out = <int>[codes.length];
    for (final c in codes) {
      out.addAll(encodeDtc(c));
    }
    return out;
  }

  /// แปลงรหัสเช่น P0171 เป็น 2 ไบต์ตามมาตรฐาน SAE J2012
  static List<int> encodeDtc(String code) {
    const letters = 'PCBU';
    final l = letters.indexOf(code[0]);
    final d1 = int.parse(code[1]);
    final rest = int.parse(code.substring(2), radix: 16);
    final a = (l << 6) | (d1 << 4) | (rest >> 8);
    return [a, rest & 0xFF];
  }

  /// สร้างเฟรม CAN แบบ ISO-TP (มี PCI byte) ในรูปที่ ELM327 แสดงเมื่อเปิด header
  List<String> _frames(int header, List<int> data) {
    String join(List<int> bs) => bs.map(_hex).join(_spaces ? ' ' : '');
    if (!_headers) {
      // ปิด header: ELM327 ตัด PCI ออกให้ และแสดงข้อความยาวเป็น "จำนวนไบต์" + "0: …"
      if (data.length <= 7) return [join(data)];
      final lines = <String>[data.length.toRadixString(16).padLeft(3, '0').toUpperCase()];
      lines.add('0:${_spaces ? ' ' : ''}${join(data.take(6).toList())}');
      var seq = 1;
      for (var i = 6; i < data.length; i += 7) {
        final chunk = data.skip(i).take(7).toList();
        lines.add('${(seq & 0x0F).toRadixString(16).toUpperCase()}:${_spaces ? ' ' : ''}${join(chunk)}');
        seq++;
      }
      return lines;
    }
    final raw = <List<int>>[];
    if (data.length <= 7) {
      raw.add([data.length, ...data]);
    } else {
      raw.add([0x10 | (data.length >> 8), data.length & 0xFF, ...data.take(6)]);
      var seq = 1;
      for (var i = 6; i < data.length; i += 7) {
        raw.add([0x20 | (seq & 0x0F), ...data.skip(i).take(7)]);
        seq++;
      }
    }
    final h = header.toRadixString(16).toUpperCase();
    return raw.map((f) {
      final padded = [...f, ...List.filled(8 - f.length, 0x55)];
      return _spaces ? '$h ${join(padded)}' : '$h${join(padded)}';
    }).toList();
  }

  static String _hex(int b) => b.toRadixString(16).padLeft(2, '0').toUpperCase();
}
