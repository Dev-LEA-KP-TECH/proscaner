import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/analysis/vehicle_catalog.dart';
import '../core/analysis/vin.dart';
import '../core/app_info.dart';
import '../core/diagnosis/diagnosis.dart';
import '../core/elm/elm327.dart';
import '../core/obd/dtc.dart';
import '../core/obd/dtc_database.dart';
import '../core/obd/obd_service.dart';
import '../core/obd/pids.dart';
import '../core/transport/adapter_memory.dart';
import '../core/transport/demo_transport.dart';
import '../core/transport/obd_transport.dart';
import '../core/uds/uds_client.dart';
import '../data/comm_log.dart';
import '../data/garage_store.dart';
import '../data/history_store.dart';
import '../data/log_store.dart';
import 'settings.dart';

export 'settings.dart';

// ---------------- โหมดผู้ใช้ ----------------

enum AppMode {
  owner,
  mechanic;

  String get labelTh => this == AppMode.owner ? 'เจ้าของรถ' : 'ช่าง';
}

class AppModeNotifier extends Notifier<AppMode> {
  static const _key = 'app_mode';

  @override
  AppMode build() {
    final saved = ref.watch(sharedPrefsProvider).getString(_key);
    return AppMode.values.firstWhere((m) => m.name == saved, orElse: () => AppMode.owner);
  }

  void set(AppMode m) {
    state = m;
    ref.read(sharedPrefsProvider).setString(_key, m.name);
  }
}

final appModeProvider = NotifierProvider<AppModeNotifier, AppMode>(AppModeNotifier.new);

// ---------------- ข้อมูลพื้นฐาน ----------------

final dtcDatabaseProvider = FutureProvider<DtcDatabase>((ref) => DtcDatabase.load());

final historyStoreProvider = Provider<HistoryStore>((ref) => HistoryStore());
final garageStoreProvider = Provider<GarageStore>((ref) => GarageStore());
final logStoreProvider = Provider<LogStore>((ref) => LogStore());

final historyProvider = FutureProvider<List<VehicleSnapshot>>(
    (ref) => ref.watch(historyStoreProvider).load());

final logsProvider = FutureProvider<List<DriveLog>>((ref) => ref.watch(logStoreProvider).list());

/// เลือกตัววินิจฉัยตรงนี้จุดเดียว เฟส 2 เปลี่ยนเป็น AiDiagnosisEngine
final diagnosisEngineProvider = FutureProvider<DiagnosisEngine>((ref) async {
  final db = await ref.watch(dtcDatabaseProvider.future);
  return RuleBasedDiagnosisEngine(db);
});

// ---------------- โรงรถ ----------------

class GarageNotifier extends AsyncNotifier<List<Vehicle>> {
  GarageStore get _store => ref.read(garageStoreProvider);

  /// รถจากโหมดทดลอง: แสดงในแอประหว่างทดลอง แต่ไม่บันทึกลงเครื่อง
  final _transient = <String>{};

  @override
  Future<List<Vehicle>> build() => ref.watch(garageStoreProvider).load();

  Future<void> _save(List<Vehicle> list) async {
    state = AsyncData([...list]);
    await _store.save(list.where((v) => !_transient.contains(v.id)).toList());
  }

  /// เลิกโหมดทดลอง: เอารถทดลองออกจากรายการ
  void dropTransient() {
    if (_transient.isEmpty) return;
    final list = state.valueOrNull;
    if (list != null) state = AsyncData(list.where((v) => !_transient.contains(v.id)).toList());
    _transient.clear();
  }

  /// หารถจาก VIN (รถที่เพิ่มเองแล้วใส่ VIN ทีหลังก็ถูกจับคู่)
  static Vehicle? _findVin(List<Vehicle> list, String vin) {
    for (final v in list) {
      if (v.vin == vin || v.id == vin) return v;
    }
    return null;
  }

  Vehicle? byVin(String? vin) {
    if (vin == null) return null;
    for (final v in state.valueOrNull ?? const <Vehicle>[]) {
      if (v.vin == vin) return v;
    }
    return null;
  }

