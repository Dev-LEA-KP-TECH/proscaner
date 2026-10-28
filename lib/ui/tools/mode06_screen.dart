import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/obd/obd_service.dart';
import '../home_screen.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// ผลทดสอบที่กล่องเครื่องยนต์ทำเอง (Mode 06): misfire สะสมรายสูบ, แคท, O2, EVAP ฯลฯ
class Mode06Screen extends ConsumerStatefulWidget {
  const Mode06Screen({super.key});

  @override
  ConsumerState<Mode06Screen> createState() => _Mode06ScreenState();
}

class _Mode06ScreenState extends ConsumerState<Mode06Screen> {
  List<Mode06Result>? _results;
  bool _busy = false;
  String _step = '';
  String? _error;
  bool _failedOnly = false;

  Future<void> _read(ObdService service) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await service.readMode06(onStep: (s) {
        if (mounted) setState(() => _step = s);
      });
      if (mounted) setState(() => _results = r);
    } catch (e) {
      if (mounted) setState(() => _error = 'อ่านไม่สำเร็จ: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const FitText('ผลทดสอบเซ็นเซอร์ (Mode 06)')),
      body: NeedsConnection(
        message: 'เชื่อมต่อรถเพื่ออ่านผลทดสอบ',
        builder: (context, service) {
          final results = _results;
          if (results == null) {
            return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
              PremiumCard(
                glow: cs.primary,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('กล่องทดสอบอะไรไปแล้วบ้าง', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                  const SizedBox(height: 8),
                  Text(
                    'กล่องเครื่องยนต์ทดสอบแคทาไลติก เซ็นเซอร์ O2 ระบบ EVAP EGR และนับการจุดระเบิดไม่สมบูรณ์รายสูบตลอดเวลา '
                    'ผลนี้ช่วยเห็นปัญหาก่อนไฟเตือนติด เช่น สูบที่เริ่ม misfire หรือแคทที่ใกล้เสื่อม',
                    style: TextStyle(color: cs.onSurfaceVariant, height: 1.5, fontSize: 13),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      icon: const Icon(Icons.science_rounded),
                      label: Text(_busy ? 'กำลังอ่าน $_step' : 'อ่านผลทดสอบ'),
                      onPressed: _busy ? null : () => _read(service),
                    ),
                  ),
                  if (_busy) ...[const SizedBox(height: 12), const LinearProgressIndicator()],
                  if (_error != null) ...[const SizedBox(height: 10), Text(_error!, style: TextStyle(color: cs.error))],
                  if (!service.elm.isCan) ...[
                    const SizedBox(height: 10),
                    Text('รถคันนี้ไม่ใช่ CAN จึงอาจไม่รองรับ Mode 06 แบบมาตรฐาน', style: TextStyle(color: cs.onSurfaceVariant)),
                  ],
                ]),
              ),
            ]);
          }
          if (results.isEmpty) {
            return EmptyState(
              icon: Icons.science_outlined,
              title: 'รถไม่ส่งผลทดสอบ Mode 06',
              action: OutlinedButton(onPressed: () => _read(service), child: const Text('ลองใหม่')),
            );
          }
          final failed = results.where((r) => !r.passed).length;
          final misfire = results.where((r) => r.misfireCylinder != null && r.tid == 0x0B).toList();
          final groups = <int, List<Mode06Result>>{};
          for (final r in results) {
            if (_failedOnly && r.passed) continue;
            (groups[r.mid] ??= []).add(r);
          }
          return RefreshIndicator(
            onRefresh: () => _read(service),
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
              PremiumCard(
                glow: failed > 0 ? StatusColors.bad : StatusColors.good,
                child: Row(children: [
                  Icon(failed > 0 ? Icons.report_rounded : Icons.verified_rounded,
                      size: 38, color: failed > 0 ? StatusColors.bad : StatusColors.good),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(failed > 0 ? 'ไม่ผ่าน $failed\u00A0รายการ' : 'ผ่านทุกรายการ',
                          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
                      Text('ทดสอบทั้งหมด ${results.length}\u00A0รายการ', style: TextStyle(color: cs.onSurfaceVariant)),
                    ]),
                  ),
                ]),
              ),
              if (misfire.isNotEmpty) ...[
                const SectionLabel('การจุดระเบิดไม่สมบูรณ์รายสูบ (เฉลี่ย 10\u00A0รอบขับ)'),
                PremiumCard(child: _MisfireBars(items: misfire)),
              ],
              SectionLabel('รายการทดสอบ',
                  trailing: FilterChip(
                    label: const Text('เฉพาะไม่ผ่าน'),
                    selected: _failedOnly,
                    onSelected: (v) => setState(() => _failedOnly = v),
                  )),
              for (final e in groups.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: PremiumCard(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    radius: 18,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(e.value.first.midName, style: const TextStyle(fontWeight: FontWeight.w800)),
                      const SizedBox(height: 4),
                      for (final r in e.value) _TestRow(r: r),
                    ]),
                  ),
                ),
            ]),
          );
        },
      ),
    );
  }
}

class _TestRow extends StatelessWidget {
  const _TestRow({required this.r});

  final Mode06Result r;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = r.passed ? StatusColors.good : StatusColors.bad;
    final span = r.max - r.min;
    final frac = span <= 0 ? 0.5 : ((r.value - r.min) / span).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(r.passed ? Icons.check_circle_rounded : Icons.cancel_rounded, size: 16, color: color),
          const SizedBox(width: 6),
          Expanded(child: Text(r.tidName, style: const TextStyle(fontSize: 13))),
          Text('${r.fmt(r.value)} ${r.unit}', style: TextStyle(fontWeight: FontWeight.w800, color: color, fontSize: 13)),
        ]),
        const SizedBox(height: 4),
        Row(children: [
          SizedBox(
            width: 60,
            child: Text(r.fmt(r.min), style: TextStyle(fontSize: 10.5, color: cs.onSurfaceVariant, fontFamily: kMono)),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) => Stack(children: [
                Container(height: 6, decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(3))),
                Positioned(
                  left: (c.maxWidth - 10) * frac,
                  child: Container(width: 10, height: 6, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3))),
                ),
              ]),
            ),
          ),
          SizedBox(
            width: 60,
            child: Text(r.fmt(r.max),
                textAlign: TextAlign.right, style: TextStyle(fontSize: 10.5, color: cs.onSurfaceVariant, fontFamily: kMono)),
          ),
        ]),
      ]),
    );
  }
}

class _MisfireBars extends StatelessWidget {
  const _MisfireBars({required this.items});

  final List<Mode06Result> items;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final maxV = items.map((r) => r.value).fold<double>(10, (a, b) => b > a ? b : a);
    return Column(children: [
      SizedBox(
        height: 130,
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          for (final r in items)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                  Text(r.value.round().toString(), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
                  const SizedBox(height: 4),
                  Container(
                    height: 90 * (r.value / maxV).clamp(0.03, 1.0),
                    decoration: BoxDecoration(
                      color: r.value > 20 ? StatusColors.bad : (r.value > 5 ? StatusColors.warn : StatusColors.good),
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ]),
              ),
            ),
        ]),
      ),
      const SizedBox(height: 6),
      Row(children: [
        for (final r in items)
          Expanded(child: Text('สูบ\u00A0${r.misfireCylinder}', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant))),
      ]),
      const SizedBox(height: 8),
      Text('สูบที่ตัวเลขสูงกว่าสูบอื่นชัดเจน ให้ตรวจหัวเทียน คอยล์ หัวฉีด ของสูบนั้นก่อน',
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
    ]);
  }
}
