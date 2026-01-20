import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:async';
import 'dart:io' show Platform;
import '../services/transcription_service.dart';
import '../services/audio_capture_service.dart';
import '../services/windows_audio_service.dart';
import '../models/transcript_bubble.dart';

class SpeechToTextProvider extends ChangeNotifier {
  TranscriptionService? _transcriptionService;
  AudioCaptureService? _audioCaptureService;
  Timer? _mockAudioTimer;
  Timer? _systemAudioPollTimer;
  bool _isSystemAudioCapturing = false;
  
  bool _isRecording = false;
  bool _isConnected = false;
  final List<TranscriptBubble> _bubbles = <TranscriptBubble>[];
  String _errorMessage = '';
  int _audioFrameCount = 0;

  bool get isRecording => _isRecording;
  bool get isConnected => _isConnected;
  List<TranscriptBubble> get bubbles => List.unmodifiable(_bubbles);
  String get errorMessage => _errorMessage;

  String _appendWithOverlap(String existing, String next) {
    final nextTrimmed = next.trim();
    if (nextTrimmed.isEmpty) return existing;

    final existingTrimmed = existing.trimRight();
    if (existingTrimmed.isEmpty) return nextTrimmed;

    if (existingTrimmed.toLowerCase().endsWith(nextTrimmed.toLowerCase())) {
      return existingTrimmed;
    }

    const tailWindow = 200;
    final tail = existingTrimmed.substring(
      existingTrimmed.length > tailWindow ? existingTrimmed.length - tailWindow : 0,
    );

    final tailLower = tail.toLowerCase();
    final nextLower = nextTrimmed.toLowerCase();
    final maxOverlap = tailLower.length < nextLower.length ? tailLower.length : nextLower.length;

    var overlap = 0;
    for (var i = 1; i <= maxOverlap; i++) {
      if (tailLower.substring(tailLower.length - i) == nextLower.substring(0, i)) {
        overlap = i;
      }
    }

    final toAppend = nextTrimmed.substring(overlap);
    if (toAppend.isEmpty) return existingTrimmed;

    final needsSpace = !existingTrimmed.endsWith(' ') && !existingTrimmed.endsWith('\n');
    return existingTrimmed + (needsSpace ? ' ' : '') + toAppend;
  }

  void _upsertFinalBubble({required TranscriptSource source, required String text}) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    // If the last bubble is from the same source, merge into it to reduce fragmentation.
    if (_bubbles.isNotEmpty && _bubbles.last.source == source) {
      // If the last bubble is a draft, finalize it in-place.
      if (_bubbles.last.isDraft) {
        _bubbles[_bubbles.length - 1] = _bubbles.last.copyWith(
          text: trimmed,
          isDraft: false,
          timestamp: DateTime.now(),
        );
        return;
      }

      final merged = _appendWithOverlap(_bubbles.last.text, trimmed);
      _bubbles[_bubbles.length - 1] = _bubbles.last.copyWith(text: merged);
      return;
    }

