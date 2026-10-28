import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/obd/ext_library.dart';
import '../../core/obd/ext_pid.dart';
import '../../state/ext_packs.dart';
import '../../state/live_poller.dart';
import '../../state/providers.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'ext_common.dart';

/// รายการคลังชุดค่า (ใช้เป็นแท็บในหน้าค่าเฉพาะยี่ห้อ)
class ExtLibraryView extends ConsumerStatefulWidget {
  const ExtLibraryView({super.key, required this.onUse});

  /// ผู้ใช้เลือกใช้ชุดนี้ (คัดลอกเข้า "ชุดของฉัน" แล้ว)
  final void Function(ExtPidPack pack) onUse;

  @override
  ConsumerState<ExtLibraryView> createState() => _ExtLibraryViewState();
}

class _ExtLibraryViewState extends ConsumerState<ExtLibraryView> {
  String _query = '';
  String? _brand;

  Future<void> _use(ExtLibraryEntry e) async {
    final pack = await ref.read(extLibraryProvider).pack(e);
    final adopted = ref.read(extPacksProvider.notifier).adopt(pack);
    widget.onUse(adopted);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final idx = ref.watch(extLibraryIndexProvider);
    final session = ref.watch(sessionProvider);
    final veh = currentVehicle(ref);
    return idx.when(
      loading: () => const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())),
      error: (e, _) => Padding(padding: const EdgeInsets.all(24), child: Text('โหลดคลังไม่ได้: $e')),
      data: (entries) {
        final brands = <String>[];
        for (final e in entries) {
          if (!brands.contains(e.brand)) brands.add(e.brand);
        }
        final q = _query.toLowerCase();
        final shown = entries.where((e) {
          if (_brand != null && e.brand != _brand) return false;
          if (q.isEmpty) return true;
          return e.name.toLowerCase().contains(q) || e.models.any((m) => m.toLowerCase().contains(q)) || e.brand.toLowerCase().contains(q);
        }).toList();
        // เรียงแบบคงลำดับเดิมเมื่อคะแนนเท่ากัน (กระบะก่อน แล้วตามลำดับในคลัง ซึ่งเรียงรุ่นยอดนิยมไว้ก่อน)
        // List.sort ของ Dart ไม่รักษาลำดับเดิม จึงต้องใส่ลำดับในคลังเป็นตัวตัดสินเอง
        final order = {for (var i = 0; i < entries.length; i++) entries[i].lib: i};
        int score(ExtLibraryEntry e) => veh == null ? 0 : e.matchScore(brand: veh.make, model: veh.model, year: veh.year);
        shown.sort((a, b) {
          final s = score(b).compareTo(score(a));
          if (s != 0) return s;
          final k = (a.kind == 'truck' ? 0 : 1).compareTo(b.kind == 'truck' ? 0 : 1);
          if (k != 0) return k;
          return (order[a.lib] ?? 0).compareTo(order[b.lib] ?? 0);
        });
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          PremiumCard(
            glow: cs.primary,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('คลังชุดค่าที่มากับแอป', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              const SizedBox(height: 8),
              Text(
                'รวบรวมจากฐานข้อมูลเปิด OBDb (บันทึกจากรถจริง) และแหล่งที่ระบุในแต่ละชุด แต่ละค่ามีป้ายบอกว่า '
                '"พบในรถจริง" หรือ "รอยืนยัน" ก่อนใช้ตัดสินงานซ่อมให้ทดสอบกับรถคันจริงและเทียบกับเครื่องมือศูนย์',
                style: TextStyle(color: cs.onSurfaceVariant, height: 1.5, fontSize: 13),
              ),
              if (session.isConnected) ...[
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.manage_search_rounded),
                    label: const Text('หาชุดที่ตรงกับรถคันนี้'),
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => ExtMatchScreen(onUse: (p) {
                        Navigator.of(context).pop();
                        widget.onUse(p);
                      }),
                    )),
                  ),
                ),
              ],
            ]),
          ),
          const SizedBox(height: 12),
          TextField(
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search_rounded), hintText: 'ค้นหารุ่น เช่น Revo, D-Max'),
            onChanged: (v) => setState(() => _query = v.trim()),
          ),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            ChoiceChip(label: const Text('ทุกยี่ห้อ'), selected: _brand == null, onSelected: (_) => setState(() => _brand = null)),
            for (final b in brands)
              ChoiceChip(label: Text(b), selected: _brand == b, onSelected: (_) => setState(() => _brand = _brand == b ? null : b)),
          ]),
          const SizedBox(height: 4),
          for (final e in shown) ...[
            if (q.isEmpty && _brand == null && veh == null && (identical(e, shown.first) || shown[shown.indexOf(e) - 1].kind != e.kind))
              SectionLabel(e.kind == 'car' ? 'รถเก๋ง / อเนกประสงค์ (ข้อมูลส่วนใหญ่จากรถต่างประเทศ)' : 'กระบะ / PPV / รถตู้'),
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _EntryCard(
                entry: e,
                suggested: score(e) >= 4,
                inMine: ref.watch(extPacksProvider).any((p) => p.lib == e.lib),
                onOpen: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => ExtLibraryPackScreen(entry: e, onUse: (p) {
                    Navigator.of(context).pop();
                    widget.onUse(p);
                  }),
                )),
                onUse: () => _use(e),
              ),
            ),
          ],
        ]);
      },
    );
  }
}

