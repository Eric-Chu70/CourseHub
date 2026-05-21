import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
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
  glm,
  hunyuan,
  doubao,
  custom,
}

class AIService {
  static final AIService _instance = AIService._internal();
  factory AIService() => _instance;
  AIService._internal();

  static AIService get instance => _instance;

  static const String _glmBaseUrl = 'https://open.bigmodel.cn/api/paas/v4/chat/completions';
  static const String _glmModel = 'glm-4.7-flash';
  static const String _defaultCustomModel = 'gpt-4o-mini';
  
  static const String _defaultSupabaseUrl = 'https://jnwhpbkhvumiyjwyjwhu.supabase.co/functions/v1/hunyuan';
  static const String _doubaoEdgeFunctionUrl = 'https://jnwhpbkhvumiyjwyjwhu.supabase.co/functions/v1/HuoshanAPI';
  static const String _nonDoubaoEdgeFunctionUrl = 'https://jnwhpbkhvumiyjwyjwhu.supabase.co/functions/v1/NonDoubaoAPI';

  String? _apiKey;
  String? _secretId;
  String? _secretKey;
  String? _supabaseUrl = _defaultSupabaseUrl;
  String? _customApiUrl;
  String? _customApiKey;
  String? _customModel;
  String _currentProviderStr = 'hunyuan';
  
  AIProvider _provider = AIProvider.hunyuan;

