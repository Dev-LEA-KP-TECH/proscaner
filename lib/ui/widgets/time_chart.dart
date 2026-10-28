import 'dart:math' as math;

import 'package:flutter/material.dart';

/// เส้นข้อมูลหนึ่งเส้นในกราฟเวลา
class ChartSeries {
  const ChartSeries({required this.label, required this.points, required this.color, this.decimals = 1});

  final String label;
  final List<(double, double)> points; // (เวลา วินาที, ค่า)
  final Color color;
  final int decimals;
}

/// กราฟเส้นตามเวลา มีแกน ตาราง และเส้นเล็งค่า (แตะ/ลากเพื่อดูค่า)
class TimeChart extends StatefulWidget {
  const TimeChart({super.key, required this.series, this.height = 220, this.unit = ''});

  final List<ChartSeries> series;
  final double height;
  final String unit;

  @override
  State<TimeChart> createState() => _TimeChartState();
}

class _TimeChartState extends State<TimeChart> {
  double? _cursorX;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final font = DefaultTextStyle.of(context).style.fontFamily;
    return SizedBox(
      height: widget.height,
      child: LayoutBuilder(builder: (context, box) {
        void set(Offset p) => setState(() => _cursorX = p.dx.clamp(0, box.maxWidth));
        return GestureDetector(
          onTapDown: (d) => set(d.localPosition),
          onHorizontalDragStart: (d) => set(d.localPosition),
          onHorizontalDragUpdate: (d) => set(d.localPosition),
          onDoubleTap: () => setState(() => _cursorX = null),
          child: CustomPaint(
            size: Size(box.maxWidth, widget.height),
            painter: _TimePainter(
              series: widget.series,
              grid: cs.outline,
              label: cs.onSurfaceVariant,
              cursorX: _cursorX,
              fontFamily: font,
              surface: cs.surfaceContainerHighest,
              text: cs.onSurface,
            ),
          ),
        );
      }),
    );
  }
}

class _TimePainter extends CustomPainter {
  _TimePainter({
    required this.series,
    required this.grid,
    required this.label,
    required this.cursorX,
    required this.fontFamily,
    required this.surface,
    required this.text,
  });

  final List<ChartSeries> series;
  final Color grid;
  final Color label;
  final double? cursorX;
  final String? fontFamily;
  final Color surface;
  final Color text;

  static const left = 46.0;
  static const bottom = 20.0;

  TextPainter _tp(String s, Color c, {double size = 10, FontWeight w = FontWeight.w400}) => TextPainter(
        text: TextSpan(text: s, style: TextStyle(fontSize: size, color: c, fontFamily: fontFamily, fontWeight: w)),
        textDirection: TextDirection.ltr,
      )..layout();

  @override
  void paint(Canvas canvas, Size size) {
    final all = [for (final s in series) ...s.points];
    if (all.length < 2) {
      final tp = _tp('ไม่มีข้อมูลพอสำหรับกราฟ', label, size: 12);
      tp.paint(canvas, Offset((size.width - tp.width) / 2, (size.height - tp.height) / 2));
      return;
    }
    var t0 = all.map((p) => p.$1).reduce(math.min);
    var t1 = all.map((p) => p.$1).reduce(math.max);
    var lo = all.map((p) => p.$2).reduce(math.min);
    var hi = all.map((p) => p.$2).reduce(math.max);
    if (t1 - t0 < 1e-6) t1 = t0 + 1;
    if (hi - lo < 1e-6) {
      lo -= 1;
      hi += 1;
    }
    final pad = (hi - lo) * 0.08;
    lo -= pad;
    hi += pad;
    final w = size.width - left;
    final h = size.height - bottom;
    double x(double t) => left + (t - t0) / (t1 - t0) * w;
    double y(double v) => h - (v - lo) / (hi - lo) * h;

    final gp = Paint()
      ..color = grid
      ..strokeWidth = 1;
    final step = (hi - lo) / 4;
    final dec = math.max(series.first.decimals, step >= 1 ? 0 : (step >= 0.1 ? 1 : 2));
    for (var i = 0; i <= 4; i++) {
      final yy = h * i / 4;
      canvas.drawLine(Offset(left, yy), Offset(size.width, yy), gp);
      final v = hi - (hi - lo) * i / 4;
      final tp = _tp(v.toStringAsFixed(dec), label);
      tp.paint(canvas, Offset(left - 6 - tp.width, (yy - tp.height / 2).clamp(0, h - tp.height)));
    }
    for (var i = 0; i <= 4; i++) {
      final t = t0 + (t1 - t0) * i / 4;
      final tp = _tp(_fmtT(t), label);
      final xx = left + w * i / 4;
      tp.paint(canvas, Offset((xx - tp.width / 2).clamp(left, size.width - tp.width), h + 4));
    }

    for (final s in series) {
      if (s.points.length < 2) continue;
      final path = Path()..moveTo(x(s.points.first.$1), y(s.points.first.$2));
      // ลดจำนวนจุดเมื่อข้อมูลยาวมาก ให้วาดเร็ว
      final step = math.max(1, s.points.length ~/ (w * 1.5).round());
      for (var i = step; i < s.points.length; i += step) {
        path.lineTo(x(s.points[i].$1), y(s.points[i].$2));
      }
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeJoin = StrokeJoin.round
          ..color = s.color,
      );
    }

    final cx = cursorX;
    if (cx != null && cx >= left) {
      final t = t0 + (cx - left) / w * (t1 - t0);
      canvas.drawLine(Offset(cx, 0), Offset(cx, h), Paint()
        ..color = text.withValues(alpha: 0.6)
        ..strokeWidth = 1);
      final lines = <TextPainter>[_tp(_fmtT(t), text, size: 11, w: FontWeight.w700)];
      for (final s in series) {
        final v = _valueAt(s.points, t);
        if (v == null) continue;
        canvas.drawCircle(Offset(cx, y(v)), 4, Paint()..color = s.color);
        lines.add(_tp('${s.label}: ${v.toStringAsFixed(s.decimals)}', s.color, size: 11, w: FontWeight.w700));
      }
      final bw = lines.map((l) => l.width).reduce(math.max) + 16;
      final bh = lines.fold<double>(0, (a, l) => a + l.height) + 10;
      var bx = cx + 10;
      if (bx + bw > size.width) bx = cx - 10 - bw;
      final r = RRect.fromRectAndRadius(Rect.fromLTWH(bx, 4, bw, bh), const Radius.circular(8));
      canvas.drawRRect(r, Paint()..color = surface.withValues(alpha: 0.95));
      var yy = 9.0;
      for (final l in lines) {
        l.paint(canvas, Offset(bx + 8, yy));
        yy += l.height;
      }
    }
  }

  static double? _valueAt(List<(double, double)> pts, double t) {
    if (pts.isEmpty) return null;
    if (t <= pts.first.$1) return pts.first.$2;
    if (t >= pts.last.$1) return pts.last.$2;
    var lo = 0, hi = pts.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (pts[mid].$1 <= t) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final a = pts[lo], b = pts[hi];
    final f = b.$1 == a.$1 ? 0 : (t - a.$1) / (b.$1 - a.$1);
    return a.$2 + (b.$2 - a.$2) * f;
  }

  static String _fmtT(double s) {
    if (s < 120) return '${s.toStringAsFixed(s < 10 ? 1 : 0)}\u00A0วิ';
    final m = s ~/ 60;
    final r = (s % 60).round();
    return '$m:${r.toString().padLeft(2, '0')}';
  }

  @override
  bool shouldRepaint(_TimePainter old) => true;
}
