import 'package:flutter/foundation.dart';
import '../services/billing_service.dart';
import '../providers/meeting_provider.dart';

class DashboardStats {
  final String plan;
  final int totalMeetingMinutes;
  final int apiUsedTokens;
  final int apiLimitTokens;
  final double apiUsagePercentage;
  final int transcriptionUsedMinutes;
  final int transcriptionLimitMinutes;
  final double transcriptionUsagePercentage;

  DashboardStats({
    required this.plan,
    required this.totalMeetingMinutes,
    required this.apiUsedTokens,
    required this.apiLimitTokens,
    required this.apiUsagePercentage,
    required this.transcriptionUsedMinutes,
    required this.transcriptionLimitMinutes,
    required this.transcriptionUsagePercentage,
  });

  String get planDisplayName {
    switch (plan.toLowerCase()) {
      case 'free':
        return 'Free';
      case 'pro':
        return 'Pro';
      case 'pro_plus':
        return 'Pro Plus';
      default:
        return plan;
    }
  }

  String get formattedTotalMeetingTime {
    final hours = totalMeetingMinutes ~/ 60;
    final minutes = totalMeetingMinutes % 60;
    if (hours > 0) {
      return '${hours}h ${minutes}m';
    }
    return '${minutes}m';
  }
}

class DashboardProvider extends ChangeNotifier {
  final BillingService _billingService = BillingService();
  final MeetingProvider _meetingProvider;

  DashboardStats? _stats;
  bool _isLoading = false;
  String? _error;

  DashboardProvider(this._meetingProvider);

  DashboardStats? get stats => _stats;
  bool get isLoading => _isLoading;
  String? get error => _error;

  void setAuthToken(String? token) {
    _billingService.setAuthToken(token);
  }

  Future<void> loadStats() async {
    if (_isLoading) return;

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      // Fetch billing info
      final billingInfo = await _billingService.getMe();

      // Calculate total meeting time from all sessions
      final sessions = _meetingProvider.sessions;
      int totalMinutes = 0;
      for (final session in sessions) {
        totalMinutes += session.duration.inMinutes;
      }

      // Calculate API usage percentage
      final apiUsagePercentage = billingInfo.aiLimitTokens > 0
          ? (billingInfo.aiUsedTokens / billingInfo.aiLimitTokens * 100).clamp(0.0, 100.0)
          : 0.0;

      // Calculate transcription usage percentage
      final transcriptionUsagePercentage = billingInfo.limitMinutes > 0
          ? (billingInfo.usedMinutes / billingInfo.limitMinutes * 100).clamp(0.0, 100.0)
          : 0.0;

      _stats = DashboardStats(
        plan: billingInfo.plan,
        totalMeetingMinutes: totalMinutes,
        apiUsedTokens: billingInfo.aiUsedTokens,
        apiLimitTokens: billingInfo.aiLimitTokens,
        apiUsagePercentage: apiUsagePercentage,
        transcriptionUsedMinutes: billingInfo.usedMinutes,
        transcriptionLimitMinutes: billingInfo.limitMinutes,
        transcriptionUsagePercentage: transcriptionUsagePercentage,
      );

      _error = null;
    } catch (e) {
      _error = e.toString();
      _stats = null;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> refresh() async {
    await loadStats();
  }
}
