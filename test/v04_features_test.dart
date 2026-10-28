import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obd_doctor/core/diagnosis/diagnosis.dart';
import 'package:obd_doctor/core/elm/elm327.dart';
import 'package:obd_doctor/core/obd/dtc_database.dart';
import 'package:obd_doctor/core/obd/ext_pid.dart';
import 'package:obd_doctor/core/obd/formula.dart';
import 'package:obd_doctor/core/obd/obd_service.dart';
import 'package:obd_doctor/core/obd/pids.dart';
import 'package:obd_doctor/core/transport/demo_transport.dart';
import 'package:obd_doctor/core/voice/voice_service.dart';
import 'package:obd_doctor/data/garage_store.dart';
import 'package:obd_doctor/data/history_store.dart';
import 'package:obd_doctor/data/log_store.dart';
import 'package:obd_doctor/state/ext_packs.dart';
import 'package:obd_doctor/state/live_poller.dart';
import 'package:obd_doctor/state/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemoryHistory extends HistoryStore {
  @override
  Future<List<VehicleSnapshot>> load() async => [];

  @override
  Future<void> add(VehicleSnapshot s) async {}

  @override
  Future<void> clear() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('สูตรแปลงค่า', () {
    test('ตัวดำเนินการพื้นฐานและลำดับ', () {
      expect(Formula('A-40').eval([120]), 80);
      expect(Formula('(A*256+B)/4').eval([0x1A, 0xF8]), 1726);
      expect(Formula('A+B*2').eval([1, 3]), 7);
      expect(Formula('-A/2').eval([10]), -5);
      expect(Formula('A%16').eval([0x35]), 5);
      expect(Formula('0x10+A').eval([1]), 17);
      expect(Formula('A*0.5').eval([9]), 4.5);
    });

    test('ฟังก์ชัน S, S16, U16, บิต, min/max/abs', () {
      expect(Formula('S(A)').eval([0xFF]), -1);
      expect(Formula('Signed(A)').eval([0x7F]), 127);
      expect(Formula('S16(A,B)/100').eval([0xFF, 0x9C]), -1);
      expect(Formula('U16(A,B)').eval([0xFF, 0x9C]), 65436);
      expect(Formula('{A:3}').eval([0x08]), 1);
      expect(Formula('{B:0}').eval([0, 0x02]), 0);
      expect(Formula('max(A,B)-min(A,B)').eval([3, 10]), 7);
      expect(Formula('abs(S(A))').eval([0xF6]), 10);
      expect(Formula('AA').bytesNeeded, 27);
      expect(Formula('C+1').bytesNeeded, 3);
    });

    test('สูตรผิดและข้อมูลไม่พอ', () {
      for (final bad in ['', 'A+', '(A', r'A$', 'foo(A)', '{A:9}', 'A B']) {
        expect(Formula.isValid(bad), false, reason: bad);
      }
      expect(() => Formula('A+B').eval([1]), throwsRangeError);
      expect(() => Formula('A/B').eval([1, 0]), throwsFormatException);
    });
  });

  group('ค่าเฉพาะยี่ห้อ: แบบข้อมูลและการนำเข้า', () {
    test('ตรวจความถูกต้อง และที่อยู่ตอบกลับ', () {
      final p = ExtPid(name: 'x', request: '221101', formula: 'A', header: '7E0');
      expect(p.validate(), isNull);
      expect(p.responseHeader, '7E8');
      expect(p.idBytes, [0x11, 0x01]);
      expect(ExtPid(name: 'x', request: '2101', formula: 'A', header: '18DA10F1').responseHeader, '18DAF110');
      expect(ExtPid(name: '', request: '2101', formula: 'A').validate(), isNotNull);
      expect(ExtPid(name: 'x', request: '21', formula: 'A').validate(), isNotNull);
      expect(ExtPid(name: 'x', request: '2101', formula: 'A+').validate(), isNotNull);
      expect(ExtPid(name: 'x', request: '2101', formula: 'A', header: '7E').validate(), isNotNull);
    });

    test('นำเข้า CSV แบบ Torque', () {
      const csv = 'Name,ShortName,ModeAndPID,Equation,Min Value,Max Value,Units,Header\n'
          'ATF Temp,ATF,0x2101,A-40,-40,150,°C,7E1\n'
          '"Inj, Cyl 1",IC1,221101,"S16(A,B)/100",-5,5,mm3,DA10F1\n'
          'broken line\n'
          'Bad,B,zz,A,0,1,x,7E0\n';
      final (pack, skipped) = importPack(csv, fallbackName: 'ทดสอบ');
      expect(pack.name, 'ทดสอบ');
      expect(pack.pids.length, 2);
      expect(skipped, 2);
      expect(pack.pids[0].request, '2101');
      expect(pack.pids[0].header, '7E1');
      expect(pack.pids[0].max, 150);
      expect(pack.pids[1].name, 'Inj, Cyl 1');
      expect(pack.pids[1].header, '18DA10F1');
      expect(pack.verified, false);
    });

    test('ส่งออกแล้วนำเข้ากลับได้เหมือนเดิม', () {
      final src = demoPack();
      final (back, skipped) = importPack(src.export());
      expect(skipped, 0);
      expect(back.name, src.name);
      expect(back.pids.map((p) => p.toJson()).toList(), src.pids.map((p) => p.toJson()).toList());
      expect(back.id, isNot(src.id));
    });

    test('แยกคำตอบ: ตรงเลข / ปฏิเสธ / เลขไม่ตรง', () {
      final p = ExtPid(name: 'x', request: '221201', formula: 'A-40', header: '7E1');
      expect(ExtPidReader.decode(p, [
        [0x62, 0x12, 0x01, 0x80]
      ]).value, 88);
      expect(ExtPidReader.decode(p, [
        [0x62, 0x12, 0x02, 0x80]
      ]).error, isNotNull);
      expect(ExtPidReader.decode(p, [
        [0x7F, 0x22, 0x78],
        [0x7F, 0x22, 0x31]
      ]).error, 'รถไม่รองรับค่านี้');
      expect(ExtPidReader.decode(ExtPid(name: 'x', request: '2101', formula: 'A+B', header: '7E0'), [
        [0x61, 0x01, 0x05]
      ]).error, contains('ไม่ตรงกับสูตร'));
    });

    test('เก็บชุดค่าในเครื่อง', () async {
      // ignore: invalid_use_of_visible_for_testing_member
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      var c = ProviderContainer(overrides: [sharedPrefsProvider.overrideWithValue(prefs)]);
      c.read(extPacksProvider.notifier).put(demoPack());
      final p = c.read(extPacksProvider).single;
      p.pids.removeLast();
      c.read(extPacksProvider.notifier).put(p);
      c.dispose();
      c = ProviderContainer(overrides: [sharedPrefsProvider.overrideWithValue(prefs)]);
      expect(c.read(extPacksProvider).single.pids.length, demoPack().pids.length - 1);
      c.read(extPacksProvider.notifier).remove('demo_pack');
      expect(c.read(extPacksProvider), isEmpty);
      c.dispose();
    });
  });

  group('ค่าเฉพาะยี่ห้อ: อ่านจากรถจำลอง', () {
    late DemoTransport t;
    late Elm327 elm;

    setUp(() async {
      t = DemoTransport(responseDelay: const Duration(milliseconds: 1));
      await t.connect();
      elm = Elm327(t)..attach();
      await elm.initialize();
    });

    tearDown(() async {
      await elm.detach();
      await t.disconnect();
    });

    test('อ่านชุดตัวอย่างครบ และ header กลับเป็นปกติ', () async {
      final pack = demoPack();
      final r = await ExtPidReader(elm).readAll(pack.pids);
      double v(String name) => r[pack.pids.firstWhere((p) => p.name == name).key]!.value!;
      expect(v('ชดเชยหัวฉีดสูบ 3'), closeTo(2.85, 0.1));
      expect(v('ชดเชยหัวฉีดสูบ 2'), closeTo(-0.31, 0.1));
      expect(v('เขม่าสะสมใน DPF'), closeTo(18.4, 1));
      expect(v('ระยะทางจากการเผา DPF ครั้งล่าสุด'), 412);
      expect(v('อุณหภูมิน้ำมันเกียร์'), inInclusiveRange(70, 90));
      // หลังอ่านกล่องเฉพาะ ต้องอ่าน OBD มาตรฐานได้ตามเดิม
      final svc = ObdService(elm);
      await svc.loadSupportedPids();
      expect(await svc.readPid(Pid.rpm), isNotNull);
    });

    test('ค่าที่รถไม่มี ได้ข้อความชัดเจน ไม่ล้ม', () async {
      final r = await ExtPidReader(elm).readAll([
        ExtPid(name: 'none', request: '229999', formula: 'A', header: '7E0'),
        ExtPid(name: 'nobox', request: '221101', formula: 'A', header: '7A0'),
      ]);
      expect(r.values.map((e) => e.error), everyElement(isNotNull));
    });

    test('ค้นหาเลขที่กล่องตอบ (21 และ 22)', () async {
      final kwp = await ExtPidReader(elm).scan(header: '7E0', service: 0x21, start: 0, end: 0x0F);
      expect(kwp.map((h) => h.request), ['2101', '2102']);
      expect(kwp.first.data, [0x5A, 0x1F, 0x40, 0x7B]);
      final uds = await ExtPidReader(elm).scan(header: '7E0', service: 0x22, start: 0x1100, end: 0x1112);
      expect(uds.map((h) => h.request), ['221101', '221102', '221103', '221104', '221110', '221111']);
    });
  });

  group('เสียงพูดเตือน', () {
    late ProviderContainer c;
    late SilentVoiceService voice;

    Future<ProviderContainer> make({required bool voiceOn}) async {
      // ignore: invalid_use_of_visible_for_testing_member
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final db = DtcDatabase.fromJsonString(File('assets/dtc_th.json').readAsStringSync());
      voice = SilentVoiceService();
      c = ProviderContainer(overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        historyStoreProvider.overrideWithValue(_MemoryHistory()),
        garageStoreProvider.overrideWithValue(MemoryGarageStore()),
        logStoreProvider.overrideWithValue(MemoryLogStore()),
        dtcDatabaseProvider.overrideWith((ref) async => db),
        voiceServiceProvider.overrideWithValue(voice),
      ]);
      // ตั้งเกณฑ์ความร้อนต่ำมาก ให้เตือนทันที
      c.read(settingsProvider.notifier).setAlerts(const AlertLimits().copyWith(coolantMax: 1, voice: voiceOn));
      await c.read(sessionProvider.notifier).connect(DemoTransport(responseDelay: const Duration(milliseconds: 1)));
      return c;
    }

    tearDown(() async {
      c.read(livePollerProvider).unsubscribe('t');
      await c.read(sessionProvider.notifier).disconnect();
      c.dispose();
    });

    test('พูดภาษาไทยเมื่อค่าเกินเกณฑ์', () async {
      await make(voiceOn: true);
      c.read(livePollerProvider).subscribe('t', [Pid.coolantTemp]);
      for (var i = 0; i < 60 && voice.spoken.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(voice.spoken, isNotEmpty);
      expect(voice.spoken.first, startsWith('ระวัง ความร้อนเครื่องสูง'));
      expect(voice.spoken.first, contains('องศา'));
      expect(c.read(liveDataProvider).alert, contains('ความร้อนเครื่องสูง'));
      // ไม่พูดซ้ำถี่ ๆ (เว้น 20 วินาทีต่อเรื่อง)
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(voice.spoken.length, 1);
    });

    test('ปิดเสียงแล้ว ยังเตือนบนจอแต่ไม่พูด', () async {
      await make(voiceOn: false);
      c.read(livePollerProvider).subscribe('t', [Pid.coolantTemp]);
      for (var i = 0; i < 60 && c.read(liveDataProvider).alert == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(c.read(liveDataProvider).alert, isNotNull);
      expect(voice.spoken, isEmpty);
    });

    test('บันทึกการตั้งค่าเสียง', () async {
      await make(voiceOn: false);
      final prefs = c.read(sharedPrefsProvider);
      expect(prefs.getBool('al_voice'), false);
    });
  });
}
