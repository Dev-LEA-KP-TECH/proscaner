import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/analysis/odometer_check.dart' show formatKm;
import '../core/analysis/vin.dart';
import '../core/obd/pids.dart';
import '../data/garage_store.dart';
import '../state/providers.dart';
import 'dtc_lookup_screen.dart';
import 'history_screen.dart';
import 'home_screen.dart';
import 'terminal_screen.dart';
import 'theme.dart';
import 'tools/battery_screen.dart';
import 'tools/brand_data_screen.dart';
import 'tools/dashboard_screen.dart';
import 'tools/ecu_info_screen.dart';
import 'tools/logs_screen.dart';
import 'tools/mode06_screen.dart';
import 'tools/modules_screen.dart';
import 'tools/odometer_screen.dart';
import 'tools/performance_screen.dart';
import 'tools/remap_test_screen.dart';
import 'tools/used_car_screen.dart';
import 'vehicle_identity.dart';
import 'vehicle_screen.dart';
import 'widgets/common.dart';
import 'widgets/gauges.dart';
import 'widgets/severity_style.dart';

class _Tool {
  const _Tool(this.icon, this.title, this.subtitle, this.builder, {this.color});

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget Function() builder;
  final Color? color;
}

final _ownerTools = <_Tool>[
  _Tool(Icons.speed_rounded, 'เช็คเลขไมล์', 'ไมล์ถูกหมุนหรือไม่', () => const OdometerScreen(), color: const Color(0xFF3DA5FF)),
  _Tool(Icons.policy_rounded, 'ตรวจรถมือสอง', 'สแกนครบก่อนตัดสินใจซื้อ', () => const UsedCarScreen(), color: const Color(0xFFA06BFF)),
  _Tool(Icons.dashboard_rounded, 'แดชบอร์ดขับรถ', 'จอใหญ่ + ทริป + สิ้นเปลือง', () => const DashboardScreen()),
  _Tool(Icons.battery_charging_full_rounded, 'เช็คแบตเตอรี่', 'แบต + ไดชาร์จ 4 ขั้นตอน', () => const BatteryScreen(),
      color: const Color(0xFF22C474)),
  _Tool(Icons.timeline_rounded, 'บันทึกการขับ', 'กราฟ / CSV / เทียบก่อน-หลัง', () => const LogsScreen(), color: const Color(0xFFFFA824)),
  _Tool(Icons.timer_rounded, 'จับเวลาอัตราเร่ง', '0–100, 402 ม.', () => const PerformanceScreen(), color: const Color(0xFFFF8A1F)),
  _Tool(Icons.badge_rounded, 'ข้อมูลรถ / VIN', 'ปีรุ่น ผู้ผลิต รุ่นซอฟต์แวร์', () => const EcuInfoScreen(), color: const Color(0xFF2BD9D9)),
  _Tool(Icons.history_rounded, 'ประวัติการสแกน', 'ผลทุกครั้งที่เคยตรวจ', () => const HistoryScreen()),
];

final _mechTools = <_Tool>[
  _Tool(Icons.hub_rounded, 'กล่องทั้งหมด', 'ABS ถุงลม เกียร์ · อ่าน/ลบ · DID', () => const ModulesScreen(), color: const Color(0xFFA06BFF)),
  _Tool(Icons.tune_rounded, 'ค่าเฉพาะยี่ห้อ', 'Revo Triton D-Max · หัวฉีด DPF เกียร์', () => const BrandDataScreen(),
      color: const Color(0xFFFF8A1F)),
  _Tool(Icons.rocket_launch_rounded, 'ทดสอบรีแมพ', 'ก่อน/หลัง · บูสต์ ราง อัตราเร่ง', () => const RemapTestScreen(),
      color: const Color(0xFFFF4D5A)),
  _Tool(Icons.science_rounded, 'Mode 06', 'misfire รายสูบ แคท O2', () => const Mode06Screen(), color: const Color(0xFF22C474)),
  _Tool(Icons.manage_search_rounded, 'ค้นหารหัสปัญหา', 'ฐานข้อมูลภาษาไทย', () => const DtcLookupScreen(), color: const Color(0xFF3DA5FF)),
  _Tool(Icons.terminal_rounded, 'เทอร์มินัล', 'ส่งคำสั่งดิบถึงตัวสแกน', () => const TerminalScreen(), color: const Color(0xFF8A95A5)),
];

class HomeTab extends ConsumerWidget {
  const HomeTab({super.key, required this.onGoTab});

