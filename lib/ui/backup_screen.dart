import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../core/app_info.dart';
import '../data/backup.dart';
import '../data/file_port.dart';
import '../report/pdf_report.dart' show shareFile;
import '../state/backup_providers.dart';
import 'theme.dart';
import 'widgets/common.dart';

/// สำรอง/กู้คืนข้อมูลทั้งแอปเป็นไฟล์เดียว (ย้ายเครื่อง ย้ายระหว่างแอปทดสอบกับแอปจริง กันข้อมูลหาย)
class BackupScreen extends ConsumerStatefulWidget {
  const BackupScreen({super.key});

  @override
  ConsumerState<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends ConsumerState<BackupScreen> {
  late Future<BackupData> _current = _collect();
  bool _busy = false;

  Future<BackupData> _collect() => ref.read(backupServiceProvider).collect(appVersion: kAppVersion);

  static String _fileName(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return 'ProScaner_backup_${t.year}${two(t.month)}${two(t.day)}_${two(t.hour)}${two(t.minute)}.json';
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// ทำงานทีละอย่าง กันกดซ้ำ และแจ้งข้อผิดพลาดเป็นภาษาไทย
  Future<void> _run(Future<void> Function() body) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await body();
    } on FilePortException catch (e) {
      _snack(e.message);
    } catch (e) {
      _snack('ทำไม่สำเร็จ: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() => _run(() async {
        final data = await _collect();
        final uri = await ref
            .read(filePortProvider)
            .saveDocument(name: _fileName(data.created), mime: 'application/json', bytes: data.encode());
        if (uri != null) _snack('บันทึกไฟล์สำรองแล้ว');
      });

  Future<void> _share() => _run(() async {
        final data = await _collect();
        final dir = await getTemporaryDirectory();
        final f = File('${dir.path}/${_fileName(data.created)}');
        await f.writeAsBytes(data.encode(), flush: true);
        if (mounted) await shareFile(context, f.path, mime: 'application/json', subject: 'ไฟล์สำรอง ProScaner');
      });

  Future<void> _restore() async {
    if (_busy) return;
    final Uint8List? bytes;
    try {
      bytes = await ref.read(filePortProvider).openDocument();
    } on FilePortException catch (e) {
      _snack(e.message);
      return;
    }
    if (bytes == null || !mounted) return;
    final BackupData data;
    try {
      data = BackupData.parse(bytes);
    } on FormatException catch (e) {
      await _message('เปิดไฟล์นี้ไม่ได้', [e.message]);
      return;
    }
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        icon: const Icon(Icons.settings_backup_restore_rounded),
        title: const Text('กู้คืนจากไฟล์นี้?'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text([
              if (data.appVersion.isNotEmpty) 'จาก ProScaner ${data.appVersion}',
              if (data.created.year > 2000) 'สร้างเมื่อ ${thaiDate(data.created)}',
            ].join(' · ')),
            const SizedBox(height: 10),
            for (final l in data.contentsTh()) Text('• $l'),
            const SizedBox(height: 12),
            const Text(
              'ข้อมูลในไฟล์จะถูกรวมเข้ากับข้อมูลในเครื่องนี้ ไม่ลบของเดิม '
              'รถที่มีอยู่แล้วจะเติมเฉพาะช่องที่ยังว่าง ค่าที่ตั้งไว้แล้วไม่เปลี่ยน '
              'และแอปจะเก็บสำเนาข้อมูลเดิมไว้ก่อน',
              style: TextStyle(fontSize: 13, height: 1.45),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('ยกเลิก')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('กู้คืน')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _run(() async {
      final service = ref.read(backupServiceProvider);
      final safety = await service.safetyCopy(appVersion: kAppVersion);
      if (safety == null) {
        await _message('ยังไม่ได้กู้คืน', ['เก็บสำเนาข้อมูลเดิมไม่สำเร็จ (ที่เก็บข้อมูลในเครื่องอาจเต็ม) ลองลบไฟล์ที่ไม่ใช้แล้วลองใหม่']);
        return;
      }
      final r = await service.restore(data);
      reloadAfterRestore(ref);
      if (mounted) {
        setState(() {
          _current = _collect();
        });
      }
      await _message(
        r.nothing ? 'ไม่มีอะไรต้องเพิ่ม' : 'กู้คืนเรียบร้อย',
        r.nothing ? ['ข้อมูลในไฟล์มีอยู่ในเครื่องนี้ครบแล้ว'] : r.linesTh(),
      );
    });
  }

  Future<void> _message(String title, List<String> lines) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [for (final l in lines) Text(lines.length > 1 ? '• $l' : l)],
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('ตกลง'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const FitText('สำรอง / กู้คืนข้อมูล')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
        Text(
          'เก็บข้อมูลทั้งหมดของแอปไว้ในไฟล์เดียว ใช้ย้ายไปเครื่องใหม่ ย้ายจากแอปตัวทดสอบมาแอปตัวจริง '
          'หรือเก็บไว้กันข้อมูลหาย',
          style: TextStyle(color: cs.onSurfaceVariant, height: 1.45),
        ),
        const SectionLabel('ข้อมูลในเครื่องนี้'),
        PremiumCard(
          child: FutureBuilder<BackupData>(
            future: _current,
            builder: (context, snap) {
              if (snap.hasError) return Text('อ่านข้อมูลไม่สำเร็จ: ${snap.error}');
              final d = snap.data;
              if (d == null) return const LinearProgressIndicator();
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (final l in d.contentsTh())
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(children: [
                      Icon(Icons.check_circle_outline_rounded, size: 18, color: cs.primary),
                      const SizedBox(width: 10),
                      Expanded(child: Text(l)),
                    ]),
                  ),
              ]);
            },
          ),
        ),
        const SectionLabel('สำรองข้อมูล'),
        FilledButton.icon(
          icon: const Icon(Icons.save_alt_rounded),
          label: const Text('บันทึกไฟล์สำรองลงเครื่อง'),
          onPressed: _busy ? null : _save,
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          icon: const Icon(Icons.share_rounded),
          label: const Text('ส่งไฟล์สำรอง (LINE, Drive, อีเมล)'),
          onPressed: _busy ? null : _share,
        ),
        const SectionLabel('กู้คืน'),
        OutlinedButton.icon(
          icon: const Icon(Icons.settings_backup_restore_rounded),
          label: const Text('กู้คืนจากไฟล์สำรอง'),
          onPressed: _busy ? null : _restore,
        ),
        const SizedBox(height: 8),
        Text(
          'เลือกไฟล์ที่ได้จากปุ่มบันทึกหรือส่งไฟล์สำรอง ข้อมูลจะถูกรวมกับของในเครื่องนี้ ไม่ลบของเดิม',
          style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant, height: 1.45),
        ),
        if (_busy) ...[const SizedBox(height: 16), const LinearProgressIndicator()],
        const SizedBox(height: 18),
        PremiumCard(
          glow: const Color(0xFFFFB020),
          padding: const EdgeInsets.all(14),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.privacy_tip_rounded, color: Color(0xFFFFB020)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'ไฟล์สำรองมีข้อมูลลูกค้า (ชื่อ เบอร์โทร ทะเบียน VIN) ส่งให้เฉพาะคนที่ไว้ใจ และเก็บไว้ในที่ปลอดภัย',
                style: TextStyle(fontSize: 12.5, color: cs.onSurface, height: 1.45),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}