class _EntryCard extends StatelessWidget {
  const _EntryCard({required this.entry, required this.suggested, required this.inMine, required this.onOpen, required this.onUse});

  final ExtLibraryEntry entry;
  final bool suggested;
  final bool inMine;
  final VoidCallback onOpen;
  final VoidCallback onUse;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final e = entry;
    final ev = e.evidenceYears;
    return PremiumCard(
      glow: suggested ? StatusColors.good : null,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      radius: 18,
      onTap: onOpen,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(e.name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5))),
          if (suggested) const Pill(text: 'แนะนำสำหรับรถคันนี้', color: StatusColors.good, icon: Icons.thumb_up_alt_rounded),
        ]),
        const SizedBox(height: 4),
        Text('${e.brand} · ${e.models.join(', ')}${e.yearsText.isEmpty ? '' : ' · ${e.yearsText}'}',
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 6, children: [
          Pill(text: '${e.count} ค่า · ${e.commands} คำสั่ง', color: cs.primary),
          if (e.evidenceCount > 0)
            Pill(
              text: 'พบในรถจริง ${e.evidenceCount} ค่า (ปี ${ev.length == 1 ? ev.first : '${ev.first}–${ev.last}'})',
              color: StatusColors.info,
              icon: Icons.fact_check_rounded,
            )
          else
            const Pill(text: 'ทุกค่ารอยืนยัน', color: StatusColors.warn, icon: Icons.help_outline_rounded),
        ]),
        const SizedBox(height: 6),
        Text('ที่มา: ${e.sources.join(' · ')}', style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant)),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerRight,
          child: inMine
              ? TextButton.icon(onPressed: onUse, icon: const Icon(Icons.folder_open_rounded), label: const Text('เปิดชุดนี้'))
              : FilledButton.tonalIcon(onPressed: onUse, icon: const Icon(Icons.download_done_rounded), label: const Text('ใช้ชุดนี้')),
        ),
      ]),
    );
  }
}

/// รายละเอียดชุดในคลัง
class ExtLibraryPackScreen extends ConsumerStatefulWidget {
  const ExtLibraryPackScreen({super.key, required this.entry, required this.onUse});

  final ExtLibraryEntry entry;
  final void Function(ExtPidPack pack) onUse;

  @override
  ConsumerState<ExtLibraryPackScreen> createState() => _ExtLibraryPackScreenState();
}

class _ExtLibraryPackScreenState extends ConsumerState<ExtLibraryPackScreen> {
  /// เก็บไว้ตั้งแต่ initState (ห้ามใช้ ref ใน dispose)
  late final LivePoller _poller;
  ExtPidPack? _pack;
  ExtProbeResult? _probe;
  bool _testing = false;
  double _progress = 0;
  static const _pollKey = 'ext_lib_probe';

  @override
  void initState() {
    super.initState();
    _poller = ref.read(livePollerProvider);
    ref.read(extLibraryProvider).pack(widget.entry).then((p) {
      if (mounted) setState(() => _pack = p);
    });
  }

  @override
  void dispose() {
    resumePoller(_poller, _pollKey);
    super.dispose();
  }

