import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/obd/ext_automatch.dart';
import '../../core/obd/ext_pid.dart';
import '../../core/obd/formula.dart';
import '../../core/obd/obd_service.dart';
import '../../core/obd/pids.dart';
import '../../state/ext_packs.dart';
import '../../state/live_poller.dart';
import '../../state/providers.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'ext_common.dart';

/// จับคู่ค่าในชุด (เช่น เลขคำสั่งที่ค้นพบเอง) กับค่า OBD มาตรฐานของรถคันเดียวกัน
/// ใช้ค่ามาตรฐานของรถคันนั้นเป็นตัวเทียบแทนเครื่องมือศูนย์: อ่านซ้ำหลายรอบขณะค่าเปลี่ยน แล้วหาสูตรที่ตรงทุกจุด
class ExtAutoMatchScreen extends ConsumerStatefulWidget {
  const ExtAutoMatchScreen({super.key, required this.packId});

  final String packId;

  @override
  ConsumerState<ExtAutoMatchScreen> createState() => _ExtAutoMatchScreenState();
}

class _ExtAutoMatchScreenState extends ConsumerState<ExtAutoMatchScreen> {
  /// เก็บไว้ตั้งแต่ initState (ห้ามใช้ ref ใน dispose)
  late final LivePoller _poller;
  final _matcher = AutoMatcher();

  /// ไบต์ล่าสุดของแต่ละคำสั่ง และข้อความเมื่อคำสั่งนั้นอ่านไม่ได้
  final _latest = <String, List<int>>{};
  final _errors = <String, String>{};
  Map<String, AutoMatchSuggestion> _best = {};
  Map<String, int> _others = {};

  /// ค่าที่กด "ใช้สูตรนี้" แล้ว
  final _applied = <ExtPid>{};
  bool _running = false;
  bool _carSilent = false;
  int _rounds = 0;
  List<int> _stdPids = const [];

  /// ค่ามาตรฐานที่อ่านท้ายรอบก่อน ใช้เป็นค่า "ก่อน" ของรอบถัดไปได้เลย (ห่างกันไม่ถึงวินาที)
  /// ไม่ต้องอ่านซ้ำทุกรอบ ทำให้แต่ละรอบเร็วขึ้น (บนรถจริงผ่าน Bluetooth คำสั่งละประมาณ 0.15–0.2 วินาที)
  Map<int, List<int>>? _lastStd;
  DateTime? _lastStdAt;
  static const _pollKey = 'ext_automatch';

  /// PID มาตรฐานที่ใช้เทียบ เรียงตามความน่าจะเป็นค่าที่กล่องเก็บไว้ (อ่านไม่เกิน 16 ตัวต่อรอบ)
  static const _preferred = <int>[
    Pid.rpm, Pid.coolantTemp, Pid.intakeTemp, Pid.map, Pid.maf, Pid.speed, Pid.engineLoad, Pid.throttle,
    Pid.fuelRailPressure, Pid.fuelRailAbs, Pid.timingAdvance, Pid.baro, Pid.moduleVoltage, Pid.ambientTemp,
    Pid.oilTemp, Pid.commandedEgr, Pid.egrError, Pid.fuelRate, Pid.fuelPressure, Pid.pedalD, Pid.pedalE,
    Pid.relativePedal, Pid.absoluteLoad, Pid.chargeAirTemp, Pid.injectionTiming, Pid.runTime,
  ];

  @override
  void initState() {
    super.initState();
    _poller = ref.read(livePollerProvider);
  }

  @override
  void dispose() {
    _running = false;
    resumePoller(_poller, _pollKey);
    super.dispose();
  }

  ExtPidPack? _pack() => ref.read(extPacksProvider).where((p) => p.id == widget.packId).firstOrNull;

  bool _fits(ExtPidPack pack, {bool watch = false}) =>
      fitsCurrentVehicle(ref, brand: pack.brand, models: pack.models, years: pack.years, watch: watch);

  /// PID มาตรฐานที่รถรองรับและเปลี่ยนตามสภาพเครื่อง
  static List<int> _pickStdPids(Set<int> supported) {
    final out = <int>[];
    for (final p in _preferred) {
      if (out.length >= 16) break;
      final def = pidTable[p];
      if (def == null || !def.live) continue;
      if (supported.isNotEmpty && !supported.contains(p)) continue;
      out.add(p);
    }
    const groups = {PidGroup.engine, PidGroup.fuel, PidGroup.air, PidGroup.diesel, PidGroup.electrical};
    for (final p in supported.toList()..sort()) {
      if (out.length >= 16) break;
      final def = pidTable[p];
      if (def == null || !def.live || out.contains(p) || !groups.contains(def.group)) continue;
      out.add(p);
    }
    return out;
  }

