// เพิ่มสิทธิ์ Bluetooth / เครือข่าย ให้โปรเจกต์ Android และ iOS
//
// ใช้หลังสร้างโฟลเดอร์แพลตฟอร์มแล้ว:
//   flutter create --platforms=android,ios --org com.yourcompany .
//   dart run tool/setup_platforms.dart
//
// รันซ้ำได้ สคริปต์จะไม่ใส่ซ้ำถ้ามีอยู่แล้ว
// ignore_for_file: avoid_print
import 'dart:io';

void main() {
  _patchAndroid();
  _patchIos();
}

void _patchAndroid() {
  final f = File('android/app/src/main/AndroidManifest.xml');
  if (!f.existsSync()) {
    print('ไม่พบ ${f.path} ให้รัน flutter create ก่อน');
    return;
  }
  var xml = f.readAsStringSync();
  const perms = <String>[
    '<uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation" />',
    '<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />',
    '<uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />',
    '<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" />',
    '<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" android:maxSdkVersion="30" />',
    '<uses-permission android:name="android.permission.INTERNET" />',
    '<uses-feature android:name="android.hardware.bluetooth_le" android:required="false" />',
  ];
  final missing = perms.where((p) => !xml.contains('"${p.split('"')[1]}"')).toList();
  if (missing.isEmpty) {
    print('Android: มีสิทธิ์ครบแล้ว');
    return;
  }
  final idx = xml.indexOf('<application');
  if (idx < 0) {
    print('ไม่พบแท็ก <application> ใน AndroidManifest.xml');
    return;
  }
  xml = '${xml.substring(0, idx)}${missing.map((p) => '    $p\n').join()}\n    ${xml.substring(idx)}';
  f.writeAsStringSync(xml);
  print('Android: เพิ่ม ${missing.length} รายการใน AndroidManifest.xml');
}

void _patchIos() {
  final f = File('ios/Runner/Info.plist');
  if (!f.existsSync()) {
    print('ไม่พบ ${f.path} ให้รัน flutter create ก่อน');
    return;
  }
  var plist = f.readAsStringSync();
  const entries = <String, String>{
    'NSBluetoothAlwaysUsageDescription': 'แอปใช้ Bluetooth เพื่อเชื่อมต่อตัวสแกน OBD-II ของรถ',
    'NSLocalNetworkUsageDescription': 'แอปใช้เครือข่ายในเครื่องเพื่อเชื่อมต่อตัวสแกน OBD-II แบบ Wi-Fi',
  };
  final add = StringBuffer();
  entries.forEach((k, v) {
    if (!plist.contains('<key>$k</key>')) add.write('\t<key>$k</key>\n\t<string>$v</string>\n');
  });
  if (add.isEmpty) {
    print('iOS: มีคำอธิบายสิทธิ์ครบแล้ว');
    return;
  }
  final idx = plist.lastIndexOf('</dict>');
  plist = '${plist.substring(0, idx)}$add${plist.substring(idx)}';
  f.writeAsStringSync(plist);
  print('iOS: เพิ่มคำอธิบายสิทธิ์ใน Info.plist');
}
