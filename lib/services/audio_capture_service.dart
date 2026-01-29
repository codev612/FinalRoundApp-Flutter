import 'dart:async';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AudioCaptureService {
  late final AudioRecorder _recorder;
  StreamSubscription? _audioSubscription;
  final Function(List<int>) onAudioData;

  // Last device actually used (for warnings / debugging)
  String? lastUsedDeviceId;
  String? lastUsedDeviceLabel;
  bool usedFallbackDevice = false;
  bool selectedDeviceNotFound = false;

  AudioCaptureService({required this.onAudioData}) {
    _recorder = AudioRecorder();
  }

  /// Get the selected audio device ID from preferences
  static Future<String?> getSelectedDeviceId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString('selected_audio_device_id');
    } catch (e) {
      print('[AudioCaptureService] Error loading selected device: $e');
      return null;
    }
  }

  Future<bool> requestPermissions() async {
    try {
      final hasPermission = await _recorder.hasPermission();
      if (hasPermission == false) {
        print('[AudioCaptureService] No microphone permission');
        return false;
      }
      print('[AudioCaptureService] Microphone permission granted');
      return true;
    } catch (e) {
      print('[AudioCaptureService] Error requesting permissions: $e');
      return false;
    }
  }

  Future<void> startCapturing() async {
    try {
      print('[AudioCaptureService] Starting audio capture...');
      usedFallbackDevice = false;
      selectedDeviceNotFound = false;
      lastUsedDeviceId = null;
      lastUsedDeviceLabel = null;

      // Check if recorder is recording already
      final isRecording = await _recorder.isRecording();
      if (isRecording) {
        await _recorder.stop();
      }

      // Get selected device ID if available
      final selectedDeviceId = await getSelectedDeviceId();

      // Always list devices so we can handle unplug/replug gracefully.
      final devices = await _recorder.listInputDevices();

      // Try to find and use the selected device
      InputDevice? selectedDevice;
      if (selectedDeviceId != null && selectedDeviceId.isNotEmpty) {
        final match = devices.where((d) => d.id == selectedDeviceId).toList();
        if (match.isNotEmpty) {
          selectedDevice = match.first;
        } else {
          selectedDeviceNotFound = true;
          usedFallbackDevice = true;
        }
      } else {
        usedFallbackDevice = true;
      }

      // If no selected device (or it disappeared), pick a safer fallback than "whatever Windows default is".
      if (selectedDevice == null && devices.isNotEmpty) {
        final blacklist = <String>[
          'stereo mix',
          'what u hear',
          'loopback',
          'virtual',
          'cable',
          'voicemeeter',
        ];
        int score(InputDevice d) {
          final label = d.label.toLowerCase();
          if (label.trim().isEmpty) return -10;
          if (blacklist.any((b) => label.contains(b))) return -1000;
          var s = 0;
          if (label.contains('microphone') || label.contains('mic')) s += 10;
          return s;
        }

        InputDevice best = devices.first;
        var bestScore = score(best);
        for (final d in devices.skip(1)) {
          final s = score(d);
          if (s > bestScore) {
            best = d;
            bestScore = s;
          }
        }
        selectedDevice = best;
      }
      
      // Start recording microphone with streaming
      // RecordConfig.device parameter is optional and may not be supported on all platforms
      final recordStream = await _recorder.startStream(
        RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
          bitRate: 128000,
          device: selectedDevice?.id.isNotEmpty == true ? selectedDevice : null,
        ),
      );

      lastUsedDeviceId = selectedDevice?.id;
      lastUsedDeviceLabel = selectedDevice?.label;
      if (selectedDeviceNotFound) {
        print('[AudioCaptureService] Selected device not found (unplugged/reconnected?). Using fallback: ${selectedDevice?.label ?? 'default'}');
      } else if (usedFallbackDevice) {
        print('[AudioCaptureService] Using fallback audio device: ${selectedDevice?.label ?? 'default'}');
      } else if (selectedDevice != null) {
        print('[AudioCaptureService] Using selected audio device: ${selectedDevice.label} (${selectedDevice.id})');
      }

      print('[AudioCaptureService] Audio stream started');

      // Listen to audio stream
      _audioSubscription = recordStream.listen(
        (data) {
          if (data.isNotEmpty) {
            onAudioData(data);
          }
        },
        onError: (error) {
          print('[AudioCaptureService] Stream error: $error');
        },
        onDone: () {
          print('[AudioCaptureService] Stream done');
        },
      );
    } catch (e) {
      print('[AudioCaptureService] Error starting capture: $e');
      rethrow;
    }
  }

  Future<void> stopCapturing() async {
    try {
      print('[AudioCaptureService] Stopping audio capture...');
      try {
        // Avoid hanging forever if stream cancel never completes.
        await _audioSubscription?.cancel().timeout(const Duration(seconds: 2));
      } catch (e) {
        print('[AudioCaptureService] Error canceling audio stream subscription: $e');
      }
      _audioSubscription = null;
      
      bool isRecording = false;
      try {
        isRecording = await _recorder.isRecording().timeout(const Duration(seconds: 2));
      } catch (e) {
        print('[AudioCaptureService] Error checking isRecording(): $e');
      }
      if (isRecording) {
        try {
          final path = await _recorder.stop().timeout(const Duration(seconds: 3));
          print('[AudioCaptureService] Recording stopped at: $path');
        } catch (e) {
          // This is the most common hang point on some systems. Don’t block UI.
          print('[AudioCaptureService] Error stopping recorder: $e');
        }
      }
    } catch (e) {
      print('[AudioCaptureService] Error stopping capture: $e');
    }
  }

  void dispose() {
    try {
      _audioSubscription?.cancel();
      _audioSubscription = null;
    } catch (e) {
      print('[AudioCaptureService] Error canceling subscription: $e');
    }
    try {
      _recorder.dispose();
    } catch (e) {
      print('[AudioCaptureService] Error disposing recorder: $e');
    }
  }
}
