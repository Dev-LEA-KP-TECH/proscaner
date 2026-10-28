import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// ระดับความรุนแรง เรียงจากเบาไปหนัก
enum Severity {
  info,
  low,
  medium,
  high;

  String get labelTh => switch (this) {
        Severity.info => 'ข้อมูล',
        Severity.low => 'ขับต่อได้',
        Severity.medium => 'ควรเข้าอู่',
        Severity.high => 'หยุดขับ',
      };

  /// คำแนะนำสำหรับเจ้าของรถ
  String get ownerAdvice => switch (this) {
        Severity.info => 'ไม่ต้องทำอะไรเพิ่ม',
        Severity.low => 'ยังขับได้ตามปกติ ให้ช่างตรวจในรอบบำรุงรักษาถัดไป',
        Severity.medium => 'ขับได้แต่ควรนำรถเข้าอู่ภายใน 1–2 สัปดาห์ ถ้ารถมีอาการผิดปกติให้เข้าเร็วขึ้น',
        Severity.high => 'หยุดขับเมื่อปลอดภัย การขับต่ออาจทำให้เครื่องยนต์เสียหายหนัก ควรเรียกช่างหรือรถยก',
      };

  static Severity parse(String? s) =>
      Severity.values.firstWhere((v) => v.name == s, orElse: () => Severity.medium);

  bool operator >(Severity other) => index > other.index;

  Severity lower() => index == 0 ? this : Severity.values[index - 1];
}

class DtcInfo {
  const DtcInfo({
    required this.code,
    required this.descriptionTh,
    required this.severity,
    this.causes = const [],
    this.checks = const [],
    this.isFallback = false,
  });

  final String code;
  final String descriptionTh;
  final Severity severity;
  final List<String> causes;
  final List<String> checks;

  /// true = ไม่มีในฐานข้อมูล ใช้คำอธิบายตามหมวดของรหัสแทน
  final bool isFallback;
}

/// ฐานคำอธิบายรหัสปัญหาภาษาไทย โหลดจาก assets/dtc_th.json
class DtcDatabase {
  DtcDatabase(Map<String, dynamic> json) {
    json.forEach((code, v) {
      final m = v as Map<String, dynamic>;
      _entries[code.toUpperCase()] = DtcInfo(
        code: code.toUpperCase(),
        descriptionTh: m['th'] as String,
        severity: Severity.parse(m['sev'] as String?),
        causes: (m['causes'] as List<dynamic>? ?? const []).cast<String>(),
        checks: (m['checks'] as List<dynamic>? ?? const []).cast<String>(),
      );
    });
  }

  factory DtcDatabase.fromJsonString(String s) =>
      DtcDatabase(jsonDecode(s) as Map<String, dynamic>);

  static Future<DtcDatabase> load() async =>
      DtcDatabase.fromJsonString(await rootBundle.loadString('assets/dtc_th.json'));

  final _entries = <String, DtcInfo>{};

  int get length => _entries.length;

  /// รหัสทั้งหมดในฐานข้อมูล เรียงตามรหัส
  static int _rank(String code) => switch (code.isEmpty ? 'P' : code[0]) { 'P' => 0, 'C' => 1, 'B' => 2, _ => 3 };

  /// เรียง P → C → B → U แล้วตามรหัส (รหัสเครื่องยนต์ที่ใช้บ่อยขึ้นก่อน)
  List<DtcInfo> get all => _entries.values.toList()
    ..sort((a, b) {
      final r = _rank(a.code).compareTo(_rank(b.code));
      return r != 0 ? r : a.code.compareTo(b.code);
    });

  /// ค้นหาด้วยรหัสหรือคำภาษาไทย ถ้าพิมพ์รหัสเต็มที่ไม่มีในฐาน จะได้คำอธิบายตามหมวด
  List<DtcInfo> search(String query) {
    final q = query.trim().toUpperCase();
    if (q.isEmpty) return all;
    final hits = all.where((e) => e.code.contains(q) || e.descriptionTh.toUpperCase().contains(q)).toList();
    if (hits.isEmpty && RegExp(r'^[PCBU][0-3][0-9A-F]{3}$').hasMatch(q)) return [lookup(q)];
    return hits;
  }

