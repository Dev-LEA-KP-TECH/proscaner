import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:obd_doctor/core/analysis/remap_sampler.dart';
import 'package:obd_doctor/core/elm/elm327.dart';
import 'package:obd_doctor/core/obd/ext_pid.dart';
import 'package:obd_doctor/core/obd/obd_service.dart';
import 'package:obd_doctor/core/obd/pids.dart';
import 'package:obd_doctor/core/safety/command_guard.dart';
import 'package:obd_doctor/core/transport/demo_transport.dart';
import 'package:obd_doctor/core/transport/obd_transport.dart';
import 'package:obd_doctor/core/uds/uds_client.dart';

/// ตัวจำลองที่จดทุกคำสั่งที่ถึงตัวสแกนจริง (ใช้ตรวจว่าคำสั่งต้องห้ามไม่หลุดออกไป)
class _Recording implements ObdTransport {
  _Recording(this.inner);

  final DemoTransport inner;
  final sent = <String>[];
  final _buf = StringBuffer();

  @override
  TransportKind get kind => inner.kind;

  @override
  String get displayName => inner.displayName;

  @override
  Stream<List<int>> get incoming => inner.incoming;

  @override
  bool get isConnected => inner.isConnected;

  @override
  Future<void> connect() => inner.connect();

  @override
  Future<void> disconnect() => inner.disconnect();

  @override
  Future<void> write(List<int> bytes) {
    _buf.write(String.fromCharCodes(bytes));
    var text = _buf.toString();
    var i = text.indexOf('\r');
    while (i >= 0) {
      sent.add(text.substring(0, i).trim().toUpperCase());
      text = text.substring(i + 1);
      i = text.indexOf('\r');
    }
    _buf
      ..clear()
      ..write(text);
    return inner.write(bytes);
  }
}