  /// ระบุรถอัตโนมัติจาก VIN: หา/สร้างรถในโรงรถ แล้วเติมยี่ห้อ ปี เชื้อเพลิง ที่ยังว่าง
  /// ถ้าในโรงรถมีรถรุ่นเดียวกัน (8 หลักแรกของ VIN ตรงกัน) ที่เคยระบุรุ่นไว้ จะใช้รุ่นนั้นให้เลย
  /// ไม่ทับค่าที่ผู้ใช้แก้เอง
  /// [persist] = false (โหมดทดลอง): รถใหม่อยู่แค่ในแอป ไม่บันทึกลงเครื่อง
  Future<({Vehicle vehicle, bool created})?> identify({required String vin, bool? diesel, bool persist = true}) async {
    final info = decodeVin17(vin);
    final list = [...(state.valueOrNull ?? await future)];
    var v = _findVin(list, vin);
    final created = v == null;
    if (v == null) {
      v = Vehicle(id: vin, vin: vin);
      list.add(v);
      if (!persist) _transient.add(v.id);
    }
    var changed = created;
    if (v.make == null && info.brand != null) {
      v.make = normalizeBrand(info.brand);
      v.idSource ??= 'vin';
      changed = true;
    }
    if (v.year == null && info.yearReliable && info.modelYear != null) {
      v.year = info.modelYear;
      changed = true;
    }
    if (v.fuel == null && diesel != null) {
      v.fuel = diesel ? 'ดีเซล' : 'เบนซิน';
      changed = true;
    }
    final family = info.familyKey;
    if (v.needsModel && family != null) {
      final me = v;
      final twin = list
          .where((x) => !identical(x, me) && !x.needsModel && (x.vin?.length ?? 0) == 17 && x.vin!.startsWith(family))
          .firstOrNull;
      if (twin != null) {
        v
          ..model = twin.model
          ..make ??= twin.make
          ..idSource = 'learned';
        changed = true;
      }
    }
    if (changed) {
      if (persist) {
        await _save(list);
      } else {
        state = AsyncData([...list]);
      }
    }
    return (vehicle: v, created: created);
  }

  Vehicle? byId(String? id) {
    if (id == null) return null;
    for (final v in state.valueOrNull ?? const <Vehicle>[]) {
      if (v.id == id) return v;
    }
    return null;
  }

  /// เพิ่มหรืออัปเดตรถจาก VIN และบันทึกข้อมูลเลขไมล์จากการสแกน
  /// รถที่ไม่ส่ง VIN จะบันทึกเฉพาะเมื่อผู้ใช้เลือกรถไว้แล้ว ([vehicleId]) เพื่อไม่ให้ข้อมูลหลายคันปนกัน
  Future<Vehicle?> recordScan(VehicleSnapshot s, {String? vehicleId}) async {
    final vin = s.vin;
    final list = [...(state.valueOrNull ?? await future)];
    Vehicle? v;
    if (vin != null && vin.isNotEmpty) {
      v = _findVin(list, vin);
      if (v == null) {
        v = Vehicle(id: vin, vin: vin);
        list.add(v);
      }
    } else if (vehicleId != null) {
      v = list.where((x) => x.id == vehicleId).firstOrNull;
    }
    if (v == null) return null;
    if (s.ecuOdometerKm != null || s.engineHours != null || s.ignitionCycles != null || s.dashboardKm != null) {
      // สแกนเดิมที่อัปเดตเลขหน้าปัดทีหลัง ให้แทนที่รายการเดิม ไม่เพิ่มซ้ำ
      v.odometer.removeWhere((e) => e.time == s.time);
      v.odometer.add(OdoEntry(
        time: s.time,
        ecuKm: s.ecuOdometerKm,
        dashKm: s.dashboardKm,
        engineHours: s.engineHours,
        ignitions: s.ignitionCycles,
      ));
    }
    await _save(list);
    return v;
  }

