import 'dart:convert';

import '../elm/elm327.dart';
import '../safety/command_guard.dart';
import 'formula.dart';

String _hx(int v) => v.toRadixString(16).padLeft(2, '0').toUpperCase();

String bytesToHex(List<int> b, {String sep = ' '}) => b.map(_hx).join(sep);

List<int> hexToBytes(String s) {
  final h = s.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
  return [for (var i = 0; i + 1 < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)];
}

/// คำตอบจริงที่แหล่งข้อมูลบันทึกไว้ (ใช้ยืนยันว่าถอดค่าถูก)
class ExtEvidence {
  const ExtEvidence({required this.year, required this.raw, this.value});

  final int year;
  final List<int> raw;

  /// ค่าที่แหล่งข้อมูลถอดได้ (ตัวเลข หรือข้อความของค่าที่เป็นสถานะ)
  final Object? value;

  Map<String, dynamic> toJson() => {'y': year, 'r': bytesToHex(raw, sep: ''), if (value != null) 'v': value};

  factory ExtEvidence.fromJson(Map<String, dynamic> j) => ExtEvidence(
        year: (j['y'] as num?)?.toInt() ?? 0,
        raw: hexToBytes(j['r'] as String? ?? ''),
        value: j['v'],
      );
}

/// จุดเทียบค่า: ค่าดิบที่แอปอ่านได้ กับค่าที่เครื่องมือศูนย์แสดงในเวลาเดียวกัน
class CalPoint {
  CalPoint({required this.raw, required this.ref, DateTime? at}) : at = at ?? DateTime.now();

  final List<int> raw;
  final double ref;
  final DateTime at;

  Map<String, dynamic> toJson() => {'r': bytesToHex(raw, sep: ''), 'ref': ref, 't': at.toIso8601String()};

  factory CalPoint.fromJson(Map<String, dynamic> j) => CalPoint(
        raw: hexToBytes(j['r'] as String? ?? ''),
        ref: (j['ref'] as num?)?.toDouble() ?? 0,
        at: DateTime.tryParse(j['t'] as String? ?? ''),
      );
}

/// แหล่งที่มาของชุดข้อมูล
class ExtSource {
  const ExtSource({required this.name, this.url = '', this.license = '', this.by = '', this.changes = ''});

  final String name;
  final String url;
  final String license;
  final String by;
  final String changes;

  Map<String, dynamic> toJson() => {
        'name': name,
        if (url.isNotEmpty) 'url': url,
        if (license.isNotEmpty) 'license': license,
        if (by.isNotEmpty) 'by': by,
        if (changes.isNotEmpty) 'changes': changes,
      };

  factory ExtSource.fromJson(Map<String, dynamic> j) => ExtSource(
        name: j['name'] as String? ?? '',
        url: j['url'] as String? ?? '',
        license: j['license'] as String? ?? '',
        by: j['by'] as String? ?? '',
        changes: j['changes'] as String? ?? '',
      );
}

/// ค่าเฉพาะยี่ห้อ / ค่าที่ช่างกำหนดเอง (ไม่อยู่ใน OBD มาตรฐาน)
/// เช่น ค่าชดเชยหัวฉีดรายสูบ อุณหภูมิน้ำมันเกียร์ ปริมาณเขม่าใน DPF
class ExtPid {
  ExtPid({
    required this.name,
    required this.request,
    required this.formula,
    this.header = '',
    this.unit = '',
    this.min,
    this.max,
    this.decimals = 1,
    this.group = '',
    this.verified = false,
    this.id,
    this.en,
    this.rx,
    this.nullMin,
    this.nullMax,
    this.okMin,
    this.okMax,
    Map<int, String>? labels,
    this.desc,
    this.years,
    List<int>? seenYears,
    List<ExtEvidence>? evidence,
    this.debug = false,
    this.source,
    this.verifiedBy,
    this.verifiedAt,
    this.verifiedOn,
    List<CalPoint>? points,
  })  : labels = labels ?? const {},
        seenYears = seenYears ?? const [],
        evidence = evidence ?? const [],
        points = points ?? [];

  /// ชื่อที่แสดง
  String name;

  /// คำสั่งเป็นเลขฐาน 16 เช่น "2101", "221101", "015C"
  String request;

  /// สูตรแปลง เช่น "A-40", "S16(A,B)/100"
  String formula;

  /// header ปลายทาง เช่น "7E0", "7E1", "18DA10F1" (ว่าง = ส่งแบบทุกกล่อง)
  String header;
  String unit;

  /// ช่วงค่าที่เป็นไปได้ (ใช้ตรวจว่าถอดค่าถูกรุ่นหรือไม่)
  double? min;
  double? max;
  int decimals;

  /// กลุ่มสำหรับจัดหน้าจอ เช่น "หัวฉีด", "DPF", "เกียร์"
  String group;

  /// ร้านนี้ยืนยันกับรถจริงแล้ว
  bool verified;

  /// รหัสจากแหล่งข้อมูล (เช่น HILUX_ATF_T_PAN_V3)
  String? id;

  /// ชื่อภาษาอังกฤษเดิม (ใช้เทียบกับชื่อใน Techstream / G-IDSS)
  String? en;

  /// header ตอบกลับ ถ้าไม่ใช่แบบปกติ (11 บิต = header + 8)
  String? rx;

  /// ค่าที่เท่ากับหรือเกินขอบนี้แปลว่าเซ็นเซอร์ไม่พร้อม (ไม่มีค่า)
  double? nullMin;
  double? nullMax;

  /// ช่วงค่าปกติ (ถ้าแหล่งข้อมูลระบุ)
  double? okMin;
  double? okMax;

  /// ป้ายของค่าที่เป็นสถานะ เช่น 0 = ปิด, 1 = เปิด
  Map<int, String> labels;

  String? desc;

  /// ปีรุ่นที่ใช้ได้ (ข้อความ) ถ้าไม่ได้ใช้กับทุกปีของชุด
  String? years;

  /// ปีรุ่นที่แหล่งข้อมูลเคยพบคำสั่งนี้ตอบในรถจริง
  List<int> seenYears;

  /// ตัวอย่างคำตอบจริงพร้อมค่าที่ถูกต้อง
  List<ExtEvidence> evidence;

  /// แหล่งข้อมูลยังไม่ยืนยันคำสั่งนี้
  bool debug;

  /// ชื่อแหล่งที่มา (ถ้ารายการนี้มาจากแหล่งต่างจากชุด)
  String? source;

  /// ผู้ยืนยัน วันที่ และรถที่ใช้ยืนยัน
  String? verifiedBy;
  DateTime? verifiedAt;
  String? verifiedOn;

  /// จุดเทียบกับเครื่องมือศูนย์
  List<CalPoint> points;

  String get key => '${header.toUpperCase()}|${request.toUpperCase()}|$formula|${id ?? name}';

  /// คำสั่งเดียวกัน (ส่งครั้งเดียวแล้วถอดได้หลายค่า)
  String get cmdKey => '${header.toUpperCase()}|${responseHeader ?? ''}|${request.toUpperCase()}';

