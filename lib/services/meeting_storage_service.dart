import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/meeting_session.dart';
import '../config/app_config.dart';
import 'http_client_service.dart';

class MeetingStorageService {
  String? _authToken;
  
  String? get authToken => _authToken;

  void setAuthToken(String? token) {
    _authToken = token;
  }

  Map<String, String> _getHeaders() {
    final headers = <String, String>{
      'Content-Type': 'application/json',
    };
    if (_authToken != null && _authToken!.isNotEmpty) {
      headers['Authorization'] = 'Bearer $_authToken';
    }
    return headers;
  }

  String _getApiUrl(String path) {
    final base = AppConfig.serverHttpBaseUrl;
    final cleanBase = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final cleanPath = path.startsWith('/') ? path : '/$path';
    return '$cleanBase$cleanPath';
  }

  Future<MeetingSession> saveSession(MeetingSession session) async {
    try {
      final url = _getApiUrl('/api/sessions');
      final body = session.toJson();
      
      // Check if session ID is a valid MongoDB ObjectId (24 hex characters)
      final isValidObjectId = session.id != null && 
          RegExp(r'^[0-9a-fA-F]{24}$').hasMatch(session.id!);
      
      if (isValidObjectId) {
        // Try to update existing session
        final response = await HttpClientService.client.put(
          Uri.parse('$url/${session.id}'),
          headers: _getHeaders(),
          body: jsonEncode(body),
        );

        if (response.statusCode == 201 || response.statusCode == 200) {
          // Successfully created or updated
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          return MeetingSession.fromJson(data);
        } else if (response.statusCode == 404) {
          // Session doesn't exist, create it
          final createResponse = await HttpClientService.client.post(
            Uri.parse(url),
            headers: _getHeaders(),
            body: jsonEncode(body),
          );

          if (createResponse.statusCode != 201) {
            final error = jsonDecode(createResponse.body)['error'] ?? 'Failed to create session';
            throw Exception(error);
          }
          final data = jsonDecode(createResponse.body) as Map<String, dynamic>;
          return MeetingSession.fromJson(data);
        } else {
          final error = jsonDecode(response.body)['error'] ?? 'Failed to save session';
          throw Exception(error);
        }
      } else {
        // Not a valid ObjectId, create new session
        final createResponse = await HttpClientService.client.post(
          Uri.parse(url),
          headers: _getHeaders(),
          body: jsonEncode(body),
        );

        if (createResponse.statusCode != 201) {
          final error = jsonDecode(createResponse.body)['error'] ?? 'Failed to create session';
          throw Exception(error);
        }
        final data = jsonDecode(createResponse.body) as Map<String, dynamic>;
        return MeetingSession.fromJson(data);
      }
    } catch (e) {
      throw Exception('Failed to save session: $e');
    }
  }

