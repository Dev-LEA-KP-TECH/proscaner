import 'dart:math' as math;

import 'ext_pid.dart';
import 'formula.dart';

/// สูตรที่หาได้จากจุดเทียบ
class FitCandidate {
  const FitCandidate({
    required this.formula,
    required this.maxError,
    required this.meanError,
    required this.tolerance,
    required this.bytesUsed,
  });

  final String formula;
  final double maxError;
  final double meanError;
  final double tolerance;

  /// ไบต์ที่ใช้ (A = 0)
  final List<int> bytesUsed;

  /// ตรงกับทุกจุดภายในความคลาดเคลื่อนที่ยอมรับ
  bool get fits => maxError <= tolerance;
}

class _Raw {
  const _Raw(this.expr, this.bytes, this.eval, this.complexity);
  final String expr;
  final List<int> bytes;
  final double Function(List<int> b) eval;
  final int complexity;
}

String _letter(int i) => i < 26 ? String.fromCharCode(65 + i) : '${String.fromCharCode(64 + i ~/ 26)}${String.fromCharCode(65 + i % 26)}';

/// หาสูตรเชิงเส้น (ค่า = ไบต์ × a + b) ที่ตรงกับจุดเทียบมากที่สุด
/// ลองทั้งไบต์เดี่ยว ไบต์มีเครื่องหมาย และ 16 บิต (ทั้งเรียงปกติและสลับ)
class FormulaFit {
  static const _denoms = <int>[
    1, 2, 4, 5, 8, 10, 16, 20, 25, 32, 40, 50, 64, 80, 100, 128, 160, 200, 250, 255, 256, 320, 400, 500, 512,
    1000, 1024, 2000, 2048, 4096, 8192, 10000, 32768, 65535, 65536,
  ];

  /// ความคลาดเคลื่อนที่ยอมรับ: ครึ่งหนึ่งของความละเอียดที่เครื่องมือศูนย์แสดง หรือ 1% ของช่วงค่า
  static double toleranceFor(List<double> refs) {
    var decimals = 0;
    for (final r in refs) {
      final s = r.toString();
      final dot = s.indexOf('.');
      if (dot >= 0) {
        final frac = s.substring(dot + 1).replaceAll(RegExp(r'0+$'), '');
        decimals = math.max(decimals, frac.length.clamp(0, 4));
      }
    }
    final res = math.pow(10, -decimals).toDouble();
    final span = refs.reduce(math.max) - refs.reduce(math.min);
    return math.max(res * 0.6, span * 0.003);
  }

  static List<_Raw> _raws(int len) {
    final out = <_Raw>[];
    for (var i = 0; i < len; i++) {
      final a = _letter(i);
      out.add(_Raw(a, [i], (b) => b[i].toDouble(), 1));
      out.add(_Raw('S($a)', [i], (b) => (b[i] >= 128 ? b[i] - 256 : b[i]).toDouble(), 3));
    }
    for (var i = 0; i + 1 < len; i++) {
      final a = _letter(i), c = _letter(i + 1);
      out.add(_Raw('($a*256+$c)', [i, i + 1], (b) => (b[i] * 256 + b[i + 1]).toDouble(), 2));
      out.add(_Raw('S16($a,$c)', [i, i + 1], (b) {
        final x = b[i] * 256 + b[i + 1];
        return (x >= 0x8000 ? x - 0x10000 : x).toDouble();
      }, 3));
      out.add(_Raw('($c*256+$a)', [i, i + 1], (b) => (b[i + 1] * 256 + b[i]).toDouble(), 4));
    }
    return out;
  }

  static int _gcd(int a, int b) {
    while (b != 0) {
      final t = a % b;
      a = b;
      b = t;
    }
    return a == 0 ? 1 : a;
  }

  static String _num(double v) {
    if ((v - v.roundToDouble()).abs() < 1e-9) return v.round().toString();
    var s = v.toStringAsFixed(6);
    s = s.replaceAll(RegExp(r'0+$'), '');
    if (s.endsWith('.')) s = s.substring(0, s.length - 1);
    return s;
  }

  static String _compose(String raw, int p, int q, double b) {
    var e = raw;
    if (p != 1) e = '$e*$p';
    if (q != 1) e = '$e/$q';
    if (b.abs() > 1e-9) e = '$e${b > 0 ? '+' : '-'}${_num(b.abs())}';
    return e;
  }

  static String _composeFloat(String raw, double a, double b) {
    var e = raw;
    if ((a - 1).abs() > 1e-12) e = '$e*${_num(a)}';
    if (b.abs() > 1e-9) e = '$e${b > 0 ? '+' : '-'}${_num(b.abs())}';
    return e;
  }