  /// บันทึกค่าเลขไมล์จากหน้าตรวจเลขไมล์ (สร้างรถใหม่ถ้ายังไม่มี)
  /// คืน false ถ้ารถไม่มี VIN (ระบุรถไม่ได้)
  Future<bool> addOdometer(String? vin, OdoEntry e) async {
    if (vin == null || vin.isEmpty) return false;
    final list = [...(state.valueOrNull ?? await future)];
    var v = _findVin(list, vin);
    if (v == null) {
      v = Vehicle(id: vin, vin: vin);
      list.add(v);
    }
    v.odometer.add(e);
    await _save(list);
    return true;
  }

  Future<void> upsert(Vehicle v) async {
    final list = [...(state.valueOrNull ?? await future)];
    final i = list.indexWhere((x) => x.id == v.id);
    if (i >= 0) {
      list[i] = v;
    } else {
      list.add(v);
    }
    await _save(list);
  }

  Future<void> remove(String id) async {
    final list = [...(state.valueOrNull ?? await future)]..removeWhere((x) => x.id == id);
    await _save(list);
  }
}

final garageProvider = AsyncNotifierProvider<GarageNotifier, List<Vehicle>>(GarageNotifier.new);

// ---------------- log การสื่อสาร ----------------

class LogNotifier extends Notifier<List<String>> {
  static const maxLines = 600;

  late CommLog _comm;

  @override
  List<String> build() {
    _comm = ref.watch(commLogProvider);
    return const [];
  }

  /// เพิ่มบรรทัดในหน้าเทอร์มินัล และในบันทึกการสื่อสาร (ถ้ากำลังบันทึกการเชื่อมต่ออยู่)
  void add(String line) {
    final next = [...state, line];
    state = next.length > maxLines ? next.sublist(next.length - maxLines) : next;
    _comm.add(line);
  }

  void clear() => state = const [];
}

final logProvider = NotifierProvider<LogNotifier, List<String>>(LogNotifier.new);

// ---------------- บันทึกการสื่อสาร (ส่งให้ผู้พัฒนาตรวจปัญหา) ----------------

final commLogProvider = Provider<CommLog>((ref) {
  final log = CommLog();
  ref.onDispose(log.dispose);
  return log;
});

/// เปิด/ปิดการบันทึกการสื่อสารทุกครั้งที่เชื่อมต่อ (ค่าเริ่มต้น: เปิด)
class CommLogEnabledNotifier extends Notifier<bool> {
  @override
  bool build() => ref.watch(sharedPrefsProvider).getBool(CommLog.prefKey) ?? true;

  void set(bool on) {
    state = on;
    ref.read(sharedPrefsProvider).setBool(CommLog.prefKey, on);
    if (!on) ref.read(commLogProvider).end('ปิดการบันทึก');
  }
}

final commLogEnabledProvider = NotifierProvider<CommLogEnabledNotifier, bool>(CommLogEnabledNotifier.new);

// ---------------- การเชื่อมต่อ ----------------

enum ConnStatus { disconnected, connecting, connected, failed }

class SessionState {
  const SessionState({
    this.status = ConnStatus.disconnected,
    this.message,
    this.transport,
    this.service,
    this.vin,
    this.diesel = false,
    this.vehicleId,
    this.newVehicle = false,
  });

  final ConnStatus status;
  final String? message;
  final ObdTransport? transport;
  final ObdService? service;
  final String? vin;
  final bool diesel;

  /// รถในโรงรถที่ตรงกับคันที่เชื่อมต่ออยู่ (ระบุอัตโนมัติจาก VIN หรือผู้ใช้เลือก)
  final String? vehicleId;

  /// เพิ่งเพิ่มรถคันนี้เข้าโรงรถจากการเชื่อมต่อครั้งนี้
  final bool newVehicle;

  SessionState withVehicle(String? id, {bool newVehicle = false}) => SessionState(
        status: status,
        message: message,
        transport: transport,
        service: service,
        vin: vin,
        diesel: diesel,
        vehicleId: id,
        newVehicle: newVehicle,
      );

