import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:obd_doctor/core/elm/elm327.dart';
import 'package:obd_doctor/core/obd/ext_automatch.dart';
import 'package:obd_doctor/core/obd/ext_library.dart';
import 'package:obd_doctor/core/obd/ext_pid.dart';
import 'package:obd_doctor/core/obd/formula.dart';
import 'package:obd_doctor/core/obd/obd_service.dart';
import 'package:obd_doctor/core/transport/demo_transport.dart';

ExtLibrary _lib() => ExtLibrary(loader: (path) async => File(path).readAsString());

Future<(DemoTransport, Elm327)> _demo() async {
  final t = DemoTransport(responseDelay: const Duration(milliseconds: 1));
  await t.connect();
  final elm = Elm327(t)..attach();
  await elm.initialize();
  return (t, elm);
}

Future<void> _close(DemoTransport t, Elm327 elm) async {
  await elm.detach();
  await t.disconnect();
}

List<int> _u16(int v) => [(v >> 8) & 0xFF, v & 0xFF];

AutoMatchSample _sample(Map<String, List<int>> payloads, Map<int, List<int>> std) =>
    AutoMatchSample(payloads: payloads, std: std);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('กล่องเลขมาตรฐาน และชุดที่ทำไว้สำหรับรถคันนี้', () {
    test('เลขกล่องที่ OBD-II สงวนไว้ให้เครื่องมือวินิจฉัย', () {
      for (final h in ['', '7DF', '7df', '7E0', '7E7', ' 7e2 ', '18DB33F1', '18DA10F1', '18da28f1']) {
        expect(isStandardDiagHeader(h), true, reason: h);
      }
      for (final h in ['700', '7C0', '620', '7B0', '726', '7E8', '7E', '7E00', '18DAF110', '18DA10F2']) {
        expect(isStandardDiagHeader(h), false, reason: h);
      }
      expect(ExtPid(name: 'x', request: '221210', formula: 'A', header: '7E0').standardHeader, true);
      expect(ExtPid(name: 'x', request: '22112B', formula: 'A', header: '700').standardHeader, false);
    });

    test('ชุดในคลังกับรถจริง (Isuzu D-Max 2007 ที่ทดสอบ)', () async {
      final idx = await _lib().index();
      ExtLibraryEntry e(String lib) => idx.firstWhere((x) => x.lib == lib);
      bool fits(ExtLibraryEntry x, String? make, String? model, int? year) => packFitsVehicle(
            packBrand: x.brand,
            packModels: x.models,
            packYears: x.years,
            make: make,
            model: model,
            year: year,
          );
      // D-Max 2007 ไม่ใช่ชุด 2012–2019 และไม่ใช่ชุด 2020 ขึ้นไป (กล่องคนละรุ่น) แต่ตรงกับชุด 2007–2011 ที่เทียบกับ Tech2
      expect(fits(e('isuzu_dmax_2012'), 'Isuzu', 'D-Max', 2007), false);
      expect(fits(e('isuzu_dmax_2020'), 'Isuzu', 'D-Max', 2007), false);
      expect(fits(e('isuzu_dmax_2007'), 'Isuzu', 'D-Max', 2007), true);
      expect(fits(e('isuzu_dmax_2007'), 'Isuzu', 'D-Max', 2015), false);
      // ทุกช่วงค้นหาของชุด D-Max 2007 ส่งไปกล่องเลขมาตรฐาน (ค้นหาได้ปลอดภัยแม้รถปีอื่น)
      expect(e('isuzu_dmax_2007').scan, isNotEmpty);
      expect(e('isuzu_dmax_2007').scan.every((j) => isStandardDiagHeader(j.header)), true);
      expect(e('isuzu_dmax_2007').evidenceYears, contains(2007));
      expect(fits(e('isuzu_dmax_2012'), 'Isuzu', 'D-Max', 2015), true);
      expect(fits(e('isuzu_dmax_2012'), 'Isuzu', 'D-Max', 2011), true, reason: 'เผื่อ ±1 ปี');
      expect(fits(e('isuzu_dmax_2012'), 'Isuzu', 'D-Max', 2010), false);
      expect(fits(e('toyota_hilux'), 'Toyota', 'Hilux Revo', 2016), true);
      // ชื่อรุ่นสั้นอย่าง "2" ห้ามใช้จับคู่ข้ามยี่ห้อ (D-Max 2.5 ไม่ใช่ Mazda 2)
      expect(fits(e('mazda_2'), 'Isuzu', 'D-Max 2.5', 2016), false);
      // ชื่อรุ่นตรงข้ามยี่ห้อได้ (Colorado อยู่ในชุด Isuzu 2012–2019)
      expect(fits(e('isuzu_dmax_2012'), 'Chevrolet', 'Colorado', 2014), true);
      // ยังไม่รู้ว่ารถที่ต่ออยู่เป็นรุ่นไหน: ชุดในคลังถือว่าไม่ตรง (ถามเฉพาะกล่องเลขมาตรฐาน)
      expect(fits(e('toyota_hilux'), null, null, null), false);
      // ชุดที่ผู้ใช้สร้างเอง (ไม่ระบุยี่ห้อ) ตั้งใจใช้กับรถที่ต่ออยู่
      expect(packFitsVehicle(packBrand: '', make: 'Isuzu', model: 'D-Max', year: 2007), true);
      expect(packFitsVehicle(packBrand: ''), true);
    });

    test('ระยะห่างของปีรถจากช่วงปีของชุด', () {
      expect(packYearGap(const [2012, 2019], 2007), 5);
      expect(packYearGap(const [2012, 2019], 2015), 0);
      expect(packYearGap(const [2012, 2019], 2021), 2);
      expect(packYearGap(const [2012, 2019], null), 0);
      expect(packYearGap(const [], 2010), 0);
    });
  });

  group('ชุดที่ไม่ใช่ของรถคันนี้: ถามเฉพาะกล่องเลขมาตรฐาน', () {
    test('readAll / probe แบบ standardOnly ไม่ส่งคำสั่งไปกล่องเลขเฉพาะยี่ห้อ', () async {
      final (t, elm) = await _demo();
      final log = <String>[];
      elm.onLog = log.add;
      final brand = ExtPid(name: 'Hilux 700', request: '22112B', formula: 'A', header: '700', id: 'H700');
      final std = ExtPid(name: 'น้ำหล่อเย็น', request: '221210', formula: 'A-40', header: '7E0', id: 'C1210');
      final results = <String, ExtCmdResult>{};
      final r = await ExtPidReader(elm).readAll([brand, std], standardOnly: true, commandResults: results);
      expect(r[brand.key]!.skipped, true);
      expect(r[brand.key]!.error, notForThisCarText);
      expect(results[brand.cmdKey]!.status, ExtCmdStatus.skipped);
      expect(r[std.key]!.value, isNotNull);
      expect(log.any((l) => l.startsWith('> ATSH700')), false);
      expect(log.contains('> 22112B'), false);

      // ชุดของรถคันนี้: ถามกล่องเลขเฉพาะยี่ห้อได้ตามปกติ
      log.clear();
      final r2 = await ExtPidReader(elm).readAll([brand, std]);
      expect(log.contains('> ATSH700'), true);
      expect(r2[brand.key]!.value, isNotNull);

      // ทดสอบชุด: นับค่าที่ไม่ได้ถาม
      log.clear();
      final pr = await ExtPidReader(elm).probe([brand, std], standardOnly: true);
      expect(pr.notForThisCar, 1);
      expect(pr.commands, 1);
      expect(pr.responded, 1);
      expect(log.any((l) => l.startsWith('> ATSH700')), false);

      // header กลับเป็นปกติ อ่าน OBD มาตรฐานได้
      expect((await elm.query('010C')).messages, isNotEmpty);
      await _close(t, elm);
    });
  });

  group('ค้นหาเลขคำสั่ง: สรุปแต่ละช่วง', () {
    test('เจอ / ปฏิเสธพร้อมรหัส / เงียบ และคำแนะนำ', () async {
      final (t, elm) = await _demo();
      final reader = ExtPidReader(elm);
      final hits = await reader.scanJobs(const [
        ScanJob(header: '7E0', service: 0x22, start: 0x1200, end: 0x1210),
        ScanJob(header: '7E5', service: 0x22, start: 0x1100, end: 0x1105),
        ScanJob(header: '7E0', service: 0x21, start: 0x10, end: 0x12),
      ]);
      expect(hits.map((h) => h.request).toList(), ['221203', '221210']);
      expect(reader.lastScanStats.length, 3);

      final a = reader.lastScanStats[0];
      expect(a.found, 2);
      expect(a.negative, 15);
      expect(a.silent, 0);
      expect(a.commonNrc, 0x31);
      expect(a.summary, startsWith('7E0 · 22 1200–1210: '));
      expect(a.summary, contains('เจอ 2 · ปฏิเสธ 15 (รหัส 31 = '));
      expect(a.summary, endsWith('เงียบ 0'));
      expect(a.hint, contains('เจอค่า'));

      // ไม่มีกล่องที่เลข 7E5
      final b = reader.lastScanStats[1];
      expect(b.found, 0);
      expect(b.negative, 0);
      expect(b.silent, 6);
      expect(b.hint, contains('ไม่มีกล่องตอบ'));

      // กล่องรองรับคำสั่ง 21 แต่ไม่มีเลขในช่วงนี้
      final c = reader.lastScanStats[2];
      expect(c.found, 0);
      expect(c.negative, 3);
      expect(c.commonNrc, 0x12);
      expect(c.hint, contains('ลองช่วงอื่น'));
      await _close(t, elm);
    });

    test('หยุดกลางทางแล้วค้นต่อจากเลขที่ค้างไว้', () {
      expect(resumeIdFrom('7E0 221604', 0x22), '1604');
      expect(resumeIdFrom('221a0f', 0x22), '1A0F');
      expect(resumeIdFrom('7E0 2135', 0x21), '35');
      expect(resumeIdFrom('7E0 2135', 0x22), isNull);
      expect(resumeIdFrom('', 0x22), isNull);
    });

    test('กล่องไม่รองรับคำสั่งชนิดนี้ (รหัส 11)', () {
      final s = ScanJobStat(const ScanJob(header: '7E2', service: 0x21, start: 0x00, end: 0x03))..negative = 4;
      s.nrcs[0x11] = 4;
      expect(s.commonNrc, 0x11);
      expect(s.hint, contains('ลองอีกชนิด'));
      expect(s.summary, contains('รหัส 11'));
    });
  });

  group('จับคู่กับค่า OBD มาตรฐาน', () {
    test('ค่าที่กล่องเก็บแบบเดียวกับ PID มาตรฐาน', () {
      final m = AutoMatcher();
      // ความร้อนกับรอบเครื่องเปลี่ยนไม่สัมพันธ์กัน (ไม่ให้จับคู่ไขว้กัน)
      const rounds = [(60, 800), (75, 2400), (90, 1600), (68, 1200)];
      const noise = [10, 200, 37, 90];
      for (var i = 0; i < rounds.length; i++) {
        final (t, rpm) = rounds[i];
        m.add(_sample({
          'C': [t + 40],
          'R': _u16(rpm * 4),
          'N': [noise[i]],
        }, {
          0x05: [t + 40],
          0x0C: _u16(rpm * 4),
          0x0F: [76],
        }));
      }
      final c = m.best('C')!;
      expect(c.pid, 0x05);
      expect(c.formula, 'A-40');
      expect(c.kind, AutoMatchKind.sameEncoding);
      expect(c.weak, false);
      expect(c.points, 4);
      expect(c.calPoints.length, 4);
      expect(m.suggestionsFor('C').length, 1);
      final r = m.best('R')!;
      expect(r.pid, 0x0C);
      expect(r.formula, '(A*256+B)/4');
      expect(r.kind, AutoMatchKind.sameEncoding);
      // ค่าที่เปลี่ยนแบบไม่เกี่ยวกับค่ามาตรฐานตัวไหน
      expect(m.best('N'), isNull);
    });

    test('ค่าที่เก็บคนละสูตร: หาสูตรจากจุดเทียบ', () {
      final m = AutoMatcher();
      // กล่องเก็บความร้อนน้ำละเอียด 0.1 °C แบบ 16 บิต ไม่ใช่แบบ PID 05
      const temps = [55, 63, 71, 80, 88];
      for (final t in temps) {
        m.add(_sample({'T': _u16(t * 10)}, {0x05: [t + 40]}));
      }
      final best = m.best('T')!;
      expect(best.pid, 0x05);
      expect(best.kind, AutoMatchKind.fit);
      for (final t in temps) {
        expect(Formula(best.formula).eval(_u16(t * 10)), closeTo(t, 0.5), reason: best.formula);
      }
    });

    test('ค่ายังไม่เปลี่ยน: ค่าดิบตรงกันเป็นแค่ข้อสันนิษฐาน และไม่นับค่า 00', () {
      final m = AutoMatcher();
      for (var i = 0; i < 3; i++) {
        m.add(_sample(
          {'BARO': [0x64], 'ZERO': [0x00], 'ZERO2': [0x00, 0x00]},
          {0x33: [0x64], 0x0D: [0x00], 0x0C: [0x00, 0x00]},
        ));
      }
      final b = m.best('BARO')!;
      expect(b.pid, 0x33);
      expect(b.kind, AutoMatchKind.sameRaw);
      expect(b.weak, true);
      expect(b.formula, 'A');
      expect(m.best('ZERO'), isNull);
      expect(m.best('ZERO2'), isNull);
    });

    test('เก็บตัวอย่างล่าสุดไม่เกินที่กำหนด', () {
      final m = AutoMatcher(maxSamples: 3);
      for (var i = 0; i < 5; i++) {
        m.add(_sample({'X': [i]}, {0x05: [i]}));
      }
      expect(m.samples.length, 3);
      expect(m.samples.first.payloads['X'], [2]);
      m.clear();
      expect(m.samples, isEmpty);
    });

    test('รถจำลอง: เลข 22 1210 / 1203 / 1240 จับคู่กับ PID 05 / 0C / 0F', () async {
      final (t, elm) = await _demo();
      final service = ObdService(elm);
      final pids = [
        ExtPid(name: 'ค่าใหม่ 7E0 221210', request: '221210', formula: 'A', header: '7E0'),
        ExtPid(name: 'ค่าใหม่ 7E0 221203', request: '221203', formula: '(A*256+B)', header: '7E0'),
        ExtPid(name: 'ค่าใหม่ 7E0 221240', request: '221240', formula: 'A', header: '7E0'),
      ];
      expect(pids.first.cmdKey, '7E0|7E8|221210');
      final m = AutoMatcher();
      const rounds = [(60.0, 800.0), (75.0, 2400.0), (90.0, 1600.0), (68.0, 1200.0)];
      for (final (temp, revs) in rounds) {
        t
          ..coolantOverride = temp
          ..rpmOverride = revs;
        final results = <String, ExtCmdResult>{};
        await ExtPidReader(elm).readAll(pids, commandResults: results);
        final std = <int, List<int>>{};
        for (final pid in const [0x05, 0x0C, 0x0F]) {
          final raw = await service.readPidRaw(pid);
          if (raw != null) std[pid] = raw;
        }
        expect(std.length, 3);
        m.add(AutoMatchSample(payloads: {
          for (final e in results.entries)
            if (e.value.status == ExtCmdStatus.ok) e.key: e.value.payload!,
        }, std: std));
      }
      final coolant = m.best('7E0|7E8|221210')!;
      expect(coolant.pid, 0x05);
      expect(coolant.formula, 'A-40');
      expect(coolant.weak, false);
      final rpm = m.best('7E0|7E8|221203')!;
      expect(rpm.pid, 0x0C);
      expect(rpm.formula, '(A*256+B)/4');
      expect(rpm.weak, false);
      // อุณหภูมิอากาศเข้าไม่เปลี่ยน: ค่าดิบตรงกับ PID 0F แต่ยังเป็นแค่ข้อสันนิษฐาน
      final iat = m.best('7E0|7E8|221240')!;
      expect(iat.pid, 0x0F);
      expect(iat.weak, true);
      await _close(t, elm);
    });
  });
}
