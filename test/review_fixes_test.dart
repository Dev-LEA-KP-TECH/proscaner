// เทสต์สำหรับบัคที่พบจากการตรวจโค้ด (ต.ค. 2569)
// - อ่านไม่สำเร็จต้องไม่กลายเป็น "ไม่พบปัญหา"
// - ไฟเตือน/readiness ต้องมาจากกล่องเครื่องยนต์ (และไฟเตือนติดถ้ากล่องใดสั่งติด)
// - คำสั่งที่ถูกขัดจังหวะ (STOPPED) ส่งซ้ำ
// - ยกเลิกการเชื่อมต่อได้จริง และงานเก่าไม่ทับการเชื่อมต่อใหม่
// - โหมดทดลองไม่บันทึกรถ/ผลสแกนลงเครื่อง
// - ไฟล์โรงรถ/ประวัติเสียแล้วไม่ทำให้ข้อมูลหาย
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obd_doctor/core/diagnosis/diagnosis.dart';
import 'package:obd_doctor/core/elm/elm327.dart';
import 'package:obd_doctor/core/obd/dtc.dart';
import 'package:obd_doctor/core/obd/dtc_database.dart';
import 'package:obd_doctor/core/obd/obd_service.dart';
import 'package:obd_doctor/core/obd/pids.dart';
import 'package:obd_doctor/core/transport/demo_transport.dart';
import 'package:obd_doctor/core/transport/obd_transport.dart';
import 'package:obd_doctor/data/demo_cleanup.dart';
import 'package:obd_doctor/data/garage_store.dart';
import 'package:obd_doctor/data/history_store.dart';
import 'package:obd_doctor/data/log_store.dart';
import 'package:obd_doctor/state/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// ตัวสแกนเขียนบทเอง: ตอบตาม [reply] (null = ไม่ตอบ), คำสั่งใน [failOn] = ส่งไม่ได้ (สายหลุด)
class _Scripted implements ObdTransport {
  _Scripted(this.reply, {this.failOn = const {}});

  final String? Function(String cmd) reply;
  final Set<String> failOn;
  final sent = <String>[];
  final _c = StreamController<List<int>>.broadcast();

  @override
  TransportKind get kind => TransportKind.wifi;

  @override
  String get displayName => 'scripted';

  @override
  Stream<List<int>> get incoming => _c.stream;

  @override
  bool get isConnected => true;

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> write(List<int> bytes) async {
    final cmd = String.fromCharCodes(bytes).trim();
    if (failOn.contains(cmd)) throw TransportException('สายหลุด');
    sent.add(cmd);
    final r = reply(cmd);
    if (r == null) return;
    scheduleMicrotask(() => _c.add('$r\r\r>'.codeUnits));
  }
}

/// ตัวสแกนที่การเชื่อมต่อค้าง จนกว่าจะปล่อย [gate]
class _Gate implements ObdTransport {
  final gate = Completer<void>();
  bool disconnected = false;
  final _c = StreamController<List<int>>.broadcast();

  @override
  TransportKind get kind => TransportKind.wifi;

  @override
  String get displayName => 'gate';

  @override
  Stream<List<int>> get incoming => _c.stream;

  @override
  bool get isConnected => !disconnected;

  @override
  Future<void> connect() => gate.future;

  @override
  Future<void> write(List<int> bytes) async {}

  @override
  Future<void> disconnect() async => disconnected = true;
}

const _pid00Ok = '7E8 06 41 00 BE 3F A8 13 00';

/// ตัวสแกน CAN ทั่วไป: ตอบคำสั่ง AT และ PID 00, คำสั่งอื่นใช้ [extra] ก่อน ไม่งั้น NO DATA
String? Function(String) _adapter({String? Function(String cmd)? extra}) {
  var proto = '0';
  return (cmd) {
    final e = extra?.call(cmd);
    if (e != null) return e;
    if (cmd == 'ATZ' || cmd == 'ATI') return 'ELM327 v1.5';
    if (cmd == 'STI') return '?';
    if (cmd == 'AT@1') return 'OBDII to RS232 Interpreter';
    if (cmd.startsWith('ATSP')) {
      proto = cmd.substring(4);
      return 'OK';
    }
    if (cmd == 'ATDPN') return proto == '0' ? 'A6' : proto;
    if (cmd == 'ATDP') return 'ISO 15765-4 (CAN 11/500)';
    if (cmd.startsWith('AT')) return 'OK';
    if (cmd == '0100') return _pid00Ok;
    return 'NO DATA';
  };
}

