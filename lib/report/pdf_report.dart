import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import '../core/analysis/odometer_check.dart';
import '../core/analysis/remap_test.dart';
import '../core/analysis/used_car.dart';
import '../core/analysis/vin.dart';
import '../core/diagnosis/diagnosis.dart';
import '../core/obd/dtc_database.dart';
import '../core/obd/mode06.dart';
import '../core/obd/pids.dart';
import '../data/garage_store.dart';
import '../state/providers.dart';
import '../ui/theme.dart';
import '../ui/widgets/xy_chart.dart';

/// ข้อมูลทั้งหมดที่ใช้สร้างรายงาน
class ReportInput {
  const ReportInput({
    required this.report,
    this.shop = const ShopProfile(),
    this.vehicle,
    this.usedCar,
    this.odometer,
    this.mode06 = const [],
    this.settings = const AppSettings(),
  });

  final DiagnosisReport report;
  final ShopProfile shop;
  final Vehicle? vehicle;
  final UsedCarReport? usedCar;
  final OdometerResult? odometer;
  final List<Mode06Result> mode06;
  final AppSettings settings;
}

const _ink = Color(0xFF111620);
const _dim = Color(0xFF5E6878);
const _line = Color(0xFFDDE2EA);
const _good = Color(0xFF16A35F);
const _warn = Color(0xFFDB8A00);
const _bad = Color(0xFFD9303E);
const _info = Color(0xFF1F7FD6);

Color _sevColor(Severity s) => switch (s) {
      Severity.info => _info,
      Severity.low => _good,
      Severity.medium => _warn,
      Severity.high => _bad,
    };

Color _lvlColor(CheckLevel l) => switch (l) {
      CheckLevel.ok => _good,
      CheckLevel.warn => _warn,
      CheckLevel.bad => _bad,
      CheckLevel.info => _info,
    };

CheckLevel _sevLevel(Severity s) => switch (s) {
      Severity.info => CheckLevel.ok,
      Severity.low => CheckLevel.info,
      Severity.medium => CheckLevel.warn,
      Severity.high => CheckLevel.bad,
    };

/// วาดหน้ารายงานด้วยเครื่องจัดข้อความของ Flutter (ตัดคำและวางสระ/วรรณยุกต์ไทยถูกต้อง)
/// แล้วแปลงเป็นภาพในไฟล์ PDF ขนาด A4
class _Pager {
  _Pager({required this.accent, this.logo, required this.shop, required this.title});

  static const w = 595.0;
  static const h = 842.0;
  static const m = 40.0;
  static const bottom = h - 54;
  static const scale = 2.4;

  final Color accent;
  final ui.Image? logo;
  final ShopProfile shop;
  final String title;

  final pictures = <ui.Picture>[];
  ui.PictureRecorder? _rec;
  late Canvas c;
  double y = 0;

  double get width => w - 2 * m;

  void _startPage() {
    _rec = ui.PictureRecorder();
    c = Canvas(_rec!);
    c.drawRect(const Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.white);
    // แถบสีหัวกระดาษ
    c.drawRect(const Rect.fromLTWH(0, 0, w, 6), Paint()..color = accent);
    y = 22;
    if (pictures.isEmpty) {
      _header();
    } else {
      final tp = _tp(title, 9, color: _dim);
      tp.paint(c, Offset(m, y));
      y += tp.height + 10;
      _rule();
    }
    _pageTop = y;
  }

  void _header() {
    var x = m;
    if (logo != null) {
      const size = 56.0;
      final src = Rect.fromLTWH(0, 0, logo!.width.toDouble(), logo!.height.toDouble());
      final ratio = logo!.width / logo!.height;
      final dw = ratio >= 1 ? size : size * ratio;
      final dh = ratio >= 1 ? size / ratio : size;
      c.drawImageRect(logo!, src, Rect.fromLTWH(m, y, dw, dh), Paint()..filterQuality = FilterQuality.high);
      x = m + dw + 14;
    }
    final top = y;
    final name = shop.name.isEmpty ? 'ProScaner' : shop.name;
    final t1 = _tp(name, 17, weight: FontWeight.w700, width: w - m - x);
    t1.paint(c, Offset(x, y));
    var yy = y + t1.height + 2;
    final contact = [
      if (shop.phone.isNotEmpty) 'โทร ${shop.phone}',
      if (shop.address.isNotEmpty) shop.address,
    ].join('  ·  ');
    if (contact.isNotEmpty) {
      final t2 = _tp(contact, 9.5, color: _dim, width: w - m - x);
      t2.paint(c, Offset(x, yy));
      yy += t2.height;
    }
    y = (logo != null ? top + 60 : yy) + 12;
    final t3 = _tp(title, 20, weight: FontWeight.w800, color: accent);
    t3.paint(c, Offset(m, y));
    y += t3.height + 8;
    _rule();
  }

  void _finishPage() {
    if (_rec == null) return;
    pictures.add(_rec!.endRecording());
    _rec = null;
  }

