import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obd_doctor/core/analysis/vehicle_catalog.dart';
import 'package:obd_doctor/core/analysis/vin.dart';
import 'package:obd_doctor/core/diagnosis/diagnosis.dart';
import 'package:obd_doctor/core/obd/dtc_database.dart';
import 'package:obd_doctor/core/transport/demo_transport.dart';
import 'package:obd_doctor/data/garage_store.dart';
import 'package:obd_doctor/data/history_store.dart';
import 'package:obd_doctor/data/log_store.dart';
import 'package:obd_doctor/state/providers.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ถอด VIN เป็นยี่ห้อ', () {
    test('รถไทย: รู้ยี่ห้อ แต่ปีจาก VIN ไม่น่าเชื่อถือ', () {
      final v = decodeVin17('MR0FZ22G801234567', nowYear: 2026);
      expect(v.brand, 'Toyota');
      expect(v.familyKey, 'MR0FZ22G');
      expect(v.yearReliable, false);
      expect(decodeVin17('MMTJNKB40PH000001').brand, 'Mitsubishi');
      expect(decodeVin17('MMM148MK0PH000001').brand, 'Chevrolet');
    });

    test('รถจีน/อเมริกา: ปีจาก VIN เชื่อถือได้', () {
      final byd = decodeVin17('LGXCE4CB0N0123456', nowYear: 2026);
      expect(byd.brand, 'BYD');
      expect(byd.yearReliable, true);
      expect(byd.modelYear, 2022);
      final honda = decodeVin17('1HGCM82633A004352', nowYear: 2026);
      expect(honda.brand, 'Honda');
      expect(honda.modelYear, 2003);
    });

    test('WMI ไม่อยู่ในตาราง ใช้ 2 หลักแรกเดายี่ห้อ', () {
      expect(decodeVin17('JT2BG22K1W0123456').brand, 'Toyota');
      expect(decodeVin17('XTA21099000000001').brand, isNull);
    });

    test('ชื่อยี่ห้อมาตรฐาน', () {
      expect(normalizeBrand('MG / SAIC'), 'MG');
      expect(normalizeBrand('Great Wall'), 'GWM');
      expect(normalizeBrand('toyota'), 'Toyota');
      expect(normalizeBrand('Unknown Motors'), 'Unknown Motors');
      expect(brandByName('Mercedes-Benz')!.initials, 'MB');
      expect(brandByName('BYD')!.initials, 'BYD');
      expect(brandByName('Toyota')!.initials, 'T');
      expect(brandLogoAsset('Land Rover'), 'assets/brand_logos/land_rover.png');
      expect(brandByName('Mercedes-Benz')!.logoAsset, 'assets/brand_logos/mercedes_benz.png');
    });
  });

  test('Vehicle เก็บยี่ห้อ/รุ่น/ปี และตั้งชื่อจากยี่ห้อ+รุ่น', () {
    final v = Vehicle(id: 'a', make: 'Isuzu', model: 'D-Max', year: 2020, fuel: 'ดีเซล', idSource: 'manual');
    final back = Vehicle.fromJson(v.toJson());
    expect(back.title, 'Isuzu D-Max');
    expect(back.year, 2020);
    expect(back.fuel, 'ดีเซล');
    expect(back.idSource, 'manual');
    expect(back.needsModel, false);
    // ข้อมูลเก่าที่ไม่มีช่องใหม่ยังโหลดได้
    final old = Vehicle.fromJson({'id': 'b', 'vin': 'MR0FZ22G801234567', 'odo': []});
    expect(old.make, isNull);
    expect(old.title, 'Toyota');
  });

  group('ระบุรถอัตโนมัติในโรงรถ', () {
    late ProviderContainer c;

    setUp(() => c = ProviderContainer(overrides: [garageStoreProvider.overrideWithValue(MemoryGarageStore())]));
    tearDown(() => c.dispose());

    test('สร้างรถจาก VIN และจำรุ่นให้รถรุ่นเดียวกัน', () async {
      final g = c.read(garageProvider.notifier);
      final r1 = (await g.identify(vin: 'MR0FZ22G801234567', diesel: true))!;
      expect(r1.created, true);
      expect(r1.vehicle.make, 'Toyota');
      expect(r1.vehicle.fuel, 'ดีเซล');
      expect(r1.vehicle.year, isNull);
      expect(r1.vehicle.idSource, 'vin');
      expect(r1.vehicle.needsModel, true);

      // ผู้ใช้เลือกรุ่นครั้งเดียว
      r1.vehicle
        ..model = 'Hilux Vigo'
        ..year = 2012
        ..idSource = 'manual';
      await g.upsert(r1.vehicle);

      // รถอีกคัน รุ่นเดียวกัน (8 หลักแรกตรงกัน) → ได้รุ่นอัตโนมัติ แต่ไม่เอาปีไป
      final r2 = (await g.identify(vin: 'MR0FZ22G809999999', diesel: true))!;
      expect(r2.created, true);
      expect(r2.vehicle.model, 'Hilux Vigo');
      expect(r2.vehicle.idSource, 'learned');
      expect(r2.vehicle.year, isNull);

      // เชื่อมต่อคันแรกอีกครั้ง → ไม่สร้างซ้ำ ไม่ทับค่าที่ผู้ใช้แก้
      final r3 = (await g.identify(vin: 'MR0FZ22G801234567', diesel: false))!;
      expect(r3.created, false);
      expect(r3.vehicle.fuel, 'ดีเซล');
      expect(r3.vehicle.idSource, 'manual');

      // รุ่นต่างกัน → ไม่เดา
      final r4 = (await g.identify(vin: 'MR0HA3CD500000001'))!;
      expect(r4.vehicle.model, isNull);

      final all = await c.read(garageProvider.future);
      expect(all.length, 3);
    });

    test('รถจีนได้ปีจาก VIN', () async {
      final r = (await c.read(garageProvider.notifier).identify(vin: 'LGXCE4CB0N0123456', diesel: false))!;
      expect(r.vehicle.make, 'BYD');
      expect(r.vehicle.year, 2022);
    });
  });

  group('เชื่อมต่อแล้วรู้จักรถเอง (ตัวจำลอง)', () {
    late ProviderContainer c;

    setUp(() async {
      // ignore: invalid_use_of_visible_for_testing_member
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final db = DtcDatabase.fromJsonString(File('assets/dtc_th.json').readAsStringSync());
      c = ProviderContainer(overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        historyStoreProvider.overrideWithValue(_MemoryHistory()),
        garageStoreProvider.overrideWithValue(MemoryGarageStore()),
        logStoreProvider.overrideWithValue(MemoryLogStore()),
        dtcDatabaseProvider.overrideWith((ref) async => db),
      ]);
    });

    tearDown(() async {
      await c.read(sessionProvider.notifier).disconnect();
      c.dispose();
    });

    test('เชื่อมต่อ → ระบุรถจาก VIN → สแกนบันทึกเข้ารถคันนั้น', () async {
      await c.read(sessionProvider.notifier).connect(DemoTransport(responseDelay: const Duration(milliseconds: 1)));
      final s = c.read(sessionProvider);
      expect(s.isConnected, true);
      expect(s.vehicleId, 'MR0FZ22G801234567');
      expect(s.newVehicle, true);
      final v = c.read(garageProvider.notifier).byId(s.vehicleId)!;
      expect(v.make, 'Toyota');
      expect(v.fuel, isNotNull);

      await c.read(scanProvider.notifier).run();
      final garage = await c.read(garageProvider.future);
      expect(garage.single.odometer, isNotEmpty);
    });

    test('รถไม่ส่ง VIN: ผู้ใช้เลือกรถ แล้วผลสแกนเข้ารถคันนั้น', () async {
      final g = c.read(garageProvider.notifier);
      final mine = Vehicle(id: 'car_1', make: 'Honda', model: 'City');
      await g.upsert(mine);
      await c.read(sessionProvider.notifier).connect(DemoTransport(responseDelay: const Duration(milliseconds: 1), vin: ''));
      expect(c.read(sessionProvider).vehicleId, isNull);
      c.read(sessionProvider.notifier).selectVehicle('car_1');
      expect(c.read(sessionProvider).vehicleId, 'car_1');
      await c.read(scanProvider.notifier).run();
      final after = (await c.read(garageProvider.future)).single;
      expect(after.id, 'car_1');
      expect(after.odometer, isNotEmpty);
    });
  });
}
