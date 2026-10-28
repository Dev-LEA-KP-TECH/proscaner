import 'package:flutter/services.dart';

/// บันทึกไฟล์ลงที่ที่ผู้ใช้เลือก / เปิดไฟล์ที่ผู้ใช้เลือก ผ่านหน้าต่างเลือกไฟล์ของ Android
/// (ไม่ต้องขอสิทธิ์อ่าน/เขียนที่เก็บข้อมูล ผู้ใช้เลือกเองทุกครั้ง)
abstract class FilePort {
  /// คืนที่อยู่ไฟล์ที่บันทึก หรือ null ถ้าผู้ใช้ยกเลิก
  Future<String?> saveDocument({required String name, required String mime, required Uint8List bytes});

  /// คืนข้อมูลไฟล์ที่เลือก หรือ null ถ้าผู้ใช้ยกเลิก
  Future<Uint8List?> openDocument({List<String> mimeTypes = const ['*/*']});
}

class FilePortException implements Exception {
  const FilePortException(this.message);

  final String message;

  @override
  String toString() => message;
}

class PlatformFilePort implements FilePort {
  const PlatformFilePort([this._channel = const MethodChannel('proscaner/files')]);

  final MethodChannel _channel;

  @override
  Future<String?> saveDocument({required String name, required String mime, required Uint8List bytes}) async {
    try {
      return await _channel.invokeMethod<String>('saveDocument', {'name': name, 'mime': mime, 'bytes': bytes});
    } on MissingPluginException {
      throw const FilePortException('เครื่องนี้บันทึกไฟล์ด้วยวิธีนี้ไม่ได้ ใช้ปุ่มส่งไฟล์แทน');
    } on PlatformException catch (e) {
      throw FilePortException(e.message ?? 'บันทึกไฟล์ไม่สำเร็จ');
    }
  }

  @override
  Future<Uint8List?> openDocument({List<String> mimeTypes = const ['*/*']}) async {
    try {
      return await _channel.invokeMethod<Uint8List>('openDocument', {'mimeTypes': mimeTypes});
    } on MissingPluginException {
      throw const FilePortException('เครื่องนี้เปิดไฟล์ด้วยวิธีนี้ไม่ได้');
    } on PlatformException catch (e) {
      throw FilePortException(e.message ?? 'เปิดไฟล์ไม่สำเร็จ');
    }
  }
}