  /// service ที่ใช้ (01, 21, 22 …)
  int get service => int.parse(request.substring(0, 2), radix: 16);

  /// ไบต์ระบุค่าที่กล่องตอบกลับซ้ำ (หลังไบต์ตอบรับ)
  List<int> get idBytes {
    final all = hexToBytes(request);
    return all.sublist(1);
  }

  bool get isFunctional => header.isEmpty || header.toUpperCase() == '7DF' || header.toUpperCase() == '18DB33F1';

  /// ส่งไปยังเลขกล่องวินิจฉัยมาตรฐานของ OBD-II หรือไม่ (ดู [isStandardDiagHeader])
  bool get standardHeader => isStandardDiagHeader(header);

  /// ที่อยู่ตอบกลับ: 11 บิต = header + 8, 29 บิต 18DAttss → 18DAsstt
  String? get responseHeader {
    if (rx != null && rx!.isNotEmpty) return rx!.toUpperCase();
    final h = header.toUpperCase();
    if (h.length == 3) {
      final v = int.tryParse(h, radix: 16);
      return v == null ? null : (v + 8).toRadixString(16).toUpperCase().padLeft(3, '0');
    }
    if (h.length == 8 && h.substring(2, 4) == 'DA') return '${h.substring(0, 4)}${h.substring(6, 8)}${h.substring(4, 6)}';
    return null;
  }

  bool get isState => labels.isNotEmpty;
  bool get hasEvidence => seenYears.isNotEmpty || evidence.isNotEmpty;

  /// ระดับความเชื่อถือ: 2 = ร้านยืนยันเอง, 1 = แหล่งข้อมูลเคยพบในรถจริง, 0 = รอยืนยัน
  int get trust => verified ? 2 : (hasEvidence ? 1 : 0);

  /// คำสั่งเป็นเลขฐาน 16 ยาว 2–4 ไบต์
  bool get requestIsHex => RegExp(r'^([0-9A-F]{2}){2,4}$').hasMatch(request.toUpperCase());

  /// เหตุผลที่แอปไม่ส่งคำสั่งของค่านี้ (ไม่ใช่คำสั่งอ่านค่า) หรือ null ถ้าส่งได้
  /// ชุดที่เก็บไว้แล้วยังอยู่ครบ แค่ค่าที่ใช้คำสั่งต้องห้ามจะไม่ถูกส่งให้รถ
  String? get safetyBlock {
    final c = checkCommand(request);
    return switch (c.kind) {
      CommandKind.read => null,
      CommandKind.clear => 'คำสั่งลบรหัสปัญหา',
      _ => c.reason,
    };
  }

  String? validate() {
    if (name.trim().isEmpty) return 'ใส่ชื่อค่า';
    if (!requestIsHex) return 'คำสั่งต้องเป็นเลขฐาน 16 เช่น 2101 หรือ 221101';
    final unsafe = safetyBlock;
    if (unsafe != null) return 'แอปไม่ส่งคำสั่งนี้เพื่อความปลอดภัย ($unsafe) ใช้ได้เฉพาะคำสั่งอ่านค่า เช่น 21xx หรือ 22xxxx';
    if (header.isNotEmpty && !RegExp(r'^([0-9A-F]{3}|[0-9A-F]{8})$').hasMatch(header.toUpperCase())) {
      return 'header ต้องเป็น 3 หลัก (เช่น 7E0) หรือ 8 หลัก (เช่น 18DA10F1)';
    }
    if (rx != null && rx!.isNotEmpty && !RegExp(r'^([0-9A-F]{3}|[0-9A-F]{8})$').hasMatch(rx!.toUpperCase())) {
      return 'header ตอบกลับต้องเป็น 3 หรือ 8 หลัก';
    }
    if (!isFunctional && responseHeader == null) return 'ไม่รู้ที่อยู่ตอบกลับของ header นี้';
    try {
      Formula(formula);
    } on FormatException catch (e) {
      return 'สูตรไม่ถูกต้อง: ${e.message}';
    }
    return null;
  }

  /// ข้อความค่าที่อ่านได้ (รวมป้ายสถานะ)
  String format(double v) {
    if (labels.isNotEmpty) {
      final l = labels[v.round()];
      return l ?? v.round().toString();
    }
    return v.toStringAsFixed(decimals.clamp(0, 4));
  }

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'name': name,
        if (en != null) 'en': en,
        'req': request.toUpperCase(),
        'f': formula,
        if (header.isNotEmpty) 'hdr': header.toUpperCase(),
        if (rx != null && rx!.isNotEmpty) 'rx': rx!.toUpperCase(),
        if (unit.isNotEmpty) 'unit': unit,
        if (min != null) 'min': min,
        if (max != null) 'max': max,
        'dec': decimals,
        if (group.isNotEmpty) 'group': group,
        if (labels.isNotEmpty) 'labels': {for (final e in labels.entries) '${e.key}': e.value},
        if (nullMin != null) 'nmin': nullMin,
        if (nullMax != null) 'nmax': nullMax,
        if (okMin != null) 'omin': okMin,
        if (okMax != null) 'omax': okMax,
        if (desc != null) 'desc': desc,
        if (years != null) 'yr': years,
        if (seenYears.isNotEmpty) 'evy': seenYears,
        if (evidence.isNotEmpty) 'ev': evidence.map((e) => e.toJson()).toList(),
        if (debug) 'dbg': true,
        if (source != null) 'srcn': source,
        if (verified) 'ok': true,
        if (verifiedBy != null) 'by': verifiedBy,
        if (verifiedAt != null) 'at': verifiedAt!.toIso8601String(),
        if (verifiedOn != null) 'veh': verifiedOn,
        if (points.isNotEmpty) 'cal': points.map((p) => p.toJson()).toList(),
      };

  factory ExtPid.fromJson(Map<String, dynamic> j) {
    double? d(String k) => (j[k] as num?)?.toDouble();
    final labels = <int, String>{};
    final lj = j['labels'];
    if (lj is Map) {
      for (final e in lj.entries) {
        final k = int.tryParse('${e.key}');
        if (k != null) labels[k] = '${e.value}';
      }
    }
    return ExtPid(
      id: j['id'] as String?,
      name: j['name'] as String? ?? '',
      en: j['en'] as String?,
      request: (j['req'] as String? ?? '').toUpperCase(),
      formula: j['f'] as String? ?? 'A',
      header: (j['hdr'] as String? ?? '').toUpperCase(),
      rx: (j['rx'] as String?)?.toUpperCase(),
      unit: j['unit'] as String? ?? '',
      min: d('min'),
      max: d('max'),
      decimals: (j['dec'] as num?)?.toInt() ?? 1,
      group: j['group'] as String? ?? '',
      labels: labels,
      nullMin: d('nmin'),
      nullMax: d('nmax'),
      okMin: d('omin'),
      okMax: d('omax'),
      desc: j['desc'] as String?,
      years: j['yr'] as String?,
      seenYears: [for (final y in (j['evy'] as List<dynamic>? ?? const [])) (y as num).toInt()],
      evidence: [
        for (final e in (j['ev'] as List<dynamic>? ?? const [])) ExtEvidence.fromJson(e as Map<String, dynamic>),
      ],
      debug: j['dbg'] as bool? ?? false,
      source: j['srcn'] as String?,
      verified: j['ok'] as bool? ?? false,
      verifiedBy: j['by'] as String?,
      verifiedAt: DateTime.tryParse(j['at'] as String? ?? ''),
      verifiedOn: j['veh'] as String?,
      points: [for (final p in (j['cal'] as List<dynamic>? ?? const [])) CalPoint.fromJson(p as Map<String, dynamic>)],
    );
  }

  ExtPid copy() => ExtPid.fromJson(jsonDecode(jsonEncode(toJson())) as Map<String, dynamic>);
}

