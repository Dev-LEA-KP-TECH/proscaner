import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/transport/adapter_memory.dart';
import '../core/transport/ble_transport.dart';
import '../core/transport/classic_transport.dart';
import '../core/transport/demo_transport.dart';
import '../core/transport/obd_transport.dart';
import '../core/transport/wifi_transport.dart';
import '../state/providers.dart';
import 'theme.dart';
import 'widgets/common.dart';

/// หน้าเชื่อมต่อตัวสแกน: Bluetooth (ธรรมดา + BLE), Wi-Fi, โหมดทดลอง
/// และปุ่มเชื่อมต่อตัวสแกนล่าสุดด้วยการแตะครั้งเดียว
class ConnectScreen extends ConsumerStatefulWidget {
  const ConnectScreen({super.key, this.reconnectLast = false});

  /// เปิดหน้าแล้วเชื่อมต่อตัวสแกนล่าสุดทันที
  final bool reconnectLast;

  @override
  ConsumerState<ConnectScreen> createState() => _ConnectScreenState();
}

enum _Tab { bluetooth, wifi, demo }

class _ConnectScreenState extends ConsumerState<ConnectScreen> {
  _Tab _tab = _Tab.bluetooth;
  bool _starting = false;
  final _host = TextEditingController(text: WifiTransport.defaultHost);
  final _port = TextEditingController(text: '${WifiTransport.defaultPort}');

  @override
  void initState() {
    super.initState();
    final last = ref.read(lastAdapterProvider);
    if (last != null && last.kind == TransportKind.wifi) {
      _tab = _Tab.wifi;
      _host.text = last.id;
      _port.text = '${last.port ?? WifiTransport.defaultPort}';
    }
    if (widget.reconnectLast && last != null) {
      _starting = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _connect(last.build()));
    }
  }

  @override
  void dispose() {
    BleTransport.stopScan();
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  Future<void> _connect(ObdTransport t) async {
    if (mounted && !_starting) setState(() => _starting = true);
    await BleTransport.stopScan();
    await ref.read(sessionProvider.notifier).connect(t);
    if (!mounted) return;
    setState(() => _starting = false);
    if (ref.read(sessionProvider).isConnected) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final busy = _starting || session.status == ConnStatus.connecting;
    final last = ref.watch(lastAdapterProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('เชื่อมต่อตัวสแกน')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          if (busy)
            _Progress(
              message: session.status == ConnStatus.connecting ? (session.message ?? '') : 'กำลังเริ่มเชื่อมต่อ…',
              onCancel: () {
                ref.read(sessionProvider.notifier).disconnect();
                setState(() => _starting = false);
              },
            )
          else ...[
            if (last != null)
              _LastAdapterCard(
                memento: last,
                onConnect: () => _connect(last.build()),
                onForget: () => ref.read(lastAdapterProvider.notifier).forget(),
              ),
            if (session.status == ConnStatus.failed && session.message != null) _ErrorCard(message: session.message!),
            const SizedBox(height: 12),
            SegmentedButton<_Tab>(
              segments: const [
                ButtonSegment(value: _Tab.bluetooth, icon: Icon(Icons.bluetooth), label: Text('Bluetooth')),
                ButtonSegment(value: _Tab.wifi, icon: Icon(Icons.wifi), label: Text('Wi-Fi')),
                ButtonSegment(value: _Tab.demo, icon: Icon(Icons.science_outlined), label: Text('ทดลอง')),
              ],
              selected: {_tab},
              onSelectionChanged: (s) => setState(() => _tab = s.first),
            ),
            const SizedBox(height: 16),
            switch (_tab) {
              _Tab.bluetooth => _BluetoothPanel(onConnect: _connect),
              _Tab.wifi => _WifiPanel(
                  host: _host,
                  port: _port,
                  onConnect: () => _connect(WifiTransport(
                    host: _host.text.trim().isEmpty ? WifiTransport.defaultHost : _host.text.trim(),
                    port: int.tryParse(_port.text.trim()) ?? WifiTransport.defaultPort,
                  )),
                ),
              _Tab.demo => _DemoPanel(onConnect: () => _connect(DemoTransport(practice: true))),
            },
          ],
        ],
      ),
    );
  }
}

