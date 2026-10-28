import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/obd/ext_library.dart';
import '../../core/obd/ext_pid.dart';
import '../../state/ext_packs.dart';
import '../../state/live_poller.dart';
import '../../state/providers.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'ext_automatch_screen.dart';
import 'ext_common.dart';
import 'ext_pid_detail_screen.dart';
import 'ext_pid_edit_screen.dart';

/// ชุดช่วงค้นหาสำเร็จรูป
class _Preset {
  const _Preset(this.title, this.subtitle, this.jobs, {this.replacesLib, this.entry});
  final String title;
  final String subtitle;
  final List<ScanJob> jobs;

  /// ใช้แทนช่วงของชุดในคลังชุดนี้ เมื่อเลือกให้อัตโนมัติตามรถ (ชุดในคลังยังมีข้อมูลน้อย ช่วงจึงแคบเกินไป)
  final String? replacesLib;

  /// ชุดในคลังที่เป็นที่มาของช่วงนี้ (null = ช่วงทั่วไป)
  final ExtLibraryEntry? entry;
}

const _kwpPresetTitle = 'KWP 21 กล่องหลัก';

const _genericPresets = <_Preset>[
  _Preset(_kwpPresetTitle, 'เครื่อง เกียร์ และกล่องที่ 3 (7E0/7E1/7E2) · Toyota, Mitsubishi และรถรุ่นเก่า', [
    ScanJob(header: '7E0', service: 0x21, start: 0x00, end: 0xFF),
    ScanJob(header: '7E1', service: 0x21, start: 0x00, end: 0xFF),
    ScanJob(header: '7E2', service: 0x21, start: 0x00, end: 0xFF),
  ]),
  _Preset(
    'Isuzu D-Max/MU-X (ค้นหาใหม่)',
    'กล่องเครื่อง 7E0 และเกียร์ 7E2 ช่วงที่ GM/Isuzu ใช้บ่อย (ส่งเฉพาะกล่องเลขมาตรฐาน ค้นหาได้ปลอดภัยทุกปีรุ่น)',
    [
      ScanJob(header: '7E2', service: 0x22, start: 0x1900, end: 0x19FF),
      ScanJob(header: '7E0', service: 0x22, start: 0x1100, end: 0x12FF),
      ScanJob(header: '7E0', service: 0x21, start: 0x00, end: 0xFF),
    ],
    replacesLib: 'isuzu_dmax_2012',
  ),
];

/// ค้นหาว่ากล่องในรถตอบเลขคำสั่งไหนบ้าง แล้วนำไปดูไบต์สด/เทียบค่า/เพิ่มเป็นค่าใหม่
class DidScannerScreen extends ConsumerStatefulWidget {
  const DidScannerScreen({super.key, this.targetPackId, this.autoPreset = true});

  /// ชุดที่จะเพิ่มค่าใหม่เข้าไป (ถ้าไม่มีจะสร้าง "ชุดของฉัน")
  final String? targetPackId;

  /// เลือกช่วงค้นหาตามยี่ห้อของรถคันที่ต่ออยู่ให้อัตโนมัติ
  final bool autoPreset;

  @override
  ConsumerState<DidScannerScreen> createState() => _DidScannerScreenState();
}

class _DidScannerScreenState extends ConsumerState<DidScannerScreen> {
  /// เก็บไว้ตั้งแต่ initState (ห้ามใช้ ref ใน dispose)
  late final LivePoller _poller;

  @override
  void initState() {
    super.initState();
    _poller = ref.read(livePollerProvider);
  }

  final _header = TextEditingController(text: '7E0');
  final _rx = TextEditingController();
  final _start = TextEditingController(text: '00');
  final _end = TextEditingController(text: 'FF');
  int _service = 0x21;
  _Preset? _preset;
  bool _custom = false;
  bool _busy = false;
  bool _cancel = false;
  double _progress = 0;
  String _current = '';
  List<DidHit>? _hits;

  /// สรุปผลแต่ละช่วงของการค้นหาครั้งล่าสุด
  List<ScanJobStat>? _stats;

  /// "ชุดของฉัน" ที่หน้านี้สร้างไว้ (เมื่อไม่ได้ระบุชุดปลายทาง)
  String? _ownPackId;

