import 'package:flutter/material.dart';

import '../../core/obd/ext_pid.dart';
import '../../core/obd/formula.dart';

/// แก้ไข/เพิ่มค่าเฉพาะยี่ห้อ
class ExtPidEditScreen extends StatefulWidget {
  const ExtPidEditScreen({super.key, this.pid, this.sampleRaw});

  final ExtPid? pid;

  /// ข้อมูลดิบล่าสุด (ถ้ามี) ใช้แสดงค่าตัวอย่างขณะแก้สูตร
  final List<int>? sampleRaw;

  @override
  State<ExtPidEditScreen> createState() => _ExtPidEditScreenState();
}

class _ExtPidEditScreenState extends State<ExtPidEditScreen> {
  late final ExtPid _p = widget.pid?.copy() ?? ExtPid(name: '', request: '', formula: 'A', header: '7E0');
  late final _name = TextEditingController(text: _p.name);
  late final _header = TextEditingController(text: _p.header);
  late final _rx = TextEditingController(text: _p.rx ?? '');
  late final _req = TextEditingController(text: _p.request);
  late final _formula = TextEditingController(text: _p.formula)..addListener(() => setState(() {}));
  late final _unit = TextEditingController(text: _p.unit);
  late final _min = TextEditingController(text: _p.min?.toString() ?? '');
  late final _max = TextEditingController(text: _p.max?.toString() ?? '');
  late final _group = TextEditingController(text: _p.group);
  late int _dec = _p.decimals;
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _header, _rx, _req, _formula, _unit, _min, _max, _group]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    final changedCmd = _p.request != _req.text.trim().toUpperCase().replaceAll(' ', '') ||
        _p.header != _header.text.trim().toUpperCase() ||
        _p.formula != _formula.text.trim();
    final p = _p
      ..name = _name.text.trim()
      ..header = _header.text.trim().toUpperCase()
      ..rx = _rx.text.trim().isEmpty ? null : _rx.text.trim().toUpperCase()
      ..request = _req.text.trim().toUpperCase().replaceAll(' ', '')
      ..formula = _formula.text.trim()
      ..unit = _unit.text.trim()
      ..min = double.tryParse(_min.text.trim())
      ..max = double.tryParse(_max.text.trim())
      ..decimals = _dec
      ..group = _group.text.trim();
    final err = p.validate();
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    // แก้คำสั่งหรือสูตรแล้ว ผลยืนยันเดิมใช้ไม่ได้
    if (changedCmd && p.verified) {
      p
        ..verified = false
        ..verifiedBy = null
        ..verifiedAt = null
        ..verifiedOn = null;
    }
    Navigator.of(context).pop(p);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    InputDecoration dec(String label, [String? hint]) => InputDecoration(labelText: label, hintText: hint);
    String? preview;
    final raw = widget.sampleRaw;
    if (raw != null && raw.isNotEmpty) {
      try {
        preview = Formula(_formula.text.trim()).eval(raw).toStringAsFixed(_dec.clamp(0, 4));
      } catch (e) {
        preview = 'คำนวณไม่ได้';
      }
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.pid == null || widget.pid!.name.isEmpty ? 'เพิ่มค่า' : 'แก้ไขค่า'),
        actions: [TextButton(onPressed: _save, child: const Text('บันทึก'))],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 40), children: [
        TextField(controller: _name, decoration: dec('ชื่อ', 'เช่น ชดเชยหัวฉีดสูบ 1')),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: TextField(controller: _header, decoration: dec('Header กล่อง', '7E0 / 700 / 18DA10F1'))),
          const SizedBox(width: 10),
          Expanded(child: TextField(controller: _req, decoration: dec('คำสั่ง (hex)', '221101 หรือ 2101'))),
        ]),
        const SizedBox(height: 10),
        TextField(controller: _rx, decoration: dec('Header ตอบกลับ (เว้นว่าง = ปกติ)', 'เช่น 708 หรือ 6A0')),
        const SizedBox(height: 10),
        TextField(controller: _formula, decoration: dec('สูตร', 'เช่น A-40 หรือ S16(A,B)/100')),
        const SizedBox(height: 6),
        Text(
          'A, B, C … = ไบต์ข้อมูลหลังเลขคำสั่ง · S(A) = มีเครื่องหมาย · S16(A,B) / U16(A,B) = 16 บิต · {A:3} = บิตที่ 3 · bits(x,s,n) = ตัดบิต',
          style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant, height: 1.4),
        ),
        if (preview != null) ...[
          const SizedBox(height: 6),
          Text('ค่าจากข้อมูลล่าสุด: $preview ${_unit.text}', style: TextStyle(fontWeight: FontWeight.w700, color: cs.primary)),
        ],
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: TextField(controller: _unit, decoration: dec('หน่วย', '°C, g, mm³'))),
          const SizedBox(width: 10),
          Expanded(child: TextField(controller: _group, decoration: dec('กลุ่ม', 'หัวฉีด, DPF, เกียร์'))),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _min,
              keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
              decoration: dec('ค่าต่ำสุดที่เป็นไปได้'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _max,
              keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
              decoration: dec('ค่าสูงสุดที่เป็นไปได้'),
            ),
          ),
        ]),
        const SizedBox(height: 14),
        Row(children: [
          const Text('ทศนิยม'),
          const Spacer(),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('0')),
              ButtonSegment(value: 1, label: Text('1')),
              ButtonSegment(value: 2, label: Text('2')),
              ButtonSegment(value: 3, label: Text('3')),
            ],
            selected: {_dec.clamp(0, 3)},
            onSelectionChanged: (s) => setState(() => _dec = s.first),
          ),
        ]),
        if (_p.verified) ...[
          const SizedBox(height: 10),
          Text('ถ้าแก้คำสั่งหรือสูตร ผลยืนยันเดิมจะถูกยกเลิก ต้องเทียบค่าใหม่',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
        ],
        if (_error != null) ...[
          const SizedBox(height: 6),
          Text(_error!, style: TextStyle(color: cs.error)),
        ],
        const SizedBox(height: 14),
        FilledButton(onPressed: _save, child: const Text('บันทึก')),
      ]),
    );
  }
}