  bool get isConnected => status == ConnStatus.connected && service != null;

  /// โหมดทดลองจากหน้าเชื่อมต่อ: ไม่บันทึกรถ/ผลสแกนลงเครื่อง
  bool get isPractice {
    final t = transport;
    return t is DemoTransport && t.practice;
  }
  Elm327? get elm => service?.elm;
  AdapterInfo? get adapter => elm?.adapter;
}

/// การเชื่อมต่อครั้งนี้ถูกยกเลิก หรือมีการเชื่อมต่อใหม่มาแทนแล้ว
class _Superseded implements Exception {
  const _Superseded();
}

class SessionNotifier extends Notifier<SessionState> {
  StreamSubscription<List<int>>? _dropWatch;

  /// เพิ่มทุกครั้งที่เริ่มเชื่อมต่อหรือตัดการเชื่อมต่อ งานเชื่อมต่อเก่าที่ยังค้างจะรู้ว่าตัวเองถูกยกเลิก
  int _gen = 0;

  /// ELM ของการเชื่อมต่อที่ยังไม่เสร็จ (ตัดการเชื่อมต่อแล้วต้องหยุดคำสั่งที่ค้างทันที)
  Elm327? _pendingElm;

  /// บันทึกการสื่อสาร (ตัวเดียวตลอดอายุแอป)
  late CommLog _comm;

  @override
  SessionState build() {
    _comm = ref.read(commLogProvider);
    ref.onDispose(() => _teardown(state));
    return const SessionState();
  }

  Future<void> connect(ObdTransport transport) async {
    await disconnect();
    final gen = ++_gen;
    void check() {
      if (gen != _gen) throw const _Superseded();
    }

    ref.read(logProvider.notifier).clear();
    state = SessionState(status: ConnStatus.connecting, transport: transport, message: 'กำลังเชื่อมต่อ ${transport.displayName}…');
    final log = ref.read(logProvider.notifier);
    _startCommLog(transport);
    log.add('เชื่อมต่อ ${transport.displayName}');
    Elm327? elm;
    try {
      await transport.connect();
      check();
      elm = Elm327(transport)..onLog = log.add;
      _pendingElm = elm;
      elm.attach();
      state = SessionState(status: ConnStatus.connecting, transport: transport, message: 'กำลังเตรียมตัวสแกน…');
      await elm.initialize(onStep: (step) {
        if (gen == _gen && state.transport == transport && state.status == ConnStatus.connecting) {
          state = SessionState(status: ConnStatus.connecting, transport: transport, message: step);
        }
      });
      check();
      final service = ObdService(elm);
      state = SessionState(status: ConnStatus.connecting, transport: transport, message: 'กำลังอ่านข้อมูลรถ…');
      await service.loadSupportedPids();
      check();
      log.add('รองรับ ${service.supported.length} PID, โปรโตคอล ${elm.protocolLabel}, ตัวสแกน ${elm.adapter?.kind.labelTh}');

      final monitor = await service.readMonitorStatus();
      check();
      final ft = service.supported.contains(Pid.fuelType) ? await service.readPid(Pid.fuelType) : null;
      final diesel = ft != null ? ft.round() == 4 : (monitor?.isDiesel ?? false);
      String? vin;
      try {
        vin = await service.readVin();
      } catch (_) {
        vin = null;
      }
      check();
      // รถบางคันตอบ VIN ว่างหรือเป็นช่องว่าง ถือว่าไม่มี VIN
      vin = vin?.trim();
      if (vin != null && vin.isEmpty) vin = null;
      log.add('VIN ${vin ?? '(รถไม่ส่ง VIN)'} · ${diesel ? 'ดีเซล' : 'ไม่ใช่ดีเซล'}');

      // ถ้าการเชื่อมต่อหลุดกลางทาง ให้สถานะกลับเป็น "หลุด"
      _dropWatch = transport.incoming.listen((_) {}, onError: (Object e) {
        if (state.transport == transport) {
          // ปิด ELM/transport ด้วย ไม่เช่นนั้น BLE ค้างการเชื่อมต่อ เพราะ state ใหม่ไม่มี transport แล้ว
          final old = state;
          state = SessionState(status: ConnStatus.failed, message: e.toString());
          log.add('การเชื่อมต่อหลุด: $e');
          _comm.end('การเชื่อมต่อหลุด');
          _teardown(old);
        }
      });

      _pendingElm = null;
      state = SessionState(
        status: ConnStatus.connected,
        transport: transport,
        service: service,
        vin: vin,
        diesel: diesel,
      );
      _rememberAdapter(transport);
      await _identify(transport, vin, diesel);
    } catch (e) {
      if (identical(_pendingElm, elm)) _pendingElm = null;
      await elm?.detach();
      try {
        await transport.disconnect();
      } catch (_) {}
      // ผู้ใช้กดยกเลิก หรือเริ่มเชื่อมต่อใหม่ไปแล้ว: ไม่เขียนสถานะ "ล้มเหลว" ทับการเชื่อมต่อใหม่
      if (e is _Superseded || gen != _gen) return;
      log.add('เชื่อมต่อไม่สำเร็จ: $e');
      _comm.end('เชื่อมต่อไม่สำเร็จ');
      state = SessionState(status: ConnStatus.failed, message: e.toString());
    }
  }

