import 'package:flutter/material.dart';

import '../../core/analysis/odometer_check.dart';
import '../theme.dart';

/// สีสถานะมาตรฐานของแอป
abstract final class StatusColors {
  static const good = Color(0xFF22C474);
  static const warn = Color(0xFFFFA824);
  static const bad = Color(0xFFFF4D5A);
  static const info = Color(0xFF3DA5FF);
}

extension CheckLevelStyle on CheckLevel {
  Color get color => switch (this) {
        CheckLevel.ok => StatusColors.good,
        CheckLevel.warn => StatusColors.warn,
        CheckLevel.bad => StatusColors.bad,
        CheckLevel.info => StatusColors.info,
      };

  IconData get icon => switch (this) {
        CheckLevel.ok => Icons.check_circle_rounded,
        CheckLevel.warn => Icons.error_rounded,
        CheckLevel.bad => Icons.cancel_rounded,
        CheckLevel.info => Icons.info_rounded,
      };
}

/// ป้ายสถานะทรงแคปซูล
class Pill extends StatelessWidget {
  const Pill({super.key, required this.text, required this.color, this.icon, this.mono = false});

  final String text;
  final Color color;
  final IconData? icon;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 14, color: color), const SizedBox(width: 5)],
        Flexible(
          child: Text(
            text,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: color, fontFamily: mono ? kMono : null),
          ),
        ),
      ]),
    );
  }
}

/// แถวป้ายชื่อ-ค่า
class KvRow extends StatelessWidget {
  const KvRow(this.label, this.value, {super.key, this.mono = false, this.valueColor});

  final String label;
  final String value;
  final bool mono;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(flex: 5, child: Text(label, style: TextStyle(color: cs.onSurfaceVariant))),
        const SizedBox(width: 10),
        Expanded(
          flex: 6,
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: TextStyle(fontWeight: FontWeight.w600, fontFamily: mono ? kMono : null, color: valueColor),
          ),
        ),
      ]),
    );
  }
}

/// หน้าว่างแบบมีไอคอนและคำอธิบาย
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.text, this.action});

  final IconData icon;
  final String title;
  final String? text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 60, color: cs.onSurfaceVariant.withValues(alpha: 0.6)),
          const SizedBox(height: 14),
          Text(title, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          if (text != null) ...[
            const SizedBox(height: 6),
            Text(text!, textAlign: TextAlign.center, style: TextStyle(color: cs.onSurfaceVariant, height: 1.45)),
          ],
          if (action != null) ...[const SizedBox(height: 18), action!],
        ]),
      ),
    );
  }
}

/// แถวผลตรวจหนึ่งข้อ (ไอคอนสถานะ + หัวข้อ + รายละเอียด)
class CheckRow extends StatelessWidget {
  const CheckRow({super.key, required this.level, required this.title, required this.detail});

  final CheckLevel level;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(level.icon, color: level.color, size: 22),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700, height: 1.3)),
            if (detail.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(detail, style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant, height: 1.45)),
            ],
          ]),
        ),
      ]),
    );
  }
}

/// การ์ดเครื่องมือแบบตาราง (ไอคอน + ชื่อ + คำอธิบายสั้น)
class ToolCard extends StatelessWidget {
  const ToolCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.color,
    this.badge,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Color? color;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final c = color ?? cs.primary;
    return PremiumCard(
      onTap: onTap,
      padding: const EdgeInsets.all(14),
      radius: 18,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: c.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(12)),
            child: Icon(icon, color: c, size: 22),
          ),
          const Spacer(),
          if (badge != null) Pill(text: badge!, color: c),
        ]),
        const Spacer(),
        Text(title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5, height: 1.3)),
        const SizedBox(height: 2),
        Flexible(
          flex: 0,
          child: Text(subtitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant, height: 1.3)),
        ),
      ]),
    );
  }
}

/// แถบความคืบหน้าแบบหลายขั้นตอน
class StepList extends StatelessWidget {
  const StepList({super.key, required this.steps});

  final List<(String, bool)> steps;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final (label, done) in steps)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            done
                ? const Icon(Icons.check_circle_rounded, size: 18, color: StatusColors.good)
                : SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2.4, color: cs.primary),
                  ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(label,
                  style: TextStyle(fontSize: 13, color: done ? cs.onSurfaceVariant : cs.onSurface, fontWeight: done ? FontWeight.w400 : FontWeight.w600)),
            ),
          ]),
        ),
    ]);
  }
}

String thaiDate(DateTime t, {bool time = true}) {
  String two(int n) => n.toString().padLeft(2, '0');
  final d = '${two(t.day)}/${two(t.month)}/${t.year + 543}';
  return time ? '$d ${two(t.hour)}:${two(t.minute)}' : d;
}
