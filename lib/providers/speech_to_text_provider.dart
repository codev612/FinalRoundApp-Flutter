import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:async';
import 'dart:io' show Platform;
import '../services/transcription_service.dart';
import '../services/audio_capture_service.dart';
import '../services/windows_audio_service.dart';
import '../services/ai_service.dart';
import '../models/transcript_bubble.dart';

class SpeechToTextProvider extends ChangeNotifier {
  TranscriptionService? _transcriptionService;
  AudioCaptureService? _audioCaptureService;
  AiService? _aiService;
  Timer? _mockAudioTimer;
  Timer? _systemAudioPollTimer;
  bool _isSystemAudioCapturing = false;
  bool _useMic = true;
  
  // Track when last system final transcript was received to suppress mic echo
  DateTime? _lastSystemFinalTime;
  // Increased window for gaming headphones (echo can be delayed)
  static const _micSuppressionWindow = Duration(milliseconds: 3000);
  
  // Track recent system transcripts to detect if system audio is actively playing
  final List<DateTime> _recentSystemTranscripts = [];
  static const _systemActivityWindow = Duration(seconds: 10);
  
  // Track when recording started to suppress mic initially (prevent early duplicates)
  DateTime? _recordingStartTime;
  static const _initialSuppressionWindow = Duration(seconds: 8); // Suppress mic for first 8 seconds when system audio is active
  
  bool _isRecording = false;
  bool _isConnected = false;
  final List<TranscriptBubble> _bubbles = <TranscriptBubble>[];
  String _errorMessage = '';
  int _audioFrameCount = 0;

  String _aiResponse = '';
  String _aiErrorMessage = '';
  bool _isAiLoading = false;

  bool get isRecording => _isRecording;
  bool get isConnected => _isConnected;
  bool get useMic => _useMic;
  List<TranscriptBubble> get bubbles => List.unmodifiable(_bubbles);
  String get errorMessage => _errorMessage;

  String get aiResponse => _aiResponse;
  String get aiErrorMessage => _aiErrorMessage;
  bool get isAiLoading => _isAiLoading;

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

  /// Calculate similarity between two texts (0.0 to 1.0)
  double _calculateSimilarity(String text1, String text2) {
    final norm1 = text1.toLowerCase().trim();
    final norm2 = text2.toLowerCase().trim();
    
    // Exact match
    if (norm1 == norm2) return 1.0;
    
    // Check word overlap
    final words1 = norm1.split(RegExp(r'\s+')).where((w) => w.length > 2).toSet();
    final words2 = norm2.split(RegExp(r'\s+')).where((w) => w.length > 2).toSet();
    
    if (words1.isEmpty || words2.isEmpty) return 0.0;
    
    final intersection = words1.intersection(words2).length;
    final union = words1.union(words2).length;
    
    // Jaccard similarity (intersection over union)
    return union > 0 ? intersection / union : 0.0;
  }
  
  /// Check if system audio is actively playing (has recent transcripts)
  bool _isSystemAudioActive() {
    if (_recentSystemTranscripts.isEmpty) return false;
    final now = DateTime.now();
    // Check if there's a system transcript in the last 3 seconds
    return _recentSystemTranscripts.any((time) => now.difference(time) < const Duration(seconds: 3));
  }
  
  /// Check if text is similar to any recent transcript from the other source
  bool _isSimilarToRecentTranscript(String text, TranscriptSource source, {int checkLast = 15}) {
    final otherSource = source == TranscriptSource.mic ? TranscriptSource.system : TranscriptSource.mic;
    final now = DateTime.now();
    final checkWindow = const Duration(seconds: 8); // Increased window for gaming headphones
    
    // Check recent bubbles from the other source
    final searchLimit = _bubbles.length > checkLast ? _bubbles.length - checkLast : 0;
    for (int i = _bubbles.length - 1; i >= searchLimit; i--) {
      final bubble = _bubbles[i];
      
      // Only check final bubbles from the other source within time window
      if (bubble.source != otherSource || bubble.isDraft) continue;
      if (now.difference(bubble.timestamp) > checkWindow) break;
      
      final similarity = _calculateSimilarity(text, bubble.text);
      // Lower threshold for mic (more aggressive) - 60% instead of 70%
      final threshold = source == TranscriptSource.mic ? 0.6 : 0.7;
      if (similarity > threshold) {
        print('[SpeechToTextProvider] Found similar transcript: "$text" (similarity: ${(similarity * 100).toStringAsFixed(1)}%) matches "${bubble.text}"');
        return true;
      }
    }
    
    return false;
  }

