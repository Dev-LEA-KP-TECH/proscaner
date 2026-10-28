/// ทดสอบขับก่อน/หลังรีแมพ: บันทึกค่าขณะทดสอบ วิเคราะห์ แล้วเทียบสองรอบ
///
/// ทุกอย่างในไฟล์นี้เป็นตรรกะล้วน (ไม่แตะรถ ไม่แตะหน้าจอ) จึงทดสอบด้วยข้อมูลสังเคราะห์ได้
library;

import 'dart:convert';
import 'dart:math' as math;

/// ชนิดของค่าที่บันทึก ใช้ตัดสินว่าจะนำไปวิเคราะห์อะไร
enum RemapSignal {
  speed('ความเร็วรถ', 'กม./ชม.', 0),
  rpm('รอบเครื่อง', 'รอบ/นาที', 0),
  load('ภาระเครื่องยนต์', '%', 0),
  pedal('คันเร่ง', '%', 0),
  coolant('อุณหภูมิน้ำหล่อเย็น', '°C', 0),
  iat('อุณหภูมิอากาศเข้า', '°C', 0),
  egt('อุณหภูมิไอเสีย', '°C', 0),
  maf('มวลอากาศ (MAF)', 'g/s', 1),
  baro('ความดันบรรยากาศ', 'kPa', 0),
  boost('ความดันบูสต์ (สัมบูรณ์)', 'kPa', 0),
  boostCmd('บูสต์ที่ต้องการ (สัมบูรณ์)', 'kPa', 0),
  rail('ความดันราง', 'MPa', 1),
  railCmd('ความดันรางที่ต้องการ', 'MPa', 1),
  injQty('ปริมาณฉีด', 'mm³', 1),
  fuelRate('อัตราการใช้น้ำมัน', 'ลิตร/ชม.', 1),
  voltage('แรงดันไฟ', 'V', 1),
  other('', '', 1);

  const RemapSignal(this.labelTh, this.unit, this.decimals);
  final String labelTh;
  final String unit;
  final int decimals;
}

/// รอบทดสอบนี้วัดเมื่อไร (ใช้จับคู่เทียบก่อน/หลัง)
enum RemapStage {
  before('ก่อนรีแมพ'),
  after('หลังรีแมพ'),
  other('ทดสอบทั่วไป');

  const RemapStage(this.labelTh);
  final String labelTh;
}

/// ค่าหนึ่งตัวที่บันทึก (คอลัมน์ของตาราง)
class RemapChannel {
  const RemapChannel({
    required this.key,
    required this.name,
    required this.unit,
    required this.signal,
    this.decimals = 1,
  });

  /// 'std:0D' = PID มาตรฐาน, 'std:70c'/'std:70a' = บูสต์ที่ต้องการ/จริงจาก PID 70,
  /// 'std:6Dc'/'std:6Da' = ความดันรางที่ต้องการ/จริงจาก PID 6D, 'ext:…' = ค่าเฉพาะยี่ห้อ
  final String key;
  final String name;
  final String unit;
  final RemapSignal signal;
  final int decimals;

  Map<String, dynamic> toJson() => {'k': key, 'n': name, 'u': unit, 's': signal.name, 'd': decimals};

  factory RemapChannel.fromJson(Map<String, dynamic> j) => RemapChannel(
        key: j['k'] as String,
        name: j['n'] as String? ?? '',
        unit: j['u'] as String? ?? '',
        signal: RemapSignal.values.asNameMap()[j['s']] ?? RemapSignal.other,
        decimals: (j['d'] as num?)?.toInt() ?? 1,
      );
}

/// การทดสอบหนึ่งรอบ
class RemapRun {
  RemapRun({
    required this.id,
    required this.name,
    required this.stage,
    required this.start,
    required this.channels,
    List<double>? times,
    List<List<double?>>? rows,
    this.vin,
    this.vehicleId,
    this.vehicleLabel = '',
    List<String>? dtcBefore,
    List<String>? dtcAfter,
    this.milBefore,
    this.milAfter,
    this.turbo = false,
    this.hz = 0,
    this.multiPid = false,
    this.note = '',
    this.appVersion = '',
  })  : times = times ?? [],
        rows = rows ?? [],
        dtcBefore = dtcBefore ?? [],
        dtcAfter = dtcAfter ?? [];

  final String id;
  String name;
  RemapStage stage;
  final DateTime start;
  final String? vin;
  final String? vehicleId;
  final String vehicleLabel;
  final List<RemapChannel> channels;

  /// เวลาของแต่ละแถว (วินาทีนับจากเริ่ม) แถวหนึ่ง = คำตอบของคำสั่งหนึ่งครั้ง จึงมีค่าไม่ครบทุกคอลัมน์
  final List<double> times;
  final List<List<double?>> rows;

  /// รหัสปัญหา (ยืนยันแล้วและรอยืนยัน) ก่อนและหลังทดสอบ
  final List<String> dtcBefore;
  final List<String> dtcAfter;
  final bool? milBefore;
  bool? milAfter;

  /// รถมีเทอร์โบ (ดีเซล หรือกล่องรายงานบูสต์ที่ต้องการ) ใช้ตัดสินว่า "เหยียบสุดแต่บูสต์ไม่ขึ้น" ผิดปกติหรือไม่
  final bool turbo;

  /// อัตราการอ่าน (คำสั่งต่อวินาที) และอ่านแบบหลาย PID ต่อคำสั่งได้หรือไม่
  double hz;
  bool multiPid;
  String note;
  final String appVersion;

  double get durationS => times.isEmpty ? 0 : times.last;

