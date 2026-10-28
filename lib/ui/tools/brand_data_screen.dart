import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/obd/ext_known.dart';
import '../../core/obd/ext_pid.dart';
import '../../core/transport/demo_transport.dart';
import '../../state/ext_packs.dart';
import '../../state/live_poller.dart';
import '../../state/providers.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'did_scanner_screen.dart';
import 'ext_automatch_screen.dart';
import 'ext_common.dart';
import 'ext_library_screen.dart';
import 'ext_pid_detail_screen.dart';
import 'ext_pid_edit_screen.dart';

bool _isInjectorGroup(String g) {
  final l = g.toLowerCase();
  return l.contains('หัวฉีด') || l.contains('injector');
}

/// ค่าเฉพาะยี่ห้อ: ค่าชดเชยหัวฉีดรายสูบ อุณหภูมิน้ำมันเกียร์ เขม่า DPF ฯลฯ
/// ค่าเหล่านี้ไม่อยู่ใน OBD มาตรฐาน ต้องรู้เลขคำสั่งของรถแต่ละรุ่น
class BrandDataScreen extends ConsumerStatefulWidget {
  const BrandDataScreen({super.key, this.initialTab});

  /// 0 = ชุดของฉัน, 1 = คลังชุดข้อมูล (ไม่ระบุ = เลือกให้ตามที่มีชุดอยู่)
  final int? initialTab;

  @override
  ConsumerState<BrandDataScreen> createState() => _BrandDataScreenState();
}

class _BrandDataScreenState extends ConsumerState<BrandDataScreen> {
  /// เก็บไว้ตั้งแต่ initState (ห้ามใช้ ref ใน dispose)
  late final LivePoller _poller;

  @override
  void initState() {
    super.initState();
    _poller = ref.read(livePollerProvider);
  }

  late int _tab = widget.initialTab ?? (ref.read(extPacksProvider).isEmpty ? 1 : 0);
  String? _selId;
  bool _live = false;
  bool _reading = false;
  Map<String, ExtReading> _values = {};
  int _rounds = 0;
  double _progress = 0;
  ExtProbeResult? _probe;
  bool _probing = false;
  String _search = '';
  final _expanded = <String>{};
  static const _pollKey = 'brand_data';

  @override
  void dispose() {
    _live = false;
    resumePoller(_poller, _pollKey);
    super.dispose();
  }

  ExtPidPack? _selected(List<ExtPidPack> packs) {
    if (packs.isEmpty) return null;
    return packs.where((p) => p.id == _selId).firstOrNull ?? packs.first;
  }

