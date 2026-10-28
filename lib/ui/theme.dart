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

/// คำไทยที่ต้องขึ้นบรรทัดใหม่ทั้งคำ
/// - คำทับศัพท์ที่ระบบตัดคำ (ICU) ไม่รู้จักแล้วตัดกลางพยางค์ เช่น "กราว|ด์", "เรี|ยลไทม์", "เท|อร์โบ", "แบ|ต"
/// - คำประสมที่ไม่ควรแยกคนละบรรทัด เช่น "น้ำหล่อเย็น", "คำสั่ง"
/// ใช้กับข้อความที่แสดงบนจอเท่านั้น (ห้ามใช้กับข้อมูลที่บันทึก ส่งออก หรือค้นหา)
/// ห้ามใส่คำที่เทสต์ค้นด้วย find.text บนวิดเจ็ตที่ใช้ [thaiKeep] (เช่น เครื่องยนต์ หัวฉีด รีแมพ) ไม่อย่างนั้นเทสต์หาข้อความไม่เจอ
/// แก้รายการแล้วต้องผ่าน test/v11_text_layout_test.dart (วางข้อความจริงทั้งแอปหลายความกว้าง ตรวจทุกจุดขึ้นบรรทัดใหม่)
const kThaiKeepWords = [
  // คำทับศัพท์
  'กราวด์', 'เทอร์โบ', 'เทอร์โมสตัท', 'เทอร์โมมิเตอร์', 'เทอร์มิสเตอร์', 'เทอร์มินัล', 'เทอร์ไบน์', 'เทอร์',
  'เซ็นเซอร์', 'เซนเซอร์', 'อินเตอร์คูลเลอร์', 'คูลเลอร์', 'เรกกูเลเตอร์', 'เร็กกูเลเตอร์', 'ฮีตเตอร์', 'คัทเอาท์',
  'แบนด์', 'เรียลไทม์', 'แบตเตอรี่', 'แบต', 'ครูส', 'สเต็ป', 'วาล์ว', 'สวิร์ล', 'แคตาไลติก', 'แคท', 'แดชบอร์ด',
  'แคป', 'ซีเรียล', 'โพรเพน', 'แอคทีฟ', 'เกจ', 'จูน', 'ซอฟต์แวร์', 'ไดชาร์จ', 'สตาร์ท', 'แคมชาฟท์', 'โปรโตคอล',
  'ออกซิเจน', 'โซล่า',
  // คำประสม
  'น้ำหล่อเย็น', 'น้ำมันเครื่อง', 'เชื้อเพลิง', 'คำสั่ง', 'ไอดี', 'ไอเสีย', 'ล่วงหน้า', 'สอดคล้อง', 'ตัดสินใจ',
  'สิ้นเปลือง', 'ขั้นตอน', 'ร้ายแรง', 'คันเร่ง', 'ลิ้นเร่ง', 'ข้อเหวี่ยง', 'หัวเทียน', 'ถุงลม', 'อัตราเร่ง',
  'ความเร็ว', 'ความดัน', 'ความร้อน', 'ไฟเตือน', 'ปีกผีเสื้อ', 'มาตรฐาน', 'ผิดปกติ', 'ปลอดภัย', 'ตรวจสภาพ',
  'เลขไมล์', 'หน้าปัด', 'สัญญาณ', 'แรงดัน', 'ระยะทาง', 'รถยก', 'เชื่อมต่อ', 'ตัวสแกน', 'บันทึก', 'ความสามารถ',
  'ประสิทธิภาพ', 'วิเคราะห์', 'วินิจฉัย', 'อุปกรณ์', 'เครื่องติด',
];

/// คำในรายการที่ต้องไม่ตามด้วยตัวอักษรเหล่านี้ (เป็นส่วนของคำอื่น เช่น "ครู|สอน")
const _thaiKeepNotBefore = {'ครูส': 'อ'};

const kWordJoiner = '\u2060';
const kZeroWidthSpace = '\u200B';

bool _isThaiChar(int c) => c >= 0x0E01 && c <= 0x0E5B;
bool _isLeadingVowel(int c) => c >= 0x0E40 && c <= 0x0E44;
bool _isThaiBase(int c) => (c >= 0x0E01 && c <= 0x0E2E) || _isLeadingVowel(c);

/// สระหลัง สระบน/ล่าง วรรณยุกต์ และเครื่องหมายที่ต้องอยู่ติดพยัญชนะตัวหน้า
bool isThaiDependent(int c) =>
    c == 0x0E30 || c == 0x0E31 || c == 0x0E32 || c == 0x0E33 || c == 0x0E45 || (c >= 0x0E34 && c <= 0x0E3A) || (c >= 0x0E47 && c <= 0x0E4E);

/// ใส่ตัวเชื่อมคำ (U+2060) หน้าพยัญชนะและสระหน้าทุกตัวภายในคำ (ไม่ใส่หน้าสระบน/ล่าง วรรณยุกต์ และไม่แยกสระหน้าออกจากพยัญชนะ
/// จึงไม่กระทบการวาดตัวอักษร) ระบบตัดคำจึงไม่มีจุดให้ตัดภายในคำเลย ไม่ว่าคำนั้นอยู่ในพจนานุกรมหรือไม่
String _glueWord(String w) {
  final b = StringBuffer();
  for (var i = 0; i < w.length; i++) {
    final c = w.codeUnitAt(i);
    if (i > 0 && _isThaiBase(c) && !_isLeadingVowel(w.codeUnitAt(i - 1))) b.write(kWordJoiner);
    b.writeCharCode(c);
  }
  return b.toString();
}

