import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/backup.dart';
import '../data/file_port.dart';
import 'ext_packs.dart';
import 'providers.dart';
import 'remap_providers.dart';

/// หน้าต่างบันทึก/เปิดไฟล์ของเครื่อง
final filePortProvider = Provider<FilePort>((ref) => const PlatformFilePort());

/// สำรอง/กู้คืนข้อมูลทั้งแอป
final backupServiceProvider = Provider<BackupService>((ref) => BackupService(
      prefs: SharedPrefsBackup(ref.watch(sharedPrefsProvider)),
      garage: ref.watch(garageStoreProvider),
      history: ref.watch(historyStoreProvider),
      logs: ref.watch(logStoreProvider),
      remaps: ref.watch(remapStoreProvider),
    ));

/// หลังกู้คืน: ให้ทุกหน้าที่แสดงข้อมูลโหลดใหม่จากที่เก็บ
void reloadAfterRestore(WidgetRef ref) {
  ref.invalidate(garageProvider);
  ref.invalidate(historyProvider);
  ref.invalidate(logsProvider);
  ref.invalidate(remapRunsProvider);
  ref.invalidate(extPacksProvider);
  ref.invalidate(settingsProvider);
  ref.invalidate(appModeProvider);
  ref.invalidate(lastAdapterProvider);
  ref.invalidate(commLogEnabledProvider);
}
