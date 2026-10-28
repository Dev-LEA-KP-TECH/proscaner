import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/transport/demo_transport.dart';
import 'garage_store.dart';
import 'history_store.dart';

/// แอปรุ่นก่อนบันทึกรถจำลองของโหมดทดลอง (VIN ของ DemoTransport) ลงโรงรถและประวัติจริง
/// ล้างออกครั้งเดียว เฉพาะรถจำลองที่ผู้ใช้ไม่ได้แก้ไขข้อมูลอะไร (ทะเบียน ลูกค้า เบอร์ ฯลฯ)
Future<void> removeOldDemoData(SharedPreferences prefs, {GarageStore? garage, HistoryStore? history}) async {
  const key = 'cleanup_demo_v1';
  if (prefs.getBool(key) ?? false) return;
  try {
    final g = garage ?? GarageStore();
    final cars = await g.load();
    final keep = cars.where((v) => !isUntouchedDemoCar(v)).toList();
    if (keep.length != cars.length) await g.save(keep);
    final h = history ?? HistoryStore();
    await h.removeWhere((s) => s.vin == DemoTransport.defaultVin);
    await prefs.setBool(key, true);
  } catch (e) {
    debugPrint('ProScaner: ล้างข้อมูลโหมดทดลองเก่าไม่สำเร็จ $e');
  }
}

/// รถจำลองที่ผู้ใช้ไม่ได้แก้ไขอะไร (ลบได้โดยไม่เสียข้อมูลของผู้ใช้)
bool isUntouchedDemoCar(Vehicle v) {
  bool empty(String? s) => s == null || s.trim().isEmpty;
  return v.vin == DemoTransport.defaultVin &&
      v.nickname.trim().isEmpty &&
      empty(v.plate) &&
      empty(v.customer) &&
      empty(v.phone) &&
      v.idSource != 'manual' &&
      v.injectors.isEmpty &&
      v.maintenance.every((m) => m.lastKm == null && m.lastDate == null);
}
