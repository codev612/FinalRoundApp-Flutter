import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io' show Platform;

import 'home_page.dart';
import 'settings_page.dart';
import 'meeting_page_enhanced.dart';
import 'notifications_page.dart';
import 'signin_page.dart';
import '../providers/shortcuts_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/meeting_provider.dart';
import '../providers/speech_to_text_provider.dart';
import '../providers/notification_provider.dart';
import '../providers/dashboard_provider.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WindowListener {
  int _index = 0; // default to Home
  bool _wasAuthenticated = false;
  bool _authTransitionScheduled = false;

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      windowManager.addListener(this);
    }
  }
  

  @override
  void dispose() {
    if (Platform.isWindows) {
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  @override
  Future<bool> onWindowClose() async {
    // Minimize to tray instead of closing
    if (Platform.isWindows) {
      try {
        await windowManager.hide();
        return true; // Prevent window from closing
      } catch (e) {
        return false; // Allow close if hide fails
      }
    }
    return false; // Allow normal close on other platforms
  }

  @override
  void onWindowResize() async {
    // Save window size when it's resized
    if (Platform.isWindows) {
      try {
        final size = await windowManager.getSize();
        final prefs = await SharedPreferences.getInstance();
        await prefs.setDouble('window_width', size.width);
        await prefs.setDouble('window_height', size.height);
      } catch (e) {
        // Ignore errors
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer3<AuthProvider, MeetingProvider, SpeechToTextProvider>(
      builder: (context, authProvider, meetingProvider, speechProvider, _) {
        final isAuthenticated = authProvider.isAuthenticated;
        
        // Update auth token whenever auth state changes
        if (isAuthenticated) {
          final token = authProvider.token;
          meetingProvider.updateAuthToken(token);
          speechProvider.updateAuthToken(token);
          context.read<NotificationProvider>().updateAuthToken(token);
          context.read<DashboardProvider>().setAuthToken(token);
          speechProvider.setOnAuthInvalidated(() async {
            await authProvider.signOut();
          });
        } else {
          context.read<NotificationProvider>().updateAuthToken(null);
          context.read<DashboardProvider>().setAuthToken(null);
        }
        
        // Show signin page if not authenticated
        if (!isAuthenticated) {
          // Reset auth transition bookkeeping
          _wasAuthenticated = false;
          _authTransitionScheduled = false;
          return const SignInPage();
        }

        // If we just transitioned from unauthenticated -> authenticated,
        // force home immediately for this frame, then sync state next frame.
        final shouldForceHomeNow = !_wasAuthenticated;
        final displayIndex = shouldForceHomeNow ? 0 : _index;

        if (shouldForceHomeNow && !_authTransitionScheduled) {
          _authTransitionScheduled = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            setState(() {
              _index = 0;
              _wasAuthenticated = true;
              _authTransitionScheduled = false;
            });
          });
        } else {
          _wasAuthenticated = true;
        }

        return Consumer<ShortcutsProvider>(
          builder: (context, shortcutsProvider, child) {
        // Get toggle hide shortcut from provider
        final toggleHide = shortcutsProvider.getShortcutActivator('toggleHide');
        final shortcuts = <ShortcutActivator, Intent>{};
        if (Platform.isWindows && toggleHide != null) {
          shortcuts[toggleHide] = _ToggleHideIntent();
        }
        
        return Shortcuts(
          shortcuts: shortcuts,
          child: Actions(
            actions: {
              if (Platform.isWindows)
                _ToggleHideIntent: CallbackAction<_ToggleHideIntent>(
                  onInvoke: (_) async {
                    if (Platform.isWindows) {
                      final isMinimized = await windowManager.isMinimized();
                      if (isMinimized) {
                        await windowManager.show();
                        await windowManager.focus();
                      } else {
                        await windowManager.minimize();
                      }
                    }
                    return null;
                  },
                ),
            },
            child: Focus(
              autofocus: true,
              child: Scaffold(
            backgroundColor: Colors.transparent,
            body: SafeArea(
              child: IndexedStack(
                index: displayIndex,
                children: [
                  // Home page with opaque background
                  Container(
                    color: Theme.of(context).colorScheme.surface,
                    child: HomePage(
                      onStartMeeting: () async {
                        // Clear current session and create a new one when starting a new meeting
                        final meetingProvider = context.read<MeetingProvider>();
                        final speechProvider = context.read<SpeechToTextProvider>();
                        await meetingProvider.clearCurrentSession();
                        // Clear speech provider bubbles to start fresh
                        speechProvider.clearTranscript();
                        await meetingProvider.createNewSession();
                        setState(() => _index = 1);
                      },
                      onLoadSession: () {
                        // Just navigate to meeting page when loading an existing session
                        // The session is already loaded by loadSession() call
                        setState(() => _index = 1);
                      },
                    ),
                  ),
                  // Meeting page remains transparent
                  const MeetingPageEnhanced(),
                  // Notifications page (uses same background as surface)
                  NotificationsPage(isActive: displayIndex == 2),
                  // Settings page with opaque background
                  Container(
                    color: Theme.of(context).colorScheme.surface,
                    child: const SettingsPage(),
                  ),
                ],
              ),
            ),
      bottomNavigationBar: Consumer2<SpeechToTextProvider, NotificationProvider>(
        builder: (context, speechProvider, notificationProvider, child) {
          final isRecording = speechProvider.isRecording;
          final showAlert = isRecording && displayIndex != 1; // Show alert when recording and not on meeting page
          final hasUnreadNotifications = notificationProvider.hasUnread;
          
          return BottomNavigationBar(
            currentIndex: displayIndex,
            onTap: (i) async {
              // If clicking Home tab (index 0), reload sessions to show newly saved ones
              if (i == 0 && displayIndex != 0) {
                final meetingProvider = context.read<MeetingProvider>();
                // Reload all sessions (no pagination for homepage)
                meetingProvider.loadSessions();
              }
              // If clicking Meeting tab (index 1) and no current session, start a new meeting
              if (i == 1) {
                final meetingProvider = context.read<MeetingProvider>();
                if (meetingProvider.currentSession == null) {
                  // Start a new meeting like the "Start Meeting" button
                  final speechProvider = context.read<SpeechToTextProvider>();
                  await meetingProvider.clearCurrentSession();
                  speechProvider.clearTranscript();
                  await meetingProvider.createNewSession();
                }
              }
              setState(() => _index = i);
            },
            backgroundColor: Theme.of(context).colorScheme.surface,
            selectedItemColor: Theme.of(context).colorScheme.primary,
            unselectedItemColor: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
            type: BottomNavigationBarType.fixed,
            items: [
              const BottomNavigationBarItem(
                icon: Icon(Icons.home_outlined),
                activeIcon: Icon(Icons.home),
                label: 'Home',
              ),
              BottomNavigationBarItem(
                icon: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    const Icon(Icons.record_voice_over_outlined),
                    if (showAlert)
                      Positioned(
                        right: -4,
                        top: -4,
                        child: Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: Colors.red,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Theme.of(context).colorScheme.surface,
                              width: 2,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                activeIcon: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    const Icon(Icons.record_voice_over),
                    if (showAlert)
                      Positioned(
                        right: -4,
                        top: -4,
                        child: Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: Colors.red,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Theme.of(context).colorScheme.surface,
                              width: 2,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                label: 'Meeting',
              ),
              BottomNavigationBarItem(
                icon: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    const Icon(Icons.notifications_outlined),
                    if (hasUnreadNotifications)
                      Positioned(
                        right: -4,
                        top: -4,
                        child: Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: Colors.red,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Theme.of(context).colorScheme.surface,
                              width: 2,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                activeIcon: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    const Icon(Icons.notifications),
                    if (hasUnreadNotifications)
                      Positioned(
                        right: -4,
                        top: -4,
                        child: Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: Colors.red,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Theme.of(context).colorScheme.surface,
                              width: 2,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                label: 'Notifications',
              ),
              const BottomNavigationBarItem(
                icon: Icon(Icons.settings_outlined),
                activeIcon: Icon(Icons.settings),
                label: 'Settings',
              ),
            ],
          );
        },
      ),
            ),
          ),
        ),
      );
        },
      );
      },
    );
  }
}

class _ToggleHideIntent extends Intent {
  const _ToggleHideIntent();
}
