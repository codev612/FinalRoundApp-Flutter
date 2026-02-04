class AppConfig {
  static const String defaultServerWebSocketUrl = 'wss://app.finalroundapp.com/listen';
  static const String defaultServerHttpBaseUrl = 'https://app.finalroundapp.com';

  /// Override at build/run time with:
  /// `--dart-define=HEARNOW_SERVER_URL=wss://app.finalroundapp.com/listen`
  static const String serverWebSocketUrl = String.fromEnvironment(
    'HEARNOW_SERVER_URL',
    defaultValue: defaultServerWebSocketUrl,
  );

  /// Override at build/run time with:
  /// `--dart-define=HEARNOW_SERVER_HTTP_BASE_URL=https://app.finalroundapp.com`
  static const String serverHttpBaseUrlOverride = String.fromEnvironment(
    'HEARNOW_SERVER_HTTP_BASE_URL',
    defaultValue: '',
  );

  static String get serverHttpBaseUrl {
    if (serverHttpBaseUrlOverride.trim().isNotEmpty) {
      return serverHttpBaseUrlOverride.trim();
    }

    // Derive from the WebSocket URL (ws->http, wss->https) and strip /listen.
    var base = serverWebSocketUrl.trim();
    if (base.endsWith('/listen')) {
      base = base.substring(0, base.length - '/listen'.length);
    }

    if (base.startsWith('ws://')) {
      return 'http://' + base.substring('ws://'.length);
    }
    if (base.startsWith('wss://')) {
      return 'https://' + base.substring('wss://'.length);
    }

    return defaultServerHttpBaseUrl;
  }

  /// AI WebSocket endpoint used for streaming AI responses to the app.
  /// Derived from `serverWebSocketUrl` by swapping `/listen` for `/ai`.
  static String get serverAiWebSocketUrl {
    var base = serverWebSocketUrl.trim();
    if (base.endsWith('/listen')) {
      return base.substring(0, base.length - '/listen'.length) + '/ai';
    }
    // Fallback: append /ai
    if (base.endsWith('/')) return base + 'ai';
    return base + '/ai';
  }
}
