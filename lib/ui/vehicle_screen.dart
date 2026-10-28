import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/analysis/odometer_check.dart' show formatKm;
import '../core/analysis/vehicle_catalog.dart';
import '../core/analysis/vin.dart';
import '../data/garage_store.dart';
import '../state/providers.dart';
import 'history_screen.dart';
import 'qr_scan_screen.dart';
import 'theme.dart';
import 'vehicle_identity.dart';
import 'widgets/common.dart';
import 'widgets/gauges.dart';

/// แก้ไขข้อมูลรถ/ลูกค้า คืนรถที่แก้แล้ว (null = ยกเลิก)
Future<Vehicle?> editVehicleDialog(BuildContext context, Vehicle v) async {
  final nick = TextEditingController(text: v.nickname);
  final plate = TextEditingController(text: v.plate ?? '');
  final vin = TextEditingController(text: v.vin ?? '');
  final cust = TextEditingController(text: v.customer ?? '');
  final phone = TextEditingController(text: v.phone ?? '');
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (c) => Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.of(c).viewInsets.bottom + 20),
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          const Text('ข้อมูลรถ', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
          const SizedBox(height: 12),
          TextField(controller: nick, decoration: const InputDecoration(labelText: 'ชื่อเรียก เช่น วีโก้สีขาว')),
          const SizedBox(height: 10),
          TextField(controller: plate, decoration: const InputDecoration(labelText: 'ทะเบียนรถ')),
          const SizedBox(height: 10),
          TextField(
            controller: vin,
            enabled: v.vin == null || v.vin!.isEmpty || v.id.startsWith('car_'),
            textCapitalization: TextCapitalization.characters,
            inputFormatters: [LengthLimitingTextInputFormatter(17)],
            decoration: const InputDecoration(labelText: 'เลขตัวถัง (VIN) 17 หลัก'),
            style: const TextStyle(fontFamily: kMono),
          ),
          const SizedBox(height: 18),
          const Text('ลูกค้า (สำหรับอู่)', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          TextField(controller: cust, decoration: const InputDecoration(labelText: 'ชื่อลูกค้า')),
          const SizedBox(height: 10),
          TextField(
            controller: phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'เบอร์โทร'),
          ),
          const SizedBox(height: 18),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('บันทึก')),
        ]),
      ),
    ),
  );
  Vehicle? out;
  if (ok == true) {
    String? t(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
    v
      ..nickname = nick.text.trim()
      ..plate = t(plate)
      ..customer = t(cust)
      ..phone = t(phone);
    final newVin = t(vin)?.toUpperCase();
    if (newVin != null) {
      v.vin = newVin;
      // ใส่ VIN เอง → เติมยี่ห้อให้อัตโนมัติถ้ายังว่าง
      final i = decodeVin17(newVin);
      if (v.make == null && i.brand != null) {
        v.make = normalizeBrand(i.brand);
        v.idSource ??= 'vin';
      }
      if (v.year == null && i.yearReliable && i.modelYear != null) v.year = i.modelYear;
    }
    out = v;
  }
  return out;
}

class VehicleScreen extends ConsumerWidget {
  const VehicleScreen({super.key, required this.vehicleId});

  final String vehicleId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(garageProvider).valueOrNull ?? const <Vehicle>[];
    final v = list.where((x) => x.id == vehicleId).firstOrNull;
    final mode = ref.watch(appModeProvider);
    final cs = Theme.of(context).colorScheme;
    if (v == null) {
      return Scaffold(appBar: AppBar(), body: const EmptyState(icon: Icons.car_crash_rounded, title: 'ไม่พบรถคันนี้'));
    }
    final notifier = ref.read(garageProvider.notifier);
    Future<void> save() => notifier.upsert(v);
    final info = v.vin == null ? null : decodeVin17(v.vin!);
    final now = DateTime.now();
    final km = v.latestKm;