  void setApiKey(String apiKey) {
    _apiKey = apiKey;
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

  Future<void> _cacheCustomReasoningCapability({
    required String apiUrl,
    required String model,
    required bool isReasoning,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _customReasoningCacheKey(apiUrl: apiUrl, model: model);
    await prefs.setBool(key, isReasoning);
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

  void setHunyuanCredentials(String secretId, String secretKey, {String? supabaseUrl}) {
    _secretId = secretId;
    _secretKey = secretKey;
    if (supabaseUrl != null && supabaseUrl.isNotEmpty) {
      _supabaseUrl = supabaseUrl;
    }
    _provider = AIProvider.hunyuan;
  }

  void setGLMApiKey(String apiKey) {
    _apiKey = apiKey;
    _provider = AIProvider.glm;
  }

  void setDoubaoProvider() {
    _provider = AIProvider.doubao;
  }

  void setProvider(AIProvider provider) {
    _provider = provider;
  }

  AIProvider get provider => _provider;

  Future<void> loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final providerStr = prefs.getString('ai_provider');
    _currentProviderStr = providerStr ?? 'hunyuan';
    
    if (providerStr == 'glm') {
      _provider = AIProvider.glm;
      _apiKey = prefs.getString('glm_api_key');
      _customApiUrl = null;
      _customApiKey = null;
      _customModel = null;
    } else if (providerStr == 'doubao') {
      _provider = AIProvider.doubao;
      _customApiUrl = null;
      _customApiKey = null;
      _customModel = null;
    } else if (providerStr == 'custom') {
      _customApiUrl = prefs.getString('custom_api_url');
      _customApiKey = prefs.getString('custom_api_key');
      _customModel = prefs.getString('custom_api_model') ?? _defaultCustomModel;
      _provider = AIProvider.custom;
    } else {
      _provider = AIProvider.hunyuan;
      _secretId = prefs.getString('tencent_secret_id');
      _secretKey = prefs.getString('tencent_secret_key');
      final savedUrl = prefs.getString('supabase_url');
      _supabaseUrl = (savedUrl != null && savedUrl.isNotEmpty) ? savedUrl : _defaultSupabaseUrl;
      _customApiUrl = null;
      _customApiKey = null;
      _customModel = null;
    }
  }

  Future<void> saveConfig() async {
    final prefs = await SharedPreferences.getInstance();
    String providerStr = 'hunyuan';
    if (_provider == AIProvider.glm) {
      providerStr = 'glm';
    } else if (_provider == AIProvider.doubao) {
      providerStr = 'doubao';
    } else if (_provider == AIProvider.custom) {
      providerStr = 'custom';
    }
    await prefs.setString('ai_provider', providerStr);
    
    if (_provider == AIProvider.glm) {
      if (_apiKey != null) await prefs.setString('glm_api_key', _apiKey!);
    } else if (_provider == AIProvider.hunyuan) {
      if (_secretId != null) await prefs.setString('tencent_secret_id', _secretId!);
      if (_secretKey != null) await prefs.setString('tencent_secret_key', _secretKey!);
      if (_supabaseUrl != null) await prefs.setString('supabase_url', _supabaseUrl!);
    }
  }

  Future<GLMParseResult> parseScheduleText(String ocrText) async {
    if (_currentProviderStr == 'custom') {
      if (_customApiUrl == null || _customApiUrl!.isEmpty || _customApiKey == null || _customApiKey!.isEmpty) {
        await _ensureCustomConfigLoaded();
      }
      if (_customApiUrl == null || _customApiUrl!.isEmpty || _customApiKey == null || _customApiKey!.isEmpty) {
        throw GLMException('请先在开发者选项中配置自定义API地址和密钥');
      }
      return _parseWithNonDoubao(
        ocrText,
        provider: 'custom',
        model: _customModel ?? _defaultCustomModel,
      );
    }

    if (_currentProviderStr == 'hunyuan') {
      return _parseWithNonDoubao(
        ocrText,
        provider: 'hunyuan',
        model: 'hunyuan-lite',
      );
    }

    if (_currentProviderStr == 'glm') {
      return _parseWithNonDoubao(
        ocrText,
        provider: 'glm',
        model: _glmModel,
      );
    }

    return _parseWithDoubao(ocrText);
  }

  Stream<String> parseScheduleTextStream(
    String ocrText, {
    String? provider,
    String? model,
    String? reasoningEffort,
  }) async* {
    String resolvedProvider = provider ?? _currentProviderStr;
    if (resolvedProvider != 'doubao' &&
        resolvedProvider != 'hunyuan' &&
        resolvedProvider != 'glm' &&
        resolvedProvider != 'custom') {
      resolvedProvider = _provider == AIProvider.custom
          ? 'custom'
          : (_provider == AIProvider.glm
              ? 'glm'
              : (_provider == AIProvider.doubao ? 'doubao' : 'hunyuan'));
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
    } else if (resolvedProvider == 'hunyuan' &&
        (resolvedModel == null || resolvedModel.isEmpty)) {
      resolvedModel = 'hunyuan-lite';
    } else if (resolvedProvider == 'glm' &&
        (resolvedModel == null || resolvedModel.isEmpty)) {
      resolvedModel = _glmModel;
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

  Future<GLMParseResult> parseScheduleFromImage(String imagePath) async {
    if (_provider != AIProvider.doubao) {
      throw GLMException('当前模型不支持直接图片识别，请切换到OCR+AI模式');
    }
    return _parseWithDoubaoVision(imagePath);
  }

  Stream<String> parseScheduleFromImageStream(String imagePath) async* {
    if (_provider != AIProvider.doubao) {
      throw GLMException('当前模型不支持直接图片识别，请切换到OCR+AI模式');
    }

    final file = File(imagePath);
    if (!await file.exists()) {
      throw GLMException('图片文件不存在');
    }

    final bytes = await file.readAsBytes();
    final base64Image = base64Encode(bytes);

    final httpClient = HttpClient();

    try {
      final request = await httpClient.postUrl(Uri.parse(_doubaoEdgeFunctionUrl));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({
        'type': 'vision',
        'stream': true,
        'messages': [
          {
            'role': 'system',
            'content': _systemPrompt,
          },
          {
            'role': 'user',
            'content': [
              {
                'type': 'image_url',
                'image_url': {
                  'url': 'data:image/jpeg;base64,$base64Image',
                },
              },
              {
                'type': 'text',
                'text': '请识别这张课程表图片中的所有课程信息，并按照要求的JSON格式输出。请直接输出JSON数组，不要输出其他文字：',
              },
            ],
          },
        ],
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
            
            // 优先处理内容
            if (content != null && content.isNotEmpty) {
              yield content;
            }
            // 处理状态信息（如"正在搜索网络..."）
            else if (status != null && status.isNotEmpty) {
              yield '【状态】$status';
            }
            // 处理思考过程
            else if (thinking != null && thinking.isNotEmpty) {
              yield '【思考】$thinking';
            }
          } catch (_) {
            // Skip invalid JSON
          }
        }
      }

      if (returnedModel != null) {
        _lastStreamedModel = returnedModel;
      }
    } catch (e) {
      if (e is GLMException) rethrow;
      throw GLMException('解析失败: $e');
    } finally {
      httpClient.close();
    }
  }

  Future<GLMParseResult> _parseWithDoubaoVision(String imagePath) async {
    final file = File(imagePath);
    if (!await file.exists()) {
      throw GLMException('图片文件不存在');
    }

    final bytes = await file.readAsBytes();
    final base64Image = base64Encode(bytes);

    int retryCount = 0;
    const maxRetries = 3;

    while (retryCount < maxRetries) {
      try {
        final response = await http.post(
          Uri.parse(_doubaoEdgeFunctionUrl),
          headers: {
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'type': 'vision',
            'messages': [
              {
                'role': 'system',
                'content': _systemPrompt,
              },
              {
                'role': 'user',
                'content': [
                  {
                    'type': 'image_url',
                    'image_url': {
                      'url': 'data:image/jpeg;base64,$base64Image',
                    },
                  },
                  {
                    'type': 'text',
                    'text': '请识别这张课程表图片中的所有课程信息，并按照要求的JSON格式输出。请直接输出JSON数组，不要输出其他文字：',
                  },
                ],
              },
            ],
          }),
        );

        if (response.statusCode != 200) {
          throw GLMException('API请求失败: ${response.statusCode} - ${response.body}');
        }

        final data = jsonDecode(response.body);

        if (data['error'] != null) {
          throw GLMException('API错误: ${data['error']['message'] ?? data['error']}');
        }

        final content = data['choices']?[0]?['message']?['content'] as String? ?? '';
        final selectedModel = data['model'] as String?;

        if (content.isEmpty) {
          throw GLMException('AI返回内容为空');
        }

        return _parseResponse(content, selectedModel: selectedModel);
      } on http.ClientException catch (e) {
        retryCount++;
        if (retryCount >= maxRetries) {
          throw GLMException('网络连接失败，请检查网络\n错误: $e');
        }
        await Future.delayed(Duration(seconds: retryCount * 2));
      } catch (e) {
        if (e is GLMException) rethrow;
        throw GLMException('解析失败: $e');
      }
    }

    throw GLMException('请求超时，请检查网络连接');
  }

  Future<GLMParseResult> _parseWithDoubao(String ocrText, {String? model}) async {
    final prompt = _buildPrompt(ocrText);

    int retryCount = 0;
    const maxRetries = 3;

    while (retryCount < maxRetries) {
      try {
        final response = await http.post(
          Uri.parse(_doubaoEdgeFunctionUrl),
          headers: {
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'type': 'vision',
            if (model != null && model.isNotEmpty) 'model': model,
            'messages': [
              {
                'role': 'system',
                'content': _systemPrompt,
              },
              {
                'role': 'user',
                'content': prompt,
              },
            ],
          }),
        );

        if (response.statusCode != 200) {
          throw GLMException('API请求失败: ${response.statusCode} - ${response.body}');
        }

        final data = jsonDecode(response.body);

        if (data['error'] != null) {
          throw GLMException('API错误: ${data['error']['message'] ?? data['error']}');
        }

        final content = data['choices']?[0]?['message']?['content'] as String? ?? '';
        final selectedModel = data['model'] as String?;

        if (content.isEmpty) {
          throw GLMException('AI返回内容为空');
        }

        return _parseResponse(content, selectedModel: selectedModel);
      } on http.ClientException catch (e) {
        retryCount++;
        if (retryCount >= maxRetries) {
          throw GLMException('网络连接失败，请检查网络\n错误: $e');
        }
        await Future.delayed(Duration(seconds: retryCount * 2));
      } catch (e) {
        if (e is GLMException) rethrow;
        throw GLMException('解析失败: $e');
      }
    }

    throw GLMException('请求超时，请检查网络连接');
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

    if (provider == 'hunyuan') {
      if (_secretId != null && _secretId!.isNotEmpty) {
        payload['secret_id'] = _secretId;
      }
      if (_secretKey != null && _secretKey!.isNotEmpty) {
        payload['secret_key'] = _secretKey;
      }
    } else if (provider == 'glm') {
      if (_apiKey != null && _apiKey!.isNotEmpty) {
        payload['api_key'] = _apiKey;
      }
    } else if (provider == 'custom') {
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

  Future<GLMParseResult> _parseWithNonDoubao(
    String ocrText, {
    required String provider,
    required String model,
  }) async {
    final prompt = _buildPrompt(ocrText);
    int retryCount = 0;
    const maxRetries = 3;

    while (retryCount < maxRetries) {
      try {
        final response = await http.post(
          Uri.parse(_nonDoubaoEdgeFunctionUrl),
          headers: {
            'Content-Type': 'application/json',
          },
          body: jsonEncode(
            _buildNonDoubaoRequestBody(
              provider: provider,
              model: model,
              messages: [
                {
                  'role': 'system',
                  'content': _systemPrompt,
                },
                {
                  'role': 'user',
                  'content': prompt,
                },
              ],
            ),
          ),
        );

        if (response.statusCode != 200) {
          throw GLMException('API请求失败: ${response.statusCode} - ${response.body}');
        }

        final data = jsonDecode(response.body);
        if (data['error'] != null) {
          throw GLMException('API错误: ${data['error']['message'] ?? data['error']}');
        }

        final content = data['choices']?[0]?['message']?['content'] as String? ?? '';
        final selectedModel = data['model'] as String?;
        if (content.isEmpty) {
          throw GLMException('AI返回内容为空');
        }

        return _parseResponse(content, selectedModel: selectedModel);
      } on http.ClientException catch (e) {
        retryCount++;
        if (retryCount >= maxRetries) {
          throw GLMException('网络连接失败，请检查网络\n错误: $e');
        }
        await Future.delayed(Duration(seconds: retryCount * 2));
      } catch (e) {
        if (e is GLMException) rethrow;
        throw GLMException('解析失败: $e');
      }
    }

    throw GLMException('请求超时，请检查网络连接');
  }

  Future<String> _testNonDoubaoConnection({
    required String provider,
    required String successMessage,
    String? model,
  }) async {
    if (provider == 'custom') {
      await _ensureCustomConfigLoaded();
    }

    try {
      final response = await http.post(
        Uri.parse(_nonDoubaoEdgeFunctionUrl),
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode(
          _buildNonDoubaoRequestBody(
            provider: provider,
            model: model,
            messages: [
              {'role': 'user', 'content': '你好'}
            ],
          ),
        ),
      );

      if (response.statusCode == 200) {
        return successMessage;
      }

      throw GLMException('连接失败: ${response.statusCode}');
    } catch (e) {
      if (e is GLMException) rethrow;
      throw GLMException('连接测试失败: $e');
    }
  }

  Future<String> _chatWithNonDoubao(
    String userMessage,
    String? context,
    List<CourseData>? courses, {
    required String provider,
    required String model,
  }) async {
    String systemContent = '''你是一个智能助手，可以帮助用户解答各种问题。

当用户询问课程表相关问题时，以下是当前识别到的课程数据：
${courses != null ? jsonEncode(courses.map((c) => c.toJson()).toList()) : '暂无'}

当用户要求修改课程时，请分析用户的需求，然后返回一个JSON对象来描述修改操作：
1. 添加课程：返回 {"action": "add", "course": {...课程信息...}}
2. 修改课程：返回 {"action": "modify", "index": 课程索引, "course": {...修改后的课程信息...}}
3. 删除课程：返回 {"action": "delete", "index": 课程索引}

课程信息字段说明：
- name: 课程名称（必填）
- teacher: 教师姓名（可选）
- location: 上课地点（可选）
- dayOfWeek: 星期几，1=周一，7=周日（必填）
- period: 第几节课，从1开始（必填）
- duration: 课程持续节数，默认为2（可选）
- weeks: 上课周次，支持不连续周次，格式如 "1,3,5-8,10"（可选）

注意：
- 只有当用户明确要求修改课程时，才返回JSON格式的修改指令
- 其他情况下请用自然语言回答用户的问题''';

    if (context != null && context.isNotEmpty) {
      systemContent += '\n\n原始OCR识别内容：\n$context';
    }

    if (provider == 'custom') {
      await _ensureCustomConfigLoaded();
    }

    try {
      final response = await http.post(
        Uri.parse(_nonDoubaoEdgeFunctionUrl),
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode(
          _buildNonDoubaoRequestBody(
            provider: provider,
            model: model,
            messages: [
              {'role': 'system', 'content': systemContent},
              {'role': 'user', 'content': userMessage},
            ],
          ),
        ),
      );

      if (response.statusCode != 200) {
        throw GLMException('API请求失败: ${response.statusCode}');
      }

      final data = jsonDecode(response.body);
      return data['choices'][0]['message']['content'] as String;
    } catch (e) {
      if (e is GLMException) rethrow;
      throw GLMException('对话失败: $e');
    }
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
      bool sawReasoning = false;

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

  Future<Map<String, dynamic>> _chatWithModelNonDoubao({
    required List<Map<String, dynamic>> messages,
    required String provider,
    String? model,
  }) async {
    if (provider == 'custom') {
      await _ensureCustomConfigLoaded();
    }

    try {
      final response = await http.post(
        Uri.parse(_nonDoubaoEdgeFunctionUrl),
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode(
          _buildNonDoubaoRequestBody(
            provider: provider,
            model: model,
            messages: messages,
          ),
        ),
      );

      if (response.statusCode != 200) {
        throw GLMException('API请求失败: ${response.statusCode}');
      }

      final data = jsonDecode(response.body);
      return {
        'content': data['choices'][0]['message']['content'] as String,
        'model': data['model'] as String,
      };
    } catch (e) {
      if (e is GLMException) rethrow;
      throw GLMException('对话失败: $e');
    }
  }

  Future<GLMParseResult> _parseWithHunyuan(String ocrText) async {
    if (_secretId == null || _secretId!.isEmpty) {
      throw GLMException('请先设置腾讯云 SecretId');
    }
    if (_secretKey == null || _secretKey!.isEmpty) {
      throw GLMException('请先设置腾讯云 SecretKey');
    }
    if (_supabaseUrl == null || _supabaseUrl!.isEmpty) {
      throw GLMException('请先设置 Supabase Function URL');
    }

    final prompt = _buildPrompt(ocrText);

    int retryCount = 0;
    const maxRetries = 3;

    while (retryCount < maxRetries) {
      try {
        final authHeader = '$_secretId $_secretKey';
        debugPrint('=== Hunyuan API Request ===');
        debugPrint('URL: $_supabaseUrl');
        debugPrint('SecretId length: ${_secretId!.length}');
        debugPrint('SecretKey length: ${_secretKey!.length}');
        debugPrint('Auth header: ${authHeader.substring(0, 20)}...');
        
        final response = await http.post(
          Uri.parse(_supabaseUrl!),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': authHeader,
          },
          body: jsonEncode({
            'model': 'hunyuan-lite',
            'messages': [
              {
                'role': 'system',
                'content': _systemPrompt,
              },
              {
                'role': 'user',
                'content': prompt,
              },
            ],
          }),
        ).timeout(const Duration(seconds: 60));

        if (response.statusCode != 200) {
          final errorData = jsonDecode(response.body);
          throw GLMException('API请求失败: ${errorData['error'] ?? response.statusCode}');
        }

        final data = jsonDecode(response.body);

        if (data['error'] != null) {
          throw GLMException('API错误: ${data['error']}');
        }

        final content = data['choices']?[0]?['message']?['content'] as String? ?? '';

        if (content.isEmpty) {
          throw GLMException('AI返回内容为空');
        }

        return _parseResponse(content);
      } on http.ClientException catch (e) {
        retryCount++;
        if (retryCount >= maxRetries) {
          throw GLMException('网络连接失败，请检查网络\n错误: $e');
        }
        await Future.delayed(Duration(seconds: retryCount * 2));
      } catch (e) {
        if (e is GLMException) rethrow;
        throw GLMException('解析失败: $e');
      }
    }

    throw GLMException('请求超时，请检查网络连接');
  }

  Future<GLMParseResult> _parseWithGLM(String ocrText) async {
    if (_apiKey == null || _apiKey!.isEmpty) {
      throw GLMException('请先设置 GLM API Key');
    }

    final prompt = _buildPrompt(ocrText);

    int retryCount = 0;
    const maxRetries = 3;

    while (retryCount < maxRetries) {
      try {
        final response = await http.post(
          Uri.parse(_glmBaseUrl),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $_apiKey',
          },
          body: jsonEncode({
            'model': _glmModel,
            'messages': [
              {
                'role': 'system',
                'content': _systemPrompt,
              },
              {
                'role': 'user',
                'content': prompt,
              },
            ],
            'temperature': 0.1,
            'max_tokens': 4096,
          }),
        );

        if (response.statusCode != 200) {
          throw GLMException('API请求失败: ${response.statusCode} - ${response.body}');
        }

        final data = jsonDecode(response.body);

        if (data['error'] != null) {
          throw GLMException('API错误: ${data['error']['message']}');
        }

        final content = data['choices']?[0]?['message']?['content'] as String? ?? '';

        if (content.isEmpty) {
          throw GLMException('AI返回内容为空');
        }

        return _parseResponse(content);
      } on http.ClientException catch (e) {
        retryCount++;
        if (retryCount >= maxRetries) {
          throw GLMException('网络连接失败，请检查网络后重试\n错误: $e');
        }
        await Future.delayed(Duration(seconds: retryCount * 2));
      } catch (e) {
        if (e is GLMException) rethrow;
        throw GLMException('解析失败: $e');
      }
    }

    throw GLMException('请求超时，请检查网络连接');
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

  GLMParseResult _parseResponse(String content, {String? selectedModel}) {
    try {
      String jsonStr = content.trim();

      if (jsonStr.contains('```json')) {
        jsonStr = jsonStr.replaceAll(RegExp(r'```json\s*'), '').replaceAll(RegExp(r'\s*```'), '');
      } else if (jsonStr.contains('```')) {
        jsonStr = jsonStr.replaceAll(RegExp(r'```\s*'), '').replaceAll(RegExp(r'\s*```'), '');
      }

      int startIndex = jsonStr.indexOf('[');
      int endIndex = jsonStr.lastIndexOf(']');
      if (startIndex != -1 && endIndex != -1 && endIndex > startIndex) {
        jsonStr = jsonStr.substring(startIndex, endIndex + 1);
      }

      if (jsonStr.isEmpty) {
        throw GLMException('AI返回的JSON内容为空');
      }

      final List<dynamic> coursesJson = jsonDecode(jsonStr);

      return GLMParseResult(
        courses: coursesJson.map((json) => CourseData.fromJson(json as Map<String, dynamic>)).toList(),
        rawContent: content,
        selectedModel: selectedModel,
      );
    } catch (e) {
      throw GLMException('JSON解析失败: $e\n原始内容: $content');
    }
  }

  Future<String> testConnection() async {
    if (_provider == AIProvider.hunyuan) {
      return _testNonDoubaoConnection(
        provider: 'hunyuan',
        model: 'hunyuan-lite',
        successMessage: '混元连接成功',
      );
    }
    if (_provider == AIProvider.glm) {
      return _testNonDoubaoConnection(
        provider: 'glm',
        model: _glmModel,
        successMessage: 'GLM连接成功',
      );
    }
    return _testDoubaoConnection();
  }

  Future<String> _testDoubaoConnection({String? model, String successMessage = '火山引擎连接成功'}) async {
    try {
      final response = await http.post(
        Uri.parse(_doubaoEdgeFunctionUrl),
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          if (model != null && model.isNotEmpty) 'model': model,
          'messages': [
            {'role': 'user', 'content': '你好'}
          ],
        }),
      );

      if (response.statusCode == 200) {
        return successMessage;
      } else {
        throw GLMException('连接失败: ${response.statusCode}');
      }
    } catch (e) {
      if (e is GLMException) rethrow;
      throw GLMException('连接测试失败: $e');
    }
  }

  Future<String> _testHunyuanConnection() async {
    if (_secretId == null || _secretId!.isEmpty) {
      throw GLMException('请先设置腾讯云 SecretId');
    }
    if (_secretKey == null || _secretKey!.isEmpty) {
      throw GLMException('请先设置腾讯云 SecretKey');
    }
    if (_supabaseUrl == null || _supabaseUrl!.isEmpty) {
      throw GLMException('请先设置 Supabase Function URL');
    }

    try {
      final response = await http.post(
        Uri.parse(_supabaseUrl!),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': '$_secretId $_secretKey',
        },
        body: jsonEncode({
          'model': 'hunyuan-lite',
          'messages': [
            {'role': 'user', 'content': '你好'}
          ],
        }),
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        return '混元连接成功';
      } else {
        final errorData = jsonDecode(response.body);
        throw GLMException('连接失败: ${errorData['error'] ?? response.statusCode}');
      }
    } catch (e) {
      if (e is GLMException) rethrow;
      throw GLMException('连接测试失败: $e');
    }
  }

