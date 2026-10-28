import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/elm/elm327.dart';
import '../core/obd/pids.dart';
import '../core/voice/voice_service.dart';
import '../data/log_store.dart';
import 'providers.dart';

/// สถิติทริปที่คำนวณจากค่าสด
class TripStats {
  const TripStats({this.km = 0, this.fuelL = 0, this.instKmPerL, this.litersPerHour, this.seconds = 0});

  final double km;
  final double fuelL;
  final double? instKmPerL;
  final double? litersPerHour;
  final double seconds;

  double? get avgKmPerL => fuelL > 0.01 ? km / fuelL : null;
}

/// ค่าสดล่าสุด + ประวัติย้อนหลังสำหรับกราฟ + ทริป + แจ้งเตือน
class LiveData {
  const LiveData({
    this.latest = const {},
    this.series = const {},
    this.hz = 0,
    this.error,
    this.trip = const TripStats(),
    this.alert,
    this.alertAt,
  });

  final Map<int, double> latest;
  final Map<int, List<double>> series;
  final double hz;
  final String? error;
  final TripStats trip;
  final String? alert;
  final DateTime? alertAt;

  LiveData copyWith({
    Map<int, double>? latest,
    Map<int, List<double>>? series,
    double? hz,
    String? error,
    bool clearError = false,
    TripStats? trip,
    String? alert,
    DateTime? alertAt,
    bool clearAlert = false,
  }) =>
      LiveData(
        latest: latest ?? this.latest,
        series: series ?? this.series,
        hz: hz ?? this.hz,
        error: clearError ? null : (error ?? this.error),
        trip: trip ?? this.trip,
        alert: clearAlert ? null : (alert ?? this.alert),
        alertAt: clearAlert ? null : (alertAt ?? this.alertAt),
      );
}

class LiveDataNotifier extends Notifier<LiveData> {
  static const maxSamples = 150;

  @override
  LiveData build() {
    // เปลี่ยนรถ = ล้างค่า
    ref.watch(sessionProvider.select((s) => s.service));
    return const LiveData();
  }

  void pushAll(Map<int, double> values) {
    if (values.isEmpty) return;
    final s = Map<int, List<double>>.of(state.series);
    for (final e in values.entries) {
      final list = List<double>.of(s[e.key] ?? const []);
      list.add(e.value);
      if (list.length > maxSamples) list.removeRange(0, list.length - maxSamples);
      s[e.key] = list;
    }
    state = state.copyWith(latest: {...state.latest, ...values}, series: s);
  }

  void setRate(double hz) => state = state.copyWith(hz: hz, clearError: true);
  void setError(String e) => state = state.copyWith(error: e);
  void setTrip(TripStats t) => state = state.copyWith(trip: t);
  void resetTrip() => state = state.copyWith(trip: const TripStats());
  void raise(String msg) => state = state.copyWith(alert: msg, alertAt: DateTime.now());
  void dismissAlert() => state = state.copyWith(clearAlert: true);
}

final liveDataProvider = NotifierProvider<LiveDataNotifier, LiveData>(LiveDataNotifier.new);

// ---------------- บันทึกการขับ ----------------

class RecorderState {
  const RecorderState({this.recording = false, this.start, this.pids = const [], this.rows = 0, this.lastSaved});

  final bool recording;
  final DateTime? start;
  final List<int> pids;
  final int rows;
  final DriveLog? lastSaved;
}

class RecorderNotifier extends Notifier<RecorderState> {
  final _times = <double>[];
  final _rows = <List<double?>>[];

  @override
  RecorderState build() => const RecorderState();

  static const _pollKey = 'recorder';

  /// เริ่มบันทึก ตัวอ่านค่าสดจะทำงานต่อแม้ออกจากหน้าจอ จนกว่าจะกดหยุด
  void start(List<int> pids) {
    _times.clear();
    _rows.clear();
    state = RecorderState(recording: true, start: DateTime.now(), pids: pids);
    ref.read(livePollerProvider).subscribe(_pollKey, pids);
  }

  /// ยกเลิกโดยไม่บันทึก
  void cancel() {
    ref.read(livePollerProvider).unsubscribe(_pollKey);
    _times.clear();
    _rows.clear();
    state = const RecorderState();
  }