  /// เพิ่มหนึ่งแถว (ค่าที่อ่านได้จากคำสั่งหนึ่งครั้ง)
  void add(double t, Map<String, double> values) {
    if (values.isEmpty) return;
    times.add(t);
    rows.add([for (final c in channels) values[c.key]]);
  }

  int indexOf(String key) => channels.indexWhere((c) => c.key == key);

  /// ค่าของคอลัมน์หนึ่ง คู่กับเวลา
  List<(double, double)> series(String key) {
    final c = indexOf(key);
    if (c < 0) return const [];
    return [
      for (var i = 0; i < rows.length; i++)
        if (rows[i][c] != null) (times[i], rows[i][c]!),
    ];
  }

  /// คอลัมน์แรกของชนิดที่ต้องการที่มีข้อมูล (ถ้ามี)
  RemapChannel? channelOf(RemapSignal s) {
    for (final c in channels) {
      if (c.signal != s) continue;
      final i = indexOf(c.key);
      if (rows.any((r) => r[i] != null)) return c;
    }
    return null;
  }

  /// ค่าของชนิดที่ต้องการ: ใช้คอลัมน์แรกของชนิดนั้นที่มีข้อมูล
  List<(double, double)> signal(RemapSignal s) {
    final c = channelOf(s);
    return c == null ? const [] : series(c.key);
  }

