import 'diagnosis.dart';

/// ตัววินิจฉัยด้วย AI (เฟส 2) — ตอนนี้ส่งต่อให้ตัววินิจฉัยด้วยกฎ
///
/// แผนการต่อใช้งาน:
/// 1. แอปส่ง `snapshot.toJson()` พร้อมผลจากกฎ ไปที่ backend ของเราเอง (POST [endpoint])
/// 2. backend เก็บ API key ของ AI ไว้ฝั่งเซิร์ฟเวอร์ ห้ามใส่ key ในแอป
/// 3. backend ส่งกลับรายการ finding รูปแบบเดียวกับ [Finding] (title, severity,
///    causes, checks, evidence) แอปจึงแสดงผลด้วย UI เดิมได้ทันที
/// 4. ถ้าเน็ตไม่มีหรือ backend ล่ม ใช้ผลจาก [fallback] เสมอ
class AiDiagnosisEngine implements DiagnosisEngine {
  AiDiagnosisEngine({required this.endpoint, required this.fallback});

  final Uri endpoint;
  final DiagnosisEngine fallback;

  @override
  String get name => 'AI (ยังไม่เปิดใช้ ใช้${fallback.name}แทน)';

  @override
  Future<DiagnosisReport> analyze(VehicleSnapshot snapshot) async {
    // TODO(phase-2): เรียก backend แล้วรวมผลกับ fallback
    return fallback.analyze(snapshot);
  }
}
