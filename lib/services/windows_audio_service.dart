import 'package:flutter/services.dart';
import 'dart:typed_data';

class WindowsAudioService {
  static const platform = MethodChannel('com.finalround/audio');

  /// Start capturing system audio (Windows Stereo Mix / Loopback)
  static Future<bool> startSystemAudioCapture() async {
    try {
      final result = await platform.invokeMethod<bool>('startSystemAudio');
      return result ?? false;
    } catch (e) {
      print('[WindowsAudioService] Error starting system audio: $e');
      return false;
    }
  }

  /// Stop capturing system audio
  static Future<void> stopSystemAudioCapture() async {
    try {
      await platform.invokeMethod('stopSystemAudio');
    } catch (e) {
      print('[WindowsAudioService] Error stopping system audio: $e');
    }
  }

  /// Get system audio data
  /// Returns a stream of audio bytes from system audio
  static Future<List<int>> getSystemAudioFrame({int? lengthBytes}) async {
    try {
      final result = await platform.invokeMethod<Uint8List>(
        'getSystemAudioFrame',
        lengthBytes == null ? null : <String, dynamic>{'length': lengthBytes},
      );
      return result?.toList() ?? <int>[];
    } catch (e) {
      print('[WindowsAudioService] Error getting system audio frame: $e');
      return [];
    }
  }

  /// Mix microphone and system audio
  static List<int> mixAudio(List<int> micAudio, List<int> systemAudio) {
    final length = micAudio.length;
    final mixedAudio = List<int>.filled(length, 0);

    // Mix the audio by averaging samples (simple mixing)
    for (int i = 0; i < length; i += 2) {
      if (i + 1 >= length) continue;

      // Convert mic bytes to signed 16-bit integer
      int mic = (micAudio[i] & 0xFF) | ((micAudio[i + 1] & 0xFF) << 8);
      if ((mic & 0x8000) != 0) mic -= 0x10000;

      // If we don't have a matching system sample, pass mic through.
      if (i + 1 >= systemAudio.length) {
        mixedAudio[i] = micAudio[i];
        mixedAudio[i + 1] = micAudio[i + 1];
        continue;
      }

      int system = (systemAudio[i] & 0xFF) | ((systemAudio[i + 1] & 0xFF) << 8);
      if ((system & 0x8000) != 0) system -= 0x10000;

      // Mix (simple averaging to prevent clipping)
      int mixed = ((mic + system) ~/ 2).clamp(-32768, 32767);

      // Convert back to bytes
      mixedAudio[i] = mixed & 0xFF;
      mixedAudio[i + 1] = (mixed >> 8) & 0xFF;
    }

    return mixedAudio;
  }
}