  void _snack(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  List<String> _activeGroups(ExtPidPack pack) {
    final all = pack.groups;
    final on = pack.activeGroups;
    if (on == null) return all;
    final act = all.where(on.contains).toList();
    return act.isEmpty ? all : act;
  }

  List<ExtPid> _toRead(ExtPidPack pack) {
    final groups = _activeGroups(pack).toSet();
    return pack.pids.where((p) => groups.contains(p.group.isEmpty ? 'ทั่วไป' : p.group)).toList();
  }

  /// ชุดนี้ทำไว้สำหรับรถคันที่ต่ออยู่หรือไม่
  /// ถ้าไม่ใช่ จะถามเฉพาะกล่องเลขมาตรฐาน (เลขเฉพาะยี่ห้ออาจชนกับข้อความปกติของรถคันนี้)
  bool _fits(ExtPidPack pack, {bool watch = false}) =>
      fitsCurrentVehicle(ref, brand: pack.brand, models: pack.models, years: pack.years, watch: watch);

  // ---------------- อ่านค่า ----------------

  Future<void> _readOnce(ExtPidPack pack) async {
    final service = ref.read(sessionProvider).service;
    final pids = _toRead(pack);
    if (service == null || pids.isEmpty) return;
    setState(() => _reading = true);
    // หยุดตัวอ่านค่าสดชั่วคราว เพราะต้องเปลี่ยน header ไปคุยกับกล่องอื่น
    pausePoller(_poller, _pollKey);
    try {
      final reader = ExtPidReader(service.elm, skip: ref.read(extSkipProvider));
      final r = await reader.readAll(pids, onProgress: (p, _) {
        if (mounted) setState(() => _progress = p);
      }, cancelled: () => !mounted, standardOnly: !_fits(pack));
      if (mounted) {
        setState(() {
          _values = {..._values, ...r};
          _rounds++;
        });
        if (reader.carSilent) {
          // รถไม่ตอบอะไรเลย (ปิดสวิตช์กุญแจ) หยุดอ่านต่อเนื่อง ไม่ต้องรอหมดเวลาทุกรอบ
          _live = false;
          _snack(carSilentText);
        }
      }
    } catch (e) {
      if (mounted) _snack('อ่านค่าไม่สำเร็จ: $e');
      _live = false;
    } finally {
      if (!_live) resumePoller(_poller, _pollKey);
      if (mounted) setState(() => _reading = false);
    }
  }

  Future<void> _toggleLive(ExtPidPack pack) async {
    if (_live) {
      setState(() => _live = false);
      return;
    }
    setState(() => _live = true);
    while (_live && mounted) {
      await _readOnce(pack);
      if (!_live || !mounted) break;
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    resumePoller(_poller, _pollKey);
  }

  Future<void> _probeNow(ExtPidPack pack) async {
    final service = ref.read(sessionProvider).service;
    if (service == null) return;
    setState(() {
      _probing = true;
      _probe = null;
      _live = false;
    });
    pausePoller(_poller, _pollKey);
    try {
      final r = await ExtPidReader(service.elm).probe(pack.pids, maxCommands: 20, standardOnly: !_fits(pack),
          onProgress: (p, _) {
        if (mounted) setState(() => _progress = p);
      });
      if (mounted) {
        setState(() {
          _probe = r;
          _values = {..._values, ...r.readings};
        });
      }
    } finally {
      resumePoller(_poller, _pollKey);
      if (mounted) setState(() => _probing = false);
    }
  }

  // ---------------- จัดการชุด ----------------

  void _select(String id) => setState(() {
        _selId = id;
        _live = false;
        _values = {};
        _rounds = 0;
        _probe = null;
        _search = '';
        _expanded.clear();
      });

  void _useFromLibrary(ExtPidPack pack) {
    _select(pack.id);
    setState(() => _tab = 0);
  }

  Future<void> _newPack() async {
    final name = await askText(context, 'ชื่อชุดค่า', hint: 'เช่น Revo 2.8 1GD ปี\u00A02020');
    if (name == null || name.trim().isEmpty) return;
    final p = ExtPidPack(id: 'pack_${DateTime.now().millisecondsSinceEpoch}', name: name.trim());
    ref.read(extPacksProvider.notifier).put(p);
    _select(p.id);
  }

  Future<void> _import() async {
    final text = await askText(
      context,
      'นำเข้าชุดค่า',
      hint: 'วางข้อความ JSON ที่ส่งออกจากแอปนี้ หรือไฟล์ PID แบบ Torque (CSV)',
      multiline: true,
    );
    if (text == null || text.trim().isEmpty || !mounted) return;
    final PackImport r;
    try {
      r = importPackDetailed(text);
    } catch (e) {
      _snack('รูปแบบข้อความไม่ถูกต้อง');
      return;
    }
    // ด่านอ่านอย่างเดียว: บอกให้รู้ว่าข้ามบรรทัดไหน เพราะอะไร
    if (r.blocked.isNotEmpty) {
      await _showBlocked(r.blocked);
      if (!mounted) return;
    }
    if (r.pack.pids.isEmpty) {
      _snack(r.blocked.isEmpty ? 'ไม่พบรายการที่ใช้ได้ในข้อความนี้' : 'ไม่มีรายการที่เป็นคำสั่งอ่านค่า จึงไม่ได้สร้างชุดใหม่');
      return;
    }
    ref.read(extPacksProvider.notifier).put(r.pack);
    _select(r.pack.id);
    setState(() => _tab = 0);
    final notes = [
      if (r.skipped > 0) 'ข้าม ${r.skipped} บรรทัดที่อ่านไม่ได้',
      if (r.blocked.isNotEmpty) 'ข้าม ${r.blocked.length}\u00A0รายการเพื่อความปลอดภัย',
    ];
    _snack('นำเข้า ${r.pack.pids.length}\u00A0รายการ${notes.isEmpty ? '' : ' (${notes.join(', ')})'}');
  }

  Future<void> _showBlocked(List<BlockedPid> blocked) => showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          icon: const Icon(Icons.shield_rounded),
          title: Text('ข้าม ${blocked.length}\u00A0รายการเพื่อความปลอดภัย'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                const Text(
                  'แอปส่งให้รถเฉพาะคำสั่งอ่านค่า รายการเหล่านี้เป็นคำสั่งที่เปลี่ยนแปลงกล่องหรือสั่งรถทำงาน จึงไม่ถูกนำเข้า',
                ),
                const SizedBox(height: 12),
                for (final b in blocked)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text('• ${b.label}'),
                  ),
              ],
            ),
          ),
          actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('รับทราบ'))],
        ),
      );

  void _loadDemo() {
    final p = demoPack();
    ref.read(extPacksProvider.notifier).put(p);
    _select(p.id);
  }

  Future<void> _packMenu(ExtPidPack pack, String action) async {
    final n = ref.read(extPacksProvider.notifier);
    switch (action) {
      case 'rename':
        final name = await askText(context, 'เปลี่ยนชื่อชุด', initial: pack.name);
        if (name != null && name.trim().isNotEmpty) n.put(pack..name = name.trim());
      case 'share':
        // iPad แสดงหน้าต่างแชร์แบบลอย ต้องบอกตำแหน่งอ้างอิง (ไม่ใส่จะแชร์ไม่ได้บน iPad)
        final box = context.findRenderObject() as RenderBox?;
        await SharePlus.instance.share(ShareParams(
          text: pack.export(),
          subject: 'ชุดค่า ${pack.name}',
          sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
        ));
      case 'copy':
        await Clipboard.setData(ClipboardData(text: pack.export()));
        if (mounted) _snack('คัดลอกแล้ว ส่งให้ช่างคนอื่นนำเข้าได้');
      case 'sources':
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('แหล่งที่มา'),
            content: SingleChildScrollView(child: SourcesCard(sources: pack.sources)),
            actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('ปิด'))],
          ),
        );
      case 'retry':
        ref.read(extSkipProvider).clear();
        _snack('จะลองถามคำสั่งที่รถไม่ตอบอีกครั้งในรอบถัดไป');
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text('ลบชุด "${pack.name}"?'),
            content: Text('${pack.pids.length}\u00A0รายการในชุดนี้ (รวมผลยืนยันของร้าน) จะถูกลบออกจากเครื่อง'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('ยกเลิก')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('ลบ')),
            ],
          ),
        );
        if (ok == true) {
          n.remove(pack.id);
          setState(() {
            _selId = null;
            _live = false;
            _values = {};
          });
        }
    }
  }

  Future<void> _addPid(ExtPidPack pack) async {
    final edited = await Navigator.of(context).push<ExtPid?>(MaterialPageRoute(builder: (_) => const ExtPidEditScreen()));
    if (edited == null) return;
    pack.pids.add(edited);
    ref.read(extPacksProvider.notifier).put(pack);
    setState(() {});
  }

  Future<void> _openPid(ExtPidPack pack, ExtPid pid) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ExtPidDetailScreen(pid: pid, packId: pack.id)));
    if (mounted) setState(() {});
  }

  void _deletePid(ExtPidPack pack, ExtPid pid) {
    pack.pids.remove(pid);
    ref.read(extPacksProvider.notifier).put(pack);
    setState(() {});
  }

  void _toggleGroup(ExtPidPack pack, String g) {
    final act = _activeGroups(pack).toList();
    if (act.contains(g)) {
      if (act.length == 1) return;
      act.remove(g);
    } else {
      act.add(g);
    }
    pack.activeGroups = act.length == pack.groups.length ? null : act;
    ref.read(extPacksProvider.notifier).put(pack);
    setState(() {});
  }

  // ---------------- หน้าจอ ----------------

  @override
  Widget build(BuildContext context) {
    final packs = ref.watch(extPacksProvider);
    final pack = _selected(packs);
    return Scaffold(
      appBar: AppBar(title: const FitText('ค่าเฉพาะยี่ห้อ'), actions: [
        IconButton(
          tooltip: 'ค้นหาค่าที่กล่องตอบ',
          icon: const Icon(Icons.radar_rounded),
          onPressed: () => Navigator.of(context)
              .push(MaterialPageRoute<void>(builder: (_) => DidScannerScreen(targetPackId: pack?.id)))
              .then((_) => mounted ? setState(() {}) : null),
        ),
        IconButton(tooltip: 'นำเข้า', icon: const Icon(Icons.download_rounded), onPressed: _import),
      ]),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 40), children: [
        SegmentedButton<int>(
          segments: [
            ButtonSegment(
                value: 0,
                icon: const Icon(Icons.folder_special_rounded),
                label: FitText('ชุดของฉัน (${packs.length})', alignment: Alignment.center)),
            const ButtonSegment(
                value: 1, icon: Icon(Icons.library_books_rounded), label: FitText('คลังชุดข้อมูล', alignment: Alignment.center)),
          ],
          selected: {_tab},
          onSelectionChanged: (s) => setState(() {
            _tab = s.first;
            _live = false;
          }),
        ),
        const SizedBox(height: 14),
        if (_tab == 1) ExtLibraryView(onUse: _useFromLibrary) else ..._mine(packs, pack),
      ]),
    );
  }

  List<Widget> _mine(List<ExtPidPack> packs, ExtPidPack? pack) {
    final session = ref.watch(sessionProvider);
    final demo = session.transport is DemoTransport;
    return [
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final p in packs)
          ChoiceChip(
            label: FitText(p.name),
            avatar: p.verified ? const Icon(Icons.verified_rounded, size: 18) : null,
            selected: p.id == pack?.id,
            onSelected: (_) => _select(p.id),
          ),
        ActionChip(avatar: const Icon(Icons.add_rounded, size: 18), label: const Text('สร้างชุดใหม่'), onPressed: _newPack),
        if (demo && !packs.any((p) => p.id == 'demo_pack'))
          ActionChip(
            avatar: const Icon(Icons.science_rounded, size: 18),
            label: const Text('โหลดชุดตัวอย่างรถจำลอง'),
            onPressed: _loadDemo,
          ),
      ]),
      if (pack == null)
        Padding(
          padding: const EdgeInsets.only(top: 18),
          child: EmptyState(
            icon: Icons.tune_rounded,
            title: 'ยังไม่มีชุดค่า',
            text: 'เลือกชุดของรุ่นที่ต้องการจาก "คลังชุดข้อมูล" นำเข้าไฟล์ PID หรือสร้างชุดเอง',
            action: FilledButton.icon(
              icon: const Icon(Icons.library_books_rounded),
              label: const Text('เปิดคลังชุดข้อมูล'),
              onPressed: () => setState(() => _tab = 1),
            ),
          ),
        )
      else
        ..._packBody(pack, session),
    ];
  }

  List<Widget> _packBody(ExtPidPack pack, SessionState session) {
    final cs = Theme.of(context).colorScheme;
    final verified = pack.pids.where((p) => p.verified).length;
    final evidence = pack.pids.where((p) => !p.verified && p.hasEvidence).length;
    final pending = pack.pids.length - verified - evidence;
    final active = _activeGroups(pack);
    final allGroups = pack.groups;
    final q = _search.toLowerCase();
    final searching = q.isNotEmpty;
    final readCount = _toRead(pack).length;
    final readCmds = {for (final p in _toRead(pack)) p.cmdKey}.length;
    // ชุดของรถคนละรุ่น: ถามเฉพาะกล่องเลขมาตรฐาน
    final fits = _fits(pack, watch: true);
    final brandOnly = pack.pids.where((p) => !p.standardHeader).length;
    final veh = currentVehicle(ref);
    final carText = [veh?.make, veh?.model, veh?.year?.toString()].whereType<String>().join(' ');
    final packFor = [pack.brand, if (pack.models.isNotEmpty) pack.models.first, pack.yearsText]
        .where((s) => s.isNotEmpty)
        .join(' ');
    return [
      const SizedBox(height: 16),
      Row(children: [
        Expanded(child: Text(pack.name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17))),
        PopupMenuButton<String>(
          onSelected: (a) => _packMenu(pack, a),
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'rename', child: Text('เปลี่ยนชื่อ')),
            const PopupMenuItem(value: 'share', child: Text('ส่งออก / แชร์')),
            const PopupMenuItem(value: 'copy', child: Text('คัดลอกเป็นข้อความ')),
            if (pack.sources.isNotEmpty) const PopupMenuItem(value: 'sources', child: Text('แหล่งที่มาและสัญญาอนุญาต')),
            const PopupMenuItem(value: 'retry', child: Text('ลองคำสั่งที่รถไม่ตอบอีกครั้ง')),
            const PopupMenuItem(value: 'delete', child: Text('ลบชุดนี้')),
          ],
        ),
      ]),
      if (pack.brand.isNotEmpty || pack.models.isNotEmpty)
        Text(thaiKeep('${pack.brand}\u00A0· ${pack.models.join(', ')}${pack.yearsText.isEmpty ? '' : '\u00A0· ${pack.yearsText}'}'),
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5)),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 6, children: [
        if (verified > 0) Pill(text: 'ร้านยืนยัน $verified', color: StatusColors.good, icon: Icons.verified_rounded),
        if (evidence > 0) Pill(text: 'พบในรถจริง $evidence', color: StatusColors.info, icon: Icons.fact_check_rounded),
        if (pending > 0) Pill(text: 'รอยืนยัน $pending', color: StatusColors.warn, icon: Icons.help_outline_rounded),
      ]),
      if (pack.note.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text(thaiKeep(pack.note), style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant, height: 1.45)),
      ],
      if (pack.sources.isNotEmpty)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
            icon: const Icon(Icons.info_outline_rounded, size: 18),
            label: Text('ที่มา: ${pack.sources.map((s) => s.name).join('\u00A0· ')}', style: const TextStyle(height: 1.3)),
            onPressed: () => _packMenu(pack, 'sources'),
          ),
        ),
      const SizedBox(height: 10),
      _KnownNamesCard(pack: pack),
      if (session.isConnected && !fits && brandOnly > 0) ...[
        PremiumCard(
          glow: StatusColors.warn,
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          radius: 16,
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.shield_outlined, color: StatusColors.warn, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '${carText.isEmpty ? 'แอปยังไม่รู้ว่ารถที่ต่ออยู่เป็นยี่ห้อ/รุ่นไหน (แตะ "เลือกรถ" ที่หน้าหลัก หรือใส่ยี่ห้อ รุ่น ปี ในโรงรถ)' : 'ชุดนี้ทำไว้สำหรับ $packFor แต่รถที่ต่ออยู่คือ $carText'} '
                'แอปจะถามเฉพาะกล่องเลขมาตรฐาน (7DF, 7E0–7E7) และข้าม $brandOnly\u00A0ค่าที่ส่งไปกล่องเลขเฉพาะยี่ห้อ '
                'เพราะรถคนละรุ่นอาจใช้เลขนั้นเป็นข้อความปกติ คำสั่งจะไปชนกันได้',
                style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant, height: 1.45),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 10),
      ],
      if (!session.isConnected)
        Text('เชื่อมต่อรถเพื่ออ่านค่า', style: TextStyle(color: cs.onSurfaceVariant))
      else if (pack.pids.isNotEmpty) ...[
        ButtonPair(
          minWidth: 140,
          first: FilledButton.icon(
            icon: Icon(_live ? Icons.stop_rounded : Icons.play_arrow_rounded),
            label: FitText(_live ? 'หยุดอ่านต่อเนื่อง' : 'อ่านต่อเนื่อง'),
            onPressed: _probing ? null : () => _toggleLive(pack),
          ),
          second: OutlinedButton(
            onPressed: _live || _reading || _probing ? null : () => _readOnce(pack),
            child: const FitText('อ่านครั้งเดียว'),
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.rule_rounded),
          label: const Text('ทดสอบกับรถคันนี้'),
          onPressed: _live || _reading || _probing ? null : () => _probeNow(pack),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.auto_fix_high_rounded),
          label: const Text('จับคู่กับค่า OBD มาตรฐาน'),
          onPressed: _live || _reading || _probing
              ? null
              : () => Navigator.of(context)
                  .push(MaterialPageRoute<void>(builder: (_) => ExtAutoMatchScreen(packId: pack.id)))
                  .then((_) => mounted ? setState(() {}) : null),
        ),
        Text('อ่าน $readCount\u00A0ค่าจาก $readCmds\u00A0คำสั่ง (เลือกกลุ่มด้านล่าง)',
            style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant)),
      ],
      if (_reading || _probing)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: LinearProgressIndicator(value: _progress, minHeight: 3),
        ),
      if (_probe != null) ...[const SizedBox(height: 10), ProbeResultCard(result: _probe!)],
      if (allGroups.length > 1) ...[
        const SectionLabel('กลุ่มที่อ่าน'),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final g in allGroups)
            FilterChip(
              label: FitText('$g (${pack.pids.where((p) => (p.group.isEmpty ? 'ทั่วไป' : p.group) == g).length})'),
              selected: active.contains(g),
              onSelected: (_) => _toggleGroup(pack, g),
            ),
        ]),
      ],
      if (pack.pids.length > 30) ...[
        const SizedBox(height: 12),
        TextField(
          decoration: const InputDecoration(prefixIcon: Icon(Icons.search_rounded), hintText: 'ค้นหาค่าในชุดนี้ (ไทย/อังกฤษ)'),
          onChanged: (v) => setState(() => _search = v.trim()),
        ),
      ],
      for (final g in (searching ? allGroups : active)) ..._groupSection(pack, g, q),
      const SizedBox(height: 14),
      Wrap(spacing: 10, runSpacing: 8, children: [
        OutlinedButton.icon(icon: const Icon(Icons.add_rounded), label: const Text('เพิ่มค่า'), onPressed: () => _addPid(pack)),
        OutlinedButton.icon(
          icon: const Icon(Icons.radar_rounded),
          label: const Text('ค้นหาค่าที่กล่องตอบ'),
          onPressed: () => Navigator.of(context)
              .push(MaterialPageRoute<void>(builder: (_) => DidScannerScreen(targetPackId: pack.id)))
              .then((_) => mounted ? setState(() {}) : null),
        ),
      ]),
      if (_rounds > 0)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text('อ่านแล้ว $_rounds\u00A0รอบ', style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant)),
        ),
    ];
  }

  List<Widget> _groupSection(ExtPidPack pack, String g, String q) {
    final cs = Theme.of(context).colorScheme;
    var pids = pack.pids.where((p) => (p.group.isEmpty ? 'ทั่วไป' : p.group) == g).toList();
    if (q.isNotEmpty) {
      pids = pids.where((p) => p.name.toLowerCase().contains(q) || (p.en ?? '').toLowerCase().contains(q) || p.request.toLowerCase().contains(q)).toList();
      if (pids.isEmpty) return const [];
    }
    final limit = _expanded.contains(g) || q.isNotEmpty ? pids.length : 40;
    final shown = pids.take(limit).toList();
    // กราฟหัวฉีดรายสูบ: รวมค่าชนิดเดียวกันของแต่ละสูบ (ชื่อเหมือนกันต่างแค่เลขสูบ)
    // ถ้าคำสั่งเดียวให้หลายสูบ แยกตามคำสั่ง เพื่อไม่ปนค่าจากคำสั่งของรุ่นอื่น
    final charts = <Widget>[];
    if (_isInjectorGroup(g)) {
      final perCmd = <String, int>{};
      for (final p in pids) {
        perCmd[p.cmdKey] = (perCmd[p.cmdKey] ?? 0) + 1;
      }
      final byFamily = <String, List<ExtPid>>{};
      for (final p in pids) {
        if (_values[p.key]?.value == null) continue;
        final fam = '${p.header}|${perCmd[p.cmdKey]! > 1 ? p.request : ''}|${p.name.replaceAll(RegExp(r'\d+'), '#')}';
        (byFamily[fam] ??= []).add(p);
      }
      for (final list in byFamily.values) {
        if (list.length >= 2) {
          charts.add(Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: PremiumCard(child: _InjectorChart(pids: list, values: _values)),
          ));
        }
      }
    }
    return [
      SectionLabel(g, trailing: Text('${pids.length}\u00A0ค่า', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant))),
      ...charts,
      PremiumCard(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        radius: 18,
        child: Column(children: [
          for (final p in shown)
            _PidRow(
              pid: p,
              reading: _values[p.key],
              onOpen: () => _openPid(pack, p),
              onDelete: () => _deletePid(pack, p),
            ),
          if (pids.length > shown.length)
            TextButton(
              onPressed: () => setState(() => _expanded.add(g)),
              child: Text('แสดงทั้งหมด ${pids.length}\u00A0ค่า'),
            ),
        ]),
      ),
    ];
  }
}

