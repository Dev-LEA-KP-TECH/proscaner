import 'dart:math' as math;

import 'ext_pid.dart';
import 'formula.dart';
import 'formula_fit.dart';
import 'pids.dart';

/// ตัวอย่างหนึ่งรอบ: ไบต์ของแต่ละคำสั่ง และค่าดิบของ PID มาตรฐาน ที่อ่านในรอบเดียวกัน
class AutoMatchSample {
  AutoMatchSample({required this.payloads, required this.std, DateTime? at}) : at = at ?? DateTime.now();

  /// cmdKey ของคำสั่ง (ดู [ExtPid.cmdKey]) -> ไบต์ข้อมูลหลังเลขคำสั่ง
  final Map<String, List<int>> payloads;

  /// PID มาตรฐาน (Mode 01) -> ไบต์ข้อมูลหลัง 41 xx
  final Map<int, List<int>> std;
  final DateTime at;
}

/// ชนิดของการจับคู่ (เรียงจากน่าเชื่อถือมากไปน้อย)
enum AutoMatchKind {
  /// เก็บค่าแบบเดียวกับ PID มาตรฐาน (สูตรเดียวกัน) และตรงทุกจุดขณะค่าเปลี่ยน
  sameEncoding,

  /// ค่าเปลี่ยนหลายระดับ และสูตรที่หาได้จากจุดเทียบตรงทุกจุด
  fit,

  /// ไบต์ดิบเท่ากับ PID มาตรฐานทุกรอบ แต่ค่ายังไม่เปลี่ยน (ยังเป็นแค่ข้อสันนิษฐาน)
  sameRaw,
}

/// คำแนะนำว่าคำสั่งหนึ่งน่าจะเป็นค่ามาตรฐานตัวไหน พร้อมสูตร
class AutoMatchSuggestion {
  const AutoMatchSuggestion({
    required this.cmdKey,
    required this.pid,
    required this.formula,
    required this.kind,
    required this.points,
    required this.maxError,
    required this.calPoints,
  });

  final String cmdKey;

  /// PID มาตรฐานที่ตรงกัน
  final int pid;
  final String formula;
  final AutoMatchKind kind;

  /// จำนวนค่าที่ต่างกันที่ใช้ยืนยัน
  final int points;
  final double maxError;

  /// จุดเทียบสำหรับบันทึกเป็นหลักฐาน (ไม่เกิน 5 จุด เลือกค่าที่ต่างกัน)
  final List<CalPoint> calPoints;

  PidDef? get def => pidTable[pid];

  /// ยังเป็นแค่ข้อสันนิษฐาน (ค่ายังไม่เปลี่ยน)
  bool get weak => kind == AutoMatchKind.sameRaw;

  String get pidCode => pid.toRadixString(16).padLeft(2, '0').toUpperCase();

  String get note => switch (kind) {
        AutoMatchKind.sameEncoding => 'สูตรเดียวกับ PID $pidCode ตรงทุกจุด ($points ค่าที่ต่างกัน)',
        AutoMatchKind.fit => 'หาสูตรจากจุดเทียบได้ ตรงทุกจุด ($points ค่าที่ต่างกัน)',
        AutoMatchKind.sameRaw => 'ค่าดิบตรงกัน แต่ค่ายังไม่เปลี่ยน ควรติดเครื่อง/เร่งเครื่องให้ค่าเปลี่ยนก่อนยืนยัน',
      };
}

/// จับคู่ค่าที่ค้นพบเอง (คำสั่ง 21/22 ที่ยังไม่รู้ว่าเป็นค่าอะไร) กับค่า OBD มาตรฐานของรถคันเดียวกัน
///
/// อ่านทั้งสองแบบซ้ำหลายรอบขณะค่าเปลี่ยน (ติดเครื่อง เร่งเครื่อง ปล่อยให้เครื่องร้อนขึ้น)
/// แล้วดูว่าไบต์ของคำสั่งไหนเปลี่ยนไปพร้อมกับค่ามาตรฐานตัวไหนด้วยสูตรเชิงเส้นที่ตรงทุกจุด
/// ใช้ค่ามาตรฐานของรถคันนั้นเองเป็น "เครื่องมือเทียบ" แทนเครื่องมือศูนย์
class AutoMatcher {
  AutoMatcher({this.maxSamples = 40});

  /// เก็บตัวอย่างล่าสุดไม่เกินจำนวนนี้ (ให้คำนวณเร็วพอทุกรอบ)
  final int maxSamples;
  final List<AutoMatchSample> samples = [];

  void add(AutoMatchSample s) {
    samples.add(s);
    if (samples.length > maxSamples) samples.removeRange(0, samples.length - maxSamples);
  }

  void clear() => samples.clear();

