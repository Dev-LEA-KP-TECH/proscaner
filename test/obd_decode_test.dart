import 'package:flutter_test/flutter_test.dart';
import 'package:obd_doctor/core/elm/response_parser.dart';
import 'package:obd_doctor/core/obd/dtc.dart';
import 'package:obd_doctor/core/obd/pids.dart';
import 'package:obd_doctor/core/transport/demo_transport.dart';

void main() {
  group('รหัสปัญหา', () {
    test('แปลง 2 ไบต์เป็นรหัส', () {
      expect(decodeDtcBytes(0x01, 0x71), 'P0171');
      expect(decodeDtcBytes(0x03, 0x01), 'P0301');
      expect(decodeDtcBytes(0xC1, 0x00), 'U0100');
      expect(decodeDtcBytes(0x42, 0x34), 'C0234');
      expect(decodeDtcBytes(0x9A, 0x12), 'B1A12');
    });

    test('แปลงไปกลับกับตัวจำลองได้ตรงกัน', () {
      for (final code in ['P0171', 'P2463', 'U0101', 'C1234', 'B2AFF']) {
        final b = DemoTransport.encodeDtc(code);
        expect(decodeDtcBytes(b[0], b[1]), code);
      }
    });

    test('CAN มีไบต์จำนวน และข้าม ECU ที่ไม่มีโค้ด', () {
      final msgs = [
        const EcuMessage('7E8', [0x43, 0x02, 0x01, 0x71, 0x03, 0x01]),
        const EcuMessage('7E9', [0x43, 0x00]),
      ];
      final dtcs = parseDtcMessages(msgs, DtcKind.stored, isCan: true);
      expect(dtcs.map((d) => d.code), ['P0171', 'P0301']);
      expect(dtcs.first.ecu, '7E8');
    });

    test('โปรโตคอลเก่า ไม่มีไบต์จำนวน เติม 0000', () {
      final msgs = [
        const EcuMessage('10', [0x43, 0x01, 0x71, 0x03, 0x01, 0x00, 0x00]),
      ];
      final dtcs = parseDtcMessages(msgs, DtcKind.stored, isCan: false);
      expect(dtcs.map((d) => d.code), ['P0171', 'P0301']);
    });

    test('ไม่ปนกับคำตอบของ mode อื่น', () {
      final msgs = [const EcuMessage('7E8', [0x47, 0x01, 0x04, 0x20])];
      expect(parseDtcMessages(msgs, DtcKind.stored, isCan: true), isEmpty);
      expect(parseDtcMessages(msgs, DtcKind.pending, isCan: true).single.code, 'P0420');
    });
  });

  group('สูตร PID', () {
    test('รอบเครื่อง', () => expect(pidTable[Pid.rpm]!.decode([0x1A, 0xF8]), 1726));
    test('อุณหภูมิน้ำ', () => expect(pidTable[Pid.coolantTemp]!.decode([0x7B]), 83));
    test('Fuel trim', () => expect(pidTable[Pid.ltftB1]!.decode([0x92]), closeTo(14.06, 0.01)));
    test('แรงดันไฟ', () => expect(pidTable[Pid.moduleVoltage]!.decode([0x37, 0x14]), closeTo(14.1, 0.01)));
    test('MAF', () => expect(pidTable[Pid.maf]!.decode([0x01, 0x22]), closeTo(2.9, 0.001)));

    test('บิตแมสก์ PID ที่รองรับ', () {
      final s = decodeSupportMask(0x00, [0xBE, 0x3F, 0xB8, 0x13]);
      expect(s, containsAll([0x01, 0x05, 0x0C, 0x0D, 0x1F, 0x20]));
      expect(s.contains(0x02), false);
    });

    test('สถานะไฟเตือน', () {
      final m = MonitorStatus.decode([0x82, 0x07, 0x65, 0x00]);
      expect(m.milOn, true);
      expect(m.dtcCount, 2);
      expect(m.isDiesel, false);
    });
  });
}
