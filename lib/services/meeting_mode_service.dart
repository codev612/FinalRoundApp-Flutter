import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/meeting_mode.dart';
import '../models/custom_meeting_mode.dart';
import '../config/app_config.dart';
import 'http_client_service.dart';

/// Display info for mode dropdown / list. [modeKey] is enum name or "custom:{id}".
class ModeDisplay {
  final String modeKey;
  final String label;
  final IconData icon;

  const ModeDisplay({required this.modeKey, required this.label, required this.icon});
}

class MeetingModeConfig {
  final MeetingMode mode;
  final String realTimePrompt;
  final String notesTemplate;

  MeetingModeConfig({
    required this.mode,
    required this.realTimePrompt,
    required this.notesTemplate,
  });

  Map<String, dynamic> toJson() {
    return {
      'mode': mode.name,
      'realTimePrompt': realTimePrompt,
      'notesTemplate': notesTemplate,
    };
  }

  factory MeetingModeConfig.fromJson(Map<String, dynamic> json) {
    return MeetingModeConfig(
      mode: MeetingMode.fromString(json['mode'] as String?),
      realTimePrompt: json['realTimePrompt'] as String? ?? '',
      notesTemplate: json['notesTemplate'] as String? ?? '',
    );
  }

  MeetingModeConfig copyWith({
    String? realTimePrompt,
    String? notesTemplate,
  }) {
    return MeetingModeConfig(
      mode: mode,
      realTimePrompt: realTimePrompt ?? this.realTimePrompt,
      notesTemplate: notesTemplate ?? this.notesTemplate,
    );
  }
}

class MeetingModeService {
  static const String _configsKey = 'meeting_mode_configs';
  static const String _customModesKey = 'meeting_custom_modes';
  static const String _customPrefix = 'custom:';

  static bool isCustomModeKey(String key) => key.startsWith(_customPrefix);
  static String customModeKey(String id) => '$_customPrefix$id';

  /// Notify listeners when custom modes were added/removed/updated elsewhere. Bump to refresh dropdowns.
  static final ValueNotifier<int> customModesVersion = ValueNotifier(0);

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

  Future<Map<MeetingMode, MeetingModeConfig>> getAllConfigs() async {
    // Try to load from database first
    if (_authToken != null && _authToken!.isNotEmpty) {
      try {
        final url = _getApiUrl('/api/mode-configs');
        final response = await HttpClientService.client.get(
          Uri.parse(url),
          headers: _getHeaders(),
        );

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          // Start from cache so local notes templates persist when API has no/partial data
          final configs = await _loadCachedConfigs();
          for (final mode in MeetingMode.values) {
            if (data.containsKey(mode.name)) {
              final configData = data[mode.name] as Map<String, dynamic>;
              var cfg = MeetingModeConfig.fromJson({
                'mode': mode.name,
                ...configData,
              });
              if (cfg.notesTemplate == _legacyDefaultNotesTemplate) {
                cfg = cfg.copyWith(notesTemplate: defaultNotesTemplate);
              }
              configs[mode] = cfg;
            }
            // else keep configs[mode] from cache
          }
          await _cacheConfigs(configs);
          return configs;
        } else if (response.statusCode == 404) {
          // No configs in DB yet — keep local cache so notes templates etc. persist after restart
          return await _loadCachedConfigs();
        }
      } catch (e) {
        // Fall through to local cache/defaults
        print('Failed to load configs from DB: $e');
      }
    }
    
