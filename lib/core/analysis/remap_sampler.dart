import '../elm/elm327.dart';
import '../obd/dtc.dart';
import '../obd/ext_pid.dart';
import '../obd/obd_service.dart';
import '../obd/pids.dart';
import 'remap_test.dart';

/// ค่าเฉพาะยี่ห้อที่ใช้ในการทดสอบรีแมพ พร้อมวิธีแปลงหน่วยให้ตรงกับชนิดของค่า
class RemapExtChannel {
  const RemapExtChannel(this.pid, this.signal, {this.factor = 1, this.offset = 0});

  final ExtPid pid;
  final RemapSignal signal;
  final double factor;
  final double offset;

  double convert(double v) => v * factor + offset;

  String get key => 'ext:${pid.key}';

  RemapChannel get channel => RemapChannel(
        key: key,
        name: pid.name,
        unit: signal == RemapSignal.other ? pid.unit : signal.unit,
        signal: signal,
        decimals: signal == RemapSignal.other ? pid.decimals : signal.decimals,
      );
}

double? _toKpa(String u) => switch (u) {
      'kpa' => 1,
      'bar' => 100,
      'mbar' || 'hpa' => 0.1,
      'psi' => 6.89476,
      'mpa' => 1000,
      _ => null,
    };

/// เดาจากชื่อ (อังกฤษ/ไทย) และหน่วยว่าค่าเฉพาะยี่ห้อนี้คือค่าอะไรในการทดสอบรีแมพ
/// คืน null ถ้าไม่เกี่ยว (เช่น แรงดันไฟเซนเซอร์ ค่าสถานะ) หรือแปลงหน่วยไม่ได้
RemapExtChannel? classifyRemapExt(ExtPid p) {
  // ค่าที่ใช้คำสั่งต้องห้าม (ไม่ใช่คำสั่งอ่าน) ไม่ให้เลือกมาอ่านระหว่างขับ
  if (p.safetyBlock != null) return null;
  final en = (p.en ?? '').toLowerCase();
  final th = p.name;
  final unit = p.unit.trim().toLowerCase();
  bool hasEn(List<String> w) => w.any(en.contains);
  bool hasTh(List<String> w) => w.any(th.contains);
  if (p.isState || unit == 'v' || unit == '%' || hasEn(['voltage', 'volt']) ||
      hasTh(['แรงดันไฟ', 'แรงดันเซนเซอร์', 'แรงดันเซ็นเซอร์'])) {
    return null;
  }
  final desired = hasEn(['desired', 'target', 'commanded', 'request']) || hasTh(['ต้องการ', 'เป้าหมาย']);

  if (hasEn(['exhaust gas temp', 'egt']) || hasTh(['อุณหภูมิไอเสีย'])) {
    if (unit == '°f' || unit == 'f') return RemapExtChannel(p, RemapSignal.egt, factor: 5 / 9, offset: -32 * 5 / 9);
    if (unit == '°c' || unit == 'c') return RemapExtChannel(p, RemapSignal.egt);
    return null;
  }
  final injection = (en.contains('inject') && hasEn(['quantity', 'volume', 'amount', 'qty'])) || th.contains('ปริมาณฉีด');
  if (injection) {
    // ใช้เฉพาะปริมาณฉีดรวมต่อจังหวะ ไม่เอาค่ารายสูบ ค่าที่มีเลขลำดับ ค่าสะสม หรือการฉีดย่อย (นำ/หลัง)
    const okUnits = {'', 'mm³', 'mm3', 'mm³/st', 'mm3/st', 'mm³/stk', 'mg/st', 'mg/stk', 'mg'};
    if (!okUnits.contains(unit) ||
        hasEn(['pilot', 'post', 'after', 'learning', 'startup', 'smoke', 'correction', 'cylinder', 'per 10', 'control']) ||
        hasTh(['นำ', 'หลัง (', 'ตาม (', 'เรียนรู้', 'สตาร์ท', 'จำกัด', 'ชดเชย', 'สูบ', 'ต่อ 10', 'ควบคุม']) ||
        _endsWithNumber.hasMatch(en.trim()) ||
        _endsWithNumber.hasMatch(th.trim())) {
      return null;
    }
    return RemapExtChannel(p, RemapSignal.injQty);
  }
  if ((en.contains('boost') && !en.contains('booster')) || (th.contains('บูสต์') && !th.contains('หม้อลม'))) {
    final f = _toKpa(unit);
    if (f == null) return null;
    return RemapExtChannel(p, desired ? RemapSignal.boostCmd : RemapSignal.boost, factor: f);
  }
  final railLike = hasEn(['rail', 'high fuel pressure', 'high pressure fuel']) || th.contains('ราง');
  if (railLike && !hasEn(['low side', 'low pressure', 'low desired']) && !th.contains('ต่ำ')) {
    final f = _toKpa(unit);
    if (f == null) return null;
    return RemapExtChannel(p, desired ? RemapSignal.railCmd : RemapSignal.rail, factor: f / 1000);
  }
  return null;
}

