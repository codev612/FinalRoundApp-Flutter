import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config/app_config.dart';
import 'http_client_service.dart';

class BillingInfo {
  final String plan; // free, pro, pro_plus
  final DateTime periodStartUtc;
  final DateTime periodEndUtc;
  final int limitMinutes;
  final int usedMinutes;
  final int remainingMinutes;
  final bool canUseSummary;
  final List<String> allowedModels;
  final int aiLimitTokens;
  final int aiUsedTokens;
  final int aiRemainingTokens;
  final int? aiLimitRequests;
  final int aiUsedRequests;
  final int? aiRemainingRequests;
  final Map<String, Map<String, int>> aiByModel; // model -> { usedTokens, requests, limitTokens?, remainingTokens? }

  BillingInfo({
    required this.plan,
    required this.periodStartUtc,
    required this.periodEndUtc,
    required this.limitMinutes,
    required this.usedMinutes,
    required this.remainingMinutes,
    required this.canUseSummary,
    required this.allowedModels,
    required this.aiLimitTokens,
    required this.aiUsedTokens,
    required this.aiRemainingTokens,
    required this.aiLimitRequests,
    required this.aiUsedRequests,
    required this.aiRemainingRequests,
    required this.aiByModel,
  });

  factory BillingInfo.fromJson(Map<String, dynamic> json) {
    final bp = (json['billingPeriod'] as Map<String, dynamic>? ?? const {});
    final transcription = (json['transcription'] as Map<String, dynamic>? ?? const {});
    final ai = (json['ai'] as Map<String, dynamic>? ?? const {});

    final rawByModel = ai['byModel'];
    final Map<String, Map<String, int>> byModel = {};
    if (rawByModel is Map) {
      for (final entry in rawByModel.entries) {
        final k = entry.key?.toString();
        final v = entry.value;
        if (k == null || k.trim().isEmpty) continue;
        if (v is! Map) continue;
        int getInt(String key) => (v[key] as num?)?.toInt() ?? 0;
        final m = <String, int>{
          'usedTokens': getInt('usedTokens'),
          'requests': getInt('requests'),
        };
        if (v['limitTokens'] is num) m['limitTokens'] = (v['limitTokens'] as num).toInt();
        if (v['remainingTokens'] is num) m['remainingTokens'] = (v['remainingTokens'] as num).toInt();
        byModel[k] = m;
      }
    }

    return BillingInfo(
      plan: (json['plan'] as String?) ?? 'free',
      periodStartUtc: DateTime.parse((bp['start'] as String?) ?? DateTime.now().toUtc().toIso8601String()),
      periodEndUtc: DateTime.parse((bp['end'] as String?) ?? DateTime.now().toUtc().toIso8601String()),
      limitMinutes: (transcription['limitMinutes'] as num?)?.toInt() ?? 0,
      usedMinutes: (transcription['usedMinutes'] as num?)?.toInt() ?? 0,
      remainingMinutes: (transcription['remainingMinutes'] as num?)?.toInt() ?? 0,
      canUseSummary: (ai['canUseSummary'] as bool?) ?? false,
      allowedModels: ((ai['allowedModels'] as List?) ?? const [])
          .whereType<String>()
          .toList(growable: false),
      aiLimitTokens: (ai['limitTokens'] as num?)?.toInt() ?? 0,
      aiUsedTokens: (ai['usedTokens'] as num?)?.toInt() ?? 0,
      aiRemainingTokens: (ai['remainingTokens'] as num?)?.toInt() ?? 0,
      aiLimitRequests: (ai['limitRequests'] as num?)?.toInt(),
      aiUsedRequests: (ai['usedRequests'] as num?)?.toInt() ?? 0,
      aiRemainingRequests: (ai['remainingRequests'] as num?)?.toInt(),
      aiByModel: byModel,
    );
  }
}

class BillingService {
  String? _authToken;

  void setAuthToken(String? token) {
    _authToken = token;
  }

  Map<String, String> _headers() {
    final h = <String, String>{
      'Content-Type': 'application/json',
    };
    if (_authToken != null && _authToken!.isNotEmpty) {
      h['Authorization'] = 'Bearer $_authToken';
    }
    return h;
  }

  String _apiUrl(String path) {
    final base = AppConfig.serverHttpBaseUrl;
    final cleanBase = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final cleanPath = path.startsWith('/') ? path : '/$path';
    return '$cleanBase$cleanPath';
  }

  Future<BillingInfo> getMe() async {
    final uri = Uri.parse(_apiUrl('/api/billing/me'));
    final response = await HttpClientService.client.get(uri, headers: _headers()).timeout(const Duration(seconds: 10));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      try {
        final data = jsonDecode(response.body);
        final error = data is Map<String, dynamic> ? (data['error']?.toString() ?? '') : '';
        throw Exception(error.isNotEmpty ? error : 'HTTP ${response.statusCode}');
      } catch (_) {
        throw Exception('HTTP ${response.statusCode}');
      }
    }
    final data = jsonDecode(response.body);
    if (data is! Map<String, dynamic>) throw Exception('Unexpected response');
    return BillingInfo.fromJson(data);
  }

  Future<void> recordTranscriptionUsage({required int durationMs, String? sessionId}) async {
    final uri = Uri.parse(_apiUrl('/api/billing/transcription-usage'));
    final payload = <String, dynamic>{
      'durationMs': durationMs,
    };
    if (sessionId != null && sessionId.trim().isNotEmpty) {
      payload['sessionId'] = sessionId.trim();
    }
    final response = await http
        .post(uri, headers: _headers(), body: jsonEncode(payload))
        .timeout(const Duration(seconds: 10));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      // Best-effort: do not throw hard errors in caller unless needed.
      try {
        final data = jsonDecode(response.body);
        final error = data is Map<String, dynamic> ? (data['error']?.toString() ?? '') : '';
        throw Exception(error.isNotEmpty ? error : 'HTTP ${response.statusCode}');
      } catch (_) {
        throw Exception('HTTP ${response.statusCode}');
      }
    }
  }
}

