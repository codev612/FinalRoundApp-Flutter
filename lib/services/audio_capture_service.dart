import 'dart:async';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AudioCaptureService {
  late final AudioRecorder _recorder;
  StreamSubscription? _audioSubscription;
  final Function(List<int>) onAudioData;

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

      // Check if recorder is recording already
      final isRecording = await _recorder.isRecording();
      if (isRecording) {
        await _recorder.stop();
      }

      // Get selected device ID if available
      final selectedDeviceId = await getSelectedDeviceId();
      
      // Try to find and use the selected device
      InputDevice? selectedDevice;
      if (selectedDeviceId != null && selectedDeviceId.isNotEmpty) {
        try {
          final devices = await _recorder.listInputDevices();
          final device = devices.firstWhere(
            (d) => d.id == selectedDeviceId,
            orElse: () => InputDevice(id: '', label: ''),
          );
          if (device.id.isNotEmpty) {
            selectedDevice = device;
            print('[AudioCaptureService] Using selected audio device: ${device.label} (${device.id})');
          }
        } catch (e) {
          print('[AudioCaptureService] Error finding device, using default: $e');
        }
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
      
      if (selectedDevice == null) {
        print('[AudioCaptureService] Using default audio device');
      }

      print('[AudioCaptureService] Audio stream started');

      // Listen to audio stream
      _audioSubscription = recordStream.listen(
        (data) {
          if (data.isNotEmpty) {
            print('[AudioCaptureService] Audio frame received: ${data.length} bytes');
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
      _audioSubscription?.cancel();
      
      final isRecording = await _recorder.isRecording();
      if (isRecording) {
        final path = await _recorder.stop();
        print('[AudioCaptureService] Recording stopped at: $path');
      }
    } catch (e) {
      print('[AudioCaptureService] Error stopping capture: $e');
    }
  }

  void dispose() {
    _audioSubscription?.cancel();
    _recorder.dispose();
  }
}
