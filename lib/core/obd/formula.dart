/// ตัวคำนวณสูตรแปลงค่าแบบเดียวกับ Torque / แอป OBD ทั่วไป
///
/// ตัวแปร A, B, C … Z, AA, AB … คือไบต์ข้อมูลตามลำดับ (หลังส่วนตอบรับและเลข PID)
/// รองรับ + - * / % วงเล็บ ลบหน้าตัวเลข และฟังก์ชัน
///   S(x) / Signed(x)  = ไบต์มีเครื่องหมาย (-128..127), S(x, n) = n บิตมีเครื่องหมาย
///   bits(x, s, n)     = บิตที่ s ถึง s+n-1 ของ x (นับจากบิตต่ำสุด)
///   S16(a, b)         = 16 บิตมีเครื่องหมาย (a*256+b)
///   U16(a, b)         = 16 บิตไม่มีเครื่องหมาย
///   {A:3}             = บิตที่ 3 ของ A (0 หรือ 1)
///   min(x, y) max(x, y) abs(x)
class Formula {
  Formula(this.source) : _tokens = _tokenize(source) {
    _pos = 0;
    _ast = _expr();
    if (_pos != _tokens.length) throw FormatException('สูตรมีส่วนเกิน: ${_tokens[_pos]}');
  }

  final String source;
  final List<String> _tokens;
  int _pos = 0;
  late final _Node _ast;

  /// คืนจำนวนไบต์ที่สูตรต้องใช้ (A = 1, B = 2 …)
  int get bytesNeeded => _maxVar + 1;
  int _maxVar = -1;

  double eval(List<int> bytes) => _ast.eval(bytes);

  static bool isValid(String s) {
    try {
      Formula(s);
      return true;
    } catch (_) {
      return false;
    }
  }

  // ---------------- tokenizer ----------------

  static List<String> _tokenize(String s) {
    final out = <String>[];
    var i = 0;
    while (i < s.length) {
      final c = s[i];
      if (c.trim().isEmpty) {
        i++;
        continue;
      }
      if ('+-*/%(),{}:'.contains(c)) {
        out.add(c);
        i++;
        continue;
      }
      final m = RegExp(r'^(0x[0-9A-Fa-f]+|\d+(\.\d+)?([eE][-+]?\d+)?|[A-Za-z][A-Za-z0-9]*)').firstMatch(s.substring(i));
      if (m == null) throw FormatException('อักขระไม่รู้จัก "$c" ในสูตร');
      out.add(m.group(0)!);
      i += m.group(0)!.length;
    }
    if (out.isEmpty) throw const FormatException('สูตรว่าง');
    return out;
  }

  String? get _peek => _pos < _tokens.length ? _tokens[_pos] : null;

  String _take([String? expect]) {
    final t = _peek;
    if (t == null) throw const FormatException('สูตรจบไม่ครบ');
    if (expect != null && t != expect) throw FormatException('ต้องการ "$expect" แต่พบ "$t"');
    _pos++;
    return t;
  }

  // ---------------- parser ----------------

  _Node _expr() {
    var n = _term();
    while (_peek == '+' || _peek == '-') {
      final op = _take();
      final r = _term();
      final l = n;
      n = op == '+' ? _Fn((b) => l.eval(b) + r.eval(b)) : _Fn((b) => l.eval(b) - r.eval(b));
    }
    return n;
  }

  _Node _term() {
    var n = _factor();
    while (_peek == '*' || _peek == '/' || _peek == '%') {
      final op = _take();
      final r = _factor();
      final l = n;
      n = switch (op) {
        '*' => _Fn((b) => l.eval(b) * r.eval(b)),
        '/' => _Fn((b) {
            final d = r.eval(b);
            if (d == 0) throw const FormatException('หารด้วยศูนย์');
            return l.eval(b) / d;
          }),
        _ => _Fn((b) => l.eval(b) % r.eval(b)),
      };
    }
    return n;
  }

  /// แปลงชื่อตัวแปร A..Z, AA..AZ … เป็นลำดับไบต์
  int? _varIndex(String t) {
    if (!RegExp(r'^[A-Z]{1,2}$').hasMatch(t)) return null;
    if (t.length == 1) return t.codeUnitAt(0) - 65;
    return (t.codeUnitAt(0) - 64) * 26 + (t.codeUnitAt(1) - 65);
  }

