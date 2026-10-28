import 'dart:async';

import '../safety/command_guard.dart';
import '../transport/obd_transport.dart';
import 'response_parser.dart';

class ElmException implements Exception {
  ElmException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// แอปไม่ส่งคำสั่งนี้ (ไม่ใช่คำสั่งอ่านค่า ดู [checkCommand])
class BlockedCommandException extends ElmException {
  BlockedCommandException(this.command, this.reason) : super('ไม่ส่งคำสั่ง $command: $reason');

  final String command;
  final String reason;
}

/// ชนิดชิปของตัวสแกน (เดาจากคำตอบของ ATI / STI)
enum AdapterKind {
  stn('ชิป STN (OBDLink หรือเทียบเท่า)'),
  elmGenuine('ELM327'),
  elmClone('ELM327 (น่าจะเป็นตัวก๊อป)'),
  simulator('ตัวจำลอง'),
  unknown('ไม่ทราบ');

  const AdapterKind(this.labelTh);
  final String labelTh;
}

/// ความสามารถของตัวสแกนที่ตรวจพบตอนเชื่อมต่อ
class AdapterInfo {
  const AdapterInfo({
    required this.kind,
    required this.version,
    this.stnVersion,
    this.description,
    this.flowControl = false,
  });

  final AdapterKind kind;
  final String version;
  final String? stnVersion;
  final String? description;

  /// รองรับคำสั่ง ATFC (ตั้ง flow control เอง) ซึ่งจำเป็นเวลาอ่านข้อความยาวจากกล่องอื่นๆ
  final bool flowControl;

  /// ส่งข้อความยาวหลายเฟรมได้ (STPX) ใช้สำหรับงานเขียนข้อมูลลงกล่องในอนาคต
  bool get canSendLongMessages => kind == AdapterKind.stn;
}

/// คุยกับชิป ELM327: ส่งคำสั่งทีละคำสั่ง รอเครื่องหมาย '>' แล้วคืนข้อความดิบ
class Elm327 {
  Elm327(this.transport);

  final ObdTransport transport;

  final _buffer = StringBuffer();
  Completer<String>? _pending;
  Future<void> _queue = Future<void>.value();
  StreamSubscription<List<int>>? _sub;
  int _orphans = 0; // จำนวนคำสั่งที่หมดเวลาแต่คำตอบอาจยังมาทีหลัง
  Completer<void>? _drained;
  final _exclusiveKey = Object();

  String? version;
  String? protocolCode; // ผลจาก ATDPN เช่น "A6"
  String? protocolName; // ผลจาก ATDP
  AdapterInfo? adapter;

  /// ถูกเรียกทุกครั้งที่ส่งหรือรับข้อความ ใช้แสดงในหน้า log/เทอร์มินัล
  void Function(String line)? onLog;

  /// เริ่มต้นตัวสแกนเสร็จแล้ว (หลังจากนี้ถ้าตัวสแกนรีเซ็ตตัวเอง ต้องตั้งค่าใหม่)
  bool _ready = false;

  /// ตรวจพบว่าตัวสแกนรีเซ็ตตัวเองระหว่างที่ไม่มีคำสั่งค้าง ต้องตั้งค่าใหม่ก่อนคำสั่งถัดไป
  bool _needsReinit = false;

  /// จำนวนครั้งที่ตัวสแกนรีเซ็ตตัวเอง (ไฟตกตอนสตาร์ท ฯลฯ) แสดงในหน้าข้อมูลตัวสแกน
  int resetCount = 0;

  /// การตั้งค่าที่ต้องใช้เสมอ: ปิด echo, ปิดขึ้นบรรทัด, ปิดช่องว่าง, เปิด header, timing อัตโนมัติ
  static const setupCommands = ['ATE0', 'ATL0', 'ATS0', 'ATH1', 'ATAT1'];

  /// ข้อความที่บอกว่าตัวสแกนรีเซ็ตตัวเอง (การตั้งค่ากลับเป็นค่าเริ่มต้นหมด)
  static final _resetMarker = RegExp(r'ELM327|LV RESET|ACT ALERT', caseSensitive: false);