/// ชุดค่าของรถรุ่นหนึ่ง
class ExtPidPack {
  ExtPidPack({
    required this.id,
    required this.name,
    this.note = '',
    List<ExtPid>? pids,
    this.lib,
    this.libVersion = 0,
    this.brand = '',
    List<String>? models,
    List<int>? years,
    List<ExtSource>? sources,
    this.activeGroups,
  })  : pids = pids ?? [],
        models = models ?? const [],
        years = years ?? const [],
        sources = sources ?? const [];

  final String id;
  String name;
  String note;
  final List<ExtPid> pids;

  /// รหัสชุดในคลังของแอป (ถ้าคัดลอกมาจากคลัง)
  final String? lib;
  final int libVersion;
  final String brand;
  final List<String> models;

  /// ปีรุ่น [จาก, ถึง]
  final List<int> years;
  final List<ExtSource> sources;

  /// กลุ่มที่อ่านอยู่ (null = ทุกกลุ่ม)
  List<String>? activeGroups;

  bool get verified => pids.isNotEmpty && pids.every((p) => p.verified);

  List<String> get groups {
    final out = <String>[];
    for (final p in pids) {
      final g = p.group.isEmpty ? 'ทั่วไป' : p.group;
      if (!out.contains(g)) out.add(g);
    }
    return out;
  }

  int get commandCount => {for (final p in pids) p.cmdKey}.length;

  String get yearsText {
    if (years.length < 2) return '';
    if (years[0] == years[1]) return '${years[0]}';
    return years[1] >= DateTime.now().year ? '${years[0]} ขึ้นไป' : '${years[0]}–${years[1]}';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (note.isNotEmpty) 'note': note,
        if (lib != null) 'lib': lib,
        if (libVersion > 0) 'libv': libVersion,
        if (brand.isNotEmpty) 'brand': brand,
        if (models.isNotEmpty) 'models': models,
        if (years.isNotEmpty) 'years': years,
        if (sources.isNotEmpty) 'src': sources.map((s) => s.toJson()).toList(),
        if (activeGroups != null) 'on': activeGroups,
        'pids': pids.map((p) => p.toJson()).toList(),
      };

  factory ExtPidPack.fromJson(Map<String, dynamic> j) => ExtPidPack(
        id: j['id'] as String? ?? 'pack_${DateTime.now().millisecondsSinceEpoch}',
        name: j['name'] as String? ?? 'ชุดค่าไม่มีชื่อ',
        note: j['note'] as String? ?? '',
        lib: j['lib'] as String?,
        libVersion: (j['libv'] as num?)?.toInt() ?? 0,
        brand: j['brand'] as String? ?? '',
        models: [for (final m in (j['models'] as List<dynamic>? ?? const [])) '$m'],
        years: [for (final y in (j['years'] as List<dynamic>? ?? const [])) (y as num).toInt()],
        sources: [for (final s in (j['src'] as List<dynamic>? ?? const [])) ExtSource.fromJson(s as Map<String, dynamic>)],
        activeGroups: (j['on'] as List<dynamic>?)?.map((e) => '$e').toList(),
        pids: (j['pids'] as List<dynamic>? ?? const [])
            .map((e) => ExtPid.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  ExtPidPack copyWithId(String newId) => ExtPidPack.fromJson({...jsonDecode(jsonEncode(toJson())) as Map<String, dynamic>, 'id': newId});

  /// ส่งออกเป็นข้อความ JSON ให้ช่างแชร์กันทาง LINE ได้
  String export() => const JsonEncoder.withIndent(' ').convert({'proscaner_pack': 1, ...toJson()});
}

/// รายการที่ไม่ถูกนำเข้าเพราะคำสั่งไม่ใช่การอ่านค่า
class BlockedPid {
  const BlockedPid({required this.name, required this.request, required this.reason, this.line});

  final String name;
  final String request;
  final String reason;

  /// บรรทัดในไฟล์ CSV (null ถ้านำเข้าจาก JSON)
  final int? line;

  String get label => '${line == null ? '' : 'บรรทัด $line: '}$name ($request) — $reason';
}

/// ผลการนำเข้าชุดค่า
class PackImport {
  const PackImport(this.pack, {this.skipped = 0, this.blocked = const []});

  final ExtPidPack pack;

  /// จำนวนบรรทัด/รายการที่อ่านไม่ได้ (รูปแบบผิด)
  final int skipped;

  /// รายการที่ข้ามเพื่อความปลอดภัย (คำสั่งเขียน รีเซ็ต ลบรหัส ฯลฯ)
  final List<BlockedPid> blocked;
}

/// นำเข้าข้อความที่วางมา: JSON ของแอปนี้ หรือไฟล์ CSV แบบ Torque
/// คืนชุดค่าและจำนวนบรรทัดที่ข้าม (รวมบรรทัดที่ข้ามเพื่อความปลอดภัย) ดูรายละเอียดได้จาก [importPackDetailed]
(ExtPidPack, int) importPack(String text, {String fallbackName = 'ชุดที่นำเข้า'}) {
  final r = importPackDetailed(text, fallbackName: fallbackName);
  return (r.pack, r.skipped + r.blocked.length);
}

/// นำเข้าข้อความที่วางมา: JSON ของแอปนี้ หรือไฟล์ CSV แบบ Torque
/// (Name,ShortName,ModeAndPID,Equation,Min Value,Max Value,Units,Header)
/// ค่าที่ใช้คำสั่งต้องห้ามจะไม่ถูกนำเข้า และบอกไว้ใน [PackImport.blocked] ว่าข้ามบรรทัดไหน เพราะอะไร
PackImport importPackDetailed(String text, {String fallbackName = 'ชุดที่นำเข้า'}) {
  final t = text.trim().replaceFirst('﻿', '');
  if (t.startsWith('{')) {
    final j = jsonDecode(t) as Map<String, dynamic>;
    final pack = ExtPidPack.fromJson({...j, 'id': 'pack_${DateTime.now().millisecondsSinceEpoch}'});
    final blocked = <BlockedPid>[];
    var bad = 0;
    pack.pids.removeWhere((p) {
      final unsafe = p.requestIsHex ? p.safetyBlock : null;
      if (unsafe != null) {
        blocked.add(BlockedPid(name: p.name, request: p.request, reason: unsafe));
        return true;
      }
      if (p.validate() != null) {
        bad++;
        return true;
      }
      return false;
    });
    return PackImport(pack, skipped: bad, blocked: blocked);
  }
  final pack = ExtPidPack(id: 'pack_${DateTime.now().millisecondsSinceEpoch}', name: fallbackName);
  final blocked = <BlockedPid>[];
  var skipped = 0;
  var lineNo = 0;
  for (final raw in t.split(RegExp(r'\r?\n'))) {
    lineNo++;
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final cells = _csvCells(line);
    if (cells.length < 4 || cells[0].toLowerCase() == 'name') {
      if (cells.isNotEmpty && cells[0].toLowerCase() != 'name') skipped++;
      continue;
    }
    final req = cells[2].toUpperCase().replaceAll(RegExp(r'^0X'), '').replaceAll(' ', '');
    var header = cells.length > 7 ? cells[7].toUpperCase().replaceAll(' ', '') : '';
    if (header == 'AUTO') header = '';
    // Torque ใส่ header 29 บิตแบบย่อ 6 หลัก (DA10F1)
    if (header.length == 6) header = '18$header';
    final p = ExtPid(
      name: cells[0],
      request: req,
      formula: cells[3],
      header: header,
      min: cells.length > 4 ? double.tryParse(cells[4]) : null,
      max: cells.length > 5 ? double.tryParse(cells[5]) : null,
      unit: cells.length > 6 ? cells[6] : '',
    );
    final unsafe = p.requestIsHex ? p.safetyBlock : null;
    if (unsafe != null) {
      blocked.add(BlockedPid(name: p.name, request: p.request, reason: unsafe, line: lineNo));
    } else if (p.validate() == null) {
      pack.pids.add(p);
    } else {
      skipped++;
    }
  }
  return PackImport(pack, skipped: skipped, blocked: blocked);
}

List<String> _csvCells(String line) {
  final out = <String>[];
  final b = StringBuffer();
  var quoted = false;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (c == '"') {
      quoted = !quoted;
    } else if (c == ',' && !quoted) {
      out.add(b.toString().trim());
      b.clear();
    } else {
      b.write(c);
    }
  }
  out.add(b.toString().trim());
  return out;
}

/// ผลการอ่านหนึ่งค่า
class ExtReading {
  const ExtReading({this.value, this.raw, this.error, this.empty = false, this.outOfRange = false, this.skipped = false});

