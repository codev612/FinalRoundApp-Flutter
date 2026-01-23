import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io' show Platform;
import 'providers/speech_to_text_provider.dart';
import 'providers/meeting_provider.dart';
import 'providers/shortcuts_provider.dart';
import 'providers/auth_provider.dart';
import 'services/ai_service.dart';
import 'services/appearance_service.dart';
import 'config/app_config.dart';
import 'screens/app_shell.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize window manager for transparency and always-on-top (Windows only)
  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    
    // Load saved window size or use default
    final prefs = await SharedPreferences.getInstance();
    final savedWidth = prefs.getDouble('window_width');
    final savedHeight = prefs.getDouble('window_height');
    final windowSize = savedWidth != null && savedHeight != null
        ? Size(savedWidth, savedHeight)
        : const Size(1200, 800);
    
    WindowOptions windowOptions = WindowOptions(
      size: windowSize,
      backgroundColor: Colors.transparent,
      skipTaskbar: true,
      titleBarStyle: TitleBarStyle.normal,
      alwaysOnTop: true,
    );
    
    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.setBackgroundColor(Colors.transparent);
      await windowManager.setAlwaysOnTop(true);
      // Set minimum window size
      await windowManager.setMinimumSize(const Size(800, 600));
      // Restore saved window size
      if (savedWidth != null && savedHeight != null) {
        await windowManager.setSize(windowSize);
      }
      // Apply appearance settings (will load from SharedPreferences)
      await AppearanceService.applySettings();
      await windowManager.show();
      await windowManager.focus();
    });
  }
  
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => AuthProvider(),
        ),
        ChangeNotifierProvider(
          create: (_) => SpeechToTextProvider(),
        ),
        ChangeNotifierProxyProvider<SpeechToTextProvider, MeetingProvider>(
          create: (_) => MeetingProvider(
            aiService: AiService(
              httpBaseUrl: AppConfig.serverHttpBaseUrl,
              aiWsUrl: AppConfig.serverAiWebSocketUrl,
            ),
          ),
          update: (_, speechProvider, previous) => previous ??
              MeetingProvider(
                aiService: AiService(
                  httpBaseUrl: AppConfig.serverHttpBaseUrl,
                  aiWsUrl: AppConfig.serverAiWebSocketUrl,
                ),
              ),
        ),
        ChangeNotifierProvider(
          create: (_) => ShortcutsProvider(),
        ),
      ],
      child: MaterialApp(
        title: 'HearNow',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.deepPurple,
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
          scaffoldBackgroundColor: Colors.transparent,
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.deepPurple,
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
          scaffoldBackgroundColor: Colors.transparent,
        ),
        themeMode: ThemeMode.dark,
        home: const AppShell(),
      ),
    );
  }
}