class _LastAdapterCard extends StatelessWidget {
  const _LastAdapterCard({required this.memento, required this.onConnect, required this.onForget});

  final AdapterMemento memento;
  final VoidCallback onConnect;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final icon = switch (memento.kind) {
      TransportKind.wifi => Icons.wifi_rounded,
      TransportKind.ble => Icons.bluetooth_searching_rounded,
      _ => Icons.bluetooth_rounded,
    };
    return PremiumCard(
      glow: cs.primary,
      radius: 18,
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      child: Row(children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(color: cs.primary.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(14)),
          child: Icon(icon, color: cs.primary),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('ตัวสแกนล่าสุด', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            Text(memento.label,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5)),
            Text(memento.kindLabel, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          ]),
        ),
        FilledButton(onPressed: onConnect, child: const Text('เชื่อมต่อ')),
        PopupMenuButton<String>(
          onSelected: (_) => onForget(),
          itemBuilder: (_) => const [PopupMenuItem(value: 'forget', child: Text('ลืมตัวสแกนนี้'))],
        ),
      ]),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(top: 12),
      color: cs.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.error_outline_rounded, color: cs.onErrorContainer),
            const SizedBox(width: 8),
            Text('เชื่อมต่อไม่สำเร็จ', style: TextStyle(fontWeight: FontWeight.w800, color: cs.onErrorContainer)),
          ]),
          const SizedBox(height: 6),
          Text(message, style: TextStyle(color: cs.onErrorContainer, height: 1.4)),
          const SizedBox(height: 8),
          Text(
            'ลองตรวจ: บิดกุญแจ ON หรือติดเครื่อง · เสียบตัวสแกนให้แน่น (ไฟที่ตัวสแกนต้องติด) · '
            'ปิดแอป OBD อื่นที่อาจต่อค้างอยู่ · ถอดตัวสแกนออกแล้วเสียบใหม่',
            style: TextStyle(color: cs.onErrorContainer.withValues(alpha: 0.85), fontSize: 12.5, height: 1.4),
          ),
        ]),
      ),
    );
  }
}

class _Progress extends ConsumerWidget {
  const _Progress({required this.message, required this.onCancel});

  final String message;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final log = ref.watch(logProvider);
    final tail = log.length > 8 ? log.sublist(log.length - 8) : log;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 8),
      const LinearProgressIndicator(),
      const SizedBox(height: 14),
      Text(message, style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 4),
      Text('ครั้งแรกอาจใช้เวลาถึง 20 วินาทีระหว่างตัวสแกนค้นหาโปรโตคอลของรถ '
          'ถ้าตัวสแกนค้นหาเองไม่เจอ แอปจะลองทีละโปรโตคอลให้ (อาจนานถึง 1 นาที)',
          style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 12),
      for (final l in tail) Text(l, style: const TextStyle(fontFamily: kMono, fontSize: 12)),
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(icon: const Icon(Icons.close_rounded), label: const Text('ยกเลิก'), onPressed: onCancel),
      ),
    ]);
  }
}

// ---------------- Bluetooth ----------------

class _BluetoothPanel extends StatefulWidget {
  const _BluetoothPanel({required this.onConnect});

  final Future<void> Function(ObdTransport) onConnect;

  @override
  State<_BluetoothPanel> createState() => _BluetoothPanelState();
}

class _BluetoothPanelState extends State<_BluetoothPanel> {
  String? _error;
  String? _hint;
  bool _preparing = true;
  bool _discovering = false;
  List<ClassicDevice> _paired = const [];
  final _nearby = <String, ClassicDevice>{};
  StreamSubscription<ClassicDevice?>? _discovery;