  Future<void> _test() async {
    final service = ref.read(sessionProvider).service;
    final pack = _pack;
    if (service == null || pack == null) return;
    setState(() {
      _testing = true;
      _probe = null;
    });
    // ชุดของรถคนละรุ่น: ถามเฉพาะกล่องเลขมาตรฐาน (เลขเฉพาะยี่ห้ออาจชนกับข้อความปกติของรถคันนี้)
    final e = widget.entry;
    final fit = fitsCurrentVehicle(ref, brand: e.brand, models: e.models, years: e.years);
    pausePoller(_poller, _pollKey);
    try {
      final r = await ExtPidReader(service.elm).probe(pack.pids, maxCommands: 20, standardOnly: !fit,
          onProgress: (p, _) {
        if (mounted) setState(() => _progress = p);
      });
      if (mounted) setState(() => _probe = r);
    } finally {
      resumePoller(_poller, _pollKey);
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final pack = _pack;
    final connected = ref.watch(sessionProvider.select((s) => s.isConnected));
    final e = widget.entry;
    return Scaffold(
      appBar: AppBar(title: FitText(e.name)),
      body: pack == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 40), children: [
              PremiumCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(e.name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
                  const SizedBox(height: 4),
                  Text('${e.brand} · ${e.models.join(', ')}${e.yearsText.isEmpty ? '' : ' · ${e.yearsText}'}',
                      style: TextStyle(color: cs.onSurfaceVariant)),
                  const SizedBox(height: 10),
                  Text(pack.note, style: const TextStyle(height: 1.5, fontSize: 13)),
                  const SizedBox(height: 14),
                  Row(children: [
                    Expanded(
                      child: FilledButton.icon(
                        icon: const Icon(Icons.download_done_rounded),
                        label: const Text('ใช้ชุดนี้'),
                        onPressed: () {
                          final adopted = ref.read(extPacksProvider.notifier).adopt(pack.copyWithId(pack.id));
                          widget.onUse(adopted);
                        },
                      ),
                    ),
                    if (connected) ...[
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.rule_rounded),
                          label: const Text('ทดสอบกับรถคันนี้'),
                          onPressed: _testing ? null : _test,
                        ),
                      ),
                    ],
                  ]),
                  if (_testing) ...[const SizedBox(height: 10), LinearProgressIndicator(value: _progress)],
                ]),
              ),
              if (_probe != null) ...[const SizedBox(height: 12), ProbeResultCard(result: _probe!)],
              const SectionLabel('มีค่าอะไรบ้าง'),
              PremiumCard(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                child: Column(children: [
                  for (final g in pack.groups)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Row(children: [
                        Expanded(child: Text(g, style: const TextStyle(fontWeight: FontWeight.w600))),
                        Text(
                          '${pack.pids.where((p) => p.group == g).length} ค่า'
                          ' · พบในรถจริง ${pack.pids.where((p) => p.group == g && p.hasEvidence).length}',
                          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5),
                        ),
                      ]),
                    ),
                ]),
              ),
              const SectionLabel('แหล่งที่มาและสัญญาอนุญาต'),
              SourcesCard(sources: pack.sources),
            ]),
    );
  }
}

/// แสดงแหล่งที่มา (ต้องแสดงตามสัญญาอนุญาต CC BY-SA)
class SourcesCard extends StatelessWidget {
  const SourcesCard({super.key, required this.sources});

  final List<ExtSource> sources;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return PremiumCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (sources.isEmpty) Text('ชุดนี้สร้างเองในเครื่อง', style: TextStyle(color: cs.onSurfaceVariant)),
        for (final s in sources)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s.name, style: const TextStyle(fontWeight: FontWeight.w700)),
              if (s.url.isNotEmpty) SelectableText(s.url, style: TextStyle(fontSize: 12, color: cs.primary)),
              if (s.by.isNotEmpty) Text('โดย ${s.by}', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              if (s.license.isNotEmpty)
                Text('สัญญาอนุญาต ${s.license}${s.license.startsWith('CC BY-SA') ? ' (https://creativecommons.org/licenses/by-sa/4.0/)' : ''}',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              if (s.changes.isNotEmpty) Text('สิ่งที่ปรับ: ${s.changes}', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            ]),
          ),
      ]),
    );
  }
}

