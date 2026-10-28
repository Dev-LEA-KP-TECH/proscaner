import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// ผลการตรวจว่าเครื่องพูดภาษาไทยได้หรือไม่
enum VoiceStatus { ready, noThai, unavailable }

/// เสียงพูดเตือนภาษาไทย (ใช้เสียงอ่านข้อความของเครื่อง)
abstract class VoiceService {
  Future<VoiceStatus> check();
  Future<void> speak(String text);
  Future<void> stop();
}

/// ใช้ Text-to-Speech ของระบบ (Android: Google TTS, iOS: เสียงของ Apple)
class TtsVoiceService implements VoiceService {
  FlutterTts? _tts;
  VoiceStatus? _status;

  Future<FlutterTts?> _engine() async {
    if (_tts != null) return _tts;
    try {
      final t = FlutterTts();
      await t.awaitSpeakCompletion(false);
      final ok = await t.isLanguageAvailable('th-TH');
      if (ok == true) {
        await t.setLanguage('th-TH');
        _status = VoiceStatus.ready;
      } else {
        _status = VoiceStatus.noThai;
      }
      await t.setSpeechRate(0.5);
      await t.setVolume(1.0);
      await t.setPitch(1.0);
      _tts = t;
      return t;
    } catch (_) {
      // ไม่มีปลั๊กอิน (เช่นตอนเทสต์) หรือเครื่องไม่มีระบบอ่านออกเสียง
      _status = VoiceStatus.unavailable;
      return null;
    }
  }

  @override
  Future<VoiceStatus> check() async {
    await _engine();
    return _status ?? VoiceStatus.unavailable;
  }

  @override
  Future<void> speak(String text) async {
    final t = await _engine();
    if (t == null || _status != VoiceStatus.ready) return;
    try {
      await t.stop();
      await t.speak(text);
    } catch (_) {
      // พูดไม่สำเร็จ ไม่ให้กระทบการอ่านค่า
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _tts?.stop();
    } catch (_) {}
  }
}

/// ไม่มีเสียง (ใช้ในเทสต์) เก็บข้อความที่ "พูด" ไว้ให้ตรวจ
class SilentVoiceService implements VoiceService {
  final spoken = <String>[];

  @override
  Future<VoiceStatus> check() async => VoiceStatus.ready;

  @override
  Future<void> speak(String text) async => spoken.add(text);

  @override
  Future<void> stop() async {}
}

final voiceServiceProvider = Provider<VoiceService>((ref) => TtsVoiceService());