  HeaderFormat get headerFormat => ResponseParser.headerFormatFor(protocolCode);

  bool get isCan => headerFormat == HeaderFormat.can11 || headerFormat == HeaderFormat.can29;
  bool get is29Bit => headerFormat == HeaderFormat.can29;

  /// header สำหรับคำสั่ง OBD แบบส่งถึงทุกกล่อง (functional)
  String get functionalHeader => is29Bit ? '18DB33F1' : '7DF';

  void attach() {
    _sub ??= transport.incoming.listen(_onData, onError: _onError);
  }

  Future<void> detach() async {
    await _sub?.cancel();
    _sub = null;
    _pending?.completeError(ElmException('ตัดการเชื่อมต่อแล้ว'));
    _pending = null;
  }

  void _onData(List<int> bytes) {
    // ตัวสแกนบางรุ่นส่ง 0x00 แทรกมา ตัดทิ้ง
    _buffer.write(String.fromCharCodes(bytes.where((b) => b != 0)));
    var text = _buffer.toString();
    var idx = text.indexOf('>');
    while (idx >= 0) {
      final response = text.substring(0, idx);
      text = text.substring(idx + 1);
      if (_orphans > 0) {
        // คำตอบมาช้าของคำสั่งที่หมดเวลาไปแล้ว ทิ้ง ไม่ให้ไปปนกับคำสั่งถัดไป
        _orphans--;
        onLog?.call('(ทิ้งคำตอบที่มาช้า: ${response.trim()})');
        if (_orphans == 0) _drained?.complete();
      } else {
        final p = _pending;
        _pending = null;
        if (p != null && !p.isCompleted) {
          p.complete(response);
        } else if (_ready && _resetMarker.hasMatch(response)) {
          // ตัวสแกนรีเซ็ตเองตอนไม่มีคำสั่งค้าง (เช่น ไฟตกตอนสตาร์ทเครื่อง)
          _needsReinit = true;
          onLog?.call('(ตัวสแกนรีเซ็ตตัวเอง: ${response.trim()})');
        }
      }
      idx = text.indexOf('>');
    }
    _buffer
      ..clear()
      ..write(text);
  }

  void _onError(Object error) {
    final p = _pending;
    _pending = null;
    if (p != null && !p.isCompleted) {
      p.completeError(error is TransportException ? ElmException(error.message) : error);
    }
  }

  bool get _insideExclusive => Zone.current[_exclusiveKey] == true;

  static final _clearKey = Object();

  /// รัน [body] โดยอนุญาตให้ส่งคำสั่งลบรหัสปัญหา (04 / 14)
  /// ใช้เฉพาะปุ่มลบรหัสที่ผู้ใช้ยืนยันแล้ว คำสั่งต้องห้ามอื่นยังส่งไม่ได้เหมือนเดิม
  Future<T> allowClearing<T>(Future<T> Function() body) => runZoned(body, zoneValues: {_clearKey: true});

  bool get _clearingAllowed => Zone.current[_clearKey] == true;

  /// ด่านอ่านอย่างเดียว: ทุกคำสั่งผ่านจุดนี้ก่อนออกจากแอป
  void _guard(String command) {
    final check = checkCommand(command);
    if (check.sendable || (check.kind == CommandKind.clear && _clearingAllowed)) return;
    final reason = check.kind == CommandKind.clear
        ? 'ลบรหัสได้จากปุ่ม "ลบรหัส" เท่านั้น (มีหน้าต่างยืนยันก่อนลบ)'
        : '${check.reason} แอปส่งให้รถเฉพาะคำสั่งอ่านค่า';
    onLog?.call('(ไม่ส่ง $command: $reason)');
    throw BlockedCommandException(command, reason);
  }

