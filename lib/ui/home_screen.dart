import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/obd/obd_service.dart';
import '../state/live_poller.dart';
import '../state/providers.dart';
import 'connect_screen.dart';
import 'diagnosis_tab.dart';
import 'dtc_lookup_screen.dart';
import 'garage_tab.dart';
import 'home_tab.dart';
import 'live_data_tab.dart';
import 'settings_tab.dart';
import 'theme.dart';
import 'vehicle_identity.dart';

/// โครงหลักของแอป: 5 แท็บ
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => HomeScreenState();
}

class HomeScreenState extends ConsumerState<HomeScreen> {
  int _tab = 0;

  static const _titles = ['หน้าหลัก', 'วินิจฉัย', 'ค่าสด', 'โรงรถ', 'ตั้งค่า'];

  /// ให้หน้าลูกสลับแท็บได้ เช่น ปุ่ม "สแกน" บนหน้าหลัก
  void goTab(int i) => setState(() => _tab = i);

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final cs = Theme.of(context).colorScheme;

    // แจ้งเตือนเมื่อการเชื่อมต่อหลุดกลางทาง และเมื่อระบุรถได้อัตโนมัติ
    ref.listen(sessionProvider, (prev, next) {
      final messenger = ScaffoldMessenger.of(context);
      if (prev?.status == ConnStatus.connected && next.status == ConnStatus.failed) {
        messenger.showSnackBar(SnackBar(content: Text('การเชื่อมต่อหลุด: ${next.message ?? ''}')));
        return;
      }
      if (next.isConnected && next.vehicleId != null && prev?.vehicleId != next.vehicleId) {
        final v = ref.read(garageProvider.notifier).byId(next.vehicleId);
        if (v == null) return;
        final spec = vehicleSpecLine(v);
        final practice = next.isPractice;
        messenger.showSnackBar(SnackBar(
          duration: const Duration(seconds: 6),
          // Flutter รุ่นใหม่ให้แถบที่มีปุ่มค้างจนกว่าจะกด ซึ่งจะบังล่างจอทุกหน้า: ให้หายเองตามเวลา
          persist: false,
          content: Row(children: [
            BrandBadge(make: v.make, size: 30),
            const SizedBox(width: 12),
            Expanded(
              child: Text(practice
                  ? 'โหมดทดลอง: ${v.title} (รถจำลอง ผลสแกนไม่ถูกบันทึกลงโรงรถ)'
                  : '${next.newVehicle ? 'พบรถใหม่' : 'รู้จักรถคันนี้'}: ${v.title}${spec.isEmpty ? '' : '\u00A0· $spec'}'),
            ),
          ]),
          action: v.needsModel && !practice
              ? SnackBarAction(label: 'เลือกรุ่น', onPressed: () => editIdentitySheet(context, ref, v))
              : null,
        ));
      } else if (prev?.isConnected != true && next.isConnected && next.vin == null) {
        messenger.showSnackBar(SnackBar(
          duration: const Duration(seconds: 8),
          persist: false,
          content: const Text('รถคันนี้ไม่ส่ง VIN แตะ "เลือกรถ" ที่หน้าหลักเพื่อบันทึกผลเข้ารถในโรงรถ'),
          action: SnackBarAction(label: 'เลือกรถ', onPressed: () => chooseVehicleSheet(context, ref)),
        ));
      }
    });

    // ใช้ switch แทน IndexedStack เพื่อให้แท็บค่าสดหยุดอ่านข้อมูลเมื่อออกจากแท็บ
    final body = switch (_tab) {
      0 => HomeTab(onGoTab: goTab),
      1 => const DiagnosisTab(),
      2 => const LiveDataTab(),
      3 => const GarageTab(),
      _ => const SettingsTab(),
    };

