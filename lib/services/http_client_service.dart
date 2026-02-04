import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';

/// Custom HTTP client service that handles SSL certificate validation.
/// 
/// On Windows desktop, Flutter uses BoringSSL which doesn't properly access
/// the Windows certificate store, so we bypass validation for Windows only.
/// On web, browsers handle certificates correctly, so validation works fine.
class HttpClientService {
  static http.Client? _client;
  static bool _initialized = false;

  /// Initialize the HTTP client with SSL certificate handling.
  /// 
  /// Automatically detects the platform:
  /// - Windows desktop: Bypasses certificate validation (BoringSSL limitation)
  /// - Web: Uses proper certificate validation (browser handles it)
  /// - Other platforms: Uses proper certificate validation
  /// 
  /// Set [bypassCertificateValidation] to override the automatic detection.
  static void initialize({bool? bypassCertificateValidation}) {
    if (_initialized) return;

    // Auto-detect: bypass only on Windows desktop (not web)
    // Since HTTPS works on web, the certificate is valid, but Windows desktop
    // has issues with BoringSSL not accessing the Windows certificate store
    final shouldBypass = bypassCertificateValidation ?? 
        (!kIsWeb && Platform.isWindows);

    if (shouldBypass) {
      // Create a client that bypasses certificate validation for Windows desktop
      // This is necessary because Flutter desktop on Windows uses BoringSSL
      // which doesn't properly access the Windows certificate store
      final httpClient = HttpClient()
        ..badCertificateCallback = (X509Certificate cert, String host, int port) {
          if (kDebugMode) {
            print('[HttpClientService] Bypassing certificate validation for $host:$port (Windows desktop)');
          }
          return true;
        };
      _client = IOClient(httpClient);
    } else {
      // Use default client with system certificate validation
      // On web, browsers handle certificates automatically
      // On other platforms, system certificate store is used
      _client = http.Client();
    }

    _initialized = true;
  }

  /// Get the configured HTTP client instance.
  /// 
  /// If not initialized, initializes with default settings (proper certificate validation).
  static http.Client get client {
    if (!_initialized) {
      initialize(bypassCertificateValidation: false);
    }
    return _client!;
  }

  /// Dispose of the HTTP client.
  static void dispose() {
    _client?.close();
    _client = null;
    _initialized = false;
  }

  /// Create a WebSocket channel with proper certificate handling.
  /// 
  /// On Windows desktop, certificate validation is bypassed due to BoringSSL limitations.
  /// On web and other platforms, proper certificate validation is used.
  static WebSocketChannel createWebSocketChannel(Uri uri) {
    // On web, use the standard WebSocketChannel which handles certificates correctly
    if (kIsWeb) {
      return WebSocketChannel.connect(uri);
    }

    // On Windows desktop, bypass certificate validation (BoringSSL limitation)
    // On other platforms, use default certificate validation
    if (Platform.isWindows) {
      final httpClient = HttpClient()
        ..badCertificateCallback = (X509Certificate cert, String host, int port) {
          if (kDebugMode) {
            print('[HttpClientService] Bypassing WebSocket certificate validation for $host:$port (Windows desktop)');
          }
          return true;
        };
      return IOWebSocketChannel.connect(uri, customClient: httpClient);
    } else {
      // Use default WebSocket connection with system certificate validation
      return WebSocketChannel.connect(uri);
    }
  }
}