  /// ส่งคำสั่งดิบ คืนข้อความก่อนเครื่องหมาย '>'
  /// คำสั่งถูกต่อคิว จึงเรียกพร้อมกันจากหลายที่ได้อย่างปลอดภัย
  Future<String> send(String command, {Duration timeout = const Duration(seconds: 5)}) {
    if (_insideExclusive) return _sendNow(command, timeout);
    final result = Completer<String>();
    _queue = _queue.then((_) async {
      try {
        if (_needsReset) {
          await runZoned(resetTarget, zoneValues: {_exclusiveKey: true});
        }
        result.complete(await _sendNow(command, timeout));
      } catch (e, st) {
        result.completeError(e, st);
      }
    });
    return result.future;
  }

  /// รันชุดคำสั่งต่อเนื่องโดยไม่ให้คำสั่งจากที่อื่น (เช่นค่าสด) แทรกกลาง
  /// ใช้ตอนเปลี่ยน header ไปคุยกับกล่องอื่น
  Future<T> exclusive<T>(Future<T> Function() body) {
    if (_insideExclusive) return body();
    final result = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        result.complete(await runZoned(body, zoneValues: {_exclusiveKey: true}));
      } catch (e, st) {
        result.completeError(e, st);
      }
    });
    return result.future;
  }

  /// ส่งคำสั่ง ถ้าพบว่าตัวสแกนรีเซ็ตตัวเอง จะตั้งค่าใหม่แล้วส่งคำสั่งเดิมอีกครั้ง
  Future<String> _sendNow(String command, Duration timeout) async {
    if (_needsReinit && _ready) {
      _needsReinit = false;
      await _reapplySettings();
    }
    final r = await _transmit(command, timeout);
    if (_looksLikeReset(command, r)) {
      await _reapplySettings();
      return _transmit(command, timeout);
    }
    // คำสั่งก่อนหน้าหมดเวลา แล้วคำสั่งนี้ไปขัดจังหวะตัวสแกนที่ยังทำงานค้างอยู่ จึงได้ STOPPED
    // ตอนนี้ตัวสแกนว่างแล้ว ส่งคำสั่งเดิมซ้ำครั้งเดียว (ไม่ให้ STOPPED ถูกตีความว่าไม่มีข้อมูล)
    if (_wasInterrupted(command, r)) {
      onLog?.call('(คำสั่งถูกขัดจังหวะ ส่งใหม่)');
      return _transmit(command, timeout);
    }
    return r;
  }

  static bool _wasInterrupted(String command, String response) =>
      !command.toUpperCase().trim().startsWith('AT') && response.toUpperCase().contains('STOPPED');

  bool _looksLikeReset(String command, String response) {
    if (!_ready) return false;
    final c = command.toUpperCase().trim();
    // คำสั่งที่ตอบด้วยชื่อรุ่นตามปกติ
    if (c.startsWith('ATZ') || c.startsWith('ATWS') || c.startsWith('ATI') || c.startsWith('AT@') || c.startsWith('STI')) {
      return false;
    }
    if (_resetMarker.hasMatch(response)) return true;
    // echo กลับมาเปิดเอง (ATE0 หาย) แปลว่าตัวสแกนรีเซ็ตไปโดยไม่ได้แจ้ง
    return !c.startsWith('AT') && response.trimLeft().toUpperCase().startsWith(c);
  }

  /// ตั้งค่าใหม่หลังตัวสแกนรีเซ็ตตัวเอง และล็อกโปรโตคอลเดิมไว้ (ไม่ต้องค้นหาใหม่)
  Future<void> _reapplySettings() async {
    resetCount++;
    onLog?.call('ตัวสแกนรีเซ็ตตัวเอง (มักเกิดจากไฟตกตอนสตาร์ท) กำลังตั้งค่าใหม่');
    final proto = _fixedProtocol;
    for (final cmd in [...setupCommands, if (proto != null) 'ATSP$proto']) {
      try {
        await _transmit(cmd, const Duration(seconds: 3));
      } on ElmException {
        // ลองคำสั่งถัดไป
      }
    }
  }

  /// รหัสโปรโตคอลที่ใช้อยู่ เช่น "6" (ตัด "A" ที่แปลว่าเจอจากการค้นหาอัตโนมัติ)
  String? get _fixedProtocol {
    final p = (protocolCode ?? '').toUpperCase().trim();
    final code = p.startsWith('A') && p.length > 1 ? p.substring(1) : p;
    return code.isEmpty || code == '0' ? null : code;
  }

  Future<String> _transmit(String command, Duration timeout) async {
    _guard(command);
    if (_orphans > 0) {
      // รอคำตอบที่ค้างจากคำสั่งที่หมดเวลา ถ้าไม่มาภายใน 4 วินาทีถือว่าหายไปแล้ว
      // (ถ้าส่งคำสั่งใหม่เร็วเกินไป จะไปขัดจังหวะตัวสแกนที่ยังค้นหาอยู่)
      final d = _drained = Completer<void>();
      try {
        await d.future.timeout(const Duration(seconds: 4));
      } on TimeoutException {
        _orphans = 0;
      }
      _drained = null;
    }
    _buffer.clear();
    final c = Completer<String>();
    _pending = c;
    onLog?.call('> $command');
    try {
      await transport.write('$command\r'.codeUnits);
    } catch (e) {
      _pending = null;
      throw ElmException('ส่งคำสั่งไปตัวสแกนไม่ได้: $e');
    }
    try {
      final r = await c.future.timeout(timeout);
      final shown = r.trim();
      if (shown.isNotEmpty) onLog?.call(shown.replaceAll(RegExp(r'[\r\n]+'), ' | '));
      return r;
    } on TimeoutException {
      _pending = null;
      _orphans++;
      onLog?.call('(ไม่มีคำตอบภายใน ${timeout.inSeconds} วินาที)');
      throw ElmException('ตัวสแกนไม่ตอบคำสั่ง $command ภายใน ${timeout.inSeconds} วินาที');
    }
  }

  /// ส่งคำสั่ง OBD แล้วแยกคำตอบเป็นข้อความต่อ ECU
  Future<ParseResult> query(String command, {Duration timeout = const Duration(seconds: 5)}) async {
    final raw = await send(command, timeout: timeout);
    return ResponseParser.parse(raw, format: headerFormat);
  }

  static String _lastLine(String r) {
    final lines = r.trim().split(RegExp(r'[\r\n]+')).where((l) => l.trim().isNotEmpty).toList();
    return lines.isEmpty ? '' : lines.last.trim();
  }

  Future<bool> _ok(String cmd) async {
    try {
      return (await send(cmd)).toUpperCase().contains('OK');
    } on ElmException {
      return false;
    }
  }

  /// ลำดับเริ่มต้นตัวสแกน แล้วค้นหาโปรโตคอลของรถอัตโนมัติ
  /// ถ้าค้นหาอัตโนมัติไม่เจอ (ตัวก๊อปบางรุ่น) จะลองบังคับทีละโปรโตคอล
  Future<void> initialize({void Function(String step)? onStep}) async {
    _ready = false;
    _needsReinit = false;
    try {
      await send('ATZ', timeout: const Duration(seconds: 4));
    } on ElmException {
      // ตัวก๊อปบางรุ่นไม่ตอบ ATZ แต่ใช้งานได้ ลองต่อ
    }
    // ตัวสแกนบางรุ่นยังไม่พร้อมรับคำสั่งทันทีหลังรีเซ็ต
    await Future<void>.delayed(const Duration(milliseconds: 900));

    for (final cmd in [...setupCommands, 'ATSP0']) {
      if (!await _ok(cmd)) onLog?.call('คำเตือน: $cmd ไม่ตอบ OK');
    }

    version = _lastLine(await send('ATI'));
    adapter = await _detectAdapter(version!);

    // คำสั่งแรกจะทำให้ตัวสแกนค้นหาโปรโตคอล อาจใช้เวลานาน
    onStep?.call('กำลังค้นหาโปรโตคอลของรถ…');
    var first = await _probe(const Duration(seconds: 20));
    if (!_hasPid00(first) && !_isBusError(first)) {
      // ตัวก๊อปบางรุ่นค้นหาอัตโนมัติไม่เจอ ลองบังคับทีละโปรโตคอล
      // เริ่มจาก CAN 11 บิต 500k เพราะรถในไทยหลังปี 2008 เกือบทั้งหมดใช้แบบนี้
      for (final p in fallbackProtocols) {
        final name = protocolNames[p] ?? p;
        onStep?.call('ลองโปรโตคอล $name');
        onLog?.call('ลองโปรโตคอล $name');
        if (!await _ok('ATSP$p')) continue;
        final isCan = int.tryParse(p, radix: 16)! >= 6;
        final r = await _probe(Duration(seconds: isCan ? 4 : 9));
        if (_hasPid00(r)) {
          first = r;
          break;
        }
      }
    }
    if (!_hasPid00(first)) {
      await _ok('ATSP0'); // กลับไปค้นหาอัตโนมัติสำหรับครั้งหน้า
      if (_isBusError(first)) {
        throw ElmException('เกิดข้อผิดพลาดบนบัสสื่อสารของรถ ตรวจว่าเสียบตัวสแกนแน่น แล้วลองใหม่');
      }
      throw ElmException(
          'ตัวสแกนติดต่อกล่อง ECU ไม่ได้ ให้บิดกุญแจไปที่ ON หรือติดเครื่องยนต์แล้วลองใหม่ '
          '(ถ้ายังไม่ได้ รถอาจไม่รองรับ OBD-II หรือตัวสแกนเสีย)');
    }

    protocolCode = _lastLine(await send('ATDPN'));
    protocolName = _lastLine(await send('ATDP'));
    _ready = true;
  }

  /// ลำดับโปรโตคอลที่ลองเมื่อค้นหาอัตโนมัติไม่เจอ
  static const fallbackProtocols = ['6', '8', '7', '9', '5', '4', '3', '1', '2'];

  /// ส่ง 0100 แล้วคืนคำตอบ (null ถ้าไม่ตอบภายในเวลา)
  Future<String?> _probe(Duration timeout) async {
    try {
      return await send('0100', timeout: timeout);
    } on ElmException {
      return null;
    }
  }

  static bool _hasPid00(String? r) => r != null && r.toUpperCase().replaceAll(RegExp(r'\s'), '').contains('4100');

  static bool _isBusError(String? r) {
    final u = (r ?? '').toUpperCase();
    return u.contains('CAN ERROR') || u.contains('BUS ERROR');
  }

  Future<AdapterInfo> _detectAdapter(String ver) async {
    String? stn;
    String? desc;
    try {
      final r = _lastLine(await send('STI', timeout: const Duration(seconds: 2)));
      if (r.toUpperCase().contains('STN')) stn = r;
    } on ElmException {
      stn = null;
    }
    try {
      final r = _lastLine(await send('AT@1', timeout: const Duration(seconds: 2)));
      if (r.isNotEmpty && r != '?') desc = r;
    } on ElmException {
      desc = null;
    }
    // ตั้ง flow control กลับค่าเริ่มต้น ถ้าตอบ OK แปลว่ารองรับคำสั่งกลุ่ม ATFC
    final fc = await _ok('ATFCSM0');

    final AdapterKind kind;
    final v = ver.toUpperCase();
    if (stn != null) {
      kind = AdapterKind.stn;
    } else if (v.contains('SIM')) {
      kind = AdapterKind.simulator;
    } else if (v.contains('ELM327')) {
      // ELM Electronics ไม่เคยออกรุ่น v1.5 และ v2.1 เป็นรุ่นที่ถูกก๊อปมากที่สุด
      final suspicious = v.contains('V1.5') || v.contains('V2.1') || !fc;
      kind = suspicious ? AdapterKind.elmClone : AdapterKind.elmGenuine;
    } else {
      kind = AdapterKind.unknown;
    }
    return AdapterInfo(kind: kind, version: ver, stnVersion: stn, description: desc, flowControl: fc);
  }

  /// แรงดันไฟที่ขา 16 ของช่อง OBD (เท่ากับแรงดันแบตเตอรี่โดยประมาณ)
  Future<double?> readVoltage() async {
    final r = await send('ATRV', timeout: const Duration(seconds: 2));
    final m = RegExp(r'(\d+(?:\.\d+)?)\s*V', caseSensitive: false).firstMatch(r);
    return m == null ? null : double.tryParse(m.group(1)!);
  }

  // ---------------- คุยกับกล่องเฉพาะตัว (physical addressing) ----------------

  /// ตั้ง header ปลายทาง ตัวกรองคำตอบ และ flow control ให้คุยกับกล่องที่ [tx]
  /// ต้องเรียกภายใน [exclusive] เท่านั้น
  Future<void> setTarget(String tx, String rx) async {
    await _setHeader(tx);
    await send('ATCRA$rx');
    if (adapter?.flowControl ?? false) {
      await send('ATFCSH$tx');
      await send('ATFCSD300000');
      await send('ATFCSM1');
    }
  }

  /// กลับไปใช้ header มาตรฐานของ OBD-II
  /// ทุกคำสั่งลองแยกกัน ถ้าบางคำสั่งล้มเหลว จะลองใหม่ก่อนคำสั่ง OBD ถัดไป
  /// (ไม่ให้ตัวสแกนค้าง header ไว้ที่กล่องอื่นแล้วอ่านค่าผิดกล่องโดยไม่รู้ตัว)
  Future<void> resetTarget() async {
    var ok = true;
    for (final cmd in [
      'ATCRA',
      if (adapter?.flowControl ?? false) 'ATFCSM0',
      'ATSH$functionalHeader',
      'ATST32',
    ]) {
      try {
        if (cmd.startsWith('ATSH')) {
          await _setHeader(functionalHeader);
        } else {
          await send(cmd);
        }
      } on ElmException {
        ok = false;
      }
    }
    _needsReset = !ok;
  }

  bool _needsReset = false;

  /// ตั้ง header ส่งคำสั่ง ชิปรุ่นเก่า/ตัวก๊อปบางรุ่นไม่รับ header 29 บิตแบบ 4 ไบต์ในคำสั่งเดียว
  /// (ตอบ "?") จึงตั้งแบบเดิม: ไบต์แรก (priority) ด้วย ATCP แล้วอีก 3 ไบต์ด้วย ATSH
  Future<void> _setHeader(String h) async {
    final r = await send('ATSH$h');
    if (h.length == 8 && r.contains('?')) {
      onLog?.call('ตัวสแกนไม่รับ header 4 ไบต์ ตั้งแบบ ATCP + 3 ไบต์แทน');
      await send('ATCP${h.substring(0, 2)}');
      await send('ATSH${h.substring(2)}');
    }
  }

  /// ตั้งเวลารอคำตอบ (หน่วยมิลลิวินาที ละเอียด 4 ms)
  Future<void> setResponseTimeout(int ms) async {
    final v = (ms / 4).round().clamp(1, 255);
    await send('ATST${v.toRadixString(16).padLeft(2, '0').toUpperCase()}');
  }

  static const protocolNames = <String, String>{
    '1': 'SAE J1850 PWM',
    '2': 'SAE J1850 VPW',
    '3': 'ISO 9141-2',
    '4': 'ISO 14230-4 KWP (5 baud init)',
    '5': 'ISO 14230-4 KWP (fast init)',
    '6': 'ISO 15765-4 CAN (11 bit, 500 kbps)',
    '7': 'ISO 15765-4 CAN (29 bit, 500 kbps)',
    '8': 'ISO 15765-4 CAN (11 bit, 250 kbps)',
    '9': 'ISO 15765-4 CAN (29 bit, 250 kbps)',
    'A': 'SAE J1939 CAN (29 bit, 250 kbps)',
  };

  String get protocolLabel {
    final p = (protocolCode ?? '').toUpperCase();
    final code = p.startsWith('A') && p.length > 1 ? p.substring(1) : p;
    return protocolNames[code] ?? protocolName ?? 'ไม่ทราบ';
  }
}
