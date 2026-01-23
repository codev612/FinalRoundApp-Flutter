import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io' show Platform;
import '../services/appearance_service.dart';

class ThemeProvider extends ChangeNotifier {
  static const String _keyThemeMode = 'theme_mode';
  ThemeMode _themeMode = ThemeMode.dark;

  ThemeProvider() {
    _loadThemeMode();
  }

  ThemeMode get themeMode => _themeMode;

  bool _getIsDarkMode(BuildContext? context) {
    switch (_themeMode) {
      case ThemeMode.light:
        return false;
      case ThemeMode.dark:
        return true;
      case ThemeMode.system:
        // For system mode, check the platform brightness if context is available
        if (context != null) {
          return MediaQuery.platformBrightnessOf(context) == Brightness.dark;
        }
        // Default to dark if no context
        return true;
    }
  }

  Future<void> _loadThemeMode() async {
    final prefs = await SharedPreferences.getInstance();
    final themeModeIndex = prefs.getInt(_keyThemeMode);
    if (themeModeIndex != null) {
      _themeMode = ThemeMode.values[themeModeIndex];
      notifyListeners();
      // Update title bar theme after loading (default to dark for system mode)
      if (Platform.isWindows) {
        final isDark = _themeMode == ThemeMode.dark || 
                       (_themeMode == ThemeMode.system);
        await AppearanceService.setTitleBarTheme(isDark);
      }
    }
  }

  Future<void> setThemeMode(ThemeMode mode, {BuildContext? context}) async {
    if (_themeMode == mode) return;
    
    _themeMode = mode;
    notifyListeners();
    
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyThemeMode, mode.index);
    
    // Update Windows title bar theme
    if (Platform.isWindows) {
      final isDark = _getIsDarkMode(context);
      await AppearanceService.setTitleBarTheme(isDark);
    }
  }
}