  Future<void> _toggle() async {
    if (_running) {
      setState(() => _running = false);
      return;
    }
    final service = ref.read(sessionProvider).service;
    final pack = _pack();
    if (service == null || pack == null) return;
    final standardOnly = !_fits(pack);
    setState(() {
      _running = true;
      _carSilent = false;
      _stdPids = _pickStdPids(service.supported);
      _lastStd = null;
    });
    pausePoller(_poller, _pollKey);
    try {
      while (_running && mounted) {
        await _round(pack, service, standardOnly);
        if (!_running || !mounted) break;
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('อ่านค่าไม่สำเร็จ: $e')));
    } finally {
      resumePoller(_poller, _pollKey);
      if (mounted) setState(() => _running = false);
    }
  }

  /// อ่านค่ามาตรฐานทุกตัวที่เลือกไว้หนึ่งครั้ง
  Future<Map<int, List<int>>> _readStd(ObdService service) async {
    final out = <int, List<int>>{};
    for (final pid in _stdPids) {
      if (!_running || !mounted) break;
      try {
        final raw = await service.readPidRaw(pid);
        if (raw != null) out[pid] = raw;
      } catch (_) {
        // ข้ามตัวที่ไม่ตอบ
      }
    }
    return out;
  }

  /// หนึ่งรอบ: อ่านค่ามาตรฐาน → ค่าในชุด → ค่ามาตรฐานอีกครั้ง
  /// เก็บเฉพาะค่ามาตรฐานที่ไม่เปลี่ยนระหว่างรอบ (ค่ากำลังเปลี่ยนเร็ว เช่น ตอนกดคันเร่ง จะจับคู่ผิดจังหวะ)
  Future<void> _round(ExtPidPack pack, ObdService service, bool standardOnly) async {
    final last = _lastStd, lastAt = _lastStdAt;
    final reuse = last != null && lastAt != null && DateTime.now().difference(lastAt) < const Duration(seconds: 2);
    final before = reuse ? last : await _readStd(service);
    if (!_running || !mounted) return;
    final results = <String, ExtCmdResult>{};
    final reader = ExtPidReader(service.elm);
    final readings = await reader.readAll(
      pack.pids,
      commandResults: results,
      standardOnly: standardOnly,
      cancelled: () => !_running || !mounted,
    );
    if (!mounted) return;
    if (reader.carSilent) {
      setState(() {
        _carSilent = true;
        _running = false;
      });
      return;
    }
    final after = await _readStd(service);
    _lastStd = after;
    _lastStdAt = DateTime.now();
    if (!_running || !mounted) return;
    final std = <int, List<int>>{};
    for (final e in after.entries) {
      final def = pidTable[e.key];
      final b = before[e.key];
      if (def == null || b == null || b.length < def.bytes || e.value.length < def.bytes) continue;
      final v1 = def.decode(b), v2 = def.decode(e.value);
      final res = math.pow(10, -def.decimals.clamp(0, 4)).toDouble();
      if ((v1 - v2).abs() <= math.max(res, 0.03 * math.max(v1.abs(), v2.abs()))) std[e.key] = e.value;
    }
    final payloads = <String, List<int>>{};
    for (final p in pack.pids) {
      final c = results[p.cmdKey];
      final payload = c?.payload;
      if (c != null && c.status == ExtCmdStatus.ok && payload != null) {
        payloads[p.cmdKey] = payload;
        _latest[p.cmdKey] = payload;
        _errors.remove(p.cmdKey);
      } else {
        // เหตุผลที่อ่านไม่ได้ (รวมถึงข้ามเพราะเป็นกล่องเลขเฉพาะยี่ห้อ ในชุดที่ไม่ใช่ของรถคันนี้)
        final why = readings[p.key]?.error ?? c?.error;
        if (why != null) _errors[p.cmdKey] = why;
      }
    }
    _matcher.add(AutoMatchSample(payloads: payloads, std: std));
    final best = <String, AutoMatchSuggestion>{};
    final others = <String, int>{};
    for (final c in {for (final p in pack.pids) p.cmdKey}) {
      final all = _matcher.suggestionsFor(c);
      if (all.isEmpty) continue;
      best[c] = all.first;
      others[c] = all.length - 1;
    }
    setState(() {
      _rounds++;
      _best = best;
      _others = others;
    });
  }

  void _apply(ExtPidPack pack, ExtPid p, AutoMatchSuggestion s) {
    final def = s.def;
    if (def == null) return;
    final now = DateTime.now();
    final date = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    setState(() {
      p
        ..name = def.nameTh
        ..formula = s.formula
        ..unit = def.unit
        ..decimals = def.decimals
        ..min = def.min
        ..max = def.max
        // เกณฑ์ "ไม่มีค่า" และป้ายค่าเดิมเป็นของสูตรเก่า ใช้กับสูตรใหม่ไม่ได้
        ..nullMin = null
        ..nullMax = null
        ..okMin = null
        ..okMax = null
        ..labels = const {}
        ..desc = 'จับคู่กับ PID ${s.pidCode} ของรถคันนี้ $date${s.weak ? ' (ค่ายังไม่เปลี่ยนตอนจับคู่ ควรตรวจซ้ำ)' : ''}';
      p.points.addAll(s.calPoints.take(5));
      _applied.add(p);
    });
    ref.read(extPacksProvider.notifier).put(pack);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('ตั้ง "${def.nameTh}" สูตร ${s.formula} แล้ว (ยังไม่ถือว่าร้านยืนยัน)')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final pack = ref.watch(extPacksProvider).where((p) => p.id == widget.packId).firstOrNull;
    final connected = ref.watch(sessionProvider.select((s) => s.isConnected));
    if (pack == null) {
      return Scaffold(
        appBar: AppBar(title: const FitText('จับคู่กับค่า OBD มาตรฐาน')),
        body: const Center(child: Text('ไม่พบชุดนี้')),
      );
    }
    final fits = _fits(pack, watch: true);
    final brandOnly = pack.pids.where((p) => !p.standardHeader).length;
    int rank(ExtPid p) {
      final s = _best[p.cmdKey];
      if (s == null) return 2;
      return s.weak ? 1 : 0;
    }

    // เรียงค่าที่จับคู่ได้ขึ้นก่อน (คงลำดับเดิมในกลุ่มเดียวกัน)
    final order = {for (var i = 0; i < pack.pids.length; i++) pack.pids[i]: i};
    final pids = [...pack.pids]
      ..sort((a, b) {
        final r = rank(a).compareTo(rank(b));
        return r != 0 ? r : order[a]!.compareTo(order[b]!);
      });
    final strong = pack.pids.where((p) => rank(p) == 0).length;
    return Scaffold(
      appBar: AppBar(title: const FitText('จับคู่กับค่า OBD มาตรฐาน')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 40), children: [
        PremiumCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              'แอปจะอ่านค่าในชุด "${pack.name}" พร้อมกับค่า OBD มาตรฐานของรถคันนี้ (รอบเครื่อง ความร้อน แรงดันอากาศ ฯลฯ) '
              'ซ้ำหลายรอบ แล้วหาว่าเลขไหนเปลี่ยนไปพร้อมกับค่าไหนด้วยสูตรที่ตรงทุกจุด ใช้รถคันนี้เป็นตัวเทียบแทนเครื่องมือศูนย์',
              style: TextStyle(color: cs.onSurfaceVariant, height: 1.5, fontSize: 13),
            ),
            const SizedBox(height: 6),
            Text(
              'ติดเครื่อง จอดนิ่ง เกียร์ว่าง ดึงเบรกมือ แล้วเร่งเครื่องค้างไว้ทีละระดับ (เดินเบา → 1,500 → 2,500\u00A0รอบ/นาที) '
              'ระดับละประมาณ 10–15\u00A0วินาที หรือปล่อยให้เครื่องร้อนขึ้น ยิ่งค่าเปลี่ยนหลายระดับ ยิ่งจับคู่ได้แน่นอน',
              style: TextStyle(color: cs.onSurfaceVariant, height: 1.5, fontSize: 12.5),
            ),
            const SizedBox(height: 12),
            if (!connected)
              Text('เชื่อมต่อรถก่อน', style: TextStyle(color: cs.onSurfaceVariant))
            else
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: Icon(_running ? Icons.stop_rounded : Icons.play_arrow_rounded),
                  label: Text(_running ? 'หยุด (อ่านแล้ว $_rounds\u00A0รอบ)' : 'เริ่มจับคู่'),
                  onPressed: _toggle,
                ),
              ),
            if (_running) ...[const SizedBox(height: 10), const LinearProgressIndicator(minHeight: 3)],
            if (_rounds > 0) ...[
              const SizedBox(height: 8),
              Text(
                'อ่านแล้ว $_rounds\u00A0รอบ\u00A0· เทียบกับค่ามาตรฐาน ${_stdPids.length} ตัว\u00A0· จับคู่ได้ $strong\u00A0ค่า',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ],
          ]),
        ),
        if (!fits && brandOnly > 0) ...[
          const SizedBox(height: 12),
          PremiumCard(
            glow: StatusColors.warn,
            child: Text(
              'ชุดนี้ไม่ใช่ของรถคันที่ต่ออยู่ (ยี่ห้อ/รุ่น/ปีไม่ตรง) แอปจะอ่านเฉพาะค่าที่ส่งไปกล่องเลขมาตรฐาน (7DF, 7E0–7E7) '
              'และข้าม $brandOnly\u00A0ค่าที่ส่งไปกล่องเลขเฉพาะยี่ห้อ เพื่อไม่ให้คำสั่งไปชนกับข้อความปกติของรถคันนี้',
              style: TextStyle(color: cs.onSurfaceVariant, height: 1.5, fontSize: 13),
            ),
          ),
        ],
        if (_carSilent) ...[
          const SizedBox(height: 12),
          PremiumCard(
            glow: StatusColors.warn,
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.power_settings_new_rounded, color: StatusColors.warn, size: 28),
              const SizedBox(width: 10),
              Expanded(child: Text(carSilentText, style: TextStyle(color: cs.onSurfaceVariant, height: 1.5))),
            ]),
          ),
        ],
        SectionLabel('ค่าในชุด (${pack.pids.length})'),
        for (final p in pids)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _MatchRow(
              pid: p,
              latest: _latest[p.cmdKey],
              error: _errors[p.cmdKey],
              suggestion: _best[p.cmdKey],
              others: _others[p.cmdKey] ?? 0,
              applied: _applied.contains(p),
              onApply: (s) => _apply(pack, p, s),
            ),
          ),
      ]),
    );
  }
}

