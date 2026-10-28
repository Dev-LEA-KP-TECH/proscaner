import 'dart:math' as math;

import 'package:flutter/material.dart';

/// เกจวงกลมแบบหน้าปัดรถ (กวาด 270°) พร้อมเส้นขีดและแสงเรือง
class ArcGauge extends StatelessWidget {
  const ArcGauge({
    super.key,
    required this.fraction,
    required this.valueText,
    required this.unit,
    required this.label,
    required this.color,
    this.size = 150,
  });

  /// 0..1 หรือ null = ยังไม่มีค่า
  final double? fraction;
  final String valueText;
  final String unit;
  final String label;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: size,
      height: size,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: fraction ?? 0),
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOutCubic,
        builder: (context, f, _) => CustomPaint(
          painter: _ArcPainter(
            fraction: f,
            color: color,
            track: cs.surfaceContainerHighest,
            tick: cs.onSurfaceVariant.withValues(alpha: 0.35),
          ),
          child: Center(
            child: Padding(
              padding: EdgeInsets.only(top: size * 0.06),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                FittedBox(
                  child: Text(
                    valueText,
                    style: TextStyle(
                      fontSize: size * 0.22,
                      fontWeight: FontWeight.w800,
                      height: 1,
                      color: cs.onSurface,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(unit, style: TextStyle(fontSize: size * 0.085, color: cs.onSurfaceVariant)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _ArcPainter extends CustomPainter {
  _ArcPainter({required this.fraction, required this.color, required this.track, required this.tick});

  final double fraction;
  final Color color;
  final Color track;
  final Color tick;

  static const _start = math.pi * 0.75;
  static const _sweep = math.pi * 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.075;
    final rect = Offset.zero & size;
    final arcRect = rect.deflate(stroke / 2 + size.width * 0.05);
    final center = rect.center;

    canvas.drawArc(
      arcRect,
      _start,
      _sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = track,
    );

    // ขีดบอกระดับ 11 ขีด
    final r1 = arcRect.width / 2 - stroke * 0.9;
    final r2 = r1 - size.width * 0.04;
    final tickPaint = Paint()
      ..color = tick
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i <= 10; i++) {
      final a = _start + _sweep * i / 10;
      final dir = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(center + dir * r1, center + dir * (i % 5 == 0 ? r2 - 3 : r2), tickPaint);
    }

    if (fraction <= 0) return;
    final sweep = _sweep * fraction;
    final shader = SweepGradient(
      startAngle: _start,
      endAngle: _start + _sweep,
      colors: [color.withValues(alpha: 0.55), color],
      transform: const GradientRotation(0),
    ).createShader(arcRect);

    // แสงเรือง
    canvas.drawArc(
      arcRect,
      _start,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke * 1.6
        ..strokeCap = StrokeCap.round
        ..color = color.withValues(alpha: 0.22)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );
    canvas.drawArc(
      arcRect,
      _start,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..shader = shader,
    );

    // จุดปลายเข็ม
    final a = _start + sweep;
    final tip = center + Offset(math.cos(a), math.sin(a)) * (arcRect.width / 2);
    canvas.drawCircle(tip, stroke * 0.42, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_ArcPainter old) =>
      old.fraction != fraction || old.color != color || old.track != track;
}

/// วงแหวนคะแนนสุขภาพรถ 0–100
class ScoreRing extends StatelessWidget {
  const ScoreRing({super.key, required this.score, required this.color, this.size = 116});

  final int score;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: size,
      height: size,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: score / 100),
        duration: const Duration(milliseconds: 900),
        curve: Curves.easeOutCubic,
        builder: (context, f, _) => CustomPaint(
          painter: _RingPainter(f, color, cs.surfaceContainerHighest),
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(
                '${(f * 100).round()}',
                style: TextStyle(fontSize: size * 0.3, fontWeight: FontWeight.w900, height: 1, color: cs.onSurface),
              ),
              Text('คะแนน', style: TextStyle(fontSize: size * 0.1, color: cs.onSurfaceVariant)),
            ]),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.fraction, this.color, this.track);

  final double fraction;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.09;
    final rect = (Offset.zero & size).deflate(stroke / 2 + 4);
    canvas.drawArc(rect, 0, math.pi * 2, false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..color = track);
    if (fraction <= 0) return;
    canvas.drawArc(rect, -math.pi / 2, math.pi * 2 * fraction, false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke * 1.8
          ..strokeCap = StrokeCap.round
          ..color = color.withValues(alpha: 0.25)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10));
    canvas.drawArc(rect, -math.pi / 2, math.pi * 2 * fraction, false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round
          ..color = color);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.fraction != fraction || old.color != color;
}

/// กราฟเส้นเล็ก (sparkline) หรือกราฟเต็มเมื่อ [showAxis] = true
class Sparkline extends StatelessWidget {
  const Sparkline({
    super.key,
    required this.values,
    required this.color,
    this.height = 32,
    this.showAxis = false,
    this.decimals = 0,
  });

  final List<double> values;
  final Color color;
  final double height;
  final bool showAxis;
  final int decimals;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: height,
      child: CustomPaint(
        size: Size.infinite,
        painter: _SparkPainter(values, color, showAxis ? cs.outline : null, cs.onSurfaceVariant, decimals,
            DefaultTextStyle.of(context).style.fontFamily),
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  _SparkPainter(this.values, this.color, this.grid, this.label, this.decimals, this.fontFamily);

  final List<double> values;
  final Color color;
  final Color? grid;
  final Color label;
  final int decimals;
  final String? fontFamily;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    var lo = values.reduce(math.min);
    var hi = values.reduce(math.max);
    if (hi - lo < 1e-6) {
      lo -= 1;
      hi += 1;
    }
    final pad = (hi - lo) * 0.12;
    lo -= pad;
    hi += pad;
    final left = grid != null ? 44.0 : 0.0;
    final w = size.width - left;
    final h = size.height;
    Offset pt(int i) => Offset(left + w * i / (values.length - 1), h - (values[i] - lo) / (hi - lo) * h);

    final g = grid;
    if (g != null) {
      final gp = Paint()
        ..color = g
        ..strokeWidth = 1;
      for (var i = 0; i <= 4; i++) {
        final y = h * i / 4;
        canvas.drawLine(Offset(left, y), Offset(size.width, y), gp);
        final v = hi - (hi - lo) * i / 4;
        final tp = TextPainter(
          text: TextSpan(text: v.toStringAsFixed(decimals), style: TextStyle(fontSize: 10, color: label, fontFamily: fontFamily)),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: left - 6);
        tp.paint(canvas, Offset(0, (y - tp.height / 2).clamp(0, h - tp.height)));
      }
    }

    final path = Path()..moveTo(pt(0).dx, pt(0).dy);
    for (var i = 1; i < values.length; i++) {
      final p0 = pt(i - 1), p1 = pt(i);
      final mx = (p0.dx + p1.dx) / 2;
      path.cubicTo(mx, p0.dy, mx, p1.dy, p1.dx, p1.dy);
    }
    final fill = Path.from(path)
      ..lineTo(pt(values.length - 1).dx, h)
      ..lineTo(left, h)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.32), color.withValues(alpha: 0)],
        ).createShader(Rect.fromLTWH(left, 0, w, h)),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = grid != null ? 2.4 : 1.8
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );
    final last = pt(values.length - 1);
    canvas.drawCircle(last, 3.2, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_SparkPainter old) => true;
}
