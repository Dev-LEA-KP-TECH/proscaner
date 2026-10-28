import 'package:flutter_test/flutter_test.dart';
import 'package:obd_doctor/core/elm/response_parser.dart';
import 'package:obd_doctor/core/obd/obd_service.dart';

void main() {
  group('CAN 11 บิต เปิด header', () {
    test('แยกคำตอบจาก 2 ECU', () {
      const raw = '7E8 06 41 00 BE 3F B8 13 55\r7E9 06 41 00 98 18 00 01 55\r\r';
      final r = ResponseParser.parse(raw);
      expect(r.messages.length, 2);
      expect(r.messages[0].ecu, '7E8');
      expect(r.messages[0].data, [0x41, 0x00, 0xBE, 0x3F, 0xB8, 0x13]);
      expect(r.messages[1].ecu, '7E9');
      expect(r.messages[1].data, [0x41, 0x00, 0x98, 0x18, 0x00, 0x01]);
    });

    test('ไม่มีช่องว่าง + มีคำว่า SEARCHING', () {
      const raw = 'SEARCHING...\r7E8044 10C1AF8555555\r';
      final r = ResponseParser.parse(raw.replaceAll(' ', ''));
      expect(r.messages.single.data, [0x41, 0x0C, 0x1A, 0xF8]);
    });

    test('ประกอบ VIN หลายเฟรม (ISO-TP)', () {
      const raw = '7E8 10 14 49 02 01 4D 52 30\r'
          '7E8 21 46 5A 32 32 47 38 30\r'
          '7E8 22 31 32 33 34 35 36 37\r';
      final r = ResponseParser.parse(raw);
      expect(r.messages.single.data.length, 20);
      expect(decodeVin(r.messages, isCan: true), 'MR0FZ22G801234567');
    });
  });

  test('CAN 29 บิต', () {
    const raw = '18DAF110 04 41 0C 1A F8 00 00 00\r';
    final r = ResponseParser.parse(raw, format: HeaderFormat.can29);
    expect(r.messages.single.ecu, '18DAF110');
    expect(r.messages.single.data, [0x41, 0x0C, 0x1A, 0xF8]);
  });

  test('โปรโตคอลเก่า: ตัด header 3 ไบต์และ checksum', () {
    const raw = '48 6B 10 41 0C 1A F8 C9\r';
    final r = ResponseParser.parse(raw, format: HeaderFormat.legacy);
    expect(r.messages.single.ecu, '10');
    expect(r.messages.single.data, [0x41, 0x0C, 0x1A, 0xF8]);
  });

  group('ปิด header', () {
    test('บรรทัดเดียว', () {
      final r = ResponseParser.parse('41 0C 1A F8\r', format: HeaderFormat.none);
      expect(r.messages.single.data, [0x41, 0x0C, 0x1A, 0xF8]);
    });

    test('ข้อความยาวรูปแบบ 014 / 0: / 1:', () {
      const raw = '014\r0: 49 02 01 4D 52 30\r1: 46 5A 32 32 47 38 30\r2: 31 32 33 34 35 36 37\r';
      final r = ResponseParser.parse(raw, format: HeaderFormat.none);
      expect(r.messages.single.data.length, 20);
      expect(decodeVin(r.messages, isCan: true), 'MR0FZ22G801234567');
    });
  });

  group('ข้อผิดพลาด', () {
    test('NO DATA', () {
      final r = ResponseParser.parse('NO DATA\r\r');
      expect(r.isOk, false);
      expect(r.error, ElmError.noData);
    });

    test('UNABLE TO CONNECT', () {
      final r = ResponseParser.parse('SEARCHING...\rUNABLE TO CONNECT\r');
      expect(r.error, ElmError.unableToConnect);
    });

    test('คำสั่งไม่รู้จัก', () {
      expect(ResponseParser.parse('?\r').error, ElmError.unknownCommand);
    });
  });

  test('แปลงรหัสโปรโตคอลจาก ATDPN', () {
    expect(ResponseParser.headerFormatFor('A6'), HeaderFormat.can11);
    expect(ResponseParser.headerFormatFor('7'), HeaderFormat.can29);
    expect(ResponseParser.headerFormatFor('A3'), HeaderFormat.legacy);
    expect(ResponseParser.headerFormatFor('6', headersOn: false), HeaderFormat.none);
  });
}