  Future<String> _testGLMConnection() async {
    if (_apiKey == null || _apiKey!.isEmpty) {
      throw GLMException('请先设置 GLM API Key');
    }

    try {
      final response = await http.post(
        Uri.parse(_glmBaseUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $_apiKey',
        },
        body: jsonEncode({
          'model': _glmModel,
          'messages': [
            {'role': 'user', 'content': '你好'}
          ],
          'max_tokens': 50,
        }),
      );

      if (response.statusCode == 200) {
        return 'GLM连接成功';
      } else {
        throw GLMException('连接失败: ${response.statusCode}');
      }
    } catch (e) {
      if (e is GLMException) rethrow;
      throw GLMException('连接测试失败: $e');
    }
  }

  Future<String> chat({
    required String userMessage,
    String? context,
    List<CourseData>? courses,
  }) async {
    if (_provider == AIProvider.custom) {
      final customModel = (_customModel != null && _customModel!.trim().isNotEmpty)
          ? _customModel!.trim()
          : _defaultCustomModel;
      return _chatWithNonDoubao(
        userMessage,
        context,
        courses,
        provider: 'custom',
        model: customModel,
      );
    }

    if (_provider == AIProvider.doubao) {
      return _chatWithDoubao(userMessage, context, courses);
    }

    if (_provider == AIProvider.hunyuan) {
      return _chatWithNonDoubao(
        userMessage,
        context,
        courses,
        provider: 'hunyuan',
        model: 'hunyuan-lite',
      );
    }

    return _chatWithNonDoubao(
      userMessage,
      context,
      courses,
      provider: 'glm',
      model: _glmModel,
    );
  }