  /// คืนสูตรที่เป็นไปได้ เรียงจากเหมาะที่สุด (อย่างมาก [limit] สูตร)
  static List<FitCandidate> fit(List<CalPoint> points, {int limit = 6, int maxBytes = 40}) {
    if (points.length < 2) return const [];
    final ys = points.map((p) => p.ref).toList();
    if (ys.reduce(math.max) - ys.reduce(math.min) <= 0) return const [];
    final len = math.min(points.map((p) => p.raw.length).reduce(math.min), maxBytes);
    if (len == 0) return const [];
    final tol = toleranceFor(ys);
    final scored = <(FitCandidate, double)>[];
    for (final r in _raws(len)) {
      final xs = [for (final p in points) r.eval(p.raw)];
      final mx = xs.reduce((a, b) => a + b) / xs.length;
      final my = ys.reduce((a, b) => a + b) / ys.length;
      var sxx = 0.0, sxy = 0.0;
      for (var i = 0; i < xs.length; i++) {
        sxx += (xs[i] - mx) * (xs[i] - mx);
        sxy += (xs[i] - mx) * (ys[i] - my);
      }
      if (sxx <= 0) continue;
      final a = sxy / sxx;
      if (a.abs() < 1e-9) continue;
      // ลองค่าคูณแบบเศษส่วนสวย ๆ ก่อน แล้วค่อยใช้ทศนิยม
      final options = <(String, double, double, int)>[];
      final tried = <String>{};
      for (final q0 in _denoms) {
        final p0 = (a * q0).round();
        if (p0 == 0 || p0.abs() > 100000) continue;
        // ตัดทอนเศษส่วน (4/4 → 1, 50/100 → 1/2)
        final g = _gcd(p0.abs(), q0);
        final p = p0 ~/ g, q = q0 ~/ g;
        if (!tried.add('$p/$q')) continue;
        final aa = p / q;
        if ((aa - a).abs() > 0.03 * a.abs()) continue;
        var b = 0.0;
        for (var i = 0; i < xs.length; i++) {
          b += ys[i] - aa * xs[i];
        }
        b /= xs.length;
        // ปัดค่าบวกให้สวยถ้ายังอยู่ในความคลาดเคลื่อน
        for (final bb in [b.roundToDouble(), (b * 10).roundToDouble() / 10, (b * 100).roundToDouble() / 100, b]) {
          final f = _compose(r.expr, p, q, bb);
          final cx = '$p'.length + '$q'.length + (bb == b.roundToDouble() ? 0 : 2);
          options.add((f, aa, bb, cx));
        }
      }
      var b0 = my - a * mx;
      options.add((_composeFloat(r.expr, a, b0), a, b0, 12));
      for (final (f, aa, bb, cx) in options) {
        var maxE = 0.0, sumE = 0.0;
        for (var i = 0; i < xs.length; i++) {
          final e = (aa * xs[i] + bb - ys[i]).abs();
          maxE = math.max(maxE, e);
          sumE += e;
        }
        final cand = FitCandidate(formula: f, maxError: maxE, meanError: sumE / xs.length, tolerance: tol, bytesUsed: r.bytes);
        // คะแนน: ตรงก่อน (ยิ่งต่างน้อยยิ่งดี) แล้วค่อยเรียบง่าย
        final fitScore = maxE <= tol ? 0.0 : 1 + maxE / tol;
        scored.add((cand, fitScore * 1000 + 40 * (maxE / tol) + cx * 2 + r.complexity));
      }
    }
    scored.sort((x, y) => x.$2.compareTo(y.$2));
    final out = <FitCandidate>[];
    final seen = <String>{};
    for (final (c, _) in scored) {
      if (seen.contains(c.formula)) continue;
      // ตัดสูตรที่ใช้ไบต์เดียวกันซ้ำ (เหลือแบบที่ดีที่สุดของแต่ละชุดไบต์)
      final k = c.bytesUsed.join(',');
      if (out.any((o) => o.bytesUsed.join(',') == k)) continue;
      // ตรวจกับตัวคำนวณจริงอีกชั้น
      try {
        Formula(c.formula);
      } catch (_) {
        continue;
      }
      seen.add(c.formula);
      out.add(c);
      if (out.length >= limit) break;
    }
    return out;
  }

  /// เทียบสูตรปัจจุบันกับจุดเทียบ: คืน (ต่างมากที่สุด, ความคลาดเคลื่อนที่ยอมรับ) หรือ null ถ้าคำนวณไม่ได้
  static (double, double)? check(String formula, List<CalPoint> points) {
    if (points.isEmpty) return null;
    final ys = points.map((p) => p.ref).toList();
    final tol = ys.length < 2 ? toleranceFor([...ys, ys.first]) : toleranceFor(ys);
    try {
      final f = Formula(formula);
      var maxE = 0.0;
      for (final p in points) {
        maxE = math.max(maxE, (f.eval(p.raw) - p.ref).abs());
      }
      return (maxE, math.max(tol, 1e-9));
    } catch (_) {
      return null;
    }
  }
}
