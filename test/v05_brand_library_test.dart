import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:obd_doctor/core/elm/elm327.dart';
import 'package:obd_doctor/core/obd/ext_library.dart';
import 'package:obd_doctor/core/obd/ext_pid.dart';
import 'package:obd_doctor/core/obd/formula.dart';
import 'package:obd_doctor/core/obd/formula_fit.dart';
import 'package:obd_doctor/core/transport/demo_transport.dart';
import 'package:obd_doctor/core/transport/obd_transport.dart';

ExtLibrary _lib() => ExtLibrary(loader: (path) async => File(path).readAsString());

/// ตัวสแกนรุ่นเก่า: ไม่รับ ATSH แบบ 8 หลัก (ตอบ "?") แต่รับ ATCP + ATSH 6 หลัก
class _OldChipTransport implements ObdTransport {
  final sent = <String>[];
  final _c = StreamController<List<int>>.broadcast();
  bool _on = false;

  @override
  TransportKind get kind => TransportKind.demo;
  @override
  String get displayName => 'old chip';
  @override
  Stream<List<int>> get incoming => _c.stream;
  @override
  bool get isConnected => _on;
  @override
  Future<void> connect() async => _on = true;
  @override
  Future<void> disconnect() async => _on = false;
  @override
  Future<void> write(List<int> bytes) async {
    final cmd = String.fromCharCodes(bytes).trim();
    sent.add(cmd);
    final reply = cmd.startsWith('ATSH') && cmd.length == 12 ? '?' : 'OK';
    scheduleMicrotask(() => _c.add('$reply\r\r>'.codeUnits));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('สูตร: ฟังก์ชันใหม่', () {
    test('bits / S(x,n) / เลขยกกำลังสิบ', () {
      expect(Formula('bits(A,4,4)').eval([0xAB]), 0xA);
      expect(Formula('bits((A*256+B),3,10)').eval([0x12, 0x34]), (0x1234 >> 3) & 0x3FF);
      expect(Formula('S(bits((A*256+B),0,12),12)').eval([0x0F, 0xFF]), -1);
      expect(Formula('S(A,4)').eval([0x08]), -8);
      expect(Formula('S(A)').eval([0x80]), -128);
      expect(Formula('A*1e-2').eval([150]), closeTo(1.5, 1e-9));
      expect(Formula('{AD:6}').eval(List<int>.filled(30, 0)..[29] = 0x40), 1);
    });
  });

  group('คลังชุดค่า (assets/ext_packs)', () {
    test('ทุกชุดโหลดได้ ทุกค่าใช้ได้ และถอดตัวอย่างคำตอบจริงได้ตรงกับแหล่งข้อมูล', () async {
      final lib = _lib();
      final idx = await lib.index();
      expect(idx.length, greaterThanOrEqualTo(8));
      expect(idx.map((e) => e.lib), containsAll(['toyota_hilux', 'mitsubishi_triton', 'isuzu_dmax_2020', 'isuzu_dmax_2012']));
      var checked = 0;
      for (final e in idx) {
        final pack = await lib.pack(e);
        expect(pack.pids.length, e.count, reason: e.lib);
        expect(pack.sources, isNotEmpty, reason: '${e.lib} ต้องระบุแหล่งที่มา');
        expect(pack.lib, e.lib);
        for (final p in pack.pids) {
          expect(p.validate(), isNull, reason: '${e.lib} ${p.id} ${p.formula}');
          expect(p.verified, false, reason: 'ชุดในคลังต้องยังไม่ถูกยืนยันโดยร้าน');
          for (final ev in p.evidence) {
            final r = ExtPidReader.evaluate(p, ev.raw);
            final want = ev.value;
            if (want == null) {
              // แหล่งข้อมูลถือว่าไม่มีค่า: แอปต้องขึ้นว่าไม่มีค่า หรือ (ค่าสถานะ) เป็นค่าที่ไม่รู้จัก
              expect(r.value == null || (p.isState && r.outOfRange), true, reason: '${p.id} ${bytesToHex(ev.raw)} ควรไม่มีค่า');
            } else if (want is num) {
              expect(r.value, isNotNull, reason: '${p.id} ${r.error}');
              expect(r.value!, closeTo(want.toDouble(), 1e-4 * (want.abs() > 1 ? want.abs() : 1)), reason: '${p.id} ${p.formula}');
            } else {
              expect(p.format(r.value!), want, reason: '${p.id} label');
            }
            checked++;
          }
        }
      }
      // มีตัวอย่างคำตอบจริงให้ตรวจจำนวนมาก
      expect(checked, greaterThan(500));
    });

    test('ข้อมูลในคลังแยกที่มาชัดเจน และใส่สัญญาอนุญาตของ OBDb', () async {
      final lib = _lib();
      for (final e in await lib.index()) {
        final pack = await lib.pack(e);
        for (final s in pack.sources.where((s) => s.name.startsWith('OBDb'))) {
          expect(s.license, 'CC BY-SA 4.0');
          expect(s.url, startsWith('https://github.com/OBDb/'));
        }
      }
      final dmax = (await lib.index()).firstWhere((e) => e.lib == 'isuzu_dmax_2012');
      final p = await lib.pack(dmax);
      final atf = p.pids.firstWhere((x) => x.request == '221940');
      expect(atf.header, '7E2');
      expect(atf.formula, 'A-40');
      expect(ExtPidReader.evaluate(atf, [120]).value, 80);
    });

    test('ปีของแต่ละชุดตรงกับช่วงที่รุ่นนั้นมีขายจริง (ไม่ขึ้นว่า Veloz มีตั้งแต่ 2008)', () async {
      final idx = {for (final e in await _lib().index()) e.lib: e};
      expect(idx['toyota_veloz']!.years, [2021, 2026]);
      expect(idx['toyota_corolla_cross']!.years, [2020, 2026]);
      expect(idx['toyota_yaris_cross']!.years.first, 2020);
      expect(idx['mazda_cx30']!.years.first, 2020);
      expect(idx['isuzu_dmax_2012']!.years, [2012, 2019]);
      // รถ Toyota ปี 2008 รุ่นไม่ทราบ: Hilux ต้องได้คะแนนมากกว่า Veloz
      final hilux = idx['toyota_hilux']!.matchScore(brand: 'Toyota', year: 2008);
      final veloz = idx['toyota_veloz']!.matchScore(brand: 'Toyota', year: 2008);
      expect(hilux, greaterThan(veloz));
    });

    test('ชุดจากคลังเป็นสำเนา แก้ไขแล้วไม่กระทบคลัง', () async {
      final lib = _lib();
      final e = (await lib.index()).firstWhere((e) => e.lib == 'toyota_hilux');
      final a = await lib.pack(e);
      a.pids.first.verified = true;
      a.pids.removeLast();
      final b = await lib.pack(e);
      expect(b.pids.first.verified, false);
      expect(b.pids.length, e.count);
    });

    test('รถคนละแบบ (11/29 บิต) ไม่ส่งคำสั่ง และคำสั่งซ้ำส่งครั้งเดียว', () async {
      final t = DemoTransport(responseDelay: const Duration(milliseconds: 1));
      await t.connect();
      final elm = Elm327(t)..attach();
      await elm.initialize();
      final log = <String>[];
      elm.onLog = log.add;
      final pids = [
        for (var c = 0; c < 4; c++)
          ExtPid(name: 'fb${c + 1}', request: '22112B', formula: '${String.fromCharCode(65 + c)}*5/32-20', header: '700', id: 'FB$c'),
        ExtPid(name: '29bit', request: '224500', formula: 'A', header: '18DA15F1', id: 'X29'),
        ExtPid(name: 'silent', request: '229999', formula: 'A', header: '700', id: 'SIL'),
      ];
      final skip = <String>{};
      final r = await ExtPidReader(elm, skip: skip).readAll(pids);
      expect(log.where((l) => l == '> 22112B').length, 1);
      expect(log.any((l) => l.startsWith('> ATSH18DA')), false);
      expect(r[pids[4].key]!.skipped, true);
      for (var c = 0; c < 4; c++) {
        expect(r[pids[c].key]!.value, isNotNull);
      }
      expect(r[pids[5].key]!.error, isNotNull);
      // เงียบครั้งแรกยังไม่ข้าม (กันพลาดจากจังหวะเดียว) รอบสองยังถาม
      log.clear();
      final r2 = await ExtPidReader(elm, skip: skip).readAll(pids);
      expect(log.where((l) => l == '> 229999').length, 1);
      expect(r2[pids[5].key]!.skipped, false);
      // เงียบซ้ำแล้ว รอบถัดไปไม่ถามอีก
      log.clear();
      final r3 = await ExtPidReader(elm, skip: skip).readAll(pids);
      expect(log.where((l) => l == '> 229999').length, 0);
      expect(r3[pids[5].key]!.skipped, true);
      expect(r3[pids[0].key]!.value, isNotNull);
      // header กลับเป็นปกติ อ่าน OBD มาตรฐานได้
      final std = await elm.query('010C');
      expect(std.messages, isNotEmpty);
      await elm.detach();
      await t.disconnect();
    });

    test('ทดสอบชุด Hilux กับรถจำลอง: รถตอบบางคำสั่ง และค่าที่ได้อยู่ในช่วง', () async {
      final t = DemoTransport(responseDelay: const Duration(milliseconds: 1));
      await t.connect();
      final elm = Elm327(t)..attach();
      await elm.initialize();
      final lib = _lib();
      final hilux = await lib.pack((await lib.index()).firstWhere((e) => e.lib == 'toyota_hilux'));
      final r = await ExtPidReader(elm).probe(hilux.pids, maxCommands: 40);
      expect(r.commands, greaterThan(5));
      expect(r.responded, greaterThan(2));
      expect(r.pidsOk, greaterThan(0));
      // ชุด Triton ใช้กับรถจำลองไม่ได้
      final triton = await lib.pack((await lib.index()).firstWhere((e) => e.lib == 'mitsubishi_triton'));
      final r2 = await ExtPidReader(elm).probe(triton.pids, maxCommands: 10);
      expect(r2.responded, lessThan(r.responded));
      expect(r2.carSilent, false, reason: 'รถตอบ OBD มาตรฐาน แค่ไม่รู้จักคำสั่งของ Triton');
      expect(r2.verdict, isNot('รถไม่ตอบ'));
      // ค้นหา: เลขที่เจอส่งออกมาทันทีระหว่างค้นหา และตรงกับผลสุดท้าย
      final live = <DidHit>[];
      final hits = await ExtPidReader(elm)
          .scanJobs([const ScanJob(header: '700', service: 0x22, start: 0x1100, end: 0x1140)], onHit: live.add);
      expect(hits.map((h) => h.request), containsAll(['221105', '22112B', '221131']));
      expect(live.map((h) => h.request).toList(), hits.map((h) => h.request).toList());
      await elm.detach();
      await t.disconnect();
    });

    test('ปิดสวิตช์กุญแจ: ไม่จำว่าข้าม ไม่สรุปว่าชุดไม่ตรง และบอกให้เปิดสวิตช์', () async {
      final t = DemoTransport(responseDelay: const Duration(milliseconds: 1));
      await t.connect();
      final elm = Elm327(t)..attach();
      await elm.initialize();
      final lib = _lib();
      final hilux = await lib.pack((await lib.index()).firstWhere((e) => e.lib == 'toyota_hilux'));
      final pids = hilux.pids.where((p) => p.request == '22112B' || p.request == '221627').toList();
      expect(pids.length, greaterThanOrEqualTo(5));
      t.ignitionOff = true;
      final skip = <String>{};
      final reader = ExtPidReader(elm, skip: skip);
      for (var round = 0; round < 3; round++) {
        final r = await reader.readAll(pids);
        expect(reader.carSilent, true);
        expect(skip, isEmpty, reason: 'รถดับต้องไม่ถูกจำว่าคำสั่งใช้ไม่ได้');
        expect(r.values.every((x) => x.error != null && x.error!.contains('รถไม่ตอบ')), true);
      }
      final pr = await ExtPidReader(elm).probe(hilux.pids, maxCommands: 6);
      expect(pr.carSilent, true);
      expect(pr.verdict, 'รถไม่ตอบ');
      expect(pr.level, 0);
      final sr = ExtPidReader(elm);
      final sw = Stopwatch()..start();
      final hits = await sr.scanJobs([const ScanJob(header: '7E0', service: 0x21, start: 0x00, end: 0xFF)]);
      expect(sr.carSilent, true);
      expect(hits, isEmpty);
      expect(sw.elapsed.inSeconds, lessThan(3), reason: 'รถไม่ตอบต้องหยุดทันที ไม่ไล่ถาม 256 เลข');
      // เปิดสวิตช์แล้วอ่านได้ตามปกติ ด้วยชุดข้ามเดิม
      t.ignitionOff = false;
      final r2 = await reader.readAll(pids);
      expect(reader.carSilent, false);
      expect(r2.values.where((x) => x.ok).length, greaterThanOrEqualTo(5));
      // header กลับเป็นปกติ
      expect((await elm.query('010C')).messages, isNotEmpty);
      await elm.detach();
      await t.disconnect();
    });

    test('ตัวสแกนรุ่นเก่าที่ไม่รับ header 29 บิตแบบ 4 ไบต์ ตั้งเป็น ATCP + 3 ไบต์แทน', () async {
      final t = _OldChipTransport();
      await t.connect();
      final elm = Elm327(t)..attach();
      elm.protocolCode = 'A7'; // CAN 29 บิต
      await elm.exclusive(() async {
        await elm.setTarget('18DA10F1', '18DAF110');
        await elm.resetTarget();
      });
      expect(t.sent, [
        'ATSH18DA10F1', 'ATCP18', 'ATSHDA10F1', 'ATCRA18DAF110', //
        'ATCRA', 'ATSH18DB33F1', 'ATCP18', 'ATSHDB33F1', 'ATST32',
      ]);
      await elm.detach();
      await t.disconnect();
    });

    test('รหัสปฏิเสธเป็นภาษาไทย และรหัสที่ถามซ้ำไม่มีประโยชน์จะถูกข้าม', () {
      final r = ExtPidReader.parse(0x22, [0x11, 0x2B], [
        [0x7F, 0x22, 0x78],
        [0x7F, 0x22, 0x33],
      ]);
      expect(r.status, ExtCmdStatus.negative);
      expect(r.nrc, 0x33);
      expect(r.error, contains('ล็อก'));
      expect(nrcPermanent(0x33), true);
      expect(nrcPermanent(0x31), true);
      expect(nrcPermanent(0x22), false, reason: 'สภาพรถยังไม่พร้อม ลองใหม่ได้');
      expect(nrcPermanent(0x21), false);
      expect(nrcText(0x7F), contains('โหมดพิเศษ'));
      expect(nrcText(0x99), contains('0x99'));
      // รอตอบ (78) แล้วได้คำตอบจริง
      final ok = ExtPidReader.parse(0x22, [0x16, 0x27], [
        [0x7F, 0x22, 0x78],
        [0x62, 0x16, 0x27, 0x68, 0x60],
      ]);
      expect(ok.status, ExtCmdStatus.ok);
      expect(ok.payload, [0x68, 0x60]);
    });
  });

  group('หาสูตรจากจุดเทียบ', () {
    List<CalPoint> pts(List<List<int>> raws, double Function(List<int>) f) => [for (final r in raws) CalPoint(raw: r, ref: f(r))];

    test('หา A-40 จากอุณหภูมิ', () {
      final p = pts([
        [0x12, 60, 0x99],
        [0x12, 95, 0x40],
        [0x13, 128, 0x41],
      ], (r) => r[1] - 40.0);
      final c = FormulaFit.fit(p);
      expect(c, isNotEmpty);
      expect(c.first.formula, 'B-40');
      expect(c.first.fits, true);
    });

    test('หา 16 บิต /100 และแบบมีเครื่องหมาย', () {
      final p = pts([
        [0x00, 0x2A, 0x00],
        [0x01, 0x23, 0x00],
        [0xFF, 0x9C, 0x00],
        [0xFF, 0xE4, 0x00],
      ], (r) {
        final x = r[0] * 256 + r[1];
        return (x >= 0x8000 ? x - 0x10000 : x) / 100.0;
      });
      final c = FormulaFit.fit(p);
      expect(c.first.formula, 'S16(A,B)/100');
    });

    test('ค่าจากเครื่องมือศูนย์ปัดเศษ ยังหาสูตรถูก', () {
      // ศูนย์แสดงทศนิยม 1 ตำแหน่ง: (A*256+B)/256-40
      final raws = [
        [0x5A, 0xA0],
        [0x5D, 0x20],
        [0x60, 0xE0],
        [0x75, 0x10],
      ];
      final p = [for (final r in raws) CalPoint(raw: r, ref: double.parse(((r[0] * 256 + r[1]) / 256 - 40).toStringAsFixed(1)))];
      final c = FormulaFit.fit(p);
      expect(c.first.fits, true);
      expect(Formula(c.first.formula).eval([0x68, 0x60]), closeTo((0x6860) / 256 - 40, 0.06));
    });

    test('จุดเดียว หรือค่าเท่ากันหมด หาสูตรไม่ได้', () {
      expect(FormulaFit.fit([CalPoint(raw: [1], ref: 5)]), isEmpty);
      expect(FormulaFit.fit([CalPoint(raw: [1], ref: 5), CalPoint(raw: [2], ref: 5)]), isEmpty);
    });

    test('ตรวจสูตรเดิมกับจุดเทียบ', () {
      final p = [CalPoint(raw: [100], ref: 60), CalPoint(raw: [130], ref: 90)];
      final ok = FormulaFit.check('A-40', p)!;
      expect(ok.$1, 0);
      final bad = FormulaFit.check('A-50', p)!;
      expect(bad.$1, 10);
      expect(bad.$1 > bad.$2, true);
    });
  });

  group('บันทึกผลยืนยัน', () {
    test('ผลยืนยันและจุดเทียบติดไปกับชุดเมื่อส่งออก', () {
      final p = ExtPid(name: 'ATF', request: '221627', formula: '(A*256+B)/256-40', header: '700', unit: '°C')
        ..verified = true
        ..verifiedBy = 'อู่ช่างเอ'
        ..verifiedAt = DateTime(2026, 10, 26)
        ..verifiedOn = 'Toyota Hilux Revo 2019 (VIN …345678)'
        ..points.add(CalPoint(raw: [0x68, 0x60], ref: 64.4, at: DateTime(2026, 10, 26, 9)));
      final pack = ExtPidPack(id: 'x', name: 'ชุดทดสอบ', pids: [p]);
      final (back, skipped) = importPack(pack.export());
      expect(skipped, 0);
      final q = back.pids.single;
      expect(q.verified, true);
      expect(q.verifiedBy, 'อู่ช่างเอ');
      expect(q.verifiedOn, contains('Hilux'));
      expect(q.points.single.ref, 64.4);
      expect(q.points.single.raw, [0x68, 0x60]);
      expect(jsonEncode(q.toJson()), jsonEncode(p.toJson()));
    });
  });
}