final _endsWithNumber = RegExp(r'\s\d+$');

/// ลำดับความเหมาะสม (น้อย = ดีกว่า): ค่าที่ร้านยืนยัน/พบในรถจริงก่อน ชื่อทั่วไปก่อนชื่อที่มีเลขลำดับหรือจุดวัดหลังอุปกรณ์
int remapExtRank(RemapExtChannel c) {
  final p = c.pid;
  final en = (p.en ?? '').toLowerCase();
  var r = (2 - p.trust) * 100;
  if (RegExp(r'\d').hasMatch(en.isEmpty ? p.name : en)) r += 20;
  if (en.contains('after') || p.name.contains('หลัง')) r += 10;
  return r + p.name.length;
}

/// คัดค่าเฉพาะยี่ห้อที่จะเสนอให้เลือก: ชนิดละไม่เกิน [perSignal] ตัว (ตัวที่เหมาะที่สุดก่อน)
/// เรียงตามความสำคัญในการทดสอบรีแมพ: บูสต์/รางที่ต้องการ → บูสต์/รางจริง → ปริมาณฉีด → ไอเสีย
List<RemapExtChannel> pickRemapExt(Iterable<RemapExtChannel> all, {int perSignal = 2}) {
  const order = [
    RemapSignal.boostCmd,
    RemapSignal.railCmd,
    RemapSignal.boost,
    RemapSignal.rail,
    RemapSignal.injQty,
    RemapSignal.egt,
  ];
  final out = <RemapExtChannel>[];
  for (final s in order) {
    final group = all.where((c) => c.signal == s).toList()..sort((a, b) => remapExtRank(a).compareTo(remapExtRank(b)));
    out.addAll(group.take(perSignal));
  }
  return out;
}

/// ค่าที่อ่านได้จากคำสั่งหนึ่งครั้ง (เวลา = กึ่งกลางระหว่างส่งคำสั่งกับได้คำตอบ)
typedef RemapEmit = void Function(double t, Map<String, double> values);

/// ตัวอ่านค่าระหว่างทดสอบรีแมพ: อ่านความเร็ว/รอบเครื่องทุกรอบ ค่าอื่นสลับกันอ่าน
/// รถ CAN อ่านหลาย PID ในคำสั่งเดียว (ISO 15765-4 กำหนดให้กล่องรองรับ) ได้อัตราสูงกว่าอ่านทีละตัวมาก
/// อ่านอย่างเดียว ไม่มีคำสั่งเขียน/ลบใดๆ
class RemapSampler {
  RemapSampler(this.svc, {required this.clock, List<RemapExtChannel> ext = const [], this.extEvery = 4, this.useMultiPid = true})
      : ext = List.unmodifiable(ext);

  final ObdService svc;

  /// วินาทีนับจากเริ่มทดสอบ
  final double Function() clock;
  final List<RemapExtChannel> ext;

  /// อ่านค่าเฉพาะยี่ห้อทุกกี่รอบ (ต้องเปลี่ยน header ไปกล่องเฉพาะ ช้ากว่าค่ามาตรฐาน)
  final int extEvery;
  final bool useMultiPid;

  final channels = <RemapChannel>[];
  bool multiPid = false;
  bool turbo = false;

  /// จำนวนคำสั่งที่ส่งไปแล้ว (ใช้คำนวณอัตราการอ่าน)
  int requests = 0;

  /// สถานะไฟเตือนล่าสุด (อ่าน PID 01 เป็นระยะ)
  bool? milOn;
  int? dtcCount;

  final _hot = <int>[];
  final _cold = <int>[];
  int _hotI = 0, _coldI = 0;
  int _step = 0;
  bool _has70 = false, _has6D = false, _has78 = false;
  final _extSkip = <String>{};
  final _convert = <int, double Function(double)>{};

  static String stdKey(int pid) => 'std:${pid.toRadixString(16).padLeft(2, '0').toUpperCase()}';

