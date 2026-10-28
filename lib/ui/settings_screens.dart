import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../core/voice/voice_service.dart';
import '../state/providers.dart';
import 'theme.dart';

/// ข้อมูลอู่สำหรับหัวรายงาน PDF
class ShopProfileScreen extends ConsumerStatefulWidget {
  const ShopProfileScreen({super.key});

  @override
  ConsumerState<ShopProfileScreen> createState() => _ShopProfileScreenState();
}

class _ShopProfileScreenState extends ConsumerState<ShopProfileScreen> {
  late final ShopProfile _init = ref.read(settingsProvider).shop;
  late final _name = TextEditingController(text: _init.name);
  late final _phone = TextEditingController(text: _init.phone);
  late final _address = TextEditingController(text: _init.address);
  late final _tech = TextEditingController(text: _init.technician);
  late String? _logo = _init.logoPath;

  @override
  void dispose() {
    for (final c in [_name, _phone, _address, _tech]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickLogo() async {
    try {
      final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 800, maxHeight: 800);
      if (x == null) return;
      final dir = await getApplicationDocumentsDirectory();
      final ext = x.path.contains('.') ? x.path.substring(x.path.lastIndexOf('.')) : '.png';
      // ชื่อไฟล์ใหม่ทุกครั้ง เพื่อไม่ให้รูปเก่าค้างในแคช
      final dest = File('${dir.path}/shop_logo_${DateTime.now().millisecondsSinceEpoch}$ext');
      await dest.writeAsBytes(await x.readAsBytes(), flush: true);
      if (mounted) setState(() => _logo = dest.path);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('เลือกรูปไม่สำเร็จ: $e')));
    }
  }

  void _save() {
    // ลบไฟล์โลโก้เก่าเฉพาะตอนบันทึก (ถ้ากดย้อนกลับ โลโก้เดิมยังอยู่)
    final old = _init.logoPath;
    if (old != null && old != _logo) {
      try {
        File(old).deleteSync();
      } catch (_) {}
    }
    ref.read(settingsProvider.notifier).setShop(ShopProfile(
          name: _name.text.trim(),
          phone: _phone.text.trim(),
          address: _address.text.trim(),
          technician: _tech.text.trim(),
          logoPath: _logo,
        ));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final logo = _logo;
    return Scaffold(
      appBar: AppBar(title: const FitText('ข้อมูลอู่ / ผู้ตรวจ'), actions: [
        TextButton(onPressed: _save, child: const Text('บันทึก')),
      ]),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
        PremiumCard(
          child: Row(children: [
            Container(
              width: 84,
              height: 84,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(18),
              ),
              child: logo != null && File(logo).existsSync()
                  ? Image.file(File(logo), fit: BoxFit.contain)
                  : Icon(Icons.storefront_rounded, size: 40, color: cs.onSurfaceVariant),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('โลโก้อู่', style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                Wrap(spacing: 8, children: [
                  OutlinedButton(onPressed: _pickLogo, child: const Text('เลือกรูป')),
                  if (logo != null) TextButton(onPressed: () => setState(() => _logo = null), child: const Text('เอาออก')),
                ]),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 14),
        TextField(controller: _name, decoration: const InputDecoration(labelText: 'ชื่ออู่ / ร้าน')),
        const SizedBox(height: 10),
        TextField(controller: _phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'เบอร์โทร')),
        const SizedBox(height: 10),
        TextField(controller: _address, maxLines: 2, decoration: const InputDecoration(labelText: 'ที่อยู่')),
        const SizedBox(height: 10),
        TextField(controller: _tech, decoration: const InputDecoration(labelText: 'ชื่อผู้ตรวจ (แสดงในรายงาน)')),
        const SizedBox(height: 18),
        FilledButton(onPressed: _save, child: const Text('บันทึก')),
        const SizedBox(height: 10),
        Text('ข้อมูลนี้เก็บในเครื่องเท่านั้น และแสดงบนหัวรายงาน PDF ที่ส่งให้ลูกค้า',
            textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
      ]),
    );
  }
}

