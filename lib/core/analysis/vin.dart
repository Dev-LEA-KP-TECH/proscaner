/// ถอดรหัส VIN (ISO 3779): ผู้ผลิต, ประเทศ, ปีรุ่น
library;

class VinInfo {
  const VinInfo({
    required this.vin,
    required this.valid,
    this.maker,
    this.country,
    this.modelYear,
    this.serial,
    this.yearReliable = false,
  });

  final String vin;
  final bool valid;

  /// ผู้ผลิตพร้อมประเทศที่ผลิต เช่น "Toyota (ประเทศไทย)"
  final String? maker;
  final String? country;

  /// ปีรุ่นจากหลักที่ 10 (ผู้ผลิตบางรายในเอเชียไม่ได้ใช้หลักนี้บอกปี)
  final int? modelYear;
  final String? serial;

  /// หลักที่ 10 เชื่อถือได้ว่าเป็นปีรุ่น (รถตลาดอเมริกา จีน เกาหลี บังคับตามมาตรฐาน)
  /// รถผลิตในไทย ญี่ปุ่น ยุโรป หลายยี่ห้อไม่ได้ใช้หลักนี้บอกปี จึงถือเป็นค่าประมาณ
  final bool yearReliable;

  /// ชื่อยี่ห้ออย่างเดียว ไม่มีประเทศ เช่น "Toyota"
  String? get brand => maker?.replaceAll(RegExp(r'\s*\(.*\)'), '').trim();

  /// WMI + VDS (8 หลักแรก) รถรุ่นเดียวกันจากโรงงานเดียวกันมักเหมือนกัน
  String? get familyKey => valid ? vin.substring(0, 8) : null;
}

const _th = 'ประเทศไทย', _jp = 'ญี่ปุ่น', _de = 'เยอรมนี', _cn = 'จีน', _kr = 'เกาหลี', _us = 'สหรัฐฯ';

