import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import 'ext_pid.dart';

/// รายการชุดค่าในคลังของแอป (ไฟล์ assets/ext_packs)
class ExtLibraryEntry {
  const ExtLibraryEntry({
    required this.file,
    required this.lib,
    required this.name,
    required this.brand,
    required this.models,
    required this.years,
    required this.count,
    required this.evidenceCount,
    required this.evidenceYears,
    required this.commands,
    required this.sources,
    this.scan = const [],
    this.kind = 'truck',
  });

  final String file;
  final String lib;
  final String name;
  final String brand;
  final List<String> models;
  final List<int> years;
  final int count;

  /// จำนวนค่าที่แหล่งข้อมูลเคยพบในรถจริง
  final int evidenceCount;
  final List<int> evidenceYears;
  final int commands;
  final List<String> sources;

  /// ช่วงค้นหาที่น่าจะเจอค่าของรุ่นนี้
  final List<ScanJob> scan;

  /// 'truck' = กระบะ/PPV/รถตู้, 'car' = รถเก๋ง/อเนกประสงค์
  final String kind;

  String get yearsText {
    if (years.length < 2) return '';
    if (years[0] == years[1]) return '${years[0]}';
    return years[1] >= DateTime.now().year ? '${years[0]} ขึ้นไป' : '${years[0]}–${years[1]}';
  }

  factory ExtLibraryEntry.fromJson(Map<String, dynamic> j) => ExtLibraryEntry(
        file: j['file'] as String,
        lib: j['lib'] as String,
        name: j['name'] as String,
        brand: j['brand'] as String? ?? '',
        models: [for (final m in (j['models'] as List<dynamic>? ?? const [])) '$m'],
        years: [for (final y in (j['years'] as List<dynamic>? ?? const [])) (y as num).toInt()],
        count: (j['count'] as num?)?.toInt() ?? 0,
        evidenceCount: (j['evCount'] as num?)?.toInt() ?? 0,
        evidenceYears: [for (final y in (j['evy'] as List<dynamic>? ?? const [])) (y as num).toInt()],
        commands: (j['cmds'] as num?)?.toInt() ?? 0,
        sources: [for (final s in (j['src'] as List<dynamic>? ?? const [])) '$s'],
        kind: j['kind'] as String? ?? 'truck',
        scan: [
          for (final s in (j['scan'] as List<dynamic>? ?? const []))
            ScanJob(
              header: (s as Map<String, dynamic>)['h'] as String,
              rx: s['rx'] as String?,
              service: (s['s'] as num).toInt(),
              start: (s['a'] as num).toInt(),
              end: (s['b'] as num).toInt(),
            ),
        ],
      );

  /// รถคันนี้น่าจะใช้ชุดนี้ได้ (จากยี่ห้อ/รุ่น/ปี)
  int matchScore({String? brand, String? model, int? year}) {
    var s = 0;
    if (brand != null && brand.isNotEmpty && this.brand.toLowerCase() == brand.toLowerCase()) s += 2;
    if (model != null && model.isNotEmpty) {
      final m = model.toLowerCase();
      if (models.any((x) => m.contains(x.toLowerCase()) || x.toLowerCase().contains(m))) s += 3;
    }
    if (year != null && years.length == 2 && year >= years[0] && year <= years[1]) s += 1;
    return s;
  }
}

/// คลังชุดค่าที่มากับแอป
class ExtLibrary {
  ExtLibrary({Future<String> Function(String path)? loader}) : _load = loader ?? rootBundle.loadString;

  static const base = 'assets/ext_packs/';
  final Future<String> Function(String path) _load;
  final _cache = <String, ExtPidPack>{};
  List<ExtLibraryEntry>? _index;
  int version = 0;

  Future<List<ExtLibraryEntry>> index() async {
    if (_index != null) return _index!;
    final j = jsonDecode(await _load('${base}index.json')) as Map<String, dynamic>;
    version = (j['version'] as num?)?.toInt() ?? 0;
    return _index = [
      for (final e in (j['packs'] as List<dynamic>? ?? const [])) ExtLibraryEntry.fromJson(e as Map<String, dynamic>),
    ];
  }

  /// โหลดชุดเต็ม (ได้สำเนาใหม่ทุกครั้ง แก้ไขได้โดยไม่กระทบคลัง)
  Future<ExtPidPack> pack(ExtLibraryEntry e) async {
    final cached = _cache[e.file] ??=
        ExtPidPack.fromJson(jsonDecode(await _load('$base${e.file}')) as Map<String, dynamic>);
    return cached.copyWithId(cached.id);
  }
}
