/// แปลงข้อความดิบจาก ELM327 เป็นข้อความต่อ ECU
///
/// รองรับ:
/// - CAN 11 บิต / 29 บิต แบบเปิด header (ATH1) พร้อมประกอบเฟรม ISO-TP หลายเฟรม
/// - โปรโตคอลเก่า (J1850, ISO 9141, KWP) แบบเปิด header ตัด checksum ท้ายบรรทัด
/// - แบบปิด header (ATH0) ทั้งบรรทัดเดียวและรูปแบบ "014 / 0: … / 1: …"
/// - มีหรือไม่มีช่องว่าง, คำว่า SEARCHING..., และข้อความผิดพลาดต่างๆ
library;

class EcuMessage {
  const EcuMessage(this.ecu, this.data);

  /// ที่อยู่ของ ECU ที่ตอบ เช่น 7E8 หรือ 18DAF110 หรือ 10 (ไม่ทราบ = "ECU")
  final String ecu;

  /// ไบต์ข้อมูล เริ่มที่ไบต์ตอบรับของ service เช่น 0x41
  final List<int> data;

  @override
  String toString() => '$ecu: ${data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}';
}

enum ElmError { noData, unableToConnect, busError, canError, stopped, bufferFull, unknownCommand, other }

class ParseResult {
  const ParseResult(this.messages, {this.error, this.errorText});

  final List<EcuMessage> messages;
  final ElmError? error;
  final String? errorText;

  bool get isOk => messages.isNotEmpty;
}

/// ลักษณะ header ที่ใช้แยกบรรทัด
enum HeaderFormat { can11, can29, legacy, none }

class ResponseParser {
  /// แปลงเลขโปรโตคอลจาก ATDPN (เช่น "A6", "6", "3") เป็นรูปแบบ header
  static HeaderFormat headerFormatFor(String? protocol, {bool headersOn = true}) {
    if (!headersOn) return HeaderFormat.none;
    if (protocol == null || protocol.isEmpty) return HeaderFormat.can11;
    final p = protocol.toUpperCase().replaceFirst('A', '');
    final code = p.isEmpty ? '' : p[p.length - 1];
    switch (code) {
      case '6':
      case '8':
      case 'B':
        return HeaderFormat.can11;
      case '7':
      case '9':
      case 'C':
        return HeaderFormat.can29;
      case '1':
      case '2':
      case '3':
      case '4':
      case '5':
        return HeaderFormat.legacy;
      default:
        return HeaderFormat.can11;
    }
  }

  static const _errorMap = <String, ElmError>{
    'NO DATA': ElmError.noData,
    'UNABLE TO CONNECT': ElmError.unableToConnect,
    'BUS ERROR': ElmError.busError,
    'BUS BUSY': ElmError.busError,
    'BUS INIT: ...ERROR': ElmError.busError,
    'CAN ERROR': ElmError.canError,
    'STOPPED': ElmError.stopped,
    'BUFFER FULL': ElmError.bufferFull,
    'DATA ERROR': ElmError.other,
    'FB ERROR': ElmError.busError,
    'ERR': ElmError.other,
    '?': ElmError.unknownCommand,
  };