/// เกณฑ์แจ้งเตือนค่าผิดปกติขณะดูค่าสด/ขับ
class AlertSettingsScreen extends ConsumerWidget {
  const AlertSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = ref.watch(settingsProvider.select((s) => s.alerts));
    final set = ref.read(settingsProvider.notifier).setAlerts;
    final cs = Theme.of(context).colorScheme;
    Widget slider(String label, double value, double min, double max, int div, String Function(double) fmt,
            void Function(double) onChanged) =>
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600))),
              Text(value <= 0 ? 'ปิด' : fmt(value), style: TextStyle(fontWeight: FontWeight.w800, color: cs.primary)),
            ]),
            Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: div,
              onChanged: a.enabled ? onChanged : null,
            ),
          ]),
        );

    return Scaffold(
      appBar: AppBar(title: const FitText('แจ้งเตือนค่าผิดปกติ')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
        PremiumCard(
          child: Column(children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('เปิดการแจ้งเตือน', style: TextStyle(fontWeight: FontWeight.w700)),
              subtitle: const Text('สั่นและแสดงแถบสีแดงเมื่อค่าเกินเกณฑ์ ขณะเปิดค่าสด แดชบอร์ด หรือกำลังบันทึก'),
              value: a.enabled,
              onChanged: (v) => set(a.copyWith(enabled: v)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: Icon(Icons.record_voice_over_rounded, color: cs.primary),
              title: const Text('เตือนด้วยเสียงพูดภาษาไทย', style: TextStyle(fontWeight: FontWeight.w700)),
              subtitle: const Text('เช่น "ระวัง ความร้อนเครื่องสูง 108 องศา" ไม่ต้องละสายตาจากถนน'),
              value: a.voice,
              onChanged: a.enabled ? (v) => set(a.copyWith(voice: v)) : null,
            ),
            if (a.enabled && a.voice)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.volume_up_rounded),
                  label: const Text('ทดลองฟังเสียง'),
                  onPressed: () async {
                    final voice = ref.read(voiceServiceProvider);
                    final status = await voice.check();
                    if (status == VoiceStatus.ready) {
                      await voice.speak('ระวัง ความร้อนเครื่องสูง 108 องศา ควรจอดพักเครื่อง');
                    } else if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(status == VoiceStatus.noThai
                            ? 'เครื่องนี้ยังไม่มีเสียงภาษาไทย ไปที่ การตั้งค่า > เอาต์พุตการอ่านออกเสียง เลือก Google และดาวน์โหลดเสียงภาษาไทย'
                            : 'เครื่องนี้ไม่มีระบบอ่านออกเสียง ติดตั้งแอป "Google Text-to-Speech" จาก Play Store'),
                        duration: const Duration(seconds: 6),
                      ));
                    }
                  },
                ),
              ),
            slider('ความร้อนเครื่องสูงกว่า', a.coolantMax, 90, 125, 35, (v) => '${v.round()} °C',
                (v) => set(a.copyWith(coolantMax: v.roundToDouble()))),
            slider('ไฟชาร์จต่ำกว่า (ขณะเครื่องติด)', a.voltLow, 11.5, 13.5, 20, (v) => '${v.toStringAsFixed(1)} V',
                (v) => set(a.copyWith(voltLow: double.parse(v.toStringAsFixed(1))))),
            slider('ไฟชาร์จสูงกว่า', a.voltHigh, 14.5, 16, 15, (v) => '${v.toStringAsFixed(1)} V',
                (v) => set(a.copyWith(voltHigh: double.parse(v.toStringAsFixed(1))))),
            slider('รอบเครื่องเกิน (0 = ปิด)', a.rpmMax, 0, 8000, 32, (v) => '${v.round()} รอบ',
                (v) => set(a.copyWith(rpmMax: v.roundToDouble()))),
            slider('บูสต์เทอร์โบเกิน แบบเกจ (0 = ปิด)', a.boostMax, 0, 250, 25, (v) => '${v.round()} kPa',
                (v) => set(a.copyWith(boostMax: v.roundToDouble()))),
          ]),
        ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: () {
            set(const AlertLimits());
            HapticFeedback.selectionClick();
          },
          child: const Text('คืนค่าเริ่มต้น'),
        ),
      ]),
    );
  }
}
