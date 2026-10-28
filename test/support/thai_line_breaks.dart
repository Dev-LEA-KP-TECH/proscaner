// ตรวจจุดขึ้นบรรทัดใหม่ของข้อความไทย (ใช้ร่วมกันใน test/ และ test_screens/)
// จุดที่ผิด = ตัดกลางพยางค์ เช่น ขึ้นบรรทัดด้วยสระ/วรรณยุกต์ ("แล|้ว"), สระหน้าค้างท้ายบรรทัด ("เ|ก"),
// แยกไม้หันอากาศ/สระอือ/เ-ีย/เ-ือ/เ-อ ออกจากตัวสะกด ("สั|ญญาณ", "เรี|ยลไทม์", "เท|อร์โบ"), ตัวการันต์ขึ้นบรรทัดใหม่ ("กราว|ด์"),
// แยก รร และพยัญชนะตัวเดียวหลุดเป็นท่อน ("แบ|ต|รอ", "ครู|ส|คอนโทรล")
import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:obd_doctor/ui/theme.dart' show isThaiDependent;

bool _invisible(int c) => c == 0x2060 || c == 0x200B;
bool _thai(int c) => c >= 0x0E01 && c <= 0x0E5B;
bool _cons(int c) => c >= 0x0E01 && c <= 0x0E2E;
bool _lead(int c) => c >= 0x0E40 && c <= 0x0E44;
bool _tone(int c) => c >= 0x0E48 && c <= 0x0E4B;

const _c = '[ก-ฮ]';
const _cluster2 = '[กขคตปพผบดท][รลว]';
const _hoLead = 'ห[งญนมยรลว]';
final _eUpper = RegExp('เ($_c|$_cluster2|$_hoLead)[ิีึื]\$');
final _eOpen = RegExp('เ($_c|$_cluster2|$_hoLead|อย)\$');
final _rr = RegExp('(^|[^ก-ฮ])$_cร\$');
final _vowelAfterO = 'ะัาำิีึืุู่้๊๋'.codeUnits.toSet();

/// เหตุผล ถ้าการขึ้นบรรทัดใหม่ก่อนตำแหน่ง [at] ของ [s] ตัดกลางพยางค์ไทย (ไม่ผิดคืน null)
String? thaiBadBreak(String s, int at) {
  var i = at, j = at;
  while (i > 0 && _invisible(s.codeUnitAt(i - 1))) {
    i--;
  }
  while (j < s.length && _invisible(s.codeUnitAt(j))) {
    j++;
  }
  if (i <= 0 || j >= s.length) return null;
  final prev = s.codeUnitAt(i - 1), next = s.codeUnitAt(j);
  if (!_thai(prev) || !_thai(next)) return null;
  if (isThaiDependent(next) || next == 0x0E46 || next == 0x0E2F) return 'ขึ้นบรรทัดด้วยสระ/วรรณยุกต์';
  if (_lead(prev)) return 'สระหน้าค้างท้ายบรรทัด';
  final core = String.fromCharCodes(s.substring(math.max(0, i - 8), i).codeUnits.where((c) => !_tone(c) && !_invisible(c)));
  if (core.endsWith('ั')) return 'แยกไม้หันอากาศ';
  if (core.endsWith('ื') || core.endsWith('ึ')) return 'แยกสระอือ/อึ';
  if (_eUpper.hasMatch(core)) return 'แยกสระเ-ีย/เ-ือ/เ-ิ';
  final b = s.substring(j);
  if (next == 0x0E2D && _eOpen.hasMatch(core)) {
    final n1 = b.length > 1 ? b.codeUnitAt(1) : -1;
    final n2 = b.length > 2 ? b.codeUnitAt(2) : -1;
    final newSyllable = _vowelAfterO.contains(n1) || n1 == 0x0E2D || (n1 == 0x0E22 && _vowelAfterO.contains(n2));
    if (!newSyllable) return 'แยกสระเ-อ';
  }
  if (b.length >= 2 &&
      _cons(next) &&
      (b.codeUnitAt(1) == 0x0E4C || (b.length >= 3 && (b.codeUnitAt(1) == 0x0E34 || b.codeUnitAt(1) == 0x0E38) && b.codeUnitAt(2) == 0x0E4C))) {
    return 'ตัวการันต์ขึ้นบรรทัดใหม่';
  }
  if (next == 0x0E23 && _rr.hasMatch(core)) return 'แยก รร';
  return null;
}

