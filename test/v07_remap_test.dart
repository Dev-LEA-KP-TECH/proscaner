import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:obd_doctor/core/analysis/remap_demo.dart';
import 'package:obd_doctor/core/analysis/remap_sampler.dart';
import 'package:obd_doctor/core/analysis/remap_test.dart';
import 'package:obd_doctor/core/elm/elm327.dart';
import 'package:obd_doctor/core/obd/ext_pid.dart';
import 'package:obd_doctor/core/obd/obd_service.dart';
import 'package:obd_doctor/core/obd/pids.dart';
import 'package:obd_doctor/core/transport/demo_transport.dart';
import 'package:obd_doctor/data/remap_store.dart';
import 'package:obd_doctor/report/pdf_report.dart';

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

const _speed = RemapChannel(key: 'v', name: 'ความเร็ว', unit: 'กม./ชม.', signal: RemapSignal.speed);
const _rpm = RemapChannel(key: 'n', name: 'รอบ', unit: 'รอบ/นาที', signal: RemapSignal.rpm);
const _pedal = RemapChannel(key: 'ped', name: 'คันเร่ง', unit: '%', signal: RemapSignal.pedal);
const _boost = RemapChannel(key: 'b', name: 'บูสต์', unit: 'kPa', signal: RemapSignal.boost);
const _boostCmd = RemapChannel(key: 'bc', name: 'บูสต์ที่ต้องการ', unit: 'kPa', signal: RemapSignal.boostCmd);
const _rail = RemapChannel(key: 'r', name: 'ราง', unit: 'MPa', signal: RemapSignal.rail);
const _railCmd = RemapChannel(key: 'rc', name: 'รางที่ต้องการ', unit: 'MPa', signal: RemapSignal.railCmd);
const _baro = RemapChannel(key: 'p', name: 'บรรยากาศ', unit: 'kPa', signal: RemapSignal.baro);
const _coolant = RemapChannel(key: 'ect', name: 'น้ำ', unit: '°C', signal: RemapSignal.coolant);

/// สร้างรอบทดสอบจากฟังก์ชันค่าตามเวลา (10 แถวต่อวินาที)
RemapRun _make(List<RemapChannel> ch, double seconds, Map<String, double> Function(double t) f, {bool turbo = true}) {
  final run = RemapRun(id: 't', name: 't', stage: RemapStage.other, start: DateTime(2026, 10, 27), channels: ch, turbo: turbo);
  for (var i = 0; i * 0.1 <= seconds + 1e-9; i++) {
    final t = i * 0.1;
    run.add(t, f(t));
  }
  return run;
}

