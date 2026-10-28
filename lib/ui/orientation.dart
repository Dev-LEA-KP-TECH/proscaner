import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// การหมุนจอของแอป
/// - iPhone: ใช้แนวตั้งตลอด ยกเว้นแดชบอร์ดขับรถที่เปิดเป็นจอนอน
///   (iOS ไม่หมุนกลับเองหลังออกจากหน้าที่บังคับจอนอน และหน้าจอของแอปออกแบบให้มือถือถือแนวตั้ง)
/// - Android และแท็บเล็ต (รวม iPad): หมุนตามเครื่องเหมือนเดิม

/// iPhone (iOS และจอด้านสั้นแคบกว่า 600 จุด)
bool isIPhone(BuildContext context) =>
    defaultTargetPlatform == TargetPlatform.iOS && MediaQuery.sizeOf(context).shortestSide < 600;

/// ตั้งการหมุนจอปกติของแอป: เรียกตอนเริ่มแอป และตอนปิดหน้าที่บังคับจอนอน
Future<void> applyAppOrientation({required bool iPhone}) =>
    SystemChrome.setPreferredOrientations(iPhone ? const [DeviceOrientation.portraitUp] : const []);