class _PidRow extends StatelessWidget {
  const _PidRow({required this.pid, required this.reading, required this.onOpen, required this.onDelete});

  final ExtPid pid;
  final ExtReading? reading;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final r = reading;
    final v = r?.value;
    final raw = r?.raw;
    final (_, tColor, tIcon) = trustStyle(pid);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onOpen,
      onLongPress: () async {
        final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text('ลบ "${pid.name}"?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('ยกเลิก')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('ลบ')),
            ],
          ),
        );
        if (ok == true) onDelete();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        child: Row(children: [
          Icon(tIcon, size: 18, color: tColor),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(thaiKeep(pid.name), style: const TextStyle(fontWeight: FontWeight.w600)),
              if (pid.en != null)
                Text(pid.en!, style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
              const SizedBox(height: 2),
              Text(
                '${pid.header.isEmpty ? '7DF' : pid.header}\u00A0· ${pid.request}'
                '${raw != null && raw.isNotEmpty ? ' → ${bytesToHex(raw.take(8).toList())}${raw.length > 8 ? ' …' : ''}' : ''}',
                style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant, fontFamily: kMono, fontFamilyFallback: const [kFont]),
              ),
            ]),
          ),
          const SizedBox(width: 10),
          if (v != null)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 150),
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(
                    text: pid.format(v),
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: pid.isState ? 15 : 20,
                      color: r!.outOfRange ? StatusColors.bad : cs.onSurface,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  if (pid.unit.isNotEmpty && !pid.isState)
                    TextSpan(text: ' ${pid.unit}', style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant)),
                ]),
                textAlign: TextAlign.right,
              ),
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 140),
              child: Text(
                // ค่าที่ใช้คำสั่งต้องห้ามยังอยู่ในชุด (ไม่ลบให้) แต่แอปไม่ส่งให้รถ
                pid.safetyBlock != null ? 'ไม่ส่ง: ไม่ใช่คำสั่งอ่านค่า' : r?.error ?? '—',
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: 12,
                  color: pid.safetyBlock != null
                      ? StatusColors.bad
                      : r == null || r.skipped
                          ? cs.onSurfaceVariant
                          : StatusColors.warn,
                ),
              ),
            ),
        ]),
      ),
    );
  }
}

