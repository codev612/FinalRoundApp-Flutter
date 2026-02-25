import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:highlight/highlight.dart' show highlight;
import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, Platform;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import '../config/app_config.dart';
import '../providers/speech_to_text_provider.dart';
import '../providers/meeting_provider.dart';
import '../providers/auth_provider.dart';
import '../models/meeting_session.dart';
import '../models/meeting_mode.dart';
import '../models/transcript_bubble.dart';
import '../models/ai_response_entry.dart';
import '../services/meeting_question_service.dart';
import '../services/meeting_mode_service.dart';
import '../services/ai_service.dart';
import '../services/billing_service.dart';
import '../providers/shortcuts_provider.dart';
import '../utils/error_message_helper.dart';
import 'manage_mode_page.dart';
import 'manage_question_templates_page.dart';

class MeetingPageEnhanced extends StatefulWidget {
  const MeetingPageEnhanced({super.key});

  @override
  State<MeetingPageEnhanced> createState() => _MeetingPageEnhancedState();
}

enum ScreenCaptureTarget {
  window,
  screen,
  region,
}

class _ShareableWindowInfo {
  final int hwnd;
  final String title;
  final bool isMinimized;

  const _ShareableWindowInfo({required this.hwnd, required this.title, required this.isMinimized});

  static _ShareableWindowInfo? tryParse(dynamic v) {
    if (v is! Map) return null;
    final hwnd = (v['hwnd'] as num?)?.toInt();
    final title = v['title']?.toString();
    final isMinimized = v['isMinimized'] == true;
    if (hwnd == null || hwnd <= 0) return null;
    if (title == null || title.trim().isEmpty) return null;
    return _ShareableWindowInfo(hwnd: hwnd, title: title.trim(), isMinimized: isMinimized);
  }
}

class _MonitorInfo {
  final int id;
  final int index;
  final int width;
  final int height;
  final bool isPrimary;
  final String device;

  const _MonitorInfo({
    required this.id,
    required this.index,
    required this.width,
    required this.height,
    required this.isPrimary,
    required this.device,
  });

  String get label {
    final base = 'Screen $index';
    return isPrimary ? '$base (Primary)' : base;
  }

  static _MonitorInfo? tryParse(dynamic v) {
    if (v is! Map) return null;
    final id = (v['id'] as num?)?.toInt();
    final index = (v['index'] as num?)?.toInt() ?? 0;
    final width = (v['width'] as num?)?.toInt() ?? 0;
    final height = (v['height'] as num?)?.toInt() ?? 0;
    final isPrimary = v['isPrimary'] == true;
    final device = v['device']?.toString() ?? '';
    if (id == null || id == 0) return null;
    if (index <= 0) return null;
    return _MonitorInfo(
      id: id,
      index: index,
      width: width,
      height: height,
      isPrimary: isPrimary,
      device: device,
    );
  }
}

class _PendingRegionSelection {
  final _MonitorInfo monitor;
  const _PendingRegionSelection(this.monitor);
}

class _RegionBounds {
  final int x;
  final int y;
  final int width;
  final int height;
  final int monitorId;
  final String monitorLabel;

  const _RegionBounds({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.monitorId,
    required this.monitorLabel,
  });

  Map<String, dynamic> toJson() => {
    'x': x,
    'y': y,
    'width': width,
    'height': height,
    'monitorId': monitorId,
    'monitorLabel': monitorLabel,
  };

  static _RegionBounds? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final x = (json['x'] as num?)?.toInt();
    final y = (json['y'] as num?)?.toInt();
    final w = (json['width'] as num?)?.toInt();
    final h = (json['height'] as num?)?.toInt();
    final monitorId = (json['monitorId'] as num?)?.toInt();
    final monitorLabel = json['monitorLabel']?.toString();
    if (x == null || y == null || w == null || h == null || w <= 0 || h <= 0 || monitorId == null || monitorLabel == null) return null;
    return _RegionBounds(x: x, y: y, width: w, height: h, monitorId: monitorId, monitorLabel: monitorLabel);
  }

  String get displayLabel => '${width}×$height region on $monitorLabel';
}

class _ScreenCaptureChoice {
  final ScreenCaptureTarget target;
  final _ShareableWindowInfo? window;
  final int? monitorId;
  final String? monitorLabel;
  final _RegionBounds? region;
  const _ScreenCaptureChoice._(this.target, this.window, this.monitorId, this.monitorLabel, [this.region]);
  _ScreenCaptureChoice.screenMonitor(_MonitorInfo m) : this._(ScreenCaptureTarget.screen, null, m.id, m.label);
  const _ScreenCaptureChoice.window(_ShareableWindowInfo w) : this._(ScreenCaptureTarget.window, w, null, null);
  _ScreenCaptureChoice.regionCapture(_RegionBounds r) : this._(ScreenCaptureTarget.region, null, r.monitorId, r.monitorLabel, r);
}

class _MeetingPageEnhancedState extends State<MeetingPageEnhanced> {
  final ScrollController _transcriptScrollController = ScrollController();
  final ScrollController _aiResponseScrollController = ScrollController();
  final TextEditingController _askAiController = TextEditingController();
  int _lastAiHistoryCount = 0;
  static const MethodChannel _windowChannel = MethodChannel('com.finalround/window');
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
  bool _autoAsk = false;
  bool _autoAskUseScreen = false;
  bool _screenCaptureInFlight = false;
  ScreenCaptureTarget _screenCaptureTarget = ScreenCaptureTarget.window;
  int? _screenCaptureWindowHwnd;
  String? _screenCaptureWindowTitle;
  int? _screenCaptureMonitorId; // null = all screens
  String? _screenCaptureMonitorLabel;
  _RegionBounds? _screenCaptureRegion;
  bool _showConversationControls = true;
  bool _showAiControls = true;
  bool _showConversationPanel = true;
  bool _showAiPanel = true;
  bool _isUpdatingBubbles = false; // Flag to prevent infinite loops
  MeetingModeService? _modeService;
  Future<List<ModeDisplay>>? _modeDisplaysFuture;
  VoidCallback? _modesVersionListener;
  MeetingQuestionService? _questionService;

  static const String _aiModelPrefKey = 'openai_model';
  static const String _autoAskUseScreenPrefKey = 'auto_ask_use_screen';
  static const String _screenCaptureTargetPrefKey = 'screen_capture_target';
  static const String _screenCaptureMonitorIdPrefKey = 'screen_capture_monitor_id';
  static const String _screenCaptureMonitorLabelPrefKey = 'screen_capture_monitor_label';
  static const String _screenCaptureRegionPrefKey = 'screen_capture_region';
  String _selectedAiModel = 'gpt-4.1-mini';

  BillingService? _billingService;
  BillingInfo? _billingInfo;
  String? _billingError;
  int? _recordingRunStartRemainingMs;
  static const _inactivityAutoStopMinutes = 5;
  bool _inactivityStopTriggered = false;
  bool _limitStopTriggered = false;
  String _lastAiErrorShown = '';

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

      await _loadAiModel();
      await _loadAutoAskUseScreen();
      await _loadScreenCaptureTarget();
      await _loadScreenCaptureMonitorSelection();
      await _loadScreenCaptureRegion();
      
      final authToken = authProvider.token;
      _billingService = BillingService()..setAuthToken(authToken);
      await _refreshBilling();

      _questionService = MeetingQuestionService()..setAuthToken(authToken);
      _speechProvider!.initialize(
        wsUrl: AppConfig.serverWebSocketUrl,
        httpBaseUrl: AppConfig.serverHttpBaseUrl,
        authToken: authToken,
      );
      
      // Set up plan update callback to refresh billing info when plan changes
      _speechProvider!.setOnPlanUpdated(() {
        if (mounted) {
          _refreshBilling();
        }
      });
      
      // Set up callback to persist AI responses to the current session
      _speechProvider!.setOnAiResponseCompleted((response) {
        _meetingProvider?.addAiResponseToSession(response);
      });
      
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

