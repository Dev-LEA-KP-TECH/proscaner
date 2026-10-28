/// รายชื่อยี่ห้อและรุ่นยอดนิยมในไทย สำหรับให้ผู้ใช้เลือกรุ่นด้วยการแตะครั้งเดียว
library;

class BrandInfo {
  const BrandInfo(this.name, this.color, this.models, {this.aliases = const []});

  final String name;

  /// สีประจำแบรนด์ (ARGB) ใช้กับตราสัญลักษณ์ตัวอักษรในแอป
  final int color;
  final List<String> models;

  /// ชื่ออื่นที่ VIN อาจถอดได้ เช่น "MG / SAIC"
  final List<String> aliases;

  /// ไฟล์โลโก้ที่ผู้ใช้ใส่เองได้ เช่น assets/brand_logos/mercedes_benz.png
  String get logoAsset => brandLogoAsset(name);

  /// อักษรย่อสำหรับตราในแอป (ไม่ใช้โลโก้จริงของแบรนด์)
  String get initials {
    final parts = name.split(RegExp(r'[\s\-/]+')).where((p) => p.isNotEmpty).toList();
    if (parts.length >= 2) return (parts[0][0] + parts[1][0]).toUpperCase();
    return name.length <= 4 ? name.toUpperCase() : name[0].toUpperCase();
  }
}

