import 'dart:convert';
import 'dart:io';
import 'package:package_info_plus/package_info_plus.dart';
import '../config/app_config.dart';
import 'http_client_service.dart';

class VersionCheckResult {
  final String platform;
  final bool hasUpdate;
  final LatestVersion? latestVersion;
  final String currentVersion;

  VersionCheckResult({
    required this.platform,
    required this.hasUpdate,
    this.latestVersion,
    required this.currentVersion,
  });

  factory VersionCheckResult.fromJson(Map<String, dynamic> json) {
    return VersionCheckResult(
      platform: json['platform'] as String? ?? '',
      hasUpdate: json['hasUpdate'] == true,
      latestVersion: json['latestVersion'] != null
          ? LatestVersion.fromJson(json['latestVersion'] as Map<String, dynamic>)
          : null,
      currentVersion: json['currentVersion'] as String? ?? '',
    );
  }
}

class LatestVersion {
  final String version;
  final String downloadUrl;
  final String fileName;
  final int fileSize;
  final String releaseNotes;
  final DateTime? uploadedAt;

  LatestVersion({
    required this.version,
    required this.downloadUrl,
    required this.fileName,
    required this.fileSize,
    required this.releaseNotes,
    this.uploadedAt,
  });

  factory LatestVersion.fromJson(Map<String, dynamic> json) {
    DateTime? uploadedAt;
    if (json['uploadedAt'] != null) {
      try {
        uploadedAt = DateTime.parse(json['uploadedAt'] as String);
      } catch (_) {
        // Ignore parse errors
      }
    }
    return LatestVersion(
      version: json['version'] as String? ?? '',
      downloadUrl: json['downloadUrl'] as String? ?? '',
      fileName: json['fileName'] as String? ?? '',
      fileSize: json['fileSize'] as int? ?? 0,
      releaseNotes: json['releaseNotes'] as String? ?? '',
      uploadedAt: uploadedAt,
    );
  }
}

class VersionCheckService {
  static String _getPlatform() {
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    return 'unknown';
  }

  static Future<VersionCheckResult?> checkForUpdate() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;
      final platform = _getPlatform();

      final uri = Uri.parse(AppConfig.serverHttpBaseUrl)
          .resolve('/api/version/check')
          .replace(queryParameters: {
        'platform': platform,
        'currentVersion': currentVersion,
      });

      final response = await HttpClientService.client
          .get(uri, headers: {'Content-Type': 'application/json'})
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        return null;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return VersionCheckResult.fromJson(data);
    } catch (e) {
      // Silently fail - don't interrupt app startup if version check fails
      print('[VersionCheck] Error checking for updates: $e');
      return null;
    }
  }
}