  final double? value;

  /// ข้อมูลหลังเลขคำสั่ง (ไบต์ A, B, C …)
  final List<int>? raw;
  final String? error;

  /// เซ็นเซอร์ไม่พร้อม (ค่าตกขอบที่แหล่งข้อมูลกำหนดว่าไม่มีค่า)
  final bool empty;

  /// ค่าออกนอกช่วงที่เป็นไปได้ (อาจถอดผิดรุ่น)
  final bool outOfRange;

  /// ไม่ได้ถามเพราะรอบก่อนรถไม่ตอบ
  final bool skipped;

  bool get ok => value != null && error == null;
}

/// สถานะของคำสั่งหนึ่ง
enum ExtCmdStatus { ok, negative, silent, skipped }

/// เลขกล่องที่ OBD-II สงวนไว้ให้เครื่องมือวินิจฉัยในรถ CAN ทุกคัน (ISO 15765-4):
/// 11 บิต = 7DF (ถามทุกกล่อง) และ 7E0–7E7, 29 บิต = 18DB33F1 และ 18DAxxF1
/// เลขอื่น (เช่น 700, 7C0, 620) เป็นเลขเฉพาะยี่ห้อ รถคนละยี่ห้อ/คนละรุ่นอาจใช้เลขนั้นเป็นข้อความปกติ
/// (เช่น ข้อมูลหน้าปัด) ส่งคำสั่งไปจึงอาจไปชนกับข้อความของรถได้
bool isStandardDiagHeader(String header) {
  final h = header.trim().toUpperCase();
  if (h.isEmpty || h == '7DF' || h == '18DB33F1') return true;
  if (h.length == 3) {
    final v = int.tryParse(h, radix: 16);
    return v != null && v >= 0x7E0 && v <= 0x7E7;
  }
  return h.length == 8 && h.startsWith('18DA') && h.endsWith('F1');
}

/// ชุดค่านี้ทำไว้สำหรับรถคันที่ต่ออยู่หรือไม่: ยี่ห้อตรง (หรือชื่อรุ่นตรง) และปีอยู่ในช่วงของชุด (เผื่อ ±1 ปี)
/// ชุดที่ผู้ใช้สร้างเอง (ไม่ระบุยี่ห้อ) ถือว่าตั้งใจใช้กับรถที่ต่ออยู่
/// ถ้าไม่ตรง แอปจะถามเฉพาะกล่องเลขมาตรฐาน ([isStandardDiagHeader])
bool packFitsVehicle({
  required String packBrand,
  List<String> packModels = const [],
  List<int> packYears = const [],
  String? make,
  String? model,
  int? year,
}) {
  if (packBrand.trim().isEmpty) return true;
  final brandHit = make != null && make.trim().toLowerCase() == packBrand.trim().toLowerCase();
  final m = (model ?? '').trim().toLowerCase();
  // ชื่อรุ่นสั้นๆ อย่าง "2" ห้ามใช้จับคู่ข้ามยี่ห้อ (D-Max 2.5 ไม่ใช่ Mazda 2)
  final modelHit = m.length >= 3 &&
      packModels.any((x) {
        final l = x.trim().toLowerCase();
        return l.length >= 3 && (m.contains(l) || l.contains(m));
      });
  if (!brandHit && !modelHit) return false;
  if (year != null && packYears.length == 2 && (year < packYears[0] - 1 || year > packYears[1] + 1)) return false;
  return true;
}

/// ปีของรถห่างจากช่วงปีของชุดกี่ปี (0 = อยู่ในช่วง หรือไม่รู้ปี)
int packYearGap(List<int> packYears, int? year) {
  if (year == null || packYears.length < 2) return 0;
  if (year < packYears[0]) return packYears[0] - year;
  if (year > packYears[1]) return year - packYears[1];
  return 0;
}

/// เหตุผลที่ข้ามค่าที่ส่งไปกล่องเลขเฉพาะยี่ห้อ เมื่อชุดนั้นไม่ใช่ของรถคันที่ต่ออยู่
const notForThisCarText = 'ข้าม: กล่องเลขเฉพาะยี่ห้อ แต่ชุดนี้ไม่ใช่ของรถคันนี้';

/// เลขที่ค้างไว้เมื่อหยุดค้นหากลางทาง จากข้อความความคืบหน้า เช่น "7E0 221604" → "1604" (คำสั่ง 21: "7E0 2135" → "35")
/// คืน null ถ้าอ่านไม่ได้ หรือเป็นคำสั่งคนละชนิดกับที่ค้นหาอยู่
String? resumeIdFrom(String progress, int service) {
  final m = RegExp(r'([0-9A-Fa-f]{2})([0-9A-Fa-f]+)$').firstMatch(progress.trim());
  if (m == null || int.tryParse(m.group(1)!, radix: 16) != service) return null;
  final id = m.group(2)!.toUpperCase();
  return id.length == (service == 0x22 ? 4 : 2) ? id : null;
}

/// ข้อความเมื่อรถไม่ตอบอะไรเลย แม้แต่คำสั่ง OBD มาตรฐาน (มักเป็นเพราะปิดสวิตช์กุญแจ)
const carSilentText = 'รถไม่ตอบเลย แม้แต่คำสั่ง OBD มาตรฐาน: เปิดสวิตช์กุญแจ (ON) หรือติดเครื่อง แล้วลองใหม่';

/// รหัสปฏิเสธของกล่อง (negative response ของ KWP/UDS) เป็นภาษาไทย
String nrcText(int nrc) => switch (nrc) {
      0x11 => 'กล่องนี้ไม่รองรับคำสั่งชนิดนี้',
      0x12 || 0x31 => 'รถไม่รองรับค่านี้',
      0x13 => 'รูปแบบคำสั่งไม่ตรงกับกล่องนี้',
      0x21 => 'กล่องไม่ว่าง (ลองอ่านใหม่)',
      0x22 => 'สภาพรถยังไม่พร้อม (บางค่าต้องติดเครื่อง)',
      0x33 => 'กล่องล็อกค่านี้ไว้ (ต้องใช้เครื่องมือศูนย์)',
      0x7E || 0x7F => 'ต้องเข้าโหมดพิเศษของกล่อง (แอปไม่ทำ เพื่อความปลอดภัย)',
      _ => 'กล่องปฏิเสธ (0x${_hx(nrc)})',
    };

/// รหัสปฏิเสธที่ถามซ้ำกี่ครั้งก็ไม่ได้ค่า (ข้ามคำสั่งนั้นในรอบถัดไป)
bool nrcPermanent(int nrc) => const {0x11, 0x12, 0x13, 0x31, 0x33, 0x7E, 0x7F}.contains(nrc);

/// ผลของคำสั่งหนึ่ง
class ExtCmdResult {
  const ExtCmdResult(this.status, {this.payload, this.nrc, this.error});