    return Scaffold(
      appBar: AppBar(
        title: Text(v.title),
        actions: [
          IconButton(
            tooltip: 'แก้ไข',
            icon: const Icon(Icons.edit_rounded),
            onPressed: () async {
              final e = await editVehicleDialog(context, v);
              if (e != null) await save();
            },
          ),
          PopupMenuButton<String>(
            onSelected: (s) async {
              if (s != 'delete') return;
              final ok = await showDialog<bool>(
                context: context,
                builder: (d) => AlertDialog(
                  title: const Text('ลบรถคันนี้ออกจากโรงรถ?'),
                  content: const Text('ข้อมูลบำรุงรักษา เลขไมล์ และรหัสหัวฉีดของรถคันนี้จะถูกลบ (ประวัติการสแกนยังอยู่)'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('ยกเลิก')),
                    FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: StatusColors.bad),
                      onPressed: () => Navigator.pop(d, true),
                      child: const Text('ลบ'),
                    ),
                  ],
                ),
              );
              if (ok == true) {
                await notifier.remove(v.id);
                if (context.mounted) Navigator.of(context).pop();
              }
            },
            itemBuilder: (_) => const [PopupMenuItem(value: 'delete', child: Text('ลบรถคันนี้'))],
          ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
        PremiumCard(
          glow: cs.primary,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              BrandBadge(make: v.make ?? info?.brand, size: 56),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(v.title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
                  if (v.displayName != null && v.displayName != v.title)
                    Text(v.displayName!, style: const TextStyle(fontWeight: FontWeight.w600)),
                  if (vehicleSpecLine(v).isNotEmpty)
                    Text(vehicleSpecLine(v), style: TextStyle(color: cs.onSurfaceVariant))
                  else if (info != null && info.valid && info.maker != null)
                    Text(info.maker!, style: TextStyle(color: cs.onSurfaceVariant)),
                  const SizedBox(height: 6),
                  identitySourcePill(v),
                ]),
              ),
            ]),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.tune_rounded, size: 18),
                label: Text(v.needsModel ? 'ระบุยี่ห้อ / รุ่น / ปี' : 'แก้ยี่ห้อ / รุ่น / ปี'),
                onPressed: () => editIdentitySheet(context, ref, v),
              ),
            ),
            if (info != null && info.valid && info.maker != null && v.make != null) KvRow('ผู้ผลิตตาม VIN', info.maker!),
            if (v.plate != null) KvRow('ทะเบียน', v.plate!),
            if (v.vin != null) KvRow('VIN', v.vin!, mono: true),
            KvRow('เลขไมล์ล่าสุด', km == null ? 'ยังไม่มีข้อมูล' : formatKm(km)),
            if (v.customer != null) KvRow('ลูกค้า', v.customer!),
            if (v.phone != null) KvRow('โทร', v.phone!),
          ]),
        ),
        SectionLabel('บำรุงรักษา',
            trailing: TextButton.icon(
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('เพิ่ม'),
              onPressed: () async {
                final item = await _editMaint(context, MaintItem(name: ''));
                if (item != null && item.name.isNotEmpty) {
                  v.maintenance.add(item);
                  await save();
                }
              },
            )),
        PremiumCard(
          padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
          child: Column(children: [
            for (final m in v.maintenance)
              _MaintRow(
                item: m,
                km: km,
                now: now,
                onDone: () async {
                  final at = await _askKm(context, km);
                  if (at == null) return;
                  m
                    ..lastKm = at
                    ..lastDate = DateTime.now();
                  await save();
                },
                onEdit: () async {
                  final e = await _editMaint(context, m);
                  if (e == null) return;
                  if (e.name.isEmpty) v.maintenance.remove(m);
                  await save();
                },
              ),
          ]),
        ),
        if (km == null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('สแกนรถหรือเช็คเลขไมล์ เพื่อให้แอปคำนวณระยะที่เหลือ',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          ),
        if (v.odometer.isNotEmpty) ...[
          const SectionLabel('ประวัติเลขไมล์'),
          PremiumCard(
            child: Column(children: [
              if (v.odometer.where((e) => e.km != null).length >= 2)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Sparkline(
                    values: [for (final e in v.odometer) if (e.km != null) e.km!],
                    color: cs.primary,
                    height: 70,
                    showAxis: true,
                  ),
                ),
              for (final e in v.odometer.reversed.take(8))
                KvRow(
                  thaiDate(e.time),
                  [
                    if (e.dashKm != null) 'หน้าปัด ${formatKm(e.dashKm!)}',
                    if (e.ecuKm != null) 'ECU ${formatKm(e.ecuKm!)}',
                    if (e.dashKm == null && e.ecuKm == null && e.engineHours != null) '${e.engineHours!.round()} ชม.',
                  ].join('\n'),
                ),
            ]),
          ),
        ],
        if (mode == AppMode.mechanic) ...[
          SectionLabel('รหัสหัวฉีด',
              trailing: TextButton.icon(
                icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
                label: const Text('สแกน'),
                onPressed: () async {
                  final code = await Navigator.of(context).push<String>(
                    MaterialPageRoute(builder: (_) => const QrScanScreen(title: 'สแกน QR หัวฉีด')),
                  );
                  if (code == null || !context.mounted) return;
                  final inj = await _editInjector(context, v.injectors.length + 1, code);
                  if (inj != null) {
                    v.injectors
                      ..removeWhere((x) => x.cylinder == inj.cylinder)
                      ..add(inj)
                      ..sort((a, b) => a.cylinder.compareTo(b.cylinder));
                    await save();
                  }
                },
              )),
          PremiumCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (v.injectors.isEmpty)
                Text('ยังไม่มีรหัส สแกน QR บนหัวฉีดหรือพิมพ์เอง', style: TextStyle(color: cs.onSurfaceVariant))
              else
                for (final inj in v.injectors)
                  InkWell(
                    onLongPress: () async {
                      v.injectors.remove(inj);
                      await save();
                    },
                    onTap: () => Clipboard.setData(ClipboardData(text: inj.code)),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        SizedBox(width: 56, child: Text('สูบ ${inj.cylinder}', style: const TextStyle(fontWeight: FontWeight.w700))),
                        Expanded(
                          child: Text(inj.code, style: const TextStyle(fontFamily: kMono, fontSize: 13, height: 1.4)),
                        ),
                      ]),
                    ),
                  ),
              const SizedBox(height: 6),
              TextButton.icon(
                icon: const Icon(Icons.keyboard_rounded, size: 18),
                label: const Text('พิมพ์รหัสเอง'),
                onPressed: () async {
                  final inj = await _editInjector(context, v.injectors.length + 1, '');
                  if (inj != null && inj.code.isNotEmpty) {
                    v.injectors
                      ..removeWhere((x) => x.cylinder == inj.cylinder)
                      ..add(inj)
                      ..sort((a, b) => a.cylinder.compareTo(b.cylinder));
                    await save();
                  }
                },
              ),
              Text(
                'แตะเพื่อคัดลอก กดค้างเพื่อลบ · เก็บไว้อ้างอิงตอนเข้ารหัสด้วยเครื่องมือเฉพาะยี่ห้อ '
                '(ตัวสแกน PRO SCANNER เขียนรหัสหัวฉีดลงกล่องไม่ได้)',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant, height: 1.4),
              ),
            ]),
          ),
        ],
        if (v.vin != null) ...[
          const SectionLabel('ประวัติการสแกนของรถคันนี้'),
          HistoryList(vin: v.vin, shrinkWrap: true),
        ],
      ]),
    );
  }
}