/// กราฟแท่งค่าชดเชยหัวฉีด (กึ่งกลาง = 0) ชี้สูบที่ต่างจากสูบอื่นชัด
class _InjectorChart extends StatelessWidget {
  const _InjectorChart({required this.pids, required this.values});

  final List<ExtPid> pids;
  final Map<String, ExtReading> values;

  /// สูบที่ต่างจากค่าเฉลี่ยของสูบอื่นเกินค่านี้ (หน่วยเดียวกับค่าที่อ่าน) จะถูกชี้
  static const deviation = 1.5;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final vals = [for (final p in pids) values[p.key]!.value!];
    // สเกลไม่เล็กกว่าเกณฑ์ชี้สูบผิดปกติ เพื่อไม่ให้ค่าเล็ก ๆ ดูเหมือนต่างกันมาก
    var span = vals.map((v) => v.abs()).fold<double>(0, (a, b) => a > b ? a : b);
    if (span < deviation * 1.5) span = deviation * 1.5;
    final flagged = <int>{};
    for (var i = 0; i < vals.length; i++) {
      final others = [for (var j = 0; j < vals.length; j++) if (j != i) vals[j]];
      final avg = others.reduce((a, b) => a + b) / others.length;
      if ((vals[i] - avg).abs() > deviation) flagged.add(i);
    }
    final unit = pids.first.unit;
    String fmt(double v) => v.toStringAsFixed(pids.first.decimals.clamp(0, 3));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(flagged.isEmpty ? Icons.verified_rounded : Icons.report_rounded,
            color: flagged.isEmpty ? StatusColors.good : StatusColors.bad),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            flagged.isEmpty ? 'ทุกสูบใกล้เคียงกัน' : 'ต่างจากสูบอื่นชัด: ${flagged.map((i) => pids[i].name).join(', ')}',
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
      ]),
      const SizedBox(height: 14),
      for (var i = 0; i < pids.length; i++)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(children: [
            SizedBox(
              width: 44,
              child: Text('#${i + 1}', style: TextStyle(fontWeight: FontWeight.w700, color: cs.onSurfaceVariant)),
            ),
            Expanded(
              child: SizedBox(
                height: 18,
                child: LayoutBuilder(builder: (context, c) {
                  final half = c.maxWidth / 2;
                  final w = (vals[i].abs() / span).clamp(0.0, 1.0) * half;
                  final color = flagged.contains(i) ? StatusColors.bad : cs.primary;
                  return Stack(children: [
                    Positioned(left: half - 0.5, top: 0, bottom: 0, child: Container(width: 1, color: cs.outline)),
                    Positioned(
                      left: vals[i] >= 0 ? half : half - w,
                      top: 3,
                      bottom: 3,
                      child: Container(
                        width: w < 2 ? 2 : w,
                        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4)),
                      ),
                    ),
                  ]);
                }),
              ),
            ),
            SizedBox(
              width: 76,
              child: Text(
                '${vals[i] >= 0 ? '+' : ''}${fmt(vals[i])}',
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: flagged.contains(i) ? StatusColors.bad : cs.onSurface,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ]),
        ),
      const SizedBox(height: 8),
      Text(
        'แท่งไปทางบวก = กล่องสั่งฉีดเพิ่มเพื่อชดเชย, ทางลบ = สั่งลดลง',
        style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant, height: 1.4),
      ),
      Text(
        'ชี้สูบที่ต่างจากค่าเฉลี่ยสูบอื่นเกิน ${deviation.toStringAsFixed(1)}${unit.isEmpty ? '' : ' $unit'} '
        'เป็นเกณฑ์คร่าว ๆ ควรเทียบกับคู่มือของรุ่นนั้น และดูขณะเครื่องเดินเบาที่ร้อนแล้ว',
        style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant, height: 1.4),
      ),
    ]);
  }
}