class _MatchRow extends StatelessWidget {
  const _MatchRow({
    required this.pid,
    required this.latest,
    required this.error,
    required this.suggestion,
    required this.others,
    required this.applied,
    required this.onApply,
  });

  final ExtPid pid;
  final List<int>? latest;
  final String? error;
  final AutoMatchSuggestion? suggestion;
  final int others;
  final bool applied;
  final void Function(AutoMatchSuggestion s) onApply;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = suggestion;
    final def = s?.def;
    final raw = latest;
    String? preview;
    if (s != null && raw != null && def != null) {
      try {
        final v = Formula(s.formula).eval(raw);
        preview = '${v.toStringAsFixed(def.decimals.clamp(0, 3))}${def.unit.isEmpty ? '' : ' ${def.unit}'}';
      } catch (_) {
        preview = null;
      }
    }
    final color = s == null ? null : (s.weak ? StatusColors.warn : StatusColors.good);
    return PremiumCard(
      glow: color,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      radius: 16,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(thaiKeep(pid.name), style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 2),
        Text(
          '${pid.header.isEmpty ? '7DF' : pid.header}\u00A0· ${pid.request}'
          '${raw != null && raw.isNotEmpty ? ' → ${bytesToHex(raw.take(8).toList())}${raw.length > 8 ? ' …' : ''}' : ''}',
          style: TextStyle(fontSize: 12, fontFamily: kMono, color: cs.onSurfaceVariant),
        ),
        if (s == null || def == null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              error ?? (raw == null ? 'ยังไม่ได้อ่าน' : 'ยังจับคู่ไม่ได้ (ค่ายังไม่เปลี่ยน หรือไม่ตรงกับค่ามาตรฐานตัวไหน)'),
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          )
        else ...[
          const SizedBox(height: 6),
          Row(children: [
            Icon(s.weak ? Icons.help_outline_rounded : Icons.link_rounded, size: 18, color: color),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '≈ ${def.nameTh} (PID ${s.pidCode})${preview == null ? '' : ' = $preview'}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ]),
          const SizedBox(height: 2),
          Text('สูตร ${s.formula}\u00A0· ${s.note}${others > 0 ? '\u00A0· ตรงกับค่าอื่นอีก $others ตัว' : ''}',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant, height: 1.4)),
          Align(
            alignment: Alignment.centerRight,
            child: applied
                ? Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('ตั้งชื่อและสูตรแล้ว', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                  )
                : TextButton.icon(
                    icon: const Icon(Icons.check_rounded),
                    label: const Text('ใช้สูตรนี้'),
                    onPressed: () => onApply(s),
                  ),
          ),
        ],
      ]),
    );
  }
}
