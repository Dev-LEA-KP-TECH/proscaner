import 'package:flutter_test/flutter_test.dart';
import 'package:obd_doctor/core/elm/elm327.dart';
import 'package:obd_doctor/core/obd/dtc.dart';
import 'package:obd_doctor/core/obd/obd_service.dart';
import 'package:obd_doctor/core/obd/pids.dart';
import 'package:obd_doctor/core/transport/demo_transport.dart';

/// ทดสอบทุกชั้นต่อกันจริง: ตัวจำลอง → ELM327 → ตัวแยกคำตอบ → คำสั่ง OBD
void main() {
  late DemoTransport transport;
  late Elm327 elm;
  late ObdService svc;

  setUp(() async {
    transport = DemoTransport(responseDelay: const Duration(milliseconds: 1));
    await transport.connect();
    elm = Elm327(transport)..attach();
    await elm.initialize();
    svc = ObdService(elm);
  });

  tearDown(() async {
    await elm.detach();
    await transport.disconnect();
  });

  test('เริ่มต้นตัวสแกนและรู้จักโปรโตคอล', () {
    expect(elm.version, contains('ELM327'));
    expect(elm.protocolCode, 'A6');
    expect(elm.isCan, true);
    expect(elm.protocolLabel, contains('CAN (11 bit, 500'));
  });

  test('อ่าน PID ที่รองรับข้ามหลายช่วง (00, 20, 40)', () async {
    final s = await svc.loadSupportedPids();
    expect(s, containsAll([Pid.rpm, Pid.coolantTemp, Pid.fuelLevel, Pid.moduleVoltage, Pid.oilTemp]));
  });

  test('อ่านค่าสด', () async {
    final rpm = await svc.readPid(Pid.rpm);
    expect(rpm, inInclusiveRange(700, 850));
    final ltft = await svc.readPid(Pid.ltftB1);
    expect(ltft, closeTo(14, 1));
  });

  test('อ่านรหัสทั้ง 3 ประเภท และ VIN หลายเฟรม', () async {
    expect((await svc.readDtcs(DtcKind.stored)).map((d) => d.code), ['P0171', 'P0301']);
    expect((await svc.readDtcs(DtcKind.pending)).map((d) => d.code), ['P0420']);
    expect((await svc.readDtcs(DtcKind.permanent)).map((d) => d.code), ['P0171']);
    expect(await svc.readVin(), 'MR0FZ22G801234567');
    final m = await svc.readMonitorStatus();
    expect(m!.milOn, true);
    expect(m.dtcCount, 2);
  });

  test('ลบรหัส: stored/pending หาย แต่ permanent ยังอยู่', () async {
    expect(await svc.clearDtcs(), true);
    expect(await svc.readDtcs(DtcKind.stored), isEmpty);
    expect(await svc.readDtcs(DtcKind.pending), isEmpty);
    expect((await svc.readDtcs(DtcKind.permanent)).single.code, 'P0171');
  });

  test('คำสั่งที่ส่งพร้อมกันถูกต่อคิว ไม่ปนกัน', () async {
    final results = await Future.wait([
      svc.readPid(Pid.rpm),
      svc.readPid(Pid.coolantTemp),
      svc.readPid(Pid.moduleVoltage),
    ]);
    expect(results[0], inInclusiveRange(700, 850));
    expect(results[1], inInclusiveRange(60, 95));
    expect(results[2], closeTo(14.1, 0.2));
  });
}