/// ท่อนระหว่างจุดขึ้นบรรทัดใหม่ที่เป็นพยัญชนะตัวเดียว (กับวรรณยุกต์/การันต์) ติดกับคำไทย = ถูกตัดผิด
/// คืนตำแหน่งต้นท่อนนั้น
List<int> thaiLoneSegments(String s, List<int> breaks) {
  final cuts = [0, ...breaks, s.length];
  final out = <int>[];
  for (var k = 0; k + 1 < cuts.length; k++) {
    final a = cuts[k], b = cuts[k + 1];
    if (b <= a) continue;
    var seg = String.fromCharCodes(s.substring(a, b).codeUnits.where((c) => !_invisible(c)));
    seg = seg.replaceAll(RegExp('[ \u00A0]+\$'), '');
    if (seg.isEmpty || !_cons(seg.codeUnitAt(0))) continue;
    if (!seg.codeUnits.skip(1).every((c) => c >= 0x0E47 && c <= 0x0E4E)) continue;
    if (seg == 'ณ' || seg == 'ธ' || seg == 'ก็') continue;
    var l = a, r = b;
    while (l > 0 && _invisible(s.codeUnitAt(l - 1))) {
      l--;
    }
    while (r < s.length && _invisible(s.codeUnitAt(r))) {
      r++;
    }
    final thaiLeft = l > 0 && _thai(s.codeUnitAt(l - 1));
    final thaiRight = r < s.length && _thai(s.codeUnitAt(r));
    if (thaiLeft || thaiRight) out.add(a);
  }
  return out;
}

/// ทุกจุดที่ตัวจัดบรรทัดของ Flutter (ICU ตัวเดียวกับในเครื่อง) ยอมให้ขึ้นบรรทัดใหม่ ภายในช่วงอักษรไทยของข้อความบรรทัดเดียว
/// วิธีหา: วางข้อความต่อท้ายคำนำยาว ๆ ("WWW…W ") แล้วบีบความกว้างให้พอดีถึงแต่ละตำแหน่ง บรรทัดแรกจบที่จุดตัดสุดท้ายก่อนตำแหน่งนั้นเสมอ
/// คำนำต้องยาวกว่าทุกคำในข้อความ: ถ้าบรรทัดแคบกว่าคำ ตัวจัดบรรทัดจะหักคำนั้นกลางตัวอักษรทันที (ไม่ใช่จุดตัดจริง)
/// จุดตัดขึ้นกับตัวอักษรเท่านั้น ไม่ขึ้นกับความกว้างจอหรือขนาดตัวอักษร
List<int> lineBreakOpportunities(String line, TextStyle? style) {
  final n = line.length;
  final prefix = '${'W' * (2 * n + 4)} ';
  final k = prefix.length;
  final tp = TextPainter(text: TextSpan(text: '$prefix$line', style: style), textDirection: TextDirection.ltr)..layout();
  // ตำแหน่งเคอร์เซอร์หลังตัวอักษรที่กว้างศูนย์ (ตัวเชื่อมคำ ฯลฯ) อาจได้ค่า 0 ใช้ค่าก่อนหน้าแทน
  // (ความกว้างที่ลองต้องไม่แคบกว่าคำนำ ไม่อย่างนั้นตัวจัดบรรทัดหักคำนำทีละตัวอักษร ช้ามาก)
  final xs = <double>[];
  for (var p = 0; p <= n; p++) {
    final x = tp.getOffsetForCaret(TextPosition(offset: p + k), Rect.zero).dx;
    xs.add(p == 0 ? x : math.max(x, xs[p - 1]));
  }
  final out = <int>{};
  for (var p = 1; p < n; p++) {
    final c = line.codeUnitAt(p), before = line.codeUnitAt(p - 1);
    if (!(_thai(c) || _invisible(c)) || !(_thai(before) || _invisible(before))) continue;
    if (xs[p] <= xs[0]) continue;
    tp.layout(maxWidth: xs[p] + 0.5);
    final end = tp.getLineBoundary(const TextPosition(offset: 0)).end - k;
    if (end > 0 && end < n) out.add(end);
  }
  tp.dispose();
  return out.toList()..sort();
}

/// ปัญหาการขึ้นบรรทัดใหม่ทั้งหมดของข้อความ (ทุกบรรทัดที่ขึ้นด้วย \n): "ข้อความก่อน|ข้อความหลัง (เหตุผล)"
List<String> thaiBreakProblems(InlineSpan text) {
  final all = text.toPlainText();
  if (!all.codeUnits.any(_thai)) return const [];
  final style = text is TextSpan ? text.style : null;
  final out = <String>[];
  for (final s in all.split('\n')) {
    if (!s.codeUnits.any(_thai)) continue;
    final opps = lineBreakOpportunities(s, style);
    String ctx(int at) {
      final from = math.max(0, at - 10), to = math.min(s.length, at + 10);
      String clean(String t) => String.fromCharCodes(t.codeUnits.where((c) => !_invisible(c)));
      return '${clean(s.substring(from, at))}|${clean(s.substring(at, to))}';
    }

    for (final at in opps) {
      final why = thaiBadBreak(s, at);
      if (why != null) out.add('${ctx(at)} ($why)');
    }
    for (final at in thaiLoneSegments(s, opps)) {
      out.add('${ctx(at)} (พยัญชนะตัวเดียวหลุด)');
    }
  }
  return out;
}
