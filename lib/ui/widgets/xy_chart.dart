import 'dart:math' as math;

import 'package:flutter/material.dart';

/// เส้น/จุดหนึ่งชุดในกราฟ X-Y
class XySeries {
  const XySeries({required this.label, required this.points, required this.color, this.dots = true, this.line = true});

  final String label;

  /// (x, y) เรียงตาม x ถ้าจะลากเส้น
  final List<(double, double)> points;
  final Color color;
  final bool dots;
  final bool line;
}

/// กราฟ X-Y เช่น บูสต์ตามรอบเครื่อง (แกนนอนไม่ใช่เวลา)
class XyChart extends StatelessWidget {
  const XyChart({
    super.key,
    required this.series,
    this.height = 220,
    this.xUnit = '',
    this.yUnit = '',
    this.xDecimals = 0,
    this.yDecimals = 0,
  });

  final List<XySeries> series;
  final double height;
  final String xUnit;
  final String yUnit;
  final int xDecimals;
  final int yDecimals;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final font = DefaultTextStyle.of(context).style.fontFamily;
    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, box) => CustomPaint(
          size: Size(box.maxWidth, height),
          painter: XyPainter(
            series: series,
            grid: cs.outline,
            label: cs.onSurfaceVariant,
            fontFamily: font,
            xUnit: xUnit,
            yUnit: yUnit,
            xDecimals: xDecimals,
            yDecimals: yDecimals,
          ),
        ),
      ),
    );
  }
}

/// ตัววาดกราฟ X-Y (ใช้ทั้งบนจอและในรายงาน PDF)
class XyPainter extends CustomPainter {
  XyPainter({
    required this.series,
    required this.grid,
    required this.label,
    this.fontFamily,
    this.xUnit = '',
    this.yUnit = '',
    this.xDecimals = 0,
    this.yDecimals = 0,
    this.fontSize = 10,
    this.emptyText = 'ไม่มีข้อมูลพอสำหรับกราฟ',
  });

  final List<XySeries> series;
  final Color grid;
  final Color label;
  final String? fontFamily;
  final String xUnit;
  final String yUnit;
  final int xDecimals;
  final int yDecimals;
  final double fontSize;
  final String emptyText;

  TextPainter _tp(String s, Color c, {double? size}) => TextPainter(
        text: TextSpan(text: s, style: TextStyle(fontSize: size ?? fontSize, color: c, fontFamily: fontFamily)),
        textDirection: TextDirection.ltr,
      )..layout();

  @override
  void paint(Canvas canvas, Size size) {
    final all = [for (final s in series) ...s.points];
    if (all.length < 2) {
      final tp = _tp(emptyText, label, size: fontSize + 2);
      tp.paint(canvas, Offset((size.width - tp.width) / 2, (size.height - tp.height) / 2));
      return;
    }
    var x0 = all.map((p) => p.$1).reduce(math.min);
    var x1 = all.map((p) => p.$1).reduce(math.max);
    var y0 = all.map((p) => p.$2).reduce(math.min);
    var y1 = all.map((p) => p.$2).reduce(math.max);
    if (x1 - x0 < 1e-6) {
      x0 -= 1;
      x1 += 1;
    }
    if (y1 - y0 < 1e-6) {
      y0 -= 1;
      y1 += 1;
    }
    final pad = (y1 - y0) * 0.08;
    y0 -= pad;
    y1 += pad;
    final left = fontSize * 4.6;
    final bottom = fontSize * 2.0;
    final w = size.width - left - 4;
    final h = size.height - bottom;
    double x(double v) => left + (v - x0) / (x1 - x0) * w;
    double y(double v) => h - (v - y0) / (y1 - y0) * h;

    final gp = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final yy = h * i / 4;
      canvas.drawLine(Offset(left, yy), Offset(size.width - 4, yy), gp);
      final v = y1 - (y1 - y0) * i / 4;
      final tp = _tp(v.toStringAsFixed(yDecimals), label);
      tp.paint(canvas, Offset(left - 6 - tp.width, (yy - tp.height / 2).clamp(0, h - tp.height)));
    }
    for (var i = 0; i <= 4; i++) {
      final v = x0 + (x1 - x0) * i / 4;
      final xx = left + w * i / 4;
      canvas.drawLine(Offset(xx, 0), Offset(xx, h), gp..color = grid.withValues(alpha: 0.5));
      final text = i == 4 && xUnit.isNotEmpty ? '${v.toStringAsFixed(xDecimals)} $xUnit' : v.toStringAsFixed(xDecimals);
      final tp = _tp(text, label);
      tp.paint(canvas, Offset((xx - tp.width / 2).clamp(left, size.width - tp.width), h + 4));
    }
    if (yUnit.isNotEmpty) {
      final tp = _tp(yUnit, label);
      tp.paint(canvas, Offset(left + 4, 2));
    }

    for (final s in series) {
      if (s.points.isEmpty) continue;
      if (s.line && s.points.length >= 2) {
        final path = Path()..moveTo(x(s.points.first.$1), y(s.points.first.$2));
        for (final p in s.points.skip(1)) {
          path.lineTo(x(p.$1), y(p.$2));
        }
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.2
            ..strokeJoin = StrokeJoin.round
            ..color = s.color,
        );
      }
      if (s.dots) {
        final dot = Paint()..color = s.color.withValues(alpha: s.line ? 1 : 0.55);
        final r = s.line ? 3.0 : 2.2;
        for (final p in s.points) {
          canvas.drawCircle(Offset(x(p.$1), y(p.$2)), r, dot);
        }
      }
    }
  }

  @override
  bool shouldRepaint(XyPainter old) => true;
}
