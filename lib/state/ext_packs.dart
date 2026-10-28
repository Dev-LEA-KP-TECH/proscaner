import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/obd/ext_known.dart';
import '../core/obd/ext_library.dart';
import '../core/obd/ext_pid.dart';
import 'providers.dart';

/// ชุดค่าเฉพาะยี่ห้อที่ผู้ใช้เพิ่ม/นำเข้า เก็บในเครื่อง
class ExtPacksNotifier extends Notifier<List<ExtPidPack>> {
  static const _key = 'ext_packs';

  @override
  List<ExtPidPack> build() {
    final raw = ref.watch(sharedPrefsProvider).getString(_key);
    if (raw == null) return const [];
    try {
      return (jsonDecode(raw) as List<dynamic>)
          .map((e) => ExtPidPack.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  void _save(List<ExtPidPack> list) {
    state = list;
    ref.read(sharedPrefsProvider).setString(_key, jsonEncode(list.map((p) => p.toJson()).toList()));
  }

  /// เพิ่มหรือแทนที่ชุดที่มี id เดียวกัน
  void put(ExtPidPack pack) {
    final list = [for (final p in state) if (p.id != pack.id) p];
    final i = state.indexWhere((p) => p.id == pack.id);
    list.insert(i < 0 ? list.length : i, pack);
    _save(list);
  }

  void remove(String id) => _save([for (final p in state) if (p.id != id) p]);

  /// ชุดที่คัดลอกมาจากคลัง (ถ้ามีแล้ว)
  ExtPidPack? fromLibrary(String lib) => state.where((p) => p.lib == lib).firstOrNull;

  /// ใช้ชุดจากคลัง: ถ้ามีอยู่แล้วคืนชุดเดิม (เก็บผลยืนยันของร้านไว้) ถ้ายังไม่มีคัดลอกเข้ามา
  ExtPidPack adopt(ExtPidPack libraryPack) {
    final existing = libraryPack.lib == null ? null : fromLibrary(libraryPack.lib!);
    if (existing != null) return existing;
    put(libraryPack);
    return libraryPack;
  }
}

final extPacksProvider = NotifierProvider<ExtPacksNotifier, List<ExtPidPack>>(ExtPacksNotifier.new);

/// คลังชุดค่าที่มากับแอป
final extLibraryProvider = Provider<ExtLibrary>((ref) => ExtLibrary());

final extLibraryIndexProvider = FutureProvider<List<ExtLibraryEntry>>((ref) => ref.watch(extLibraryProvider).index());

/// ค่าที่ค้นพบเอง (ยังไม่รู้ชื่อ) ในชุดหนึ่ง ที่กล่องและคำสั่งตรงกับค่าที่รู้แล้วในคลังของรถรุ่นเดียวกัน
/// ใช้ยี่ห้อ รุ่น ปีของชุด (หน้าค้นหาบันทึกจากรถที่ต่ออยู่ตอนค้นหา) ดู [findKnown]
final knownNamesProvider = FutureProvider.family<List<KnownMatch>, String>((ref, packId) async {
  final pack = ref.watch(extPacksProvider).where((p) => p.id == packId).firstOrNull;
  if (pack == null || !pack.pids.any(isUnnamedDiscovered)) return const [];
  final library = ref.watch(extLibraryProvider);
  final index = await ref.watch(extLibraryIndexProvider.future);
  final libs = <ExtPidPack>[];
  for (final e in index) {
    if (e.lib == pack.lib) continue;
    if (sameCarForNames(
      libBrand: e.brand,
      libModels: e.models,
      libYears: e.years,
      make: pack.brand.isEmpty ? null : pack.brand,
      model: pack.models.isEmpty ? null : pack.models.first,
      year: pack.years.isEmpty ? null : pack.years.first,
    )) {
      libs.add(await library.pack(e));
    }
  }
  return findKnown(pack, libs);
});

/// คำสั่งที่รถคันที่ต่ออยู่ไม่ตอบ (จำไว้เฉพาะการเชื่อมต่อครั้งนี้ เพื่อไม่ต้องรอหมดเวลาซ้ำ)
final extSkipProvider = Provider<Set<String>>((ref) {
  ref.watch(sessionProvider.select((s) => s.service));
  return <String>{};
});
