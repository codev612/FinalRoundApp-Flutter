import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/custom_question_template.dart';
import '../config/app_config.dart';
import 'http_client_service.dart';

class MeetingQuestionService {
  static const String _customQuestionsKey = 'custom_question_templates';
  static const List<String> _defaultQuestions = [
    'What should I say?',
  ];

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
    if (base.endsWith('/')) {
      return '$base${path.startsWith('/') ? path.substring(1) : path}';
    }
    return '$base${path.startsWith('/') ? path : '/$path'}';
  }

  List<String> getQuestionsByCategory(String category) {
    return _defaultQuestions;
  }

  Future<List<String>> getAllQuestions() async {
    final customTemplates = await getCustomTemplates();
    final customQuestions = customTemplates.map((t) => t.question).toList();
    return [..._defaultQuestions, ...customQuestions];
  }

  Future<List<String>> getRandomQuestions(int count) async {
    final all = await getAllQuestions();
    all.shuffle();
    return all.take(count).toList();
  }

  Future<Map<String, List<String>>> getQuestionsByCategoryMap() async {
    final allQuestions = await getAllQuestions();
    return {
      'Questions': allQuestions,
    };
  }

  /// Get all custom question templates
  Future<List<CustomQuestionTemplate>> getCustomTemplates() async {
    if (_authToken != null && _authToken!.isNotEmpty) {
      try {
        final url = _getApiUrl('/api/question-templates');
        print('[QuestionService] Loading templates from DB: $url');
        final response = await HttpClientService.client.get(Uri.parse(url), headers: _getHeaders());
        print('[QuestionService] Load response: ${response.statusCode}');
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body) as List<dynamic>;
          print('[QuestionService] Loaded ${data.length} templates from DB');
          final apiList = (data.map((e) => CustomQuestionTemplate.fromJson(e as Map<String, dynamic>))).toList();
          final cached = await _loadCachedTemplates();
          print('[QuestionService] Cached templates: ${cached.length}');
          if (apiList.isEmpty) {
            if (cached.isNotEmpty) {
              print('[QuestionService] DB empty, returning cached templates');
              return cached;
            }
            return [];
          }
          final merged = <String, CustomQuestionTemplate>{};
          for (final t in apiList) merged[t.id] = t;
          for (final t in cached) merged[t.id] = t;
          final result = merged.values.toList();
          await _cacheTemplates(result);
          print('[QuestionService] Returning ${result.length} merged templates');
          return result;
        } else {
          print('[QuestionService] Load failed: ${response.statusCode} ${response.body}');
        }
      } catch (e) {
        print('[QuestionService] Failed to load question templates from DB: $e');
      }
    } else {
      print('[QuestionService] No auth token, loading from cache only');
    }
    final cached = await _loadCachedTemplates();
    print('[QuestionService] Returning ${cached.length} cached templates');
    return cached;
  }

  Future<List<CustomQuestionTemplate>> _loadCachedTemplates() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_customQuestionsKey);
    if (raw == null) return [];
    try {
      final data = jsonDecode(raw) as List<dynamic>;
      return data.map((e) => CustomQuestionTemplate.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }

  /// Add a custom question template
  Future<void> addCustomTemplate(CustomQuestionTemplate template) async {
    final list = await getCustomTemplates();
    if (list.any((e) => e.id == template.id)) return;
    list.add(template);
    await _saveCustomTemplates(list);
  }

  /// Update a custom question template
  Future<void> updateCustomTemplate(CustomQuestionTemplate template) async {
    final list = await getCustomTemplates();
    final index = list.indexWhere((e) => e.id == template.id);
    if (index >= 0) {
      list[index] = template;
    } else {
      list.add(template);
    }
    await _saveCustomTemplates(list);
  }

  /// Delete a custom question template
  Future<void> deleteCustomTemplate(String id) async {
    // Delete from database
    if (_authToken != null && _authToken!.isNotEmpty) {
      try {
        final url = _getApiUrl('/api/question-templates/${Uri.encodeComponent(id)}');
        final response = await HttpClientService.client.delete(Uri.parse(url), headers: _getHeaders());
        if (response.statusCode == 200) {
          // Successfully deleted from DB, update cache
          final list = await getCustomTemplates();
          list.removeWhere((e) => e.id == id);
          await _cacheTemplates(list);
          return;
        } else {
          throw Exception('Failed to delete template: ${response.statusCode}');
        }
      } catch (e) {
        print('Failed to delete template from DB: $e');
        // Fall through to local cache
      }
    }
    
    // Fallback to local cache
    final list = await getCustomTemplates();
    list.removeWhere((e) => e.id == id);
    await _cacheTemplates(list);
  }

  Future<void> _saveCustomTemplates(List<CustomQuestionTemplate> list) async {
    // Always persist to local cache first so data survives restart even if PUT fails
    await _cacheTemplates(list);
    if (_authToken != null && _authToken!.isNotEmpty) {
      try {
        final url = _getApiUrl('/api/question-templates');
        final body = jsonEncode(list.map((e) => e.toJson()).toList());
        print('[QuestionService] Saving ${list.length} templates to DB');
        final response = await HttpClientService.client.put(
          Uri.parse(url),
          headers: _getHeaders(),
          body: body,
        );
        print('[QuestionService] Save response: ${response.statusCode}');
        if (response.statusCode != 200 && response.statusCode != 201) {
          print('[QuestionService] Save failed: ${response.body}');
          throw Exception('Failed to save question templates to DB: ${response.statusCode} ${response.body}');
        }
        print('[QuestionService] Successfully saved templates to DB');
      } catch (e) {
        print('[QuestionService] Error saving to DB: $e');
        // Don't throw - local cache is already saved
      }
    } else {
      print('[QuestionService] No auth token, saving to local cache only');
    }
  }

  Future<void> _cacheTemplates(List<CustomQuestionTemplate> list) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_customQuestionsKey, jsonEncode(list.map((e) => e.toJson()).toList()));
  }
}