List<RemapEvent> _events(RemapRun r, RemapEventKind k, {RemapLimits limits = const RemapLimits()}) =>
    analyzeRemapRun(r, limits: limits).events.where((e) => e.kind == k).toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('จับเวลาอัตราเร่ง', () {
    test('0–100, 60–100, 80–120 จากรอบสังเคราะห์ตรงกับที่คำนวณไว้', () {
      final a = analyzeRemapRun(syntheticRemapRun(id: 'x', stage: RemapStage.before, start: DateTime(2026)));
      // ความเร็ว = 140·(1 − e^(−t/6.2)) ปัดเป็นจำนวนเต็มแบบกล่อง 8 ครั้ง/วินาที
      expect(a.accelFor(0, 100)!.seconds, closeTo(7.69, 0.05));
      expect(a.accelFor(60, 100)!.seconds, closeTo(4.25, 0.05));
      expect(a.accelFor(80, 120)!.seconds, closeTo(6.75, 0.05));
      final b = analyzeRemapRun(syntheticRemapRun(id: 'y', stage: RemapStage.after, start: DateTime(2026), tau: 5.3));
      expect(b.accelFor(0, 100)!.seconds, closeTo(6.56, 0.05));
    });

    test('ถอนคันเร่งกลางทาง ไม่นับช่วงนั้น', () {
      final speed = <(double, double)>[
        for (var t = 0.0; t <= 4; t += 0.2) (t, t < 1 ? 0 : (t - 1) * 20), // 0 → 60
        for (var t = 4.2; t <= 6; t += 0.2) (t, 60 - (t - 4) * 10), // ชะลอลงเหลือ 40
        for (var t = 6.2; t <= 12; t += 0.2) (t, 40 + (t - 6) * 12), // เร่งต่อถึง 110
      ];
      expect(bestAccel(speed, 0, 100), isNull);
      // 60–100 จากช่วงหลังยังนับได้ (ผ่าน 60 ขาขึ้นอีกครั้ง)
      expect(bestAccel(speed, 60, 100)!.seconds, closeTo(40 / 12, 0.05));
    });
  });

  group('ค่าจริงเทียบค่าที่กล่องต้องการ', () {
    test('บูสต์เกินต่อเนื่อง 3 วินาที = แจ้งเตือน', () {
      final r = _make([_boost, _boostCmd, _baro], 8, (t) => {'b': t >= 2 && t < 5 ? 240 : 200, 'bc': 200, 'p': 100});
      final ev = _events(r, RemapEventKind.overboost);
      expect(ev, hasLength(1));
      expect(ev.single.level, RemapLevel.warn);
      expect(ev.single.peak, closeTo(40, 0.01));
      expect(ev.single.start, closeTo(2, 0.05));
      expect(ev.single.duration, closeTo(3, 0.15));
    });

    test('กระชากสั้นกว่า 1 วินาทีไม่นับ', () {
      final r = _make([_boost, _boostCmd, _baro], 8, (t) => {'b': t >= 2 && t < 2.5 ? 260 : 200, 'bc': 200, 'p': 100});
      expect(_events(r, RemapEventKind.overboost), isEmpty);
    });

    test('เกินมาก (มากกว่า 40 kPa) เป็นระดับเสี่ยง', () {
      final r = _make([_boost, _boostCmd, _baro], 8, (t) => {'b': t >= 2 && t < 5 ? 260 : 200, 'bc': 200, 'p': 100});
      expect(_events(r, RemapEventKind.overboost).single.level, RemapLevel.bad);
    });

    test('จังหวะเปลี่ยนเกียร์ (ค่าที่ต้องการลดทันที บูสต์จริงค่อยๆ ลด) ไม่นับว่าบูสต์เกิน', () {
      final r = _make([_boost, _boostCmd, _baro], 6, (t) {
        final cmd = t < 3 ? 220.0 : 120.0;
        final act = t < 3 ? 220.0 : 120 + 100 * (1 - (t - 3) / 1.2).clamp(0.0, 1.0);
        return {'b': act, 'bc': cmd, 'p': 100};
      });
      expect(_events(r, RemapEventKind.overboost), isEmpty);
    });

    test('ค่าที่ต้องการตกแล้วค่อยๆ กลับ (เปลี่ยนเกียร์) ไม่เอาช่วงนั้นมาคิด บูสต์เกินยังเท่าค่าจริง', () {
      // บูสต์จริงเกินคงที่ 30 kPa แต่ช่วง 3.0–3.6 วินาที ค่าที่ต้องการตกเหลือ 207 แล้วไต่กลับเป็น 225
      // ถ้าดูแค่ต้นกับปลายหน้าต่าง จะได้ค่าเกินเป็น 36 kPa ซึ่งไม่จริง
      final r = _make([_boost, _boostCmd, _baro], 8, (t) {
        final cmd = t < 3 ? 225.0 : (t < 3.6 ? 207 + 18 * (t - 3) / 0.6 : 225.0);
        return {'b': 255, 'bc': cmd, 'p': 100};
      });
      final ev = _events(r, RemapEventKind.overboost);
      expect(ev, isNotEmpty);
      for (final e in ev) {
        expect(e.peak, closeTo(30, 0.01));
      }
    });

    test('ค่าที่ต้องการลดเป็นขั้นเล็กน้อย (16 kPa) บูสต์จริงลดตามช้า ไม่ทำให้ค่าเกินดูสูงกว่าความจริง', () {
      // เจอจริงในรอบจำลอง: ตอนเปลี่ยนเกียร์ 3→4 ค่าที่ต้องการลด 225 → 209 ช่วงกว้าง 16 kPa ยังอยู่ในเกณฑ์นิ่ง
      // แต่บูสต์จริงยังค้าง 255 ทำให้ได้ค่าเกิน 46 kPa (ระดับเสี่ยง) ทั้งที่เกินจริงแค่ 30
      final r = _make([_boost, _boostCmd, _baro], 10, (t) {
        final cmd = t < 5 - 1e-9 ? 225.0 : 209.0;
        final act = t < 5 - 1e-9 ? 255.0 : (255 - 16 * (t - 5) / 0.8).clamp(239.0, 255.0);
        return {'b': act, 'bc': cmd, 'p': 100};
      });
      final ev = _events(r, RemapEventKind.overboost);
      expect(ev, isNotEmpty);
      for (final e in ev) {
        expect(e.peak, closeTo(30, 0.01));
        expect(e.level, RemapLevel.warn);
      }
    });

    test('บูสต์ไม่ถึงค่าที่ต้องการ = แจ้งเตือน', () {
      final r = _make([_boost, _boostCmd, _baro], 8, (t) => {'b': t >= 1 && t < 6 ? 160 : 220, 'bc': 220, 'p': 100});
      final ev = _events(r, RemapEventKind.underboost);
      expect(ev, hasLength(1));
      expect(ev.single.peak, closeTo(-60, 0.01));
    });

    test('กล่องไม่ได้ขอบูสต์ (เดินเบา) ไม่นับว่าบูสต์ไม่ถึง', () {
      final r = _make([_boost, _boostCmd, _baro], 8, (t) => {'b': 95, 'bc': 120, 'p': 100});
      expect(_events(r, RemapEventKind.underboost), isEmpty);
    });

    test('ความดันรางต่ำกว่าที่ต้องการมาก = เสี่ยง', () {
      final r = _make([_rail, _railCmd], 8, (t) => {'r': t >= 2 && t < 5 ? 120 : 150, 'rc': 150});
      final ev = _events(r, RemapEventKind.railLow);
      expect(ev, hasLength(1));
      expect(ev.single.level, RemapLevel.bad);
      expect(analyzeRemapRun(r).limpSuspected, true);
    });

    test('บูสต์เกินค่าสูงสุดที่ร้านตั้งไว้ (รถที่กล่องไม่บอกบูสต์ที่ต้องการ)', () {
      final r = _make([_boost, _baro], 6, (t) => {'b': t >= 1 && t < 4 ? 270 : 180, 'p': 100});
      expect(_events(r, RemapEventKind.boostCap), isEmpty, reason: 'ไม่ได้ตั้งค่า = ไม่ตรวจ');
      final ev = _events(r, RemapEventKind.boostCap, limits: const RemapLimits(boostCapGauge: 150));
      expect(ev, hasLength(1));
      expect(ev.single.peak, closeTo(170, 0.01));
    });

    test('เหยียบเกือบสุดแต่บูสต์ไม่ขึ้น = สงสัยโหมดป้องกันตัวเอง', () {
      final r = _make([_pedal, _rpm, _boost, _baro], 8, (t) => {'ped': t >= 1 ? 100 : 0, 'n': 2500, 'b': 110, 'p': 100});
      final a = analyzeRemapRun(r);
      expect(a.events.map((e) => e.kind), contains(RemapEventKind.noBoostFullPedal));
      expect(a.limpSuspected, true);
      // รถไม่มีเทอร์โบ ไม่ตรวจข้อนี้
      final na = _make([_pedal, _rpm, _boost, _baro], 8, (t) => {'ped': t >= 1 ? 100 : 0, 'n': 2500, 'b': 98, 'p': 100}, turbo: false);
      expect(analyzeRemapRun(na).events, isEmpty);
    });

    test('ความร้อนเกินเกณฑ์นานกว่า 2 วินาที', () {
      final hot = _make([_coolant], 10, (t) => {'ect': t >= 3 && t < 7 ? 108 : 95});
      expect(_events(hot, RemapEventKind.coolantHot).single.level, RemapLevel.bad);
      final spike = _make([_coolant], 10, (t) => {'ect': t >= 3 && t < 4 ? 108 : 95});
      expect(_events(spike, RemapEventKind.coolantHot), isEmpty);
      // เกณฑ์จากการตั้งค่า
      expect(_events(hot, RemapEventKind.coolantHot, limits: const RemapLimits(coolantMax: 110)), isEmpty);
    });

    test('รหัสปัญหาใหม่และไฟเตือนติดหลังทดสอบ', () {
      final r = _make([_speed], 2, (t) => {'v': 0})
        ..dtcBefore.add('P0401')
        ..dtcAfter.addAll(['P0401', 'P0234'])
        ..milAfter = true;
      final r2 = RemapRun.fromJson({...r.toJson(), 'milBefore': false});
      final a = analyzeRemapRun(r2);
      final dtc = a.events.firstWhere((e) => e.kind == RemapEventKind.newDtc);
      expect(dtc.detail, contains('P0234'));
      expect(dtc.detail, isNot(contains('P0401')));
      expect(a.events.map((e) => e.kind), contains(RemapEventKind.milOn));
      expect(a.level, RemapLevel.bad);
    });

    test('ข้อมูลขาดช่วงนาน ไม่ต่อเป็นช่วงผิดปกติเดียวกัน', () {
      final r = RemapRun(id: 'g', name: 'g', stage: RemapStage.other, start: DateTime(2026), channels: [_boost, _boostCmd, _baro]);
      for (final t in [0.0, 0.2, 0.4, 0.6, 10.0, 10.2, 10.4, 10.6]) {
        r.add(t, {'b': 250, 'bc': 200, 'p': 100});
      }
      expect(_events(r, RemapEventKind.overboost), isEmpty);
    });

    test('รอบสังเคราะห์: ก่อนรีแมพไม่พบอะไร หลังรีแมพพบบูสต์เกินช่วงเร่งยาว', () {
      final before = analyzeRemapRun(syntheticRemapRun(id: 'b', stage: RemapStage.before, start: DateTime(2026)));
      expect(before.events, isEmpty);
      expect(before.level, RemapLevel.ok);
      final after = analyzeRemapRun(syntheticRemapRun(
          id: 'a', stage: RemapStage.after, start: DateTime(2026), tau: 5.3, boostPeak: 150, railPeak: 175, overboost: 35));
      expect(after.events, hasLength(1));
      expect(after.events.single.kind, RemapEventKind.overboost);
      expect(after.events.single.level, RemapLevel.warn);
      expect(after.events.single.peak, closeTo(35, 1));
      expect(after.maxBoostGauge, closeTo(185, 1));
      expect(after.maxBoostCmdGauge, closeTo(150, 0.5));
      expect(after.max[RemapSignal.rail], closeTo(175, 1));
    });
  });

  group('เทียบก่อน/หลัง', () {
    final before = analyzeRemapRun(syntheticRemapRun(id: 'b', stage: RemapStage.before, start: DateTime(2026, 10, 20)));
    final after = analyzeRemapRun(syntheticRemapRun(
        id: 'a', stage: RemapStage.after, start: DateTime(2026, 10, 24), tau: 5.3, boostPeak: 150, railPeak: 175, overboost: 35));
    final rows = compareRemap(before, after);
    RemapCompareRow row(String label) => rows.firstWhere((r) => r.label.startsWith(label));

    test('อัตราเร่งเร็วขึ้น = ดีขึ้น', () {
      final r = row('อัตราเร่ง 0–100');
      expect(r.diff, lessThan(-1));
      expect(r.better, true);
      expect(r.diffText, startsWith('-1.'));
    });

    test('บูสต์สูงขึ้นแสดงตัวเลขแต่ไม่ตัดสินว่าดี', () {
      final r = row('บูสต์สูงสุด');
      expect(r.after! - r.before!, closeTo(75, 2));
      expect(r.better, isNull);
    });

    test('สิ่งผิดปกติเพิ่มขึ้น = แย่ลง และหัวข้อสรุปบอกว่าเร็วขึ้นกี่วินาที', () {
      expect(row('สิ่งผิดปกติ').better, false);
      expect(remapCompareHeadline(rows), contains('เร็วขึ้น'));
      expect(remapCompareHeadline(rows), contains('0–100'));
    });

    test('กราฟความเร็วซ้อนกันที่จุดเริ่มจับเวลา และบูสต์ตามรอบ', () {
      final tr = accelTrace(after, after.accelFor(0, 100)!);
      expect(tr.first.$1, lessThan(0));
      expect(tr.any((p) => p.$1.abs() < 0.2), true);
      final curve = binnedMax(versusRpm(after, RemapSignal.boost));
      expect(curve.length, greaterThan(4));
      expect(curve.map((p) => p.$2).reduce((a, b) => a > b ? a : b), closeTo(185, 2));
      // จุดเรียงตามรอบเครื่อง
      for (var i = 1; i < curve.length; i++) {
        expect(curve[i].$1, greaterThan(curve[i - 1].$1));
      }
    });
  });

  group('บันทึกและส่งออก', () {
    test('JSON กลับไปกลับมาได้ครบ ผลวิเคราะห์เท่าเดิม', () {
      final r = syntheticRemapRun(id: 'j', stage: RemapStage.after, start: DateTime(2026, 10, 27, 9, 5), overboost: 35, dtcAfter: ['P0234']);
      final back = RemapRun.decode(r.encode());
      expect(back.id, 'j');
      expect(back.stage, RemapStage.after);
      expect(back.channels.map((c) => c.key), r.channels.map((c) => c.key));
      expect(back.rows.length, r.rows.length);
      expect(back.turbo, true);
      expect(back.dtcAfter, ['P0234']);
      final a1 = analyzeRemapRun(r), a2 = analyzeRemapRun(back);
      expect(a2.accelFor(0, 100)!.seconds, closeTo(a1.accelFor(0, 100)!.seconds, 0.001));
      expect(a2.events.length, a1.events.length);
    });

    test('ไฟล์เสียบางส่วน อ่านได้เท่าที่มี', () {
      final j = syntheticRemapRun(id: 'k', stage: RemapStage.other, start: DateTime(2026)).toJson();
      final rows = (j['rows'] as List<dynamic>).take(10).toList();
      final back = RemapRun.fromJson({...j, 'rows': rows});
      expect(back.rows.length, 10);
      expect(back.times.length, 10);
    });

    test('CSV มีหัวคอลัมน์และครบทุกแถว', () {
      final r = syntheticRemapRun(id: 'c', stage: RemapStage.before, start: DateTime(2026));
      final lines = r.toCsv().trim().split('\n');
      expect(lines.first, '# ProScaner remap test');
      expect(lines[5], startsWith('time_s,ความเร็วรถ (กม./ชม.),รอบเครื่องยนต์'));
      expect(lines.length, 6 + r.rows.length);
    });

    test('ที่เก็บในหน่วยความจำและในไฟล์ เรียงใหม่สุดก่อน', () async {
      final a = syntheticRemapRun(id: 'r1', stage: RemapStage.before, start: DateTime(2026, 10, 20));
      final b = syntheticRemapRun(id: 'r2', stage: RemapStage.after, start: DateTime(2026, 10, 24));
      final mem = MemoryRemapStore();
      await mem.save(a);
      await mem.save(b);
      expect((await mem.list()).map((r) => r.id), ['r2', 'r1']);

      final dir = Directory.systemTemp.createTempSync('remap_store_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final fs = RemapStore(directory: dir);
      await fs.save(a);
      await fs.save(b);
      expect((await fs.list()).map((r) => r.id), ['r2', 'r1']);
      // บันทึกซ้ำ (เปลี่ยนชื่อ) ต้องแทนที่ไฟล์เดิม
      a.name = 'เปลี่ยนชื่อแล้ว';
      await fs.save(a);
      final again = await fs.list();
      expect(again.length, 2);
      expect(again.last.name, 'เปลี่ยนชื่อแล้ว');
      await fs.delete('r1');
      expect((await fs.list()).map((r) => r.id), ['r2']);
      expect(dir.listSync(recursive: true).where((f) => f.path.endsWith('.tmp')), isEmpty);
    });

    testWidgets('รายงาน PDF รอบเดียว และเทียบก่อน/หลัง', (tester) async {
      final before = analyzeRemapRun(syntheticRemapRun(id: 'b', stage: RemapStage.before, start: DateTime(2026, 10, 20)));
      final after = analyzeRemapRun(syntheticRemapRun(
          id: 'a', stage: RemapStage.after, start: DateTime(2026, 10, 24), tau: 5.3, boostPeak: 150, overboost: 35));
      late Uint8List single, pair;
      await tester.runAsync(() async {
        single = await buildRemapPdf(before: after);
        pair = await buildRemapPdf(before: before, after: after);
      });
      expect(String.fromCharCodes(single.take(4)), '%PDF');
      expect(String.fromCharCodes(pair.take(4)), '%PDF');
      expect(pair.length, greaterThan(20000));
    });
  });

  group('เดาค่าจากชุดค่าเฉพาะยี่ห้อ', () {
    ExtPid p(String en, String unit, {String name = 'ค่า', Map<int, String>? labels}) =>
        ExtPid(name: name, en: en, unit: unit, request: '221234', header: '7E0', formula: 'A', labels: labels);

    test('ชุด D-Max 2007: บูสต์ที่ต้องการ (1130) และบูสต์ (1240) ไม่เอาค่าแรงดันไฟเซนเซอร์', () {
      final pack = ExtPidPack.fromJson(
          jsonDecode(File('assets/ext_packs/isuzu_dmax_2007.json').readAsStringSync()) as Map<String, dynamic>);
      final found = {
        for (final x in pack.pids)
          if (classifyRemapExt(x) case final c?) x.request: c,
      };
      expect(found['221130']!.signal, RemapSignal.boostCmd);
      expect(found['221130']!.convert(117), 117);
      expect(found['221240']!.signal, RemapSignal.boost);
      // ความดันรางจริง (1250) และที่ต้องการ (1450) หน่วย MPa ใช้ได้ตรงๆ
      expect(found['221250']!.signal, RemapSignal.rail);
      expect(found['221250']!.convert(84), 84);
      expect(found['221450']!.signal, RemapSignal.railCmd);
      expect(found['221450']!.convert(56), 56);
      for (final req in ['221151', '221110', '221100', '221170', '221270', '221212', '221150', '221200', '221203']) {
        expect(found.containsKey(req), false, reason: req);
      }
    });

    test('ชุด Toyota Hilux: ไม่เสนอค่ารายสูบ/มีเลขลำดับ และเสนอชนิดละไม่เกิน 2 ตัว ตัวที่พบในรถจริงก่อน', () {
      final pack = ExtPidPack.fromJson(
          jsonDecode(File('assets/ext_packs/toyota_hilux.json').readAsStringSync()) as Map<String, dynamic>);
      final all = [
        for (final x in pack.pids)
          if (classifyRemapExt(x) case final c?) c,
      ];
      expect(all.where((c) => c.pid.name.contains('สูบ')), isEmpty);
      expect(all.where((c) => RegExp(r'\s\d+$').hasMatch(c.pid.name)), isEmpty);
      final picked = pickRemapExt(all);
      for (final s in RemapSignal.values) {
        expect(picked.where((c) => c.signal == s).length, lessThanOrEqualTo(2), reason: s.name);
      }
      final railCmd = picked.where((c) => c.signal == RemapSignal.railCmd).toList();
      expect(railCmd, isNotEmpty);
      expect(railCmd.first.pid.trust, greaterThanOrEqualTo(1));
      expect(railCmd.first.convert(150000), closeTo(150, 1e-9));
    });

    test('แปลงหน่วยและแยกชนิดถูก', () {
      expect(classifyRemapExt(p('Boost, desired', 'bar'))!.convert(1.5), closeTo(150, 1e-9));
      expect(classifyRemapExt(p('Boost, desired', 'bar'))!.signal, RemapSignal.boostCmd);
      expect(classifyRemapExt(p('Boost', 'psi'))!.convert(10), closeTo(68.9476, 1e-6));
      final rail = classifyRemapExt(p('Fuel rail pressure, desired', 'kPa'))!;
      expect(rail.signal, RemapSignal.railCmd);
      expect(rail.convert(150000), closeTo(150, 1e-9));
      expect(classifyRemapExt(p('Fuel rail pressure', 'psi'))!.signal, RemapSignal.rail);
      expect(classifyRemapExt(p('Exhaust gas temperature 1', '°C'))!.signal, RemapSignal.egt);
      expect(classifyRemapExt(p('Exhaust gas temperature', '°F'))!.convert(212), closeTo(100, 1e-9));
      expect(classifyRemapExt(p('Injection volume - target', ''))!.signal, RemapSignal.injQty);
      expect(classifyRemapExt(p('Injection volume total', ''))!.signal, RemapSignal.injQty);
      expect(classifyRemapExt(p('', 'kPa', name: 'ความดันบูสต์ที่ต้องการ'))!.signal, RemapSignal.boostCmd);
      for (final x in [
        p('Cylinder 1 injection volume', ''),
        p('Injection volume 3', ''),
        p('Injection volume', 'L'),
        p('Fuel injection volume control, cylinder 2', ''),
        p('Fuel injection amount, pilot 1', ''),
        p('Brake booster pressure', 'kPa'),
        p('Boost pressure sensor voltage', 'V'),
        p('Low side fuel rail pressure', 'kPa'),
        p('Variable geometry turbo duty cycle', '%'),
        p('Turbo boost', 'kPa', labels: {0: 'ปิด', 1: 'เปิด'}),
        p('Target common rail fuel pressure', ''),
      ]) {
        expect(classifyRemapExt(x), isNull, reason: x.en);
      }
    });
  });

  group('อ่านค่าจากรถจำลอง', () {
    test('ถาม 6 PID ในคำสั่งเดียว ได้ครบ และค่าตรงกับถามทีละตัว', () async {
      final (t, elm) = await _demo();
      final svc = ObdService(elm);
      t
        ..rpmOverride = 2000
        ..speedOverride = 55
        ..coolantOverride = 90;
      final v = await svc.readPidsMulti([Pid.speed, Pid.rpm, Pid.coolantTemp, Pid.engineLoad, Pid.intakeTemp, Pid.moduleVoltage]);
      expect(v.keys.toSet(), {Pid.speed, Pid.rpm, Pid.coolantTemp, Pid.engineLoad, Pid.intakeTemp, Pid.moduleVoltage});
      expect(v[Pid.speed], 55);
      expect(v[Pid.rpm], 2000);
      expect(v[Pid.coolantTemp], await svc.readPid(Pid.coolantTemp));
      // PID ที่รถไม่รองรับไม่อยู่ในคำตอบ ตัวอื่นยังได้ครบ
      final w = await svc.readPidsMulti([Pid.speed, Pid.fuelPressure, Pid.rpm]);
      expect(w.keys.toSet(), {Pid.speed, Pid.rpm});
      await expectLater(svc.readPidsMultiRaw(List.filled(7, Pid.speed)), throwsArgumentError);
      await _close(t, elm);
    });

    test('กล่องที่ตอบได้ทีละ PID: ใช้แบบทีละตัว ยังได้ความเร็วทุกรอบ', () async {
      final (t, elm) = await _demo();
      t.multiPid = false;
      final svc = ObdService(elm);
      final clock = Stopwatch()..start();
      final s = RemapSampler(svc, clock: () => clock.elapsedMicroseconds / 1e6);
      await s.init();
      expect(s.multiPid, false);
      expect(svc.multiPidOk, false);
      final run = RemapRun(id: 'x', name: 'x', stage: RemapStage.other, start: DateTime.now(), channels: s.channels);
      for (var i = 0; i < 6; i++) {
        await s.step(run.add);
      }
      expect(run.series('std:0D').length, 6);
      expect(run.series('std:0C').length, 6);
      await _close(t, elm);
    });

    test('ดีเซลเทอร์โบ: อ่านบูสต์/รางทั้งค่าที่ต้องการและค่าจริงจากคำตอบเดียวกัน', () async {
      final (t, elm) = await _demo();
      t.turboDiesel = true;
      final svc = ObdService(elm);
      final clock = Stopwatch()..start();
      final s = RemapSampler(svc, clock: () => clock.elapsedMicroseconds / 1e6);
      await s.init(diesel: true);
      expect(s.multiPid, true);
      expect(s.turbo, true);
      final keys = s.channels.map((c) => c.key).toList();
      expect(keys, containsAll(['std:0D', 'std:0C', RemapSampler.boostActKey, RemapSampler.boostCmdKey,
          RemapSampler.railActKey, RemapSampler.railCmdKey, 'std:78']));
      expect(keys, isNot(contains('std:0B')), reason: 'มี PID 70 แล้ว ไม่ต้องอ่านท่อไอดีซ้ำ');
      expect(keys, isNot(contains('std:23')), reason: 'มี PID 6D แล้ว');
      t.startDrive();
      final run = RemapRun(id: 'x', name: 'x', stage: RemapStage.other, start: DateTime.now(), channels: s.channels, turbo: true);
      for (var i = 0; i < 12; i++) {
        await s.step(run.add);
      }
      expect(run.series('std:0D').length, 12);
      expect(run.series(RemapSampler.boostCmdKey), isNotEmpty);
      expect(run.series(RemapSampler.boostActKey), isNotEmpty);
      expect(run.series(RemapSampler.railCmdKey).last.$2, greaterThan(30));
      expect(run.series('std:78'), isNotEmpty);
      // ค่าที่ต้องการกับค่าจริงมาพร้อมกันในแถวเดียวกัน
      final ib = run.indexOf(RemapSampler.boostCmdKey), ia = run.indexOf(RemapSampler.boostActKey);
      expect(run.rows.any((r) => r[ib] != null && r[ia] != null), true);
      expect(s.requests, greaterThanOrEqualTo(12 * 3));
      await _close(t, elm);
    });

    test('อ่านค่าเฉพาะยี่ห้อร่วมด้วย (แปลงหน่วยแล้ว)', () async {
      final (t, elm) = await _demo();
      final svc = ObdService(elm);
      final clock = Stopwatch()..start();
      // 7E0 22 1210 ของรถจำลอง = อุณหภูมิน้ำหล่อเย็น (A-40) ใช้แทนค่าเฉพาะยี่ห้อหนึ่งตัว
      final ext = RemapExtChannel(
        ExtPid(name: 'อุณหภูมิไอเสีย (ทดสอบ)', en: 'Exhaust gas temperature', unit: '°C', request: '221210', header: '7E0', formula: 'A-40'),
        RemapSignal.egt,
      );
      final s = RemapSampler(svc, clock: () => clock.elapsedMicroseconds / 1e6, ext: [ext], extEvery: 2);
      await s.init();
      final run = RemapRun(id: 'x', name: 'x', stage: RemapStage.other, start: DateTime.now(), channels: s.channels);
      for (var i = 0; i < 6; i++) {
        await s.step(run.add);
      }
      final pts = run.series(ext.key);
      expect(pts.length, 3);
      expect(pts.first.$2, closeTo((await svc.readPid(Pid.coolantTemp))!, 1));
      await _close(t, elm);
    });
  });
}