  /// ชุดที่บันทึกจากผลค้นหาครั้งล่าสุดทั้งหมด (แสดงปุ่มไปหน้า "จับคู่กับค่า OBD มาตรฐาน" แทนปุ่มบันทึก)
  String? _savedAllPackId;
  String? _error;

  /// ข้อความแนะนำ (ไม่ใช่ข้อผิดพลาด) เช่น หยุดกลางทางแล้วค้นต่อได้จากเลขไหน
  String? _note;
  static const _pollKey = 'did_scan';

  @override
  void dispose() {
    _cancel = true;
    resumePoller(_poller, _pollKey);
    for (final c in [_header, _rx, _start, _end]) {
      c.dispose();
    }
    super.dispose();
  }

  void _setService(int s) => setState(() {
        _service = s;
        if (s == 0x21) {
          _start.text = '00';
          _end.text = 'FF';
        } else {
          _start.text = '1100';
          _end.text = '11FF';
        }
      });

  List<ScanJob>? _customJobs() {
    final h = _header.text.trim().toUpperCase();
    final rx = _rx.text.trim().toUpperCase();
    final s = int.tryParse(_start.text.trim(), radix: 16);
    final e = int.tryParse(_end.text.trim(), radix: 16);
    final probe = ExtPid(name: 'x', request: '${_service.toRadixString(16)}00', formula: 'A', header: h, rx: rx.isEmpty ? null : rx);
    String? err;
    if (h.isNotEmpty && probe.validate() != null) err = probe.validate();
    if (s == null || e == null || e < s) err = 'ช่วงเลขไม่ถูกต้อง';
    final maxId = _service == 0x21 ? 0xFF : 0xFFFF;
    if (err == null && (e! > maxId || e - s! > 4096)) err = 'ค้นหาได้ครั้งละไม่เกิน 4,096 เลข';
    if (err != null) {
      setState(() => _error = err);
      return null;
    }
    return [ScanJob(header: h, rx: rx.isEmpty ? null : rx, service: _service, start: s!, end: e!)];
  }

  /// ช่วงที่ใช้อยู่ (ที่ผู้ใช้เลือก หรือที่เลือกให้ตามรถ)
  /// เลือกให้เฉพาะชุดที่ทำไว้สำหรับรถคันนี้ (ยี่ห้อ/รุ่น และปี ±1) ถ้าไม่มี ใช้ช่วงทั่วไปที่ส่งไปกล่องเลขมาตรฐานเท่านั้น
  _Preset? _effective(List<_Preset> presets, List<ExtLibraryEntry> lib) {
    if (_custom) return null;
    if (_preset != null) return _preset;
    if (!widget.autoPreset) return null;
    final veh = currentVehicle(ref);
    if (veh == null) return null;
    ExtLibraryEntry? best;
    var bestScore = 0;
    var bestGap = 0;
    for (final e in lib) {
      if (e.scan.isEmpty) continue;
      final fits = packFitsVehicle(
        packBrand: e.brand,
        packModels: e.models,
        packYears: e.years,
        make: veh.make,
        model: veh.model,
        year: veh.year,
      );
      if (!fits) continue;
      final sc = e.matchScore(brand: veh.make, model: veh.model, year: veh.year);
      final gap = packYearGap(e.years, veh.year);
      // คะแนนสูงกว่าก่อน ถ้าเท่ากันเลือกชุดที่ปีใกล้รถคันนี้กว่า
      if (best == null || sc > bestScore || (sc == bestScore && gap < bestGap)) {
        best = e;
        bestScore = sc;
        bestGap = gap;
      }
    }
    final pick = best;
    if (pick == null) {
      // ไม่มีชุดของรถรุ่น/ปีนี้ในคลัง: ใช้ช่วงทั่วไป (ส่งไปกล่องเลขมาตรฐานเท่านั้น)
      final isuzu = (veh.make ?? '').trim().toLowerCase() == 'isuzu';
      return presets.where((p) => isuzu ? p.replacesLib != null : p.title == _kwpPresetTitle).firstOrNull;
    }
    return presets.where((p) => p.replacesLib == pick.lib).firstOrNull ??
        presets.where((p) => p.entry?.lib == pick.lib).firstOrNull;
  }

