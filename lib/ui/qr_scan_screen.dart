import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'theme.dart';

/// สแกน QR/บาร์โค้ด แล้วคืนข้อความที่อ่านได้
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key, this.title = 'สแกนรหัส'});

  final String title;

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  final _controller = MobileScannerController(detectionSpeed: DetectionSpeed.noDuplicates);
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final v = b.rawValue?.trim();
      if (v != null && v.isNotEmpty) {
        _done = true;
        Navigator.of(context).pop(v);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: FitText(widget.title),
        actions: [
          IconButton(
            tooltip: 'ไฟฉาย',
            icon: const Icon(Icons.flashlight_on_rounded),
            onPressed: () => _controller.toggleTorch(),
          ),
        ],
      ),
      body: Stack(fit: StackFit.expand, children: [
        MobileScanner(controller: _controller, onDetect: _onDetect),
        IgnorePointer(
          child: Center(
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 3),
                borderRadius: BorderRadius.circular(22),
              ),
            ),
          ),
        ),
        const Positioned(
          left: 24,
          right: 24,
          bottom: 40,
          child: Text(
            'เล็ง QR บนตัวหัวฉีดให้อยู่ในกรอบ ทำความสะอาดคราบน้ำมันก่อนสแกน',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white, fontSize: 14, height: 1.4),
          ),
        ),
      ]),
    );
  }
}
