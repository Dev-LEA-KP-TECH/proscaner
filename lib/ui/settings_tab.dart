import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_info.dart';
import '../state/providers.dart';
import 'backup_screen.dart';
import 'comm_log_screen.dart';
import 'connect_screen.dart';
import 'dtc_lookup_screen.dart';
import 'home_screen.dart';
import 'settings_screens.dart';
import 'terminal_screen.dart';
import 'theme.dart';

class SettingsTab extends ConsumerWidget {
  const SettingsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(appModeProvider);
    final settings = ref.watch(settingsProvider);
    final setter = ref.read(settingsProvider.notifier);
    final session = ref.watch(sessionProvider);
    final commLogOn = ref.watch(commLogEnabledProvider);
    final elm = session.elm;
    final cs = Theme.of(context).colorScheme;
    // จอแคบ/ตัวอักษรใหญ่: ปุ่มเลือกธีมไม่มีไอคอน ให้ชื่อปุ่มอ่านครบบรรทัดเดียว
    final narrow = isNarrow(context);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      children: [
        const SectionLabel('โหมดการใช้งาน'),
        Row(children: [
          Expanded(
            child: _ModeCard(
              icon: Icons.person_rounded,
              title: 'เจ้าของรถ',
              text: 'สรุปง่าย บอกว่าขับต่อได้ไหม',
              selected: mode == AppMode.owner,
              onTap: () => ref.read(appModeProvider.notifier).set(AppMode.owner),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _ModeCard(
              icon: Icons.engineering_rounded,
              title: 'ช่าง',
              // ขึ้นบรรทัดใหม่ก่อนคำทับศัพท์ ไม่ให้ระบบตัดกลางคำ (เช่น "เท/อร์มินัล") บนจอแคบ
              text: 'ค่าดิบ กราฟ Freeze Frame\nเทอร์มินัล',
              selected: mode == AppMode.mechanic,
              onTap: () => ref.read(appModeProvider.notifier).set(AppMode.mechanic),
            ),
          ),
        ]),

        const SectionLabel('ธีม'),
        PremiumCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<ThemeMode>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(
                      value: ThemeMode.dark,
                      icon: narrow ? null : const Icon(Icons.dark_mode_rounded),
                      label: const FitText('มืด', alignment: Alignment.center)),
                  ButtonSegment(
                      value: ThemeMode.light,
                      icon: narrow ? null : const Icon(Icons.light_mode_rounded),
                      label: const FitText('สว่าง', alignment: Alignment.center)),
                  ButtonSegment(
                      value: ThemeMode.system,
                      icon: narrow ? null : const Icon(Icons.brightness_auto_rounded),
                      label: const FitText('ตามเครื่อง', alignment: Alignment.center)),
                ],
                selected: {settings.themeMode},
                onSelectionChanged: (s) => setter.setThemeMode(s.first),
              ),
            ),
            const SizedBox(height: 18),
            Text('สีเน้น\u00A0· ${settings.accent.labelTh}', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
            const SizedBox(height: 12),
            Wrap(spacing: 12, runSpacing: 12, children: [
              for (final a in AccentPreset.values)
                _Swatch(color: a.color, selected: a == settings.accent, onTap: () => setter.setAccent(a)),
            ]),
          ]),
        ),

        const SectionLabel('หน่วยวัด'),
        PremiumCard(
          child: Column(children: [
            _UnitRow(
              icon: Icons.thermostat_rounded,
              label: 'อุณหภูมิ',
              child: SegmentedButton<TempUnit>(
                showSelectedIcon: false,
                segments: [for (final u in TempUnit.values) ButtonSegment(value: u, label: FitText(u.label, alignment: Alignment.center))],
                selected: {settings.tempUnit},
                onSelectionChanged: (s) => setter.setTempUnit(s.first),
              ),
            ),
            const SizedBox(height: 12),
            _UnitRow(
              icon: Icons.speed_rounded,
              label: 'ความเร็ว',
              child: SegmentedButton<SpeedUnit>(
                showSelectedIcon: false,
                segments: [for (final u in SpeedUnit.values) ButtonSegment(value: u, label: FitText(u.label, alignment: Alignment.center))],
                selected: {settings.speedUnit},
                onSelectionChanged: (s) => setter.setSpeedUnit(s.first),
              ),
            ),
          ]),
        ),

        const SectionLabel('ตัวสแกน'),
        PremiumCard(
          glow: session.isConnected ? const Color(0xFF22C474) : null,
          child: !session.isConnected
              ? Row(children: [
                  Icon(Icons.link_off_rounded, color: cs.onSurfaceVariant),
                  const SizedBox(width: 12),
                  const Expanded(child: Text('ยังไม่ได้เชื่อมต่อ')),
                  FilledButton(
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                    onPressed: () => Navigator.of(context)
                        .push(MaterialPageRoute<void>(builder: (_) => const ConnectScreen())),
                    child: const Text('เชื่อมต่อ'),
                  ),
                ])
              : Column(children: [
                  _row(context, 'การเชื่อมต่อ', session.transport?.displayName ?? '-'),
                  _row(context, 'ตัวสแกน', session.adapter?.kind.labelTh ?? '-'),
                  _row(context, 'รุ่นชิป', session.adapter?.stnVersion ?? elm?.version ?? '-'),
                  _row(context, 'โปรโตคอลรถ', elm?.protocolLabel ?? '-'),
                  _row(context, 'PID ที่รองรับ', '${session.service?.supported.length ?? 0}\u00A0รายการ'),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.link_off_rounded),
                      label: const Text('ตัดการเชื่อมต่อ'),
                      onPressed: () => ref.read(sessionProvider.notifier).disconnect(),
                    ),
                  ),
                ]),
        ),

        const SectionLabel('ปรับแต่ง'),
        _ToolTile(
          icon: Icons.storefront_rounded,
          title: 'ข้อมูลอู่ / ผู้ตรวจ',
          subtitle: settings.shop.name.isEmpty ? 'ใส่ชื่อ โลโก้ เบอร์โทร เพื่อแสดงบนรายงาน PDF' : settings.shop.name,
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ShopProfileScreen())),
        ),
        _ToolTile(
          icon: Icons.notifications_active_rounded,
          title: 'แจ้งเตือนค่าผิดปกติ',
          subtitle: settings.alerts.enabled
              ? 'ความร้อน ${settings.alerts.coolantMax.round()}\u00A0°C\u00A0· ไฟชาร์จ ${settings.alerts.voltLow}–${settings.alerts.voltHigh}\u00A0V'
              : 'ปิดอยู่',
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AlertSettingsScreen())),
        ),
        const SectionLabel('เครื่องมือ'),
        _ToolTile(
          icon: Icons.manage_search_rounded,
          title: 'ค้นหารหัสปัญหา',
          subtitle: 'ดูความหมาย สาเหตุ และวิธีตรวจ แบบออฟไลน์',
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DtcLookupScreen())),
        ),
        if (mode == AppMode.mechanic)
          _ToolTile(
            icon: Icons.terminal_rounded,
            title: 'เทอร์มินัลตัวสแกน',
            subtitle: 'ส่งคำสั่ง AT หรือ OBD เอง และดู log การสื่อสาร',
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const TerminalScreen())),
          ),
        _ToolTile(
          icon: Icons.delete_sweep_rounded,
          title: 'ล้างประวัติการสแกน',
          subtitle: 'ลบผลสแกนที่บันทึกไว้ในเครื่องนี้',
          danger: true,
          onTap: () async {
            final ok = await showDialog<bool>(
              context: context,
              builder: (c) => AlertDialog(
                title: const Text('ล้างประวัติทั้งหมด?'),
                content: const Text('ลบผลสแกนที่บันทึกไว้ในเครื่องนี้ทั้งหมด กู้คืนไม่ได้'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('ยกเลิก')),
                  TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('ล้าง')),
                ],
              ),
            );
            if (ok == true) {
              await ref.read(historyStoreProvider).clear();
              ref.invalidate(historyProvider);
            }
          },
        ),

        const SectionLabel('ข้อมูลและบันทึก'),
        _ToolTile(
          icon: Icons.settings_backup_restore_rounded,
          title: 'สำรอง / กู้คืนข้อมูล',
          subtitle: 'รถ ประวัติสแกน ชุดค่า ข้อมูลอู่ ในไฟล์เดียว ย้ายเครื่องหรือกันข้อมูลหาย',
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const BackupScreen())),
        ),
        _ToolTile(
          icon: Icons.receipt_long_rounded,
          title: 'บันทึกการสื่อสาร',
          subtitle: commLogOn ? 'เปิดอยู่\u00A0· ส่งให้ผู้พัฒนาเมื่ออ่านค่ารถไม่ได้' : 'ปิดอยู่',
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const CommLogScreen())),
        ),

        const SectionLabel('เกี่ยวกับแอปพลิเคชัน'),
        PremiumCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const BrandMark(size: 48),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const FitText('ProScaner', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900)),
                  Text('เวอร์ชัน $kAppVersion', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5)),
                ]),
              ),
            ]),
            const SizedBox(height: 14),
            for (final (i, p) in kAboutParagraphs.indexed) ...[
              if (i > 0) const SizedBox(height: 10),
              Text(thaiKeep(p), style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant, height: 1.55)),
            ],
            const SizedBox(height: 14),
            Divider(color: cs.outline, height: 1),
            const SizedBox(height: 14),
            Text('ผู้พัฒนาและเจ้าของลิขสิทธิ์',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant, fontWeight: FontWeight.w700, letterSpacing: 0.2)),
            const SizedBox(height: 4),
            const Text(kDeveloperName, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, height: 1.35)),
            const SizedBox(height: 10),
            Text(kCopyrightLine,
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant, letterSpacing: 0.6, fontWeight: FontWeight.w600)),
          ]),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 110,
            child: Text(k, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ),
          Expanded(child: Text(v, style: const TextStyle(fontWeight: FontWeight.w700))),
        ]),
      );
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.icon,
    required this.title,
    required this.text,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String text;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return PremiumCard(
      glow: selected ? cs.primary : null,
      onTap: onTap,
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, color: selected ? cs.primary : cs.onSurfaceVariant, size: 28),
          const Spacer(),
          Icon(
            selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
            color: selected ? cs.primary : cs.onSurfaceVariant,
            size: 20,
          ),
        ]),
        const SizedBox(height: 12),
        Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
        const SizedBox(height: 4),
        Text(text, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant, height: 1.35)),
      ]),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.color, required this.selected, required this.onTap});

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [color, Color.lerp(color, Colors.black, 0.4)!],
          ),
          border: Border.all(
            color: selected ? Theme.of(context).colorScheme.onSurface : Colors.transparent,
            width: 2.5,
          ),
          boxShadow: [if (selected) BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 14)],
        ),
        child: selected ? const Icon(Icons.check_rounded, color: Colors.white, size: 22) : null,
      ),
    );
  }
}

