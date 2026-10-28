import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/obd/pids.dart';

/// ใส่ค่าจริงใน main() ด้วย overrideWithValue(await SharedPreferences.getInstance())
final sharedPrefsProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('sharedPrefsProvider ต้องถูก override ใน main()'),
);

/// สีเน้นของธีม
enum AccentPreset {
  carbonRed('แดงคาร์บอน', Color(0xFFFF3B47)),
  electricBlue('ฟ้าไฟฟ้า', Color(0xFF2E9BFF)),
  racingOrange('ส้มเรซซิ่ง', Color(0xFFFF8A1F)),
  neonGreen('เขียวนีออน', Color(0xFF2BE38B)),
  royalGold('ทองพรีเมียม', Color(0xFFE8B84A)),
  ultraViolet('ม่วงอัลตร้า', Color(0xFFA06BFF));

  const AccentPreset(this.labelTh, this.color);

  final String labelTh;
  final Color color;
}

enum TempUnit {
  celsius('°C'),
  fahrenheit('°F');

  const TempUnit(this.label);
  final String label;
}

enum SpeedUnit {
  kmh('กม./ชม.'),
  mph('mph');

  const SpeedUnit(this.label);
  final String label;
}

/// ข้อมูลอู่ สำหรับหัวรายงาน PDF
@immutable
class ShopProfile {
  const ShopProfile({this.name = '', this.phone = '', this.address = '', this.technician = '', this.logoPath});

  final String name;
  final String phone;
  final String address;
  final String technician;
  final String? logoPath;

  bool get isEmpty => name.isEmpty && phone.isEmpty && address.isEmpty && logoPath == null;
}

/// เกณฑ์แจ้งเตือนขณะดูค่าสด/ขับ (0 = ปิด)
@immutable
class AlertLimits {
  const AlertLimits({
    this.enabled = true,
    this.coolantMax = 105,
    this.voltLow = 12.2,
    this.voltHigh = 15.2,
    this.rpmMax = 0,
    this.boostMax = 0,
    this.voice = true,
  });

  final bool enabled;

  /// พูดเตือนเป็นภาษาไทย (นอกจากแถบแดงและการสั่น)
  final bool voice;
  final double coolantMax;
  final double voltLow;
  final double voltHigh;
  final double rpmMax;
  final double boostMax;

  AlertLimits copyWith({
    bool? enabled,
    double? coolantMax,
    double? voltLow,
    double? voltHigh,
    double? rpmMax,
    double? boostMax,
    bool? voice,
  }) =>
      AlertLimits(
        enabled: enabled ?? this.enabled,
        coolantMax: coolantMax ?? this.coolantMax,
        voltLow: voltLow ?? this.voltLow,
        voltHigh: voltHigh ?? this.voltHigh,
        rpmMax: rpmMax ?? this.rpmMax,
        boostMax: boostMax ?? this.boostMax,
        voice: voice ?? this.voice,
      );
}

@immutable
class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.dark,
    this.accent = AccentPreset.carbonRed,
    this.tempUnit = TempUnit.celsius,
    this.speedUnit = SpeedUnit.kmh,
    this.shop = const ShopProfile(),
    this.alerts = const AlertLimits(),
    this.dashboardPids = const [Pid.rpm, Pid.coolantTemp, Pid.moduleVoltage, Pid.engineLoad],
  });

  final ThemeMode themeMode;
  final AccentPreset accent;
  final TempUnit tempUnit;
  final SpeedUnit speedUnit;
  final ShopProfile shop;
  final AlertLimits alerts;

  /// ค่าที่แสดงบนแดชบอร์ดตอนขับ (4 ช่อง รอบความเร็ว)
  final List<int> dashboardPids;

  AppSettings copyWith({
    ThemeMode? themeMode,
    AccentPreset? accent,
    TempUnit? tempUnit,
    SpeedUnit? speedUnit,
    ShopProfile? shop,
    AlertLimits? alerts,
    List<int>? dashboardPids,
  }) =>
      AppSettings(
        themeMode: themeMode ?? this.themeMode,
        accent: accent ?? this.accent,
        tempUnit: tempUnit ?? this.tempUnit,
        speedUnit: speedUnit ?? this.speedUnit,
        shop: shop ?? this.shop,
        alerts: alerts ?? this.alerts,
        dashboardPids: dashboardPids ?? this.dashboardPids,
      );
}

class SettingsNotifier extends Notifier<AppSettings> {
  SharedPreferences get _p => ref.read(sharedPrefsProvider);

  static T _pick<T extends Enum>(List<T> values, String? name, T fallback) =>
      values.firstWhere((v) => v.name == name, orElse: () => fallback);

