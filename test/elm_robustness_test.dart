import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:obd_doctor/core/elm/elm327.dart';
import 'package:obd_doctor/core/obd/obd_service.dart';
import 'package:obd_doctor/core/obd/pids.dart';
import 'package:obd_doctor/core/transport/adapter_memory.dart';
import 'package:obd_doctor/core/transport/classic_transport.dart';
import 'package:obd_doctor/core/transport/demo_transport.dart';
import 'package:obd_doctor/core/transport/obd_transport.dart';
import 'package:obd_doctor/core/transport/wifi_transport.dart';

/// ตัวสแกนจำลองแบบเขียนบทเอง: ตอบตามฟังก์ชัน [reply] (null = ไม่ตอบ)
/// ใช้จำลองพฤติกรรมของตัวสแกนจริง/ตัวก๊อป ที่ตัวจำลองหลักไม่ได้ทำ
class _Scripted implements ObdTransport {
  _Scripted(this.reply);

  final String? Function(String cmd) reply;
  final sent = <String>[];
  final _c = StreamController<List<int>>.broadcast();

  @override
  TransportKind get kind => TransportKind.demo;

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
    sent.add(cmd);
    final r = reply(cmd);
    if (r == null) return;
    scheduleMicrotask(() => _c.add('$r\r\r>'.codeUnits));
  }

  /// ข้อความที่ตัวสแกนส่งมาเอง (ไม่ได้ตอบคำสั่ง)
  void push(String s) => _c.add(s.codeUnits);
}

/// ตัวสแกนทั่วไป: โปรโตคอลหาได้จากการค้นหาอัตโนมัติ (CAN 11 บิต 500k)
String? Function(String) _adapter({
  required String? Function(String proto) pid00,
  String? Function(String cmd)? extra,
}) {
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
    if (cmd == '0100') return pid00(proto);
    return 'NO DATA';
  };
}

const _pid00Ok = '7E8 06 41 00 BE 3F A8 13 00';

