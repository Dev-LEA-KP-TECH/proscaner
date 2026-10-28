import 'dart:async';

/// ชนิดของการเชื่อมต่อกับตัวสแกน
enum TransportKind {
  /// Bluetooth Low Energy (Android และ iOS)
  ble,

  /// Bluetooth Classic / SPP (เฉพาะ Android) ตัวสแกนราคาถูกส่วนใหญ่เป็นแบบนี้
  classic,
  wifi,
  demo,
}

/// ชั้นการเชื่อมต่อ: ซ่อนความต่างของ BLE / Bluetooth Classic / Wi-Fi / ตัวจำลอง ไว้หลัง interface เดียว
/// ชั้นที่อยู่สูงกว่า (ELM327) เห็นแค่ "ส่งไบต์" กับ "รับไบต์"
abstract class ObdTransport {
  TransportKind get kind;
  String get displayName;

  /// ไบต์ดิบที่ได้รับจากตัวสแกน (อาจมาเป็นชิ้นๆ ไม่ครบบรรทัด)
  Stream<List<int>> get incoming;

  bool get isConnected;

  Future<void> connect();
  Future<void> write(List<int> bytes);
  Future<void> disconnect();
}

class TransportException implements Exception {
  TransportException(this.message);
  final String message;

  @override
  String toString() => message;
}