class _MaintRow extends StatelessWidget {
  const _MaintRow({required this.item, required this.km, required this.now, required this.onDone, required this.onEdit});

  final MaintItem item;
  final double? km;
  final DateTime now;
  final VoidCallback onDone;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final kLeft = item.kmLeft(km);
    final dLeft = item.daysLeft(now);
    final overdue = (kLeft != null && kLeft < 0) || (dLeft != null && dLeft < 0);
    final due = item.isDue(km, now);
    final color = overdue ? StatusColors.bad : (due ? StatusColors.warn : StatusColors.good);
    final never = item.lastKm == null && item.lastDate == null;
    final parts = <String>[
      if (never) 'ยังไม่ได้บันทึกครั้งล่าสุด',
      if (kLeft != null) kLeft < 0 ? 'เลยมา ${formatKm(-kLeft)}' : 'อีก ${formatKm(kLeft)}',
      if (dLeft != null) dLeft < 0 ? 'เลยกำหนด ${-dLeft} วัน' : 'อีก $dLeft วัน',
    ];
    final every = [
      if (item.intervalKm != null) 'ทุก ${formatKm(item.intervalKm!.toDouble())}',
      if (item.intervalMonths != null) 'ทุก ${item.intervalMonths} เดือน',
    ].join(' หรือ ');
    return InkWell(
      onTap: onEdit,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          Icon(never ? Icons.radio_button_unchecked_rounded : (due ? Icons.schedule_rounded : Icons.check_circle_rounded),
              color: never ? cs.onSurfaceVariant : color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(item.name, style: const TextStyle(fontWeight: FontWeight.w600)),
              Text([every, ...parts].where((s) => s.isNotEmpty).join(' · '),
                  style: TextStyle(fontSize: 12, color: never ? cs.onSurfaceVariant : color)),
            ]),
          ),
          TextButton(onPressed: onDone, child: const Text('ทำแล้ว')),
        ]),
      ),
    );
  }
}

