import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io' show Platform;

import 'home_page.dart';
import 'settings_page.dart';
import 'meeting_page_enhanced.dart';
import 'signin_page.dart';
import '../providers/shortcuts_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/meeting_provider.dart';
import '../providers/speech_to_text_provider.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WindowListener {
  int _index = 0; // default to Home
  bool _wasAuthenticated = false;

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
    return Consumer2<AuthProvider, MeetingProvider>(
      builder: (context, authProvider, meetingProvider, _) {
        // Update auth token whenever auth state changes
        if (authProvider.isAuthenticated) {
          meetingProvider.updateAuthToken(authProvider.token);
        }
        
        // Show signin page if not authenticated
        if (!authProvider.isAuthenticated) {
          _wasAuthenticated = false;
          return const SignInPage();
        }

        // Reset to home page when user just signed in
        if (!_wasAuthenticated && authProvider.isAuthenticated) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              setState(() {
                _index = 0; // Go to home page after sign in
              });
            }
          });
        }
        _wasAuthenticated = true;

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
            body: Stack(
        children: [
          // Title bar background for visibility
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 32, // Standard Windows title bar height
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
              ),
            ),
          ),
          SafeArea(
            child: IndexedStack(
              index: _index,
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
                // Settings page with opaque background
                Container(
                  color: Theme.of(context).colorScheme.surface,
                  child: const SettingsPage(),
                ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _index,
        onTap: (i) async {
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
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.home_outlined),
            activeIcon: Icon(Icons.home),
            label: 'Home',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.record_voice_over_outlined),
            activeIcon: Icon(Icons.record_voice_over),
            label: 'Meeting',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings_outlined),
            activeIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
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
