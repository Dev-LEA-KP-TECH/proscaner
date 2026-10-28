// ข้อความไทยบนจอ: ไม่ขึ้นบรรทัดใหม่กลางพยางค์ ทุกขนาดจอ
// ตรวจด้วยตัวจัดบรรทัดจริงของ Flutter (ICU ตัวเดียวกับในเครื่อง Android/iOS): หาทุกจุดที่ยอมให้ขึ้นบรรทัดใหม่
// ของข้อความในฐานรหัสปัญหา ชุดค่าทุกยี่ห้อ ชื่อค่ามาตรฐาน และหน้าเกี่ยวกับ แล้วตรวจทีละจุด (test/support/thai_line_breaks.dart)
import 'dart:convert';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obd_doctor/core/app_info.dart';
import 'package:obd_doctor/core/obd/pids.dart';
import 'package:obd_doctor/ui/theme.dart';

import 'support/thai_line_breaks.dart';

const _wj = '\u2060';
const _zw = '\u200B';
String _visible(String s) => s.replaceAll(_wj, '').replaceAll(_zw, '').replaceAll('\u00A0', ' ');
bool _isBase(int c) => (c >= 0x0E01 && c <= 0x0E2E) || (c >= 0x0E40 && c <= 0x0E44);
bool _isLead(int c) => c >= 0x0E40 && c <= 0x0E44;
bool _isThai(int c) => c >= 0x0E01 && c <= 0x0E5B;

const _style = TextStyle(fontFamily: 'Prompt', fontSize: 14);
List<String> _problems(String s) => thaiBreakProblems(TextSpan(text: s, style: _style));

