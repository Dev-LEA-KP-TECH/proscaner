import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/diagnosis/diagnosis.dart';
import '../core/diagnosis/report_text.dart';
import '../report/pdf_report.dart';
import '../state/providers.dart';
import 'diagnosis_tab.dart';
import 'theme.dart';
import 'widgets/severity_style.dart';

/// ผลวิเคราะห์ของทุกรายการในประวัติ (คำนวณครั้งเดียว ไม่กระพริบตอนเลื่อน)
final historyReportsProvider = FutureProvider<List<DiagnosisReport>>((ref) async {
  final items = await ref.watch(historyProvider.future);
  final engine = await ref.watch(diagnosisEngineProvider.future);
  return [for (final s in items) await engine.analyze(s)];
});

String formatThaiDate(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(t.day)}/${two(t.month)}/${t.year + 543} ${two(t.hour)}:${two(t.minute)}';
}

class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key, this.vin});

  /// แสดงเฉพาะรถคันนี้ (null = ทั้งหมด)
  final String? vin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('ประวัติการสแกน')),
      body: HistoryList(vin: vin),
    );
  }
}

class HistoryList extends ConsumerWidget {
  const HistoryList({super.key, this.vin, this.shrinkWrap = false});

  final String? vin;
  final bool shrinkWrap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reports = ref.watch(historyReportsProvider);
    final cs = Theme.of(context).colorScheme;

    return reports.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('อ่านประวัติไม่ได้: $e')),
      data: (all) {
        final items = vin == null ? all : all.where((r) => r.snapshot.vin == vin).toList();
        if (items.isEmpty) {
          return Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.history_toggle_off_rounded, size: 64, color: cs.onSurfaceVariant),
              const SizedBox(height: 12),
              const Text('ยังไม่มีประวัติการสแกน', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text('ผลสแกนทุกครั้งจะถูกบันทึกไว้ที่นี่', style: TextStyle(color: cs.onSurfaceVariant)),
              const SizedBox(height: 24),
            ]),
          );
        }
        return ListView.separated(
          shrinkWrap: shrinkWrap,
          physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
          padding: shrinkWrap ? EdgeInsets.zero : const EdgeInsets.fromLTRB(16, 8, 16, 24),
          itemCount: items.length,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (context, i) {
            final r = items[i];
            final s = r.snapshot;
            final color = r.overall.color(cs);
            return PremiumCard(
              padding: const EdgeInsets.all(14),
              radius: 18,
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => HistoryDetail(report: r))),
              child: Row(children: [
                Container(
                  width: 54,
                  height: 54,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: color, width: 3),
                    color: color.withValues(alpha: 0.1),
                  ),
                  child: Text('${r.healthScore}', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17, color: color)),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(r.headlineTh, style: const TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 3),
                    Text(formatThaiDate(s.time), style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                    const SizedBox(height: 6),
                    Wrap(spacing: 6, runSpacing: 4, children: [
                      if (s.codes.isEmpty)
                        Text('ไม่มีรหัสปัญหา', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                      for (final c in s.codes)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: cs.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(c,
                              style: const TextStyle(fontFamily: kMono, fontSize: 11.5, fontWeight: FontWeight.w700)),
                        ),
                    ]),
                  ]),
                ),
                Icon(Icons.chevron_right_rounded, color: cs.onSurfaceVariant),
              ]),
            );
          },
        );
      },
    );
  }
}

class HistoryDetail extends ConsumerWidget {
  const HistoryDetail({super.key, required this.report});

  final DiagnosisReport report;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: Text(formatThaiDate(report.snapshot.time)),
        actions: [
          IconButton(
            tooltip: 'รายงาน PDF',
            icon: const Icon(Icons.picture_as_pdf_rounded),
            onPressed: () => shareReportPdf(context, ref, report: report),
          ),
          IconButton(
            tooltip: 'คัดลอกรายงาน',
            icon: const Icon(Icons.copy_all_rounded),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: buildReportText(report)));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('คัดลอกรายงานแล้ว')));
              }
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [ReportView(report: report, mode: ref.watch(appModeProvider))],
      ),
    );
  }
}