const brandCatalog = <BrandInfo>[
  BrandInfo('Toyota', 0xFFE0242F, [
    'Hilux Revo', 'Hilux Vigo', 'Hilux Champ', 'Hilux Tiger', 'Fortuner', 'Yaris', 'Yaris Ativ', 'Vios', 'Corolla Altis',
    'Corolla Cross', 'Camry', 'C-HR', 'Innova', 'Veloz', 'Avanza', 'Sienta', 'Commuter', 'Hiace', 'Majesty', 'Alphard',
    'Land Cruiser', 'Prius',
  ]),
  BrandInfo('Isuzu', 0xFFD3202A, ['D-Max', 'D-Max V-Cross', 'MU-X', 'MU-7', 'Dragon Eye', 'TFR']),
  BrandInfo('Honda', 0xFFCC0000, ['City', 'City Hatchback', 'Civic', 'Jazz', 'HR-V', 'CR-V', 'BR-V', 'WR-V', 'Accord', 'Brio', 'Mobilio']),
  BrandInfo('Mitsubishi', 0xFFE60012, ['Triton', 'Pajero Sport', 'Xpander', 'Xpander Cross', 'Attrage', 'Mirage', 'Lancer', 'Space Wagon', 'Strada']),
  BrandInfo('Nissan', 0xFFC3002F, ['Navara', 'Almera', 'Kicks', 'Terra', 'Note', 'March', 'Sylphy', 'Teana', 'X-Trail', 'Urvan', 'Frontier']),
  BrandInfo('Mazda', 0xFF910A2D, ['Mazda2', 'Mazda3', 'CX-3', 'CX-30', 'CX-5', 'CX-8', 'BT-50', 'MX-5']),
  BrandInfo('Ford', 0xFF1351D8, ['Ranger', 'Ranger Raptor', 'Everest', 'Fiesta', 'Focus', 'EcoSport']),
  BrandInfo('Chevrolet', 0xFFD1A13B, ['Colorado', 'Trailblazer', 'Captiva', 'Cruze', 'Sonic', 'Spin', 'Optra']),
  BrandInfo('Suzuki', 0xFF1E50A2, ['Swift', 'Ciaz', 'Celerio', 'Ertiga', 'XL7', 'Carry', 'Jimny', 'Vitara']),
  BrandInfo('MG', 0xFFB1132B, ['MG3', 'MG5', 'ZS', 'ZS EV', 'HS', 'HS PHEV', 'VS HEV', 'Extender', 'MG4', 'Maxus 9', 'Cyberster'],
      aliases: ['MG / SAIC', 'SAIC']),
  BrandInfo('BYD', 0xFF2B6CB0, ['Atto 3', 'Dolphin', 'Seal', 'Sealion 6', 'Sealion 7', 'M6', 'Atto 2']),
  BrandInfo('GWM', 0xFF2F7A3E, ['Haval H6', 'Haval Jolion', 'Haval H6 HEV', 'ORA Good Cat', 'ORA 07', 'Tank 300', 'Tank 500', 'Cannon'],
      aliases: ['Great Wall', 'Haval', 'ORA']),
  BrandInfo('Hyundai', 0xFF00287A, ['H-1', 'Staria', 'Creta', 'Stargazer', 'Ioniq 5', 'Tucson', 'Elantra']),
  BrandInfo('Kia', 0xFF05141F, ['Carnival', 'Sorento', 'Sportage', 'EV6', 'EV9', 'Grand Carnival']),
  BrandInfo('Subaru', 0xFF1C3F94, ['Forester', 'XV', 'Outback', 'BRZ', 'Impreza', 'WRX']),
  BrandInfo('BMW', 0xFF1C69D4, ['Series 3', 'Series 5', 'Series 7', 'X1', 'X3', 'X5', 'X7', 'iX', 'i4', 'Z4'],
      aliases: ['BMW M', 'BMW i']),
  BrandInfo('Mercedes-Benz', 0xFF5E6772, ['A-Class', 'C-Class', 'E-Class', 'S-Class', 'CLA', 'GLA', 'GLC', 'GLE', 'GLS', 'EQS', 'V-Class']),
  BrandInfo('Volvo', 0xFF003057, ['XC40', 'XC60', 'XC90', 'S60', 'S90', 'EX30']),
  BrandInfo('Lexus', 0xFF1A1A1A, ['ES', 'IS', 'NX', 'RX', 'UX', 'LM', 'LX']),
  BrandInfo('Porsche', 0xFFB12B28, ['911', 'Cayenne', 'Macan', 'Panamera', 'Taycan']),
  BrandInfo('Volkswagen', 0xFF001E50, ['Caravelle', 'Golf', 'Tiguan', 'Passat']),
  BrandInfo('Audi', 0xFFBB0A30, ['A4', 'A5', 'A6', 'Q3', 'Q5', 'Q7', 'Q8', 'e-tron']),
  BrandInfo('MINI', 0xFF1A1A1A, ['Cooper', 'Countryman', 'Clubman']),
  BrandInfo('Tesla', 0xFFCC0000, ['Model 3', 'Model Y', 'Model S', 'Model X']),
  BrandInfo('Chery', 0xFFB4162B, ['Omoda C5', 'Omoda 5', 'Jaecoo 6', 'Jaecoo 7', 'Tiggo 8']),
  BrandInfo('Changan', 0xFF1D4E9E, ['Deepal S07', 'Deepal L07', 'Lumin', 'Avatr 11']),
  BrandInfo('GAC', 0xFF1F3B73, ['Aion Y Plus', 'Aion V', 'Aion ES', 'Hyptec HT']),
  BrandInfo('Neta', 0xFF1E88E5, ['Neta V', 'Neta X', 'Neta O']),
  BrandInfo('Land Rover', 0xFF005A2B, ['Defender', 'Discovery', 'Range Rover', 'Range Rover Sport', 'Range Rover Evoque']),
  BrandInfo('Peugeot', 0xFF00255A, ['2008', '3008', '5008']),
  BrandInfo('Daihatsu', 0xFFE60012, ['Mira', 'Terios', 'Hijet']),
  BrandInfo('Geely', 0xFF1F4E9E, ['EX5', 'Coolray', 'Emgrand']),
  BrandInfo('Wuling', 0xFFC8102E, ['Air ev', 'Bingo']),
  BrandInfo('Xpeng', 0xFF1A1A1A, ['G6', 'P7', 'X9']),
  BrandInfo('Zeekr', 0xFF1A1A1A, ['X', '001', '009', '7X']),
  BrandInfo('Leapmotor', 0xFF1A1A1A, ['C10', 'C11', 'T03']),
  BrandInfo('Omoda', 0xFF1A1A1A, ['C5', 'E5']),
  BrandInfo('Foton', 0xFF5A6B7B, ['Tunland', 'View']),
  BrandInfo('Jaguar', 0xFF1A1A1A, ['F-Pace', 'E-Pace', 'XE', 'XF', 'F-Type']),
  BrandInfo('Ferrari', 0xFFD40000, ['296', 'Roma', 'Purosangue', 'SF90']),
  BrandInfo('Lamborghini', 0xFFB8962E, ['Urus', 'Huracán', 'Revuelto']),
  BrandInfo('Rolls-Royce', 0xFF1A1A1A, ['Cullinan', 'Ghost', 'Phantom', 'Spectre']),
  BrandInfo('Bentley', 0xFF1F3B2D, ['Bentayga', 'Continental GT', 'Flying Spur']),
  BrandInfo('Aston Martin', 0xFF00665E, ['DB12', 'DBX', 'Vantage']),
  BrandInfo('Maserati', 0xFF0C2340, ['Grecale', 'Levante', 'MC20', 'Ghibli']),
  BrandInfo('McLaren', 0xFFFF8000, ['750S', 'Artura', 'GT']),
];

/// หายี่ห้อจากชื่อ (ไม่สนตัวพิมพ์ เทียบชื่ออื่นด้วย)
BrandInfo? brandByName(String? name) {
  if (name == null || name.trim().isEmpty) return null;
  final n = name.trim().toLowerCase();
  for (final b in brandCatalog) {
    if (b.name.toLowerCase() == n) return b;
    if (b.aliases.any((a) => a.toLowerCase() == n)) return b;
  }
  return null;
}

/// ชื่อยี่ห้อมาตรฐานของแอป เช่น VIN ถอดได้ "MG / SAIC" → "MG", "Great Wall" → "GWM"
String? normalizeBrand(String? name) => brandByName(name)?.name ?? name?.trim();

/// สีของยี่ห้อ ถ้าไม่รู้จักคืน null
int? brandColor(String? name) => brandByName(name)?.color;

/// ที่อยู่ไฟล์โลโก้ของยี่ห้อ (ชื่อไฟล์ตัวพิมพ์เล็ก เว้นวรรค/ขีด เป็น _) เช่น "Land Rover" → assets/brand_logos/land_rover.png
String brandLogoAsset(String name) =>
    'assets/brand_logos/${name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '')}.png';
