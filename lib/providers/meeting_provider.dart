import 'package:flutter/foundation.dart';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/meeting_session.dart';
import '../models/meeting_mode.dart';
import '../models/transcript_bubble.dart';
import '../services/meeting_storage_service.dart';
import '../services/ai_service.dart';
import '../services/meeting_mode_service.dart';

class MeetingProvider extends ChangeNotifier {
  final MeetingStorageService _storage = MeetingStorageService();
  AiService? _aiService;
  static const String _currentSessionIdKey = 'current_meeting_session_id';
  static const String _lastSelectedModeKey = 'last_selected_meeting_mode';

  MeetingSession? _currentSession;
  List<MeetingSession> _sessions = [];
  bool _isLoading = false;
  String _errorMessage = '';
  bool _isGeneratingSummary = false;
  bool _isGeneratingInsights = false;
  bool _isGeneratingQuestions = false;
  bool _isDisposed = false;

  MeetingProvider({AiService? aiService}) : _aiService = aiService {
    _restoreCurrentSession();
    // Also check and log saved mode preference on initialization
    _logSavedModePreference();
  }
  
  Future<void> _logSavedModePreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedMode = prefs.getString(_lastSelectedModeKey);
      if (savedMode != null && savedMode.isNotEmpty) {
        print('[MeetingProvider] Initialization: Found saved mode preference: $savedMode');
      } else {
        print('[MeetingProvider] Initialization: No saved mode preference found');
      }
    } catch (e) {
      print('[MeetingProvider] Error checking saved mode preference: $e');
    }
  }

  void setAiService(AiService? aiService) {
    _aiService = aiService;
  }

  void updateAuthToken(String? token) {
    _aiService?.setAuthToken(token);
    _storage.setAuthToken(token);
    // If we have a token and no current session, try to restore
    if (token != null && token.isNotEmpty && _currentSession == null) {
      _restoreCurrentSession();
    }
  }

  // Set auth tokens without triggering session restoration
  void setAuthTokensOnly(String? token) {
    print('[MeetingProvider] setAuthTokensOnly called with token: ${token != null ? "set" : "null"}');
    _aiService?.setAuthToken(token);
    _storage.setAuthToken(token);
    print('[MeetingProvider] Auth token set on AiService');
  }

  Future<void> ensureSessionRestored() async {
    if (_currentSession == null && _storage.authToken != null && _storage.authToken!.isNotEmpty) {
      await _restoreCurrentSession();
    }
  }

  Future<void> _restoreCurrentSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedSessionId = prefs.getString(_currentSessionIdKey);
      
      if (savedSessionId != null && savedSessionId.isNotEmpty) {
        // Check if saved ID is a MongoDB ObjectId (24 hex chars) - only restore saved sessions, not new timestamp IDs
        final isMongoObjectId = RegExp(r'^[0-9a-fA-F]{24}$').hasMatch(savedSessionId);
        if (!isMongoObjectId) {
          // It's a timestamp ID (new session), don't try to restore it
          // But still try to restore the mode preference if available
          final savedMode = prefs.getString(_lastSelectedModeKey);
          if (savedMode != null && savedMode.isNotEmpty) {
            print('[MeetingProvider] Found saved mode preference: $savedMode (session not restored, but mode preference exists)');
          }
          return;
        }
        
        // Check if we have auth token before trying to load
        if (_storage.authToken != null && _storage.authToken!.isNotEmpty) {
          final session = await _storage.loadSession(savedSessionId);
          if (session != null) {
            _currentSession = session;
            
            // Save the mode from restored session as the last selected mode
            if (session.modeKey != null && session.modeKey.isNotEmpty) {
              await prefs.setString(_lastSelectedModeKey, session.modeKey);
              print('[MeetingProvider] Restored session mode: ${session.modeKey}');
            }
            
            notifyListeners();
          } else {
            // Session not found, clear the saved ID
            await prefs.remove(_currentSessionIdKey);
          }
        } else {
          // No auth token yet, but we can still check for saved mode preference
          final savedMode = prefs.getString(_lastSelectedModeKey);
          if (savedMode != null && savedMode.isNotEmpty) {
            print('[MeetingProvider] Found saved mode preference: $savedMode (waiting for auth token)');
          }
        }
      } else {
        // No saved session ID, but check for saved mode preference
        final savedMode = prefs.getString(_lastSelectedModeKey);
        if (savedMode != null && savedMode.isNotEmpty) {
          print('[MeetingProvider] Found saved mode preference: $savedMode (no saved session)');
        }
      }
    } catch (e) {
      print('Error restoring current session: $e');
    }
  }

  Future<void> _saveCurrentSessionId(String? sessionId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (sessionId != null && sessionId.isNotEmpty) {
        await prefs.setString(_currentSessionIdKey, sessionId);
      } else {
        await prefs.remove(_currentSessionIdKey);
      }
    } catch (e) {
      print('Error saving current session ID: $e');
    }
  }

  MeetingSession? get currentSession => _currentSession;
  List<MeetingSession> get sessions => List.unmodifiable(_sessions);
  bool get isLoading => _isLoading;
  String get errorMessage => _errorMessage;
  bool get isGeneratingSummary => _isGeneratingSummary;
  bool get isGeneratingInsights => _isGeneratingInsights;
  bool get isGeneratingQuestions => _isGeneratingQuestions;
  List<Map<String, dynamic>> get markers {
    final meta = _currentSession?.metadata ?? const <String, dynamic>{};
    final raw = meta['markers'];
    if (raw is List) {
      return raw.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList(growable: false);
    }
    return const <Map<String, dynamic>>[];
  }

  Future<void> loadSessions() async {
    _isLoading = true;
    _errorMessage = '';
    notifyListeners();

    try {
      _sessions = await _storage.listSessions();
    } catch (e) {
      _errorMessage = 'Failed to load sessions: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> createNewSession({String? title, String? modeKey}) async {
    // If no modeKey provided, use the last selected mode, or default to 'general'
    String finalModeKey = modeKey ?? 'general';
    if (modeKey == null) {
      final prefs = await SharedPreferences.getInstance();
      final lastMode = prefs.getString(_lastSelectedModeKey);
      if (lastMode != null && lastMode.isNotEmpty) {
        finalModeKey = lastMode;
        print('[MeetingProvider] createNewSession: Using last selected mode: $finalModeKey');
      } else {
        print('[MeetingProvider] createNewSession: No saved mode found, using default: general');
      }
    } else {
      print('[MeetingProvider] createNewSession: Using provided mode: $modeKey');
    }
    
    final sessionId = DateTime.now().millisecondsSinceEpoch.toString();
    _currentSession = MeetingSession(
      id: sessionId,
      title: title ?? 'Meeting ${DateTime.now().toLocal().toString().substring(0, 16)}',
      createdAt: DateTime.now(),
      bubbles: [],
      modeKey: finalModeKey,
    );
    await _saveCurrentSessionId(sessionId);
    notifyListeners();
  }

  Future<void> updateCurrentSessionModeKey(String modeKey) async {
    // Save the selected mode to persist it for future sessions (even if no current session)
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastSelectedModeKey, modeKey);
    print('[MeetingProvider] updateCurrentSessionModeKey: Saved mode preference: $modeKey');
    
    if (_currentSession == null) {
      print('[MeetingProvider] updateCurrentSessionModeKey: No current session, but mode preference saved');
      return;
    }
    
    _currentSession = _currentSession!.copyWith(
      modeKey: modeKey,
      updatedAt: DateTime.now(),
    );
    notifyListeners();
    
    // Auto-save if session has been saved before (has MongoDB ObjectId)
    if (_currentSession!.id.length == 24) {
      try {
        await _storage.saveSession(_currentSession!);
        print('[MeetingProvider] updateCurrentSessionModeKey: Auto-saved session with mode: $modeKey');
      } catch (e) {
        // Silently fail - mode will be saved on next manual save
        print('[MeetingProvider] Failed to auto-save mode: $e');
      }
    }
  }

  Future<void> saveCurrentSession({String? title}) async {
    if (_currentSession == null) return;

    try {
      _isLoading = true;
      _errorMessage = '';
      notifyListeners();

      final updated = _currentSession!.copyWith(
        title: title ?? _currentSession!.title,
        updatedAt: DateTime.now(),
      );
      // Save session and get the updated session with server-generated ID
      final savedSession = await _storage.saveSession(updated);
      _currentSession = savedSession;
      // Save the session ID (now with MongoDB ObjectId)
      if (savedSession.id != null) {
        await _saveCurrentSessionId(savedSession.id!);
      }
      await loadSessions();
    } catch (e) {
      _errorMessage = 'Failed to save session: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> loadSession(String sessionId) async {
    // Validate session ID
    if (sessionId.isEmpty) {
      _errorMessage = 'Invalid session ID';
      return;
    }
    
    try {
      _isLoading = true;
      _errorMessage = '';
      notifyListeners();

      final session = await _storage.loadSession(sessionId);
      if (session != null) {
        _currentSession = session;
        await _saveCurrentSessionId(sessionId);
        
        // Save the mode from loaded session as the last selected mode
        if (session.modeKey != null && session.modeKey.isNotEmpty) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_lastSelectedModeKey, session.modeKey);
          print('[MeetingProvider] Saved mode from loaded session: ${session.modeKey}');
        }
      } else {
        _errorMessage = 'Session not found';
      }
    } catch (e) {
      print('[MeetingProvider] Error in loadSession: $e');
      _errorMessage = 'Failed to load session: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> deleteSession(String sessionId) async {
    try {
      _isLoading = true;
      _errorMessage = '';
      notifyListeners();

      await _storage.deleteSession(sessionId);
      if (_currentSession?.id == sessionId) {
        _currentSession = null;
      }
      await loadSessions();
    } catch (e) {
      _errorMessage = 'Failed to delete session: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  void updateCurrentSessionBubbles(List<TranscriptBubble> bubbles) {
    if (_currentSession == null || _isDisposed) return;

    try {
      _currentSession = _currentSession!.copyWith(
        bubbles: bubbles,
        updatedAt: DateTime.now(),
      );
      if (!_isDisposed) {
        try {
          notifyListeners();
        } catch (e) {
          print('[MeetingProvider] Error in notifyListeners: $e');
        }
      }
      
      // Auto-save session when bubbles are updated (debounced)
      // Only if not disposed to avoid crashes during cleanup
      if (!_isDisposed) {
        try {
          _autoSaveSession();
        } catch (e) {
          print('[MeetingProvider] Error scheduling auto-save: $e');
        }
      }
    } catch (e) {
      print('[MeetingProvider] Error updating session bubbles: $e');
      // Don't rethrow - just log the error to prevent crashes
    }
  }

  Timer? _autoSaveTimer;
  bool _isSaving = false; // Track if save is in progress
  
  void _autoSaveSession() {
    // Don't schedule new saves if disposed or already saving
    if (_isDisposed || _isSaving) return;
    
    // Debounce auto-save to avoid too many API calls
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(const Duration(seconds: 2), () async {
      if (!_isDisposed && !_isSaving) {
        await _saveSessionIfNeeded();
      }
    });
  }

  Future<void> _saveSessionIfNeeded() async {
    // Prevent concurrent saves
    if (_isSaving || _isDisposed) return;
    
    if (_currentSession != null && _storage.authToken != null && _storage.authToken!.isNotEmpty) {
      _isSaving = true;
      try {
        final savedSession = await _storage.saveSession(_currentSession!);
        
        // Check if still valid after async operation
        if (_isDisposed) return;
        
        if (savedSession.id != null && savedSession.id != _currentSession!.id) {
          // Session ID changed (got MongoDB ObjectId), update it
          _currentSession = savedSession;
          await _saveCurrentSessionId(savedSession.id!);
          if (!_isDisposed) {
            try {
              notifyListeners();
            } catch (e) {
              print('[MeetingProvider] Error in notifyListeners (after save): $e');
            }
          }
        } else {
          _currentSession = savedSession;
        }
      } catch (e) {
        // Silently fail auto-save to avoid disrupting user experience
        print('[MeetingProvider] Auto-save failed: $e');
      } finally {
        _isSaving = false;
      }
    }
  }

  void addMarker(Map<String, dynamic> marker) {
    if (_currentSession == null) return;

    final meta = Map<String, dynamic>.from(_currentSession!.metadata);
    final existing = meta['markers'];
    final list = <Map<String, dynamic>>[];
    if (existing is List) {
      for (final item in existing) {
        if (item is Map) {
          list.add(Map<String, dynamic>.from(item));
        }
      }
    }
    list.add(Map<String, dynamic>.from(marker));
    meta['markers'] = list;

    _currentSession = _currentSession!.copyWith(
      metadata: meta,
      updatedAt: DateTime.now(),
    );
    notifyListeners();
  }

  Future<void> generateSummary({bool regenerate = false}) async {
    if (_currentSession == null || _aiService == null) return;
    if (_isGeneratingSummary) return;
    
    // If summary already exists and not regenerating, return early
    if (!regenerate && _currentSession!.summary != null && _currentSession!.summary!.isNotEmpty) {
      print('[MeetingProvider] Summary already exists, skipping generation');
      return;
    }
    
    // Ensure auth token is set before generating
    if (_storage.authToken != null && _storage.authToken!.isNotEmpty) {
      _aiService?.setAuthToken(_storage.authToken);
    }

    final bubbles = _currentSession!.bubbles.where((b) => !b.isDraft).toList();
    if (bubbles.isEmpty) {
      _errorMessage = 'No transcript to summarize';
      notifyListeners();
      return;
    }

    _isGeneratingSummary = true;
    _errorMessage = '';
    notifyListeners();

    try {
      final allTurns = bubbles.map((b) => {
        'source': b.source.toString().split('.').last,
        'text': b.text,
      }).toList();

      // Get notes template from current mode
      String? notesTemplate;
      final modeKey = _currentSession!.modeKey;
      if (modeKey != null && modeKey.isNotEmpty) {
        final modeService = MeetingModeService();
        modeService.setAuthToken(_storage.authToken);
        final config = await modeService.getConfigForModeKey(modeKey);
        notesTemplate = config.notesTemplate;
        print('[MeetingProvider] Retrieved notes template for mode: $modeKey');
        print('[MeetingProvider] Notes template length: ${notesTemplate?.length ?? 0}');
        if (notesTemplate != null && notesTemplate.isNotEmpty) {
          print('[MeetingProvider] Notes template preview: ${notesTemplate.substring(0, notesTemplate.length > 200 ? 200 : notesTemplate.length)}...');
        }
      } else {
        print('[MeetingProvider] No modeKey found in session, skipping notes template');
      }

      print('[MeetingProvider] Generating summary with ${allTurns.length} turns');
      print('[MeetingProvider] Using notes template: ${notesTemplate != null && notesTemplate.isNotEmpty ? "yes (${notesTemplate.length} chars)" : "no"}');
      print('[MeetingProvider] AiService authToken: ${_aiService != null ? (_storage.authToken != null ? "set" : "null") : "null"}');
      print('[MeetingProvider] AiService aiWsUrl: ${_aiService?.aiWsUrl}');
      
      String summary;
      // If more than 50 turns, summarize in chunks and then combine
      if (allTurns.length > 50) {
        print('[MeetingProvider] Too many turns (${allTurns.length}), using chunked summarization');
        final chunkSize = 50;
        final chunks = <List<Map<String, String>>>[];
        
        // Split into chunks of 50
        for (int i = 0; i < allTurns.length; i += chunkSize) {
          final end = (i + chunkSize < allTurns.length) ? i + chunkSize : allTurns.length;
          chunks.add(allTurns.sublist(i, end));
        }
        
        // Summarize each chunk
        final chunkSummaries = <String>[];
        for (int i = 0; i < chunks.length; i++) {
          print('[MeetingProvider] Summarizing chunk ${i + 1}/${chunks.length} (${chunks[i].length} turns)');
          final chunkSummary = await _aiService!.generateSummary(
            turns: chunks[i], 
            notesTemplate: notesTemplate,
          );
          chunkSummaries.add(chunkSummary);
        }
        
        // Combine chunk summaries into final summary
        if (chunkSummaries.length == 1) {
          summary = chunkSummaries.first;
        } else {
          // Create a combined summary by summarizing the chunk summaries
          final combinedTurns = chunkSummaries.asMap().entries.map((e) => {
            'source': 'summary',
            'text': 'Chunk ${e.key + 1} Summary:\n${e.value}',
          }).toList();
          
          print('[MeetingProvider] Combining ${chunkSummaries.length} chunk summaries');
          summary = await _aiService!.generateSummary(
            turns: combinedTurns, 
            notesTemplate: notesTemplate,
          );
        }
      } else {
        // Use all turns directly if 50 or fewer
        summary = await _aiService!.generateSummary(turns: allTurns, notesTemplate: notesTemplate);
      }
      
      print('[MeetingProvider] Summary generated: ${summary.length} characters');
      _currentSession = _currentSession!.copyWith(
        summary: summary,
        updatedAt: DateTime.now(),
      );
      // Auto-save session with summary
      await _saveSessionIfNeeded();
    } catch (e, stackTrace) {
      print('[MeetingProvider] Error generating summary: $e');
      print('[MeetingProvider] Stack trace: $stackTrace');
      _errorMessage = 'Failed to generate summary: $e';
    } finally {
      _isGeneratingSummary = false;
      notifyListeners();
    }
  }

  Future<void> generateInsights({bool regenerate = false}) async {
    if (_currentSession == null || _aiService == null) return;
    if (_isGeneratingInsights) return;
    
    // If insights already exist and not regenerating, return early
    if (!regenerate && _currentSession!.insights != null && _currentSession!.insights!.isNotEmpty) {
      print('[MeetingProvider] Insights already exist, skipping generation');
      return;
    }
    
    // Ensure auth token is set before generating
    if (_storage.authToken != null && _storage.authToken!.isNotEmpty) {
      _aiService?.setAuthToken(_storage.authToken);
    }

    final bubbles = _currentSession!.bubbles.where((b) => !b.isDraft).toList();
    if (bubbles.isEmpty) {
      _errorMessage = 'No transcript to analyze';
      notifyListeners();
      return;
    }

    _isGeneratingInsights = true;
    _errorMessage = '';
    notifyListeners();

    try {
      final turns = bubbles.map((b) => {
        'source': b.source.toString().split('.').last,
        'text': b.text,
      }).toList();

      print('[MeetingProvider] Generating insights with ${turns.length} turns');
      final insights = await _aiService!.generateInsights(turns: turns);
      print('[MeetingProvider] Insights generated: ${insights.length} characters');
      _currentSession = _currentSession!.copyWith(
        insights: insights,
        updatedAt: DateTime.now(),
      );
      // Auto-save session with insights
      await _saveSessionIfNeeded();
    } catch (e, stackTrace) {
      print('[MeetingProvider] Error generating insights: $e');
      print('[MeetingProvider] Stack trace: $stackTrace');
      _errorMessage = 'Failed to generate insights: $e';
    } finally {
      _isGeneratingInsights = false;
      notifyListeners();
    }
  }

  Future<String> generateQuestions({bool regenerate = false}) async {
    if (_currentSession == null || _aiService == null) {
      return '';
    }
    if (_isGeneratingQuestions) return _currentSession!.questions ?? '';
    
    // If questions already exist and not regenerating, return existing questions
    if (!regenerate && _currentSession!.questions != null && _currentSession!.questions!.isNotEmpty) {
      print('[MeetingProvider] Questions already exist, returning existing questions');
      return _currentSession!.questions!;
    }
    
    // Ensure auth token is set before generating
    if (_storage.authToken != null && _storage.authToken!.isNotEmpty) {
      _aiService?.setAuthToken(_storage.authToken);
    }

    final bubbles = _currentSession!.bubbles.where((b) => !b.isDraft).toList();
    if (bubbles.isEmpty) {
      return '';
    }

    _isGeneratingQuestions = true;
    _errorMessage = '';
    notifyListeners();

    try {
      final turns = bubbles.map((b) => {
        'source': b.source.toString().split('.').last,
        'text': b.text,
      }).toList();

      print('[MeetingProvider] Generating questions with ${turns.length} turns');
      final questions = await _aiService!.generateQuestions(turns: turns);
      print('[MeetingProvider] Questions generated: ${questions.length} characters');
      
      // Save questions to session
      _currentSession = _currentSession!.copyWith(
        questions: questions,
        updatedAt: DateTime.now(),
      );
      // Auto-save session with questions
      await _saveSessionIfNeeded();
      
      _isGeneratingQuestions = false;
      notifyListeners();
      return questions;
    } catch (e, stackTrace) {
      print('[MeetingProvider] Error generating questions: $e');
      print('[MeetingProvider] Stack trace: $stackTrace');
      _errorMessage = 'Failed to generate questions: $e';
      _isGeneratingQuestions = false;
      notifyListeners();
      return '';
    }
  }

  Future<String> exportSessionAsText(String sessionId) async {
    try {
      final session = await _storage.loadSession(sessionId);
      if (session == null) {
        throw Exception('Session not found');
      }
      return await _storage.exportSessionAsText(session);
    } catch (e) {
      throw Exception('Failed to export session: $e');
    }
  }

  Future<void> clearCurrentSession() async {
    _currentSession = null;
    _autoSaveTimer?.cancel();
    await _saveCurrentSessionId(null);
    notifyListeners();
  }

  bool get hasNewSession {
    // Check if current session is a new one (timestamp ID, not MongoDB ObjectId)
    if (_currentSession == null) return false;
    final id = _currentSession!.id;
    if (id == null) return false;
    // MongoDB ObjectId is 24 hex characters, timestamp IDs are numeric strings
    return !RegExp(r'^[0-9a-fA-F]{24}$').hasMatch(id);
  }

  @override
  void dispose() {
    _isDisposed = true;
    _autoSaveTimer?.cancel();
    super.dispose();
  }
}