  TextPainter _tp(String text, double size,
      {FontWeight weight = FontWeight.w400, Color color = _ink, double? width, String family = kFont, double height = 1.45}) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontFamily: family, fontSize: size, fontWeight: weight, color: color, height: height),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: width ?? this.width);
    return tp;
  }

  double _pageTop = 0;

  void ensure(double need) {
    if (_rec == null) _startPage();
    // ขึ้นหน้าใหม่เฉพาะเมื่อหน้านี้มีเนื้อหาแล้ว (กันหน้าว่างเมื่อบล็อกสูงกว่าหนึ่งหน้า)
    if (y + need > bottom && y > _pageTop + 1) {
      _finishPage();
      _startPage();
    }
  }

  void gap(double v) => y += v;

  void _rule() {
    c.drawLine(Offset(m, y), Offset(w - m, y), Paint()
      ..color = _line
      ..strokeWidth = 0.8);
    y += 10;
  }

  void rule() {
    ensure(12);
    _rule();
  }

  void heading(String text) {
    final tp = _tp(text, 13, weight: FontWeight.w700);
    ensure(tp.height + 40); // ไม่ให้หัวข้อค้างท้ายหน้า
    y += 6;
    c.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(m, y + 3, 4, tp.height - 6), const Radius.circular(2)),
      Paint()..color = accent,
    );
    tp.paint(c, Offset(m + 12, y));
    y += tp.height + 6;
  }

  void para(String text, {double size = 10.5, Color color = _ink, FontWeight weight = FontWeight.w400, double indent = 0}) {
    final tp = _tp(text, size, color: color, weight: weight, width: width - indent);
    ensure(tp.height);
    tp.paint(c, Offset(m + indent, y));
    y += tp.height + 2;
  }

  void kv(String k, String v, {Color? valueColor, bool mono = false}) {
    final kt = _tp(k, 10.5, color: _dim, width: width * 0.42);
    final vt = _tp(v, 10.5,
        weight: FontWeight.w600, color: valueColor ?? _ink, width: width * 0.56, family: mono ? kMono : kFont);
    final hh = kt.height > vt.height ? kt.height : vt.height;
    ensure(hh + 2);
    kt.paint(c, Offset(m, y));
    vt.paint(c, Offset(w - m - vt.width, y));
    y += hh + 3;
  }

  /// แถวมีเครื่องหมายสถานะด้านหน้า (วาดเป็นรูปทรง ไม่พึ่งฟอนต์สัญลักษณ์)
  void mark(CheckLevel level, String title, String detail, {Color? color}) {
    final col = color ?? _lvlColor(level);
    final tt = _tp(title, 10.8, weight: FontWeight.w600, width: width - 26);
    final dt = detail.isEmpty ? null : _tp(detail, 9.6, color: _dim, width: width - 26);
    ensure(tt.height + (dt?.height ?? 0) + 6);
    final cx = m + 8, cy = y + 9;
    c.drawCircle(Offset(cx, cy), 8, Paint()..color = col);
    final pen = Paint()
      ..color = Colors.white
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    switch (level) {
      case CheckLevel.ok:
        c.drawPath(
            Path()
              ..moveTo(cx - 3.6, cy + 0.2)
              ..lineTo(cx - 1, cy + 2.8)
              ..lineTo(cx + 3.8, cy - 2.6),
            pen);
      case CheckLevel.bad:
        c.drawLine(Offset(cx - 3, cy - 3), Offset(cx + 3, cy + 3), pen);
        c.drawLine(Offset(cx + 3, cy - 3), Offset(cx - 3, cy + 3), pen);
      case CheckLevel.warn:
        c.drawLine(Offset(cx, cy - 4), Offset(cx, cy + 0.8), pen);
        c.drawCircle(Offset(cx, cy + 3.6), 1.1, Paint()..color = Colors.white);
      case CheckLevel.info:
        c.drawLine(Offset(cx, cy - 0.8), Offset(cx, cy + 4), pen);
        c.drawCircle(Offset(cx, cy - 3.6), 1.1, Paint()..color = Colors.white);
    }
    tt.paint(c, Offset(m + 26, y));
    y += tt.height;
    if (dt != null) {
      dt.paint(c, Offset(m + 26, y));
      y += dt.height;
    }
    y += 6;
  }

  /// กล่องสรุปสีพื้นอ่อน
  void banner(String big, String small, Color color, {String? side}) {
    final bt = _tp(big, 16, weight: FontWeight.w800, color: color, width: width - 110);
    final st = _tp(small, 10, color: _dim, width: width - 110);
    final hh = bt.height + st.height + 24;
    ensure(hh + 6);
    final r = RRect.fromRectAndRadius(Rect.fromLTWH(m, y, width, hh), const Radius.circular(10));
    c.drawRRect(r, Paint()..color = color.withValues(alpha: 0.08));
    c.drawRRect(
        r,
        Paint()
          ..color = color.withValues(alpha: 0.5)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1);
    bt.paint(c, Offset(m + 14, y + 12));
    st.paint(c, Offset(m + 14, y + 12 + bt.height));
    if (side != null) {
      final sd = _tp(side, 26, weight: FontWeight.w800, color: color);
      sd.paint(c, Offset(w - m - 14 - sd.width, y + (hh - sd.height) / 2));
    }
    y += hh + 8;
  }

  /// ตาราง: คอลัมน์แรกชิดซ้าย คอลัมน์อื่นชิดขวา [colors] กำหนดสีรายช่อง (null = สีปกติ)
  void table(List<String> headers, List<List<String>> rows, {List<double>? flex, List<List<Color?>>? colors}) {
    final f = flex ?? List<double>.filled(headers.length, 1);
    final total = f.fold<double>(0, (a, b) => a + b);
    final widths = [for (final x in f) width * x / total];
    void row(List<String> cells, {bool head = false, List<Color?>? cellColors}) {
      final tps = [
        for (var i = 0; i < cells.length; i++)
          _tp(cells[i], head ? 9.4 : 10,
              weight: head ? FontWeight.w700 : (i == 0 ? FontWeight.w400 : FontWeight.w600),
              color: cellColors?[i] ?? (head ? _dim : _ink),
              width: widths[i] - 8),
      ];
      final hh = tps.fold<double>(0, (a, t) => t.height > a ? t.height : a) + 8;
      ensure(hh);
      if (head) c.drawRect(Rect.fromLTWH(m, y, width, hh), Paint()..color = const Color(0xFFF3F5F8));
      var x = m;
      for (var i = 0; i < tps.length; i++) {
        final tp = tps[i];
        tp.paint(c, Offset(i == 0 ? x + 4 : x + widths[i] - 4 - tp.width, y + 4));
        x += widths[i];
      }
      y += hh;
      c.drawLine(Offset(m, y), Offset(w - m, y), Paint()
        ..color = _line
        ..strokeWidth = 0.6);
    }

    row(headers, head: true);
    for (var r = 0; r < rows.length; r++) {
      row(rows[r], cellColors: colors == null || r >= colors.length ? null : colors[r]);
    }
    y += 8;
  }

  /// กราฟเส้น X-Y พร้อมคำอธิบายเส้น (ใช้ตัววาดเดียวกับบนจอ)
  void chart(String title, List<XySeries> series,
      {String xUnit = '', String yUnit = '', int xDecimals = 0, int yDecimals = 0, double height = 165}) {
    final tt = _tp(title, 10.5, weight: FontWeight.w600);
    ensure(tt.height + height + 34);
    tt.paint(c, Offset(m, y));
    y += tt.height + 2;
    var lx = m;
    var any = false;
    for (final s in series) {
      if (s.label.isEmpty) continue;
      any = true;
      c.drawRect(Rect.fromLTWH(lx, y + 6, 14, 3), Paint()..color = s.color);
      final lt = _tp(s.label, 9, color: _dim);
      lt.paint(c, Offset(lx + 18, y));
      lx += 18 + lt.width + 14;
    }
    if (any) y += 16;
    c.save();
    c.translate(m, y);
    XyPainter(
      series: series,
      grid: _line,
      label: _dim,
      fontFamily: kFont,
      xUnit: xUnit,
      yUnit: yUnit,
      xDecimals: xDecimals,
      yDecimals: yDecimals,
      fontSize: 8,
    ).paint(c, Size(width, height));
    c.restore();
    y += height + 12;
  }

  Future<List<Uint8List>> render() async {
    _finishPage();
    final out = <Uint8List>[];
    final total = pictures.length;
    for (var i = 0; i < total; i++) {
      final rec = ui.PictureRecorder();
      final cc = Canvas(rec);
      cc.scale(scale);
      cc.drawPicture(pictures[i]);
      final now = DateTime.now();
      final foot = TextPainter(
        text: TextSpan(
          text: 'สร้างโดย ProScaner · ${now.day}/${now.month}/${now.year + 543}    หน้า ${i + 1}/$total',
          style: const TextStyle(fontFamily: kFont, fontSize: 8.5, color: _dim),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      foot.paint(cc, Offset(w - m - foot.width, h - 30));
      final img = await rec.endRecording().toImage((w * scale).round(), (h * scale).round());
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();
      out.add(data!.buffer.asUint8List());
    }
    return out;
  }
}

String _two(int n) => n.toString().padLeft(2, '0');
String _date(DateTime t) => '${_two(t.day)}/${_two(t.month)}/${t.year + 543} ${_two(t.hour)}:${_two(t.minute)}';

/// สร้างไฟล์ PDF แล้วคืนเป็น bytes
Future<Uint8List> buildReportPdf(ReportInput input, {Color accent = const Color(0xFFD9303E)}) async {
  ui.Image? logo;
  final lp = input.shop.logoPath;
  if (lp != null) {
    try {
      final codec = await ui.instantiateImageCodec(await File(lp).readAsBytes(), targetWidth: 300);
      logo = (await codec.getNextFrame()).image;
    } catch (_) {
      logo = null;
    }
  }
  final r = input.report;
  final s = r.snapshot;
  final title = input.usedCar != null ? 'รายงานตรวจสภาพรถมือสอง' : 'รายงานวินิจฉัยรถยนต์ (OBD-II)';
  final p = _Pager(accent: accent, logo: logo, shop: input.shop, title: title);

  // ---- ข้อมูลรถ ----
  p.ensure(10);
  p.heading('ข้อมูลรถ');
  final v = input.vehicle;
  if (v?.customer != null && v!.customer!.isNotEmpty) p.kv('ลูกค้า', '${v.customer}${v.phone != null && v.phone!.isNotEmpty ? ' (${v.phone})' : ''}');
  if (v?.plate != null && v!.plate!.isNotEmpty) p.kv('ทะเบียน', v.plate!);
  if (v != null && v.nickname.isNotEmpty) p.kv('รถ', v.nickname);
  if (v?.displayName != null) p.kv('ยี่ห้อ / รุ่น', '${v!.displayName}${v.year != null ? ' ปี ${v.year}' : ''}');
  if (s.vin != null) {
    p.kv('VIN', s.vin!, mono: true);
    final info = decodeVin17(s.vin!);
    if (info.valid) {
      if (info.maker != null) p.kv('ผู้ผลิต', info.maker!);
      if (info.modelYear != null) p.kv('ปีรุ่น (จาก VIN)', '${info.modelYear}');
    }
  }
  p.kv('เชื้อเพลิง', s.fuelName);
  final odo = s.dashboardKm ?? s.ecuOdometerKm;
  if (odo != null) p.kv('เลขไมล์', formatKm(odo));
  p.kv('วันที่ตรวจ', _date(s.time));
  if (input.shop.technician.isNotEmpty) p.kv('ผู้ตรวจ', input.shop.technician);

  // ---- สรุป ----
  p.heading('สรุปผล');
  p.banner(r.headlineTh, r.overall.ownerAdvice, _sevColor(r.overall), side: '${r.healthScore}');
  p.kv('ไฟเตือนเครื่องยนต์', s.milOn ? 'ติด' : 'ดับ', valueColor: s.milOn ? _warn : _good);
  p.kv('รหัสปัญหาเครื่องยนต์', '${s.codes.length} รหัส');
  final modDtcs = s.modules.fold<int>(0, (a, m) => a + m.dtcs.length);
  if (s.modules.isNotEmpty) p.kv('กล่องอื่นที่สแกน', '${s.modules.length} กล่อง · รหัส $modDtcs รายการ');
  if (s.readiness.isNotEmpty) {
    final done = s.readiness.where((m) => m.complete).length;
    p.kv('ความพร้อมตรวจสภาพ', '${s.inspectionReady ? 'พร้อม' : 'ยังไม่พร้อม'} ($done/${s.readiness.length})',
        valueColor: s.inspectionReady ? _good : _warn);
  }

  // ---- รถมือสอง ----
  final uc = input.usedCar;
  if (uc != null) {
    p.heading('ผลตรวจรถมือสอง');
    final color = switch (uc.risk) {
      UsedCarRisk.low => _good,
      UsedCarRisk.medium => _warn,
      UsedCarRisk.high => _bad,
    };
    p.banner(uc.risk.labelTh, uc.risk.adviceTh, color);
    for (final f in uc.flags) {
      p.mark(f.level, f.title, f.detail);
    }
  }

  // ---- เลขไมล์ ----
  final od = input.odometer;
  if (od != null) {
    p.heading('ตรวจเลขไมล์');
    final color = switch (od.verdict) {
      OdoVerdict.consistent => _good,
      OdoVerdict.checkMore => _warn,
      OdoVerdict.suspicious => _bad,
      OdoVerdict.insufficient => _info,
    };
    p.para(od.verdict.labelTh, size: 12.5, weight: FontWeight.w700, color: color);
    p.gap(4);
    for (final c in od.checks) {
      p.mark(c.level, c.title, c.detail);
    }
    p.para('ผลนี้เป็นหลักฐานประกอบ ไม่ใช่ข้อพิสูจน์', size: 9, color: _dim);
  }

  // ---- ผลวิเคราะห์ ----
  p.heading('ผลวิเคราะห์ (${r.findings.length})');
  for (final f in r.findings) {
    final color = _sevColor(f.severity);
    final head = [if (f.code != null) f.code!, f.title].join('  ');
    p.mark(_sevLevel(f.severity), color: color, head, [
      f.severity.labelTh,
      if (f.module != null) f.module!,
      if (f.kinds.isNotEmpty) f.kinds.map((k) => k.labelTh).join(', '),
    ].join(' · '));
    if (f.causes.isNotEmpty) {
      p.para('สาเหตุที่เป็นไปได้: ${f.causes.take(4).join(' / ')}', size: 9.6, color: _dim, indent: 26);
    }
    if (f.checks.isNotEmpty) {
      p.para('ตรวจเช็ก: ${f.checks.take(4).join(' / ')}', size: 9.6, color: _dim, indent: 26);
    }
    if (f.evidence.isNotEmpty) {
      p.para('ค่าสด: ${f.evidence.take(3).join(' / ')}', size: 9.6, color: _dim, indent: 26);
    }
    p.gap(4);
  }

  // ---- กล่องอื่น ----
  if (s.modules.isNotEmpty) {
    p.heading('ผลสแกนกล่องอื่น');
    for (final m in s.modules) {
      if (m.error != null) {
        p.mark(CheckLevel.info, m.title, 'อ่านไม่ได้: ${m.error} (ไม่ได้แปลว่าไม่มีปัญหา)');
      } else if (m.dtcs.isEmpty) {
        p.mark(CheckLevel.ok, '${m.title} (${m.tx})', 'ไม่มีรหัสปัญหา');
      } else {
        p.mark(CheckLevel.warn, '${m.title} (${m.tx})', 'พบ ${m.dtcs.length} รหัส');
        // แยกบรรทัดละรหัส เพื่อให้ตัดหน้าได้ถูกต้องแม้มีรหัสจำนวนมาก
        for (final d in m.dtcs) {
          p.para('${d.display}  ${d.statusTh}', size: 9.6, color: _dim, indent: 26);
        }
        p.gap(4);
      }
    }
  }

  // ---- ความพร้อม ----
  if (s.readiness.isNotEmpty) {
    p.heading('ระบบทดสอบตัวเอง (Readiness)');
    for (final m in s.readiness) {
      p.kv(m.nameTh, m.complete ? 'เสร็จ' : 'ยังไม่เสร็จ', valueColor: m.complete ? _good : _warn);
    }
  }

  // ---- Mode 06 ----
  final failed = input.mode06.where((t) => !t.passed).toList();
  if (input.mode06.isNotEmpty) {
    p.heading('ผลทดสอบเซ็นเซอร์ในกล่อง (Mode 06)');
    p.para('ทดสอบ ${input.mode06.length} รายการ ไม่ผ่าน ${failed.length} รายการ', size: 10.5);
    for (final t in failed) {
      p.mark(CheckLevel.bad, '${t.midName} · ${t.tidName}',
          'ค่า ${t.fmt(t.value)} ${t.unit} (ช่วงปกติ ${t.fmt(t.min)}–${t.fmt(t.max)})');
    }
  }

  // ---- ค่าสดขณะตรวจ ----
  final keys = [
    Pid.rpm, Pid.coolantTemp, Pid.moduleVoltage, Pid.engineLoad, Pid.stftB1, Pid.ltftB1, Pid.maf,
    Pid.intakeTemp, Pid.fuelRailPressure, Pid.boost, Pid.engineRunTimeTotal, Pid.distanceSinceClear,
  ].where((k) => s.pids[k] != null && pidTable[k] != null).toList();
  if (keys.isNotEmpty) {
    p.heading('ค่าเซ็นเซอร์ขณะตรวจ');
    for (final k in keys) {
      final def = pidTable[k]!;
      p.kv(def.nameTh, displayPid(def, s.pids[k]!, input.settings).withUnit);
    }
  }

  p.gap(10);
  p.rule();
  p.para(
    'รายงานนี้สร้างจากข้อมูลที่อ่านผ่านช่อง OBD-II เป็นแนวทางเบื้องต้น ควรให้ช่างตรวจยืนยันก่อนเปลี่ยนอะไหล่ '
    'ระบบที่ไม่ได้เชื่อมกับกล่องอิเล็กทรอนิกส์ (ตัวถัง ช่วงล่าง ยาง) ต้องตรวจด้วยสายตาเพิ่มเติม',
    size: 9,
    color: _dim,
  );

  final pages = await p.render();
  logo?.dispose();
  final doc = pw.Document(title: title, creator: 'ProScaner');
  for (final png in pages) {
    final img = pw.MemoryImage(png);
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: pw.EdgeInsets.zero,
      build: (_) => pw.Image(img, fit: pw.BoxFit.fill),
    ));
  }
  return doc.save();
}

