import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import 'obd_transport.dart';

/// อุปกรณ์ Bluetooth Classic ที่พบหรือจับคู่ไว้แล้ว
class ClassicDevice {
  const ClassicDevice({required this.address, this.name, this.bonded = false});

  final String address;
  final String? name;
  final bool bonded;

  String get label => (name == null || name!.trim().isEmpty) ? address : name!.trim();

  static ClassicDevice fromMap(Map<Object?, Object?> m) => ClassicDevice(
        address: m['address']! as String,
        name: m['name'] as String?,
        bonded: m['bonded'] as bool? ?? false,
      );
}

/// ตัวสแกน ELM327 แบบ Bluetooth Classic (SPP) ซึ่งเป็นแบบที่ขายทั่วไปมากที่สุด
/// ใช้ได้เฉพาะ Android (iPhone ไม่อนุญาตให้แอปใช้ Bluetooth Classic)
/// ฝั่ง Android อยู่ใน ProScanerActivity.kt
class ClassicBtTransport implements ObdTransport {
  ClassicBtTransport(this.device);

  final ClassicDevice device;

  static const _method = MethodChannel('proscaner/classic');
  static const _data = EventChannel('proscaner/classic/data');
  static const _scan = EventChannel('proscaner/classic/scan');

  /// ช่องรับข้อมูลใช้ร่วมกันทุกการเชื่อมต่อ ถ้าแต่ละตัวเปิดช่องของตัวเอง
  /// การปิดช่องของการเชื่อมต่อเก่าจะไปตัดช่องของการเชื่อมต่อใหม่
  static final Stream<dynamic> _dataStream = _data.receiveBroadcastStream();

  /// เลขประจำการเชื่อมต่อ ฝั่ง Android จะปิดเฉพาะการเชื่อมต่อที่ตรงเลขนี้
  static int _nextToken = 1;
  final int _token = _nextToken++;

  static bool get supported => Platform.isAndroid;

  final _controller = StreamController<List<int>>.broadcast();
  StreamSubscription<dynamic>? _sub;
  bool _connected = false;
  bool _closing = false;

  @override
  TransportKind get kind => TransportKind.classic;

  @override
  String get displayName => 'Bluetooth ${device.label}';

  @override
  Stream<List<int>> get incoming => _controller.stream;

  @override
  bool get isConnected => _connected;

  static Future<bool> isEnabled() async {
    if (!supported) return false;
    try {
      return await _method.invokeMethod<bool>('isEnabled') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// เปิดหน้าต่างระบบ "อนุญาตให้เปิด Bluetooth" คืน true ถ้าผู้ใช้กดอนุญาต
  static Future<bool> requestEnable() async {
    if (!supported) return false;
    try {
      return await _method.invokeMethod<bool>('requestEnable') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// เปิดหน้าตั้งค่า Bluetooth ของมือถือ (ใช้จับคู่ตัวสแกนครั้งแรก)
  static Future<void> openSettings() async {
    if (!supported) return;
    try {
      await _method.invokeMethod<void>('openSettings');
    } on PlatformException {
      // ไม่มีหน้าตั้งค่า
    }
  }

  /// Android 11 ลงไป ต้องเปิด "ตำแหน่ง" จึงจะค้นหาอุปกรณ์ Bluetooth ได้
  static Future<bool> locationEnabled() async {
    if (!supported) return true;
    try {
      return await _method.invokeMethod<bool>('locationEnabled') ?? true;
    } on PlatformException {
      return true;
    }
  }

  /// ขอสิทธิ์ Bluetooth (และตำแหน่งสำหรับ Android รุ่นเก่า) คืน true ถ้าได้ครบ
  static Future<bool> ensurePermissions({bool scan = false}) async {
    if (!supported) return true;
    try {
      return await _method.invokeMethod<bool>('ensurePermissions', {'scan': scan}) ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// อุปกรณ์ที่จับคู่ไว้แล้วในมือถือ
  static Future<List<ClassicDevice>> bonded() async {
    if (!supported) return const [];
    final list = await _method.invokeListMethod<Object?>('bonded') ?? const <Object?>[];
    return [
      for (final m in list)
        if (m is Map) ClassicDevice.fromMap(m),
    ];
  }

  /// ค้นหาอุปกรณ์ใกล้เคียง (ราว 12 วินาที) ส่ง null เมื่อค้นหาเสร็จ หยุดได้ด้วยการ cancel
  static Stream<ClassicDevice?> discover() {
    if (!supported) return const Stream.empty();
    return _scan.receiveBroadcastStream().map((e) {
      if (e is! Map) return null;
      if (e['done'] == true) return null;
      return ClassicDevice.fromMap(e);
    });
  }

  @override
  Future<void> connect() async {
    if (!supported) throw TransportException('Bluetooth Classic ใช้ได้เฉพาะ Android');
    _closing = false;
    // ฟังข้อมูลก่อนเชื่อมต่อ จะได้ไม่พลาดไบต์แรก
    _sub ??= _dataStream.listen(
      (e) {
        if (e is Uint8List) _controller.add(e);
      },
      onError: (Object e) {
        if (_closing) return;
        _connected = false;
        final msg = e is PlatformException ? (e.message ?? 'Bluetooth หลุดการเชื่อมต่อ') : 'Bluetooth หลุดการเชื่อมต่อ';
        _controller.addError(TransportException(msg));
      },
    );
    try {
      await _method.invokeMethod<bool>('connect', {'address': device.address, 'token': _token});
    } on PlatformException catch (e) {
      await _sub?.cancel();
      _sub = null;
      throw TransportException(e.message ?? 'เชื่อมต่อ Bluetooth ไม่สำเร็จ');
    }
    if (_closing) {
      // ผู้ใช้ยกเลิกระหว่างรอเชื่อมต่อ
      await disconnect();
      throw TransportException('ยกเลิกการเชื่อมต่อแล้ว');
    }
    _connected = true;
  }

  @override
  Future<void> write(List<int> bytes) async {
    if (!_connected) throw TransportException('ยังไม่ได้เชื่อมต่อ');
    try {
      await _method.invokeMethod<void>('write', Uint8List.fromList(bytes));
    } on PlatformException catch (e) {
      throw TransportException(e.message ?? 'ส่งข้อมูลไป Bluetooth ไม่สำเร็จ');
    }
  }

  @override
  Future<void> disconnect() async {
    _closing = true;
    _connected = false;
    try {
      await _method.invokeMethod<void>('disconnect', {'token': _token});
    } on PlatformException {
      // ปิดไปแล้ว
    } on MissingPluginException {
      // ไม่ได้รันบน Android
    }
    await _sub?.cancel();
    _sub = null;
  }
}
