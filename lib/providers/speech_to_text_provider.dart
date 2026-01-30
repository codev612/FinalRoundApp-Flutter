import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';
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
  StreamSubscription? _transcriptSubscription;
  bool _isSystemAudioCapturing = false;
  bool _useMic = false;
  bool _isStopping = false; // Prevent concurrent stop operations

  // System-audio watchdog (Windows loopback can stall on device changes)
  DateTime? _lastSystemAudioFrameAt;
  bool _hadSystemAudioFramesThisRun = false;
  bool _systemAudioRestartInProgress = false;
  DateTime? _lastSystemAudioRestartAt;
  int _systemAudioRestartAttempts = 0;
  Timer? _systemAudioRecoveryTimer;
  bool _systemAudioRecoveryNotified = false;
  
  // Track when last system final transcript was received to suppress mic echo
  DateTime? _lastSystemFinalTime;
  DateTime? _lastSystemTranscriptTime;
  // Increased window for gaming headphones (echo can be delayed)
  static const _micSuppressionWindow = Duration(milliseconds: 3000);
  
  // Track recent system transcripts to detect if system audio is actively playing
  final List<DateTime> _recentSystemTranscripts = [];
  static const _systemActivityWindow = Duration(seconds: 10);
  
  // Track when recording started to suppress mic initially (prevent early duplicates)
  DateTime? _recordingStartTime;
  static const _initialSuppressionWindow = Duration(seconds: 3); // Suppress mic for first 3 seconds when system audio is active

  // Pricing: estimate "transcription used" time based on transcript activity,
  // not wall-clock recording time. Long silence gaps won't consume minutes.
  static const Duration _usageGapCap = Duration(seconds: 2);
  int _transcriptionUsageMsThisRun = 0;
  DateTime? _lastTranscriptUsageAt;
  
  bool _isRecording = false;
  bool _isConnected = false;
  bool _isDisposed = false;
  final List<TranscriptBubble> _bubbles = <TranscriptBubble>[];
  String _errorMessage = '';
  int _audioFrameCount = 0;
  
  // Resource optimization: Limit bubbles in memory to prevent excessive memory usage
  // Older bubbles are already saved to the session, so we can safely limit memory
  static const int _maxBubblesInMemory = 2000; // Keep last 2000 bubbles in memory

  String _aiResponse = '';
  String _aiErrorMessage = '';
  bool _isAiLoading = false;
  
  // Auto ask callback - called when a question is detected from others
  Function(String)? _onQuestionDetected;

  bool get isRecording => _isRecording;
  
  void setAutoAskCallback(Function(String)? callback) {
    _onQuestionDetected = callback;
  }
  bool get isConnected => _isConnected;
  bool get isStopping => _isStopping;
  bool get useMic => _useMic;
  int get transcriptionUsageMsThisRun => _transcriptionUsageMsThisRun;
  void _trackTranscriptionUsageEvent() {
    if (!_isRecording || _isStopping || _isDisposed) return;
    final now = DateTime.now();
    final prev = _lastTranscriptUsageAt;
    if (prev == null) {
      // Count a small minimum chunk for the first transcript event.
      _transcriptionUsageMsThisRun += 1000;
    } else {
      final delta = now.difference(prev);
      final capped = delta > _usageGapCap ? _usageGapCap : delta;
      final ms = capped.inMilliseconds;
      if (ms > 0) _transcriptionUsageMsThisRun += ms;
    }
    _lastTranscriptUsageAt = now;
  }

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

  bool _isQuestion(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    
    // Check if text ends with question mark
    if (trimmed.endsWith('?')) return true;
    
    // Check for common question patterns
    final questionPatterns = [
      RegExp(r'^(what|who|where|when|why|how|which|whose|whom)\s', caseSensitive: false),
      RegExp(r'\?$'),
      RegExp(r'^(can|could|would|should|will|do|does|did|is|are|was|were|have|has|had)\s', caseSensitive: false),
    ];
    
    for (final pattern in questionPatterns) {
      if (pattern.hasMatch(trimmed)) {
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
        final finalText = trimmed;
        _bubbles[_bubbles.length - 1] = _bubbles.last.copyWith(
          text: finalText,
          isDraft: false,
          timestamp: DateTime.now(),
        );
        // Check if finalized text is a question from system source (others asking)
        if (source == TranscriptSource.system && 
            _onQuestionDetected != null && 
            _isQuestion(finalText) &&
            !_isAiLoading) {
          print('[SpeechToTextProvider] Question detected in finalized draft: "$finalText" - triggering auto ask');
          Future.microtask(() {
            if (!_isDisposed && _onQuestionDetected != null) {
              _onQuestionDetected!('What should I say?');
            }
          });
        }
        return;
      }

      final merged = _appendWithOverlap(_bubbles.last.text, trimmed);
      final previousText = _bubbles.last.text;
      _bubbles[_bubbles.length - 1] = _bubbles.last.copyWith(text: merged);
      
      // Check if merged text is a question from system source (others asking)
      // Only trigger if question wasn't already in the previous text
      if (source == TranscriptSource.system && 
          _onQuestionDetected != null && 
          _isQuestion(merged) &&
          !_isAiLoading &&
          !_isQuestion(previousText)) {
        print('[SpeechToTextProvider] Question detected in merged text: "$merged" - triggering auto ask');
        Future.microtask(() {
          if (!_isDisposed && _onQuestionDetected != null) {
            _onQuestionDetected!('What should I say?');
          }
        });
      }
      return;
    }

    // New bubble - check if it's a question from system source
    final newBubble = TranscriptBubble(
      source: source,
      text: trimmed,
      timestamp: DateTime.now(),
      isDraft: false,
    );
    _bubbles.add(newBubble);
    
    // Resource optimization: Limit bubbles in memory to prevent excessive memory usage
    // Older bubbles are already saved to the session, so we can safely limit memory
    if (_bubbles.length > _maxBubblesInMemory) {
      // Remove oldest bubbles (keep most recent)
      final toRemove = _bubbles.length - _maxBubblesInMemory;
      _bubbles.removeRange(0, toRemove);
      print('[SpeechToTextProvider] Trimmed bubble history: removed $toRemove old bubbles (keeping last $_maxBubblesInMemory)');
    }
    
    // Check if new bubble is a question from system source (others asking)
    if (source == TranscriptSource.system && 
        _onQuestionDetected != null && 
        _isQuestion(trimmed) &&
        !_isAiLoading) {
      print('[SpeechToTextProvider] Question detected in new bubble: "$trimmed" - triggering auto ask');
      Future.microtask(() {
        if (!_isDisposed && _onQuestionDetected != null) {
          _onQuestionDetected!('What should I say?');
        }
      });
    }
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
    
    // Cancel any existing subscription first
    _transcriptSubscription?.cancel();
    _transcriptSubscription = _transcriptionService!.transcriptStream.listen(
      (result) {
        // Check if recording is still active before processing
        if (!_isRecording) {
          return;
        }

        // Count "transcription used" time based on transcript activity.
        _trackTranscriptionUsageEvent();
        
        final source = switch (result.source) {
          'mic' => TranscriptSource.mic,
          'system' => TranscriptSource.system,
          _ => TranscriptSource.unknown,
        };

        // Track when system final transcript is received to suppress mic echo
        if (result.isFinal && source == TranscriptSource.system) {
          final now = DateTime.now();
          _lastSystemFinalTime = now;
          _recentSystemTranscripts.add(now);
          // Clean up old entries
          _recentSystemTranscripts.removeWhere((time) => now.difference(time) > _systemActivityWindow);
        }
        
        // Double-check recording state before processing
        if (!_isRecording) {
          return;
        }

        if (result.isFinal) {
          _upsertFinalBubble(source: source, text: result.text);
        } else {
          _upsertDraftBubble(source: source, text: result.text);
        }

        // Only notify if still recording
        if (_isRecording) {
          notifyListeners();
        }
      },
      onError: (error) {
        // Only process errors if recording is active
        if (!_isRecording) {
          return;
        }
        
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
              if (!_isDisposed) {
                notifyListeners();
              }
            }
          });
        } else {
          if (!_isDisposed) {
            notifyListeners();
          }
        }
      },
    );
  }

  void updateAuthToken(String? token) {
    _transcriptionService?.setAuthToken(token);
    _aiService?.setAuthToken(token);
  }

  List<Map<String, String>> _buildAiTurns({int maxTurns = 50}) {
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

  Future<void> askAi({String? question, String? systemPrompt, String? model, Uint8List? imagePngBytes}) async {
    final ai = _aiService;
    if (ai == null) {
      _aiErrorMessage = 'AI service not initialized';
      notifyListeners();
      return;
    }
    if (_isAiLoading) return;

    final trimmedQuestion = question?.trim() ?? '';
    final turns = _buildAiTurns();
    final hasImage = imagePngBytes != null && imagePngBytes.isNotEmpty;
    
    // If no custom question provided, try to use the last mic turn as question
    String? finalQuestion = trimmedQuestion.isNotEmpty ? trimmedQuestion : _defaultQuestionFromLastMicTurn();

    // If user wants to ask with a screenshot but there is no mic question yet,
    // provide a sensible default question.
    if (finalQuestion == null && hasImage) {
      finalQuestion = 'Analyze the attached screenshot and the conversation so far. Tell me what I should say next. Be concise.';
    }
    
    // Require transcript only if no question is provided (neither custom nor from transcript)
    if (turns.isEmpty && finalQuestion == null && !hasImage) {
      _aiErrorMessage = 'No transcript yet';
      notifyListeners();
      return;
    }

    // If a screenshot is attached, explicitly tell the model to use it as context.
    final questionToSend = (hasImage && finalQuestion != null && finalQuestion.trim().isNotEmpty)
        ? 'Screenshot attached.\n\n$finalQuestion'
        : finalQuestion;

    _isAiLoading = true;
    _aiErrorMessage = '';
    _aiResponse = '';
    notifyListeners();

    try {
      // For image requests, prefer HTTP (payload can be large).
      // If AI WS is configured, stream token deltas for a more responsive UI.
      if (ai.aiWsUrl != null && !hasImage) {
        await for (final delta in ai.streamRespond(
          turns: turns,
          question: questionToSend,
          mode: 'reply',
          systemPrompt: systemPrompt,
          model: model,
        )) {
          _aiResponse += delta;
          notifyListeners();
        }
      } else {
        final text = await ai.respond(
          turns: turns,
          question: questionToSend,
          mode: 'reply',
          systemPrompt: systemPrompt,
          model: model,
          imagePngBytes: imagePngBytes,
        );
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

  String _friendlyMicError(Object e) {
    if (e is PlatformException) {
      final msg = (e.message ?? '').toLowerCase();
      if (msg.contains('no audio recording device')) {
        return 'No microphone was found. Reconnect your headset/mic, or uncheck “Use mic” to continue with system audio only.';
      }
      if (msg.contains('not found')) {
        return 'Microphone device not found. Reconnect your headset/mic and try again.';
      }
    }
    final text = e.toString();
    // Avoid showing raw PlatformException noise when possible.
    if (text.contains('PlatformException')) {
      return 'Microphone error. Try reconnecting your headset/mic, then restart mic.';
    }
    return 'Microphone error: $text';
  }

  Future<void> startRecording({bool clearExisting = false, bool useMic = true}) async {
    try {
      print('[SpeechToTextProvider] Starting recording... (useMic: $useMic)');
      _errorMessage = '';
      _audioFrameCount = 0;
      _isSystemAudioCapturing = false;
      _useMic = useMic;

      // Reset system-audio watchdog
      _lastSystemAudioFrameAt = null;
      _hadSystemAudioFramesThisRun = false;
      _systemAudioRestartInProgress = false;
      _lastSystemAudioRestartAt = null;
      _systemAudioRestartAttempts = 0;
      _systemAudioRecoveryTimer?.cancel();
      _systemAudioRecoveryTimer = null;
      _systemAudioRecoveryNotified = false;

      // Reset per-run usage accounting (used for billing countdown)
      _transcriptionUsageMsThisRun = 0;
      _lastTranscriptUsageAt = null;
      
      // Reset suppression timestamps when starting recording
      _lastSystemFinalTime = null;
      _lastSystemTranscriptTime = null;
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

      // Mark recording active early so system-audio polling can work even if mic fails to start.
      _isRecording = true;
      if (!_isDisposed) {
        notifyListeners();
      }
      
      // Re-establish transcript stream subscription
      // This is needed when resuming a meeting after stopping (subscription was cancelled)
      _transcriptSubscription?.cancel();
      _transcriptSubscription = _transcriptionService!.transcriptStream.listen(
          (result) {
            // Check if recording is still active and not stopping before processing
            if (!_isRecording || _isStopping || _isDisposed) {
              return;
            }

            // Count "transcription used" time based on transcript activity.
            _trackTranscriptionUsageEvent();
            
            final source = switch (result.source) {
              'mic' => TranscriptSource.mic,
              'system' => TranscriptSource.system,
              _ => TranscriptSource.unknown,
            };

            // Track system transcript timing (interim + final) to suppress mic echo.
            if (source == TranscriptSource.system) {
              final now = DateTime.now();
              _lastSystemTranscriptTime = now;
              _recentSystemTranscripts.add(now);
              _recentSystemTranscripts.removeWhere((time) => now.difference(time) > _systemActivityWindow);
              if (result.isFinal) {
                _lastSystemFinalTime = now;
              }
            }
            
            // Double-check recording state before processing
            if (!_isRecording || _isStopping || _isDisposed) {
              return;
            }

            if (result.isFinal) {
              _upsertFinalBubble(source: source, text: result.text);
            } else {
              _upsertDraftBubble(source: source, text: result.text);
            }

            // Only notify if still recording and not stopping
            if (_isRecording && !_isStopping && !_isDisposed) {
              try {
                notifyListeners();
              } catch (e) {
                print('[SpeechToTextProvider] Error in notifyListeners (transcript): $e');
              }
            }
          },
          onError: (error) {
            // Only process errors if recording is active and not stopping
            if (!_isRecording || _isStopping || _isDisposed) {
              return;
            }
            
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
                  if (!_isDisposed) {
                    notifyListeners();
                  }
                }
              });
            } else {
              if (!_isDisposed) {
                notifyListeners();
              }
            }
          },
        );
      print('[SpeechToTextProvider] Transcript stream subscription re-established');

      // Start system audio capture on Windows (best-effort).
      if (!kIsWeb && Platform.isWindows) {
        final started = await _startSystemAudioCaptureAndPolling();
        if (!started) {
          // Don't fail the meeting; just keep retrying in the background.
          _ensureSystemAudioRecoveryTimer();
        }
      }

      // Only start microphone capture if useMic is true
      if (_useMic) {
        // Request permissions
        final hasPermission = await requestPermissions();
        if (!hasPermission) {
          _errorMessage = 'Microphone permission denied. Uncheck “Use mic” to continue.';
          _useMic = false;
          if (!_isDisposed) notifyListeners();
          // Continue recording (system audio may still work)
        } else {
          // Initialize audio capture
          _audioCaptureService = AudioCaptureService(
            onAudioData: (audioData) {
              // Only send mic audio if useMic is still true, recording is active, and not stopping
              if (!_useMic || !_isRecording || _isStopping) return;
              
              final now = DateTime.now();
              
              // Early meeting suppression: If system audio capture is active and recording just started,
              // suppress mic for initial period to prevent early duplicates
              if (_recordingStartTime != null && _isSystemAudioCapturing) {
                final timeSinceStart = now.difference(_recordingStartTime!);
                if (timeSinceStart < _initialSuppressionWindow) {
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
                  return;
                }
              }
              
              // Aggressive suppression: Suppress mic audio if system audio is active
              // This is especially important for gaming headphones where echo is delayed
              if (_isSystemAudioActive()) {
                // If system audio is actively playing, suppress mic more aggressively
                final lastSystem = _lastSystemTranscriptTime ?? _lastSystemFinalTime;
                if (lastSystem != null) {
                  final timeSinceSystem = now.difference(lastSystem);
                  if (timeSinceSystem < _micSuppressionWindow) {
                    return;
                  }
                }
              }
              
              // Standard suppression: Suppress mic audio if system just finalized a transcript
              if (_lastSystemFinalTime != null) {
                final timeSinceSystemFinal = now.difference(_lastSystemFinalTime!);
                if (timeSinceSystemFinal < _micSuppressionWindow) {
                  // Skip sending mic audio - it's likely echo from system audio
                  return;
                }
                // Clear suppression timestamp if window has passed
                if (timeSinceSystemFinal >= _micSuppressionWindow) {
                  _lastSystemFinalTime = null;
                }
              }
              
              _audioFrameCount++;
              // Final check before sending - must not be stopping
              if (!_isStopping && _transcriptionService != null) {
                try {
                  _transcriptionService?.sendAudio(audioData, source: 'mic');
                } catch (e) {
                  print('[SpeechToTextProvider] Error sending mic audio: $e');
                }
              }
            },
          );

          // Request microphone permission and start capturing
          final canCapture = await _audioCaptureService!.requestPermissions();
          if (!canCapture) {
            _errorMessage = 'Microphone permission denied. Uncheck “Use mic” to continue.';
            _useMic = false;
            _audioCaptureService?.dispose();
            _audioCaptureService = null;
            if (!_isDisposed) notifyListeners();
          } else {
            // Start audio capturing
            try {
              await _audioCaptureService!.startCapturing();
              if (_audioCaptureService!.selectedDeviceNotFound) {
                final used = _audioCaptureService!.lastUsedDeviceLabel ?? 'default device';
                _errorMessage =
                    'Mic was disconnected/reconnected. Using "$used". Go to Settings → Audio to reselect your microphone.';
                if (!_isDisposed) notifyListeners();
              }
            } catch (e) {
              _errorMessage = _friendlyMicError(e);
              _useMic = false;
              try {
                await _audioCaptureService?.stopCapturing();
              } catch (_) {}
              _audioCaptureService?.dispose();
              _audioCaptureService = null;
              if (!_isDisposed) notifyListeners();
              // Continue recording (system audio may still work)
            }
          }
        }
      } else {
        _audioCaptureService = null;
      }

      // If neither system audio nor mic is available, stop cleanly.
      if (!_isSystemAudioCapturing && !_useMic) {
        _errorMessage = 'No audio source available (no mic and system audio capture unavailable).';
        _isRecording = false;
        _isConnected = false;
        try {
          _systemAudioPollTimer?.cancel();
          _systemAudioPollTimer = null;
        } catch (_) {}
        _transcriptionService?.disconnect();
        if (!_isDisposed) notifyListeners();
        return;
      }

      print('[SpeechToTextProvider] Recording started${_useMic ? ' with microphone' : ' without microphone'}');
    } catch (e) {
      _errorMessage = 'Failed to start recording: $e';
      print('[SpeechToTextProvider] Error: $e');
      _isRecording = false;
      _isConnected = false;
      notifyListeners();
    }
  }

  Future<bool> _startSystemAudioCaptureAndPolling() async {
    if (kIsWeb || !Platform.isWindows) return false;
    try {
      final started = await WindowsAudioService.startSystemAudioCapture().timeout(const Duration(seconds: 4));
      _isSystemAudioCapturing = started;
      if (!started) return false;

      // Successful start: clear recovery flags
      _systemAudioRestartAttempts = 0;
      _systemAudioRecoveryNotified = false;
      _systemAudioRecoveryTimer?.cancel();
      _systemAudioRecoveryTimer = null;

      // IMPORTANT: poll at real-time (~50ms chunks at 20Hz)
      _systemAudioPollTimer?.cancel();
      const pollInterval = Duration(milliseconds: 50);
      _systemAudioPollTimer = Timer.periodic(
        pollInterval,
        (_) {
          if (!_isRecording || _isStopping || _transcriptionService == null) return;
          if (!_isSystemAudioCapturing) return;

          WindowsAudioService.getSystemAudioFrame(lengthBytes: 1600).then((frame) {
            if (!_isRecording || _isStopping || _transcriptionService == null) return;
            final now = DateTime.now();
            if (frame.isEmpty) {
              _maybeRestartSystemAudioCapture(now: now);
              return;
            }
            _lastSystemAudioFrameAt = now;
            _hadSystemAudioFramesThisRun = true;
            try {
              _transcriptionService?.sendAudio(frame, source: 'system');
            } catch (e) {
              print('[SpeechToTextProvider] Error sending system audio: $e');
            }
          }).catchError((error) {
            print('[SpeechToTextProvider] Error getting system audio frame: $error');
            _maybeRestartSystemAudioCapture(now: DateTime.now());
          });
        },
      );
      return true;
    } catch (_) {
      _isSystemAudioCapturing = false;
      return false;
    }
  }

  Future<void> _stopSystemAudioCaptureAndPolling() async {
    try {
      _systemAudioPollTimer?.cancel();
      _systemAudioPollTimer = null;
    } catch (_) {}
    if (!kIsWeb && Platform.isWindows && _isSystemAudioCapturing) {
      try {
        await WindowsAudioService.stopSystemAudioCapture().timeout(const Duration(seconds: 4));
      } catch (_) {}
    }
    _isSystemAudioCapturing = false;
  }

  void _ensureSystemAudioRecoveryTimer() {
    if (kIsWeb || !Platform.isWindows) return;
    if (_systemAudioRecoveryTimer != null) return;

    if (!_systemAudioRecoveryNotified) {
      _systemAudioRecoveryNotified = true;
      _errorMessage = 'System audio device changed. Reconnecting…';
      if (!_isDisposed) notifyListeners();
    }

    _systemAudioRecoveryTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (_isDisposed || !_isRecording || _isStopping) {
        _systemAudioRecoveryTimer?.cancel();
        _systemAudioRecoveryTimer = null;
        return;
      }
      if (_isSystemAudioCapturing) {
        _systemAudioRecoveryTimer?.cancel();
        _systemAudioRecoveryTimer = null;
        return;
      }
      final ok = await _startSystemAudioCaptureAndPolling();
      if (ok) {
        // Clear the temporary message once recovered.
        if (_errorMessage.startsWith('System audio device changed')) {
          _errorMessage = '';
        }
        if (!_isDisposed) notifyListeners();
      }
    });
  }

  void _maybeRestartSystemAudioCapture({required DateTime now}) {
    if (_systemAudioRestartInProgress) return;
    if (!_isRecording || _isStopping) return;
    if (!Platform.isWindows) return;
    if (!_isSystemAudioCapturing) return;

    // Backoff + cap attempts (avoid thrashing during silence)
    if (_systemAudioRestartAttempts >= 3) return;
    if (_lastSystemAudioRestartAt != null && now.difference(_lastSystemAudioRestartAt!) < const Duration(seconds: 6)) {
      return;
    }

    // Only restart if we previously had frames (common "stuck after device change" case),
    // OR if we've been recording for a while and still never got any system frames.
    final lastFrameAt = _lastSystemAudioFrameAt;
    final timeSinceStart = _recordingStartTime == null ? null : now.difference(_recordingStartTime!);

    final shouldRestart =
        (_hadSystemAudioFramesThisRun && lastFrameAt != null && now.difference(lastFrameAt) > const Duration(seconds: 2)) ||
        (!_hadSystemAudioFramesThisRun && timeSinceStart != null && timeSinceStart > const Duration(seconds: 12));

    if (!shouldRestart) return;

    _systemAudioRestartInProgress = true;
    _lastSystemAudioRestartAt = now;
    _systemAudioRestartAttempts++;

    Future.microtask(() async {
      try {
        // Stop + restart loopback capture to pick up the new default output device.
        await _stopSystemAudioCaptureAndPolling();
        if (!_isRecording || _isStopping) return;
        await Future.delayed(const Duration(milliseconds: 200));
        final restarted = await _startSystemAudioCaptureAndPolling();
        if (!restarted) {
          // Enter recovery mode: keep retrying in the background.
          _ensureSystemAudioRecoveryTimer();
        } else {
          if (_errorMessage.startsWith('System audio device changed')) {
            _errorMessage = '';
          }
          if (!_isDisposed) notifyListeners();
        }
      } catch (_) {
        // Ignore; we'll retry with backoff if still recording.
        _ensureSystemAudioRecoveryTimer();
      } finally {
        _systemAudioRestartInProgress = false;
      }
    });
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
            // Only send mic audio if useMic is still true, recording is active, and not stopping
            if (!_useMic || !_isRecording || _isStopping) return;
            
            final now = DateTime.now();
            
            // Early meeting suppression: If system audio capture is active and recording just started,
            // suppress mic for initial period to prevent early duplicates
            if (_recordingStartTime != null && _isSystemAudioCapturing) {
              final timeSinceStart = now.difference(_recordingStartTime!);
              if (timeSinceStart < _initialSuppressionWindow) {
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
                return;
              }
            }
            
            // Aggressive suppression: Suppress mic audio if system audio is active
            if (_isSystemAudioActive()) {
              final lastSystem = _lastSystemTranscriptTime ?? _lastSystemFinalTime;
              if (lastSystem != null) {
                final timeSinceSystem = now.difference(lastSystem);
                if (timeSinceSystem < _micSuppressionWindow) {
                  return;
                }
              }
            }
            
            // Standard suppression: Suppress mic audio if system just finalized a transcript
            if (_lastSystemFinalTime != null) {
              final timeSinceSystemFinal = now.difference(_lastSystemFinalTime!);
              if (timeSinceSystemFinal < _micSuppressionWindow) {
                return;
              }
              if (timeSinceSystemFinal >= _micSuppressionWindow) {
                _lastSystemFinalTime = null;
              }
            }
            
            _audioFrameCount++;
            // Final check before sending - must not be stopping
            if (!_isStopping && _isRecording && _transcriptionService != null) {
              try {
                _transcriptionService?.sendAudio(audioData, source: 'mic');
              } catch (e) {
                print('[SpeechToTextProvider] Error sending mic audio: $e');
              }
            }
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
          if (_audioCaptureService!.selectedDeviceNotFound) {
            final used = _audioCaptureService!.lastUsedDeviceLabel ?? 'default device';
            _errorMessage =
                'Mic was disconnected/reconnected. Using "$used". Go to Settings → Audio to reselect your microphone.';
            notifyListeners();
          }
        } catch (e) {
          _errorMessage = _friendlyMicError(e);
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
    // Prevent concurrent stop operations
    if (_isStopping) {
      print('[SpeechToTextProvider] Stop already in progress, ignoring duplicate call');
      return;
    }
    
    _isStopping = true;
    try {
      print('[SpeechToTextProvider] Stopping recording...');
      
      // STEP 1: Set all flags to stop callbacks FIRST
      _isRecording = false;
      _isConnected = false;
      
      // STEP 2: Cancel ALL timers immediately to stop periodic callbacks
      try {
        _mockAudioTimer?.cancel();
        _mockAudioTimer = null;
      } catch (e) {
        print('[SpeechToTextProvider] Error canceling mock audio timer: $e');
      }

      // Cancel system audio poll timer - this is critical to stop getSystemAudioFrame calls
      try {
        _systemAudioPollTimer?.cancel();
        _systemAudioPollTimer = null;
      } catch (e) {
        print('[SpeechToTextProvider] Error canceling system audio poll timer: $e');
      }
      try {
        _systemAudioRecoveryTimer?.cancel();
        _systemAudioRecoveryTimer = null;
      } catch (_) {}
      
      // STEP 3: Cancel transcript subscription to stop processing incoming messages
      try {
        _transcriptSubscription?.cancel();
        _transcriptSubscription = null;
      } catch (e) {
        print('[SpeechToTextProvider] Error canceling transcript subscription: $e');
      }
      
      // STEP 4: Reset state immediately
      _lastSystemFinalTime = null;
      _lastSystemTranscriptTime = null;
      _recentSystemTranscripts.clear();
      _recordingStartTime = null;
      _lastTranscriptUsageAt = null;
      
      // Notify listeners IMMEDIATELY so UI updates right away (button changes to resume/start)
      if (!_isDisposed) {
        try {
          notifyListeners();
        } catch (e) {
          print('[SpeechToTextProvider] Error in notifyListeners (immediate): $e');
        }
      }
      
      print('[SpeechToTextProvider] Recording stopped. Processed $_audioFrameCount audio frames');
      
      // STEP 5: Do cleanup in background (non-blocking)
      // This allows UI to remain responsive while cleanup happens
      Future.microtask(() async {
        try {
          // Stop audio capture services (mic first, then system)
          try {
            await _audioCaptureService?.stopCapturing().timeout(const Duration(seconds: 4));
          } catch (e) {
            print('[SpeechToTextProvider] Error stopping audio capture: $e');
          }
          
          // Stop system audio capture (native Windows service)
          if (!kIsWeb && Platform.isWindows && _isSystemAudioCapturing) {
            try {
              await WindowsAudioService.stopSystemAudioCapture().timeout(const Duration(seconds: 4));
            } catch (e) {
              print('[SpeechToTextProvider] Error stopping system audio capture: $e');
            }
          }
          _isSystemAudioCapturing = false;
          _lastSystemTranscriptTime = null;
          
          // Dispose audio capture service
          try {
            _audioCaptureService?.dispose();
          } catch (e) {
            print('[SpeechToTextProvider] Error disposing audio capture service: $e');
          }
          _audioCaptureService = null;
          
          // Disconnect from transcription service (WebSocket)
          // Do this last after all audio is stopped
          try {
            _transcriptionService?.disconnect();
          } catch (e) {
            print('[SpeechToTextProvider] Error disconnecting transcription service: $e');
          }
        } catch (e) {
          print('[SpeechToTextProvider] Error in background cleanup: $e');
        } finally {
          // Reset stopping flag after cleanup completes
          _isStopping = false;
          // Notify listeners one more time to update UI (remove loading state)
          if (!_isDisposed) {
            try {
              notifyListeners();
            } catch (e) {
              print('[SpeechToTextProvider] Error in notifyListeners (after cleanup): $e');
            }
          }
        }
      });
    } catch (e, stackTrace) {
      _errorMessage = 'Failed to stop recording: $e';
      print('[SpeechToTextProvider] Error stopping: $e');
      print('[SpeechToTextProvider] Stack trace: $stackTrace');
      // Ensure state is reset even on error
      _isRecording = false;
      _isConnected = false;
      
      // Still do cleanup even on error
      Future.microtask(() async {
        try {
          // Try to clean up as much as possible
          try {
            await _audioCaptureService?.stopCapturing().timeout(const Duration(seconds: 4));
          } catch (_) {}
          try {
            _audioCaptureService?.dispose();
          } catch (_) {}
          _audioCaptureService = null;
          if (!kIsWeb && Platform.isWindows && _isSystemAudioCapturing) {
            try {
              await WindowsAudioService.stopSystemAudioCapture().timeout(const Duration(seconds: 4));
            } catch (_) {}
          }
          _isSystemAudioCapturing = false;
          _lastSystemTranscriptTime = null;
          try {
            _transcriptionService?.disconnect();
          } catch (_) {}
        } finally {
          _isStopping = false;
          if (!_isDisposed) {
            try {
              notifyListeners();
            } catch (_) {}
          }
        }
      });
      
      if (!_isDisposed) {
        try {
          // Notify immediately about the error state
          notifyListeners();
        } catch (notifyError) {
          print('[SpeechToTextProvider] Error in notifyListeners (error handler): $notifyError');
        }
      }
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
    // Resource optimization: Only restore recent bubbles to limit memory usage
    // If restoring a very long session, keep only the most recent bubbles
    if (bubbles.length > _maxBubblesInMemory) {
      _bubbles.addAll(bubbles.sublist(bubbles.length - _maxBubblesInMemory));
      print('[SpeechToTextProvider] Restored only last $_maxBubblesInMemory bubbles from ${bubbles.length} total bubbles');
    } else {
      _bubbles.addAll(bubbles);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    _mockAudioTimer?.cancel();
    _systemAudioPollTimer?.cancel();
    _systemAudioRecoveryTimer?.cancel();
    _transcriptSubscription?.cancel();
    _audioCaptureService?.dispose();
    _transcriptionService?.dispose();
    _aiService?.dispose();
    super.dispose();
  }
}