/// ค่าที่ค้นพบเองที่รู้แล้วว่าเป็นค่าอะไร (เลขตรงกับชุดในคลังของรถรุ่นเดียวกัน): กดครั้งเดียวตั้งชื่อ สูตร หน่วยให้
class _KnownNamesCard extends ConsumerWidget {
  const _KnownNamesCard({required this.pack});

  final ExtPidPack pack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final matches = ref.watch(knownNamesProvider(pack.id)).valueOrNull ?? const <KnownMatch>[];
    if (matches.isEmpty) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final names = [for (final m in matches) ...m.known.map((k) => k.name)];
    final sources = {for (final m in matches) m.source};
    final unknown = pack.pids.where(isUnnamedDiscovered).length - matches.length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: PremiumCard(
        glow: StatusColors.info,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        radius: 16,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.lightbulb_rounded, color: StatusColors.info, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text('รู้แล้วว่าเป็นค่าอะไร ${matches.length}\u00A0ค่า',
                  style: const TextStyle(fontWeight: FontWeight.w800)),
            ),
          ]),
          const SizedBox(height: 6),
          Text(
            'เลขเหล่านี้มีชื่ออยู่ในชุด ${sources.map((s) => '"$s"').join(', ')} ของรถรุ่นเดียวกันแล้ว: '
            '${names.take(6).join(', ')}${names.length > 6 ? ' และอีก ${names.length - 6}\u00A0ค่า' : ''}',
            style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant, height: 1.45),
          ),
          if (unknown > 0) ...[
            const SizedBox(height: 4),
            Text(
              'อีก $unknown\u00A0ค่ายังไม่รู้ ใช้ "จับคู่กับค่า OBD มาตรฐาน" ตอนติดเครื่อง หรือเทียบกับเครื่องมือศูนย์ในหน้าของแต่ละค่า',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant, height: 1.45),
            ),
          ],
          const SizedBox(height: 10),
          FilledButton.icon(
            icon: const Icon(Icons.drive_file_rename_outline_rounded),
            label: Text('ตั้งชื่อจากคลัง (${matches.length}\u00A0ค่า)'),
            onPressed: () {
              ref.read(extPacksProvider.notifier).put(applyKnown(pack, matches));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('ตั้งชื่อ สูตร และหน่วยจากคลังให้ ${matches.length}\u00A0ค่าแล้ว')),
              );
            },
          ),
        ]),
      ),
    );
  }
}
