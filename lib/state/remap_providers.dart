import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/analysis/remap_test.dart';
import '../data/remap_store.dart';

/// ที่เก็บผลทดสอบก่อน/หลังรีแมพ
final remapStoreProvider = Provider<RemapStore>((ref) => RemapStore());

/// ผลทดสอบทั้งหมด (ใหม่สุดก่อน)
final remapRunsProvider = FutureProvider<List<RemapRun>>((ref) => ref.watch(remapStoreProvider).list());
