import 'package:flutter/foundation.dart';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/meeting_session.dart';
import '../models/meeting_mode.dart';
import '../models/transcript_bubble.dart';
import '../services/meeting_storage_service.dart';
import '../services/ai_service.dart';

class MeetingProvider extends ChangeNotifier {
  final MeetingStorageService _storage = MeetingStorageService();
  AiService? _aiService;
  static const String _currentSessionIdKey = 'current_meeting_session_id';

  MeetingSession? _currentSession;
  List<MeetingSession> _sessions = [];
  bool _isLoading = false;
  String _errorMessage = '';
  bool _isGeneratingSummary = false;
  bool _isGeneratingInsights = false;
  bool _isGeneratingQuestions = false;

  MeetingProvider({AiService? aiService}) : _aiService = aiService {
    _restoreCurrentSession();
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
          return;
        }
        
        // Check if we have auth token before trying to load
        if (_storage.authToken != null && _storage.authToken!.isNotEmpty) {
          final session = await _storage.loadSession(savedSessionId);
          if (session != null) {
            _currentSession = session;
            notifyListeners();
          } else {
            // Session not found, clear the saved ID
            await prefs.remove(_currentSessionIdKey);
          }
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
    final sessionId = DateTime.now().millisecondsSinceEpoch.toString();
    _currentSession = MeetingSession(
      id: sessionId,
      title: title ?? 'Meeting ${DateTime.now().toLocal().toString().substring(0, 16)}',
      createdAt: DateTime.now(),
      bubbles: [],
      modeKey: modeKey ?? 'general',
    );
    await _saveCurrentSessionId(sessionId);
    notifyListeners();
  }

  Future<void> updateCurrentSessionModeKey(String modeKey) async {
    if (_currentSession == null) return;
    
    _currentSession = _currentSession!.copyWith(
      modeKey: modeKey,
      updatedAt: DateTime.now(),
    );
    notifyListeners();
    
    // Auto-save if session has been saved before (has MongoDB ObjectId)
    if (_currentSession!.id.length == 24) {
      try {
        await _storage.saveSession(_currentSession!);
      } catch (e) {
        // Silently fail - mode will be saved on next manual save
        print('Failed to auto-save mode: $e');
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
    if (_currentSession == null) return;

    _currentSession = _currentSession!.copyWith(
      bubbles: bubbles,
      updatedAt: DateTime.now(),
    );
    notifyListeners();
    
    // Auto-save session when bubbles are updated (debounced)
    _autoSaveSession();
  }

  Timer? _autoSaveTimer;
  void _autoSaveSession() {
    // Debounce auto-save to avoid too many API calls
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(const Duration(seconds: 2), () async {
      await _saveSessionIfNeeded();
    });
  }

  Future<void> _saveSessionIfNeeded() async {
    if (_currentSession != null && _storage.authToken != null && _storage.authToken!.isNotEmpty) {
      try {
        final savedSession = await _storage.saveSession(_currentSession!);
        if (savedSession.id != null && savedSession.id != _currentSession!.id) {
          // Session ID changed (got MongoDB ObjectId), update it
          _currentSession = savedSession;
          await _saveCurrentSessionId(savedSession.id!);
          notifyListeners();
        } else {
          _currentSession = savedSession;
        }
      } catch (e) {
        // Silently fail auto-save to avoid disrupting user experience
        print('Auto-save failed: $e');
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
      final turns = bubbles.map((b) => {
        'source': b.source.toString().split('.').last,
        'text': b.text,
      }).toList();

      print('[MeetingProvider] Generating summary with ${turns.length} turns');
      print('[MeetingProvider] AiService authToken: ${_aiService != null ? (_storage.authToken != null ? "set" : "null") : "null"}');
      print('[MeetingProvider] AiService aiWsUrl: ${_aiService?.aiWsUrl}');
      
      final summary = await _aiService!.generateSummary(turns: turns);
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
    _autoSaveTimer?.cancel();
    super.dispose();
  }
}
