class AppConfig {
  static const String defaultServerWebSocketUrl = 'ws://localhost:3000/listen';

  /// Override at build/run time with:
  /// `--dart-define=HEARNOW_SERVER_URL=ws://<host>:3000/listen`
  static const String serverWebSocketUrl = String.fromEnvironment(
    'HEARNOW_SERVER_URL',
    defaultValue: defaultServerWebSocketUrl,
  );
}