Future<double?> _askKm(BuildContext context, double? current) async {
  final c = TextEditingController(text: current?.round().toString() ?? '');
  final v = await showDialog<double>(
    context: context,
    builder: (d) => AlertDialog(
      title: const Text('ทำที่เลขไมล์เท่าไร'),
      content: TextField(
        controller: c,
        autofocus: true,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: const InputDecoration(suffixText: 'กม.'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: const Text('ยกเลิก')),
        FilledButton(onPressed: () => Navigator.pop(d, double.tryParse(c.text) ?? -1), child: const Text('บันทึก')),
      ],
    ),
  );
  if (v == null) return null;
  return v < 0 ? (current ?? 0) : v;
}

/// แก้ไขรายการบำรุงรักษา ชื่อว่าง = ลบ
Future<MaintItem?> _editMaint(BuildContext context, MaintItem m) async {
  final name = TextEditingController(text: m.name);
  final km = TextEditingController(text: m.intervalKm?.toString() ?? '');
  final mo = TextEditingController(text: m.intervalMonths?.toString() ?? '');
  final ok = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(m.name.isEmpty ? 'เพิ่มรายการ' : 'แก้ไขรายการ'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: name, decoration: const InputDecoration(labelText: 'รายการ')),
        const SizedBox(height: 10),
        TextField(
          controller: km,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(labelText: 'ทุกกี่ กม. (เว้นว่างได้)'),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: mo,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(labelText: 'ทุกกี่เดือน (เว้นว่างได้)'),
        ),
      ]),
      actions: [
        if (m.name.isNotEmpty)
          TextButton(
            onPressed: () {
              name.clear();
              Navigator.pop(d, true);
            },
            child: const Text('ลบ', style: TextStyle(color: StatusColors.bad)),
          ),
        TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('ยกเลิก')),
        FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('บันทึก')),
      ],
    ),
  );
  MaintItem? out;
  if (ok == true) {
    m
      ..name = name.text.trim()
      ..intervalKm = int.tryParse(km.text)
      ..intervalMonths = int.tryParse(mo.text);
    out = m;
  }
  return out;
}

Future<InjectorCode?> _editInjector(BuildContext context, int cylinder, String code) async {
  final cyl = TextEditingController(text: '$cylinder');
  final c = TextEditingController(text: code);
  final ok = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      title: const Text('รหัสหัวฉีด'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(
          controller: cyl,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(labelText: 'สูบที่'),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: c,
          maxLines: 3,
          minLines: 1,
          textCapitalization: TextCapitalization.characters,
          style: const TextStyle(fontFamily: kMono),
          decoration: const InputDecoration(labelText: 'รหัส (QR / IMA / C2I)'),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('ยกเลิก')),
        FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('บันทึก')),
      ],
    ),
  );
  InjectorCode? out;
  if (ok == true && c.text.trim().isNotEmpty) {
    out = InjectorCode(
      cylinder: int.tryParse(cyl.text) ?? cylinder,
      code: c.text.trim().toUpperCase(),
      time: DateTime.now(),
    );
  }
  return out;
}
