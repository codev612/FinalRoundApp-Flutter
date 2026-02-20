import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'http_client_service.dart';

/// AI client that can call the backend via HTTP or via WebSocket streaming.
class AiService {
  final String httpBaseUrl;

  /// If provided, AI calls will prefer streaming over WebSocket to this URL.
  /// Example: `ws://localhost:3000/ai`
  final String? aiWsUrl;

  String? _authToken;
  WebSocketChannel? _aiChannel;
  StreamSubscription? _aiSub;
  final Map<String, StreamController<String>> _streams = {};
  VoidCallback? _onSessionRevoked;

  AiService({required this.httpBaseUrl, this.aiWsUrl, String? authToken}) : _authToken = authToken;

  void setAuthToken(String? token) {
    final tokenChanged = _authToken != token;
    _authToken = token;
    // Only disconnect if token actually changed (not just set for the first time)
    if (tokenChanged && _aiChannel != null) {
      disconnectAi();
    }
  }

  void setOnSessionRevoked(VoidCallback? cb) {
    _onSessionRevoked = cb;
  }

  Future<void> _ensureAiConnected() async {
    if (aiWsUrl == null) return;
    // Resource optimization: Reuse existing WebSocket connection if still open
    if (_aiChannel != null) {
      // Check if connection is still valid (readyState check would require platform channel)
      // For now, assume connection is valid if channel exists
      return;
    }
    if (_authToken == null || _authToken!.isEmpty) {
      throw Exception('Authentication required');
    }

    // Build WebSocket URL with auth token
    var wsUrl = aiWsUrl!;
    final uri = Uri.parse(wsUrl);
    wsUrl = uri.replace(queryParameters: {
      ...uri.queryParameters,
      'token': _authToken!,
    }).toString();

    print('[AiService] Connecting to AI WebSocket: $wsUrl');
    _aiChannel = HttpClientService.createWebSocketChannel(Uri.parse(wsUrl));
    print('[AiService] AI WebSocket connected (reused for multiple requests)');
    _aiSub = _aiChannel!.stream.listen(
      (message) {
        try {
          final data = jsonDecode(message);
          if (data is! Map<String, dynamic>) {
            print('[AiService] Received non-map message: $message');
            return;
          }

          final type = data['type']?.toString() ?? '';
          final requestId = data['requestId']?.toString() ?? '';

          if (type == 'session_revoked') {
            // Server revoked this auth session. Force sign-out and reset WS.
            try {
              _onSessionRevoked?.call();
            } catch (_) {}
            disconnectAi();
            return;
          }
          
          // Handle ai_start message (has requestId but is just a notification)
          if (type == 'ai_start') {
            print('[AiService] Received ai_start for request $requestId');
            // Don't need to do anything, just wait for deltas
            return;
          }

          // All other messages should have a requestId
          if (requestId.isEmpty) {
            print('[AiService] Received message without requestId: type=$type, data=$data');
            return;
          }

          final ctrl = _streams[requestId];
          if (ctrl == null) {
            print('[AiService] Received message for unknown requestId: $requestId, type=$type');
            return;
          }

          if (type == 'ai_delta') {
            final delta = data['delta']?.toString() ?? '';
            if (delta.isNotEmpty) {
              ctrl.add(delta);
            }
            return;
          }
          if (type == 'ai_done') {
            print('[AiService] Received ai_done for request $requestId');
            ctrl.close();
            _streams.remove(requestId);
            return;
          }
          if (type == 'ai_error') {
            final msg = data['message']?.toString() ?? 'AI error';
            print('[AiService] AI error for request $requestId: $msg');
            ctrl.addError(msg);
            ctrl.close();
            _streams.remove(requestId);
            return;
          }
          
          print('[AiService] Unknown message type: $type for request $requestId');
        } catch (e) {
          // Log parse errors but don't disconnect
          print('[AiService] Error parsing message: $e, message: $message');
        }
      },
      onError: (e) {
        print('[AiService] WebSocket error: $e');
        // Only disconnect if it's a critical error
        // Don't disconnect on transient errors - let the connection retry
        for (final ctrl in _streams.values) {
          if (!ctrl.isClosed) {
            ctrl.addError(e);
            ctrl.close();
          }
        }
        _streams.clear();
        // Don't disconnect immediately - let it retry on next request
        // disconnectAi();
      },
      onDone: () {
        print('[AiService] WebSocket connection closed (onDone)');
        // Connection closed - clear streams but don't disconnect (already closed)
        for (final ctrl in _streams.values) {
          if (!ctrl.isClosed) {
            ctrl.addError('AI connection closed');
            ctrl.close();
          }
        }
        _streams.clear();
        // Reset channel so it can reconnect on next request
        _aiSub = null;
        _aiChannel = null;
      },
    );
  }

