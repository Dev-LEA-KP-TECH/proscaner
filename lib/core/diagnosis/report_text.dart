import '../obd/pids.dart';
import 'diagnosis.dart';

/// รายงานผลตรวจแบบข้อความ สำหรับคัดลอกไปส่งทาง LINE / อีเมล
String buildReportText(DiagnosisReport r, {String appName = 'ProScaner'}) {
  final s = r.snapshot;
  String two(int n) => n.toString().padLeft(2, '0');
  final t = s.time;
  final b = StringBuffer()
    ..writeln('รายงานตรวจสภาพรถ · $appName')
    ..writeln('วันที่ ${two(t.day)}/${two(t.month)}/${t.year + 543} ${two(t.hour)}:${two(t.minute)}')
    ..writeln(s.vin != null ? 'VIN ${s.vin}' : 'VIN: อ่านไม่ได้')
    ..writeln('')
    ..writeln('สรุป: ${r.headlineTh} (คะแนน ${r.healthScore}/100)')
    ..writeln('ไฟเตือนเครื่องยนต์: ${s.milOn ? 'ติด' : 'ดับ'}')
    ..writeln('พร้อมตรวจสภาพ: ${s.readiness.isEmpty ? 'ไม่ทราบ' : (s.inspectionReady ? 'พร้อม' : 'ยังไม่พร้อม')}');

  if (s.dtcs.isNotEmpty) {
    b
      ..writeln('')
      ..writeln('รหัสปัญหา');
    for (final code in s.codes) {
      final kinds = s.dtcs.where((d) => d.code == code).map((d) => d.kind.labelTh).toSet().join('/');
      final f = r.findings.where((x) => x.code == code).firstOrNull;
      b.writeln('• $code ($kinds) ${f?.title ?? ''}');
    }
  }

  b
    ..writeln('')
    ..writeln('ผลวิเคราะห์');
  for (final f in r.findings) {
    b.writeln('• [${f.severity.labelTh}] ${f.title}');
    for (final e in f.evidence.take(2)) {
      b.writeln('   - $e');
    }
    if (f.causes.isNotEmpty) b.writeln('   สาเหตุที่เป็นไปได้: ${f.causes.take(3).join(', ')}');
  }

  final keyPids = [Pid.rpm, Pid.coolantTemp, Pid.moduleVoltage, Pid.ltftB1, Pid.engineLoad];
  final lines = [
    for (final p in keyPids)
      if (s.pids[p] != null) '${pidTable[p]!.nameTh} ${pidTable[p]!.format(s.pids[p]!)}',
  ];
  if (lines.isNotEmpty) {
    b
      ..writeln('')
      ..writeln('ค่าเซ็นเซอร์ขณะตรวจ')
      ..writeln(lines.map((l) => '• $l').join('\n'));
  }
  b
    ..writeln('')
    ..writeln('* ผลเป็นแนวทางเบื้องต้น ควรให้ช่างยืนยันก่อนเปลี่ยนอะไหล่');
  return b.toString();
}