  /// ช่วงที่ส่งคำสั่งไปกล่องเลขเฉพาะยี่ห้อ (ไม่ใช่ 7DF/7E0–7E7) ทั้งที่ไม่รู้ว่าเป็นของรถคันนี้
  /// (กำหนดเอง หรือชุดในคลังที่ยี่ห้อ/รุ่น/ปีไม่ตรง) ต้องให้ช่างยืนยันก่อน เพราะอาจไปชนกับข้อความปกติของรถ
  Future<bool> _confirmNonStandard(_Preset? preset, List<ScanJob> jobs) async {
    final odd = {
      for (final j in jobs)
        if (!isStandardDiagHeader(j.header)) j.header.trim().toUpperCase(),
    };
    if (odd.isEmpty) return true;
    final e = preset?.entry;
    if (e != null && fitsCurrentVehicle(ref, brand: e.brand, models: e.models, years: e.years)) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('ส่งคำสั่งไปกล่องเลขเฉพาะยี่ห้อ?'),
        content: Text(
          'ช่วงนี้จะส่งคำสั่งไปที่เลข ${odd.join(', ')} ซึ่งไม่ใช่เลขมาตรฐานของ OBD (7DF, 7E0–7E7)'
          '${e != null ? ' และชุดนี้ไม่ใช่ของรถคันที่ต่ออยู่' : ''} '
          'ถ้ารถคันนี้ใช้เลขนั้นเป็นข้อความปกติ (เช่น ข้อมูลหน้าปัด) คำสั่งอาจไปชนกัน '
          'ทำให้หน้าปัดรวนหรือไฟเตือนติดชั่วคราวได้\n\nค้นหาต่อเฉพาะเมื่อแน่ใจว่ารถคันนี้มีกล่องที่เลขนี้',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('ยกเลิก')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('ค้นหาต่อ')),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _run(_Preset? preset) async {
    final service = ref.read(sessionProvider).service;
    if (service == null) return;
    final jobs = preset == null ? _customJobs() : preset.jobs;
    if (jobs == null || jobs.isEmpty) return;
    if (!await _confirmNonStandard(preset, jobs) || !mounted) return;
    final skipped = [
      for (final j in jobs)
        if (ExtPidReader.incompatibility(service.elm, ExtPid(name: 'x', request: '2200', formula: 'A', header: j.header)) != null) j
    ];
    setState(() {
      _busy = true;
      _cancel = false;
      _error = skipped.isEmpty ? null : 'ข้าม ${skipped.length} ช่วงที่เป็นของรถ CAN คนละแบบ (11/29 บิต)';
      _hits = [];
      _stats = null;
      _savedAllPackId = null;
      _note = null;
    });
    pausePoller(_poller, _pollKey);
    try {
      final reader = ExtPidReader(service.elm);
      final hits = await reader.scanJobs(
        jobs,
        cancelled: () => _cancel,
        // แสดงเลขที่เจอทันที ไม่ต้องรอค้นหาจบ (ค้นหาเต็มชุดใช้เวลาหลายนาที)
        onHit: (h) {
          if (mounted) setState(() => _hits?.add(h));
        },
        onProgress: (p, c) {
          if (mounted) {
            setState(() {
              _progress = p;
              _current = c;
            });
          }
        },
      );
      if (mounted) {
        setState(() {
          _hits = reader.carSilent ? null : hits;
          // สรุปแต่ละช่วง (รวมกรณีหยุดกลางทาง) บอกช่างว่าควรลองอะไรต่อ
          _stats = reader.carSilent ? null : List.of(reader.lastScanStats);
          if (reader.carSilent) _error = carSilentText;
          // หยุดกลางทางในช่วงที่กำหนดเอง (ช่วงยาวใช้เวลาหลายนาที): ตั้งเลขเริ่มเป็นเลขที่ค้างไว้ กด "เริ่มค้นหา" เพื่อค้นต่อได้เลย
          if (_cancel && preset == null && !reader.carSilent) {
            final id = resumeIdFrom(_current, _service);
            if (id != null) {
              _start.text = id;
              _note = 'หยุดที่เลข $id · บันทึกเลขที่เจอไว้ก่อน แล้วกด "เริ่มค้นหา" เพื่อค้นต่อจาก $id';
            }
          }
        });
      }
    } catch (ex) {
      if (mounted) setState(() => _error = 'ค้นหาไม่สำเร็จ: $ex');
    } finally {
      resumePoller(_poller, _pollKey);
      if (mounted) setState(() => _busy = false);
    }
  }

  ExtPid _pidFromHit(DidHit h) => ExtPid(
        name: 'ค่าใหม่ ${h.header.isEmpty ? '' : '${h.header} '}${h.request}',
        request: h.request,
        formula: 'A',
        header: h.header,
        rx: h.rx,
        group: 'ค่าที่ค้นพบเอง',
      );

  void _saveToPack(ExtPid pid) {
    final n = ref.read(extPacksProvider.notifier);
    final packs = ref.read(extPacksProvider);
    final targetId = widget.targetPackId ?? _ownPackId;
    var pack = packs.where((p) => p.id == targetId).firstOrNull;
    pack ??= ExtPidPack(id: 'pack_${DateTime.now().millisecondsSinceEpoch}', name: 'ชุดของฉัน');
    // ค่าถัดไปที่บันทึกจากหน้านี้ เข้าชุดเดียวกัน (ไม่สร้าง "ชุดของฉัน" ซ้ำทุกครั้ง)
    _ownPackId = pack.id;
    pack.pids.add(pid);
    n.put(pack);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('เพิ่ม "${pid.name}" เข้า "${pack.name}" แล้ว')));
    }
  }

  /// บันทึกเลขที่เจอทั้งหมดเป็นชุดใหม่ (ยังไม่รู้ว่าเป็นค่าอะไร ใช้ "จับคู่กับค่า OBD มาตรฐาน" หาต่อได้)
  void _saveAllHits(List<DidHit> hits) {
    if (hits.isEmpty) return;
    final veh = currentVehicle(ref, watch: false);
    final make = veh?.make;
    final model = veh?.model;
    final year = veh?.year;
    final now = DateTime.now();
    final date = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final label = [make, model, year?.toString()].whereType<String>().join(' ');
    final pack = ExtPidPack(
      id: 'pack_${now.millisecondsSinceEpoch}',
      name: 'ค้นพบเอง ${label.isEmpty ? 'ชุดของฉัน' : label} $date',
      note: 'เลขที่กล่องตอบตอนค้นหา ${hits.length} รายการ ยังไม่รู้ว่าเป็นค่าอะไร '
          'ใช้ "จับคู่กับค่า OBD มาตรฐาน" ตอนติดเครื่อง หรือแตะแต่ละค่าเพื่อดูไบต์สดและหาสูตร',
      brand: make ?? '',
      models: [if (model != null) model],
      years: [if (year != null) ...[year, year]],
      pids: [
        for (final h in hits)
          ExtPid(
            name: 'ค่าใหม่ ${h.header.isEmpty ? '' : '${h.header} '}${h.request}',
            request: h.request,
            formula: h.data.length == 2 ? '(A*256+B)' : 'A',
            header: h.header,
            rx: h.rx,
            decimals: 0,
            group: 'ค่าที่ค้นพบเอง',
          ),
      ],
    );
    ref.read(extPacksProvider.notifier).put(pack);
    // ไม่ใส่ปุ่มใน SnackBar: SnackBar ที่มีปุ่มค้างอยู่บนจอ (ไม่หายเอง) และกดไม่ได้ผลหลังออกจากหน้านี้
    // ปุ่ม "จับคู่กับค่า OBD มาตรฐาน" ของชุดนี้จะแสดงแทนปุ่มบันทึกในรายการผลค้นหา
    setState(() => _savedAllPackId = pack.id);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('บันทึก ${hits.length} เลขเป็นชุด "${pack.name}" แล้ว (อยู่ใน "ชุดของฉัน")'),
    ));
  }

  void _openAutoMatch(String packId) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ExtAutoMatchScreen(packId: packId)));
  }

  Future<void> _hitActions(DidHit h) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.visibility_rounded),
            title: const Text('ดูไบต์สด / เทียบค่า / หาสูตร'),
            subtitle: const Text('ดูว่าไบต์ไหนเปลี่ยนตามอะไร แล้วเทียบกับเครื่องมือศูนย์'),
            onTap: () => Navigator.pop(ctx, 'watch'),
          ),
          ListTile(
            leading: const Icon(Icons.add_circle_outline_rounded),
            title: const Text('เพิ่มเป็นค่าใหม่ (กำหนดสูตรเอง)'),
            onTap: () => Navigator.pop(ctx, 'add'),
          ),
        ]),
      ),
    );
    if (!mounted || action == null) return;
    final pid = _pidFromHit(h);
    if (action == 'watch') {
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ExtPidDetailScreen(pid: pid, onSave: _saveToPack, startWatching: true),
      ));
    } else {
      final edited = await Navigator.of(context).push<ExtPid?>(
        MaterialPageRoute(builder: (_) => ExtPidEditScreen(pid: pid, sampleRaw: h.data)),
      );
      if (edited != null) _saveToPack(edited);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final session = ref.watch(sessionProvider);
    final lib = ref.watch(extLibraryIndexProvider).valueOrNull ?? const <ExtLibraryEntry>[];
    final presets = <_Preset>[
      for (final e in lib)
        if (e.scan.isNotEmpty)
          _Preset('ตามชุด ${e.name}', '${e.scan.length} ช่วง · ${e.scan.map((j) => j.label).take(3).join(', ')}${e.scan.length > 3 ? ' …' : ''}', e.scan,
              entry: e),
      ..._genericPresets,
    ];
    final preset = _effective(presets, lib);
    final jobs = preset?.jobs;
    final total = jobs?.fold<int>(0, (a, j) => a + j.count);
    final hits = _hits;
    final stats = _stats;
    final byHeader = <String, List<DidHit>>{};
    for (final h in hits ?? const <DidHit>[]) {
      (byHeader[h.header.isEmpty ? '7DF' : h.header] ??= []).add(h);
    }
    return Scaffold(
      appBar: AppBar(title: const Text('ค้นหาค่าที่กล่องตอบ')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 40), children: [
        PremiumCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              'ส่งคำสั่งอ่านทีละเลขแล้วเก็บเลขที่กล่องตอบกลับ ใช้หาว่ารุ่นนี้มีค่าอะไรให้อ่าน '
              'จากนั้นแตะรายการเพื่อดูไบต์สด เทียบกับเครื่องมือศูนย์ และให้แอปหาสูตรให้',
              style: TextStyle(color: cs.onSurfaceVariant, height: 1.5, fontSize: 13),
            ),
            const SizedBox(height: 6),
            Text(
              'ควรทำตอนบิดกุญแจ ON หรือเครื่องเดินเบาจอดนิ่ง ใช้เฉพาะคำสั่งอ่าน (21/22) ไม่เขียนค่าลงกล่อง',
              style: TextStyle(color: cs.onSurfaceVariant, height: 1.5, fontSize: 12),
            ),
          ]),
        ),
        const SectionLabel('ช่วงที่จะค้นหา'),
        DropdownButtonFormField<int>(
          key: ValueKey(preset?.title ?? 'custom'),
          isExpanded: true,
          initialValue: preset == null ? -1 : presets.indexWhere((p) => p.title == preset.title),
          decoration: const InputDecoration(isDense: true),
          items: [
            const DropdownMenuItem(value: -1, child: Text('กำหนดเอง')),
            for (var i = 0; i < presets.length; i++)
              DropdownMenuItem(value: i, child: Text(presets[i].title, overflow: TextOverflow.ellipsis)),
          ],
          onChanged: _busy
              ? null
              : (v) => setState(() {
                    if (v == null || v < 0) {
                      _custom = true;
                      _preset = null;
                    } else {
                      _custom = false;
                      _preset = presets[v];
                    }
                  }),
        ),
        const SizedBox(height: 12),
        PremiumCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (jobs != null) ...[
              Text(preset!.subtitle, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5)),
              const SizedBox(height: 8),
              for (final j in jobs)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(j.label, style: const TextStyle(fontFamily: kMono, fontSize: 13)),
                ),
              const SizedBox(height: 4),
              Text('รวม $total เลข ใช้เวลาประมาณ ${((total ?? 0) * 0.15 / 60).ceil()} นาที (หยุดกลางทางได้)',
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
            ] else ...[
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 0x21, label: Text('21 (KWP)')),
                  ButtonSegment(value: 0x22, label: Text('22 (UDS)')),
                ],
                selected: {_service},
                onSelectionChanged: _busy ? null : (s) => _setService(s.first),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _header,
                    enabled: !_busy,
                    decoration: const InputDecoration(labelText: 'Header', hintText: '7E0'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _rx,
                    enabled: !_busy,
                    decoration: const InputDecoration(labelText: 'ตอบจาก', hintText: 'ปกติ'),
                  ),
                ),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: TextField(controller: _start, enabled: !_busy, decoration: const InputDecoration(labelText: 'เริ่ม (hex)')),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(controller: _end, enabled: !_busy, decoration: const InputDecoration(labelText: 'ถึง (hex)')),
                ),
              ]),
            ],
            const SizedBox(height: 14),
            if (!session.isConnected)
              Text('เชื่อมต่อรถก่อน', style: TextStyle(color: cs.onSurfaceVariant))
            else
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: Icon(_busy ? Icons.stop_rounded : Icons.radar_rounded),
                  label: Text(_busy ? 'หยุด ($_current)' : 'เริ่มค้นหา'),
                  onPressed: _busy ? () => setState(() => _cancel = true) : () => _run(preset),
                ),
              ),
            if (_busy) ...[const SizedBox(height: 10), LinearProgressIndicator(value: _progress)],
            if (_error != null) ...[const SizedBox(height: 10), Text(_error!, style: TextStyle(color: cs.error))],
            if (_note != null && !_busy) ...[
              const SizedBox(height: 10),
              Text(_note!, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5, height: 1.4)),
            ],
          ]),
        ),
        if (stats != null && stats.isNotEmpty && !_busy) ...[
          const SectionLabel('สรุปแต่ละช่วง'),
          for (final s in stats)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: PremiumCard(
                glow: s.found > 0 ? StatusColors.good : null,
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                radius: 16,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(s.summary, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13, height: 1.4)),
                  if (s.hint.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(s.hint, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant, height: 1.4)),
                  ],
                ]),
              ),
            ),
        ],
        if (hits != null) ...[
          SectionLabel('กล่องตอบ ${hits.length} รายการ'),
          if (hits.isEmpty && !_busy)
            Text('ไม่มีเลขที่กล่องตอบในช่วงนี้ ลองเปลี่ยนช่วง ชนิดคำสั่ง หรือ header',
                style: TextStyle(color: cs.onSurfaceVariant)),
          if (hits.isNotEmpty && !_busy)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _savedAllPackId == null
                  ? OutlinedButton.icon(
                      icon: const Icon(Icons.library_add_rounded),
                      label: const Text('บันทึกเลขที่เจอทั้งหมดเป็นชุดใหม่'),
                      onPressed: () => _saveAllHits(List.of(hits)),
                    )
                  : FilledButton.tonalIcon(
                      icon: const Icon(Icons.auto_fix_high_rounded),
                      label: const Text('บันทึกแล้ว · จับคู่กับค่า OBD มาตรฐาน'),
                      onPressed: () => _openAutoMatch(_savedAllPackId!),
                    ),
            ),
          for (final e in byHeader.entries) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
              child: Text('กล่อง ${e.key} · ${e.value.length} รายการ',
                  style: TextStyle(fontWeight: FontWeight.w700, color: cs.onSurfaceVariant)),
            ),
            for (final h in e.value)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: PremiumCard(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                  radius: 16,
                  onTap: () => _hitActions(h),
                  child: Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(h.request, style: const TextStyle(fontWeight: FontWeight.w800, fontFamily: kMono)),
                        const SizedBox(height: 2),
                        Text('${h.data.length} B: ${h.hex}',
                            style: TextStyle(fontSize: 12, fontFamily: kMono, color: cs.onSurfaceVariant),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis),
                      ]),
                    ),
                    const Icon(Icons.chevron_right_rounded),
                  ]),
                ),
              ),
          ],
        ],
      ]),
    );
  }
}