  static ParseResult parse(String raw, {HeaderFormat format = HeaderFormat.can11}) {
    final lines = raw
        .replaceAll('>', '')
        .split(RegExp(r'[\r\n]+'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    ElmError? error;
    String? errorText;
    final hexLines = <String>[];

    for (final line in lines) {
      final upper = line.toUpperCase();
      if (upper.startsWith('SEARCHING')) continue;
      if (upper.startsWith('BUS INIT') && upper.contains('OK')) continue;
      final compact = upper.replaceAll(' ', '');
      if (RegExp(r'^[0-9A-F]+$').hasMatch(compact) ||
          RegExp(r'^[0-9A-F]:[0-9A-F]+$').hasMatch(compact)) {
        hexLines.add(compact);
        continue;
      }
      // ข้อความผิดพลาด
      for (final e in _errorMap.entries) {
        if (upper.startsWith(e.key) || (e.key.length > 3 && upper.contains(e.key))) {
          error ??= e.value;
          errorText ??= line;
          break;
        }
      }
      if (error == null) {
        // บรรทัดที่อ่านไม่ออก (เช่น echo ที่ยังไม่ปิด) ข้ามไป
        continue;
      }
    }

    final messages = switch (format) {
      HeaderFormat.can11 => _parseCan(hexLines, 3),
      HeaderFormat.can29 => _parseCan(hexLines, 8),
      HeaderFormat.legacy => _parseLegacy(hexLines),
      HeaderFormat.none => _parseNoHeader(hexLines),
    };

    return ParseResult(messages, error: messages.isEmpty ? (error ?? ElmError.noData) : null,
        errorText: messages.isEmpty ? errorText : null);
  }

  static List<int> _bytes(String hex) => [
        for (var i = 0; i + 1 < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)
      ];

  static List<EcuMessage> _parseCan(List<String> lines, int headerLen) {
    final order = <String>[];
    final buffers = <String, List<int>>{};
    final expected = <String, int>{};
    final singles = <EcuMessage>[];

    for (final line in lines) {
      if (line.length <= headerLen || line.contains(':')) continue;
      final header = line.substring(0, headerLen);
      final body = _bytes(line.substring(headerLen));
      if (body.isEmpty) continue;
      final pci = body[0] >> 4;
      switch (pci) {
        case 0x0: // single frame
          final len = body[0] & 0x0F;
          final end = (1 + len).clamp(1, body.length);
          singles.add(EcuMessage(header, body.sublist(1, end)));
          if (!order.contains(header)) order.add(header);
        case 0x1: // first frame
          if (body.length < 2) continue;
          expected[header] = ((body[0] & 0x0F) << 8) | body[1];
          buffers[header] = body.sublist(2);
          if (!order.contains(header)) order.add(header);
        case 0x2: // consecutive frame
          buffers[header]?.addAll(body.sublist(1));
        default: // flow control หรืออื่นๆ ข้ามไป
          break;
      }
    }

    // เรียงตามลำดับ ECU ที่ตอบก่อน
    final out = <EcuMessage>[];
    for (final h in order) {
      out.addAll(singles.where((m) => m.ecu == h));
      final buf = buffers[h];
      if (buf == null) continue;
      final total = expected[h] ?? buf.length;
      out.add(EcuMessage(h, buf.sublist(0, total.clamp(0, buf.length))));
    }
    return out;
  }

  /// J1850 / ISO 9141 / KWP: header 3 ไบต์ (priority, target, source) + ข้อมูล + checksum
  static List<EcuMessage> _parseLegacy(List<String> lines) {
    final out = <EcuMessage>[];
    for (final line in lines) {
      if (line.contains(':')) continue;
      final b = _bytes(line);
      if (b.length < 5) continue;
      final source = b[2].toRadixString(16).padLeft(2, '0').toUpperCase();
      out.add(EcuMessage(source, b.sublist(3, b.length - 1)));
    }
    return out;
  }

  /// ปิด header: ไม่รู้ว่า ECU ไหนตอบ ใช้ชื่อ "ECU"
  static List<EcuMessage> _parseNoHeader(List<String> lines) {
    final out = <EcuMessage>[];
    List<int>? multi;
    int? multiLen;
    for (final line in lines) {
      if (line.contains(':')) {
        multi ??= <int>[];
        multi.addAll(_bytes(line.substring(line.indexOf(':') + 1)));
        continue;
      }
      // บรรทัดยาว 3 ตัวอักษร = จำนวนไบต์ของข้อความหลายเฟรมที่จะตามมา
      if (line.length == 3) {
        if (multi != null) {
          out.add(EcuMessage('ECU', multi.sublist(0, (multiLen ?? multi.length).clamp(0, multi.length))));
        }
        multi = <int>[];
        multiLen = int.parse(line, radix: 16);
        continue;
      }
      out.add(EcuMessage('ECU', _bytes(line)));
    }
    if (multi != null && multi.isNotEmpty) {
      out.add(EcuMessage('ECU', multi.sublist(0, (multiLen ?? multi.length).clamp(0, multi.length))));
    }
    return out;
  }
}
