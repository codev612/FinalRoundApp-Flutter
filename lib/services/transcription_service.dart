import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

class TranscriptionService {
  WebSocketChannel? _channel;
  bool _disconnecting = false;

  final String serverUrl;
  final StreamController<TranscriptionResult> _transcriptController =
      StreamController<TranscriptionResult>.broadcast();

  TranscriptionService({required this.serverUrl});

  Stream<TranscriptionResult> get transcriptStream => _transcriptController.stream;
  bool get isConnected => _channel != null;

  Future<void> connect() async {
    try {
      print('[TranscriptionService] Connecting to: $serverUrl');
      _channel = WebSocketChannel.connect(Uri.parse(serverUrl));

      _channel!.stream.listen(
        (message) {
          print('[TranscriptionService] Received: $message');
          final data = jsonDecode(message);

          if (data['type'] == 'transcript') {
            final text = (data['text'] as String?) ?? '';
            if (text.trim().isEmpty) return;

            _transcriptController.add(
              TranscriptionResult(
                text: text,
                isFinal: data['is_final'] == true,
                source: (data['source'] as String?) ?? 'unknown',
                confidence: data['confidence']?.toDouble() ?? 0.0,
              ),
            );
            return;
          }

          if (data['type'] == 'status') {
            print('[TranscriptionService] Status: ${data['message']}');
            return;
          }

          if (data['type'] == 'error') {
            print('[TranscriptionService] Error from server: ${data['message']}');
            _transcriptController.addError(data['message']);
            return;
          }
        },
        onError: (error) {
          print('[TranscriptionService] WebSocket error: $error');
          _transcriptController.addError(error);
          disconnect();
        },
        onDone: () {
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