  bool get _android => ClassicBtTransport.supported;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _discovery?.cancel();
    BleTransport.stopScan();
    super.dispose();
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _error = message;
      _preparing = false;
    });
  }

  Future<void> _start() async {
    setState(() {
      _error = null;
      _hint = null;
      _preparing = true;
    });
    try {
      if (_android) {
        // ขอสิทธิ์ครั้งเดียวก่อน ไม่ให้หน้าต่างขอสิทธิ์ซ้อนกัน
        final granted = await ClassicBtTransport.ensurePermissions(scan: true);
        if (!mounted) return;
        if (!granted) {
          _fail('ต้องอนุญาตสิทธิ์ "อุปกรณ์ใกล้เคียง" (Bluetooth) ให้แอปก่อน จึงจะค้นหาตัวสแกนได้ '
              'กด "ค้นหาอีกครั้ง" แล้วเลือกอนุญาต หรือเปิดสิทธิ์ในการตั้งค่าแอป');
          return;
        }
        if (!await ClassicBtTransport.isEnabled()) {
          // รอผลจากหน้าต่าง "อนุญาตให้เปิด Bluetooth" ถ้าผู้ใช้ปฏิเสธ แจ้งทันที ไม่ต้องหมุนรอ
          final turnedOn = await ClassicBtTransport.requestEnable();
          if (!mounted) return;
          if (!turnedOn) {
            _fail('Bluetooth ปิดอยู่ เปิด Bluetooth แล้วกด "ค้นหาอีกครั้ง"');
            return;
          }
          final state = await FlutterBluePlus.adapterState
              .where((s) => s == BluetoothAdapterState.on)
              .first
              .timeout(const Duration(seconds: 10), onTimeout: () => BluetoothAdapterState.off);
          if (!mounted) return;
          if (state != BluetoothAdapterState.on && !await ClassicBtTransport.isEnabled()) {
            _fail('Bluetooth ปิดอยู่ เปิด Bluetooth แล้วกด "ค้นหาอีกครั้ง"');
            return;
          }
        }
        if (!await ClassicBtTransport.locationEnabled()) {
          _hint = 'มือถือรุ่นนี้ต้องเปิด "ตำแหน่ง (Location)" ด้วย จึงจะค้นหาอุปกรณ์ Bluetooth ใหม่ได้ '
              '(ตัวสแกนที่จับคู่แล้วใช้ได้ตามปกติ)';
        }
        final paired = await ClassicBtTransport.bonded();
        if (!mounted) return;
        _paired = paired;
        _startDiscovery();
      }
      if (mounted && await FlutterBluePlus.isSupported) {
        if (!_android) {
          // iOS: สถานะ Bluetooth เป็น "ไม่ทราบ" จนกว่าระบบพร้อม (และจนกว่าผู้ใช้ตอบหน้าต่างขอสิทธิ์ครั้งแรก)
          // ถ้าสั่งค้นหาก่อนพร้อมจะได้ข้อผิดพลาดภาษาอังกฤษ จึงรอให้รู้สถานะก่อน แล้วบอกวิธีแก้เป็นภาษาไทย
          final state = await FlutterBluePlus.adapterState
              .where((s) => s != BluetoothAdapterState.unknown && s != BluetoothAdapterState.turningOn)
              .first
              .timeout(const Duration(seconds: 30), onTimeout: () => BluetoothAdapterState.unknown);
          if (!mounted) return;
          switch (state) {
            case BluetoothAdapterState.on:
              break;
            case BluetoothAdapterState.unauthorized:
              _fail('ยังไม่ได้อนุญาตให้ ProScaner ใช้ Bluetooth: เปิดแอป "การตั้งค่า" > ProScaner > เปิด Bluetooth '
                  'แล้วกลับมากด "ค้นหาอีกครั้ง"');
              return;
            case BluetoothAdapterState.off:
              _fail('Bluetooth ปิดอยู่ เปิด Bluetooth (ศูนย์ควบคุม หรือ การตั้งค่า > Bluetooth) แล้วกด "ค้นหาอีกครั้ง"');
              return;
            default:
              _fail('ยังใช้ Bluetooth ไม่ได้ในขณะนี้ รอสักครู่แล้วกด "ค้นหาอีกครั้ง"');
              return;
          }
        }
        await BleTransport.startScan();
      }
    } on PlatformException catch (e) {
      _error = e.message ?? '$e';
    } catch (e) {
      _error = 'ค้นหาไม่ได้: $e';
    }
    if (mounted) setState(() => _preparing = false);
  }

  void _startDiscovery() {
    _discovery?.cancel();
    _nearby.clear();
    setState(() => _discovering = true);
    _discovery = ClassicBtTransport.discover().listen(
      (d) {
        if (!mounted) return;
        if (d == null) {
          setState(() => _discovering = false);
          return;
        }
        if (_paired.any((p) => p.address == d.address)) return;
        setState(() => _nearby[d.address] = d);
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() {
          _discovering = false;
          _error ??= e is PlatformException ? (e.message ?? '$e') : '$e';
        });
      },
    );
  }

  static int _likelyFirst(String a, String b) {
    final la = BleTransport.likelyObdName.hasMatch(a) ? 0 : 1;
    final lb = BleTransport.likelyObdName.hasMatch(b) ? 0 : 1;
    return la.compareTo(lb);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final small = Theme.of(context).textTheme.bodySmall;
    final paired = [..._paired]..sort((a, b) => _likelyFirst(a.label, b.label));
    final nearby = _nearby.values.toList()..sort((a, b) => _likelyFirst(a.label, b.label));

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(
        _android
            ? 'แตะชื่อตัวสแกนเพื่อเชื่อมต่อ ตัวสแกนส่วนใหญ่ชื่อ OBDII, OBD2, V-LINK หรือ ELM327 '
                'ถ้ามือถือขอรหัส PIN ให้ใส่ 1234 หรือ 0000'
            : 'iPhone ใช้ได้กับตัวสแกนแบบ Bluetooth LE (BLE) และแบบ Wi-Fi เท่านั้น '
                '(ตัวสแกน Bluetooth ธรรมดาใช้กับ iPhone ไม่ได้ เป็นข้อจำกัดของ Apple)',
        style: small,
      ),
      if (_hint != null) ...[
        const SizedBox(height: 8),
        Text(_hint!, style: TextStyle(color: StatusColors.warn, fontSize: 12.5, height: 1.4)),
      ],
      if (_error != null) ...[
        const SizedBox(height: 8),
        Text(_error!, style: TextStyle(color: cs.error, height: 1.4)),
      ],
      const SizedBox(height: 10),
      Wrap(spacing: 8, runSpacing: 8, children: [
        StreamBuilder<bool>(
          stream: FlutterBluePlus.isScanning,
          initialData: false,
          builder: (context, snap) {
            final scanning = _preparing || _discovering || (snap.data ?? false);
            return OutlinedButton.icon(
              icon: scanning
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh_rounded),
              label: Text(scanning ? 'กำลังค้นหา…' : 'ค้นหาอีกครั้ง'),
              onPressed: scanning ? null : _start,
            );
          },
        ),
        if (_android)
          TextButton.icon(
            icon: const Icon(Icons.settings_bluetooth_rounded),
            label: const Text('จับคู่ในตั้งค่า Bluetooth'),
            onPressed: ClassicBtTransport.openSettings,
          ),
      ]),
      if (paired.isNotEmpty) ...[
        const SectionLabel('จับคู่แล้ว'),
        for (final d in paired)
          _DeviceTile(
            name: d.label,
            subtitle: d.address,
            tag: 'Bluetooth',
            onTap: () => widget.onConnect(ClassicBtTransport(d)),
          ),
      ],
      const SectionLabel('พบใกล้เคียง'),
      StreamBuilder<List<ScanResult>>(
        stream: FlutterBluePlus.scanResults,
        initialData: const [],
        builder: (context, snap) {
          final ble = [...?snap.data]..sort((a, b) {
              final l = _likelyFirst(a.device.platformName, b.device.platformName);
              if (l != 0) return l;
              final na = a.device.platformName.isEmpty ? 1 : 0;
              final nb = b.device.platformName.isEmpty ? 1 : 0;
              return na != nb ? na.compareTo(nb) : b.rssi.compareTo(a.rssi);
            });
          if (ble.isEmpty && nearby.isEmpty) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Text(
                _android
                    ? 'ยังไม่พบอุปกรณ์ใหม่ ถ้าตัวสแกนจับคู่ไว้แล้วจะอยู่ในหัวข้อ "จับคู่แล้ว" ด้านบน'
                    : 'ยังไม่พบอุปกรณ์ ตรวจว่าเสียบตัวสแกนกับรถแล้ว',
                textAlign: TextAlign.center,
                style: small,
              ),
            );
          }
          return Column(children: [
            for (final d in nearby)
              _DeviceTile(
                name: d.label,
                subtitle: '${d.address} · ยังไม่จับคู่ (จะขอ PIN 1234/0000)',
                tag: 'Bluetooth',
                onTap: () => widget.onConnect(ClassicBtTransport(d)),
              ),
            for (final r in ble)
              _DeviceTile(
                name: r.device.platformName.isEmpty ? '(ไม่มีชื่อ)' : r.device.platformName,
                subtitle: '${r.device.remoteId.str} · สัญญาณ ${r.rssi} dBm',
                tag: 'BLE',
                onTap: () => widget.onConnect(BleTransport(r.device)),
              ),
          ]);
        },
      ),
    ]);
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({required this.name, required this.subtitle, required this.tag, required this.onTap});

  final String name;
  final String subtitle;
  final String tag;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final likely = BleTransport.likelyObdName.hasMatch(name);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(likely ? Icons.directions_car_filled_rounded : Icons.bluetooth_rounded,
          color: likely ? cs.primary : cs.onSurfaceVariant),
      title: Text(name, style: TextStyle(fontWeight: likely ? FontWeight.w700 : FontWeight.w500)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
      trailing: Pill(text: tag, color: tag == 'BLE' ? const Color(0xFF3DA5FF) : cs.primary),
      onTap: onTap,
    );
  }
}