  static const boostCmdKey = 'std:70c';
  static const boostActKey = 'std:70a';
  static const railCmdKey = 'std:6Dc';
  static const railActKey = 'std:6Da';

  bool _sup(int pid) => svc.supported.contains(pid);

  /// เลือกค่าที่จะอ่านจาก PID ที่รถรองรับ และลองว่ารถตอบคำสั่งหลาย PID ได้ไหม
  Future<void> init({bool diesel = false, bool refreshSupported = true}) async {
    if (refreshSupported) {
      final before = svc.supported;
      try {
        final r = await svc.loadSupportedPids();
        if (r.isEmpty) svc.supported = before;
      } on ElmException {
        svc.supported = before;
      }
    }
    channels.clear();
    _hot.clear();
    _cold.clear();
    _convert.clear();
    _has70 = _sup(Pid.boost);
    _has6D = _sup(0x6D);
    _has78 = _sup(Pid.egtB1);

    RemapChannel std(int pid, RemapSignal s, {String? unit, int? decimals}) {
      final def = pidTable[pid];
      return RemapChannel(
        key: stdKey(pid),
        name: def?.nameTh ?? s.labelTh,
        unit: unit ?? def?.unit ?? s.unit,
        signal: s,
        decimals: decimals ?? def?.decimals ?? s.decimals,
      );
    }

    channels.add(std(Pid.speed, RemapSignal.speed));
    channels.add(std(Pid.rpm, RemapSignal.rpm));
    final pedal = [Pid.relativePedal, Pid.pedalD, Pid.pedalE, Pid.throttle].where(_sup).firstOrNull;
    if (pedal != null) {
      channels.add(std(pedal, RemapSignal.pedal));
      _hot.add(pedal);
    }
    if (_sup(Pid.engineLoad)) {
      channels.add(std(Pid.engineLoad, RemapSignal.load));
      _hot.add(Pid.engineLoad);
    }
    if (_has70) {
      channels.add(const RemapChannel(key: boostActKey, name: 'บูสต์จริง (PID 70)', unit: 'kPa', signal: RemapSignal.boost, decimals: 0));
      channels.add(const RemapChannel(key: boostCmdKey, name: 'บูสต์ที่ต้องการ (PID 70)', unit: 'kPa', signal: RemapSignal.boostCmd, decimals: 0));
    } else if (_sup(Pid.map)) {
      channels.add(std(Pid.map, RemapSignal.boost));
      _hot.add(Pid.map);
    }
    if (_has6D) {
      channels.add(const RemapChannel(key: railActKey, name: 'ความดันรางจริง (PID 6D)', unit: 'MPa', signal: RemapSignal.rail, decimals: 1));
      channels.add(const RemapChannel(key: railCmdKey, name: 'ความดันรางที่ต้องการ (PID 6D)', unit: 'MPa', signal: RemapSignal.railCmd, decimals: 1));
    } else {
      final rail = [Pid.fuelRailPressure, Pid.fuelRailAbs].where(_sup).firstOrNull;
      if (rail != null) {
        channels.add(std(rail, RemapSignal.rail, unit: 'MPa', decimals: 1));
        _convert[rail] = (kpa) => kpa / 1000;
        _hot.add(rail);
      }
    }
    if (_sup(Pid.maf)) {
      channels.add(std(Pid.maf, RemapSignal.maf));
      _hot.add(Pid.maf);
    }
    if (_has78) channels.add(std(Pid.egtB1, RemapSignal.egt));
    for (final (pid, s) in [
      (Pid.coolantTemp, RemapSignal.coolant),
      (Pid.intakeTemp, RemapSignal.iat),
      (Pid.baro, RemapSignal.baro),
      (Pid.fuelRate, RemapSignal.fuelRate),
      (Pid.moduleVoltage, RemapSignal.voltage),
    ]) {
      if (!_sup(pid)) continue;
      channels.add(std(pid, s));
      _cold.add(pid);
    }
    for (final e in ext) {
      channels.add(e.channel);
    }
    turbo = diesel || _has70 || ext.any((e) => e.signal == RemapSignal.boostCmd);

    multiPid = false;
    if (useMultiPid && svc.elm.isCan) {
      final probe = <int>{Pid.speed, Pid.rpm, ..._hot.take(3), ..._cold.take(1)}.where(_sup).take(6).toList();
      try {
        final r = await svc.readPidsMultiRaw(probe);
        multiPid = probe.length > 1 && probe.every(r.containsKey);
      } on ElmException {
        multiPid = false;
      }
      svc.multiPidOk = multiPid;
    }
  }

