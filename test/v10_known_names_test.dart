// เทสต์ v0.6.3: ค่าที่ค้นพบเอง ("ค่าใหม่ 7E0 22xxxx") ที่เลขตรงกับค่าที่รู้แล้วในคลังของรถรุ่นเดียวกัน ได้ชื่อ สูตร หน่วย
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obd_doctor/core/obd/ext_known.dart';
import 'package:obd_doctor/core/obd/ext_library.dart';
import 'package:obd_doctor/core/obd/ext_pid.dart';
import 'package:obd_doctor/state/ext_packs.dart';
import 'package:obd_doctor/state/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

ExtLibrary _lib() => ExtLibrary(loader: (path) async => File(path).readAsString());

/// ค่าที่หน้า "ค้นหาค่าที่กล่องตอบ" บันทึก (แบบเดียวกับ DidScannerScreen._saveAllHits)
ExtPid _found(String request, {String header = '7E0'}) => ExtPid(
      name: 'ค่าใหม่ $header $request',
      request: request,
      formula: 'A',
      header: header,
      decimals: 0,
      group: 'ค่าที่ค้นพบเอง',
    );

ExtPidPack _discovered(List<String> requests, {int? year = 2007, String model = 'D-Max'}) => ExtPidPack(
      id: 'pack_found',
      name: 'ค้นพบเอง Isuzu D-Max 2007 2026-10-26',
      brand: 'Isuzu',
      models: [model],
      years: [if (year != null) ...[year, year]],
      pids: [for (final r in requests) _found(r)],
    );

/// เลขที่รถ D-Max 2007 ของร้านตอบตอนค้นหา 26 ต.ค. (ช่วง 1100–12FF และ 1300–1FFF)
const _scan1 = [
  '221100', '221101', '221102', '221110', '221111', '221112', '221113', '221114', '221115', '221120', //
  '221130', '221131', '221150', '221151', '221152', '221153', '221170', '22117A', '221200', '221203',
  '221204', '221205', '221210', '221211', '221212', '221220', '221240', '221241', '221250', '221251',
  '221252', '221270', '22127A', '221280', '221281', '221282', '221283',
];
const _scan2 = [
  '221300', '221301', '221304', '221305', '221310', '221400', '221401', '221402', '221403', '221404', //
  '221405', '221406', '221407', '221408', '221409', '22140A', '22140B', '221410', '221411', '221412',
  '221413', '221414', '221415', '221416', '221421', '221422', '221423', '221424', '221425', '221430',
  '221450', '221451', '221452', '221453', '221460', '221470', '221473', '22147A', '221500', '221501',
  '221510', '221550', '221600', '221601', '221602', '221603', '221604',
];