  /// Stream AI tokens from the backend over WebSocket.
  /// Emits token deltas as they arrive.
  Stream<String> streamRespond({
    required List<Map<String, String>> turns,
    String? question,
    String mode = 'reply',
    String? systemPrompt,
    String? model,
    List<Map<String, dynamic>>? previousAiResponses,
    Duration timeout = const Duration(seconds: 60),
  }) {
    if (aiWsUrl == null) {
      return Stream.error('AI WebSocket not configured');
    }

    final requestId = DateTime.now().microsecondsSinceEpoch.toString();
    final controller = StreamController<String>();
    _streams[requestId] = controller;

    () async {
      try {
        print('[AiService] streamRespond: mode=$mode, requestId=$requestId, turns=${turns.length}');
        await _ensureAiConnected();
        
        if (_aiChannel == null) {
          print('[AiService] Failed to establish connection, falling back to HTTP');
          final ctrl = _streams.remove(requestId);
          if (ctrl != null && !ctrl.isClosed) {
            ctrl.addError('Failed to establish AI connection');
            ctrl.close();
          }
          return;
        }

        final payload = <String, dynamic>{
          'type': 'ai_request',
          'requestId': requestId,
          'mode': mode,
          'turns': turns,
        };

        final q = question?.trim() ?? '';
        if (q.isNotEmpty) payload['question'] = q;
        
        final prompt = systemPrompt?.trim() ?? '';
        if (prompt.isNotEmpty) payload['systemPrompt'] = prompt;

        final chosenModel = model?.trim() ?? '';
        if (chosenModel.isNotEmpty) payload['model'] = chosenModel;
        
        if (previousAiResponses != null && previousAiResponses.isNotEmpty) {
          payload['previousAiResponses'] = previousAiResponses;
        }

        print('[AiService] Sending ai_request: mode=$mode, requestId=$requestId');
        try {
          _aiChannel!.sink.add(jsonEncode(payload));
          print('[AiService] Request sent successfully');
        } catch (e) {
          // Connection might be closed, reset it
          print('[AiService] Error sending request, resetting connection: $e');
          _aiChannel = null;
          _aiSub = null;
          final ctrl = _streams.remove(requestId);
          if (ctrl != null && !ctrl.isClosed) {
            ctrl.addError('Connection lost, please try again');
            ctrl.close();
          }
        }

        // Timeout protection
        Future.delayed(timeout, () {
          final ctrl = _streams.remove(requestId);
          if (ctrl != null && !ctrl.isClosed) {
            print('[AiService] Request $requestId timed out after ${timeout.inSeconds}s');
            try {
              _aiChannel?.sink.add(jsonEncode({'type': 'ai_cancel', 'requestId': requestId}));
            } catch (_) {}
            ctrl.addError('AI request timed out');
            ctrl.close();
          }
        });
      } catch (e, stackTrace) {
        print('[AiService] Error in streamRespond setup: $e');
        print('[AiService] Stack trace: $stackTrace');
        final ctrl = _streams.remove(requestId);
        if (ctrl != null && !ctrl.isClosed) {
          ctrl.addError(e);
          ctrl.close();
        }
      }
    }();

    return controller.stream;
  }

