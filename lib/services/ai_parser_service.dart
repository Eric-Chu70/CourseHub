import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class AiParseResult {
  final bool success;
  final List<Map<String, dynamic>>? courses;
  final String? errorMessage;
  final String? rawResponse;

  AiParseResult({
    required this.success,
    this.courses,
    this.errorMessage,
    this.rawResponse,
  });

  factory AiParseResult.success(List<Map<String, dynamic>> courses, {String? rawResponse}) {
    return AiParseResult(
      success: true,
      courses: courses,
      rawResponse: rawResponse,
    );
  }

  factory AiParseResult.error(String message, {String? rawResponse}) {
    return AiParseResult(
      success: false,
      errorMessage: message,
      rawResponse: rawResponse,
    );
  }
}

class AiParserService {
  static final AiParserService _instance = AiParserService._internal();
  factory AiParserService() => _instance;
  AiParserService._internal();

  static const String _apiKeyKey = 'volcengine_api_key';
  static const String _apiUrlKey = 'volcengine_api_url';
  
  static const String _defaultApiUrl = 'https://ark.cn-beijing.volces.com/api/v3/chat/completions';

  String? _cachedApiKey;
  String? _cachedApiUrl;

  Future<String?> getApiKey() async {
    if (_cachedApiKey != null) return _cachedApiKey;
    final prefs = await SharedPreferences.getInstance();
    _cachedApiKey = prefs.getString(_apiKeyKey);
    return _cachedApiKey;
  }