/// ผลทดสอบชุดกับรถ
class ProbeResultCard extends StatelessWidget {
  const ProbeResultCard({super.key, required this.result});

  final ExtProbeResult result;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final r = result;
    if (r.carSilent) {
      // รถไม่ตอบอะไรเลย: บอกไม่ได้ว่าชุดตรงรุ่นหรือไม่ (ห้ามสรุปว่าไม่ตรง)
      return PremiumCard(
        glow: StatusColors.warn,
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.power_settings_new_rounded, color: StatusColors.warn, size: 30),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(r.verdict, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
              const SizedBox(height: 4),
              Text(carSilentText, style: TextStyle(color: cs.onSurfaceVariant, height: 1.5, fontSize: 13)),
            ]),
          ),
        ]),
      );
    }
    final color = switch (r.level) { 2 => StatusColors.good, 1 => StatusColors.warn, _ => StatusColors.bad };
    return PremiumCard(
      glow: color,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(r.level == 2 ? Icons.check_circle_rounded : (r.level == 1 ? Icons.error_rounded : Icons.cancel_rounded), color: color, size: 30),
          const SizedBox(width: 10),
          Expanded(child: Text(r.verdict, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17))),
          Text('${(r.score * 100).round()}%', style: TextStyle(fontWeight: FontWeight.w800, color: color, fontSize: 18)),
        ]),
        const SizedBox(height: 8),
        Text(
          'ทดสอบ ${r.commands} คำสั่ง: ตอบ ${r.responded} · ปฏิเสธ ${r.negative} · เงียบ ${r.silent}'
          '${r.pidsTested > 0 ? '\nถอดค่าได้ ${r.pidsTested} ค่า อยู่ในช่วงที่เป็นไปได้ ${r.pidsOk} ค่า' : ''}'
          '${r.incompatible > 0 ? '\nข้าม ${r.incompatible} ค่าที่เป็นของรถ CAN คนละแบบ' : ''}'
          '${r.notForThisCar > 0 ? '\nไม่ถาม ${r.notForThisCar} ค่าที่ส่งไปกล่องเลขเฉพาะยี่ห้อ (ชุดนี้ไม่ใช่ของรถคันนี้)' : ''}',
          style: TextStyle(color: cs.onSurfaceVariant, height: 1.5, fontSize: 13),
        ),
      ]),
    );
  }
}

/// หาชุดในคลังที่ตรงกับรถคันที่ต่ออยู่
class ExtMatchScreen extends ConsumerStatefulWidget {
  const ExtMatchScreen({super.key, required this.onUse});

  final void Function(ExtPidPack pack) onUse;

  @override
  ConsumerState<ExtMatchScreen> createState() => _ExtMatchScreenState();
}

class _ExtMatchScreenState extends ConsumerState<ExtMatchScreen> {
  /// เก็บไว้ตั้งแต่ initState (ห้ามใช้ ref ใน dispose)
  late final LivePoller _poller;

  @override
  void initState() {
    super.initState();
    _poller = ref.read(livePollerProvider);
  }

  final _results = <(ExtLibraryEntry, ExtProbeResult)>[];
  bool _running = false;
  bool _cancel = false;
  bool _all = false;
  bool _carSilent = false;
  String _step = '';
  double _progress = 0;
  static const _pollKey = 'ext_match';

  @override
  void dispose() {
    _cancel = true;
    resumePoller(_poller, _pollKey);
    super.dispose();
  }

