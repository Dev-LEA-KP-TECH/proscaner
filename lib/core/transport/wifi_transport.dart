import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'obd_transport.dart';

/// ตัวสแกนแบบ Wi-Fi ส่วนใหญ่ปล่อย access point ของตัวเอง
/// และเปิด TCP ที่ 192.168.0.10:35000 (บางรุ่นใช้ 192.168.4.1 หรือ 192.168.1.10)
class WifiTransport implements ObdTransport {
  WifiTransport({this.host = defaultHost, this.port = defaultPort});

  static const defaultHost = '192.168.0.10';
  static const defaultPort = 35000;

  /// ที่อยู่ที่ตัวสแกน Wi-Fi ยี่ห้อต่างๆ ใช้ ลองตามลำดับเมื่อผู้ใช้ไม่ได้แก้ค่าเริ่มต้น
  static const commonAddresses = <(String, int)>[
    ('192.168.0.10', 35000),
    ('192.168.4.1', 35000),
    ('192.168.1.10', 35000),
    ('192.168.0.74', 23),
  ];

  static const _net = MethodChannel('proscaner/net');

  final String host;
  final int port;

  String? _activeHost;
  int? _activePort;
  Socket? _socket;
  StreamSubscription<List<int>>? _sub;
  final _controller = StreamController<List<int>>.broadcast();
  bool _closing = false;
  bool _bound = false;

  /// ที่อยู่ที่เชื่อมต่อได้จริง (อาจไม่ใช่ค่าที่ผู้ใช้กรอก ถ้าค้นหาอัตโนมัติเจอ)
  String get activeHost => _activeHost ?? host;
  int get activePort => _activePort ?? port;

  @override
  TransportKind get kind => TransportKind.wifi;

  @override
  String get displayName => 'Wi-Fi $activeHost:$activePort';

  @override
  Stream<List<int>> get incoming => _controller.stream;

  @override
  bool get isConnected => _socket != null;

  /// Android: ตัวสแกนไม่มีอินเทอร์เน็ต ระบบจึงมักส่งข้อมูลออกทางเน็ตมือถือแทน
  /// ผูกแอปไว้กับเครือข่าย Wi-Fi ระหว่างเชื่อมต่อ (ไม่ต้องปิดเน็ตมือถือเอง)
  static Future<bool> _bindWifi() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _net.invokeMethod<bool>('bindWifi') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<void> _unbind() async {
    if (!Platform.isAndroid) return;
    try {
      await _net.invokeMethod<void>('unbind');
    } on PlatformException {
      // ไม่เป็นไร
    } on MissingPluginException {
      // ไม่เป็นไร
    }
  }

  @override
  Future<void> connect() async {
    _closing = false;
    _bound = await _bindWifi();
    final useDefaults = host == defaultHost && port == defaultPort;
    final targets = useDefaults ? commonAddresses : [(host, port)];
    Object? lastError;
    for (final (h, p) in targets) {
      if (_closing) break;
      try {
        final socket = await Socket.connect(h, p, timeout: Duration(seconds: useDefaults ? 4 : 6));
        if (_closing) {
          // ผู้ใช้ยกเลิกระหว่างรอ
          socket.destroy();
          break;
        }
        socket.setOption(SocketOption.tcpNoDelay, true);
        _socket = socket;
        _activeHost = h;
        _activePort = p;
        _sub = socket.listen(
          _controller.add,
          onError: (Object e) => _controller.addError(TransportException('การเชื่อมต่อ Wi-Fi ขัดข้อง: $e')),
          onDone: () {
            _socket = null;
            if (!_closing) {
              _controller.addError(TransportException('การเชื่อมต่อ Wi-Fi ถูกตัด'));
            }
          },
        );
        return;
      } on SocketException catch (e) {
        lastError = e.message;
      }
    }
    if (_bound) await _unbind();
    _bound = false;
    if (_closing) throw TransportException('ยกเลิกการเชื่อมต่อแล้ว');
    final tried = targets.map((t) => '${t.$1}:${t.$2}').join(', ');
    throw TransportException('เชื่อมต่อตัวสแกน Wi-Fi ไม่ได้ (ลอง $tried) '
        'ตรวจว่ามือถือต่อ Wi-Fi ของตัวสแกนอยู่ (มักชื่อ WiFi_OBDII, V-LINK หรือ OBDII) '
        'และตัวสแกนเสียบอยู่กับรถ'
        '${Platform.isIOS ? ' และอนุญาตให้ ProScaner ใช้เครือข่ายเฉพาะที่แล้ว (การตั้งค่า > ProScaner)' : ''} '
        '($lastError)');
  }

  @override
  Future<void> write(List<int> bytes) async {
    final socket = _socket;
    if (socket == null) throw TransportException('ยังไม่ได้เชื่อมต่อ');
    socket.add(bytes);
    await socket.flush();
  }

  @override
  Future<void> disconnect() async {
    _closing = true;
    await _sub?.cancel();
    _sub = null;
    final socket = _socket;
    _socket = null;
    if (socket != null) {
      try {
        await socket.close();
      } catch (_) {}
      socket.destroy();
    }
    if (_bound) {
      _bound = false;
      await _unbind();
    }
  }
}
