// เทสต์ v0.6.2
// - สำรอง/กู้คืนข้อมูลทั้งแอป (ย้ายรถและประวัติจากแอปทดสอบไปแอปตัวจริง) แบบรวม ไม่ลบ ไม่ทับของเดิม
// - บันทึกการสื่อสารกับตัวสแกน (ไฟล์ละการเชื่อมต่อ ส่งให้ผู้พัฒนาได้)
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obd_doctor/core/analysis/remap_demo.dart';
import 'package:obd_doctor/core/analysis/remap_test.dart';
import 'package:obd_doctor/core/app_info.dart';
import 'package:obd_doctor/core/diagnosis/diagnosis.dart';
import 'package:obd_doctor/core/obd/ext_pid.dart';
import 'package:obd_doctor/core/obd/pids.dart';
import 'package:obd_doctor/core/transport/demo_transport.dart';
import 'package:obd_doctor/core/transport/obd_transport.dart';
import 'package:obd_doctor/data/backup.dart';
import 'package:obd_doctor/data/comm_log.dart';
import 'package:obd_doctor/data/garage_store.dart';
import 'package:obd_doctor/data/history_store.dart';
import 'package:obd_doctor/data/log_store.dart';
import 'package:obd_doctor/data/remap_store.dart';
import 'package:obd_doctor/state/ext_packs.dart';
import 'package:obd_doctor/state/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// ค่าตั้งค่าในหน่วยความจำ (แทน SharedPreferences ของ "อีกแอปหนึ่ง")
class _MapPrefs implements BackupPrefs {
  _MapPrefs([Map<String, Object>? init]) : m = {...?init};

  final Map<String, Object> m;

  @override
  Map<String, Object> readAll() => Map.of(m);

  @override
  bool has(String key) => m.containsKey(key);

  @override
  Future<void> write(String key, Object value) async => m[key] = value;
}

/// ตัวสแกนเขียนบทเอง: ตอบตาม [reply] (null = ไม่ตอบ)
class _Scripted implements ObdTransport {
  _Scripted(this.reply);

  final String? Function(String cmd) reply;
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
    final r = reply(cmd);
    if (r == null) return;
    scheduleMicrotask(() => _c.add('$r\r\r>'.codeUnits));
  }
}

/// ตัวสแกนที่เชื่อมต่อไม่ได้
class _NoAdapter implements ObdTransport {
  @override
  TransportKind get kind => TransportKind.wifi;

  @override
  String get displayName => 'ไม่มีตัวสแกน';

  @override
  Stream<List<int>> get incoming => const Stream.empty();

  @override
  bool get isConnected => false;

  @override
  Future<void> connect() async => throw TransportException('ไม่พบตัวสแกนที่ 192.168.0.10');

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> write(List<int> bytes) async {}
}

/// ตัวสแกน CAN ทั่วไป: ตอบคำสั่ง AT และ PID 00 คำสั่งอื่น NO DATA
String? _adapter(String cmd) {
  if (cmd == 'ATZ' || cmd == 'ATI') return 'ELM327 v1.5';
  if (cmd == 'STI') return '?';
  if (cmd == 'AT@1') return 'OBDII to RS232 Interpreter';
  if (cmd == 'ATDPN') return 'A6';
  if (cmd == 'ATDP') return 'ISO 15765-4 (CAN 11/500)';
  if (cmd.startsWith('AT')) return 'OK';
  if (cmd == '0100') return '7E8 06 41 00 BE 3F A8 13 00';
  return 'NO DATA';
}

const _vin = 'MPATFS85H7H500001';

ExtPidPack _pack({String id = 'pack_1', String? lib}) => ExtPidPack(
      id: id,
      name: 'D-Max 4JJ1',
      brand: 'Isuzu',
      lib: lib,
      pids: [
        ExtPid(name: 'ชดเชยหัวฉีดสูบ 1', request: '221101', formula: 'S16(A,B)/100', header: '7E0', unit: 'mm³'),
        // คำสั่งเขียนข้อมูลลงกล่อง: ต้องไม่ถูกนำเข้า
        ExtPid(name: 'เขียนค่าหัวฉีด', request: '2E1101', formula: 'A', header: '7E0'),
      ],
    );

