import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/elm/elm327.dart';
import '../../core/uds/uds_client.dart';
import '../../state/live_poller.dart';
import '../../state/providers.dart';
import '../home_screen.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// กล่องที่ค้นพบในการเชื่อมต่อครั้งนี้ (ใช้ร่วมกันระหว่างหน้า)
class ModulesNotifier extends Notifier<List<EcuModule>> {
  @override
  List<EcuModule> build() {
    ref.watch(sessionProvider.select((s) => s.service));
    // สแกนทั้งคันครั้งใหม่ = ใช้รายการกล่องชุดใหม่
    ref.listen(scanProvider.select((s) => s.report), (_, r) {
      if (r != null && r.snapshot.modules.isNotEmpty) state = _copy(r.snapshot.modules);
    });
    final r = ref.read(scanProvider).report;
    return r == null ? const [] : _copy(r.snapshot.modules);
  }

  /// สำเนาแยกจากผลสแกน เพื่อไม่ให้การอ่าน/ลบในหน้านี้ไปแก้รายงานที่วิเคราะห์ไว้แล้ว
  static List<EcuModule> _copy(List<EcuModule> src) =>
      [for (final m in src) if (m.tx != '-') EcuModule.fromJson(m.toJson())];

  void set(List<EcuModule> list) => state = list;
  void touch() => state = List.of(state);
}

final modulesProvider = NotifierProvider<ModulesNotifier, List<EcuModule>>(ModulesNotifier.new);

/// หยุดตัวอ่านค่าสดระหว่างคุยกับกล่องอื่น (เพราะต้องเปลี่ยน header ของตัวสแกน)
Future<T> _quiet<T>(WidgetRef ref, Future<T> Function() body) async {
  final poller = ref.read(livePollerProvider);
  const key = 'uds';
  poller.subscribe(key, const <int>[], priority: true);
  try {
    return await body();
  } finally {
    poller.unsubscribe(key);
  }
}

String _err(Object e) => e is UdsNegative ? e.messageTh : (e is ElmException ? e.message : e.toString());

/// เครื่องมือช่าง: ค้นหาทุกกล่องในรถ อ่าน/ลบรหัส และอ่านข้อมูล DID
class ModulesScreen extends ConsumerStatefulWidget {
  const ModulesScreen({super.key});

  @override
  ConsumerState<ModulesScreen> createState() => _ModulesScreenState();
}

class _ModulesScreenState extends ConsumerState<ModulesScreen> {
  bool _busy = false;
  double _progress = 0;
  String _step = '';

