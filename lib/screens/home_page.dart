import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/meeting_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/speech_to_text_provider.dart';
import '../providers/dashboard_provider.dart';
import '../widgets/dashboard_widgets.dart';
import '../models/meeting_session.dart';
import '../utils/error_message_helper.dart';

class _HoverableListTile extends StatefulWidget {
  final MeetingSession session;
  final MeetingProvider provider;
  final String Function(DateTime) formatTime;
  final String Function(Duration) formatDuration;
  final VoidCallback? onLoadSession;
  final VoidCallback onStartMeeting;
  final BuildContext? parentContext;

  const _HoverableListTile({
    required this.session,
    required this.provider,
    required this.formatTime,
    required this.formatDuration,
    this.onLoadSession,
    required this.onStartMeeting,
    this.parentContext,
  });

  @override
  State<_HoverableListTile> createState() => _HoverableListTileState();
}

class _HoverableListTileState extends State<_HoverableListTile> {
  bool _isHovered = false;
  bool _isMenuOpen = false;

  Future<void> _showDeleteConfirmation() async {
    if (!mounted) return;
    
    bool? confirmed;
    try {
      confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: true,
        builder: (context) => AlertDialog(
            title: Row(
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  color: Theme.of(context).colorScheme.error,
                  size: 24,
                ),
                const SizedBox(width: 8),
                const Text('Delete Session'),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Are you sure you want to delete this session?',
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceVariant.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.description,
                        size: 16,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          widget.session.title,
                          style: Theme.of(context).textTheme.bodyMedium,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'This action cannot be undone.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.error,
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
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                ),
                child: const Text('Delete'),
              ),
            ],
          ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error showing dialog: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
      return;
    }
    
    if (confirmed == true && mounted) {
      // Show SnackBar immediately using current context (before deletion)
      // This ensures the context is still valid
      final scaffoldContext = widget.parentContext ?? context;
      try {
        ScaffoldMessenger.of(scaffoldContext).showSnackBar(
          SnackBar(
            content: const Row(
              children: [
                Icon(Icons.check_circle, color: Colors.white),
                SizedBox(width: 8),
                Text('Session deleted successfully'),
              ],
            ),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
          ),
        );
      } catch (e) {
        // If showing immediately fails, try after a delay
        WidgetsBinding.instance.addPostFrameCallback((_) {
          try {
            ScaffoldMessenger.of(scaffoldContext).showSnackBar(
              SnackBar(
                content: const Row(
                  children: [
                    Icon(Icons.check_circle, color: Colors.white),
                    SizedBox(width: 8),
                    Text('Session deleted successfully'),
                  ],
                ),
                backgroundColor: Colors.green,
                behavior: SnackBarBehavior.floating,
                duration: const Duration(seconds: 3),
              ),
            );
          } catch (_) {
            // Ignore if still fails
          }
        });
      }
      
      try {
        await widget.provider.deleteSession(widget.session.id);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  const Icon(Icons.error, color: Colors.white),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('Failed to delete session: $e'),
                  ),
                ],
              ),
              backgroundColor: Theme.of(context).colorScheme.error,
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 4),
            ),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        decoration: BoxDecoration(
          color: _isHovered
              ? Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.5)
              : Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _isHovered
                ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.3)
                : Theme.of(context).colorScheme.outline.withValues(alpha: 0.1),
            width: 1,
          ),
          boxShadow: _isHovered
              ? [
                  BoxShadow(
                    color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ]
              : [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 4,
                    offset: const Offset(0, 1),
                  ),
                ],
        ),
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          title: Consumer<SpeechToTextProvider>(
            builder: (context, speechProvider, _) {
              final currentSession = widget.provider.currentSession;
              final isCurrentSession = currentSession != null && 
                  currentSession.id == widget.session.id;
              final isRecording = speechProvider.isRecording;
              
              return Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.session.title,
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: Theme.of(context).colorScheme.onSurface,
                                ),
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
                  ),
                  const SizedBox(width: 12),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.access_time,
                        size: 16,
                        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '${widget.formatTime(widget.session.createdAt)} • ${widget.formatDuration(widget.session.duration)}',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                            ),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.session.bubbles.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Chip(
                    label: Text('${widget.session.bubbles.length}'),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              // Menu button (only visible on hover or when menu is open)
              if (_isHovered || _isMenuOpen)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: PopupMenuButton<String>(
                    icon: Icon(
                      Icons.more_vert,
                      size: 20,
                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                    ),
                    onOpened: () {
                      setState(() {
                        _isMenuOpen = true;
                      });
                    },
                    onCanceled: () {
                      setState(() {
                        _isMenuOpen = false;
                      });
                    },
                    onSelected: (value) {
                      setState(() {
                        _isMenuOpen = false;
                      });
                      
                      if (value == 'delete') {
                        if (mounted) {
                          _showDeleteConfirmation();
                        }
                      } else if (value == 'copy_link') {
                        // Copy session ID as link (could be enhanced to include full URL)
                        final link = widget.session.id;
                        Clipboard.setData(ClipboardData(text: link));
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Session link copied to clipboard')),
                          );
                        }
                      } else if (value == 'regenerate') {
                        // Load session first, then regenerate summary, insights, and questions
                        (() async {
                          try {
                            // Show loading message
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Row(
                                    children: [
                                      SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      ),
                                      SizedBox(width: 12),
                                      Text('Regenerating AI content...'),
                                    ],
                                  ),
                                  duration: Duration(seconds: 30),
                                ),
                              );
                            }
                            
                            // Load the session
                            await widget.provider.loadSession(widget.session.id);
                            final session = widget.provider.currentSession;
                            
                            if (session != null && session.bubbles.isNotEmpty) {
                              // Regenerate summary, insights, and questions
                              await widget.provider.generateSummary(regenerate: true);
                              await widget.provider.generateInsights(regenerate: true);
                              await widget.provider.generateQuestions(regenerate: true);
                              
                              if (mounted) {
                                ScaffoldMessenger.of(context).hideCurrentSnackBar();
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Row(
                                      children: [
                                        Icon(Icons.check_circle, color: Colors.white, size: 20),
                                        SizedBox(width: 8),
                                        Text('Summary, insights, and questions regenerated successfully'),
                                      ],
                                    ),
                                    backgroundColor: Colors.green,
                                    duration: Duration(seconds: 3),
                                  ),
                                );
                              }
                            } else {
                              if (mounted) {
                                ScaffoldMessenger.of(context).hideCurrentSnackBar();
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('No transcript available to regenerate'),
                                    duration: Duration(seconds: 2),
                                  ),
                                );
                              }
                            }
                          } catch (e) {
                            if (mounted) {
                              ScaffoldMessenger.of(context).hideCurrentSnackBar();
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Row(
                                    children: [
                                      const Icon(Icons.error, color: Colors.white, size: 20),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text('Error regenerating: $e'),
                                      ),
                                    ],
                                  ),
                                  backgroundColor: Theme.of(context).colorScheme.error,
                                  duration: const Duration(seconds: 4),
                                ),
                              );
                            }
                          }
                        })();
                      }
                    },
                    itemBuilder: (context) => [
                      const PopupMenuItem(
                        value: 'copy_link',
                        child: Row(
                          children: [
                            Icon(Icons.link, size: 20),
                            SizedBox(width: 8),
                            Text('Copy Link'),
                          ],
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'regenerate',
                        child: Row(
                          children: [
                            Icon(Icons.refresh, size: 20),
                            SizedBox(width: 8),
                            Text('Regenerate'),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 'delete',
                        child: Row(
                          children: [
                            Icon(
                              Icons.delete_outline,
                              size: 20,
                              color: Colors.red,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Delete',
                              style: TextStyle(color: Colors.red),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              Icon(
                Icons.chevron_right,
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ],
          ),
          onTap: widget.provider.isLoading ? null : () {
            // Store callbacks and session ID immediately to avoid issues if widget is disposed
            final onLoadSession = widget.onLoadSession;
            final onStartMeeting = widget.onStartMeeting;
            final sessionId = widget.session.id;
            
            // Validate session ID before attempting to load
            if (sessionId.isEmpty) {
              print('[HomePage] Session ID is empty, cannot load session');
              // Still navigate to meeting page
              if (mounted && onLoadSession != null) {
                onLoadSession();
              } else if (mounted) {
                onStartMeeting();
              }
              return;
            }
            
            // Navigate immediately, then load session in background
            // This ensures navigation happens even if loadSession sets isLoading = true
            if (mounted) {
              if (onLoadSession != null) {
                onLoadSession();
              } else {
                onStartMeeting();
              }
            }
            
            // Load session asynchronously after navigation
            // Use a microtask to ensure navigation happens first
            Future.microtask(() async {
              try {
                await widget.provider.loadSession(sessionId).timeout(
                  const Duration(seconds: 10),
                  onTimeout: () {
                    print('[HomePage] loadSession timed out after 10 seconds');
                  },
                );
              } catch (e) {
                print('[HomePage] Error loading session: $e');
                // Error is already handled by loadSession
              }
            });
          },
        ),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  final VoidCallback onStartMeeting;
  final VoidCallback? onLoadSession;

  const HomePage({super.key, required this.onStartMeeting, this.onLoadSession});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final authProvider = context.read<AuthProvider>();
      final meetingProvider = context.read<MeetingProvider>();
      final dashboardProvider = context.read<DashboardProvider>();
      // Ensure auth token is set before loading sessions
      meetingProvider.updateAuthToken(authProvider.token);
      dashboardProvider.setAuthToken(authProvider.token);
      meetingProvider.loadSessions(); // Load all sessions (no pagination for homepage)
      // Load dashboard stats (will refresh when sessions finish loading)
      dashboardProvider.loadStats();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reload sessions when navigating back to this page
    // This ensures newly saved sessions appear immediately
    // Use a flag to prevent multiple reloads
    if (mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final meetingProvider = context.read<MeetingProvider>();
        final dashboardProvider = context.read<DashboardProvider>();
        // Only reload if we have an auth token (user is logged in)
        final authProvider = context.read<AuthProvider>();
        if (authProvider.token != null && authProvider.token!.isNotEmpty) {
          // Reload all sessions (no pagination for homepage)
          meetingProvider.loadSessions();
          // Refresh dashboard stats when sessions reload (only if not already loading)
          if (!dashboardProvider.isLoading) {
            dashboardProvider.refresh();
          }
        }
      });
    }
  }

  String _formatDate(DateTime date) {
    // Convert to local time if it's in UTC
    final localDate = date.isUtc ? date.toLocal() : date;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final dateOnly = DateTime(localDate.year, localDate.month, localDate.day);

    if (dateOnly == today) {
      return 'Today';
    } else if (dateOnly == yesterday) {
      return 'Yesterday';
    } else {
      // Format: "January 15, 2024"
      final months = [
        'January',
        'February',
        'March',
        'April',
        'May',
        'June',
        'July',
        'August',
        'September',
        'October',
        'November',
        'December'
      ];
      return '${months[date.month - 1]} ${date.day}, ${date.year}';
    }
  }

  String _formatTime(DateTime date) {
    // Convert to local time if it's in UTC
    final localDate = date.isUtc ? date.toLocal() : date;
    final hour = localDate.hour == 0 ? 12 : (localDate.hour > 12 ? localDate.hour - 12 : localDate.hour);
    final minute = localDate.minute.toString().padLeft(2, '0');
    final period = localDate.hour < 12 ? 'AM' : 'PM';
    return '$hour:$minute $period';
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    if (hours > 0) {
      return '${hours}h ${minutes}m';
    }
    return '${minutes}m';
  }

  Map<String, List<MeetingSession>> _groupSessionsByDate(List<MeetingSession> sessions) {
    final grouped = <String, List<MeetingSession>>{};
    for (final session in sessions) {
      final dateKey = _formatDate(session.createdAt);
      grouped.putIfAbsent(dateKey, () => []).add(session);
    }
    // Sort sessions within each date group (newest first)
    for (final sessions in grouped.values) {
      sessions.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }
    return grouped;
  }

  List<String> _getSortedDateKeys(Map<String, List<MeetingSession>> grouped) {
    final keys = grouped.keys.toList();
    // Sort dates: Today, Yesterday, then by date (newest first)
    keys.sort((a, b) {
      if (a == 'Today') return -1;
      if (b == 'Today') return 1;
      if (a == 'Yesterday') return -1;
      if (b == 'Yesterday') return 1;
      // For other dates, extract the date from the first session in each group
      final sessionsA = grouped[a]!;
      final sessionsB = grouped[b]!;
      if (sessionsA.isNotEmpty && sessionsB.isNotEmpty) {
        return sessionsB.first.createdAt.compareTo(sessionsA.first.createdAt);
      }
      return a.compareTo(b);
    });
    return keys;
  }

  Widget _buildSessionsList(Map<String, List<MeetingSession>> grouped, List<String> dateKeys, MeetingProvider provider) {
    return RefreshIndicator(
      onRefresh: () => provider.loadSessions(),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: dateKeys.length,
        itemBuilder: (context, dateIndex) {
          final dateKey = dateKeys[dateIndex];
          final dateSessions = grouped[dateKey]!;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Date header
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
                child: Text(
                  dateKey,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.bold,
                      ),
                ),
              ),
              // Sessions for this date
              ...dateSessions.map((session) {
                return _HoverableListTile(
                  session: session,
                  provider: provider,
                  formatTime: _formatTime,
                  formatDuration: _formatDuration,
                  onLoadSession: widget.onLoadSession,
                  onStartMeeting: widget.onStartMeeting,
                  parentContext: context,
                );
              }),
              if (dateIndex < dateKeys.length - 1)
                const Divider(height: 1),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<MeetingProvider>(
      builder: (context, provider, child) {
        final sessions = provider.sessions;
        final grouped = _groupSessionsByDate(sessions);
        final dateKeys = _getSortedDateKeys(grouped);

        // Check if there's a server connection error
        final hasServerError = provider.errorMessage.isNotEmpty &&
            ErrorMessageHelper.isServerConnectionError(provider.errorMessage);

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 64),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Server connection error banner
              if (hasServerError)
                Container(
                  margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.error.withValues(alpha: 0.3),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.cloud_off,
                        color: Theme.of(context).colorScheme.error,
                        size: 20,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Server Connection Error',
                              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: Theme.of(context).colorScheme.onErrorContainer,
                                  ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              provider.errorMessage,
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Theme.of(context).colorScheme.onErrorContainer.withValues(alpha: 0.9),
                                  ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        color: Theme.of(context).colorScheme.onErrorContainer,
                        onPressed: () {
                          provider.clearError();
                        },
                        tooltip: 'Dismiss',
                      ),
                    ],
                  ),
                ),
              // Header with title and start button
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Image.asset(
                              'assets/logo.png',
                              height: 48,
                              width: 48,
                              errorBuilder: (context, error, stackTrace) {
                                // Fallback if logo image is not found
                                return const SizedBox.shrink();
                              },
                            ),
                            const SizedBox(width: 12),
                            Text(
                              'FinalRound',
                              style: Theme.of(context).textTheme.headlineMedium,
                            ),
                          ],
                        ),
                        SizedBox(
                          width: 140,
                          child: FilledButton.icon(
                            onPressed: widget.onStartMeeting,
                            icon: const Icon(Icons.record_voice_over, size: 18),
                            label: const Text('Start Meeting', style: TextStyle(fontSize: 13)),
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'AI-powered meeting assistant that captures and transcribes your meetings in real-time using advanced speech recognition technology.',
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w500,
                            height: 1.5,
                          ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Key Features:',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        _FeatureChip(
                          icon: Icons.mic,
                          label: 'Dual Audio Capture',
                          description: 'Separate microphone and system audio transcripts for complete meeting coverage',
                        ),
                        _FeatureChip(
                          icon: Icons.auto_awesome,
                          label: 'AI-Powered Transcription',
                          description: 'Real-time speech-to-text with advanced AI models for accurate transcription',
                        ),
                        _FeatureChip(
                          icon: Icons.summarize,
                          label: 'Smart Summaries',
                          description: 'Automated meeting summaries, insights, and action items',
                        ),
                        _FeatureChip(
                          icon: Icons.history,
                          label: 'Session History',
                          description: 'Access and review all your past meetings with full transcripts',
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // Dashboard widgets
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: const DashboardWidgets(),
              ),
            const Divider(height: 1),
            // Sessions list
            Expanded(
              child: provider.isLoading && sessions.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : provider.isLoading && sessions.isNotEmpty
                      ? Stack(
                          children: [
                            // Show existing sessions with reduced opacity
                            Opacity(
                              opacity: 0.5,
                              child: IgnorePointer(
                                child: _buildSessionsList(grouped, dateKeys, provider),
                              ),
                            ),
                            // Show loading overlay
                            const Center(
                              child: CircularProgressIndicator(),
                            ),
                          ],
                        )
                      : grouped.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.meeting_room_outlined,
                                size: 64,
                                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'No meetings yet',
                                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                                    ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Start your first meeting to get started',
                                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                                    ),
                              ),
                            ],
                          ),
                        )
                      : _buildSessionsList(grouped, dateKeys, provider),
            ),
          ],
        ),
      );
      },
    );
  }
}

// Feature chip widget for displaying key features
class _FeatureChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String description;

  const _FeatureChip({
    required this.icon,
    required this.label,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: description,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.w500,
                  ),
            ),
          ],
        ),
      ),
    );
  }
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
