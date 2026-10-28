import 'package:flutter/material.dart';

import '../../core/obd/dtc_database.dart';

/// สีและไอคอนตามระดับความรุนแรง (ไม่ใช้สีอย่างเดียว มีไอคอนและข้อความกำกับเสมอ)
extension SeverityStyle on Severity {
  Color color(ColorScheme cs) => switch (this) {
        Severity.info => const Color(0xFF3DA5FF),
        Severity.low => const Color(0xFF22C474),
        Severity.medium => const Color(0xFFFFA824),
        Severity.high => const Color(0xFFFF4D5A),
      };

  IconData get icon => switch (this) {
        Severity.info => Icons.check_circle_outline,
        Severity.low => Icons.info_outline,
        Severity.medium => Icons.build_circle_outlined,
        Severity.high => Icons.dangerous_outlined,
      };
}

class SeverityChip extends StatelessWidget {
  const SeverityChip(this.severity, {super.key});

  final Severity severity;

  @override
  Widget build(BuildContext context) {
    final c = severity.color(Theme.of(context).colorScheme);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: c.withValues(alpha: 0.5)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(severity.icon, size: 14, color: c),
        const SizedBox(width: 4),
        Text(severity.labelTh, style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}