    _bubbles.add(
      TranscriptBubble(
        source: source,
        text: trimmed,
        timestamp: DateTime.now(),
        isDraft: false,
      ),
    );
  }

  void _upsertDraftBubble({required TranscriptSource source, required String text}) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    // Update existing draft bubble for this source if it is the most recent.
    if (_bubbles.isNotEmpty && _bubbles.last.source == source && _bubbles.last.isDraft) {
      _bubbles[_bubbles.length - 1] = _bubbles.last.copyWith(
        text: trimmed,
        timestamp: DateTime.now(),
      );
      return;
    }

    // Otherwise append a new draft bubble (interleaved transcripts are expected).
    _bubbles.add(
      TranscriptBubble(
        source: source,
        text: trimmed,
        timestamp: DateTime.now(),
        isDraft: true,
      ),
    );
  }

  Future<bool> requestPermissions() async {
    final status = await Permission.microphone.request();
    return status.isGranted;
  }

  Future<void> initialize(String serverUrl) async {
    _transcriptionService = TranscriptionService(serverUrl: serverUrl);
    
    _transcriptionService!.transcriptStream.listen(
      (result) {
        final source = switch (result.source) {
          'mic' => TranscriptSource.mic,
          'system' => TranscriptSource.system,
          _ => TranscriptSource.unknown,
        };

        if (result.isFinal) {
          _upsertFinalBubble(source: source, text: result.text);
        } else {
          _upsertDraftBubble(source: source, text: result.text);
        }

        notifyListeners();
      },
      onError: (error) {
        _errorMessage = error.toString();
        notifyListeners();
      },
    );
  }

  Future<void> startRecording() async {
    try {
      print('[SpeechToTextProvider] Starting recording...');
      _errorMessage = '';
      _audioFrameCount = 0;
      _isSystemAudioCapturing = false;
      _bubbles.clear();
      
      // Request permissions
      final hasPermission = await requestPermissions();
      if (!hasPermission) {
        _errorMessage = 'Microphone permission denied';
        print('[SpeechToTextProvider] Microphone permission denied');
        notifyListeners();
        return;
      }

      print('[SpeechToTextProvider] Permission granted, connecting to transcription service...');
      // Connect to WebSocket
      await _transcriptionService?.connect();
      _isConnected = true;

      // Start system audio capture on Windows (best-effort).
      if (!kIsWeb && Platform.isWindows) {
        final started = await WindowsAudioService.startSystemAudioCapture();
        _isSystemAudioCapturing = started;
        if (started) {
          _systemAudioPollTimer?.cancel();
          _systemAudioPollTimer = Timer.periodic(
            const Duration(milliseconds: 50),
            (_) {
              // Pull ~50ms at 16kHz mono PCM16 => 16000*0.05*2 = 1600 bytes
              WindowsAudioService.getSystemAudioFrame(lengthBytes: 1600).then((frame) {
                if (frame.isEmpty) return;
                _transcriptionService?.sendAudio(frame, source: 'system');
              });
            },
          );
        } else {
          print('[SpeechToTextProvider] System audio capture not available');
        }
      }

      // Initialize audio capture
      _audioCaptureService = AudioCaptureService(
        onAudioData: (audioData) {
          _audioFrameCount++;
          if (_audioFrameCount % 10 == 0) {
            print('[SpeechToTextProvider] Audio frame #$_audioFrameCount: ${audioData.length} bytes');
          }
          _transcriptionService?.sendAudio(audioData, source: 'mic');
        },
      );

      // Request microphone permission and start capturing
      final canCapture = await _audioCaptureService!.requestPermissions();
      if (!canCapture) {
        _errorMessage = 'Microphone permission denied';
        _isConnected = false;
        _transcriptionService?.disconnect();
        notifyListeners();
        return;
      }

      // Start audio capturing
      try {
        await _audioCaptureService!.startCapturing();
      } catch (e) {
        _errorMessage = 'Failed to start audio capture: $e';
        _isConnected = false;
        _transcriptionService?.disconnect();
        notifyListeners();
        return;
      }

      _isRecording = true;
      notifyListeners();
      print('[SpeechToTextProvider] Recording started with real audio capture');
    } catch (e) {
      _errorMessage = 'Failed to start recording: $e';
      print('[SpeechToTextProvider] Error: $e');
      _isRecording = false;
      _isConnected = false;
      notifyListeners();
    }
  }

  Future<void> stopRecording() async {
    try {
      print('[SpeechToTextProvider] Stopping recording...');
      _mockAudioTimer?.cancel();
      _mockAudioTimer = null;

      _systemAudioPollTimer?.cancel();
      _systemAudioPollTimer = null;
      if (!kIsWeb && Platform.isWindows && _isSystemAudioCapturing) {
        await WindowsAudioService.stopSystemAudioCapture();
      }
      _isSystemAudioCapturing = false;
      
      // Stop audio capture
      await _audioCaptureService?.stopCapturing();
      _audioCaptureService?.dispose();
      _audioCaptureService = null;
      
      // Disconnect from transcription
      _transcriptionService?.disconnect();
      
      _isRecording = false;
      _isConnected = false;
      print('[SpeechToTextProvider] Recording stopped. Processed $_audioFrameCount audio frames');
      notifyListeners();
    } catch (e) {
      _errorMessage = 'Failed to stop recording: $e';
      print('[SpeechToTextProvider] Error stopping: $e');
      notifyListeners();
    }
  }

  void clearTranscript() {
    _bubbles.clear();
    _errorMessage = '';
    notifyListeners();
  }

  @override
  void dispose() {
    _mockAudioTimer?.cancel();
    _audioCaptureService?.dispose();
    _transcriptionService?.dispose();
    super.dispose();
  }
}