// ---------------- Wi-Fi / ทดลอง ----------------

class _WifiPanel extends StatelessWidget {
  const _WifiPanel({required this.host, required this.port, required this.onConnect});

  final TextEditingController host;
  final TextEditingController port;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(
        '1) เปิดการตั้งค่า Wi-Fi ของมือถือ แล้วต่อเครือข่ายของตัวสแกน (มักชื่อ WiFi_OBDII, V-LINK หรือ OBDII)\n'
        '2) กลับมาที่แอปแล้วกดเชื่อมต่อ ไม่ต้องปิดเน็ตมือถือ แอปจะคุยผ่าน Wi-Fi ของตัวสแกนให้เอง\n'
        'ถ้าไม่รู้ IP ให้ใช้ค่าเดิมไว้ แอปจะลองที่อยู่ที่ตัวสแกนส่วนใหญ่ใช้ให้อัตโนมัติ',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.5),
      ),
      if (Theme.of(context).platform == TargetPlatform.iOS) ...[
        const SizedBox(height: 8),
        Text(
          'iPhone: ครั้งแรกที่เชื่อมต่อจะมีหน้าต่างถามว่าให้ ProScaner ค้นหาและเชื่อมต่ออุปกรณ์ในเครือข่ายเฉพาะที่หรือไม่ '
          'ให้กดอนุญาต แล้วกดเชื่อมต่ออีกครั้ง (ถ้าเคยกดไม่อนุญาต เปิดได้ที่ การตั้งค่า > ProScaner > เครือข่ายเฉพาะที่)',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(height: 1.5, color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ],
      const SizedBox(height: 16),
      TextField(controller: host, decoration: const InputDecoration(labelText: 'IP ของตัวสแกน', border: OutlineInputBorder())),
      const SizedBox(height: 12),
      TextField(
        controller: port,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(labelText: 'พอร์ต', border: OutlineInputBorder()),
      ),
      Align(
        alignment: Alignment.centerRight,
        child: TextButton(
          onPressed: () {
            host.text = WifiTransport.defaultHost;
            port.text = '${WifiTransport.defaultPort}';
          },
          child: const Text('ใช้ค่าเริ่มต้น (ค้นหาอัตโนมัติ)'),
        ),
      ),
      const SizedBox(height: 4),
      FilledButton.icon(icon: const Icon(Icons.wifi), label: const Text('เชื่อมต่อ'), onPressed: onConnect),
    ]);
  }
}

class _DemoPanel extends StatelessWidget {
  const _DemoPanel({required this.onConnect});

  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('ใช้รถจำลองเพื่อลองแอปโดยไม่ต้องมีตัวสแกน รถจำลองมีรหัส P0171, P0301 '
          'และ P0420 (รอยืนยัน) พร้อมค่าเซ็นเซอร์ที่สอดคล้องกัน'),
      const SizedBox(height: 16),
      FilledButton.icon(icon: const Icon(Icons.play_arrow), label: const Text('เริ่มโหมดทดลอง'), onPressed: onConnect),
    ]);
  }
}