  final ExtCmdStatus status;
  final List<int>? payload;
  final int? nrc;
  final String? error;
}

/// รายการที่กล่องตอบตอนค้นหา
class DidHit {
  const DidHit(this.request, this.data, {this.header = '', this.rx});
  final String request;
  final List<int> data;
  final String header;
  final String? rx;

  String get hex => bytesToHex(data);
  String get ascii => String.fromCharCodes(data.map((b) => b >= 0x20 && b < 0x7F ? b : 0x2E));
}

/// งานค้นหาหนึ่งช่วง
class ScanJob {
  const ScanJob({required this.header, required this.service, required this.start, required this.end, this.rx});

  final String header;

  /// header ตอบกลับ ถ้าไม่ใช่แบบปกติ
  final String? rx;
  final int service;
  final int start;
  final int end;

  int get count => end - start + 1;
  String get label {
    final w = service == 0x22 ? 4 : 2;
    String f(int v) => v.toRadixString(16).padLeft(w, '0').toUpperCase();
    return '${header.isEmpty ? '7DF' : header} · ${_hx(service)} ${f(start)}–${f(end)}';
  }
}

/// สรุปผลการค้นหาหนึ่งช่วง: เจอ / กล่องปฏิเสธ (พร้อมรหัส) / เงียบ
/// ใช้บอกช่างว่าควรลองอะไรต่อ (เปลี่ยนชนิดคำสั่ง เปลี่ยนช่วง หรือไม่มีกล่องที่เลขนี้)
class ScanJobStat {
  ScanJobStat(this.job);

  final ScanJob job;

  /// เลขที่กล่องตอบค่ากลับมา
  int found = 0;

  /// เลขที่กล่องตอบปฏิเสธ (7F)
  int negative = 0;

  /// เลขที่ไม่มีคำตอบเลย
  int silent = 0;

  /// จำนวนครั้งของรหัสปฏิเสธแต่ละรหัส
  final Map<int, int> nrcs = {};

  /// รหัสปฏิเสธที่พบบ่อยที่สุด
  int? get commonNrc {
    int? best;
    var n = 0;
    for (final e in nrcs.entries) {
      if (e.value > n) {
        best = e.key;
        n = e.value;
      }
    }
    return best;
  }

  /// คำแนะนำสั้น ๆ ว่าควรลองอะไรต่อ
  String get hint {
    if (found == 0 && negative == 0) return 'ไม่มีกล่องตอบที่เลขนี้ หรือกล่องไม่สนใจคำสั่งชนิดนี้ ลองอีกชนิด (21/22)';
    final n = commonNrc;
    if (found == 0 && n == 0x11) return 'กล่องตอบแต่ไม่รองรับคำสั่งชนิดนี้ ลองอีกชนิด';
    if (found == 0 && (n == 0x31 || n == 0x12)) return 'กล่องรองรับคำสั่งนี้ แต่ไม่มีเลขในช่วงนี้ ลองช่วงอื่น';
    if (found > 0) return 'เจอค่าที่กล่องตอบ แตะรายการด้านล่างเพื่อดูไบต์สด';
    return '';
  }

  /// ข้อความสรุปหนึ่งบรรทัด
  String get summary {
    final n = commonNrc;
    final why = n == null ? '' : ' (รหัส ${_hx(n)} = ${nrcText(n)})';
    return '${job.label}: เจอ $found · ปฏิเสธ $negative$why · เงียบ $silent';
  }
}

/// ผลทดสอบชุดค่ากับรถคันที่ต่ออยู่
class ExtProbeResult {
  ExtProbeResult({
    this.incompatible = 0,
    required this.commands,
    required this.responded,
    required this.negative,
    required this.silent,
    required this.readings,
    required this.pidsTested,
    required this.pidsOk,
    required this.pidsOutOfRange,
    this.carSilent = false,
    this.notForThisCar = 0,
  });

  /// รถไม่ตอบอะไรเลย แม้แต่ OBD มาตรฐาน (ปิดสวิตช์กุญแจ/ตัวสแกนหลุด) ผลนี้จึงบอกไม่ได้ว่าชุดตรงรุ่นหรือไม่
  final bool carSilent;

  /// ค่าที่ไม่ได้ถาม เพราะส่งไปกล่องเลขเฉพาะยี่ห้อ และชุดนี้ไม่ใช่ของรถคันนี้
  final int notForThisCar;

  /// รายการที่ข้ามเพราะเป็นของรถคนละแบบ (CAN 11/29 บิต)
  final int incompatible;
  final int commands;
  final int responded;
  final int negative;
  final int silent;
  final Map<String, ExtReading> readings;
  final int pidsTested;
  final int pidsOk;
  final int pidsOutOfRange;

