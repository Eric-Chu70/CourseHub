import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CourseData {
  final String name;
  final String? teacher;
  final String? location;
  final int dayOfWeek;
  final int? period;
  final int? duration;
  final String? startTime;
  final String? endTime;
  final int? startWeek;
  final int? endWeek;
  final String? weeks;
  final String? color;
  final String? notes;

  CourseData({
    required this.name,
    this.teacher,
    this.location,
    required this.dayOfWeek,
    this.period,
    this.duration,
    this.startTime,
    this.endTime,
    this.startWeek,
    this.endWeek,
    this.weeks,
    this.color,
    this.notes,
  });

  factory CourseData.fromJson(Map<String, dynamic> json) {
    return CourseData(
      name: json['name']?.toString() ?? '',
      teacher: json['teacher']?.toString(),
      location: json['location']?.toString(),
      dayOfWeek: (json['dayOfWeek'] is int) ? json['dayOfWeek'] : int.tryParse(json['dayOfWeek']?.toString() ?? '1') ?? 1,
      period: json['period'] != null ? (json['period'] is int ? json['period'] : int.tryParse(json['period'].toString())) : null,
      duration: json['duration'] != null ? (json['duration'] is int ? json['duration'] : int.tryParse(json['duration'].toString())) : null,
      startTime: json['startTime']?.toString(),
      endTime: json['endTime']?.toString(),
      startWeek: json['startWeek'] != null ? (json['startWeek'] is int ? json['startWeek'] : int.tryParse(json['startWeek'].toString())) : null,
      endWeek: json['endWeek'] != null ? (json['endWeek'] is int ? json['endWeek'] : int.tryParse(json['endWeek'].toString())) : null,
      weeks: json['weeks']?.toString(),
      color: json['color']?.toString(),
      notes: json['notes']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'teacher': teacher,
      'location': location,
      'dayOfWeek': dayOfWeek,
      'period': period,
      'duration': duration,
      'startTime': startTime,
      'endTime': endTime,
      'startWeek': startWeek,
      'endWeek': endWeek,
      'weeks': weeks,
      'color': color,
      'notes': notes,
    };
  }
}

class GLMParseResult {
  final List<CourseData> courses;
  final String rawContent;
  final String? selectedModel;

  GLMParseResult({required this.courses, required this.rawContent, this.selectedModel});
}

enum AIProvider {
  custom,
  agnes,
  builtin,
}

class AIService {
  static final AIService _instance = AIService._internal();
  factory AIService() => _instance;
  AIService._internal();

  static AIService get instance => _instance;

  static const String _defaultCustomModel = 'gpt-4o-mini';

  // Agnes AI：OpenAI 兼容接口，直接以 Bearer 密钥调用
  static const String _agnesBaseUrl = 'https://api.agnes-ai.cn/v1/chat/completions';
  static const String _defaultAgnesModel = 'agnes-2.0-flash';

  static const String _nonDoubaoEdgeFunctionUrl = 'https://jnwhpbkhvumiyjwyjwhu.supabase.co/functions/v1/NonDoubaoAPI';

  // 内置模型（限时免费）：单一 Supabase Edge Function，请求体带 node 字段（1-4）
  // 区分节点，函数内部按节点查表选择模型与密钥。请求/响应协议与 NonDoubaoAPI
  // 完全一致（流式 SSE：content/status/thinking），客户端无需携带任何密钥
  static const String _builtinEndpointUrl =
      'https://jnwhpbkhvumiyjwyjwhu.supabase.co/functions/v1/BuiltinModel';
  int _builtinNode = 1;

  // 会话级标记：每次进入 App（进程启动）后，首次通过内置模型发起 AI 请求时
  // 随机选择 1-4 号节点并写回偏好（供设置页/徽章展示真实节点）；会话内用户
  // 在设置页手动切换节点仍然生效，重启 App 后重新随机
  bool _builtinNodeRandomizedThisSession = false;

  Future<void> _randomizeBuiltinNodeForSession() async {
    if (_builtinNodeRandomizedThisSession) return;
    _builtinNodeRandomizedThisSession = true;
    _builtinNode = math.Random().nextInt(4) + 1;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('builtin_node', _builtinNode);
  }

  String? _customApiUrl;
  String? _customApiKey;
  String? _customModel;
  String? _agnesApiKey;
  String _agnesModel = _defaultAgnesModel;
  String _currentProviderStr = 'builtin';

  AIProvider _provider = AIProvider.builtin;
  /// 内置模型：切换节点（1-4），并立即持久化
  Future<void> setBuiltinNode(int node) async {
    if (node < 1 || node > 4) return;
    _builtinNode = node;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('builtin_node', node);
  }

  void setCustomApiConfig({
    required String apiUrl,
    required String apiKey,
    String? model,
  }) {
    _customApiUrl = apiUrl;
    _customApiKey = apiKey;
    _customModel = (model != null && model.trim().isNotEmpty) ? model.trim() : _defaultCustomModel;
  }

  String _customReasoningCacheKey({
    required String apiUrl,
    required String model,
  }) {
    final uri = Uri.tryParse(apiUrl);
    final endpoint = (uri != null && uri.host.isNotEmpty)
        ? '${uri.scheme}://${uri.host}${uri.path}'
        : apiUrl;
    return 'custom_reasoning_capability::$endpoint::${model.trim()}';
  }

  String _customVisionCacheKey({
    required String apiUrl,
    required String model,
  }) {
    final uri = Uri.tryParse(apiUrl);
    final endpoint = (uri != null && uri.host.isNotEmpty)
        ? '${uri.scheme}://${uri.host}${uri.path}'
        : apiUrl;
    return 'custom_vision_capability::$endpoint::${model.trim()}';
  }