const _wmi = <String, String>{
  // ผลิตในไทย
  'MR0': 'Toyota ($_th)',
  'MR1': 'Toyota ($_th)',
  'MR2': 'Toyota ($_th)',
  'MPA': 'Isuzu ($_th)',
  'MMB': 'Mitsubishi ($_th)',
  'MMT': 'Mitsubishi ($_th)',
  'MNT': 'Nissan ($_th)',
  'MRH': 'Honda ($_th)',
  'MM8': 'Mazda ($_th)',
  'MNB': 'Ford ($_th)',
  'MNA': 'Ford ($_th)',
  'MMM': 'Chevrolet ($_th)',
  // อาเซียน / อินเดีย
  'MHF': 'Toyota (อินโดนีเซีย)',
  'MHK': 'Daihatsu (อินโดนีเซีย)',
  'MHR': 'Honda (อินโดนีเซีย)',
  'MHY': 'Suzuki (อินโดนีเซีย)',
  'MA3': 'Suzuki (อินเดีย)',
  'MAK': 'Honda (อินเดีย)',
  'MAL': 'Hyundai (อินเดีย)',
  'MAJ': 'Ford (อินเดีย)',
  'MAT': 'Tata (อินเดีย)',
  'MBJ': 'Toyota (อินเดีย)',
  // ญี่ปุ่น
  'JTD': 'Toyota ($_jp)',
  'JTE': 'Toyota ($_jp)',
  'JTM': 'Toyota ($_jp)',
  'JTN': 'Toyota ($_jp)',
  'JTF': 'Toyota ($_jp)',
  'JTH': 'Lexus ($_jp)',
  'JTJ': 'Lexus ($_jp)',
  'JHM': 'Honda ($_jp)',
  'JHL': 'Honda ($_jp)',
  'JH4': 'Acura ($_jp)',
  'JN1': 'Nissan ($_jp)',
  'JN8': 'Nissan ($_jp)',
  'JNK': 'Infiniti ($_jp)',
  'JMB': 'Mitsubishi ($_jp)',
  'JMY': 'Mitsubishi ($_jp)',
  'JA3': 'Mitsubishi ($_jp)',
  'JA4': 'Mitsubishi ($_jp)',
  'JAA': 'Isuzu ($_jp)',
  'JAL': 'Isuzu ($_jp)',
  'JM1': 'Mazda ($_jp)',
  'JM3': 'Mazda ($_jp)',
  'JMZ': 'Mazda ($_jp)',
  'JF1': 'Subaru ($_jp)',
  'JF2': 'Subaru ($_jp)',
  'JS1': 'Suzuki ($_jp)',
  'JS2': 'Suzuki ($_jp)',
  'JS3': 'Suzuki ($_jp)',
  'JDA': 'Daihatsu ($_jp)',
  // เกาหลี
  'KMH': 'Hyundai ($_kr)',
  'KMF': 'Hyundai ($_kr)',
  'KNA': 'Kia ($_kr)',
  'KND': 'Kia ($_kr)',
  'KL1': 'Chevrolet ($_kr)',
  'KPT': 'SsangYong ($_kr)',
  // จีน
  'LGX': 'BYD ($_cn)',
  'LC0': 'BYD ($_cn)',
  'LSJ': 'MG / SAIC ($_cn)',
  'LGW': 'Great Wall ($_cn)',
  'LVV': 'Chery ($_cn)',
  'LS5': 'Changan ($_cn)',
  'LMG': 'GAC ($_cn)',
  'L6T': 'Geely ($_cn)',
  'LB3': 'Geely ($_cn)',
  'LZW': 'Wuling ($_cn)',
  'LRW': 'Tesla ($_cn)',
  'LVS': 'Ford ($_cn)',
  'LFV': 'Volkswagen ($_cn)',
  'LSV': 'Volkswagen ($_cn)',
  'LBV': 'BMW ($_cn)',
  'LE4': 'Mercedes-Benz ($_cn)',
  'LVG': 'Toyota ($_cn)',
  'LFM': 'Toyota ($_cn)',
  'LHG': 'Honda ($_cn)',
  'LVH': 'Honda ($_cn)',
  'LBE': 'Hyundai ($_cn)',
  'LYV': 'Volvo ($_cn)',
  // ยุโรป
  'WBA': 'BMW ($_de)',
  'WBS': 'BMW M ($_de)',
  'WBY': 'BMW i ($_de)',
  'WMW': 'MINI ($_de)',
  'WDB': 'Mercedes-Benz ($_de)',
  'WDD': 'Mercedes-Benz ($_de)',
  'WDC': 'Mercedes-Benz ($_de)',
  'WDF': 'Mercedes-Benz ($_de)',
  'W1K': 'Mercedes-Benz ($_de)',
  'W1N': 'Mercedes-Benz ($_de)',
  'WVW': 'Volkswagen ($_de)',
  'WVG': 'Volkswagen ($_de)',
  'WV1': 'Volkswagen ($_de)',
  'WV2': 'Volkswagen ($_de)',
  'WAU': 'Audi ($_de)',
  'WA1': 'Audi ($_de)',
  'WUA': 'Audi ($_de)',
  'WP0': 'Porsche ($_de)',
  'WP1': 'Porsche ($_de)',
  'WF0': 'Ford ($_de)',
  'W0L': 'Opel ($_de)',
  'SAL': 'Land Rover (อังกฤษ)',
  'SAJ': 'Jaguar (อังกฤษ)',
  'SCB': 'Bentley (อังกฤษ)',
  'SCA': 'Rolls-Royce (อังกฤษ)',
  'SCF': 'Aston Martin (อังกฤษ)',
  'VF1': 'Renault (ฝรั่งเศส)',
  'VF3': 'Peugeot (ฝรั่งเศส)',
  'VR3': 'Peugeot (ฝรั่งเศส)',
  'VF7': 'Citroën (ฝรั่งเศส)',
  'ZFA': 'Fiat (อิตาลี)',
  'ZFF': 'Ferrari (อิตาลี)',
  'ZHW': 'Lamborghini (อิตาลี)',
  'ZAM': 'Maserati (อิตาลี)',
  'ZAR': 'Alfa Romeo (อิตาลี)',
  'YV1': 'Volvo (สวีเดน)',
  'YV4': 'Volvo (สวีเดน)',
  'TMB': 'Škoda (เช็ก)',
  'VSS': 'SEAT (สเปน)',
  'NMT': 'Toyota (ตุรกี)',
  'AHT': 'Toyota (แอฟริกาใต้)',
  // อเมริกาเหนือ
  '1G1': 'Chevrolet ($_us)',
  '1GC': 'Chevrolet ($_us)',
  '1FA': 'Ford ($_us)',
  '1FT': 'Ford ($_us)',
  '1FM': 'Ford ($_us)',
  '1HG': 'Honda ($_us)',
  '2HG': 'Honda (แคนาดา)',
  '4T1': 'Toyota ($_us)',
  '5TD': 'Toyota ($_us)',
  '5TF': 'Toyota ($_us)',
  '1C4': 'Jeep / Chrysler ($_us)',
  '1J4': 'Jeep ($_us)',
  '3VW': 'Volkswagen (เม็กซิโก)',
  '5YJ': 'Tesla ($_us)',
  '7SA': 'Tesla ($_us)',
  '6FP': 'Ford (ออสเตรเลีย)',
};