  double get score {
    if (commands == 0) return 0;
    final resp = responded / commands;
    final sane = pidsTested == 0 ? 1.0 : (pidsOk / pidsTested);
    return resp * (0.5 + 0.5 * sane);
  }

  /// 2 = ตรงกับรถคันนี้, 1 = ใช้ได้บางส่วน, 0 = ไม่ตรงรุ่น (หรือรถไม่ตอบ)
  int get level => carSilent ? 0 : (score >= 0.6 ? 2 : (score >= 0.2 ? 1 : 0));

  String get verdict => carSilent
      ? 'รถไม่ตอบ'
      : switch (level) {
          2 => 'ตรงกับรถคันนี้',
          1 => 'ใช้ได้บางส่วน',
          _ => 'ไม่ตรงกับรถคันนี้',
        };
}

/// อ่านค่าเฉพาะยี่ห้อผ่าน ELM327 (สลับ header ไปคุยกับกล่องที่กำหนด แล้วกลับคืนเสมอ)
class ExtPidReader {
  ExtPidReader(this.elm, {this.skip});

  final Elm327 elm;

  /// คำสั่งที่รถไม่ตอบ/ปฏิเสธในรอบก่อน (ข้ามไป ไม่ต้องรอหมดเวลาซ้ำทุกรอบ)
  /// คำสั่งที่เงียบครั้งแรกจะถูกจำไว้เป็น "~คำสั่ง" ก่อน ถ้าเงียบอีกรอบจึงข้ามจริง
  final Set<String>? skip;

  /// ผลของการอ่าน/ทดสอบ/ค้นหาครั้งล่าสุด: รถไม่ตอบอะไรเลย แม้แต่ OBD มาตรฐาน
  bool carSilent = false;

  /// สรุปผลการค้นหาครั้งล่าสุด แยกตามช่วง (ดู [scanJobs])
  final List<ScanJobStat> lastScanStats = [];

  /// รถยังตอบคำสั่ง OBD มาตรฐานอยู่หรือไม่
  /// ใช้แยก "ปิดสวิตช์กุญแจ/ตัวสแกนหลุด" ออกจาก "รถรุ่นนี้ไม่รองรับคำสั่งนี้" (ต้องเรียกนอก exclusive ที่ตั้ง header ไว้)
  Future<bool> carResponds() async {
    try {
      final r = await elm.query('0100', timeout: const Duration(seconds: 3));
      return r.messages.any((m) => m.data.length >= 2 && m.data[0] == 0x41 && m.data[1] == 0x00);
    } on ElmException {
      return false;
    }
  }

  /// แยกข้อมูลหลังไบต์ตอบรับและเลขคำสั่ง จากคำตอบของกล่อง
  static ExtCmdResult parse(int service, List<int> id, List<List<int>> responses) {
    final ok = service + 0x40;
    int? nrc;
    for (final d in responses) {
      if (d.isEmpty) continue;
      if (d[0] == 0x7F && d.length >= 3 && d[1] == service) {
        if (d[2] == 0x78) continue;
        nrc = d[2];
        continue;
      }
      if (d[0] != ok || d.length < 1 + id.length) continue;
      var match = true;
      for (var i = 0; i < id.length; i++) {
        if (d[1 + i] != id[i]) match = false;
      }
      if (!match) continue;
      return ExtCmdResult(ExtCmdStatus.ok, payload: d.sublist(1 + id.length));
    }
    if (nrc != null) {
      return ExtCmdResult(ExtCmdStatus.negative, nrc: nrc, error: nrcText(nrc));
    }
    return const ExtCmdResult(ExtCmdStatus.silent, error: 'ไม่มีคำตอบ');
  }

  /// คำนวณค่าหนึ่งจากข้อมูลของคำสั่ง
  static ExtReading evaluate(ExtPid p, List<int> payload) {
    final double v;
    try {
      v = Formula(p.formula).eval(payload);
    } catch (e) {
      return ExtReading(raw: payload, error: 'ข้อมูลไม่ตรงกับสูตร (${payload.length} ไบต์)');
    }
    if (v.isNaN || v.isInfinite) return ExtReading(raw: payload, error: 'คำนวณไม่ได้');
    // ตรวจค่าว่างแบบเดียวกับแหล่งข้อมูล (ตัดให้อยู่ในช่วงก่อนแล้วเทียบขอบ)
    var c = v;
    final mn = p.min, mx = p.max;
    if (mn != null && mx != null && mx > mn) c = c.clamp(mn, mx).toDouble();
    const eps = 1e-9;
    if ((p.nullMin != null && c <= p.nullMin! + eps) || (p.nullMax != null && c >= p.nullMax! - eps)) {
      return ExtReading(raw: payload, empty: true, error: 'ไม่มีค่า (เซ็นเซอร์ไม่พร้อม)');
    }
    final out = (mn != null && v < mn - eps) || (mx != null && v > mx + eps) ||
        (p.labels.isNotEmpty && !p.labels.containsKey(v.round()));
    return ExtReading(value: v, raw: payload, outOfRange: out);
  }

  /// แบบเดิม: แยกคำตอบแล้วคำนวณในขั้นเดียว
  static ExtReading decode(ExtPid p, List<List<int>> responses) {
    final r = parse(p.service, p.idBytes, responses);
    if (r.status != ExtCmdStatus.ok) return ExtReading(error: r.error);
    return evaluate(p, r.payload!);
  }

  /// คำสั่งนี้ส่งได้กับโปรโตคอลของรถหรือไม่
  /// (ห้ามส่ง header 29 บิตบนรถ 11 บิต หรือกลับกัน เพราะตัวสแกนจะตัด header เหลือ ID อื่นที่อาจเป็นข้อความของกล่องอื่นในรถ)
  static String? incompatibility(Elm327 elm, ExtPid p) {
    // ด่านอ่านอย่างเดียว: ค่าที่ใช้คำสั่งต้องห้ามอยู่ในชุดได้ แต่ไม่ถูกส่งให้รถ
    final unsafe = p.safetyBlock;
    if (unsafe != null) return 'ไม่ส่งเพื่อความปลอดภัย: $unsafe';
    if (p.isFunctional) return null;
    if (!elm.isCan) return 'รถคันนี้ไม่ใช่ CAN จึงส่งคำสั่งแบบระบุกล่องไม่ได้';
    final long = p.header.length == 8;
    if (elm.is29Bit && !long) return 'คำสั่งนี้เป็นของรถ CAN 11 บิต แต่รถคันนี้เป็น 29 บิต';
    if (!elm.is29Bit && long) return 'คำสั่งนี้เป็นของรถ CAN 29 บิต แต่รถคันนี้เป็น 11 บิต';
    return null;
  }