  Future<void> _discover(bool deep) async {
    final elm = ref.read(sessionProvider).elm;
    if (elm == null) return;
    setState(() {
      _busy = true;
      _progress = 0;
    });
    try {
      final found = await _quiet(ref, () => UdsClient(elm).discover(
            deep: deep,
            onProgress: (p, s) {
              if (mounted) {
                setState(() {
                  _progress = p;
                  _step = s;
                });
              }
            },
          ));
      if (!mounted) return;
      ref.read(modulesProvider.notifier).set(found);
      if (found.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('ไม่พบกล่องที่ตอบ ลองค้นหาแบบละเอียด หรือตัวสแกนอาจไม่รองรับ'),
        ));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('ค้นหาไม่สำเร็จ: ${_err(e)}')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final modules = ref.watch(modulesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('กล่องทั้งหมดในรถ')),
      body: NeedsConnection(
        message: 'เชื่อมต่อรถเพื่อค้นหากล่อง',
        builder: (context, service) {
          if (!service.elm.isCan) {
            return const EmptyState(
              icon: Icons.device_hub_rounded,
              title: 'รถใช้โปรโตคอลรุ่นเก่า',
              text: 'การอ่านกล่องอื่น (ABS ถุงลม ฯลฯ) ผ่าน PRO SCANNER รองรับเฉพาะรถที่ใช้ CAN (ส่วนใหญ่ปี 2008 ขึ้นไป)',
            );
          }
          return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
            PremiumCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  'ค้นหากล่องที่ตอบบนบัส CAN แล้วอ่านรหัสปัญหาด้วยมาตรฐาน UDS/KWP2000 '
                  'ชื่อกล่องและรหัสเฉพาะยี่ห้อบางรุ่นอาจแสดงไม่ครบ',
                  style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant, height: 1.45),
                ),
                const SizedBox(height: 14),
                Row(children: [
                  Expanded(
                    child: FilledButton.icon(
                      icon: const Icon(Icons.radar_rounded),
                      label: const Text('ค้นหาด่วน'),
                      onPressed: _busy ? null : () => _discover(false),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.travel_explore_rounded),
                      // จอแคบ (มือถือ) ให้ย่อตัวอักษรลงแทนการตัดขึ้นบรรทัดใหม่กลางวงเล็บ
                      label: const FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text('ละเอียด (~2 นาที)', maxLines: 1, softWrap: false),
                      ),
                      onPressed: _busy ? null : () => _discover(true),
                    ),
                  ),
                ]),
                if (_busy) ...[
                  const SizedBox(height: 14),
                  LinearProgressIndicator(value: _progress),
                  const SizedBox(height: 6),
                  Text(_step, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant, fontFamily: kMono)),
                ],
              ]),
            ),
            if (modules.isNotEmpty) ...[
              SectionLabel('พบ ${modules.length} กล่อง'),
              for (final m in modules)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: PremiumCard(
                    padding: const EdgeInsets.all(14),
                    radius: 18,
                    onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ModuleDetailScreen(module: m))),
                    child: Row(children: [
                      Container(
                        width: 44,
                        height: 44,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: (m.dtcs.isEmpty ? StatusColors.good : StatusColors.warn).withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(Icons.memory_rounded, color: m.dtcs.isEmpty ? StatusColors.good : StatusColors.warn),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(m.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                          Text('${m.tx} → ${m.rx}', style: TextStyle(fontFamily: kMono, fontSize: 12, color: cs.onSurfaceVariant)),
                        ]),
                      ),
                      if (m.error != null)
                        const Pill(text: 'อ่านไม่ได้', color: StatusColors.info)
                      else if (m.dtcs.isNotEmpty)
                        Pill(text: '${m.dtcs.length} รหัส', color: StatusColors.warn)
                      else
                        Icon(Icons.chevron_right_rounded, color: cs.onSurfaceVariant),
                    ]),
                  ),
                ),
            ],
          ]);
        },
      ),
    );
  }
}

const _commonDids = <(int, String)>[
  (0xF190, 'VIN'),
  (0xF197, 'ชื่อระบบ'),
  (0xF187, 'เลขอะไหล่'),
  (0xF18C, 'เลขซีเรียล'),
  (0xF189, 'เวอร์ชันซอฟต์แวร์'),
  (0xF191, 'เลขฮาร์ดแวร์'),
  (0xF18B, 'วันผลิต'),
  (0xF19E, 'ไฟล์ ODX'),
];

class ModuleDetailScreen extends ConsumerStatefulWidget {
  const ModuleDetailScreen({super.key, required this.module});

  final EcuModule module;

  @override
  ConsumerState<ModuleDetailScreen> createState() => _ModuleDetailScreenState();
}

class _ModuleDetailScreenState extends ConsumerState<ModuleDetailScreen> {
  bool _busy = false;
  final _did = TextEditingController(text: 'F190');
  final _didResults = <(String, String, String)>[]; // (DID, hex, ascii)

  @override
  void dispose() {
    _did.dispose();
    super.dispose();
  }

  UdsClient? get _uds {
    final elm = ref.read(sessionProvider).elm;
    return elm == null ? null : UdsClient(elm);
  }

