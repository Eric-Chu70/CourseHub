import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:shared_preferences/shared_preferences.dart';
import '../services/ocr_service.dart';
import '../services/glm_service.dart';
import '../services/regex_parser_service.dart';
import '../models/course.dart';
import '../dialogs/course_dialog.dart';
import '../utils/course_color_palette.dart';

enum AIProcessingStep {
  ocr,
  parsing,
  completed,
  error,
}

enum ParseMode {
  ai,
  regex,
}

class AIProcessingDialog extends StatefulWidget {
  final String imagePath;
  final Function(List<CourseData>)? onCompleted;

  const AIProcessingDialog({
    super.key,
    required this.imagePath,
    this.onCompleted,
  });

  static Future<void> show(
    BuildContext context, {
    required String imagePath,
    Function(List<CourseData>)? onCompleted,
  }) {
    return showGeneralDialog(
      context: context,
      barrierDismissible: false,
      barrierLabel: 'AI处理中',
      barrierColor: Colors.black.withValues(alpha: 0.5),
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, animation, secondaryAnimation) {
        return BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: AIProcessingDialog(
            imagePath: imagePath,
            onCompleted: onCompleted,
          ),
        );
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        return FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.9, end: 1.0).animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOut),
            ),
            child: child,
          ),
        );
      },
    );
  }

  @override
  State<AIProcessingDialog> createState() => _AIProcessingDialogState();
}

