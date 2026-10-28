import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/obd/ext_known.dart';
import '../../core/obd/ext_pid.dart';
import '../../core/obd/formula.dart';
import '../../core/obd/formula_fit.dart';
import '../../state/ext_packs.dart';
import '../../state/live_poller.dart';
import '../../state/providers.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'ext_common.dart';
import 'ext_pid_edit_screen.dart';

/// รายละเอียดค่าหนึ่ง: ดูไบต์สด เทียบกับเครื่องมือศูนย์ หาสูตรอัตโนมัติ และยืนยันผล
class ExtPidDetailScreen extends ConsumerStatefulWidget {
  const ExtPidDetailScreen({super.key, required this.pid, this.packId, this.onSave, this.startWatching = false});

  final ExtPid pid;

  /// ชุดที่ค่านี้อยู่ (บันทึกการแก้ไขกลับเข้าชุดอัตโนมัติ)
  final String? packId;

  /// ใช้กับค่าชั่วคราว (เช่นจากหน้าค้นหา) ให้ผู้เรียกบันทึกเอง
  final void Function(ExtPid pid)? onSave;
  final bool startWatching;

  @override
  ConsumerState<ExtPidDetailScreen> createState() => _ExtPidDetailScreenState();
}

class _ExtPidDetailScreenState extends ConsumerState<ExtPidDetailScreen> {
  /// เก็บไว้ตั้งแต่ initState (ห้ามใช้ ref ใน dispose)
  late final LivePoller _poller;
  late ExtPid _p = widget.pid.copy();
  /// วัตถุที่อยู่ในชุดตอนนี้ (ใช้หาตำแหน่งเพื่อแทนที่)
  late ExtPid _inPack = widget.pid;
  List<int>? _raw;

  /// เวลาที่อ่านไบต์ล่าสุดได้สำเร็จ (จุดเทียบต้องจับคู่กับค่าที่อ่าน "ตอนนี้" เท่านั้น)
  DateTime? _rawAt;
  final _changes = <int, int>{};
  final _selected = <int>{};
  bool _watch = false;
  bool _busy = false;
  String? _error;
  final _ref = TextEditingController();
  static const _pollKey = 'ext_detail';

  @override
  void initState() {
    super.initState();
    _poller = ref.read(livePollerProvider);
    if (widget.startWatching) WidgetsBinding.instance.addPostFrameCallback((_) => _toggleWatch());
  }

  @override
  void dispose() {
    _watch = false;
    resumePoller(_poller, _pollKey);
    _ref.dispose();
    super.dispose();
  }

  // ---------------- บันทึก ----------------

  void _persist() {
    final packId = widget.packId;
    if (packId == null) return;
    final packs = ref.read(extPacksProvider);
    final pack = packs.where((p) => p.id == packId).firstOrNull;
    if (pack == null) return;
    var i = pack.pids.indexWhere((x) => identical(x, _inPack));
    if (i < 0) i = pack.pids.indexWhere((x) => x.key == _inPack.key);
    if (i < 0) return;
    pack.pids[i] = _p;
    _inPack = _p;
    ref.read(extPacksProvider.notifier).put(pack);
  }

  void _update(void Function(ExtPid p) f) {
    setState(() => f(_p));
    _persist();
  }

  // ---------------- อ่านค่า ----------------

  /// ช่างยืนยันแล้วว่าให้ส่งคำสั่งไปกล่องเลขเฉพาะยี่ห้อได้ (ถามครั้งเดียวต่อการเปิดหน้านี้)
  bool _okNonStandard = false;

