/// ค่าเซ็นเซอร์ ณ ตอนที่รหัสปัญหาเกิดขึ้น
class FreezeFrame {
  const FreezeFrame(this.dtc, this.values);

  final String dtc;
  final Map<int, double> values;

  Map<String, dynamic> toJson() =>
      {'dtc': dtc, 'values': values.map((k, v) => MapEntry(k.toString(), v))};

  factory FreezeFrame.fromJson(Map<String, dynamic> j) => FreezeFrame(
        j['dtc'] as String,
        (j['values'] as Map<String, dynamic>).map((k, v) => MapEntry(int.parse(k), (v as num).toDouble())),
      );
}