class _AIProcessingDialogState extends State<AIProcessingDialog>
    with SingleTickerProviderStateMixin {
  AIProcessingStep _currentStep = AIProcessingStep.ocr;
  String _statusText = '正在识别图片中的文字...';
  String? _ocrText;
  List<CourseData>? _parsedCourses;
  String? _errorMessage;
  String? _selectedModel;
  ParseMode _parseMode = ParseMode.ai;
  String _runtimeProvider = 'hunyuan';
  String? _runtimeReasoningEffort;
  bool _runtimeWebSearchEnabled = false;
  
  final TextEditingController _chatController = TextEditingController();
  final List<ChatMessage> _chatMessages = [];
  final ScrollController _scrollController = ScrollController();
  final ScrollController _thinkingScrollController = ScrollController();
  bool _isChatMode = false;
  bool _isSending = false;
  bool _showCourseListInDialog = false;
  
  String _streamingContent = '';
  bool _isStreaming = false;
  String _thinkingContent = '';
  bool _isThinking = false;
  bool _isThinkingCollapsed = false;
  bool _isFirstChunkReceived = false;
  Timer? _noResponseTimer;
  StreamSubscription<String>? _streamSubscription;
  
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOut,
    );
    _scaleAnimation = Tween<double>(begin: 0.9, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOut),
    );
    _animationController.forward();
    _startProcessing();
  }

  @override
  void dispose() {
    _noResponseTimer?.cancel();
    _streamSubscription?.cancel();
    _animationController.dispose();
    _chatController.dispose();
    _scrollController.dispose();
    _thinkingScrollController.dispose();
    super.dispose();
  }

  void _startNoResponseTimer() {
    _noResponseTimer?.cancel();
    _noResponseTimer = Timer(const Duration(seconds: 60), () {
      if (!_isFirstChunkReceived && _isStreaming) {
        setState(() {
          _currentStep = AIProcessingStep.error;
          _errorMessage = 'AI响应超时，请检查网络连接或重试';
          _isStreaming = false;
        });
        _updateLastAIMessage('❌ AI响应超时，请检查网络连接或重试');
      }
    });
  }

  void _cancelNoResponseTimer() {
    _noResponseTimer?.cancel();
    _noResponseTimer = null;
  }

  void _resetStreamingState() {
    _streamingContent = '';
    _thinkingContent = '';
    _isThinking = false;
    _isThinkingCollapsed = false;
    _isFirstChunkReceived = false;
  }

  void _updateLastAIStreamingMessage({String fallbackText = '正在思考...'}) {
    _updateLastAIMessage(
      _streamingContent.isNotEmpty ? _streamingContent : fallbackText,
      thinkingContent: _thinkingContent.isNotEmpty ? _thinkingContent : null,
      isThinkingCollapsed: _isThinkingCollapsed,
    );
    _scrollThinkingToBottom();
  }

  void _scrollThinkingToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_isThinking || _isThinkingCollapsed) return;
      if (_thinkingScrollController.hasClients) {
        _thinkingScrollController.jumpTo(
          _thinkingScrollController.position.maxScrollExtent,
        );
      }
    });
  }

  Future<void> _startProcessing() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final providerStr = prefs.getString('ai_provider') ?? 'hunyuan';
      _runtimeProvider = providerStr;
      final customModelName = (prefs.getString('custom_api_model')?.trim().isNotEmpty ?? false)
          ? prefs.getString('custom_api_model')!.trim()
          : 'gpt-4o-mini';
      final reasoningEffortStr = prefs.getString('custom_api_reasoning_effort') ?? '';
      const validEfforts = {'low', 'medium', 'high'};
      _runtimeReasoningEffort = validEfforts.contains(reasoningEffortStr) ? reasoningEffortStr : null;
      _runtimeWebSearchEnabled = prefs.getBool('web_search_enabled') ?? false;
      
      bool hasAIConfig = false;
      if (providerStr == 'doubao' || providerStr == 'hunyuan' || providerStr == 'glm') {
        hasAIConfig = true;
      } else if (providerStr == 'custom') {
        hasAIConfig = true;
      } else {
        final secretId = prefs.getString('tencent_secret_id');
        final secretKey = prefs.getString('tencent_secret_key');
        hasAIConfig = secretId != null && secretId.isNotEmpty && secretKey != null && secretKey.isNotEmpty;
      }

      if (!hasAIConfig) {
        _parseMode = ParseMode.regex;
        await _processWithOCRAndRegex();
      } else {
        _parseMode = ParseMode.ai;
        await AIService.instance.loadConfig();

        if (providerStr == 'doubao') {
          await _processWithOCRAndAI();
        } else if (providerStr == 'custom') {
          final manualOverride = prefs.getBool('custom_api_vision_manual_override') ?? false;
          final manualVisionEnabled = prefs.getBool('custom_api_vision_manual_value') ?? false;

          bool useCustomVision;
          String visionDecisionSource;
          if (manualOverride) {
            useCustomVision = manualVisionEnabled;
            visionDecisionSource = 'manual';
          } else {
            final cachedVisionSupport = await AIService.instance.getCustomVisionSupport(model: customModelName);
            if (cachedVisionSupport != null) {
              useCustomVision = cachedVisionSupport;
              visionDecisionSource = 'cache';
            } else {
              setState(() {
                _currentStep = AIProcessingStep.parsing;
                _statusText = '正在检测自定义模型图片能力...';
              });
              final probedVisionSupport = await AIService.instance.probeCustomVisionSupport(model: customModelName);
              useCustomVision = probedVisionSupport ?? false;
              visionDecisionSource = probedVisionSupport == null ? 'probe-unknown' : 'probe';
            }
          }

          debugPrint('[AI Processing] provider=custom, visionDecisionSource=$visionDecisionSource, supportsVision=$useCustomVision, model=$customModelName');
          
          if (useCustomVision) {
            debugPrint('[AI Processing] custom image import route: vision');
            await _parseWithVisionModelStream(
              provider: 'custom',
              model: customModelName,
              modelLabel: '自定义模型 $customModelName',
            );
          } else {
            debugPrint('[AI Processing] custom image import route: ocr+ai');
            await _processWithOCRAndAI();
          }
        } else {
          await _processWithOCRAndAI();
        }
      }
    } catch (e) {
      setState(() {
        _currentStep = AIProcessingStep.error;
        _errorMessage = '处理失败：$e';
      });
    }
  }

  Future<void> _processWithOCRAndRegex() async {
    setState(() {
      _currentStep = AIProcessingStep.ocr;
      _statusText = '正在识别图片中的文字...';
    });

    final ocrResult = await OCRService.instance.recognizeText(widget.imagePath);
    _ocrText = ocrResult.text;

    if (_ocrText == null || _ocrText!.trim().isEmpty) {
      setState(() {
        _currentStep = AIProcessingStep.error;
        _errorMessage = '未识别到文字内容';
      });
      return;
    }

    _parseWithRegex();
  }

  Future<void> _processWithOCRAndAI() async {
    setState(() {
      _currentStep = AIProcessingStep.ocr;
      _statusText = '正在识别图片中的文字...';
    });

    final ocrResult = await OCRService.instance.recognizeText(widget.imagePath);
    _ocrText = ocrResult.text;

    if (_ocrText == null || _ocrText!.trim().isEmpty) {
      setState(() {
        _currentStep = AIProcessingStep.error;
        _errorMessage = '未识别到文字内容';
      });
      return;
    }

    _parseWithAI();
  }

  Future<void> _parseWithVisionModelStream({
    required String provider,
    required String? model,
    required String modelLabel,
  }) async {
    final file = File(widget.imagePath);
    if (!await file.exists()) {
      setState(() {
        _currentStep = AIProcessingStep.error;
        _errorMessage = '图片文件不存在';
      });
      return;
    }

    final bytes = await file.readAsBytes();
    final imageBase64 = base64Encode(bytes);

    setState(() {
      _currentStep = AIProcessingStep.parsing;
      _statusText = '正在使用$modelLabel识别课程表...';
      _isChatMode = true;
      _isStreaming = true;
      _resetStreamingState();
    });

    _addAIMessage('正在使用$modelLabel直接识别图片...\n\n请稍候，正在分析图片内容...');

    try {
      final stream = AIService.instance.chatWithModelStream(
        userMessage: '请识别这张课程表图片中的所有课程信息，并按照要求的JSON格式输出。请直接输出JSON数组，不要输出其他文字。',
        model: model,
        systemPrompt: '''你是一个课程表解析助手。你的任务是将课程表图片转换为结构化JSON。

输出格式要求：
1. 必须输出一个JSON数组，以 [ 开始，以 ] 结束
2. 每个课程对象包含：name, teacher, location, dayOfWeek, period, duration, weeks
3. dayOfWeek: 1=周一，7=周日
4. period: 从1开始，表示开始节次
5. duration默认规则（非常重要）：
  - 大学课程通常为两节连上，若无法从图片中明确判断，duration 默认填 2
  - 只有当图片中明确显示为单节课时，duration 才填 1
  - 若明确显示跨3节及以上，按实际节数填写
6. weeks字段格式要求（非常重要）：
   - 只输出纯数字、逗号和连字符，绝对不要包含"周"、"连"等任何文字！
   - 正确示例：weeks: "1-16" 或 weeks: "1,3,5-8,10" 或 weeks: "1-8,10-16"
   - 错误示例：weeks: "连1-16" 或 weeks: "1-16周" 或 weeks: "连1-8 连10-16"（这些都是错误的！）
   - 检测到 "连1-16周" 时，输出 "1-16"（去掉"连"和"周"字）
   - 检测到 "连1-8 连10-16周" 时，输出 "1-8,10-16"（去掉"连"和"周"字，用逗号分隔）
7. 仅输出JSON数组，不要输出解释文字''',
        imageBase64: imageBase64,
        provider: provider,
        enableSearch: false,
        reasoningEffort: _runtimeReasoningEffort,
      );
      
      _streamSubscription = stream.listen(
        (chunk) {
          if (!_isFirstChunkReceived) {
            _cancelNoResponseTimer();
            setState(() {
              _isFirstChunkReceived = true;
            });
          }
          setState(() {
            if (chunk.startsWith('【状态】')) {
              _statusText = chunk.substring(4);
              debugPrint('[AI Processing] Status: $_statusText');
            } else if (chunk.startsWith('【思考】')) {
              _cancelNoResponseTimer();
              _thinkingContent += chunk.substring(4);
              _isThinking = true;
              debugPrint('[AI Processing] Thinking: ${chunk.substring(4)}');
            } else {
              _streamingContent += chunk;
              if (_isThinking && !_isThinkingCollapsed) {
                _isThinkingCollapsed = true;
              }
            }
          });
          _updateLastAIStreamingMessage(fallbackText: '正在解析课程表...');
          _scrollToBottom();
        },
        onError: (error) {
          _cancelNoResponseTimer();
          setState(() {
            _currentStep = AIProcessingStep.error;
            _errorMessage = 'AI解析失败: $error';
            _isStreaming = false;
          });
          _updateLastAIMessage('❌ AI解析失败: $error', thinkingContent: null, isThinkingCollapsed: false);
        },
        onDone: () {
          _cancelNoResponseTimer();
          _parseStreamResult();
        },
        cancelOnError: true,
      );
      _startNoResponseTimer();
    } catch (e) {
      setState(() {
        _currentStep = AIProcessingStep.error;
        _errorMessage = 'AI解析失败: $e';
        _isStreaming = false;
      });
      _updateLastAIMessage('❌ AI解析失败: $e', thinkingContent: null, isThinkingCollapsed: false);
    }
  }

  void _parseStreamResult() {
    setState(() {
      _isStreaming = false;
      _isThinking = false;
      _thinkingContent = '';
      _isThinkingCollapsed = false;
    });
    
    try {
      String jsonStr = _streamingContent.trim();
      debugPrint('[AI Processing] Raw streaming content: $jsonStr');
      
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
        throw Exception('AI返回的JSON内容为空');
      }

      debugPrint('[AI Processing] Parsed JSON string: $jsonStr');
      final List<dynamic> coursesJson = jsonDecode(jsonStr);
      
      for (var json in coursesJson) {
        debugPrint('[AI Processing] Course JSON: $json');
        debugPrint('[AI Processing] weeks field: ${json['weeks']}');
      }
      
      final courses = coursesJson.map((json) => CourseData.fromJson(json as Map<String, dynamic>)).toList();
      
      for (var course in courses) {
        debugPrint('[AI Processing] Parsed course: name=${course.name}, weeks=${course.weeks}, startWeek=${course.startWeek}, endWeek=${course.endWeek}');
      }
      
      final colorAssignedCourses = _assignColorsByName(courses);

      setState(() {
        _currentStep = AIProcessingStep.completed;
        _parsedCourses = colorAssignedCourses;
        _selectedModel = AIService.instance.lastStreamedModel;
        _statusText = '解析完成，识别到 ${colorAssignedCourses.length} 门课程';
      });

      _updateLastAIMessage('✅ 已成功识别到 ${colorAssignedCourses.length} 门课程！\n\n💡 点击右上角 📋 按钮可查看和编辑课程详情。\n\n您可以继续问我任何关于课程表的问题，或要求修改课程信息。');
    } catch (e) {
      setState(() {
        _currentStep = AIProcessingStep.error;
        _errorMessage = 'JSON解析失败: $e';
      });
      _updateLastAIMessage('❌ JSON解析失败: $e\n\n原始内容:\n$_streamingContent');
    }
  }

  List<CourseData> _assignColorsByName(List<CourseData> courses) {
    final colorMap = <String, String>{};
    final colors = CourseColorPalette.extendedHexColors;
    int colorIndex = 0;
    
    for (final course in courses) {
      if (!colorMap.containsKey(course.name)) {
        colorMap[course.name] = colors[colorIndex % colors.length];
        colorIndex++;
      }
    }
    
    return courses.map((c) => CourseData(
      name: c.name,
      teacher: c.teacher,
      location: c.location,
      dayOfWeek: c.dayOfWeek,
      period: c.period,
      duration: c.duration,
      startTime: c.startTime,
      endTime: c.endTime,
      startWeek: c.startWeek,
      endWeek: c.endWeek,
      weeks: c.weeks,
      color: colorMap[c.name],
      notes: c.notes,
    )).toList();
  }

  Future<void> _parseWithRegex() async {
    setState(() {
      _currentStep = AIProcessingStep.parsing;
      _statusText = '正在解析课程表（正则模式）...';
    });

    try {
      final courses = RegexParserService.instance.parseScheduleText(_ocrText!);

      if (courses.isEmpty) {
        setState(() {
          _currentStep = AIProcessingStep.error;
          _errorMessage = '未能解析出课程信息\n\n提示：配置GLM API Key可获得更准确的AI解析';
        });
        return;
      }

      setState(() {
        _currentStep = AIProcessingStep.completed;
        _parsedCourses = courses;
        _statusText = '解析完成（正则模式），识别到 ${courses.length} 门课程';
      });

      _addAIMessage('已通过正则表达式识别到 ${courses.length} 门课程。\n\n提示：配置GLM API Key后可获得更准确的AI解析和对话功能。');
    } catch (e) {
      setState(() {
        _currentStep = AIProcessingStep.error;
        _errorMessage = '正则解析失败：$e\n\n提示：配置GLM API Key可获得更准确的AI解析';
      });
    }
  }

  Future<void> _parseWithAI() async {
    setState(() {
      _currentStep = AIProcessingStep.parsing;
      _statusText = '正在使用AI解析课程表...';
      _isChatMode = true;
      _isStreaming = true;
      _resetStreamingState();
    });

    _addAIMessage('正在等待AI响应...\n\nOCR识别内容:\n${_ocrText!.length > 500 ? _ocrText!.substring(0, 500) + '...' : _ocrText}');

    try {
      final stream = AIService.instance.parseScheduleTextStream(
        _ocrText!,
        reasoningEffort: _runtimeReasoningEffort,
      );
      _streamSubscription = stream.listen(
        (chunk) {
          if (!_isFirstChunkReceived) {
            _cancelNoResponseTimer();
            setState(() {
              _isFirstChunkReceived = true;
            });
          }
          setState(() {
            if (chunk.startsWith('【状态】')) {
              _statusText = chunk.substring(4);
            } else if (chunk.startsWith('【思考】')) {
              _cancelNoResponseTimer();
              _thinkingContent += chunk.substring(4);
              _isThinking = true;
            } else {
              _streamingContent += chunk;
              if (_isThinking && !_isThinkingCollapsed) {
                _isThinkingCollapsed = true;
              }
            }
          });
          _updateLastAIStreamingMessage(fallbackText: '正在解析课程表...');
          _scrollToBottom();
        },
        onError: (error) {
          _cancelNoResponseTimer();
          setState(() {
            _currentStep = AIProcessingStep.error;
            _errorMessage = 'AI解析失败: $error';
            _isStreaming = false;
          });
          _updateLastAIMessage('❌ AI解析失败: $error', thinkingContent: null, isThinkingCollapsed: false);
        },
        onDone: () {
          _cancelNoResponseTimer();
          _parseStreamResult();
        },
        cancelOnError: true,
      );
      _startNoResponseTimer();
    } catch (e) {
      setState(() {
        _currentStep = AIProcessingStep.error;
        _errorMessage = 'AI解析失败: $e';
        _isStreaming = false;
      });
      _updateLastAIMessage('❌ AI解析失败: $e', thinkingContent: null, isThinkingCollapsed: false);
    }
  }

  void _addAIMessage(
    String text, {
    String? thinkingContent,
    bool isThinkingCollapsed = false,
  }) {
    _chatMessages.add(ChatMessage(
      text: text,
      isUser: false,
      timestamp: DateTime.now(),
      thinkingContent: thinkingContent,
      isThinkingCollapsed: isThinkingCollapsed,
    ));
    _scrollToBottom();
  }

  void _updateLastAIMessage(
    String text, {
    String? thinkingContent,
    bool? isThinkingCollapsed,
  }) {
    if (_chatMessages.isNotEmpty && !_chatMessages.last.isUser) {
      final previous = _chatMessages[_chatMessages.length - 1];
      _chatMessages[_chatMessages.length - 1] = ChatMessage(
        text: text,
        isUser: false,
        timestamp: DateTime.now(),
        thinkingContent: thinkingContent,
        isThinkingCollapsed: isThinkingCollapsed ?? previous.isThinkingCollapsed,
      );
    }
  }

  void _addUserMessage(String text) {
    _chatMessages.add(ChatMessage(
      text: text,
      isUser: true,
      timestamp: DateTime.now(),
    ));
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _toggleThinkingBubble(ChatMessage message) {
    final index = _chatMessages.indexOf(message);
    if (index == -1 || _chatMessages[index].isUser) return;

    final current = _chatMessages[index];
    setState(() {
      _chatMessages[index] = ChatMessage(
        text: current.text,
        isUser: current.isUser,
        timestamp: current.timestamp,
        thinkingContent: current.thinkingContent,
        isThinkingCollapsed: !current.isThinkingCollapsed,
      );
    });

    if (!current.isThinkingCollapsed) return;
    _scrollThinkingToBottom();
  }

  Future<void> _sendMessage() async {
    if (_parseMode == ParseMode.regex) {
      _addAIMessage('正则模式下暂不支持对话功能。请配置混元密钥后使用AI对话。');
      return;
    }

    final text = _chatController.text.trim();
    if (text.isEmpty || _isSending) return;

    _chatController.clear();
    _addUserMessage(text);
    _addAIMessage('正在思考...');
    
    setState(() {
      _isSending = true;
      _isStreaming = true;
      _resetStreamingState();
    });

    try {
      final history = _chatMessages
          .take(_chatMessages.length - 2)
          .map((msg) => {'role': msg.isUser ? 'user' : 'assistant', 'content': msg.text})
          .toList();

      final stream = AIService.instance.chatScheduleStream(
        userMessage: text,
        courses: _parsedCourses ?? [],
        ocrContext: _ocrText,
        history: history,
        reasoningEffort: _runtimeReasoningEffort,
      );

      _streamSubscription = stream.listen(
        (chunk) {
          setState(() {
            if (chunk.startsWith('【状态】')) {
              _statusText = chunk.substring(4);
            } else if (chunk.startsWith('【思考】')) {
              _thinkingContent += chunk.substring(4);
              _isThinking = true;
            } else {
              _streamingContent += chunk;
              if (_isThinking && !_isThinkingCollapsed) {
                _isThinkingCollapsed = true;
              }
            }
          });
          _updateLastAIStreamingMessage();
          _scrollToBottom();
        },
        onError: (error) {
          setState(() {
            _isSending = false;
            _isStreaming = false;
            _resetStreamingState();
          });
          _updateLastAIMessage('❌ 处理失败: $error', thinkingContent: null, isThinkingCollapsed: false);
        },
        onDone: () {
          setState(() {
            _isSending = false;
            _isStreaming = false;
            _isThinking = false;
          });
          
          final processed = _processScheduleResponse(_streamingContent);
          if (processed != null) {
            _updateLastAIMessage(
              processed,
              thinkingContent: _thinkingContent.isNotEmpty ? _thinkingContent : null,
              isThinkingCollapsed: _isThinkingCollapsed,
            );
          }
          _resetStreamingState();
        },
        cancelOnError: true,
      );
    } catch (e) {
      setState(() {
        _isSending = false;
        _isStreaming = false;
        _isThinking = false;
      });
      _updateLastAIMessage('抱歉，处理您的请求时出错：$e', thinkingContent: null, isThinkingCollapsed: false);
    }
  }

  String? _processScheduleResponse(String content) {
    debugPrint('[AI Processing] Processing response content: $content');
    try {
      int startIndex = content.indexOf('{');
      int endIndex = content.lastIndexOf('}');
      if (startIndex == -1 || endIndex == -1 || endIndex <= startIndex) {
        debugPrint('[AI Processing] No JSON found in content');
        return null;
      }
      
      String jsonStr = content.substring(startIndex, endIndex + 1);
      debugPrint('[AI Processing] Extracted JSON: $jsonStr');
      
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      final action = json['action'] as String?;
      debugPrint('[AI Processing] Action: $action');
      
      if (action == null) return null;

      if (action == 'add') {
        final courseJson = json['course'] as Map<String, dynamic>?;
        if (courseJson != null) {
          final newCourse = CourseData.fromJson(courseJson);
          final colorAssignedCourses = _assignColorsByName([..._parsedCourses ?? [], newCourse]);
          setState(() {
            _parsedCourses = colorAssignedCourses;
            _statusText = '解析完成，识别到 ${colorAssignedCourses.length} 门课程';
          });
          return '✅ 已添加课程：**${newCourse.name}**\n\n'
              '📍 地点：${newCourse.location ?? "未知"}\n'
              '👨‍🏫 教师：${newCourse.teacher ?? "未知"}\n'
              '📅 时间：周${["一", "二", "三", "四", "五", "六", "日"][newCourse.dayOfWeek - 1]} 第${newCourse.period}节';
        }
      } else if (action == 'modify') {
        final index1Based = json['index'] as int?;
        final courseJson = json['course'] as Map<String, dynamic>?;
        if (index1Based != null && courseJson != null && _parsedCourses != null) {
          final index0Based = index1Based - 1;
          if (index0Based >= 0 && index0Based < _parsedCourses!.length) {
            final updatedCourse = CourseData.fromJson(courseJson);
            setState(() {
              final newList = List<CourseData>.from(_parsedCourses!);
              newList[index0Based] = updatedCourse;
              _parsedCourses = newList;
            });
            return '✅ 已修改第 $index1Based 门课程：**${updatedCourse.name}**\n\n'
                '📍 地点：${updatedCourse.location ?? "未知"}\n'
                '👨‍🏫 教师：${updatedCourse.teacher ?? "未知"}\n'
                '📅 时间：周${["一", "二", "三", "四", "五", "六", "日"][updatedCourse.dayOfWeek - 1]} 第${updatedCourse.period}节';
          } else {
            return '❌ 无效的课程序号：$index1Based（当前共有 ${_parsedCourses!.length} 门课程）';
          }
        }
      } else if (action == 'delete') {
        final index1Based = json['index'] as int?;
        if (index1Based != null && _parsedCourses != null) {
          final index0Based = index1Based - 1;
          if (index0Based >= 0 && index0Based < _parsedCourses!.length) {
            final deletedCourse = _parsedCourses![index0Based];
            setState(() {
              final newList = List<CourseData>.from(_parsedCourses!);
              newList.removeAt(index0Based);
              _parsedCourses = newList;
              _statusText = '解析完成，识别到 ${_parsedCourses!.length} 门课程';
            });
            return '🗑️ 已删除第 $index1Based 门课程：**${deletedCourse.name}**';
          } else {
            return '❌ 无效的课程序号：$index1Based（当前共有 ${_parsedCourses!.length} 门课程）';
          }
        }
      }
    } catch (e) {
      debugPrint('Error processing schedule response: $e');
    }
    return null;
  }

  void _handleCourseAction(String action, CourseData course, int index) {
    if (action == 'edit') {
      _editCourse(course, index);
    } else if (action == 'delete') {
      _deleteCourse(index);
    }
  }

  void _editCourse(CourseData courseData, int index) {
    final course = Course(
      id: 'temp_$index',
      name: courseData.name,
      teacher: courseData.teacher,
      location: courseData.location,
      day: courseData.dayOfWeek - 1,
      time: (courseData.period ?? 1) - 1,
      duration: courseData.duration ?? 2,
      weeks: courseData.weeks ?? _buildWeeksString(courseData.startWeek, courseData.endWeek),
      color: courseData.color ?? '#4A90E2',
    );
    
    CourseDialog.show(
      context: context,
      course: course,
      selectedDay: course.day,
      selectedPeriod: course.time,
    ).then((updatedCourse) {
      if (updatedCourse != null) {
        setState(() {
          _parsedCourses![index] = CourseData(
            name: updatedCourse.name,
            teacher: updatedCourse.teacher,
            location: updatedCourse.location,
            dayOfWeek: updatedCourse.day + 1,
            period: updatedCourse.time + 1,
            duration: updatedCourse.duration,
            weeks: updatedCourse.weeks,
            color: updatedCourse.color,
          );
        });
      }
    });
  }

  void _deleteCourse(int index) {
    setState(() {
      _parsedCourses!.removeAt(index);
      _statusText = '解析完成，识别到 ${_parsedCourses!.length} 门课程';
    });
    _addAIMessage('已删除课程。当前共 ${_parsedCourses!.length} 门课程。');
  }

  String _buildWeeksString(int? startWeek, int? endWeek) {
    if (startWeek == null || endWeek == null) return '';
    return '$startWeek-$endWeek';
  }

  Color _parseColor(String hex) {
    try {
      hex = hex.replaceAll('#', '');
      if (hex.length == 6) {
        return Color(int.parse('FF$hex', radix: 16));
      }
    } catch (e) {
      debugPrint('Error parsing color: $e');
    }
    return const Color(0xFF4A90E2);
  }

  @override
  Widget build(BuildContext context) {
    final keyboardHeight = MediaQuery.of(context).viewInsets.bottom;
    final screenHeight = MediaQuery.of(context).size.height;
    final topPadding = MediaQuery.of(context).padding.top;
    
    final dialogMaxHeight = screenHeight - topPadding - keyboardHeight - 40;
    final actualMaxHeight = dialogMaxHeight.clamp(300.0, 600.0);
    
    return Center(
      child: Material(
        color: Colors.transparent,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          margin: EdgeInsets.only(
            left: 24, 
            right: 24, 
            bottom: keyboardHeight > 0 ? keyboardHeight + 8 : 0,
          ),
          constraints: BoxConstraints(maxWidth: 500, maxHeight: actualMaxHeight),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.2),
                blurRadius: 30,
                offset: const Offset(0, 15),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildHeader(),
              const Divider(height: 1),
              Expanded(
                child: ScrollConfiguration(
                  behavior: ScrollConfiguration.of(context).copyWith(
                    physics: const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics(),
                    ),
                  ),
                  child: _isChatMode ? _buildChatView() : _buildProcessingView(),
                ),
              ),
              if (_currentStep == AIProcessingStep.completed) ...[
                const Divider(height: 1),
                _buildBottomActions(),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: _parseMode == ParseMode.ai
              ? [const Color(0xFF9C27B0), const Color(0xFFBA68C8)]
              : [const Color(0xFF4A90E2), const Color(0xFF6BA3F5)],
        ),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              _parseMode == ParseMode.ai ? Icons.auto_awesome : Icons.rule,
              color: Colors.white,
              size: 24,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '课程表识别',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _parseMode == ParseMode.ai 
                    ? (_runtimeProvider == 'custom'
                      ? '自定义模型 AI驱动'
                      : (_runtimeProvider == 'hunyuan'
                        ? '混元 Lite AI驱动'
                        : (_runtimeProvider == 'glm'
                          ? 'GLM-4.7-Flash AI驱动'
                          : 'AI驱动')))
                      : '正则表达式模式',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.white70,
                  ),
                ),
              ],
            ),
          ),
          if (_currentStep == AIProcessingStep.completed && _parsedCourses != null && _parsedCourses!.isNotEmpty)
            IconButton(
              onPressed: () {
                setState(() {
                  if (_showCourseListInDialog) {
                    _showCourseListInDialog = false;
                    _isChatMode = true;
                  } else {
                    _showCourseListInDialog = true;
                    _isChatMode = false;
                  }
                });
              },
              icon: Icon(
                _showCourseListInDialog ? Icons.chat : Icons.edit_note,
                color: Colors.white,
              ),
              tooltip: _showCourseListInDialog ? 'AI对话' : '编辑课程',
            ),
        ],
      ),
    );
  }

  Widget _buildProcessingView() {
    if (_currentStep == AIProcessingStep.error) {
      return _buildErrorView();
    }

    if (_currentStep == AIProcessingStep.completed && _parsedCourses != null) {
      if (_showCourseListInDialog) {
        return _buildEditableCourseListView();
      }
      if (_isChatMode && _parseMode == ParseMode.ai) {
        return _buildChatView();
      }
      return _buildResultView();
    }

    return _buildLoadingView();
  }

  Widget _buildLoadingView() {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 80,
            height: 80,
            child: CircularProgressIndicator(
              strokeWidth: 4,
              valueColor: AlwaysStoppedAnimation(
                _parseMode == ParseMode.ai ? const Color(0xFF9C27B0) : const Color(0xFF4A90E2),
              ),
              backgroundColor: Colors.grey.shade200,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            _statusText,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildStepIndicator('OCR识别', _currentStep == AIProcessingStep.ocr),
              _buildStepConnector(),
              _buildStepIndicator(
                _parseMode == ParseMode.ai ? 'AI解析' : '正则解析',
                _currentStep == AIProcessingStep.parsing,
              ),
              _buildStepConnector(),
              _buildStepIndicator('完成', _currentStep == AIProcessingStep.completed),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStepIndicator(String label, bool isActive) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: isActive
            ? (_parseMode == ParseMode.ai ? const Color(0xFF9C27B0) : const Color(0xFF4A90E2))
            : Colors.grey.shade200,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: isActive ? Colors.white : Colors.grey.shade600,
        ),
      ),
    );
  }

  Widget _buildStepConnector() {
    return Container(
      width: 20,
      height: 2,
      color: Colors.grey.shade300,
    );
  }

  Widget _buildErrorView() {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: Colors.orange.shade50,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(
              Icons.warning_amber_rounded,
              size: 40,
              color: Colors.orange.shade400,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            _errorMessage ?? '处理失败',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton(
                onPressed: () => Navigator.pop(context),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.grey.shade200,
                  foregroundColor: Colors.grey.shade700,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text('关闭'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildResultView() {
    return Column(
      children: [
        if (_parseMode == ParseMode.regex)
          Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.blue.shade50,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.blue.shade100),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline, color: Colors.blue.shade700, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '正则模式解析。配置GLM API Key可获得更准确的AI解析。',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.blue.shade700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            itemCount: _parsedCourses!.length,
            itemBuilder: (context, index) {
              final course = _parsedCourses![index];
              final dayNames = ['', '周一', '周二', '周三', '周四', '周五', '周六', '周日'];
              final courseColor = _parseColor(course.color ?? '#4A90E2');

              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 4,
                      height: 50,
                      decoration: BoxDecoration(
                        color: courseColor,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            course.name,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${dayNames[course.dayOfWeek]} ${course.period != null ? "第${course.period}节" : ""}'
                            '${course.location != null ? ' · ${course.location}' : ''}'
                            '${course.teacher != null ? ' · ${course.teacher}' : ''}',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildEditableCourseListView() {
    final dayNames = ['', '周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          color: Colors.grey.shade100,
          child: Row(
            children: [
              Icon(Icons.edit_note, color: Colors.grey.shade700, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '编辑课程列表 · 共 ${_parsedCourses!.length} 门',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Colors.grey.shade700,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: () => setState(() => _showCourseListInDialog = false),
                icon: const Icon(Icons.check, size: 18),
                label: const Text('完成'),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF9C27B0),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: _parsedCourses!.length,
            itemBuilder: (context, index) {
              final course = _parsedCourses![index];
              final courseColor = _parseColor(course.color ?? '#4A90E2');
              
              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 4,
                      height: 60,
                      decoration: BoxDecoration(
                        color: courseColor,
                        borderRadius: const BorderRadius.horizontal(left: Radius.circular(12)),
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              course.name,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${dayNames[course.dayOfWeek]} ${course.period != null ? "第${course.period}节" : ""}'
                              '${course.location != null ? ' · ${course.location}' : ''}'
                              '${course.teacher != null ? ' · ${course.teacher}' : ''}',
                              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                            ),
                          ],
                        ),
                      ),
                    ),
                    PopupMenuButton<String>(
                      icon: Icon(Icons.more_vert, color: Colors.grey.shade400, size: 20),
                      onOpened: () {
                        HapticFeedback.selectionClick();
                      },
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      color: Colors.white,
                      elevation: 8,
                      onSelected: (value) => _handleCourseAction(value, course, index),
                      itemBuilder: (context) => [
                        const PopupMenuItem(
                          value: 'edit',
                          child: Row(
                            children: [
                              Icon(Icons.edit_outlined, color: Color(0xFF4A90E2), size: 18),
                              SizedBox(width: 8),
                              Text('编辑'),
                            ],
                          ),
                        ),
                        const PopupMenuItem(
                          value: 'delete',
                          child: Row(
                            children: [
                              Icon(Icons.delete_outline, color: Colors.red, size: 18),
                              SizedBox(width: 8),
                              Text('删除', style: TextStyle(color: Colors.red)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildChatView() {
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.all(16),
            itemCount: _chatMessages.length,
            itemBuilder: (context, index) {
              final message = _chatMessages[index];
              return _buildChatBubble(message);
            },
          ),
        ),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.grey.shade50,
            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(24)),
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _chatController,
                  decoration: InputDecoration(
                    hintText: '问我任何关于课程表的问题...',
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide(color: Colors.grey.shade300),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide(color: Colors.grey.shade300),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: const BorderSide(color: Color(0xFF9C27B0)),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  ),
                  onSubmitted: (_) => _sendMessage(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: _isSending ? null : _sendMessage,
                icon: _isSending
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send, color: Color(0xFF9C27B0)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildChatBubble(ChatMessage message) {
    return Align(
      alignment: message.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.7,
        ),
        decoration: BoxDecoration(
          color: message.isUser
              ? const Color(0xFF9C27B0)
              : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(16),
        ),
        child: message.isUser
            ? Text(
                message.text,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (message.thinkingContent != null && message.thinkingContent!.isNotEmpty) ...[
                    _buildThinkingBubble(message),
                    if (message.text.isNotEmpty) const SizedBox(height: 10),
                  ],
                  if (message.text.isNotEmpty)
                    MarkdownBody(
                      data: message.text,
                      styleSheet: MarkdownStyleSheet(
                        p: const TextStyle(fontSize: 14),
                        code: TextStyle(
                          fontSize: 12,
                          backgroundColor: Colors.grey.shade200,
                        ),
                        codeblockDecoration: BoxDecoration(
                          color: Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      extensionSet: md.ExtensionSet.gitHubWeb,
                    ),
                ],
              ),
      ),
    );
  }

  Widget _buildThinkingBubble(ChatMessage message) {
    final isExpanded = !message.isThinkingCollapsed;
    final isThinkingLive = _isStreaming && _isThinking;
    final isLiveMessage =
        _isStreaming && _chatMessages.isNotEmpty && identical(message, _chatMessages.last);

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _toggleThinkingBubble(message),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isThinkingLive && message.text.isEmpty)
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.grey.shade500,
                    ),
                  )
                else
                  Icon(
                    isExpanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: Colors.grey.shade500,
                  ),
                const SizedBox(width: 6),
                Text(
                  isThinkingLive && message.text.isEmpty ? '思考中...' : '思考过程',
                  style: TextStyle(
                    color: Colors.grey.shade600,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          if (isExpanded) ...[
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 120),
              child: SingleChildScrollView(
                controller: isLiveMessage ? _thinkingScrollController : null,
                child: MarkdownBody(
                  data: message.thinkingContent!,
                  styleSheet: MarkdownStyleSheet(
                    p: const TextStyle(fontSize: 12, height: 1.5),
                    code: TextStyle(
                      fontSize: 11,
                      backgroundColor: Colors.grey.shade200,
                    ),
                  ),
                  extensionSet: md.ExtensionSet.gitHubWeb,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBottomActions() {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () => Navigator.pop(context),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text('取消'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                widget.onCompleted?.call(_parsedCourses!);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: _parseMode == ParseMode.ai
                    ? const Color(0xFF9C27B0)
                    : const Color(0xFF4A90E2),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text('导入课程'),
            ),
          ),
        ],
      ),
    );
  }
}

class ChatMessage {
  final String text;
  final bool isUser;
  final DateTime timestamp;
  final String? thinkingContent;
  final bool isThinkingCollapsed;

  ChatMessage({
    required this.text,
    required this.isUser,
    required this.timestamp,
    this.thinkingContent,
    this.isThinkingCollapsed = false,
  });
}

class _CourseEditDialog extends StatefulWidget {
  final Course course;
  final Function(Course) onSave;

  const _CourseEditDialog({
    required this.course,
    required this.onSave,
  });

  @override
  State<_CourseEditDialog> createState() => _CourseEditDialogState();
}

class _CourseEditDialogState extends State<_CourseEditDialog> {
  late TextEditingController _nameController;
  late TextEditingController _teacherController;
  late TextEditingController _locationController;
  late int _selectedDay;
  late int _selectedPeriod;
  late int _selectedDuration;
  late Color _selectedColor;

  final List<Color> _colorOptions = CourseColorPalette.primaryColors;

  final List<String> _weekDayNames = ['一', '二', '三', '四', '五', '六', '日'];

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.course.name);
    _teacherController = TextEditingController(text: widget.course.teacher ?? '');
    _locationController = TextEditingController(text: widget.course.location ?? '');
    _selectedDay = widget.course.day.clamp(0, 6);
    _selectedPeriod = widget.course.time.clamp(1, 12);
    _selectedDuration = widget.course.duration.clamp(1, 4);
    _selectedColor = _parseColor(widget.course.color);
  }

  Color _parseColor(String hex) {
    try {
      hex = hex.replaceAll('#', '');
      if (hex.length == 6) {
        return Color(int.parse('FF$hex', radix: 16));
      }
    } catch (e) {
      debugPrint('Error parsing color: $e');
    }
    return const Color(0xFF4A90E2);
  }

  String _colorToHex(Color color) {
    return CourseColorPalette.colorToHex(color);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 400,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '编辑课程',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _nameController,
            decoration: InputDecoration(
              labelText: '课程名称',
              filled: true,
              fillColor: Colors.grey.shade50,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.grey.shade300),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFF9C27B0), width: 2),
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _teacherController,
            decoration: InputDecoration(
              labelText: '教师',
              filled: true,
              fillColor: Colors.grey.shade50,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.grey.shade300),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFF9C27B0), width: 2),
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _locationController,
            decoration: InputDecoration(
              labelText: '地点',
              filled: true,
              fillColor: Colors.grey.shade50,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.grey.shade300),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFF9C27B0), width: 2),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<int>(
                  value: _selectedDay,
                  decoration: InputDecoration(
                    labelText: '星期',
                    filled: true,
                    fillColor: Colors.grey.shade50,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: Colors.grey.shade300),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Color(0xFF9C27B0), width: 2),
                    ),
                  ),
                  items: List.generate(7, (i) => DropdownMenuItem(
                    value: i,
                    child: Text('周${_weekDayNames[i]}'),
                  )),
                  onChanged: (v) => setState(() => _selectedDay = v!),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<int>(
                  value: _selectedPeriod,
                  decoration: InputDecoration(
                    labelText: '节次',
                    filled: true,
                    fillColor: Colors.grey.shade50,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: Colors.grey.shade300),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Color(0xFF9C27B0), width: 2),
                    ),
                  ),
                  items: List.generate(12, (i) => DropdownMenuItem(
                    value: i + 1,
                    child: Text('第${i + 1}节'),
                  )),
                  onChanged: (v) => setState(() => _selectedPeriod = v!),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            value: _selectedDuration,
            decoration: InputDecoration(
              labelText: '持续节数',
              filled: true,
              fillColor: Colors.grey.shade50,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.grey.shade300),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFF9C27B0), width: 2),
              ),
            ),
            items: [1, 2, 3, 4].map((d) => DropdownMenuItem(
              value: d,
              child: Text('$d 节'),
            )).toList(),
            onChanged: (v) => setState(() => _selectedDuration = v!),
          ),
          const SizedBox(height: 12),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _colorOptions.length,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 5,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              mainAxisExtent: 34,
            ),
            itemBuilder: (context, index) {
              final color = _colorOptions[index];
              final isSelected = _selectedColor.toARGB32() == color.toARGB32();
              return GestureDetector(
                onTap: () => setState(() => _selectedColor = color),
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: isSelected
                        ? Border.all(color: Colors.black, width: 2)
                        : null,
                  ),
                  child: isSelected
                      ? const Icon(Icons.check, size: 16, color: Colors.white)
                      : null,
                ),
              );
            },
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              const SizedBox(width: 12),
              ElevatedButton(
                onPressed: () {
                  widget.onSave(Course(
                    id: widget.course.id,
                    name: _nameController.text,
                    teacher: _teacherController.text.isEmpty ? null : _teacherController.text,
                    location: _locationController.text.isEmpty ? null : _locationController.text,
                    day: _selectedDay,
                    time: _selectedPeriod,
                    duration: _selectedDuration,
                    weeks: widget.course.weeks,
                    color: _colorToHex(_selectedColor),
                  ));
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF9C27B0),
                  foregroundColor: Colors.white,
                ),
                child: const Text('保存'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