  void _upsertFinalBubble({required TranscriptSource source, required String text}) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    
    // Layer 2: Text similarity check (backup to time-based suppression)
    // More aggressive for mic source - if mic transcript matches system, always ignore it
    if (source == TranscriptSource.mic) {
      // Check against both final and draft system transcripts
      final otherSource = TranscriptSource.system;
      final now = DateTime.now();
      final checkWindow = const Duration(seconds: 8);
      final searchLimit = _bubbles.length > 15 ? _bubbles.length - 15 : 0;
      
      for (int i = _bubbles.length - 1; i >= searchLimit; i--) {
        final bubble = _bubbles[i];
        if (bubble.source != otherSource) continue;
        if (now.difference(bubble.timestamp) > checkWindow) break;
        
        final similarity = _calculateSimilarity(trimmed, bubble.text);
        // Lower threshold for mic (60%) - more aggressive duplicate detection
        if (similarity > 0.6) {
          print('[SpeechToTextProvider] Ignoring mic transcript (${(similarity * 100).toStringAsFixed(1)}% similar to system "${bubble.text}"): "$trimmed"');
          return; // Always ignore mic if it matches system
        }
      }
    }
    
    // Check if this transcript is similar to a recent transcript from the other source
    if (_isSimilarToRecentTranscript(trimmed, source)) {
      // If system comes after mic, find and remove the mic version
      final searchLimit = _bubbles.length > 15 ? _bubbles.length - 15 : 0;
      for (int i = _bubbles.length - 1; i >= searchLimit; i--) {
        if (_bubbles[i].source == TranscriptSource.mic && 
            !_bubbles[i].isDraft &&
            _calculateSimilarity(_bubbles[i].text, trimmed) > 0.6) {
          _bubbles.removeAt(i);
          print('[SpeechToTextProvider] Replacing mic transcript with system version: "$trimmed"');
          break;
        }
      }
    }

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

  Future<void> initialize({required String wsUrl, required String httpBaseUrl, String? authToken}) async {
    _transcriptionService = TranscriptionService(serverUrl: wsUrl, authToken: authToken);
    // Derive AI WS endpoint from the transcription WS endpoint (/listen -> /ai).
    String? aiWsUrl;
    try {
      var v = wsUrl.trim();
      if (v.endsWith('/listen')) {
        aiWsUrl = v.substring(0, v.length - '/listen'.length) + '/ai';
      }
    } catch (_) {}
    _aiService = AiService(httpBaseUrl: httpBaseUrl, aiWsUrl: aiWsUrl, authToken: authToken);
    
    _transcriptionService!.transcriptStream.listen(
      (result) {
        print('[SpeechToTextProvider] Received transcript - raw source: "${result.source}", text: "${result.text.substring(0, result.text.length > 50 ? 50 : result.text.length)}..."');
        final source = switch (result.source) {
          'mic' => TranscriptSource.mic,
          'system' => TranscriptSource.system,
          _ => TranscriptSource.unknown,
        };
        print('[SpeechToTextProvider] Mapped to TranscriptSource: $source');

        // Track when system final transcript is received to suppress mic echo
        if (result.isFinal && source == TranscriptSource.system) {
          final now = DateTime.now();
          _lastSystemFinalTime = now;
          _recentSystemTranscripts.add(now);
          // Clean up old entries
          _recentSystemTranscripts.removeWhere((time) => now.difference(time) > _systemActivityWindow);
          print('[SpeechToTextProvider] System final transcript received, suppressing mic audio for ${_micSuppressionWindow.inMilliseconds}ms');
        }
        

        if (result.isFinal) {
          _upsertFinalBubble(source: source, text: result.text);
        } else {
          _upsertDraftBubble(source: source, text: result.text);
        }

        notifyListeners();
      },
      onError: (error) {
        _errorMessage = error.toString();
        // If recording was active, stop it when WebSocket error occurs
        if (_isRecording) {
          print('[SpeechToTextProvider] WebSocket error during recording, stopping recording');
          // Stop recording asynchronously to avoid blocking
          Future.microtask(() async {
            try {
              await stopRecording();
            } catch (e) {
              print('[SpeechToTextProvider] Error stopping recording after WebSocket error: $e');
              // Force stop if stopRecording fails
              _isRecording = false;
              _isConnected = false;
              notifyListeners();
            }
          });
        } else {
          notifyListeners();
        }
      },
    );
  }

