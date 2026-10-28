import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/analysis/vehicle_catalog.dart';
import '../core/analysis/vin.dart';
import '../data/garage_store.dart';
import '../state/providers.dart';
import 'theme.dart';
import 'widgets/common.dart';

/// ไฟล์โลโก้ยี่ห้อที่มีอยู่ในแอป (โหลดรายชื่อครั้งเดียว)
Future<Set<String>>? _logoAssets;

/// รายชื่อที่โหลดเสร็จแล้ว: ตราที่สร้างใหม่ใช้ได้ทันทีตั้งแต่เฟรมแรก
/// (ไม่ขึ้นเป็นตัวอักษรย่อแวบหนึ่งก่อนเปลี่ยนเป็นโลโก้ เช่นตอนเลื่อนรายการหรือเปิดหน้าใหม่)
Set<String>? _logoAssetsReady;

Future<Set<String>> _loadLogoAssets() async {
  try {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final found = manifest.listAssets().where((a) => a.startsWith('assets/brand_logos/') && a.endsWith('.png')).toSet();
    _logoAssetsReady = found;
    return found;
  } catch (_) {
    // อ่านรายชื่อไม่ได้: ใช้ตัวอักษรย่อไปก่อน และไม่จำผลที่ล้มเหลว ครั้งหน้าจะลองอ่านใหม่
    _logoAssets = null;
    return const {};
  }
}

/// ตรายี่ห้อ: ถ้ามีไฟล์โลโก้ใน assets/brand_logos/ จะแสดงโลโก้นั้น
/// ถ้าไม่มี แสดงตัวอักษรย่อบนสีประจำแบรนด์
class BrandBadge extends StatelessWidget {
  const BrandBadge({super.key, required this.make, this.size = 48});

  final String? make;
  final double size;

  @override
  Widget build(BuildContext context) {
    final name = normalizeBrand(make);
    if (name == null || name.isEmpty) return _initials(context);
    final path = brandLogoAsset(name);
    return FutureBuilder<Set<String>>(
      future: _logoAssets ??= _loadLogoAssets(),
      initialData: _logoAssetsReady,
      builder: (context, snap) {
        if (!(snap.data?.contains(path) ?? false)) return _initials(context);
        return Container(
          width: size,
          height: size,
          padding: EdgeInsets.all(size * 0.14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(size * 0.28),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: size * 0.2, spreadRadius: -size * 0.06)],
          ),
          child: Image.asset(path, fit: BoxFit.contain, filterQuality: FilterQuality.high,
              errorBuilder: (c, e, s) => _initials(c)),
        );
      },
    );
  }

  Widget _initials(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final b = brandByName(make);
    final base = b == null ? cs.primary : Color(b.color);
    final dark = Color.lerp(base, Colors.black, 0.55)!;
    final text = b?.initials ?? (make != null && make!.trim().isNotEmpty ? make!.trim()[0].toUpperCase() : null);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.28),
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [base, dark]),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
        boxShadow: [BoxShadow(color: base.withValues(alpha: 0.35), blurRadius: size * 0.25, spreadRadius: -size * 0.06)],
      ),
      alignment: Alignment.center,
      child: text == null
          ? Icon(Icons.directions_car_filled_rounded, color: Colors.white, size: size * 0.55)
          : Padding(
              padding: EdgeInsets.all(size * 0.12),
              child: FittedBox(
                child: Text(text,
                    style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w900, fontSize: size * 0.42, letterSpacing: 0.5, height: 1)),
              ),
            ),
    );
  }
}

/// ป้ายบอกที่มาของข้อมูลรถ
Widget identitySourcePill(Vehicle v) => switch (v.idSource) {
      'vin' => const Pill(text: 'ระบุอัตโนมัติจาก VIN', color: StatusColors.good, icon: Icons.auto_awesome_rounded),
      'learned' => const Pill(text: 'จำจากรถรุ่นเดียวกัน', color: StatusColors.good, icon: Icons.auto_awesome_rounded),
      'manual' => const Pill(text: 'ระบุเอง', color: Color(0xFF8A95A5), icon: Icons.edit_rounded),
      _ => const SizedBox.shrink(),
    };