    // จอแคบหรือตั้งตัวอักษรใหญ่: ป้ายสถานะการเชื่อมต่อใช้คำสั้น เหลือที่ให้ชื่อหน้าและชื่อแอป
    final textScale = MediaQuery.textScalerOf(context).scale(100) / 100;
    final compact = MediaQuery.sizeOf(context).width / textScale < 400;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: compact ? 14 : 20,
        title: Row(children: [
          const BrandMark(size: 30),
          SizedBox(width: compact ? 10 : 12),
          // ชื่อหน้าและ PROSCANER แสดงครบเสมอ: ถ้าที่ไม่พอ ย่อลงทั้งก้อน ไม่ตัดคำ
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_titles[_tab], maxLines: 1, softWrap: false),
                Text('PROSCANER',
                    maxLines: 1,
                    softWrap: false,
                    style: TextStyle(fontSize: 10, letterSpacing: 2.4, fontWeight: FontWeight.w800, color: cs.primary)),
              ]),
            ),
          ),
        ]),
        actions: [
          IconButton(
            tooltip: 'ค้นหารหัสปัญหา',
            icon: const Icon(Icons.manage_search_rounded),
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => const DtcLookupScreen())),
          ),
          Padding(
            padding: EdgeInsets.only(right: compact ? 10 : 12),
            child: ConnectionChip(session: session, compact: compact),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(children: [
          const GlobalBanners(),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: KeyedSubtree(key: ValueKey(_tab), child: body),
            ),
          ),
        ]),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: goTab,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard_rounded), label: 'หน้าหลัก'),
          NavigationDestination(
              icon: Icon(Icons.health_and_safety_outlined), selectedIcon: Icon(Icons.health_and_safety_rounded), label: 'วินิจฉัย'),
          NavigationDestination(icon: Icon(Icons.speed_outlined), selectedIcon: Icon(Icons.speed_rounded), label: 'ค่าสด'),
          NavigationDestination(icon: Icon(Icons.garage_outlined), selectedIcon: Icon(Icons.garage_rounded), label: 'โรงรถ'),
          NavigationDestination(icon: Icon(Icons.tune_outlined), selectedIcon: Icon(Icons.tune_rounded), label: 'ตั้งค่า'),
        ],
      ),
    );
  }
}

/// โลโก้แอป ProScaner (ไอคอนคาร์บอน + PRO โครเมียม)
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 32});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.24),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 10, spreadRadius: -2)],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.24),
        child: Image.asset('assets/brand/app_icon.png', width: size, height: size, filterQuality: FilterQuality.high),
      ),
    );
  }
}

class ConnectionChip extends StatelessWidget {
  const ConnectionChip({super.key, required this.session, this.compact = false});

  final SessionState session;

  /// จอแคบ: ใช้คำสั้น (ความหมายเดิม) ให้หัวแอปมีที่แสดงชื่อหน้าเต็ม
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (label, color, icon) = switch (session.status) {
      ConnStatus.connected => (
          session.isPractice ? (compact ? 'ทดลอง' : 'โหมดทดลอง') : 'เชื่อมต่อ',
          const Color(0xFF22C474),
          Icons.link_rounded
        ),
      ConnStatus.connecting => ('กำลังต่อ', cs.primary, Icons.sync_rounded),
      ConnStatus.failed => ('หลุด', const Color(0xFFFF4D5A), Icons.link_off_rounded),
      ConnStatus.disconnected => (compact ? 'ไม่ได้ต่อ' : 'ไม่ได้เชื่อมต่อ', cs.onSurfaceVariant, Icons.link_off_rounded),
    };
    return InkWell(
      borderRadius: BorderRadius.circular(30),
      onTap: () => openConnect(context),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 12, vertical: 7),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12.5)),
        ]),
      ),
    );
  }
}

/// เปิดหน้าเชื่อมต่อ [reconnect] = เชื่อมต่อตัวสแกนล่าสุดทันที
void openConnect(BuildContext context, {bool reconnect = false}) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ConnectScreen(reconnectLast: reconnect)));

/// ห่อหน้าจอที่ต้องเชื่อมต่อรถก่อน
class NeedsConnection extends ConsumerWidget {
  const NeedsConnection({super.key, required this.message, required this.builder});

