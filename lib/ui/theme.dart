import 'package:flutter/material.dart';

import '../state/settings.dart';

/// สีพื้นของธีมมืด แบบคาร์บอน/แดชบอร์ดรถ
abstract final class Carbon {
  static const bg = Color(0xFF07090C);
  static const surface = Color(0xFF0F1318);
  static const card = Color(0xFF151A21);
  static const cardHigh = Color(0xFF1C222B);
  static const line = Color(0xFF262E39);
  static const text = Color(0xFFE9EDF2);
  static const textDim = Color(0xFF8A95A5);
}

/// สีพื้นของธีมสว่าง
abstract final class Paper {
  static const bg = Color(0xFFF3F5F8);
  static const card = Color(0xFFFFFFFF);
  static const line = Color(0xFFE1E6ED);
  static const text = Color(0xFF111620);
  static const textDim = Color(0xFF5E6878);
}

/// ฟอนต์ที่ฝังในแอป (Prompt สำหรับภาษาไทย/อังกฤษ, IBM Plex Mono สำหรับรหัส)
const kFont = 'Prompt';
const kMono = 'IBMPlexMono';

/// ขนาดตัวอักษรตามที่ตั้งในเครื่องได้ไม่เกินกี่เท่า
/// (ตั้งตัวอักษรใหญ่มากในเครื่อง หน้าจอที่มีตัวเลขใหญ่ มาตรวัด และปุ่มเรียงกันจะล้นหรือถูกตัด)
/// ทุกหน้าตรวจด้วยภาพหน้าจอที่ขนาดนี้แล้ว (test_screens, SHOT_SCALE=1.3)
const kMaxTextScale = 1.3;

ThemeData buildTheme(AccentPreset accent, Brightness brightness, {String fontFamily = kFont}) {
  final dark = brightness == Brightness.dark;
  final base = ColorScheme.fromSeed(seedColor: accent.color, brightness: brightness);
  final scheme = base.copyWith(
    primary: accent.color,
    onPrimary: _onColor(accent.color),
    secondary: accent.color,
    surface: dark ? Carbon.surface : Paper.card,
    onSurface: dark ? Carbon.text : Paper.text,
    onSurfaceVariant: dark ? Carbon.textDim : Paper.textDim,
    surfaceContainerLowest: dark ? Carbon.bg : Paper.bg,
    surfaceContainerLow: dark ? Carbon.surface : Paper.card,
    surfaceContainer: dark ? Carbon.card : Paper.card,
    surfaceContainerHigh: dark ? Carbon.cardHigh : const Color(0xFFF7F9FB),
    surfaceContainerHighest: dark ? Carbon.line : Paper.line,
    outline: dark ? Carbon.line : Paper.line,
    outlineVariant: dark ? Carbon.line : Paper.line,
  );

  final t = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: fontFamily,
    // ข้อความฟอนต์อื่น (เช่นตัวเลขแบบ mono) ที่มีภาษาไทยปน ใช้ฟอนต์ไทยของแอปแทนฟอนต์ระบบ
    fontFamilyFallback: const [kFont],
    scaffoldBackgroundColor: dark ? Carbon.bg : Paper.bg,
    splashFactory: InkSparkle.splashFactory,
  );

  return t.copyWith(
    appBarTheme: AppBarTheme(
      backgroundColor: dark ? Carbon.bg : Paper.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: t.textTheme.titleLarge?.copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: 0.2,
        color: scheme.onSurface,
      ),
    ),
    cardTheme: CardThemeData(
      color: dark ? Carbon.card : Paper.card,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: dark ? Carbon.line : Paper.line),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: dark ? Carbon.surface : Paper.card,
      surfaceTintColor: Colors.transparent,
      indicatorColor: accent.color.withValues(alpha: 0.18),
      height: 70,
      labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
            fontSize: 12,
            fontWeight: s.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
            color: s.contains(WidgetState.selected) ? accent.color : scheme.onSurfaceVariant,
          )),
      iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(
            color: s.contains(WidgetState.selected) ? accent.color : scheme.onSurfaceVariant,
          )),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, fontFamily: fontFamily),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 52),
        side: BorderSide(color: dark ? Carbon.line : Paper.line),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        side: WidgetStatePropertyAll(BorderSide(color: dark ? Carbon.line : Paper.line)),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
      ),
    ),
    dividerTheme: DividerThemeData(color: dark ? Carbon.line : Paper.line, space: 1),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? Carbon.card : Paper.card,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: dark ? Carbon.line : Paper.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: dark ? Carbon.line : Paper.line),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
  );
}

Color _onColor(Color c) => c.computeLuminance() > 0.45 ? Colors.black : Colors.white;

/// การ์ดพรีเมียม: พื้นไล่เฉดบางๆ + ขอบเรืองแสงตามสีที่กำหนด
class PremiumCard extends StatelessWidget {
  const PremiumCard({
    super.key,
    required this.child,
    this.glow,
    this.padding = const EdgeInsets.all(18),
    this.onTap,
    this.radius = 22,
  });

  final Widget child;
  final Color? glow;
  final EdgeInsets padding;
  final VoidCallback? onTap;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final g = glow;
    final border = g != null ? g.withValues(alpha: dark ? 0.55 : 0.45) : cs.outline;
    final top = dark ? Carbon.cardHigh : Paper.card;
    final bottom = dark ? Carbon.card : const Color(0xFFFAFBFD);
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: g == null
              ? [top, bottom]
              : [Color.alphaBlend(g.withValues(alpha: dark ? 0.16 : 0.08), top), bottom],
        ),
        border: Border.all(color: border, width: g != null ? 1.3 : 1),
        boxShadow: [
          if (g != null && dark) BoxShadow(color: g.withValues(alpha: 0.18), blurRadius: 24, spreadRadius: -6),
          if (!dark) BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 16, offset: const Offset(0, 6)),
        ],
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(radius),
          onTap: onTap,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// ข้อความบรรทัดเดียวที่แสดงครบเสมอ: ถ้าช่องแคบ (จอเล็ก ตัวอักษรใหญ่) ย่อตัวอักษรลงแทนการตัดคำ
/// ใช้กับหัวข้อหน้า ชื่อปุ่ม ป้าย และตัวเลข ที่ต้องเห็นครบทั้งคำ
class FitText extends StatelessWidget {
  const FitText(this.text, {super.key, this.style, this.alignment = Alignment.centerLeft, this.textAlign});

  final String text;
  final TextStyle? style;
  final AlignmentGeometry alignment;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) => FittedBox(
        fit: BoxFit.scaleDown,
        alignment: alignment,
        child: Text(text, maxLines: 1, softWrap: false, style: style, textAlign: textAlign),
      );
}

/// หัวข้อส่วน ตัวเล็ก ตัวหนา ตัวพิมพ์ห่าง
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 10),
      child: Row(children: [
        Container(width: 4, height: 16, decoration: BoxDecoration(color: cs.primary, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text,
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: cs.onSurface, letterSpacing: 0.3)),
        ),
        if (trailing != null) trailing!,
      ]),
    );
  }
}