  /// เริ่มบันทึกการสื่อสารของการเชื่อมต่อครั้งนี้ (ไม่บันทึกตัวจำลอง หรือเมื่อผู้ใช้ปิดไว้)
  void _startCommLog(ObdTransport transport) {
    _comm.end();
    if (transport is DemoTransport || !ref.read(commLogEnabledProvider)) return;
    _comm.start(transport.displayName, info: {
      'app': 'ProScaner $kAppVersion',
      'transport': transport.kind.name,
      'os': '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
    });
  }

  /// ระบุรถอัตโนมัติ ถ้าผิดพลาด (เช่น บันทึกไฟล์ไม่ได้) ไม่ให้การเชื่อมต่อล้ม
  Future<void> _identify(ObdTransport transport, String? vin, bool diesel) async {
    if (vin == null || vin.isEmpty) return;
    try {
      final practice = transport is DemoTransport && transport.practice;
      final r = await ref.read(garageProvider.notifier).identify(vin: vin, diesel: diesel, persist: !practice);
      if (r != null && state.transport == transport && state.isConnected) {
        state = state.withVehicle(r.vehicle.id, newVehicle: r.created);
      }
    } catch (e) {
      ref.read(logProvider.notifier).add('ระบุรถอัตโนมัติไม่สำเร็จ: $e');
    }
  }

  /// จำตัวสแกนที่เชื่อมต่อสำเร็จ ไว้เชื่อมต่อซ้ำด้วยการแตะครั้งเดียว (ไม่จำโหมดทดลอง)
  void _rememberAdapter(ObdTransport transport) {
    final m = AdapterMemento.of(transport);
    if (m == null) return;
    try {
      ref.read(lastAdapterProvider.notifier).remember(m);
    } catch (e) {
      ref.read(logProvider.notifier).add('จำตัวสแกนไม่สำเร็จ: $e');
    }
  }

  /// ผู้ใช้เลือกรถเอง (ใช้กับรถที่ไม่ส่ง VIN หรือเมื่อต้องการเปลี่ยน)
  void selectVehicle(String? id) {
    if (!state.isConnected) return;
    state = state.withVehicle(id);
  }

  Future<void> disconnect() async {
    _gen++;
    final pending = _pendingElm;
    _pendingElm = null;
    final old = state;
    state = const SessionState();
    final commName = _comm.currentName;
    if (old.isPractice) ref.read(garageProvider.notifier).dropTransient();
    await _teardown(old);
    // การเชื่อมต่อที่ยังไม่เสร็จ: หยุดคำสั่งที่ค้างให้จบทันที ไม่ต้องรอหมดเวลา
    await pending?.detach();
    // จบบันทึกหลังปิดเสร็จ (เก็บข้อความตอนปิดด้วย) เฉพาะบันทึกของการเชื่อมต่อนี้ ไม่ใช่ของการเชื่อมต่อใหม่ที่เริ่มระหว่างรอ
    if (commName != null && _comm.currentName == commName) _comm.end('ตัดการเชื่อมต่อ');
  }

