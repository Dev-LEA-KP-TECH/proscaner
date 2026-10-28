import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/safety/command_guard.dart';
import '../state/providers.dart';
import 'theme.dart';

/// เทอร์มินัลสำหรับช่าง: ส่งคำสั่งดิบ ดูคำตอบและ log ทั้งหมด
class TerminalScreen extends ConsumerStatefulWidget {
  const TerminalScreen({super.key});

  @override
  ConsumerState<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends ConsumerState<TerminalScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _sending = false;

  static const _quick = ['ATRV', 'ATDP', '0100', '0101', '03', '07', '0A', '0902'];

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send(String cmd) async {
    final elm = ref.read(sessionProvider).elm;
    final c = cmd.replaceAll(RegExp(r'\s+'), '').toUpperCase();
    if (elm == null || c.isEmpty) return;
    // ด่านอ่านอย่างเดียว: คำสั่งตัวสแกนพิมพ์ได้เฉพาะคำสั่งดูข้อมูล (คำสั่งตั้งค่าจะไปเปลี่ยนสิ่งที่แอปใช้อยู่)
    // คำสั่งถึงรถส่งได้เฉพาะคำสั่งอ่านค่า ลบรหัสต้องใช้ปุ่มในหน้าวินิจฉัย
    final refusal = terminalRefusal(c);
    if (refusal != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(refusal)));
      return;
    }
    setState(() => _sending = true);
    try {
      await elm.send(c, timeout: const Duration(seconds: 10));
    } catch (_) {
      // ข้อผิดพลาดถูกเขียนลง log แล้ว
    } finally {
      if (mounted) setState(() => _sending = false);
      _input.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final log = ref.watch(logProvider);
    final connected = ref.watch(sessionProvider).isConnected;
    return Scaffold(
      appBar: AppBar(
        title: const FitText('เทอร์มินัลตัวสแกน'),
        actions: [
          IconButton(
            tooltip: 'ล้าง log',
            icon: const Icon(Icons.clear_all),
            onPressed: () => ref.read(logProvider.notifier).clear(),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: Container(
              color: Colors.black,
              width: double.infinity,
              child: ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.all(8),
                itemCount: log.length,
                itemBuilder: (_, i) => Text(
                  log[i],
                  style: TextStyle(
                    fontFamily: kMono,
                    fontSize: 12,
                    color: log[i].startsWith('>')
                        ? Colors.lightGreenAccent
                        : log[i].startsWith('(ไม่ส่ง')
                            ? Colors.orangeAccent
                            : Colors.white,
                  ),
                ),
              ),
            ),
          ),
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                for (final q in _quick)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ActionChip(label: Text(q), onPressed: connected && !_sending ? () => _send(q) : null),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  enabled: connected && !_sending,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(
                    hintText: 'เช่น 010C หรือ ATRV',
                    helperText: 'ส่งได้เฉพาะคำสั่งอ่านค่า',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onSubmitted: _send,
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                icon: const Icon(Icons.send),
                onPressed: connected && !_sending ? () => _send(_input.text) : null,
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}
