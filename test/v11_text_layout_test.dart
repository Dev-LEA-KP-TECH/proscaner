// ข้อความบนจอ: thaiKeep ต้องไม่เปลี่ยนตัวอักษรที่ผู้ใช้เห็น (เพิ่มได้เฉพาะตัวเชื่อมคำที่มองไม่เห็นและช่องว่างไม่ตัดบรรทัด)
import 'package:flutter_test/flutter_test.dart';
import 'package:obd_doctor/ui/theme.dart';

String _visible(String s) => s.replaceAll('\u2060', '').replaceAll('\u00A0', ' ');

void main() {
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
      '',
    ];

    test('ตัวอักษรที่มองเห็นเหมือนเดิมทุกตัว', () {
      for (final s in samples) {
        expect(_visible(thaiKeep(s)), s, reason: s);
      }
    });

    test('ไม่แยกพยัญชนะออกจากสระ/วรรณยุกต์ และไม่แยกสระหน้าออกจากพยัญชนะ', () {
      for (final s in [...samples, for (final w in kThaiKeepWords) w.replaceAll('|', '')]) {
        final out = thaiKeep(s);
        for (var i = 0; i < out.length; i++) {
          if (out.codeUnitAt(i) != 0x2060) continue;
          expect(i, greaterThan(0), reason: s);
          final prev = out.codeUnitAt(i - 1);
          final next = out.codeUnitAt(i + 1);
          // ก่อนตัวเชื่อม: ไม่ใช่สระหน้า เ แ โ ใ ไ
          expect(prev >= 0x0E40 && prev <= 0x0E44, isFalse, reason: '$s @$i');
          // หลังตัวเชื่อม: พยัญชนะหรือสระหน้าเท่านั้น (ไม่ใช่สระบน/ล่าง วรรณยุกต์ หรือสระอำ)
          final startsSyllable = (next >= 0x0E01 && next <= 0x0E2E) || (next >= 0x0E40 && next <= 0x0E44);
          expect(startsSyllable, isTrue, reason: '$s @$i');
        }
      }
    });

    test('ทุกคำในรายการเชื่อมได้จริง และรอยต่อไม่แยกสระประสม (เ-ือ เ-ีย -ัว เ-อ)', () {
      for (final w in kThaiKeepWords) {
        final plain = w.replaceAll('|', '');
        expect(thaiKeep(plain), w.replaceAll('|', '\u2060'), reason: w);
        final parts = w.split('|');
        for (var i = 1; i < parts.length; i++) {
          // ส่วนถัดไปต้องขึ้นพยางค์ใหม่: ไม่ขึ้นต้นด้วยสระหลัง วรรณยุกต์ หรือ อ (มักเป็นส่วนของสระ เ-อ เ-ือ -ือ)
          // ย ต่อจาก -ี (สระ เ-ีย) และ ว ต่อจาก -ั (สระ -ัว) ก็ห้าม
          final c = parts[i].codeUnitAt(0);
          final prev = parts[i - 1].replaceAll(RegExp('[\u0E48-\u0E4B]'), '');
          final badStart = 'อะาำๅั'.contains(parts[i][0]) ||
              (c >= 0x0E34 && c <= 0x0E3A) ||
              (c >= 0x0E47 && c <= 0x0E4E) ||
              (parts[i][0] == 'ย' && prev.endsWith('ี')) ||
              (parts[i][0] == 'ว' && prev.endsWith('ั'));
          expect(badStart, isFalse, reason: w);
          // ส่วนก่อนหน้าต้องไม่จบด้วยสระหน้า เ แ โ ใ ไ
          expect('เแโใไ'.contains(parts[i - 1][parts[i - 1].length - 1]), isFalse, reason: w);
        }
      }
    });

    test('คำที่เทสต์หน้าจอค้นหาไม่ถูกแก้', () {
      expect(thaiKeep('รอบเครื่องยนต์'), 'รอบเครื่องยนต์');
      expect(thaiKeep('เริ่มทดสอบ ก่อนรีแมพ'), 'เริ่มทดสอบ ก่อนรีแมพ');
      expect(thaiKeep('ทดสอบออกตัว'), 'ทดสอบออกตัว');
    });

    test('คำไทยติดกับเลขหรือตัวอักษรกำกับ', () {
      expect(thaiKeep('ชดเชยหัวฉีดสูบ 1'), 'ชดเชยหัวฉีดสูบ\u00A01');
      expect(thaiKeep('กล่องตอบ 3 รายการ'), 'กล่องตอบ\u00A03\u00A0รายการ');
      expect(thaiKeep('(แคม A แบงก์ 1)'), '(แคม\u00A0A แบงก์\u00A01)');
      expect(thaiKeep('ABS ถุงลม'), contains('ABS '));
    });

    test('ตัวเลขติดหน่วย และคำที่ตัดผิดบ่อยไม่มีจุดตัดกลางคำ', () {
      expect(thaiKeep('500 kbps'), '500\u00A0kbps');
      expect(thaiKeep('10,000 กม.'), '10,000\u00A0กม.');
      expect(thaiKeep('น้ำหล่อเย็น').contains('\u2060'), isTrue);
      expect(thaiKeep('กม./ชม.'), 'กม./\u2060ชม.');
    });
  });
}