  void addRow(Map<int, double> values) {
    if (!state.recording || state.start == null) return;
    final t = DateTime.now().difference(state.start!).inMilliseconds / 1000;
    _times.add(t);
    _rows.add([for (final p in state.pids) values[p]]);
    state = RecorderState(recording: true, start: state.start, pids: state.pids, rows: _rows.length);
  }

  /// หยุดและบันทึก คืนไฟล์ที่บันทึก (null ถ้าไม่มีข้อมูล)
  Future<DriveLog?> stop({String? name}) async {
    if (!state.recording) return null;
    ref.read(livePollerProvider).unsubscribe(_pollKey);
    final start = state.start!;
    final pids = state.pids;
    state = const RecorderState();
    if (_rows.isEmpty) return null;
    String two(int n) => n.toString().padLeft(2, '0');
    final log = DriveLog(
      id: 'log_${start.millisecondsSinceEpoch}',
      name: name ?? 'บันทึก ${two(start.day)}/${two(start.month)} ${two(start.hour)}:${two(start.minute)}',
      start: start,
      pids: pids,
      times: List.of(_times),
      rows: List.of(_rows),
      vin: ref.read(sessionProvider).vin,
    );
    await ref.read(logStoreProvider).save(log);
    ref.invalidate(logsProvider);
    state = RecorderState(lastSaved: log);
    return log;
  }
}

final recorderProvider = NotifierProvider<RecorderNotifier, RecorderState>(RecorderNotifier.new);

// ---------------- ตัวอ่านค่าสดกลาง ----------------

class _Client {
  _Client(this.pids, this.priority);
  final Set<int> pids;
  final bool priority;
}

/// ตัวอ่านค่าสดตัวเดียวของแอป หน้าจอต่างๆ ลงทะเบียน PID ที่ต้องการ
/// ถ้ามีหน้าจอที่ต้องการความเร็วสูง (priority) จะอ่านเฉพาะ PID ของหน้านั้น
class LivePoller {
  LivePoller(this.ref);

  final Ref ref;
  final _clients = <Object, _Client>{};
  bool _running = false;
  DateTime? _lastSweep;
  final _lastAlert = <String, DateTime>{};

  bool get isRunning => _running;

  void subscribe(Object key, Iterable<int> pids, {bool priority = false}) {
    _clients[key] = _Client(pids.toSet(), priority);
    if (!_running) unawaited(_run());
  }

  void unsubscribe(Object key) => _clients.remove(key);

  Set<int> _wanted() {
    final prio = _clients.values.where((c) => c.priority).toList();
    final src = prio.isNotEmpty ? prio : _clients.values.toList();
    final set = <int>{for (final c in src) ...c.pids};
    // หน้าจอที่ขอหยุดการอ่านทั้งหมด (priority แต่ไม่มี PID) เช่น ทดสอบแบต/คุยกับกล่องอื่น
    final pausedAll = prio.isNotEmpty && set.isEmpty;
    final rec = ref.read(recorderProvider);
    if (rec.recording && !pausedAll) set.addAll(rec.pids);
    return set;
  }

  Future<void> _run() async {
    _running = true;
    _lastSweep = null;
    try {
      while (_clients.isNotEmpty) {
        final session = ref.read(sessionProvider);
        final svc = session.service;
        if (svc == null) {
          await Future<void>.delayed(const Duration(milliseconds: 400));
          continue;
        }
        final pids = _wanted().where((p) => pidTable[p] != null && svc.supports(p)).toList();
        if (pids.isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          continue;
        }
        final live = ref.read(liveDataProvider.notifier);
        final sw = Stopwatch()..start();
        final values = <int, double>{};
        try {
          for (final pid in pids) {
            if (_clients.isEmpty || ref.read(sessionProvider).service != svc) break;
            final v = await svc.readPid(pid);
            if (v != null) values[pid] = v;
          }
          live.pushAll(values);
          final secs = sw.elapsedMilliseconds / 1000;
          if (secs > 0) live.setRate(values.length / secs);
          _updateTrip(values, session.diesel);
          _checkAlerts(values);
          ref.read(recorderProvider.notifier).addRow(values);
        } on ElmException catch (e) {
          live.setError(e.message);
          await Future<void>.delayed(const Duration(seconds: 1));
        } catch (e) {
          // ข้อผิดพลาดอื่น (เช่นการเชื่อมต่อหลุด) ไม่ให้ตัวอ่านหยุดถาวร
          live.setError(e.toString());
          await Future<void>.delayed(const Duration(seconds: 1));
        }
        // รอบเร็วเกินไปทำให้ตัวสแกนราคาถูกค้าง เว้นช่วงเล็กน้อย
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }
    } finally {
      _running = false;
    }
  }

