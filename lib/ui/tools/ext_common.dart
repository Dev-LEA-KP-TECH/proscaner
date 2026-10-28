import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/obd/ext_pid.dart';
import '../../data/garage_store.dart';
import '../../state/live_poller.dart';
import '../../state/providers.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// รถคันที่ต่ออยู่ (ถ้ารู้)
Vehicle? currentVehicle(WidgetRef ref, {bool watch = true}) {
  final session = watch ? ref.watch(sessionProvider) : ref.read(sessionProvider);
  final garage = (watch ? ref.watch(garageProvider) : ref.read(garageProvider)).valueOrNull ?? const <Vehicle>[];
  return garage.where((v) => session.vehicleId != null && v.id == session.vehicleId).firstOrNull ??
      (session.vin == null ? null : garage.where((v) => v.vin == session.vin).firstOrNull);
}

/// ชุดค่า (ยี่ห้อ/รุ่น/ปีของชุด) ทำไว้สำหรับรถคันที่ต่ออยู่หรือไม่ (ดู [packFitsVehicle])
/// ถ้าไม่ใช่ ให้ถามเฉพาะกล่องเลขมาตรฐาน เพราะเลขเฉพาะยี่ห้ออาจชนกับข้อความปกติของรถคันนี้
bool fitsCurrentVehicle(
  WidgetRef ref, {
  required String brand,
  List<String> models = const [],
  List<int> years = const [],
  bool watch = false,
}) {
  final v = currentVehicle(ref, watch: watch);
  return packFitsVehicle(
    packBrand: brand,
    packModels: models,
    packYears: years,
    make: v?.make,
    model: v?.model,
    year: v?.year,
  );
}

/// ข้อความรถสำหรับบันทึกผลยืนยัน เช่น "Toyota Hilux Revo 2019 (VIN …345678)"
String vehicleLabel(Vehicle? v, {String? vin}) {
  final parts = <String>[
    if (v?.make != null) v!.make!,
    if (v?.model != null) v!.model!,
    if (v?.year != null) '${v!.year}',
  ];
  final id = v?.vin ?? vin;
  final tail = id != null && id.length >= 6 ? 'VIN …${id.substring(id.length - 6)}' : null;
  if (parts.isEmpty) return tail ?? 'รถคันที่ต่ออยู่';
  return tail == null ? parts.join(' ') : '${parts.join(' ')} ($tail)';
}

/// ป้ายระดับความเชื่อถือของค่า
class TrustPill extends StatelessWidget {
  const TrustPill({super.key, required this.pid, this.compact = false});

  final ExtPid pid;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final (text, color, icon) = trustStyle(pid);
    if (compact) return Icon(icon, size: 16, color: color);
    return Pill(text: text, color: color, icon: icon);
  }
}

(String, Color, IconData) trustStyle(ExtPid p) {
  if (p.verified) return ('ร้านยืนยันแล้ว', StatusColors.good, Icons.verified_rounded);
  if (p.hasEvidence) {
    final ys = p.seenYears.isNotEmpty ? p.seenYears : p.evidence.map((e) => e.year).toSet().toList()..sort();
    final y = ys.isEmpty ? '' : ' ${ys.length == 1 ? ys.first : '${ys.first}–${ys.last}'}';
    return ('พบในรถจริง$y', StatusColors.info, Icons.fact_check_rounded);
  }
  return ('รอยืนยัน', StatusColors.warn, Icons.help_outline_rounded);
}

/// หยุดตัวอ่านค่าสดชั่วคราว (ต้องเปลี่ยน header ไปคุยกับกล่องอื่น)
/// (ต้องเก็บ LivePoller ไว้ตั้งแต่ initState เพราะห้ามใช้ ref ใน dispose)
void pausePoller(LivePoller poller, Object key) => poller.subscribe(key, const <int>[], priority: true);
void resumePoller(LivePoller poller, Object key) => poller.unsubscribe(key);

/// กล่องรับข้อความ
Future<String?> askText(BuildContext context, String title,
    {String? hint, String? initial, bool multiline = false, TextInputType? keyboard}) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 520,
        child: TextField(
          controller: c,
          autofocus: true,
          keyboardType: keyboard,
          minLines: multiline ? 6 : 1,
          maxLines: multiline ? 12 : 1,
          style: multiline ? const TextStyle(fontSize: 12.5) : null,
          decoration: InputDecoration(hintText: hint),
        ),
      ),
      actions: [
        if (multiline)
          TextButton(
            onPressed: () async {
              final d = await Clipboard.getData(Clipboard.kTextPlain);
              if (d?.text != null) c.text = d!.text!;
            },
            child: const Text('วางจากคลิปบอร์ด'),
          ),
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('ยกเลิก')),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('ตกลง')),
      ],
    ),
  );
}

/// แสดงไบต์ข้อมูลพร้อมชื่อตัวแปร A, B, C … (ไฮไลต์ไบต์ที่สูตรใช้และไบต์ที่เพิ่งเปลี่ยน)
class ByteGrid extends StatelessWidget {
  const ByteGrid({super.key, required this.bytes, this.used = const {}, this.changed = const {}, this.onTap, this.selected = const {}});

  final List<int> bytes;
  final Set<int> used;

  /// จำนวนครั้งที่ไบต์นี้เปลี่ยนค่า (ยิ่งมากยิ่งเข้ม)
  final Map<int, int> changed;
  final Set<int> selected;
  final void Function(int index)? onTap;

  static String letter(int i) =>
      i < 26 ? String.fromCharCode(65 + i) : '${String.fromCharCode(64 + i ~/ 26)}${String.fromCharCode(65 + i % 26)}';

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final maxChange = changed.values.fold<int>(0, (a, b) => a > b ? a : b);
    return Wrap(spacing: 6, runSpacing: 6, children: [
      for (var i = 0; i < bytes.length; i++)
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap == null ? null : () => onTap!(i),
          child: Container(
            width: 50,
            padding: const EdgeInsets.symmetric(vertical: 5),
            decoration: BoxDecoration(
              color: Color.alphaBlend(
                StatusColors.warn.withValues(alpha: maxChange == 0 ? 0 : 0.35 * (changed[i] ?? 0) / maxChange),
                selected.contains(i) ? cs.primary.withValues(alpha: 0.25) : cs.surfaceContainerHighest,
              ),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: used.contains(i) || selected.contains(i) ? cs.primary : cs.outline,
                width: used.contains(i) || selected.contains(i) ? 1.6 : 1,
              ),
            ),
            child: Column(children: [
              Text(letter(i), style: TextStyle(fontSize: 10.5, color: cs.onSurfaceVariant, fontWeight: FontWeight.w700)),
              Text(bytes[i].toRadixString(16).padLeft(2, '0').toUpperCase(),
                  style: const TextStyle(fontFamily: kMono, fontWeight: FontWeight.w700, fontSize: 14)),
              Text('${bytes[i]}', style: TextStyle(fontSize: 10.5, color: cs.onSurfaceVariant)),
            ]),
          ),
        ),
    ]);
  }
}

/// ไบต์ที่สูตรใช้ (A = 0)
Set<int> formulaBytes(String formula) {
  final out = <int>{};
  final re = RegExp(r'(?<![A-Za-z0-9])([A-Z]{1,2})(?![A-Za-z0-9(])');
  for (final m in re.allMatches(formula)) {
    final t = m.group(1)!;
    final i = t.length == 1 ? t.codeUnitAt(0) - 65 : (t.codeUnitAt(0) - 64) * 26 + (t.codeUnitAt(1) - 65);
    out.add(i);
  }
  return out;
}
