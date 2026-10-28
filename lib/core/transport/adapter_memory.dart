import 'dart:convert';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'ble_transport.dart';
import 'classic_transport.dart';
import 'demo_transport.dart';
import 'obd_transport.dart';
import 'wifi_transport.dart';

/// ตัวสแกนที่เคยเชื่อมต่อสำเร็จ ใช้เชื่อมต่อซ้ำได้ด้วยการแตะครั้งเดียว
class AdapterMemento {
  const AdapterMemento({required this.kind, required this.id, this.name, this.port});

  final TransportKind kind;

  /// BLE: remoteId, Bluetooth Classic: MAC address, Wi-Fi: IP
  final String id;
  final String? name;
  final int? port;

  String get label => switch (kind) {
        TransportKind.wifi => '$id:${port ?? WifiTransport.defaultPort}',
        _ => (name == null || name!.trim().isEmpty) ? id : name!.trim(),
      };

  String get kindLabel => switch (kind) {
        TransportKind.ble => 'Bluetooth LE',
        TransportKind.classic => 'Bluetooth',
        TransportKind.wifi => 'Wi-Fi',
        TransportKind.demo => 'ทดลอง',
      };

  ObdTransport build() => switch (kind) {
        TransportKind.ble => BleTransport(BluetoothDevice.fromId(id)),
        TransportKind.classic => ClassicBtTransport(ClassicDevice(address: id, name: name, bonded: true)),
        TransportKind.wifi => WifiTransport(host: id, port: port ?? WifiTransport.defaultPort),
        TransportKind.demo => DemoTransport(),
      };

  /// เก็บเฉพาะตัวสแกนจริง (ไม่เก็บโหมดทดลอง)
  static AdapterMemento? of(ObdTransport t) => switch (t) {
        BleTransport b => AdapterMemento(kind: TransportKind.ble, id: b.device.remoteId.str, name: b.device.platformName),
        ClassicBtTransport c => AdapterMemento(kind: TransportKind.classic, id: c.device.address, name: c.device.name),
        WifiTransport w => AdapterMemento(kind: TransportKind.wifi, id: w.activeHost, port: w.activePort),
        _ => null,
      };

  String encode() => jsonEncode({
        'k': kind.name,
        'id': id,
        if (name != null) 'n': name,
        if (port != null) 'p': port,
      });

  static AdapterMemento? decode(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      final j = jsonDecode(s) as Map<String, dynamic>;
      final kind = TransportKind.values.firstWhere((k) => k.name == j['k']);
      if (kind == TransportKind.demo) return null;
      return AdapterMemento(
        kind: kind,
        id: j['id'] as String,
        name: j['n'] as String?,
        port: (j['p'] as num?)?.toInt(),
      );
    } catch (_) {
      return null;
    }
  }
}
