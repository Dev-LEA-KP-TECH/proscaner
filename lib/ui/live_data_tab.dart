import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/obd/pids.dart';
import '../state/live_poller.dart';
import '../state/providers.dart';
import 'home_screen.dart';
import 'pid_chart_screen.dart';
import 'theme.dart';
import 'tools/dashboard_screen.dart';
import 'tools/logs_screen.dart';
import 'widgets/gauges.dart';

/// แสดงค่าสด อ่านต่อเนื่องเฉพาะตอนเปิดแท็บนี้อยู่ (รวมหน้ากราฟที่เปิดจากแท็บนี้)
class LiveDataTab extends ConsumerStatefulWidget {
  const LiveDataTab({super.key});

  @override
  ConsumerState<LiveDataTab> createState() => _LiveDataTabState();
}

/// ลำดับเกจในโหมดเจ้าของรถ (ตัวสำคัญขึ้นก่อน)
const _ownerOrder = <int>[
  Pid.rpm, Pid.speed, Pid.coolantTemp, Pid.moduleVoltage, Pid.engineLoad,
  Pid.fuelLevel, Pid.oilTemp, Pid.intakeTemp, Pid.boost, Pid.gear,
];

class _LiveDataTabState extends ConsumerState<LiveDataTab> {
  final Object _pollKey = Object();
  late final LivePoller _poller;
  bool _paused = false;
  PidGroup? _group = PidGroup.engine; // null = ทั้งหมด
  Set<int> _subscribed = const {};

  @override
  void initState() {
    super.initState();
    _poller = ref.read(livePollerProvider);
  }

  @override
  void dispose() {
    _poller.unsubscribe(_pollKey);
    super.dispose();
  }

  List<int> _pidsFor(AppMode mode, bool Function(int) ok) {
    if (mode == AppMode.owner) return _ownerOrder.where(ok).toList();
    return pidTable.values
        .where((d) => d.live && ok(d.pid) && (_group == null || d.group == _group))
        .map((d) => d.pid)
        .toList();
  }