    // Fallback to local cache
    return await _loadCachedConfigs();
  }

  Future<void> saveConfig(MeetingModeConfig config) async {
    // Save to database
    if (_authToken != null && _authToken!.isNotEmpty) {
      try {
        final url = _getApiUrl('/api/mode-configs/${config.mode.name}');
        final response = await HttpClientService.client.put(
          Uri.parse(url),
          headers: _getHeaders(),
          body: jsonEncode(config.toJson()),
        );

        if (response.statusCode == 200 || response.statusCode == 201) {
          // Successfully saved to DB, update cache
          final allConfigs = await getAllConfigs();
          allConfigs[config.mode] = config;
          await _cacheConfigs(allConfigs);
          return;
        } else {
          throw Exception('Failed to save config: ${response.statusCode}');
        }
      } catch (e) {
        // Fall through to local cache
        print('Failed to save config to DB: $e');
      }
    }
    
    // Fallback to local cache
    final prefs = await SharedPreferences.getInstance();
    final allConfigs = await _loadCachedConfigs();
    allConfigs[config.mode] = config;
    await _cacheConfigs(allConfigs);
  }

  Future<MeetingModeConfig> getConfig(MeetingMode mode) async {
    final configs = await getAllConfigs();
    return configs[mode] ?? getDefaultConfig(mode);
  }

  /// All modes for dropdown: built-in + custom. [modeKey] is enum name or "custom:id".
  Future<List<ModeDisplay>> getModeDisplays() async {
    final list = <ModeDisplay>[];
    for (final m in MeetingMode.values) {
      list.add(ModeDisplay(modeKey: m.name, label: m.label, icon: m.icon));
    }
    final custom = await getCustomModes();
    for (final c in custom) {
      list.add(ModeDisplay(modeKey: customModeKey(c.id), label: c.label, icon: c.icon));
    }
    return list;
  }

  /// Only custom modes for the session mode dropdown (no template/built-in modes).
  Future<List<ModeDisplay>> getCustomOnlyModeDisplays() async {
    final custom = await getCustomModes();
    return custom
        .map((c) => ModeDisplay(modeKey: customModeKey(c.id), label: c.label, icon: c.icon))
        .toList();
  }

  /// Config for a session's mode (built-in or custom).
  Future<MeetingModeConfig> getConfigForModeKey(String modeKey) async {
    if (isCustomModeKey(modeKey)) {
      final id = modeKey.substring(_customPrefix.length);
      final customList = (await getCustomModes()).where((c) => c.id == id).toList();
      if (customList.isNotEmpty) {
        final custom = customList.first;
        return MeetingModeConfig(
          mode: MeetingMode.other,
          realTimePrompt: custom.realTimePrompt,
          notesTemplate: custom.notesTemplate,
        );
      }
    }
    final mode = MeetingMode.fromString(modeKey);
    return getConfig(mode);
  }

  Future<List<CustomMeetingMode>> getCustomModes() async {
    if (_authToken != null && _authToken!.isNotEmpty) {
      try {
        final url = _getApiUrl('/api/custom-mode-configs');
        final response = await HttpClientService.client.get(Uri.parse(url), headers: _getHeaders());
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body) as List<dynamic>;
          final apiList = (data.map((e) => CustomMeetingMode.fromJson(e as Map<String, dynamic>))).toList();
          final cached = await _loadCachedCustomModes();
          if (apiList.isEmpty) {
            if (cached.isNotEmpty) return cached;
            final defaults = MeetingModeService.getDefaultCustomModes();
            await _saveCustomModes(defaults);
            return defaults;
          }
          final merged = <String, CustomMeetingMode>{};
          for (final m in apiList) merged[m.id] = m;
          for (final m in cached) merged[m.id] = m;
          final result = merged.values.toList();
          await _cacheCustomModes(result);
          return result;
        }
      } catch (e) {
        print('Failed to load custom modes from DB: $e');
      }
    }
    final cached = await _loadCachedCustomModes();
    if (cached.isEmpty) {
      final defaults = MeetingModeService.getDefaultCustomModes();
      await _cacheCustomModes(defaults);
      return defaults;
    }
    return cached;
  }

  Future<void> addCustomMode(CustomMeetingMode custom) async {
    final list = await getCustomModes();
    if (list.any((e) => e.id == custom.id)) return;
    list.add(custom);
    await _saveCustomModes(list);
    customModesVersion.value++;
  }

  Future<void> updateCustomMode(CustomMeetingMode custom) async {
    final list = await getCustomModes();
    final id = custom.id;
    // Build a new list replacing only the mode with matching id, so other modes keep their own notesTemplate
    final toSave = [
      for (final m in list)
        if (m.id == id) custom else CustomMeetingMode(
          id: m.id,
          label: m.label,
          iconCodePoint: m.iconCodePoint,
          realTimePrompt: m.realTimePrompt,
          notesTemplate: m.notesTemplate,
        ),
    ];
    if (!list.any((e) => e.id == id)) {
      toSave.add(custom);
    }
    await _saveCustomModes(toSave);
  }

  /// Deletes one custom mode by id. [authToken] is used for the API request.
  Future<void> deleteCustomMode(String id, {String? authToken}) async {
    final tokenToUse = (authToken != null && authToken.isNotEmpty) ? authToken! : _authToken;
    if (tokenToUse == null || tokenToUse.isEmpty) {
      // Offline: only update local cache
      debugPrint('[RemoveMode] deleteCustomMode id=$id: no token, updating local cache only');
      final list = List<CustomMeetingMode>.from(await getCustomModes());
      final before = list.length;
      list.removeWhere((e) => e.id == id);
      await _cacheCustomModes(list);
      customModesVersion.value++;
      debugPrint('[RemoveMode] deleteCustomMode offline done: list $before -> ${list.length}');
      return;
    }
    _authToken = tokenToUse;
    final url = _getApiUrl('/api/custom-mode-configs/${Uri.encodeComponent(id)}');
    debugPrint('[RemoveMode] deleteCustomMode id=$id: sending DELETE $url');
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $tokenToUse',
    };
    final response = await HttpClientService.client.delete(Uri.parse(url), headers: headers);
    debugPrint('[RemoveMode] deleteCustomMode response: status=${response.statusCode} body=${response.body}');
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception('Failed to delete custom mode: ${response.statusCode} ${response.body}');
    }
    // Refresh from API only — do not use getCustomModes() here, it merges with cache
    // and would bring the deleted mode back (cache is still stale).
    final getUrl = _getApiUrl('/api/custom-mode-configs');
    final getResponse = await HttpClientService.client.get(Uri.parse(getUrl), headers: headers);
    if (getResponse.statusCode == 200) {
      final data = jsonDecode(getResponse.body) as List<dynamic>;
      final list = (data.map((e) => CustomMeetingMode.fromJson(e as Map<String, dynamic>))).toList();
      await _cacheCustomModes(list);
      customModesVersion.value++;
      debugPrint('[RemoveMode] deleteCustomMode done, cache refreshed from API length=${list.length}');
    }
  }

  Future<void> _saveCustomModes(List<CustomMeetingMode> list) async {
    // Always persist to local cache first so data survives restart even if PUT fails
    await _cacheCustomModes(list);
    if (_authToken != null && _authToken!.isNotEmpty) {
      final url = _getApiUrl('/api/custom-mode-configs');
      final body = jsonEncode(list.map((e) => e.toJson()).toList());
      final response = await HttpClientService.client.put(
        Uri.parse(url),
        headers: _getHeaders(),
        body: body,
      );
      if (response.statusCode != 200 && response.statusCode != 201) {
        throw Exception('Failed to save custom modes to DB: ${response.statusCode} ${response.body}');
      }
    }
  }

  Future<void> _cacheCustomModes(List<CustomMeetingMode> list) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_customModesKey, jsonEncode(list.map((e) => e.toJson()).toList()));
  }

  Future<List<CustomMeetingMode>> _loadCachedCustomModes() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_customModesKey);
    if (raw == null) return [];
    try {
      final data = jsonDecode(raw) as List<dynamic>;
      return data.map((e) => CustomMeetingMode.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }

  Future<Map<MeetingMode, MeetingModeConfig>> _loadCachedConfigs() async {
    final prefs = await SharedPreferences.getInstance();
    final configsJson = prefs.getString(_configsKey);
    
    if (configsJson == null) {
      return _getDefaultConfigs();
    }

    try {
      final Map<String, dynamic> decoded = jsonDecode(configsJson) as Map<String, dynamic>;
      
      final configs = <MeetingMode, MeetingModeConfig>{};
      for (final mode in MeetingMode.values) {
        MeetingModeConfig cfg;
        if (decoded.containsKey(mode.name)) {
          final configData = decoded[mode.name] as Map<String, dynamic>;
          cfg = MeetingModeConfig.fromJson({
            'mode': mode.name,
            ...configData,
          });
          if (cfg.notesTemplate == _legacyDefaultNotesTemplate) {
            cfg = cfg.copyWith(notesTemplate: defaultNotesTemplate);
          }
        } else {
          cfg = getDefaultConfig(mode);
        }
        configs[mode] = cfg;
      }
      return configs;
    } catch (e) {
      return _getDefaultConfigs();
    }
  }

  Future<void> _cacheConfigs(Map<MeetingMode, MeetingModeConfig> configs) async {
    final prefs = await SharedPreferences.getInstance();
    final configsMap = configs.map((key, value) => 
      MapEntry(key.name, value.toJson())
    );
    await prefs.setString(_configsKey, jsonEncode(configsMap));
  }

  /// Default notes template used by all modes: Overview, Background, Questions, Summary, Action Items.
  static const String defaultNotesTemplate =
      '## Overview\n'
      'Brief summary of what this meeting or conversation is about.\n\n'
      '## Background\n'
      'Context and relevant information shared before or during the discussion.\n\n'
      '## Questions\n'
      'Key questions raised, answered, or still open.\n\n'
      '## Summary\n'
      'Main points, decisions, and outcomes from the conversation.\n\n'
      '## Action Items\n'
      'Tasks, next steps, owners, and deadlines.';

  /// Legacy default without descriptions; migrated to [defaultNotesTemplate] when loading.
  static const String _legacyDefaultNotesTemplate =
      '## Overview\n\n## Background\n\n## Questions\n- \n\n## Summary\n\n## Action Items\n- ';

  static MeetingModeConfig getDefaultConfig(MeetingMode mode) {
    switch (mode) {
      case MeetingMode.general:
        return MeetingModeConfig(
          mode: mode,
          realTimePrompt: 'You are a helpful assistant. Provide concise, relevant responses based on the conversation. Keep responses brief and easy to scan. Use **bold** for main answers and bullet points (•) for tips.',
          notesTemplate: defaultNotesTemplate,
        );
      case MeetingMode.interview:
        return MeetingModeConfig(
          mode: mode,
          realTimePrompt: 'You are an interview assistant. Help identify key candidate qualifications, strengths, and areas of concern. Ask relevant follow-up questions. Keep responses concise. Use **bold** for key qualifications and bullet points (•) for strengths/concerns.',
          notesTemplate: defaultNotesTemplate,
        );
      case MeetingMode.presentation:
        return MeetingModeConfig(
          mode: mode,
          realTimePrompt: 'You are a presentation assistant. Help summarize key points, identify questions from the audience, and suggest clarifications. Keep responses concise. Use **bold** for main points and bullet points (•) for questions or suggestions.',
          notesTemplate: defaultNotesTemplate,
        );
      case MeetingMode.discussion:
        return MeetingModeConfig(
          mode: mode,
          realTimePrompt: 'You are a discussion facilitator. Help identify main topics, summarize different viewpoints, and highlight decisions made. Keep responses concise. Use **bold** for decisions and bullet points (•) for key topics.',
          notesTemplate: defaultNotesTemplate,
        );
      case MeetingMode.lecture:
        return MeetingModeConfig(
          mode: mode,
          realTimePrompt: 'You are a lecture assistant. Help summarize main concepts, identify important examples, and note questions from students. Keep responses concise. Use **bold** for key concepts and bullet points (•) for examples or questions.',
          notesTemplate: defaultNotesTemplate,
        );
      case MeetingMode.meeting:
        return MeetingModeConfig(
          mode: mode,
          realTimePrompt: 'You are a meeting assistant. Help track agenda items, summarize discussions, and identify action items and decisions. Keep responses concise. Use **bold** for decisions and bullet points (•) for action items.',
          notesTemplate: defaultNotesTemplate,
        );
      case MeetingMode.call:
        return MeetingModeConfig(
          mode: mode,
          realTimePrompt: 'You are a call assistant. Help summarize the conversation, identify important information exchanged, and note follow-ups. Keep responses concise. Use **bold** for key information and bullet points (•) for follow-ups.',
          notesTemplate: defaultNotesTemplate,
        );
      case MeetingMode.brainstorm:
        return MeetingModeConfig(
          mode: mode,
          realTimePrompt: 'You are a brainstorm facilitator. Help capture ideas, group related concepts, identify themes, and suggest next steps or priorities. Keep responses concise. Use **bold** for themes and bullet points (•) for ideas or next steps.',
          notesTemplate: defaultNotesTemplate,
        );
      case MeetingMode.other:
        return MeetingModeConfig(
          mode: mode,
          realTimePrompt: 'You are a helpful assistant. Provide concise, relevant responses based on the conversation. Keep responses brief and easy to scan. Use **bold** for main answers and bullet points (•) for tips.',
          notesTemplate: defaultNotesTemplate,
        );
    }
  }

  static Map<MeetingMode, MeetingModeConfig> _getDefaultConfigs() {
    return {
      for (final mode in MeetingMode.values)
        mode: getDefaultConfig(mode),
    };
  }

  /// Default custom modes: one per built-in template. Used when the user has no custom modes yet.
  static List<CustomMeetingMode> getDefaultCustomModes() {
    return [
      for (final mode in MeetingMode.values)
        CustomMeetingMode(
          id: 'default-${mode.name}',
          label: mode.label,
          iconCodePoint: mode.icon.codePoint,
          realTimePrompt: getDefaultConfig(mode).realTimePrompt,
          notesTemplate: getDefaultConfig(mode).notesTemplate,
        ),
    ];
  }
}