ExtPid _pidFromDmax(String request) {
  final pack = ExtPidPack.fromJson(
      jsonDecode(File('assets/ext_packs/isuzu_dmax_2007.json').readAsStringSync()) as Map<String, dynamic>);
  return pack.pids.firstWhere((p) => p.request.toUpperCase() == request);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ตัวตรวจคำสั่ง', () {
    test('คำสั่งอ่านค่าผ่าน', () {
      for (final c in [
        '0100', '010C0D', '01 0c', '03', '07', '0A', '0902', '0600', '020C00', //
        '2101', '221130', '22F190F18C', '1902FF', '1802FF00', '1A90', '1301', '3E00', '1001', '1081',
      ]) {
        expect(checkCommand(c).kind, CommandKind.read, reason: c);
      }
    });

    test('คำสั่งตั้งค่าตัวสแกนที่แอปใช้ผ่าน (ไม่ได้ส่งถึงกล่องในรถ)', () {
      for (final c in [
        'ATZ', 'ATE0', 'ATH1', 'ATSP0', 'ATSH7E0', 'ATCRA7E8', 'ATCRA', 'ATFCSH7E0', 'ATFCSD300000', //
        'ATFCSM1', 'ATST32', 'ATCP18', 'ATRV', 'ATI', 'AT@1', 'STI', 'ATCAF1',
      ]) {
        expect(checkCommand(c).kind, CommandKind.adapter, reason: c);
      }
    });

    test('ลบรหัสปัญหา = ต้องผ่านปุ่มลบรหัส', () {
      for (final c in ['04', '14FFFFFF', '14FF00']) {
        expect(checkCommand(c).kind, CommandKind.clear, reason: c);
        expect(checkCommand(c).sendable, false, reason: c);
      }
    });

    test('คำสั่งที่เปลี่ยนแปลงกล่องหรือสั่งรถทำงานถูกปิด พร้อมเหตุผลภาษาไทย', () {
      const cases = {
        '1101': 'รีเซ็ต',
        '1002': 'โหมดพิเศษ',
        '1003': 'โหมดพิเศษ',
        '2701': 'ปลดล็อก',
        '2EF19041': 'เขียน',
        '3B9A01': 'เขียน',
        '2F0C0103': 'อุปกรณ์',
        '31010203': 'โปรแกรมพิเศษ',
        '3400': 'แฟลช',
        '2803': 'ปิดการสื่อสาร',
        '8502': 'ปิดการบันทึก',
        '0800': 'ทำงาน',
        '23': 'หน่วยความจำ',
        'C1': 'ไม่รู้จัก',
      };
      for (final e in cases.entries) {
        final r = checkCommand(e.key);
        expect(r.kind, CommandKind.blocked, reason: e.key);
        expect(r.reason, contains(e.value), reason: e.key);
      }
    });

    test('คำสั่งตัวสแกนที่ส่งข้อความเองถึงรถ หรือทำให้ตรวจคำสั่งไม่ได้ ถูกปิด', () {
      for (final c in ['ATWM8110F13E', 'STPX H:7E0, D:1101', 'ATFCSD021101', 'ATCAF0', 'at caf 0', '', '   ', 'XYZ', 'GG00']) {
        expect(checkCommand(c).kind, CommandKind.blocked, reason: '"$c"');
      }
    });

    test('หน้าเทอร์มินัล: พิมพ์ได้เฉพาะคำสั่งอ่านค่าและคำสั่งดูข้อมูลตัวสแกน', () {
      expect(terminalRefusal('010C'), isNull);
      expect(terminalRefusal('atrv'), isNull);
      expect(terminalRefusal('0902'), isNull);
      expect(terminalRefusal('ATSH7E0'), contains('การตั้งค่าตัวสแกน'));
      expect(terminalRefusal('ATMA'), isNotNull);
      expect(terminalRefusal('ATWM8110F13E'), isNotNull);
      expect(terminalRefusal('04'), contains('ปุ่ม'));
      expect(terminalRefusal('14FFFFFF'), contains('ปุ่ม'));
      expect(terminalRefusal('1101'), allOf(contains('รีเซ็ต'), contains('เฉพาะคำสั่งอ่านค่า')));
    });
  });

  group('ด่านใน ELM327 (ทุกคำสั่งผ่านจุดเดียว)', () {
    late _Recording t;
    late Elm327 elm;
    late ObdService svc;
    final log = <String>[];

    setUp(() async {
      t = _Recording(DemoTransport(responseDelay: const Duration(milliseconds: 1)));
      await t.connect();
      elm = Elm327(t)
        ..attach()
        ..onLog = log.add;
      await elm.initialize();
      svc = ObdService(elm);
      await svc.loadSupportedPids();
    });

    tearDown(() async {
      await elm.detach();
      await t.disconnect();
      log.clear();
    });

    test('คำสั่งต้องห้ามไม่ถึงตัวสแกนเลย และแอปยังอ่านค่าต่อได้', () async {
      for (final c in ['1101', '2EF19041', '3101FF00', '1003', 'ATWM8110F13E', 'STPX']) {
        await expectLater(elm.send(c), throwsA(isA<BlockedCommandException>()), reason: c);
      }
      expect(
        t.sent.where((s) => ['11', '2E', '31', '1003', 'ATWM', 'STPX'].any(s.startsWith)),
        isEmpty,
      );
      expect(log.where((l) => l.startsWith('(ไม่ส่ง 1101')), isNotEmpty);
      expect(await svc.readPid(Pid.rpm), isNotNull);
    });

    test('ข้อผิดพลาดเป็นชนิดเดียวกับข้อผิดพลาดของตัวสแกน (โค้ดเดิมจัดการได้)', () async {
      await expectLater(elm.query('2F0C0103'), throwsA(isA<ElmException>()));
    });

    test('ส่งลบรหัสตรงๆ ไม่ได้ ต้องผ่านปุ่มลบรหัส', () async {
      await expectLater(elm.send('04'), throwsA(isA<BlockedCommandException>()));
      await expectLater(elm.query('14FFFFFF'), throwsA(isA<BlockedCommandException>()));
      expect(t.sent.where((s) => s == '04' || s.startsWith('14')), isEmpty);
      expect(await svc.clearDtcs(), true);
      expect(t.sent, contains('04'));
      // สิทธิ์ลบรหัสไม่ติดไปกับคำสั่งถัดไป
      await expectLater(elm.send('04'), throwsA(isA<BlockedCommandException>()));
    });

    test('อนุญาตลบรหัสแล้ว คำสั่งต้องห้ามอื่นก็ยังส่งไม่ได้', () async {
      await expectLater(elm.allowClearing(() => elm.send('1101')), throwsA(isA<BlockedCommandException>()));
      expect(t.sent.where((s) => s.startsWith('11')), isEmpty);
    });

    test('ลบรหัสกล่อง ABS ผ่าน UDS ยังใช้ได้', () async {
      final uds = UdsClient(elm);
      final abs = (await uds.discover()).firstWhere((m) => m.tx == '7B0');
      expect(await uds.clearDtcs(abs), true);
      expect(t.sent, contains('14FFFFFF'));
      await expectLater(elm.send('14FFFFFF'), throwsA(isA<BlockedCommandException>()));
    });

    test('ชุดที่เก็บไว้มีคำสั่งต้องห้าม: ชุดไม่ถูกลบ แต่ค่านั้นไม่ถูกส่ง', () async {
      final pack = ExtPidPack(id: 'p', name: 'ชุดเก่า', pids: [
        ExtPid(name: 'รอบเครื่อง', request: '010C', formula: '(A*256+B)/4'),
        ExtPid(name: 'รีเซ็ตกล่อง', request: '1101', formula: 'A'),
        ExtPid(name: 'สั่งหัวฉีด', request: '2F0C0103', formula: 'A'),
      ]);
      final stored = ExtPidPack.fromJson(jsonDecode(jsonEncode(pack.toJson())) as Map<String, dynamic>);
      expect(stored.pids, hasLength(3), reason: 'เก็บครบ ไม่ลบให้');
      final r = await ExtPidReader(elm).readAll(stored.pids);
      expect(r[stored.pids[0].key]!.value, isNotNull);
      for (final p in stored.pids.skip(1)) {
        expect(r[p.key]!.skipped, true);
        expect(r[p.key]!.error, contains('ไม่ส่งเพื่อความปลอดภัย'));
      }
      expect(t.sent.where((s) => s.startsWith('11') || s.startsWith('2F')), isEmpty);
      final probe = await ExtPidReader(elm).probe(stored.pids);
      expect(probe.incompatible, 2);
      expect((await ExtPidReader(elm).readRaw(stored.pids[1])).status, ExtCmdStatus.skipped);
    });
  });

  group('ชุดค่า', () {
    test('นำเข้า JSON: ข้ามคำสั่งต้องห้าม และบอกชื่อกับเหตุผล', () {
      final json = jsonEncode({
        'proscaner_pack': 1,
        'name': 'ทดสอบ',
        'pids': [
          {'name': 'บูสต์ที่ต้องการ', 'req': '221130', 'f': 'A', 'unit': 'kPa'},
          {'name': 'รีเซ็ตกล่อง', 'req': '1101', 'f': 'A'},
          {'name': 'เขียน VIN', 'req': '2EF190', 'f': 'A'},
          {'name': 'ผิดรูปแบบ', 'req': 'ZZ', 'f': 'A'},
        ],
      });
      final r = importPackDetailed(json);
      expect(r.pack.pids.map((p) => p.request), ['221130']);
      expect(r.skipped, 1);
      expect(r.blocked.map((b) => b.request), ['1101', '2EF190']);
      expect(r.blocked.first.reason, contains('รีเซ็ต'));
      expect(r.blocked.first.label, contains('รีเซ็ตกล่อง (1101)'));
      // ฟังก์ชันเดิมยังนับรวมบรรทัดที่ข้าม
      expect(importPack(json).$2, 3);
    });

    test('นำเข้า CSV แบบ Torque: บอกเลขบรรทัดที่ข้าม', () {
      const csv = 'Name,ShortName,ModeAndPID,Equation,Min Value,Max Value,Units,Header\n'
          'Boost,BST,0x221130,A,0,300,kPa,7E0\n'
          'ECU Reset,RST,0x1101,A,0,1,,7E0\n'
          'Injector test,INJ,0x2F0C0103,A,0,1,,7E0\n';
      final r = importPackDetailed(csv);
      expect(r.pack.pids, hasLength(1));
      expect(r.blocked.map((b) => b.line), [3, 4]);
      expect(r.blocked.last.reason, contains('อุปกรณ์'));
      expect(r.blocked.first.label, startsWith('บรรทัด 3: ECU Reset (1101)'));
    });

    test('หน้าแก้ไขค่า: บันทึกคำสั่งต้องห้ามไม่ได้', () {
      expect(ExtPid(name: 'x', request: '3101FF00', formula: 'A').validate(), contains('ความปลอดภัย'));
      expect(ExtPid(name: 'x', request: '0400', formula: 'A').validate(), contains('ลบรหัส'));
      expect(ExtPid(name: 'x', request: '221130', formula: 'A').validate(), isNull);
    });

    test('ทดสอบรีแมพไม่เลือกค่าที่ใช้คำสั่งต้องห้ามมาอ่านระหว่างขับ', () {
      final ok = _pidFromDmax('221130');
      expect(classifyRemapExt(ok), isNotNull);
      final bad = ExtPid.fromJson({...ok.toJson(), 'req': '2F1130'});
      expect(bad.name, ok.name);
      expect(classifyRemapExt(bad), isNull);
    });

    test('ชุดค่าที่มากับแอปทุกชุดเป็นคำสั่งอ่านค่าทั้งหมด', () {
      var count = 0;
      for (final f in Directory('assets/ext_packs').listSync().whereType<File>()) {
        if (!f.path.endsWith('.json') || f.path.endsWith('index.json')) continue;
        final pack = ExtPidPack.fromJson(jsonDecode(f.readAsStringSync()) as Map<String, dynamic>);
        for (final p in pack.pids) {
          expect(p.safetyBlock, isNull, reason: '${f.path} ${p.name} ${p.request}');
          count++;
        }
      }
      expect(count, greaterThan(1000));
    });
  });
}
