import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'dart:async';
import '../config/app_config.dart';
import '../providers/speech_to_text_provider.dart';
import '../providers/meeting_provider.dart';
import '../providers/auth_provider.dart';
import '../models/meeting_session.dart';
import '../models/meeting_mode.dart';
import '../models/transcript_bubble.dart';
import '../services/meeting_question_service.dart';
import '../services/meeting_mode_service.dart';
import '../services/ai_service.dart';
import '../providers/shortcuts_provider.dart';
import 'manage_mode_page.dart';
import 'manage_question_templates_page.dart';

class MeetingPageEnhanced extends StatefulWidget {
  const MeetingPageEnhanced({super.key});

  @override
  State<MeetingPageEnhanced> createState() => _MeetingPageEnhancedState();
}

class _MeetingPageEnhancedState extends State<MeetingPageEnhanced> {
  final ScrollController _transcriptScrollController = ScrollController();
  final TextEditingController _askAiController = TextEditingController();
  final TextEditingController _aiResponseController = TextEditingController();
  int _lastBubbleCount = 0;
  String _lastTailSignature = '';
  String _suggestedQuestions = '';
  bool _showQuestionSuggestions = false;
  List<String> _cachedQuestions = [];
  bool _showSummary = false;
  bool _showInsights = false;
  SpeechToTextProvider? _speechProvider;
  MeetingProvider? _meetingProvider;
  Timer? _recordingTimer;
  DateTime? _recordingStartedAt;
  bool _showMarkers = true;
  bool _useMic = false;
  bool _autoAsk = false;
  bool _showConversationControls = true;
  bool _showAiControls = true;
  bool _showConversationPanel = true;
  bool _showAiPanel = true;
  bool _isUpdatingBubbles = false; // Flag to prevent infinite loops
  MeetingModeService? _modeService;
  Future<List<ModeDisplay>>? _modeDisplaysFuture;
  VoidCallback? _modesVersionListener;
  MeetingQuestionService? _questionService;