/// สร้างรายงานแล้วเปิดหน้าต่างแชร์ (LINE, อีเมล, บันทึกไฟล์)
Future<void> shareReportPdf(
  BuildContext context,
  WidgetRef ref, {
  required DiagnosisReport report,
  UsedCarReport? usedCar,
  OdometerResult? odometer,
  List<Mode06Result> mode06 = const [],
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final box = context.findRenderObject() as RenderBox?;
  messenger.showSnackBar(const SnackBar(content: Text('กำลังสร้างรายงาน PDF…'), duration: Duration(seconds: 2)));
  try {
    final settings = ref.read(settingsProvider);
    final garage = ref.read(garageProvider.notifier);
    final vehicle = garage.byVin(report.snapshot.vin) ?? garage.byId(ref.read(sessionProvider).vehicleId);
    final bytes = await buildReportPdf(
      ReportInput(
        report: report,
        shop: settings.shop,
        vehicle: vehicle,
        usedCar: usedCar,
        odometer: odometer,
        mode06: mode06,
        settings: settings,
      ),
      accent: settings.accent.color,
    );
    final dir = await getTemporaryDirectory();
    final t = report.snapshot.time;
    final name = 'ProScaner_Report_${t.year}${_two(t.month)}${_two(t.day)}_${_two(t.hour)}${_two(t.minute)}.pdf';
    final file = File('${dir.path}/$name');
    await file.writeAsBytes(bytes, flush: true);
    await SharePlus.instance.share(ShareParams(
      files: [XFile(file.path, mimeType: 'application/pdf', name: name)],
      subject: 'รายงานตรวจรถ',
      sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
    ));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('สร้างรายงานไม่สำเร็จ: $e')));
  }
}