  Future<void> _teardown(SessionState s) async {
    await _dropWatch?.cancel();
    _dropWatch = null;
    await s.elm?.detach();
    try {
      await s.transport?.disconnect();
    } catch (_) {}
  }
}

final sessionProvider = NotifierProvider<SessionNotifier, SessionState>(SessionNotifier.new);

// ---------------- ตัวสแกนล่าสุด ----------------

class LastAdapterNotifier extends Notifier<AdapterMemento?> {
  static const _key = 'last_adapter';

  @override
  AdapterMemento? build() => AdapterMemento.decode(ref.watch(sharedPrefsProvider).getString(_key));

  void remember(AdapterMemento m) {
    state = m;
    ref.read(sharedPrefsProvider).setString(_key, m.encode());
  }

  void forget() {
    state = null;
    ref.read(sharedPrefsProvider).remove(_key);
  }
}

final lastAdapterProvider = NotifierProvider<LastAdapterNotifier, AdapterMemento?>(LastAdapterNotifier.new);

// ---------------- การสแกนวินิจฉัย ----------------

/// ขั้นตอนการสแกน สำหรับแสดงความคืบหน้า
class ScanStep {
  const ScanStep(this.label, {this.done = false});
  final String label;
  final bool done;
}

class ScanState {
  const ScanState({
    this.running = false,
    this.step,
    this.progress = 0,
    this.steps = const [],
    this.report,
    this.error,
    this.fullScan = false,
  });

  final bool running;
  final String? step;
  final double progress;
  final List<ScanStep> steps;
  final DiagnosisReport? report;
  final String? error;

  /// ผลล่าสุดมาจากการสแกนทั้งคัน (รวมกล่องอื่น)
  final bool fullScan;
}

class ScanNotifier extends Notifier<ScanState> {
  @override
  ScanState build() {
    // เปลี่ยนรถหรือตัดการเชื่อมต่อ = ล้างผลเดิม
    ref.watch(sessionProvider.select((s) => s.service));
    return const ScanState();
  }

  final _steps = <ScanStep>[];

  void _step(String s, double progress) {
    if (_steps.isNotEmpty) _steps[_steps.length - 1] = ScanStep(_steps.last.label, done: true);
    _steps.add(ScanStep(s));
    state = ScanState(running: true, step: s, progress: progress, steps: List.of(_steps), report: state.report);
  }

  void _detail(String s, double progress) =>
      state = ScanState(running: true, step: s, progress: progress, steps: List.of(_steps), report: state.report);