  @override
  AppSettings build() {
    final p = ref.watch(sharedPrefsProvider);
    const d = AppSettings();
    const a = AlertLimits();
    final dash = p.getStringList('dash_pids')?.map(int.tryParse).whereType<int>().toList();
    return AppSettings(
      themeMode: _pick(ThemeMode.values, p.getString('theme_mode'), d.themeMode),
      accent: _pick(AccentPreset.values, p.getString('accent'), d.accent),
      tempUnit: _pick(TempUnit.values, p.getString('temp_unit'), d.tempUnit),
      speedUnit: _pick(SpeedUnit.values, p.getString('speed_unit'), d.speedUnit),
      shop: ShopProfile(
        name: p.getString('shop_name') ?? '',
        phone: p.getString('shop_phone') ?? '',
        address: p.getString('shop_address') ?? '',
        technician: p.getString('shop_tech') ?? '',
        logoPath: p.getString('shop_logo'),
      ),
      alerts: AlertLimits(
        enabled: p.getBool('al_on') ?? a.enabled,
        coolantMax: p.getDouble('al_cool') ?? a.coolantMax,
        voltLow: p.getDouble('al_vlo') ?? a.voltLow,
        voltHigh: p.getDouble('al_vhi') ?? a.voltHigh,
        rpmMax: p.getDouble('al_rpm') ?? a.rpmMax,
        boostMax: p.getDouble('al_boost') ?? a.boostMax,
        voice: p.getBool('al_voice') ?? a.voice,
      ),
      dashboardPids: dash == null || dash.length != 4 ? d.dashboardPids : dash,
    );
  }

  void setThemeMode(ThemeMode m) {
    state = state.copyWith(themeMode: m);
    _p.setString('theme_mode', m.name);
  }

  void setAccent(AccentPreset a) {
    state = state.copyWith(accent: a);
    _p.setString('accent', a.name);
  }

  void setTempUnit(TempUnit u) {
    state = state.copyWith(tempUnit: u);
    _p.setString('temp_unit', u.name);
  }

  void setSpeedUnit(SpeedUnit u) {
    state = state.copyWith(speedUnit: u);
    _p.setString('speed_unit', u.name);
  }

  void setShop(ShopProfile s) {
    state = state.copyWith(shop: s);
    _p.setString('shop_name', s.name);
    _p.setString('shop_phone', s.phone);
    _p.setString('shop_address', s.address);
    _p.setString('shop_tech', s.technician);
    if (s.logoPath == null) {
      _p.remove('shop_logo');
    } else {
      _p.setString('shop_logo', s.logoPath!);
    }
  }

  void setAlerts(AlertLimits a) {
    state = state.copyWith(alerts: a);
    _p.setBool('al_on', a.enabled);
    _p.setBool('al_voice', a.voice);
    _p.setDouble('al_cool', a.coolantMax);
    _p.setDouble('al_vlo', a.voltLow);
    _p.setDouble('al_vhi', a.voltHigh);
    _p.setDouble('al_rpm', a.rpmMax);
    _p.setDouble('al_boost', a.boostMax);
  }

  void setDashboardPid(int slot, int pid) {
    final list = [...state.dashboardPids];
    list[slot] = pid;
    state = state.copyWith(dashboardPids: list);
    _p.setStringList('dash_pids', list.map((e) => e.toString()).toList());
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);

/// ค่าที่พร้อมแสดงผลหลังแปลงหน่วยตามที่ผู้ใช้เลือก
class DisplayValue {
  const DisplayValue(this.value, this.unit, this.decimals, this.min, this.max);

  final double value;
  final String unit;
  final int decimals;
  final double min;
  final double max;

  String get text => value.toStringAsFixed(decimals);
  String get withUnit => unit.isEmpty ? text : '$text $unit';
  double get fraction => max <= min ? 0 : ((value - min) / (max - min)).clamp(0.0, 1.0);
}

DisplayValue displayPid(PidDef def, double v, AppSettings s) {
  var value = v;
  var unit = def.unit;
  var min = def.min ?? 0;
  var max = def.max ?? 100;
  if (def.unit == '°C' && s.tempUnit == TempUnit.fahrenheit) {
    double f(double c) => c * 9 / 5 + 32;
    value = f(v);
    min = f(min);
    max = f(max);
    unit = '°F';
  } else if (def.unit == 'กม./ชม.' && s.speedUnit == SpeedUnit.mph) {
    const k = 0.621371;
    value = v * k;
    min *= k;
    max *= k;
    unit = 'mph';
  }
  return DisplayValue(value, unit, def.decimals, min, max);
}

/// จัดรูปตัวเลขมีคอมมา เช่น 186,420
String groupDigits(num v, {int decimals = 0}) {
  final s = v.toStringAsFixed(decimals);
  final parts = s.split('.');
  final neg = parts[0].startsWith('-');
  final digits = neg ? parts[0].substring(1) : parts[0];
  final b = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) b.write(',');
    b.write(digits[i]);
  }
  return '${neg ? '-' : ''}$b${parts.length > 1 ? '.${parts[1]}' : ''}';
}