  final void Function(int tab) onGoTab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(appModeProvider);
    final session = ref.watch(sessionProvider);
    final scan = ref.watch(scanProvider);
    final garage = ref.watch(garageProvider).valueOrNull ?? const <Vehicle>[];
    final lastAdapter = ref.watch(lastAdapterProvider);
    final vehicle = garage.where((v) => session.vehicleId != null && v.id == session.vehicleId).firstOrNull ??
        (session.vin == null ? null : garage.where((v) => v.vin == session.vin).firstOrNull);
    final now = DateTime.now();
    final due = <(Vehicle, MaintItem)>[
      for (final v in vehicle != null ? [vehicle] : garage)
        for (final m in v.maintenance)
          if (m.isDue(v.latestKm, now) && (m.lastKm != null || m.lastDate != null)) (v, m),
    ];
    final width = MediaQuery.sizeOf(context).width;
    final cols = width > 900 ? 4 : (width > 600 ? 3 : 2);
    // การ์ดสูงตามความกว้างบนมือถือ แต่ไม่เกิน 150 บนแท็บเล็ต (ไม่ให้การ์ดโล่งเกินไป)
    final cardWidth = (width - 32 - (cols - 1) * 10) / cols;
    final cardHeight = (cardWidth / 1.12).clamp(110.0, 150.0).toDouble();

    void open(Widget w) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => w));

    void startScan({required bool all}) {
      ref.read(scanProvider.notifier).run(allModules: all);
      onGoTab(1);
    }

    // การ์ดเครื่องมือเรียงเป็นแถว แต่ละแถวสูงเท่าการ์ดที่เนื้อหายาวที่สุด (ไม่ต่ำกว่า cardHeight)
    // จอแคบหรือตั้งตัวอักษรใหญ่ การ์ดจะสูงขึ้นเอง ข้อความไม่ถูกตัด
    Widget grid(List<_Tool> tools) => Column(children: [
          for (var i = 0; i < tools.length; i += cols)
            Padding(
              padding: EdgeInsets.only(bottom: i + cols < tools.length ? 10 : 0),
              child: IntrinsicHeight(
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  for (var j = i; j < i + cols; j++) ...[
                    if (j > i) const SizedBox(width: 10),
                    Expanded(
                      child: j < tools.length
                          ? ConstrainedBox(
                              constraints: BoxConstraints(minHeight: cardHeight),
                              child: ToolCard(
                                icon: tools[j].icon,
                                title: tools[j].title,
                                subtitle: tools[j].subtitle,
                                color: tools[j].color,
                                onTap: () => open(tools[j].builder()),
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ],
                ]),
              ),
            ),
        ]);

    return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
      _VehicleHero(vehicle: vehicle, onOpenVehicle: vehicle == null ? null : () => open(VehicleScreen(vehicleId: vehicle.id))),
      const SizedBox(height: 12),
      if (session.isConnected)
        Row(children: [
          Expanded(
            child: FilledButton.icon(
              icon: const Icon(Icons.radar_rounded),
              label: const Text('สแกนด่วน'),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 54)),
              onPressed: scan.running ? () => onGoTab(1) : () => startScan(all: false),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: FilledButton.tonalIcon(
              icon: const Icon(Icons.hub_rounded),
              label: const Text('สแกนทั้งคัน'),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 54)),
              onPressed: scan.running ? () => onGoTab(1) : () => startScan(all: true),
            ),
          ),
        ])
      else if (lastAdapter != null)
        Row(children: [
          Expanded(
            child: FilledButton.icon(
              icon: const Icon(Icons.link_rounded),
              label: Text('เชื่อมต่อ ${lastAdapter.label}', maxLines: 1, overflow: TextOverflow.ellipsis),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 56)),
              onPressed: () => openConnect(context, reconnect: true),
            ),
          ),
          const SizedBox(width: 10),
          OutlinedButton(
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 56)),
            onPressed: () => openConnect(context),
            child: const Text('ตัวอื่น'),
          ),
        ])
      else
        FilledButton.icon(
          icon: const Icon(Icons.link_rounded),
          label: const Text('เชื่อมต่อตัวสแกน'),
          style: FilledButton.styleFrom(minimumSize: const Size(0, 56)),
          onPressed: () => openConnect(context),
        ),
      if (due.isNotEmpty) ...[
        const SectionLabel('ถึงกำหนดบำรุงรักษา'),
        PremiumCard(
          glow: StatusColors.warn,
          padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
          onTap: () => open(VehicleScreen(vehicleId: due.first.$1.id)),
          child: Column(children: [
            for (final (v, m) in due.take(4))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  const Icon(Icons.build_circle_rounded, color: StatusColors.warn, size: 20),
                  const SizedBox(width: 10),
                  Expanded(child: Text(m.name, style: const TextStyle(fontWeight: FontWeight.w600))),
                  if (vehicle == null) Text(v.title, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                ]),
              ),
          ]),
        ),
      ],
      const SectionLabel('เครื่องมือ'),
      grid(_ownerTools),
      if (mode == AppMode.mechanic) ...[
        const SectionLabel('เครื่องมือช่าง'),
        grid(_mechTools),
      ] else ...[
        const SizedBox(height: 10),
        PremiumCard(
          padding: const EdgeInsets.all(14),
          radius: 18,
          onTap: () => ref.read(appModeProvider.notifier).set(AppMode.mechanic),
          child: Row(children: [
            Icon(Icons.engineering_rounded, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 12),
            const Expanded(
              child: Text('เปิดโหมดช่าง: อ่านกล่อง ABS/ถุงลม, Mode 06, เทอร์มินัล, รหัสหัวฉีด',
                  style: TextStyle(fontSize: 13, height: 1.4)),
            ),
            const Icon(Icons.chevron_right_rounded),
          ]),
        ),
      ],
    ]);
  }
}

