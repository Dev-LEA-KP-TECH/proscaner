import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:obd_doctor/core/diagnosis/diagnosis.dart';
import 'package:obd_doctor/core/diagnosis/report_text.dart';
import 'package:obd_doctor/core/elm/elm327.dart';
import 'package:obd_doctor/core/obd/dtc.dart';
import 'package:obd_doctor/core/obd/dtc_database.dart';
import 'package:obd_doctor/core/obd/obd_service.dart';
import 'package:obd_doctor/core/obd/pids.dart';
import 'package:obd_doctor/core/transport/demo_transport.dart';
import 'package:obd_doctor/state/settings.dart';

void main() {
  group('Readiness', () {
    test('รถเบนซิน ทุกระบบเสร็จ', () {
      final m = decodeReadiness([0x82, 0x07, 0x65, 0x00]);
      expect(m.length, 7); // 3 แบบต่อเนื่อง + 4 ระบบ (บิต 0, 2, 5, 6)
      expect(m.every((x) => x.complete), true);
      expect(m.map((x) => x.nameTh), contains('แคตาไลติก'));
    });

    test('หลังลบรหัส ระบบยังไม่เสร็จ', () {
      final m = decodeReadiness([0x00, 0x27, 0x65, 0x65]);
      expect(m.where((x) => !x.complete).length, 5); // fuel + 4 ระบบ
    });

    test('เครื่องดีเซลใช้ชื่อระบบดีเซล', () {
      final m = decodeReadiness([0x00, 0x0F, 0xC0, 0x40]);
      expect(m.map((x) => x.nameTh), containsAll(['กรองฝุ่น DPF', 'ระบบ EGR / VVT']));
      expect(m.firstWhere((x) => x.nameTh == 'กรองฝุ่น DPF').complete, false);
    });
  });

  group('ตัวจำลอง: Freeze Frame และ Readiness', () {
    late DemoTransport t;
    late Elm327 elm;
    late ObdService svc;

    setUp(() async {
      t = DemoTransport(responseDelay: const Duration(milliseconds: 1));
      await t.connect();
      elm = Elm327(t)..attach();
      await elm.initialize();
      svc = ObdService(elm);
      await svc.loadSupportedPids();
    });

    tearDown(() async {
      await elm.detach();
      await t.disconnect();
    });

    test('อ่าน Freeze Frame ของ P0301', () async {
      final ff = await svc.readFreezeFrame(snapshotPids);
      expect(ff, isNotNull);
      expect(ff!.dtc, 'P0301');
      expect(ff.values[Pid.rpm], 2150);
      expect(ff.values[Pid.speed], 62);
      expect(ff.values[Pid.coolantTemp], 88);
    });

    test('ลบรหัสแล้ว Freeze Frame หาย และ Readiness กลับเป็นยังไม่เสร็จ', () async {
      expect((await svc.readReadiness()).every((m) => m.complete), true);
      await svc.clearDtcs();
      expect(await svc.readFreezeFrame(snapshotPids), isNull);
      expect((await svc.readReadiness()).where((m) => !m.complete), isNotEmpty);
    });
  });

  group('รายงานและคะแนน', () {
    late RuleBasedDiagnosisEngine engine;

    setUpAll(() {
      engine = RuleBasedDiagnosisEngine(
          DtcDatabase.fromJsonString(File('assets/dtc_th.json').readAsStringSync()));
    });

    test('คะแนนลดตามความรุนแรง และรายงานมีรหัสครบ', () async {
      final r = await engine.analyze(VehicleSnapshot(
        time: DateTime(2026, 10, 22, 9, 5),
        dtcs: const [Dtc('P0171', DtcKind.stored), Dtc('P0301', DtcKind.stored)],
        pids: const {Pid.rpm: 780, Pid.ltftB1: 14},
        milOn: true,
        vin: 'MR0FZ22G801234567',
        freezeFrame: const FreezeFrame('P0301', {Pid.rpm: 2150, Pid.speed: 62}),
      ));
      expect(r.healthScore, inInclusiveRange(0, 60));
      final text = buildReportText(r);
      expect(text, contains('P0171'));
      expect(text, contains('P0301'));
      expect(text, contains('22/10/2569'));
      expect(r.findings.firstWhere((f) => f.code == 'P0301').evidence.first, contains('Freeze Frame'));
    });

    test('รถปกติได้ 100 คะแนน', () async {
      final r = await engine.analyze(VehicleSnapshot(
        time: DateTime(2026),
        dtcs: const [],
        pids: const {Pid.rpm: 780, Pid.coolantTemp: 90, Pid.moduleVoltage: 14.1},
      ));
      expect(r.healthScore, 100);
    });
  });

  test('แปลงหน่วย °F และ mph', () {
    const s = AppSettings(tempUnit: TempUnit.fahrenheit, speedUnit: SpeedUnit.mph);
    final t = displayPid(pidTable[Pid.coolantTemp]!, 90, s);
    expect(t.value, closeTo(194, 0.01));
    expect(t.unit, '°F');
    final v = displayPid(pidTable[Pid.speed]!, 100, s);
    expect(v.value, closeTo(62.14, 0.01));
    expect(v.unit, 'mph');
  });
}