  /// ส่งคำสั่งหนึ่งไปยังกล่องที่ตั้ง target ไว้แล้ว
  Future<ExtCmdResult> _ask(ExtPid p) async {
    try {
      final r = await elm.query(p.request.toUpperCase(), timeout: const Duration(seconds: 3));
      final rx = p.isFunctional ? null : p.responseHeader;
      final msgs = r.messages.where((m) => rx == null || m.ecu.toUpperCase() == rx).map((m) => m.data).toList();
      return parse(p.service, p.idBytes, msgs);
    } on ElmException catch (e) {
      return ExtCmdResult(ExtCmdStatus.silent, error: e.message);
    }
  }

  /// อ่านหลายค่า: จัดกลุ่มตาม header และส่งคำสั่งที่ซ้ำกันครั้งเดียว
  Future<Map<String, ExtReading>> readAll(
    List<ExtPid> pids, {
    void Function(double progress, String step)? onProgress,
    bool Function()? cancelled,
    Map<String, ExtCmdResult>? commandResults,
    int? responseTimeoutMs,
    bool standardOnly = false,
  }) async {
    carSilent = false;
    final out = <String, ExtReading>{};
    final byTarget = <String, Map<String, List<ExtPid>>>{};
    // คำสั่งที่ไม่มีคำตอบในรอบนี้ (ตัดสินใจทีหลังว่ารถรุ่นนี้ไม่มีคำสั่งนี้ หรือรถไม่ตอบอะไรเลย)
    final silent = <String, List<ExtPid>>{};
    var answered = false;
    for (final p in pids) {
      final why = incompatibility(elm, p) ?? (standardOnly && !p.standardHeader ? notForThisCarText : null);
      if (why != null) {
        out[p.key] = ExtReading(error: why, skipped: true);
        commandResults?[p.cmdKey] = const ExtCmdResult(ExtCmdStatus.skipped);
        continue;
      }
      final t = p.isFunctional ? '' : '${p.header.toUpperCase()}|${p.responseHeader}';
      ((byTarget[t] ??= {})[p.cmdKey] ??= []).add(p);
    }
    final total = byTarget.values.fold<int>(0, (a, m) => a + m.length);
    var done = 0;
    for (final e in byTarget.entries) {
      if (cancelled?.call() ?? false) break;
      await elm.exclusive(() async {
        final targeted = e.key.isNotEmpty;
        final first = e.value.values.first.first;
        try {
          if (targeted) await elm.setTarget(first.header.toUpperCase(), first.responseHeader!);
          if (responseTimeoutMs != null) await elm.setResponseTimeout(responseTimeoutMs);
          for (final c in e.value.entries) {
            if (cancelled?.call() ?? false) break;
            onProgress?.call(total == 0 ? 1 : done / total, c.value.first.request);
            done++;
            if (skip?.contains(c.key) ?? false) {
              for (final p in c.value) {
                out[p.key] = const ExtReading(error: 'ข้าม (รอบก่อนรถไม่ตอบ)', skipped: true);
              }
              commandResults?[c.key] = const ExtCmdResult(ExtCmdStatus.skipped);
              continue;
            }
            final r = await _ask(c.value.first);
            commandResults?[c.key] = r;
            if (r.status == ExtCmdStatus.ok) {
              answered = true;
              skip?.remove('~${c.key}');
              for (final p in c.value) {
                out[p.key] = evaluate(p, r.payload!);
              }
            } else {
              if (r.status == ExtCmdStatus.negative) {
                answered = true;
                skip?.remove('~${c.key}');
                if (nrcPermanent(r.nrc!)) skip?.add(c.key);
              } else {
                silent[c.key] = c.value;
              }
              for (final p in c.value) {
                out[p.key] = ExtReading(error: r.error);
              }
            }
          }
        } finally {
          if (targeted || responseTimeoutMs != null) await elm.resetTarget();
        }
      });
    }
    if (silent.isNotEmpty && !(cancelled?.call() ?? false)) {
      // ไม่มีคำสั่งไหนตอบเลย: ถาม OBD มาตรฐานดูว่ารถยังตอบอยู่ไหม
      // ถ้าไม่ตอบ แปลว่าปิดสวิตช์กุญแจ/ตัวสแกนหลุด ไม่ใช่รถไม่รองรับ (ห้ามจำว่าข้าม)
      if (!answered && !await carResponds()) {
        carSilent = true;
        for (final g in silent.values) {
          for (final p in g) {
            out[p.key] = const ExtReading(error: 'รถไม่ตอบ (เปิดสวิตช์กุญแจอยู่ไหม)');
          }
        }
      } else if (skip != null) {
        // เงียบครั้งแรกจำไว้ก่อน เงียบซ้ำรอบถัดไปจึงข้าม (กันพลาดจากจังหวะที่กล่องไม่ว่างครั้งเดียว)
        for (final k in silent.keys) {
          if (!skip!.add('~$k')) skip!.add(k);
        }
      }
    }
    onProgress?.call(1, '');
    return out;
  }

  /// อ่านข้อมูลดิบของคำสั่งหนึ่ง (ใช้ดูไบต์สดและเทียบค่า)
  Future<ExtCmdResult> readRaw(ExtPid p) async {
    final why = incompatibility(elm, p);
    if (why != null) return ExtCmdResult(ExtCmdStatus.skipped, error: why);
    return elm.exclusive(() async {
      final targeted = !p.isFunctional;
      try {
        if (targeted) await elm.setTarget(p.header.toUpperCase(), p.responseHeader!);
        return await _ask(p);
      } finally {
        if (targeted) await elm.resetTarget();
      }
    });
  }