Future<Elm327> _elm(_Scripted t) async {
  final elm = Elm327(t)..attach();
  await elm.initialize();
  return elm;
}

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

  group('อ่านค่าจากรถ', () {
    test('NO DATA = ไม่มีรหัส แต่ CAN ERROR = อ่านไม่สำเร็จ (ต้องโยน error)', () async {
      final elm = await _elm(_Scripted(_adapter(extra: (cmd) => switch (cmd) {
            '03' => 'CAN ERROR',
            '07' => 'NO DATA',
            _ => null,
          })));
      final svc = ObdService(elm);
      expect(await svc.readDtcs(DtcKind.pending), isEmpty);
      await expectLater(svc.readDtcs(DtcKind.stored), throwsA(isA<ElmException>()));
    });

    test('กล่องเกียร์ตอบก่อน: ไฟเตือนและ readiness ใช้ของกล่องเครื่องยนต์', () async {
      final elm = await _elm(_Scripted(_adapter(extra: (cmd) => switch (cmd) {
            '0101' => '7E9 06 41 01 00 07 E1 00\r7E8 06 41 01 82 07 65 00',
            _ => null,
          })));
      final svc = ObdService(elm);
      final m = (await svc.readMonitorStatus())!;
      expect(m.milOn, true);
      expect(m.dtcCount, 2);
      final r = await svc.readReadiness();
      expect(r.map((x) => (x.nameTh, x.complete)), decodeReadiness(const [0x82, 0x07, 0x65, 0x00]).map((x) => (x.nameTh, x.complete)));
    });

    test('กล่องเกียร์สั่งไฟเตือนติด แม้กล่องเครื่องยนต์ไม่ติด = ไฟเตือนติด', () async {
      final elm = await _elm(_Scripted(_adapter(extra: (cmd) => switch (cmd) {
            '0101' => '7E8 06 41 01 00 07 65 00\r7E9 06 41 01 80 00 00 00',
            _ => null,
          })));
      final m = (await ObdService(elm).readMonitorStatus())!;
      expect(m.milOn, true);
      expect(m.dtcCount, 0);
    });

    test('คำสั่งถูกขัดจังหวะ (STOPPED) → ส่งซ้ำแล้วได้ค่าจริง', () async {
      var first = true;
      final t = _Scripted(_adapter(extra: (cmd) {
        if (cmd != '0105') return null;
        if (first) {
          first = false;
          return 'STOPPED';
        }
        return '7E8 03 41 05 7B';
      }));
      final elm = await _elm(t);
      expect(await ObdService(elm).readPid(Pid.coolantTemp), 83);
      expect(t.sent.where((c) => c == '0105').length, 2);
    });
  });

  group('การเชื่อมต่อและการสแกนผ่าน provider', () {
    late ProviderContainer c;
    late MemoryGarageStore garage;
    late _MemoryHistory history;

    setUp(() async {
      // ignore: invalid_use_of_visible_for_testing_member
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final db = DtcDatabase.fromJsonString(File('assets/dtc_th.json').readAsStringSync());
      garage = MemoryGarageStore();
      history = _MemoryHistory();
      c = ProviderContainer(overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        historyStoreProvider.overrideWithValue(history),
        garageStoreProvider.overrideWithValue(garage),
        logStoreProvider.overrideWithValue(MemoryLogStore()),
        dtcDatabaseProvider.overrideWith((ref) async => db),
      ]);
    });

    tearDown(() async {
      await c.read(sessionProvider.notifier).disconnect();
      c.dispose();
    });

    test('รถหยุดตอบ (ดับเครื่อง/รถหลับ): แจ้ง error ไม่สร้างรายงาน "ปกติ"', () async {
      await c.read(sessionProvider.notifier).connect(_Scripted(_adapter()));
      expect(c.read(sessionProvider).isConnected, true);
      expect(await c.read(scanProvider.notifier).run(), false);
      final s = c.read(scanProvider);
      expect(s.report, isNull);
      expect(s.error, contains('กล่องเครื่องยนต์ไม่ตอบ'));
      expect(history.items, isEmpty);
    });

    test('อ่านรหัสไม่สำเร็จ (CAN ERROR): แจ้ง error ไม่สรุปว่าไม่มีรหัส', () async {
      await c.read(sessionProvider.notifier).connect(_Scripted(_adapter(extra: (cmd) => switch (cmd) {
            '0101' => '7E8 06 41 01 00 07 65 00',
            '03' => 'CAN ERROR',
            _ => null,
          })));
      expect(await c.read(scanProvider.notifier).run(), false);
      final s = c.read(scanProvider);
      expect(s.report, isNull);
      expect(s.error, contains('อ่านรหัสปัญหา'));
    });

    test('ลบรหัสแล้วสายหลุด: แจ้งผลให้ผู้ใช้รู้ ไม่เงียบ', () async {
      await c.read(sessionProvider.notifier).connect(_Scripted(
            _adapter(extra: (cmd) => cmd == '010D' ? '7E8 03 41 0D 00' : null),
            failOn: {'04'},
          ));
      final msg = await c.read(scanProvider.notifier).clearCodes();
      expect(msg, contains('ลบรหัสไม่สำเร็จ'));
    });

    test('ยกเลิกระหว่างเชื่อมต่อ แล้วเชื่อมต่อใหม่: งานเก่าที่จบทีหลังไม่ทับของใหม่', () async {
      final s = c.read(sessionProvider.notifier);
      final slow = _Gate();
      final first = s.connect(slow);
      await Future<void>.delayed(Duration.zero);
      expect(c.read(sessionProvider).status, ConnStatus.connecting);

      await s.disconnect(); // ผู้ใช้กดยกเลิก
      expect(c.read(sessionProvider).status, ConnStatus.disconnected);
      expect(slow.disconnected, true);

      await s.connect(DemoTransport(responseDelay: const Duration(milliseconds: 1)));
      expect(c.read(sessionProvider).isConnected, true);

      slow.gate.complete(); // การเชื่อมต่อเก่าเพิ่งตอบกลับมา
      await first;
      final st = c.read(sessionProvider);
      expect(st.isConnected, true);
      expect(st.transport, isA<DemoTransport>());
    });

    test('ยกเลิกแล้วการเชื่อมต่อเก่าล้มทีหลัง: ไม่ขึ้น "ล้มเหลว" ทับของใหม่', () async {
      final s = c.read(sessionProvider.notifier);
      final slow = _Gate();
      final first = s.connect(slow);
      await Future<void>.delayed(Duration.zero);
      await s.disconnect();
      await s.connect(DemoTransport(responseDelay: const Duration(milliseconds: 1)));
      slow.gate.completeError(TransportException('หมดเวลา'));
      await first;
      expect(c.read(sessionProvider).isConnected, true);
    });

    test('โหมดทดลอง: แสดงรถจำลองได้ แต่ไม่บันทึกรถและผลสแกนลงเครื่อง', () async {
      final s = c.read(sessionProvider.notifier);
      await s.connect(DemoTransport(responseDelay: const Duration(milliseconds: 1), practice: true));
      final st = c.read(sessionProvider);
      expect(st.isPractice, true);
      expect(st.vehicleId, DemoTransport.defaultVin);
      expect(c.read(garageProvider).value!.map((v) => v.vin), [DemoTransport.defaultVin]);

      expect(await c.read(scanProvider.notifier).run(), true);
      expect(c.read(scanProvider).report, isNotNull);
      expect(history.items, isEmpty);
      expect(await garage.load(), isEmpty);

      await s.disconnect();
      expect(c.read(garageProvider).value, isEmpty);
    });

    test('รถจริง (ไม่ใช่โหมดทดลอง) ยังบันทึกตามปกติ', () async {
      await c.read(sessionProvider.notifier).connect(DemoTransport(responseDelay: const Duration(milliseconds: 1)));
      expect(c.read(sessionProvider).isPractice, false);
      expect(await c.read(scanProvider.notifier).run(), true);
      expect(history.items, hasLength(1));
      expect((await garage.load()).single.vin, DemoTransport.defaultVin);
    });
  });

  group('ไฟล์โรงรถ/ประวัติ ไม่หายเมื่อไฟล์เสีย', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('proscaner_test_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('ไฟล์โรงรถเสีย: เก็บไฟล์เสียไว้ และกู้จาก .bak แทนการคืนรายการว่าง', () async {
      final g = GarageStore(directory: dir);
      await g.save([Vehicle(id: 'a', plate: 'กข 1')]);
      await g.save([Vehicle(id: 'a', plate: 'กข 1'), Vehicle(id: 'b', plate: 'กข 2')]);
      File('${dir.path}/garage.json').writeAsStringSync('{เสีย');

      final loaded = await GarageStore(directory: dir).load();
      expect(loaded.map((v) => v.id), ['a']);
      expect(dir.listSync().any((f) => f.path.contains('garage.json.bad-')), true);
      // ไฟล์หลักถูกกู้กลับแล้ว
      expect((await GarageStore(directory: dir).load()).map((v) => v.id), ['a']);
    });

    test('รถคันเดียวข้อมูลเสีย คันอื่นยังอยู่', () async {
      File('${dir.path}/garage.json').writeAsStringSync(jsonEncode([
        Vehicle(id: 'ok').toJson(),
        {'id': 5},
      ]));
      expect((await GarageStore(directory: dir).load()).map((v) => v.id), ['ok']);
    });

    test('บันทึกพร้อมกันหลายครั้ง: ไฟล์ไม่เสีย และได้ค่าล่าสุด', () async {
      final g = GarageStore(directory: dir);
      await Future.wait([
        for (var i = 1; i <= 20; i++) g.save([for (var k = 0; k < i; k++) Vehicle(id: 'v$k')]),
      ]);
      expect((await GarageStore(directory: dir).load()).length, 20);
    });

    test('ประวัติเสีย: กู้จาก .bak และล้างประวัติแล้วไม่ถูกกู้กลับมา', () async {
      VehicleSnapshot snap(String vin) => VehicleSnapshot(time: DateTime(2026), dtcs: const [], pids: const {}, vin: vin);
      final h = HistoryStore(directory: dir);
      await h.add(snap('A'));
      await h.add(snap('B'));
      File('${dir.path}/scan_history.json').writeAsStringSync('xx');
      expect((await HistoryStore(directory: dir).load()).map((s) => s.vin), ['A']);

      await h.clear();
      expect(await HistoryStore(directory: dir).load(), isEmpty);
    });

    test('ล้างรถจำลองจากแอปรุ่นก่อนครั้งเดียว ไม่แตะรถที่ผู้ใช้แก้ไข', () async {
      // ignore: invalid_use_of_visible_for_testing_member
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final g = GarageStore(directory: dir);
      final h = HistoryStore(directory: dir);
      await g.save([
        Vehicle(id: DemoTransport.defaultVin, vin: DemoTransport.defaultVin, make: 'Toyota', idSource: 'vin'),
        Vehicle(id: 'real', vin: 'MR0FZ22G809999999', plate: 'กข 9'),
      ]);
      await h.add(VehicleSnapshot(time: DateTime(2026), dtcs: const [], pids: const {}, vin: DemoTransport.defaultVin));
      await h.add(VehicleSnapshot(time: DateTime(2026), dtcs: const [], pids: const {}, vin: 'MR0FZ22G809999999'));

      await removeOldDemoData(prefs, garage: g, history: h);
      expect((await g.load()).map((v) => v.id), ['real']);
      expect((await h.load()).map((s) => s.vin), ['MR0FZ22G809999999']);
      expect(prefs.getBool('cleanup_demo_v1'), true);

      // รถจำลองที่ผู้ใช้ใส่ทะเบียนไว้แล้ว ไม่ลบ
      expect(isUntouchedDemoCar(Vehicle(id: 'x', vin: DemoTransport.defaultVin, plate: 'ทดสอบ')), false);
      expect(isUntouchedDemoCar(Vehicle(id: 'y', vin: DemoTransport.defaultVin)), true);
    });
  });
}