Future<List<ExtPidPack>> _librariesFor(ExtPidPack pack) async {
  final lib = _lib();
  return [
    for (final e in await lib.index())
      if (sameCarForNames(
        libBrand: e.brand,
        libModels: e.models,
        libYears: e.years,
        make: pack.brand,
        model: pack.models.first,
        year: pack.years.isEmpty ? null : pack.years.first,
      ))
        await lib.pack(e),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ค่าที่ยังไม่รู้ชื่อ', () {
    test('ค่าใหม่จากหน้าค้นหา = ยังไม่รู้ชื่อ แต่ถ้าเริ่มเทียบ ยืนยัน หรือเปลี่ยนชื่อแล้ว ไม่นับ', () {
      expect(isUnnamedDiscovered(_found('221210')), true);
      expect(isUnnamedDiscovered(_found('221210')..name = 'อุณหภูมิน้ำ'), false);
      expect(isUnnamedDiscovered(_found('221210')..verified = true), false);
      expect(isUnnamedDiscovered(_found('221210')..points.add(CalPoint(raw: [100], ref: 60))), false);
    });
  });

  group('ชุดในคลังเป็นของรถรุ่นเดียวกัน', () {
    bool same({String libBrand = 'Isuzu', List<int> libYears = const [2007, 2011], String? make = 'Isuzu', String? model = 'D-Max', int? year = 2007}) =>
        sameCarForNames(libBrand: libBrand, libModels: const ['D-Max'], libYears: libYears, make: make, model: model, year: year);

    test('ยี่ห้อ รุ่น ปีตรง', () => expect(same(), true));
    test('ปีอยู่นอกช่วง (รุ่นใหม่ใช้เลขคนละชุด) ไม่ตรง แม้ห่างแค่ปีเดียว', () {
      expect(same(year: 2012), false);
      expect(same(year: 2006), false);
    });
    test('ไม่รู้ปี ไม่ตั้งชื่อให้ (อาจเป็นรุ่นอื่น)', () => expect(same(year: null), false));
    test('ยี่ห้อต่าง หรือชุดในคลังไม่ระบุยี่ห้อ ไม่ตรง', () {
      expect(same(make: 'Toyota'), false);
      expect(same(make: null), false);
      expect(same(libBrand: ''), false);
    });
    test('รุ่นต่าง ไม่ตรง', () => expect(same(model: 'MU-7'), false));
  });

  group('ตั้งชื่อจากคลัง', () {
    test('เลขที่รถ D-Max 2007 ตอบ: ได้ชื่อจากชุดในคลัง 23 ค่า (เทียบ Tech2 + PID มาตรฐาน) ที่เหลือยังไม่รู้', () async {
      final a = _discovered(_scan1);
      final b = _discovered(_scan2);
      final libsA = await _librariesFor(a);
      expect(libsA.map((p) => p.lib), ['isuzu_dmax_2007']);
      final ma = findKnown(a, libsA);
      final mb = findKnown(b, await _librariesFor(b));
      expect(ma.map((m) => m.discovered.request), [
        '221100', '221101', '221102', '221110', '221111', '221112', '221130', '221150', '221151', '221170', //
        '221200', '221203', '221204', '221210', '221211', '221212', '221240', '221241', '221250', '221270',
      ]);
      expect(mb.map((m) => m.discovered.request), ['221410', '221450', '221470']);
      // 27 ต.ค.: รอบเครื่องและความดันรางเทียบกับ PID มาตรฐานของรถคันเดียวกันแล้ว
      final rpm = ma.firstWhere((m) => m.discovered.request == '221203').known.single;
      expect(rpm.name, 'รอบเครื่องยนต์');
      expect(rpm.formula, 'A*256+B');
      expect(rpm.unit, 'rpm');
      expect(ma.firstWhere((m) => m.discovered.request == '221250').names, 'ความดันราง');
      expect(mb.firstWhere((m) => m.discovered.request == '221450').names, 'ความดันรางที่ต้องการ (รอยืนยัน)');
      final coolant = ma.firstWhere((m) => m.discovered.request == '221210');
      expect(coolant.names, 'อุณหภูมิน้ำหล่อเย็น');
      expect(coolant.source, 'Isuzu D-Max (2007–2011) · เทียบกับ Tech2');

      // รถรุ่นอื่น/ไม่รู้ปี: ไม่ใช้ชุด 2007
      expect(await _librariesFor(_discovered(_scan1, year: 2015)), isNot(contains(predicate<ExtPidPack>((p) => p.lib == 'isuzu_dmax_2007'))));
      expect(await _librariesFor(_discovered(_scan1, year: null)), isEmpty);
    });

    test('แทนที่ตรงตำแหน่งเดิมด้วยชื่อ สูตร หน่วย กลุ่ม จากคลัง ชุดเดิมไม่ถูกแก้', () async {
      final pack = _discovered(['221300', '221210', '221211'])..activeGroups = ['ค่าที่ค้นพบเอง'];
      final matches = findKnown(pack, await _librariesFor(pack));
      final out = applyKnown(pack, matches);

      expect(pack.pids.map((p) => p.name), ['ค่าใหม่ 7E0 221300', 'ค่าใหม่ 7E0 221210', 'ค่าใหม่ 7E0 221211']);
      expect(out.id, pack.id);
      expect(out.pids.map((p) => p.name), ['ค่าใหม่ 7E0 221300', 'อุณหภูมิน้ำหล่อเย็น', 'อุณหภูมิน้ำมันเชื้อเพลิง']);
      final coolant = out.pids[1];
      expect(coolant.formula, 'A-40');
      expect(coolant.unit, '°C');
      expect(coolant.header, '7E0');
      expect(coolant.request, '221210');
      expect(coolant.verified, false);
      expect(coolant.source, isNotNull);
      // กลุ่มของค่าที่ได้ชื่อถูกเปิดอ่านด้วย
      expect(out.activeGroups, containsAll(['ค่าที่ค้นพบเอง', coolant.group, out.pids[2].group]));
      // ตั้งชื่อแล้ว ไม่มีอะไรให้ตั้งอีก
      expect(findKnown(out, await _librariesFor(out)), isEmpty);
    });

    test('คำตอบเดียวมีหลายค่า: ได้ทุกค่า และค่าที่มีในชุดแล้วไม่ซ้ำ', () {
      final lib = ExtPidPack(id: 'lib', name: 'คลัง', pids: [
        ExtPid(name: 'แรงดันราง', request: '2101', formula: 'A*256+B', header: '7E0', unit: 'kPa', group: 'เชื้อเพลิง'),
        ExtPid(name: 'อุณหภูมิน้ำมัน', request: '2101', formula: 'C-40', header: '7E0', unit: '°C', group: 'เชื้อเพลิง'),
        ExtPid(name: 'อื่น', request: '2102', formula: 'A', header: '7E0'),
      ]);
      final pack = ExtPidPack(id: 'mine', name: 'ของฉัน', pids: [
        _found('2101'),
        ExtPid(name: 'อุณหภูมิน้ำมัน', request: '2101', formula: 'C-40', header: '7E0', unit: '°C', group: 'เชื้อเพลิง'),
      ]);
      final m = findKnown(pack, [lib]);
      expect(m.single.known.length, 2);
      final out = applyKnown(pack, m);
      expect(out.pids.map((p) => p.name), ['แรงดันราง', 'อุณหภูมิน้ำมัน']);
    });

    test('กล่องต่างกัน (7E2 กับ 7E0) เลขคำสั่งเดียวกัน ไม่จับคู่', () {
      final lib = ExtPidPack(id: 'lib', name: 'คลัง', pids: [
        ExtPid(name: 'อุณหภูมิน้ำมันเกียร์', request: '221940', formula: 'A-40', header: '7E2'),
      ]);
      expect(findKnown(ExtPidPack(id: 'x', name: 'x', pids: [_found('221940')]), [lib]), isEmpty);
      expect(findKnown(ExtPidPack(id: 'x', name: 'x', pids: [_found('221940', header: '7E2')]), [lib]).length, 1);
    });

    test('ผ่าน provider: ใช้ยี่ห้อ รุ่น ปีของชุด และกดตั้งชื่อแล้วรายการหายไป', () async {
      // ignore: invalid_use_of_visible_for_testing_member
      SharedPreferences.setMockInitialValues({});
      final c = ProviderContainer(overrides: [
        sharedPrefsProvider.overrideWithValue(await SharedPreferences.getInstance()),
        extLibraryProvider.overrideWithValue(_lib()),
      ]);
      addTearDown(c.dispose);
      c.read(extPacksProvider.notifier).put(_discovered(_scan1));
      final matches = await c.read(knownNamesProvider('pack_found').future);
      expect(matches.length, 20);
      c.read(extPacksProvider.notifier).put(applyKnown(c.read(extPacksProvider).single, matches));
      expect(await c.read(knownNamesProvider('pack_found').future), isEmpty);
      final names = c.read(extPacksProvider).single.pids.map((p) => p.name).toList();
      expect(names, contains('อุณหภูมิน้ำหล่อเย็น'));
      expect(names.where((n) => n.startsWith('ค่าใหม่')).length, _scan1.length - 20);
    });
  });
}
