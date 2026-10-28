// ทดสอบบนเครื่องจริง (มือถือ/แท็บเล็ตที่เสียบ USB): เปิดทุกหน้าด้วยรถจำลอง
// รัน: DEVICE_TEST.bat  (flutter test integration_test/device_tour_test.dart -d <device id>)
//
// ไม่แตะข้อมูลจริงในเครื่อง: ค่าตั้งค่าอยู่ในหน่วยความจำ, โรงรถ/ประวัติ/บันทึกการขับอยู่ในโฟลเดอร์ชั่วคราว
// และแอปทดสอบ (debug) ใช้ชื่อแพ็กเกจ .test แยกจากแอปจริง
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:integration_test/integration_test.dart';
import 'package:obd_doctor/core/analysis/used_car.dart';
import 'package:obd_doctor/core/transport/demo_transport.dart';
import 'package:obd_doctor/data/garage_store.dart';
import 'package:obd_doctor/data/history_store.dart';
import 'package:obd_doctor/data/log_store.dart';
import 'package:obd_doctor/main.dart';
import 'package:obd_doctor/report/pdf_report.dart';
import 'package:obd_doctor/state/ext_packs.dart';
import 'package:obd_doctor/state/live_poller.dart';
import 'package:obd_doctor/state/providers.dart';
import 'package:obd_doctor/ui/garage_tab.dart';
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
import 'package:obd_doctor/ui/tools/used_car_screen.dart';
import 'package:obd_doctor/ui/vehicle_screen.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

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
    NavigatorState nav() => tester.state<NavigatorState>(find.byType(Navigator).first);

    Future<void> open(Widget w, {int ms = 1500}) async {
      nav().push(MaterialPageRoute<void>(builder: (_) => w));
      await pause(ms);
    }

    Future<void> back([int ms = 700]) async {
      nav().pop();
      await pause(ms);
    }

    Future<void> tab(String label) async {
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(label)));
      await pause(900);
    }

    Future<void> scrollBy(double dy) async {
      await tester.drag(find.byType(Scrollable).last, Offset(0, -dy));
      await pause(600);
    }

    log('1 เปิดแอป');
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const ObdDoctorApp()));
    await until('หน้าหลัก', () => shows(find.text('เชื่อมต่อตัวสแกน')));

    log('2 เชื่อมต่อรถจำลอง');
    await container.read(sessionProvider.notifier).connect(DemoTransport());
    await until('เชื่อมต่อรถจำลอง', () => container.read(sessionProvider).isConnected && shows(find.text('สแกนด่วน')),
        seconds: 60);
    await pause(1500);
    expect(container.read(sessionProvider).vehicleId, isNotNull, reason: 'ต้องระบุรถอัตโนมัติจาก VIN');

    log('3 สแกนทั้งคัน');
    await tab('วินิจฉัย');
    await container.read(scanProvider.notifier).run(allModules: true);
    await pause(1500);
    expect(container.read(scanProvider).report, isNotNull, reason: 'สแกนแล้วต้องได้ผล');
    await scrollBy(900);
    container.read(appModeProvider.notifier).set(AppMode.mechanic);
    await pause(900);
    await scrollBy(700);

    log('4 หน้าหลักโหมดช่าง');
    await tab('หน้าหลัก');
    await scrollBy(700);

    log('5 ค่าสด');
    container.read(appModeProvider.notifier).set(AppMode.owner);
    await tab('ค่าสด');
    await pause(4000);
    container.read(appModeProvider.notifier).set(AppMode.mechanic);
    await pause(4000);
    await tester.tap(find.text('รอบเครื่องยนต์').first);
    await pause(3000);
    await back();
    await tab('หน้าหลัก');

    log('6 เช็คเลขไมล์');
    await open(const OdometerScreen());
    await tester.enterText(find.byType(TextField).first, '186,500');
    await tester.tap(find.text('อ่านข้อมูลและตรวจ'));
    await until('ผลเช็คเลขไมล์', () => shows(find.text('ข้อมูลที่อ่านได้')), seconds: 90);
    await pause(800);
    await scrollBy(800);
    await back();

    log('7 ตรวจรถมือสอง');
    await open(const UsedCarScreen());
    await tester.enterText(find.byType(TextField).first, '98,000');
    await tester.tap(find.textContaining('เริ่มตรวจ'));
    await until('ผลตรวจรถมือสอง', () => shows(find.text('ส่งรายงาน PDF')), seconds: 180);
    await pause(1000);
    await scrollBy(700);

    log('8 สร้างรายงาน PDF');
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

    log('9 ข้อมูลกล่อง ECU');
    await open(const EcuInfoScreen(), ms: 4000);
    await back();

    log('10 Mode 06');
    await open(const Mode06Screen());
    await tester.tap(find.text('อ่านผลทดสอบ'));
    await until('ผล Mode 06', () => shows(find.textContaining('ทดสอบทั้งหมด')), seconds: 90);
    await pause(800);
    await back();

    log('11 กล่องอื่น (ABS)');
    await open(const ModulesScreen(), ms: 2500);
    final abs = container.read(modulesProvider).firstWhere((m) => m.tx == '7B0');
    await open(ModuleDetailScreen(module: abs));
    await tester.tap(find.text('อ่านรหัส'));
    await until('รหัส ABS', () => shows(find.text('C0035-31')), seconds: 60);
    await pause(800);
    await back();
    await back();

    log('12 เช็คแบตเตอรี่');
    await open(const BatteryScreen(), ms: 2500);
    await tester.tap(find.text('เริ่ม').first);
    await until('ผลเช็คแบต', () => shows(find.text('วัดใหม่')), seconds: 90);
    await pause(800);
    await back();

    log('13 จับเวลาอัตราเร่ง');
    await open(const PerformanceScreen(), ms: 2000);
    await tester.tap(find.text('เตรียมพร้อม'));
    await pause(500);
    await tester.tap(find.text('จำลองออกตัว'));
    await until('จบการจับเวลา', () => shows(find.text('เตรียมพร้อม')), seconds: 120);
    await pause(800);
    await back();

    log('14 แดชบอร์ดขับรถ');
    await open(const DashboardScreen(), ms: 5000);
    await back();

    log('15 บันทึกการขับ');
    container.read(recorderProvider.notifier).start(recordPresets.first.$2);
    await pause(5000);
    await container.read(recorderProvider.notifier).stop(name: 'ทดสอบบนเครื่อง');
    await pause(800);
    await open(const LogsScreen(), ms: 2000);
    await tester.tap(find.text('ทดสอบบนเครื่อง'));
    await pause(2500);
    await back();
    await back();

    log('16 โรงรถ');
    await tab('โรงรถ');
    expect(find.byType(GarageTab), findsOneWidget);
    final v = container.read(garageProvider).value!.first;
    await open(VehicleScreen(vehicleId: v.id), ms: 2500);
    await scrollBy(800);
    await back();

    log('17 ตั้งค่า');
    await tab('ตั้งค่า');
    await scrollBy(800);
    await open(const ShopProfileScreen());
    await back();

    log('18 ค้นหารหัสปัญหา');
    await tester.tap(find.byTooltip('ค้นหารหัสปัญหา'));
    await pause(2000);
    await back();

    log('19 ธีมสว่าง/สีทอง และมืด/สีฟ้า');
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

    log('20 เชื่อมต่อผ่านหน้าจอเชื่อมต่อ (เรียก Bluetooth จริงของเครื่อง แล้วเลือกโหมดทดลอง)');
    await container.read(sessionProvider.notifier).disconnect();
    await until('ปุ่มเชื่อมต่อ', () => shows(find.text('เชื่อมต่อตัวสแกน')));
    await tester.tap(find.text('เชื่อมต่อตัวสแกน'));
    await until('หน้าเชื่อมต่อ', () => shows(find.text('ทดลอง')));
    await pause(3000);
    await tester.tap(find.text('ทดลอง'));
    await pause(1000);
    await tester.tap(find.text('เริ่มโหมดทดลอง'));
    await until('เชื่อมต่อจากหน้าจอ', () => container.read(sessionProvider).isConnected && shows(find.text('สแกนด่วน')),
        seconds: 60);
    await pause(1500);

    log('21 ค่าเฉพาะยี่ห้อ: โหลดคลังชุดข้อมูลจากไฟล์ในแอป');
    final lib = container.read(extLibraryProvider);
    final libIndex = await lib.index();
    expect(libIndex.length, greaterThanOrEqualTo(30), reason: 'คลังต้องโหลดจาก assets ในแอปได้');
    final hiluxEntry = libIndex.firstWhere((e) => e.lib == 'toyota_hilux');
    final hilux = await lib.pack(hiluxEntry);
    expect(hilux.pids.length, hiluxEntry.count);
    log('คลัง ${libIndex.length} ชุด, Hilux ${hilux.pids.length} ค่า');

    log('22 หาชุดที่ตรงกับรถคันนี้ (ทดสอบทุกชุดของยี่ห้อ)');
    await open(ExtMatchScreen(onUse: (_) {}), ms: 1500);
    await tester.tap(find.textContaining('เริ่มทดสอบ'));
    await pause(1500);
    await until('ผลหาชุดที่ตรง', () => shows(find.textContaining('เริ่มทดสอบ')), seconds: 180);
    expect(find.text(hiluxEntry.name), findsWidgets, reason: 'รถจำลองตอบคำสั่งแบบ Hilux');
    await pause(800);
    await back();

    log('23 ใช้ชุด Hilux แล้วอ่านค่า');
    container.read(extPacksProvider.notifier).adopt(hilux);
    await open(const BrandDataScreen(), ms: 2500);
    await tester.tap(find.text('อ่านครั้งเดียว'));
    await until('ค่าหัวฉีดจากรถจำลอง', () => shows(find.textContaining('22112B →')), seconds: 90);
    await pause(1000);

    log('24 รายละเอียดค่า: ดูไบต์สด');
    final row = find.text('ค่าชดเชยหัวฉีด (Feedback) สูบ 1').first;
    await tester.ensureVisible(row);
    await pause(500);
    await tester.tap(row);
    await pause(1500);
    await tester.tap(find.text('ดูไบต์สด'));
    await until('ไบต์สด', () => shows(find.text('หยุดดูไบต์สด')), seconds: 20);
    await pause(3000);
    await tester.tap(find.text('หยุดดูไบต์สด'));
    await pause(800);
    await back();
    await back();

    log('25 ค้นหาค่าที่กล่องตอบ (ช่วงตามชุดของรถคันนี้)');
    await open(const DidScannerScreen(), ms: 2000);
    final start = find.text('เริ่มค้นหา');
    await tester.ensureVisible(start);
    await pause(500);
    await tester.tap(start);
    // เลขที่เจอต้องขึ้นระหว่างค้นหา ไม่ต้องรอจบ
    await until('เจอค่าที่กล่องตอบ', () => shows(find.text('22112B')), seconds: 120);
    await tester.tap(find.textContaining('หยุด ('));
    await until('หยุดค้นหา', () => shows(find.text('เริ่มค้นหา')), seconds: 30);
    await pause(800);
    await back();

    log('26 เสียงพูดภาษาไทยของเครื่อง (ไม่พูดออกเสียง แค่ตรวจว่ามี)');
    try {
      final th = await FlutterTts().isLanguageAvailable('th-TH');
      log('มีเสียงภาษาไทยในเครื่อง: $th');
    } catch (e) {
      log('ตรวจเสียงภาษาไทยไม่ได้: $e');
    }

    log('27 ปิดการเชื่อมต่อ');
    await container.read(sessionProvider.notifier).disconnect();
    await pause(1000);
    await tester.pumpWidget(const SizedBox());
    await pause(1000);
    log('ผ่านทุกขั้นตอน');
  }, timeout: const Timeout(Duration(minutes: 20)));
}
