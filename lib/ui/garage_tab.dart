import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/analysis/odometer_check.dart' show formatKm;
import '../core/analysis/vin.dart';
import '../data/garage_store.dart';
import '../state/providers.dart';
import 'theme.dart';
import 'vehicle_identity.dart';
import 'vehicle_screen.dart';
import 'widgets/common.dart';

/// แท็บโรงรถ: รถทุกคันที่เคยเชื่อมต่อหรือเพิ่มเอง พร้อมลูกค้าและกำหนดบำรุงรักษา
class GarageTab extends ConsumerWidget {
  const GarageTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final garage = ref.watch(garageProvider);
    final session = ref.watch(sessionProvider);
    final mode = ref.watch(appModeProvider);
    final cs = Theme.of(context).colorScheme;

    return Stack(children: [
      garage.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('อ่านข้อมูลโรงรถไม่ได้: $e')),
        data: (list) {
          if (list.isEmpty) {
            return EmptyState(
              icon: Icons.garage_rounded,
              title: 'ยังไม่มีรถในโรงรถ',
              text: mode == AppMode.mechanic
                  ? 'รถจะถูกเพิ่มอัตโนมัติเมื่อสแกน (จาก VIN)\nหรือกดเพิ่มรถของลูกค้าเอง'
                  : 'รถจะถูกเพิ่มอัตโนมัติเมื่อสแกนครั้งแรก\nใช้ติดตามเลขไมล์และกำหนดเปลี่ยนน้ำมันเครื่อง',
            );
          }
          final now = DateTime.now();
          bool isCurrent(Vehicle v) =>
              session.isConnected && (v.id == session.vehicleId || (v.vin != null && v.vin == session.vin));
          final sorted = [...list]..sort((a, b) {
              final ca = isCurrent(a) ? 0 : 1;
              final cb = isCurrent(b) ? 0 : 1;
              if (ca != cb) return ca - cb;
              final ta = a.odometer.isEmpty ? a.created : a.odometer.last.time;
              final tb = b.odometer.isEmpty ? b.created : b.odometer.last.time;
              return tb.compareTo(ta);
            });
          return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 96), children: [
            for (final v in sorted)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _VehicleTile(
                  vehicle: v,
                  current: isCurrent(v),
                  dueCount: v.maintenance.where((m) => m.isDue(v.latestKm, now)).length,
                ),
              ),
          ]);
        },
      ),
      Positioned(
        right: 16,
        bottom: 16,
        child: FloatingActionButton.extended(
          heroTag: 'add_vehicle',
          backgroundColor: cs.primary,
          foregroundColor: cs.onPrimary,
          icon: const Icon(Icons.add_rounded),
          label: const Text('เพิ่มรถ'),
          onPressed: () async {
            final v = await editVehicleDialog(context, Vehicle(id: 'car_${DateTime.now().millisecondsSinceEpoch}'));
            if (v != null) await ref.read(garageProvider.notifier).upsert(v);
          },
        ),
      ),
    ]);
  }
}

class _VehicleTile extends StatelessWidget {
  const _VehicleTile({required this.vehicle, required this.current, required this.dueCount});

  final Vehicle vehicle;
  final bool current;
  final int dueCount;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final v = vehicle;
    final info = v.vin == null ? null : decodeVin17(v.vin!);
    final spec = vehicleSpecLine(v);
    final sub = [
      if (v.displayName != null && v.displayName != v.title) v.displayName!,
      if (spec.isNotEmpty) spec,
      if (v.make == null && info != null && info.valid && info.maker != null) info.maker!,
      if (v.customer != null && v.customer!.isNotEmpty) 'ลูกค้า: ${v.customer}',
      if (v.latestKm != null) formatKm(v.latestKm!),
    ].join('\u00A0· ');
    return PremiumCard(
      glow: current ? cs.primary : null,
      padding: const EdgeInsets.all(14),
      radius: 18,
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => VehicleScreen(vehicleId: v.id))),
      child: Row(children: [
        BrandBadge(make: v.make ?? info?.brand, size: 50),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // ชื่อรถยาวขึ้นบรรทัดใหม่ได้ ป้าย "เชื่อมต่ออยู่" ลงบรรทัดถัดไปเองถ้าที่ไม่พอ
            Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text(v.title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5)),
              if (current) const Pill(text: 'เชื่อมต่ออยู่', color: StatusColors.good),
            ]),
            if (sub.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(sub, style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant)),
            ],
            if (v.plate != null && v.plate!.isNotEmpty && v.plate != v.title) ...[
              const SizedBox(height: 3),
              Text(v.plate!, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
            ],
          ]),
        ),
        if (dueCount > 0)
          Pill(text: 'ถึงกำหนด $dueCount', color: StatusColors.warn, icon: Icons.build_rounded)
        else
          Icon(Icons.chevron_right_rounded, color: cs.onSurfaceVariant),
      ]),
    );
  }
}