void main() {
  group('ตัวสแกนจริง/ตัวก๊อป', () {
    test('ค้นหาอัตโนมัติไม่เจอ → ลองทีละโปรโตคอลจนเจอ', () async {
      final t = _Scripted(_adapter(pid00: (p) => switch (p) {
            '0' => 'SEARCHING...\rUNABLE TO CONNECT',
            '8' => _pid00Ok,
            _ => 'NO DATA',
          }));
      final elm = Elm327(t)..attach();
      final steps = <String>[];
      await elm.initialize(onStep: steps.add);
      expect(elm.protocolCode, '8');
      expect(elm.isCan, true);
      expect(t.sent, containsAllInOrder(['ATSP0', '0100', 'ATSP6', '0100', 'ATSP8', '0100']));
      expect(steps.any((s) => s.contains('ลองโปรโตคอล')), true);
    });

    test('ไม่มีโปรโตคอลไหนตอบ (บิดกุญแจยังไม่ ON) → แจ้งให้บิดกุญแจ', () async {
      final t = _Scripted(_adapter(pid00: (p) => p == '0' ? 'SEARCHING...\rUNABLE TO CONNECT' : 'NO DATA'));
      final elm = Elm327(t)..attach();
      await expectLater(
        elm.initialize(),
        throwsA(isA<ElmException>().having((e) => e.message, 'message', contains('บิดกุญแจ'))),
      );
      expect(t.sent.last, 'ATSP0'); // กลับไปค้นหาอัตโนมัติไว้สำหรับครั้งหน้า
    });

    test('ไฟตกตอนสตาร์ท ตัวสแกนรีเซ็ตระหว่างคำสั่ง → ตั้งค่าใหม่แล้วส่งซ้ำ', () async {
      var resetOnce = true;
      final t = _Scripted(_adapter(
        pid00: (p) => 'SEARCHING...\r$_pid00Ok',
        extra: (cmd) {
          if (cmd != '010C') return null;
          if (resetOnce) {
            resetOnce = false;
            return 'LV RESET\r\rELM327 v1.5';
          }
          return '7E8 04 41 0C 1A F8';
        },
      ));
      final elm = Elm327(t)..attach();
      await elm.initialize();
      expect(elm.protocolCode, 'A6');

      final rpm = await ObdService(elm).readPid(Pid.rpm);
      expect(rpm, closeTo(1726, 0.5));
      expect(elm.resetCount, 1);
      final i = t.sent.indexOf('010C');
      expect(t.sent.sublist(i + 1), containsAllInOrder(['ATE0', 'ATH1', 'ATSP6', '010C']));
    });

    test('ตัวสแกนรีเซ็ตเองตอนไม่มีคำสั่ง → ตั้งค่าใหม่ก่อนคำสั่งถัดไป', () async {
      final t = _Scripted(_adapter(
        pid00: (p) => _pid00Ok,
        extra: (cmd) => cmd == '010D' ? '7E8 03 41 0D 3C' : null,
      ));
      final elm = Elm327(t)..attach();
      await elm.initialize();
      final before = t.sent.length;

      t.push('\r\rLV RESET\r\rELM327 v1.5\r\r>');
      await Future<void>.delayed(Duration.zero);

      final speed = await ObdService(elm).readPid(Pid.speed);
      expect(speed, 60);
      expect(elm.resetCount, 1);
      expect(t.sent.sublist(before), containsAllInOrder(['ATE0', 'ATH1', 'ATSP6', '010D']));
    });

    test('echo กลับมาเปิดเอง (ตัวสแกนรีเซ็ตโดยไม่แจ้ง) → จับได้และแก้ให้', () async {
      var echo = true;
      final t = _Scripted(_adapter(
        pid00: (p) => _pid00Ok,
        extra: (cmd) {
          if (cmd != '0105') return null;
          final body = '7E8 03 41 05 7B';
          if (echo) {
            echo = false;
            return '0105\r$body';
          }
          return body;
        },
      ));
      final elm = Elm327(t)..attach();
      await elm.initialize();
      final coolant = await ObdService(elm).readPid(Pid.coolantTemp);
      expect(coolant, 83);
      expect(elm.resetCount, 1);
    });

    test('ตัวจำลองหลักไม่ถูกมองว่ารีเซ็ต (ไม่มีการตั้งค่าซ้ำโดยไม่จำเป็น)', () async {
      final demo = DemoTransport(responseDelay: const Duration(milliseconds: 1));
      await demo.connect();
      final elm = Elm327(demo)..attach();
      await elm.initialize();
      final svc = ObdService(elm);
      await svc.loadSupportedPids();
      await svc.readPids([Pid.rpm, Pid.speed, Pid.coolantTemp]);
      await svc.readVin();
      expect(elm.resetCount, 0);
      await elm.detach();
      await demo.disconnect();
    });
  });

  group('จำตัวสแกนล่าสุด', () {
    test('Bluetooth ธรรมดา และ Wi-Fi เก็บแล้วโหลดกลับได้', () {
      final c = AdapterMemento.of(ClassicBtTransport(const ClassicDevice(address: '00:1D:A5:68:98:8B', name: 'OBDII')))!;
      final back = AdapterMemento.decode(c.encode())!;
      expect(back.kind, TransportKind.classic);
      expect(back.id, '00:1D:A5:68:98:8B');
      expect(back.label, 'OBDII');
      expect(back.build(), isA<ClassicBtTransport>());

      final w = AdapterMemento.decode(AdapterMemento.of(WifiTransport(host: '192.168.4.1', port: 35000))!.encode())!;
      expect(w.kind, TransportKind.wifi);
      expect(w.label, '192.168.4.1:35000');
      final rebuilt = w.build() as WifiTransport;
      expect(rebuilt.host, '192.168.4.1');
    });

    test('โหมดทดลองไม่ถูกจำ และข้อมูลเสียไม่ทำให้แอปล้ม', () {
      expect(AdapterMemento.of(DemoTransport()), isNull);
      expect(AdapterMemento.decode('{bad json'), isNull);
      expect(AdapterMemento.decode(null), isNull);
    });
  });
}