class _UnitRow extends StatelessWidget {
  const _UnitRow({required this.icon, required this.label, required this.child});

  final IconData icon;
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final head = Row(children: [
      Icon(icon, color: Theme.of(context).colorScheme.onSurfaceVariant),
      const SizedBox(width: 10),
      Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600))),
    ]);
    // จอแคบ/ตัวอักษรใหญ่: ปุ่มเลือกหน่วยลงไปอยู่ใต้ชื่อ เต็มความกว้าง (ไม่บีบชื่อจนหักคำ)
    return LayoutBuilder(builder: (context, box) {
      final textScale = MediaQuery.textScalerOf(context).scale(100) / 100;
      if (box.maxWidth / textScale >= 330) {
        return Row(children: [Expanded(child: head), child]);
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [head, const SizedBox(height: 8), child]);
    });
  }
}

class _ToolTile extends StatelessWidget {
  const _ToolTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final c = danger ? const Color(0xFFFF4D5A) : cs.primary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: PremiumCard(
        onTap: onTap,
        padding: const EdgeInsets.all(14),
        radius: 18,
        child: Row(children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(color: c.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(12)),
            child: Icon(icon, color: c),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(fontWeight: FontWeight.w700, color: danger ? c : null)),
              const SizedBox(height: 2),
              Text(subtitle, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            ]),
          ),
          Icon(Icons.chevron_right_rounded, color: cs.onSurfaceVariant),
        ]),
      ),
    );
  }
}
