import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AiResponseSettingsProvider extends ChangeNotifier {
  static const String _fontSizeKey = 'ai_response_font_size';
  double _fontSize = 14.0;

  double get fontSize => _fontSize;

  AiResponseSettingsProvider() {
    _loadFontSize();
  }

  Future<void> _loadFontSize() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getDouble(_fontSizeKey);
    if (value != null && value != _fontSize) {
      _fontSize = value;
      notifyListeners();
    }
  }

  Future<void> setFontSize(double value) async {
    if (_fontSize == value) return;
    _fontSize = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_fontSizeKey, value);
  }
}
