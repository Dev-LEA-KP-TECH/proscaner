/// ด่านอ่านอย่างเดียว: ตรวจทุกคำสั่งก่อนส่งออกจากแอปไปตัวสแกน/รถ
///
/// แอปส่งให้รถได้เฉพาะคำสั่งอ่านค่า คำสั่งที่เขียนข้อมูล รีเซ็ตกล่อง สั่งอุปกรณ์ทำงาน
/// หรือเข้าโหมดพิเศษจะไม่ถูกส่งเลย ไม่ว่าจะมาจากชุดค่าที่นำเข้า เทอร์มินัล หรือโค้ดส่วนไหนของแอป
/// ส่วนคำสั่งลบรหัสปัญหาส่งได้เฉพาะจากปุ่มลบรหัส (ดู Elm327.allowClearing)
library;

/// ชนิดของคำสั่ง
enum CommandKind {
  /// คำสั่งตั้งค่าตัวสแกน (AT/ST) ไม่ได้ส่งถึงกล่องในรถ
  adapter,

  /// คำสั่งอ่านค่า
  read,

  /// คำสั่งลบรหัสปัญหา (ส่งได้เฉพาะจากปุ่มลบรหัสที่มีหน้าต่างยืนยัน)
  clear,

  /// คำสั่งที่เปลี่ยนแปลงกล่องหรือสั่งให้รถทำงาน แอปไม่ส่ง
  blocked,
}

/// ผลตรวจคำสั่งหนึ่งคำสั่ง
class CommandCheck {
  const CommandCheck(this.kind, [this.reason]);

  final CommandKind kind;

  /// เหตุผลภาษาไทย (มีเฉพาะคำสั่งลบรหัสและคำสั่งต้องห้าม)
  final String? reason;

  /// ส่งได้ทันทีโดยไม่ต้องขออนุญาตเพิ่ม
  bool get sendable => kind == CommandKind.read || kind == CommandKind.adapter;

  @override
  String toString() => 'CommandCheck(${kind.name}${reason == null ? '' : ', $reason'})';
}

/// บริการอ่านค่าที่ส่งได้ (OBD-II, KWP2000, UDS)
/// 01 02 03 05 06 07 09 0A = OBD-II, 12 13 17 18 1A 21 = KWP2000 อ่านค่า/รหัส,
/// 19 22 = UDS อ่านรหัส/อ่านค่า, 3E = บอกกล่องว่ายังต่ออยู่ (ไม่เปลี่ยนอะไร)
const readServices = <int>{
  0x01, 0x02, 0x03, 0x05, 0x06, 0x07, 0x09, 0x0A, //
  0x12, 0x13, 0x17, 0x18, 0x19, 0x1A, 0x21, 0x22, 0x3E,
};

/// บริการลบรหัสปัญหา: 04 = OBD-II, 14 = UDS/KWP2000
const clearServices = <int>{0x04, 0x14};

final _hex = RegExp(r'^[0-9A-F]+$');

/// ตรวจคำสั่งหนึ่งคำสั่ง (ไม่สนช่องว่างและตัวพิมพ์เล็ก/ใหญ่)
CommandCheck checkCommand(String command) {
  final c = command.replaceAll(RegExp(r'\s+'), '').toUpperCase();
  // บรรทัดว่างทำให้ ELM327 ส่งคำสั่งก่อนหน้าซ้ำ (ถ้าคำสั่งก่อนหน้าเป็นการลบรหัสจะลบซ้ำ)
  if (c.isEmpty) return const CommandCheck(CommandKind.blocked, 'คำสั่งว่าง (ตัวสแกนจะส่งคำสั่งก่อนหน้าซ้ำ)');
  if (c.startsWith('AT') || c.startsWith('ST')) return _checkAdapter(c);
  if (c.length < 2 || !_hex.hasMatch(c)) return const CommandCheck(CommandKind.blocked, 'ไม่ใช่คำสั่งที่แอปรู้จัก');
  final sid = int.parse(c.substring(0, 2), radix: 16);
  if (sid == 0x10) {
    // 10 01 / 10 81 = กลับโหมดปกติ (แอปใช้ค้นหากล่อง) โหมดอื่นคือโหมดโปรแกรม/โหมดช่าง
    final sub = c.length >= 4 ? c.substring(2, 4) : '';
    if (sub == '01' || sub == '81') return const CommandCheck(CommandKind.read);
    return const CommandCheck(CommandKind.blocked, 'เข้าโหมดพิเศษของกล่อง (โหมดโปรแกรม/โหมดช่าง)');
  }
  if (readServices.contains(sid)) return const CommandCheck(CommandKind.read);
  if (clearServices.contains(sid)) return const CommandCheck(CommandKind.clear, 'ลบรหัสปัญหา');
  return CommandCheck(CommandKind.blocked, blockedReason(sid));
}