final _thaiKeepMap = {for (final w in kThaiKeepWords) w: _glueWord(w)};
final _thaiKeepRe = RegExp((_thaiKeepMap.keys.toList()..sort((a, b) => b.length.compareTo(a.length))).join('|'));
final _thaiNumRe = RegExp(r'([\u0E00-\u0E7F]) (\d|[A-Z](?![A-Za-z]))');
final _thaiSlashRe = RegExp(r'([\u0E00-\u0E7F.])/(?=[\u0E00-\u0E7F])');
final _unitRe = RegExp(r'(\d) (bit|kbps|กม\.|ครั้ง|วัน|เดือน|ปี|ชม\.|วินาที|นาที|ค่า|รายการ|°C|V|kPa|MPa|%)');
final _hyphenRe = RegExp(r'([A-Za-z0-9])-(?=[A-Za-z0-9])');

/// ข้อความสำหรับแสดงบนจอ: ไม่ให้ขึ้นบรรทัดใหม่กลางคำ/กลางพยางค์ ตัวอักษรที่มองเห็นเหมือนเดิมทุกตัว
String thaiKeep(String s) {
  // ตัวเลขติดกับหน่วยเสมอ (เช่น "11 bit", "500 kbps", "10,000 กม.") ไม่ให้หน่วยไปขึ้นบรรทัดใหม่
  s = s.replaceAllMapped(_unitRe, (m) => '${m[1]}\u00A0${m[2]}');
  // ชื่อที่มีขีดกลาง (D-Max, Wi-Fi, OBD-II, สูบ 1-2) ไม่ขึ้นบรรทัดใหม่หลังขีด
  s = s.replaceAllMapped(_hyphenRe, (m) => '${m[1]}-$kWordJoiner');
  if (!s.codeUnits.any(_isThaiChar)) return s;
  // ไม้ยมกไม่ขึ้นต้นบรรทัด ("ต่าง ๆ")
  s = s.replaceAll(' ๆ', '\u00A0ๆ');
  // คำไทยติดกับเลข/ตัวอักษรกำกับที่ตามมา (เช่น "สูบ 1", "แบบ 3", "แคม A") ไม่แยกกันคนละบรรทัด
  s = s.replaceAllMapped(_thaiNumRe, (m) => '${m[1]}\u00A0${m[2]}');
  // หน่วยไทยที่มีทับ (กม./ชม., รอบ/นาที, อ่าน/ลบ) ไม่ขึ้นบรรทัดใหม่หลังเครื่องหมายทับ
  s = s.replaceAllMapped(_thaiSlashRe, (m) => '${m[1]}/$kWordJoiner');
  return _keepWords(s);
}

/// คำในรายการทั้งคำเป็นก้อนเดียว และมีจุดตัดบรรทัดที่มองไม่เห็น (U+200B) หน้าและหลังคำเมื่อติดกับคำไทยอื่น
/// ระบบตัดคำจึงเห็นคำข้างเคียงเป็นคำเต็ม (ถ้าไม่ใส่ ส่วนที่เหลือของคำข้างเคียงจะถูกตัดผิดแทน เช่น "ตำแหน่|งลิ้นเร่ง")
/// คำที่เจอเป็นส่วนหนึ่งของคำอื่น (ต่อด้วยสระ/วรรณยุกต์ หรือพยัญชนะการันต์ หรือขึ้นต้นหลังสระหน้า) ไม่แตะ
String _keepWords(String s) {
  final out = StringBuffer();
  var last = 0;
  var lastWasBreak = false;
  for (final m in _thaiKeepRe.allMatches(s)) {
    final a = m.start, b = m.end, w = m[0]!;
    if (a > 0 && _isLeadingVowel(s.codeUnitAt(a - 1))) continue;
    if (b < s.length && isThaiDependent(s.codeUnitAt(b))) continue;
    if (b + 1 < s.length && s.codeUnitAt(b + 1) == 0x0E4C) continue;
    final notBefore = _thaiKeepNotBefore[w];
    if (notBefore != null && b < s.length && notBefore.contains(s[b])) continue;
    out.write(s.substring(last, a));
    if (a > 0 && _isThaiChar(s.codeUnitAt(a - 1)) && !(lastWasBreak && a == last)) out.write(kZeroWidthSpace);
    out.write(_thaiKeepMap[w]);
    lastWasBreak = false;
    if (b < s.length && _isThaiChar(s.codeUnitAt(b)) && s.codeUnitAt(b) != 0x0E46 && s.codeUnitAt(b) != 0x0E2F) {
      out.write(kZeroWidthSpace);
      lastWasBreak = true;
    }
    last = b;
  }
  if (last == 0) return s;
  out.write(s.substring(last));
  return out.toString();
}

/// จอแคบเมื่อคิดรวมขนาดตัวอักษร (เช่น มือถือ 360 dp ที่ตั้งตัวอักษรใหญ่ 1.3 เท่า ≈ จอ 277 dp)
/// ใช้เลือกรูปแบบที่กะทัดรัดกว่า (ซ่อนไอคอนในปุ่ม ย่อรูป) ให้ข้อความแสดงครบ
bool isNarrow(BuildContext context, [double limit = 400]) {
  final scale = MediaQuery.textScalerOf(context).scale(100) / 100;
  return MediaQuery.sizeOf(context).width / scale < limit;
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
          child: Text(thaiKeep(text),
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: cs.onSurface, letterSpacing: 0.3)),
        ),
        if (trailing != null) trailing!,
      ]),
    );
  }
}