/// แชร์ไฟล์ใดๆ (ใช้กับ CSV ของบันทึกการขับ)
Future<void> shareFile(BuildContext context, String path, {String? mime, String? subject}) async {
  final box = context.findRenderObject() as RenderBox?;
  await SharePlus.instance.share(ShareParams(
    files: [XFile(path, mimeType: mime)],
    subject: subject,
    sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
  ));
}

// ---------------------------------------------------------------- รายงานทดสอบรีแมพ

Future<ui.Image?> _loadLogo(ShopProfile shop) async {
  final lp = shop.logoPath;
  if (lp == null) return null;
  try {
    final codec = await ui.instantiateImageCodec(await File(lp).readAsBytes(), targetWidth: 300);
    return (await codec.getNextFrame()).image;
  } catch (_) {
    return null;
  }
}

String _dur(double s) {
  final m = s ~/ 60;
  final r = (s % 60).round();
  return m == 0 ? '$r วินาที' : '$m นาที $r วินาที';
}

CheckLevel _remapCheck(RemapLevel l) => switch (l) {
      RemapLevel.ok => CheckLevel.ok,
      RemapLevel.warn => CheckLevel.warn,
      RemapLevel.bad => CheckLevel.bad,
    };

Color _remapColor(RemapLevel l) => _lvlColor(_remapCheck(l));

