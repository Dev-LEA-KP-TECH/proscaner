import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'obd_transport.dart';

/// ตัวสแกน ELM327 แบบ Bluetooth Low Energy ใช้ได้ทั้ง Android และ iOS
///
/// ตัวสแกนแต่ละยี่ห้อใช้ UUID ต่างกัน จึงลองชุดที่รู้จักก่อน
/// ถ้าไม่เจอจะค้นหา characteristic ที่ "เขียนได้" และ "แจ้งเตือนได้" เอง
class BleTransport implements ObdTransport {
  BleTransport(this.device);

  final BluetoothDevice device;

  BluetoothCharacteristic? _tx; // สำหรับเขียนคำสั่ง
  BluetoothCharacteristic? _rx; // สำหรับรับคำตอบ (notify/indicate)
  StreamSubscription<List<int>>? _rxSub;
  StreamSubscription<BluetoothConnectionState>? _stateSub;
  final _controller = StreamController<List<int>>.broadcast();
  bool _connected = false;
  bool _closing = false;
  int _chunkSize = 20;

  /// (service, notify, write) ของตัวสแกนที่พบบ่อย
  static const _knownLayouts = <(String, String, String)>[
    ('fff0', 'fff1', 'fff2'), // Vgate, Veepeak, ตัวทั่วไป
    ('ffe0', 'ffe1', 'ffe1'), // HM-10 based clones
    ('18f0', '2af0', '2af1'), // OBDLink CX / vLinker
  ];

  /// คำที่มักอยู่ในชื่อตัวสแกน ใช้จัดลำดับรายการให้ตัวสแกนขึ้นก่อน
  static final likelyObdName =
      RegExp(r'obd|elm|vgate|vlink|v-link|veepeak|carista|konnwei|icar|ios|kiwi|thinkcar|launch|scan',
          caseSensitive: false);

  @override
  TransportKind get kind => TransportKind.ble;

  @override
  String get displayName {
    final name = device.platformName;
    return 'BLE ${name.isEmpty ? device.remoteId.str : name}';
  }

  @override
  Stream<List<int>> get incoming => _controller.stream;

  @override
  bool get isConnected => _connected;

  /// เริ่มสแกนหาอุปกรณ์ BLE ใกล้เคียง ผลลัพธ์ดูได้จาก [FlutterBluePlus.scanResults]
  static Future<void> startScan({Duration timeout = const Duration(seconds: 10)}) async {
    if (Platform.isAndroid &&
        FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
      try {
        await FlutterBluePlus.turnOn();
      } catch (_) {}
    }
    await FlutterBluePlus.startScan(timeout: timeout);
  }

  /// ไม่โยน error: ถูกเรียกก่อนเชื่อมต่อทุกแบบ (รวมโหมดทดลอง) และตอน dispose
  static Future<void> stopScan() async {
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
  }

  @override
  Future<void> connect() async {
    _closing = false;
    try {
      await device.connect(timeout: const Duration(seconds: 12), autoConnect: false);
    } catch (e) {
      throw TransportException('เชื่อมต่อ Bluetooth ไม่สำเร็จ: $e');
    }

    _stateSub = device.connectionState.listen((s) {
      if (s == BluetoothConnectionState.disconnected && _connected) {
        _connected = false;
        if (!_closing) {
          _controller.addError(TransportException('Bluetooth หลุดการเชื่อมต่อ'));
        }
      }
    });

    if (Platform.isAndroid) {
      try {
        final mtu = await device.requestMtu(185);
        _chunkSize = (mtu - 3).clamp(20, 182);
      } catch (_) {
        _chunkSize = 20;
      }
    }

    final services = await device.discoverServices();
    _pickCharacteristics(services);

    final rx = _rx;
    final tx = _tx;
    if (rx == null || tx == null) {
      await disconnect();
      throw TransportException(
          'ไม่พบช่องสื่อสาร OBD บนอุปกรณ์นี้ อาจไม่ใช่ตัวสแกน ELM327 แบบ BLE');
    }

    await rx.setNotifyValue(true);
    _rxSub = rx.onValueReceived.listen(_controller.add);
    _connected = true;
  }

  void _pickCharacteristics(List<BluetoothService> services) {
    // 1) ลองชุด UUID ที่รู้จัก
    for (final (svcId, notifyId, writeId) in _knownLayouts) {
      for (final s in services) {
        if (_short(s.uuid) != svcId) continue;
        BluetoothCharacteristic? n;
        BluetoothCharacteristic? w;
        for (final c in s.characteristics) {
          final id = _short(c.uuid);
          if (id == notifyId && (c.properties.notify || c.properties.indicate)) n = c;
          if (id == writeId && (c.properties.write || c.properties.writeWithoutResponse)) w = c;
        }
        if (n != null && w != null) {
          _rx = n;
          _tx = w;
          return;
        }
      }
    }
    // 2) ค้นหาเอง: service เดียวกันที่มีทั้งช่องเขียนและช่องแจ้งเตือน
    for (final s in services) {
      // ข้าม service มาตรฐานของระบบ (Generic Access / Generic Attribute / Device Info)
      if (const {'1800', '1801', '180a'}.contains(_short(s.uuid))) continue;
      BluetoothCharacteristic? n;
      BluetoothCharacteristic? w;
      for (final c in s.characteristics) {
        if (n == null && (c.properties.notify || c.properties.indicate)) n = c;
        if (w == null && (c.properties.write || c.properties.writeWithoutResponse)) w = c;
      }
      if (n != null && w != null) {
        _rx = n;
        _tx = w;
        return;
      }
    }
  }

  /// แปลง UUID เป็นรูปสั้น 4 ตัวอักษร ถ้าเป็น UUID ฐานของ Bluetooth SIG
  static String _short(Guid g) {
    final s = g.toString().toLowerCase();
    if (s.length == 36 && s.endsWith('-0000-1000-8000-00805f9b34fb')) {
      return s.substring(4, 8);
    }
    return s;
  }

  @override
  Future<void> write(List<int> bytes) async {
    final tx = _tx;
    if (tx == null || !_connected) throw TransportException('ยังไม่ได้เชื่อมต่อ');
    final noResponse = tx.properties.writeWithoutResponse;
    for (var i = 0; i < bytes.length; i += _chunkSize) {
      final end = (i + _chunkSize < bytes.length) ? i + _chunkSize : bytes.length;
      await tx.write(bytes.sublist(i, end), withoutResponse: noResponse);
    }
  }

  @override
  Future<void> disconnect() async {
    _closing = true;
    _connected = false;
    await _rxSub?.cancel();
    _rxSub = null;
    await _stateSub?.cancel();
    _stateSub = null;
    try {
      await device.disconnect();
    } catch (_) {}
  }
}