/// เดายี่ห้อจาก 2 หลักแรก เมื่อ WMI ไม่อยู่ในตาราง (ใช้เฉพาะคู่ที่มีผู้ผลิตรายเดียว)
const _wmi2 = <String, String>{
  'JT': 'Toyota',
  'JH': 'Honda',
  'JN': 'Nissan',
  'JM': 'Mazda',
  'JF': 'Subaru',
  'JS': 'Suzuki',
  'KM': 'Hyundai',
  'KN': 'Kia',
  'WB': 'BMW',
  'WD': 'Mercedes-Benz',
  'W1': 'Mercedes-Benz',
  'WV': 'Volkswagen',
  'WA': 'Audi',
  'WP': 'Porsche',
  'YV': 'Volvo',
};

String? _country(String vin) {
  final a = vin[0], b = vin[1];
  if (a == 'M') {
    if ('ABCDE'.contains(b)) return 'อินเดีย';
    if ('FGHJK'.contains(b)) return 'อินโดนีเซีย';
    if ('LMNPR'.contains(b)) return 'ไทย';
    if ('STUVWXYZ'.contains(b)) return 'เมียนมา/อื่นๆ';
  }
  return switch (a) {
    'J' => 'ญี่ปุ่น',
    'K' => 'เกาหลีใต้',
    'L' => 'จีน',
    'P' => 'มาเลเซีย/ฟิลิปปินส์',
    'W' => 'เยอรมนี',
    'S' => 'สหราชอาณาจักร',
    'V' => 'ฝรั่งเศส/สเปน',
    'Z' => 'อิตาลี',
    'Y' => 'สวีเดน/ฟินแลนด์',
    'T' => 'ยุโรปกลาง',
    'N' => 'ตุรกี',
    'A' => 'แอฟริกาใต้',
    '1' || '4' || '5' || '7' => 'สหรัฐอเมริกา',
    '2' => 'แคนาดา',
    '3' => 'เม็กซิโก',
    '6' => 'ออสเตรเลีย',
    '9' => 'บราซิล',
    _ => null,
  };
}

const _yearCodes = 'ABCDEFGHJKLMNPRSTVWXY123456789';

int? decodeModelYear(String code, {int? nowYear}) {
  final i = _yearCodes.indexOf(code);
  if (i < 0) return null;
  final now = nowYear ?? DateTime.now().year;
  var y = 1980 + i;
  while (y + 30 <= now + 1) {
    y += 30;
  }
  return y;
}

VinInfo decodeVin17(String raw, {int? nowYear}) {
  final vin = raw.trim().toUpperCase();
  final valid = RegExp(r'^[A-HJ-NPR-Z0-9]{17}$').hasMatch(vin);
  if (!valid) return VinInfo(vin: vin, valid: false);
  final country = _country(vin);
  var maker = _wmi[vin.substring(0, 3)];
  if (maker == null) {
    final b = _wmi2[vin.substring(0, 2)];
    if (b != null) maker = country == null ? b : '$b ($country)';
  }
  return VinInfo(
    vin: vin,
    valid: true,
    maker: maker,
    country: country,
    modelYear: decodeModelYear(vin[9], nowYear: nowYear),
    serial: vin.substring(11),
    yearReliable: '12345KL'.contains(vin[0]),
  );
}