/// รายละเอียดสั้น เช่น "ปี 2019 · ดีเซล"
String vehicleSpecLine(Vehicle v) => [
      if (v.year != null) 'ปี\u00A0${v.year}',
      if (v.fuel != null) v.fuel!,
    ].join('\u00A0· ');

const fuelOptions = ['ดีเซล', 'เบนซิน', 'ไฮบริด', 'ไฟฟ้า'];

/// แผ่นเลือกยี่ห้อ / รุ่น / ปี / เชื้อเพลิง แตะครั้งเดียวต่อช่อง คืน true ถ้าบันทึก
Future<bool> editIdentitySheet(BuildContext context, WidgetRef ref, Vehicle v) async {
  final info = v.vin == null ? null : decodeVin17(v.vin!);
  String? make = v.make ?? normalizeBrand(info?.brand);
  String? model = v.model;
  int? year = v.year ?? (info != null && info.yearReliable ? info.modelYear : null);
  String? fuel = v.fuel;
  var showAllBrands = false;
  final initialModel = v.model;
  final isCustom = initialModel != null && !(brandByName(make)?.models.contains(initialModel) ?? false);
  final custom = TextEditingController(text: isCustom ? initialModel : '');
  final nowYear = DateTime.now().year;

  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (c) => StatefulBuilder(builder: (c, set) {
      final cs = Theme.of(c).colorScheme;
      final brand = brandByName(make);
      final brands = showAllBrands ? brandCatalog : brandCatalog.take(12).toList();
      final hasMake = brands.any((b) => b.name == make);
      Widget label(String t) => Padding(
            padding: const EdgeInsets.only(top: 16, bottom: 8),
            child: Text(t, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5)),
          );
      return Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.viewInsetsOf(c).bottom + MediaQuery.paddingOf(c).bottom + 20),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * 0.82),
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                BrandBadge(make: make, size: 44),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text([make, model].whereType<String>().join(' ').ifEmpty('ระบุรถคันนี้'),
                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
                    if (info?.maker != null)
                      Text('VIN บอกผู้ผลิต: ${info!.maker}', style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant)),
                  ]),
                ),
              ]),
              label('ยี่ห้อ'),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final b in brands)
                  ChoiceChip(
                    label: FitText(b.name),
                    selected: make == b.name,
                    onSelected: (_) => set(() {
                      if (make != b.name) {
                        model = null;
                        custom.clear();
                      }
                      make = b.name;
                    }),
                  ),
                if (!hasMake && make != null) ChoiceChip(label: Text(make!), selected: true, onSelected: (_) {}),
                ActionChip(
                  avatar: Icon(showAllBrands ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 18),
                  label: Text(showAllBrands ? 'ย่อ' : 'ยี่ห้ออื่น'),
                  onPressed: () => set(() => showAllBrands = !showAllBrands),
                ),
              ]),
              if (brand != null) ...[
                label('รุ่น'),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final m in brand.models)
                    ChoiceChip(
                      label: FitText(m),
                      selected: model == m,
                      onSelected: (_) => set(() {
                        model = m;
                        custom.clear();
                      }),
                    ),
                ]),
              ] else
                label('รุ่น'),
              const SizedBox(height: 10),
              TextField(
                controller: custom,
                decoration: const InputDecoration(labelText: 'ไม่มีในรายการ? พิมพ์ชื่อรุ่นเอง', isDense: true),
                onChanged: (t) => set(() => model = t.trim().isEmpty ? null : t.trim()),
              ),
              label('ปีรถ'),
              DropdownButtonFormField<int?>(
                initialValue: year,
                isDense: true,
                decoration: InputDecoration(
                  helperMaxLines: 2,
                  helperText: info != null && !info.yearReliable ? 'รถผลิตในไทย/ญี่ปุ่นส่วนใหญ่ไม่ได้ใส่ปีไว้ใน VIN ดูปีจากเล่มทะเบียน' : null,
                ),
                items: [
                  const DropdownMenuItem<int?>(value: null, child: Text('ไม่ระบุ')),
                  for (var y = nowYear + 1; y >= 1990; y--) DropdownMenuItem<int?>(value: y, child: Text('$y')),
                ],
                onChanged: (y) => set(() => year = y),
              ),
              label('เชื้อเพลิง'),
              SegmentedButton<String>(
                emptySelectionAllowed: true,
                showSelectedIcon: false,
                segments: [for (final f in fuelOptions) ButtonSegment(value: f, label: FitText(f, alignment: Alignment.center))],
                selected: {if (fuel != null) fuel!},
                onSelectionChanged: (s) => set(() => fuel = s.isEmpty ? null : s.first),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                icon: const Icon(Icons.check_rounded),
                label: const Text('บันทึก'),
                style: FilledButton.styleFrom(minimumSize: const Size(0, 50)),
                onPressed: () => Navigator.pop(c, true),
              ),
            ]),
          ),
        ),
      );
    }),
  );
  if (ok != true) return false;
  v
    ..make = make
    ..model = model
    ..year = year
    ..fuel = fuel
    ..idSource = 'manual';
  await ref.read(garageProvider.notifier).upsert(v);
  return true;
}

