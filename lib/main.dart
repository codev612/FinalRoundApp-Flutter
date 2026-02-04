import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:system_tray/system_tray.dart';
import 'dart:io' show Platform;
import 'providers/speech_to_text_provider.dart';
import 'providers/meeting_provider.dart';
import 'providers/shortcuts_provider.dart';
import 'providers/auth_provider.dart';
import 'providers/theme_provider.dart';
import 'services/ai_service.dart';
import 'services/appearance_service.dart';
import 'services/http_client_service.dart';
import 'config/app_config.dart';
import 'screens/app_shell.dart';

final SystemTray systemTray = SystemTray();

Future<void> initSystemTray() async {
  if (!Platform.isWindows) return;
  
  try {
    // Initialize system tray
    // For Windows, use the icon from resources or assets
    // The package will look for the icon in the assets folder
    await systemTray.initSystemTray(
      title: "FinalRound",
      iconPath: "assets/app_icon.ico",
      toolTip: "FinalRound - AI Meeting Assistant",
    );
    
    // Create tray menu (shown on right-click)
    final Menu menu = Menu();
    await menu.buildFrom([
      MenuItemLabel(
        label: 'Show',
        onClicked: (menuItem) async {
          await windowManager.show();
          await windowManager.focus();
        },
      ),
      MenuItemLabel(
        label: 'Exit',
        onClicked: (menuItem) async {
          await windowManager.destroy();
        },
      ),
    ]);
    
    // Set context menu
    await systemTray.setContextMenu(menu);
    
    // Handle tray icon events
    systemTray.registerSystemTrayEventHandler((eventName) async {
      print('[SystemTray] Event received: $eventName');
      if (eventName == kSystemTrayEventClick) {
        // Left-click: toggle window visibility
        final isVisible = await windowManager.isVisible();
        if (isVisible) {
          await windowManager.hide();
        } else {
          await windowManager.show();
          await windowManager.focus();
        }
      } else if (eventName == kSystemTrayEventRightClick) {
        // Right-click: show context menu
        print('[SystemTray] Right-click detected, showing context menu');
        await systemTray.popUpContextMenu();
      } else {
        print('[SystemTray] Unknown event: $eventName');
      }
    });
  } catch (e) {
    print('[SystemTray] Error initializing system tray: $e');
    // Continue without system tray if initialization fails
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize HTTP client
  // On Windows desktop, certificate validation is bypassed due to BoringSSL limitations
  // On web, proper certificate validation is used (browsers handle it correctly)
  HttpClientService.initialize();
  
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
      skipTaskbar: false, // Changed to false so it shows in taskbar when visible
      titleBarStyle: TitleBarStyle.normal,
      alwaysOnTop: true,
    );
    
    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.setBackgroundColor(Colors.transparent);
      await windowManager.setAlwaysOnTop(true);
      // Set window title
      await windowManager.setTitle('FinalRound');
      // Prevent window from closing - will be handled by onWindowClose
      await windowManager.setPreventClose(true);
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
      
      // Initialize system tray
      await initSystemTray();
      
      // Set initial title bar theme after window is shown to prevent blinking
      // This will be called after ThemeProvider loads the saved theme
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final prefs = await SharedPreferences.getInstance();
        final themeModeIndex = prefs.getInt('theme_mode');
        if (themeModeIndex != null) {
          final themeMode = ThemeMode.values[themeModeIndex];
          final isDark = themeMode == ThemeMode.dark || 
                        (themeMode == ThemeMode.system);
          await AppearanceService.setTitleBarTheme(isDark);
        }
      });
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
        ChangeNotifierProvider(
          create: (_) => ThemeProvider(),
        ),
      ],
      child: Consumer<ThemeProvider>(
        builder: (context, themeProvider, child) {
          // Update Windows title bar theme when theme changes
          WidgetsBinding.instance.addPostFrameCallback((_) async {
            if (Platform.isWindows) {
              final brightness = themeProvider.themeMode == ThemeMode.light
                  ? Brightness.light
                  : (themeProvider.themeMode == ThemeMode.dark
                      ? Brightness.dark
                      : MediaQuery.platformBrightnessOf(context));
              await AppearanceService.setTitleBarTheme(brightness == Brightness.dark);
            }
          });
          
          // Create user-friendly text theme
          final baseLightTextTheme = Typography.material2021(platform: TargetPlatform.windows);
          final baseDarkTextTheme = Typography.material2021(platform: TargetPlatform.windows);
          
          return MaterialApp(
            title: 'FinalRound',
            theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(
                seedColor: Colors.deepPurple,
                brightness: Brightness.light,
              ),
              useMaterial3: true,
              scaffoldBackgroundColor: Colors.transparent,
              textTheme: baseLightTextTheme.black.copyWith(
                // Headlines - larger, bolder for important titles
                headlineLarge: baseLightTextTheme.black.headlineLarge?.copyWith(
                  fontSize: 32,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.5,
                  height: 1.2,
                ),
                headlineMedium: baseLightTextTheme.black.headlineMedium?.copyWith(
                  fontSize: 28,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.5,
                  height: 1.3,
                ),
                headlineSmall: baseLightTextTheme.black.headlineSmall?.copyWith(
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.25,
                  height: 1.3,
                ),
                // Titles - for section headers and card titles
                titleLarge: baseLightTextTheme.black.titleLarge?.copyWith(
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0,
                  height: 1.4,
                ),
                titleMedium: baseLightTextTheme.black.titleMedium?.copyWith(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.15,
                  height: 1.5,
                ),
                titleSmall: baseLightTextTheme.black.titleSmall?.copyWith(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.1,
                  height: 1.5,
                ),
                // Body text - main content
                bodyLarge: baseLightTextTheme.black.bodyLarge?.copyWith(
                  fontSize: 16,
                  fontWeight: FontWeight.w400,
                  letterSpacing: 0.5,
                  height: 1.6,
                ),
                bodyMedium: baseLightTextTheme.black.bodyMedium?.copyWith(
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  letterSpacing: 0.25,
                  height: 1.5,
                ),
                bodySmall: baseLightTextTheme.black.bodySmall?.copyWith(
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  letterSpacing: 0.4,
                  height: 1.4,
                ),
                // Labels - for buttons, form fields
                labelLarge: baseLightTextTheme.black.labelLarge?.copyWith(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.1,
                  height: 1.4,
                ),
                labelMedium: baseLightTextTheme.black.labelMedium?.copyWith(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.5,
                  height: 1.4,
                ),
                labelSmall: baseLightTextTheme.black.labelSmall?.copyWith(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.5,
                  height: 1.4,
                ),
              ),
            ),
            darkTheme: ThemeData(
              colorScheme: ColorScheme.fromSeed(
                seedColor: Colors.deepPurple,
                brightness: Brightness.dark,
              ),
              useMaterial3: true,
              scaffoldBackgroundColor: Colors.transparent,
              textTheme: baseDarkTextTheme.white.copyWith(
                // Headlines - larger, bolder for important titles
                headlineLarge: baseDarkTextTheme.white.headlineLarge?.copyWith(
                  fontSize: 32,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.5,
                  height: 1.2,
                ),
                headlineMedium: baseDarkTextTheme.white.headlineMedium?.copyWith(
                  fontSize: 28,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.5,
                  height: 1.3,
                ),
                headlineSmall: baseDarkTextTheme.white.headlineSmall?.copyWith(
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.25,
                  height: 1.3,
                ),
                // Titles - for section headers and card titles
                titleLarge: baseDarkTextTheme.white.titleLarge?.copyWith(
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0,
                  height: 1.4,
                ),
                titleMedium: baseDarkTextTheme.white.titleMedium?.copyWith(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.15,
                  height: 1.5,
                ),
                titleSmall: baseDarkTextTheme.white.titleSmall?.copyWith(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.1,
                  height: 1.5,
                ),
                // Body text - main content
                bodyLarge: baseDarkTextTheme.white.bodyLarge?.copyWith(
                  fontSize: 16,
                  fontWeight: FontWeight.w400,
                  letterSpacing: 0.5,
                  height: 1.6,
                ),
                bodyMedium: baseDarkTextTheme.white.bodyMedium?.copyWith(
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  letterSpacing: 0.25,
                  height: 1.5,
                ),
                bodySmall: baseDarkTextTheme.white.bodySmall?.copyWith(
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  letterSpacing: 0.4,
                  height: 1.4,
                ),
                // Labels - for buttons, form fields
                labelLarge: baseDarkTextTheme.white.labelLarge?.copyWith(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.1,
                  height: 1.4,
                ),
                labelMedium: baseDarkTextTheme.white.labelMedium?.copyWith(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.5,
                  height: 1.4,
                ),
                labelSmall: baseDarkTextTheme.white.labelSmall?.copyWith(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.5,
                  height: 1.4,
                ),
              ),
            ),
            themeMode: themeProvider.themeMode,
            home: const AppShell(),
          );
        },
      ),
    );
  }
}