/// ข้อความสรุปผลเทียบ เช่น "0–100 กม./ชม. เร็วขึ้น 1.25 วินาที (−11%)"
String remapCompareHeadline(List<RemapCompareRow> rows) {
  final accel = rows.where((r) => r.unit == 'วินาที' && r.diff != null).firstOrNull;
  if (accel == null) return 'ไม่มีช่วงอัตราเร่งที่วัดได้ทั้งสองรอบ';
  final d = accel.diff!;
  final name = accel.label.replaceFirst('อัตราเร่ง ', '');
  if (d.abs() < 0.05) return '$name เท่าเดิม';
  final pct = accel.pct == null ? '' : ' (${accel.pct!.abs().toStringAsFixed(0)}%)';
  return '$name ${d < 0 ? 'เร็วขึ้น' : 'ช้าลง'} ${d.abs().toStringAsFixed(2)} วินาที$pct';
}

/// รายงานทดสอบรีแมพ: ให้ [before] อย่างเดียว = รายงานรอบเดียว, ให้ [after] ด้วย = เทียบก่อน/หลัง
Future<Uint8List> buildRemapPdf({
  required RemapAnalysis before,
  RemapAnalysis? after,
  ShopProfile shop = const ShopProfile(),
  Color accent = const Color(0xFFD9303E),
}) async {
  final logo = await _loadLogo(shop);
  final b = after;
  final title = b != null ? 'รายงานเทียบก่อน/หลังรีแมพ' : 'รายงานทดสอบขับ (${before.run.stage.labelTh})';
  final p = _Pager(accent: accent, logo: logo, shop: shop, title: title);
  // สีเดียวกับบนจอ: ก่อน = ฟ้า, หลัง = ส้ม (ไม่ใช้สีธีมของร้าน เพราะอาจเป็นฟ้าซ้ำกับรอบก่อน)
  const cBefore = _info;
  const cAfter = Color(0xFFE8730C);

  // ---- ข้อมูลการทดสอบ
  p.ensure(10);
  p.heading('ข้อมูลการทดสอบ');
  final vehicle = before.run.vehicleLabel.isNotEmpty ? before.run.vehicleLabel : (b?.run.vehicleLabel ?? '');
  if (vehicle.isNotEmpty) p.kv('รถ', vehicle);
  if (shop.technician.isNotEmpty) p.kv('ผู้ทดสอบ', shop.technician);
  void runInfo(String label, RemapAnalysis a) {
    final r = a.run;
    p.kv(label, r.name);
    p.kv('วันที่ · ระยะเวลา', '${_date(r.start)} · ${_dur(r.durationS)}');
    p.kv('อัตราอ่านค่า', '${r.hz.toStringAsFixed(1)} คำสั่ง/วินาที${r.multiPid ? ' (หลาย PID ต่อคำสั่ง)' : ''}');
  }

  runInfo(b == null ? 'รอบทดสอบ' : 'รอบก่อน', before);
  if (b != null) {
    p.gap(4);
    runInfo('รอบหลัง', b);
  }

  // ---- สรุป
  p.heading('สรุปผล');
  if (b != null) {
    final rows = compareRemap(before, b);
    final accel = rows.where((r) => r.unit == 'วินาที' && r.diff != null).firstOrNull;
    final color = switch (accel?.better) {
      true => _good,
      false => _warn,
      null => _info,
    };
    final boost = rows.where((r) => r.label.startsWith('บูสต์สูงสุด') && r.diff != null).firstOrNull;
    p.banner(
      remapCompareHeadline(rows),
      [
        if (boost != null) 'บูสต์สูงสุด ${boost.diffText} kPa',
        'สิ่งผิดปกติ ก่อน ${before.events.length} · หลัง ${b.events.length} รายการ',
      ].join(' · '),
      color,
    );
    final (vt, va) = b.verdictTh;
    p.banner('รอบหลังรีแมพ: $vt', va, _remapColor(b.level));
  } else {
    final (vt, va) = before.verdictTh;
    p.banner(vt, va, _remapColor(before.level));
  }

  // ---- ตัวเลข
  if (b != null) {
    p.heading('เทียบตัวเลข');
    final rows = compareRemap(before, b);
    p.table(
      ['รายการ', 'ก่อน', 'หลัง', 'ต่าง'],
      [
        for (final r in rows)
          ['${r.label}${r.unit.isEmpty ? '' : ' (${r.unit})'}', r.fmt(r.before), r.fmt(r.after), r.diffText],
      ],
      flex: [2.6, 1, 1, 1.5],
      colors: [
        for (final r in rows)
          [null, null, null, switch (r.better) { true => _good, false => _bad, null => null }],
      ],
    );
    p.para('สีเขียว = ดีขึ้น สีแดง = แย่ลง ค่าที่ไม่มีสีไม่ได้ตัดสิน (เช่น บูสต์สูงขึ้นไม่ได้แปลว่าดีเสมอ)', size: 9, color: _dim);
  } else {
    final a = before;
    p.heading('อัตราเร่ง');
    if (a.accel.isEmpty) {
      p.para('ไม่มีช่วงอัตราเร่งที่วัดได้ (ต้องออกตัวจากจอดนิ่ง หรือเร่งผ่านช่วงความเร็วต่อเนื่อง)', size: 10, color: _dim);
    }
    for (final r in a.accel) {
      p.kv('${r.label} กม./ชม.', '${r.seconds.toStringAsFixed(2)} วินาที');
    }
    p.heading('ค่าสูงสุด');
    void mx(String label, double? v, String unit, [int dec = 0]) {
      if (v != null) p.kv(label, '${v.toStringAsFixed(dec)} $unit');
    }

    mx('บูสต์สูงสุด (เกจ)', a.maxBoostGauge, 'kPa');
    mx('บูสต์ที่ต้องการสูงสุด (เกจ)', a.maxBoostCmdGauge, 'kPa');
    mx('ความดันรางสูงสุด', a.max[RemapSignal.rail], 'MPa', 1);
    mx('ความดันรางที่ต้องการสูงสุด', a.max[RemapSignal.railCmd], 'MPa', 1);
    mx('ปริมาณฉีดสูงสุด', a.max[RemapSignal.injQty], 'mm³', 1);
    mx('มวลอากาศสูงสุด', a.max[RemapSignal.maf], 'g/s', 1);
    mx('รอบเครื่องสูงสุด', a.max[RemapSignal.rpm], 'รอบ/นาที');
    mx('ความเร็วสูงสุด', a.max[RemapSignal.speed], 'กม./ชม.');
    mx('อุณหภูมิไอเสียสูงสุด', a.max[RemapSignal.egt], '°C');
    mx('น้ำหล่อเย็นสูงสุด', a.max[RemapSignal.coolant], '°C');
    mx('อากาศเข้าสูงสุด', a.max[RemapSignal.iat], '°C');
    mx('แรงดันไฟต่ำสุด', a.min[RemapSignal.voltage], 'V', 1);
  }

  // ---- กราฟ
  p.heading('กราฟ');
  if (b != null) {
    AccelResult? pick(RemapAnalysis a, double from, double to) => a.accelFor(from, to);
    for (final (from, to) in remapAccelRanges) {
      final ra = pick(before, from, to), rb = pick(b, from, to);
      if (ra == null || rb == null) continue;
      p.chart('ความเร็วช่วง ${ra.label} กม./ชม. (ซ้อนกันที่จุดเริ่มจับเวลา)', [
        XySeries(label: 'ก่อน ${ra.seconds.toStringAsFixed(2)} วิ', points: accelTrace(before, ra), color: cBefore, dots: false),
        XySeries(label: 'หลัง ${rb.seconds.toStringAsFixed(2)} วิ', points: accelTrace(b, rb), color: cAfter, dots: false),
      ], xUnit: 'วิ', yUnit: 'กม./ชม.', xDecimals: 1);
      break;
    }
    for (final (s, name, unit, dec) in [
      (RemapSignal.boost, 'บูสต์สูงสุดตามรอบเครื่อง ตอนเร่งหนัก', 'kPa (เกจ)', 0),
      (RemapSignal.rail, 'ความดันรางสูงสุดตามรอบเครื่อง ตอนเร่งหนัก', 'MPa', 0),
    ]) {
      final pa = binnedMax(versusRpm(before, s)), pb = binnedMax(versusRpm(b, s));
      if (pa.length < 2 && pb.length < 2) continue;
      p.chart(name, [
        XySeries(label: 'ก่อน', points: pa, color: cBefore),
        XySeries(label: 'หลัง', points: pb, color: cAfter),
      ], xUnit: 'รอบ', yUnit: unit, yDecimals: dec);
    }
  } else {
    final a = before;
    List<(double, double)> gauge(List<(double, double)> pts) => [for (final (t, v) in pts) (t, v - a.baro)];
    final boost = gauge(a.run.signal(RemapSignal.boost));
    final boostCmd = gauge(a.run.signal(RemapSignal.boostCmd));
    if (boost.length >= 2) {
      p.chart('บูสต์ (เกจ) ตลอดการทดสอบ', [
        XySeries(label: 'จริง', points: boost, color: cAfter, dots: false),
        if (boostCmd.length >= 2) XySeries(label: 'ที่กล่องต้องการ', points: boostCmd, color: cBefore, dots: false),
      ], xUnit: 'วิ', yUnit: 'kPa');
    }
    final rail = a.run.signal(RemapSignal.rail), railCmd = a.run.signal(RemapSignal.railCmd);
    if (rail.length >= 2) {
      p.chart('ความดันรางตลอดการทดสอบ', [
        XySeries(label: 'จริง', points: rail, color: cAfter, dots: false),
        if (railCmd.length >= 2) XySeries(label: 'ที่กล่องต้องการ', points: railCmd, color: cBefore, dots: false),
      ], xUnit: 'วิ', yUnit: 'MPa');
    }
    final speed = a.run.signal(RemapSignal.speed);
    if (speed.length >= 2) {
      p.chart('ความเร็วรถ', [XySeries(label: '', points: speed, color: _good, dots: false)], xUnit: 'วิ', yUnit: 'กม./ชม.');
    }
  }

  // ---- สิ่งที่พบ
  void events(String head, RemapAnalysis a) {
    p.heading(head);
    if (a.events.isEmpty) {
      p.mark(CheckLevel.ok, 'ไม่พบสิ่งผิดปกติ', 'บูสต์/ความดันรางตามที่กล่องต้องการ ไม่มีรหัสปัญหาใหม่ ความร้อนอยู่ในเกณฑ์');
      return;
    }
    for (final e in a.events) {
      p.mark(_remapCheck(e.level), [e.kind.titleTh, if (e.whenTh != null) '(${e.whenTh})'].join(' '), e.detail);
    }
  }

  if (b != null) {
    events('สิ่งที่พบ: รอบหลัง', b);
    events('สิ่งที่พบ: รอบก่อน', before);
  } else {
    events('สิ่งที่พบ', before);
  }

  // ---- รหัสปัญหา
  p.heading('รหัสปัญหาเครื่องยนต์');
  void dtc(String prefix, RemapRun r) {
    String list(List<String> l) => l.isEmpty ? 'ไม่มี' : l.join(', ');
    p.kv('$prefixก่อนทดสอบ', list(r.dtcBefore));
    p.kv('$prefixหลังทดสอบ', list(r.dtcAfter), valueColor: r.dtcAfter.any((c) => !r.dtcBefore.contains(c)) ? _bad : null);
    if (r.note.isNotEmpty) p.para(r.note, size: 9, color: _dim);
  }

  if (b != null) {
    dtc('รอบก่อน: ', before.run);
    dtc('รอบหลัง: ', b.run);
  } else {
    dtc('', before.run);
  }

  p.gap(10);
  p.rule();
  p.para(
    'ค่าทั้งหมดอ่านจากช่อง OBD-II ระหว่างขับทดสอบ (อ่านอย่างเดียว ไม่ได้เขียนหรือแก้ไขกล่อง) ความเร็วจากกล่องอาจคลาดจากจริงตามขนาดยาง '
    'การเทียบก่อน/หลังควรใช้เส้นทาง น้ำหนักบรรทุก น้ำมัน และอากาศใกล้เคียงกัน ทดสอบในพื้นที่ปิดเท่านั้น',
    size: 9,
    color: _dim,
  );

  final pages = await p.render();
  logo?.dispose();
  final doc = pw.Document(title: title, creator: 'ProScaner');
  for (final png in pages) {
    final img = pw.MemoryImage(png);
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: pw.EdgeInsets.zero,
      build: (_) => pw.Image(img, fit: pw.BoxFit.fill),
    ));
  }
  return doc.save();
}