  Future<String> _chatWithDoubao(String userMessage, String? context, List<CourseData>? courses, {String? model}) async {
    String systemContent = '''你是一个智能助手，可以帮助用户解答各种问题。

当用户询问课程表相关问题时，以下是当前识别到的课程数据：
${courses != null ? jsonEncode(courses.map((c) => c.toJson()).toList()) : '暂无'}

当用户要求修改课程时，请分析用户的需求，然后返回一个JSON对象来描述修改操作：
1. 添加课程：返回 {"action": "add", "course": {...课程信息...}}
2. 修改课程：返回 {"action": "modify", "index": 课程索引, "course": {...修改后的课程信息...}}
3. 删除课程：返回 {"action": "delete", "index": 课程索引}

课程信息字段说明：
- name: 课程名称（必填）
- teacher: 教师姓名（可选）
- location: 上课地点（可选）
- dayOfWeek: 星期几，1=周一，7=周日（必填）
- period: 第几节课，从1开始（必填）
- duration: 课程持续节数，默认为2（可选）
- weeks: 上课周次，支持不连续周次，格式如 "1,3,5-8,10"（可选）

注意：
- 只有当用户明确要求修改课程时，才返回JSON格式的修改指令
- 其他情况下请用自然语言回答用户的问题''';

    if (context != null && context.isNotEmpty) {
      systemContent += '\n\n原始OCR识别内容：\n$context';
    }

    try {
      final response = await http.post(
        Uri.parse(_doubaoEdgeFunctionUrl),
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'type': 'chat',
          if (model != null && model.isNotEmpty) 'model': model,
          'messages': [
            {'role': 'system', 'content': systemContent},
            {'role': 'user', 'content': userMessage},
          ],
        }),
      );