/// ข้อความที่แอปแสดงจากไฟล์ข้อมูล (ฐานรหัสปัญหา + ชุดค่าทุกยี่ห้อ) และในโค้ด (ชื่อค่ามาตรฐาน หน้าเกี่ยวกับ)
Set<String> _corpus() {
  final out = <String>{...kAboutParagraphs, for (final d in pidTable.values) d.nameTh};
  final dtc = jsonDecode(File('assets/dtc_th.json').readAsStringSync()) as Map<String, dynamic>;
  for (final v in dtc.values) {
    final m = v as Map<String, dynamic>;
    out.add(m['th'] as String? ?? '');
    for (final k in ['causes', 'checks']) {
      out.addAll(((m[k] as List?) ?? const []).cast<String>());
    }
  }
  for (final f in Directory('assets/ext_packs').listSync().whereType<File>()) {
    if (!f.path.endsWith('.json') || f.path.endsWith('index.json')) continue;
    final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    out.add(j['note'] as String? ?? '');
    for (final p in (j['pids'] as List? ?? const [])) {
      final m = p as Map<String, dynamic>;
      out.add(m['name'] as String? ?? '');
      out.add(m['desc'] as String? ?? '');
    }
    for (final s in (j['src'] as List? ?? const [])) {
      if (s is Map<String, dynamic>) out.add(s['changes'] as String? ?? '');
    }
  }
  return out.where((s) => s.codeUnits.any(_isThai)).toSet();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final loader = FontLoader('Prompt');
    final bytes = File('assets/fonts/Prompt-Regular.ttf').readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
  });

  group('thaiKeep', () {
    const samples = [
      'อุณหภูมิน้ำหล่อเย็น',
      'กรองเชื้อเพลิง / กรองโซล่า',
      '19.5 คำสั่ง/วินาที · 242 แถว · หลาย PID ต่อคำสั่ง',
      'จังหวะแคมชาฟท์ไอดีเปิดล่วงหน้าเกินค่า (แคม A)',
      'ISO 15765-4 CAN (11 bit, 500 kbps)',
      'ทุก 10,000 กม. หรือ ทุก 6 เดือน',
      'พบปัญหาร้ายแรง ควรหยุดขับ',
      'เทอร์มินัล',
      'น้ำมันเครื่อง + กรองน้ำมันเครื่อง',
      'Toyota Hilux (Vigo, Revo) / Fortuner',
      'รอบเครื่องยนต์',
      'สายสัญญาณลัดลงกราวด์หรือขาด',
      'ให้ปลดขั้วแบตรอ 3 นาทีก่อน',
      'สัญญาณสวิตช์ครูสคอนโทรล',
      'ระบบต่าง ๆ ของรถยนต์',
      '',
    ];

    test('ตัวอักษรที่มองเห็นเหมือนเดิมทุกตัว และใส่ซ้ำได้ผลเดิม', () {
      for (final s in [...samples, ...kThaiKeepWords, ...kAboutParagraphs]) {
        final k = thaiKeep(s);
        expect(_visible(k), s.replaceAll('\u00A0', ' '), reason: s);
        expect(thaiKeep(k), k, reason: 'ใส่ซ้ำ: $s');
      }
    });

    test('ตัวเชื่อมคำอยู่หน้าพยัญชนะ/สระหน้าเท่านั้น และไม่แยกสระหน้าออกจากพยัญชนะ', () {
      for (final s in [...samples, ...kThaiKeepWords, ...kAboutParagraphs]) {
        final out = thaiKeep(s);
        for (var i = 0; i < out.length; i++) {
          final c = out.codeUnitAt(i);
          if (c != 0x2060 && c != 0x200B) continue;
          expect(i, greaterThan(0), reason: s);
          expect(i + 1, lessThan(out.length), reason: s);
          final prev = out.codeUnitAt(i - 1), next = out.codeUnitAt(i + 1);
          expect(_isLead(prev), isFalse, reason: '$s @$i');
          expect(isThaiDependent(next), isFalse, reason: '$s @$i');
          if (c == 0x2060 && _isThai(prev)) expect(_isBase(next), isTrue, reason: '$s @$i');
          if (c == 0x200B) expect(next == 0x0E46 || next == 0x0E2F, isFalse, reason: '$s @$i');
        }
      }
    });

    test('คำในรายการไม่มีจุดขึ้นบรรทัดใหม่ภายในคำ ไม่ว่าอยู่ตรงไหนของประโยค', () {
      for (final w in kThaiKeepWords) {
        for (final ctx in [w, 'ทดสอบ$wทดสอบ', 'ตรวจ $w และ', 'สาย$wขาด']) {
          final s = thaiKeep(ctx);
          final opps = lineBreakOpportunities(s, _style);
          final g = thaiKeep(w);
          final start = s.indexOf(g);
          expect(start, greaterThanOrEqualTo(0), reason: ctx);
          final inside = opps.where((p) => p > start && p < start + g.length).toList();
          expect(inside, isEmpty, reason: 'ตัดภายในคำ "$w" ใน "$ctx" ที่ $inside');
        }
      }
    });

    test('คำที่เทสต์หน้าจอค้นหาไม่ถูกแก้', () {
      expect(thaiKeep('รอบเครื่องยนต์'), 'รอบเครื่องยนต์');
      expect(thaiKeep('เริ่มทดสอบ ก่อนรีแมพ'), 'เริ่มทดสอบ ก่อนรีแมพ');
      expect(thaiKeep('ทดสอบออกตัว'), 'ทดสอบออกตัว');
    });

    test('คำไทยติดกับเลขหรือตัวอักษรกำกับ ตัวเลขติดหน่วย ชื่อที่มีขีดกลาง', () {
      expect(thaiKeep('ชดเชยหัวฉีดสูบ 1'), 'ชดเชยหัวฉีดสูบ\u00A01');
      expect(thaiKeep('กล่องตอบ 3 รายการ'), 'กล่องตอบ\u00A03\u00A0รายการ');
      expect(thaiKeep('(แคม A แบงก์ 1)'), '(แคม\u00A0A แบงก์\u00A01)');
      expect(thaiKeep('500 kbps'), '500\u00A0kbps');
      expect(thaiKeep('10,000 กม.'), '10,000\u00A0กม.');
      expect(thaiKeep('กม./ชม.'), 'กม./\u2060ชม.');
      expect(thaiKeep('Isuzu D-Max'), 'Isuzu D-\u2060Max');
      expect(thaiKeep('ต่าง ๆ'), 'ต่าง\u00A0ๆ');
    });

    test('ไม่แตะคำที่เป็นส่วนของคำอื่น', () {
      expect(thaiKeep('ครูสอนขับรถ'), 'ครูสอนขับรถ');
      expect(thaiKeep('ทดสอบแคทาไลติก').contains(_zw), isFalse);
    });
  });

  group('ตรวจจุดขึ้นบรรทัดใหม่', () {
    test('กฎจับการตัดกลางพยางค์ได้', () {
      int at(String s, String mark) => s.indexOf(mark);
      expect(thaiBadBreak('สายกราวด์', at('สายกราวด์', 'ด์')), isNotNull);
      expect(thaiBadBreak('แบบเรียลไทม์', at('แบบเรียลไทม์', 'ยล')), isNotNull);
      expect(thaiBadBreak('รอบเทอร์ไบน์', at('รอบเทอร์ไบน์', 'อร์')), isNotNull);
      expect(thaiBadBreak('สัญญาณ', 2), isNotNull);
      expect(thaiBadBreak('แล้ว', 2), isNotNull);
      expect(thaiBadBreak('พิเศษออก', 5), isNull);
      expect(thaiBadBreak('ระบบวิเคราะห์', 4), isNull);
      expect(thaiLoneSegments('แบตรอ', [2, 3]), [2]);
    });

    test('หน้าเกี่ยวกับ: ไม่มีจุดตัดผิดเลย (เดิม "เรี|ยลไทม์" บนจอแคบ)', () {
      // ตัวตรวจต้องเจอจุดผิดของข้อความดิบจริง (ยืนยันว่าตัวตรวจใช้ได้กับตัวจัดบรรทัดของ Flutter)
      expect(_problems(kAboutParagraphs.first).any((p) => p.contains('เรี|ยล')), isTrue);
      expect(_problems('สายสัญญาณลัดลงกราวด์').any((p) => p.contains('กราว|ด์')), isTrue);
      for (final p in kAboutParagraphs) {
        expect(_problems(thaiKeep(p)), isEmpty, reason: p);
      }
    });

    test('ทุกข้อความในฐานรหัสปัญหา ชุดค่าทุกยี่ห้อ และชื่อค่ามาตรฐาน ไม่มีจุดตัดกลางพยางค์', () {
      final corpus = _corpus();
      expect(corpus.length, greaterThan(2000));
      final problems = <String>[];
      for (final s in corpus) {
        problems.addAll(_problems(thaiKeep(s)));
      }
      expect(problems, isEmpty, reason: '${problems.length} จุด:\n${problems.take(60).join('\n')}');
    });
  });
}