  /// [allModules] = สแกนทั้งคัน (รวม ABS, ถุงลม, เกียร์ ฯลฯ) ใช้เวลานานกว่า
  /// คืน true เมื่อสแกนสำเร็จและได้ผลใหม่
  Future<bool> run({bool allModules = false, bool deep = false, double? dashboardKm}) async {
    final session = ref.read(sessionProvider);
    final service = session.service;
    if (service == null || state.running) return false;
    _steps.clear();
    try {
      _step('อ่านสถานะไฟเตือน', 0.02);
      var monitor = await service.readMonitorStatus();
      if (monitor == null) {
        // คำตอบแรกอาจหลุด ลองอีกครั้ง
        await Future<void>.delayed(const Duration(milliseconds: 400));
        monitor = await service.readMonitorStatus();
      }
      // รถทุกคันที่รองรับ OBD-II ต้องตอบ PID 01 ถ้าไม่ตอบแปลว่ารถหลับ/ดับเครื่องไปแล้ว
      // ห้ามสร้างรายงาน ไม่เช่นนั้นจะได้ผล "ไม่พบปัญหา" ทั้งที่อ่านอะไรไม่ได้เลย
      if (monitor == null) {
        throw ElmException('กล่องเครื่องยนต์ไม่ตอบ ตรวจว่ายังบิดกุญแจ ON หรือติดเครื่องอยู่ แล้วสแกนใหม่');
      }

      final dtcs = <Dtc>[];
      var i = 0;
      for (final kind in DtcKind.values) {
        _step('อ่านรหัสปัญหาเครื่องยนต์ (${kind.labelTh})', 0.05 + 0.05 * i++);
        dtcs.addAll(await service.readDtcs(kind));
      }

      _step('อ่านค่าเซ็นเซอร์และเลขไมล์', 0.2);
      final pids = await service.readPids(snapshotPids);
      if (pids.isEmpty && service.supported.isNotEmpty && snapshotPids.any(service.supported.contains)) {
        throw ElmException('อ่านค่าเซ็นเซอร์ไม่ได้ (รถหยุดตอบระหว่างสแกน) ตรวจกุญแจและการเชื่อมต่อ แล้วสแกนใหม่');
      }

      _step('อ่านความพร้อมตรวจสภาพ', 0.3);
      final readiness = await service.readReadiness();

      FreezeFrame? freeze;
      if (dtcs.any((d) => d.kind == DtcKind.stored)) {
        _step('อ่านข้อมูลตอนเกิดปัญหา (Freeze Frame)', 0.35);
        try {
          freeze = await service.readFreezeFrame(snapshotPids);
        } catch (_) {
          freeze = null; // บางรถไม่รองรับ Mode 02
        }
      }

      _step('อ่านข้อมูลกล่อง ECU (Calibration, ตัวนับการสตาร์ท)', 0.42);
      List<EcuIdentity> ids = const [];
      try {
        ids = await service.readEcuIdentities();
      } catch (_) {
        ids = const [];
      }

      var modules = <EcuModule>[];
      if (allModules && service.elm.isCan) {
        _step(deep ? 'ค้นหากล่องทั้งหมดในรถ (ละเอียด)' : 'ค้นหากล่องทั้งหมดในรถ', 0.5);
        final uds = UdsClient(service.elm);
        try {
          modules = await uds.discover(
            deep: deep,
            onProgress: (p, s) => _detail(s, 0.5 + 0.3 * p),
          );
        } on ElmException catch (e) {
          // ค้นหากล่องไม่สำเร็จ ยังเก็บผลเครื่องยนต์ไว้ได้
          modules = [EcuModule(tx: '-', rx: '-', name: 'ค้นหากล่องอื่นไม่สำเร็จ', error: e.message)];
        }
        // กล่องเครื่องยนต์อ่านผ่าน OBD แล้ว ไม่ต้องซ้ำ
        modules.removeWhere((m) => m.tx == '7E0' || m.tx == '18DA10F1');
        for (var k = 0; k < modules.length; k++) {
          final m = modules[k];
          if (m.error != null) continue;
          _step('อ่านรหัสปัญหา ${m.title}', 0.8 + 0.15 * k / modules.length);
          try {
            m.dtcs = await uds.readDtcs(m);
          } on UdsNegative catch (e) {
            m.error = e.messageTh;
          } on ElmException catch (e) {
            m.error = e.message;
          }
        }
      } else if (allModules) {
        _step('รถใช้โปรโตคอลรุ่นเก่า (ไม่ใช่ CAN) สแกนได้เฉพาะกล่องเครื่องยนต์', 0.8);
      }

      final snapshot = VehicleSnapshot(
        time: DateTime.now(),
        dtcs: dtcs,
        pids: pids,
        milOn: monitor.milOn,
        isDiesel: session.diesel,
        vin: session.vin,
        readiness: readiness,
        freezeFrame: freeze,
        modules: modules,
        ecuIds: ids,
        dashboardKm: dashboardKm,
      );

      // ระหว่างสแกนอาจตัดการเชื่อมต่อหรือเปลี่ยนรถ ไม่เขียนผลของรถคันเก่าทับ
      if (ref.read(sessionProvider).service != service) return false;

      _step('วิเคราะห์ผล', 0.97);
      final report = await (await ref.read(diagnosisEngineProvider.future)).analyze(snapshot);

      _steps[_steps.length - 1] = ScanStep(_steps.last.label, done: true);
      state = ScanState(report: report, steps: List.of(_steps), fullScan: allModules);

      // บันทึกประวัติและโรงรถ (โหมดทดลองไม่บันทึก) ถ้าบันทึกไม่สำเร็จ ผลสแกนยังแสดงอยู่
      if (!session.isPractice) {
        try {
          await ref.read(historyStoreProvider).add(snapshot);
          ref.invalidate(historyProvider);
          await ref.read(garageProvider.notifier).recordScan(snapshot, vehicleId: ref.read(sessionProvider).vehicleId);
        } catch (e) {
          ref.read(logProvider.notifier).add('บันทึกผลสแกนไม่สำเร็จ: $e');
        }
      }
      return true;
    } catch (e) {
      state = ScanState(error: 'สแกนไม่สำเร็จ: $e', report: state.report);
      return false;
    }
  }