  Future<void> _cacheCustomVisionCapability({
    required String apiUrl,
    required String model,
    required bool supportsVision,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _customVisionCacheKey(apiUrl: apiUrl, model: model);
    await prefs.setBool(key, supportsVision);
  }

  Future<void> setCustomVisionManualOverride({
    required bool enabled,
    required bool supportsVision,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('custom_api_vision_manual_override', enabled);
    await prefs.setBool('custom_api_vision_manual_value', supportsVision);
  }

  Future<String?> getCustomReasoningEffort() async {
    final prefs = await SharedPreferences.getInstance();
    final val = prefs.getString('custom_api_reasoning_effort') ?? '';
    return val.isEmpty ? null : val;
  }

  Future<void> setCustomReasoningEffort(String? effort) async {
    final prefs = await SharedPreferences.getInstance();
    if (effort != null && effort.isNotEmpty) {
      await prefs.setString('custom_api_reasoning_effort', effort);
    } else {
      await prefs.remove('custom_api_reasoning_effort');
    }
  }

  Future<bool> isCustomVisionManualOverrideEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('custom_api_vision_manual_override') ?? false;
  }

  Future<bool> getCustomVisionManualValue() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('custom_api_vision_manual_value') ?? false;
  }

  Future<bool?> getCustomVisionSupport({
    required String model,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final manualOverride = prefs.getBool('custom_api_vision_manual_override') ?? false;
    if (manualOverride) {
      return prefs.getBool('custom_api_vision_manual_value') ?? false;
    }

    String apiUrl = (_customApiUrl ?? '').trim();
    if (apiUrl.isEmpty) {
      apiUrl = (prefs.getString('custom_api_url') ?? '').trim();
      _customApiUrl = apiUrl;
    }
    if (apiUrl.isEmpty || model.trim().isEmpty) return null;

    final key = _customVisionCacheKey(apiUrl: apiUrl, model: model);
    return prefs.getBool(key);
  }

  Future<bool?> probeCustomVisionSupport({
    String? model,
  }) async {
    if (_customApiUrl == null || _customApiKey == null || _customApiUrl!.isEmpty || _customApiKey!.isEmpty) {
      final prefs = await SharedPreferences.getInstance();
      _customApiUrl = prefs.getString('custom_api_url');
      _customApiKey = prefs.getString('custom_api_key');
      _customModel = prefs.getString('custom_api_model');
    }

    final prefs = await SharedPreferences.getInstance();
    if ((prefs.getBool('custom_api_vision_manual_override') ?? false)) {
      return prefs.getBool('custom_api_vision_manual_value') ?? false;
    }

    final apiUrl = (_customApiUrl ?? '').trim();
    final apiKey = (_customApiKey ?? '').trim();
    final resolvedModel = (model != null && model.trim().isNotEmpty)
        ? model.trim()
        : ((_customModel != null && _customModel!.trim().isNotEmpty)
            ? _customModel!.trim()
            : _defaultCustomModel);

    if (apiUrl.isEmpty || apiKey.isEmpty) return null;

    const tinyImageBase64 =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9VE3d2QAAAAASUVORK5CYII=';
    final httpClient = HttpClient();

    try {
      final request = await httpClient.postUrl(Uri.parse(apiUrl));
      request.headers.contentType = ContentType.json;
      request.headers.set('Authorization', 'Bearer $apiKey');
      request.write(jsonEncode({
        'model': resolvedModel,
        'stream': false,
        'max_tokens': 1,
        'messages': [
          {
            'role': 'user',
            'content': [
              {
                'type': 'image_url',
                'image_url': {
                  'url': 'data:image/png;base64,$tinyImageBase64',
                },
              },
              {
                'type': 'text',
                'text': '请回复ok',
              },
            ],
          },
        ],
      }));

      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();

      if (response.statusCode == 200) {
        await _cacheCustomVisionCapability(
          apiUrl: apiUrl,
          model: resolvedModel,
          supportsVision: true,
        );
        return true;
      }

      final lowered = responseBody.toLowerCase();
      final isVisionUnsupported =
          lowered.contains('image') ||
          lowered.contains('vision') ||
          lowered.contains('multimodal') ||
          lowered.contains('unsupported') ||
          lowered.contains('not support');

      if (isVisionUnsupported) {
        await _cacheCustomVisionCapability(
          apiUrl: apiUrl,
          model: resolvedModel,
          supportsVision: false,
        );
        return false;
      }

      return null;
    } catch (_) {
      return null;
    } finally {
      httpClient.close();
    }
  }

  Future<bool> getCachedReasoningCapability({
    required String model,
  }) async {
    String apiUrl = (_customApiUrl ?? '').trim();
    if (apiUrl.isEmpty) {
      final prefs = await SharedPreferences.getInstance();
      apiUrl = (prefs.getString('custom_api_url') ?? '').trim();
      _customApiUrl = apiUrl;
    }
    if (apiUrl.isEmpty || model.trim().isEmpty) return false;

    final prefs = await SharedPreferences.getInstance();
    final key = _customReasoningCacheKey(apiUrl: apiUrl, model: model);
    return prefs.getBool(key) ?? false;
  }

  void setAgnesConfig(String apiKey, String model) {
    _agnesApiKey = apiKey;
    _agnesModel = (model.trim().isNotEmpty) ? model.trim() : _defaultAgnesModel;
    _provider = AIProvider.agnes;
  }

  void setProvider(AIProvider provider) {
    _provider = provider;
  }

  AIProvider get provider => _provider;

  /// 旧版拼写迁移：Agnes 曾误拼为 Anges，将旧 prefs 键（anges_*）
  /// 与旧 provider 值（'anges'）一次性迁移为正确拼写，避免老用户配置丢失
  static Future<void> migrateLegacyAgnesKeys() async {
    final prefs = await SharedPreferences.getInstance();
    const keyPairs = [
      ('anges_api_key', 'agnes_api_key'),
      ('anges_model', 'agnes_model'),
      ('anges_reasoning_effort', 'agnes_reasoning_effort'),
    ];
    for (final (oldKey, newKey) in keyPairs) {
      final oldValue = prefs.getString(oldKey);
      if (oldValue != null && prefs.getString(newKey) == null) {
        await prefs.setString(newKey, oldValue);
      }
      if (oldValue != null) {
        await prefs.remove(oldKey);
      }
    }
    if (prefs.getString('ai_provider') == 'anges') {
      await prefs.setString('ai_provider', 'agnes');
    }
  }

  Future<void> loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    // 只支持内置/Agnes/自定义三种 provider；历史遗留值（hunyuan/glm/doubao）
    // 一律回落到内置模型（默认节点 1）
    String providerStr = prefs.getString('ai_provider') ?? 'builtin';
    if (providerStr != 'builtin' && providerStr != 'agnes' && providerStr != 'custom') {
      providerStr = 'builtin';
    }
    _currentProviderStr = providerStr;

    if (providerStr == 'agnes') {
      _provider = AIProvider.agnes;
      _agnesApiKey = prefs.getString('agnes_api_key');
      final savedModel = prefs.getString('agnes_model');
      _agnesModel = (savedModel != null && savedModel.trim().isNotEmpty)
          ? savedModel.trim()
          : _defaultAgnesModel;
      _customApiUrl = null;
      _customApiKey = null;
      _customModel = null;
    } else if (providerStr == 'custom') {
      _customApiUrl = prefs.getString('custom_api_url');
      _customApiKey = prefs.getString('custom_api_key');
      _customModel = prefs.getString('custom_api_model') ?? _defaultCustomModel;
      _provider = AIProvider.custom;
    } else {
      _provider = AIProvider.builtin;
      _builtinNode = prefs.getInt('builtin_node') ?? 1;
      if (_builtinNode < 1 || _builtinNode > 4) _builtinNode = 1;
      _customApiUrl = null;
      _customApiKey = null;
      _customModel = null;
    }
  }

