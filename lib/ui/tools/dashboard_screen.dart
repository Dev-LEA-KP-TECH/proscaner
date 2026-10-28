import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/obd/pids.dart';
import '../../state/live_poller.dart';
import '../../state/providers.dart';
import '../home_screen.dart';
import '../orientation.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/gauges.dart';

/// แดชบอร์ดตอนขับ: จอนอน ไม่ดับ ตัวเลขใหญ่ พร้อมสถิติทริปและอัตราสิ้นเปลือง
class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  static const _pollKey = 'dashboard';
  late final LivePoller _poller;

  bool _iPhone = false;

  @override
  void initState() {
    super.initState();
    _poller = ref.read(livePollerProvider);
    _subscribe();
    WakelockPlus.enable().catchError((Object _) {});
    SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _iPhone = isIPhone(context);
  }

  void _subscribe() {
    final dash = ref.read(settingsProvider).dashboardPids;
    _poller.subscribe(_pollKey, {Pid.speed, Pid.rpm, Pid.maf, Pid.fuelRate, ...dash});
  }

  @override
  void dispose() {
    _poller.unsubscribe(_pollKey);
    WakelockPlus.disable().catchError((Object _) {});
    // กลับการหมุนจอปกติของแอป: iPhone กลับแนวตั้งทันที (iOS ไม่หมุนกลับเอง) ที่เหลือหมุนตามเครื่อง
    applyAppOrientation(iPhone: _iPhone);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _pick(int slot) async {
    final service = ref.read(sessionProvider).service;
    final defs = pidTable.values.where((d) => d.live && (service?.supports(d.pid) ?? true)).toList();
    final pid = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (c) => ListView(children: [
        for (final d in defs)
          ListTile(
            title: Text(d.nameTh),
            subtitle: Text('${d.code} · ${d.unit}', style: const TextStyle(fontFamily: kMono, fontSize: 12)),
            onTap: () => Navigator.pop(c, d.pid),
          ),
      ]),
    );
    if (pid == null) return;
    ref.read(settingsProvider.notifier).setDashboardPid(slot, pid);
    _subscribe();
  }

  @override
  Widget build(BuildContext context) {
    final live = ref.watch(liveDataProvider);
    final settings = ref.watch(settingsProvider);
    final cs = Theme.of(context).colorScheme;
    final speedDef = pidTable[Pid.speed]!;
    final rpmDef = pidTable[Pid.rpm]!;
    final speed = live.latest[Pid.speed];
    final rpm = live.latest[Pid.rpm];
    final sv = speed == null ? null : displayPid(speedDef, speed, settings);

    return Scaffold(
      backgroundColor: Theme.of(context).brightness == Brightness.dark ? Colors.black : null,
      body: SafeArea(
        child: NeedsConnection(
          message: 'เชื่อมต่อรถเพื่อใช้แดชบอร์ด',
          builder: (context, service) => LayoutBuilder(builder: (context, box) {
            final landscape = box.maxWidth > box.maxHeight;
            final gauge = LayoutBuilder(
              builder: (context, c) => Center(
                child: ArcGauge(
                  size: c.biggest.shortestSide,
                  fraction: sv?.fraction,
                  valueText: sv?.text ?? '—',
                  unit: sv?.unit ?? speedDef.unit,
                  label: rpm == null ? 'ความเร็ว' : '${rpm.round()} รอบ',
                  color: (rpm ?? 0) > 4500 ? StatusColors.bad : cs.primary,
                ),
              ),
            );
            final rpmBar = ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: rpm == null ? 0 : (rpm / (rpmDef.max ?? 8000)).clamp(0.0, 1.0),
                minHeight: 8,
                color: (rpm ?? 0) > 4500 ? StatusColors.bad : cs.primary,
                backgroundColor: cs.surfaceContainerHighest,
              ),
            );
            final tiles = GridView.count(
              crossAxisCount: 2,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: landscape ? 1.5 : 1.6,
              children: [
                for (var i = 0; i < settings.dashboardPids.length; i++)
                  _Tile(
                    pid: settings.dashboardPids[i],
                    value: live.latest[settings.dashboardPids[i]],
                    onLongPress: () => _pick(i),
                  ),
              ],
            );
            final trip = _TripBar(onReset: () => ref.read(liveDataProvider.notifier).resetTrip());
            final top = Row(children: [
              IconButton(
                tooltip: 'ปิด',
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              Expanded(
                child: Text('กดค้างที่ช่องเพื่อเปลี่ยนค่าที่แสดง · ${live.hz.toStringAsFixed(1)} ค่า/วินาที',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant), overflow: TextOverflow.ellipsis),
              ),
              IconButton(
                tooltip: 'หมุนจอ',
                icon: const Icon(Icons.screen_rotation_rounded),
                onPressed: () => SystemChrome.setPreferredOrientations(landscape
                    ? [DeviceOrientation.portraitUp]
                    : [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]),
              ),
            ]);
            if (landscape) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 16, 8),
                child: Column(children: [
                  top,
                  Expanded(
                    child: Row(children: [
                      Expanded(flex: 5, child: Column(children: [Expanded(child: gauge), rpmBar])),
                      const SizedBox(width: 16),
                      Expanded(flex: 6, child: Column(children: [Expanded(child: tiles), const SizedBox(height: 8), trip])),
                    ]),
                  ),
                ]),
              );
            }
            return Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(children: [
                top,
                Expanded(flex: 5, child: gauge),
                rpmBar,
                const SizedBox(height: 14),
                Expanded(flex: 4, child: tiles),
                const SizedBox(height: 10),
                trip,
              ]),
            );
          }),
        ),
      ),
    );
  }
}

