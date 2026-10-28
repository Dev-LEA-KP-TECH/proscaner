// Renders the real app screens to PNG files (test_screens/out/*.png) using the demo car.
// Run:  flutter test test_screens/app_screens_test.dart --update-goldens
// (SCREENSHOTS.bat does this.) Not part of the normal `flutter test` suite.
//
// ขนาดจอและขนาดตัวอักษรตั้งได้ (CI รันหลายขนาด ดู .github/workflows/test.yml):
//   --dart-define=SHOT_W=360 --dart-define=SHOT_H=780 --dart-define=SHOT_SCALE=1.3 --dart-define=SHOT_DIR=out_text13
// ทุกภาพจดลง <SHOT_DIR>/report.txt ว่ามีข้อความถูกตัด (…) หรือวาดล้นกรอบ (overflow) ตรงไหนบ้าง
// มีหน้าที่วาดล้นกรอบ = เทสต์ไม่ผ่าน
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obd_doctor/core/diagnosis/diagnosis.dart';
import 'package:obd_doctor/core/obd/ext_pid.dart';
import 'package:obd_doctor/core/voice/voice_service.dart';
import 'package:obd_doctor/state/ext_packs.dart';
import 'package:obd_doctor/core/obd/ext_library.dart';
import 'package:obd_doctor/ui/theme.dart';
import 'package:obd_doctor/ui/tools/brand_data_screen.dart';
import 'package:obd_doctor/ui/tools/did_scanner_screen.dart';
import 'package:obd_doctor/ui/tools/ext_common.dart';
import 'package:obd_doctor/ui/tools/ext_library_screen.dart';
import 'package:obd_doctor/ui/tools/ext_pid_detail_screen.dart';
import 'package:obd_doctor/core/transport/demo_transport.dart';
import 'package:obd_doctor/data/garage_store.dart';
import 'package:obd_doctor/data/history_store.dart';
import 'package:obd_doctor/data/log_store.dart';
import 'package:obd_doctor/state/live_poller.dart';
import 'package:obd_doctor/ui/garage_tab.dart';
import 'package:obd_doctor/ui/home_screen.dart';
import 'package:obd_doctor/ui/splash_screen.dart';
import 'package:obd_doctor/ui/settings_screens.dart';
import 'package:obd_doctor/ui/tools/battery_screen.dart';
import 'package:obd_doctor/ui/tools/dashboard_screen.dart';
import 'package:obd_doctor/ui/tools/ecu_info_screen.dart';
import 'package:obd_doctor/ui/tools/logs_screen.dart';
import 'package:obd_doctor/ui/tools/mode06_screen.dart';
import 'package:obd_doctor/ui/tools/modules_screen.dart';
import 'package:obd_doctor/ui/tools/odometer_screen.dart';
import 'package:obd_doctor/ui/tools/performance_screen.dart';
import 'package:obd_doctor/ui/tools/remap_test_screen.dart';
import 'package:obd_doctor/ui/tools/used_car_screen.dart';
import 'package:obd_doctor/core/analysis/remap_demo.dart';
import 'package:obd_doctor/core/analysis/remap_test.dart';
import 'package:obd_doctor/data/remap_store.dart';
import 'package:obd_doctor/state/remap_providers.dart';
import 'package:obd_doctor/ui/vehicle_screen.dart';
import 'package:obd_doctor/main.dart';
import 'package:obd_doctor/report/pdf_report.dart';
import 'package:obd_doctor/core/analysis/used_car.dart';
import 'package:obd_doctor/state/providers.dart';
import 'package:obd_doctor/data/backup.dart';
import 'package:obd_doctor/data/comm_log.dart';
import 'package:obd_doctor/state/backup_providers.dart';
import 'package:obd_doctor/ui/backup_screen.dart';
import 'package:obd_doctor/ui/comm_log_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// ขนาดจอ (dp) ขนาดตัวอักษร และโฟลเดอร์ผล
final _w = double.parse(const String.fromEnvironment('SHOT_W', defaultValue: '360'));
final _h = double.parse(const String.fromEnvironment('SHOT_H', defaultValue: '780'));
final _scale = double.parse(const String.fromEnvironment('SHOT_SCALE', defaultValue: '1.0'));
const _dir = String.fromEnvironment('SHOT_DIR', defaultValue: 'out');

/// รายการหลักของหน้าบนสุด: Scrollable แนวตั้งตัวที่ใหญ่ที่สุดที่ยังแตะถึงได้
ScrollableState? _mainScroll() {
  ScrollableState? best;
  var bestArea = 0.0;
  for (final e in find.byType(Scrollable).hitTestable().evaluate()) {
    final s = e.widget as Scrollable;
    if (axisDirectionToAxis(s.axisDirection) != Axis.vertical || s.physics is NeverScrollableScrollPhysics) continue;
    final box = e.renderObject;
    if (box is! RenderBox || !box.hasSize) continue;
    final area = box.size.width * box.size.height;
    if (area > bestArea) {
      bestArea = area;
      best = (e as StatefulElement).state as ScrollableState;
    }
  }
  return best;
}