  /// ค่าล่าสุดของชนิดที่ต้องการ (ใช้แสดงระหว่างทดสอบ)
  double? latest(RemapSignal s) {
    for (final c in channels) {
      if (c.signal != s) continue;
      final i = indexOf(c.key);
      for (var r = rows.length - 1; r >= 0 && r >= rows.length - 60; r--) {
        final v = rows[r][i];
        if (v != null) return v;
      }
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'proscaner_remap': 1,
        'id': id,
        'name': name,
        'stage': stage.name,
        'start': start.toIso8601String(),
        if (vin != null) 'vin': vin,
        if (vehicleId != null) 'vehicleId': vehicleId,
        'vehicle': vehicleLabel,
        'channels': [for (final c in channels) c.toJson()],
        'times': [for (final t in times) _round(t, 3)],
        'rows': [
          for (final r in rows) [for (final v in r) v == null ? null : _round(v, 4)],
        ],
        'dtcBefore': dtcBefore,
        'dtcAfter': dtcAfter,
        if (milBefore != null) 'milBefore': milBefore,
        if (milAfter != null) 'milAfter': milAfter,
        'turbo': turbo,
        'hz': _round(hz, 2),
        'multiPid': multiPid,
        'note': note,
        'app': appVersion,
      };

  String encode() => jsonEncode(toJson());

  factory RemapRun.fromJson(Map<String, dynamic> j) {
    final channels = [
      for (final c in (j['channels'] as List<dynamic>? ?? const [])) RemapChannel.fromJson(c as Map<String, dynamic>),
    ];
    final times = [for (final t in (j['times'] as List<dynamic>? ?? const [])) (t as num).toDouble()];
    final rows = <List<double?>>[
      for (final r in (j['rows'] as List<dynamic>? ?? const []))
        [
          for (var i = 0; i < channels.length; i++)
            i < (r as List<dynamic>).length && r[i] != null ? (r[i] as num).toDouble() : null,
        ],
    ];
    // ไฟล์เสียบางส่วน: ใช้เฉพาะแถวที่มีทั้งเวลาและค่า
    final n = math.min(times.length, rows.length);
    return RemapRun(
      id: j['id'] as String,
      name: j['name'] as String? ?? '',
      stage: RemapStage.values.asNameMap()[j['stage']] ?? RemapStage.other,
      start: DateTime.tryParse(j['start'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
      vin: j['vin'] as String?,
      vehicleId: j['vehicleId'] as String?,
      vehicleLabel: j['vehicle'] as String? ?? '',
      channels: channels,
      times: times.sublist(0, n),
      rows: rows.sublist(0, n),
      dtcBefore: [for (final d in (j['dtcBefore'] as List<dynamic>? ?? const [])) '$d'],
      dtcAfter: [for (final d in (j['dtcAfter'] as List<dynamic>? ?? const [])) '$d'],
      milBefore: j['milBefore'] as bool?,
      milAfter: j['milAfter'] as bool?,
      turbo: j['turbo'] as bool? ?? false,
      hz: (j['hz'] as num?)?.toDouble() ?? 0,
      multiPid: j['multiPid'] as bool? ?? false,
      note: j['note'] as String? ?? '',
      appVersion: j['app'] as String? ?? '',
    );
  }

  static RemapRun decode(String s) => RemapRun.fromJson(jsonDecode(s) as Map<String, dynamic>);

  /// ตารางสำหรับเปิดใน Excel (ช่องว่าง = ไม่ได้อ่านค่านั้นในแถวนั้น)
  String toCsv() {
    String clean(String s) => s.replaceAll(RegExp(r'[\r\n,]'), ' ');
    final b = StringBuffer()
      ..writeln('# ProScaner remap test')
      ..writeln('# name=${clean(name)}')
      ..writeln('# stage=${stage.labelTh}')
      ..writeln('# start=${start.toIso8601String()}')
      ..writeln('# vehicle=${clean(vehicleLabel)}')
      ..writeln(['time_s', for (final c in channels) clean('${c.name} (${c.unit})')].join(','));
    for (var i = 0; i < rows.length; i++) {
      b.writeln([
        times[i].toStringAsFixed(2),
        for (var c = 0; c < channels.length; c++)
          rows[i][c] == null ? '' : rows[i][c]!.toStringAsFixed(channels[c].decimals + 1),
      ].join(','));
    }
    return b.toString();
  }
}

double _round(double v, int d) {
  final p = math.pow(10, d).toDouble();
  return (v * p).roundToDouble() / p;
}

// ---------------------------------------------------------------- วิเคราะห์

/// เกณฑ์ที่ใช้ตัดสินว่าผิดปกติ (ค่าเริ่มต้นเหมาะกับกระบะดีเซลเทอร์โบ)
class RemapLimits {
  const RemapLimits({
    this.overboostKpa = 15,
    this.overboostPct = 10,
    this.underboostKpa = 20,
    this.underboostPct = 15,
    this.boostRequestKpa = 30,
    this.boostCapGauge = 0,
    this.railDevMpa = 5,
    this.railDevPct = 10,
    this.railMinMpa = 20,
    this.coolantMax = 105,
    this.iatMax = 70,
    this.egtMax = 750,
    this.minEventS = 1.0,
    this.minHotS = 2.0,
    this.settleS = 1.5,
  });

  /// บูสต์จริงเกินที่ต้องการ: มากกว่า [overboostKpa] หรือ [overboostPct]% ของค่าที่ต้องการ (เอาค่าที่มากกว่า)
  final double overboostKpa;
  final double overboostPct;

  /// บูสต์ไม่ถึง: ต่ำกว่าที่ต้องการเกิน [underboostKpa] หรือ [underboostPct]% ตอนที่กล่องขอบูสต์อย่างน้อย [boostRequestKpa] (เกจ)
  final double underboostKpa;
  final double underboostPct;
  final double boostRequestKpa;

  /// บูสต์สูงสุดที่ยอมรับแบบเกจ (0 = ไม่ตรวจ) ใช้กับรถที่กล่องไม่บอกบูสต์ที่ต้องการ
  final double boostCapGauge;

  /// ความดันรางต่างจากที่ต้องการเกิน [railDevMpa] หรือ [railDevPct]% (เมื่อค่าที่ต้องการไม่ต่ำกว่า [railMinMpa])
  final double railDevMpa;
  final double railDevPct;
  final double railMinMpa;

  final double coolantMax;
  final double iatMax;
  final double egtMax;

  /// ต้องเป็นต่อเนื่องอย่างน้อยกี่วินาทีจึงนับ (กันค่ากระชากชั่วขณะ)
  final double minEventS;
  final double minHotS;

  /// บูสต์ที่ต้องการต้องนิ่ง (แกว่งไม่เกิน 15 kPa หรือ 8% ตลอดช่วง) นานเท่านี้ก่อนจึงเทียบกับบูสต์จริง
  final double settleS;
}

enum RemapEventKind {
  overboost('บูสต์เกินค่าที่กล่องต้องการ'),
  boostCap('บูสต์เกินค่าสูงสุดที่ตั้งไว้'),
  underboost('บูสต์ไม่ถึงค่าที่กล่องต้องการ'),
  railHigh('ความดันรางสูงเกินที่ต้องการ'),
  railLow('ความดันรางไม่ถึงที่ต้องการ'),
  noBoostFullPedal('เหยียบคันเร่งเกือบสุดแต่บูสต์ไม่ขึ้น'),
  coolantHot('ความร้อนน้ำหล่อเย็นสูง'),
  iatHot('อากาศเข้าร้อนเกิน'),
  egtHot('อุณหภูมิไอเสียสูง'),
  newDtc('มีรหัสปัญหาใหม่หลังทดสอบ'),
  milOn('ไฟเตือนเครื่องยนต์ติดระหว่างทดสอบ');

  const RemapEventKind(this.titleTh);
  final String titleTh;

  /// อาการที่มักเป็นสัญญาณว่ากล่องตัดกำลัง/เข้าโหมดป้องกันตัวเอง
  bool get limpSign => this == noBoostFullPedal || this == railLow || this == newDtc || this == milOn;
}

enum RemapLevel { ok, warn, bad }

/// สิ่งที่พบระหว่างทดสอบ
class RemapEvent {
  const RemapEvent({
    required this.kind,
    required this.level,
    required this.detail,
    this.start,
    this.end,
    this.peak,
  });

  final RemapEventKind kind;
  final RemapLevel level;
  final String detail;

  /// ช่วงเวลา (วินาทีนับจากเริ่ม) และค่าที่ห่างที่สุด
  final double? start;
  final double? end;
  final double? peak;

  double get duration => start == null || end == null ? 0 : end! - start!;

  /// ข้อความเวลา เช่น "นาทีที่ 1:05"
  String? get whenTh {
    final s = start;
    if (s == null) return null;
    final m = s ~/ 60;
    final r = (s % 60).floor();
    return 'นาทีที่ $m:${r.toString().padLeft(2, '0')}';
  }
}

/// เวลาอัตราเร่งจากความเร็วหนึ่งไปอีกความเร็วหนึ่ง (ใช้ช่วงที่เร็วที่สุดในการทดสอบ)
class AccelResult {
  const AccelResult({required this.from, required this.to, required this.seconds, required this.startT});

  final double from;
  final double to;
  final double seconds;

  /// เวลาที่เริ่มนับ (วินาทีนับจากเริ่มทดสอบ)
  final double startT;

  String get label => '${from.round()}–${to.round()}';
}

/// ผลวิเคราะห์ของการทดสอบหนึ่งรอบ
class RemapAnalysis {
  RemapAnalysis({
    required this.run,
    required this.max,
    required this.min,
    required this.accel,
    required this.events,
    required this.baro,
  });

  final RemapRun run;
  final Map<RemapSignal, double> max;
  final Map<RemapSignal, double> min;

  /// เวลาอัตราเร่ง ตามช่วงใน [remapAccelRanges] (เฉพาะช่วงที่ทำได้ในการทดสอบนี้)
  final List<AccelResult> accel;
  final List<RemapEvent> events;

  /// ความดันบรรยากาศที่ใช้แปลงบูสต์สัมบูรณ์เป็นบูสต์แบบเกจ
  final double baro;

  AccelResult? accelFor(double from, double to) {
    for (final a in accel) {
      if (a.from == from && a.to == to) return a;
    }
    return null;
  }

  /// บูสต์สูงสุดแบบเกจ (ลบความดันบรรยากาศแล้ว)
  double? get maxBoostGauge => max[RemapSignal.boost] == null ? null : max[RemapSignal.boost]! - baro;

  /// บูสต์ที่ต้องการสูงสุดแบบเกจ
  double? get maxBoostCmdGauge => max[RemapSignal.boostCmd] == null ? null : max[RemapSignal.boostCmd]! - baro;

  RemapLevel get level {
    if (events.any((e) => e.level == RemapLevel.bad)) return RemapLevel.bad;
    if (events.any((e) => e.level == RemapLevel.warn)) return RemapLevel.warn;
    return RemapLevel.ok;
  }

  int count(RemapLevel l) => events.where((e) => e.level == l).length;

  /// มีอาการที่มักเกิดเมื่อกล่องเข้าโหมดป้องกันตัวเอง
  bool get limpSuspected => events.any((e) => e.kind.limpSign);

  /// สรุปผลเป็นข้อความ (หัวข้อ, คำแนะนำ)
  (String, String) get verdictTh {
    if (run.rows.isEmpty) return ('ไม่มีข้อมูล', 'ไม่ได้อ่านค่าจากรถระหว่างทดสอบ');
    final bad = count(RemapLevel.bad), warn = count(RemapLevel.warn);
    if (level == RemapLevel.ok) {
      return ('ไม่พบสิ่งผิดปกติ', 'ค่าจริงตามค่าที่กล่องต้องการ ไม่มีรหัสปัญหาใหม่ ความร้อนอยู่ในเกณฑ์');
    }
    final limp = limpSuspected ? ' มีอาการที่มักเกิดเมื่อกล่องเข้าโหมดป้องกันตัวเอง (ตัดกำลัง)' : '';
    if (level == RemapLevel.bad) {
      return ('พบความเสี่ยง $bad รายการ${warn > 0 ? ' · ควรตรวจ $warn' : ''}',
          'ไม่ควรใช้งานหนักจนกว่าจะแก้ไข$limp');
    }
    return ('ควรตรวจเพิ่ม $warn รายการ', 'ค่าจริงยังไม่ตรงกับที่กล่องต้องการบางช่วง$limp');
  }
}

/// ช่วงความเร็วที่จับเวลา (กม./ชม.)
const remapAccelRanges = <(double, double)>[(0.0, 100.0), (60.0, 100.0), (80.0, 120.0)];

/// ค่าที่ตำแหน่งเวลา t โดยประมาณเส้นตรงระหว่างสองจุดที่ใกล้ที่สุด
/// คืน null ถ้าไม่มีข้อมูลในระยะ [maxGap] วินาที
double? valueAt(List<(double, double)> pts, double t, {double maxGap = 1.5}) {
  if (pts.isEmpty) return null;
  var lo = 0, hi = pts.length - 1;
  if (t <= pts[lo].$1) return (pts[lo].$1 - t) <= maxGap ? pts[lo].$2 : null;
  if (t >= pts[hi].$1) return (t - pts[hi].$1) <= maxGap ? pts[hi].$2 : null;
  while (hi - lo > 1) {
    final mid = (lo + hi) >> 1;
    if (pts[mid].$1 <= t) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  final a = pts[lo], b = pts[hi];
  if (b.$1 - a.$1 > maxGap * 2) {
    // ช่องว่างใหญ่: ใช้จุดที่ใกล้กว่าถ้าอยู่ในระยะ
    if (t - a.$1 <= maxGap) return a.$2;
    if (b.$1 - t <= maxGap) return b.$2;
    return null;
  }
  if (b.$1 == a.$1) return b.$2;
  return a.$2 + (b.$2 - a.$2) * (t - a.$1) / (b.$1 - a.$1);
}

/// เวลาอัตราเร่งที่ดีที่สุดจาก [from] ถึง [to] กม./ชม.
/// [from] = 0 ต้องออกตัวจากรถจอดนิ่ง ช่วงอื่นนับจากจังหวะที่ความเร็วผ่าน [from] ขณะเร่งต่อเนื่อง
/// ความเร็วลดลงระหว่างทางได้ไม่เกิน [dip] (กันจังหวะเปลี่ยนเกียร์) ถ้าลดมากกว่านั้นถือว่าถอนคันเร่ง
AccelResult? bestAccel(List<(double, double)> speed, double from, double to, {double dip = 4}) {
  if (speed.length < 2) return null;
  AccelResult? best;
  for (var i = 1; i < speed.length; i++) {
    final p = speed[i - 1], q = speed[i];
    double? t0;
    if (from <= 0) {
      // ออกตัว: จุดสุดท้ายที่จอดนิ่ง → จุดแรกที่เคลื่อน ใช้จุดกึ่งกลาง (เหมือนหน้าจับเวลาอัตราเร่ง)
      if (p.$2 < 0.5 && q.$2 >= 0.5 && q.$1 - p.$1 <= 2.0) t0 = p.$1 + (q.$1 - p.$1) / 2;
    } else if (p.$2 < from && q.$2 >= from && q.$1 - p.$1 <= 3.0) {
      t0 = p.$1 + (q.$1 - p.$1) * (from - p.$2) / (q.$2 - p.$2);
    }
    if (t0 == null) continue;
    var peak = q.$2;
    for (var j = i; j < speed.length; j++) {
      final a = speed[j - 1], b = speed[j];
      if (b.$1 - a.$1 > 3.0) break; // ข้อมูลขาดช่วง
      if (b.$2 < peak - dip) break; // ถอนคันเร่ง/เบรก
      if (b.$2 > peak) peak = b.$2;
      if (a.$2 < to && b.$2 >= to) {
        final t1 = a.$1 + (b.$1 - a.$1) * (to - a.$2) / (b.$2 - a.$2);
        final secs = t1 - t0;
        if (secs > 0 && (best == null || secs < best.seconds)) {
          best = AccelResult(from: from, to: to, seconds: secs, startT: t0);
        }
        break;
      }
    }
  }
  return best;
}

/// ช่วงที่เงื่อนไขเป็นจริงต่อเนื่อง: คืน (เริ่ม, จบ, ค่าที่ห่างที่สุด)
/// ตัวอย่างที่เป็นจริงนับต่อไปจนถึงตัวอย่างถัดไป ถ้าตัวอย่างถัดไปห่างเกิน [maxGap] วินาที (ข้อมูลขาดช่วง) ช่วงจบที่ตัวอย่างนั้น
List<(double, double, double)> _spans(List<(double, double?)> pts, {double maxGap = 1.5}) {
  final out = <(double, double, double)>[];
  double? s;
  var e = 0.0;
  var peak = 0.0;
  for (var i = 0; i < pts.length; i++) {
    final (t, v) = pts[i];
    if (s != null && (v == null || t > e + 1e-9)) {
      out.add((s, e, peak));
      s = null;
    }
    if (v == null) continue;
    final next = i + 1 < pts.length ? pts[i + 1].$1 : t;
    if (s == null) {
      s = t;
      peak = v;
    } else if (v.abs() > peak.abs()) {
      peak = v;
    }
    e = next - t <= maxGap ? next : t;
  }
  if (s != null) out.add((s, e, peak));
  return out;
}

String _f(double v, [int d = 0]) => v.toStringAsFixed(d);

/// ค่าที่ต้องการนิ่งตลอด [window] วินาทีก่อนเวลา t: ช่วงกว้างของค่า (สูงสุด − ต่ำสุด) ในหน้าต่างนี้
/// ไม่เกิน [tolAbs] หรือ [tolPct] ของค่าปัจจุบัน (ดูทั้งหน้าต่าง ไม่ใช่แค่ต้นกับปลาย
/// เพราะตอนเปลี่ยนเกียร์ค่าที่ต้องการตกแล้วกลับมาเท่าเดิมได้ภายในหน้าต่างเดียว)
/// และค่าปัจจุบันต้องไม่ต่ำกว่าค่าสูงสุดในหน้าต่างเกินครึ่งเกณฑ์ ถ้าค่าที่ต้องการเพิ่งลด
/// (เปลี่ยนเกียร์/ถอนคันเร่ง) ค่าจริงยังค้างสูงเพราะเทอร์โบ/ปั๊มลดตามไม่ทัน ช่วงนั้นจะดูเกินกว่าความจริง
bool _settled(List<(double, double)> pts, double t, double window, double tolAbs, double tolPct) {
  final end = valueAt(pts, t, maxGap: 1.0);
  final begin = valueAt(pts, t - window, maxGap: 1.0);
  if (end == null || begin == null) return false;
  var lo = math.min(begin, end), hi = math.max(begin, end);
  // จุดแรกที่เวลามากกว่า t − window
  var a = 0, b = pts.length;
  while (a < b) {
    final m = (a + b) >> 1;
    if (pts[m].$1 <= t - window) {
      a = m + 1;
    } else {
      b = m;
    }
  }
  for (var i = a; i < pts.length && pts[i].$1 < t; i++) {
    final v = pts[i].$2;
    if (v < lo) lo = v;
    if (v > hi) hi = v;
  }
  final tol = math.max(tolAbs, end * tolPct);
  if (hi - end > tol / 2) return false;
  return hi - lo <= tol;
}

RemapAnalysis analyzeRemapRun(RemapRun run, {RemapLimits limits = const RemapLimits()}) {
  final max = <RemapSignal, double>{};
  final min = <RemapSignal, double>{};
  for (final s in RemapSignal.values) {
    if (s == RemapSignal.other) continue;
    final pts = run.signal(s);
    if (pts.isEmpty) continue;
    var hi = -double.infinity, lo = double.infinity;
    for (final p in pts) {
      if (p.$2 > hi) hi = p.$2;
      if (p.$2 < lo) lo = p.$2;
    }
    max[s] = hi;
    min[s] = lo;
  }
  final baroPts = run.signal(RemapSignal.baro);
  final baro = baroPts.isEmpty ? 101.3 : baroPts.map((p) => p.$2).reduce((a, b) => a + b) / baroPts.length;

  final speed = run.signal(RemapSignal.speed);
  final accel = <AccelResult>[
    for (final (from, to) in remapAccelRanges)
      if (bestAccel(speed, from, to) case final a?) a,
  ];

  final events = <RemapEvent>[];

  // ---- บูสต์จริงเทียบที่ต้องการ (ใช้เวลาของค่าจริง หาค่าที่ต้องการ ณ เวลาเดียวกัน)
  // เทียบเฉพาะช่วงที่ค่าที่ต้องการนิ่งแล้ว: ตอนเปลี่ยนเกียร์/ถอนคันเร่ง ค่าที่ต้องการลดทันทีแต่บูสต์จริงค่อยๆ ลด
  // และตอนกดคันเร่ง เทอร์โบต้องใช้เวลาปั่น ช่วงนั้นต่างกันเป็นเรื่องปกติ
  final boost = run.signal(RemapSignal.boost);
  final boostCmd = run.signal(RemapSignal.boostCmd);
  if (boost.isNotEmpty && boostCmd.isNotEmpty) {
    final over = <(double, double?)>[];
    final under = <(double, double?)>[];
    for (final (t, act) in boost) {
      final cmd = valueAt(boostCmd, t, maxGap: 1.0);
      if (cmd == null || !_settled(boostCmd, t, limits.settleS, 15, 0.08)) {
        over.add((t, null));
        under.add((t, null));
        continue;
      }
      final d = act - cmd;
      final overLimit = math.max(limits.overboostKpa, cmd * limits.overboostPct / 100);
      final underLimit = math.max(limits.underboostKpa, cmd * limits.underboostPct / 100);
      over.add((t, d > overLimit ? d : null));
      final requested = cmd - baro >= limits.boostRequestKpa;
      under.add((t, requested && -d > underLimit ? d : null));
    }
    for (final (s, e, peak) in _spans(over)) {
      if (e - s < limits.minEventS) continue;
      final bad = peak > 2 * math.max(limits.overboostKpa, 20);
      events.add(RemapEvent(
        kind: RemapEventKind.overboost,
        level: bad ? RemapLevel.bad : RemapLevel.warn,
        start: s,
        end: e,
        peak: peak,
        detail: 'สูงกว่าที่กล่องต้องการ ${_f(peak)} kPa นาน ${_f(e - s, 1)} วินาที '
            '${bad ? 'เสี่ยงเทอร์โบรอบเกิน และกล่องอาจตัดเข้าโหมดป้องกันตัวเอง' : 'ควรตรวจการคุมบูสต์ (โซลินอยด์/ครีบเทอร์โบ) หรือค่าที่ปรับ'}',
      ));
    }
    for (final (s, e, peak) in _spans(under)) {
      if (e - s < limits.minEventS * 1.5) continue;
      events.add(RemapEvent(
        kind: RemapEventKind.underboost,
        level: RemapLevel.warn,
        start: s,
        end: e,
        peak: peak,
        detail: 'ต่ำกว่าที่กล่องต้องการ ${_f(-peak)} kPa นาน ${_f(e - s, 1)} วินาที '
            'ตรวจท่อยาง/อินเตอร์คูลเลอร์รั่ว โซลินอยด์หรือครีบเทอร์โบติด',
      ));
    }
  }

  // ---- บูสต์เกินค่าสูงสุดที่ร้านตั้งไว้ (ไม่ต้องรู้ค่าที่กล่องต้องการ)
  if (boost.isNotEmpty && limits.boostCapGauge > 0) {
    final cap = [for (final (t, v) in boost) (t, v - baro > limits.boostCapGauge ? v - baro : null)];
    for (final (s, e, peak) in _spans(cap)) {
      if (e - s < limits.minEventS) continue;
      events.add(RemapEvent(
        kind: RemapEventKind.boostCap,
        level: peak > limits.boostCapGauge * 1.15 ? RemapLevel.bad : RemapLevel.warn,
        start: s,
        end: e,
        peak: peak,
        detail: 'บูสต์ ${_f(peak)} kPa (เกจ) เกินที่ตั้งไว้ ${_f(limits.boostCapGauge)} kPa นาน ${_f(e - s, 1)} วินาที',
      ));
    }
  }

  // ---- ความดันรางจริงเทียบที่ต้องการ
  final rail = run.signal(RemapSignal.rail);
  final railCmd = run.signal(RemapSignal.railCmd);
  if (rail.isNotEmpty && railCmd.isNotEmpty) {
    final high = <(double, double?)>[];
    final low = <(double, double?)>[];
    for (final (t, act) in rail) {
      final cmd = valueAt(railCmd, t, maxGap: 1.0);
      if (cmd == null || cmd < limits.railMinMpa || !_settled(railCmd, t, 1.0, 5, 0.1)) {
        high.add((t, null));
        low.add((t, null));
        continue;
      }
      final d = act - cmd;
      final lim = math.max(limits.railDevMpa, cmd * limits.railDevPct / 100);
      high.add((t, d > lim ? d : null));
      low.add((t, -d > lim ? d : null));
    }
    for (final (s, e, peak) in _spans(high)) {
      if (e - s < limits.minEventS) continue;
      events.add(RemapEvent(
        kind: RemapEventKind.railHigh,
        level: RemapLevel.warn,
        start: s,
        end: e,
        peak: peak,
        detail: 'สูงกว่าที่ต้องการ ${_f(peak, 1)} MPa นาน ${_f(e - s, 1)} วินาที ตรวจวาล์วคุมแรงดัน (SCV) และค่าที่ปรับ',
      ));
    }
    for (final (s, e, peak) in _spans(low)) {
      if (e - s < limits.minEventS) continue;
      events.add(RemapEvent(
        kind: RemapEventKind.railLow,
        level: -peak > 2 * limits.railDevMpa ? RemapLevel.bad : RemapLevel.warn,
        start: s,
        end: e,
        peak: peak,
        detail: 'ต่ำกว่าที่ต้องการ ${_f(-peak, 1)} MPa นาน ${_f(e - s, 1)} วินาที '
            'ปั๊มแรงดันสูง/ไส้กรองโซล่า/หัวฉีดไหลกลับมาก หรือค่าที่ปรับเกินกำลังปั๊ม',
      ));
    }
  }

  // ---- เหยียบเกือบสุดแต่บูสต์ไม่ขึ้น (อาจเข้าโหมดป้องกันตัวเอง หรือเทอร์โบ/ท่อรั่ว) เฉพาะรถเทอร์โบ
  final pedal = run.signal(RemapSignal.pedal);
  final rpm = run.signal(RemapSignal.rpm);
  if ((run.turbo || boostCmd.isNotEmpty) && pedal.isNotEmpty && boost.isNotEmpty) {
    // คันเร่งบางรถรายงานเป็นตำแหน่งเซนเซอร์ (เช่น 15–80%) ใช้ช่วงที่เห็นจริงถ้ากว้างพอ
    final lo = min[RemapSignal.pedal]!, hi = max[RemapSignal.pedal]!;
    final full = hi - lo >= 40 ? math.max(60.0, lo + 0.9 * (hi - lo)) : 90.0;
    final flat = <(double, double?)>[];
    for (final (t, p) in pedal) {
      final b = valueAt(boost, t, maxGap: 1.0);
      final r = valueAt(rpm, t, maxGap: 1.0);
      final cond = p >= full && b != null && b - baro <= 30 && (r == null || r >= 1800);
      flat.add((t, cond ? b - baro : null));
    }
    for (final (s, e, peak) in _spans(flat)) {
      if (e - s < 3) continue;
      events.add(RemapEvent(
        kind: RemapEventKind.noBoostFullPedal,
        level: RemapLevel.warn,
        start: s,
        end: e,
        peak: peak,
        detail: 'คันเร่งเกือบสุดนาน ${_f(e - s, 1)} วินาที แต่บูสต์ไม่เกิน ${_f(peak)} kPa (เกจ) '
            'อาจเข้าโหมดป้องกันตัวเอง หรือเทอร์โบ/ท่ออากาศรั่ว',
      ));
    }
  }

  // ---- ความร้อน
  void hot(RemapSignal s, double limit, RemapEventKind kind, String advice) {
    final pts = run.signal(s);
    if (pts.isEmpty || limit <= 0) return;
    for (final (start, end, peak) in _spans([for (final (t, v) in pts) (t, v >= limit ? v : null)])) {
      if (end - start < limits.minHotS) continue;
      events.add(RemapEvent(
        kind: kind,
        level: RemapLevel.bad,
        start: start,
        end: end,
        peak: peak,
        detail: 'สูงสุด ${_f(peak)} °C (เกณฑ์ ${_f(limit)} °C) $advice',
      ));
    }
  }

  hot(RemapSignal.coolant, limits.coolantMax, RemapEventKind.coolantHot, 'หยุดทดสอบและตรวจระบบหล่อเย็นก่อน');
  hot(RemapSignal.iat, limits.iatMax, RemapEventKind.iatHot, 'อินเตอร์คูลเลอร์ระบายความร้อนไม่ทัน');
  hot(RemapSignal.egt, limits.egtMax, RemapEventKind.egtHot, 'ส่วนผสมหนา/จ่ายน้ำมันมากเกิน เสี่ยงลูกสูบและเทอร์โบ');

  // ---- รหัสปัญหาก่อน/หลังทดสอบ
  final added = run.dtcAfter.where((c) => !run.dtcBefore.contains(c)).toList();
  if (added.isNotEmpty) {
    events.add(RemapEvent(
      kind: RemapEventKind.newDtc,
      level: RemapLevel.bad,
      detail: '${added.join(', ')} อ่านรายละเอียดที่หน้าวินิจฉัย',
    ));
  }
  if (run.milAfter == true && run.milBefore == false) {
    events.add(const RemapEvent(
      kind: RemapEventKind.milOn,
      level: RemapLevel.bad,
      detail: 'กล่องสั่งไฟเตือนติดหลังทดสอบ อ่านรหัสปัญหาที่หน้าวินิจฉัย',
    ));
  }

  events.sort((a, b) => (a.start ?? 1e9).compareTo(b.start ?? 1e9));
  return RemapAnalysis(run: run, max: max, min: min, accel: accel, events: events, baro: baro);
}

// ---------------------------------------------------------------- เทียบก่อน/หลัง

/// หนึ่งแถวของตารางเทียบ
class RemapCompareRow {
  const RemapCompareRow({
    required this.label,
    required this.unit,
    required this.before,
    required this.after,
    this.decimals = 0,
    this.lowerIsBetter = false,
    this.neutral = false,
  });

  final String label;
  final String unit;
  final double? before;
  final double? after;
  final int decimals;

  /// ค่าน้อยดีกว่า (เช่น เวลาอัตราเร่ง ความร้อน จำนวนสิ่งผิดปกติ)
  final bool lowerIsBetter;

  /// ไม่ตัดสินว่าดีขึ้นหรือแย่ลง (เช่น บูสต์สูงขึ้นไม่ได้แปลว่าดี)
  final bool neutral;

  double? get diff => before == null || after == null ? null : after! - before!;

  /// เปลี่ยนไปกี่เปอร์เซ็นต์ (เทียบกับก่อน)
  double? get pct => diff == null || before == null || before == 0 ? null : diff! / before!.abs() * 100;

  /// ดีขึ้น (true) แย่ลง (false) หรือไม่ตัดสิน (null)
  bool? get better {
    final d = diff;
    if (neutral || d == null || d.abs() < math.pow(10, -decimals) / 2) return null;
    return lowerIsBetter ? d < 0 : d > 0;
  }

  String fmt(double? v) => v == null ? '—' : v.toStringAsFixed(decimals);

  /// ส่วนต่างเป็นตัวเลข เช่น "-1.13"
  String get diffValueText {
    final d = diff;
    return d == null ? '—' : '${d >= 0 ? '+' : ''}${d.toStringAsFixed(decimals)}';
  }

  /// ส่วนต่างเป็นเปอร์เซ็นต์ เช่น "(-15%)" (null ถ้าเปลี่ยนน้อยกว่าครึ่งเปอร์เซ็นต์หรือคำนวณไม่ได้)
  String? get pctText {
    final p = pct;
    return p == null || p.abs() < 0.5 ? null : '(${p >= 0 ? '+' : ''}${p.toStringAsFixed(0)}%)';
  }

  String get diffText => pctText == null ? diffValueText : '$diffValueText $pctText';
}

List<RemapCompareRow> compareRemap(RemapAnalysis before, RemapAnalysis after) {
  final rows = <RemapCompareRow>[];
  for (final (from, to) in remapAccelRanges) {
    final a = before.accelFor(from, to), b = after.accelFor(from, to);
    if (a == null && b == null) continue;
    rows.add(RemapCompareRow(
      label: 'อัตราเร่ง ${from.round()}–${to.round()} กม./ชม.',
      unit: 'วินาที',
      before: a?.seconds,
      after: b?.seconds,
      decimals: 2,
      lowerIsBetter: true,
    ));
  }
  void gauge(String label, double? a, double? b) {
    if (a == null && b == null) return;
    rows.add(RemapCompareRow(label: label, unit: 'kPa', before: a, after: b, neutral: true));
  }

  gauge('บูสต์สูงสุด (เกจ)', before.maxBoostGauge, after.maxBoostGauge);
  gauge('บูสต์ที่ต้องการสูงสุด (เกจ)', before.maxBoostCmdGauge, after.maxBoostCmdGauge);

  void max(RemapSignal s, String label, {bool lowerIsBetter = false}) {
    final a = before.max[s], b = after.max[s];
    if (a == null && b == null) return;
    rows.add(RemapCompareRow(
      label: label,
      unit: s.unit,
      before: a,
      after: b,
      decimals: s.decimals,
      lowerIsBetter: lowerIsBetter,
      neutral: !lowerIsBetter,
    ));
  }

  max(RemapSignal.rail, 'ความดันรางสูงสุด');
  max(RemapSignal.railCmd, 'ความดันรางที่ต้องการสูงสุด');
  max(RemapSignal.injQty, 'ปริมาณฉีดสูงสุด');
  max(RemapSignal.maf, 'มวลอากาศสูงสุด');
  max(RemapSignal.fuelRate, 'อัตราใช้น้ำมันสูงสุด');
  max(RemapSignal.rpm, 'รอบเครื่องสูงสุด');
  max(RemapSignal.speed, 'ความเร็วสูงสุด');
  max(RemapSignal.egt, 'อุณหภูมิไอเสียสูงสุด', lowerIsBetter: true);
  max(RemapSignal.coolant, 'น้ำหล่อเย็นสูงสุด', lowerIsBetter: true);
  max(RemapSignal.iat, 'อากาศเข้าสูงสุด', lowerIsBetter: true);
  rows.add(RemapCompareRow(
    label: 'สิ่งผิดปกติที่พบ',
    unit: 'รายการ',
    before: before.events.length.toDouble(),
    after: after.events.length.toDouble(),
    lowerIsBetter: true,
  ));
  return rows;
}

/// ความเร็วช่วงอัตราเร่ง เลื่อนเวลาให้ 0 = จังหวะเริ่มนับ (ใช้ซ้อนกราฟก่อน/หลัง)
List<(double, double)> accelTrace(RemapAnalysis a, AccelResult r, {double pad = 1.0}) {
  final speed = a.run.signal(RemapSignal.speed);
  return [
    for (final (t, v) in speed)
      if (t >= r.startT - pad && t <= r.startT + r.seconds + pad) (t - r.startT, v),
  ];
}

/// ค่าสูงสุดในแต่ละช่วงแกนนอน (เช่น ทุก 250 รอบ) ใช้ลากเส้นบูสต์/ความดันรางตามรอบแบบกราฟไดโน
List<(double, double)> binnedMax(List<(double, double)> pts, {double width = 250}) {
  final bins = <int, double>{};
  for (final (x, y) in pts) {
    final b = (x / width).floor();
    final cur = bins[b];
    if (cur == null || y > cur) bins[b] = y;
  }
  final keys = bins.keys.toList()..sort();
  return [for (final k in keys) ((k + 0.5) * width, bins[k]!)];
}

/// จุด (รอบเครื่อง, ค่า) ตอนเร่งหนัก ใช้วาดกราฟบูสต์/ความดันรางตามรอบ
/// เลือกเฉพาะจังหวะที่คันเร่ง (หรือภาระเครื่องถ้าไม่มีคันเร่ง) ตั้งแต่ [minDemand]% ขึ้นไป
/// บูสต์แปลงเป็นแบบเกจ (ลบความดันบรรยากาศ)
List<(double, double)> versusRpm(RemapAnalysis a, RemapSignal s, {double minDemand = 70}) {
  final run = a.run;
  final pts = run.signal(s);
  final rpm = run.signal(RemapSignal.rpm);
  if (pts.isEmpty || rpm.isEmpty) return const [];
  final pedal = run.signal(RemapSignal.pedal);
  final load = run.signal(RemapSignal.load);
  final demandPts = pedal.isNotEmpty ? pedal : load;
  final out = <(double, double)>[];
  for (final (t, v) in pts) {
    final r = valueAt(rpm, t, maxGap: 0.8);
    if (r == null || r < 600) continue;
    final demand = valueAt(demandPts, t, maxGap: 1.0);
    if (demand != null && demand < minDemand) continue;
    final y = s == RemapSignal.boost || s == RemapSignal.boostCmd ? v - a.baro : v;
    out.add((r, y));
  }
  out.sort((x, y) => x.$1.compareTo(y.$1));
  return out;
}