  List<int> _take(List<int> list, int n, bool hot) {
    final out = <int>[];
    for (var i = 0; i < n && list.isNotEmpty; i++) {
      final pid = hot ? list[_hotI++ % list.length] : list[_coldI++ % list.length];
      if (!out.contains(pid)) out.add(pid);
    }
    return out;
  }

  double _std(int pid, double v) => _convert[pid]?.call(v) ?? v;

  Future<void> _timed(Future<Map<String, double>> Function() read, RemapEmit emit) async {
    final t0 = clock();
    final v = await read();
    final t1 = clock();
    requests++;
    if (v.isNotEmpty) emit((t0 + t1) / 2, v);
  }

  Future<Map<String, double>> _single(int pid) async {
    final v = await svc.readPid(pid);
    return v == null ? const {} : {stdKey(pid): _std(pid, v)};
  }

  int _w(List<int> d, int i) => d[i] * 256 + d[i + 1];

  /// อ่านหนึ่งรอบ ส่งค่าที่ได้ออกทาง [emit] ทีละคำสั่ง
  Future<void> step(RemapEmit emit) async {
    final k = _step++;
    if (multiPid) {
      final batch = <int>[Pid.speed, Pid.rpm, ..._take(_hot, 3, true), if (k.isEven) ..._take(_cold, 1, false)];
      await _timed(() async {
        final v = await svc.readPidsMulti(batch);
        return {for (final e in v.entries) stdKey(e.key): _std(e.key, e.value)};
      }, emit);
    } else {
      await _timed(() => _single(Pid.speed), emit);
      await _timed(() => _single(Pid.rpm), emit);
      for (final pid in _take(_hot, 1, true)) {
        await _timed(() => _single(pid), emit);
      }
      if (k % 3 == 0) {
        for (final pid in _take(_cold, 1, false)) {
          await _timed(() => _single(pid), emit);
        }
      }
    }

    // ค่าที่ต้องการกับค่าจริงมาในคำตอบเดียวกัน จึงเทียบกันได้ตรงเวลา
    final alternate = !multiPid && _has70 && _has6D;
    if (_has70 && (!alternate || k.isEven)) {
      await _timed(() async {
        final d = await svc.readPidRaw(Pid.boost);
        if (d == null || d.length < 5) return const {};
        final bits = d[0];
        return {
          if (bits & 0x01 != 0 || bits == 0) boostCmdKey: _w(d, 1) * 0.03125,
          if (bits & 0x02 != 0 || bits == 0) boostActKey: _w(d, 3) * 0.03125,
        };
      }, emit);
    }
    if (_has6D && (!alternate || k.isOdd)) {
      await _timed(() async {
        final d = await svc.readPidRaw(0x6D);
        if (d == null || d.length < 5) return const {};
        final bits = d[0];
        return {
          if (bits & 0x01 != 0 || bits == 0) railCmdKey: _w(d, 1) * 10 / 1000,
          if (bits & 0x02 != 0 || bits == 0) railActKey: _w(d, 3) * 10 / 1000,
        };
      }, emit);
    }
    if (_has78 && k % 4 == 2) await _timed(() => _single(Pid.egtB1), emit);

    if (ext.isNotEmpty && k % extEvery == extEvery - 1) {
      await _timed(() async {
        final r = await ExtPidReader(svc.elm, skip: _extSkip).readAll([for (final e in ext) e.pid]);
        return {
          for (final e in ext)
            if (r[e.pid.key]?.value case final v? when r[e.pid.key]!.ok) e.key: e.convert(v),
        };
      }, emit);
    }

    if (k % 25 == 10) {
      final s = await svc.readMonitorStatus();
      requests++;
      if (s != null) {
        milOn = s.milOn;
        dtcCount = s.dtcCount;
      }
    }
  }
}

/// รหัสปัญหาในกล่องเครื่องยนต์ (ยืนยันแล้ว + รอยืนยัน) และสถานะไฟเตือน อ่านอย่างเดียว
Future<(List<String>, bool?)> readRemapDtcs(ObdService svc) async {
  final codes = <String>[];
  for (final kind in [DtcKind.stored, DtcKind.pending]) {
    for (final d in await svc.readDtcs(kind)) {
      if (!codes.contains(d.code)) codes.add(d.code);
    }
  }
  final s = await svc.readMonitorStatus();
  return (codes, s?.milOn);
}
