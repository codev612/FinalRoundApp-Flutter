import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import 'dart:io' show Platform;
import 'package:flutter/services.dart';

class AppearanceService {
  static const String _keyUndetectable = 'appearance_undetectable';
  static const String _keySkipTaskbar = 'appearance_skip_taskbar';
  static const String _keyThemeMode = 'theme_mode';
  static const String _keyMeetingPageTransparent = 'appearance_meeting_page_transparent';
  static const MethodChannel _channel = MethodChannel('com.finalround/window');

  /// Load undetectable setting
  static Future<bool> getUndetectable() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyUndetectable) ?? false;
  }

  /// Save undetectable setting
  static Future<void> setUndetectable(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyUndetectable, value);
    
    if (Platform.isWindows) {
      try {
        await _channel.invokeMethod('setUndetectable', value);
      } catch (e) {
        print('Error setting undetectable: $e');
      }
    }
  }

  /// Load skip taskbar setting
  static Future<bool> getSkipTaskbar() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keySkipTaskbar) ?? true; // Default to true
  }

  /// Save skip taskbar setting
  static Future<void> setSkipTaskbar(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keySkipTaskbar, value);
    
    if (Platform.isWindows) {
      try {
        await windowManager.setSkipTaskbar(value);
      } catch (e) {
        print('Error setting skip taskbar: $e');
      }
    }
  }

  /// Set title bar theme (dark or light)
  static Future<void> setTitleBarTheme(bool isDark) async {
    if (!Platform.isWindows) return;
    
    try {
      await _channel.invokeMethod('setTitleBarTheme', isDark);
    } catch (e) {
      print('Error setting title bar theme: $e');
    }
  }

  /// Load meeting page transparency setting
  static Future<bool> getMeetingPageTransparent() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyMeetingPageTransparent) ?? true; // Default to true (transparent)
  }

  /// Save meeting page transparency setting
  static Future<void> setMeetingPageTransparent(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyMeetingPageTransparent, value);
  }

  /// Apply all appearance settings on app start
  static Future<void> applySettings() async {
    if (!Platform.isWindows) return;
    
    try {
      final undetectable = await getUndetectable();
      final skipTaskbar = await getSkipTaskbar();
      
      await setUndetectable(undetectable);
      await setSkipTaskbar(skipTaskbar);
    } catch (e) {
      print('Error applying appearance settings: $e');
    }
  }
}