  DtcInfo lookup(String rawCode) {
    final code = rawCode.toUpperCase();
    final exact = _entries[code];
    if (exact != null) return exact;

    // P0301–P0312: จุดระเบิดไม่สมบูรณ์รายสูบ
    final misfire = RegExp(r'^P03(0[1-9]|1[0-2])$').firstMatch(code);
    if (misfire != null) {
      final cyl = int.parse(misfire.group(1)!);
      return DtcInfo(
        code: code,
        descriptionTh: 'สูบที่ $cyl จุดระเบิดไม่สมบูรณ์ (Misfire)',
        severity: Severity.high,
        causes: const ['หัวเทียนเสื่อม', 'คอยล์จุดระเบิดเสีย', 'หัวฉีดสูบนั้นตันหรือรั่ว', 'กำลังอัดสูบนั้นต่ำ'],
        checks: [
          'สลับคอยล์สูบ $cyl กับสูบข้างเคียง ถ้าอาการย้ายตาม = คอยล์เสีย',
          'ถอดหัวเทียนสูบ $cyl ดูสภาพ',
          'วัดกำลังอัดถ้าเปลี่ยนคอยล์และหัวเทียนแล้วยังเป็น',
        ],
      );
    }

    // P0201–P0212: วงจรหัวฉีดรายสูบ
    final injector = RegExp(r'^P02(0[1-9]|1[0-2])$').firstMatch(code);
    if (injector != null) {
      final cyl = int.parse(injector.group(1)!);
      return DtcInfo(
        code: code,
        descriptionTh: 'วงจรหัวฉีดสูบที่ $cyl ผิดปกติ',
        severity: Severity.medium,
        causes: const ['ขั้วต่อหัวฉีดหลวม', 'สายไฟขาด', 'หัวฉีดเสีย'],
        checks: ['ตรวจขั้วต่อหัวฉีดสูบ $cyl', 'วัดความต้านทานหัวฉีดเทียบสูบอื่น'],
      );
    }

    return _fallback(code);
  }

  DtcInfo _fallback(String code) {
    final system = switch (code.isEmpty ? '' : code[0]) {
      'P' => 'ระบบส่งกำลัง (เครื่องยนต์/เกียร์)',
      'C' => 'ระบบช่วงล่าง/เบรก/พวงมาลัย',
      'B' => 'ระบบตัวถังและไฟฟ้าภายในรถ',
      'U' => 'ระบบสื่อสารระหว่างกล่องควบคุม',
      _ => 'ไม่ทราบระบบ',
    };
    final isGeneric = code.length == 5 && code[1] == '0';
    String? group;
    if (code.startsWith('P') && code.length == 5) {
      group = switch (code[2]) {
        '0' || '1' || '2' => 'การวัดอากาศและเชื้อเพลิง',
        '3' => 'ระบบจุดระเบิด/การจุดระเบิดไม่สมบูรณ์',
        '4' => 'ระบบควบคุมไอเสีย',
        '5' => 'ความเร็วรถ รอบเดินเบา และอินพุตเสริม',
        '6' => 'กล่องควบคุมและวงจรเอาต์พุต',
        '7' || '8' || '9' => 'ระบบเกียร์',
        'A' || 'B' || 'C' => 'ระบบขับเคลื่อนไฮบริด',
        _ => null,
      };
    }
    final desc = StringBuffer('รหัส$system')
      ..write(group != null ? ' หมวด$group' : '')
      ..write(isGeneric ? '' : ' (รหัสเฉพาะผู้ผลิต)');
    return DtcInfo(
      code: code,
      descriptionTh: desc.toString(),
      severity: Severity.medium,
      causes: const [],
      checks: const ['ค้นหาความหมายรหัสนี้ในคู่มือซ่อมของรุ่นรถ'],
      isFallback: true,
    );
  }
}
