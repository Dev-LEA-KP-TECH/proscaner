import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/analysis/vin.dart';
import '../../core/obd/mode09.dart';
import '../../state/providers.dart';
import '../home_screen.dart';
import '../theme.dart';
import '../widgets/common.dart';

final _ecuIdsProvider = FutureProvider.autoDispose<List<EcuIdentity>>((ref) async {
  final service = ref.watch(sessionProvider.select((s) => s.service));
  if (service == null) return const [];
  return service.readEcuIdentities();
});

/// ข้อมูลรถและกล่อง: ถอดรหัส VIN, Calibration ID, CVN, ตัวนับ, ตัวสแกนและโปรโตคอล
class EcuInfoScreen extends ConsumerWidget {
  const EcuInfoScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('ข้อมูลรถและกล่อง ECU')),
      body: NeedsConnection(
        message: 'เชื่อมต่อรถเพื่ออ่านข้อมูลกล่อง',
        builder: (context, service) {
          final session = ref.watch(sessionProvider);
          final ids = ref.watch(_ecuIdsProvider);
          final vin = session.vin == null ? null : decodeVin17(session.vin!);
          final adapter = session.adapter;
          return RefreshIndicator(
            onRefresh: () => ref.refresh(_ecuIdsProvider.future),
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
              const SectionLabel('เลขตัวถัง (VIN)'),
              PremiumCard(
                child: vin == null
                    ? Text('รถคันนี้ไม่ส่ง VIN ผ่าน OBD (พบบ่อยในรถก่อนปี 2008)', style: TextStyle(color: cs.onSurfaceVariant))
                    : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Expanded(
                            child: SelectableText(vin.vin,
                                style: const TextStyle(fontFamily: kMono, fontSize: 19, fontWeight: FontWeight.w700, letterSpacing: 1.2)),
                          ),
                          IconButton(
                            tooltip: 'คัดลอก',
                            icon: const Icon(Icons.copy_rounded, size: 20),
                            onPressed: () => Clipboard.setData(ClipboardData(text: vin.vin)),
                          ),
                        ]),
                        if (!vin.valid)
                          const Pill(text: 'รูปแบบ VIN ไม่ถูกต้อง', color: StatusColors.warn, icon: Icons.error_rounded)
                        else ...[
                          KvRow('ผู้ผลิต', vin.maker ?? 'ไม่อยู่ในฐานข้อมูล'),
                          KvRow('ประเทศที่ผลิต', vin.country ?? 'ไม่ทราบ'),
                          KvRow('ปีรุ่น', vin.modelYear?.toString() ?? 'ไม่ทราบ'),
                          KvRow('หมายเลขลำดับ', vin.serial ?? '—', mono: true),
                          const SizedBox(height: 6),
                          Text('เทียบ VIN นี้กับเล่มทะเบียนและที่ตอกบนตัวถัง ถ้าไม่ตรงกัน อาจมีการเปลี่ยนกล่อง ECU',
                              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant, height: 1.4)),
                        ],
                      ]),
              ),
              const SectionLabel('การเชื่อมต่อ'),
              PremiumCard(
                child: Column(children: [
                  KvRow('โปรโตคอลของรถ', service.elm.protocolLabel),
                  KvRow('ตัวสแกน', adapter?.kind.labelTh ?? 'ไม่ทราบ'),
                  KvRow('รุ่นชิป', adapter?.stnVersion ?? adapter?.version ?? service.elm.version ?? '—', mono: true),
                  if (adapter?.description != null) KvRow('รายละเอียด', adapter!.description!),
                  KvRow('อ่านกล่องอื่น (ABS, ถุงลม)', service.elm.isCan
                      ? ((adapter?.flowControl ?? false) ? 'รองรับ (กล่องที่ใช้ UDS/KWP บน CAN)' : 'รองรับบางส่วน')
                      : 'ไม่รองรับ (รถไม่ใช่ CAN)'),
                  KvRow('จำนวนค่าสดที่รองรับ', '${service.supported.length} ค่า'),
                ]),
              ),
              if (adapter?.kind.name == 'elmClone') ...[
                const SizedBox(height: 10),
                const Pill(
                  text: 'ตัวสแกนก๊อปบางรุ่นอ่านกล่องอื่นได้ไม่ครบ ถ้าสแกนทั้งคันไม่เจอกล่อง ลองใช้ตัวสแกนชิป STN/vLinker',
                  color: StatusColors.info,
                  icon: Icons.info_rounded,
                ),
              ],
              const SectionLabel('กล่องที่ตอบ (Mode 09)'),
              ids.when(
                loading: () => const PremiumCard(child: Center(child: CircularProgressIndicator())),
                error: (e, _) => PremiumCard(child: Text('อ่านไม่ได้: $e')),
                data: (list) => list.isEmpty
                    ? PremiumCard(child: Text('กล่องไม่ตอบ Mode 09', style: TextStyle(color: cs.onSurfaceVariant)))
                    : Column(children: [
                        for (final e in list)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: PremiumCard(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(e.name ?? 'กล่อง ${e.ecu}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                                const SizedBox(height: 6),
                                KvRow('ที่อยู่', e.ecu, mono: true),
                                for (final c in e.calIds) KvRow('Calibration ID', c, mono: true),
                                for (final c in e.cvns) KvRow('CVN', c, mono: true),
                                if (e.ignitionCount != null) KvRow('จำนวนครั้งที่สตาร์ท', groupDigits(e.ignitionCount!)),
                                if (e.obdConditionCount != null) KvRow('รอบขับครบเงื่อนไข OBD', groupDigits(e.obdConditionCount!)),
                              ]),
                            ),
                          ),
                        Text(
                          'Calibration ID คือรุ่นซอฟต์แวร์ในกล่อง ใช้เช็กว่าอัปเดตล่าสุดหรือไม่ CVN เปลี่ยนเมื่อมีการแก้ไขโปรแกรม (จูน/รีแมพ)',
                          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant, height: 1.45),
                        ),
                      ]),
              ),
            ]),
          );
        },
      ),
    );
  }
}