  @override
  void initState() {
    super.initState();
    _modesVersionListener = () {
      if (mounted && _modeService != null) {
        setState(() {
          _modeDisplaysFuture = _modeService!.getCustomOnlyModeDisplays();
        });
      }
    };
    MeetingModeService.customModesVersion.addListener(_modesVersionListener!);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final authProvider = context.read<AuthProvider>();
      _speechProvider = context.read<SpeechToTextProvider>();
      _meetingProvider = context.read<MeetingProvider>();
      
      final authToken = authProvider.token;
      _questionService = MeetingQuestionService()..setAuthToken(authToken);
      _speechProvider!.initialize(
        wsUrl: AppConfig.serverWebSocketUrl,
        httpBaseUrl: AppConfig.serverHttpBaseUrl,
        authToken: authToken,
      );
      
      // Update AI service with auth token (but don't restore session here - we'll handle it below)
      _meetingProvider!.setAuthTokensOnly(authToken);
      _questionService?.setAuthToken(authToken);

      // Check if we should restore session or start fresh
      final currentSession = _meetingProvider!.currentSession;
      
      if (currentSession != null) {
        // We have a current session
        // Check if it's a new session (timestamp ID) - if so, clear bubbles and don't restore anything
        final isNewSession = _meetingProvider!.hasNewSession;
        if (isNewSession) {
          // It's a new session - clear any existing bubbles to start fresh
          _speechProvider!.clearTranscript();
          // Reset recording start time for new session
          _recordingStartedAt = null;
        } else if (currentSession.bubbles.isNotEmpty) {
          // Session has bubbles and is a saved session - restore them (user clicked a saved session)
          _speechProvider!.restoreBubbles(currentSession.bubbles);
          // Initialize recording start time from session (first bubble or createdAt)
          _recordingStartedAt = currentSession.bubbles.isNotEmpty 
              ? currentSession.bubbles.first.timestamp 
              : currentSession.createdAt;
        } else {
          // Session exists but is empty (saved session with no bubbles) - clear bubbles
          _speechProvider!.clearTranscript();
          // Reset recording start time
          _recordingStartedAt = null;
        }
      } else {
        // No current session - try to restore last session, or create new
        await _meetingProvider!.ensureSessionRestored();
        final restoredSession = _meetingProvider!.currentSession;
        if (restoredSession != null && restoredSession.bubbles.isNotEmpty) {
          _speechProvider!.restoreBubbles(restoredSession.bubbles);
          // Initialize recording start time from restored session
          _recordingStartedAt = restoredSession.bubbles.isNotEmpty 
              ? restoredSession.bubbles.first.timestamp 
              : restoredSession.createdAt;
        } else if (_meetingProvider!.currentSession == null) {
          // Create new session if none exists
          await _meetingProvider!.createNewSession();
          // Clear bubbles for new session
          _speechProvider!.clearTranscript();
          // Reset recording start time for new session
          _recordingStartedAt = null;
        }
      }

      // Sync bubbles to meeting session
      _speechProvider!.addListener(_syncBubblesToSession);
      
      // Set up auto ask callback
      _updateAutoAskCallback();
      
      // Load question templates
      _loadQuestionTemplates();
      
      // Reload questions when returning to this page (e.g., from settings)
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // This will be called when the page becomes visible again
      });
      
      // Listen for session changes to restore bubbles when session is loaded
      _meetingProvider!.addListener(_onSessionChanged);
    });
  }

  void _syncBubblesToSession() {
    // Prevent infinite loop - don't sync if we're already updating bubbles
    if (_isUpdatingBubbles) return;
    if (!mounted) return;
    if (_meetingProvider?.currentSession == null || _speechProvider == null) return;
    
    try {
      // Only update if bubbles actually changed
      final currentBubbles = _speechProvider!.bubbles;
      final sessionBubbles = _meetingProvider!.currentSession!.bubbles;
      
      // More comprehensive comparison: check length, and if lengths match, check content
      bool hasChanged = false;
      if (currentBubbles.length != sessionBubbles.length) {
        hasChanged = true;
      } else if (currentBubbles.isNotEmpty && sessionBubbles.isNotEmpty) {
        // Compare all bubbles to detect any changes
        for (int i = 0; i < currentBubbles.length; i++) {
          if (i >= sessionBubbles.length ||
              currentBubbles[i].text != sessionBubbles[i].text ||
              currentBubbles[i].isDraft != sessionBubbles[i].isDraft ||
              currentBubbles[i].source != sessionBubbles[i].source) {
            hasChanged = true;
            break;
          }
        }
      } else if (currentBubbles.isEmpty != sessionBubbles.isEmpty) {
        // One is empty, the other is not
        hasChanged = true;
      }
      
      if (hasChanged && mounted && _meetingProvider?.currentSession != null) {
        _meetingProvider!.updateCurrentSessionBubbles(currentBubbles);
      }
    } catch (e) {
      debugPrint('Error in _syncBubblesToSession: $e');
      // Don't rethrow - just log to prevent crashes
    }
  }

  void _onSessionChanged() {
    // Prevent infinite loop - don't process if we're already updating bubbles
    if (_isUpdatingBubbles) return;
    if (!mounted) return;
    
    // When session changes (e.g., loaded from home page), restore or clear bubbles
    final currentSession = _meetingProvider?.currentSession;
    if (currentSession != null && _speechProvider != null) {
      _isUpdatingBubbles = true;
      try {
        if (!mounted) return;
        // Don't restore if it's a new session (timestamp ID) - only restore saved sessions
        final isNewSession = _meetingProvider?.hasNewSession ?? false;
        if (isNewSession) {
          // It's a new session, clear bubbles
          if (mounted && _speechProvider != null) {
            _speechProvider!.clearTranscript();
            // Reset recording start time for new session
            _recordingStartedAt = null;
          }
          return;
        }
        
        if (!mounted) return;
        // It's a saved session
        if (currentSession.bubbles.isNotEmpty) {
          // Session has bubbles - restore them if speech provider bubbles are empty or different
          if (_speechProvider!.bubbles.isEmpty || 
              _speechProvider!.bubbles.length != currentSession.bubbles.length) {
            if (mounted && _speechProvider != null) {
              _speechProvider!.restoreBubbles(currentSession.bubbles);
              // Initialize recording start time from session
              _recordingStartedAt = currentSession.bubbles.isNotEmpty 
                  ? currentSession.bubbles.first.timestamp 
                  : currentSession.createdAt;
            }
          }
        } else {
          // Session has no bubbles - clear any existing bubbles
          if (mounted && _speechProvider != null) {
            _speechProvider!.clearTranscript();
            // Reset recording start time
            _recordingStartedAt = null;
          }
        }
      } finally {
        _isUpdatingBubbles = false;
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reload questions when route becomes active (e.g., returning from settings)
    _loadQuestionTemplates();
  }

  @override
  void dispose() {
    final listener = _modesVersionListener;
    if (listener != null) {
      MeetingModeService.customModesVersion.removeListener(listener);
    }
    _recordingTimer?.cancel();
    _transcriptScrollController.dispose();
    _askAiController.dispose();
    _aiResponseController.dispose();
    _speechProvider?.removeListener(_syncBubblesToSession);
    _meetingProvider?.removeListener(_onSessionChanged);
    super.dispose();
  }

  /// Calculate the recording start time from the current session or bubbles
  DateTime? _calculateRecordingStartTime() {
    final currentSession = _meetingProvider?.currentSession;
    final bubbles = _speechProvider?.bubbles ?? [];
    
    // If we have bubbles, use the first bubble's timestamp
    if (bubbles.isNotEmpty) {
      return bubbles.first.timestamp;
    }
    
    // Otherwise, use the session's createdAt time
    if (currentSession != null) {
      return currentSession.createdAt;
    }
    
    // Fallback to null (will use current time if recording starts fresh)
    return null;
  }

  void _ensureRecordingClock(SpeechToTextProvider speechProvider) {
    if (speechProvider.isRecording) {
      // If recording started time is not set, calculate it from session/bubbles
      // This ensures that when resuming a session, we continue from where we left off
      _recordingStartedAt ??= _calculateRecordingStartTime() ?? DateTime.now();
      _recordingTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() {});
      });
    } else {
      // Stop the timer when recording stops
      // Don't reset _recordingStartedAt here - keep it so if recording resumes,
      // it continues from the same start time
      _recordingTimer?.cancel();
      _recordingTimer = null;
    }
  }

  String _formatDuration(Duration d) {
    final mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final hh = d.inHours;
    if (hh > 0) {
      return '${hh.toString().padLeft(2, '0')}:$mm:$ss';
    }
    return '$mm:$ss';
  }

  String _formatWallTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  Future<void> _copyLastOtherSide() async {
    final bubbles = context.read<SpeechToTextProvider>().bubbles;
    for (var i = bubbles.length - 1; i >= 0; i--) {
      final b = bubbles[i];
      if (b.isDraft) continue;
      if (b.source != TranscriptSource.system) continue;
      final t = b.text.trim();
      if (t.isEmpty) continue;
      await Clipboard.setData(ClipboardData(text: t));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Copied last other-side turn')),
      );
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('No other-side turn found yet')),
    );
  }

  TranscriptBubble? _lastFinalBubble({TranscriptSource? source}) {
    final bubbles = context.read<SpeechToTextProvider>().bubbles;
    for (var i = bubbles.length - 1; i >= 0; i--) {
      final b = bubbles[i];
      if (b.isDraft) continue;
      if (source != null && b.source != source) continue;
      final t = b.text.trim();
      if (t.isEmpty) continue;
      return b;
    }
    return null;
  }

  Future<void> _markMoment() async {
    final meetingProvider = context.read<MeetingProvider>();
    
    // Ensure a session exists
    if (meetingProvider.currentSession == null) {
      await meetingProvider.createNewSession();
    }
    
    final now = DateTime.now();
    final elapsed = _recordingStartedAt == null ? null : now.difference(_recordingStartedAt!);

    // Prefer the other-side (system) last turn, otherwise fall back to last mic.
    final last = _lastFinalBubble(source: TranscriptSource.system) ??
        _lastFinalBubble(source: TranscriptSource.mic) ??
        _lastFinalBubble();

    final defaultText = (last?.text.trim() ?? '');
    final source = (last?.source == null) ? '' : last!.source.toString().split('.').last;

    final note = await showDialog<String>(
      context: context,
      builder: (context) {
        final controller = TextEditingController(text: '');
        return AlertDialog(
          title: const Text('Mark moment'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (defaultText.isNotEmpty) ...[
                Text(
                  defaultText.length > 180 ? '${defaultText.substring(0, 180)}…' : defaultText,
                  style: const TextStyle(color: Colors.black54),
                ),
                const SizedBox(height: 10),
              ],
              TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Quick note (optional)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, null),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Save marker'),
            ),
          ],
        );
      },
    );

    if (!mounted) return;
    if (note == null) return;

    meetingProvider.addMarker({
      'id': now.millisecondsSinceEpoch.toString(),
      'at': elapsed == null ? _formatWallTime(now) : _formatDuration(elapsed),
      'wallTime': now.toIso8601String(),
      'source': source,
      'text': defaultText,
      'label': note,
    });

    setState(() => _showMarkers = true);
    
    // Show snackbar with option to view markers
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Marked moment'),
        action: SnackBarAction(
          label: 'View all',
          onPressed: () => _showMarkersDialog(meetingProvider),
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> _showTextDialog({
    required String title,
    required String text,
  }) async {
    final t = text.trim();
    if (t.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$title is empty')),
      );
      return;
    }

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 720,
          child: SingleChildScrollView(
            child: SelectableText(t),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: t));
              if (!context.mounted) return;
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Copied to clipboard')),
              );
            },
            child: const Text('Copy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _showManageModeDialog(BuildContext context, MeetingProvider meetingProvider) async {
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const ManageModePage(),
      ),
    );
  }

  Future<void> _showMarkersDialog(MeetingProvider meetingProvider) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Markers (${meetingProvider.markers.length})'),
        content: SizedBox(
          width: 720,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 420),
            child: meetingProvider.markers.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.bookmarks_outlined,
                          size: 48,
                          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'No markers yet',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Click the bookmark icon in the conversation control bar (or press Ctrl+M) to mark important moments during your meeting.',
                          style: Theme.of(context).textTheme.bodyMedium,
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: meetingProvider.markers.length,
                    separatorBuilder: (_, __) => const Divider(height: 12),
                    itemBuilder: (context, index) {
                      final m = meetingProvider.markers[index];
                      final at = (m['at']?.toString() ?? '').trim();
                      final label = (m['label']?.toString() ?? '').trim();
                      final text = (m['text']?.toString() ?? '').trim();
                      final source = (m['source']?.toString() ?? '').trim();
                      final display = [
                        if (at.isNotEmpty) at,
                        if (source.isNotEmpty) '[$source]',
                        if (label.isNotEmpty) label,
                      ].join(' ');
                      return ListTile(
                        title: Text(display.isEmpty ? 'Marker' : display),
                        subtitle: text.isEmpty ? null : Text(text),
                        onTap: () async {
                          final clip = [
                            if (at.isNotEmpty) at,
                            if (source.isNotEmpty) '[$source]',
                            if (label.isNotEmpty) label,
                            if (text.isNotEmpty) '\n$text',
                          ].join(' ');
                          await Clipboard.setData(ClipboardData(text: clip.trim()));
                          if (!context.mounted) return;
                          Navigator.pop(context);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Marker copied')),
                          );
                        },
                      );
                    },
                  ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _maybeAutoScroll(SpeechToTextProvider provider) {
    final bubbleCount = provider.bubbles.length;
    final tail = provider.bubbles.isNotEmpty ? provider.bubbles.last : null;
    final tailSignature = tail == null
        ? ''
        : '${tail.source}:${tail.isDraft}:${tail.text.length}:${tail.timestamp.millisecondsSinceEpoch}';

    final changed = bubbleCount != _lastBubbleCount || tailSignature != _lastTailSignature;
    _lastBubbleCount = bubbleCount;
    _lastTailSignature = tailSignature;

    if (!changed) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_transcriptScrollController.hasClients) return;

      final position = _transcriptScrollController.position;
      final target = position.maxScrollExtent;
      if ((target - position.pixels).abs() < 4) return;
      _transcriptScrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  Widget _buildBubble({
    required TranscriptSource source,
    required String text,
    required DateTime timestamp,
    DateTime? meetingStartTime,
  }) {
    final isMe = source == TranscriptSource.mic;
    // Make bubbles more transparent - use black background with low opacity for better readability
    final backgroundColor = isMe 
        ? Colors.blue.shade600.withValues(alpha: 0.3) 
        : Colors.grey.shade800.withValues(alpha: 0.3);
    final textColor = isMe ? Colors.white : Colors.white;
    
    // Calculate relative time from meeting start
    String timeDisplay;
    if (meetingStartTime != null) {
      final duration = timestamp.difference(meetingStartTime);
      timeDisplay = _formatDuration(duration);
    } else {
      // Fallback to wall time if no meeting start time available
      timeDisplay = _formatWallTime(timestamp);
    }

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: IntrinsicWidth(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minWidth: 80,
            maxWidth: 520,
          ),
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 6),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: backgroundColor,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isMe 
                    ? Colors.blue.shade400.withValues(alpha: 0.5) 
                    : Colors.grey.shade400.withValues(alpha: 0.5),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  text,
                  style: TextStyle(
                    fontSize: 16,
                    color: textColor,
                    fontStyle: FontStyle.normal,
                    shadows: [
                      Shadow(
                        color: Colors.black.withValues(alpha: 0.9),
                        blurRadius: 5,
                        offset: const Offset(1, 1),
                      ),
                      Shadow(
                        color: Colors.black.withValues(alpha: 0.9),
                        blurRadius: 5,
                        offset: const Offset(-1, -1),
                      ),
                      Shadow(
                        color: Colors.black.withValues(alpha: 0.9),
                        blurRadius: 5,
                        offset: const Offset(1, -1),
                      ),
                      Shadow(
                        color: Colors.black.withValues(alpha: 0.9),
                        blurRadius: 5,
                        offset: const Offset(-1, 1),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Align(
                  alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                  child: Text(
                    timeDisplay,
                    style: TextStyle(
                      fontSize: 11,
                      color: textColor.withValues(alpha: 0.7),
                      shadows: [
                        Shadow(
                          color: Colors.black.withValues(alpha: 0.9),
                          blurRadius: 3,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<String?> _getRealTimePrompt() async {
    if (_meetingProvider?.currentSession == null) return null;
    final modeKey = _meetingProvider!.currentSession!.modeKey;
    try {
      final config = await MeetingModeService().getConfigForModeKey(modeKey);
      return config.realTimePrompt;
    } catch (e) {
      print('Failed to get real-time prompt: $e');
      return null;
    }
  }

  Future<void> _askAiWithPrompt(String? question) async {
    if (_speechProvider == null || _speechProvider!.isAiLoading) return;
    final systemPrompt = await _getRealTimePrompt();
    _speechProvider!.askAi(question: question, systemPrompt: systemPrompt);
  }
  
  void _updateAutoAskCallback() {
    if (_speechProvider == null) return;
    if (_autoAsk) {
      // Set callback to auto-ask when question is detected
      _speechProvider!.setAutoAskCallback((question) {
        if (mounted && !_speechProvider!.isAiLoading) {
          _askAiWithPrompt(question);
        }
      });
    } else {
      // Remove callback when auto ask is disabled
      _speechProvider!.setAutoAskCallback(null);
    }
  }

  void _askQuestionFromTemplate(String question) {
    if (_speechProvider != null && !_speechProvider!.isAiLoading) {
      _askAiWithPrompt(question);
    }
  }

  Future<void> _loadQuestionTemplates() async {
    if (_questionService == null) return;
    final questions = await _questionService!.getAllQuestions();
    if (mounted) {
      setState(() {
        _cachedQuestions = questions;
      });
    }
  }

  Future<List<PopupMenuEntry<String>>> _buildQuestionMenuItemsAsync() async {
    // Reload questions when menu is opened
    await _loadQuestionTemplates();
    return _cachedQuestions.map((question) {
      return PopupMenuItem<String>(
        value: question,
        child: Text(question),
      );
    }).toList();
  }

  List<PopupMenuEntry<String>> _buildQuestionMenuItems() {
    return _cachedQuestions.map((question) {
      return PopupMenuItem<String>(
        value: question,
        child: Text(question),
      );
    }).toList();
  }

  Future<void> _generateSuggestedQuestions({bool regenerate = false}) async {
    final meetingProvider = context.read<MeetingProvider>();
    final session = meetingProvider.currentSession;
    
    // If questions exist and not regenerating, use existing
    if (!regenerate && session?.questions != null && session!.questions!.isNotEmpty) {
      if (mounted) {
        setState(() {
          _suggestedQuestions = session.questions!;
          _showQuestionSuggestions = true;
        });
      }
      return;
    }
    
    // Generate questions
    final questions = await meetingProvider.generateQuestions(regenerate: regenerate);
    if (questions.isNotEmpty && mounted) {
      setState(() {
        _suggestedQuestions = questions;
        _showQuestionSuggestions = true;
      });
    }
  }

  Future<void> _saveSession() async {
    if (!mounted) return;
    try {
      final meetingProvider = context.read<MeetingProvider>();
      final currentSession = meetingProvider.currentSession;
      final currentTitle = currentSession?.title ?? '';
      
      final titleController = TextEditingController(text: currentTitle);
      
      final title = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Save Session'),
          content: TextField(
            controller: titleController,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Session Name',
              hintText: 'Enter session name',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(titleController.text.trim()),
              child: const Text('Save'),
            ),
          ],
        ),
      );
      
      if (title == null) return; // User cancelled
      if (!mounted) return;
      
      await meetingProvider.saveCurrentSession(
        title: title.isNotEmpty ? title : null,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Session saved')),
        );
      }
    } catch (e, stackTrace) {
      debugPrint('Error saving session: $e');
      debugPrint('Stack trace: $stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving session: $e')),
        );
      }
    }
  }

  Future<void> _exportSession() async {
    final meetingProvider = context.read<MeetingProvider>();
    if (meetingProvider.currentSession == null) return;

    try {
      final text = await meetingProvider.exportSessionAsText(
        meetingProvider.currentSession!.id,
      );
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Session exported to clipboard')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e')),
        );
      }
    }
  }

  Widget _buildTranscript(SpeechToTextProvider speechProvider) {
    final bubbles = speechProvider.bubbles;
    final hasAny = bubbles.isNotEmpty;
    final meetingProvider = context.read<MeetingProvider>();
    final currentSession = meetingProvider.currentSession;
    // A session is considered "saved" only if it has bubbles (content)
    // New sessions that were just auto-saved but have no bubbles should still show "start"
    final isSavedSession = currentSession != null && currentSession.bubbles.isNotEmpty;

    if (!hasAny) {
      return Center(
        child: Text(
          isSavedSession 
              ? 'Tap the resume button to continue the meeting'
              : 'Tap the start button to begin the meeting',
          style: TextStyle(
            color: Colors.white,
            fontSize: 16,
            shadows: [
              Shadow(color: Colors.black, blurRadius: 4, offset: const Offset(1, 1)),
              Shadow(color: Colors.black, blurRadius: 6, offset: const Offset(-1, -1)),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      controller: _transcriptScrollController,
      // No bottom padding: allow content to sit “under” the transparent dock.
      padding: EdgeInsets.zero,
      itemCount: bubbles.length,
      itemBuilder: (context, index) {
        final b = bubbles[index];
        // Calculate meeting start time: use first bubble's timestamp, or session createdAt, or recording start time
        DateTime? meetingStartTime;
        if (bubbles.isNotEmpty) {
          meetingStartTime = bubbles.first.timestamp;
        } else if (currentSession != null) {
          meetingStartTime = currentSession.createdAt;
        } else if (_recordingStartedAt != null) {
          meetingStartTime = _recordingStartedAt;
        }
        return _buildBubble(
          source: b.source,
          text: b.text,
          timestamp: b.timestamp,
          meetingStartTime: meetingStartTime,
        );
      },
    );
  }

  Widget _buildConversationPanel(
    SpeechToTextProvider speechProvider,
    MeetingProvider meetingProvider,
  ) {
    _ensureRecordingClock(speechProvider);
    final isRec = speechProvider.isRecording;
    final elapsed = _recordingStartedAt == null ? null : DateTime.now().difference(_recordingStartedAt!);
    
    // Check if this is a saved session (has bubbles or valid MongoDB ObjectId)
    final currentSession = meetingProvider.currentSession;
    // A session is considered "saved" only if it has bubbles (content)
    // New sessions that were just auto-saved but have no bubbles should still show "start"
    final isSavedSession = currentSession != null && currentSession.bubbles.isNotEmpty;
    final hasExistingBubbles = speechProvider.bubbles.isNotEmpty;
    const dockButtonSize = 48.0;
    final dockButtonStyle = IconButton.styleFrom(
      minimumSize: const Size(dockButtonSize, dockButtonSize),
      maximumSize: const Size(dockButtonSize, dockButtonSize),
      padding: EdgeInsets.zero,
      iconSize: 22,
      foregroundColor: Theme.of(context).colorScheme.onSurface,
      side: BorderSide(
        color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.8),
        width: 1.5,
      ),
    );
    final templatesButtonStyle = IconButton.styleFrom(
      minimumSize: const Size(dockButtonSize, dockButtonSize),
      maximumSize: const Size(dockButtonSize, dockButtonSize),
      padding: EdgeInsets.zero,
      iconSize: 22,
      foregroundColor: Theme.of(context).brightness == Brightness.light 
          ? Colors.white 
          : Theme.of(context).colorScheme.onSurface,
      side: BorderSide(
        color: Theme.of(context).brightness == Brightness.light
            ? Colors.white.withValues(alpha: 0.8)
            : Theme.of(context).colorScheme.outline.withValues(alpha: 0.8),
        width: 1.5,
      ),
    );

    final dockDecoration = BoxDecoration(
      // Dark theme background with transparency
      color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.7),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(
        color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3),
      ),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.3),
          blurRadius: 14,
          offset: const Offset(0, 6),
        ),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Small top status row with connection state and optional checkboxes
        SizedBox(
          height: dockButtonSize,
          child: Row(
            children: [
              // Connection state indicator
              Tooltip(
                message: speechProvider.isConnected ? 'Connected' : 'Not connected',
                child: Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: speechProvider.isConnected ? Colors.green : Colors.grey,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // Use mic checkbox
              Checkbox(
                value: _useMic,
                onChanged: (value) {
                  final newValue = value ?? true;
                  setState(() => _useMic = newValue);
                  // If recording is active, toggle mic in the provider
                  if (_speechProvider?.isRecording == true) {
                    _speechProvider?.setUseMic(newValue);
                  }
                },
                visualDensity: VisualDensity.compact,
              ),
              Text('Use mic', style: TextStyle(
                fontSize: 13,
                color: Colors.white,
                shadows: [
                  Shadow(color: Colors.black, blurRadius: 4, offset: const Offset(1, 1)),
                  Shadow(color: Colors.black, blurRadius: 6, offset: const Offset(-1, -1)),
                ],
              )),
              const SizedBox(width: 16),
              // Auto Ask checkbox
              Checkbox(
                value: _autoAsk,
                onChanged: (value) {
                  setState(() => _autoAsk = value ?? false);
                  _updateAutoAskCallback();
                },
                visualDensity: VisualDensity.compact,
              ),
              Text('Auto Ask', style: TextStyle(
                fontSize: 13,
                color: Colors.white,
                shadows: [
                  Shadow(color: Colors.black, blurRadius: 4, offset: const Offset(1, 1)),
                  Shadow(color: Colors.black, blurRadius: 6, offset: const Offset(-1, -1)),
                ],
              )),
              const Spacer(),
              // Recording status
              if (isRec) ...[
                Container(
                  width: 10,
                  height: 10,
                  decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Text('REC', style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  shadows: [
                    Shadow(color: Colors.black, blurRadius: 4, offset: const Offset(1, 1)),
                    Shadow(color: Colors.black, blurRadius: 6, offset: const Offset(-1, -1)),
                  ],
                )),
                const SizedBox(width: 8),
                Text(
                  elapsed == null ? '' : _formatDuration(elapsed),
                  style: TextStyle(
                    fontFeatures: [FontFeature.tabularFigures()],
                    color: Colors.white,
                    shadows: [
                      Shadow(color: Colors.black, blurRadius: 4, offset: const Offset(1, 1)),
                      Shadow(color: Colors.black, blurRadius: 6, offset: const Offset(-1, -1)),
                    ],
                  ),
                ),
              ] else
                Text(
                  (isSavedSession || hasExistingBubbles) ? 'Ready to resume' : 'Ready',
                  style: TextStyle(
                    color: Colors.white70,
                    shadows: [
                      Shadow(color: Colors.black, blurRadius: 4, offset: const Offset(1, 1)),
                      Shadow(color: Colors.black, blurRadius: 6, offset: const Offset(-1, -1)),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),

        // Transcript display
        Expanded(
          child: Stack(
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.5)),
                ),
                child: _buildTranscript(speechProvider),
              ),
              if (_showConversationControls)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        decoration: dockDecoration,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        child: Wrap(
                          alignment: WrapAlignment.center,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 10,
                          runSpacing: 8,
                          children: [
                            if (isRec)
                              IconButton.outlined(
                                onPressed: speechProvider.isStopping
                                    ? null
                                    : () async {
                                        if (!mounted) return;
                                        
                                        // Stop recording - non-blocking for UI responsiveness
                                        if (!mounted) return;
                                        try {
                                          // Start stop operation (non-blocking)
                                          speechProvider.stopRecording().catchError((error, stackTrace) {
                                            debugPrint('Error stopping recording: $error');
                                            debugPrint('Stack trace: $stackTrace');
                                          });
                                          
                                          // Sync bubbles AFTER stopping (deferred to avoid crashes)
                                          // Use a small delay to let stop flags be set first
                                          Future.delayed(const Duration(milliseconds: 200), () {
                                            if (!mounted) return;
                                            if (_meetingProvider?.currentSession != null && _speechProvider != null) {
                                              try {
                                                _isUpdatingBubbles = true;
                                                final currentBubbles = _speechProvider!.bubbles;
                                                if (currentBubbles.isNotEmpty && mounted) {
                                                  try {
                                                    _meetingProvider!.updateCurrentSessionBubbles(currentBubbles);
                                                  } catch (syncError) {
                                                    debugPrint('Error syncing bubbles after stop: $syncError');
                                                  }
                                                }
                                              } catch (e) {
                                                debugPrint('Error in bubble sync after stop: $e');
                                              } finally {
                                                if (mounted) {
                                                  _isUpdatingBubbles = false;
                                                }
                                              }
                                            }
                                          });
                                          
                                          // Don't save automatically - let user save manually to avoid crashes
                                          // Session is auto-saved periodically anyway
                                        } catch (e, stackTrace) {
                                          debugPrint('Error initiating stop: $e');
                                          debugPrint('Stack trace: $stackTrace');
                                          // Don't show SnackBar here to avoid context access issues
                                        }
                                      },
                                tooltip: speechProvider.isStopping ? 'Stopping...' : 'Stop (Ctrl+R)',
                                icon: speechProvider.isStopping
                                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                    : const Icon(Icons.stop),
                                style: IconButton.styleFrom(
                                  minimumSize: const Size(dockButtonSize, dockButtonSize),
                                  maximumSize: const Size(dockButtonSize, dockButtonSize),
                                  padding: EdgeInsets.zero,
                                  iconSize: 22,
                                  foregroundColor: Theme.of(context).colorScheme.error,
                                  side: BorderSide(
                                    color: Theme.of(context).colorScheme.error,
                                    width: 2,
                                  ),
                                ),
                              )
                            else
                              IconButton.filled(
                                onPressed: () {
                                  // Don't clear bubbles when resuming a saved session
                                  final shouldClear = !isSavedSession && !hasExistingBubbles;
                                  speechProvider.startRecording(clearExisting: shouldClear, useMic: _useMic);
                                },
                                tooltip: (isSavedSession || hasExistingBubbles) ? 'Resume (Ctrl+R)' : 'Start (Ctrl+R)',
                                icon: Icon((isSavedSession || hasExistingBubbles) ? Icons.play_arrow : Icons.play_arrow),
                                style: IconButton.styleFrom(
                                  minimumSize: const Size(dockButtonSize, dockButtonSize),
                                  maximumSize: const Size(dockButtonSize, dockButtonSize),
                                  padding: EdgeInsets.zero,
                                  iconSize: 22,
                                  backgroundColor: Theme.of(context).colorScheme.primary,
                                  foregroundColor: Theme.of(context).colorScheme.onPrimary,
                                ),
                              ),
                            IconButton.outlined(
                              onPressed: _markMoment,
                              tooltip: 'Mark moment (Ctrl+M)',
                              icon: const Icon(Icons.bookmark_add_outlined),
                              style: dockButtonStyle,
                            ),
                            IconButton.outlined(
                              onPressed: isRec ? null : speechProvider.clearTranscript,
                              tooltip: 'Clear transcript',
                              icon: const Icon(Icons.clear),
                              style: dockButtonStyle,
                            ),
                            IconButton.outlined(
                              onPressed: meetingProvider.isLoading ? null : _saveSession,
                              tooltip: 'Save session (Ctrl+S)',
                              icon: const Icon(Icons.save),
                              style: dockButtonStyle,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              // Toggle conversation controls button
              Align(
                alignment: Alignment.bottomLeft,
                child: Padding(
                  padding: const EdgeInsets.only(left: 12, bottom: 12),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      decoration: dockDecoration,
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                      child: IconButton(
                        icon: Icon(_showConversationControls ? Icons.visibility_off : Icons.visibility),
                        tooltip: _showConversationControls ? 'Hide conversation controls' : 'Show conversation controls',
                        onPressed: () => setState(() => _showConversationControls = !_showConversationControls),
                        style: IconButton.styleFrom(
                          minimumSize: const Size(28, 28),
                          maximumSize: const Size(28, 28),
                          padding: EdgeInsets.zero,
                          iconSize: 14,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAiPanel({
    required SpeechToTextProvider speechProvider,
    required MeetingProvider meetingProvider,
    required MeetingSession? session,
    required bool twoColumn,
  }) {
    const dockButtonSize = 48.0;
    final dockButtonStyle = IconButton.styleFrom(
      minimumSize: const Size(dockButtonSize, dockButtonSize),
      maximumSize: const Size(dockButtonSize, dockButtonSize),
      padding: EdgeInsets.zero,
      iconSize: 22,
      foregroundColor: Theme.of(context).colorScheme.onSurface,
      side: BorderSide(
        color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.8),
        width: 1.5,
      ),
    );
    final templatesButtonStyle = IconButton.styleFrom(
      minimumSize: const Size(dockButtonSize, dockButtonSize),
      maximumSize: const Size(dockButtonSize, dockButtonSize),
      padding: EdgeInsets.zero,
      iconSize: 22,
      foregroundColor: Theme.of(context).brightness == Brightness.light 
          ? Colors.white 
          : Theme.of(context).colorScheme.onSurface,
      side: BorderSide(
        color: Theme.of(context).brightness == Brightness.light
            ? Colors.white.withValues(alpha: 0.8)
            : Theme.of(context).colorScheme.outline.withValues(alpha: 0.8),
        width: 1.5,
      ),
    );
    final dockDecoration = BoxDecoration(
      // Dark theme background with transparency
      color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.7),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(
        color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3),
      ),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.3),
          blurRadius: 14,
          offset: const Offset(0, 6),
        ),
      ],
    );
    if (!twoColumn) {
      // In single-column mode, use the same layout structure as two-column mode
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Prompt input + Ask button ABOVE the AI response field (same as two-column)
          SizedBox(
            height: dockButtonSize,
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.5)),
                    ),
                    child: TextField(
                      controller: _askAiController,
                      enabled: !speechProvider.isAiLoading,
                      style: const TextStyle(
                        color: Colors.white,
                        shadows: [
                          Shadow(color: Colors.black, blurRadius: 4, offset: Offset(1, 1)),
                          Shadow(color: Colors.black, blurRadius: 6, offset: Offset(-1, -1)),
                        ],
                      ),
                      decoration: InputDecoration(
                        hintText: 'Ask AI… (Ctrl+Enter)',
                        hintStyle: TextStyle(
                          color: Colors.white.withValues(alpha: 0.7),
                          shadows: [
                            Shadow(color: Colors.black, blurRadius: 4, offset: const Offset(1, 1)),
                            Shadow(color: Colors.black, blurRadius: 6, offset: const Offset(-1, -1)),
                          ],
                        ),
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                      ),
                      textInputAction: TextInputAction.send,
                      onSubmitted: (value) => _askAiWithPrompt(value),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                _QuestionTemplateButton(
                  cachedQuestions: _cachedQuestions,
                  onQuestionSelected: _askQuestionFromTemplate,
                  onReload: _loadQuestionTemplates,
                  getQuestions: () async {
                    if (_questionService == null) return _cachedQuestions;
                    return await _questionService!.getAllQuestions();
                  },
                ),
                const SizedBox(width: 10),
                IconButton.filled(
                  tooltip: 'Ask (Ctrl+Enter)',
                  onPressed: speechProvider.isAiLoading
                      ? null
                      : () => _askAiWithPrompt(_askAiController.text),
                  icon: speechProvider.isAiLoading
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.auto_awesome),
                  style: IconButton.styleFrom(
                    minimumSize: const Size(dockButtonSize, dockButtonSize),
                    maximumSize: const Size(dockButtonSize, dockButtonSize),
                    padding: EdgeInsets.zero,
                    iconSize: 22,
                    backgroundColor: Colors.deepPurple,
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),

          // AI Response field that expands (same as two-column)
          Expanded(
            child: Stack(
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.5)),
                  ),
                  child: TextField(
                    controller: _aiResponseController,
                    readOnly: true,
                    minLines: null,
                    maxLines: null,
                    expands: true,
                    style: const TextStyle(
                      color: Colors.white,
                      shadows: [
                        Shadow(
                          color: Colors.black,
                          blurRadius: 4,
                          offset: Offset(1, 1),
                        ),
                        Shadow(
                          color: Colors.black,
                          blurRadius: 6,
                          offset: Offset(-1, -1),
                        ),
                      ],
                    ),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      isCollapsed: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),
                if (_showAiControls)
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: Container(
                          decoration: dockDecoration,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          child: Wrap(
                            alignment: WrapAlignment.center,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 10,
                            runSpacing: 8,
                            children: [
                              IconButton.outlined(
                                tooltip: 'Summary (long-press to regenerate)',
                                onPressed: meetingProvider.isGeneratingSummary
                                    ? null
                                    : () async {
                                        final session = meetingProvider.currentSession;
                                        // If summary exists, show it directly
                                        if (session?.summary != null && session!.summary!.isNotEmpty) {
                                          await _showTextDialog(title: 'Summary', text: session.summary!);
                                        } else {
                                          // Generate if doesn't exist
                                          await meetingProvider.generateSummary();
                                          final s = meetingProvider.currentSession?.summary ?? '';
                                          await _showTextDialog(title: 'Summary', text: s);
                                        }
                                      },
                                onLongPress: meetingProvider.isGeneratingSummary
                                    ? null
                                    : () async {
                                        // Force regenerate
                                        await meetingProvider.generateSummary(regenerate: true);
                                        final s = meetingProvider.currentSession?.summary ?? '';
                                        await _showTextDialog(title: 'Summary', text: s);
                                      },
                                icon: meetingProvider.isGeneratingSummary
                                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                    : const Icon(Icons.summarize),
                                style: dockButtonStyle,
                              ),
                              IconButton.outlined(
                                tooltip: 'Markers (${meetingProvider.markers.length})',
                                onPressed: () => _showMarkersDialog(meetingProvider),
                                icon: const Icon(Icons.bookmarks_outlined),
                                style: dockButtonStyle,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                // Toggle AI controls button
                Align(
                  alignment: Alignment.bottomRight,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 12, bottom: 12),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        decoration: dockDecoration,
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                        child: IconButton(
                          icon: Icon(_showAiControls ? Icons.visibility_off : Icons.visibility),
                          tooltip: _showAiControls ? 'Hide AI controls' : 'Show AI controls',
                          onPressed: () => setState(() => _showAiControls = !_showAiControls),
                          style: IconButton.styleFrom(
                            minimumSize: const Size(28, 28),
                            maximumSize: const Size(28, 28),
                            padding: EdgeInsets.zero,
                            iconSize: 14,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    // In two-column mode, keep the response area height stable (matching transcript).
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Prompt input + Ask button ABOVE the AI response field
        SizedBox(
          height: dockButtonSize,
          child: Row(
            children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.5)),
                  ),
                  child: TextField(
                    controller: _askAiController,
                    enabled: !speechProvider.isAiLoading,
                    style: const TextStyle(
                      color: Colors.white,
                      shadows: [
                        Shadow(color: Colors.black, blurRadius: 4, offset: Offset(1, 1)),
                        Shadow(color: Colors.black, blurRadius: 6, offset: Offset(-1, -1)),
                      ],
                    ),
                    decoration: InputDecoration(
                      hintText: 'Ask AI… (Ctrl+Enter)',
                      hintStyle: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7),
                        shadows: [
                          Shadow(color: Colors.black, blurRadius: 4, offset: const Offset(1, 1)),
                          Shadow(color: Colors.black, blurRadius: 6, offset: const Offset(-1, -1)),
                        ],
                      ),
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                    ),
                    textInputAction: TextInputAction.send,
                    onSubmitted: (value) => _askAiWithPrompt(value),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              _QuestionTemplateButton(
                cachedQuestions: _cachedQuestions,
                onQuestionSelected: _askQuestionFromTemplate,
                onReload: _loadQuestionTemplates,
                getQuestions: () async {
                  if (_questionService == null) return _cachedQuestions;
                  return await _questionService!.getAllQuestions();
                },
              ),
              const SizedBox(width: 10),
              IconButton.filled(
                tooltip: 'Ask (Ctrl+Enter)',
                onPressed: speechProvider.isAiLoading
                    ? null
                    : () => _askAiWithPrompt(_askAiController.text),
                icon: speechProvider.isAiLoading
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.auto_awesome),
                style: IconButton.styleFrom(
                  minimumSize: const Size(dockButtonSize, dockButtonSize),
                  maximumSize: const Size(dockButtonSize, dockButtonSize),
                  padding: EdgeInsets.zero,
                  iconSize: 22,
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  foregroundColor: Theme.of(context).colorScheme.onPrimary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),

        Expanded(
          child: Stack(
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.5)),
                ),
                child: TextField(
                  controller: _aiResponseController,
                  readOnly: true,
                  minLines: null,
                  maxLines: null,
                  expands: true,
                  style: const TextStyle(
                    color: Colors.white,
                    shadows: [
                      Shadow(
                        color: Colors.black,
                        blurRadius: 4,
                        offset: Offset(1, 1),
                      ),
                      Shadow(
                        color: Colors.black,
                        blurRadius: 6,
                        offset: Offset(-1, -1),
                      ),
                    ],
                  ),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    isCollapsed: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ),
              if (_showAiControls)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        decoration: dockDecoration,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        child: Wrap(
                          alignment: WrapAlignment.center,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 10,
                          runSpacing: 8,
                          children: [
                            IconButton.outlined(
                              tooltip: 'Summary (long-press to regenerate)',
                            onPressed: meetingProvider.isGeneratingSummary
                                ? null
                                : () async {
                                    final session = meetingProvider.currentSession;
                                    // If summary exists, show it directly
                                    if (session?.summary != null && session!.summary!.isNotEmpty) {
                                      await _showTextDialog(title: 'Summary', text: session.summary!);
                                    } else {
                                      // Generate if doesn't exist
                                      await meetingProvider.generateSummary();
                                      final s = meetingProvider.currentSession?.summary ?? '';
                                      await _showTextDialog(title: 'Summary', text: s);
                                    }
                                  },
                            onLongPress: meetingProvider.isGeneratingSummary
                                ? null
                                : () async {
                                    // Force regenerate
                                    await meetingProvider.generateSummary(regenerate: true);
                                    final s = meetingProvider.currentSession?.summary ?? '';
                                    await _showTextDialog(title: 'Summary', text: s);
                                  },
                            icon: meetingProvider.isGeneratingSummary
                                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                : const Icon(Icons.summarize),
                            style: dockButtonStyle,
                          ),
                          IconButton.outlined(
                            tooltip: 'Markers (${meetingProvider.markers.length})',
                            onPressed: () => _showMarkersDialog(meetingProvider),
                            icon: const Icon(Icons.bookmarks_outlined),
                            style: dockButtonStyle,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              // Toggle AI controls button
              Align(
                alignment: Alignment.bottomRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 12, bottom: 12),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      decoration: dockDecoration,
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                      child: IconButton(
                        icon: Icon(_showAiControls ? Icons.visibility_off : Icons.visibility),
                        tooltip: _showAiControls ? 'Hide AI controls' : 'Show AI controls',
                        onPressed: () => setState(() => _showAiControls = !_showAiControls),
                        style: IconButton.styleFrom(
                          minimumSize: const Size(28, 28),
                          maximumSize: const Size(28, 28),
                          padding: EdgeInsets.zero,
                          iconSize: 14,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<SpeechToTextProvider, MeetingProvider>(
      builder: (context, speechProvider, meetingProvider, child) {
        _maybeAutoScroll(speechProvider);

        final aiText = speechProvider.aiErrorMessage.isNotEmpty
            ? 'Error: ${speechProvider.aiErrorMessage}'
            : speechProvider.aiResponse;
        if (_aiResponseController.text != aiText) {
          _aiResponseController.text = aiText;
          _aiResponseController.selection = TextSelection.collapsed(
            offset: _aiResponseController.text.length,
          );
        }

        final session = meetingProvider.currentSession;
        final shortcutsProvider = context.read<ShortcutsProvider>();

        // Build shortcuts map from provider
        final shortcuts = <ShortcutActivator, Intent>{};
        final toggleRecord = shortcutsProvider.getShortcutActivator('toggleRecord');
        final askAi = shortcutsProvider.getShortcutActivator('askAi');
        final saveSession = shortcutsProvider.getShortcutActivator('saveSession');
        final exportSession = shortcutsProvider.getShortcutActivator('exportSession');
        final markMoment = shortcutsProvider.getShortcutActivator('markMoment');
        
        if (toggleRecord != null) shortcuts[toggleRecord] = const _ToggleRecordIntent();
        if (askAi != null) shortcuts[askAi] = const _AskAiIntent();
        if (saveSession != null) shortcuts[saveSession] = const _SaveSessionIntent();
        if (exportSession != null) shortcuts[exportSession] = const _ExportIntent();
        if (markMoment != null) shortcuts[markMoment] = const _MarkIntent();

        return Shortcuts(
          shortcuts: shortcuts,
          child: Actions(
            actions: <Type, Action<Intent>>{
              _ToggleRecordIntent: CallbackAction<_ToggleRecordIntent>(
                onInvoke: (_) async {
                  if (speechProvider.isRecording) {
                    if (!mounted || speechProvider.isStopping) return null;
                    
                    // Stop recording - non-blocking for UI responsiveness
                    if (!mounted) return null;
                    try {
                      // Start stop operation (non-blocking)
                      speechProvider.stopRecording().catchError((error, stackTrace) {
                        debugPrint('Error stopping recording: $error');
                        debugPrint('Stack trace: $stackTrace');
                      });
                      
                      // Sync bubbles AFTER stopping (deferred to avoid crashes)
                      // Use a small delay to let stop flags be set first
                      Future.delayed(const Duration(milliseconds: 200), () {
                        if (!mounted) return;
                        if (_meetingProvider?.currentSession != null && _speechProvider != null) {
                          try {
                            _isUpdatingBubbles = true;
                            final currentBubbles = _speechProvider!.bubbles;
                            if (currentBubbles.isNotEmpty && mounted) {
                              try {
                                _meetingProvider!.updateCurrentSessionBubbles(currentBubbles);
                              } catch (syncError) {
                                debugPrint('Error syncing bubbles after stop: $syncError');
                              }
                            }
                          } catch (e) {
                            debugPrint('Error in bubble sync after stop: $e');
                          } finally {
                            if (mounted) {
                              _isUpdatingBubbles = false;
                            }
                          }
                        }
                      });
                      
                      // Don't save automatically - let user save manually to avoid crashes
                      // Session is auto-saved periodically anyway
                    } catch (e, stackTrace) {
                      debugPrint('Error initiating stop: $e');
                      debugPrint('Stack trace: $stackTrace');
                      // Don't show SnackBar here to avoid context access issues
                    }
                    return null;
                  } else {
                    // Check if we should preserve existing bubbles (resume vs new)
                    final meetingProvider = context.read<MeetingProvider>();
                    final currentSession = meetingProvider.currentSession;
                    // A session is considered "saved" only if it has bubbles (content)
                    // New sessions that were just auto-saved but have no bubbles should still show "start"
                    final isSavedSession = currentSession != null && currentSession.bubbles.isNotEmpty;
                    final hasExistingBubbles = speechProvider.bubbles.isNotEmpty;
                    final shouldClear = !isSavedSession && !hasExistingBubbles;
                    speechProvider.startRecording(clearExisting: shouldClear, useMic: _useMic);
                  }
                  return null;
                },
              ),
              _AskAiIntent: CallbackAction<_AskAiIntent>(
                onInvoke: (_) {
                  _askAiWithPrompt(_askAiController.text);
                  return null;
                },
              ),
              _SaveSessionIntent: CallbackAction<_SaveSessionIntent>(
                onInvoke: (_) {
                  if (!meetingProvider.isLoading) _saveSession();
                  return null;
                },
              ),
              _ExportIntent: CallbackAction<_ExportIntent>(
                onInvoke: (_) {
                  if (session != null) _exportSession();
                  return null;
                },
              ),
              _MarkIntent: CallbackAction<_MarkIntent>(
                onInvoke: (_) {
                  _markMoment();
                  return null;
                },
              ),
            },
            child: Focus(
              autofocus: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Background section extending from top to split line
                  Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Session title and actions (rare actions in menu; core actions are docked)
                          Row(
                            children: [
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 12.0, horizontal: 4.0),
                                  child: Text(
                                    session?.title ?? 'Untitled Session',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w500,
                                      color: Theme.of(context).colorScheme.onSurface,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              // Mode selector dropdown (built-in + custom modes)
                              Consumer<MeetingProvider>(
                                builder: (context, meetingProvider, child) {
                                  final currentKey = session?.modeKey ?? 'general';
                                  final navigatorContext = context;
                                  if (_modeDisplaysFuture == null) {
                                    final auth = context.read<AuthProvider>().token;
                                    WidgetsBinding.instance.addPostFrameCallback((_) {
                                      if (!mounted) return;
                                      final svc = MeetingModeService();
                                      svc.setAuthToken(auth);
                                      setState(() {
                                        _modeService = svc;
                                        _modeDisplaysFuture = svc.getCustomOnlyModeDisplays();
                                      });
                                    });
                                    final theme = Theme.of(context);
                                    return Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                      decoration: BoxDecoration(
                                        color: theme.colorScheme.surfaceContainerHighest,
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(color: theme.colorScheme.outline.withValues(alpha: 0.3), width: 1),
                                      ),
                                      child: const SizedBox(width: 100, height: 32, child: Center(child: CircularProgressIndicator(strokeWidth: 2))),
                                    );
                                  }
                                  return FutureBuilder<List<ModeDisplay>>(
                                    future: _modeDisplaysFuture,
                                    builder: (context, snap) {
                                      if (!snap.hasData) {
                                        final theme = Theme.of(context);
                                        return Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                          decoration: BoxDecoration(
                                            color: theme.colorScheme.surfaceContainerHighest,
                                            borderRadius: BorderRadius.circular(8),
                                            border: Border.all(color: theme.colorScheme.outline.withValues(alpha: 0.3), width: 1),
                                          ),
                                          child: const SizedBox(width: 100, height: 32, child: Center(child: CircularProgressIndicator(strokeWidth: 2))),
                                        );
                                      }
                                      final raw = snap.data!;
                                      // Dropdown shows only custom modes; prepend General so user can always select it
                                      final generalDisplay = ModeDisplay(
                                        modeKey: MeetingMode.general.name,
                                        label: MeetingMode.general.label,
                                        icon: MeetingMode.general.icon,
                                      );
                                      final displays = raw.isEmpty
                                          ? [generalDisplay]
                                          : [generalDisplay, ...raw];
                                      final currentLabel = displays.where((d) => d.modeKey == currentKey).isEmpty
                                          ? 'General'
                                          : displays.firstWhere((d) => d.modeKey == currentKey).label;
                                      final theme = Theme.of(context);
                                      return Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                        decoration: BoxDecoration(
                                          color: theme.colorScheme.surfaceContainerHighest,
                                          borderRadius: BorderRadius.circular(8),
                                          border: Border.all(color: theme.colorScheme.outline.withValues(alpha: 0.3), width: 1),
                                        ),
                                        child: PopupMenuButton<String?>(
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text(
                                                currentLabel,
                                                style: TextStyle(
                                                  color: theme.colorScheme.onSurface,
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.w500,
                                                ),
                                              ),
                                              const SizedBox(width: 4),
                                              Icon(Icons.arrow_drop_down, color: theme.colorScheme.onSurface, size: 20),
                                            ],
                                          ),
                                          color: theme.colorScheme.surfaceContainerHighest,
                                          itemBuilder: (BuildContext menuContext) {
                                            final theme = Theme.of(context);
                                            final items = <PopupMenuEntry<String?>>[];
                                            for (final d in displays) {
                                              items.add(
                                                PopupMenuItem<String?>(
                                                  value: d.modeKey,
                                                  child: Row(
                                                    mainAxisSize: MainAxisSize.min,
                                                    children: [
                                                      Icon(d.icon, size: 18, color: theme.colorScheme.onSurface),
                                                      const SizedBox(width: 8),
                                                      Text(d.label, style: TextStyle(color: theme.colorScheme.onSurface)),
                                                      if (d.modeKey == currentKey) ...[
                                                        const Spacer(),
                                                        Icon(Icons.check, color: theme.colorScheme.primary, size: 18),
                                                      ],
                                                    ],
                                                  ),
                                                ),
                                              );
                                            }
                                            items.add(PopupMenuDivider(color: theme.colorScheme.outline.withValues(alpha: 0.2)));
                                            items.add(
                                              PopupMenuItem<String?>(
                                                enabled: false,
                                                child: InkWell(
                                                  onTap: () async {
                                                    Navigator.pop(menuContext);
                                                    await Navigator.push(
                                                      navigatorContext,
                                                      MaterialPageRoute(builder: (context) => const ManageModePage()),
                                                    );
                                                    if (mounted && _modeService != null) {
                                                      setState(() {
                                                        _modeDisplaysFuture = _modeService!.getCustomOnlyModeDisplays();
                                                      });
                                                    }
                                                  },
                                                  child: Row(
                                                    mainAxisSize: MainAxisSize.min,
                                                    children: [
                                                      Icon(Icons.settings, size: 18, color: theme.colorScheme.onSurface),
                                                      const SizedBox(width: 8),
                                                      Text('Manage mode', style: TextStyle(color: theme.colorScheme.onSurface)),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            );
                                            return items;
                                          },
                                          onSelected: (String? selectedKey) {
                                            if (selectedKey != null && meetingProvider.currentSession != null) {
                                              meetingProvider.updateCurrentSessionModeKey(selectedKey);
                                            }
                                          },
                                        ),
                                      );
                                    },
                                  );
                                },
                              ),
                              const SizedBox(width: 8),
                              // Toggle conversation panel visibility (always visible)
                              Tooltip(
                                message: _showConversationPanel ? 'Hide conversation' : 'Show conversation',
                                child: IconButton(
                                  icon: Icon(_showConversationPanel ? Icons.chat_bubble_outline : Icons.chat_bubble_outline, size: 20),
                                  onPressed: () => setState(() => _showConversationPanel = !_showConversationPanel),
                                  visualDensity: VisualDensity.compact,
                                  iconSize: 20,
                                  color: _showConversationPanel ? Colors.deepPurple : Colors.grey,
                                ),
                              ),
                              // Toggle AI panel visibility (always visible)
                              Tooltip(
                                message: _showAiPanel ? 'Hide AI response' : 'Show AI response',
                                child: IconButton(
                                  icon: Icon(_showAiPanel ? Icons.auto_awesome_outlined : Icons.auto_awesome_outlined, size: 20),
                                  onPressed: () => setState(() => _showAiPanel = !_showAiPanel),
                                  visualDensity: VisualDensity.compact,
                                  iconSize: 20,
                                  color: _showAiPanel ? Colors.deepPurple : Colors.grey,
                                ),
                              ),
                              const SizedBox(width: 8),
                              IconButton(
                                icon: const Icon(Icons.file_download),
                                tooltip: 'Export (Ctrl+E)',
                                onPressed: session == null ? null : _exportSession,
                                color: Theme.of(context).colorScheme.onSurface,
                              ),
                              PopupMenuButton(
                                icon: Icon(Icons.more_vert, color: Theme.of(context).colorScheme.onSurface),
                                itemBuilder: (context) => [
                                  const PopupMenuItem(
                                    value: 'sessions',
                                    child: Row(
                                      children: [
                                        Icon(Icons.folder, size: 20),
                                        SizedBox(width: 8),
                                        Text('Manage Sessions'),
                                      ],
                                    ),
                                  ),
                                  const PopupMenuItem(
                                    value: 'new',
                                    child: Row(
                                      children: [
                                        Icon(Icons.add, size: 20),
                                        SizedBox(width: 8),
                                        Text('New Session'),
                                      ],
                                    ),
                                  ),
                                ],
                                onSelected: (value) {
                                  if (value == 'sessions') {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (context) => const SessionsListPage(),
                                      ),
                                    );
                                  } else if (value == 'new') {
                                    meetingProvider.createNewSession();
                                  }
                                },
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Content area with padding
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Error message
                          if (speechProvider.errorMessage.isNotEmpty ||
                              meetingProvider.errorMessage.isNotEmpty)
                            Container(
                              padding: const EdgeInsets.all(12),
                              margin: const EdgeInsets.only(bottom: 16),
                              decoration: BoxDecoration(
                                color: Colors.red.shade100,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Row(
                                children: [
                                  const Icon(Icons.error, color: Colors.red),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      speechProvider.errorMessage.isNotEmpty
                                          ? speechProvider.errorMessage
                                          : meetingProvider.errorMessage,
                                      style: TextStyle(color: Colors.red.shade900),
                                    ),
                                  ),
                                ],
                              ),
                            ),

                          Expanded(
                            child: Stack(
                              children: [
                                LayoutBuilder(
                                  builder: (context, constraints) {
                              final twoColumn = constraints.maxWidth >= 900;

                              if (!twoColumn) {
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    if (_showConversationPanel)
                                      Expanded(
                                        flex: 3,
                                        child: _buildConversationPanel(speechProvider, meetingProvider),
                                      ),
                                    if (_showConversationPanel && _showAiPanel) const SizedBox(height: 16),
                                    if (_showAiPanel)
                                      Expanded(
                                        flex: 2,
                                        child: _buildAiPanel(
                                          speechProvider: speechProvider,
                                          meetingProvider: meetingProvider,
                                          session: session,
                                          twoColumn: false,
                                        ),
                                      ),
                                    if (!_showConversationPanel && !_showAiPanel)
                                      const Expanded(
                                        child: Center(
                                          child: Text('Both panels are hidden', style: TextStyle(color: Colors.grey)),
                                        ),
                                      ),
                                  ],
                                );
                              }

                              return Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if (_showConversationPanel)
                                    Expanded(child: _buildConversationPanel(speechProvider, meetingProvider)),
                                  if (_showConversationPanel && _showAiPanel) const SizedBox(width: 16),
                                  if (_showConversationPanel && _showAiPanel)
                                    VerticalDivider(width: 1, thickness: 1, color: Colors.grey.shade300),
                                  if (_showConversationPanel && _showAiPanel) const SizedBox(width: 16),
                                  if (_showAiPanel)
                                    Expanded(
                                      child: _buildAiPanel(
                                        speechProvider: speechProvider,
                                        meetingProvider: meetingProvider,
                                        session: session,
                                        twoColumn: true,
                                      ),
                                    ),
                                  if (!_showConversationPanel && !_showAiPanel)
                                    const Expanded(
                                      child: Center(
                                        child: Text('Both panels are hidden', style: TextStyle(color: Colors.grey)),
                                      ),
                                    ),
                                ],
                              );
                            },
                          ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _QuestionTemplateButton extends StatefulWidget {
  final List<String> cachedQuestions;
  final Function(String) onQuestionSelected;
  final Future<void> Function() onReload;
  final Future<List<String>> Function() getQuestions;

  const _QuestionTemplateButton({
    required this.cachedQuestions,
    required this.onQuestionSelected,
    required this.onReload,
    required this.getQuestions,
  });

  @override
  State<_QuestionTemplateButton> createState() => _QuestionTemplateButtonState();
}

class _QuestionTemplateButtonState extends State<_QuestionTemplateButton> {
  static const double _buttonSize = 48.0;
  
  Future<void> _showMenu() async {
    // Reload questions before showing menu
    await widget.onReload();
    if (!mounted) return;
    
    // Get fresh questions after reload
    final questions = await widget.getQuestions();
    if (!mounted) return;
    
    final RenderBox? buttonBox = context.findRenderObject() as RenderBox?;
    if (buttonBox == null) return;
    
    final position = buttonBox.localToGlobal(Offset.zero);
    final size = buttonBox.size;
    
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy + size.height + 4,
        position.dx + size.width,
        position.dy + size.height + 4,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
      ),
      items: [
        ...questions.map((question) {
          return PopupMenuItem<String>(
            value: question,
            child: Text(question),
          );
        }),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: '__manage_templates__',
          child: Row(
            children: [
              Icon(Icons.settings, size: 20, color: Theme.of(context).colorScheme.onSurface),
              const SizedBox(width: 8),
              const Text('Manage Templates'),
            ],
          ),
        ),
      ],
    );
    
    if (selected != null && mounted) {
      if (selected == '__manage_templates__') {
        // Navigate to manage templates page
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => const ManageQuestionTemplatesPage(),
          ),
        );
      } else {
        widget.onQuestionSelected(selected);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Question Templates',
      child: GestureDetector(
        onTap: _showMenu,
        child: Container(
          width: _buttonSize,
          height: _buttonSize,
          decoration: BoxDecoration(
            border: Border.all(
              color: Colors.deepPurple,
              width: 1.5,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            Icons.quiz,
            size: 22,
            color: Colors.deepPurple,
          ),
        ),
      ),
    );
  }
}

class _ToggleRecordIntent extends Intent {
  const _ToggleRecordIntent();
}

class _AskAiIntent extends Intent {
  const _AskAiIntent();
}

class _SaveSessionIntent extends Intent {
  const _SaveSessionIntent();
}

// Animated badge widget for showing session status
class _AnimatedSessionBadge extends StatefulWidget {
  final bool isRecording;

  const _AnimatedSessionBadge({
    required this.isRecording,
  });

  @override
  State<_AnimatedSessionBadge> createState() => _AnimatedSessionBadgeState();
}

class _AnimatedSessionBadgeState extends State<_AnimatedSessionBadge>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late Animation<double> _opacityAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1000),
      vsync: this,
    )..repeat(reverse: true);

    _scaleAnimation = Tween<double>(
      begin: 1.0,
      end: 1.2,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOut,
    ));

    _opacityAnimation = Tween<double>(
      begin: 0.6,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOut,
    ));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_AnimatedSessionBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isRecording != oldWidget.isRecording) {
      if (widget.isRecording) {
        _controller.repeat(reverse: true);
      } else {
        _controller.stop();
        _controller.reset();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final badgeColor = widget.isRecording
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.primary;

    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: badgeColor,
        shape: BoxShape.circle,
      ),
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          if (widget.isRecording) {
            // Animated pulsing microphone icon when recording
            return Transform.scale(
              scale: _scaleAnimation.value,
              child: Opacity(
                opacity: _opacityAnimation.value,
                child: Icon(
                  Icons.mic,
                  size: 18,
                  color: Colors.white,
                ),
              ),
            );
          } else {
            // Static microphone icon when in progress but not recording
            return Icon(
              Icons.mic_outlined,
              size: 18,
              color: Colors.white,
            );
          }
        },
      ),
    );
  }
}

class _ExportIntent extends Intent {
  const _ExportIntent();
}

class _MarkIntent extends Intent {
  const _MarkIntent();
}

// Sessions List Page
class SessionsListPage extends StatefulWidget {
  const SessionsListPage({super.key});

  @override
  State<SessionsListPage> createState() => _SessionsListPageState();
}

class _SessionsListPageState extends State<SessionsListPage> {
  final TextEditingController _searchController = TextEditingController();
  final int _itemsPerPage = 20;
  int _currentPage = 0;
  int _totalSessions = 0;
  String _searchQuery = '';
  Timer? _searchDebounceTimer;
  MeetingModeService? _modeService;
  List<ModeDisplay>? _modeDisplays;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final authProvider = context.read<AuthProvider>();
      final meetingProvider = context.read<MeetingProvider>();
      // Ensure auth token is set before loading sessions
      meetingProvider.updateAuthToken(authProvider.token);
      
      // Initialize mode service and load mode displays
      if (mounted) {
        _modeService = MeetingModeService();
        _modeService!.setAuthToken(authProvider.token);
        _modeDisplays = await _modeService!.getModeDisplays();
      }
      
      _loadSessions();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reload sessions when navigating back to this page
    // This ensures newly saved sessions appear immediately
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final meetingProvider = context.read<MeetingProvider>();
      // Only reload if we have an auth token (user is logged in)
      final authProvider = context.read<AuthProvider>();
      if (authProvider.token != null && authProvider.token!.isNotEmpty) {
        _loadSessions();
      }
    });
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _searchDebounceTimer?.cancel();
    super.dispose();
  }

  void _onSearchChanged() {
    // Debounce search to avoid too many API calls
    _searchDebounceTimer?.cancel();
    _searchDebounceTimer = Timer(const Duration(milliseconds: 500), () {
      if (mounted) {
        setState(() {
          _searchQuery = _searchController.text.trim();
          _currentPage = 0; // Reset to first page when searching
        });
        _loadSessions();
      }
    });
  }

  Future<void> _loadSessions() async {
    final meetingProvider = context.read<MeetingProvider>();
    final skip = _currentPage * _itemsPerPage;
    
    // Load sessions with pagination and search
    await meetingProvider.loadSessions(
      limit: _itemsPerPage,
      skip: skip,
      search: _searchQuery.isNotEmpty ? _searchQuery : null,
    );
    
    // Get total count for pagination
    if (mounted) {
      final total = await meetingProvider.getSessionsCount(
        search: _searchQuery.isNotEmpty ? _searchQuery : null,
      );
      setState(() {
        _totalSessions = total;
      });
    }
  }

  void _goToPage(int page) {
    final totalPages = (_totalSessions / _itemsPerPage).ceil();
    if (page >= 0 && page < totalPages) {
      setState(() {
        _currentPage = page;
      });
      _loadSessions();
    }
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) {
      return '${hours}h ${minutes}m';
    } else if (minutes > 0) {
      return '${minutes}m ${seconds}s';
    }
    return '${seconds}s';
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final dateOnly = DateTime(date.year, date.month, date.day);
    
    if (dateOnly == today) {
      return 'Today';
    } else if (dateOnly == yesterday) {
      return 'Yesterday';
    } else {
      final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
      return '${months[date.month - 1]} ${date.day}, ${date.year}';
    }
  }

  String _formatTime(DateTime date) {
    final hour = date.hour;
    final minute = date.minute.toString().padLeft(2, '0');
    final period = hour >= 12 ? 'PM' : 'AM';
    final displayHour = hour > 12 ? hour - 12 : (hour == 0 ? 12 : hour);
    return '$displayHour:$minute $period';
  }

  ModeDisplay? _getModeDisplay(String modeKey) {
    if (_modeDisplays == null) return null;
    return _modeDisplays!.firstWhere(
      (display) => display.modeKey == modeKey,
      orElse: () => ModeDisplay(
        modeKey: modeKey,
        label: 'Unknown',
        icon: Icons.help_outline,
      ),
    );
  }

  Widget _buildSessionCard({
    required MeetingSession session,
    required bool isCurrentSession,
    required bool isRecording,
    required MeetingProvider provider,
    required BuildContext context,
  }) {
    final theme = Theme.of(context);
    final modeDisplay = _getModeDisplay(session.modeKey);
    final modeIcon = modeDisplay?.icon ?? Icons.help_outline;
    final modeLabel = modeDisplay?.label ?? 'Unknown';
    
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      elevation: isCurrentSession ? 2 : 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isCurrentSession
            ? BorderSide(
                color: theme.colorScheme.primary.withValues(alpha: 0.5),
                width: 2,
              )
            : BorderSide(
                color: theme.colorScheme.outline.withValues(alpha: 0.1),
                width: 1,
              ),
      ),
      child: InkWell(
        onTap: () async {
          await provider.loadSession(session.id);
          if (mounted) {
            Navigator.pop(context);
          }
        },
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header row with title and status badge
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                session.title,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (isCurrentSession) ...[
                              const SizedBox(width: 8),
                              _AnimatedSessionBadge(
                                isRecording: isRecording,
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 8),
                        // Date and time
                        Row(
                          children: [
                            Icon(
                              Icons.calendar_today,
                              size: 14,
                              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              _formatDate(session.createdAt),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Icon(
                              Icons.access_time,
                              size: 14,
                              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              _formatTime(session.createdAt),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  // Action menu
                  PopupMenuButton<String>(
                    icon: Icon(
                      Icons.more_vert,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                    onSelected: (value) async {
                      if (value == 'export') {
                        try {
                          final text = await provider.exportSessionAsText(session.id);
                          await Clipboard.setData(ClipboardData(text: text));
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: const Row(
                                  children: [
                                    Icon(Icons.check_circle, color: Colors.white),
                                    SizedBox(width: 8),
                                    Text('Exported to clipboard'),
                                  ],
                                ),
                                backgroundColor: Colors.green,
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          }
                        } catch (e) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Export failed: $e'),
                                backgroundColor: theme.colorScheme.error,
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          }
                        }
                      } else if (value == 'delete') {
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: Row(
                              children: [
                                Icon(
                                  Icons.warning_amber_rounded,
                                  color: theme.colorScheme.error,
                                  size: 24,
                                ),
                                const SizedBox(width: 8),
                                const Text('Delete Session?'),
                              ],
                            ),
                            content: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Are you sure you want to delete this session?'),
                                const SizedBox(height: 12),
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.surfaceVariant.withValues(alpha: 0.5),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.description,
                                        size: 16,
                                        color: theme.colorScheme.onSurfaceVariant,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          session.title,
                                          style: theme.textTheme.bodyMedium,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'This action cannot be undone.',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.error,
                                  ),
                                ),
                              ],
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context, false),
                                child: const Text('Cancel'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(context, true),
                                style: FilledButton.styleFrom(
                                  backgroundColor: theme.colorScheme.error,
                                ),
                                child: const Text('Delete'),
                              ),
                            ],
                          ),
                        );
                        if (confirmed == true && mounted) {
                          await provider.deleteSession(session.id);
                          _loadSessions();
                        }
                      }
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 'export',
                        child: Row(
                          children: [
                            Icon(Icons.download, size: 20, color: theme.colorScheme.onSurface),
                            const SizedBox(width: 12),
                            const Text('Export'),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 'delete',
                        child: Row(
                          children: [
                            Icon(Icons.delete, size: 20, color: theme.colorScheme.error),
                            const SizedBox(width: 12),
                            Text(
                              'Delete',
                              style: TextStyle(color: theme.colorScheme.error),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Session metadata row
              Wrap(
                spacing: 16,
                runSpacing: 8,
                children: [
                  // Mode
                  _buildMetadataChip(
                    icon: modeIcon,
                    label: modeLabel,
                    color: theme.colorScheme.primary,
                    context: context,
                  ),
                  // Duration
                  _buildMetadataChip(
                    icon: Icons.timer_outlined,
                    label: _formatDuration(session.duration),
                    color: theme.colorScheme.secondary,
                    context: context,
                  ),
                  // Bubble count
                  if (session.bubbles.isNotEmpty)
                    _buildMetadataChip(
                      icon: Icons.chat_bubble_outline,
                      label: '${session.bubbles.length} messages',
                      color: theme.colorScheme.tertiary,
                      context: context,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMetadataChip({
    required IconData icon,
    required String label,
    required Color color,
    required BuildContext context,
  }) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: color.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final totalPages = _totalSessions > 0 ? (_totalSessions / _itemsPerPage).ceil() : 0;
    final hasNextPage = _currentPage < totalPages - 1;
    final hasPrevPage = _currentPage > 0;
    final startItem = _currentPage * _itemsPerPage + 1;
    final endItem = (_currentPage + 1) * _itemsPerPage;
    final actualEndItem = endItem > _totalSessions ? _totalSessions : endItem;

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        title: const Text('Meeting Sessions'),
        elevation: 0,
      ),
      body: Column(
        children: [
          // Search bar with better styling
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              border: Border(
                bottom: BorderSide(
                  color: theme.colorScheme.outline.withValues(alpha: 0.1),
                ),
              ),
            ),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search sessions by title...',
                prefixIcon: Icon(
                  Icons.search,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: Icon(
                          Icons.clear,
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                        ),
                        onPressed: () {
                          _searchController.clear();
                        },
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: theme.colorScheme.outline.withValues(alpha: 0.2),
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: theme.colorScheme.outline.withValues(alpha: 0.2),
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: theme.colorScheme.primary,
                    width: 2,
                  ),
                ),
                filled: true,
                fillColor: theme.colorScheme.surfaceContainerHighest,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
            ),
          ),
          // Sessions list
          Expanded(
            child: Consumer<MeetingProvider>(
              builder: (context, provider, child) {
                if (provider.isLoading && provider.sessions.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        CircularProgressIndicator(
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Loading sessions...',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                      ],
                    ),
                  );
                }

                if (provider.sessions.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _searchQuery.isNotEmpty ? Icons.search_off : Icons.event_note_outlined,
                          size: 80,
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
                        ),
                        const SizedBox(height: 24),
                        Text(
                          _searchQuery.isNotEmpty
                              ? 'No sessions found'
                              : 'No saved sessions',
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _searchQuery.isNotEmpty
                              ? 'Try adjusting your search terms'
                              : 'Start a meeting to see it here',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                        if (_searchQuery.isNotEmpty) ...[
                          const SizedBox(height: 16),
                          TextButton.icon(
                            onPressed: () {
                              _searchController.clear();
                            },
                            icon: const Icon(Icons.clear),
                            label: const Text('Clear search'),
                          ),
                        ],
                      ],
                    ),
                  );
                }

                return RefreshIndicator(
                  onRefresh: _loadSessions,
                  color: theme.colorScheme.primary,
                  child: Consumer<SpeechToTextProvider>(
                    builder: (context, speechProvider, _) {
                      final currentSession = provider.currentSession;
                      final isRecording = speechProvider.isRecording;
                      
                      return ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: provider.sessions.length,
                        itemBuilder: (context, index) {
                          final session = provider.sessions[index];
                          final isCurrentSession = currentSession != null && 
                              currentSession.id == session.id;
                          
                          return _buildSessionCard(
                            session: session,
                            isCurrentSession: isCurrentSession,
                            isRecording: isRecording,
                            provider: provider,
                            context: context,
                          );
                        },
                      );
                    },
                  ),
                );
              },
            ),
          ),
          // Pagination controls
          if (totalPages > 1)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                border: Border(
                  top: BorderSide(
                    color: theme.colorScheme.outline.withValues(alpha: 0.1),
                  ),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Page info
                  Text(
                    _totalSessions > 0
                        ? 'Showing $startItem-$actualEndItem of $_totalSessions sessions'
                        : 'No sessions',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                  // Pagination buttons
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.chevron_left),
                        onPressed: hasPrevPage ? () => _goToPage(_currentPage - 1) : null,
                        tooltip: 'Previous page',
                        style: IconButton.styleFrom(
                          backgroundColor: hasPrevPage
                              ? theme.colorScheme.surface
                              : null,
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'Page ${_currentPage + 1} of $totalPages',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.onPrimaryContainer,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.chevron_right),
                        onPressed: hasNextPage ? () => _goToPage(_currentPage + 1) : null,
                        tooltip: 'Next page',
                        style: IconButton.styleFrom(
                          backgroundColor: hasNextPage
                              ? theme.colorScheme.surface
                              : null,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}