  Future<void> _loadScreenCaptureTarget() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_screenCaptureTargetPrefKey);
      ScreenCaptureTarget next = ScreenCaptureTarget.window;
      if (saved == 'screen') next = ScreenCaptureTarget.screen;
      if (saved == 'region') next = ScreenCaptureTarget.region;
      if (!mounted) {
        _screenCaptureTarget = next;
        return;
      }
      setState(() => _screenCaptureTarget = next);
    } catch (_) {
      // Ignore preference failures.
    }
  }

  Future<void> _loadScreenCaptureRegion() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_screenCaptureRegionPrefKey);
      if (saved == null || saved.isEmpty) return;
      final json = jsonDecode(saved) as Map<String, dynamic>?;
      final region = _RegionBounds.fromJson(json);
      if (region == null) return;
      if (!mounted) {
        _screenCaptureRegion = region;
        return;
      }
      setState(() => _screenCaptureRegion = region);
    } catch (_) {
      // Ignore preference failures.
    }
  }

  Future<void> _setScreenCaptureRegion(_RegionBounds? region) async {
    if (!mounted) {
      _screenCaptureRegion = region;
    } else {
      setState(() => _screenCaptureRegion = region);
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      if (region == null) {
        await prefs.remove(_screenCaptureRegionPrefKey);
      } else {
        await prefs.setString(_screenCaptureRegionPrefKey, jsonEncode(region.toJson()));
      }
    } catch (_) {
      // Ignore preference failures.
    }
  }

  Future<void> _setScreenCaptureTarget(ScreenCaptureTarget target) async {
    if (!mounted) {
      _screenCaptureTarget = target;
    } else {
      setState(() => _screenCaptureTarget = target);
    }
    if (target == ScreenCaptureTarget.screen) {
      // Window handle is only meaningful for window capture.
      _screenCaptureWindowHwnd = null;
      _screenCaptureWindowTitle = null;
    }
    if (target != ScreenCaptureTarget.region) {
      _screenCaptureRegion = null;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      String value = 'window';
      if (target == ScreenCaptureTarget.screen) value = 'screen';
      if (target == ScreenCaptureTarget.region) value = 'region';
      await prefs.setString(_screenCaptureTargetPrefKey, value);
    } catch (_) {
      // Ignore preference failures.
    }
  }

  Future<void> _loadScreenCaptureMonitorSelection() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final idText = prefs.getString(_screenCaptureMonitorIdPrefKey);
      final label = prefs.getString(_screenCaptureMonitorLabelPrefKey);
      final parsed = idText == null || idText.trim().isEmpty ? null : int.tryParse(idText.trim());
      if (!mounted) {
        _screenCaptureMonitorId = parsed;
        _screenCaptureMonitorLabel = label;
        return;
      }
      setState(() {
        _screenCaptureMonitorId = parsed;
        _screenCaptureMonitorLabel = label;
      });
    } catch (_) {
      // Ignore preference failures.
    }
  }

  Future<void> _setScreenCaptureMonitorSelection({required int? monitorId, required String? monitorLabel}) async {
    if (!mounted) {
      _screenCaptureMonitorId = monitorId;
      _screenCaptureMonitorLabel = monitorLabel;
    } else {
      setState(() {
        _screenCaptureMonitorId = monitorId;
        _screenCaptureMonitorLabel = monitorLabel;
      });
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_screenCaptureMonitorIdPrefKey, monitorId == null ? '' : monitorId.toString());
      await prefs.setString(_screenCaptureMonitorLabelPrefKey, (monitorLabel ?? '').trim());
    } catch (_) {
      // Ignore preference failures.
    }
  }

  Future<List<_MonitorInfo>> _listMonitors() async {
    final raw = await _windowChannel.invokeMethod<dynamic>('listMonitors');
    if (raw is! List) return const [];
    return raw.map(_MonitorInfo.tryParse).whereType<_MonitorInfo>().toList(growable: false);
  }

  Future<List<_ShareableWindowInfo>> _listShareableWindows() async {
    final raw = await _windowChannel.invokeMethod<dynamic>('listShareableWindows');
    if (raw is! List) return const [];
    final windows = raw.map(_ShareableWindowInfo.tryParse).whereType<_ShareableWindowInfo>().toList(growable: false);
    return windows;
  }

  Future<void> _showScreenCapturePicker() async {
    if (!Platform.isWindows) return;
    final result = await showDialog<dynamic>(
      context: context,
      barrierDismissible: true,
      builder: (context) {
        return _ScreenCapturePickerDialog(
          initialTarget: _screenCaptureTarget,
          initialWindowHwnd: _screenCaptureWindowHwnd,
          initialMonitorId: _screenCaptureMonitorId,
          initialRegion: _screenCaptureRegion,
          loadMonitors: _listMonitors,
          loadWindows: _listShareableWindows,
        );
      },
    );
    if (!mounted || result == null) return;

    // Handle pending region selection (user clicked "Select Screen Region")
    if (result is _PendingRegionSelection) {
      final region = await _launchRegionSelector(result.monitor);
      if (!mounted || region == null) return;
      await _setScreenCaptureTarget(ScreenCaptureTarget.region);
      await _setScreenCaptureRegion(region);
      return;
    }

    final choice = result as _ScreenCaptureChoice;

    if (choice.target == ScreenCaptureTarget.region) {
      final region = choice.region;
      if (region == null) return;
      await _setScreenCaptureTarget(ScreenCaptureTarget.region);
      await _setScreenCaptureRegion(region);
      return;
    }

    if (choice.target == ScreenCaptureTarget.screen) {
      await _setScreenCaptureTarget(ScreenCaptureTarget.screen);
      await _setScreenCaptureMonitorSelection(
        monitorId: choice.monitorId,
        monitorLabel: choice.monitorLabel,
      );
      return;
    }

    final w = choice.window;
    if (w == null) return;
    await _setScreenCaptureTarget(ScreenCaptureTarget.window);
    setState(() {
      _screenCaptureWindowHwnd = w.hwnd;
      _screenCaptureWindowTitle = w.title;
    });
  }

  Future<_RegionBounds?> _launchRegionSelector(_MonitorInfo monitor) async {
    if (!mounted) return null;
    
    // Get virtual screen bounds
    final screenBounds = await _windowChannel.invokeMethod<dynamic>('getVirtualScreenBounds');
    if (screenBounds is! Map) {
      return null;
    }
    
    final screenX = (screenBounds['x'] as num?)?.toInt() ?? 0;
    final screenY = (screenBounds['y'] as num?)?.toInt() ?? 0;
    final screenWidth = (screenBounds['width'] as num?)?.toInt() ?? 0;
    final screenHeight = (screenBounds['height'] as num?)?.toInt() ?? 0;
    
    if (screenWidth <= 0 || screenHeight <= 0) return null;
    
    // Capture screenshot of entire virtual screen for selection preview
    final screenshotPixels = await _windowChannel.invokeMethod<dynamic>(
      'captureRectPixels',
      <String, dynamic>{
        'x': screenX,
        'y': screenY,
        'width': screenWidth,
        'height': screenHeight,
      },
    );
    
    if (screenshotPixels is! Map) return null;
    
    final imgWidth = (screenshotPixels['width'] as num?)?.toInt() ?? 0;
    final imgHeight = (screenshotPixels['height'] as num?)?.toInt() ?? 0;
    final imgBytes = screenshotPixels['bytes'];
    
    if (imgWidth <= 0 || imgHeight <= 0 || imgBytes is! Uint8List) return null;
    
    // Decode the screenshot
    final screenshot = await _decodeBgraToImage(imgBytes, imgWidth, imgHeight);
    
    // Show region selector dialog with the screenshot
    final region = await showDialog<_RegionBounds>(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black87,
      builder: (context) => _RegionSelectorDialog(
        monitor: monitor,
        screenshot: screenshot,
        screenOffsetX: screenX,
        screenOffsetY: screenY,
        screenWidth: screenWidth,
        screenHeight: screenHeight,
      ),
    );
    
    screenshot.dispose();
    return region;
  }

  /// Launch the built-in screenshot tool (like Windows Snipping Tool)
  Future<void> _launchScreenshotTool() async {
    if (!mounted || !Platform.isWindows) return;

    try {
      // 1. Make our window undetectable first (won't appear in screenshot)
      await _windowChannel.invokeMethod<void>('setUndetectable', true);
      
      // 2. Get screen bounds
      final screenBounds = await _windowChannel.invokeMethod<dynamic>('getVirtualScreenBounds');
      if (screenBounds is! Map) {
        await _windowChannel.invokeMethod<void>('setUndetectable', false);
        return;
      }
      
      final screenX = (screenBounds['x'] as num?)?.toInt() ?? 0;
      final screenY = (screenBounds['y'] as num?)?.toInt() ?? 0;
      final screenWidth = (screenBounds['width'] as num?)?.toInt() ?? 0;
      final screenHeight = (screenBounds['height'] as num?)?.toInt() ?? 0;
      
      if (screenWidth <= 0 || screenHeight <= 0) {
        await _windowChannel.invokeMethod<void>('setUndetectable', false);
        return;
      }
      
      // 3. Capture screenshot (our window won't appear because it's undetectable)
      final screenshotPixels = await _windowChannel.invokeMethod<dynamic>(
        'captureRectPixels',
        <String, dynamic>{
          'x': screenX,
          'y': screenY,
          'width': screenWidth,
          'height': screenHeight,
        },
      );
      
      if (screenshotPixels is! Map) {
        await _windowChannel.invokeMethod<void>('setUndetectable', false);
        return;
      }
      
      final imgWidth = (screenshotPixels['width'] as num?)?.toInt() ?? 0;
      final imgHeight = (screenshotPixels['height'] as num?)?.toInt() ?? 0;
      final imgBytes = screenshotPixels['bytes'];
      
      if (imgWidth <= 0 || imgHeight <= 0 || imgBytes is! Uint8List) {
        await _windowChannel.invokeMethod<void>('setUndetectable', false);
        return;
      }
      
      // 4. Decode the screenshot while still in normal mode
      final screenshot = await _decodeBgraToImage(imgBytes, imgWidth, imgHeight);
      
      if (!mounted) {
        screenshot.dispose();
        await _windowChannel.invokeMethod<void>('setUndetectable', false);
        return;
      }
      
      // 5. Enter fullscreen mode for region selection (instant transition)
      await _windowChannel.invokeMethod<void>('enterRegionSelectorMode');
      
      // 6. Show fullscreen screenshot selector overlay (no transition for instant feel)
      // Note: The overlay will dispose the screenshot when it's removed from the tree
      final selectedRegion = await Navigator.of(context).push<Rect>(
        PageRouteBuilder<Rect>(
          opaque: false,
          barrierColor: Colors.transparent,
          pageBuilder: (context, animation, secondaryAnimation) => _ScreenshotToolOverlay(
            screenshot: screenshot,
            screenshotBytes: imgBytes,
            screenOffsetX: screenX,
            screenOffsetY: screenY,
            screenWidth: screenWidth,
            screenHeight: screenHeight,
          ),
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
        ),
      );
      
      // 7. Exit region selector mode and restore window
      await _windowChannel.invokeMethod<void>('exitRegionSelectorMode');
      
      // 8. If a region was selected, it's already been copied to clipboard by the overlay
      if (selectedRegion != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Screenshot copied to clipboard'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      // Make sure we restore the window on any error
      try {
        await _windowChannel.invokeMethod<void>('exitRegionSelectorMode');
        await _windowChannel.invokeMethod<void>('setUndetectable', false);
      } catch (_) {}
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Screenshot failed: $e'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  Future<void> _loadAutoAskUseScreen() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getBool(_autoAskUseScreenPrefKey);
      if (saved == null) return;
      if (!mounted) {
        _autoAskUseScreen = saved;
        return;
      }
      setState(() => _autoAskUseScreen = saved);
    } catch (_) {
      // Ignore preference failures.
    }
  }

  Future<void> _setAutoAskUseScreen(bool value) async {
    if (!mounted) {
      _autoAskUseScreen = value;
    } else {
      setState(() => _autoAskUseScreen = value);
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_autoAskUseScreenPrefKey, value);
    } catch (_) {
      // Ignore preference failures.
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
    _aiResponseScrollController.dispose();
    _askAiController.dispose();
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
        final remainingMs = _currentRemainingBillingMs(speechProvider);
        if (remainingMs != null &&
            remainingMs <= 0 &&
            !_limitStopTriggered &&
            !speechProvider.isStopping) {
          _limitStopTriggered = true;
          Future.microtask(() async {
            if (!mounted) return;
            await _stopRecordingDueToLimit();
          });
        }
        // Auto-stop if no transcription detected for 5 minutes
        final lastActivity = speechProvider.lastTranscriptOrRecordingStartTime;
        if (lastActivity != null &&
            !_inactivityStopTriggered &&
            !speechProvider.isStopping &&
            DateTime.now().difference(lastActivity) >= const Duration(minutes: _inactivityAutoStopMinutes)) {
          _inactivityStopTriggered = true;
          Future.microtask(() async {
            if (!mounted) return;
            await _stopRecordingDueToInactivity();
          });
        }
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

  int _effectiveRemainingMinutes(BillingInfo info) {
    // Use server's remainingMinutes; fallback to limit - used if inconsistent
    var rem = info.remainingMinutes;
    if (rem < 0 || rem > info.limitMinutes) {
      rem = (info.limitMinutes - info.usedMinutes).clamp(0, info.limitMinutes);
    }
    return rem;
  }

  int? _currentRemainingBillingMs(SpeechToTextProvider? speechProvider) {
    final info = _billingInfo;
    if (info == null) return null;

    // Base remaining (minutes granularity from server)
    final baseRemainingMs = _effectiveRemainingMinutes(info) * 60 * 1000;

    if (speechProvider == null || !speechProvider.isRecording) return baseRemainingMs;
    final startRemainingMs = _recordingRunStartRemainingMs;
    if (startRemainingMs == null) return baseRemainingMs;

    // Decrease only when transcription activity is happening (not silence).
    final usedMs = speechProvider.transcriptionUsageMsThisRun;
    final remaining = startRemainingMs - usedMs;
    return remaining > 0 ? remaining : 0;
  }

  String _formatRemainingMs(int ms) {
    if (ms <= 0) return '0m 00s';
    final totalSeconds = (ms / 1000).floor();
    final minutes = (totalSeconds / 60).floor();
    final seconds = totalSeconds % 60;
    return '${minutes}m ${seconds.toString().padLeft(2, '0')}s';
  }

  Future<void> _recordUsageForCurrentRunAndRefresh() async {
    _recordingRunStartRemainingMs = null;
    _limitStopTriggered = false;
    _inactivityStopTriggered = false;

    final usedMs = _speechProvider?.transcriptionUsageMsThisRun ?? 0;
    if (usedMs <= 0) return;

    try {
      await _billingService?.recordTranscriptionUsage(
        durationMs: usedMs,
        sessionId: _meetingProvider?.currentSession?.id,
      );
    } catch (_) {}

    try {
      await _refreshBilling();
    } catch (_) {}
  }

  Future<void> _stopRecordingDueToInactivity() async {
    await _recordUsageForCurrentRunAndRefresh();

    final speechProvider = _speechProvider;
    if (speechProvider == null) return;
    if (!speechProvider.isRecording || speechProvider.isStopping) return;

    try {
      speechProvider.stopRecording().catchError((_) {});
    } catch (_) {}

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('No transcription detected for $_inactivityAutoStopMinutes minutes. Recording stopped.')),
    );
  }

  Future<void> _stopRecordingDueToLimit() async {
    // Best-effort: record what we used so far, stop recording, and inform the user.
    await _recordUsageForCurrentRunAndRefresh();

    final speechProvider = _speechProvider;
    if (speechProvider == null) return;
    if (!speechProvider.isRecording || speechProvider.isStopping) return;

    try {
      speechProvider.stopRecording().catchError((_) {});
    } catch (_) {}

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Transcription limit reached. Recording stopped.')),
    );
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
    bool showWhatShouldISayButton = false,
    VoidCallback? onWhatShouldISayPressed,
    bool showCopyButton = false,
    VoidCallback? onCopyPressed,
  }) {
    final isMe = source == TranscriptSource.mic;
    final isSystem = source == TranscriptSource.system;
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
                const SizedBox(height: 6),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Align(
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
                    ),
                    if (isSystem && (showCopyButton || showWhatShouldISayButton)) ...[
                      const SizedBox(width: 8),
                      if (showCopyButton) ...[
                        Tooltip(
                          message: 'Copy text',
                          child: IconButton(
                            onPressed: onCopyPressed,
                            icon: const Icon(Icons.content_copy, size: 16),
                            tooltip: 'Copy',
                            style: IconButton.styleFrom(
                              foregroundColor: Colors.white,
                              backgroundColor: Colors.black.withValues(alpha: 0.18),
                              minimumSize: const Size(32, 32),
                              padding: EdgeInsets.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(999),
                                side: BorderSide(color: Colors.white.withValues(alpha: 0.18)),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                      if (showWhatShouldISayButton)
                        Tooltip(
                          message: 'What should I say?',
                          child: IconButton(
                            onPressed: onWhatShouldISayPressed,
                            icon: const Icon(Icons.lightbulb_outline, size: 18),
                            tooltip: 'What should I say',
                            style: IconButton.styleFrom(
                              foregroundColor: Colors.white,
                              backgroundColor: Colors.black.withValues(alpha: 0.18),
                              minimumSize: const Size(32, 32),
                              padding: EdgeInsets.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(999),
                                side: BorderSide(color: Colors.white.withValues(alpha: 0.18)),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ],
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

  Future<void> _loadAiModel() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_aiModelPrefKey);
      if (saved != null && saved.trim().isNotEmpty) {
        if (mounted) {
          setState(() {
            _selectedAiModel = saved.trim();
          });
        } else {
          _selectedAiModel = saved.trim();
        }
      }
    } catch (e) {
      // Ignore failures; default will be used.
    }
  }

  Future<void> _setAiModel(String model) async {
    final trimmed = model.trim();
    if (trimmed.isEmpty) return;
    if (mounted) {
      setState(() {
        _selectedAiModel = trimmed;
      });
    } else {
      _selectedAiModel = trimmed;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_aiModelPrefKey, trimmed);
    } catch (e) {
      // Ignore persistence failures; selection still applies for this run.
    }
  }

  Future<void> _refreshBilling() async {
    final svc = _billingService;
    if (svc == null) return;
    try {
      final info = await svc.getMe();
      if (!mounted) return;
      setState(() {
        _billingInfo = info;
        _billingError = null;
      });

      // If selected model is not allowed in this plan, snap to first allowed model.
      final allowed = info.allowedModels;
      final selected = _selectedAiModel.trim();
      if (allowed.isNotEmpty && selected.toLowerCase() != 'auto' && !allowed.contains(selected)) {
        await _setAiModel(allowed.first);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _billingError = e.toString();
      });
    }
  }

  String _formatModelLabel(String model) {
    // Keep user-friendly display while preserving exact model value for API calls.
    if (model.trim().toLowerCase() == 'auto') return 'AUTO';
    if (model.startsWith('gpt-')) {
      return model.replaceAll('-', ' ').toUpperCase();
    }
    return model;
  }

  static const double _modelMenuItemHeight = 36.0;

  List<PopupMenuEntry<String>> _buildModelMenuItems() {
    final allowed = _billingInfo?.allowedModels;
    final models = (allowed != null && allowed.isNotEmpty)
        ? allowed
        : <String>['gpt-5.2', 'gpt-5', 'gpt-5.1', 'gpt-4.1', 'gpt-4.1-mini', 'gpt-4o', 'gpt-4o-mini'];

    final items = <PopupMenuEntry<String>>[];
    items.add(
      PopupMenuItem(
        value: 'auto',
        height: _modelMenuItemHeight,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Text(
          'AUTO',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 13),
        ),
      ),
    );
    items.add(const PopupMenuDivider());
    for (final m in models) {
      items.add(
        PopupMenuItem(
          value: m,
          height: _modelMenuItemHeight,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            _formatModelLabel(m),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 13),
          ),
        ),
      );
    }
    return items;
  }

  Widget _buildModelMenuButton({required bool disabled, required ButtonStyle style}) {
    final label = _selectedAiModel.trim().isEmpty ? 'Model' : _selectedAiModel.trim();
    final displayLabel = _formatModelLabel(label);
    
    return Tooltip(
      message: 'Current model: $displayLabel\nClick to change',
      child: PopupMenuButton<String>(
        enabled: !disabled,
        tooltip: 'Select model',
        onSelected: (value) async {
          await _setAiModel(value);
        },
        itemBuilder: (context) => _buildModelMenuItems(),
        child: Container(
          width: 104,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
              color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.tune, size: 14),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  displayLabel,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _askAiWithPrompt(String? question, {String? displayQuestion, List<Uint8List>? imagesPngBytes}) async {
    if (_speechProvider == null || _speechProvider!.isAiLoading) return;
    final systemPrompt = await _getRealTimePrompt();
    final wantsScreen = _autoAskUseScreen && Platform.isWindows;

    List<Uint8List>? pngBytesList = imagesPngBytes;
    if ((pngBytesList == null || pngBytesList.isEmpty) && wantsScreen && !_screenCaptureInFlight) {
      _screenCaptureInFlight = true;
      try {
        final screenCapture = await _tryCaptureSelectedTargetPngBytes();
        if (screenCapture != null) {
          pngBytesList = [screenCapture];
        }
      } finally {
        _screenCaptureInFlight = false;
      }
    }

    // Get previous AI responses from current session (up to 3 most recent)
    final previousResponses = _meetingProvider?.currentSession?.aiResponses;
    
    _speechProvider!.askAi(
      question: question,
      displayQuestion: displayQuestion,
      systemPrompt: systemPrompt,
      model: _selectedAiModel,
      imagesPngBytes: pngBytesList,
      previousResponses: previousResponses,
    );
  }

  /// Find the latest question from system bubbles up to and including [bubbleIndex].
  /// Looks at up to [maxChars] characters and returns the most recent complete question found.
  String? _findLatestQuestion(
    List<TranscriptBubble> bubbles,
    int bubbleIndex,
    int maxChars,
  ) {
    if (bubbleIndex < 0 || bubbleIndex >= bubbles.length) {
      return null;
    }

    // Collect text from system bubbles, starting from current and going backwards
    final textParts = <String>[];
    int totalChars = 0;
    
    for (int i = bubbleIndex; i >= 0 && totalChars < maxChars; i--) {
      final bubble = bubbles[i];
      // Only include system bubbles (the other person's speech)
      if (bubble.source == TranscriptSource.system) {
        final text = bubble.text.trim();
        if (text.isNotEmpty) {
          textParts.insert(0, text); // Insert at beginning to maintain order
          totalChars += text.length;
        }
      }
    }
    
    final contextText = textParts.join(' ');
    
    // Find the last question mark position
    final lastQMark = contextText.lastIndexOf('?');
    if (lastQMark == -1) {
      return null;
    }
    
    // Find the start of this question by looking backwards for sentence boundaries
    // A sentence typically starts after . ! ? or at the beginning of text
    int questionStart = 0;
    for (int i = lastQMark - 1; i >= 0; i--) {
      final char = contextText[i];
      // Stop at period or exclamation only if followed by space and capital letter
      // This handles cases like "forward? And" where "And" continues the question
      if (char == '.' || char == '!') {
        // Check if this is really a sentence end (not abbreviation, etc.)
        if (i + 2 < contextText.length) {
          final nextNonSpace = contextText.substring(i + 1).trimLeft();
          if (nextNonSpace.isNotEmpty) {
            final firstChar = nextNonSpace[0];
            // If next word starts with lowercase or is a continuation word, keep going
            final continuationWords = ['and', 'or', 'but', 'so', 'because', 'which', 'that', 'who', 'what', 'how'];
            final nextWord = nextNonSpace.split(RegExp(r'\s+')).first.toLowerCase();
            if (firstChar.toUpperCase() != firstChar || continuationWords.contains(nextWord)) {
              continue; // Not a real sentence boundary, keep looking
            }
          }
        }
        questionStart = i + 1;
        break;
      }
    }
    
    // Extract the question from start to last question mark (inclusive)
    String question = contextText.substring(questionStart, lastQMark + 1).trim();
    
    // Clean up - remove leading punctuation/whitespace
    question = question.replaceFirst(RegExp(r'^[.,;:\s]+'), '');
    
    if (question.length > 5) {
      return question;
    }
    
    return null;
  }

  Widget _buildUseScreenCheckboxInline() {
    if (!Platform.isWindows) return const SizedBox.shrink();

    final labelStyle = TextStyle(
      fontSize: 13,
      color: Colors.white,
      shadows: const [
        Shadow(color: Colors.black, blurRadius: 4, offset: Offset(1, 1)),
        Shadow(color: Colors.black, blurRadius: 6, offset: Offset(-1, -1)),
      ],
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: 'Include a screenshot (window or screen) when asking AI',
          child: Checkbox(
            value: _autoAskUseScreen,
            onChanged: (value) async {
              await _setAutoAskUseScreen(value ?? false);
              _updateAutoAskCallback();
            },
            visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
        Text('Use screen', style: labelStyle),
      ],
    );
  }

  Widget _buildModelAndUseScreenColumn({
    required bool disabled,
    required ButtonStyle style,
  }) {
    final model = _buildModelMenuButton(disabled: disabled, style: style);
    if (!Platform.isWindows) return model;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        model,
        const SizedBox(height: 2),
        _buildUseScreenCheckboxInline(),
      ],
    );
  }

  /// Build AI response history panel showing all responses
  Widget _buildAiResponseContent(String currentText, MeetingProvider? meetingProvider, SpeechToTextProvider? speechProvider) {
    final isLoading = speechProvider?.isAiLoading ?? false;
    
    // Get history from current session
    final history = meetingProvider?.currentSession?.aiResponses ?? [];
    
    // If no history and no current response, show placeholder
    if (history.isEmpty && currentText.isEmpty && !isLoading) {
      return const Center(
        child: Text(
          'AI response will appear here...',
          style: TextStyle(
            color: Colors.white54,
            fontStyle: FontStyle.italic,
          ),
        ),
      );
    }

    // Auto-scroll to bottom when new messages arrive or during streaming
    final currentCount = history.length + (isLoading ? 1 : 0);
    if (currentCount != _lastAiHistoryCount || isLoading) {
      _lastAiHistoryCount = currentCount;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_aiResponseScrollController.hasClients) {
          _aiResponseScrollController.animateTo(
            _aiResponseScrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      });
    }

    // History is stored newest-first, but we want to display oldest-first (newest at bottom)
    final reversedHistory = history.reversed.toList();
    final hasStreamingResponse = isLoading && currentText.isNotEmpty;

    return Column(
      children: [
        // Clear history button when there's history
        if (history.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(
                  '${history.length} response${history.length > 1 ? 's' : ''}',
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 12,
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () {
                    meetingProvider?.clearSessionAiHistory();
                  },
                  icon: const Icon(Icons.clear_all, size: 16),
                  label: const Text('Clear'),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white54,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
          ),
        
        // History list (oldest first, newest at bottom)
        Expanded(
          child: ListView.builder(
            controller: _aiResponseScrollController,
            itemCount: reversedHistory.length + (hasStreamingResponse ? 1 : 0),
            itemBuilder: (context, index) {
              // Show completed history entries first
              if (index < reversedHistory.length) {
                final entry = reversedHistory[index];
                return _buildAiResponseEntry(
                  question: entry.question,
                  response: entry.response,
                  timestamp: entry.timestamp,
                  hasImages: entry.hasImages,
                  isStreaming: false,
                );
              }
              
              // Show streaming response at the bottom (last item)
              return _buildAiResponseEntry(
                question: 'Processing...',
                response: currentText,
                timestamp: DateTime.now(),
                hasImages: false,
                isStreaming: true,
              );
            },
          ),
        ),
      ],
    );
  }

  /// Build a single AI response entry
  Widget _buildAiResponseEntry({
    required String question,
    required String response,
    required DateTime timestamp,
    required bool hasImages,
    required bool isStreaming,
  }) {
    final timeStr = '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}';
    
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isStreaming ? Colors.lightBlueAccent.withValues(alpha: 0.5) : Colors.white12,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Question header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(7)),
            ),
            child: Row(
              children: [
                Icon(
                  hasImages ? Icons.image : Icons.question_answer,
                  size: 14,
                  color: Colors.white54,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    question.isNotEmpty ? question : '(No question)',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                if (isStreaming)
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  )
                else
                  Text(
                    timeStr,
                    style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 11,
                    ),
                  ),
              ],
            ),
          ),
          // Response content
          Padding(
            padding: const EdgeInsets.all(12),
            child: _buildMarkdownContent(response),
          ),
        ],
      ),
    );
  }

  /// Build markdown content for a single response
  Widget _buildMarkdownContent(String text) {
    if (text.isEmpty) {
      return const Text(
        'No response',
        style: TextStyle(
          color: Colors.white54,
          fontStyle: FontStyle.italic,
        ),
      );
    }

    try {
      return Markdown(
      data: text,
      selectable: true,
      softLineBreak: true,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      styleSheet: MarkdownStyleSheet(
        p: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          height: 1.5,
        ),
        h1: const TextStyle(
          color: Colors.white,
          fontSize: 24,
          fontWeight: FontWeight.bold,
        ),
        h2: const TextStyle(
          color: Colors.white,
          fontSize: 20,
          fontWeight: FontWeight.bold,
        ),
        h3: const TextStyle(
          color: Colors.white,
          fontSize: 18,
          fontWeight: FontWeight.bold,
        ),
        h4: const TextStyle(
          color: Colors.white,
          fontSize: 16,
          fontWeight: FontWeight.bold,
        ),
        strong: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
        ),
        em: const TextStyle(
          color: Colors.white,
          fontStyle: FontStyle.italic,
        ),
        code: TextStyle(
          color: Colors.lightBlueAccent,
          backgroundColor: Colors.black.withValues(alpha: 0.3),
          fontFamily: 'monospace',
          fontSize: 13,
        ),
        codeblockDecoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white24),
        ),
        codeblockPadding: const EdgeInsets.all(12),
        blockquote: const TextStyle(
          color: Colors.white70,
          fontStyle: FontStyle.italic,
        ),
        blockquoteDecoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          border: const Border(
            left: BorderSide(color: Colors.white38, width: 4),
          ),
        ),
        listBullet: const TextStyle(color: Colors.white),
        tableHead: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
        ),
        tableBody: const TextStyle(color: Colors.white),
        tableBorder: TableBorder.all(color: Colors.white30),
        horizontalRuleDecoration: const BoxDecoration(
          border: Border(
            top: BorderSide(color: Colors.white30, width: 1),
          ),
        ),
        a: const TextStyle(
          color: Colors.lightBlueAccent,
          decoration: TextDecoration.underline,
        ),
      ),
      builders: {
        'code': _CodeBlockBuilder(),
      },
    );
    } catch (e) {
      // Fallback to plain text if markdown parsing fails
      return SelectableText(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          height: 1.5,
        ),
      );
    }
  }

  Widget _buildCaptureTargetPickerPill() {
    if (!Platform.isWindows) return const SizedBox.shrink();

    String pillLabel;
    IconData pillIcon;
    switch (_screenCaptureTarget) {
      case ScreenCaptureTarget.screen:
        pillLabel = _screenCaptureMonitorLabel?.isNotEmpty == true ? _screenCaptureMonitorLabel! : 'Choose screen…';
        pillIcon = Icons.desktop_windows;
        break;
      case ScreenCaptureTarget.region:
        pillLabel = _screenCaptureRegion?.displayLabel ?? 'Choose region…';
        pillIcon = Icons.crop;
        break;
      case ScreenCaptureTarget.window:
        pillLabel = _screenCaptureWindowTitle?.isNotEmpty == true ? _screenCaptureWindowTitle! : 'Choose window…';
        pillIcon = Icons.crop_free;
        break;
    }

    // On desktop, InkWell hover/highlight paints on the nearest Material. If that Material
    // is the whole conversation header, hover can visually overlap the "Ready" label.
    // Give the pill its own clipped Material surface.
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 150),
      child: SizedBox(
        height: 26,
        child: Material(
          color: Colors.transparent,
          clipBehavior: Clip.antiAlias,
          borderRadius: BorderRadius.circular(999),
          child: Ink(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
            ),
            child: InkWell(
              onTap: _showScreenCapturePicker,
              hoverColor: Colors.white.withValues(alpha: 0.08),
              highlightColor: Colors.white.withValues(alpha: 0.06),
              splashColor: Colors.white.withValues(alpha: 0.10),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      pillIcon,
                      size: 14,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        pillLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(width: 2),
                    const Icon(Icons.arrow_drop_down, color: Colors.white, size: 16),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<Uint8List?> _tryCaptureSelectedTargetPngBytes() async {
    try {
      dynamic pixels;
      if (_screenCaptureTarget == ScreenCaptureTarget.region) {
        final region = _screenCaptureRegion;
        if (region == null) return null;
        pixels = await _windowChannel.invokeMethod<dynamic>(
          'captureRectPixels',
          <String, dynamic>{
            'x': region.x,
            'y': region.y,
            'width': region.width,
            'height': region.height,
          },
        );
      } else if (_screenCaptureTarget == ScreenCaptureTarget.screen) {
        var monitorId = _screenCaptureMonitorId;
        if (monitorId == null) {
          final monitors = await _listMonitors();
          if (monitors.isNotEmpty) {
            // Default capture target: Screen 1 (index == 1) if available.
            final preferred = monitors.firstWhere(
              (m) => m.index == 1,
              orElse: () => monitors.reduce((a, b) => a.index <= b.index ? a : b),
            );
            monitorId = preferred.id;
            await _setScreenCaptureMonitorSelection(monitorId: preferred.id, monitorLabel: preferred.label);
          }
        }
        if (monitorId == null) return null;
        pixels = await _windowChannel.invokeMethod<dynamic>(
          'captureMonitorPixels',
          <String, dynamic>{'monitorId': monitorId},
        );
      } else if (_screenCaptureWindowHwnd != null) {
        pixels = await _windowChannel.invokeMethod<dynamic>(
          'captureWindowPixels',
          <String, dynamic>{'hwnd': _screenCaptureWindowHwnd},
        );
      } else {
        pixels = await _windowChannel.invokeMethod<dynamic>('captureActiveWindowPixels');
      }
      if (pixels is! Map) return null;
      final width = (pixels['width'] as num?)?.toInt() ?? 0;
      final height = (pixels['height'] as num?)?.toInt() ?? 0;
      final bytes = pixels['bytes'];
      if (width <= 0 || height <= 0 || bytes is! Uint8List || bytes.isEmpty) return null;

      final image = await _decodeBgraToImage(bytes, width, height);
      ui.Image toEncode = image;

      // Downscale large captures to keep requests fast + within JSON limits.
      const maxDim = 1600;
      if (image.width > maxDim || image.height > maxDim) {
        final sx = maxDim / image.width;
        final sy = maxDim / image.height;
        final scale = sx < sy ? sx : sy;
        final newW = (image.width * scale).round().clamp(1, maxDim);
        final newH = (image.height * scale).round().clamp(1, maxDim);
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        final paint = Paint()..filterQuality = FilterQuality.medium;
        canvas.drawImageRect(
          image,
          Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
          Rect.fromLTWH(0, 0, newW.toDouble(), newH.toDouble()),
          paint,
        );
        final picture = recorder.endRecording();
        final resized = await picture.toImage(newW, newH);
        picture.dispose();
        image.dispose();
        toEncode = resized;
      }

      final byteData = await toEncode.toByteData(format: ui.ImageByteFormat.png);
      toEncode.dispose();
      return byteData?.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }

  Future<ui.Image> _decodeBgraToImage(Uint8List bgraBytes, int width, int height) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      bgraBytes,
      width,
      height,
      ui.PixelFormat.bgra8888,
      (img) => completer.complete(img),
    );
    return completer.future;
  }
  
  void _updateAutoAskCallback() {
    if (_speechProvider == null) return;
    if (_autoAsk) {
      // Set callback to auto-ask when question is detected
      _speechProvider!.setAutoAskCallback((question) async {
        if (!mounted) return;
        await _askAiWithPrompt(question);
      });
    } else {
      // Remove callback when auto ask is disabled
      _speechProvider!.setAutoAskCallback(null);
    }
  }

  void _askQuestionFromTemplate(String question) {
    if (_speechProvider != null && !_speechProvider!.isAiLoading) {
      _askAiWithPrompt(question);
      // Focus conversation on the current question (last part of history)
      _scrollTranscriptToBottom();
    }
  }

  /// Scrolls the transcript list to the bottom so the last message (current question) is in view.
  void _scrollTranscriptToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_transcriptScrollController.hasClients) return;
      final position = _transcriptScrollController.position;
      final target = position.maxScrollExtent;
      _transcriptScrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _showAskAiDialog() async {
    if (!mounted) return;
    if (_speechProvider?.isAiLoading == true) return;

    final result = await showDialog<_AskAiDialogResult>(
      context: context,
      builder: (context) => _AskAiDialog(controller: _askAiController),
    );

    if (!mounted) return;
    if (result == null) return;
    
    final q = result.question.trim();
    final images = result.allImageBytes;
    await _askAiWithPrompt(
      q.isEmpty ? null : q,
      imagesPngBytes: images.isNotEmpty ? images : null,
    );
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
          SnackBar(content: Text(ErrorMessageHelper.toUserFriendly(e))),
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
        final isSystemBubble = b.source == TranscriptSource.system;
        final hasText = b.text.trim().isNotEmpty;
        final canSuggestReply = isSystemBubble && hasText;
        final canCopy = isSystemBubble && hasText;
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
          showWhatShouldISayButton: canSuggestReply,
          showCopyButton: canCopy,
          onCopyPressed: !canCopy
              ? null
              : () async {
                  await Clipboard.setData(ClipboardData(text: b.text));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Copied')),
                  );
                },
          onWhatShouldISayPressed: !canSuggestReply || speechProvider.isAiLoading
              ? null
              : () async {
                  // Find the latest question up to and including this bubble
                  final latestQuestion = _findLatestQuestion(bubbles, index, 500);
                  
                  String displayText;
                  String promptText;
                  
                  if (latestQuestion != null) {
                    // Found a question - answer it
                    displayText = latestQuestion;
                    promptText = 'Answer this question: $latestQuestion';
                  } else {
                    // No question found, just respond to the bubble text
                    final bubbleText = b.text.trim();
                    displayText = bubbleText.length > 300 ? '${bubbleText.substring(0, 300)}...' : bubbleText;
                    promptText = 'What should I say in response to: "$displayText"';
                  }
                  
                  await _askAiWithPrompt(
                    promptText,
                    displayQuestion: displayText,
                  );
                },
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
          height: Platform.isWindows ? 64.0 : dockButtonSize,
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
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Use mic checkbox
                        Checkbox(
                          value: speechProvider.useMic,
                          onChanged: (value) {
                            final newValue = value ?? false;
                            _speechProvider?.setUseMic(newValue);
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
                        if (Platform.isWindows) ...[
                          const SizedBox(width: 12),
                          _buildCaptureTargetPickerPill(),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
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
                                        // Record transcription usage (best-effort) for billing.
                                        Future.microtask(() async {
                                          await _recordUsageForCurrentRunAndRefresh();
                                        });
                                        
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
                                onPressed: () async {
                                  // Don't clear bubbles when resuming a saved session
                                  final shouldClear = !isSavedSession && !hasExistingBubbles;
                                  // Check minutes before starting (best-effort). If billing is unavailable, allow start.
                                  try {
                                    if (_billingInfo == null) {
                                      await _refreshBilling();
                                    }
                                    final remaining = _billingInfo != null ? _effectiveRemainingMinutes(_billingInfo!) : null;
                                    if (remaining != null && remaining <= 0) {
                                      if (!mounted) return;
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(content: Text('You have no transcription minutes left. Upgrade to continue.')),
                                      );
                                      return;
                                    }
                                  } catch (_) {}

                                  _recordingRunStartRemainingMs = (_billingInfo != null ? _effectiveRemainingMinutes(_billingInfo!) : 0) * 60 * 1000;
                                  _limitStopTriggered = false;
                                  _inactivityStopTriggered = false;
                                  speechProvider.startRecording(clearExisting: shouldClear, useMic: speechProvider.useMic);
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
                            if (Platform.isWindows)
                              IconButton.outlined(
                                onPressed: _launchScreenshotTool,
                                tooltip: 'Screenshot (Ctrl+Shift+S)',
                                icon: const Icon(Icons.screenshot_outlined),
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
          // Quick ask controls ABOVE the AI response field (same as two-column)
          SizedBox(
            height: Platform.isWindows ? 64.0 : dockButtonSize,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
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
                _buildModelAndUseScreenColumn(
                  disabled: speechProvider.isAiLoading,
                  style: templatesButtonStyle,
                ),
                const SizedBox(width: 10),
                IconButton.filled(
                  tooltip: 'Ask… (Ctrl+Enter)',
                  onPressed: speechProvider.isAiLoading
                      ? null
                      : _showAskAiDialog,
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
                  child: _buildAiResponseContent(speechProvider.aiResponse, meetingProvider, speechProvider),
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
                                        // Enforce plan locally (server enforces too)
                                        if (_billingInfo != null && _billingInfo!.canUseSummary == false) {
                                          if (!mounted) return;
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            const SnackBar(content: Text('Upgrade required to generate summaries.')),
                                          );
                                          return;
                                        }
                                        final session = meetingProvider.currentSession;
                                        // If summary exists, show it directly
                                        if (session?.summary != null && session!.summary!.isNotEmpty) {
                                          await _showTextDialog(title: 'Summary', text: session.summary!);
                                        } else {
                                          // Generate if doesn't exist
                                          await meetingProvider.generateSummary(model: _selectedAiModel);
                                          final s = meetingProvider.currentSession?.summary ?? '';
                                          await _showTextDialog(title: 'Summary', text: s);
                                        }
                                      },
                                onLongPress: meetingProvider.isGeneratingSummary
                                    ? null
                                    : () async {
                                        if (_billingInfo != null && _billingInfo!.canUseSummary == false) {
                                          if (!mounted) return;
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            const SnackBar(content: Text('Upgrade required to generate summaries.')),
                                          );
                                          return;
                                        }
                                        // Force regenerate
                                        await meetingProvider.generateSummary(regenerate: true, model: _selectedAiModel);
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
        // Quick ask controls ABOVE the AI response field
        SizedBox(
          height: Platform.isWindows ? 64.0 : dockButtonSize,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
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
              _buildModelAndUseScreenColumn(
                disabled: speechProvider.isAiLoading,
                style: templatesButtonStyle,
              ),
              const SizedBox(width: 10),
              IconButton.filled(
                tooltip: 'Ask… (Ctrl+Enter)',
                onPressed: speechProvider.isAiLoading
                    ? null
                    : _showAskAiDialog,
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
                child: _buildAiResponseContent(speechProvider.aiResponse, meetingProvider, speechProvider),
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
                                    if (_billingInfo != null && _billingInfo!.canUseSummary == false) {
                                      if (!mounted) return;
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(content: Text('Upgrade required to generate summaries.')),
                                      );
                                      return;
                                    }
                                    final session = meetingProvider.currentSession;
                                    // If summary exists, show it directly
                                    if (session?.summary != null && session!.summary!.isNotEmpty) {
                                      await _showTextDialog(title: 'Summary', text: session.summary!);
                                    } else {
                                      // Generate if doesn't exist
                                      await meetingProvider.generateSummary(model: _selectedAiModel);
                                      final s = meetingProvider.currentSession?.summary ?? '';
                                      await _showTextDialog(title: 'Summary', text: s);
                                    }
                                  },
                            onLongPress: meetingProvider.isGeneratingSummary
                                ? null
                                : () async {
                                    if (_billingInfo != null && _billingInfo!.canUseSummary == false) {
                                      if (!mounted) return;
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(content: Text('Upgrade required to generate summaries.')),
                                      );
                                      return;
                                    }
                                    // Force regenerate
                                    await meetingProvider.generateSummary(regenerate: true, model: _selectedAiModel);
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

        final rawErr = speechProvider.aiErrorMessage.trim();
        if (rawErr.isNotEmpty && rawErr != _lastAiErrorShown) {
          _lastAiErrorShown = rawErr;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            final cleaned = rawErr.replaceFirst(RegExp(r'^\s*Exception:\s*'), '').trim();
            final msg = cleaned.isNotEmpty ? cleaned : 'AI request failed';
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(msg),
                action: msg.toLowerCase().contains('upgrade')
                    ? SnackBarAction(
                        label: 'Upgrade',
                        onPressed: () {
                          // No dedicated upgrade page wired yet; keep it as a clear hint.
                        },
                      )
                    : null,
              ),
            );
          });
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
        
        // Screenshot shortcut (Ctrl+Shift+S) - Windows only
        if (Platform.isWindows) {
          shortcuts[const SingleActivator(LogicalKeyboardKey.keyS, control: true, shift: true)] = const _ScreenshotIntent();
        }

        return Shortcuts(
          shortcuts: shortcuts,
          child: Actions(
            actions: <Type, Action<Intent>>{
              _ToggleRecordIntent: CallbackAction<_ToggleRecordIntent>(
                onInvoke: (_) async {
                  if (speechProvider.isRecording) {
                    if (!mounted || speechProvider.isStopping) return null;
                    
                    // Record transcription usage (best-effort) for billing.
                    Future.microtask(() async {
                      await _recordUsageForCurrentRunAndRefresh();
                    });

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
                    // Check minutes before starting (best-effort). If billing is unavailable, allow start.
                    try {
                      if (_billingInfo == null) {
                        await _refreshBilling();
                      }
                      final remaining = _billingInfo != null ? _effectiveRemainingMinutes(_billingInfo!) : null;
                      if (remaining != null && remaining <= 0) {
                        if (!mounted) return null;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('You have no transcription minutes left. Upgrade to continue.')),
                        );
                        return null;
                      }
                    } catch (_) {}

                    _recordingRunStartRemainingMs = (_billingInfo != null ? _effectiveRemainingMinutes(_billingInfo!) : 0) * 60 * 1000;
                    _limitStopTriggered = false;
                    _inactivityStopTriggered = false;
                    speechProvider.startRecording(clearExisting: shouldClear, useMic: speechProvider.useMic);
                  }
                  return null;
                },
              ),
              _AskAiIntent: CallbackAction<_AskAiIntent>(
                onInvoke: (_) {
                  _showAskAiDialog();
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
              _ScreenshotIntent: CallbackAction<_ScreenshotIntent>(
                onInvoke: (_) {
                  if (Platform.isWindows) _launchScreenshotTool();
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
                                  child: Row(
                                    children: [
                                      Expanded(
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
                                      if (_billingInfo != null) ...[
                                        const SizedBox(width: 10),
                                        Tooltip(
                                          message: 'Transcription time remaining',
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                            decoration: BoxDecoration(
                                              color: Theme.of(context).colorScheme.surfaceContainerHighest,
                                              borderRadius: BorderRadius.circular(999),
                                              border: Border.all(
                                                color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3),
                                              ),
                                            ),
                                            child: Text(
                                              '${_formatRemainingMs(_currentRemainingBillingMs(speechProvider) ?? (_effectiveRemainingMinutes(_billingInfo!) * 60 * 1000))} left',
                                              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                                    fontWeight: FontWeight.w600,
                                                    color: Theme.of(context).colorScheme.onSurface,
                                                  ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],
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
  static const double _menuItemHeight = 36.0;
  
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
            height: _menuItemHeight,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            value: question,
            child: Text(
              question,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 13),
            ),
          );
        }),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          height: _menuItemHeight,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          value: '__manage_templates__',
          child: Row(
            children: [
              Icon(Icons.settings, size: 18, color: Theme.of(context).colorScheme.onSurface),
              const SizedBox(width: 8),
              Text(
                'Manage Templates',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 13),
              ),
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

class _ScreenCapturePickerDialog extends StatefulWidget {
  final ScreenCaptureTarget initialTarget;
  final int? initialWindowHwnd;
  final int? initialMonitorId; // null = all screens
  final _RegionBounds? initialRegion;
  final Future<List<_MonitorInfo>> Function() loadMonitors;
  final Future<List<_ShareableWindowInfo>> Function() loadWindows;

  const _ScreenCapturePickerDialog({
    required this.initialTarget,
    required this.initialWindowHwnd,
    required this.initialMonitorId,
    required this.initialRegion,
    required this.loadMonitors,
    required this.loadWindows,
  });

  @override
  State<_ScreenCapturePickerDialog> createState() => _ScreenCapturePickerDialogState();
}

class _ScreenCapturePickerDialogState extends State<_ScreenCapturePickerDialog> {
  late ScreenCaptureTarget _target;
  int? _selectedHwnd;
  int? _selectedMonitorId; // null = all screens
  String? _selectedMonitorLabel;
  _RegionBounds? _selectedRegion;
  Future<Map<String, dynamic>>? _dataFuture;
  final Map<String, ui.Image> _previews = {};
  final Set<String> _previewLoading = {};

  @override
  void initState() {
    super.initState();
    _target = widget.initialTarget;
    _selectedHwnd = widget.initialWindowHwnd;
    _selectedMonitorId = widget.initialMonitorId;
    _selectedRegion = widget.initialRegion;
    _dataFuture = _loadAll();
  }

  Future<Map<String, dynamic>> _loadAll() async {
    final results = await Future.wait<dynamic>([
      widget.loadMonitors(),
      widget.loadWindows(),
    ]);
    final monitors = (results[0] as List<_MonitorInfo>?) ?? const <_MonitorInfo>[];
    final windows = (results[1] as List<_ShareableWindowInfo>?) ?? const <_ShareableWindowInfo>[];
    return {'monitors': monitors, 'windows': windows};
  }

  @override
  void dispose() {
    for (final img in _previews.values) {
      img.dispose();
    }
    _previews.clear();
    super.dispose();
  }

  void _refresh() {
    setState(() {
      _dataFuture = _loadAll();
    });
  }

  Future<ui.Image?> _decodeBgra(dynamic pixels) async {
    if (pixels is! Map) return null;
    final w = (pixels['width'] as num?)?.toInt() ?? 0;
    final h = (pixels['height'] as num?)?.toInt() ?? 0;
    final bytes = pixels['bytes'];
    if (w <= 0 || h <= 0 || bytes is! Uint8List || bytes.isEmpty) return null;
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(bytes, w, h, ui.PixelFormat.bgra8888, (img) => completer.complete(img));
    return completer.future;
  }

  Future<void> _ensurePreview(String key, Future<dynamic> Function() loader) async {
    if (_previews.containsKey(key)) return;
    if (_previewLoading.contains(key)) return;
    _previewLoading.add(key);
    try {
      final pixels = await loader();
      if (!mounted) return;
      final img = await _decodeBgra(pixels);
      if (img == null) return;
      if (!mounted) {
        img.dispose();
        return;
      }
      setState(() {
        _previews[key] = img;
      });
    } catch (_) {
      // Ignore preview failures; keep placeholder.
    } finally {
      _previewLoading.remove(key);
    }
  }

  Widget _windowTile(_ShareableWindowInfo w) {
    final selected = _target == ScreenCaptureTarget.window && _selectedHwnd == w.hwnd;
    final cs = Theme.of(context).colorScheme;

    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      leading: Icon(
        w.isMinimized ? Icons.minimize : Icons.crop_free,
        color: w.isMinimized ? cs.onSurface.withValues(alpha: 0.55) : cs.onSurface,
        size: 18,
      ),
      title: Text(
        w.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
      ),
      subtitle: w.isMinimized
          ? Text(
              'Minimized',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: cs.onSurface.withValues(alpha: 0.65),
                  ),
            )
          : null,
      trailing: selected ? Icon(Icons.check, color: cs.primary, size: 18) : null,
      selected: selected,
      selectedTileColor: cs.primary.withValues(alpha: 0.08),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      onTap: () {
        setState(() {
          _target = ScreenCaptureTarget.window;
          _selectedHwnd = w.hwnd;
        });
      },
    );
  }

  Widget _screenTileMonitor(_MonitorInfo m) {
    final selected = _target == ScreenCaptureTarget.screen && _selectedMonitorId == m.id;
    final key = 'monitor:${m.id}';
    final preview = _previews[key];
    if (preview == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _ensurePreview(
          key,
          () => _MeetingPageEnhancedState._windowChannel.invokeMethod<dynamic>(
            'captureMonitorThumbnailPixels',
            <String, dynamic>{'monitorId': m.id, 'maxWidth': 360, 'maxHeight': 225},
          ),
        );
      });
    }
    return _screenTileBase(
      selected: selected,
      title: m.label,
      subtitle: '${m.width}×${m.height}',
      icon: Icons.monitor,
      preview: preview,
      onTap: () {
        setState(() {
          _target = ScreenCaptureTarget.screen;
          _selectedHwnd = null;
          _selectedMonitorId = m.id;
          _selectedMonitorLabel = m.label;
        });
      },
    );
  }

  Widget _screenTileBase({
    required bool selected,
    required String title,
    required String subtitle,
    required IconData icon,
    required ui.Image? preview,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? Theme.of(context).colorScheme.primary : Theme.of(context).dividerColor,
            width: selected ? 2 : 1,
          ),
          color: Theme.of(context).colorScheme.surface,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (preview != null)
                      Container(
                        color: Colors.black,
                        alignment: Alignment.center,
                        child: RawImage(image: preview, fit: BoxFit.contain),
                      )
                    else
                      Container(
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        child: Center(
                          child: Icon(
                            icon,
                            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                      ),
                    if (selected)
                      Align(
                        alignment: Alignment.topRight,
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.55),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: const Icon(Icons.check, color: Colors.white, size: 16),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                        ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRegionSection(List<_MonitorInfo> monitors) {
    final cs = Theme.of(context).colorScheme;
    final hasRegion = _selectedRegion != null;
    final isSelected = _target == ScreenCaptureTarget.region && hasRegion;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasRegion)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: InkWell(
              onTap: () {
                setState(() {
                  _target = ScreenCaptureTarget.region;
                  _selectedHwnd = null;
                });
              },
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isSelected ? cs.primary : cs.outline.withValues(alpha: 0.3),
                    width: isSelected ? 2 : 1,
                  ),
                  color: isSelected ? cs.primary.withValues(alpha: 0.08) : null,
                ),
                child: Row(
                  children: [
                    Icon(Icons.crop, color: cs.onSurface, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _selectedRegion!.displayLabel,
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          Text(
                            'Position: (${_selectedRegion!.x}, ${_selectedRegion!.y})',
                            style: Theme.of(context).textTheme.labelSmall?.copyWith(color: cs.onSurface.withValues(alpha: 0.65)),
                          ),
                        ],
                      ),
                    ),
                    if (isSelected)
                      Icon(Icons.check, color: cs.primary, size: 18),
                  ],
                ),
              ),
            ),
          ),
        OutlinedButton.icon(
          onPressed: monitors.isEmpty ? null : () async {
            final monitor = monitors.length == 1
                ? monitors.first
                : monitors.firstWhere((m) => m.isPrimary, orElse: () => monitors.first);
            // Close the dialog and pass a special marker to indicate region selection needed
            Navigator.pop(context, _PendingRegionSelection(monitor));
          },
          icon: const Icon(Icons.crop),
          label: Text(hasRegion ? 'Select New Region' : 'Select Screen Region'),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            'Selection overlay is hidden from screen sharing',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: cs.onSurface.withValues(alpha: 0.5),
              fontStyle: FontStyle.italic,
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          const Expanded(child: Text('Choose what to capture')),
          IconButton(
            tooltip: 'Refresh',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      content: SizedBox(
        width: 560,
        height: 420,
        child: FutureBuilder<Map<String, dynamic>>(
          future: _dataFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            final data = snapshot.data ?? const <String, dynamic>{};
            final monitors = (data['monitors'] as List<_MonitorInfo>?) ?? const <_MonitorInfo>[];
            final windows = (data['windows'] as List<_ShareableWindowInfo>?) ?? const <_ShareableWindowInfo>[];

            if (_selectedMonitorId == null && monitors.isNotEmpty) {
              // Default to "Screen 1" for sharing (matches label "Screen 1").
              final preferred = monitors.firstWhere(
                (m) => m.index == 1,
                orElse: () => monitors.reduce((a, b) => a.index <= b.index ? a : b),
              );
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                if (_selectedMonitorId != null) return;
                setState(() {
                  _target = ScreenCaptureTarget.screen;
                  _selectedHwnd = null;
                  _selectedMonitorId = preferred.id;
                  _selectedMonitorLabel = preferred.label;
                });
              });
            }

            return CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Screens',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                if (monitors.isEmpty)
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('No screens found.'),
                    ),
                  )
                else
                  SliverGrid(
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                      childAspectRatio: 1.25,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, i) => _screenTileMonitor(monitors[i]),
                      childCount: monitors.length,
                    ),
                  ),
                const SliverToBoxAdapter(child: SizedBox(height: 16)),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Screen Region',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: _buildRegionSection(monitors),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 16)),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Windows',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                if (windows.isEmpty)
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('No windows found. Focus another app and press Refresh.'),
                    ),
                  )
                else
                  SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, i) => _windowTile(windows[i]),
                      childCount: windows.length,
                    ),
                  ),
                const SliverToBoxAdapter(child: SizedBox(height: 8)),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () async {
            if (_target == ScreenCaptureTarget.region) {
              final region = _selectedRegion;
              if (region == null) return;
              Navigator.pop(context, _ScreenCaptureChoice.regionCapture(region));
              return;
            }
            if (_target == ScreenCaptureTarget.screen) {
              if (_selectedMonitorId == null || _selectedMonitorLabel == null) return;
              Navigator.pop(
                context,
                _ScreenCaptureChoice._(ScreenCaptureTarget.screen, null, _selectedMonitorId, _selectedMonitorLabel),
              );
              return;
            }
            final hwnd = _selectedHwnd;
            if (hwnd == null) return;
            final data = await (_dataFuture ?? _loadAll());
            final windows = (data['windows'] as List<_ShareableWindowInfo>?) ?? const <_ShareableWindowInfo>[];
            final win = windows.where((w) => w.hwnd == hwnd).cast<_ShareableWindowInfo?>().firstWhere((w) => w != null, orElse: () => null);
            if (win == null) return;
            Navigator.pop(context, _ScreenCaptureChoice.window(win));
          },
          child: const Text('Share'),
        ),
      ],
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