  Future<MeetingSession?> loadSession(String sessionId) async {
    try {
      final url = _getApiUrl('/api/sessions/$sessionId');
      final response = await HttpClientService.client.get(
        Uri.parse(url),
        headers: _getHeaders(),
      );

      if (response.statusCode == 404) {
        return null;
      }

      if (response.statusCode != 200) {
        final error = jsonDecode(response.body)['error'] ?? 'Failed to load session';
        throw Exception(error);
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return MeetingSession.fromJson(data);
    } catch (e) {
      throw Exception('Failed to load session: $e');
    }
  }

  Future<List<MeetingSession>> listSessions({
    int? limit,
    int? skip,
    String? search,
  }) async {
    try {
      if (_authToken == null || _authToken!.isEmpty) {
        throw Exception('No token provided');
      }
      
      final uri = Uri.parse(_getApiUrl('/api/sessions')).replace(
        queryParameters: {
          if (limit != null) 'limit': limit.toString(),
          if (skip != null) 'skip': skip.toString(),
          if (search != null && search.isNotEmpty) 'search': search,
        },
      );
      
      final response = await HttpClientService.client.get(
        uri,
        headers: _getHeaders(),
      );

      if (response.statusCode == 401) {
        throw Exception('Authentication failed. Please sign in again.');
      }

      if (response.statusCode != 200) {
        final error = jsonDecode(response.body)['error'] ?? 'Failed to list sessions';
        throw Exception(error);
      }

      final decoded = jsonDecode(response.body);
      // Support both:
      // - { sessions: [...], total: ... } (current)
      // - [...] (legacy)
      // - { sessions: { ... } } (bad/legacy data) -> treat values as list
      final dynamic sessionsRaw = decoded is Map<String, dynamic> ? decoded['sessions'] : decoded;
      final List<dynamic> sessionsList = switch (sessionsRaw) {
        List<dynamic> v => v,
        Map v => v.values.toList(growable: false),
        _ => const <dynamic>[],
      };
      return sessionsList
          .map((item) => MeetingSession.fromJson(item as Map<String, dynamic>))
          .toList();
    } catch (e) {
      throw Exception('Failed to list sessions: $e');
    }
  }
  
  Future<int> getSessionsCount({String? search}) async {
    try {
      if (_authToken == null || _authToken!.isEmpty) {
        throw Exception('No token provided');
      }
      
      final uri = Uri.parse(_getApiUrl('/api/sessions')).replace(
        queryParameters: {
          'limit': '1', // Just need count, so limit to 1
          if (search != null && search.isNotEmpty) 'search': search,
        },
      );
      
      final response = await HttpClientService.client.get(
        uri,
        headers: _getHeaders(),
      );

      if (response.statusCode == 401) {
        throw Exception('Authentication failed. Please sign in again.');
      }

      if (response.statusCode != 200) {
        final error = jsonDecode(response.body)['error'] ?? 'Failed to get sessions count';
        throw Exception(error);
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return data['total'] as int? ?? 0;
    } catch (e) {
      throw Exception('Failed to get sessions count: $e');
    }
  }

  Future<void> deleteSession(String sessionId) async {
    try {
      final url = _getApiUrl('/api/sessions/$sessionId');
      final response = await HttpClientService.client.delete(
        Uri.parse(url),
        headers: _getHeaders(),
      );

      if (response.statusCode == 404) {
        // Session doesn't exist, consider it deleted
        return;
      }

      if (response.statusCode != 204) {
        final error = jsonDecode(response.body)['error'] ?? 'Failed to delete session';
        throw Exception(error);
      }
    } catch (e) {
      throw Exception('Failed to delete session: $e');
    }
  }

  Future<String> exportSessionAsText(MeetingSession session) async {
    final buffer = StringBuffer();
    buffer.writeln('Meeting Session: ${session.title}');
    buffer.writeln('Created: ${session.createdAt.toLocal()}');
    if (session.updatedAt != null) {
      buffer.writeln('Updated: ${session.updatedAt!.toLocal()}');
    }
    buffer.writeln('Duration: ${_formatDuration(session.duration)}');
    buffer.writeln('');
    buffer.writeln('=' * 60);
    buffer.writeln('');

    if (session.summary != null && session.summary!.isNotEmpty) {
      buffer.writeln('SUMMARY');
      buffer.writeln('-' * 60);
      buffer.writeln(session.summary);
      buffer.writeln('');
    }

    if (session.insights != null && session.insights!.isNotEmpty) {
      buffer.writeln('INSIGHTS');
      buffer.writeln('-' * 60);
      buffer.writeln(session.insights);
      buffer.writeln('');
    }

    final rawMarkers = session.metadata['markers'];
    if (rawMarkers is List && rawMarkers.isNotEmpty) {
      buffer.writeln('MARKERS');
      buffer.writeln('-' * 60);
      for (final item in rawMarkers) {
        if (item is! Map) continue;
        final m = Map<String, dynamic>.from(item);
        final at = (m['at']?.toString() ?? '').trim();
        final label = (m['label']?.toString() ?? '').trim();
        final text = (m['text']?.toString() ?? '').trim();
        final source = (m['source']?.toString() ?? '').trim();
        final line = [
          if (at.isNotEmpty) at,
          if (source.isNotEmpty) '[$source]',
          if (label.isNotEmpty) label,
          if (text.isNotEmpty) '— $text',
        ].join(' ');
        if (line.trim().isNotEmpty) buffer.writeln('- $line');
      }
      buffer.writeln('');
    }

    buffer.writeln('TRANSCRIPT');
    buffer.writeln('-' * 60);
    buffer.writeln(session.fullTranscript);

    return buffer.toString();
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) {
      return '${hours}h ${minutes}m ${seconds}s';
    } else if (minutes > 0) {
      return '${minutes}m ${seconds}s';
    } else {
      return '${seconds}s';
    }
  }
}