  void _sync(List<int> pids) {
    final want = _paused ? <int>{} : pids.toSet();
    if (want.length == _subscribed.length && want.containsAll(_subscribed)) return;
    _subscribed = want;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_subscribed.isEmpty) {
        _poller.unsubscribe(_pollKey);
      } else {
        _poller.subscribe(_pollKey, _subscribed);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final mode = ref.watch(appModeProvider);
    final live = ref.watch(liveDataProvider);
    final settings = ref.watch(settingsProvider);
    final rec = ref.watch(recorderProvider);
    final cs = Theme.of(context).colorScheme;

    if (!session.isConnected) {
      _sync(const []);
      return const ConnectPrompt(message: 'เชื่อมต่อตัวสแกนเพื่อดูค่าสด');
    }
    final service = session.service!;
    final pids = _pidsFor(mode, service.supports);
    _sync(pids);

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 8, 4),
      child: Row(children: [
        _LiveDot(active: !_paused && live.error == null),
        const SizedBox(width: 8),
        // สถานะแบ่ง 2 บรรทัดสั้น ๆ (จำนวนรายการ / ความเร็วอ่าน) จอแคบก็อ่านครบ ไม่ถูกตัด
        Expanded(
          child: live.error != null
              ? Text(live.error!, style: TextStyle(fontSize: 12.5, color: cs.error))
              : Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  FitText(_paused ? 'หยุดชั่วคราว' : 'สด · ${pids.length} รายการ',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: cs.onSurface)),
                  if (!_paused)
                    FitText('${live.hz.toStringAsFixed(1)} ค่า/วินาที',
                        style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant,
                            fontFeatures: const [FontFeature.tabularFigures()])),
                ]),
        ),
        IconButton(
          tooltip: rec.recording ? 'หยุดบันทึก' : 'บันทึกการขับ',
          icon: Icon(rec.recording ? Icons.stop_circle_rounded : Icons.fiber_manual_record_rounded,
              color: rec.recording ? const Color(0xFFFF8A1F) : const Color(0xFFFF4D5A)),
          onPressed: () async {
            if (rec.recording) {
              final log = await ref.read(recorderProvider.notifier).stop();
              if (context.mounted && log != null) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('บันทึก "${log.name}" แล้ว')));
              }
            } else {
              await showStartRecording(context, ref);
            }
          },
        ),
        IconButton(
          tooltip: 'แดชบอร์ดขับรถ',
          icon: const Icon(Icons.fullscreen_rounded),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DashboardScreen())),
        ),
        IconButton.filledTonal(
          tooltip: _paused ? 'อ่านต่อ' : 'หยุดชั่วคราว',
          icon: Icon(_paused ? Icons.play_arrow_rounded : Icons.pause_rounded),
          onPressed: () => setState(() => _paused = !_paused),
        ),
      ]),
    );

    if (mode == AppMode.owner) {
      return Column(children: [
        header,
        Expanded(
          child: GridView.count(
            crossAxisCount: MediaQuery.sizeOf(context).width > 600 ? 3 : 2,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            mainAxisSpacing: 14,
            crossAxisSpacing: 14,
            childAspectRatio: 0.86,
            children: [
              for (final pid in pids) _GaugeTile(def: pidTable[pid]!, value: live.latest[pid], settings: settings),
            ],
          ),
        ),
      ]);
    }

    final groups = PidGroup.values
        .where((g) => pidTable.values.any((d) => d.live && d.group == g && service.supports(d.pid)))
        .toList();
    return Column(children: [
      header,
      SizedBox(
        height: 44,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          children: [
            for (final g in [null, ...groups])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(g?.labelTh ?? 'ทั้งหมด'),
                  selected: _group == g,
                  onSelected: (_) => setState(() => _group = g),
                ),
              ),
          ],
        ),
      ),
      if (_group == null)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
          child: Text('อ่านทุกค่าพร้อมกันจะอัปเดตช้าลง เลือกกลุ่มเพื่อให้เร็วขึ้น',
              style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant)),
        ),
      Expanded(
        child: ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          itemCount: pids.length,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (context, i) {
            final narrow = MediaQuery.sizeOf(context).width / (MediaQuery.textScalerOf(context).scale(100) / 100) < 380;
            final def = pidTable[pids[i]]!;
            final v = live.latest[def.pid];
            final dv = v == null ? null : displayPid(def, v, settings);
            final series = (live.series[def.pid] ?? const <double>[])
                .map((x) => displayPid(def, x, settings).value)
                .toList();
            return PremiumCard(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              radius: 18,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => PidChartScreen(pid: def.pid)),
              ),
              // ชื่อค่ายาวขึ้นบรรทัดใหม่ได้ (ไม่ตัดท้าย) จอแคบให้ชื่อได้ที่มากขึ้น กราฟเล็กลง
              child: Row(children: [
                Expanded(
                  flex: narrow ? 7 : 5,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(def.nameTh, style: const TextStyle(fontWeight: FontWeight.w600, height: 1.25)),
                    const SizedBox(height: 2),
                    Text('01${def.pid.toRadixString(16).padLeft(2, '0').toUpperCase()}',
                        style: TextStyle(fontFamily: kMono, fontSize: 11, color: cs.onSurfaceVariant)),
                  ]),
                ),
                Expanded(flex: narrow ? 3 : 4, child: Sparkline(values: series, color: cs.primary, height: 34)),
                const SizedBox(width: 12),
                SizedBox(
                  width: 92,
                  child: Text.rich(
                    TextSpan(children: [
                      TextSpan(
                        text: dv?.text ?? '—',
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                      ),
                      TextSpan(
                        text: dv == null || dv.unit.isEmpty ? '' : ' ${dv.unit}',
                        style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                      ),
                    ]),
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
                  ),
                ),
              ]),
            );
          },
        ),
      ),
    ]);
  }
}

class _GaugeTile extends StatelessWidget {
  const _GaugeTile({required this.def, required this.value, required this.settings});

  final PidDef def;
  final double? value;
  final AppSettings settings;

  /// สีเตือนเมื่อค่าเกินเกณฑ์
  Color _color(ColorScheme cs, double? v) {
    if (v == null) return cs.primary;
    if (def.pid == Pid.coolantTemp && v >= 105) return const Color(0xFFFF4D5A);
    if (def.pid == Pid.moduleVoltage && (v < 12.0 || v > 15.0)) return const Color(0xFFFFA824);
    if (def.pid == Pid.fuelLevel && v < 12) return const Color(0xFFFFA824);
    return cs.primary;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final v = value;
    final dv = v == null ? null : displayPid(def, v, settings);
    final color = _color(cs, v);
    return PremiumCard(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 8),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => PidChartScreen(pid: def.pid)),
      ),
      child: Column(children: [
        FitText(def.nameTh,
            alignment: Alignment.center,
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: cs.onSurfaceVariant)),
        Expanded(
          child: LayoutBuilder(
            builder: (context, c) => Center(
              child: ArcGauge(
                size: c.biggest.shortestSide,
                fraction: dv?.fraction,
                valueText: dv?.text ?? '—',
                unit: dv?.unit ?? def.unit,
                label: def.nameTh,
                color: color,
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

class _LiveDot extends StatefulWidget {
  const _LiveDot({required this.active});

  final bool active;

  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.active ? const Color(0xFF22C474) : Theme.of(context).colorScheme.outline;
    return FadeTransition(
      opacity: widget.active ? Tween(begin: 0.35, end: 1.0).animate(_c) : const AlwaysStoppedAnimation(1),
      child: Container(
        width: 9,
        height: 9,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 8)],
        ),
      ),
    );
  }
}