  Future<void> setApiKey(String apiKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_apiKeyKey, apiKey);
    _cachedApiKey = apiKey;
  }

  Future<String?> getApiUrl() async {
    if (_cachedApiUrl != null) return _cachedApiUrl;
    final prefs = await SharedPreferences.getInstance();
    _cachedApiUrl = prefs.getString(_apiUrlKey) ?? _defaultApiUrl;
    return _cachedApiUrl;
  }

  Future<void> setApiUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_apiUrlKey, url);
    _cachedApiUrl = url;
  }

  Future<bool> hasApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    final provider = prefs.getString('ai_provider') ?? 'hunyuan';
    
    if (provider == 'custom') {
      final customUrl = prefs.getString('custom_api_url') ?? '';
      final customKey = prefs.getString('custom_api_key') ?? '';
      return customUrl.isNotEmpty && customKey.isNotEmpty;
    }
    
    final key = await getApiKey();
    return key != null && key.isNotEmpty;
  }

  Future<AiParseResult> parseCourseText(String ocrText) async {
    final prefs = await SharedPreferences.getInstance();
    final provider = prefs.getString('ai_provider') ?? 'hunyuan';

    if (provider == 'custom') {
      return _parseWithCustomApi(ocrText, prefs);
    }
    
    return _parseWithVolcengine(ocrText);
  }

  Future<AiParseResult> _parseWithCustomApi(String ocrText, SharedPreferences prefs) async {
    final apiUrl = prefs.getString('custom_api_url') ?? '';
    final apiKey = prefs.getString('custom_api_key') ?? '';
    final model = prefs.getString('custom_api_model') ?? 'gpt-4o-mini';

    if (apiUrl.isEmpty || apiKey.isEmpty) {
      return AiParseResult.error('请先配置自定义API');
    }

    const systemPrompt = '''你是一个课程表解析助手。用户会给你从课程表图片中OCR识别出的文本，你需要将其解析成结构化的课程数据。

请仔细分析文本内容，识别出每门课程的以下信息：
- name: 课程名称
- teacher: 授课教师（可选）
- location: 上课地点（可选）
- day: 星期几，1-7表示周一到周日
- time: 第几节课开始，从1开始计数
- duration: 持续几节课，默认为1
- weeks: 上课周次，如"1-16周"或"单周"或"双周"（可选）
- color: 课程颜色，使用十六进制颜色代码如"#4A90E2"（可选，自动分配不同颜色）

注意事项：
1. 仔细分析表格结构，确定每门课程的时间位置
2. 有些课程可能跨多节课，注意识别duration
3. 有些课程可能只在特定周次上课，注意识别weeks
4. 如果无法确定某项信息，可以省略或设为null
5. 为每门课程分配不同的颜色，使课表更美观

请只返回JSON数组格式，不要包含其他说明文字。示例输出：
[
  {
    "name": "高等数学",
    "teacher": "张老师",
    "location": "教学楼A101",
    "day": 1,
    "time": 1,
    "duration": 2,
    "weeks": "1-16周",
    "color": "#4A90E2"
  }
]''';

    try {
      final response = await http.post(
        Uri.parse(apiUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
        },
        body: jsonEncode({
          'model': model,
          'messages': [
            {'role': 'system', 'content': systemPrompt},
            {'role': 'user', 'content': '请解析以下课程表文本：\n\n$ocrText'},
          ],
          'temperature': 0.1,
          'max_tokens': 4096,
        }),
      );

      if (response.statusCode != 200) {
        return AiParseResult.error('API请求失败: ${response.statusCode} - ${response.body}');
      }

      final responseData = jsonDecode(utf8.decode(response.bodyBytes));
      
      String? content;
      if (responseData['choices'] != null && 
          responseData['choices'] is List && 
          (responseData['choices'] as List).isNotEmpty) {
        final choice = responseData['choices'][0];
        if (choice['message'] != null && choice['message']['content'] != null) {
          content = choice['message']['content'].toString();
        }
      }

      if (content == null || content.isEmpty) {
        return AiParseResult.error('API返回内容为空', rawResponse: jsonEncode(responseData));
      }

      final courses = _parseAiResponse(content);
      if (courses.isEmpty) {
        return AiParseResult.error('无法从AI响应中解析出课程数据', rawResponse: content);
      }

      return AiParseResult.success(courses, rawResponse: content);
    } catch (e) {
      return AiParseResult.error('解析失败: $e');
    }
  }

  Future<AiParseResult> _parseWithVolcengine(String ocrText) async {
    final apiKey = await getApiKey();
    if (apiKey == null || apiKey.isEmpty) {
      return AiParseResult.error('请先配置火山引擎API Key');
    }

    final apiUrl = await getApiUrl() ?? _defaultApiUrl;

    const systemPrompt = '''你是一个课程表解析助手。用户会给你从课程表图片中OCR识别出的文本，你需要将其解析成结构化的课程数据。

请仔细分析文本内容，识别出每门课程的以下信息：
- name: 课程名称
- teacher: 授课教师（可选）
- location: 上课地点（可选）
- day: 星期几，1-7表示周一到周日
- time: 第几节课开始，从1开始计数
- duration: 持续几节课，默认为1
- weeks: 上课周次，如"1-16周"或"单周"或"双周"（可选）
- color: 课程颜色，使用十六进制颜色代码如"#4A90E2"（可选，自动分配不同颜色）

注意事项：
1. 仔细分析表格结构，确定每门课程的时间位置
2. 有些课程可能跨多节课，注意识别duration
3. 有些课程可能只在特定周次上课，注意识别weeks
4. 如果无法确定某项信息，可以省略或设为null
5. 为每门课程分配不同的颜色，使课表更美观

请只返回JSON数组格式，不要包含其他说明文字。示例输出：
[
  {
    "name": "高等数学",
    "teacher": "张老师",
    "location": "教学楼A101",
    "day": 1,
    "time": 1,
    "duration": 2,
    "weeks": "1-16周",
    "color": "#4A90E2"
  }
]''';

    try {
      final response = await http.post(
        Uri.parse(apiUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
        },
        body: jsonEncode({
          'model': 'deepseek-r1-250528',
          'messages': [
            {'role': 'system', 'content': systemPrompt},
            {'role': 'user', 'content': '请解析以下课程表文本：\n\n$ocrText'},
          ],
          'temperature': 0.1,
          'max_tokens': 4096,
        }),
      );

      if (response.statusCode != 200) {
        return AiParseResult.error('API请求失败: ${response.statusCode} - ${response.body}');
      }

      final responseData = jsonDecode(utf8.decode(response.bodyBytes));
      
      String? content;
      if (responseData['choices'] != null && 
          responseData['choices'] is List && 
          (responseData['choices'] as List).isNotEmpty) {
        final choice = responseData['choices'][0];
        if (choice['message'] != null && choice['message']['content'] != null) {
          content = choice['message']['content'].toString();
        }
      }

      if (content == null || content.isEmpty) {
        return AiParseResult.error('API返回内容为空', rawResponse: jsonEncode(responseData));
      }

      final courses = _parseAiResponse(content);
      if (courses.isEmpty) {
        return AiParseResult.error('无法从AI响应中解析出课程数据', rawResponse: content);
      }

      return AiParseResult.success(courses, rawResponse: content);
    } catch (e) {
      return AiParseResult.error('解析失败: $e');
    }
  }

  List<Map<String, dynamic>> _parseAiResponse(String content) {
    final jsonMatch = RegExp(r'\[[\s\S]*\]').firstMatch(content);
    if (jsonMatch == null) {
      return [];
    }

    try {
      final jsonStr = jsonMatch.group(0)!;
      final List<dynamic> parsed = jsonDecode(jsonStr);
      
      final courses = <Map<String, dynamic>>[];
      final defaultColors = [
        '#4A90E2', '#E74C3C', '#27AE60', '#F39C12', '#9B59B6',
        '#1ABC9C', '#E91E63', '#00ACC1', '#795548', '#607D8B',
      ];
      
      for (int i = 0; i < parsed.length; i++) {
        final item = parsed[i];
        if (item is Map<String, dynamic>) {
          final course = Map<String, dynamic>.from(item);
          
          if (course['name'] == null || course['name'].toString().isEmpty) {
            continue;
          }
          
          if (course['day'] == null) {
            course['day'] = 1;
          } else if (course['day'] is String) {
            course['day'] = int.tryParse(course['day']) ?? 1;
          }
          
          if (course['time'] == null) {
            course['time'] = 1;
          } else if (course['time'] is String) {
            course['time'] = int.tryParse(course['time']) ?? 1;
          }
          
          if (course['duration'] == null) {
            course['duration'] = 1;
          } else if (course['duration'] is String) {
            course['duration'] = int.tryParse(course['duration']) ?? 1;
          }
          
          if (course['color'] == null || course['color'].toString().isEmpty) {
            course['color'] = defaultColors[i % defaultColors.length];
          }
          
          if (course['day'] < 1 || course['day'] > 7) {
            course['day'] = 1;
          }
          if (course['time'] < 1) {
            course['time'] = 1;
          }
          if (course['duration'] < 1) {
            course['duration'] = 1;
          }
          
          courses.add(course);
        }
      }
      
      return courses;
    } catch (e) {
      return [];
    }
  }
}
