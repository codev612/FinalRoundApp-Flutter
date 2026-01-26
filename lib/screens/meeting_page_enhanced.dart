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
  bool _showSummary = false;
  bool _showInsights = false;
  SpeechToTextProvider? _speechProvider;
  MeetingProvider? _meetingProvider;
  Timer? _recordingTimer;
  DateTime? _recordingStartedAt;
  bool _showMarkers = true;
  bool _useMic = true;
  bool _autoAsk = false;
  bool _showConversationControls = true;
  bool _showAiControls = true;
  bool _showConversationPanel = true;
  bool _showAiPanel = true;
  bool _isUpdatingBubbles = false; // Flag to prevent infinite loops
  MeetingModeService? _modeService;
  Future<List<ModeDisplay>>? _modeDisplaysFuture;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final authProvider = context.read<AuthProvider>();
      _speechProvider = context.read<SpeechToTextProvider>();
      _meetingProvider = context.read<MeetingProvider>();
      
      final authToken = authProvider.token;
      _speechProvider!.initialize(
        wsUrl: AppConfig.serverWebSocketUrl,
        httpBaseUrl: AppConfig.serverHttpBaseUrl,
        authToken: authToken,
      );
      
      // Update AI service with auth token (but don't restore session here - we'll handle it below)
      _meetingProvider!.setAuthTokensOnly(authToken);

      // Check if we should restore session or start fresh
      final currentSession = _meetingProvider!.currentSession;
      
      if (currentSession != null) {
        // We have a current session
        // Check if it's a new session (timestamp ID) - if so, clear bubbles and don't restore anything
        final isNewSession = _meetingProvider!.hasNewSession;
        if (isNewSession) {
          // It's a new session - clear any existing bubbles to start fresh
          _speechProvider!.clearTranscript();
        } else if (currentSession.bubbles.isNotEmpty) {
          // Session has bubbles and is a saved session - restore them (user clicked a saved session)
          _speechProvider!.restoreBubbles(currentSession.bubbles);
        } else {
          // Session exists but is empty (saved session with no bubbles) - clear bubbles
          _speechProvider!.clearTranscript();
        }
      } else {
        // No current session - try to restore last session, or create new
        await _meetingProvider!.ensureSessionRestored();
        final restoredSession = _meetingProvider!.currentSession;
        if (restoredSession != null && restoredSession.bubbles.isNotEmpty) {
          _speechProvider!.restoreBubbles(restoredSession.bubbles);
        } else if (_meetingProvider!.currentSession == null) {
          // Create new session if none exists
          await _meetingProvider!.createNewSession();
          // Clear bubbles for new session
          _speechProvider!.clearTranscript();
        }
      }

      // Sync bubbles to meeting session
      _speechProvider!.addListener(_syncBubblesToSession);
      
      // Listen for session changes to restore bubbles when session is loaded
      _meetingProvider!.addListener(_onSessionChanged);
    });
  }

  void _syncBubblesToSession() {
    // Prevent infinite loop - don't sync if we're already updating bubbles
    if (_isUpdatingBubbles) return;
    if (_meetingProvider?.currentSession == null || _speechProvider == null) return;
    
    // Only update if bubbles actually changed
    final currentBubbles = _speechProvider!.bubbles;
    final sessionBubbles = _meetingProvider!.currentSession!.bubbles;
    if (currentBubbles.length != sessionBubbles.length ||
        (currentBubbles.isNotEmpty && sessionBubbles.isNotEmpty && 
         currentBubbles.first.text != sessionBubbles.first.text)) {
      _meetingProvider!.updateCurrentSessionBubbles(currentBubbles);
    }
  }

  void _onSessionChanged() {
    // Prevent infinite loop - don't process if we're already updating bubbles
    if (_isUpdatingBubbles) return;
    
    // When session changes (e.g., loaded from home page), restore or clear bubbles
    final currentSession = _meetingProvider?.currentSession;
    if (currentSession != null && _speechProvider != null) {
      _isUpdatingBubbles = true;
      try {
        // Don't restore if it's a new session (timestamp ID) - only restore saved sessions
        final isNewSession = _meetingProvider?.hasNewSession ?? false;
        if (isNewSession) {
          // It's a new session, clear bubbles
          _speechProvider!.clearTranscript();
          return;
        }
        
        // It's a saved session
        if (currentSession.bubbles.isNotEmpty) {
          // Session has bubbles - restore them if speech provider bubbles are empty or different
          if (_speechProvider!.bubbles.isEmpty || 
              _speechProvider!.bubbles.length != currentSession.bubbles.length) {
            _speechProvider!.restoreBubbles(currentSession.bubbles);
          }
        } else {
          // Session has no bubbles - clear any existing bubbles
          _speechProvider!.clearTranscript();
        }
      } finally {
        _isUpdatingBubbles = false;
      }
    }
  }

  @override
  void dispose() {
    _recordingTimer?.cancel();
    _transcriptScrollController.dispose();
    _askAiController.dispose();
    _aiResponseController.dispose();
    _speechProvider?.removeListener(_syncBubblesToSession);
    _meetingProvider?.removeListener(_onSessionChanged);
    super.dispose();
  }

  void _ensureRecordingClock(SpeechToTextProvider speechProvider) {
    if (speechProvider.isRecording) {
      _recordingStartedAt ??= DateTime.now();
      _recordingTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() {});
      });
    } else {
      _recordingStartedAt = null;
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
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
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
    );
  }

  Future<void> _showQuestionTemplates() async {
    final category = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Question Templates'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: MeetingQuestionService.getQuestionsByCategoryMap().entries.map((entry) {
              return ListTile(
                title: Text(entry.key),
                trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                onTap: () => Navigator.pop(context, entry.key),
              );
            }).toList(),
          ),
        ),
      ),
    );

    if (category != null && mounted) {
      final questions = MeetingQuestionService.getQuestionsByCategory(category);
      final selected = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('$category Questions'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: questions.length,
              itemBuilder: (context, index) {
                return ListTile(
                  title: Text(questions[index]),
                  onTap: () => Navigator.pop(context, questions[index]),
                );
              },
            ),
          ),
        ),
      );

      if (selected != null && mounted) {
        _askAiController.text = selected;
      }
    }
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
    
    await meetingProvider.saveCurrentSession(
      title: title.isNotEmpty ? title : null,
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Session saved')),
      );
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
        color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.5),
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
                onChanged: (value) => setState(() => _useMic = value ?? true),
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
                onChanged: (value) => setState(() => _autoAsk = value ?? false),
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
                                onPressed: () async {
                                  await speechProvider.stopRecording();
                                  // Save session when stopping recording
                                  if (_meetingProvider?.currentSession != null) {
                                    try {
                                      await _meetingProvider!.saveCurrentSession();
                                    } catch (e) {
                                      // Silently fail - session is auto-saved anyway
                                      print('Failed to save session on stop: $e');
                                    }
                                  }
                                },
                                tooltip: 'Stop (Ctrl+R)',
                                icon: const Icon(Icons.stop),
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
                                  speechProvider.startRecording(clearExisting: shouldClear);
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
        color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.5),
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
                      onSubmitted: (value) => speechProvider.askAi(question: value),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                IconButton.outlined(
                  tooltip: 'Templates',
                  onPressed: _showQuestionTemplates,
                  icon: const Icon(Icons.quiz),
                  style: dockButtonStyle,
                ),
                const SizedBox(width: 10),
                IconButton.filled(
                  tooltip: 'Ask (Ctrl+Enter)',
                  onPressed: speechProvider.isAiLoading
                      ? null
                      : () => speechProvider.askAi(question: _askAiController.text),
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
                                tooltip: 'Insights (long-press to regenerate)',
                                onPressed: meetingProvider.isGeneratingInsights
                                    ? null
                                    : () async {
                                        final session = meetingProvider.currentSession;
                                        // If insights exist, show them directly
                                        if (session?.insights != null && session!.insights!.isNotEmpty) {
                                          await _showTextDialog(title: 'Insights', text: session.insights!);
                                        } else {
                                          // Generate if doesn't exist
                                          await meetingProvider.generateInsights();
                                          final s = meetingProvider.currentSession?.insights ?? '';
                                          await _showTextDialog(title: 'Insights', text: s);
                                        }
                                      },
                                onLongPress: meetingProvider.isGeneratingInsights
                                    ? null
                                    : () async {
                                        // Force regenerate
                                        await meetingProvider.generateInsights(regenerate: true);
                                        final s = meetingProvider.currentSession?.insights ?? '';
                                        await _showTextDialog(title: 'Insights', text: s);
                                      },
                                icon: meetingProvider.isGeneratingInsights
                                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                    : const Icon(Icons.insights),
                                style: dockButtonStyle,
                              ),
                              IconButton.outlined(
                                tooltip: 'Questions (long-press to regenerate)',
                                onPressed: meetingProvider.isGeneratingQuestions
                                    ? null
                                    : () async {
                                        final session = meetingProvider.currentSession;
                                        // If questions exist, show them directly
                                        if (session?.questions != null && session!.questions!.isNotEmpty) {
                                          await _showTextDialog(title: 'Suggested Questions', text: session.questions!);
                                        } else {
                                          // Generate if doesn't exist
                                          await _generateSuggestedQuestions();
                                          await _showTextDialog(title: 'Suggested Questions', text: _suggestedQuestions);
                                        }
                                      },
                                onLongPress: meetingProvider.isGeneratingQuestions
                                    ? null
                                    : () async {
                                        // Force regenerate
                                        await _generateSuggestedQuestions(regenerate: true);
                                        await _showTextDialog(title: 'Suggested Questions', text: _suggestedQuestions);
                                      },
                                icon: meetingProvider.isGeneratingQuestions
                                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                    : const Icon(Icons.help_outline),
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
                    onSubmitted: (value) => speechProvider.askAi(question: value),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              IconButton.outlined(
                tooltip: 'Templates',
                onPressed: _showQuestionTemplates,
                icon: const Icon(Icons.quiz),
                style: dockButtonStyle,
              ),
              const SizedBox(width: 10),
              IconButton.filled(
                tooltip: 'Ask (Ctrl+Enter)',
                onPressed: speechProvider.isAiLoading
                    ? null
                    : () => speechProvider.askAi(question: _askAiController.text),
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
                            tooltip: 'Insights (long-press to regenerate)',
                            onPressed: meetingProvider.isGeneratingInsights
                                ? null
                                : () async {
                                    final session = meetingProvider.currentSession;
                                    // If insights exist, show them directly
                                    if (session?.insights != null && session!.insights!.isNotEmpty) {
                                      await _showTextDialog(title: 'Insights', text: session.insights!);
                                    } else {
                                      // Generate if doesn't exist
                                      await meetingProvider.generateInsights();
                                      final s = meetingProvider.currentSession?.insights ?? '';
                                      await _showTextDialog(title: 'Insights', text: s);
                                    }
                                  },
                            onLongPress: meetingProvider.isGeneratingInsights
                                ? null
                                : () async {
                                    // Force regenerate
                                    await meetingProvider.generateInsights(regenerate: true);
                                    final s = meetingProvider.currentSession?.insights ?? '';
                                    await _showTextDialog(title: 'Insights', text: s);
                                  },
                            icon: meetingProvider.isGeneratingInsights
                                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                : const Icon(Icons.insights),
                            style: dockButtonStyle,
                          ),
                          IconButton.outlined(
                            tooltip: 'Questions (long-press to regenerate)',
                            onPressed: meetingProvider.isGeneratingQuestions
                                ? null
                                : () async {
                                    final session = meetingProvider.currentSession;
                                    // If questions exist, show them directly
                                    if (session?.questions != null && session!.questions!.isNotEmpty) {
                                      await _showTextDialog(title: 'Suggested Questions', text: session.questions!);
                                    } else {
                                      // Generate if doesn't exist
                                      await _generateSuggestedQuestions();
                                      await _showTextDialog(title: 'Suggested Questions', text: _suggestedQuestions);
                                    }
                                  },
                            onLongPress: meetingProvider.isGeneratingQuestions
                                ? null
                                : () async {
                                    // Force regenerate
                                    await _generateSuggestedQuestions(regenerate: true);
                                    await _showTextDialog(title: 'Suggested Questions', text: _suggestedQuestions);
                                  },
                            icon: meetingProvider.isGeneratingQuestions
                                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                : const Icon(Icons.help_outline),
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
                    await speechProvider.stopRecording();
                    // Save session when stopping recording via keyboard shortcut
                    if (_meetingProvider?.currentSession != null) {
                      try {
                        await _meetingProvider!.saveCurrentSession();
                      } catch (e) {
                        // Silently fail - session is auto-saved anyway
                        print('Failed to save session on stop: $e');
                      }
                    }
                  } else {
                    // Check if we should preserve existing bubbles (resume vs new)
                    final meetingProvider = context.read<MeetingProvider>();
                    final currentSession = meetingProvider.currentSession;
                    // A session is considered "saved" only if it has bubbles (content)
                    // New sessions that were just auto-saved but have no bubbles should still show "start"
                    final isSavedSession = currentSession != null && currentSession.bubbles.isNotEmpty;
                    final hasExistingBubbles = speechProvider.bubbles.isNotEmpty;
                    final shouldClear = !isSavedSession && !hasExistingBubbles;
                    speechProvider.startRecording(clearExisting: shouldClear);
                  }
                  return null;
                },
              ),
              _AskAiIntent: CallbackAction<_AskAiIntent>(
                onInvoke: (_) {
                  speechProvider.askAi(question: _askAiController.text);
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
                  // Dark background section extending from top to split line
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
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
                                      color: Colors.white,
                                      shadows: [
                                        Shadow(color: Colors.black, blurRadius: 4, offset: const Offset(1, 1)),
                                        Shadow(color: Colors.black, blurRadius: 6, offset: const Offset(-1, -1)),
                                      ],
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
                                        _modeDisplaysFuture = svc.getModeDisplays();
                                      });
                                    });
                                    return Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                      decoration: BoxDecoration(
                                        color: Colors.white.withValues(alpha: 0.1),
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(color: Colors.white.withValues(alpha: 0.3), width: 1),
                                      ),
                                      child: const SizedBox(width: 100, height: 32, child: Center(child: CircularProgressIndicator(strokeWidth: 2))),
                                    );
                                  }
                                  return FutureBuilder<List<ModeDisplay>>(
                                    future: _modeDisplaysFuture,
                                    builder: (context, snap) {
                                      if (!snap.hasData) {
                                        return Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                          decoration: BoxDecoration(
                                            color: Colors.white.withValues(alpha: 0.1),
                                            borderRadius: BorderRadius.circular(8),
                                            border: Border.all(color: Colors.white.withValues(alpha: 0.3), width: 1),
                                          ),
                                          child: const SizedBox(width: 100, height: 32, child: Center(child: CircularProgressIndicator(strokeWidth: 2))),
                                        );
                                      }
                                      final displays = snap.data!;
                                      final currentLabel = displays.where((d) => d.modeKey == currentKey).isEmpty
                                          ? 'General'
                                          : displays.firstWhere((d) => d.modeKey == currentKey).label;
                                      return Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                        decoration: BoxDecoration(
                                          color: Colors.white.withValues(alpha: 0.1),
                                          borderRadius: BorderRadius.circular(8),
                                          border: Border.all(color: Colors.white.withValues(alpha: 0.3), width: 1),
                                        ),
                                        child: PopupMenuButton<String?>(
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text(
                                                currentLabel,
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.w500,
                                                  shadows: [Shadow(color: Colors.black, blurRadius: 4, offset: Offset(1, 1))],
                                                ),
                                              ),
                                              const SizedBox(width: 4),
                                              const Icon(Icons.arrow_drop_down, color: Colors.white, size: 20),
                                            ],
                                          ),
                                          color: Colors.grey.shade900,
                                          itemBuilder: (BuildContext menuContext) {
                                            final items = <PopupMenuEntry<String?>>[];
                                            for (final d in displays) {
                                              items.add(
                                                PopupMenuItem<String?>(
                                                  value: d.modeKey,
                                                  child: Row(
                                                    mainAxisSize: MainAxisSize.min,
                                                    children: [
                                                      Icon(d.icon, size: 18, color: Colors.white),
                                                      const SizedBox(width: 8),
                                                      Text(d.label, style: const TextStyle(color: Colors.white)),
                                                      if (d.modeKey == currentKey) ...[
                                                        const Spacer(),
                                                        const Icon(Icons.check, color: Colors.white, size: 18),
                                                      ],
                                                    ],
                                                  ),
                                                ),
                                              );
                                            }
                                            items.add(const PopupMenuDivider());
                                            items.add(
                                              PopupMenuItem<String?>(
                                                enabled: false,
                                                child: InkWell(
                                                  onTap: () {
                                                    Navigator.pop(menuContext);
                                                    Navigator.push(
                                                      navigatorContext,
                                                      MaterialPageRoute(builder: (context) => const ManageModePage()),
                                                    );
                                                  },
                                                  child: const Row(
                                                    mainAxisSize: MainAxisSize.min,
                                                    children: [
                                                      Icon(Icons.settings, size: 18, color: Colors.white),
                                                      SizedBox(width: 8),
                                                      Text('Manage mode', style: TextStyle(color: Colors.white)),
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
                                color: Colors.white,
                              ),
                              PopupMenuButton(
                                icon: const Icon(Icons.more_vert, color: Colors.white),
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

class _ToggleRecordIntent extends Intent {
  const _ToggleRecordIntent();
}

class _AskAiIntent extends Intent {
  const _AskAiIntent();
}

class _SaveSessionIntent extends Intent {
  const _SaveSessionIntent();
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
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final authProvider = context.read<AuthProvider>();
      final meetingProvider = context.read<MeetingProvider>();
      // Ensure auth token is set before loading sessions
      meetingProvider.updateAuthToken(authProvider.token);
      meetingProvider.loadSessions();
    });
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    if (hours > 0) {
      return '${hours}h ${minutes}m';
    }
    return '${minutes}m';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(
        title: const Text('Meeting Sessions'),
      ),
      body: Container(
        color: Theme.of(context).colorScheme.surface,
        child: Consumer<MeetingProvider>(
        builder: (context, provider, child) {
          if (provider.isLoading && provider.sessions.isEmpty) {
            return const Center(child: CircularProgressIndicator());
          }

          if (provider.sessions.isEmpty) {
            return const Center(
              child: Text('No saved sessions'),
            );
          }

          return ListView.builder(
            itemCount: provider.sessions.length,
            itemBuilder: (context, index) {
              final session = provider.sessions[index];
              return ListTile(
                title: Text(session.title),
                subtitle: Text(
                  '${session.createdAt.toLocal().toString().substring(0, 16)} • ${_formatDuration(session.duration)}',
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.download),
                      tooltip: 'Export',
                      onPressed: () async {
                        try {
                          final text = await provider.exportSessionAsText(session.id);
                          await Clipboard.setData(ClipboardData(text: text));
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Exported to clipboard')),
                            );
                          }
                        } catch (e) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Export failed: $e')),
                            );
                          }
                        }
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete),
                      tooltip: 'Delete',
                      onPressed: () async {
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('Delete Session?'),
                            content: Text('Delete "${session.title}"?'),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context, false),
                                child: const Text('Cancel'),
                              ),
                              TextButton(
                                onPressed: () => Navigator.pop(context, true),
                                child: const Text('Delete'),
                              ),
                            ],
                          ),
                        );
                        if (confirmed == true && mounted) {
                          await provider.deleteSession(session.id);
                        }
                      },
                    ),
                  ],
                ),
                onTap: () async {
                  await provider.loadSession(session.id);
                  if (mounted) {
                    Navigator.pop(context);
                  }
                },
              );
            },
          );
        },
      ),
      ),
    );
  }
}