/// สร้างรายงานทดสอบรีแมพแล้วเปิดหน้าต่างแชร์
Future<void> shareRemapPdf(BuildContext context, WidgetRef ref, {required RemapAnalysis before, RemapAnalysis? after}) async {
  final messenger = ScaffoldMessenger.of(context);
  final box = context.findRenderObject() as RenderBox?;
  messenger.showSnackBar(const SnackBar(content: Text('กำลังสร้างรายงาน PDF…'), duration: Duration(seconds: 2)));
  try {
    final settings = ref.read(settingsProvider);
    final bytes = await buildRemapPdf(before: before, after: after, shop: settings.shop, accent: settings.accent.color);
    final dir = await getTemporaryDirectory();
    final t = (after ?? before).run.start;
    final kind = after == null ? 'Test' : 'Compare';
    final name = 'ProScaner_Remap${kind}_${t.year}${_two(t.month)}${_two(t.day)}_${_two(t.hour)}${_two(t.minute)}.pdf';
    final file = File('${dir.path}/$name');
    await file.writeAsBytes(bytes, flush: true);
    await SharePlus.instance.share(ShareParams(
      files: [XFile(file.path, mimeType: 'application/pdf', name: name)],
      subject: after == null ? 'รายงานทดสอบขับ' : 'รายงานเทียบก่อน/หลังรีแมพ',
      sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
    ));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('สร้างรายงานไม่สำเร็จ: $e')));
  }
}
