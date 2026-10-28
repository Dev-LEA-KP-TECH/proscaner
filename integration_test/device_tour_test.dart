// ทดสอบบนเครื่องจริง (มือถือ/แท็บเล็ตที่เสียบ USB) หรือ iPhone จำลอง: เปิดทุกหน้าด้วยรถจำลอง
// รัน: DEVICE_TEST.bat  (flutter test integration_test/device_tour_test.dart -d <device id>)
//      iOS: .github/workflows/ios.yml (เครื่อง Mac ของ GitHub)
//
// ไม่แตะข้อมูลจริงในเครื่อง: ค่าตั้งค่าอยู่ในหน่วยความจำ, โรงรถ/ประวัติ/บันทึกการขับอยู่ในโฟลเดอร์ชั่วคราว
// และแอปทดสอบ (debug) ใช้ชื่อแพ็กเกจ .test แยกจากแอปจริง
//
// แต่ละขั้นทำต่อแม้ขั้นก่อนหน้าไม่ผ่าน (กลับหน้าหลักแล้วไปต่อ) จะได้เห็นทุกจุดที่พังในรอบเดียว
// แล้วสรุปท้ายสุดว่าขั้นไหนไม่ผ่าน
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:integration_test/integration_test.dart';
import 'package:obd_doctor/core/analysis/used_car.dart';
import 'package:obd_doctor/core/obd/ext_library.dart';
import 'package:obd_doctor/core/obd/ext_pid.dart';
import 'package:obd_doctor/core/transport/demo_transport.dart';
import 'package:obd_doctor/core/transport/wifi_transport.dart';
import 'package:obd_doctor/data/backup.dart';
import 'package:obd_doctor/data/garage_store.dart';
import 'package:obd_doctor/data/history_store.dart';
import 'package:obd_doctor/data/log_store.dart';
import 'package:obd_doctor/data/remap_store.dart';
import 'package:obd_doctor/main.dart';
import 'package:obd_doctor/report/pdf_report.dart';
import 'package:obd_doctor/state/backup_providers.dart';
import 'package:obd_doctor/state/ext_packs.dart';
import 'package:obd_doctor/state/live_poller.dart';
import 'package:obd_doctor/state/providers.dart';
import 'package:obd_doctor/state/remap_providers.dart';
import 'package:obd_doctor/ui/backup_screen.dart';
import 'package:obd_doctor/ui/comm_log_screen.dart';
import 'package:obd_doctor/ui/garage_tab.dart';
import 'package:obd_doctor/ui/home_screen.dart';
import 'package:obd_doctor/ui/pid_chart_screen.dart';
import 'package:obd_doctor/ui/settings_screens.dart';
import 'package:obd_doctor/ui/tools/battery_screen.dart';
import 'package:obd_doctor/ui/tools/brand_data_screen.dart';
import 'package:obd_doctor/ui/tools/dashboard_screen.dart';
import 'package:obd_doctor/ui/tools/did_scanner_screen.dart';
import 'package:obd_doctor/ui/tools/ecu_info_screen.dart';
import 'package:obd_doctor/ui/tools/ext_library_screen.dart';
import 'package:obd_doctor/ui/tools/logs_screen.dart';
import 'package:obd_doctor/ui/tools/mode06_screen.dart';
import 'package:obd_doctor/ui/tools/modules_screen.dart';
import 'package:obd_doctor/ui/tools/odometer_screen.dart';
import 'package:obd_doctor/ui/tools/performance_screen.dart';
import 'package:obd_doctor/ui/tools/remap_test_screen.dart';
import 'package:obd_doctor/ui/tools/used_car_screen.dart';
import 'package:obd_doctor/ui/vehicle_screen.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // วาดทุกเฟรมเหมือนแอปจริง: ค่าเริ่มต้นของตัวทดสอบวาดเฉพาะตอนสั่ง pump
  // ทำให้ภาพหน้าจอที่ถ่ายระหว่างทางค้างเฟรมเก่า (เช่นหน้ากำลังเลื่อนเข้า หรือโลโก้ที่ยังโหลดไม่ทันวาด)
  // และตำแหน่งที่ใช้กดอ้างอิงเฟรมเก่านั้น
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('ProScaner: ทุกหน้าใช้งานได้บนเครื่องจริง (รถจำลอง)', (tester) async {
    void log(String s) => debugPrint('DEVICE_TEST: $s');

    // พิมพ์ข้อความลงช่องกรอกผ่านตัวทดสอบ (ไม่ต้องเปิดคีย์บอร์ดจริงของเครื่อง)
    tester.testTextInput.register();
    addTearDown(tester.testTextInput.unregister);

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final tmp = await getTemporaryDirectory();
    final dir = Directory('${tmp.path}/proscaner_device_test');
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    dir.createSync(recursive: true);
    log('โฟลเดอร์ทดสอบ ${dir.path}');

    final container = ProviderContainer(overrides: [
      sharedPrefsProvider.overrideWithValue(prefs),
      historyStoreProvider.overrideWithValue(HistoryStore(directory: dir)),
      garageStoreProvider.overrideWithValue(GarageStore(directory: dir)),
      logStoreProvider.overrideWithValue(LogStore(directory: dir)),
      remapStoreProvider.overrideWithValue(RemapStore(directory: dir)),
    ]);
    addTearDown(container.dispose);

    Future<void> pause([int ms = 400]) => tester.pump(Duration(milliseconds: ms));

    Future<void> until(String what, bool Function() done, {int seconds = 30}) async {
      final end = DateTime.now().add(Duration(seconds: seconds));
      while (!done()) {
        if (DateTime.now().isAfter(end)) {
          throw TestFailure('รอ "$what" นานเกิน $seconds วินาที');
        }
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    bool shows(Finder f) => f.evaluate().isNotEmpty;

    // ใช้ Navigator ที่ถือหน้าหลักอยู่จริง (หน้าหลักอาจถูกหน้าอื่นบังอยู่ จึงไม่ข้ามหน้าที่มองไม่เห็น)
    // ใช้ได้ทั้ง Android และ iOS (iOS เปลี่ยนหน้าแบบเลื่อนข้าง ใช้เวลานานกว่า)
    NavigatorState nav() => Navigator.of(tester.element(find.byType(HomeScreen, skipOffstage: false)));

    // บอกสถานะทุกขั้น: ยังเชื่อมต่อรถอยู่ไหม และหน้าบนสุดชื่ออะไร (ใช้ดูว่าพังตรงไหนเวลาเทสต์บนเครื่องอื่น)
    void step(String s) {
      final connected = container.read(sessionProvider).isConnected;
      final titles = find
          .descendant(of: find.byType(AppBar), matching: find.byType(Text))
          .evaluate()
          .map((e) => (e.widget as Text).data ?? '')
          .where((t) => t.isNotEmpty)
          .take(3)
          .join(' / ');
      log('$s · เชื่อมต่อ=$connected · หัวหน้า=${titles.isEmpty ? '-' : titles}');
    }

    // ทำทีละขั้น: ถ้าขั้นนี้พัง จดไว้ กลับหน้าหลัก แล้วทำขั้นต่อไป
    final failed = <String>[];
    Future<void> stage(String name, Future<void> Function() body) async {
      step(name);
      try {
        await body();
        final error = tester.takeException();
        if (error != null) throw error;
      } catch (e) {
        failed.add(name);
        log('ไม่ผ่าน · $name · $e');
        try {
          nav().popUntil((r) => r.isFirst);
        } catch (_) {
          // ยังไม่มีหน้าหลัก
        }
        await pause(1500);
        tester.takeException();
      }
    }

    Future<void> open(Widget w, {int ms = 1500}) async {
      unawaited(nav().push(MaterialPageRoute<void>(builder: (_) => w)));
      await pause(ms);
    }

    // ปิดหน้าบนสุด: กดปุ่มย้อนกลับของหน้านั้นถ้ามี ไม่มีจึงสั่ง pop
    Future<void> back([int ms = 900]) async {
      final button = find.byType(BackButton);
      if (shows(button)) {
        await tester.tap(button.last);
      } else {
        nav().pop();
      }
      await pause(ms);
    }

    // แถบแท็บอยู่ในหน้าหลักเท่านั้น: ปิดหน้าที่เปิดซ้อนทั้งหมดก่อนกดแท็บ
    Future<void> tab(String label) async {
      nav().popUntil((r) => r.isFirst);
      await pause(900);
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(label)));
      await pause(900);
    }

    // รายการหลักของหน้าบนสุด: Scrollable แนวตั้งตัวที่ใหญ่ที่สุดที่ยังแตะถึงได้
    ScrollableState? mainScroll() {
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

    Future<void> scrollBy(double dy) async {
      final s = mainScroll();
      if (s == null) {
        log('(หน้านี้ไม่มีรายการให้เลื่อน)');
        return;
      }
      final p = s.position;
      unawaited(p.animateTo((p.pixels + dy).clamp(p.minScrollExtent, p.maxScrollExtent),
          duration: const Duration(milliseconds: 450), curve: Curves.easeOutCubic));
      await pause(900);
    }

    Future<void> toTop() async {
      final s = mainScroll();
      if (s != null) s.position.jumpTo(s.position.minScrollExtent);
      await pause(500);
    }

    // รอจนเห็นสิ่งที่ต้องการ ระหว่างรอเลื่อนรายการหลักลงทีละนิด: จอเล็กอย่าง iPhone ของที่อยู่ท้ายรายการ
    // ยังไม่ถูกสร้างจนกว่าจะเลื่อนถึง (เลื่อนสุดแล้วยังไม่เจอ กลับขึ้นบนสุดแล้ววนใหม่ เผื่อยังโหลดอยู่)
    Future<void> seek(String what, Finder f, {int seconds = 30}) async {
      final end = DateTime.now().add(Duration(seconds: seconds));
      while (!shows(f)) {
        if (DateTime.now().isAfter(end)) {
          throw TestFailure('หา "$what" ไม่เจอใน $seconds วินาที');
        }
        final s = mainScroll();
        if (s != null) {
          final p = s.position;
          p.jumpTo(p.pixels >= p.maxScrollExtent - 1 ? p.minScrollExtent : math.min(p.pixels + 300, p.maxScrollExtent));
        }
        await tester.pump(const Duration(milliseconds: 300));
      }
      await tester.ensureVisible(f.first);
      await pause(500);
    }

    // เลื่อนให้เห็นแล้วกด
    Future<void> press(String what, Finder f, {int ms = 600}) async {
      await seek(what, f);
      await tester.tap(f.first);
      await pause(ms);
    }

    await stage('1 เปิดแอป', () async {
      await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const ObdDoctorApp()));
      await until('หน้าหลัก', () => shows(find.text('เชื่อมต่อตัวสแกน')));
      // ไฟล์ที่ฝังในแอป: รายชื่อไฟล์ (AssetManifest) และโลโก้ยี่ห้อต้องอ่านได้บนเครื่องนี้
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      final logos = manifest.listAssets().where((a) => a.startsWith('assets/brand_logos/') && a.endsWith('.png')).toList();
      final toyota = await rootBundle.load('assets/brand_logos/toyota.png');
      log('ไฟล์ในแอป: โลโก้ ${logos.length} ไฟล์, toyota.png ${toyota.lengthInBytes} ไบต์');
      expect(logos, contains('assets/brand_logos/toyota.png'), reason: 'รายชื่อไฟล์ในแอปต้องมีโลโก้ Toyota');
    });

    await stage('2 เชื่อมต่อรถจำลอง', () async {
      await container.read(sessionProvider.notifier).connect(DemoTransport());
      await until('เชื่อมต่อรถจำลอง', () => container.read(sessionProvider).isConnected && shows(find.text('สแกนด่วน')),
          seconds: 60);
      await pause(1500);
      expect(container.read(sessionProvider).vehicleId, isNotNull, reason: 'ต้องระบุรถอัตโนมัติจาก VIN');
    });

    await stage('3 สแกนทั้งคัน', () async {
      await tab('วินิจฉัย');
      await container.read(scanProvider.notifier).run(allModules: true);
      await pause(1500);
      expect(container.read(scanProvider).report, isNotNull, reason: 'สแกนแล้วต้องได้ผล');
      await scrollBy(900);
      container.read(appModeProvider.notifier).set(AppMode.mechanic);
      await pause(900);
      await scrollBy(700);
    });

    await stage('4 หน้าหลักโหมดช่าง', () async {
      await tab('หน้าหลัก');
      await scrollBy(700);
    });

    await stage('5 ค่าสด', () async {
      container.read(appModeProvider.notifier).set(AppMode.owner);
      await tab('ค่าสด');
      await pause(4000);
      container.read(appModeProvider.notifier).set(AppMode.mechanic);
      await pause(4000);
      await tester.tap(find.text('รอบเครื่องยนต์').first);
      await until('กราฟรอบเครื่อง', () => shows(find.byType(PidChartScreen)), seconds: 20);
      await pause(3000);
      await back();
      await until('ปิดกราฟ', () => !shows(find.byType(PidChartScreen)), seconds: 20);
      await tab('หน้าหลัก');
    });

    await stage('6 เช็คเลขไมล์', () async {
      await open(const OdometerScreen());
      await until('ช่องเลขไมล์', () => shows(find.byType(TextField)), seconds: 20);
      await tester.enterText(find.byType(TextField).first, '186,500');
      await press('ปุ่มอ่านข้อมูลและตรวจ', find.text('อ่านข้อมูลและตรวจ'));
      await seek('ผลเช็คเลขไมล์', find.text('ข้อมูลที่อ่านได้'), seconds: 90);
      await pause(800);
      await scrollBy(800);
      await back();
    });

    await stage('7 ตรวจรถมือสอง', () async {
      await open(const UsedCarScreen());
      await until('ช่องเลขไมล์รถมือสอง', () => shows(find.byType(TextField)), seconds: 20);
      await tester.enterText(find.byType(TextField).first, '98,000');
      final before = container.read(scanProvider).report?.snapshot.time;
      await press('ปุ่มเริ่มตรวจ', find.textContaining('เริ่มตรวจ'));
      // ตรวจเสร็จ = ได้ผลสแกนครั้งใหม่ และปุ่มกลับจาก "กำลังตรวจ…"
      await until(
          'ผลตรวจรถมือสอง',
          () =>
              container.read(scanProvider).report?.snapshot.time != before && !shows(find.text('กำลังตรวจ…')),
          seconds: 180);
      // ผลและปุ่มส่งรายงานอยู่ท้ายรายการ (จอ iPhone ต้องเลื่อนลงไปก่อน)
      await seek('ปุ่มส่งรายงาน PDF', find.text('ส่งรายงาน PDF'));
      await pause(1000);
    });

    await stage('8 สร้างรายงาน PDF', () async {
      final report = container.read(scanProvider).report!;
      final bytes = await buildReportPdf(ReportInput(
        report: report,
        shop: const ShopProfile(name: 'อู่ทดสอบ', phone: '080-000-0000', address: 'กรุงเทพฯ', technician: 'ช่างทดสอบ'),
        usedCar: evaluateUsedCar(report: report, modules: report.snapshot.modules),
      ));
      final pdf = File('${dir.path}/report.pdf')..writeAsBytesSync(bytes);
      expect(pdf.lengthSync(), greaterThan(20000), reason: 'ไฟล์ PDF ต้องมีเนื้อหา');
      log('PDF ${pdf.lengthSync()} ไบต์');
      await back();
    });

    await stage('9 ข้อมูลกล่อง ECU', () async {
      await open(const EcuInfoScreen(), ms: 4000);
      await back();
    });

    await stage('10 Mode 06', () async {
      await open(const Mode06Screen());
      await press('ปุ่มอ่านผลทดสอบ', find.text('อ่านผลทดสอบ'));
      await seek('ผล Mode 06', find.textContaining('ทดสอบทั้งหมด'), seconds: 90);
      await pause(800);
      await back();
    });

    await stage('11 กล่องอื่น (ABS)', () async {
      await open(const ModulesScreen(), ms: 2500);
      final abs = container.read(modulesProvider).firstWhere((m) => m.tx == '7B0');
      await open(ModuleDetailScreen(module: abs));
      await press('ปุ่มอ่านรหัส', find.text('อ่านรหัส'));
      await seek('รหัส ABS', find.text('C0035-31'), seconds: 60);
      await pause(800);
      await back();
      await back();
    });

    await stage('12 เช็คแบตเตอรี่', () async {
      await open(const BatteryScreen(), ms: 2500);
      await press('ปุ่มเริ่มวัด', find.text('เริ่ม'));
      await seek('ผลเช็คแบต', find.text('วัดใหม่'), seconds: 90);
      await pause(800);
      await back();
    });

    await stage('13 จับเวลาอัตราเร่ง', () async {
      await open(const PerformanceScreen(), ms: 2000);
      await press('ปุ่มเตรียมพร้อม', find.text('เตรียมพร้อม'), ms: 500);
      await press('ปุ่มจำลองออกตัว', find.text('จำลองออกตัว'));
      await until('จบการจับเวลา', () => shows(find.text('เตรียมพร้อม')), seconds: 120);
      await pause(800);
      await back();
    });

    await stage('14 แดชบอร์ดขับรถ', () async {
      await open(const DashboardScreen(), ms: 5000);
      await back();
      // iPhone: ปิดแดชบอร์ด (ที่บังคับจอนอน) แล้วต้องกลับเป็นแนวตั้งเอง และอยู่แนวตั้งต่อ ไม่ค้างแนวนอน
      final view = tester.view;
      bool portrait() => view.physicalSize.height > view.physicalSize.width;
      if (Platform.isIOS && view.physicalSize.shortestSide / view.devicePixelRatio < 600) {
        await until('จอกลับเป็นแนวตั้งหลังปิดแดชบอร์ด', portrait, seconds: 10);
        await pause(2500);
        expect(portrait(), isTrue, reason: 'iPhone ต้องอยู่แนวตั้งต่อหลังปิดแดชบอร์ด');
      }
    });

    await stage('15 บันทึกการขับ', () async {
      container.read(recorderProvider.notifier).start(recordPresets.first.$2);
      await pause(5000);
      await container.read(recorderProvider.notifier).stop(name: 'ทดสอบบนเครื่อง');
      await pause(800);
      await open(const LogsScreen(), ms: 2000);
      await press('บันทึกที่เพิ่งทำ', find.text('ทดสอบบนเครื่อง'), ms: 2500);
      await back();
      await back();
    });

    await stage('15b ทดสอบก่อน/หลังรีแมพ (ขับจำลอง แล้วบันทึกผล)', () async {
      await open(const RemapTestScreen(), ms: 2000);
      await press('ปุ่มเริ่มทดสอบก่อนรีแมพ', find.text('เริ่มทดสอบ ก่อนรีแมพ'), ms: 1500);
      // หน้าทดสอบอ่านรหัสปัญหาและตรวจว่ารถรองรับค่าอะไรก่อน แล้วจึงเริ่มบันทึก
      await until('เริ่มบันทึกการทดสอบรีแมพ', () => shows(find.text('จำลองออกตัว')), seconds: 60);
      await press('ปุ่มจำลองออกตัว', find.text('จำลองออกตัว'), ms: 12000);
      await press('ปุ่มหยุดและบันทึก', find.text('หยุดและบันทึก'));
      await until('ผลทดสอบรีแมพ', () => shows(find.byType(RemapResultScreen)), seconds: 60);
      await pause(1500);
      await scrollBy(900);
      final runs = await container.read(remapStoreProvider).list();
      expect(runs, hasLength(1), reason: 'บันทึกผลทดสอบรีแมพลงเครื่องแล้ว');
      log('ผลรีแมพ ${runs.first.rows.length} แถว');
      await back();
      await back();
    });

    await stage('16 โรงรถ', () async {
      await tab('โรงรถ');
      expect(find.byType(GarageTab), findsOneWidget);
      final v = container.read(garageProvider).value!.first;
      await open(VehicleScreen(vehicleId: v.id), ms: 2500);
      await scrollBy(800);
      await back();
    });

    await stage('17 ตั้งค่า', () async {
      await tab('ตั้งค่า');
      await scrollBy(800);
      await open(const ShopProfileScreen());
      await back();
    });

    await stage('18 ค้นหารหัสปัญหา', () async {
      await tester.tap(find.byTooltip('ค้นหารหัสปัญหา'));
      await pause(2000);
      await back();
    });

    await stage('19 ธีมสว่าง/สีทอง และมืด/สีฟ้า', () async {
      container.read(settingsProvider.notifier)
        ..setThemeMode(ThemeMode.light)
        ..setAccent(AccentPreset.royalGold);
      await tab('วินิจฉัย');
      await tab('หน้าหลัก');
      container.read(settingsProvider.notifier)
        ..setThemeMode(ThemeMode.dark)
        ..setAccent(AccentPreset.electricBlue);
      container.read(appModeProvider.notifier).set(AppMode.owner);
      await tab('ค่าสด');
      await pause(3000);
      await tab('หน้าหลัก');
    });

    await stage('20 เชื่อมต่อผ่านหน้าจอเชื่อมต่อ (เรียก Bluetooth จริงของเครื่อง แล้วเลือกโหมดทดลอง)', () async {
      await container.read(sessionProvider.notifier).disconnect();
      await until('ปุ่มเชื่อมต่อ', () => shows(find.text('เชื่อมต่อตัวสแกน')));
      await tester.tap(find.text('เชื่อมต่อตัวสแกน').first);
      final demoTab = find.descendant(of: find.byWidgetPredicate((w) => w is SegmentedButton), matching: find.text('ทดลอง'));
      await until('หน้าเชื่อมต่อ', () => shows(demoTab));
      await pause(3000);
      await tester.tap(demoTab);
      await pause(1000);
      await press('ปุ่มเริ่มโหมดทดลอง', find.text('เริ่มโหมดทดลอง'));
      await until('เชื่อมต่อจากหน้าจอ', () => container.read(sessionProvider).isConnected && shows(find.text('สแกนด่วน')),
          seconds: 60);
      await pause(1500);
    });

    // ใช้ร่วมกันหลายขั้นด้านล่าง
    late final List<ExtLibraryEntry> libIndex;
    late final ExtLibraryEntry hiluxEntry;
    late final ExtPidPack hilux;

    await stage('21 ค่าเฉพาะยี่ห้อ: โหลดคลังชุดข้อมูลจากไฟล์ในแอป', () async {
      final lib = container.read(extLibraryProvider);
      libIndex = await lib.index();
      expect(libIndex.length, greaterThanOrEqualTo(30), reason: 'คลังต้องโหลดจาก assets ในแอปได้');
      hiluxEntry = libIndex.firstWhere((e) => e.lib == 'toyota_hilux');
      hilux = await lib.pack(hiluxEntry);
      expect(hilux.pids.length, hiluxEntry.count);
      log('คลัง ${libIndex.length} ชุด, Hilux ${hilux.pids.length} ค่า');
    });

    await stage('22 หาชุดที่ตรงกับรถคันนี้ (ทดสอบทุกชุดของยี่ห้อ)', () async {
      await open(ExtMatchScreen(onUse: (_) {}), ms: 1500);
      await press('ปุ่มเริ่มทดสอบ', find.textContaining('เริ่มทดสอบ'), ms: 1500);
      await until('ผลหาชุดที่ตรง', () => shows(find.textContaining('เริ่มทดสอบ')), seconds: 180);
      await seek('ชุด Hilux ในผลทดสอบ (รถจำลองตอบคำสั่งแบบ Hilux)', find.text(hiluxEntry.name));
      await pause(800);
      await back();
    });

    await stage('23 ใช้ชุด Hilux แล้วอ่านค่า', () async {
      container.read(extPacksProvider.notifier).adopt(hilux);
      await open(const BrandDataScreen(), ms: 2500);
      await press('ปุ่มอ่านครั้งเดียว', find.text('อ่านครั้งเดียว'));
      await seek('ค่าหัวฉีดจากรถจำลอง', find.textContaining('22112B →'), seconds: 90);
      await pause(1000);
    });

    await stage('24 รายละเอียดค่า: ดูไบต์สด', () async {
      if (!shows(find.byType(BrandDataScreen))) await open(const BrandDataScreen(), ms: 2500);
      await press('แถวค่าชดเชยหัวฉีดสูบ 1', find.text('ค่าชดเชยหัวฉีด (Feedback) สูบ 1'), ms: 1500);
      await press('ปุ่มดูไบต์สด', find.text('ดูไบต์สด'));
      await until('ไบต์สด', () => shows(find.text('หยุดดูไบต์สด')), seconds: 20);
      await pause(3000);
      await press('ปุ่มหยุดดูไบต์สด', find.text('หยุดดูไบต์สด'), ms: 800);
      await back();
      await back();
    });

    await stage('25 ค้นหาค่าที่กล่องตอบ (ช่วงตามชุดของรถคันนี้)', () async {
      await open(const DidScannerScreen(), ms: 2000);
      await press('ปุ่มเริ่มค้นหา', find.text('เริ่มค้นหา'), ms: 500);
      // เลขที่เจอต้องขึ้นระหว่างค้นหา ไม่ต้องรอจบ
      await seek('เจอค่าที่กล่องตอบ', find.text('22112B'), seconds: 120);
      await toTop();
      await press('ปุ่มหยุดค้นหา', find.textContaining('หยุด ('));
      await until('หยุดค้นหา', () => shows(find.text('เริ่มค้นหา')), seconds: 30);
      await pause(800);
      await back();
    });

    await stage('26 เชื่อมต่อแบบ Wi-Fi (ซ็อกเก็ตจริงของเครื่อง ต่อกับตัวสแกนจำลองที่เปิดพอร์ตในเครื่องเดียวกัน)', () async {
      await container.read(sessionProvider.notifier).disconnect();
      await pause(800);
      // ตัวสแกน Wi-Fi จำลอง: รับคำสั่งทาง TCP แล้วตอบแบบ ELM327 (ใช้ตัวเดียวกับโหมดทดลอง)
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((client) async {
        final elm = DemoTransport();
        await elm.connect();
        final toApp = elm.incoming.listen((b) {
          try {
            client.add(b);
          } catch (_) {
            // แอปปิดการเชื่อมต่อไปแล้ว
          }
        });
        client.listen(
          (b) => elm.write(b).catchError((Object _) {}),
          onDone: () {
            toApp.cancel();
            elm.disconnect();
            client.destroy();
          },
          onError: (Object _) => client.destroy(),
          cancelOnError: true,
        );
      });
      await container.read(sessionProvider.notifier).connect(WifiTransport(host: '127.0.0.1', port: server.port));
      await until('เชื่อมต่อ Wi-Fi', () => container.read(sessionProvider).isConnected, seconds: 60);
      final s = container.read(sessionProvider);
      expect(s.transport, isA<WifiTransport>());
      expect(s.vin, DemoTransport.defaultVin, reason: 'อ่าน VIN ผ่าน Wi-Fi ได้');
      log('${s.transport!.displayName} · VIN ${s.vin}');
      await until('ระบุรถจาก VIN (Wi-Fi)', () => container.read(sessionProvider).vehicleId != null, seconds: 30);
      final scanned = await container.read(scanProvider.notifier).run();
      expect(scanned, isTrue, reason: 'สแกนด่วนผ่าน Wi-Fi ได้');
      expect(container.read(scanProvider).report, isNotNull, reason: 'สแกนผ่าน Wi-Fi แล้วต้องได้ผล');
      await tab('ค่าสด');
      await pause(4000);
      expect(container.read(sessionProvider).isConnected, isTrue, reason: 'อ่านค่าสดผ่าน Wi-Fi แล้วยังเชื่อมต่ออยู่');
      await tab('หน้าหลัก');
      await container.read(sessionProvider.notifier).disconnect();
      await pause(800);
    });

    await stage('26b บันทึกการสื่อสารและไฟล์สำรอง (เขียน/อ่านไฟล์ในเครื่อง)', () async {
      // การเชื่อมต่อ Wi-Fi ในขั้นก่อนต้องถูกบันทึกลงไฟล์ในโฟลเดอร์เอกสารของแอป
      final comm = container.read(commLogProvider);
      await comm.flush();
      final sessions = await comm.sessions();
      expect(sessions.any((s) => s.title.startsWith('Wi-Fi 127.0.0.1')), isTrue,
          reason: 'บันทึกการสื่อสารของการเชื่อมต่อ Wi-Fi ต้องถูกเขียนลงไฟล์');
      await open(const CommLogScreen(), ms: 2000);
      await press('บันทึกการเชื่อมต่อ Wi-Fi', find.textContaining('Wi-Fi 127.0.0.1'), ms: 2500);
      expect(find.byType(CommLogViewer), findsOneWidget, reason: 'เปิดอ่านบันทึกได้');
      await back();
      await back();
      // ไฟล์สำรอง: รวบรวมข้อมูลทั้งเครื่องแล้วอ่านกลับได้ครบ
      final data = await container.read(backupServiceProvider).collect(appVersion: 'tour');
      final bytes = data.encode();
      final copy = BackupData.parse(bytes);
      expect(copy.vehicles.length, data.vehicles.length);
      expect(copy.history.length, data.history.length);
      expect(copy.remapRuns.length, data.remapRuns.length);
      log('ไฟล์สำรอง ${bytes.length} ไบต์ · รถ ${data.vehicles.length} · ประวัติ ${data.history.length} · '
          'บันทึกขับ ${data.driveLogs.length} · รีแมพ ${data.remapRuns.length}');
      await open(const BackupScreen(), ms: 2500);
      await scrollBy(700);
      await back();
    });

    await stage('27 เสียงพูดภาษาไทยของเครื่อง (ไม่พูดออกเสียง แค่ตรวจว่ามี)', () async {
      try {
        final th = await FlutterTts().isLanguageAvailable('th-TH');
        log('มีเสียงภาษาไทยในเครื่อง: $th');
      } catch (e) {
        log('ตรวจเสียงภาษาไทยไม่ได้: $e');
      }
    });

    await stage('28 ปิดการเชื่อมต่อ', () async {
      await container.read(sessionProvider.notifier).disconnect();
      await pause(1000);
      await tester.pumpWidget(const SizedBox());
      await pause(1000);
    });

    if (failed.isEmpty) {
      log('ผ่านทุกขั้นตอน');
    } else {
      log('ไม่ผ่าน ${failed.length} ขั้น: ${failed.join(' | ')}');
      fail('ไม่ผ่าน ${failed.length} ขั้น: ${failed.join(' | ')}');
    }
  }, timeout: const Timeout(Duration(minutes: 30)));
}