  /// สูตรของ PID มาตรฐาน (เขียนแบบสูตรของแอป) ใช้ตรวจว่ากล่องเก็บค่าแบบเดียวกันหรือไม่
  static const stdFormulas = <int, String>{
    0x04: 'A*100/255',
    0x05: 'A-40',
    0x0A: 'A*3',
    0x0B: 'A',
    0x0C: '(A*256+B)/4',
    0x0D: 'A',
    0x0E: 'A/2-64',
    0x0F: 'A-40',
    0x10: '(A*256+B)/100',
    0x11: 'A*100/255',
    0x1F: '(A*256+B)',
    0x23: '(A*256+B)*10',
    0x2C: 'A*100/255',
    0x2D: 'A*100/128-100',
    0x33: 'A',
    0x42: '(A*256+B)/1000',
    0x46: 'A-40',
    0x5C: 'A-40',
    0x5E: '(A*256+B)/20',
  };

  /// ไบต์ยาวเกินนี้ไม่หาสูตรใหม่ (คำสั่งที่มีหลายค่าในคำตอบเดียว ให้เทียบทีละค่าในหน้ารายละเอียดแทน)
  static const _maxFitBytes = 8;

  /// คำแนะนำของคำสั่งหนึ่ง เรียงจากน่าเชื่อถือที่สุด
  List<AutoMatchSuggestion> suggestionsFor(String cmdKey) {
    final stdPids = <int>{for (final s in samples) ...s.std.keys};
    final out = <AutoMatchSuggestion>[];
    for (final pid in stdPids) {
      final def = pidTable[pid];
      if (def == null) continue;
      final s = _suggest(cmdKey, pid, def);
      if (s != null) out.add(s);
    }
    out.sort(_compare);
    return out;
  }

  /// คำแนะนำที่ดีที่สุดของคำสั่งหนึ่ง (null = ยังจับคู่ไม่ได้)
  AutoMatchSuggestion? best(String cmdKey) {
    final all = suggestionsFor(cmdKey);
    return all.isEmpty ? null : all.first;
  }

  static int _compare(AutoMatchSuggestion a, AutoMatchSuggestion b) {
    // แบบที่ค่าเปลี่ยนแล้ว (ยืนยันได้) มาก่อนแบบค่าดิบตรงกันเฉย ๆ
    // แล้วสูตรเดียวกับ PID มาตรฐานมาก่อนสูตรที่หาเอง และยิ่งมีค่าที่ต่างกันมากยิ่งน่าเชื่อ
    final w = (a.weak ? 1 : 0).compareTo(b.weak ? 1 : 0);
    if (w != 0) return w;
    final k = a.kind.index.compareTo(b.kind.index);
    if (k != 0) return k;
    final p = b.points.compareTo(a.points);
    if (p != 0) return p;
    return a.pid.compareTo(b.pid);
  }