  void updateAuthToken(String? token) {
    _transcriptionService?.setAuthToken(token);
    _aiService?.setAuthToken(token);
  }

  List<Map<String, String>> _buildAiTurns({int maxTurns = 20}) {
    final finals = _bubbles.where((b) => !b.isDraft).toList(growable: false);
    final recent = finals.length > maxTurns ? finals.sublist(finals.length - maxTurns) : finals;

    String sourceToString(TranscriptSource s) {
      return switch (s) {
        TranscriptSource.mic => 'mic',
        TranscriptSource.system => 'system',
        TranscriptSource.unknown => 'unknown',
      };
    }

    return recent
        .where((b) => b.text.trim().isNotEmpty)
        .map((b) => {
              'source': sourceToString(b.source),
              'text': b.text.trim(),
            })
        .toList(growable: false);
  }

  String? _defaultQuestionFromLastMicTurn() {
    for (var i = _bubbles.length - 1; i >= 0; i--) {
      final b = _bubbles[i];
      if (b.isDraft) continue;
      if (b.source != TranscriptSource.mic) continue;
      final t = b.text.trim();
      if (t.isNotEmpty) return t;
    }
    return null;
  }

  Future<void> askAi({String? question}) async {
    final ai = _aiService;
    if (ai == null) {
      _aiErrorMessage = 'AI service not initialized';
      notifyListeners();
      return;
    }
    if (_isAiLoading) return;

    final trimmedQuestion = question?.trim() ?? '';
    final turns = _buildAiTurns();
    
    // If no custom question provided, try to use the last mic turn as question
    final finalQuestion = trimmedQuestion.isNotEmpty ? trimmedQuestion : _defaultQuestionFromLastMicTurn();
    
    // Require transcript only if no question is provided (neither custom nor from transcript)
    if (turns.isEmpty && finalQuestion == null) {
      _aiErrorMessage = 'No transcript yet';
      notifyListeners();
      return;
    }

    _isAiLoading = true;
    _aiErrorMessage = '';
    _aiResponse = '';
    notifyListeners();

    try {
      // If AI WS is configured, stream token deltas for a more responsive UI.
      if (ai.aiWsUrl != null) {
        await for (final delta in ai.streamRespond(
          turns: turns,
          question: finalQuestion,
          mode: 'reply',
        )) {
          _aiResponse += delta;
          notifyListeners();
        }
      } else {
        final text = await ai.respond(turns: turns, question: finalQuestion, mode: 'reply');
        _aiResponse = text;
      }
      _aiErrorMessage = '';
    } catch (e) {
      _aiErrorMessage = e.toString();
    } finally {
      _isAiLoading = false;
      notifyListeners();
    }
  }

