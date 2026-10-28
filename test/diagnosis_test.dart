import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:obd_doctor/core/diagnosis/diagnosis.dart';
import 'package:obd_doctor/core/obd/dtc.dart';
import 'package:obd_doctor/core/obd/dtc_database.dart';
import 'package:obd_doctor/core/obd/pids.dart';

void main() {
  late DtcDatabase db;
  late RuleBasedDiagnosisEngine engine;

  setUpAll(() {
    db = DtcDatabase.fromJsonString(File('assets/dtc_th.json').readAsStringSync());
    engine = RuleBasedDiagnosisEngine(db);
  });

  VehicleSnapshot snap({List<Dtc> dtcs = const [], Map<int, double>? pids, bool mil = false}) =>
      VehicleSnapshot(
        time: DateTime(2026, 10, 21),
        dtcs: dtcs,
        pids: pids ??
            {Pid.rpm: 780, Pid.coolantTemp: 90, Pid.ltftB1: 2, Pid.stftB1: 1, Pid.moduleVoltage: 14.1},
        milOn: mil,
      );

  group('ฐานข้อมูลรหัส', () {
    test('โหลดได้และมีรหัสพอ', () => expect(db.length, greaterThanOrEqualTo(75)));

    test('รหัส misfire รายสูบสร้างจากรูปแบบ', () {
      final i = db.lookup('P0304');
      expect(i.descriptionTh, contains('4'));
      expect(i.descriptionTh, contains('สูบ'));
      expect(i.severity, Severity.high);
    });

    test('รหัสที่ไม่รู้จักได้คำอธิบายตามหมวด', () {
      final i = db.lookup('P1234');
      expect(i.isFallback, true);
      expect(i.descriptionTh, contains('เฉพาะผู้ผลิต'));
    });
  });

  test('ส่วนผสมบาง + misfire: ใช้ค่าสดยืนยัน และชี้ให้ตรวจรอยรั่วก่อน', () async {
    final r = await engine.analyze(snap(
      mil: true,
      dtcs: const [
        Dtc('P0171', DtcKind.stored, ecu: '7E8'),
        Dtc('P0301', DtcKind.stored, ecu: '7E8'),
        Dtc('P0420', DtcKind.pending, ecu: '7E8'),
        Dtc('P0171', DtcKind.permanent, ecu: '7E8'),
      ],
      pids: {Pid.rpm: 780, Pid.coolantTemp: 90, Pid.ltftB1: 14, Pid.stftB1: 6, Pid.moduleVoltage: 14.1},
    ));

    expect(r.overall, Severity.high);
    expect(r.findings.first.code, 'P0301');

    final lean = r.findings.firstWhere((f) => f.code == 'P0171');
    expect(lean.kinds, {DtcKind.stored, DtcKind.permanent});
    expect(lean.evidence.join(), contains('ส่วนผสมบางจริง'));

    final misfire = r.findings.firstWhere((f) => f.code == 'P0301');
    expect(misfire.causes.first, contains('รอยรั่วสุญญากาศ'));

    final cat = r.findings.firstWhere((f) => f.code == 'P0420');
    expect(cat.pendingOnly, true);
    expect(cat.severity, Severity.low); // รอยืนยัน: ลดระดับได้แต่ไม่ต่ำกว่า low
    expect(cat.evidence.join(), contains('แคทอาจยังไม่เสีย'));
  });

  test('เครื่องร้อนเกินเป็นระดับหยุดขับ แม้ไม่มีโค้ด', () async {
    final r = await engine.analyze(snap(pids: {Pid.rpm: 800, Pid.coolantTemp: 112}));
    expect(r.overall, Severity.high);
    expect(r.findings.first.title, contains('ร้อนเกิน'));
  });

  test('ไฟไม่ชาร์จขณะติดเครื่อง', () async {
    final r = await engine.analyze(snap(pids: {Pid.rpm: 800, Pid.moduleVoltage: 12.2}));
    expect(r.findings.any((f) => f.title.contains('ไม่ชาร์จ')), true);
  });

  test('ไฟเตือนติดแต่ไม่มีโค้ดเครื่องยนต์', () async {
    final r = await engine.analyze(snap(mil: true));
    expect(r.findings.single.severity, Severity.medium);
  });

  test('รถปกติ: ได้ผลระดับข้อมูลหนึ่งรายการ', () async {
    final r = await engine.analyze(snap());
    expect(r.overall, Severity.info);
    expect(r.findings.length, 1);
  });

  test('บันทึกและอ่านกลับจาก JSON ได้ครบ', () {
    final s = snap(dtcs: const [Dtc('P0171', DtcKind.stored, ecu: '7E8')], mil: true);
    final back = VehicleSnapshot.fromJson(s.toJson());
    expect(back.dtcs, s.dtcs);
    expect(back.pids, s.pids);
    expect(back.milOn, true);
  });
}