  void _updateTrip(Map<int, double> v, bool diesel) {
    final now = DateTime.now();
    final prev = _lastSweep;
    _lastSweep = now;
    if (prev == null) return;
    final dt = now.difference(prev).inMilliseconds / 1000;
    if (dt <= 0 || dt > 10) return;
    final live = ref.read(liveDataProvider);
    final t = live.trip;
    // ใช้เฉพาะค่าที่อ่านได้ในรอบนี้ ไม่ใช้ค่าเก่า (กันระยะทางงอกเองตอนไม่ได้อ่านความเร็ว)
    final speed = v[Pid.speed];
    if (speed == null) return;
    double? lph = v[Pid.fuelRate];
    if (lph == null && !diesel) {
      final maf = v[Pid.maf];
      // เบนซิน: AFR 14.7, ความหนาแน่น 740 g/L
      if (maf != null) lph = maf / 14.7 / 740 * 3600;
    }
    final km = t.km + speed * dt / 3600;
    final fuel = t.fuelL + (lph ?? 0) * dt / 3600;
    final inst = (lph != null && lph > 0.2 && speed > 3) ? speed / lph : null;
    ref.read(liveDataProvider.notifier).setTrip(
          TripStats(km: km, fuelL: fuel, instKmPerL: inst, litersPerHour: lph, seconds: t.seconds + dt),
        );
  }

  void _checkAlerts(Map<int, double> v) {
    final a = ref.read(settingsProvider).alerts;
    if (!a.enabled) return;
    String? msg;
    String? key;
    final cool = v[Pid.coolantTemp];
    final volt = v[Pid.moduleVoltage];
    final rpm = v[Pid.rpm];
    // PID 70 เป็นแรงดันสัมบูรณ์ แปลงเป็นบูสต์แบบเกจ (ลบความดันบรรยากาศ)
    final boostAbs = v[Pid.boost];
    final baro = ref.read(liveDataProvider).latest[Pid.baro] ?? 101.3;
    final boost = boostAbs == null ? null : boostAbs - baro;
    String? say;
    if (cool != null && a.coolantMax > 0 && cool >= a.coolantMax) {
      key = 'cool';
      msg = 'ความร้อนเครื่องสูง ${cool.round()} °C';
      say = 'ระวัง ความร้อนเครื่องสูง ${cool.round()} องศา ควรจอดพักเครื่อง';
    } else if (volt != null && rpm != null && rpm > 500 && a.voltLow > 0 && volt < a.voltLow) {
      key = 'vlo';
      msg = 'ไฟชาร์จต่ำ ${volt.toStringAsFixed(1)} V';
      say = 'ไฟชาร์จต่ำ ${volt.toStringAsFixed(1)} โวลต์ ตรวจไดชาร์จ';
    } else if (volt != null && a.voltHigh > 0 && volt > a.voltHigh) {
      key = 'vhi';
      msg = 'ไฟชาร์จสูงเกิน ${volt.toStringAsFixed(1)} V';
      say = 'ไฟชาร์จสูงเกิน ${volt.toStringAsFixed(1)} โวลต์';
    } else if (rpm != null && a.rpmMax > 0 && rpm > a.rpmMax) {
      key = 'rpm';
      msg = 'รอบเครื่องเกิน ${rpm.round()}';
      say = 'รอบเครื่องสูง ${rpm.round()} รอบ';
    } else if (boost != null && a.boostMax > 0 && boost > a.boostMax) {
      key = 'boost';
      msg = 'บูสต์เกิน ${boost.round()} kPa';
      say = 'บูสต์สูงเกิน ${boost.round()} กิโลปาสคาล';
    }
    if (msg == null || key == null) return;
    final last = _lastAlert[key];
    final now = DateTime.now();
    if (last != null && now.difference(last).inSeconds < 20) return;
    _lastAlert[key] = now;
    ref.read(liveDataProvider.notifier).raise(msg);
    unawaited(HapticFeedback.heavyImpact().catchError((Object _) {}));
    if (a.voice && say != null) unawaited(ref.read(voiceServiceProvider).speak(say));
  }
}

final livePollerProvider = Provider<LivePoller>((ref) => LivePoller(ref));
