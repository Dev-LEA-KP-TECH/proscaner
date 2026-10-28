import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/obd/dtc_database.dart';
import '../state/providers.dart';
import 'theme.dart';
import 'widgets/severity_style.dart';

/// ค้นหาความหมายรหัสปัญหาแบบออฟไลน์ ไม่ต้องเชื่อมต่อรถ
class DtcLookupScreen extends ConsumerStatefulWidget {
  const DtcLookupScreen({super.key, this.initialQuery = ''});

  final String initialQuery;

  @override
  ConsumerState<DtcLookupScreen> createState() => _DtcLookupScreenState();
}

class _DtcLookupScreenState extends ConsumerState<DtcLookupScreen> {
  late final _q = TextEditingController(text: widget.initialQuery);

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final db = ref.watch(dtcDatabaseProvider);
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('ค้นหารหัสปัญหา')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: TextField(
            controller: _q,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search_rounded),
              hintText: 'พิมพ์รหัส เช่น P0171 หรือคำว่า ส่วนผสม',
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        Expanded(
          child: db.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('โหลดฐานข้อมูลไม่ได้: $e')),
            data: (d) {
              final items = d.search(_q.text);
              if (items.isEmpty) {
                return Center(child: Text('ไม่พบรหัสที่ตรงกัน', style: TextStyle(color: cs.onSurfaceVariant)));
              }
              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                itemCount: items.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, i) => _DtcTile(info: items[i]),
              );
            },
          ),
        ),
      ]),
    );
  }
}

class _DtcTile extends StatelessWidget {
  const _DtcTile({required this.info});

  final DtcInfo info;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = info.severity.color(cs);
    return PremiumCard(
      padding: EdgeInsets.zero,
      radius: 18,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.fromLTRB(14, 4, 12, 4),
          leading: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(10)),
            child: Text(info.code,
                style: TextStyle(fontFamily: kMono, fontWeight: FontWeight.w800, color: color, fontSize: 13)),
          ),
          title: Text(info.descriptionTh, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14, height: 1.35)),
          subtitle: Padding(padding: const EdgeInsets.only(top: 6), child: Align(alignment: Alignment.centerLeft, child: SeverityChip(info.severity))),
          childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (info.causes.isNotEmpty) ...[
              const Text('สาเหตุที่พบบ่อย', style: TextStyle(fontWeight: FontWeight.w800)),
              for (final c in info.causes) Padding(padding: const EdgeInsets.only(top: 4), child: Text('• $c')),
              const SizedBox(height: 10),
            ],
            if (info.checks.isNotEmpty) ...[
              const Text('วิธีตรวจเช็ก', style: TextStyle(fontWeight: FontWeight.w800)),
              for (final c in info.checks) Padding(padding: const EdgeInsets.only(top: 4), child: Text('• $c')),
            ],
          ],
        ),
      ),
    );
  }
}