  /// ทดสอบว่าชุดค่าใช้กับรถคันนี้ได้แค่ไหน (ถามตัวอย่างคำสั่ง ไม่เกิน [maxCommands])
  Future<ExtProbeResult> probe(
    List<ExtPid> pids, {
    int maxCommands = 16,
    void Function(double progress, String step)? onProgress,
    bool Function()? cancelled,
    bool standardOnly = false,
  }) async {
    // เลือกคำสั่งที่มีหลักฐานจากรถจริงก่อน แล้วกระจายให้ครบทุก header
    final byCmd = <String, List<ExtPid>>{};
    var incompatible = 0;
    var notForThisCar = 0;
    for (final p in pids) {
      if (incompatibility(elm, p) != null) {
        incompatible++;
        continue;
      }
      // ชุดของรถคนละรุ่น: ไม่ส่งไปกล่องเลขเฉพาะยี่ห้อ (อาจชนกับข้อความปกติของรถคันนี้)
      if (standardOnly && !p.standardHeader) {
        notForThisCar++;
        continue;
      }
      (byCmd[p.cmdKey] ??= []).add(p);
    }
    final keys = byCmd.keys.toList()
      ..sort((a, b) {
        int rank(String k) => byCmd[k]!.any((p) => p.trust > 0) ? 0 : 1;
        return rank(a).compareTo(rank(b));
      });
    final chosen = <String>[];
    final seenHeaders = <String>{};
    for (final k in keys) {
      final h = k.split('|').first;
      if (!seenHeaders.contains(h)) {
        seenHeaders.add(h);
        chosen.add(k);
      }
    }
    for (final k in keys) {
      if (chosen.length >= maxCommands) break;
      if (!chosen.contains(k)) chosen.add(k);
    }
    if (maxCommands > 0 && chosen.length > maxCommands) chosen.removeRange(maxCommands, chosen.length);
    final sample = [for (final k in chosen) ...byCmd[k]!];
    final results = <String, ExtCmdResult>{};
    // ตั้งเวลารอคำตอบสั้นลง เพราะคำสั่งที่รถไม่รู้จักมักไม่ตอบเลย
    final inner = ExtPidReader(elm);
    final readings = await inner.readAll(sample,
        onProgress: onProgress, cancelled: cancelled, commandResults: results, responseTimeoutMs: 120);
    carSilent = inner.carSilent;
    final responded = results.values.where((r) => r.status == ExtCmdStatus.ok).length;
    final negative = results.values.where((r) => r.status == ExtCmdStatus.negative).length;
    final silent = results.values.where((r) => r.status == ExtCmdStatus.silent).length;
    var tested = 0, okCount = 0, out = 0;
    for (final p in sample) {
      final r = readings[p.key];
      if (r == null || r.raw == null) continue;
      tested++;
      if (r.ok && !r.outOfRange) okCount++;
      if (r.outOfRange) out++;
    }
    return ExtProbeResult(
      incompatible: incompatible,
      commands: results.length,
      responded: responded,
      negative: negative,
      silent: silent,
      readings: readings,
      pidsTested: tested,
      pidsOk: okCount,
      pidsOutOfRange: out,
      carSilent: carSilent,
      notForThisCar: notForThisCar,
    );
  }

  /// ค้นหาว่ากล่องตอบค่าไหนบ้าง (service 21: 00–FF, 22: ช่วงที่กำหนด)
  Future<List<DidHit>> scan({
    required String header,
    required int service,
    required int start,
    required int end,
    void Function(double progress, String current)? onProgress,
    bool Function()? cancelled,
  }) =>
      scanJobs([ScanJob(header: header, service: service, start: start, end: end)],
          onProgress: onProgress, cancelled: cancelled);

  /// ค้นหาหลายช่วง/หลายกล่องต่อกัน
  Future<List<DidHit>> scanJobs(
    List<ScanJob> jobs, {
    void Function(double progress, String current)? onProgress,
    void Function(DidHit hit)? onHit,
    bool Function()? cancelled,
  }) async {
    final hits = <DidHit>[];
    lastScanStats.clear();
    // ถ้ารถไม่ตอบแม้แต่ OBD มาตรฐาน (ปิดสวิตช์กุญแจ) ไม่ต้องไล่ถามเป็นร้อยเลขให้เสียเวลา
    carSilent = !await carResponds();
    if (carSilent) return hits;
    final total = jobs.fold<int>(0, (a, j) => a + j.count);
    var done = 0;
    for (final job in jobs) {
      if (cancelled?.call() ?? false) break;
      final probe = ExtPid(name: 'scan', request: '${_hx(job.service)}00', formula: 'A', header: job.header, rx: job.rx);
      if (incompatibility(elm, probe) != null) {
        done += job.count;
        continue;
      }
      final rx = probe.isFunctional ? null : probe.responseHeader;
      final stat = ScanJobStat(job);
      lastScanStats.add(stat);
      await elm.exclusive(() async {
        final targeted = !probe.isFunctional;
        try {
          if (targeted) await elm.setTarget(job.header.toUpperCase(), rx!);
          await elm.setResponseTimeout(120);
          for (var id = job.start; id <= job.end; id++) {
            if (cancelled?.call() ?? false) break;
            final idHex = job.service == 0x22 ? id.toRadixString(16).padLeft(4, '0').toUpperCase() : _hx(id);
            final req = '${_hx(job.service)}$idHex';
            onProgress?.call(total == 0 ? 1 : done / total, '${job.header.isEmpty ? '' : '${job.header} '}$req');
            done++;
            var replied = false;
            try {
              final r = await elm.query(req, timeout: const Duration(seconds: 2));
              for (final m in r.messages) {
                if (rx != null && m.ecu.toUpperCase() != rx) continue;
                if (m.data.isEmpty) continue;
                if (m.data[0] == job.service + 0x40) {
                  final idLen = job.service == 0x22 ? 2 : 1;
                  if (m.data.length > idLen) {
                    final hit = DidHit(req, m.data.sublist(1 + idLen), header: job.header.toUpperCase(), rx: job.rx);
                    hits.add(hit);
                    stat.found++;
                    onHit?.call(hit);
                  }
                  replied = true;
                  break;
                }
                // กล่องตอบปฏิเสธ (ไม่นับ 78 = ขอเวลาสักครู่)
                if (m.data[0] == 0x7F && m.data.length >= 3 && m.data[1] == job.service && m.data[2] != 0x78) {
                  stat.negative++;
                  stat.nrcs[m.data[2]] = (stat.nrcs[m.data[2]] ?? 0) + 1;
                  replied = true;
                  break;
                }
              }
            } on ElmException {
              // ข้ามรายการที่ไม่ตอบ
            }
            if (!replied) stat.silent++;
          }
        } finally {
          await elm.resetTarget();
        }
      });
    }
    onProgress?.call(1, '');
    return hits;
  }
}

/// ชุดตัวอย่างสำหรับรถจำลองในแอป (ใช้ทดลองหน้าจอเท่านั้น ไม่ใช่ค่าของรถจริงยี่ห้อใด)
ExtPidPack demoPack() => ExtPidPack(
      id: 'demo_pack',
      name: 'ตัวอย่าง (รถจำลอง)',
      note: 'ใช้กับโหมดทดลองเท่านั้น เลขคำสั่งเป็นของรถจำลอง ไม่ใช่ของรถยี่ห้อใด',
      pids: [
        for (var c = 1; c <= 4; c++)
          ExtPid(
            name: 'ชดเชยหัวฉีดสูบ $c',
            request: '22110$c',
            formula: 'S16(A,B)/100',
            header: '7E0',
            unit: 'mm³',
            min: -5,
            max: 5,
            decimals: 2,
            group: 'หัวฉีด',
          ),
        ExtPid(
          name: 'เขม่าสะสมใน DPF',
          request: '221110',
          formula: '(A*256+B)/100',
          header: '7E0',
          unit: 'g',
          min: 0,
          max: 40,
          decimals: 1,
          group: 'DPF',
        ),
        ExtPid(
          name: 'ระยะทางจากการเผา DPF ครั้งล่าสุด',
          request: '221111',
          formula: 'A*256+B',
          header: '7E0',
          unit: 'กม.',
          decimals: 0,
          group: 'DPF',
        ),
        ExtPid(
          name: 'อุณหภูมิน้ำมันเกียร์',
          request: '221201',
          formula: 'A-40',
          header: '7E1',
          unit: '°C',
          min: -40,
          max: 150,
          decimals: 0,
          group: 'เกียร์',
        ),
      ],
    );