  /// Non-streaming response (string). If WS is configured, we stream and aggregate.
  Future<String> respond({
    required List<Map<String, String>> turns,
    String? question,
    String mode = 'reply',
    String? systemPrompt,
    String? model,
    List<Uint8List>? imagesPngBytes,
    List<Map<String, dynamic>>? previousAiResponses,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final validImages = imagesPngBytes?.where((b) => b.isNotEmpty).toList() ?? [];
    final hasImages = validImages.isNotEmpty;

    // For image requests, prefer HTTP (payload can be large and WS may have size limits).
    if (aiWsUrl != null && !hasImages) {
      final buffer = StringBuffer();
      try {
        await for (final delta in streamRespond(
          turns: turns,
          question: question,
          mode: mode,
          systemPrompt: systemPrompt,
          model: model,
          previousAiResponses: previousAiResponses,
          timeout: timeout,
        )) {
          buffer.write(delta);
        }
        final result = buffer.toString().trim();
        if (result.isEmpty) {
          throw Exception('AI response was empty');
        }
        return result;
      } catch (e) {
        print('[AiService] Error in streamRespond for mode=$mode: $e');
        // If WebSocket fails, fall back to HTTP
        print('[AiService] Falling back to HTTP for mode=$mode');
      }
    }

    final uri = Uri.parse(httpBaseUrl).resolve('/ai/respond');
    final payload = <String, dynamic>{'mode': mode, 'turns': turns};

    final q = question?.trim() ?? '';
    if (q.isNotEmpty) payload['question'] = q;
    
    final prompt = systemPrompt?.trim() ?? '';
    if (prompt.isNotEmpty) payload['systemPrompt'] = prompt;

    final chosenModel = model?.trim() ?? '';
    if (chosenModel.isNotEmpty) payload['model'] = chosenModel;

    if (hasImages) {
      payload['imagesPngBase64'] = validImages.map((b) => base64Encode(b)).toList();
    }
    
    if (previousAiResponses != null && previousAiResponses.isNotEmpty) {
      payload['previousAiResponses'] = previousAiResponses;
    }

    final headers = <String, String>{
      'Content-Type': 'application/json',
    };
    if (_authToken != null && _authToken!.isNotEmpty) {
      headers['Authorization'] = 'Bearer $_authToken';
    }

    final response = await HttpClientService.client
        .post(
          uri,
          headers: headers,
          body: jsonEncode(payload),
        )
        .timeout(timeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final bodyText = response.body;
      String? extracted;
      try {
        final data = jsonDecode(bodyText);
        if (data is Map<String, dynamic>) {
          final e = (data['error']?.toString() ?? '').trim();
          final m = (data['message']?.toString() ?? '').trim();
          extracted = e.isNotEmpty ? e : (m.isNotEmpty ? m : null);
        }
      } on FormatException {
        // Non-JSON response body
      }

      if (response.statusCode == 402) {
        // Always present a clear upgrade message for quota errors.
        final msg = (extracted ?? '').trim();
        throw Exception(msg.isNotEmpty ? msg : 'AI usage limit reached. Please upgrade your plan to continue.');
      }

      if ((extracted ?? '').trim().isNotEmpty) {
        throw Exception(extracted!.trim());
      }

      final trimmed = bodyText.trim();
      if (trimmed.isNotEmpty) {
        // Avoid dumping huge HTML pages into the UI.
        final safe = trimmed.length > 400 ? '${trimmed.substring(0, 400)}…' : trimmed;
        throw Exception(safe);
      }

      throw Exception('HTTP ${response.statusCode}');
    }

    final data = jsonDecode(response.body);
    if (data is! Map<String, dynamic>) throw Exception('Unexpected response');
    return (data['text']?.toString() ?? '').trim();
  }

  Future<String> generateSummary({
    required List<Map<String, String>> turns,
    String? notesTemplate,
    String? model,
    Duration timeout = const Duration(seconds: 60),
  }) {
    String? systemPrompt;
    if (notesTemplate != null && notesTemplate.isNotEmpty) {
      systemPrompt = '''You are generating a summary using the following notes template structure. Your task is to fill in each section with actual content from the conversation transcript.

IMPORTANT: 
- Use the EXACT section headings from the template below
- Fill each section with detailed, relevant content from the conversation
- Do NOT leave sections empty or use placeholder text
- Extract and organize information from the transcript into the appropriate sections
- Maintain the same markdown formatting (## for headings)

Notes Template Structure:
$notesTemplate

Now generate the summary by filling in all sections with content from the conversation.''';
    }
    return respond(turns: turns, mode: 'summary', systemPrompt: systemPrompt, model: model, timeout: timeout);
  }

  Future<String> generateInsights({
    required List<Map<String, String>> turns,
    String? model,
    Duration timeout = const Duration(seconds: 60),
  }) =>
      respond(turns: turns, mode: 'insights', model: model, timeout: timeout);

  Future<String> generateQuestions({
    required List<Map<String, String>> turns,
    String? model,
    Duration timeout = const Duration(seconds: 60),
  }) =>
      respond(turns: turns, mode: 'questions', model: model, timeout: timeout);

  void disconnectAi() {
    try {
      _aiSub?.cancel();
    } catch (_) {}
    _aiSub = null;
    try {
      _aiChannel?.sink.close();
    } catch (_) {}
    _aiChannel = null;
  }

  void dispose() {
    disconnectAi();
    for (final ctrl in _streams.values) {
      if (!ctrl.isClosed) ctrl.close();
    }
    _streams.clear();
  }
}