  Future<void> startRecording({bool clearExisting = false, bool useMic = true}) async {
    try {
      print('[SpeechToTextProvider] Starting recording... (useMic: $useMic)');
      _errorMessage = '';
      _audioFrameCount = 0;
      _isSystemAudioCapturing = false;
      _useMic = useMic;
      
      // Reset suppression timestamps when starting recording
      _lastSystemFinalTime = null;
      _recentSystemTranscripts.clear();
      
      // Set recording start time IMMEDIATELY at the start
      // This ensures initial suppression is active before any audio capture begins
      _recordingStartTime = DateTime.now();
      print('[SpeechToTextProvider] Recording start time set, initial suppression will be active for ${_initialSuppressionWindow.inSeconds}s if system audio is active');
      
      // Only clear bubbles if explicitly requested (for new sessions)
      // When resuming, preserve existing bubbles
      if (clearExisting) {
        _bubbles.clear();
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
          print('[SpeechToTextProvider] System audio capture started, initial mic suppression active');
        }
        
        if (started) {
          _systemAudioPollTimer?.cancel();
          _systemAudioPollTimer = Timer.periodic(
            const Duration(milliseconds: 50),
            (_) {
              // Note: We don't suppress system audio when mic finalizes because:
              // 1. System audio is typically the original source (video calls, apps, etc.)
              // 2. Suppressing system audio causes delays in transcription
              // 3. Mic echo suppression is handled by suppressing mic audio instead
              
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

      // Only start microphone capture if useMic is true
      if (_useMic) {
        // Request permissions
        final hasPermission = await requestPermissions();
        if (!hasPermission) {
          _errorMessage = 'Microphone permission denied';
          print('[SpeechToTextProvider] Microphone permission denied');
          notifyListeners();
          return;
        }

        // Initialize audio capture
        _audioCaptureService = AudioCaptureService(
          onAudioData: (audioData) {
            // Only send mic audio if useMic is still true
            if (!_useMic) return;
            
            final now = DateTime.now();
            
            // Early meeting suppression: If system audio capture is active and recording just started,
            // suppress mic for initial period to prevent early duplicates
            if (_recordingStartTime != null && _isSystemAudioCapturing) {
              final timeSinceStart = now.difference(_recordingStartTime!);
              if (timeSinceStart < _initialSuppressionWindow) {
                if (_audioFrameCount % 50 == 0) {
                  print('[SpeechToTextProvider] Suppressing mic audio (early meeting, ${timeSinceStart.inMilliseconds}ms/${_initialSuppressionWindow.inMilliseconds}ms since start, system audio active)');
                }
                return;
              }
            }
            
            // Also suppress if we have any system transcripts but no mic transcripts yet
            // This handles the case where system audio starts before mic
            if (_bubbles.isNotEmpty && _recordingStartTime != null) {
              final hasSystemTranscripts = _bubbles.any((b) => b.source == TranscriptSource.system);
              final hasMicTranscripts = _bubbles.any((b) => b.source == TranscriptSource.mic);
              final timeSinceStart = now.difference(_recordingStartTime!);
              
              // If system has transcripts but mic doesn't, and we're in early period, suppress mic
              if (hasSystemTranscripts && !hasMicTranscripts && timeSinceStart < _initialSuppressionWindow) {
                if (_audioFrameCount % 50 == 0) {
                  print('[SpeechToTextProvider] Suppressing mic audio (system has transcripts, mic does not, early period)');
                }
                return;
              }
            }
            
            // Aggressive suppression: Suppress mic audio if system audio is active
            // This is especially important for gaming headphones where echo is delayed
            if (_isSystemAudioActive()) {
              // If system audio is actively playing, suppress mic more aggressively
              if (_lastSystemFinalTime != null) {
                final timeSinceSystemFinal = now.difference(_lastSystemFinalTime!);
                if (timeSinceSystemFinal < _micSuppressionWindow) {
                  // Skip sending mic audio - it's likely echo from system audio
                  if (_audioFrameCount % 100 == 0) {
                    print('[SpeechToTextProvider] Suppressing mic audio (system active, ${timeSinceSystemFinal.inMilliseconds}ms since system final)');
                  }
                  return;
                }
              }
            }
            
            // Standard suppression: Suppress mic audio if system just finalized a transcript
            if (_lastSystemFinalTime != null) {
              final timeSinceSystemFinal = now.difference(_lastSystemFinalTime!);
              if (timeSinceSystemFinal < _micSuppressionWindow) {
                // Skip sending mic audio - it's likely echo from system audio
                if (_audioFrameCount % 100 == 0) {
                  print('[SpeechToTextProvider] Suppressing mic audio (${timeSinceSystemFinal.inMilliseconds}ms since system final)');
                }
                return;
              }
              // Clear suppression timestamp if window has passed
              if (timeSinceSystemFinal >= _micSuppressionWindow) {
                _lastSystemFinalTime = null;
              }
            }
            
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
      } else {
        print('[SpeechToTextProvider] Microphone capture disabled');
        _audioCaptureService = null;
      }

      _isRecording = true;
      notifyListeners();
      print('[SpeechToTextProvider] Recording started${_useMic ? ' with microphone' : ' without microphone'}');
    } catch (e) {
      _errorMessage = 'Failed to start recording: $e';
      print('[SpeechToTextProvider] Error: $e');
      _isRecording = false;
      _isConnected = false;
      notifyListeners();
    }
  }

  Future<void> setUseMic(bool useMic) async {
    if (_useMic == useMic) return;
    
    _useMic = useMic;
    
    if (_isRecording) {
      if (useMic) {
        // Enable mic: request permissions and start capturing
        final hasPermission = await requestPermissions();
        if (!hasPermission) {
          _errorMessage = 'Microphone permission denied';
          _useMic = false;
          notifyListeners();
          return;
        }
        
        _audioCaptureService = AudioCaptureService(
          onAudioData: (audioData) {
            if (!_useMic) return;
            
            final now = DateTime.now();
            
            // Early meeting suppression: If system audio capture is active and recording just started,
            // suppress mic for initial period to prevent early duplicates
            if (_recordingStartTime != null && _isSystemAudioCapturing) {
              final timeSinceStart = now.difference(_recordingStartTime!);
              if (timeSinceStart < _initialSuppressionWindow) {
                if (_audioFrameCount % 50 == 0) {
                  print('[SpeechToTextProvider] Suppressing mic audio (early meeting, ${timeSinceStart.inMilliseconds}ms/${_initialSuppressionWindow.inMilliseconds}ms since start, system audio active)');
                }
                return;
              }
            }
            
            // Also suppress if we have any system transcripts but no mic transcripts yet
            // This handles the case where system audio starts before mic
            if (_bubbles.isNotEmpty && _recordingStartTime != null) {
              final hasSystemTranscripts = _bubbles.any((b) => b.source == TranscriptSource.system);
              final hasMicTranscripts = _bubbles.any((b) => b.source == TranscriptSource.mic);
              final timeSinceStart = now.difference(_recordingStartTime!);
              
              // If system has transcripts but mic doesn't, and we're in early period, suppress mic
              if (hasSystemTranscripts && !hasMicTranscripts && timeSinceStart < _initialSuppressionWindow) {
                if (_audioFrameCount % 50 == 0) {
                  print('[SpeechToTextProvider] Suppressing mic audio (system has transcripts, mic does not, early period)');
                }
                return;
              }
            }
            
            // Aggressive suppression: Suppress mic audio if system audio is active
            if (_isSystemAudioActive()) {
              if (_lastSystemFinalTime != null) {
                final timeSinceSystemFinal = now.difference(_lastSystemFinalTime!);
                if (timeSinceSystemFinal < _micSuppressionWindow) {
                  if (_audioFrameCount % 100 == 0) {
                    print('[SpeechToTextProvider] Suppressing mic audio (system active, ${timeSinceSystemFinal.inMilliseconds}ms since system final)');
                  }
                  return;
                }
              }
            }
            
            // Standard suppression: Suppress mic audio if system just finalized a transcript
            if (_lastSystemFinalTime != null) {
              final timeSinceSystemFinal = now.difference(_lastSystemFinalTime!);
              if (timeSinceSystemFinal < _micSuppressionWindow) {
                if (_audioFrameCount % 100 == 0) {
                  print('[SpeechToTextProvider] Suppressing mic audio (${timeSinceSystemFinal.inMilliseconds}ms since system final)');
                }
                return;
              }
              if (timeSinceSystemFinal >= _micSuppressionWindow) {
                _lastSystemFinalTime = null;
              }
            }
            
            _audioFrameCount++;
            if (_audioFrameCount % 10 == 0) {
              print('[SpeechToTextProvider] Audio frame #$_audioFrameCount: ${audioData.length} bytes');
            }
            _transcriptionService?.sendAudio(audioData, source: 'mic');
          },
        );
        
        final canCapture = await _audioCaptureService!.requestPermissions();
        if (!canCapture) {
          _errorMessage = 'Microphone permission denied';
          _useMic = false;
          _audioCaptureService?.dispose();
          _audioCaptureService = null;
          notifyListeners();
          return;
        }
        
        try {
          await _audioCaptureService!.startCapturing();
          print('[SpeechToTextProvider] Microphone enabled');
        } catch (e) {
          _errorMessage = 'Failed to start audio capture: $e';
          _useMic = false;
          _audioCaptureService?.dispose();
          _audioCaptureService = null;
          notifyListeners();
          return;
        }
      } else {
        // Disable mic: stop capturing
        await _audioCaptureService?.stopCapturing();
        _audioCaptureService?.dispose();
        _audioCaptureService = null;
        print('[SpeechToTextProvider] Microphone disabled');
      }
    }
    
    notifyListeners();
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
      
      // Reset suppression timestamps
      _lastSystemFinalTime = null;
      _recentSystemTranscripts.clear();
      _recordingStartTime = null;
      
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
    _aiResponse = '';
    _aiErrorMessage = '';
    notifyListeners();
  }

  void restoreBubbles(List<TranscriptBubble> bubbles) {
    _bubbles.clear();
    _bubbles.addAll(bubbles);
    notifyListeners();
  }

  @override
  void dispose() {
    _mockAudioTimer?.cancel();
    _audioCaptureService?.dispose();
    _transcriptionService?.dispose();
    _aiService?.dispose();
    super.dispose();
  }
}