  /// ค่าที่ส่งไปกล่องเลขเฉพาะยี่ห้อ (ไม่ใช่ 7DF/7E0–7E7) ในชุดที่ไม่ใช่ของรถคันนี้: ถามช่างก่อนอ่านครั้งแรก
  /// เพราะรถคนละรุ่นอาจใช้เลขนั้นเป็นข้อความปกติ (ค่าจากหน้าค้นหาไม่ต้องถาม เลขนั้นเพิ่งตอบกลับมาจากรถคันนี้เอง)
  Future<bool> _allowRead() async {
    if (_okNonStandard || _p.standardHeader) return true;
    final packId = widget.packId;
    if (packId == null) return true;
    final pack = ref.read(extPacksProvider).where((p) => p.id == packId).firstOrNull;
    if (pack == null || fitsCurrentVehicle(ref, brand: pack.brand, models: pack.models, years: pack.years)) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('ส่งคำสั่งไปกล่องเลขเฉพาะยี่ห้อ?'),
        content: Text(
          'ค่านี้ส่งคำสั่งไปที่เลข ${_p.header.toUpperCase()} ซึ่งไม่ใช่เลขมาตรฐานของ OBD (7DF, 7E0–7E7) '
          'และชุด "${pack.name}" ไม่ใช่ของรถคันที่ต่ออยู่ ถ้ารถคันนี้ใช้เลขนั้นเป็นข้อความปกติ (เช่น ข้อมูลหน้าปัด) '
          'คำสั่งอาจไปชนกัน ทำให้หน้าปัดรวนหรือไฟเตือนติดชั่วคราวได้\n\nอ่านต่อเฉพาะเมื่อแน่ใจว่ารถคันนี้มีกล่องที่เลขนี้',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('ยกเลิก')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('อ่านต่อ')),
        ],
      ),
    );
    if (ok ?? false) _okNonStandard = true;
    return ok ?? false;
  }

  Future<void> _readOnce() async {
    if (!await _allowRead() || !mounted) return;
    final service = ref.read(sessionProvider).service;
    if (service == null) return;
    setState(() => _busy = true);
    pausePoller(_poller, _pollKey);
    try {
      final r = await ExtPidReader(service.elm).readRaw(_p);
      if (!mounted) return;
      setState(() {
        if (r.status == ExtCmdStatus.ok) {
          final prev = _raw;
          final now = r.payload!;
          if (prev != null) {
            for (var i = 0; i < now.length; i++) {
              if (i >= prev.length || prev[i] != now[i]) _changes[i] = (_changes[i] ?? 0) + 1;
            }
          }
          _raw = now;
          _rawAt = DateTime.now();
          _error = null;
        } else {
          _error = r.error ?? 'ไม่มีคำตอบ';
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (!_watch) resumePoller(_poller, _pollKey);
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleWatch() async {
    if (_watch) {
      setState(() => _watch = false);
      return;
    }
    if (!await _allowRead() || !mounted) return;
    setState(() => _watch = true);
    while (_watch && mounted) {
      await _readOnce();
      if (!_watch || !mounted) break;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    resumePoller(_poller, _pollKey);
  }

  // ---------------- เทียบค่า ----------------

  double? _calc(List<int> raw) {
    try {
      return Formula(_p.formula).eval(raw);
    } catch (_) {
      return null;
    }
  }

  Future<void> _addPoint() async {
    final v = double.tryParse(_ref.text.trim().replaceAll(',', '.'));
    if (v == null) {
      _snack('ใส่ตัวเลขที่เครื่องมือศูนย์แสดง');
      return;
    }
    // จับคู่กับไบต์ที่อ่านเมื่อครู่เท่านั้น ค่าที่อ่านไว้นานแล้วอาจไม่ตรงกับตัวเลขที่เครื่องมือศูนย์แสดงตอนนี้
    bool fresh() => _rawAt != null && DateTime.now().difference(_rawAt!) < const Duration(seconds: 2);
    if (!fresh()) await _readOnce();
    final raw = _raw;
    if (raw == null || !fresh()) {
      _snack('อ่านค่าจากรถตอนนี้ไม่ได้ ตรวจการเชื่อมต่อก่อน');
      return;
    }
    _update((p) => p.points.add(CalPoint(raw: List.of(raw), ref: v)));
    _ref.clear();
    HapticFeedback.selectionClick();
  }

  void _snack(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  Future<void> _fit() async {
    final all = FormulaFit.fit(_p.points, limit: 12);
    final cands = _selected.isEmpty ? all : all.where((c) => c.bytesUsed.every(_selected.contains)).toList();
    if (!mounted) return;
    if (cands.isEmpty) {
      _snack(_p.points.length < 2 ? 'ต้องมีอย่างน้อย 2 จุดที่ค่าต่างกัน' : 'ยังหาสูตรที่ตรงไม่ได้ ลองเพิ่มจุดเทียบที่ค่าต่างกันมากขึ้น');
      return;
    }
    final chosen = await showModalBottomSheet<FitCandidate>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return SafeArea(
          child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [
            const Text('สูตรที่ตรงกับจุดเทียบ', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            const SizedBox(height: 4),
            Text(
              _p.points.length < 3
                  ? 'มีแค่ ${_p.points.length} จุด หลายสูตรจะตรงพอ ๆ กัน ควรเพิ่มจุดที่ค่าต่างกันชัดเจน (เช่น ตอนเครื่องเย็นและร้อน)'
                  : 'เรียงจากสูตรที่ตรงและเรียบง่ายที่สุด ยอมให้ต่างได้ไม่เกิน ${cands.first.tolerance.toStringAsFixed(2)}',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5, height: 1.4),
            ),
            const SizedBox(height: 10),
            for (final c in cands)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: Icon(c.fits ? Icons.check_circle_rounded : Icons.error_outline_rounded,
                      color: c.fits ? StatusColors.good : StatusColors.warn),
                  title: Text(c.formula, style: const TextStyle(fontFamily: kMono, fontWeight: FontWeight.w700)),
                  subtitle: Text('ต่างมากสุด ${c.maxError.toStringAsFixed(3)} · ใช้ไบต์ ${c.bytesUsed.map(ByteGrid.letter).join(', ')}'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.pop(ctx, c),
                ),
              ),
          ]),
        );
      },
    );
    if (chosen == null) return;
    _update((p) {
      p.formula = chosen.formula;
      p.verified = false;
      p.verifiedBy = null;
      p.verifiedAt = null;
    });
    _snack('ใช้สูตร ${chosen.formula} แล้ว กดยืนยันเมื่อมั่นใจ');
  }

  Future<void> _verify() async {
    final check = FormulaFit.check(_p.formula, _p.points);
    final good = check != null && _p.points.length >= 2 && check.$1 <= check.$2;
    if (!good) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('ยังเทียบค่าไม่ครบ'),
          content: Text(_p.points.length < 2
              ? 'ควรบันทึกจุดเทียบกับเครื่องมือศูนย์อย่างน้อย 2 จุดที่ค่าต่างกัน ก่อนยืนยัน\n\nยืนยันเลยไหม?'
              : 'ค่าที่แอปคำนวณยังต่างจากเครื่องมือศูนย์ (ต่างสูงสุด ${check?.$1.toStringAsFixed(2) ?? '-'})\n\nยืนยันเลยไหม?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('ยกเลิก')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('ยืนยัน')),
          ],
        ),
      );
      if (ok != true) return;
    }
    final shop = ref.read(settingsProvider).shop.name;
    final veh = vehicleLabel(currentVehicle(ref, watch: false), vin: ref.read(sessionProvider).vin);
    _update((p) {
      p.verified = true;
      p.verifiedBy = shop.isEmpty ? 'ร้านนี้' : shop;
      p.verifiedAt = DateTime.now();
      p.verifiedOn = ref.read(sessionProvider).isConnected ? veh : p.verifiedOn;
    });
    _snack('บันทึกผลยืนยันแล้ว');
  }

  void _unverify() => _update((p) {
        p.verified = false;
        p.verifiedBy = null;
        p.verifiedAt = null;
        p.verifiedOn = null;
      });

  Future<void> _edit() async {
    final edited = await Navigator.of(context).push<ExtPid?>(
      MaterialPageRoute(builder: (_) => ExtPidEditScreen(pid: _p, sampleRaw: _raw)),
    );
    if (edited == null) return;
    setState(() => _p = edited);
    _persist();
  }

  Future<void> _sharePoints() async {
    final b = StringBuffer()
      ..writeln('ProScaner: จุดเทียบค่า')
      ..writeln('ค่า: ${_p.name}${_p.en != null ? ' (${_p.en})' : ''}')
      ..writeln('กล่อง: ${_p.header.isEmpty ? '7DF' : _p.header}  คำสั่ง: ${_p.request}  สูตร: ${_p.formula}')
      ..writeln('ข้อมูลดิบ (hex),ค่าจากเครื่องมือศูนย์,ค่าจากสูตร,เวลา');
    for (final pt in _p.points) {
      b.writeln('${bytesToHex(pt.raw, sep: ' ')},${pt.ref},${_calc(pt.raw)?.toStringAsFixed(3) ?? '-'},${pt.at.toIso8601String()}');
    }
    await SharePlus.instance.share(ShareParams(text: b.toString(), subject: 'จุดเทียบค่า ${_p.name}'));
  }

  // ---------------- หน้าจอ ----------------

  /// ค่าที่ค้นพบเองที่ยังไม่รู้ชื่อ: บอกชื่อจากคลัง (ถ้ารู้แล้ว) หรือบอกวิธีหาว่าเป็นค่าอะไร
  List<Widget> _unnamedHint(ColorScheme cs) {
    final packId = widget.packId;
    final matches = packId == null ? const <KnownMatch>[] : ref.watch(knownNamesProvider(packId)).valueOrNull ?? const [];
    final known = matches.where((m) => m.discovered.cmdKey == _p.cmdKey).firstOrNull;
    return [
      const SizedBox(height: 10),
      PremiumCard(
        glow: known != null ? StatusColors.info : null,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        radius: 16,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            known != null ? 'ในคลังเรียกค่านี้ว่า: ${known.names}' : 'ยังไม่รู้ว่าเป็นค่าอะไร',
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text(
            known != null
                ? 'จากชุด "${known.source}" ของรถรุ่นเดียวกัน (กล่องและคำสั่งเดียวกัน)'
                : 'เลขนี้ได้มาตอนค้นหาค่าที่กล่องตอบ กล่องส่งมาแค่ตัวเลข ไม่ได้บอกชื่อ วิธีหา: '
                    'ติดเครื่องแล้วใช้ "จับคู่กับค่า OBD มาตรฐาน" ในหน้าชุด หรือใส่ค่าที่เครื่องมือศูนย์ (เช่น Tech2) '
                    'อ่านได้ในช่องด้านล่าง กด "บันทึกจุด" 2–3 ระดับรอบ แล้ว "หาสูตรจากจุดเทียบ" และตั้งชื่อด้วยปุ่มแก้ไข',
            style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant, height: 1.45),
          ),
          if (known != null) ...[
            const SizedBox(height: 10),
            FilledButton.icon(
              icon: const Icon(Icons.drive_file_rename_outline_rounded),
              label: const Text('ใช้ชื่อและสูตรนี้'),
              onPressed: () => _useKnown(known),
            ),
          ],
        ]),
      ),
    ];
  }

  void _useKnown(KnownMatch m) {
    final packId = widget.packId;
    final pack = packId == null ? null : ref.read(extPacksProvider).where((p) => p.id == packId).firstOrNull;
    if (pack == null) return;
    ref.read(extPacksProvider.notifier).put(applyKnown(pack, [m]));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('ตั้งชื่อเป็น "${m.names}" แล้ว')));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final connected = ref.watch(sessionProvider.select((s) => s.isConnected));
    final raw = _raw;
    final value = raw == null ? null : ExtPidReader.evaluate(_p, raw);
    final check = FormulaFit.check(_p.formula, _p.points);
    final used = formulaBytes(_p.formula);
    return Scaffold(
        appBar: AppBar(
          title: Text(_p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(tooltip: 'แก้ไข', icon: const Icon(Icons.edit_rounded), onPressed: _edit),
            if (widget.onSave != null)
              TextButton(
                onPressed: () {
                  widget.onSave!(_p);
                  Navigator.of(context).pop();
                },
                child: const Text('บันทึกเข้าชุด'),
              ),
          ],
        ),
        body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 40), children: [
          PremiumCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(_p.name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
                TrustPill(pid: _p),
              ]),
              if (_p.en != null) ...[
                const SizedBox(height: 2),
                Text(_p.en!, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5)),
              ],
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, children: [
                Pill(text: 'กล่อง ${_p.header.isEmpty ? '7DF (ทุกกล่อง)' : _p.header}', color: cs.primary),
                if (_p.rx != null) Pill(text: 'ตอบจาก ${_p.rx}', color: cs.primary),
                Pill(text: 'คำสั่ง ${_p.request}', color: cs.primary),
                Pill(text: _p.formula, color: cs.secondary, mono: true),
                if (_p.years != null) Pill(text: 'ปี ${_p.years}', color: StatusColors.info),
              ]),
              if (_p.verified) ...[
                const SizedBox(height: 10),
                Text(
                  'ยืนยันโดย ${_p.verifiedBy ?? '-'}'
                  '${_p.verifiedAt != null ? ' เมื่อ ${_p.verifiedAt!.day}/${_p.verifiedAt!.month}/${_p.verifiedAt!.year + 543}' : ''}'
                  '${_p.verifiedOn != null ? '\nกับรถ ${_p.verifiedOn}' : ''}',
                  style: const TextStyle(fontSize: 12.5, height: 1.45, color: StatusColors.good),
                ),
              ],
              if (_p.source != null || _p.desc != null) ...[
                const SizedBox(height: 8),
                if (_p.source != null)
                  Text('ที่มา: ${_p.source}', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                if (_p.desc != null)
                  Text(_p.desc!, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant, height: 1.4)),
              ],
            ]),
          ),
          if (isUnnamedDiscovered(_p)) ..._unnamedHint(cs),
          const SectionLabel('ค่าจากรถ'),
          PremiumCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (!connected)
                Text('เชื่อมต่อรถเพื่ออ่านค่า', style: TextStyle(color: cs.onSurfaceVariant))
              else ...[
                Row(children: [
                  Expanded(
                    child: value == null
                        ? Text(_error ?? (_busy ? 'กำลังอ่าน…' : 'ยังไม่ได้อ่าน'),
                            style: TextStyle(color: _error != null ? StatusColors.warn : cs.onSurfaceVariant))
                        : Text.rich(TextSpan(children: [
                            TextSpan(
                              text: value.value == null ? (value.error ?? '—') : _p.format(value.value!),
                              style: TextStyle(
                                fontSize: value.value == null ? 15 : 30,
                                fontWeight: FontWeight.w800,
                                color: value.outOfRange ? StatusColors.bad : cs.onSurface,
                                fontFeatures: const [FontFeature.tabularFigures()],
                              ),
                            ),
                            if (value.value != null && _p.unit.isNotEmpty)
                              TextSpan(text: ' ${_p.unit}', style: TextStyle(color: cs.onSurfaceVariant)),
                          ])),
                  ),
                  if (_busy && !_watch) const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4)),
                ]),
                if (value?.outOfRange ?? false)
                  const Text('ค่าออกนอกช่วงที่เป็นไปได้ อาจเป็นเลขคำสั่งหรือสูตรของรุ่นอื่น',
                      style: TextStyle(fontSize: 12, color: StatusColors.bad)),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: FilledButton.icon(
                      icon: Icon(_watch ? Icons.stop_rounded : Icons.visibility_rounded),
                      label: Text(_watch ? 'หยุดดูไบต์สด' : 'ดูไบต์สด'),
                      onPressed: _toggleWatch,
                    ),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton(onPressed: _busy || _watch ? null : _readOnce, child: const Text('อ่านครั้งเดียว')),
                ]),
                if (raw != null) ...[
                  const SizedBox(height: 14),
                  Text('ไบต์ข้อมูล (กรอบสี = สูตรใช้อยู่, สีส้ม = ไบต์ที่เปลี่ยนค่า, แตะเพื่อเลือกไบต์ให้หาสูตร)',
                      style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant)),
                  const SizedBox(height: 8),
                  ByteGrid(
                    bytes: raw,
                    used: used,
                    changed: _changes,
                    selected: _selected,
                    onTap: (i) => setState(() => _selected.contains(i) ? _selected.remove(i) : _selected.add(i)),
                  ),
                ],
              ],
            ]),
          ),
          if (!_p.isState) ...[
            const SectionLabel('เทียบกับเครื่องมือศูนย์'),
            PremiumCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  'เปิดค่าเดียวกันใน Techstream / G-IDSS / MUT-III แล้วพิมพ์ตัวเลขที่เห็นในเวลาเดียวกัน '
                  'บันทึกหลายจุดที่ค่าต่างกัน (เช่น เครื่องเย็น-ร้อน เดินเบา-เร่ง) แอปจะบอกว่าสูตรตรงหรือไม่ และช่วยหาสูตรใหม่ได้',
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5, height: 1.45),
                ),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _ref,
                      keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
                      decoration: InputDecoration(
                        labelText: 'ค่าจากเครื่องมือศูนย์${_p.unit.isEmpty ? '' : ' (${_p.unit})'}',
                        isDense: true,
                      ),
                      onSubmitted: (_) => _addPoint(),
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(onPressed: connected ? _addPoint : null, child: const Text('บันทึกจุด')),
                ]),
                if (_p.points.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  for (var i = 0; i < _p.points.length; i++) _pointRow(i),
                  const SizedBox(height: 8),
                  if (check != null)
                    Row(children: [
                      Icon(check.$1 <= check.$2 ? Icons.check_circle_rounded : Icons.error_rounded,
                          color: check.$1 <= check.$2 ? StatusColors.good : StatusColors.bad, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          check.$1 <= check.$2
                              ? 'สูตรตรงกับเครื่องมือศูนย์ทุกจุด (ต่างไม่เกิน ${check.$1.toStringAsFixed(2)})'
                              : 'สูตรยังไม่ตรง ต่างสูงสุด ${check.$1.toStringAsFixed(2)}',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ]),
                ],
                const SizedBox(height: 12),
                Wrap(spacing: 10, runSpacing: 8, children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.auto_fix_high_rounded),
                    label: Text(_selected.isEmpty ? 'หาสูตรจากจุดเทียบ' : 'หาสูตรจากไบต์ที่เลือก'),
                    onPressed: _p.points.length >= 2 ? _fit : null,
                  ),
                  if (_p.points.isNotEmpty)
                    TextButton.icon(
                      icon: const Icon(Icons.ios_share_rounded),
                      label: const Text('ส่งผลเทียบ'),
                      onPressed: _sharePoints,
                    ),
                ]),
              ]),
            ),
          ],
          const SectionLabel('ยืนยันผล'),
          PremiumCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                _p.verified
                    ? 'ค่านี้ร้านยืนยันแล้ว จะแสดงเครื่องหมายสีเขียว และติดไปกับชุดเมื่อส่งต่อให้ช่างคนอื่น'
                    : 'เมื่อเทียบแล้วตรง กดยืนยัน แอปจะบันทึกชื่อร้าน วันที่ และรถที่ใช้เทียบไว้กับค่านี้',
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5, height: 1.45),
              ),
              const SizedBox(height: 10),
              if (_p.verified)
                OutlinedButton.icon(icon: const Icon(Icons.undo_rounded), label: const Text('ยกเลิกการยืนยัน'), onPressed: _unverify)
              else
                FilledButton.icon(icon: const Icon(Icons.verified_rounded), label: const Text('ยืนยันว่าค่านี้ถูกต้อง'), onPressed: _verify),
            ]),
          ),
          if (_p.evidence.isNotEmpty) ...[
            const SectionLabel('ตัวอย่างคำตอบจริงจากแหล่งข้อมูล'),
            PremiumCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (final e in _p.evidence) _evidenceRow(e),
                const SizedBox(height: 6),
                Text('ใช้ยืนยันว่าแอปถอดค่าได้เหมือนแหล่งข้อมูล แต่ยังไม่ได้แปลว่ารถทุกคันใช้คำสั่งนี้',
                    style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant)),
              ]),
            ),
          ],
        ]),
    );
  }

  Widget _pointRow(int i) {
    final cs = Theme.of(context).colorScheme;
    final pt = _p.points[i];
    final ours = _calc(pt.raw);
    final diff = ours == null ? null : ours - pt.ref;
    final check = FormulaFit.check(_p.formula, _p.points);
    final tol = check?.$2 ?? 0.5;
    final good = diff != null && diff.abs() <= tol;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        SizedBox(width: 26, child: Text('${i + 1}', style: TextStyle(color: cs.onSurfaceVariant))),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('ศูนย์ ${pt.ref}  ·  แอป ${ours == null ? '-' : _p.format(ours)}',
                style: const TextStyle(fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()])),
            Text(bytesToHex(pt.raw.take(12).toList()) + (pt.raw.length > 12 ? ' …' : ''),
                style: TextStyle(fontSize: 11, fontFamily: kMono, color: cs.onSurfaceVariant)),
          ]),
        ),
        if (diff != null)
          Text('${diff >= 0 ? '+' : ''}${diff.toStringAsFixed(2)}',
              style: TextStyle(fontWeight: FontWeight.w700, color: good ? StatusColors.good : StatusColors.bad)),
        IconButton(
          tooltip: 'ลบจุดนี้',
          icon: const Icon(Icons.close_rounded, size: 18),
          onPressed: () => _update((p) => p.points.removeAt(i)),
        ),
      ]),
    );
  }

  Widget _evidenceRow(ExtEvidence e) {
    final cs = Theme.of(context).colorScheme;
    final r = ExtPidReader.evaluate(_p, e.raw);
    String shown;
    var match = false;
    if (r.value == null) {
      shown = r.error ?? '-';
      match = e.value == null;
    } else {
      shown = _p.format(r.value!);
      final ev = e.value;
      if (ev is num) {
        match = (r.value! - ev.toDouble()).abs() <= 1e-3 * (ev.abs() > 1 ? ev.abs() : 1) + 1e-6 ||
            (r.outOfRange && _p.max != null && (ev.toDouble() - _p.max!).abs() < 1e-6) ||
            (r.outOfRange && _p.min != null && (ev.toDouble() - _p.min!).abs() < 1e-6);
      } else if (ev is String) {
        match = shown == ev || shown.split(' · ').first == ev;
      }
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Icon(match ? Icons.check_circle_rounded : Icons.error_rounded, size: 18, color: match ? StatusColors.good : StatusColors.warn),
        const SizedBox(width: 8),
        Expanded(
          child: Text('ปี ${e.year}: ${bytesToHex(e.raw)}',
              style: TextStyle(fontFamily: kMono, fontSize: 12, color: cs.onSurfaceVariant)),
        ),
        Text('$shown ${_p.isState ? '' : _p.unit}', style: const TextStyle(fontWeight: FontWeight.w700)),
      ]),
    );
  }
}