/// เหตุผลภาษาไทยของบริการที่ไม่ใช่การอ่านค่า
String blockedReason(int sid) => switch (sid) {
      0x08 => 'สั่งให้ระบบในรถทำงานหรือทดสอบตัวเอง',
      0x11 => 'สั่งรีเซ็ตกล่อง (เครื่องอาจดับทันที)',
      0x20 || 0x81 || 0x82 || 0x83 || 0x84 || 0x86 || 0x87 => 'เปลี่ยนการสื่อสารของกล่อง',
      0x23 => 'อ่านหน่วยความจำของกล่องโดยตรง (แอปไม่ใช้)',
      0x24 || 0x2A || 0x2C => 'ตั้งค่าการส่งข้อมูลของกล่อง',
      0x27 => 'ปลดล็อกความปลอดภัยของกล่อง',
      0x28 => 'ปิดการสื่อสารของกล่อง',
      0x2E || 0x3B => 'เขียนข้อมูลลงกล่อง',
      0x3D => 'เขียนหน่วยความจำของกล่อง',
      0x2F || 0x30 => 'สั่งอุปกรณ์ทำงาน (หัวฉีด พัดลม วาล์ว ฯลฯ)',
      0x31 || 0x32 || 0x33 || 0x38 || 0x39 => 'สั่งโปรแกรมพิเศษของกล่อง (เช่น ล้างค่าเรียนรู้ เผาเขม่า)',
      0x34 || 0x35 || 0x36 || 0x37 => 'โหลดโปรแกรมเข้าหรือออกจากกล่อง (แฟลช)',
      0x85 => 'ปิดการบันทึกรหัสปัญหาของกล่อง',
      _ => 'คำสั่งที่แอปไม่รู้จัก',
    };

CommandCheck _checkAdapter(String c) {
  // คำสั่งตัวสแกนที่ทำให้ตัวสแกนส่งข้อความของมันเองถึงรถ
  if (c.startsWith('ATWM')) return const CommandCheck(CommandKind.blocked, 'ตั้งข้อความที่ตัวสแกนส่งให้รถเองเป็นระยะ');
  if (c.startsWith('STPX')) return const CommandCheck(CommandKind.blocked, 'ส่งข้อความดิบตรงถึงรถ');
  if (c.startsWith('ATFCSD') && !c.startsWith('ATFCSD30')) {
    return const CommandCheck(CommandKind.blocked, 'ตั้งข้อความควบคุมการรับข้อมูลที่ไม่ใช่แบบมาตรฐาน');
  }
  // ปิดการจัดรูปแบบอัตโนมัติ: ข้อความที่ส่งจะกลายเป็นเฟรมดิบ แอปตรวจคำสั่งไม่ได้
  if (c == 'ATCAF0') return const CommandCheck(CommandKind.blocked, 'ปิดการจัดรูปแบบอัตโนมัติ (ทำให้ตรวจคำสั่งไม่ได้)');
  return const CommandCheck(CommandKind.adapter);
}

/// คำสั่งตัวสแกนที่พิมพ์เองในหน้าเทอร์มินัลได้ (ดูข้อมูลอย่างเดียว ไม่เปลี่ยนการตั้งค่าที่แอปใช้อยู่)
const terminalAdapterCommands = <String>{
  'ATI', 'AT@1', 'AT@2', 'ATRV', 'ATDP', 'ATDPN', 'ATCS', 'ATIGN', 'ATPPS', 'ATRD', 'ATBD', //
  'STI', 'STDI', 'STSN', 'STMFR',
};

/// ตรวจคำสั่งที่พิมพ์ในหน้าเทอร์มินัล คืนข้อความบอกผู้ใช้ถ้าไม่ส่ง หรือ null ถ้าส่งได้
String? terminalRefusal(String command) {
  final c = command.replaceAll(RegExp(r'\s+'), '').toUpperCase();
  if (c.isEmpty) return 'พิมพ์คำสั่งก่อน';
  if (c.startsWith('AT') || c.startsWith('ST')) {
    if (terminalAdapterCommands.contains(c)) return null;
    return 'คำสั่งนี้เปลี่ยนการตั้งค่าตัวสแกนที่แอปใช้อยู่ ถ้าต้องการรีเซ็ตตัวสแกนให้เชื่อมต่อใหม่';
  }
  final check = checkCommand(c);
  return switch (check.kind) {
    CommandKind.read || CommandKind.adapter => null,
    CommandKind.clear => 'ลบรหัสผ่านปุ่ม "ลบรหัส" ในหน้าวินิจฉัย เพื่อให้มีการยืนยันและบันทึกประวัติ',
    CommandKind.blocked => 'ไม่ส่งคำสั่งนี้: ${check.reason} แอปส่งให้รถเฉพาะคำสั่งอ่านค่า',
  };
}
