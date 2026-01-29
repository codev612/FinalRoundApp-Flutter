import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

class TranscriptionService {
  WebSocketChannel? _channel;
  StreamSubscription? _channelSubscription;
  bool _disconnecting = false;

  final String serverUrl;
  String? _authToken;
  final StreamController<TranscriptionResult> _transcriptController =
      StreamController<TranscriptionResult>.broadcast();

  TranscriptionService({required this.serverUrl, String? authToken}) : _authToken = authToken;

  void setAuthToken(String? token) {
    _authToken = token;
  }

  Stream<TranscriptionResult> get transcriptStream => _transcriptController.stream;
  bool get isConnected => _channel != null;

  Future<void> connect() async {
    try {
      print('[TranscriptionService] Connecting to: $serverUrl');
      // Build WebSocket URL with auth token if available
      var wsUrl = serverUrl;
      if (_authToken != null && _authToken!.isNotEmpty) {
        final uri = Uri.parse(wsUrl);
        wsUrl = uri.replace(queryParameters: {
          ...uri.queryParameters,
          'token': _authToken!,
        }).toString();
      }
      _channel = WebSocketChannel.connect(Uri.parse(wsUrl));

      // Cancel any existing subscription first
      _channelSubscription?.cancel();
      _channelSubscription = _channel!.stream.listen(
        (message) {
          // Check if we're disconnecting before processing
          if (_disconnecting || _channel == null) {
            return;
          }
          
          final data = jsonDecode(message);

          if (data['type'] == 'transcript') {
            final text = (data['text'] as String?) ?? '';
            if (text.trim().isEmpty) return;
            
            final receivedSource = (data['source'] as String?) ?? 'unknown';
            print('[TranscriptionService] Received transcript with source: "$receivedSource", text: "${text.substring(0, text.length > 50 ? 50 : text.length)}..."');

            _transcriptController.add(
              TranscriptionResult(
                text: text,
                isFinal: data['is_final'] == true,
                source: receivedSource,
                confidence: data['confidence']?.toDouble() ?? 0.0,
              ),
            );
            return;
          }

          if (data['type'] == 'status') {
            return;
          }

          if (data['type'] == 'error') {
            print('[TranscriptionService] Error from server: ${data['message']}');
            _transcriptController.addError(data['message']);
            return;
          }
        },
        onError: (error) {
          if (_disconnecting) return;
          print('[TranscriptionService] WebSocket error: $error');
          if (!_transcriptController.isClosed) {
            _transcriptController.addError(error);
          }
          disconnect();
        },
        onDone: () {
          if (_disconnecting) return;
          print('[TranscriptionService] WebSocket closed');
          disconnect();
        },
      );

      print('[TranscriptionService] Connected, sending start message');
      _channel!.sink.add(jsonEncode({'type': 'start'}));
    } catch (e) {
      print('[TranscriptionService] Connection error: $e');
      _transcriptController.addError(e);
      rethrow;
    }
  }

  void sendAudio(dynamic audioData, {String source = 'mic'}) {
    final channel = _channel;
    if (channel == null) {
      // Avoid log spam in tight loop.
      return;
    }

    try {
      final Uint8List audioBytes = switch (audioData) {
        Uint8List v => v,
        List<int> v => Uint8List.fromList(v),
        _ => throw ArgumentError('Unexpected audio type: ${audioData.runtimeType}'),
      };

      final base64Audio = base64Encode(audioBytes);
      channel.sink.add(
        jsonEncode({
          'type': 'audio',
          'source': source,
          'audio': base64Audio,
        }),
      );
    } catch (e) {
      print('[TranscriptionService] Error sending audio: $e');
    }
  }

  void disconnect() {
    if (_disconnecting) return;

    final channel = _channel;
    if (channel == null) return;

    _disconnecting = true;
    
    // Cancel stream subscription first
    try {
      _channelSubscription?.cancel();
    } catch (_) {}
    _channelSubscription = null;
    
    _channel = null; // prevent re-entrancy from onDone/onError

    try {
      channel.sink.add(jsonEncode({'type': 'stop'}));
    } catch (_) {}
    try {
      channel.sink.close();
    } catch (_) {}

    _disconnecting = false;
  }

  void dispose() {
    disconnect();
    _transcriptController.close();
  }
}

class TranscriptionResult {
  final String text;
  final bool isFinal;
  final String source;
  final double confidence;

  TranscriptionResult({
    required this.text,
    required this.isFinal,
    required this.source,
    required this.confidence,
  });
}