class _ScreenshotIntent extends Intent {
  const _ScreenshotIntent();
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

/// Dialog for selecting a screen region on a captured screenshot.
class _RegionSelectorDialog extends StatefulWidget {
  final _MonitorInfo monitor;
  final ui.Image screenshot;
  final int screenOffsetX;
  final int screenOffsetY;
  final int screenWidth;
  final int screenHeight;

  const _RegionSelectorDialog({
    required this.monitor,
    required this.screenshot,
    required this.screenOffsetX,
    required this.screenOffsetY,
    required this.screenWidth,
    required this.screenHeight,
  });

  @override
  State<_RegionSelectorDialog> createState() => _RegionSelectorDialogState();
}

class _RegionSelectorDialogState extends State<_RegionSelectorDialog> {
  Offset? _startPoint;
  Offset? _currentPoint;
  bool _isDragging = false;
  final GlobalKey _imageKey = GlobalKey();

  Rect? get _selectionRect {
    if (_startPoint == null || _currentPoint == null) return null;
    return Rect.fromPoints(_startPoint!, _currentPoint!);
  }

  void _onPanStart(DragStartDetails details) {
    setState(() {
      _startPoint = details.localPosition;
      _currentPoint = details.localPosition;
      _isDragging = true;
    });
  }

  void _onPanUpdate(DragUpdateDetails details) {
    setState(() {
      _currentPoint = details.localPosition;
    });
  }

