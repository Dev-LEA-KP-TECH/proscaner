import 'dart:math' as math;

import 'remap_test.dart';

/// ช่องค่าของรอบทดสอบสังเคราะห์ (เหมือนดีเซลเทอร์โบที่รองรับ PID 70 และ 6D)
const syntheticRemapChannels = <RemapChannel>[
  RemapChannel(key: 'std:0D', name: 'ความเร็วรถ', unit: 'กม./ชม.', signal: RemapSignal.speed, decimals: 0),
  RemapChannel(key: 'std:0C', name: 'รอบเครื่องยนต์', unit: 'รอบ/นาที', signal: RemapSignal.rpm, decimals: 0),
  RemapChannel(key: 'std:5A', name: 'คันเร่งสัมพัทธ์', unit: '%', signal: RemapSignal.pedal, decimals: 0),
  RemapChannel(key: 'std:04', name: 'ภาระเครื่องยนต์', unit: '%', signal: RemapSignal.load, decimals: 0),
  RemapChannel(key: 'std:70a', name: 'บูสต์จริง (PID 70)', unit: 'kPa', signal: RemapSignal.boost, decimals: 0),
  RemapChannel(key: 'std:70c', name: 'บูสต์ที่ต้องการ (PID 70)', unit: 'kPa', signal: RemapSignal.boostCmd, decimals: 0),
  RemapChannel(key: 'std:6Da', name: 'ความดันรางจริง (PID 6D)', unit: 'MPa', signal: RemapSignal.rail, decimals: 1),
  RemapChannel(key: 'std:6Dc', name: 'ความดันรางที่ต้องการ (PID 6D)', unit: 'MPa', signal: RemapSignal.railCmd, decimals: 1),
  RemapChannel(key: 'std:78', name: 'อุณหภูมิไอเสีย (EGT) B1', unit: '°C', signal: RemapSignal.egt, decimals: 0),
  RemapChannel(key: 'std:05', name: 'อุณหภูมิน้ำหล่อเย็น', unit: '°C', signal: RemapSignal.coolant, decimals: 0),
  RemapChannel(key: 'std:0F', name: 'อุณหภูมิอากาศเข้า', unit: '°C', signal: RemapSignal.iat, decimals: 0),
  RemapChannel(key: 'std:33', name: 'แรงดันบรรยากาศ', unit: 'kPa', signal: RemapSignal.baro, decimals: 0),
];

/// รอบทดสอบสังเคราะห์ (ใช้ในเทสต์ ภาพหน้าจอ และสาธิต)
/// จอดนิ่ง 3 วินาที → เร่งเต็มที่ 22 วินาที (ความเร็ว = [vmax]·(1−e^(−t/[tau]))) → ถอนคันเร่งชะลอ 10 วินาที
/// [boostPeak] = บูสต์ที่ต้องการสูงสุดแบบเกจ (kPa), [railPeak] = ความดันรางที่ต้องการสูงสุด (MPa)
/// [overboost] = บูสต์จริงเกินที่ต้องการตอนเร่ง (kPa), [hz] = จำนวนแถวต่อวินาที
RemapRun syntheticRemapRun({
  required String id,
  required RemapStage stage,
  required DateTime start,
  String? name,
  double tau = 6.2,
  double vmax = 140,
  double boostPeak = 110,
  double railPeak = 150,
  double overboost = 0,
  double hz = 8,
  List<String> dtcBefore = const [],
  List<String> dtcAfter = const [],
  String vehicleLabel = 'Isuzu D-Max 3.0 (รถสาธิต)',
}) {
  const baro = 100.0;
  const ratio = [0.0, 118.0, 70.0, 47.0, 35.0, 28.0];
  int gear(double v) => v < 1 ? 0 : (v < 22 ? 1 : (v < 42 ? 2 : (v < 68 ? 3 : (v < 95 ? 4 : 5))));
  final run = RemapRun(
    id: id,
    name: name ?? '${stage.labelTh} (สาธิต)',
    stage: stage,
    start: start,
    channels: syntheticRemapChannels,
    vehicleLabel: vehicleLabel,
    dtcBefore: List.of(dtcBefore),
    dtcAfter: List.of(dtcAfter),
    milBefore: false,
    milAfter: false,
    turbo: true,
    hz: hz,
    multiPid: true,
    appVersion: 'demo',
  );
  final dt = 1 / hz;
  var boost = baro + 2, rail = 30.0, egt = 220.0;
  var coastFrom = 0.0;
  for (var i = 0; i * dt <= 35; i++) {
    final t = i * dt;
    final accel = t >= 3 && t < 25;
    double v;
    if (t < 3) {
      v = 0;
    } else if (accel) {
      v = vmax * (1 - math.exp(-(t - 3) / tau));
      coastFrom = v;
    } else {
      v = math.max(0.0, coastFrom - 4.5 * (t - 25));
    }
    final g = gear(v);
    final rpm = g == 0 ? 800.0 : math.max(1000.0, v * ratio[g]);
    final load = accel ? 92.0 : (v > 1 ? 18.0 : 22.0);
    final boostCmd = accel ? baro + boostPeak * ((rpm - 1100) / 1500).clamp(0.0, 1.0) : baro + 2;
    final railCmd = accel ? 30 + (railPeak - 30) * (rpm / 3000).clamp(0.3, 1.0) : 30.0;
    double follow(double cur, double target, double tauS) => cur + (target - cur) * (1 - math.exp(-dt / tauS));
    boost = follow(boost, boostCmd + (accel && boostCmd > baro + 50 ? overboost : 0), 0.6);
    rail = follow(rail, railCmd, 0.2);
    egt = follow(egt, 200 + 520 * load / 100, 3.0);
    run.add(t, {
      'std:0D': v.roundToDouble(),
      'std:0C': rpm,
      'std:5A': accel ? 100.0 : 0.0,
      'std:04': load,
      'std:70a': boost,
      'std:70c': boostCmd,
      'std:6Da': rail,
      'std:6Dc': railCmd,
      'std:78': egt,
      'std:05': 88 + 4 * t / 35,
      'std:0F': 34 + 10 * load / 100,
      'std:33': baro,
    });
  }
  return run;
}