  Future<void> _run(List<ExtLibraryEntry> entries) async {
    final service = ref.read(sessionProvider).service;
    if (service == null) return;
    final lib = ref.read(extLibraryProvider);
    setState(() {
      _running = true;
      _cancel = false;
      _carSilent = false;
      _results.clear();
    });
    pausePoller(_poller, _pollKey);
    try {
      for (var i = 0; i < entries.length; i++) {
        if (_cancel || !mounted) break;
        final e = entries[i];
        setState(() {
          _step = e.name;
          _progress = i / entries.length;
        });
        final pack = await lib.pack(e);
        if (_cancel || !mounted) break;
        // ชุดของรถคนละรุ่น: ถามเฉพาะกล่องเลขมาตรฐาน (เลขเฉพาะยี่ห้ออาจชนกับข้อความปกติของรถคันนี้)
        final fit = fitsCurrentVehicle(ref, brand: e.brand, models: e.models, years: e.years);
        final r = await ExtPidReader(service.elm)
            .probe(pack.pids, maxCommands: 10, cancelled: () => _cancel, standardOnly: !fit);
        if (!mounted) return;
        if (r.carSilent) {
          // รถไม่ตอบอะไรเลย ทดสอบชุดอื่นต่อก็ได้ผล "ไม่ตรง" ผิดๆ ทุกชุด หยุดแล้วบอกให้เปิดสวิตช์กุญแจ
          setState(() {
            _carSilent = true;
            _results.clear();
          });
          break;
        }
        setState(() {
          _results.add((e, r));
          _results.sort((a, b) => b.$2.score.compareTo(a.$2.score));
        });
      }
    } finally {
      resumePoller(_poller, _pollKey);
      if (mounted) {
        setState(() {
          _running = false;
          _progress = 1;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final entries = ref.watch(extLibraryIndexProvider).valueOrNull ?? const <ExtLibraryEntry>[];
    final veh = currentVehicle(ref);
    final brand = veh?.make;
    final candidates = _all || brand == null ? entries : entries.where((e) => e.brand.toLowerCase() == brand.toLowerCase()).toList();
    return Scaffold(
      appBar: AppBar(title: const FitText('หาชุดที่ตรงกับรถคันนี้')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 40), children: [
        PremiumCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              'แอปจะลองถามคำสั่งตัวอย่างของแต่ละชุด แล้วดูว่ารถตอบกี่คำสั่ง และค่าที่ได้อยู่ในช่วงที่เป็นไปได้หรือไม่ '
              'ใช้เวลาชุดละไม่กี่วินาที ควรทำตอนบิดกุญแจ ON หรือเครื่องเดินเบา '
              'ชุดที่ยี่ห้อ/รุ่น/ปีไม่ตรงกับรถคันนี้ จะถามเฉพาะกล่องเลขมาตรฐาน (7DF, 7E0–7E7) เพื่อไม่ให้คำสั่งไปชนกับข้อความปกติของรถ',
              style: TextStyle(color: cs.onSurfaceVariant, height: 1.5, fontSize: 13),
            ),
            if (brand == null) ...[
              const SizedBox(height: 8),
              const Text(
                'ยังไม่รู้ยี่ห้อของรถคันนี้: ทุกชุดจะถามเฉพาะกล่องเลขมาตรฐาน ชุดที่ใช้กล่องเลขเฉพาะยี่ห้อจะออกมาว่าไม่ตรง '
                'ระบุรถก่อน (แตะ "เลือกรถ" ที่หน้าหลัก) จะทดสอบได้ครบกว่า',
                style: TextStyle(color: StatusColors.warn, height: 1.5, fontSize: 12.5),
              ),
            ],
            if (brand != null) ...[
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(_all ? 'ทดสอบทุกยี่ห้อ (${entries.length} ชุด)' : 'เฉพาะ $brand (${candidates.length} ชุด)'),
                subtitle: const Text('ปิดเพื่อทดสอบเฉพาะยี่ห้อของรถคันนี้'),
                value: _all,
                onChanged: _running ? null : (v) => setState(() => _all = v),
              ),
            ],
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: Icon(_running ? Icons.stop_rounded : Icons.play_arrow_rounded),
                label: Text(_running ? 'หยุด ($_step)' : 'เริ่มทดสอบ ${candidates.length} ชุด'),
                onPressed: _running ? () => setState(() => _cancel = true) : () => _run(candidates),
              ),
            ),
            if (_running) ...[const SizedBox(height: 10), LinearProgressIndicator(value: _progress)],
          ]),
        ),
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
        if (_results.isNotEmpty) const SectionLabel('ผลการทดสอบ'),
        for (final (e, r) in _results)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
                child: Text(e.name, style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
              ProbeResultCard(result: r),
              if (r.level > 0)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    icon: const Icon(Icons.download_done_rounded),
                    label: const Text('ใช้ชุดนี้'),
                    onPressed: () async {
                      final pack = await ref.read(extLibraryProvider).pack(e);
                      final adopted = ref.read(extPacksProvider.notifier).adopt(pack);
                      widget.onUse(adopted);
                    },
                  ),
                ),
            ]),
          ),
      ]),
    );
  }
}