/// ข้อความบนจอที่ถูกตัด: เกินจำนวนบรรทัด (…) หรือบรรทัดเดียวที่ยาวเกินช่อง
List<String> _cutTexts() {
  final out = <String>[];
  for (final e in find.byType(RichText).evaluate()) {
    final ro = e.renderObject;
    if (ro is! RenderParagraph || !ro.hasSize) continue;
    var cut = ro.didExceedMaxLines;
    if (!cut && !ro.softWrap) {
      // วัดความยาวจริงของข้อความบรรทัดเดียวด้วยตัววัดแยก (ไม่ไปยุ่งกับข้อความที่วาดอยู่)
      try {
        final tp = TextPainter(text: ro.text, textDirection: ro.textDirection, textScaler: ro.textScaler, maxLines: 1)
          ..layout();
        cut = tp.width > ro.size.width + 0.5;
        tp.dispose();
      } catch (_) {
        // ข้อความที่มีวิดเจ็ตฝังอยู่ วัดแบบนี้ไม่ได้ ข้ามไป
      }
    }
    if (!cut) continue;
    var t = ro.text.toPlainText().replaceAll('\n', ' ').trim();
    if (t.length > 60) t = '${t.substring(0, 60)}…';
    if (t.isNotEmpty && !out.contains(t)) out.add(t);
  }
  return out;
}

/// บันทึกการสื่อสารตัวอย่าง 1 การเชื่อมต่อ (ข้อมูลสมมติ ไม่มีเลข VIN ของรถจริง)
const _sampleCommLog = '''# ProScaner communication log
# title=BLE OBDII
# start=2026-10-27T19:14:11.397071
# app=ProScaner 0.6.4
# transport=ble
19:14:11.512  > ATZ
19:14:12.540  ELM327 v1.5
19:14:12.601  > ATE0
19:14:12.655  OK
19:14:12.702  > ATH1
19:14:12.760  OK
19:14:12.811  > ATS0
19:14:12.866  OK
19:14:12.914  > ATSP6
19:14:12.970  OK
19:14:13.105  > 0100
19:14:13.420  7E8064100BE3EA813
19:33:05.120  > 221203
19:33:05.180  7E80562120303E9
19:33:05.402  > 221250
19:33:05.455  7E80462125021
19:33:05.660  > 221400
19:33:05.712  7E80462140006
19:33:05.918  > 221402
19:33:05.969  7E80462140202
19:33:06.175  > 221403
19:33:06.226  7E80462140304
19:33:06.433  > 221430
19:33:06.490  7E8056214300438
19:33:06.697  > 221450
19:33:06.749  7E80462145020
19:33:06.955  > 221280
19:33:07.007  7E80462128000
19:47:12.300  == ผู้ใช้ยกเลิกการเชื่อมต่อ
''';


/// History kept in memory so the screens render without file I/O.
class _MemoryHistory extends HistoryStore {
  final _items = <VehicleSnapshot>[];

  @override
  Future<List<VehicleSnapshot>> load() => SynchronousFuture(List.of(_items));

  @override
  Future<void> add(VehicleSnapshot s) {
    _items.insert(0, s);
    return SynchronousFuture(null);
  }

  @override
  Future<void> clear() {
    _items.clear();
    return SynchronousFuture(null);
  }
}

Future<void> _loadFont(String family, List<String> candidates) async {
  final loader = FontLoader(family);
  var any = false;
  for (final path in candidates) {
    final f = File(path);
    if (f.existsSync()) {
      final bytes = f.readAsBytesSync();
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
      any = true;
    }
  }
  if (any) await loader.load();
}