  void _onPanEnd(DragEndDetails details) {
    final rect = _selectionRect;
    if (rect == null || rect.width < 30 || rect.height < 30) {
      setState(() {
        _startPoint = null;
        _currentPoint = null;
        _isDragging = false;
      });
      return;
    }

    // Get the render box to calculate scale factor
    final renderBox = _imageKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final displaySize = renderBox.size;
    final scaleX = widget.screenWidth / displaySize.width;
    final scaleY = widget.screenHeight / displaySize.height;

    // Convert from display coordinates to actual screen coordinates
    final region = _RegionBounds(
      x: (rect.left * scaleX).round() + widget.screenOffsetX,
      y: (rect.top * scaleY).round() + widget.screenOffsetY,
      width: (rect.width * scaleX).round(),
      height: (rect.height * scaleY).round(),
      monitorId: widget.monitor.id,
      monitorLabel: widget.monitor.label,
    );
    Navigator.of(context).pop(region);
  }

  void _cancel() {
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final maxWidth = screenSize.width * 0.9;
    final maxHeight = screenSize.height * 0.85;

    // Calculate display size maintaining aspect ratio
    final aspectRatio = widget.screenWidth / widget.screenHeight;
    double displayWidth = maxWidth;
    double displayHeight = displayWidth / aspectRatio;
    if (displayHeight > maxHeight) {
      displayHeight = maxHeight;
      displayWidth = displayHeight * aspectRatio;
    }

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header
          Container(
            width: displayWidth,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            ),
            child: Row(
              children: [
                const Icon(Icons.crop, size: 20),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Drag to select a region',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                  ),
                ),
                if (_selectionRect != null && _selectionRect!.width >= 30 && _selectionRect!.height >= 30)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '${(_selectionRect!.width * widget.screenWidth / displayWidth).round()} × ${(_selectionRect!.height * widget.screenHeight / displayHeight).round()}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: _cancel,
                  icon: const Icon(Icons.close),
                  tooltip: 'Cancel',
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
          // Screenshot with selection overlay
          Container(
            width: displayWidth,
            height: displayHeight,
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).dividerColor),
            ),
            child: Stack(
              key: _imageKey,
              children: [
                // Screenshot
                Positioned.fill(
                  child: RawImage(
                    image: widget.screenshot,
                    fit: BoxFit.fill,
                  ),
                ),
                // Gesture detector
                Positioned.fill(
                  child: GestureDetector(
                    onPanStart: _onPanStart,
                    onPanUpdate: _onPanUpdate,
                    onPanEnd: _onPanEnd,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.precise,
                      child: Container(color: Colors.transparent),
                    ),
                  ),
                ),
                // Dimming mask outside selection
                if (_selectionRect != null)
                  ..._buildDimmingMask(_selectionRect!, Size(displayWidth, displayHeight)),
                // Selection rectangle
                if (_selectionRect != null)
                  Positioned.fromRect(
                    rect: _selectionRect!,
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.blue, width: 2),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // Footer
          Container(
            width: displayWidth,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _cancel,
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildDimmingMask(Rect selection, Size containerSize) {
    const dimColor = Color(0x99000000);

    return [
      // Top
      if (selection.top > 0)
        Positioned(
          left: 0,
          top: 0,
          right: 0,
          height: selection.top.clamp(0, containerSize.height),
          child: Container(color: dimColor),
        ),
      // Bottom
      if (selection.bottom < containerSize.height)
        Positioned(
          left: 0,
          top: selection.bottom.clamp(0, containerSize.height),
          right: 0,
          bottom: 0,
          child: Container(color: dimColor),
        ),
      // Left
      if (selection.left > 0)
        Positioned(
          left: 0,
          top: selection.top.clamp(0, containerSize.height),
          width: selection.left.clamp(0, containerSize.width),
          height: (selection.bottom - selection.top).clamp(0, containerSize.height),
          child: Container(color: dimColor),
        ),
      // Right
      if (selection.right < containerSize.width)
        Positioned(
          left: selection.right.clamp(0, containerSize.width),
          top: selection.top.clamp(0, containerSize.height),
          right: 0,
          height: (selection.bottom - selection.top).clamp(0, containerSize.height),
          child: Container(color: dimColor),
        ),
    ];
  }
}

/// Attached file info
class _AttachedFile {
  final String name;
  final Uint8List bytes;

  const _AttachedFile({required this.name, required this.bytes});
}

/// Result from the Ask AI dialog
class _AskAiDialogResult {
  final String question;
  final List<_AttachedFile> attachments;

  const _AskAiDialogResult({required this.question, this.attachments = const []});
  
  /// All attachment image bytes as a list
  List<Uint8List> get allImageBytes => attachments.map((a) => a.bytes).toList();
}

/// Enhanced Ask AI dialog with multiple file attachment support
class _AskAiDialog extends StatefulWidget {
  final TextEditingController controller;

  const _AskAiDialog({required this.controller});

  @override
  State<_AskAiDialog> createState() => _AskAiDialogState();
}

class _AskAiDialogState extends State<_AskAiDialog> {
  static const MethodChannel _windowChannel = MethodChannel('com.finalround/window');
  final List<_AttachedFile> _attachments = [];
  static const int _maxAttachments = 10;

  @override
  void initState() {
    super.initState();
    widget.controller.clear();
  }

  Future<void> _pickFiles() async {
    if (_attachments.length >= _maxAttachments) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Maximum 10 attachments allowed')),
        );
      }
      return;
    }
    
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: true,
        withData: true,
      );