  /// อัปเดตเลขไมล์หน้าปัดของผลล่าสุด แล้ววิเคราะห์ใหม่
  Future<void> setDashboardKm(double km) async {
    final r = state.report;
    if (r == null) return;
    final s = r.snapshot.copyWith(dashboardKm: km);
    final report = await (await ref.read(diagnosisEngineProvider.future)).analyze(s);
    state = ScanState(report: report, steps: state.steps, fullScan: state.fullScan);
    if (ref.read(sessionProvider).isPractice) return;
    await ref.read(garageProvider.notifier).recordScan(s, vehicleId: ref.read(sessionProvider).vehicleId);
  }

  /// ลบรหัสปัญหา ต้องจอดรถนิ่งเท่านั้น คืนข้อความผลลัพธ์
  /// [modules] = กล่องอื่นที่จะลบด้วย (จากผลสแกนทั้งคัน)
  Future<String> clearCodes({List<EcuModule> modules = const []}) async {
    final service = ref.read(sessionProvider).service;
    if (service == null) return 'ยังไม่ได้เชื่อมต่อ';
    try {
      return await _clearCodes(service, modules);
    } on ElmException catch (e) {
      return 'ลบรหัสไม่สำเร็จ: ${e.message} (ยังไม่แน่ใจว่าลบแล้วหรือไม่ ให้สแกนใหม่เพื่อตรวจ)';
    } catch (e) {
      return 'ลบรหัสไม่สำเร็จ: $e (ยังไม่แน่ใจว่าลบแล้วหรือไม่ ให้สแกนใหม่เพื่อตรวจ)';
    }
  }

  Future<String> _clearCodes(ObdService service, List<EcuModule> modules) async {
    final speed = await service.readPid(Pid.speed);
    if (speed != null && speed > 0) {
      return 'ลบรหัสได้เฉพาะตอนรถจอดนิ่ง (ความเร็วขณะนี้ ${speed.round()} กม./ชม.)';
    }
    final ok = await service.clearDtcs();
    final failed = <String>[];
    final uds = UdsClient(service.elm);
    for (final m in modules.where((m) => m.dtcs.isNotEmpty)) {
      try {
        if (!await uds.clearDtcs(m)) failed.add(m.title);
      } catch (_) {
        failed.add(m.title);
      }
    }
    if (!ok) return 'ECU ไม่ยืนยันการลบ ลองบิดกุญแจ ON โดยไม่ติดเครื่องแล้วลองใหม่';
    await run(allModules: modules.isNotEmpty);
    if (failed.isNotEmpty) return 'ลบรหัสเครื่องยนต์แล้ว แต่ลบไม่สำเร็จ: ${failed.join(', ')}';
    return 'ลบรหัสแล้ว ไฟเตือนจะดับ และระบบต้องขับทดสอบใหม่ก่อนตรวจสภาพ';
  }
}

final scanProvider = NotifierProvider<ScanNotifier, ScanState>(ScanNotifier.new);