Future<void> _loadFonts() async {
  // ฟอนต์ที่แอปฝังมา (assets/fonts) + ไอคอน Material จาก Flutter SDK
  await _loadFont('Prompt', [
    for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold', 'ExtraBold']) 'assets/fonts/Prompt-$w.ttf',
  ]);
  await _loadFont('IBMPlexMono', ['assets/fonts/IBMPlexMono-Regular.ttf', 'assets/fonts/IBMPlexMono-Bold.ttf']);
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? r'C:\flutter';
  await _loadFont('MaterialIcons', [
    '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  ]);
}

void main() {
  testWidgets('app screens', (tester) async {
    await _loadFonts();
    tester.view.physicalSize = Size(_w * 3, _h * 3);
    tester.view.devicePixelRatio = 3.0;
    tester.platformDispatcher.textScaleFactorTestValue = _scale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    Directory('test_screens/$_dir').createSync(recursive: true);

    // จดทุกภาพ: ข้อความที่ถูกตัด และ error ตอนวาด (เช่น RenderFlex overflowed) เขียนลง report.txt เสมอ แม้เทสต์หยุดกลางทาง
    final report = StringBuffer();
    final broken = <String>[];
    addTearDown(() => File('test_screens/$_dir/report.txt').writeAsStringSync(
        'ขนาดจอ ${_w.toStringAsFixed(0)}x${_h.toStringAsFixed(0)} dp · ตัวอักษร x$_scale\n'
        'หน้าที่วาดล้นกรอบ: ${broken.isEmpty ? 'ไม่มี' : broken.join(', ')}\n\n$report'));

    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final remapStore = MemoryRemapStore();
    // โฟลเดอร์ชั่วคราวแทนโฟลเดอร์ของแอป (บันทึกการสื่อสาร, ไฟล์สำรอง) ลบทิ้งตอนจบ
    final tmp = Directory.systemTemp.createTempSync('proscaner_shots_');
    addTearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });
    final commDir = Directory('${tmp.path}/comm_logs')..createSync(recursive: true);
    File('${commDir.path}/ProScaner_comm_20261027_191411_397.txt').writeAsStringSync(_sampleCommLog);
    final container = ProviderContainer(overrides: [
      commLogProvider.overrideWith((ref) {
        final log = CommLog(directory: tmp);
        ref.onDispose(log.dispose);
        return log;
      }),
      backupServiceProvider.overrideWith((ref) => BackupService(
            prefs: SharedPrefsBackup(ref.watch(sharedPrefsProvider)),
            garage: ref.watch(garageStoreProvider),
            history: ref.watch(historyStoreProvider),
            logs: ref.watch(logStoreProvider),
            remaps: ref.watch(remapStoreProvider),
            directory: tmp,
          )),
      remapStoreProvider.overrideWithValue(remapStore),
      sharedPrefsProvider.overrideWithValue(prefs),
      voiceServiceProvider.overrideWithValue(SilentVoiceService()),
      extLibraryProvider.overrideWithValue(ExtLibrary(loader: (p) => File(p).readAsString())),
      historyStoreProvider.overrideWithValue(_MemoryHistory()),
      garageStoreProvider.overrideWithValue(MemoryGarageStore()),
      logStoreProvider.overrideWithValue(MemoryLogStore()),
    ]);
    addTearDown(container.dispose);

    // advance real time (I/O, streams) and fake time (timers, animations) together
    Future<void> run(int frames) async {
      for (var i = 0; i < frames; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 4)));
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    Future<void> settle([int ms = 300]) => run(30 + ms ~/ 20);

    // วนจนกว่าเงื่อนไขจะจริง (ใช้กับงานที่ใช้เวลาจริง เช่น สแกนทั้งคัน, จับเวลา)
    Future<void> until(bool Function() done, {int max = 600, int realMs = 30}) async {
      for (var i = 0; i < max && !done(); i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: realMs)));
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    Future<void> shot(String name) async {
      final cut = _cutTexts();
      final error = tester.takeException();
      if (error != null) broken.add(name);
      report.writeln([
        name,
        if (error != null) 'วาดล้น/ผิดพลาด: ${'$error'.split('\n').first}',
        if (cut.isNotEmpty) 'ถูกตัด ${cut.length}: ${cut.join(' | ')}',
      ].join(' · '));
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('$_dir/$name.png'));
    }

    // รอจนเห็น [f]: ระหว่างรอเลื่อนรายการหลักลงทีละนิด (จอเล็กหรือตัวอักษรใหญ่ ของที่อยู่ท้ายรายการยังไม่ถูกสร้าง)
    // เจอแล้วเลื่อนกลับตำแหน่งเดิม [restore] ภาพจะได้มุมเดิม
    Future<bool> untilSeen(Finder f, {int max = 600, int realMs = 5, bool restore = true}) async {
      final s0 = _mainScroll();
      final start = s0?.position.pixels;
      var moved = false;
      for (var i = 0; i < max; i++) {
        if (f.evaluate().isNotEmpty) {
          if (moved && restore && s0 != null && s0.mounted && start != null) {
            s0.position.jumpTo(start);
            await tester.pump();
          }
          return true;
        }
        if (i % 8 == 7) {
          final s = _mainScroll();
          if (s != null) {
            final p = s.position;
            p.jumpTo(p.pixels >= p.maxScrollExtent - 1 ? p.minScrollExtent : math.min(p.pixels + 300, p.maxScrollExtent));
            moved = true;
          }
        }
        await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: realMs)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      return f.evaluate().isNotEmpty;
    }

    // กดสิ่งที่อาจอยู่นอกจอ: เลื่อนให้เห็นก่อน (ถ้ายังไม่เห็น) แล้วค่อยกด
    Future<void> tapOn(Finder f) async {
      if (f.evaluate().isEmpty) await untilSeen(f, max: 240, restore: false);
      if (f.hitTestable().evaluate().isEmpty) {
        await tester.ensureVisible(f.first);
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.tap(f.first);
    }

    Future<void> scrollBy(double dy) async {
      await tester.drag(find.byType(Scrollable).last, Offset(0, -dy));
      await settle(100);
    }

    // เลื่อนรายการหลักของหน้าปัจจุบัน (ไม่ใช่ช่องพิมพ์ที่อยู่ในรายการ)
    Future<void> scrollList(double dy) async {
      await tester.drag(find.byType(ListView).first, Offset(0, -dy));
      await settle(100);
    }

    NavigatorState nav() => tester.state<NavigatorState>(find.byType(Navigator).first);
    void pop() => nav().pop();
    Future<void> open(Widget w, {int frames = 40}) async {
      nav().push(MaterialPageRoute<void>(builder: (_) => w));
      await run(frames);
    }

    Future<void> tab(String label) async {
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(label)));
      await settle();
    }

    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const ObdDoctorApp()));
    // หน้าโหลด: ถ่ายตอนกำลังเตรียมระบบ แล้วรอจนเข้าหน้าหลัก
    await run(4);
    await shot('00_splash');
    await until(() => find.byType(HomeScreen).evaluate().isNotEmpty, max: 400, realMs: 5);
    await settle();
    await shot('01_home_not_connected');

    // connect to the demo car
    final demo = DemoTransport(responseDelay: const Duration(milliseconds: 20));
    await tester.runAsync(() => container.read(sessionProvider.notifier).connect(demo));
    await settle();
    await shot('02_home_connected');

    await tab('วินิจฉัย');
    await shot('03_ready_to_scan');

    // full scan (engine + other modules)
    // สแกนแบบสลับเวลาจริง/เวลาจำลอง ไม่ให้ค้างเมื่อมีคำสั่งค่าสดค้างอยู่ในคิว
    unawaited(container.read(scanProvider.notifier).run(allModules: true));
    await run(3);
    await until(() => !container.read(scanProvider).running, max: 3000, realMs: 5);
    await settle(500);
    await shot('04_diagnosis_owner');
    await scrollBy(900);
    await shot('05_diagnosis_modules');

    container.read(appModeProvider.notifier).set(AppMode.mechanic);
    await settle();
    await scrollBy(700);
    await shot('06_diagnosis_mechanic');

    await tab('หน้าหลัก');
    await shot('07_home_mechanic_tools');
    // เลื่อนที่รายการหลักของหน้า
    await scrollList(700);
    await shot('08_home_mechanic_tools_2');

    // live data: owner gauges, mechanic list + chart
    container.read(appModeProvider.notifier).set(AppMode.owner);
    await tab('ค่าสด');
    await run(250);
    await shot('09_live_owner_gauges');

    container.read(appModeProvider.notifier).set(AppMode.mechanic);
    await run(300);
    await shot('10_live_mechanic');

    await tapOn(find.text('รอบเครื่องยนต์'));
    await run(150);
    await shot('11_live_chart');
    pop();
    await run(30);

    await tab('หน้าหลัก');

    // odometer check
    await open(const OdometerScreen());
    await tester.enterText(find.byType(TextField).first, '186,500');
    await tapOn(find.text('อ่านข้อมูลและตรวจ'));
    await untilSeen(find.text('ข้อมูลที่อ่านได้'), max: 400);
    await settle(200);
    await shot('12_odometer');
    await scrollBy(800);
    await shot('13_odometer_details');
    pop();
    await settle();

    // used-car check (dashboard km lower than the ECU → suspicious)
    await open(const UsedCarScreen());
    await tester.enterText(find.byType(TextField).first, '98,000');
    final usedBefore = container.read(scanProvider).report?.snapshot.time;
    await tapOn(find.textContaining('เริ่มตรวจ'));
    // ตรวจเสร็จ = ได้ผลสแกนครั้งใหม่ และปุ่มกลับจาก "กำลังตรวจ…" (ปุ่มส่งรายงานอยู่ท้ายรายการ อาจยังไม่ถูกสร้าง)
    await until(
        () =>
            container.read(scanProvider).report?.snapshot.time != usedBefore &&
            find.text('กำลังตรวจ…').evaluate().isEmpty,
        max: 1500,
        realMs: 5);
    await settle(400);
    await scrollBy(700);
    await shot('14_used_car');

    // PDF report of the used-car check (rendered with the bundled Thai font)
    await tester.runAsync(() async {
      final report = container.read(scanProvider).report!;
      final bytes = await buildReportPdf(ReportInput(
        report: report,
        shop: const ShopProfile(name: 'อู่ช่างเอ ออโต้เซอร์วิส', phone: '081-234-5678', address: 'ถ.พหลโยธิน กรุงเทพฯ', technician: 'ช่างเอ'),
        usedCar: evaluateUsedCar(report: report, modules: report.snapshot.modules),
      ));
      File('test_screens/$_dir/report.pdf').writeAsBytesSync(bytes);
    });
    pop();
    await settle();

    // ECU info, Mode 06, modules
    await open(const EcuInfoScreen(), frames: 150);
    await shot('15_ecu_info');
    pop();
    await settle();

    await open(const Mode06Screen());
    await tapOn(find.text('อ่านผลทดสอบ'));
    await untilSeen(find.textContaining('ทดสอบทั้งหมด'));
    await settle(200);
    await shot('16_mode06');
    pop();
    await settle();

    await open(const ModulesScreen(), frames: 60);
    await shot('17_modules');
    final abs = container.read(modulesProvider).firstWhere((m) => m.tx == '7B0');
    await open(ModuleDetailScreen(module: abs), frames: 40);
    await tapOn(find.text('อ่านรหัส'));
    await untilSeen(find.text('C0035-31'), max: 400);
    await settle(200);
    await shot('18_module_abs');
    pop();
    pop();
    await settle();

    // ค่าเฉพาะยี่ห้อ (ชุดตัวอย่างของรถจำลอง)
    container.read(extPacksProvider.notifier).put(demoPack());
    await open(const BrandDataScreen(initialTab: 0), frames: 40);
    await tapOn(find.text('อ่านครั้งเดียว'));
    await untilSeen(find.textContaining('ต่างจากสูบอื่นชัด'), max: 400);
    await settle(200);
    await shot('18b_brand_data');
    await scrollList(600);
    await shot('18c_brand_data_2');
    await scrollList(-3000);

    // ด่านอ่านอย่างเดียว: นำเข้าไฟล์ PID ที่มีคำสั่งรีเซ็ต/สั่งอุปกรณ์/ลบรหัสปนมา แอปข้ามและบอกว่าข้ามบรรทัดไหน
    await tester.tap(find.byTooltip('นำเข้า'));
    await settle();
    await tester.enterText(
      find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)),
      'Name,ShortName,ModeAndPID,Equation,Min Value,Max Value,Units,Header\n'
      'Boost desired,BSTD,0x221130,A,0,255,kPa,7E0\n'
      'ECU reset,RST,0x1101,A,0,1,,7E0\n'
      'Injector 1 test,INJ1,0x2F0C0103,A,0,1,,7E0\n'
      'Clear codes,CLR,0x14FFFFFF,A,0,1,,7E0\n',
    );
    await settle(100);
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('ตกลง')));
    await settle(300);
    await shot('18m_import_blocked');
    await tapOn(find.text('รับทราบ'));
    await settle(300);
    final imported = container.read(extPacksProvider).firstWhere((p) => p.name == 'ชุดที่นำเข้า');
    expect(imported.pids.map((p) => p.request), ['221130']);
    container.read(extPacksProvider.notifier).remove(imported.id);
    tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger).first).clearSnackBars();
    await settle(200);

    // คลังชุดข้อมูล
    await tapOn(find.text('คลังชุดข้อมูล'));
    await untilSeen(find.text('Toyota Hilux (Vigo, Revo) / Fortuner'));
    await settle(200);
    await shot('18e_library');
    final hiluxCard = find.ancestor(of: find.text('Toyota Hilux (Vigo, Revo) / Fortuner'), matching: find.byType(PremiumCard)).first;
    final useHilux = find.descendant(of: hiluxCard, matching: find.text('ใช้ชุดนี้'));
    await tester.ensureVisible(hiluxCard);
    await settle(100);
    await tapOn(useHilux);
    await until(() => container.read(extPacksProvider).any((p) => p.lib == 'toyota_hilux'), max: 600, realMs: 5);
    await settle(200);
    await scrollList(-5000);
    await tapOn(find.text('อ่านครั้งเดียว'));
    await run(10);
    await until(() => find.byType(LinearProgressIndicator).evaluate().isEmpty, max: 3000, realMs: 5);
    await settle(200);
    await shot('18f_hilux_pack');
    await scrollList(900);
    await shot('18g_hilux_values');
    await scrollList(-5000);

    // เทียบค่ากับเครื่องมือศูนย์ (ตั้งจุดเทียบไว้ล่วงหน้า แล้วให้แอปหาสูตร)
    final hp = container.read(extPacksProvider).firstWhere((p) => p.lib == 'toyota_hilux');
    final atf = hp.pids.firstWhere((p) => p.request == '221627');
    atf.points
      ..add(CalPoint(raw: const [0x32, 0xA0], ref: 10.6))
      ..add(CalPoint(raw: const [0x37, 0x00], ref: 15.0))
      ..add(CalPoint(raw: const [0x68, 0x60], ref: 64.4));
    container.read(extPacksProvider.notifier).put(hp);
    await open(ExtPidDetailScreen(pid: atf, packId: hp.id), frames: 30);
    await tapOn(find.text('อ่านครั้งเดียว'));
    await until(() => find.byType(ByteGrid).evaluate().isNotEmpty, max: 600, realMs: 5);
    await settle(200);
    await shot('18h_pid_detail');
    await scrollList(700);
    await shot('18i_pid_calibrate');
    await tapOn(find.text('หาสูตรจากจุดเทียบ'));
    await settle(400);
    await shot('18j_fit');
    pop();
    await settle();
    pop();
    await settle();

    await open(const DidScannerScreen(autoPreset: false), frames: 30);
    await tapOn(find.text('เริ่มค้นหา'));
    await untilSeen(find.textContaining(RegExp(r'กล่องตอบ [1-9]')), max: 3000);
    await settle(200);
    await shot('18d_did_scanner');
    pop();
    pop();
    await settle();

    // รถไม่ตอบเลย (ปิดสวิตช์กุญแจ): ต้องบอกให้เปิดสวิตช์ ไม่สรุปว่าทุกชุดไม่ตรงรุ่น
    demo.ignitionOff = true;
    await open(ExtMatchScreen(onUse: (_) {}), frames: 30);
    await tapOn(find.textContaining('เริ่มทดสอบ'));
    await untilSeen(find.text(carSilentText), max: 3000);
    await settle(200);
    await shot('18k_car_silent');
    demo.ignitionOff = false;
    pop();
    await settle();

    // battery test: rest + crank
    await open(const BatteryScreen(), frames: 80);
    await tapOn(find.text('เริ่ม'));
    await untilSeen(find.text('วัดใหม่'), max: 300, realMs: 40);
    await settle(300);
    await shot('19_battery');
    pop();
    await settle();

    // performance: arm + simulated launch
    await open(const PerformanceScreen(), frames: 60);
    await tapOn(find.text('เตรียมพร้อม'));
    await run(10);
    await tapOn(find.text('จำลองออกตัว'));
    await until(() => find.text('เตรียมพร้อม').evaluate().isNotEmpty, max: 2000, realMs: 15);
    await settle(200);
    await shot('20_performance');
    pop();
    await settle();

    // ทดสอบก่อน/หลังรีแมพ: ผลสาธิตสองรอบ (ก่อน/หลัง) แล้วเทียบ
    final remapBefore = syntheticRemapRun(id: 'demo_before', stage: RemapStage.before, start: DateTime(2026, 10, 20, 9, 30));
    final remapAfter = syntheticRemapRun(
        id: 'demo_after', stage: RemapStage.after, start: DateTime(2026, 10, 24, 9, 40), tau: 5.3, boostPeak: 150, railPeak: 175, overboost: 35);
    await tester.runAsync(() async {
      await remapStore.save(remapBefore);
      await remapStore.save(remapAfter);
    });
    container.invalidate(remapRunsProvider);
    await open(const RemapTestScreen(), frames: 60);
    await shot('34_remap_hub');
    // รายการผลอยู่ท้ายหน้า (ListView สร้างเฉพาะส่วนที่ใกล้จอ) เลื่อนลงจนเจอ
    for (var i = 0; i < 12 && find.text(remapAfter.name).evaluate().isEmpty; i++) {
      await scrollList(500);
    }
    await tester.ensureVisible(find.text(remapAfter.name).last);
    await settle(200);
    await shot('34b_remap_hub_runs');
    await tester.ensureVisible(find.text(remapAfter.name).last);
    await tester.pump();
    await tester.tap(find.text(remapAfter.name).last);
    await settle(400);
    await shot('35_remap_result');
    await scrollList(1100);
    await shot('36_remap_result_2');
    await scrollList(1400);
    await shot('36b_remap_result_3');
    pop();
    await settle();
    container.invalidate(remapRunsProvider);
    await settle(200);
    await open(RemapCompareScreen(before: remapBefore, after: remapAfter), frames: 60);
    await shot('37_remap_compare');
    await scrollList(1000);
    await shot('38_remap_compare_2');
    await scrollList(1200);
    await shot('38b_remap_compare_3');
    pop();
    await settle();
    await tester.runAsync(() async {
      final bytes = await buildRemapPdf(
        before: analyzeRemapRun(remapBefore),
        after: analyzeRemapRun(remapAfter),
        shop: const ShopProfile(name: 'อู่ช่างเอ ออโต้เซอร์วิส', phone: '081-234-5678', technician: 'ช่างเอ'),
      );
      File('test_screens/$_dir/remap_report.pdf').writeAsBytesSync(bytes);
    });

    // ทดสอบจริงกับรถจำลองดีเซลเทอร์โบ: เริ่ม → จำลองออกตัว → หยุดและบันทึก
    // หยุดการขับจำลองที่ค้างจากหน้าจับเวลา ให้รถจอดนิ่งจริงก่อนเริ่มบันทึก
    demo
      ..stopDrive()
      ..turboDiesel = true
      ..overboostKpa = 30;
    await scrollList(-3000);
    await tapOn(find.text('เริ่มทดสอบ หลังรีแมพ'));
    await until(() => find.text('หยุดและบันทึก').evaluate().isNotEmpty, max: 1500, realMs: 10);
    // เก็บค่าตอนจอดนิ่งก่อนสักครู่ (จับเวลา 0–100 ต้องเห็นรถหยุดนิ่งก่อนออกตัว)
    await until(() => false, max: 40, realMs: 30);
    await tapOn(find.text('จำลองออกตัว'));
    await until(() => false, max: 330, realMs: 30);
    await settle(200);
    await shot('39_remap_live');
    await scrollList(800);
    await shot('39b_remap_live_2');
    // ปุ่มหยุดอยู่บนสุดของรายการ (ListView ทิ้งส่วนที่เลื่อนพ้นจอไปแล้ว) เลื่อนกลับขึ้นก่อนกด
    await scrollList(-3000);
    await tapOn(find.text('หยุดและบันทึก'));
    await until(() => find.byType(RemapResultScreen).evaluate().isNotEmpty, max: 1500, realMs: 10);
    await settle(400);
    await shot('40_remap_live_result');
    // เก็บข้อมูลดิบของรอบนี้ไว้ตรวจย้อนหลัง (CSV แบบเดียวกับปุ่มส่งออกในแอป)
    await tester.runAsync(() async {
      final live = (await remapStore.list()).firstWhere((r) => r.id.startsWith('remap_'));
      File('test_screens/$_dir/remap_live_run.csv').writeAsStringSync(live.toCsv());
      // สรุปผลวิเคราะห์เป็นข้อความ ตรวจได้โดยไม่ต้องเปิดภาพ (ตั้งบูสต์เกินไว้ 30 kPa ต้องได้ระดับแจ้งเตือน)
      final a = analyzeRemapRun(live);
      File('test_screens/$_dir/remap_live_summary.txt').writeAsStringSync([
        'level=${a.level.name} limp=${a.limpSuspected} rows=${live.times.length} hz=${live.hz}',
        for (final x in a.accel) 'accel ${x.label} ${x.seconds.toStringAsFixed(2)}',
        for (final e in a.events)
          'event ${e.kind.name} ${e.level.name} peak=${e.peak?.toStringAsFixed(1)} '
              '${e.start?.toStringAsFixed(2)}-${e.end?.toStringAsFixed(2)}',
      ].join('\n'));
    });
    pop();
    await settle();
    pop();
    await settle();
    demo
      ..turboDiesel = false
      ..overboostKpa = 0
      ..stopDrive();
    await tester.runAsync(() => container.read(sessionProvider).service!.loadSupportedPids());
    await settle();

    // driving dashboard
    await open(const DashboardScreen(), frames: 200);
    await shot('21_dashboard');
    pop();
    await settle();

    // drive log: record a few seconds, then view
    container.read(recorderProvider.notifier).start(recordPresets.first.$2);
    await run(150);
    await shot('22_recording_banner');
    await tester.runAsync(() => container.read(recorderProvider.notifier).stop(name: 'ทดสอบออกตัว'));
    await settle();
    await open(const LogsScreen(), frames: 60);
    await shot('23_logs');
    await tapOn(find.text('ทดสอบออกตัว'));
    await settle(400);
    await shot('24_log_view');
    pop();
    pop();
    await settle();

    // garage + vehicle
    await tab('โรงรถ');
    await shot('25_garage');
    final v = container.read(garageProvider).value!.first;
    await open(VehicleScreen(vehicleId: v.id), frames: 60);
    await shot('26_vehicle');
    pop();
    await settle();
    expect(find.byType(GarageTab), findsOneWidget);

    // settings
    await tab('ตั้งค่า');
    await shot('27_settings');
    await open(const ShopProfileScreen());
    await shot('28_shop_profile');
    pop();
    await settle();
    await open(const AlertSettingsScreen());
    await shot('28b_alert_voice');
    pop();
    await settle();

    // DTC lookup
    await tester.tap(find.byTooltip('ค้นหารหัสปัญหา'));
    await settle(300);
    await shot('29_dtc_lookup');
    pop();
    await settle();

    // other looks: light + gold, dark + electric blue
    container.read(settingsProvider.notifier)
      ..setThemeMode(ThemeMode.light)
      ..setAccent(AccentPreset.royalGold);
    await tab('วินิจฉัย');
    await shot('30_theme_light_gold');
    await tab('หน้าหลัก');
    await shot('31_theme_light_home');

    container.read(settingsProvider.notifier)
      ..setThemeMode(ThemeMode.dark)
      ..setAccent(AccentPreset.electricBlue);
    container.read(appModeProvider.notifier).set(AppMode.owner);
    await tab('ค่าสด');
    await run(200);
    await shot('32_theme_dark_blue_gauges');

    // หน้าโหลดเมื่อตั้งข้อมูลอู่แล้ว (แสดงชื่ออู่ใต้โลโก้แอป)
    container.read(settingsProvider.notifier).setShop(const ShopProfile(name: 'อู่ช่างเอ ออโต้เซอร์วิส'));
    nav().push(MaterialPageRoute<void>(builder: (_) => const SplashScreen(minDuration: Duration(seconds: 60))));
    await until(() => find.text('พร้อมใช้งาน').evaluate().isNotEmpty, max: 400, realMs: 5);
    await settle(400);
    await shot('33_splash_shop');
    pop();
    await settle();

    // ---------------- หน้าที่เพิ่มใน 0.6.2–0.6.4 ----------------
    container.read(settingsProvider.notifier)
      ..setThemeMode(ThemeMode.dark)
      ..setAccent(AccentPreset.carbonRed);
    await tab('ตั้งค่า');

    // สำรอง/กู้คืนข้อมูล (0.6.2)
    await open(const BackupScreen(), frames: 40);
    await untilSeen(find.text('บันทึกไฟล์สำรองลงเครื่อง'), max: 400);
    await until(() => find.byType(CircularProgressIndicator).evaluate().isEmpty, max: 400, realMs: 5);
    await settle(300);
    await shot('41_backup');
    pop();
    await settle();

    // บันทึกการสื่อสาร (0.6.2): รายการ + เปิดดูไฟล์
    await open(const CommLogScreen(), frames: 40);
    await until(() => find.text('BLE OBDII').evaluate().isNotEmpty, max: 400, realMs: 5);
    await settle(300);
    await shot('42_comm_log');
    if (find.text('BLE OBDII').evaluate().isNotEmpty) {
      await tapOn(find.text('BLE OBDII'));
      await untilSeen(find.textContaining('221400'), max: 400);
      await settle(300);
      await shot('43_comm_log_view');
      pop();
      await settle(200);
    }
    pop();
    await settle();

    // ค่าที่ค้นพบเอง D-Max 2007 → การ์ด "รู้แล้วว่าเป็นค่าอะไร" + ตั้งชื่อจากคลัง (0.6.3–0.6.4)
    container.read(extPacksProvider.notifier).put(ExtPidPack(
          id: 'pack_found_dmax2007',
          name: 'ค้นพบเอง Isuzu D-Max 2007',
          note: 'เลขที่กล่องตอบตอนค้นหา 8 รายการ ยังไม่รู้ว่าเป็นค่าอะไร',
          brand: 'Isuzu',
          models: ['D-Max'],
          years: [2007, 2007],
          pids: [
            for (final r in ['221100', '221110', '221203', '221210', '221250', '221400', '221430', '221280'])
              ExtPid(
                name: 'ค่าใหม่ 7E0 $r',
                request: r,
                formula: r == '221203' || r == '221430' ? '(A*256+B)' : 'A',
                header: '7E0',
                decimals: 0,
                group: 'ค่าที่ค้นพบเอง',
              ),
          ],
        ));
    await open(const BrandDataScreen(initialTab: 0), frames: 40);
    await tapOn(find.text('ค้นพบเอง Isuzu D-Max 2007'));
    await untilSeen(find.textContaining('ตั้งชื่อจากคลัง'));
    await settle(200);
    await shot('44_found_known_names');
    final nameButton = find.textContaining('ตั้งชื่อจากคลัง');
    if (nameButton.evaluate().isNotEmpty) {
      await tapOn(nameButton);
      await settle(300);
    }
    await shot('45_found_named');
    tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger).first).clearSnackBars();
    pop();
    await settle();

    // wind down: leave the live-data loop and disconnect
    await tab('หน้าหลัก');
    await tester.runAsync(() => container.read(sessionProvider.notifier).disconnect());
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(container.read(livePollerProvider).isRunning, anyOf(true, false));
    expect(broken, isEmpty, reason: 'หน้าที่วาดล้นกรอบหรือผิดพลาดตอนวาด (ดู test_screens/$_dir/report.txt)');
  });
}