  Future<void> _guard(Future<void> Function(UdsClient uds) body) async {
    final uds = _uds;
    if (uds == null || _busy) return;
    setState(() => _busy = true);
    try {
      await _quiet(ref, () => body(uds));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_err(e))));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        ref.read(modulesProvider.notifier).touch();
      }
    }
  }

  Future<void> _readDtcs() => _guard((uds) async {
        widget.module.dtcs = await uds.readDtcs(widget.module);
        widget.module.error = null;
      });

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('ลบรหัสของ ${widget.module.title}?'),
        content: const Text('จอดรถนิ่ง บิดกุญแจ ON ถ้ายังไม่ได้ซ่อม รหัสจะกลับมา\nรหัสถุงลมบางยี่ห้อต้องใช้เครื่องมือเฉพาะจึงจะลบได้'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('ยกเลิก')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: StatusColors.bad),
            onPressed: () => Navigator.pop(d, true),
            child: const Text('ลบรหัส'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _guard((uds) async {
      final done = await uds.clearDtcs(widget.module);
      widget.module.dtcs = await uds.readDtcs(widget.module);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(done ? 'ส่งคำสั่งลบแล้ว เหลือ ${widget.module.dtcs.length} รหัส' : 'กล่องไม่ยืนยันการลบ'),
        ));
      }
    });
  }

  Future<void> _readDid(int did) => _guard((uds) async {
        final d = await uds.readDid(widget.module, did);
        final id = did.toRadixString(16).padLeft(4, '0').toUpperCase();
        if (d == null) {
          _didResults.insert(0, (id, '—', 'ไม่มีคำตอบ'));
          return;
        }
        final hex = d.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');
        final ascii = String.fromCharCodes(d.map((b) => b >= 0x20 && b < 0x7F ? b : 0x2E));
        _didResults.insert(0, (id, hex, ascii));
      });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final m = widget.module;
    ref.watch(modulesProvider);
    return Scaffold(
      appBar: AppBar(title: Text(m.title)),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
        PremiumCard(
          child: Column(children: [
            KvRow('ที่อยู่ส่ง / รับ', '${m.tx} / ${m.rx}', mono: true),
            if (m.error != null) KvRow('สถานะล่าสุด', m.error!),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: FilledButton.icon(
                  icon: const Icon(Icons.qr_code_scanner_rounded),
                  label: const Text('อ่านรหัส'),
                  onPressed: _busy ? null : _readDtcs,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(foregroundColor: StatusColors.bad),
                  icon: const Icon(Icons.delete_sweep_rounded),
                  label: const Text('ลบรหัส'),
                  onPressed: _busy ? null : _clear,
                ),
              ),
            ]),
            if (_busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
          ]),
        ),
        SectionLabel('รหัสปัญหา (${m.dtcs.length})'),
        if (m.dtcs.isEmpty)
          PremiumCard(child: Text('ไม่มีรหัสปัญหา หรือยังไม่ได้อ่าน', style: TextStyle(color: cs.onSurfaceVariant)))
        else
          for (final d in m.dtcs)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: PremiumCard(
                padding: const EdgeInsets.all(14),
                radius: 16,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Text(d.display, style: const TextStyle(fontFamily: kMono, fontWeight: FontWeight.w800, fontSize: 16)),
                    const SizedBox(width: 10),
                    if (d.activeNow) const Pill(text: 'เกิดอยู่ตอนนี้', color: StatusColors.bad),
                    if (!d.activeNow && d.confirmed) const Pill(text: 'ยืนยันแล้ว', color: StatusColors.warn),
                    if (!d.confirmed && d.pending) const Pill(text: 'รอยืนยัน', color: StatusColors.info),
                  ]),
                  const SizedBox(height: 6),
                  if (d.ftbTh != null) Text(d.ftbTh!, style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text(d.statusTh, style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant)),
                ]),
              ),
            ),
        const SectionLabel('อ่านข้อมูลกล่อง (DID)'),
        PremiumCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final (id, name) in _commonDids)
                ActionChip(label: Text(name), onPressed: _busy ? null : () => _readDid(id)),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _did,
                  textCapitalization: TextCapitalization.characters,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9A-Fa-f]')),
                    LengthLimitingTextInputFormatter(4),
                  ],
                  decoration: const InputDecoration(labelText: 'DID (เลขฐาน 16)', isDense: true),
                  style: const TextStyle(fontFamily: kMono),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton(
                onPressed: _busy
                    ? null
                    : () {
                        final v = int.tryParse(_did.text, radix: 16);
                        if (v != null) _readDid(v);
                      },
                child: const Text('อ่าน'),
              ),
            ]),
            for (final (id, hex, ascii) in _didResults) ...[
              const Divider(height: 22),
              Text('DID $id', style: const TextStyle(fontWeight: FontWeight.w800, fontFamily: kMono)),
              const SizedBox(height: 4),
              SelectableText(ascii, style: const TextStyle(fontWeight: FontWeight.w600)),
              SelectableText(hex, style: TextStyle(fontFamily: kMono, fontSize: 12, color: cs.onSurfaceVariant)),
            ],
          ]),
        ),
      ]),
    );
  }
}
