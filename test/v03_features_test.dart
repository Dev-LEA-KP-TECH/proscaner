import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obd_doctor/core/analysis/odometer_check.dart';
import 'package:obd_doctor/core/analysis/used_car.dart';
import 'package:obd_doctor/core/analysis/vin.dart';
import 'package:obd_doctor/core/diagnosis/diagnosis.dart';
import 'package:obd_doctor/core/elm/elm327.dart';
import 'package:obd_doctor/core/obd/dtc_database.dart';
import 'package:obd_doctor/core/obd/obd_service.dart';
import 'package:obd_doctor/core/obd/pids.dart';
import 'package:obd_doctor/core/transport/demo_transport.dart';
import 'package:obd_doctor/core/uds/uds_client.dart';
import 'package:obd_doctor/data/garage_store.dart';
import 'package:obd_doctor/data/history_store.dart';
import 'package:obd_doctor/data/log_store.dart';
import 'package:obd_doctor/state/live_poller.dart';
import 'package:obd_doctor/state/providers.dart';
import 'package:obd_doctor/ui/tools/battery_screen.dart';
import 'package:obd_doctor/ui/tools/performance_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemoryHistory extends HistoryStore {
  final items = <VehicleSnapshot>[];

  @override
  Future<List<VehicleSnapshot>> load() async => List.of(items);

  @override
  Future<void> add(VehicleSnapshot s) async => items.insert(0, s);

  @override
  Future<void> clear() async => items.clear();
}