  Future<void> saveConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final String providerStr;
    if (_provider == AIProvider.custom) {
      providerStr = 'custom';
    } else if (_provider == AIProvider.agnes) {
      providerStr = 'agnes';
    } else {
      providerStr = 'builtin';
    }
    await prefs.setString('ai_provider', providerStr);

    if (_provider == AIProvider.agnes) {
      if (_agnesApiKey != null) await prefs.setString('agnes_api_key', _agnesApiKey!);
      await prefs.setString('agnes_model', _agnesModel);
    } else if (_provider == AIProvider.builtin) {
      await prefs.setInt('builtin_node', _builtinNode);
    }
  }
  Stream<String> parseScheduleTextStream(
    String ocrText, {
    String? provider,
    String? model,
    String? reasoningEffort,
  }) async* {
    String resolvedProvider = provider ?? _currentProviderStr;
    if (resolvedProvider != 'custom' &&
        resolvedProvider != 'agnes' &&
        resolvedProvider != 'builtin') {
      resolvedProvider = _provider == AIProvider.custom
          ? 'custom'
          : (_provider == AIProvider.agnes ? 'agnes' : 'builtin');
    }

    String? resolvedModel = model;
    if (resolvedProvider == 'custom') {
      await _ensureCustomConfigLoaded();
      if (_customApiUrl == null ||
          _customApiUrl!.isEmpty ||
          _customApiKey == null ||
          _customApiKey!.isEmpty) {
        throw GLMException('请先在开发者选项中配置自定义API地址和密钥');
      }
      if (resolvedModel == null || resolvedModel.isEmpty) {
        resolvedModel = (_customModel != null && _customModel!.trim().isNotEmpty)
            ? _customModel!.trim()
            : _defaultCustomModel;
      }
    } else if (resolvedProvider == 'agnes') {
      await _ensureAgnesConfigLoaded();
      if ((_agnesApiKey ?? '').trim().isEmpty) {
        throw GLMException('请先在AI配置中设置 Agnes AI 密钥');
      }
      if (resolvedModel == null || resolvedModel.isEmpty) {
        resolvedModel = _agnesModel;
      }
    }

    final prompt = _buildPrompt(ocrText);
    yield* chatWithModelStream(
      userMessage: prompt,
      model: resolvedModel,
      systemPrompt: _systemPrompt,
      provider: resolvedProvider,
      enableSearch: false,
      reasoningEffort: reasoningEffort,
    );
  }
  Future<void> _ensureCustomConfigLoaded() async {
    if (_customApiUrl != null && _customApiKey != null && _customApiUrl!.isNotEmpty && _customApiKey!.isNotEmpty) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    _customApiUrl = prefs.getString('custom_api_url');
    _customApiKey = prefs.getString('custom_api_key');
    _customModel = prefs.getString('custom_api_model') ?? _defaultCustomModel;
  }

  Map<String, dynamic> _buildNonDoubaoRequestBody({
    required String provider,
    required List<Map<String, dynamic>> messages,
    String? model,
    bool stream = false,
    String? reasoningEffort,
  }) {
    final payload = <String, dynamic>{
      'provider': provider,
      'stream': stream,
      if (model != null && model.isNotEmpty) 'model': model,
      if (reasoningEffort != null && reasoningEffort.isNotEmpty && const {'low', 'medium', 'high'}.contains(reasoningEffort)) 'reasoning_effort': reasoningEffort,
      if (reasoningEffort == null || reasoningEffort.isEmpty) 'thinking_disabled': true,
      'messages': messages,
    };

    if (provider == 'custom') {
      if (_customApiUrl != null && _customApiUrl!.isNotEmpty) {
        payload['custom_api_url'] = _customApiUrl;
      }
      if (_customApiKey != null && _customApiKey!.isNotEmpty) {
        payload['custom_api_key'] = _customApiKey;
      }
      final authHeader = _detectCustomAuthHeader(_customApiUrl);
      if (authHeader != null) {
        payload['custom_auth_header'] = authHeader;
      }
    }

    return payload;
  }

  String? _detectCustomAuthHeader(String? apiUrl) {
    if (apiUrl == null || apiUrl.isEmpty) return null;
    final lower = apiUrl.toLowerCase();
    if (lower.contains('xiaomimimo.com') || lower.contains('mimo')) {
      return 'api-key';
    }
    return null;
  }
  Stream<String> _chatWithNonDoubaoStream({
    required List<Map<String, dynamic>> messages,
    required String provider,
    String? model,
    String? reasoningEffort,
  }) async* {
    if (provider == 'custom') {
      await _ensureCustomConfigLoaded();
      if ((_customApiUrl ?? '').trim().isEmpty || (_customApiKey ?? '').trim().isEmpty) {
        throw GLMException('请先在开发者选项中配置自定义API地址和密钥');
      }
    }

    final httpClient = HttpClient();

    final hasImagePayload = messages.any((msg) {
      final content = msg['content'];
      if (content is List) {
        return content.any((part) {
          if (part is Map<String, dynamic>) {
            return part['type'] == 'image_url';
          }
          return false;
        });
      }
      return false;
    });

    debugPrint('[AI Service] NonDoubao stream route provider=$provider model=${model ?? ''} hasImage=$hasImagePayload endpoint=$_nonDoubaoEdgeFunctionUrl');

    try {
      final request = await httpClient.postUrl(Uri.parse(_nonDoubaoEdgeFunctionUrl));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(
        _buildNonDoubaoRequestBody(
          provider: provider,
          model: model,
          stream: true,
          messages: messages,
          reasoningEffort: reasoningEffort,
        ),
      ));

      final response = await request.close();
      if (response.statusCode != 200) {
        final errorBody = await response.transform(utf8.decoder).join();
        throw GLMException('API请求失败: ${response.statusCode} - $errorBody');
      }

      String buffer = '';
      String? returnedModel;

      await for (final chunk in response.transform(utf8.decoder)) {
        buffer += chunk;
        final lines = buffer.split('\n');
        buffer = lines.removeLast();

        for (final line in lines) {
          final trimmed = line.trim();
          if (trimmed.isEmpty || !trimmed.startsWith('data:')) continue;

          final data = trimmed.substring(5).trim();
          if (data == '[DONE]') continue;

          try {
            final parsed = jsonDecode(data);
            final content = parsed['content'] as String?;
            final status = parsed['status'] as String?;
            final thinking = parsed['thinking'] as String?;
            returnedModel ??= parsed['model'] as String?;

            if (thinking != null && thinking.isNotEmpty) {
              yield '【思考】$thinking';
            }
            if (status != null && status.isNotEmpty) {
              yield '【状态】$status';
            }
            if (content != null && content.isNotEmpty) {
              yield content;
            }
          } catch (_) {
            // Skip invalid JSON payloads.
          }
        }
      }

      if (returnedModel != null) {
        _lastStreamedModel = returnedModel;
      } else if (model != null && model.isNotEmpty) {
        _lastStreamedModel = model;
      }
    } catch (e) {
      if (e is GLMException) rethrow;
      throw GLMException('对话失败: $e');
    } finally {
      httpClient.close();
    }
  }

  /// 内置模型流式对话：经当前节点的 Supabase Edge Function 中转。
  /// 协议与 NonDoubaoAPI 一致（流式 SSE：content/status/thinking/model），无需客户端密钥
  Stream<String> _chatWithBuiltinStream({
    required List<Map<String, dynamic>> messages,
    String? model,
    String? reasoningEffort,
  }) async* {
    // 任务分析、对话页、课表识别等全部内置模型请求都经由本方法：
    // 每次进入 App 后的首次请求在此随机选定本次会话使用的节点
    await _randomizeBuiltinNodeForSession();
    debugPrint('[AI Service] Builtin stream route node=$_builtinNode model=${model ?? ''} endpoint=$_builtinEndpointUrl');

    final httpClient = HttpClient();
    try {
      final request = await httpClient.postUrl(Uri.parse(_builtinEndpointUrl));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({
        'provider': 'builtin',
        'node': _builtinNode,
        'stream': true,
        // 内置模型不透传客户端模型名（对话页的"节点 X"为展示名），
        // 由 Edge Function 内部决定实际使用的模型
        if (reasoningEffort != null &&
            reasoningEffort.isNotEmpty &&
            const {'low', 'medium', 'high'}.contains(reasoningEffort))
          'reasoning_effort': reasoningEffort,
        'messages': messages,
      }));

      final response = await request.close();
      if (response.statusCode != 200) {
        final errorBody = await response.transform(utf8.decoder).join();
        throw GLMException('API请求失败: ${response.statusCode} - $errorBody');
      }

      String buffer = '';
      String? returnedModel;

      await for (final chunk in response.transform(utf8.decoder)) {
        buffer += chunk;
        final lines = buffer.split('\n');
        buffer = lines.removeLast();

        for (final line in lines) {
          final trimmed = line.trim();
          if (trimmed.isEmpty || !trimmed.startsWith('data:')) continue;

          final data = trimmed.substring(5).trim();
          if (data == '[DONE]') continue;

          try {
            final parsed = jsonDecode(data);
            final error = parsed['error'] as String?;
            if (error != null && error.isNotEmpty) {
              throw GLMException('流式响应异常: $error');
            }
            final content = parsed['content'] as String?;
            final status = parsed['status'] as String?;
            final thinking = parsed['thinking'] as String?;
            returnedModel ??= parsed['model'] as String?;

            if (thinking != null && thinking.isNotEmpty) {
              yield '【思考】$thinking';
            }
            if (status != null && status.isNotEmpty) {
              yield '【状态】$status';
            }
            if (content != null && content.isNotEmpty) {
              yield content;
            }
          } catch (_) {
            // Skip invalid JSON payloads.
          }
        }
      }

      if (returnedModel != null) {
        _lastStreamedModel = returnedModel;
      }
    } catch (e) {
      if (e is GLMException) rethrow;
      throw GLMException('对话失败: $e');
    } finally {
      httpClient.close();
    }
  }
  /// 懒加载 Agnes 配置：内存缺失时从 SharedPreferences 读取
  Future<void> _ensureAgnesConfigLoaded() async {
    if (_agnesApiKey != null && _agnesApiKey!.trim().isNotEmpty) {
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    _agnesApiKey = prefs.getString('agnes_api_key');
    final savedModel = prefs.getString('agnes_model');
    if (savedModel != null && savedModel.trim().isNotEmpty) {
      _agnesModel = savedModel.trim();
    }
  }
  /// Agnes AI：解析思考强度（显式传入优先，否则读取配置）
  Future<String?> _resolvedAgnesReasoningEffort(String? passed) async {
    if (passed != null && passed.trim().isNotEmpty) {
      return passed.trim();
    }
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('agnes_reasoning_effort') ?? '';
    return saved.isEmpty ? null : saved;
  }

  /// Agnes AI：直连流式对话（OpenAI 兼容 SSE）
  Stream<String> _chatWithAgnesStream({
    required List<Map<String, dynamic>> messages,
    String? model,
    String? reasoningEffort,
  }) async* {
    await _ensureAgnesConfigLoaded();
    if (_agnesApiKey == null || _agnesApiKey!.trim().isEmpty) {
      throw GLMException('请先在AI配置中设置 Agnes AI 密钥');
    }

    final requestModel = (model != null && model.trim().isNotEmpty)
        ? model.trim()
        : _agnesModel;
    final effort = await _resolvedAgnesReasoningEffort(reasoningEffort);

    final httpClient = HttpClient();

    try {
      final request = await httpClient.postUrl(Uri.parse(_agnesBaseUrl));
      request.headers.contentType = ContentType.json;
      request.headers.set('Authorization', 'Bearer ${_agnesApiKey!.trim()}');
      request.write(jsonEncode({
        'model': requestModel,
        'messages': messages,
        'stream': true,
        if (effort != null) 'reasoning_effort': effort,
      }));

      final response = await request.close();

      if (response.statusCode != 200) {
        final errorBody = await response.transform(utf8.decoder).join();
        throw GLMException('Agnes AI请求失败: ${response.statusCode} - $errorBody');
      }

      String buffer = '';
      String? returnedModel;

      await for (final chunk in response.transform(utf8.decoder)) {
        buffer += chunk;
        final lines = buffer.split('\n');
        buffer = lines.removeLast();

        for (final line in lines) {
          final trimmed = line.trim();
          if (trimmed.isEmpty || !trimmed.startsWith('data:')) continue;

          final data = trimmed.substring(5).trim();
          if (data == '[DONE]') continue;

          try {
            final parsed = jsonDecode(data);
            returnedModel ??= parsed['model'] as String?;
            // 思考输出（OpenAI 兼容 reasoning_content，兼容 reasoning/thinking 变体）
            final dynamic deltaReasoning =
                parsed['choices']?[0]?['delta']?['reasoning_content'] ??
                parsed['choices']?[0]?['delta']?['reasoning'] ??
                parsed['choices']?[0]?['delta']?['thinking'];
            final dynamic messageReasoning =
                parsed['choices']?[0]?['message']?['reasoning_content'] ??
                parsed['choices']?[0]?['message']?['reasoning'] ??
                parsed['choices']?[0]?['message']?['thinking'];
            final reasoning =
                (deltaReasoning ?? messageReasoning)?.toString();
            if (reasoning != null && reasoning.isNotEmpty && reasoning != 'null') {
              yield '【思考】$reasoning';
            }
            final content = parsed['choices']?[0]?['delta']?['content'] as String?;
            if (content != null && content.isNotEmpty) {
              yield content;
            }
          } catch (_) {
            // Skip invalid JSON
          }
        }
      }

      _lastStreamedModel = returnedModel ?? requestModel;
    } catch (e) {
      if (e is GLMException) rethrow;
      throw GLMException('Agnes AI对话失败: $e');
    } finally {
      httpClient.close();
    }
  }

  /// 自定义API：客户端直连流式对话（不经 Supabase 中转，参考 Agnes 直连策略以减少延迟）。
  /// 在客户端复刻 Edge Function 的协议归一化：content/thinking/status/error 提取，
  /// 兼容 OpenAI Chat Completions 与 Responses API 两种事件格式。
  Stream<String> _chatWithCustomStream({
    required List<Map<String, dynamic>> messages,
    String? model,
    String? reasoningEffort,
  }) async* {
    await _ensureCustomConfigLoaded();
    final apiUrl = (_customApiUrl ?? '').trim();
    final apiKey = (_customApiKey ?? '').trim();
    if (apiUrl.isEmpty || apiKey.isEmpty) {
      throw GLMException('请先在开发者选项中配置自定义API地址和密钥');
    }

    final requestModel = (model != null && model.trim().isNotEmpty)
        ? model.trim()
        : ((_customModel != null && _customModel!.trim().isNotEmpty)
            ? _customModel!.trim()
            : _defaultCustomModel);
    final effort = (reasoningEffort != null && reasoningEffort.trim().isNotEmpty)
        ? reasoningEffort.trim()
        : null;
    final validEffort =
        (effort != null && const {'low', 'medium', 'high'}.contains(effort)) ? effort : null;

    debugPrint('[AI Service] Custom direct stream route model=$requestModel hasEffort=${validEffort != null}');

    final httpClient = HttpClient();

    try {
      Future<HttpClientResponse> send(Map<String, dynamic> body) async {
        final request = await httpClient.postUrl(Uri.parse(apiUrl));
        request.headers.contentType = ContentType.json;
        if (_detectCustomAuthHeader(apiUrl) == 'api-key') {
          request.headers.set('api-key', apiKey);
        } else {
          request.headers.set('Authorization', 'Bearer $apiKey');
        }
        request.headers.set('Accept', 'text/event-stream');
        request.write(jsonEncode(body));
        return request.close();
      }

      final baseBody = <String, dynamic>{
        'model': requestModel,
        'messages': messages,
        'stream': true,
        if (validEffort != null) 'reasoning_effort': validEffort,
      };
      final requestBody = <String, dynamic>{...baseBody};
      if (validEffort == null) {
        // 直接回答：双参数禁思考。thinking(GLM 系) 与 reasoning_effort 'none'
        // (实测部分默认开启思考的端点仅识别该值)，两者组合实测无冲突
        requestBody['thinking'] = const {'type': 'disabled'};
        requestBody['reasoning_effort'] = 'none';
      }

      var response = await send(requestBody);
      if (response.statusCode == 400 && validEffort == null) {
        // 部分端点不接受禁思考参数，回退为纯净请求体重试一次，保证功能可用
        debugPrint('[AI Service] Custom direct stream got 400 with thinking-disable params, retrying without them');
        try {
          await response.drain<void>();
        } catch (_) {}
        response = await send(baseBody);
      }

      if (response.statusCode != 200) {
        final errorBody = await response.transform(utf8.decoder).join();
        throw GLMException('API请求失败: ${response.statusCode} - $errorBody');
      }

      String buffer = '';
      String? returnedModel;

      await for (final chunk in response.transform(utf8.decoder)) {
        buffer += chunk;
        final lines = buffer.split('\n');
        buffer = lines.removeLast();

        for (final line in lines) {
          final trimmed = line.trim();
          if (trimmed.isEmpty || !trimmed.startsWith('data:')) continue;

          final data = trimmed.substring(5).trim();
          if (data == '[DONE]') continue;

          Map<String, dynamic>? parsed;
          try {
            final decoded = jsonDecode(data);
            if (decoded is Map<String, dynamic>) parsed = decoded;
          } catch (_) {
            // Skip invalid JSON payloads.
          }
          if (parsed == null) continue;

          returnedModel ??= _extractStreamModel(parsed, requestModel);

          // 流内错误事件：与内置模型路径行为一致，直接抛出
          final errorRaw = parsed['error'] ?? _rootStreamPayload(parsed)['error'];
          if (errorRaw != null) {
            String? errorMessage;
            if (errorRaw is Map) {
              errorMessage = errorRaw['message']?.toString() ??
                  errorRaw['Message']?.toString() ??
                  jsonEncode(errorRaw);
            } else if (errorRaw is String && errorRaw.isNotEmpty) {
              errorMessage = errorRaw;
            }
            if (errorMessage != null && errorMessage.isNotEmpty) {
              throw GLMException('流式响应异常: $errorMessage');
            }
          }

          final status = _extractStreamStatus(parsed);
          if (status != null) {
            yield '【状态】$status';
          }
          final thinking = _extractStreamThinking(parsed);
          if (thinking != null && thinking.isNotEmpty && thinking != 'null') {
            yield '【思考】$thinking';
          }
          final content = _extractStreamContent(parsed);
          if (content != null && content.isNotEmpty) {
            yield content;
          }
        }
      }

      _lastStreamedModel = returnedModel ?? requestModel;
    } catch (e) {
      if (e is GLMException) rethrow;
      throw GLMException('对话失败: $e');
    } finally {
      httpClient.close();
    }
  }

  /// 以下 _readStringLike/_rootStreamPayload/_firstStreamChoice 等辅助方法
  /// 与 Edge Function（functions/NonDoubaoAPI/index.ts）的提取逻辑保持一致
  static String? _readStringLike(dynamic value) {
    if (value is String) {
      return value.isNotEmpty ? value : null;
    }
    if (value is List) {
      final parts = <String>[];
      for (final item in value) {
        if (item is String) {
          parts.add(item);
          continue;
        }
        if (item is Map) {
          final text = _readStringLike(
            item['text'] ??
                item['Text'] ??
                item['content'] ??
                item['Content'] ??
                item['value'] ??
                item['Value'] ??
                item['reasoning_content'] ??
                item['reasoning'] ??
                item['thinking'],
          );
          if (text != null) parts.add(text);
        }
      }
      if (parts.isNotEmpty) return parts.join();
    }
    return null;
  }

  static Map<String, dynamic> _rootStreamPayload(Map<String, dynamic> parsed) {
    final response = parsed['Response'];
    if (response is Map<String, dynamic>) return response;
    return parsed;
  }

  static Map<String, dynamic>? _firstStreamChoice(Map<String, dynamic> root) {
    final choices = root['choices'] ?? root['Choices'];
    if (choices is List && choices.isNotEmpty) {
      final first = choices.first;
      if (first is Map<String, dynamic>) return first;
    }
    return null;
  }

  static String _extractStreamModel(Map<String, dynamic> parsed, String fallback) {
    final root = _rootStreamPayload(parsed);
    final model = parsed['model'] ?? root['model'] ?? root['Model'];
    if (model is String && model.isNotEmpty) return model;
    return fallback;
  }

  static String? _extractStreamStatus(Map<String, dynamic> parsed) {
    final eventType = parsed['type'];
    if (eventType == 'response.web_search_call.in_progress') {
      return '正在搜索网络...';
    }
    if (eventType == 'response.web_search_call.completed') {
      return '搜索完成，正在整理答案...';
    }
    final root = _rootStreamPayload(parsed);
    final status = root['status'] ?? root['Status'];
    if (status is String && status.isNotEmpty) return status;
    return null;
  }

  static String? _extractStreamThinking(Map<String, dynamic> parsed) {
    final root = _rootStreamPayload(parsed);
    final direct = _readStringLike(root['thinking'] ?? root['Thinking']);
    if (direct != null) return direct;

    final eventType = parsed['type'];
    if (eventType == 'response.reasoning_summary_text.delta' ||
        eventType == 'response.reasoning.delta') {
      final eventThinking = _readStringLike(parsed['delta'] ?? parsed['Delta']);
      if (eventThinking != null) return eventThinking;
    }

    final choice = _firstStreamChoice(root);
    final delta = choice?['delta'];
    final message = choice?['message'];
    return _readStringLike(
          parsed['reasoning_content'] ??
              parsed['reasoning'] ??
              parsed['thinking'],
        ) ??
        _readStringLike(
          delta is Map
              ? delta['reasoning_content'] ??
                  delta['reasoning'] ??
                  delta['thinking']
              : null,
        ) ??
        _readStringLike(
          message is Map
              ? message['reasoning_content'] ??
                  message['reasoning'] ??
                  message['thinking']
              : null,
        ) ??
        _readStringLike(
          root['reasoning_content'] ?? root['reasoning'] ?? root['thinking'],
        );
  }

  static String? _extractStreamContent(Map<String, dynamic> parsed) {
    final eventType = parsed['type'];
    if (eventType == 'response.output_text.delta') {
      return _readStringLike(parsed['delta'] ?? parsed['Delta']);
    }
    if (eventType == 'response.output_text.done' || eventType == 'response.output_item.done') {
      return _readStringLike(
        parsed['text'] ??
            parsed['delta'] ??
            parsed['output_text'] ??
            parsed['outputText'],
      );
    }

    final root = _rootStreamPayload(parsed);
    final choice = _firstStreamChoice(root);
    final delta = choice?['delta'];
    final message = choice?['message'];
    final output = root['output'];
    return _readStringLike(parsed['content'] ?? parsed['output_text']) ??
        _readStringLike(root['content'] ?? root['Content']) ??
        _readStringLike(delta is Map ? delta['content'] ?? delta['Content'] : null) ??
        _readStringLike(delta is Map ? delta['text'] ?? delta['Text'] : null) ??
        _readStringLike(message is Map ? message['content'] ?? message['Content'] : null) ??
        _readStringLike(output is Map ? output['text'] ?? output['Text'] : null);
  }

  static const String _systemPrompt = '''你是一个课程表解析助手。你的任务是将OCR识别的课程表文字转换为结构化的JSON数据。

输出格式要求：
1. 必须输出一个JSON数组，以 [ 开始，以 ] 结束
2. 每个课程对象包含以下字段：
   - name: 课程名称（必填，字符串）
   - teacher: 教师姓名（可选，字符串）
   - location: 上课地点（可选，字符串）
   - dayOfWeek: 星期几，1=周一，7=周日（必填，数字）
   - period: 第几节课，从1开始（必填，数字，如第1节填1，第2节填2）
   - duration: 课程持续节数，默认为2（可选，数字）
   - weeks: 上课周次，支持不连续周次，格式如 "1,3,5-8,10" 表示第1、3、5到8、10周（推荐使用）

周次识别规则（重要）：
- weeks字段只输出纯数字和逗号、连字符，绝对不要包含"周"、"连"等任何文字！
- 正确示例：weeks: "1-16" 或 weeks: "1,3,5-8,10" 或 weeks: "1-8,10-16"
- 错误示例：weeks: "连1-16" 或 weeks: "1-16周" 或 weeks: "连1-8 连10-16"（这些都是错误的！）
- 检测到 "1-16周"、"连1-16周" 时，输出 "1-16"（去掉"连"和"周"字）
- 检测到 "连1-8 连10-16周" 时，输出 "1-8,10-16"（去掉"连"和"周"字，用逗号分隔）
- 检测到 "1,3,5周"、"单周"、"双周" 等不连续格式时，必须使用 weeks 字段
- "单周" 表示奇数周，输出 "1,3,5,7,9,11,13,15"（根据总周数调整）
- "双周" 表示偶数周，输出 "2,4,6,8,10,12,14,16"（根据总周数调整）
- 检测到 "第1,3,5周上课" 时，输出 "1,3,5"

时间段与节次对应（重要，必须严格遵守）：
- period字段表示课程开始的节次，从1开始计数
- 第1节: 08:00开始（上午第一节课）
- 第2节: 08:55开始或09:00左右开始
- 第3节: 10:00开始（上午第三节课）
- 第4节: 10:55开始或11:00左右开始
- 第5节: 14:00开始（下午第一节课）
- 第6节: 14:55开始或15:00左右开始
- 第7节: 16:00开始（下午第三节课）
- 第8节: 16:55开始或17:00左右开始
- 第9节: 19:00开始（晚上第一节课）
- 第10节: 19:55开始或20:00左右开始

节次识别规则（非常重要，必须严格遵守）：
- period字段必须填写课程开始的节次，不是结束节次！
- 如果课表显示"第1-2节"，period=1，duration=2（不是period=2！）
- 如果课表显示"第3-4节"，period=3，duration=2（不是period=4！）
- 如果课表显示"第5-6节"，period=5，duration=2（不是period=6！）
- 如果课表显示"08:00-09:40"，这是第1-2节，period=1，duration=2
- 如果课表显示"10:00-11:40"，这是第3-4节，period=3，duration=2
- 识别节次时，只看开始时间：08:00开始→period=1，10:00开始→period=3，14:00开始→period=5
- 错误示例：课表显示"第1节"却输出period=2，这是错误的！

识别顺序（非常重要，必须严格遵守）：
1. 首先从上到下识别同一列（同一天）的所有课程
2. 然后从左到右识别下一列（下一天）
3. 即：先识别完周一所有课程，再识别周二，以此类推

禁止重复规则：
- 只有当两门课的 dayOfWeek、period、weeks（或startWeek/endWeek）都完全相同时才是重复
- 同一天同一节次但周次不同（如单周/双周，或1-8周与9-16周）必须保留为两条课程，不能合并
- 同一门课程在不同时间、不同日期出现是正常的，必须全部输出！
- 例如："高等数学"在周一第1节和周三第3节都有，这是两门不同的课，必须输出两条记录
- 如果一门课占用连续多节（如"第1-2节"），只输出一条记录，duration设为总节数

重要提醒：
- 同名课程在不同时间段是不同的课程，必须全部识别并输出
- 例如：体育课在周一第5节和周三第5节都有，要输出两条记录
- 只有完全相同的(dayOfWeek, period, weeks)组合才是重复，才需要合并为一条

重要规则：
- 只输出JSON数组，不要输出任何其他文字
- 确保JSON格式正确，可以被解析
- 时间段请转换为第几节课（period字段）
- 如果原文中没有明确信息，根据上下文合理推断''';

  String _buildPrompt(String ocrText) {
    return '''以下是OCR识别的课程表文字，请解析为JSON数组：

$ocrText

请直接输出JSON数组：''';
  }
  Stream<String> chatWithModelStream({
    required String userMessage,
    String? model,
    String? systemPrompt,
    List<Map<String, String>>? history,
    bool fastMode = false,
    String? imageBase64,
    String? provider,
    bool enableSearch = false,
    String? reasoningEffort,
  }) async* {
    final resolvedProvider = provider ??
      (_provider == AIProvider.custom
          ? 'custom'
          : (_provider == AIProvider.agnes ? 'agnes' : 'builtin'));
    String? resolvedModel = model;
    if (resolvedProvider == 'agnes') {
      await _ensureAgnesConfigLoaded();
      if ((_agnesApiKey ?? '').trim().isEmpty) {
        throw GLMException('请先在AI配置中设置 Agnes AI 密钥');
      }
      if (resolvedModel == null || resolvedModel.isEmpty) {
        resolvedModel = _agnesModel;
      }
    } else if (resolvedProvider == 'custom' && (resolvedModel == null || resolvedModel.isEmpty)) {
      resolvedModel = (_customModel != null && _customModel!.trim().isNotEmpty)
          ? _customModel!.trim()
          : _defaultCustomModel;
    }


    final List<Map<String, dynamic>> messages = [];
    
    if (systemPrompt != null) {
      messages.add({'role': 'system', 'content': systemPrompt});
    }
    
    if (history != null && history.isNotEmpty) {
      for (final msg in history) {
        messages.add({
          'role': msg['role'] ?? 'user',
          'content': msg['content'] ?? '',
        });
      }
    }
    
    if (imageBase64 != null && imageBase64.isNotEmpty) {
      messages.add({
        'role': 'user',
        'content': [
          {
            'type': 'image_url',
            'image_url': {
              'url': 'data:image/jpeg;base64,$imageBase64',
            },
          },
          {
            'type': 'text',
            'text': userMessage,
          },
        ],
      });
    } else {
      messages.add({'role': 'user', 'content': userMessage});
    }

    debugPrint('[AI Service] chatWithModelStream route provider=$resolvedProvider model=${resolvedModel ?? ''} hasImage=${imageBase64 != null && imageBase64.isNotEmpty}');
    if (resolvedProvider == 'agnes') {
      // Agnes AI：直连 OpenAI 兼容接口（不经 Supabase 中转）
      yield* _chatWithAgnesStream(
        messages: messages,
        model: resolvedModel,
        reasoningEffort: reasoningEffort,
      );
      return;
    }
    if (resolvedProvider == 'builtin') {
      // 内置模型：经当前节点的 Supabase Edge Function 中转（协议同 NonDoubao）
      yield* _chatWithBuiltinStream(
        messages: messages,
        model: resolvedModel,
        reasoningEffort: reasoningEffort,
      );
      return;
    }
    if (resolvedProvider == 'custom') {
      // 自定义API：客户端直连上游（不经 Supabase 中转，减少延迟）
      yield* _chatWithCustomStream(
        messages: messages,
        model: resolvedModel,
        reasoningEffort: reasoningEffort,
      );
      return;
    }
    yield* _chatWithNonDoubaoStream(
      messages: messages,
      provider: resolvedProvider,
      model: resolvedModel,
      reasoningEffort: reasoningEffort,
    );
  }

  String? _lastStreamedModel;
  String? get lastStreamedModel => _lastStreamedModel;

  Stream<String> chatScheduleStream({
    required String userMessage,
    required List<CourseData> courses,
    String? ocrContext,
    List<Map<String, String>>? history,
    String? reasoningEffort,
  }) async* {
    final coursesJson = courses.map((c) => c.toJson()).toList();
    
    String systemContent = '''你是一个智能助手，可以帮助用户解答各种问题。

当用户询问课程表相关问题时，以下是当前识别到的课程数据（JSON格式）：
${jsonEncode(coursesJson)}

当用户要求修改课程时，请分析用户的需求，然后返回一个JSON对象来描述修改操作：

1. 添加课程：返回 {"action": "add", "course": {...课程信息...}}
2. 修改课程：返回 {"action": "modify", "index": 课程序号(从1开始), "course": {...修改后的课程信息...}}
3. 删除课程：返回 {"action": "delete", "index": 课程序号(从1开始)}
4. 普通对话：直接回复文字，不需要JSON

课程信息字段说明：
- name: 课程名称（必填）
- teacher: 教师姓名（可选）
- location: 上课地点（可选）
- dayOfWeek: 星期几，1=周一，7=周日（必填）
- period: 第几节课，从1开始（必填）
- duration: 课程持续节数，默认为2（可选）
- weeks: 上课周次，支持不连续周次，格式如 "1,3,5-8,10" 表示第1、3、5到8、10周（推荐使用）
- startWeek: 开始周次（可选，仅用于连续周次）
- endWeek: 结束周次（可选，仅用于连续周次）

重要规则：
- index 字段使用 1-base，即第一个课程是 index=1，第二个是 index=2，以此类推
- 如果用户只是问问题或聊天，直接用文字回复，不要返回JSON
- 只有当用户明确要求修改课程时，才返回JSON格式的修改指令
- 修改完成后，用简洁的文字确认修改内容
- location一定是以...楼开头，不要识别成课程编码
- 对于不连续的周次，必须使用 weeks 字段，如 "1,3,5" 或 "1-5,7,9-12"''';

    if (ocrContext != null && ocrContext.isNotEmpty) {
      systemContent += '\n\n原始OCR识别内容：\n$ocrContext';
    }

    final List<Map<String, dynamic>> messages = [];
    messages.add({'role': 'system', 'content': systemContent});
    
    if (history != null && history.isNotEmpty) {
      for (final msg in history) {
        messages.add({
          'role': msg['role'] ?? 'user',
          'content': msg['content'] ?? '',
        });
      }
    }
    
    messages.add({'role': 'user', 'content': userMessage});

    String? model;
    String provider;
    if (_provider == AIProvider.agnes) {
      provider = 'agnes';
      model = _agnesModel;
    } else if (_provider == AIProvider.custom) {
      provider = 'custom';
      model = (_customModel != null && _customModel!.trim().isNotEmpty)
          ? _customModel!.trim()
          : _defaultCustomModel;
    } else {
      provider = 'builtin';
    }
    if (provider == 'agnes') {
      // Agnes AI：直连 OpenAI 兼容接口（不经 Supabase 中转）
      yield* _chatWithAgnesStream(messages: messages, model: model, reasoningEffort: reasoningEffort);
      return;
    }
    if (provider == 'builtin') {
      // 内置模型：经当前节点的 Supabase Edge Function 中转
      yield* _chatWithBuiltinStream(messages: messages, model: model, reasoningEffort: reasoningEffort);
      return;
    }
    if (provider == 'custom') {
      // 自定义API：客户端直连上游（不经 Supabase 中转，减少延迟）
      yield* _chatWithCustomStream(
        messages: messages,
        model: model,
        reasoningEffort: reasoningEffort,
      );
      return;
    }
    yield* _chatWithNonDoubaoStream(
      messages: messages,
      provider: provider,
      model: model,
      reasoningEffort: reasoningEffort,
    );
  }
}

class GLMException implements Exception {
  final String message;
  GLMException(this.message);

  @override
  String toString() => 'GLMException: $message';
}