class _VehicleHero extends ConsumerWidget {
  const _VehicleHero({required this.vehicle, required this.onOpenVehicle});

  final Vehicle? vehicle;
  final VoidCallback? onOpenVehicle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final session = ref.watch(sessionProvider);
    final report = ref.watch(scanProvider).report;
    final connected = session.isConnected;
    final v = vehicle;
    final info = session.vin == null ? null : decodeVin17(session.vin!);
    final title = v != null && v.title != session.vin
        ? v.title
        : (info?.brand ?? (connected ? 'รถที่เชื่อมต่ออยู่' : 'ยังไม่ได้เชื่อมต่อรถ'));
    final odo = report?.snapshot.dashboardKm ?? report?.snapshot.pids[Pid.odometer] ?? v?.latestKm;
    final color = report == null ? cs.primary : report.overall.color(cs);
    final make = v?.make ?? info?.brand;
    final specs = <String>[
      if (v?.year != null) 'ปี ${v!.year}' else if (info != null && info.yearReliable && info.modelYear != null) 'ปี ${info.modelYear}',
      if (v?.fuel != null) v!.fuel! else if (connected) (session.diesel ? 'ดีเซล' : 'เบนซิน'),
      if (connected && session.elm != null) session.elm!.protocolLabel,
    ];

    Widget action(IconData icon, String text, String button, VoidCallback onTap) => Container(
          margin: const EdgeInsets.only(top: 14),
          padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
          decoration: BoxDecoration(
            color: cs.primary.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: cs.primary.withValues(alpha: 0.25)),
          ),
          child: Row(children: [
            Icon(icon, size: 18, color: cs.primary),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: const TextStyle(fontSize: 12.5, height: 1.35))),
            TextButton(onPressed: onTap, child: Text(button)),
          ]),
        );

    return PremiumCard(
      glow: color,
      onTap: onOpenVehicle,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          if (report != null)
            ScoreRing(score: report.healthScore, color: color, size: 92)
          else if (connected)
            BrandBadge(make: make, size: 84)
          else
            Container(
              width: 92,
              height: 92,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(colors: [cs.primary.withValues(alpha: 0.3), cs.primary.withValues(alpha: 0.02)]),
              ),
              child: Icon(Icons.bluetooth_disabled_rounded, size: 42, color: cs.primary),
            ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                if (report != null && connected) ...[BrandBadge(make: make, size: 26), const SizedBox(width: 8)],
                Expanded(
                  child: Text(title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 18.5, fontWeight: FontWeight.w800, height: 1.2)),
                ),
              ]),
              const SizedBox(height: 4),
              if (!connected)
                Text('เสียบตัวสแกน PRO SCANNER แล้วกดเชื่อมต่อ แอปจะรู้จักยี่ห้อและรุ่นรถให้เอง หรือลองโหมดทดลองได้เลย',
                    style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant, height: 1.4))
              else ...[
                if (specs.isNotEmpty)
                  Text(specs.join(' · '), style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant)),
                const SizedBox(height: 2),
                if (report != null)
                  Text(report.headlineTh, style: TextStyle(fontSize: 13, color: color, fontWeight: FontWeight.w700))
                else
                  Text('พร้อมสแกน', style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant)),
              ],
              if (odo != null || (connected && v != null)) ...[
                const SizedBox(height: 8),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  if (odo != null) Pill(text: formatKm(odo), color: cs.onSurfaceVariant, icon: Icons.route_rounded),
                  if (connected && v != null) identitySourcePill(v),
                ]),
              ],
            ]),
          ),
        ]),
        if (connected && v == null && session.vin == null)
          action(Icons.help_outline_rounded, 'รถคันนี้ไม่ส่ง VIN เลือกครั้งเดียว แอปจะบันทึกผลเข้ารถให้', 'เลือกรถ',
              () => chooseVehicleSheet(context, ref))
        else if (connected && v != null && v.needsModel)
          action(Icons.auto_awesome_rounded, 'ระบุรุ่นครั้งเดียว ครั้งหน้าแอปจะจำได้เอง รวมถึงรถรุ่นเดียวกันคันอื่น', 'เลือกรุ่น',
              () => editIdentitySheet(context, ref, v)),
      ]),
    );
  }
}