DtcDatabase _db() => DtcDatabase.fromJsonString(File('assets/dtc_th.json').readAsStringSync());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ตัวจำลอง: Mode 06 / Mode 09 / ตัวสแกน', () {
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

    test('ตรวจชนิดตัวสแกนจาก ATI', () {
      expect(elm.adapter!.kind, AdapterKind.simulator);
      expect(elm.adapter!.description, 'ProScaner Simulator');
    });

    test('อ่านแรงดันแบต ATRV', () async {
      expect(await elm.readVoltage(), closeTo(14.1, 0.2));
      t.engineOff();
      expect(await elm.readVoltage(), closeTo(12.45, 0.1));
    });

    test('Mode 06: อ่านครบ และหา misfire สูบ 1 ได้', () async {
      final r = await svc.readMode06();
      expect(r, isNotEmpty);
      final cyl1 = r.firstWhere((x) => x.misfireCylinder == 1 && x.tid == 0x0B);
      expect(cyl1.value, 38);
      final cat = r.firstWhere((x) => x.mid == 0x21);
      expect(cat.passed, true);
      expect(cat.midName, isNotEmpty);
    });

    test('Mode 09: Calibration ID, CVN, ตัวนับการสตาร์ท, ชื่อกล่อง', () async {
      final ids = await svc.readEcuIdentities();
      final ecm = ids.firstWhere((e) => e.calIds.contains('89663-0K540'));
      expect(ecm.cvns, ['1A2B3C4D']);
      expect(ecm.ignitionCount, 14310);
      expect(ecm.name, contains('ECM'));
      expect(ids.length, greaterThanOrEqualTo(2)); // มีกล่องเกียร์ด้วย
    });

    test('เลขไมล์ ชั่วโมงเครื่อง จาก PID A6 / 7F', () async {
      expect(await svc.readPid(Pid.odometer), closeTo(186420.5, 1));
      expect(await svc.readPid(Pid.engineRunTimeTotal), closeTo(5120, 1));
    });

    test('UDS: ค้นหากล่อง อ่านและลบรหัส ABS', () async {
      final uds = UdsClient(elm);
      final mods = await uds.discover();
      final txs = mods.map((m) => m.tx).toSet();
      expect(txs, containsAll(['7E1', '7B0', '780', '7C0']));
      final abs = mods.firstWhere((m) => m.tx == '7B0');
      expect(abs.name, 'ABS/VSC');
      final dtcs = await uds.readDtcs(abs);
      expect(dtcs.single.display, 'C0035-31');
      expect(dtcs.single.confirmed, true);
      expect(await uds.clearDtcs(abs), true);
      expect(await uds.readDtcs(abs), isEmpty);
      // header กลับเป็นปกติ: คำสั่ง OBD ยังใช้ได้
      expect(await svc.readPid(Pid.rpm), isNotNull);
      final vin = await uds.readDid(abs, 0xF190);
      expect(vin, isNotNull);
    });
  });

  group('ตรวจเลขไมล์', () {
    test('ตรงกันทุกอย่าง = สอดคล้อง', () {
      final r = checkOdometer(const OdometerInput(
        ecuKm: 186420,
        dashboardKm: 186450,
        engineHours: 5120,
        ignitionCycles: 14310,
        modelYear: 2015,
      ));
      expect(r.verdict, OdoVerdict.consistent);
      expect(r.checks.where((c) => c.level == CheckLevel.bad), isEmpty);
    });

    test('หน้าปัดน้อยกว่ากล่องมาก = น่าสงสัย', () {
      final r = checkOdometer(const OdometerInput(ecuKm: 186420, dashboardKm: 92000));
      expect(r.verdict, OdoVerdict.suspicious);
    });

    test('ระยะทางน้อยเกินเมื่อเทียบชั่วโมงเครื่อง = น่าสงสัย', () {
      final r = checkOdometer(const OdometerInput(dashboardKm: 40000, engineHours: 6000));
      expect(r.verdict, OdoVerdict.suspicious);
      expect(r.estimateFromHours, isNotNull);
    });

    test('เลขไมล์ลดลงจากประวัติ = น่าสงสัย', () {
      final r = checkOdometer(OdometerInput(
        dashboardKm: 120000,
        history: [OdoRecord(DateTime(2025, 1, 1), 150000)],
      ));
      expect(r.verdict, OdoVerdict.suspicious);
    });

    test('ไม่มีข้อมูลจากรถ = ข้อมูลไม่พอ', () {
      final r = checkOdometer(const OdometerInput());
      expect(r.verdict, OdoVerdict.insufficient);
    });
  });

  group('VIN', () {
    test('ถอดรหัส Toyota ไทย', () {
      final v = decodeVin17('MR0FZ22G801234567', nowYear: 2026);
      expect(v.valid, true);
      expect(v.maker, contains('Toyota'));
      expect(v.country, 'ไทย');
      expect(v.modelYear, isNull); // ตำแหน่งที่ 10 เป็น '0' ไม่ใช่รหัสปี
      expect(decodeVin17('MR0FZ22G8L1234567', nowYear: 2026).modelYear, 2020);
    });

    test('ปีรุ่นรอบใหม่ (2010+)', () {
      expect(decodeModelYear('L', nowYear: 2026), 2020);
      expect(decodeModelYear('A', nowYear: 2026), 2010);
      expect(decodeModelYear('T', nowYear: 2026), 2026);
    });

    test('VIN ผิดรูปแบบ', () {
      expect(decodeVin17('MR0FZ22G80123456O').valid, false);
      expect(decodeVin17('ABC').valid, false);
    });
  });

  group('บันทึกการขับ CSV', () {
    test('เขียนแล้วอ่านกลับได้ครบ รวม BOM', () {
      final log = DriveLog(
        id: 'log_1',
        name: 'ก่อนล้างหัวฉีด',
        start: DateTime(2026, 10, 1, 9, 30),
        pids: [Pid.rpm, Pid.coolantTemp],
        times: [0, 0.5, 1.0],
        rows: [
          [800, 85],
          [1500, null],
          [2100, 86],
        ],
        vin: 'MR0FZ22G801234567',
      );
      final back = DriveLog.fromCsv('log_1', '﻿${log.toCsv()}');
      expect(back.name, 'ก่อนล้างหัวฉีด');
      expect(back.vin, 'MR0FZ22G801234567');
      expect(back.pids, [Pid.rpm, Pid.coolantTemp]);
      expect(back.times, [0, 0.5, 1.0]);
      expect(back.rows[1][1], isNull);
      expect(back.series(Pid.coolantTemp).length, 2);
      expect(back.start, DateTime(2026, 10, 1, 9, 30));
    });
  });

  group('โรงรถ', () {
    test('Vehicle JSON round-trip และกำหนดบำรุงรักษา', () {
      final now = DateTime(2026, 10, 22);
      final v = Vehicle(id: 'x', vin: 'MR0FZ22G801234567', nickname: 'วีโก้', customer: 'สมชาย', phone: '0812345678');
      v.odometer.add(OdoEntry(time: now, ecuKm: 100000, dashKm: 100050));
      v.maintenance.first
        ..lastKm = 90400
        ..lastDate = DateTime(2026, 6, 1);
      v.injectors.add(InjectorCode(cylinder: 1, code: 'ABC123', time: now));
      final back = Vehicle.fromJson(v.toJson());
      expect(back.title, 'วีโก้');
      expect(back.latestKm, 100050);
      expect(back.injectors.single.code, 'ABC123');
      final oil = back.maintenance.first;
      expect(oil.kmLeft(back.latestKm), closeTo(350, 0.1));
      expect(oil.isDue(back.latestKm, now), true);
      expect(back.maintenance[1].isDue(back.latestKm, now), false); // ยังไม่เคยบันทึก
    });

    test('MemoryGarageStore เก็บและโหลดได้', () async {
      final s = MemoryGarageStore();
      await s.save([Vehicle(id: 'a', nickname: 'A')]);
      expect((await s.load()).single.nickname, 'A');
    });
  });

  group('แบตเตอรี่', () {
    test('เปอร์เซ็นต์ประจุจากแรงดันพัก', () {
      expect(batterySoc(12.7), 100);
      expect(batterySoc(12.24), 50);
      expect(batterySoc(11.8), 0);
      expect(batterySoc(12.35), inInclusiveRange(55, 70));
    });

    test('เกณฑ์ตอนสตาร์ทและชาร์จ', () {
      expect(judgeCrank(10.1).level, CheckLevel.ok);
      expect(judgeCrank(9.3).level, CheckLevel.warn);
      expect(judgeCrank(8.2).level, CheckLevel.bad);
      expect(judgeCharge(14.1, loaded: false).level, CheckLevel.ok);
      expect(judgeCharge(13.4, loaded: true).level, CheckLevel.ok);
      expect(judgeCharge(12.5, loaded: false).level, CheckLevel.bad);
      expect(judgeCharge(15.4, loaded: false).level, CheckLevel.bad);
    });
  });

  group('จับเวลาอัตราเร่ง', () {
    test('เร่งคงที่ 0–100 ใน 8 วินาที อ่าน 10 Hz', () {
      final c = PerfCalculator();
      const a = 100 / 8; // กม./ชม. ต่อวินาที
      var done = false;
      // จอดนิ่ง 1 วินาที แล้วออกตัวที่ t = 1.03
      for (var i = 0; i <= 400 && !done; i++) {
        final t = i * 0.1;
        final v = t < 1.03 ? 0.0 : a * (t - 1.03);
        done = c.add(t, v.clamp(0, 180).toDouble(), DateTime(2026));
      }
      final r = c.run!;
      expect(r.t100, closeTo(8.0, 0.1));
      expect(r.t60, closeTo(4.8, 0.1));
      expect(r.t60to100, closeTo(3.2, 0.1));
      expect(r.quarter, isNotNull);
      // ระยะ 402 ม. ด้วยความเร่งคงที่ 3.47 m/s²: t = sqrt(2*402.3/3.4722) ≈ 15.2 วินาที
      expect(r.quarter, closeTo(15.2, 0.2));
    });
  });

  group('สแกนทั้งคันผ่าน provider (ตัวจำลอง)', () {
    late ProviderContainer c;

    setUp(() async {
      // ignore: invalid_use_of_visible_for_testing_member
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final db = _db();
      c = ProviderContainer(overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        historyStoreProvider.overrideWithValue(_MemoryHistory()),
        garageStoreProvider.overrideWithValue(MemoryGarageStore()),
        logStoreProvider.overrideWithValue(MemoryLogStore()),
        dtcDatabaseProvider.overrideWith((ref) async => db),
      ]);
      await c.read(sessionProvider.notifier).connect(DemoTransport(responseDelay: const Duration(milliseconds: 1)));
    });

    tearDown(() async {
      await c.read(sessionProvider.notifier).disconnect();
      c.dispose();
    });

    test('ได้ผลกล่องอื่น เลขไมล์ ตัวนับ และบันทึกเข้าโรงรถ', () async {
      expect(c.read(sessionProvider).isConnected, true);
      await c.read(scanProvider.notifier).run(allModules: true);
      final s = c.read(scanProvider);
      expect(s.error, isNull);
      final snap = s.report!.snapshot;
      expect(snap.modules.map((m) => m.tx), containsAll(['7B0', '780']));
      expect(snap.modules.any((m) => m.tx == '7E0'), false);
      expect(snap.ecuOdometerKm, closeTo(186420, 5));
      expect(snap.engineHours, closeTo(5120, 1));
      expect(snap.ignitionCycles, 14310);
      expect(s.report!.findings.any((f) => (f.code ?? '').startsWith('C0035') && f.module != null), true);

      final garage = await c.read(garageProvider.future);
      expect(garage.single.vin, 'MR0FZ22G801234567');
      expect(garage.single.odometer.single.ecuKm, closeTo(186420, 5));

      // รถมือสอง: มีรหัสถาวร + ABS → ความเสี่ยงสูง
      final used = evaluateUsedCar(report: s.report!, modules: snap.modules);
      expect(used.risk, UsedCarRisk.high);

      // ลบรหัสรวมกล่อง ABS แล้วสแกนใหม่
      final msg = await c.read(scanProvider.notifier).clearCodes(modules: snap.modules);
      expect(msg, contains('ลบรหัสแล้ว'));
      final after = c.read(scanProvider).report!.snapshot;
      expect(after.modules.firstWhere((m) => m.tx == '7B0').dtcs, isEmpty);
      // หลังลบโค้ด: ร่องรอยการลบโค้ดต้องถูกจับได้
      final used2 = evaluateUsedCar(report: c.read(scanProvider).report!);
      expect(used2.flags.any((f) => f.title.contains('ลบรหัส')), true);
    });

    test('บันทึกการขับผ่านตัวอ่านค่าสดกลาง', () async {
      final rec = c.read(recorderProvider.notifier);
      rec.start([Pid.rpm, Pid.speed]);
      for (var i = 0; i < 40 && c.read(recorderProvider).rows < 3; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(c.read(recorderProvider).rows, greaterThanOrEqualTo(3));
      final log = await rec.stop(name: 'ทดสอบ');
      expect(log, isNotNull);
      expect(log!.series(Pid.rpm), isNotEmpty);
      final logs = await c.read(logsProvider.future);
      expect(logs.single.name, 'ทดสอบ');
      expect(c.read(livePollerProvider).isRunning, anyOf(true, false));
    });
  });

  test('ชื่อ Mode 06 / IUPR / CALID parse', () {
    final r = parseMode06([0xA2, 0x0B, 0x24, 0x00, 0x26, 0x00, 0x00, 0xFF, 0xFF]);
    expect(r.single.misfireCylinder, 1);
    expect(r.single.value, 38);
    expect(parseCalIds([0x01, ...'89663-0K540'.codeUnits, 0, 0, 0, 0, 0]), ['89663-0K540']);
    expect(parseIupr([0x02, 0x1A, 0xA4, 0x37, 0xE6])[1], 14310);
  });

  test('UDS: ตัดรหัสที่มีแค่สถานะ "ยังไม่ได้ทดสอบ" (0x50) ออก', () {
    final d = parseUdsDtcs([0x59, 0x02, 0xFF, 0x90, 0x01, 0x00, 0x50, 0x40, 0x35, 0x31, 0x09, 0x90, 0x02, 0x00, 0x28]);
    expect(d.map((x) => x.display), ['C0035-31', 'B1002']);
    expect(d.last.statusTh, contains('ยืนยันแล้ว'));
  });

  test('รถมือสอง: กล่องที่อ่านไม่ได้ และรถไม่ใช่ CAN ต้องแจ้ง ไม่ถือว่าปกติ', () {
    final report = DiagnosisReport(
      snapshot: VehicleSnapshot(time: DateTime(2026), dtcs: const [], pids: const {Pid.distanceSinceClear: 5000}),
      findings: [],
      engineName: 'test',
    );
    final m = EcuModule(tx: '780', rx: '788', name: 'Airbag', error: 'กล่องไม่ตอบคำขออ่านรหัส');
    final r = evaluateUsedCar(report: report, modules: [m], modulesScanned: false);
    expect(r.flags.any((f) => f.title.contains('อ่านรหัสไม่ได้')), true);
    expect(r.flags.any((f) => f.title.contains('เฉพาะกล่องเครื่องยนต์')), true);
    expect(r.risk, isNot(UsedCarRisk.low));
  });
}