  final String message;
  final Widget Function(BuildContext context, ObdService service) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    if (!session.isConnected) return ConnectPrompt(message: message);
    return builder(context, session.service!);
  }
}

/// แถบแจ้งเตือนค่าผิดปกติ และแถบกำลังบันทึก แสดงด้านบนทุกแท็บ
class GlobalBanners extends ConsumerWidget {
  const GlobalBanners({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alert = ref.watch(liveDataProvider.select((l) => l.alert));
    final rec = ref.watch(recorderProvider);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      if (alert != null)
        _Banner(
          color: const Color(0xFFFF4D5A),
          icon: Icons.warning_rounded,
          text: alert,
          action: 'รับทราบ',
          onAction: () => ref.read(liveDataProvider.notifier).dismissAlert(),
        ),
      if (rec.recording)
        _Banner(
          color: const Color(0xFFFF8A1F),
          icon: Icons.fiber_manual_record_rounded,
          text: 'กำลังบันทึก ${rec.pids.length}\u00A0ค่า\u00A0· ${rec.rows}\u00A0แถว',
          action: 'หยุดและบันทึก',
          onAction: () async {
            final log = await ref.read(recorderProvider.notifier).stop();
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(log == null ? 'ไม่มีข้อมูลให้บันทึก' : 'บันทึก "${log.name}" แล้ว ดูได้ที่ บันทึกการขับ'),
              ));
            }
          },
        ),
    ]);
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.color, required this.icon, required this.text, required this.action, required this.onAction});

  final Color color;
  final IconData icon;
  final String text;
  final String action;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Row(children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 10),
        Expanded(child: Text(thaiKeep(text), style: TextStyle(fontWeight: FontWeight.w700, color: color))),
        TextButton(onPressed: onAction, child: Text(action, style: TextStyle(color: color, fontWeight: FontWeight.w800))),
      ]),
    );
  }
}

/// การ์ดชวนเชื่อมต่อ ใช้ในแท็บที่ต้องมีตัวสแกน
class ConnectPrompt extends StatelessWidget {
  const ConnectPrompt({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
      PremiumCard(
        glow: cs.primary,
        padding: const EdgeInsets.fromLTRB(22, 30, 22, 24),
        child: Column(children: [
          Container(
            width: 104,
            height: 104,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(colors: [cs.primary.withValues(alpha: 0.35), cs.primary.withValues(alpha: 0.0)]),
            ),
            child: Icon(Icons.bluetooth_searching_rounded, size: 50, color: cs.primary),
          ),
          const SizedBox(height: 16),
          Text(thaiKeep(message),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 22),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              icon: const Icon(Icons.link_rounded),
              label: const Text('เชื่อมต่อตัวสแกน'),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 58)),
              onPressed: () => openConnect(context),
            ),
          ),
        ]),
      ),
      const SectionLabel('เริ่มใช้งานใน 3 ขั้น'),
      const _Step(n: 1, title: 'เสียบตัวสแกน', text: 'ช่อง OBD-II อยู่ใต้คอนโซลฝั่งคนขับ ใกล้หัวเข่าขวา'),
      const _Step(n: 2, title: 'บิดกุญแจไปที่ ON', text: 'หรือติดเครื่องยนต์ เพื่อให้กล่อง ECU ทำงาน'),
      const _Step(n: 3, title: 'เชื่อมต่อในแอป', text: 'เลือก Bluetooth หรือ Wi-Fi ตามรุ่นตัวสแกน หรือลองโหมดทดลองก่อน'),
    ]);
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.n, required this.title, required this.text});

  final int n;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: PremiumCard(
        padding: const EdgeInsets.all(14),
        radius: 18,
        child: Row(children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: cs.primary.withValues(alpha: 0.15), shape: BoxShape.circle),
            child: Text('$n', style: TextStyle(fontWeight: FontWeight.w800, color: cs.primary)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(thaiKeep(text), style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant, height: 1.4)),
            ]),
          ),
        ]),
      ),
    );
  }
}