class _Tile extends ConsumerWidget {
  const _Tile({required this.pid, required this.value, required this.onLongPress});

  final int pid;
  final double? value;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final def = pidTable[pid];
    final cs = Theme.of(context).colorScheme;
    if (def == null) return const SizedBox.shrink();
    final dv = value == null ? null : displayPid(def, value!, ref.watch(settingsProvider));
    return GestureDetector(
      onLongPress: onLongPress,
      child: PremiumCard(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        radius: 18,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(def.nameTh,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant, fontWeight: FontWeight.w600)),
          const Spacer(),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text.rich(TextSpan(children: [
              TextSpan(text: dv?.text ?? '—', style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800)),
              TextSpan(text: ' ${dv?.unit ?? def.unit}', style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
            ])),
          ),
        ]),
      ),
    );
  }
}

class _TripBar extends ConsumerWidget {
  const _TripBar({required this.onReset});

  final VoidCallback onReset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(liveDataProvider.select((l) => l.trip));
    final cs = Theme.of(context).colorScheme;
    String f(double? v, int d) => v == null ? '—' : v.toStringAsFixed(d);
    final mins = (t.seconds / 60).floor();
    Widget cell(String label, String value) => Expanded(
          child: Column(children: [
            Text(value, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            Text(label, style: TextStyle(fontSize: 10.5, color: cs.onSurfaceVariant)),
          ]),
        );
    return PremiumCard(
      padding: const EdgeInsets.fromLTRB(8, 10, 4, 10),
      radius: 18,
      child: Row(children: [
        cell('ระยะทริป กม.', f(t.km, 1)),
        cell('เฉลี่ย กม./ลิตร', f(t.avgKmPerL, 1)),
        cell('ขณะนี้ กม./ลิตร', f(t.instKmPerL, 1)),
        cell('ลิตร/ชม.', f(t.litersPerHour, 1)),
        cell('เวลา', '$mins น.'),
        IconButton(tooltip: 'เริ่มทริปใหม่', icon: const Icon(Icons.restart_alt_rounded), onPressed: onReset),
      ]),
    );
  }
}