  _Node _factor() {
    final t = _take();
    if (t == '-') {
      final f = _factor();
      return _Fn((b) => -f.eval(b));
    }
    if (t == '(') {
      final e = _expr();
      _take(')');
      return e;
    }
    if (t == '{') {
      final v = _varIndex(_take());
      if (v == null) throw const FormatException('ใน {A:n} ต้องเป็นตัวแปรไบต์');
      _take(':');
      final bit = int.parse(_take());
      _take('}');
      if (bit < 0 || bit > 7) throw const FormatException('บิตต้องอยู่ระหว่าง 0–7');
      if (v > _maxVar) _maxVar = v;
      return _Fn((b) => ((_byte(b, v) >> bit) & 1).toDouble());
    }
    if (t.startsWith('0x')) {
      final v = int.parse(t.substring(2), radix: 16).toDouble();
      return _Fn((_) => v);
    }
    final num = double.tryParse(t);
    if (num != null) return _Fn((_) => num);
    final v = _varIndex(t);
    if (v != null && _peek != '(') {
      if (v > _maxVar) _maxVar = v;
      return _Fn((b) => _byte(b, v).toDouble());
    }
    // ฟังก์ชัน
    final name = t.toLowerCase();
    _take('(');
    final args = <_Node>[_expr()];
    while (_peek == ',') {
      _take(',');
      args.add(_expr());
    }
    _take(')');
    _Node arg(int i) {
      if (i >= args.length) throw FormatException('ฟังก์ชัน $t ต้องมี ${i + 1} ค่า');
      return args[i];
    }

    switch (name) {
      case 's':
      case 'signed':
        // S(x) = 8 บิตมีเครื่องหมาย, S(x, n) = n บิตมีเครื่องหมาย
        final a = arg(0);
        final nb = args.length > 1 ? args[1] : null;
        return _Fn((b) {
          final n = nb == null ? 8 : nb.eval(b).round();
          if (n < 1 || n > 52) throw const FormatException('จำนวนบิตต้องอยู่ระหว่าง 1–52');
          final full = _pow2(n);
          final x = _mask(a.eval(b), full);
          return x >= full / 2 ? x - full : x;
        });
      case 'bits':
        // bits(x, เลื่อน, ยาว) = ตัดบิตออกมา (เลื่อนนับจากบิตต่ำสุด)
        final a = arg(0), sh = arg(1), ln = arg(2);
        return _Fn((b) {
          final shift = sh.eval(b).round();
          final n = ln.eval(b).round();
          if (shift < 0 || n < 1 || shift + n > 52) throw const FormatException('ช่วงบิตไม่ถูกต้อง');
          final x = a.eval(b).roundToDouble();
          return _mask((x / _pow2(shift)).floorToDouble(), _pow2(n));
        });
      case 's16':
        final a = arg(0), c = arg(1);
        return _Fn((b) {
          final x = ((a.eval(b).round() & 0xFF) << 8) | (c.eval(b).round() & 0xFF);
          return (x >= 0x8000 ? x - 0x10000 : x).toDouble();
        });
      case 'u16':
        final a = arg(0), c = arg(1);
        return _Fn((b) => (((a.eval(b).round() & 0xFF) << 8) | (c.eval(b).round() & 0xFF)).toDouble());
      case 'min':
        final a = arg(0), c = arg(1);
        return _Fn((b) {
          final x = a.eval(b), y = c.eval(b);
          return x < y ? x : y;
        });
      case 'max':
        final a = arg(0), c = arg(1);
        return _Fn((b) {
          final x = a.eval(b), y = c.eval(b);
          return x > y ? x : y;
        });
      case 'abs':
        final a = arg(0);
        return _Fn((b) => a.eval(b).abs());
    }
    throw FormatException('ไม่รู้จักฟังก์ชัน $t');
  }

  static double _pow2(int n) {
    var r = 1.0;
    for (var i = 0; i < n; i++) {
      r *= 2;
    }
    return r;
  }

  /// x mod m สำหรับจำนวนเต็มที่ใหญ่กว่า 32 บิต (ใช้ double เพื่อไม่ให้ล้นบนเว็บ/32 บิต)
  static double _mask(double x, double m) {
    final r = x.roundToDouble() % m;
    return r < 0 ? r + m : r;
  }

  static int _byte(List<int> b, int i) {
    if (i >= b.length) throw RangeError('ข้อมูลมี ${b.length} ไบต์ แต่สูตรใช้ไบต์ที่ ${i + 1}');
    return b[i];
  }
}

abstract class _Node {
  double eval(List<int> b);
}

class _Fn implements _Node {
  _Fn(this.f);
  final double Function(List<int>) f;

  @override
  double eval(List<int> b) => f(b);
}
