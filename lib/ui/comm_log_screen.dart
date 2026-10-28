import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../data/comm_log.dart';
import '../report/pdf_report.dart' show shareFile;
import '../state/providers.dart';
import 'theme.dart';
import 'widgets/common.dart';

String _size(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}

/// ส่งบันทึกหนึ่งครั้ง (คัดลอกไปโฟลเดอร์ชั่วคราวก่อน ให้แอปอื่นเปิดได้)
Future<void> shareCommLog(BuildContext context, WidgetRef ref, CommLogSession s) async {
  await ref.read(commLogProvider).flush();
  final dir = await getTemporaryDirectory();
  final f = await s.file.copy('${dir.path}/ProScaner_${s.name}');
  if (context.mounted) {
    await shareFile(context, f.path, mime: 'text/plain', subject: 'ProScaner บันทึกการสื่อสาร ${thaiDate(s.start)}');
  }
}

/// บันทึกการสื่อสารกับตัวสแกน/รถ: เปิด-ปิด ดู และส่งให้ผู้พัฒนา
class CommLogScreen extends ConsumerStatefulWidget {
  const CommLogScreen({super.key});

  @override
  ConsumerState<CommLogScreen> createState() => _CommLogScreenState();
}

class _CommLogScreenState extends ConsumerState<CommLogScreen> {
  late Future<List<CommLogSession>> _sessions = ref.read(commLogProvider).sessions();

  // ใช้วงเล็บปีกกา: ถ้าเขียน setState(() => _sessions = ...) ตัวปิดจะคืนค่า Future ซึ่ง Flutter ไม่ยอม
  void _reload() => setState(() {
        _sessions = ref.read(commLogProvider).sessions();
      });

  Future<void> _share(CommLogSession s) async {
    try {
      await shareCommLog(context, ref, s);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('ส่งไม่สำเร็จ: $e')));
    }
  }

  Future<void> _deleteAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('ลบบันทึกทั้งหมด?'),
        content: const Text('ลบบันทึกการสื่อสารทุกครั้งที่เก็บไว้ในเครื่องนี้ กู้คืนไม่ได้'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('ยกเลิก')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('ลบ')),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(commLogProvider).deleteAll();
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final on = ref.watch(commLogEnabledProvider);
    final current = ref.read(commLogProvider).currentName;
    return Scaffold(
      appBar: AppBar(title: const FitText('บันทึกการสื่อสาร'), actions: [
        IconButton(
          tooltip: 'ลบบันทึกทั้งหมด',
          icon: const Icon(Icons.delete_sweep_rounded),
          onPressed: _deleteAll,
        ),
      ]),
      body: RefreshIndicator(
        onRefresh: () async {
          _reload();
          await _sessions;
        },
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
          PremiumCard(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('บันทึกทุกครั้งที่เชื่อมต่อ', style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(
                    'เก็บทุกคำสั่งที่แอปส่ง และทุกคำตอบจากตัวสแกน/รถ พร้อมเวลา ไว้ในเครื่องนี้ 30 ครั้งล่าสุด '
                    'ถ้าแอปอ่านค่ารถคันไหนไม่ได้หรือค่าแปลกๆ ส่งบันทึกครั้งนั้นให้ผู้พัฒนาตรวจได้',
                    style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant, height: 1.45),
                  ),
                ]),
              ),
              const SizedBox(width: 8),
              Switch(value: on, onChanged: (v) => ref.read(commLogEnabledProvider.notifier).set(v)),
            ]),
          ),
          const SectionLabel('บันทึกที่เก็บไว้'),
          FutureBuilder<List<CommLogSession>>(
            future: _sessions,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
              }
              final list = snap.data ?? const <CommLogSession>[];
              if (list.isEmpty) {
                return const EmptyState(
                  icon: Icons.receipt_long_rounded,
                  title: 'ยังไม่มีบันทึก',
                  text: 'เชื่อมต่อตัวสแกนกับรถจริงแล้วบันทึกจะขึ้นที่นี่ (โหมดทดลองไม่บันทึก)',
                );
              }
              return Column(children: [
                for (final s in list)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: PremiumCard(
                      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
                      radius: 18,
                      onTap: () async {
                        await Navigator.of(context)
                            .push(MaterialPageRoute<void>(builder: (_) => CommLogViewer(session: s)));
                        if (mounted) _reload();
                      },
                      child: Row(children: [
                        Icon(Icons.receipt_long_rounded, color: s.name == current ? const Color(0xFF22C474) : cs.primary),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(s.title.isEmpty ? 'การเชื่อมต่อ' : s.title,
                                style: const TextStyle(fontWeight: FontWeight.w700)),
                            const SizedBox(height: 2),
                            Text(
                              '${thaiDate(s.start)} · ${_size(s.bytes)}${s.name == current ? ' · กำลังบันทึก' : ''}',
                              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                            ),
                          ]),
                        ),
                        IconButton(
                          tooltip: 'ส่ง',
                          icon: const Icon(Icons.share_rounded),
                          onPressed: () => _share(s),
                        ),
                      ]),
                    ),
                  ),
              ]);
            },
          ),
        ]),
      ),
    );
  }
}

/// ดูบันทึกหนึ่งครั้ง (แสดงส่วนท้ายถ้ายาวมาก)
class CommLogViewer extends ConsumerStatefulWidget {
  const CommLogViewer({super.key, required this.session});

  final CommLogSession session;

  @override
  ConsumerState<CommLogViewer> createState() => _CommLogViewerState();
}

class _CommLogViewerState extends ConsumerState<CommLogViewer> {
  static const _maxChars = 200000;

  late final Future<String> _text = ref.read(commLogProvider).read(widget.session);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: FitText(thaiDate(widget.session.start)), actions: [
        IconButton(
          tooltip: 'ส่ง',
          icon: const Icon(Icons.share_rounded),
          onPressed: () async {
            try {
              await shareCommLog(context, ref, widget.session);
            } catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('ส่งไม่สำเร็จ: $e')));
              }
            }
          },
        ),
      ]),
      body: FutureBuilder<String>(
        future: _text,
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text('เปิดบันทึกไม่ได้: ${snap.error}'));
          final all = snap.data;
          if (all == null) return const Center(child: CircularProgressIndicator());
          final cut = all.length > _maxChars;
          final text = cut ? all.substring(all.length - _maxChars) : all;
          return ListView(padding: const EdgeInsets.all(12), children: [
            if (cut)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('บันทึกยาวมาก แสดงเฉพาะส่วนท้าย (ไฟล์ที่ส่งมีครบทั้งหมด)',
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5)),
              ),
            SelectableText(text, style: const TextStyle(fontFamily: kMono, fontSize: 11.5, height: 1.35)),
          ]);
        },
      ),
    );
  }
}