/// ข้อมูลของ "แอปทดสอบ" ที่จะสำรอง
Future<BackupService> _sourceApp(Directory dir) async {
  final garage = GarageStore(directory: dir);
  final car = Vehicle(
    id: 'car_1',
    nickname: 'D-Max ลูกค้า',
    plate: 'กข 1234',
    customer: 'คุณสมชาย',
    phone: '0812345678',
    make: 'Isuzu',
    model: 'D-Max',
    year: 2007,
    fuel: 'ดีเซล',
    idSource: 'manual',
    odometer: [OdoEntry(time: DateTime(2026, 10, 1, 9), dashKm: 250000)],
    injectors: [InjectorCode(cylinder: 1, code: 'ABC123', time: DateTime(2026, 10, 1, 9))],
    created: DateTime(2026, 9, 30),
  );
  car.maintenance.first.lastKm = 245000;
  await garage.save([car]);

  final history = HistoryStore(directory: dir);
  await history.add(VehicleSnapshot(time: DateTime(2026, 10, 1, 9), dtcs: const [], pids: const {}, vin: _vin));
  await history.add(VehicleSnapshot(time: DateTime(2026, 10, 2, 9), dtcs: const [], pids: const {}, vin: _vin));

  final logs = LogStore(directory: dir);
  await logs.save(DriveLog(
    id: 'log_1',
    name: 'ขับทดสอบ',
    start: DateTime(2026, 10, 1, 10),
    pids: const [Pid.rpm, Pid.speed],
    times: [0, 0.5],
    rows: [
      [800, 0],
      [1500, 12],
    ],
    vin: _vin,
  ));

  final remaps = RemapStore(directory: dir);
  await remaps.save(syntheticRemapRun(id: 'remap_1', stage: RemapStage.before, start: DateTime(2026, 10, 20)));

  final logo = File('${dir.path}/shop_logo_1.png')..writeAsBytesSync([1, 2, 3, 4]);
  final prefs = _MapPrefs({
    'shop_name': 'Magic Master Remap',
    'shop_logo': logo.path,
    'theme_mode': 'dark',
    'dash_pids': ['12', '13'],
    'al_on': true,
    'al_cool': 105.0,
    'cleanup_demo_v1': true,
    BackupData.packsKey: jsonEncode([_pack().toJson()]),
  });
  return BackupService(prefs: prefs, garage: garage, history: history, logs: logs, remaps: remaps, directory: dir);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('สำรอง/กู้คืนข้อมูล', () {
    late Directory a;
    late Directory b;

    setUp(() {
      a = Directory.systemTemp.createTempSync('backup_a_');
      b = Directory.systemTemp.createTempSync('backup_b_');
    });

    tearDown(() {
      a.deleteSync(recursive: true);
      b.deleteSync(recursive: true);
    });

    test('ย้ายข้อมูลทั้งหมดไปอีกแอป: รถ ประวัติ ชุดค่า ข้อมูลอู่ โลโก้ บันทึกการขับ ผลรีแมพ', () async {
      final source = await _sourceApp(a);
      final data = await source.collect(appVersion: '0.5.9', now: DateTime(2026, 10, 27, 15));
      expect(data.contentsTh(), [
        'รถในโรงรถ 1 คัน',
        'ประวัติการสแกน 2 ครั้ง',
        'ชุดค่าเฉพาะยี่ห้อ 1 ชุด',
        'บันทึกการขับ 1 ครั้ง',
        'ผลทดสอบรีแมพ 1 ครั้ง',
        'ข้อมูลอู่ "Magic Master Remap" พร้อมโลโก้',
      ]);
      // ค่าเฉพาะของแอปเดิมไม่ติดไป
      expect(data.prefs.containsKey('shop_logo'), false);
      expect(data.prefs.containsKey('cleanup_demo_v1'), false);

      // อ่านกลับจากไฟล์ (ผ่าน JSON จริง)
      final file = BackupData.parse(data.encode());
      expect(file.appVersion, '0.5.9');
      expect(file.created, DateTime(2026, 10, 27, 15));

      // แอปตัวจริง (ยังว่าง) ใช้ SharedPreferences จริง
      // ignore: invalid_use_of_visible_for_testing_member
      SharedPreferences.setMockInitialValues({});
      final sp = await SharedPreferences.getInstance();
      final target = BackupService(
        prefs: SharedPrefsBackup(sp),
        garage: GarageStore(directory: b),
        history: HistoryStore(directory: b),
        logs: LogStore(directory: b),
        remaps: RemapStore(directory: b),
        directory: b,
      );
      final r = await target.restore(file);
      expect(r.vehiclesAdded, 1);
      expect(r.vehiclesUpdated, 0);
      expect(r.historyAdded, 2);
      expect(r.packsAdded, 1);
      expect(r.packItemsBlocked, 1);
      expect(r.logsAdded, 1);
      expect(r.remapAdded, 1);
      expect(r.settingsFilled, 5);
      expect(r.logoRestored, true);
      expect(r.linesTh(), contains('เพิ่มรถ 1 คัน'));

      final srcCar = (await GarageStore(directory: a).load()).single;
      final car = (await GarageStore(directory: b).load()).single;
      expect(car.toJson(), srcCar.toJson());
      expect(car.maintenance.first.lastKm, 245000);
      expect((await HistoryStore(directory: b).load()).map((s) => s.time), [DateTime(2026, 10, 2, 9), DateTime(2026, 10, 1, 9)]);
      final log = (await LogStore(directory: b).list()).single;
      expect(log.name, 'ขับทดสอบ');
      expect(log.series(Pid.rpm).map((e) => e.$2), [800, 1500]);
      expect((await RemapStore(directory: b).list()).single.id, 'remap_1');

      expect(sp.getString('shop_name'), 'Magic Master Remap');
      expect(sp.getString('theme_mode'), 'dark');
      expect(sp.getStringList('dash_pids'), ['12', '13']);
      expect(sp.getBool('al_on'), true);
      expect(sp.getDouble('al_cool'), 105.0);
      expect(sp.containsKey('cleanup_demo_v1'), false);
      final logo = sp.getString('shop_logo')!;
      expect(File(logo).parent.path, File('${b.path}/x').parent.path);
      expect(File(logo).readAsBytesSync(), [1, 2, 3, 4]);

      // แอปอ่านชุดค่าที่กู้คืนได้ และไม่มีคำสั่งเขียนข้อมูล
      final c = ProviderContainer(overrides: [sharedPrefsProvider.overrideWithValue(sp)]);
      addTearDown(c.dispose);
      final packs = c.read(extPacksProvider);
      expect(packs.single.name, 'D-Max 4JJ1');
      expect(packs.single.pids.map((p) => p.request), ['221101']);
      expect(c.read(settingsProvider).shop.name, 'Magic Master Remap');

      // กู้คืนซ้ำ: ไม่มีอะไรซ้ำ
      final again = await target.restore(file);
      expect(again.nothing, true);
      expect((await GarageStore(directory: b).load()).length, 1);
      expect((await HistoryStore(directory: b).load()).length, 2);
      expect(c.read(extPacksProvider).length, 1);
    });

    test('รถคันเดียวกัน (VIN ตรงกัน): เติมช่องที่ว่างและรวมเลขไมล์ ไม่ทับของเดิม', () {
      final mine = Vehicle(
        id: _vin,
        vin: _vin,
        nickname: 'รถพี่หนึ่ง',
        make: 'Isuzu',
        odometer: [OdoEntry(time: DateTime(2026, 10, 5), ecuKm: 251000)],
      );
      final theirs = Vehicle(
        id: 'car_9',
        vin: ' ${_vin.toLowerCase()}',
        nickname: 'ชื่อในไฟล์',
        plate: 'กข 1234',
        customer: 'คุณสมชาย',
        make: 'Toyota',
        model: 'D-Max',
        year: 2007,
        idSource: 'manual',
        odometer: [OdoEntry(time: DateTime(2026, 10, 1), dashKm: 250000)],
        injectors: [InjectorCode(cylinder: 2, code: 'XYZ', time: DateTime(2026, 10, 1))],
      );
      final m = mergeVehicles([mine], [theirs]);
      expect(m.added, 0);
      expect(m.updated, 1);
      final v = m.vehicles.single;
      expect(v.id, _vin);
      expect(v.nickname, 'รถพี่หนึ่ง');
      expect(v.make, 'Isuzu');
      expect(v.plate, 'กข 1234');
      expect(v.customer, 'คุณสมชาย');
      expect(v.model, 'D-Max');
      expect(v.idSource, 'manual');
      expect(v.year, 2007);
      expect(v.odometer.map((e) => e.time), [DateTime(2026, 10, 1), DateTime(2026, 10, 5)]);
      expect(v.latestKm, 251000);
      expect(v.injectors.single.code, 'XYZ');

      // รวมซ้ำ: ไม่เปลี่ยนอะไร
      final again = mergeVehicles(m.vehicles, [theirs]);
      expect(again.updated, 0);
      expect(again.vehicles.single.odometer.length, 2);
    });

    test('id ซ้ำแต่ VIN คนละเลข = คนละคัน: เก็บทั้งสองคัน', () {
      final m = mergeVehicles(
        [Vehicle(id: 'car_1', vin: 'AAAAAAAAAAAAAAAAA'), Vehicle(id: 'car_1_2')],
        [Vehicle(id: 'car_1', vin: 'BBBBBBBBBBBBBBBBB', plate: 'กข 2')],
      );
      expect(m.added, 1);
      expect(m.vehicles.map((v) => v.id), ['car_1', 'car_1_2', 'car_1_3']);
      expect(m.vehicles.last.plate, 'กข 2');
      expect(m.vehicles.first.vin, 'AAAAAAAAAAAAAAAAA');
    });

    test('ชุดค่าที่มีอยู่แล้ว (id ใหม่จากการนำเข้า หรือชุดเดียวกันจากคลัง) ไม่เพิ่มซ้ำ', () {
      final local = [
        _pack(id: 'pack_imported_later').toJson(),
        {'id': 'lib_copy', 'name': 'Revo', 'lib': 'toyota_1gd', 'pids': <Object>[]},
      ];
      final m = mergePacks(jsonDecode(jsonEncode(local)) as List<dynamic>, [
        _pack().toJson(),
        {'id': 'other_lib_copy', 'name': 'Revo (แก้ชื่อ)', 'lib': 'toyota_1gd', 'pids': <Object>[]},
        {
          'id': 'only_write',
          'name': 'ชุดเขียนอย่างเดียว',
          'pids': [
            {'name': 'w', 'req': '2E1101', 'f': 'A', 'hdr': '7E0'},
          ],
        },
        {'id': 'new', 'name': 'ชุดใหม่', 'pids': <Object>[]},
      ]);
      expect(m.added.map((p) => p.id), ['new']);
      expect(m.blocked, 1);
    });

    test('ไฟล์ที่ไม่ใช่ไฟล์สำรอง / มาจากแอปรุ่นใหม่กว่า: แจ้งเป็นภาษาไทย', () {
      Matcher fails(String text) => throwsA(isA<FormatException>().having((e) => e.message, 'message', contains(text)));
      expect(() => BackupData.parse(utf8.encode('hello')), fails('ไม่ใช่ไฟล์สำรองของ ProScaner'));
      expect(() => BackupData.parse(utf8.encode('[1,2]')), fails('ไม่ใช่ไฟล์สำรองของ ProScaner'));
      expect(() => BackupData.parse(utf8.encode('{"proscaner_pack":1}')), fails('ไม่ใช่ไฟล์สำรองของ ProScaner'));
      expect(() => BackupData.parse(utf8.encode('{"proscaner_backup":2}')), fails('รุ่นใหม่กว่า'));
      expect(() => BackupData.parse([0xFF, 0xFE, 0x00]), fails('ไม่ใช่ไฟล์สำรองของ ProScaner'));

      // มี BOM นำหน้า (แก้ไฟล์ด้วย Notepad) ยังอ่านได้
      final ok = BackupData.parse(utf8.encode('\uFEFF{"proscaner_backup":1,"garage":[{"id":"x"}]}'));
      expect(ok.vehicles.single['id'], 'x');
      expect(ok.history, isEmpty);
    });

    test('ข้อมูลเสียบางรายการในไฟล์: ข้ามเฉพาะรายการนั้น', () async {
      final service = BackupService(
        prefs: _MapPrefs(),
        garage: MemoryGarageStore(),
        history: HistoryStore(directory: b),
        logs: MemoryLogStore(),
        remaps: MemoryRemapStore(),
        directory: b,
      );
      final r = await service.restore(BackupData.parse(utf8.encode(jsonEncode({
        'proscaner_backup': 1,
        'garage': [
          {'id': 5},
          Vehicle(id: 'ok').toJson(),
        ],
        'history': [
          {'time': 'เสีย'},
        ],
        'drive_logs': {'../../evil': '# x', 'log_ok': '# ProScaner drive log\ntime_s,010C x (y)\n0.00,800\n'},
        'remap_runs': {'remap_bad': '{oops'},
        'prefs': {
          'theme_mode': {'t': 's', 'v': 'light'},
          'weird': {'t': 'x', 'v': 1},
          'al_rpm': {'t': 'i', 'v': 'not a number'},
        },
      }))));
      expect(r.vehiclesAdded, 1);
      expect(r.historyAdded, 0);
      expect(r.logsAdded, 1);
      expect(r.remapAdded, 0);
      expect(r.settingsFilled, 1);
      expect((await service.garage.load()).single.id, 'ok');
      expect((await service.logs.list()).single.id, 'log_ok');
    });

    test('สำเนาก่อนกู้คืน: เก็บ 3 ไฟล์ล่าสุด', () async {
      final source = await _sourceApp(a);
      final made = <File>[];
      for (var i = 0; i < 5; i++) {
        made.add((await source.safetyCopy(appVersion: kAppVersion, now: DateTime(2026, 10, 27, 15, i)))!);
      }
      final kept = Directory('${a.path}/backups').listSync().whereType<File>().map((f) => f.uri.pathSegments.last).toList()
        ..sort();
      expect(kept, [for (final f in made.skip(2)) f.uri.pathSegments.last]);
      final copy = BackupData.parse(made.last.readAsBytesSync());
      expect(copy.vehicles.single['id'], 'car_1');
      expect(copy.logoBytes, [1, 2, 3, 4]);
    });

    test('ประวัติเต็ม 100 รายการ: รายการเก่ากว่าทั้งหมดไม่นับว่าเพิ่ม', () async {
      final h = HistoryStore(directory: b);
      VehicleSnapshot snap(int day) => VehicleSnapshot(time: DateTime(2026, 1, 1).add(Duration(days: day)), dtcs: const [], pids: const {});
      expect(await h.merge([for (var d = 1; d <= HistoryStore.maxEntries; d++) snap(d)]), HistoryStore.maxEntries);
      expect(await h.merge([snap(0)]), 0);
      expect(await h.merge([snap(200)]), 1);
      final all = await h.load();
      expect(all.length, HistoryStore.maxEntries);
      expect(all.first.time, snap(200).time);
      expect(all.last.time, snap(2).time);
    });

    test('ค่าตั้งค่าทุกชนิดผ่าน SharedPreferences และไฟล์ได้ครบ', () async {
      // ignore: invalid_use_of_visible_for_testing_member
      SharedPreferences.setMockInitialValues({'s': 'x', 'b': true, 'i': 3, 'd': 2.0, 'l': ['a', 'b']});
      final p = SharedPrefsBackup(await SharedPreferences.getInstance());
      final all = p.readAll();
      expect(all, {'s': 'x', 'b': true, 'i': 3, 'd': 2.0, 'l': ['a', 'b']});
      final back = BackupData.parse(BackupData(
        created: DateTime(2026),
        appVersion: kAppVersion,
        prefs: all,
        vehicles: const [],
        history: const [],
        driveLogs: const {},
        remapRuns: const {},
      ).encode());
      expect(back.prefs['d'], isA<double>());
      expect(back.prefs['i'], isA<int>());
      expect(back.prefs, all);
      await p.write('l2', ['c']);
      expect(p.has('l2'), true);
      expect(p.readAll()['l2'], ['c']);
    });
  });

  group('บันทึกการสื่อสาร', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('comm_log_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('หนึ่งไฟล์ต่อการเชื่อมต่อ มีหัวไฟล์ เวลา และข้อความตอนจบ', () async {
      var now = DateTime(2026, 10, 27, 14, 5, 1, 123);
      final log = CommLog(directory: dir, clock: () => now, flushEvery: const Duration(milliseconds: 5));
      log.add('ยังไม่ได้เริ่ม ไม่บันทึก');
      log.start('Bluetooth OBDII', info: {'app': 'ProScaner 0.6.2'});
      expect(log.active, true);
      log.add('> ATZ');
      log.add('ELM327 v1.5\r\rOK');
      now = now.add(const Duration(seconds: 2));
      log.end('ตัดการเชื่อมต่อ');
      log.add('จบแล้ว ไม่บันทึก');
      expect(log.active, false);

      final list = await log.sessions();
      expect(list, hasLength(1));
      final s = list.single;
      expect(s.title, 'Bluetooth OBDII');
      expect(s.start, DateTime(2026, 10, 27, 14, 5, 1, 123));
      expect(s.name, 'comm_20261027_140501_123.txt');
      expect(await log.read(s), '# ProScaner communication log\n'
          '# title=Bluetooth OBDII\n'
          '# start=2026-10-27T14:05:01.123\n'
          '# app=ProScaner 0.6.2\n'
          '14:05:01.123  > ATZ\n'
          '14:05:01.123  ELM327 v1.5 | OK\n'
          '14:05:03.123  == ตัดการเชื่อมต่อ\n');
    });

    test('เขียนลงไฟล์เองเป็นช่วงๆ ระหว่างเชื่อมต่อ (แอปปิดกะทันหันก็ยังมีบันทึก)', () async {
      final log = CommLog(directory: dir, flushEvery: const Duration(milliseconds: 5));
      log.start('Wi-Fi');
      log.add('> 010C');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final f = Directory('${dir.path}/comm_logs').listSync().whereType<File>().single;
      expect(f.readAsStringSync(), contains('> 010C'));
      log.end();
      await log.flush();
    });

    test('เก็บไว้ไม่เกินจำนวนที่กำหนด ลบของเก่าก่อน', () async {
      var now = DateTime(2026, 10, 27, 8);
      final log = CommLog(directory: dir, maxSessions: 3, clock: () => now);
      for (var i = 0; i < 5; i++) {
        now = now.add(const Duration(minutes: 1));
        log.start('ครั้งที่ $i');
        log.add('> ATZ');
        log.end();
      }
      final list = await log.sessions();
      expect(list.map((s) => s.title), ['ครั้งที่ 4', 'ครั้งที่ 3', 'ครั้งที่ 2']);
    });

    test('รวมกันเกินขนาดที่กำหนด: ลบของเก่า แต่ไม่ลบครั้งที่กำลังบันทึก', () async {
      var now = DateTime(2026, 10, 27, 8);
      // แต่ละครั้งประมาณ 1.1 KB: เก็บได้ราว 2 ครั้งเต็มกับครั้งที่กำลังบันทึก
      final log = CommLog(directory: dir, maxTotalBytes: 2500, clock: () => now);
      for (var i = 0; i < 3; i++) {
        now = now.add(const Duration(minutes: 1));
        log.start('ครั้งที่ $i');
        log.add('x' * 1000);
        log.end();
      }
      now = now.add(const Duration(minutes: 1));
      log.start('ครั้งล่าสุด');
      final list = await log.sessions();
      expect(list.map((s) => s.title), ['ครั้งล่าสุด', 'ครั้งที่ 2', 'ครั้งที่ 1']);
      log.end();
      await log.flush();
    });

    test('ลบทั้งหมดระหว่างบันทึก: บรรทัดต่อไปเริ่มไฟล์ใหม่พร้อมหัวไฟล์', () async {
      final log = CommLog(directory: dir);
      log.start('Bluetooth');
      log.add('ก่อนลบ');
      await log.deleteAll();
      log.add('หลังลบ');
      log.end();
      final list = await log.sessions();
      final text = await log.read(list.single);
      expect(text, startsWith('# ProScaner communication log\n# title=Bluetooth\n'));
      expect(text, contains('หลังลบ'));
      expect(text, isNot(contains('ก่อนลบ')));
    });

    test('เขียนไฟล์ไม่ได้: ไม่ทำให้แอปล้ม', () async {
      final notADir = File('${dir.path}/file.txt')..writeAsStringSync('x');
      final log = CommLog(directory: Directory(notADir.path));
      log.start('Bluetooth');
      log.add('> ATZ');
      log.end('จบ');
      await log.flush();
      expect(await log.sessions(), isEmpty);
      await log.deleteAll();
    });
  });

  group('บันทึกการสื่อสารกับการเชื่อมต่อ', () {
    late Directory dir;
    late ProviderContainer c;
    late CommLog comm;
    late SharedPreferences prefs;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('comm_session_');
      // ignore: invalid_use_of_visible_for_testing_member
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      comm = CommLog(directory: dir, flushEvery: const Duration(milliseconds: 5));
      c = ProviderContainer(overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        garageStoreProvider.overrideWithValue(MemoryGarageStore()),
        logStoreProvider.overrideWithValue(MemoryLogStore()),
        historyStoreProvider.overrideWithValue(HistoryStore(directory: dir)),
        commLogProvider.overrideWithValue(comm),
      ]);
    });

    tearDown(() async {
      await c.read(sessionProvider.notifier).disconnect();
      c.dispose();
      await comm.flush();
      dir.deleteSync(recursive: true);
    });

    test('เชื่อมต่อแล้วตัด: ได้บันทึก 1 ครั้ง มีคำสั่ง คำตอบ และรุ่นแอป', () async {
      await c.read(sessionProvider.notifier).connect(_Scripted(_adapter));
      expect(c.read(sessionProvider).isConnected, true);
      expect(comm.active, true);
      await c.read(sessionProvider.notifier).disconnect();
      expect(comm.active, false);

      final list = await comm.sessions();
      expect(list, hasLength(1));
      final text = await comm.read(list.single);
      expect(text, contains('# title=scripted'));
      expect(text, contains('# app=ProScaner $kAppVersion'));
      expect(text, contains('# transport=wifi'));
      expect(text, contains('> ATZ'));
      expect(text, contains('ELM327 v1.5'));
      expect(text, contains('VIN (รถไม่ส่ง VIN)'));
      expect(text.trim().split('\n').last, endsWith('== ตัดการเชื่อมต่อ'));
    });

    test('เชื่อมต่อไม่สำเร็จ: บันทึกเหตุผลไว้', () async {
      await c.read(sessionProvider.notifier).connect(_NoAdapter());
      expect(c.read(sessionProvider).status, ConnStatus.failed);
      final text = await comm.read((await comm.sessions()).single);
      expect(text, contains('เชื่อมต่อไม่สำเร็จ: ไม่พบตัวสแกนที่ 192.168.0.10'));
      expect(text.trim().split('\n').last, endsWith('== เชื่อมต่อไม่สำเร็จ'));
    });

    test('ตัวจำลอง (โหมดทดลอง) ไม่บันทึก', () async {
      await c.read(sessionProvider.notifier).connect(DemoTransport(responseDelay: const Duration(milliseconds: 1)));
      expect(c.read(sessionProvider).isConnected, true);
      expect(comm.active, false);
      expect(await comm.sessions(), isEmpty);
    });

    test('ผู้ใช้ปิดการบันทึก: ไม่สร้างไฟล์ และจำค่าไว้', () async {
      expect(c.read(commLogEnabledProvider), true);
      c.read(commLogEnabledProvider.notifier).set(false);
      expect(prefs.getBool(CommLog.prefKey), false);
      await c.read(sessionProvider.notifier).connect(_Scripted(_adapter));
      expect(c.read(sessionProvider).isConnected, true);
      expect(await comm.sessions(), isEmpty);
    });
  });
}