      if (result != null && result.files.isNotEmpty) {
        for (final file in result.files) {
          if (_attachments.length >= _maxAttachments) break;
          
          Uint8List? bytes;
          if (file.bytes != null) {
            bytes = file.bytes;
          } else if (file.path != null) {
            bytes = await File(file.path!).readAsBytes();
          }
          
          if (bytes != null) {
            final pngBytes = await _convertToPng(bytes, file.name);
            setState(() {
              _attachments.add(_AttachedFile(name: file.name, bytes: pngBytes));
            });
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to pick file: $e')),
        );
      }
    }
  }

  Future<Uint8List> _convertToPng(Uint8List bytes, String fileName) async {
    final ext = fileName.toLowerCase();
    if (ext.endsWith('.png')) return bytes;
    
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (byteData != null) {
        return byteData.buffer.asUint8List();
      }
    } catch (_) {}
    return bytes;
  }

  Future<void> _handlePaste() async {
    try {
      // First try to paste text from clipboard
      final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
      final pastedText = clipboardData?.text?.trim();
      if (pastedText != null && pastedText.isNotEmpty) {
        final c = widget.controller;
        final start = c.selection.start.clamp(0, c.text.length);
        final end = c.selection.end.clamp(0, c.text.length);
        final newText = c.text.replaceRange(start, end, pastedText);
        c.text = newText;
        c.selection = TextSelection.collapsed(offset: start + pastedText.length);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Text pasted'), duration: Duration(seconds: 1)),
          );
        }
        return;
      }

      // No text: try to paste image (Windows)
      if (_attachments.length >= _maxAttachments) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Maximum 10 attachments allowed')),
          );
        }
        return;
      }
      if (!Platform.isWindows) return;

      final result = await _windowChannel.invokeMethod<dynamic>('getClipboardImage');
      if (result is Map) {
        final bytes = result['bytes'];
        final width = (result['width'] as num?)?.toInt() ?? 0;
        final height = (result['height'] as num?)?.toInt() ?? 0;

        if (bytes is Uint8List && bytes.isNotEmpty && width > 0 && height > 0) {
          final completer = Completer<ui.Image>();
          ui.decodeImageFromPixels(
            bytes, width, height, ui.PixelFormat.bgra8888,
            (img) => completer.complete(img),
          );
          final image = await completer.future;
          final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();

          if (byteData != null) {
            final pngBytes = byteData.buffer.asUint8List();
            final name = 'pasted_${_attachments.length + 1}.png';
            setState(() {
              _attachments.add(_AttachedFile(name: name, bytes: pngBytes));
            });
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Image pasted'), duration: Duration(seconds: 1)),
              );
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Paste error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Paste failed: $e')),
        );
      }
    }
  }

  Future<void> _handleCopy() async {
    final c = widget.controller;
    final start = c.selection.start.clamp(0, c.text.length);
    final end = c.selection.end.clamp(0, c.text.length);
    final text = start < end
        ? c.text.substring(start, end)
        : c.text.trim();
    if (text.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Nothing to copy'), duration: Duration(seconds: 1)),
        );
      }
      return;
    }
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Copied to clipboard'), duration: Duration(seconds: 1)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Copy failed: $e')),
        );
      }
    }
  }

  void _removeAttachment(int index) {
    setState(() {
      _attachments.removeAt(index);
    });
  }

  void _clearAllAttachments() {
    setState(() {
      _attachments.clear();
    });
  }

  void _submit() {
    Navigator.pop(
      context,
      _AskAiDialogResult(
        question: widget.controller.text.trim(),
        attachments: List.from(_attachments),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.auto_awesome, size: 24),
          const SizedBox(width: 8),
          const Expanded(child: Text('Ask AI')),
          if (_attachments.isNotEmpty) ...[
            Text(
              '${_attachments.length}/$_maxAttachments',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: cs.onSurface.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              onPressed: _clearAllAttachments,
              icon: const Icon(Icons.clear_all, size: 20),
              tooltip: 'Clear all attachments',
              visualDensity: VisualDensity.compact,
            ),
          ],
          IconButton(
            onPressed: _attachments.length >= _maxAttachments ? null : _pickFiles,
            icon: const Icon(Icons.add_photo_alternate),
            tooltip: 'Add images',
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            onPressed: _handleCopy,
            icon: const Icon(Icons.copy),
            tooltip: 'Copy text (Ctrl+C)',
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            onPressed: _attachments.length >= _maxAttachments ? null : _handlePaste,
            icon: const Icon(Icons.content_paste),
            tooltip: 'Paste text or image (Ctrl+V)',
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
      content: SizedBox(
        width: 550,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Attachments grid - small thumbnails
            if (_attachments.isNotEmpty) ...[
              Container(
                constraints: const BoxConstraints(maxHeight: 100),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (int i = 0; i < _attachments.length; i++)
                        Padding(
                          padding: EdgeInsets.only(right: i < _attachments.length - 1 ? 8 : 0),
                          child: _buildThumbnail(i, _attachments[i], cs),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            // Text input
            Focus(
              onKeyEvent: (node, event) {
                if (event is! KeyDownEvent) return KeyEventResult.ignored;
                final isMod = HardwareKeyboard.instance.isControlPressed ||
                    HardwareKeyboard.instance.isMetaPressed;
                if (event.logicalKey == LogicalKeyboardKey.keyV && isMod) {
                  _handlePaste();
                  return KeyEventResult.handled;
                }
                if (event.logicalKey == LogicalKeyboardKey.keyC && isMod) {
                  _handleCopy();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: TextField(
                controller: widget.controller,
                autofocus: true,
                maxLines: 6,
                minLines: 4,
                decoration: InputDecoration(
                  hintText: _attachments.isNotEmpty
                      ? 'Ask a question about ${_attachments.length == 1 ? "this image" : "these images"}...'
                      : 'Type a question or leave empty to ask about the conversation...',
                  border: const OutlineInputBorder(),
                  alignLabelWithHint: true,
                  helperText: 'Tip: Copy/paste text with Ctrl+C / Ctrl+V; paste images with Ctrl+V or drag & drop',
                  helperStyle: TextStyle(color: cs.onSurface.withValues(alpha: 0.5)),
                ),
                textInputAction: TextInputAction.newline,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _submit,
          icon: const Icon(Icons.send, size: 18),
          label: const Text('Ask'),
        ),
      ],
    );
  }

  Widget _buildThumbnail(int index, _AttachedFile file, ColorScheme cs) {
    return Stack(
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: cs.outline.withValues(alpha: 0.3)),
            color: cs.surfaceContainerHighest,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(7),
            child: Image.memory(
              file.bytes,
              width: 72,
              height: 72,
              fit: BoxFit.cover,
            ),
          ),
        ),
        Positioned(
          top: 2,
          right: 2,
          child: GestureDetector(
            onTap: () => _removeAttachment(index),
            child: Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: cs.error,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.close, size: 14, color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }
}

/// Fullscreen screenshot tool overlay (like Windows Snipping Tool)
class _ScreenshotToolOverlay extends StatefulWidget {
  final ui.Image screenshot;
  final Uint8List screenshotBytes;
  final int screenOffsetX;
  final int screenOffsetY;
  final int screenWidth;
  final int screenHeight;

  const _ScreenshotToolOverlay({
    required this.screenshot,
    required this.screenshotBytes,
    required this.screenOffsetX,
    required this.screenOffsetY,
    required this.screenWidth,
    required this.screenHeight,
  });

  @override
  State<_ScreenshotToolOverlay> createState() => _ScreenshotToolOverlayState();
}

class _ScreenshotToolOverlayState extends State<_ScreenshotToolOverlay> {
  static const MethodChannel _windowChannel = MethodChannel('com.finalround/window');
  final FocusNode _focusNode = FocusNode();
  Offset? _startPoint;
  Offset? _currentPoint;
  bool _isDragging = false;

  @override
  void dispose() {
    _focusNode.dispose();
    widget.screenshot.dispose();
    super.dispose();
  }

  Rect? get _selectionRect {
    if (_startPoint == null || _currentPoint == null) return null;
    return Rect.fromPoints(_startPoint!, _currentPoint!);
  }

  void _onPanStart(DragStartDetails details) {
    setState(() {
      _startPoint = details.localPosition;
      _currentPoint = details.localPosition;
      _isDragging = true;
    });
  }

  void _onPanUpdate(DragUpdateDetails details) {
    setState(() {
      _currentPoint = details.localPosition;
    });
  }

  void _onPanEnd(DragEndDetails details) async {
    final rect = _selectionRect;
    if (rect == null || rect.width < 10 || rect.height < 10) {
      setState(() {
        _startPoint = null;
        _currentPoint = null;
        _isDragging = false;
      });
      return;
    }

    // Calculate the actual screen coordinates
    final screenSize = MediaQuery.of(context).size;
    final scaleX = widget.screenWidth / screenSize.width;
    final scaleY = widget.screenHeight / screenSize.height;

    final actualX = (rect.left * scaleX).round();
    final actualY = (rect.top * scaleY).round();
    final actualWidth = (rect.width * scaleX).round();
    final actualHeight = (rect.height * scaleY).round();

    // Capture the selected region from the original screenshot bytes
    await _captureAndCopyRegion(actualX, actualY, actualWidth, actualHeight);

    if (mounted) {
      Navigator.of(context).pop(rect);
    }
  }

  Future<void> _captureAndCopyRegion(int x, int y, int w, int h) async {
    // Extract the region from the screenshot bytes (BGRA format)
    final stride = widget.screenWidth * 4;
    final regionBytes = <int>[];

    for (int row = 0; row < h; row++) {
      final srcY = y + row;
      if (srcY < 0 || srcY >= widget.screenHeight) continue;
      
      final srcRowStart = srcY * stride;
      for (int col = 0; col < w; col++) {
        final srcX = x + col;
        if (srcX < 0 || srcX >= widget.screenWidth) continue;
        
        final srcIdx = srcRowStart + (srcX * 4);
        if (srcIdx + 3 < widget.screenshotBytes.length) {
          regionBytes.add(widget.screenshotBytes[srcIdx]);     // B
          regionBytes.add(widget.screenshotBytes[srcIdx + 1]); // G
          regionBytes.add(widget.screenshotBytes[srcIdx + 2]); // R
          regionBytes.add(widget.screenshotBytes[srcIdx + 3]); // A
        }
      }
    }

    // Copy to clipboard
    try {
      await _windowChannel.invokeMethod<void>('copyImageToClipboard', {
        'width': w,
        'height': h,
        'bytes': Uint8List.fromList(regionBytes),
      });
    } catch (e) {
      print('Failed to copy to clipboard: $e');
    }
  }

  void _cancel() {
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return KeyboardListener(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (event) {
        if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
          _cancel();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            // Screenshot background (fullscreen)
            Positioned.fill(
              child: RawImage(
                image: widget.screenshot,
                fit: BoxFit.fill,
              ),
            ),
            // Gesture detector for selection
            Positioned.fill(
              child: GestureDetector(
                onPanStart: _onPanStart,
                onPanUpdate: _onPanUpdate,
                onPanEnd: _onPanEnd,
                child: MouseRegion(
                  cursor: SystemMouseCursors.precise,
                  child: Container(color: Colors.transparent),
                ),
              ),
            ),
          // Dimming mask outside selection
          if (_selectionRect != null)
            ..._buildDimmingMask(_selectionRect!, MediaQuery.of(context).size),
          // Selection rectangle
          if (_selectionRect != null)
            Positioned.fromRect(
              rect: _selectionRect!,
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.blue, width: 2),
                ),
              ),
            ),
          // Floating toolbar
          Positioned(
            top: 16,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.4),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.screenshot, size: 18, color: Colors.white),
                    const SizedBox(width: 8),
                    const Text(
                      'Drag to select',
                      style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
                    ),
                    if (_selectionRect != null && _selectionRect!.width >= 10 && _selectionRect!.height >= 10) ...[
                      const SizedBox(width: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.blue.withValues(alpha: 0.8),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '${(_selectionRect!.width * widget.screenWidth / MediaQuery.of(context).size.width).round()} × ${(_selectionRect!.height * widget.screenHeight / MediaQuery.of(context).size.height).round()}',
                          style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                    const SizedBox(width: 12),
                    IconButton(
                      onPressed: _cancel,
                      icon: const Icon(Icons.close, size: 18),
                      color: Colors.white,
                      tooltip: 'Cancel (Esc)',
                      style: IconButton.styleFrom(
                        minimumSize: const Size(28, 28),
                        maximumSize: const Size(28, 28),
                        padding: EdgeInsets.zero,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      ),
    );
  }

  List<Widget> _buildDimmingMask(Rect selection, Size containerSize) {
    const dimColor = Color(0x66000000);

    return [
      // Top
      if (selection.top > 0)
        Positioned(
          left: 0,
          top: 0,
          right: 0,
          height: selection.top,
          child: Container(color: dimColor),
        ),
      // Bottom
      if (selection.bottom < containerSize.height)
        Positioned(
          left: 0,
          top: selection.bottom,
          right: 0,
          bottom: 0,
          child: Container(color: dimColor),
        ),
      // Left
      if (selection.left > 0)
        Positioned(
          left: 0,
          top: selection.top,
          width: selection.left,
          height: selection.height,
          child: Container(color: dimColor),
        ),
      // Right
      if (selection.right < containerSize.width)
        Positioned(
          left: selection.right,
          top: selection.top,
          right: 0,
          height: selection.height,
          child: Container(color: dimColor),
        ),
    ];
  }
}

/// Custom code block builder with syntax highlighting
class _CodeBlockBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfter(element, TextStyle? preferredStyle) {
    final code = element.textContent;
    
    // Try to detect language from code fence
    String? language;
    try {
      final classAttr = element.attributes['class'] ?? '';
      final match = RegExp(r'language-(\w+)').firstMatch(classAttr);
      if (match != null) {
        language = match.group(1);
      }
    } catch (_) {
      // Ignore errors in language detection
    }
    
    // Try to highlight with detected language, fall back to plain text on any error
    List<TextSpan> spans;
    try {
      if (language != null && language.isNotEmpty) {
        final result = highlight.parse(code, language: language);
        spans = _convertNodes(result.nodes ?? []);
      } else {
        // Don't auto-detect - just use plain text to avoid parsing errors
        spans = [TextSpan(text: code, style: const TextStyle(color: Colors.white))];
      }
    } catch (e) {
      // On any error, fall back to plain text
      spans = [TextSpan(text: code, style: const TextStyle(color: Colors.white))];
    }
    
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF282C34),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white24),
      ),
      child: Stack(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SelectableText.rich(
              TextSpan(
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  height: 1.5,
                ),
                children: spans,
              ),
            ),
          ),
          Positioned(
            top: 0,
            right: 0,
            child: IconButton(
              icon: const Icon(Icons.copy, size: 16, color: Colors.white54),
              tooltip: 'Copy code',
              onPressed: () {
                Clipboard.setData(ClipboardData(text: code));
              },
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
            ),
          ),
        ],
      ),
    );
  }

  List<TextSpan> _convertNodes(List<dynamic> nodes) {
    final spans = <TextSpan>[];
    for (final node in nodes) {
      if (node is String) {
        spans.add(TextSpan(text: node, style: const TextStyle(color: Colors.white)));
      } else if (node.className != null) {
        final style = atomOneDarkTheme[node.className] ?? const TextStyle(color: Colors.white);
        if (node.children != null) {
          spans.addAll(_convertNodes(node.children));
        } else {
          spans.add(TextSpan(text: node.value, style: style));
        }
      } else if (node.children != null) {
        spans.addAll(_convertNodes(node.children));
      } else {
        spans.add(TextSpan(text: node.value ?? '', style: const TextStyle(color: Colors.white)));
      }
    }
    return spans;
  }
}