import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../config/app_config.dart';
import '../services/http_client_service.dart';

class NotificationProvider extends ChangeNotifier {
  bool _hasUnread = false;
  String? _authToken;
  bool _isChecking = false;

  bool get hasUnread => _hasUnread;

  void updateAuthToken(String? token) {
    if (_authToken == token) return;
    _authToken = token;
    if (token == null || token.isEmpty) {
      if (_hasUnread) {
        _hasUnread = false;
        notifyListeners();
      }
    } else {
      checkForUnread();
    }
  }

  Future<void> checkForUnread() async {
    if (_isChecking) return;
    final token = _authToken;
    if (token == null || token.isEmpty) return;

    _isChecking = true;
    try {
      final uri = Uri.parse(AppConfig.serverHttpBaseUrl)
          .resolve('/api/notifications?limit=1&unreadOnly=true');
      final res = await HttpClientService.client.get(
        uri,
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      );
      if (res.statusCode != 200) return;

      final data = jsonDecode(res.body);
      final list = (data is Map && data['notifications'] is List)
          ? (data['notifications'] as List)
          : const [];
      final hasUnread = list.isNotEmpty;
      if (hasUnread != _hasUnread) {
        _hasUnread = hasUnread;
        notifyListeners();
      }
    } catch (_) {
      // Ignore errors; badge will stay in last known state
    } finally {
      _isChecking = false;
    }
  }
}