  AutoMatchSuggestion? _suggest(String cmdKey, int pid, PidDef def) {
    final payloads = <List<int>>[];
    final refs = <double>[];
    final stdRaws = <List<int>>[];
    final times = <DateTime>[];
    for (final s in samples) {
      final p = s.payloads[cmdKey];
      final r = s.std[pid];
      if (p == null || r == null || p.isEmpty || r.length < def.bytes) continue;
      final double v;
      try {
        v = def.decode(r);
      } catch (_) {
        continue;
      }
      if (v.isNaN || v.isInfinite) continue;
      payloads.add(p);
      refs.add(v);
      stdRaws.add(r);
      times.add(s.at);
    }
    if (payloads.length < 2) return null;
    final points = [for (var i = 0; i < payloads.length; i++) CalPoint(raw: List.of(payloads[i]), ref: refs[i], at: times[i])];
    final distinctRefs = refs.map((v) => v.toStringAsFixed(4)).toSet().length;
    final distinctRaw = payloads.map((p) => bytesToHex(p, sep: '')).toSet().length;
    final formula = stdFormulas[pid];

    if (distinctRefs >= 3 && distinctRaw >= 3) {
      // เผื่อความต่างเล็กน้อยจากจังหวะที่อ่านคนละคำสั่ง (ค่าอย่างรอบเครื่องแกว่งตลอด)
      final span = refs.reduce(math.max) - refs.reduce(math.min);
      final tol = math.max(_resolution(def), span * 0.02);
      // (ก) เก็บค่าแบบเดียวกับ PID มาตรฐาน
      if (formula != null) {
        final err = _maxError(formula, points);
        if (err != null && err <= tol) {
          return AutoMatchSuggestion(
            cmdKey: cmdKey,
            pid: pid,
            formula: formula,
            kind: AutoMatchKind.sameEncoding,
            points: distinctRefs,
            maxError: err,
            calPoints: _evidence(points),
          );
        }
      }
      // (ข) หาสูตรใหม่จากจุดเทียบ (ต้องตรงทุกจุด) กรองคู่ที่ไม่สัมพันธ์กันออกก่อนให้คำนวณเร็ว
      if (payloads.every((p) => p.length <= _maxFitBytes) && _correlated(payloads, refs)) {
        final fits = FormulaFit.fit(points, limit: 6, maxBytes: _maxFitBytes).where((c) => c.maxError <= tol).toList();
        if (fits.isNotEmpty) {
          return AutoMatchSuggestion(
            cmdKey: cmdKey,
            pid: pid,
            formula: fits.first.formula,
            kind: AutoMatchKind.fit,
            points: distinctRefs,
            maxError: fits.first.maxError,
            calPoints: _evidence(points),
          );
        }
      }
      return null;
    }

    // (ค) ค่ายังไม่เปลี่ยน: ไบต์ดิบเท่ากับค่ามาตรฐานทุกรอบ (ไม่นับค่า 00/FF ที่ซ้ำกันได้ง่าย)
    if (formula == null) return null;
    var same = true;
    for (var i = 0; i < payloads.length; i++) {
      if (!_sameBytes(payloads[i], stdRaws[i])) {
        same = false;
        break;
      }
    }
    final trivial = payloads.every((p) => p.every((b) => b == 0x00) || p.every((b) => b == 0xFF));
    if (!same || trivial) return null;
    return AutoMatchSuggestion(
      cmdKey: cmdKey,
      pid: pid,
      formula: formula,
      kind: AutoMatchKind.sameRaw,
      points: distinctRefs,
      maxError: 0,
      calPoints: _evidence(points),
    );
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// ความละเอียดของค่ามาตรฐาน (เช่น ทศนิยม 0 ตำแหน่ง = 1)
  static double _resolution(PidDef def) => math.pow(10, -def.decimals.clamp(0, 4)).toDouble();

  static double? _maxError(String formula, List<CalPoint> points) {
    try {
      final f = Formula(formula);
      var maxE = 0.0;
      for (final p in points) {
        final v = f.eval(p.raw);
        if (v.isNaN || v.isInfinite) return null;
        maxE = math.max(maxE, (v - p.ref).abs());
      }
      return maxE;
    } catch (_) {
      return null;
    }
  }

  /// มีไบต์เดี่ยวหรือไบต์คู่ (16 บิต) ที่เปลี่ยนไปพร้อมกับค่ามาตรฐานแทบเป็นเส้นตรงหรือไม่
  static bool _correlated(List<List<int>> payloads, List<double> refs) {
    final len = payloads.map((p) => p.length).reduce(math.min);
    var best = 0.0;
    double corr(double Function(List<int> b) x) {
      final xs = [for (final p in payloads) x(p)];
      final mx = xs.reduce((a, b) => a + b) / xs.length;
      final my = refs.reduce((a, b) => a + b) / refs.length;
      var sxy = 0.0, sxx = 0.0, syy = 0.0;
      for (var i = 0; i < xs.length; i++) {
        sxy += (xs[i] - mx) * (refs[i] - my);
        sxx += (xs[i] - mx) * (xs[i] - mx);
        syy += (refs[i] - my) * (refs[i] - my);
      }
      if (sxx <= 0 || syy <= 0) return 0;
      return (sxy / math.sqrt(sxx * syy)).abs();
    }

    for (var i = 0; i < len; i++) {
      best = math.max(best, corr((b) => b[i].toDouble()));
      best = math.max(best, corr((b) => (b[i] >= 128 ? b[i] - 256 : b[i]).toDouble()));
      if (i + 1 < len) {
        best = math.max(best, corr((b) => (b[i] * 256 + b[i + 1]).toDouble()));
        best = math.max(best, corr((b) {
          final v = b[i] * 256 + b[i + 1];
          return (v >= 0x8000 ? v - 0x10000 : v).toDouble();
        }));
        best = math.max(best, corr((b) => (b[i + 1] * 256 + b[i]).toDouble()));
      }
      if (best >= 0.97) return true;
    }
    return best >= 0.97;
  }

  /// จุดเทียบสำหรับเก็บเป็นหลักฐาน: ไม่เกิน 5 จุด กระจายตามค่า
  static List<CalPoint> _evidence(List<CalPoint> points) {
    final byRef = <String, CalPoint>{};
    for (final p in points) {
      byRef.putIfAbsent(p.ref.toStringAsFixed(4), () => p);
    }
    final uniq = byRef.values.toList()..sort((a, b) => a.ref.compareTo(b.ref));
    if (uniq.length <= 5) return uniq;
    return [for (var i = 0; i < 5; i++) uniq[(i * (uniq.length - 1) / 4).round()]];
  }
}