/// เลือกรถจากโรงรถให้คันที่เชื่อมต่ออยู่ (รถที่ไม่ส่ง VIN) หรือเพิ่มคันใหม่
Future<void> chooseVehicleSheet(BuildContext context, WidgetRef ref) async {
  final garage = ref.read(garageProvider).valueOrNull ?? const <Vehicle>[];
  final current = ref.read(sessionProvider).vehicleId;
  final picked = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (c) {
      final cs = Theme.of(c).colorScheme;
      return ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * 0.75),
        child: ListView(shrinkWrap: true, padding: EdgeInsets.fromLTRB(16, 0, 16, 24 + MediaQuery.paddingOf(c).bottom), children: [
          const Text('รถคันนี้คือคันไหน?', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
          const SizedBox(height: 4),
          Text('รถคันนี้ไม่ส่งเลขตัวถัง (VIN) แอปจึงระบุเองไม่ได้ เลือกครั้งเดียว ผลสแกนและเลขไมล์จะบันทึกเข้ารถคันนี้',
              style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant, height: 1.4)),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            icon: const Icon(Icons.add_rounded),
            label: const Text('เพิ่มรถคันใหม่'),
            onPressed: () => Navigator.pop(c, '__new__'),
          ),
          const SizedBox(height: 8),
          for (final v in garage)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: PremiumCard(
                radius: 16,
                padding: const EdgeInsets.all(12),
                glow: v.id == current ? cs.primary : null,
                onTap: () => Navigator.pop(c, v.id),
                child: Row(children: [
                  BrandBadge(make: v.make, size: 40),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(v.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                      if ([v.plate, vehicleSpecLine(v)].any((s) => s != null && s.isNotEmpty))
                        Text([v.plate, vehicleSpecLine(v)].whereType<String>().where((s) => s.isNotEmpty).join('\u00A0· '),
                            style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant)),
                    ]),
                  ),
                  if (v.id == current) Icon(Icons.check_circle_rounded, color: cs.primary),
                ]),
              ),
            ),
        ]),
      );
    },
  );
  if (picked == null || !context.mounted) return;
  if (picked == '__new__') {
    final session = ref.read(sessionProvider);
    final v = Vehicle(id: 'car_${DateTime.now().millisecondsSinceEpoch}', fuel: session.diesel ? 'ดีเซล' : null);
    await ref.read(garageProvider.notifier).upsert(v);
    ref.read(sessionProvider.notifier).selectVehicle(v.id);
    if (context.mounted) await editIdentitySheet(context, ref, v);
  } else {
    ref.read(sessionProvider.notifier).selectVehicle(picked);
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}