      if (response.statusCode != 200) {
        throw GLMException('API请求失败: ${response.statusCode}');
      }

      final data = jsonDecode(response.body);
      return data['choices'][0]['message']['content'] as String;
    } catch (e) {
      if (e is GLMException) rethrow;
      throw GLMException('对话失败: $e');
    }
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
      (_provider == AIProvider.hunyuan
        ? 'hunyuan'
        : (_provider == AIProvider.glm
          ? 'glm'
          : (_provider == AIProvider.custom ? 'custom' : 'doubao')));
    String? resolvedModel = model;
    if (resolvedProvider == 'hunyuan' && (resolvedModel == null || resolvedModel.isEmpty)) {
      resolvedModel = 'hunyuan-lite';
    } else if (resolvedProvider == 'glm' && (resolvedModel == null || resolvedModel.isEmpty)) {
      resolvedModel = _glmModel;
    } else if (resolvedProvider == 'custom' && (resolvedModel == null || resolvedModel.isEmpty)) {
      resolvedModel = (_customModel != null && _customModel!.trim().isNotEmpty)
          ? _customModel!.trim()
          : _defaultCustomModel;
    }

    if (resolvedProvider != 'doubao' && resolvedProvider != 'hunyuan' && resolvedProvider != 'glm' && resolvedProvider != 'custom') {
      throw GLMException('当前provider不支持此功能: $resolvedProvider');
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

    if (resolvedProvider != 'doubao') {
      debugPrint('[AI Service] chatWithModelStream route provider=$resolvedProvider model=${resolvedModel ?? ''} hasImage=${imageBase64 != null && imageBase64.isNotEmpty}');
      yield* _chatWithNonDoubaoStream(
        messages: messages,
        provider: resolvedProvider,
        model: resolvedModel,
        reasoningEffort: reasoningEffort,
      );
      return;
    }

    final httpClient = HttpClient();
    
    try {
      final request = await httpClient.postUrl(Uri.parse(_doubaoEdgeFunctionUrl));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({
        'type': imageBase64 != null ? 'vision' : 'chat',
        'stream': true,
        'fast_mode': fastMode,
        'enable_search': resolvedProvider == 'doubao' ? enableSearch : false,
        if (resolvedModel != null && resolvedModel.isNotEmpty) 'model': resolvedModel,
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
            final content = parsed['content'] as String?;
            final status = parsed['status'] as String?;
            final thinking = parsed['thinking'] as String?;
            returnedModel ??= parsed['model'] as String?;
            
            // 优先处理内容
            if (content != null && content.isNotEmpty) {
              yield content;
            }
            // 处理状态信息
            else if (status != null && status.isNotEmpty) {
              yield '【状态】$status';
            }
            // 处理思考过程
            else if (thinking != null && thinking.isNotEmpty) {
              yield '【思考】$thinking';
            }
          } catch (_) {
            // Skip invalid JSON
          }
        }
      }

      // Store the model for reference
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

  Stream<String> _chatWithHunyuanStream(
    String userMessage,
    String? systemPrompt,
    List<Map<String, String>>? history,
    String model,
  ) async* {
    if (_secretId == null || _secretKey == null) {
      throw GLMException('请先配置混元API密钥');
    }

    final List<Map<String, String>> messages = [];
    
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
    
    messages.add({'role': 'user', 'content': userMessage});

    final httpClient = HttpClient();
    
    try {
      final request = await httpClient.postUrl(Uri.parse(_supabaseUrl ?? _defaultSupabaseUrl));
      request.headers.contentType = ContentType.json;
      request.headers.set('Authorization', '$_secretId $_secretKey');
      request.write(jsonEncode({
        'model': model,
        'messages': messages,
        'stream': true,
      }));

      final response = await request.close();

      if (response.statusCode != 200) {
        final errorBody = await response.transform(utf8.decoder).join();
        throw GLMException('混元API请求失败: ${response.statusCode} - $errorBody');
      }

      String buffer = '';

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
            if (content != null && content.isNotEmpty) {
              yield content;
            }
          } catch (_) {
            // Skip invalid JSON
          }
        }
      }
      
      _lastStreamedModel = model;
    } catch (e) {
      if (e is GLMException) rethrow;
      throw GLMException('混元对话失败: $e');
    } finally {
      httpClient.close();
    }
  }

  Stream<String> _chatWithGLMStream(
    String userMessage,
    String? systemPrompt,
    List<Map<String, String>>? history,
    String model,
  ) async* {
    if (_apiKey == null) {
      throw GLMException('请先配置GLM API密钥');
    }

    final List<Map<String, String>> messages = [];
    
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
    
    messages.add({'role': 'user', 'content': userMessage});

    final httpClient = HttpClient();
    
    try {
      final request = await httpClient.postUrl(Uri.parse(_glmBaseUrl));
      request.headers.contentType = ContentType.json;
      request.headers.set('Authorization', 'Bearer $_apiKey');
      request.write(jsonEncode({
        'model': model,
        'messages': messages,
        'stream': true,
      }));

      final response = await request.close();

      if (response.statusCode != 200) {
        final errorBody = await response.transform(utf8.decoder).join();
        throw GLMException('GLM API请求失败: ${response.statusCode} - $errorBody');
      }

      String buffer = '';

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
            final content = parsed['choices']?[0]?['delta']?['content'] as String?;
            if (content != null && content.isNotEmpty) {
              yield content;
            }
          } catch (_) {
            // Skip invalid JSON
          }
        }
      }
      
      _lastStreamedModel = model;
    } catch (e) {
      if (e is GLMException) rethrow;
      throw GLMException('GLM对话失败: $e');
    } finally {
      httpClient.close();
    }
  }

  Stream<String> _chatWithCustomStream(
    String userMessage,
    String? systemPrompt,
    List<Map<String, String>>? history,
    String model,
  ) async* {
    if (_customApiUrl == null || _customApiKey == null || _customApiUrl!.isEmpty || _customApiKey!.isEmpty) {
      final prefs = await SharedPreferences.getInstance();
      _customApiUrl = prefs.getString('custom_api_url');
      _customApiKey = prefs.getString('custom_api_key');
      _customModel = prefs.getString('custom_api_model');
    }

    final apiUrl = (_customApiUrl ?? '').trim();
    final apiKey = (_customApiKey ?? '').trim();
    final resolvedModel = model.trim().isNotEmpty
        ? model.trim()
        : ((_customModel != null && _customModel!.trim().isNotEmpty)
            ? _customModel!.trim()
            : _defaultCustomModel);

    if (apiUrl.isEmpty || apiKey.isEmpty) {
      throw GLMException('请先在开发者选项中配置自定义API地址和密钥');
    }

    final List<Map<String, String>> messages = [];

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

    messages.add({'role': 'user', 'content': userMessage});

    final httpClient = HttpClient();

    try {
      final request = await httpClient.postUrl(Uri.parse(apiUrl));
      request.headers.contentType = ContentType.json;
      request.headers.set('Authorization', 'Bearer $apiKey');
      request.headers.set('Accept', 'text/event-stream');
      request.write(jsonEncode({
        'model': resolvedModel,
        'messages': messages,
        'stream': true,
      }));

      final response = await request.close();

      if (response.statusCode != 200) {
        final errorBody = await response.transform(utf8.decoder).join();
        throw GLMException('自定义API请求失败: ${response.statusCode} - $errorBody');
      }

      String buffer = '';
      String? returnedModel;
  bool sawReasoning = false;

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

            final dynamic deltaContent = parsed['choices']?[0]?['delta']?['content'];
            final dynamic messageContent = parsed['choices']?[0]?['message']?['content'];
            final dynamic plainContent = parsed['content'];
            final dynamic deltaReasoning =
                parsed['choices']?[0]?['delta']?['reasoning_content'] ??
                parsed['choices']?[0]?['delta']?['reasoning'] ??
                parsed['choices']?[0]?['delta']?['thinking'];
            final dynamic messageReasoning =
                parsed['choices']?[0]?['message']?['reasoning_content'] ??
                parsed['choices']?[0]?['message']?['reasoning'] ??
                parsed['choices']?[0]?['message']?['thinking'];
            final dynamic plainReasoning =
                parsed['reasoning_content'] ?? parsed['reasoning'] ?? parsed['thinking'];

            final reasoning =
                (deltaReasoning ?? messageReasoning ?? plainReasoning)?.toString();
            final content = (deltaContent ?? messageContent ?? plainContent)?.toString();

            if (reasoning != null && reasoning.isNotEmpty && reasoning != 'null') {
              sawReasoning = true;
              yield '【思考】$reasoning';
            }

            if (content != null && content.isNotEmpty && content != 'null') {
              yield content;
            }
          } catch (_) {
            // Skip invalid JSON payloads from stream.
          }
        }
      }

      if (sawReasoning) {
        await _cacheCustomReasoningCapability(
          apiUrl: apiUrl,
          model: resolvedModel,
          isReasoning: true,
        );
      }

      _lastStreamedModel = returnedModel ?? resolvedModel;
    } catch (e) {
      if (e is GLMException) rethrow;
      throw GLMException('自定义API对话失败: $e');
    } finally {
      httpClient.close();
    }
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
    String provider = 'doubao';
    if (_provider == AIProvider.hunyuan) {
      provider = 'hunyuan';
      model = 'hunyuan-lite';
    } else if (_provider == AIProvider.glm) {
      provider = 'glm';
      model = _glmModel;
    } else if (_provider == AIProvider.custom) {
      provider = 'custom';
      model = (_customModel != null && _customModel!.trim().isNotEmpty)
          ? _customModel!.trim()
          : _defaultCustomModel;
    }
    if (provider == 'doubao') {
      yield* _chatScheduleDoubaoStream(messages, model: model);
      return;
    }
    yield* _chatWithNonDoubaoStream(
      messages: messages,
      provider: provider,
      model: model,
      reasoningEffort: reasoningEffort,
    );
  }

  Stream<String> _chatScheduleDoubaoStream(List<Map<String, dynamic>> messages, {String? model}) async* {
    final httpClient = HttpClient();
    try {
      final request = await httpClient.postUrl(Uri.parse(_doubaoEdgeFunctionUrl));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({
        'type': 'chat',
        'stream': true,
        if (model != null && model.isNotEmpty) 'model': model,
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
            final content = parsed['content'] as String?;
            returnedModel ??= parsed['model'] as String?;
            if (content != null && content.isNotEmpty) {
              yield content;
            }
          } catch (_) {}
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

  Stream<String> _chatScheduleHunyuanStream(List<Map<String, dynamic>> messages) async* {
    if (_secretId == null || _secretKey == null) {
      throw GLMException('请先配置混元API密钥');
    }

    final httpClient = HttpClient();
    
    try {
      final request = await httpClient.postUrl(Uri.parse(_supabaseUrl ?? _defaultSupabaseUrl));
      request.headers.contentType = ContentType.json;
      request.headers.set('Authorization', '$_secretId $_secretKey');
      request.write(jsonEncode({
        'model': 'hunyuan-lite',
        'messages': messages,
        'stream': true,
      }));

      final response = await request.close();

      if (response.statusCode != 200) {
        final errorBody = await response.transform(utf8.decoder).join();
        throw GLMException('混元API请求失败: ${response.statusCode} - $errorBody');
      }

      String buffer = '';

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
            if (content != null && content.isNotEmpty) {
              yield content;
            }
          } catch (_) {}
        }
      }
      
      _lastStreamedModel = 'hunyuan-lite';
    } catch (e) {
      if (e is GLMException) rethrow;
      throw GLMException('混元对话失败: $e');
    } finally {
      httpClient.close();
    }
  }

  Stream<String> _chatScheduleGLMStream(List<Map<String, dynamic>> messages) async* {
    if (_apiKey == null) {
      throw GLMException('请先配置GLM API密钥');
    }

    final httpClient = HttpClient();
    
    try {
      final request = await httpClient.postUrl(Uri.parse(_glmBaseUrl));
      request.headers.contentType = ContentType.json;
      request.headers.set('Authorization', 'Bearer $_apiKey');
      request.write(jsonEncode({
        'model': _glmModel,
        'messages': messages,
        'stream': true,
      }));

      final response = await request.close();

      if (response.statusCode != 200) {
        final errorBody = await response.transform(utf8.decoder).join();
        throw GLMException('GLM API请求失败: ${response.statusCode} - $errorBody');
      }

      String buffer = '';

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
            final content = parsed['choices']?[0]?['delta']?['content'] as String?;
            if (content != null && content.isNotEmpty) {
              yield content;
            }
          } catch (_) {}
        }
      }
      
      _lastStreamedModel = _glmModel;
    } catch (e) {
      if (e is GLMException) rethrow;
      throw GLMException('GLM对话失败: $e');
    } finally {
      httpClient.close();
    }
  }

  Future<Map<String, dynamic>> chatWithModel({
    required String userMessage,
    String? model,
    String? systemPrompt,
    List<Map<String, String>>? history,
  }) async {
    String? resolvedModel = model;
    if (resolvedModel == null || resolvedModel.isEmpty) {
      if (_provider == AIProvider.hunyuan) {
        resolvedModel = 'hunyuan-lite';
      } else if (_provider == AIProvider.glm) {
        resolvedModel = _glmModel;
      } else if (_provider == AIProvider.custom) {
        resolvedModel = (_customModel != null && _customModel!.trim().isNotEmpty)
            ? _customModel!.trim()
            : _defaultCustomModel;
      }
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
    
    messages.add({'role': 'user', 'content': userMessage});

    if (_provider == AIProvider.doubao) {
      try {
        final response = await http.post(
          Uri.parse(_doubaoEdgeFunctionUrl),
          headers: {
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'type': 'chat',
            if (resolvedModel != null && resolvedModel.isNotEmpty) 'model': resolvedModel,
            'messages': messages,
          }),
        );

        if (response.statusCode != 200) {
          throw GLMException('API请求失败: ${response.statusCode}');
        }

        final data = jsonDecode(response.body);
        return {
          'content': data['choices'][0]['message']['content'] as String,
          'model': data['model'] as String,
        };
      } catch (e) {
        if (e is GLMException) rethrow;
        throw GLMException('对话失败: $e');
      }
    }

    if (_provider == AIProvider.custom) {
      return _chatWithModelNonDoubao(
        messages: messages,
        provider: 'custom',
        model: resolvedModel,
      );
    }

    return _chatWithModelNonDoubao(
      messages: messages,
      provider: _provider == AIProvider.hunyuan ? 'hunyuan' : 'glm',
      model: resolvedModel,
    );
  }

  Future<String> _chatWithHunyuan(String userMessage, String? context, List<CourseData>? courses) async {
    if (_secretId == null || _secretKey == null || _supabaseUrl == null) {
      throw GLMException('请先配置混元API');
    }

    String systemContent = '''你是一个智能助手，可以帮助用户解答各种问题。

当用户询问课程表相关问题时，以下是当前识别到的课程数据：
${courses != null ? jsonEncode(courses.map((c) => c.toJson()).toList()) : '暂无'}

当用户要求修改课程时，请分析用户的需求，然后返回一个JSON对象来描述修改操作：
1. 添加课程：返回 {"action": "add", "course": {...课程信息...}}
2. 修改课程：返回 {"action": "modify", "index": 课程索引, "course": {...修改后的课程信息...}}
3. 删除课程：返回 {"action": "delete", "index": 课程索引}

课程信息字段说明：
- name: 课程名称（必填）
- teacher: 教师姓名（可选）
- location: 上课地点（可选）
- dayOfWeek: 星期几，1=周一，7=周日（必填）
- period: 第几节课，从1开始（必填）
- duration: 课程持续节数，默认为2（可选）
- weeks: 上课周次，支持不连续周次，格式如 "1,3,5-8,10"（可选）

注意：
- 只有当用户明确要求修改课程时，才返回JSON格式的修改指令
- 其他情况下请用自然语言回答用户的问题''';

    if (context != null && context.isNotEmpty) {
      systemContent += '\n\n原始OCR识别内容：\n$context';
    }

    try {
      final response = await http.post(
        Uri.parse(_supabaseUrl!),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': '$_secretId $_secretKey',
        },
        body: jsonEncode({
          'model': 'hunyuan-lite',
          'messages': [
            {'role': 'system', 'content': systemContent},
            {'role': 'user', 'content': userMessage},
          ],
        }),
      ).timeout(const Duration(seconds: 60));

      if (response.statusCode != 200) {
        final errorData = jsonDecode(response.body);
        throw GLMException('API请求失败: ${errorData['error'] ?? response.statusCode}');
      }

      final data = jsonDecode(response.body);
      return data['choices'][0]['message']['content'] as String;
    } catch (e) {
      if (e is GLMException) rethrow;
      throw GLMException('对话失败: $e');
    }
  }

  Future<String> _chatWithGLM(String userMessage, String? context, List<CourseData>? courses) async {
    if (_apiKey == null || _apiKey!.isEmpty) {
      throw GLMException('请先设置 GLM API Key');
    }

    try {
      String systemContent = '''你是一个课程表助手。用户会问你关于课程表的问题，请用简洁友好的方式回答。
如果用户想修改课程信息，请给出建议。
当前识别到的课程数据：
${courses != null ? jsonEncode(courses.map((c) => c.toJson()).toList()) : '暂无'}''';

      if (context != null && context.isNotEmpty) {
        systemContent += '\n\n原始OCR识别内容：\n$context';
      }

      final response = await http.post(
        Uri.parse(_glmBaseUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $_apiKey',
        },
        body: jsonEncode({
          'model': _glmModel,
          'messages': [
            {'role': 'system', 'content': systemContent},
            {'role': 'user', 'content': userMessage},
          ],
          'temperature': 0.7,
          'max_tokens': 1024,
        }),
      );

      if (response.statusCode != 200) {
        throw GLMException('API请求失败: ${response.statusCode}');
      }

      final data = jsonDecode(response.body);
      return data['choices'][0]['message']['content'] as String;
    } catch (e) {
      if (e is GLMException) rethrow;
      throw GLMException('对话失败: $e');
    }
  }
}

class GLMException implements Exception {
  final String message;
  GLMException(this.message);

  @override
  String toString() => 'GLMException: $message';
}
