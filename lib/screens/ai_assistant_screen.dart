import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../theme/app_theme.dart';
import 'package:flutter/rendering.dart';
import 'package:image/image.dart' as img;
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'home_screen.dart';
import '../widgets/toast_notification.dart';
import '../widgets/builtin_ai_usage_bar.dart';
import '../widgets/fading_edge_list.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';
import '../services/glm_service.dart';
import '../config/ai_feature_flags.dart';
import '../utils/storage.dart';
import '../utils/course_summary.dart';
import '../models/course.dart';
import '../models/task.dart';
import '../models/chat_session.dart';
import '../dialogs/course_dialog.dart';
import '../widgets/glass_dialog.dart';
import 'settings_screen.dart';
import '../widgets/segmented_selector.dart';
import '../widgets/selectable_block_adapter.dart';
import 'ai_sessions_menu_panel.dart';
import '../widgets/blur_selection_menu.dart';
import '../widgets/selection_handles.dart';
import '../widgets/floating_glass_button.dart';
import '../widgets/gradient_blur_header.dart';
import '../widgets/app_text_field.dart';

class AIAssistantScreen extends StatefulWidget {
  final VoidCallback? onKeyboardShown;
  final VoidCallback? onKeyboardHidden;
  final VoidCallback? onNavigateToSettings;
  final VoidCallback? onPageVisible;

  const AIAssistantScreen({
    super.key,
    this.onKeyboardShown,
    this.onKeyboardHidden,
    this.onNavigateToSettings,
    this.onPageVisible,
  });

  @override
  State<AIAssistantScreen> createState() => AIAssistantScreenState();
}

class AIAssistantScreenState extends State<AIAssistantScreen>
    with
        WidgetsBindingObserver,
        TickerProviderStateMixin,
        AutomaticKeepAliveClientMixin {
  // 保活：在 PageView 中切走再切回时不再销毁重建整个聊天，避免重复解析 Markdown/重载图片造成卡顿
  @override
  bool get wantKeepAlive => true;

  static List<_ChatMessage> _persistentMessages = [];
  static String? _persistentSelectedModel;
  static bool _hasAnalyzed = false;

  /// 欢迎消息（课程分析）基于的课表 id：切换课表后与之不同时，
  /// 欢迎消息右上角展示"重新生成"按钮（正常不展示）
  static String? _analysisTimetableId;
  static double _persistentScrollOffset = 0.0;
  static bool _needsRefresh = false;
  static bool _isAnalyzing = false;

  /// 当前会话标题（首轮对话完成后由 AI 自动生成）；null 时顶栏显示"课表助手"
  static String? _persistentChatTitle;

  /// 当前对话对应的已保存会话 id（保存过才有，再次保存时覆盖更新）
  static String? _persistentSavedSessionId;

  /// 本会话是否已尝试/完成标题生成（恢复的历史会话视为已有标题，不再生成）
  static bool _titleGeneratedThisSession = false;
  static bool _isGeneratingTitle = false;

  /// 已保存会话菜单（Overlay）打开期间为 true：菜单内编辑框的键盘变化
  /// 不驱动对话页输入区/消息列表移动，关闭菜单后统一补一次同步
  static bool _sessionsMenuOpen = false;
  static final ValueNotifier<int> _streamUpdateTick = ValueNotifier<int>(0);

  static bool _isLoading = false;
  static bool _isFirstChunkReceived = false;
  bool _fastModeEnabled = false;
  bool _showSlowResponseTip = false;
  bool _aiEnabled = false;

  /// 「设置 → AI设置 → 自动课表分析」子开关（从属于 AI 功能总开关）。
  /// 关闭时进入对话页不再调用 AI 分析课表，直接展示默认欢迎卡；已经生成
  /// 出来的分析留在会话里，下次进入也不重发。仅关掉自动触发，欢迎消息
  /// 右上角的「重新生成」按钮仍可手动分析。
  bool _aiAutoScheduleAnalysis = true;

  /// 默认欢迎页的文案缓存：随机部分按 [_welcomeSignatureNow] 复用，
  /// 时段/学期状态/课程有变动时才重掷——否则每次 rebuild 都会换字
  _WelcomeContent? _welcomeCache;
  String _welcomeSignature = '';
  bool _supportsImageUpload = false;
  // 内置模型（限时免费）：当前节点 1-4，徽章锚点 key
  int _builtinNode = 1;
  final GlobalKey _builtinBadgeKey = GlobalKey();
  static bool _isSearching = false;
  static bool _isReasoningModel = false;
  bool _hasSentContext = false;
  static bool _isThinking = false;
  static bool _isThinkingCollapsed = false;
  bool _showAddMenu = false;

  /// 加号菜单弹出动画（对齐三点菜单 _MenuPopTransition）：
  /// 220ms easeOutBack 弹出 / easeInCubic 收起，透明度 + 向上滑入 + 自底部缩放；
  /// 菜单自按钮上方向上弹出，故方向与锚点对齐方式与向下弹出的三点菜单镜像
  AnimationController? _addMenuController;
  CurvedAnimation? _addMenuCurved;
  bool _pauseAutoScrollDuringOutput = false;
  bool _customModelIsReasoning = false;
  bool _customModelSupportsVision = false;
  static String _currentProvider = '';
  String? _currentReasoningEffort;
  bool _webSearchEnabled = false;
  String _customModelName = 'gpt-5-mini';
  static String _statusMessage = '';
  static String _thinkingContent = '';
  double _lastKeyboardHeight = 0;
  double _layoutKeyboardHeight = 0;
  double _keyboardDismissBounceOffset = 0;

  /// 键盘驱动的布局参数用 ValueNotifier 承载，键盘高度变化时只重建输入区/内边距，
  /// 不再触发主 build()（消息列表不重建），消除键盘弹出/收起时的卡顿。
  final ValueNotifier<
          ({double layoutHeight, double bounceOffset, double rawHeight})>
      _keyboardLayoutNotifier =
      ValueNotifier((layoutHeight: 0, bounceOffset: 0, rawHeight: 0));

  /// 输入区实测总高度（post-frame 读 RenderBox，含图片预览/多行增长/边框内边距），
  /// 驱动消息列表底部避让。替代旧的「字符数估行 × 固定行高」方案——该方案对
  /// 中文（实际每行约 16 字而非估算的 25）、字体缩放、附件区动画都会系统性失准
  double _inputAreaHeight = 61;
  final GlobalKey _inputAreaKey = GlobalKey();

  /// 输入框内部滚动控制器（多行超出显示区域后内部滚动），用于边缘淡出判定
  final ScrollController _inputScrollController = ScrollController();

  /// 输入框上下边缘淡出状态：仅当文字超出显示区域滚动时，有剩余内容的一端淡出
  final ValueNotifier<({bool top, bool bottom})> _inputEdgeFade =
      ValueNotifier((top: false, bottom: false));
  late final AnimationController _keyboardDismissAnimController;
  Animation<double>? _keyboardDismissAnimation;
  Animation<double>? _keyboardDismissBounceAnimation;
  int _retryCount = 0;
  static const int _maxRetryCount = 2;
  static const Duration _noResponseTimeout = Duration(seconds: 30);
  /// 本页 AI 请求的 owner 标识：传给 AIService 后，本页就能用
  /// abortActiveStreams 精确中断**自己**发出的请求，不会误伤课表 OCR 识别、
  /// DDL 洞察等其它模块同时在跑的请求
  static final Object _aiRequestOwner = Object();
  /// 自动重试前的退避步长：第 n 次重试等待 n × 800ms。
  /// 超时请求往往还在服务端慢慢产出，立刻原样重发会叠罗汉
  static const Duration _retryBackoffStep = Duration(milliseconds: 800);
  Timer? _noResponseTimer;
  String? _lastUserMessage;
  String? _lastImageBase64;
  List<Map<String, String>>? _lastHistory;

  /// 「选取文字」模式下消息的下标与长按位置：该消息正文由
  /// SelectionArea 接管手势并自动选中长按所在行；index 为 null 表示
  /// 无消息处于选取模式
  int? _selectingMessageIndex;
  Offset? _selectingPressPosition;
  bool _stopRequested = false;
  late List<_ChatMessage> _messages;
  late String? _selectedModel;
  String? _chatTitle;
  String? _currentSavedSessionId;
  // 已保存会话的下拉菜单（Overlay 浮层 + 自持动画控制器，支持收起反向动画）
  OverlayEntry? _sessionsMenuOverlay;
  AnimationController? _sessionsMenuController;
  CurvedAnimation? _sessionsMenuCurved;
  String? _selectedImagePath;
  String? _selectedImageBase64;
  double? _selectedImageAspectRatio;
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  /// 标题栏悬浮件浮现进度：会话贴顶（标题栏下方无内容）时 ⋮ 保持无界、
  /// 模型徽章退回原来的纯色底，内容滚进标题栏后才浮出玻璃壳与投影。
  /// 目标值由滚动偏移给出，实际浓度走固定时长补间，甩动/回弹都不会闪。
  late final HeaderReveal _headerReveal =
      HeaderReveal(_scrollController, vsync: this);
  final ScrollController _thinkingScrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();
  static String _streamingContent = '';
  static StreamSubscription<String>? _streamSubscription;
  Timer? _slowResponseTimer;

  bool get _shouldShowFastModeSlowTip =>
      _currentProvider == 'doubao' && !_fastModeEnabled;

  void _safeSetState(VoidCallback fn) {
    if (mounted) {
      setState(fn);
    } else {
      fn();
      _publishStreamUpdate();
    }
  }

  static void _publishStreamUpdate() {
    _streamUpdateTick.value = _streamUpdateTick.value + 1;
  }

  void _syncMessagesFromPersistent() {
    if (_persistentMessages.length != _messages.length) {
      _messages = List.from(_persistentMessages);
      return;
    }

    if (_persistentMessages.isEmpty || _messages.isEmpty) {
      return;
    }

    final persistentLast = _persistentMessages.last;
    final localLast = _messages.last;
    final changed = persistentLast.role != localLast.role ||
        persistentLast.content != localLast.content ||
        persistentLast.thinkingContent != localLast.thinkingContent ||
        persistentLast.isInterrupted != localLast.isInterrupted ||
        persistentLast.isError != localLast.isError ||
        persistentLast.imagePath != localLast.imagePath;

    if (changed) {
      _messages = List.from(_persistentMessages);
    }
  }

  void _handleStreamUpdateTick() {
    if (!mounted) return;
    _syncMessagesFromPersistent();
    setState(() {});
    if (_isOutputInProgress()) {
      _scrollToBottom(animated: false);
    }
  }

  bool get _isTimetableMismatch =>
      _analysisTimetableId != null &&
      _analysisTimetableId != StorageService.currentTimetableId;

  /// 课表切换等数据变化：欢迎消息"重新生成"按钮主动出现/消失。
  /// 注意不能用快照做变化检测——重新生成完成后 _analysisTimetableId
  /// 会在流式回调里被静默更新，快照失真后再次切换课表时按钮不再出现
  void _handleStorageDataChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottom();
    });
  }

  void saveScrollPosition() {
    if (_scrollController.hasClients) {
      _persistentScrollOffset = _scrollController.offset;
      debugPrint(
          '[AI Assistant] Saved scroll position: $_persistentScrollOffset');
    }
  }

  void restoreScrollPosition() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients && _persistentScrollOffset > 0) {
        _scrollController.jumpTo(_persistentScrollOffset);
        debugPrint(
            '[AI Assistant] Restored scroll position: $_persistentScrollOffset');
      }
    });
  }

  static const List<Map<String, dynamic>> _fastModels = [
    {
      'name': 'DeepSeek-R1',
      'supportsImage': false,
      'provider': 'doubao',
      'supportsWebSearch': false,
      'isReasoningModel': true
    },
    {
      'name': 'DeepSeek-V3.2',
      'supportsImage': false,
      'provider': 'doubao',
      'supportsWebSearch': true
    },
    {
      'name': 'DeepSeek-V3.1',
      'supportsImage': false,
      'provider': 'doubao',
      'supportsWebSearch': true
    },
  ];

  static const List<Map<String, dynamic>> _doubaoNormalModels = [
    {
      'name': 'DeepSeek-R1',
      'supportsImage': false,
      'provider': 'doubao',
      'supportsWebSearch': false,
      'isReasoningModel': true
    },
    {
      'name': 'DeepSeek-V3.2',
      'supportsImage': false,
      'provider': 'doubao',
      'supportsWebSearch': true
    },
    {
      'name': 'DeepSeek-V3.1',
      'supportsImage': false,
      'provider': 'doubao',
      'supportsWebSearch': true
    },
    {
      'name': 'Doubao-Seed-2.0-pro',
      'supportsImage': true,
      'provider': 'doubao',
      'supportsWebSearch': true
    },
    {
      'name': 'Doubao-Seed-2.0-mini',
      'supportsImage': true,
      'provider': 'doubao',
      'supportsWebSearch': true
    },
    {
      'name': 'GLM-4.7',
      'supportsImage': false,
      'provider': 'doubao',
      'supportsWebSearch': true
    },
  ];

  static const List<Map<String, dynamic>> _hunyuanModels = [
    {
      'name': 'hunyuan-lite',
      'supportsImage': false,
      'provider': 'hunyuan',
      'supportsWebSearch': false
    },
  ];

  static const List<Map<String, dynamic>> _glmModels = [
    {
      'name': 'GLM-4.7-Flash',
      'supportsImage': false,
      'provider': 'glm',
      'supportsWebSearch': false
    },
  ];

  /// Agnes AI 可选模型：name 为界面显示名，modelId 为后台实际使用的模型名
  static const List<Map<String, dynamic>> _agnesModels = [
    {
      'name': 'Agnes 2.0 Flash',
      'modelId': 'agnes-2.0-flash',
      'supportsImage': true,
      'provider': 'agnes',
      'supportsWebSearch': false
    },
    {
      'name': 'Agnes 2.5 Flash',
      'modelId': 'agnes-2.5-flash',
      'supportsImage': true,
      'provider': 'agnes',
      'supportsWebSearch': false
    },
  ];

  /// 后台实际模型名 → 界面显示名
  static String _agnesDisplayNameOf(String modelId) =>
      modelId == 'agnes-2.5-flash' ? 'Agnes 2.5 Flash' : 'Agnes 2.0 Flash';

  /// 界面显示名 → 后台实际模型名
  static String _agnesModelIdOf(String name) =>
      name == 'Agnes 2.5 Flash' ? 'agnes-2.5-flash' : 'agnes-2.0-flash';

  List<Map<String, dynamic>> get _normalModels {
    if (_currentProvider == 'hunyuan') {
      return _hunyuanModels;
    } else if (_currentProvider == 'glm') {
      return _glmModels;
    } else if (_currentProvider == 'agnes') {
      return _agnesModels;
    } else if (_currentProvider == 'builtin') {
      return [
        {
          'name': '节点 $_builtinNode',
          'supportsImage': true,
          'provider': 'builtin',
          'supportsWebSearch': false
        },
      ];
    } else if (_currentProvider == 'custom') {
      return [
        {
          'name': _customModelName,
          'supportsImage': _customModelSupportsVision,
          'provider': 'custom',
          'supportsWebSearch': false,
          'isReasoningModel': _customModelIsReasoning,
        },
      ];
    }
    return _doubaoNormalModels;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _streamUpdateTick.addListener(_handleStreamUpdateTick);
    // 课表切换等数据变化时刷新：欢迎消息"重新生成"按钮需主动出现/消失
    StorageService.dataChangeListenable.addListener(_handleStorageDataChanged);
    _messageController.addListener(_onInputTextChanged);
    _inputScrollController.addListener(_updateInputEdgeFade);
    // 首帧后先实测一次输入区高度（初始估值为 1 行基准，字体缩放/布局差异
    // 由此校正；后续变化由 SizeChangedLayoutNotification 驱动）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncInputAreaHeight();
    });
    _messages = _persistentMessages;
    _selectedModel = _persistentSelectedModel;
    _chatTitle = _persistentChatTitle;
    _currentSavedSessionId = _persistentSavedSessionId;
    _loadFastModeSettingAndAnalyze();

    _keyboardDismissAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    _keyboardDismissAnimController.addListener(() {
      final animation = _keyboardDismissAnimation;
      final bounceAnimation = _keyboardDismissBounceAnimation;
      if ((animation == null && bounceAnimation == null) || !mounted) return;
      if (animation != null) {
        _layoutKeyboardHeight = animation.value;
      }
      _keyboardDismissBounceOffset = bounceAnimation?.value ?? 0;
      _publishKeyboardLayout();
    });

    // 恢复滚动位置
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_isOutputInProgress()) {
        _pauseAutoScrollDuringOutput = false;
        _scrollToBottom(animated: false, force: true);
      } else if (_scrollController.hasClients && _persistentScrollOffset > 0) {
        _scrollController.jumpTo(_persistentScrollOffset);
      }
    });
  }

  void _updateSupportsImageUpload() {
    final models = _fastModeEnabled ? _fastModels : _normalModels;
    for (final m in models) {
      if (m['name'] == _selectedModel) {
        setState(() {
          _supportsImageUpload = m['supportsImage'] as bool? ?? false;
          _isReasoningModel = m['isReasoningModel'] as bool? ?? false;
        });
        return;
      }
    }
    setState(() {
      _supportsImageUpload = false;
      _isReasoningModel = false;
    });
  }

  Future<void> _loadFastModeSettingAndAnalyze() async {
    final prefs = await SharedPreferences.getInstance();
    final fastModeEnabled = prefs.getBool('fast_mode_enabled') ?? false;
    final aiEnabled = prefs.getBool('ai_enabled') ?? false;
    final autoScheduleAnalysis = AIAutoAnalysisFlags.scheduleEnabled;
    // 与 AIService.loadConfig 一致：只认内置/Agnes/自定义，历史遗留值回落内置
    String provider = prefs.getString('ai_provider') ?? 'builtin';
    if (provider != 'builtin' && provider != 'agnes' && provider != 'custom') {
      provider = 'builtin';
    }
    _customModelName =
        (prefs.getString('custom_api_model')?.trim().isNotEmpty ?? false)
            ? prefs.getString('custom_api_model')!.trim()
            : 'gpt-4o-mini';
    debugPrint(
        'Fast mode setting loaded: $fastModeEnabled, AI enabled: $aiEnabled, Provider: $provider');

    String? defaultModel;
    bool fastModeAvailable = true;
    bool customReasoning = _customModelIsReasoning;
    bool customVision = _customModelSupportsVision;

    if (provider == 'hunyuan') {
      defaultModel = 'hunyuan-lite';
      fastModeAvailable = false;
    } else if (provider == 'glm') {
      defaultModel = 'GLM-4.7-Flash';
      fastModeAvailable = false;
    } else if (provider == 'agnes') {
      final agnesModelId = prefs.getString('agnes_model') ?? 'agnes-2.0-flash';
      defaultModel = _agnesDisplayNameOf(agnesModelId);
      fastModeAvailable = false;
    } else if (provider == 'builtin') {
      // 内置模型：徽章显示"节点 X"，默认中度思考、支持视觉能力（仅前端）
      _builtinNode = prefs.getInt('builtin_node') ?? 1;
      defaultModel = '节点 $_builtinNode';
      fastModeAvailable = false;
    } else if (provider == 'custom') {
      defaultModel = _customModelName;
      fastModeAvailable = false;
      customReasoning = await AIService.instance
          .getCachedReasoningCapability(model: _customModelName);
      customVision = await AIService.instance
              .getCustomVisionSupport(model: _customModelName) ??
          false;
    }

    final actualFastModeEnabled = fastModeAvailable ? fastModeEnabled : false;

    final providerChanged =
        _currentProvider.isNotEmpty && provider != _currentProvider;

    String? newSelectedModel = _selectedModel;

    List<Map<String, dynamic>> providerModels;
    if (provider == 'hunyuan') {
      providerModels = _hunyuanModels;
    } else if (provider == 'glm') {
      providerModels = _glmModels;
    } else if (provider == 'agnes') {
      providerModels = _agnesModels;
    } else if (provider == 'builtin') {
      providerModels = [
        {
          'name': '节点 $_builtinNode',
          'supportsImage': true,
          'provider': 'builtin',
          'supportsWebSearch': false
        },
      ];
    } else if (provider == 'custom') {
      providerModels = [
        {
          'name': _customModelName,
          'supportsImage': _customModelSupportsVision,
          'provider': 'custom',
          'supportsWebSearch': false,
          'isReasoningModel': _customModelIsReasoning,
        },
      ];
    } else {
      providerModels = _doubaoNormalModels;
    }

    if (providerChanged) {
      if (defaultModel != null) {
        newSelectedModel = defaultModel;
        debugPrint(
            '[AI Assistant] Init: Provider changed to $provider, new model: $newSelectedModel');
      } else {
        final modelNames =
            providerModels.map((m) => m['name'] as String).toList();
        newSelectedModel = _getRandomModel(modelNames);
        debugPrint(
            '[AI Assistant] Init: Provider changed to $provider, random model: $newSelectedModel');
      }
    } else if (_selectedModel == null) {
      if (actualFastModeEnabled) {
        final fastModelNames =
            _fastModels.map((m) => m['name'] as String).toList();
        newSelectedModel = _getRandomModel(fastModelNames);
        debugPrint(
            '[AI Assistant] Init: No model selected, fast mode enabled, random model: $newSelectedModel');
      } else if (defaultModel != null) {
        newSelectedModel = defaultModel;
        debugPrint(
            '[AI Assistant] Init: No model selected, using default: $newSelectedModel');
      } else {
        final modelNames =
            providerModels.map((m) => m['name'] as String).toList();
        newSelectedModel = _getRandomModel(modelNames);
        debugPrint(
            '[AI Assistant] Init: No model selected, $provider random model: $newSelectedModel');
      }
    }

    final activeModels = actualFastModeEnabled ? _fastModels : providerModels;
    final activeModelNames =
        activeModels.map((m) => m['name'] as String).toList();
    final modelStillAvailable =
        newSelectedModel != null && activeModelNames.contains(newSelectedModel);
    if (!modelStillAvailable && activeModelNames.isNotEmpty) {
      newSelectedModel = _getRandomModel(activeModelNames);
      debugPrint(
          '[AI Assistant] Init: Switched mode/provider, previous model unavailable, random fallback: $newSelectedModel');
    }

    final reasoningEffortStr =
        prefs.getString('custom_api_reasoning_effort') ?? '';
    final webSearchEnabled = prefs.getBool('web_search_enabled') ?? false;

    setState(() {
      _fastModeEnabled = actualFastModeEnabled;
      _aiEnabled = aiEnabled;
      _aiAutoScheduleAnalysis = autoScheduleAnalysis;
      _currentProvider = provider;
      _customModelIsReasoning = customReasoning;
      _customModelSupportsVision = customVision;
      _currentReasoningEffort =
          reasoningEffortStr.isNotEmpty ? reasoningEffortStr : null;
      _webSearchEnabled = webSearchEnabled;
      if (!_shouldShowFastModeSlowTip) {
        _showSlowResponseTip = false;
      }
      if (newSelectedModel != _selectedModel) {
        _selectedModel = newSelectedModel;
        _persistentSelectedModel = newSelectedModel;
      }
      if (_selectedModel == null && defaultModel != null) {
        _selectedModel = defaultModel;
        _persistentSelectedModel = defaultModel;
      }
    });

    _updateSupportsImageUpload();
    _triggerCustomVisionProbeSilently();

    // 总开关关闭、或「自动课表分析」子开关关闭时都不调用 AI：
    // 消息列表保持为空，空态自然渲染默认欢迎卡
    if (!_aiEnabled || !_aiAutoScheduleAnalysis) {
      return;
    }

    if (!_hasAnalyzed && _messages.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _analyzeSchedule();
        }
      });
    }
  }

  String _getRandomModel(List<String> models) {
    final random = Random();
    return models[random.nextInt(models.length)];
  }

  String? get _requestModel {
    if (_currentProvider == 'agnes' && _selectedModel != null) {
      return _agnesModelIdOf(_selectedModel!);
    }
    return _selectedModel;
  }

  String? _displayForStreamedModel(String? model) =>
      (_currentProvider == 'agnes' && model != null)
          ? _agnesDisplayNameOf(model)
          : model;

  /// 将当前键盘布局参数同步到 ValueNotifier，驱动输入区/内边距局部重建，避免 setState 触发主 build。
  void _publishKeyboardLayout() {
    _keyboardLayoutNotifier.value = (
      layoutHeight: _layoutKeyboardHeight,
      bounceOffset: _keyboardDismissBounceOffset,
      rawHeight: _lastKeyboardHeight,
    );
  }

  void _startKeyboardDismissAnimation() {
    if (_layoutKeyboardHeight <= 0.5) {
      if (_layoutKeyboardHeight != 0 || _keyboardDismissBounceOffset != 0) {
        _layoutKeyboardHeight = 0;
        _keyboardDismissBounceOffset = 0;
        _publishKeyboardLayout();
      }
      return;
    }

    _keyboardDismissAnimController.stop();
    _keyboardDismissAnimation = Tween<double>(
      begin: _layoutKeyboardHeight,
      end: 0,
    ).animate(
      CurvedAnimation(
        parent: _keyboardDismissAnimController,
        curve: Curves.easeOutCubic,
      ),
    );
    _keyboardDismissBounceAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: ConstantTween(0.0), weight: 75),
      TweenSequenceItem(
        tween: Tween(begin: 0.0, end: 3.5)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 12,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 3.5, end: 0.0)
            .chain(CurveTween(curve: Curves.easeOutBack)),
        weight: 13,
      ),
    ]).animate(_keyboardDismissAnimController);
    _keyboardDismissAnimController.forward(from: 0);
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    // 会话菜单打开期间屏蔽键盘变化：菜单内编辑框的键盘不应驱动
    // 对话页输入区/消息列表跟随移动（画面乱跳）
    if (_sessionsMenuOpen) return;
    final view = View.of(context);
    final mediaQuery = MediaQuery.maybeOf(context);
    final keyboardHeight = mediaQuery?.viewInsets.bottom ??
        (view.viewInsets.bottom / view.devicePixelRatio);
    final isKeyboardVisible = keyboardHeight > 0;
    final previousKeyboardHeight = _lastKeyboardHeight;
    final wasVisible = previousKeyboardHeight > 0;
    final isKeyboardRising = keyboardHeight > previousKeyboardHeight + 0.5;
    final isKeyboardFalling = keyboardHeight < previousKeyboardHeight - 0.5;
    final shouldStickToBottom = _isNearBottom();

    _lastKeyboardHeight = keyboardHeight;

    if (isKeyboardRising || (isKeyboardVisible && !isKeyboardFalling)) {
      if (_keyboardDismissAnimController.isAnimating) {
        _keyboardDismissAnimController.stop();
      }
      final shouldUpdateHeight =
          (_layoutKeyboardHeight - keyboardHeight).abs() > 0.5;
      final shouldResetBounce = _keyboardDismissBounceOffset != 0;
      if (shouldUpdateHeight || shouldResetBounce) {
        if (shouldUpdateHeight) {
          _layoutKeyboardHeight = keyboardHeight;
        }
        if (shouldResetBounce) {
          _keyboardDismissBounceOffset = 0;
        }
        _publishKeyboardLayout();
      }
    } else if (isKeyboardFalling &&
        !_keyboardDismissAnimController.isAnimating) {
      _startKeyboardDismissAnimation();
    } else if (!isKeyboardVisible &&
        !_keyboardDismissAnimController.isAnimating &&
        (_layoutKeyboardHeight != 0 || _keyboardDismissBounceOffset != 0)) {
      _layoutKeyboardHeight = 0;
      _keyboardDismissBounceOffset = 0;
      _publishKeyboardLayout();
    }

    if (isKeyboardVisible != wasVisible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (isKeyboardVisible) {
          debugPrint('Keyboard shown - calling onKeyboardShown');
          widget.onKeyboardShown?.call();
          if (shouldStickToBottom) {
            _scrollToBottom(animated: false);
          }
        } else {
          debugPrint('Keyboard hidden - calling onKeyboardHidden');
          widget.onKeyboardHidden?.call();
        }
      });
    } else if (isKeyboardVisible && isKeyboardRising && shouldStickToBottom) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _scrollToBottom(animated: false);
      });
    }
  }

  Future<void> _loadFastModeSetting() async {
    final prefs = await SharedPreferences.getInstance();
    // 与 AIService.loadConfig 一致：只认内置/Agnes/自定义，历史遗留值回落内置
    String provider = prefs.getString('ai_provider') ?? 'builtin';
    if (provider != 'builtin' && provider != 'agnes' && provider != 'custom') {
      provider = 'builtin';
    }
    _customModelName =
        (prefs.getString('custom_api_model')?.trim().isNotEmpty ?? false)
            ? prefs.getString('custom_api_model')!.trim()
            : 'gpt-4o-mini';

    bool fastModeAvailable = true;
    String? defaultModel;
    bool customReasoning = _customModelIsReasoning;
    bool customVision = _customModelSupportsVision;

    if (provider == 'hunyuan') {
      defaultModel = 'hunyuan-lite';
      fastModeAvailable = false;
    } else if (provider == 'glm') {
      defaultModel = 'GLM-4.7-Flash';
      fastModeAvailable = false;
    } else if (provider == 'agnes') {
      final agnesModelId = prefs.getString('agnes_model') ?? 'agnes-2.0-flash';
      defaultModel = _agnesDisplayNameOf(agnesModelId);
      fastModeAvailable = false;
    } else if (provider == 'builtin') {
      // 内置模型：徽章显示"节点 X"，默认中度思考、支持视觉能力（仅前端）
      _builtinNode = prefs.getInt('builtin_node') ?? 1;
      defaultModel = '节点 $_builtinNode';
      fastModeAvailable = false;
    } else if (provider == 'custom') {
      defaultModel = _customModelName;
      fastModeAvailable = false;
      customReasoning = await AIService.instance
          .getCachedReasoningCapability(model: _customModelName);
      customVision = await AIService.instance
              .getCustomVisionSupport(model: _customModelName) ??
          false;
    }

    final newFastModeEnabled = fastModeAvailable
        ? (prefs.getBool('fast_mode_enabled') ?? false)
        : false;
    final newAiEnabled = prefs.getBool('ai_enabled') ?? false;
    final newAutoScheduleAnalysis = AIAutoAnalysisFlags.scheduleEnabled;
    // 子开关本次是否被打开：对话页在 PageView 中保活，切回时靠这里补一次
    // 「开→空会话时补做自动分析」；关掉则什么都不撤，已生成的分析保留
    final autoScheduleAnalysisTurnedOn =
        newAutoScheduleAnalysis && !_aiAutoScheduleAnalysis;

    final providerChanged =
        _currentProvider.isNotEmpty && provider != _currentProvider;

    String? newSelectedModel = _selectedModel;

    List<Map<String, dynamic>> providerModels;
    if (provider == 'hunyuan') {
      providerModels = _hunyuanModels;
    } else if (provider == 'glm') {
      providerModels = _glmModels;
    } else if (provider == 'agnes') {
      providerModels = _agnesModels;
    } else if (provider == 'builtin') {
      providerModels = [
        {
          'name': '节点 $_builtinNode',
          'supportsImage': true,
          'provider': 'builtin',
          'supportsWebSearch': false
        },
      ];
    } else if (provider == 'custom') {
      providerModels = [
        {
          'name': _customModelName,
          'supportsImage': _customModelSupportsVision,
          'provider': 'custom',
          'supportsWebSearch': false,
          'isReasoningModel': _customModelIsReasoning,
        },
      ];
    } else {
      providerModels = _doubaoNormalModels;
    }

    if (providerChanged) {
      if (defaultModel != null) {
        newSelectedModel = defaultModel;
        debugPrint(
            '[AI Assistant] Provider changed to $provider, new model: $newSelectedModel');
      } else {
        final modelNames =
            providerModels.map((m) => m['name'] as String).toList();
        newSelectedModel = _getRandomModel(modelNames);
        debugPrint(
            '[AI Assistant] Provider changed to $provider, random model: $newSelectedModel');
      }
    } else if (_selectedModel == null) {
      if (newFastModeEnabled) {
        final fastModelNames =
            _fastModels.map((m) => m['name'] as String).toList();
        newSelectedModel = _getRandomModel(fastModelNames);
        debugPrint(
            '[AI Assistant] No model selected, fast mode enabled, random model: $newSelectedModel');
      } else if (defaultModel != null) {
        newSelectedModel = defaultModel;
        debugPrint(
            '[AI Assistant] No model selected, using default: $newSelectedModel');
      } else {
        final modelNames =
            providerModels.map((m) => m['name'] as String).toList();
        newSelectedModel = _getRandomModel(modelNames);
        debugPrint(
            '[AI Assistant] No model selected, $provider random model: $newSelectedModel');
      }
    }

    final activeModels = newFastModeEnabled ? _fastModels : providerModels;
    final activeModelNames =
        activeModels.map((m) => m['name'] as String).toList();
    final modelStillAvailable =
        newSelectedModel != null && activeModelNames.contains(newSelectedModel);
    if (!modelStillAvailable && activeModelNames.isNotEmpty) {
      newSelectedModel = _getRandomModel(activeModelNames);
      debugPrint(
          '[AI Assistant] Runtime refresh: previous model unavailable in current mode, random fallback: $newSelectedModel');
    }

    setState(() {
      _fastModeEnabled = newFastModeEnabled;
      _aiEnabled = newAiEnabled;
      _aiAutoScheduleAnalysis = newAutoScheduleAnalysis;
      _currentProvider = provider;
      _customModelIsReasoning = customReasoning;
      _customModelSupportsVision = customVision;
      if (!_shouldShowFastModeSlowTip) {
        _showSlowResponseTip = false;
      }
      if (newSelectedModel != _selectedModel) {
        _selectedModel = newSelectedModel;
        _persistentSelectedModel = newSelectedModel;
      }
      if (_selectedModel == null && defaultModel != null) {
        _selectedModel = defaultModel;
        _persistentSelectedModel = defaultModel;
      }
    });

    _updateSupportsImageUpload();
    _triggerCustomVisionProbeSilently();

    // 子开关本次被关掉：已生成的课程分析原样保留，只是此后不再自动发起；
    // 本次被打开且还没分析过、会话为空时补做一次
    if (autoScheduleAnalysisTurnedOn &&
        _aiEnabled &&
        !_hasAnalyzed &&
        _messages.isEmpty) {
      _analyzeSchedule();
    }
  }

  void _triggerCustomVisionProbeSilently() {
    if (_currentProvider != 'custom') return;
    final model = (_selectedModel ?? _customModelName).trim();
    if (model.isEmpty) return;

    unawaited(() async {
      final manualOverride =
          await AIService.instance.isCustomVisionManualOverrideEnabled();
      if (manualOverride) return;

      final probed =
          await AIService.instance.probeCustomVisionSupport(model: model);
      if (!mounted || probed == null) return;
      if (probed != _customModelSupportsVision) {
        setState(() {
          _customModelSupportsVision = probed;
        });
        _updateSupportsImageUpload();
      }
    }());
  }

  static void markNeedsRefresh() {
    _needsRefresh = true;
  }

  Future<void> refreshRuntimeConfig() async {
    // 路由感知：每次切回对话页都重新加载 AI 配置（provider/模型/思考强度/图片支持），
    // 保证设置页或其他入口修改配置后立即生效
    _needsRefresh = false;
    await _loadFastModeSetting();
  }

  void _startSlowResponseTimer() {
    _cancelSlowResponseTimer();
    _slowResponseTimer = Timer(const Duration(seconds: 10), () {
      if (_shouldShowFastModeSlowTip &&
          (_isLoading || _isAnalyzing) &&
          !_isFirstChunkReceived) {
        setState(() {
          _showSlowResponseTip = true;
        });
        _scrollToBottom();
      }
    });
  }

  void _cancelSlowResponseTimer() {
    _slowResponseTimer?.cancel();
    _slowResponseTimer = null;
  }

  void _startNoResponseTimer() {
    _cancelNoResponseTimer();
    debugPrint(
        '[AI Assistant] Starting no-response timer (${_noResponseTimeout.inSeconds}s), retry count: $_retryCount/$_maxRetryCount');
    _noResponseTimer = Timer(_noResponseTimeout, () {
      if ((_isLoading || _isAnalyzing) && !_stopRequested) {
        debugPrint(
            '[AI Assistant] No response timeout triggered, isFirstChunkReceived: $_isFirstChunkReceived');
        if (_retryCount < _maxRetryCount) {
          unawaited(_retryWithAutoRecovery());
        } else {
          _handleMaxRetryExceeded();
        }
      }
    });
  }

  void _cancelNoResponseTimer() {
    _noResponseTimer?.cancel();
    _noResponseTimer = null;
  }

  bool _hasStreamingOutput() {
    return _streamingContent.isNotEmpty || _thinkingContent.isNotEmpty;
  }

  bool _canAutoRetryNow() {
    return !_stopRequested && _retryCount < _maxRetryCount;
  }

  bool _shouldRetryForEmptyCompletion({bool requireContent = false}) {
    final hasOutput =
        requireContent ? _streamingContent.isNotEmpty : _hasStreamingOutput();
    return !hasOutput && _canAutoRetryNow();
  }

  bool _shouldRetryForAnalyzeCompletion() {
    final requireContentForCurrentProvider = _currentProvider != 'doubao';
    return _shouldRetryForEmptyCompletion(
        requireContent: requireContentForCurrentProvider);
  }

  bool _hasCompletionOutputForCurrentProvider() {
    if (_currentProvider == 'doubao') {
      return _hasStreamingOutput();
    }
    return _streamingContent.isNotEmpty;
  }

  /// 超时（30s 未等到首字节）或空响应之后的自动重试。
  ///
  /// 这里最大的坑：**取消订阅 ≠ 中断请求**。卡住的请求正在等服务端首字节，
  /// 而 `async*` 生成器要等到下一次 `yield` 才会感知取消并退出——它可能永远
  /// 等不到下一次 yield，于是底层 HttpClient 与 socket 一直挂着（连 `finally`
  /// 里的 close 都执行不到）。若不清场就发新请求，新旧请求会挤在同一个 Edge
  /// Function / 上游通道里互相排队，第二、第三次同样拿不到首字节，表现就是
  /// 「自动重试总是不成功」；而**退出重进一遍就好**恰恰是因为那时僵尸请求
  /// 早已自行结束，通道空出来了。
  ///
  /// 因此重试前依次做：
  /// 1) 取消订阅（不 await，理由见下）并清空调  timer；
  /// 2) 强制中断本页在飞的请求（force 关闭 HttpClient，直接断开 socket）；
  /// 3) 短退避，等旧连接释放；
  /// 4) 重新加载 AI 配置 + 复位上下文注入标志，让重试请求与首次完全一致。
  Future<void> _retryWithAutoRecovery() async {
    if (_stopRequested) {
      debugPrint('[AI Assistant] Retry skipped because stop was requested');
      return;
    }
    debugPrint(
        '[AI Assistant] Auto-retrying request, attempt ${_retryCount + 1}/$_maxRetryCount');
    _retryCount++;

    final pendingSubscription = _streamSubscription;
    _streamSubscription = null;
    // 刻意不 await：async* 订阅的 cancel() 要等生成器真正退出才完成，
    // 卡住的请求会让它永远不返回，重试反而发不出去
    unawaited(pendingSubscription?.cancel());
    _cancelSlowResponseTimer();
    _cancelNoResponseTimer();
    // 真正掐断尚未结束的上一次请求，把通道让给本次重试
    AIService.instance.abortActiveStreams(_aiRequestOwner);

    setState(() {
      _isFirstChunkReceived = false;
      _streamingContent = '';
      _statusMessage = '';
      _isSearching = false;
      _isThinking = false;
      _isThinkingCollapsed = false;
      _thinkingContent = '';
      _showSlowResponseTip = false;
    });
    _pauseAutoScrollDuringOutput = false;

    await Future.delayed(_retryBackoffStep * _retryCount);
    if (!mounted || _stopRequested) return;

    // 与首次发送保持一致：重新拉取最新 AI 配置（provider / 密钥 / 节点）
    try {
      await AIService.instance.loadConfig();
      await _loadFastModeSetting();
    } catch (e) {
      debugPrint('[AI Assistant] Retry reload config failed: $e');
    }
    if (!mounted || _stopRequested) return;

    // 上一次的上下文注入（system prompt 里的课表/任务数据、推理模型的背景段）
    // 连同那次卡住的请求一起作废了，复位后重试请求才会重新带上完整上下文
    _hasSentContext = false;

    if (_lastUserMessage != null) {
      _executeSendMessage(
        messageText: _lastUserMessage!,
        imageBase64: _lastImageBase64,
        history: _lastHistory,
        isRetry: true,
      );
    } else if (_isAnalyzing) {
      _executeAnalyzeSchedule(isRetry: true);
    }
  }

  void _handleMaxRetryExceeded() {
    debugPrint('[AI Assistant] Max retry count exceeded, showing error');
    _cancelNoResponseTimer();
    _cancelSlowResponseTimer();

    setState(() {
      _isLoading = false;
      _isAnalyzing = false;
      _isFirstChunkReceived = false;
      _streamingContent = '';
      _retryCount = 0;

      _messages.add(_ChatMessage(
        role: 'assistant',
        content:
            '⚠️ 请求超时，已自动重试 $_maxRetryCount 次仍无响应。\n\n可能的原因：\n• 网络连接不稳定\n• AI 服务暂时不可用\n• 当前模型响应较慢\n\n请检查网络连接后重试，或尝试切换其他模型。',
        isError: true,
      ));
    });
    _persistentMessages = List.from(_messages);
    _publishStreamUpdate();
    _scrollToBottom();
  }

  /// 重新生成最后一条回复：删除当前回复，把最近一次用户消息当成
  /// 一条全新消息发送——不携带之前的问答历史（旧实现携带完整历史，
  /// 请求与原次完全相同，模型/服务商命中缓存或确定性输出会原样复读
  /// 上一轮正文）。图片消息从本地文件重新压缩编码。
  /// 由于剥离历史后各次请求彼此相同，追加随机表述变体提示打散复读。
  static const List<String> _regenerateVariants = [
    '请换一个角度或思路重新组织回答',
    '请调整表述方式和结构重新回答',
    '请用更精炼简洁的方式回答',
    '请用更详细、充分展开的方式回答',
    '请优先用分点或列表组织回答',
    '请优先用连贯的段落叙述回答',
  ];
  final Random _random = Random();

  Future<void> _regenerateLastMessage() async {
    if (_isLoading) return;
    if (_messages.isEmpty || _messages.last.role != 'assistant') return;

    // 向前回溯最近一条用户消息
    int userIdx = -1;
    for (var i = _messages.length - 2; i >= 0; i--) {
      if (_messages[i].role == 'user') {
        userIdx = i;
        break;
      }
    }
    if (userIdx < 0) return;
    final userMsg = _messages[userIdx];

    // 图片消息：从本地文件重新读取压缩编码（请求用的 base64 不随消息保存）
    String? imageBase64;
    if (userMsg.imagePath != null) {
      try {
        var bytes = await File(userMsg.imagePath!).readAsBytes();
        bytes = _compressImageBytes(bytes);
        imageBase64 = base64Encode(bytes);
      } catch (e) {
        debugPrint('[AI Assistant] Regenerate: re-encode image failed: $e');
      }
    }

    final text = userMsg.content;
    if (text.isEmpty && imageBase64 == null) return;

    // 打散复读：剥离历史后每次重新生成的请求完全相同，中转/模型侧命中
    // 缓存或确定性输出会原样复读同一段正文。给发出的消息追加一条随机
    // 表述变体提示（仅用于本次请求，不进气泡、不进历史），保证每次请求
    // 互不相同，并引导模型换角度/换组织方式回答
    final variant =
        _regenerateVariants[_random.nextInt(_regenerateVariants.length)];
    final sentText = text.isEmpty ? text : '$text\n\n（$variant）';

    setState(() {
      _stopRequested = false;
      _isLoading = true;
      _isFirstChunkReceived = false;
      _streamingContent = '';
      _statusMessage = '';
      _isSearching = false;
      _isThinking = false;
      _isThinkingCollapsed = false;
      _thinkingContent = '';
      _showSlowResponseTip = false;
      // 移除旧回复（正常/错误/中断均适用）
      _messages.removeLast();
    });
    _persistentMessages = List.from(_messages);
    _publishStreamUpdate();
    _retryCount = 0;
    _lastUserMessage = sentText;
    _lastImageBase64 = imageBase64;
    // 全新消息：不带任何历史上下文
    _lastHistory = const [];
    // 重置上下文注入标志：让本次请求与首条消息一致（系统提示携带
    // 课表/任务数据，推理模型重新注入背景），避免模型脱离数据盲答
    _hasSentContext = false;
    _scrollToBottom(force: true);

    _executeSendMessage(
      messageText: sentText,
      imageBase64: imageBase64,
      history: const [],
    );
  }

  void _resetRetryState() {
    _cancelNoResponseTimer();
    _retryCount = 0;
    _lastUserMessage = null;
    _lastImageBase64 = null;
    _lastHistory = null;
    debugPrint('[AI Assistant] Reset retry state');
  }

  void _hideSlowResponseTip() {
    if (_showSlowResponseTip) {
      setState(() {
        _showSlowResponseTip = false;
      });
    }
  }

  Future<void> _analyzeSchedule() async {
    if (_isAnalyzing || _hasAnalyzed) return;

    if (!_aiEnabled) {
      setState(() {
        _hasAnalyzed = true;
      });
      return;
    }

    setState(() {
      _stopRequested = false;
      _isAnalyzing = true;
      _showSlowResponseTip = false;
      _thinkingContent = '';
      _isThinking = false;
      _isThinkingCollapsed = false;
    });
    _pauseAutoScrollDuringOutput = false;

    _retryCount = 0;
    debugPrint('[AI Assistant] Starting schedule analysis');

    _executeAnalyzeSchedule();
  }

  /// 重新生成课程分析（欢迎消息）：切换课表后由欢迎消息右上角的
  /// 重启按钮触发——移除旧欢迎消息，按当前课表重新分析
  void _regenerateScheduleAnalysis() {
    if (_isAnalyzing) return;
    setState(() {
      _messages.removeWhere((m) => m.isWelcome);
      _persistentMessages = List.from(_messages);
      _hasAnalyzed = false;
      _analysisTimetableId = null;
    });
    _analyzeSchedule();
  }

  Future<void> _executeAnalyzeSchedule({bool isRetry = false}) async {
    if (_stopRequested) {
      debugPrint(
          '[AI Assistant] Analyze execution skipped because stop was requested');
      return;
    }
    if (isRetry) {
      debugPrint('[AI Assistant] Retrying schedule analysis');
      setState(() {
        _statusMessage = '自动重试中... ($_retryCount/$_maxRetryCount)';
        _isSearching = true;
      });
      _scrollToBottom();
    }

    _startSlowResponseTimer();
    _startNoResponseTimer();

    final courses = StorageService.getCourses();
    final tasks = StorageService.getTasks();
    final todayCourses = _getTodayCourses(courses);
    final tomorrowCourses = _getTomorrowCourses(courses);
    final upcomingTasks = _getUpcomingTasks(tasks);
    final currentStatus = _getCurrentCourseStatus(todayCourses);

    // 假期状态判断：学期开始前或学期结束后均为假期
    final currentWeekNum = StorageService.getCurrentWeek();
    final semesterWeeks = StorageService.getSemesterWeeks();
    final isHoliday = StorageService.isHoliday();

    // 课程按名称聚合后输出（结课周 = 全部节次周次并集的最大值）：
    // 直接给逐节行会被模型当成孤立课程，某节周次更短或教师不同
    // 会被误读为整门课结课/换课
    final courseSummaries = aggregateCoursesByName(courses, semesterWeeks);
    final courseSummaryLines = courseSummaries.isEmpty
        ? '暂无课程'
        : courseSummaries.map((s) => s.summaryLine(semesterWeeks)).join('\n');

    final tasksInfo = upcomingTasks
        .map((t) => {
              'name': t.name,
              'type': t.type,
              'dueDate': DateFormat('MM-dd HH:mm').format(t.dueDate),
              'priority': t.priority,
            })
        .toList();

    String prompt;
    final now = DateTime.now();
    final timeSlots = StorageService.getTimeSlots();
    final currentPeriodFromStatus = currentStatus['currentPeriod'] as int?;

    if (isHoliday) {
      // 假期专属提示词：区分学期开始前和学期结束后
      final isBeforeStart = StorageService.isBeforeSemesterStart();

      final holidayStatus = isBeforeStart
          ? '当前处于开学前假期（新学期尚未开始）'
          : '当前处于假期状态（已超出学期$semesterWeeks周）';

      final studyAdvice = isBeforeStart
          ? '''3. 给出开学前学习建议（如预习新学期课程、调整作息迎接开学、准备开学物品等），不要建议复盘上学期课程'''
          : '''3. 给出假期学习建议（如复盘上学期、预习下学期、阅读、作息调整等）''';

      prompt =
          '''📚 当前所有课程（共${courseSummaries.length}门，学期共$semesterWeeks周，当前为第$currentWeekNum周）：
$courseSummaryLines

🎉 $holidayStatus

📝 近期待办任务（7天内，共${upcomingTasks.length}个）：
${tasksInfo.isEmpty ? '暂无待办任务 ✨' : tasksInfo.map((t) => '• [${t['priority']}] ${t['name']} (${t['type']}) 截止: ${t['dueDate']}').join('\n')}

$kCourseInterpretationRules

当前处于假期，请用简洁友好的方式，适当使用emoji：
1. 告知用户当前处于假期状态，鼓励适当休息放松
2. 提醒近期重要的任务/DDL截止时间（如果有）
$studyAdvice

直接开始回答，不要有开场白。''';
    } else if (currentStatus['status'] == 'finished') {
      final tomorrowInfo = tomorrowCourses.isEmpty
          ? '明天没有课程 🎉'
          : tomorrowCourses.map((c) {
              final timeStr = _getCourseTimeStr(c, timeSlots);
              return '• $timeStr ${c.name} (${c.teacher ?? '未知'}) @ ${c.location ?? '未知'}';
            }).join('\n');

      prompt =
          '''📚 当前所有课程（共${courseSummaries.length}门，当前第${StorageService.getCurrentWeek()}周）：
$courseSummaryLines

📅 明天的课程：
$tomorrowInfo

📝 近期待办任务（7天内，共${upcomingTasks.length}个）：
${tasksInfo.isEmpty ? '暂无待办任务 ✨' : tasksInfo.map((t) => '• [${t['priority']}] ${t['name']} (${t['type']}) 截止: ${t['dueDate']}').join('\n')}

$kCourseInterpretationRules

今天的课程已结束，请用简洁友好的方式，适当使用emoji：
1. 总结明天的课程安排（如果有课的话）
2. 提醒近期重要的任务截止时间
3. 给出学习建议

直接开始回答，不要有开场白。''';
    } else {
      final remainingCourses = todayCourses.where((c) {
        if (currentPeriodFromStatus == null) return true;
        return c.time > currentPeriodFromStatus;
      }).toList();

      String todayInfo;
      if (currentStatus['status'] == 'no_class_today') {
        final tomorrowInfo = tomorrowCourses.isEmpty
            ? '明天也没有课程 🎉'
            : tomorrowCourses.map((c) {
                final timeStr = _getCourseTimeStr(c, timeSlots);
                return '• $timeStr ${c.name} (${c.teacher ?? '未知'}) @ ${c.location ?? '未知'}';
              }).join('\n');

        prompt =
            '''📚 当前所有课程（共${courseSummaries.length}门，当前第${StorageService.getCurrentWeek()}周）：
$courseSummaryLines

📅 今天没有课程 🎉

📅 明天的课程：
$tomorrowInfo

📝 近期待办任务（7天内，共${upcomingTasks.length}个）：
${tasksInfo.isEmpty ? '暂无待办任务 ✨' : tasksInfo.map((t) => '• [${t['priority']}] ${t['name']} (${t['type']}) 截止: ${t['dueDate']}').join('\n')}

$kCourseInterpretationRules

今天没有课程，请用简洁友好的方式，适当使用emoji：
1. 告知用户今天没有课程
2. 简要介绍明天的课程安排（如果有课的话）
3. 提醒近期重要的任务截止时间
4. 给出学习建议

直接开始回答，不要有开场白。''';

        try {
          debugPrint(
              '[AI Assistant] Executing analyze stream request, model: $_selectedModel');

          final stream = AIService.instance.chatWithModelStream(
            userMessage: prompt,
            model: _requestModel,
            systemPrompt: '你是一个学习助手，帮助大学生管理课程和任务，解决学习问题。使用markdown格式。',
            fastMode: _fastModeEnabled,
            provider: _currentProvider,
            reasoningEffort: _currentProvider == 'agnes'
                ? null
                : (_currentProvider == 'builtin'
                    ? 'medium'
                    : _currentReasoningEffort),
            owner: _aiRequestOwner,
          );

          _streamSubscription = stream.listen(
            (chunk) {
              if (!_isFirstChunkReceived) {
                _cancelSlowResponseTimer();
                _cancelNoResponseTimer();
                _hideSlowResponseTip();
                debugPrint(
                    '[AI Assistant] First chunk received in analyze, canceling timeout timers');
                _safeSetState(() {
                  _isFirstChunkReceived = true;
                  _retryCount = 0;
                });
              }
              _safeSetState(() {
                if (chunk.startsWith('【状态】')) {
                  _statusMessage = chunk.substring(4);
                  _isSearching = true;
                  debugPrint('[AI Assistant] Status: $_statusMessage');
                } else if (chunk.startsWith('【思考】')) {
                  _cancelNoResponseTimer();
                  _cancelSlowResponseTimer();
                  _hideSlowResponseTip();
                  if (_currentProvider == 'custom') {
                    _isReasoningModel = true;
                    _customModelIsReasoning = true;
                  }
                  _thinkingContent += chunk.substring(4);
                  _isThinking = true;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _scrollThinkingToBottom();
                  });
                } else {
                  _streamingContent += chunk;
                  _statusMessage = '';
                  _isSearching = false;
                  if (_isThinking && !_isThinkingCollapsed) {
                    _isThinkingCollapsed = true;
                  }
                }
              });
              _scrollToBottom();
            },
            onError: (error) {
              debugPrint('[AI Assistant] Analyze stream error: $error');
              _cancelSlowResponseTimer();
              _cancelNoResponseTimer();
              _hideSlowResponseTip();
              _safeSetState(() {
                _isAnalyzing = false;
                _isFirstChunkReceived = false;
                _streamingContent = '';
                _hasAnalyzed = true;
              });
              _resetRetryState();
            },
            onDone: () {
              debugPrint(
                  '[AI Assistant] Analyze stream completed (no_class_today)');
              _cancelSlowResponseTimer();
              _cancelNoResponseTimer();
              _hideSlowResponseTip();

              if (!_hasCompletionOutputForCurrentProvider()) {
                debugPrint(
                    '[AI Assistant] Analyze stream completed with empty content, retry count: $_retryCount/$_maxRetryCount');
                if (_shouldRetryForAnalyzeCompletion()) {
                  unawaited(_retryWithAutoRecovery());
                  return;
                } else {
                  _safeSetState(() {
                    _isAnalyzing = false;
                    _isFirstChunkReceived = false;
                    _isThinking = false;
                    _retryCount = 0;
                    _hasAnalyzed = true;
                  });
                  _resetRetryState();
                  _scrollToBottom();
                  return;
                }
              }

              _safeSetState(() {
                _isAnalyzing = false;
                _isFirstChunkReceived = false;
                _isThinking = false;
                _selectedModel ??= _displayForStreamedModel(
                    AIService.instance.lastStreamedModel);
                _persistentSelectedModel = _selectedModel;
                final thinkingToSave =
                    _thinkingContent.isNotEmpty ? _thinkingContent : null;
                // 欢迎消息固定在顶部：已存在对话时（切换课表后点欢迎消息
                // 的重新生成），新欢迎消息插回列表顶部而非追加到末尾
                final welcomeMsg = _ChatMessage(
                  role: 'assistant',
                  content: _streamingContent,
                  isWelcome: true,
                  thinkingContent: thinkingToSave,
                );
                if (_messages.isEmpty) {
                  _messages.add(welcomeMsg);
                } else {
                  _messages.insert(0, welcomeMsg);
                }
                _streamingContent = '';
                _thinkingContent = '';
                _hasAnalyzed = true;
                // 记录本次课程分析基于的课表：切换课表后与之不同时展示"重新生成"
                _analysisTimetableId = StorageService.currentTimetableId;
              });
              _persistentMessages = List.from(_messages);
              _publishStreamUpdate();
              _resetRetryState();
              _updateSupportsImageUpload();
              // 顶部插入的欢迎消息完成后回到顶部查看；仅欢迎消息时维持回底
              if (_messages.length > 1) {
                _scrollToTop();
              } else {
                _scrollToBottom();
              }
            },
          );
        } catch (e) {
          debugPrint('[AI Assistant] Error starting analyze stream: $e');
          _safeSetState(() {
            _isAnalyzing = false;
            _hasAnalyzed = true;
          });
          _resetRetryState();
        }
        return;
      }

      if (currentStatus['status'] == 'in_class') {
        final course = currentStatus['course'] as Course;
        final remaining = currentStatus['remainingMinutes'] as int;
        todayInfo = '''当前状态：正在上 ${course.name}，还有 $remaining 分钟下课 📚

今天剩余课程：
${remainingCourses.isEmpty ? '今天没有更多课程了 🎉' : remainingCourses.map((c) {
                final timeStr = _getCourseTimeStr(c, timeSlots);
                return '• $timeStr ${c.name} (${c.teacher ?? '未知'}) @ ${c.location ?? '未知'}';
              }).join('\n')}''';
      } else if (currentStatus['status'] == 'break') {
        final nextCourse = currentStatus['nextCourse'] as Course;
        final waiting = currentStatus['waitingMinutes'] as int;
        todayInfo = '''当前状态：课间休息，$waiting 分钟后上 ${nextCourse.name} ☕

今天剩余课程：
${remainingCourses.isEmpty ? '今天没有更多课程了 🎉' : remainingCourses.map((c) {
                final timeStr = _getCourseTimeStr(c, timeSlots);
                return '• $timeStr ${c.name} (${c.teacher ?? '未知'}) @ ${c.location ?? '未知'}';
              }).join('\n')}''';
      } else if (currentStatus['status'] == 'before_class') {
        final waiting = currentStatus['waitingMinutes'] as int;
        final firstCourse = todayCourses.first;
        todayInfo = '''当前状态：今天有课，距离第一节课还有 $waiting 分钟 🌅
第一节课：${firstCourse.name} (${firstCourse.teacher ?? '未知'}) @ ${firstCourse.location ?? '未知'}

今天的课程：
${todayCourses.map((c) {
          final timeStr = _getCourseTimeStr(c, timeSlots);
          return '• $timeStr ${c.name} (${c.teacher ?? '未知'}) @ ${c.location ?? '未知'}';
        }).join('\n')}''';
      } else {
        todayInfo = '''当前状态：${currentStatus['message']}

今天的课程：
${todayCourses.isEmpty ? '今天没有课程 🎉' : todayCourses.map((c) {
                final timeStr = _getCourseTimeStr(c, timeSlots);
                return '• $timeStr ${c.name} (${c.teacher ?? '未知'}) @ ${c.location ?? '未知'}';
              }).join('\n')}''';
      }

      prompt =
          '''📚 当前所有课程（共${courseSummaries.length}门，当前第${StorageService.getCurrentWeek()}周）：
$courseSummaryLines

📅 今天的课程安排：
$todayInfo

📝 近期待办任务（7天内，共${upcomingTasks.length}个）：
${tasksInfo.isEmpty ? '暂无待办任务 ✨' : tasksInfo.map((t) => '• [${t['priority']}] ${t['name']} (${t['type']}) 截止: ${t['dueDate']}').join('\n')}

$kCourseInterpretationRules

请用简洁友好的方式，适当使用emoji：
1. 根据当前时间提醒用户课程状态（如正在上课还有几分钟下课，或课间休息几分钟后上课）
2. 介绍今天剩余的课程安排
3. 提醒近期重要的任务截止时间
4. 给出学习建议

直接开始回答，不要有开场白。''';
    }

    try {
      debugPrint(
          '[AI Assistant] Executing analyze stream request, model: $_selectedModel');

      final stream = AIService.instance.chatWithModelStream(
        userMessage: prompt,
        model: _requestModel,
        systemPrompt: '你是一个学习助手，帮助大学生管理课程和任务，解决学习问题。使用markdown格式。',
        fastMode: _fastModeEnabled,
        provider: _currentProvider,
        reasoningEffort: _currentProvider == 'agnes'
            ? null
            : (_currentProvider == 'builtin'
                ? 'medium'
                : _currentReasoningEffort),
      );

      _streamSubscription = stream.listen(
        (chunk) {
          if (!_isFirstChunkReceived) {
            _cancelSlowResponseTimer();
            _cancelNoResponseTimer();
            _hideSlowResponseTip();
            debugPrint(
                '[AI Assistant] First chunk received in analyze, canceling timeout timers');
            _safeSetState(() {
              _isFirstChunkReceived = true;
              _retryCount = 0;
            });
          }
          _safeSetState(() {
            if (chunk.startsWith('【状态】')) {
              _statusMessage = chunk.substring(4);
              _isSearching = true;
              debugPrint('[AI Assistant] Status: $_statusMessage');
            } else if (chunk.startsWith('【思考】')) {
              _cancelNoResponseTimer();
              _cancelSlowResponseTimer();
              _hideSlowResponseTip();
              if (_currentProvider == 'custom') {
                _isReasoningModel = true;
                _customModelIsReasoning = true;
              }
              _thinkingContent += chunk.substring(4);
              _isThinking = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _scrollThinkingToBottom();
              });
            } else {
              _streamingContent += chunk;
              _statusMessage = '';
              _isSearching = false;
              if (_isThinking && !_isThinkingCollapsed) {
                _isThinkingCollapsed = true;
              }
            }
          });
          _scrollToBottom();
        },
        onError: (error) {
          debugPrint('[AI Assistant] Analyze stream error: $error');
          _cancelSlowResponseTimer();
          _cancelNoResponseTimer();
          _hideSlowResponseTip();
          _safeSetState(() {
            _isAnalyzing = false;
            _isFirstChunkReceived = false;
            _streamingContent = '';
            _hasAnalyzed = true;
          });
          _resetRetryState();
        },
        onDone: () {
          debugPrint('[AI Assistant] Analyze stream completed');
          _cancelSlowResponseTimer();
          _cancelNoResponseTimer();
          _hideSlowResponseTip();

          if (!_hasCompletionOutputForCurrentProvider()) {
            debugPrint(
                '[AI Assistant] Analyze stream completed with empty content, retry count: $_retryCount/$_maxRetryCount');
            if (_shouldRetryForAnalyzeCompletion()) {
              unawaited(_retryWithAutoRecovery());
              return;
            } else {
              _safeSetState(() {
                _isAnalyzing = false;
                _isFirstChunkReceived = false;
                _isThinking = false;
                _retryCount = 0;
                _hasAnalyzed = true;
              });
              _resetRetryState();
              _scrollToBottom();
              return;
            }
          }

          _safeSetState(() {
            _isAnalyzing = false;
            _isFirstChunkReceived = false;
            _isThinking = false;
            _selectedModel ??=
                _displayForStreamedModel(AIService.instance.lastStreamedModel);
            _persistentSelectedModel = _selectedModel;
            final thinkingToSave =
                _thinkingContent.isNotEmpty ? _thinkingContent : null;
            // 欢迎消息固定在顶部：已存在对话时（切换课表后点欢迎消息
            // 的重新生成），新欢迎消息插回列表顶部而非追加到末尾
            final welcomeMsg = _ChatMessage(
              role: 'assistant',
              content: _streamingContent,
              isWelcome: true,
              thinkingContent: thinkingToSave,
            );
            if (_messages.isEmpty) {
              _messages.add(welcomeMsg);
            } else {
              _messages.insert(0, welcomeMsg);
            }
            _streamingContent = '';
            _thinkingContent = '';
            _hasAnalyzed = true;
            // 记录本次课程分析基于的课表：切换课表后与之不同时展示"重新生成"
            _analysisTimetableId = StorageService.currentTimetableId;
          });
          _persistentMessages = List.from(_messages);
          _publishStreamUpdate();
          _resetRetryState();
          _updateSupportsImageUpload();
          // 顶部插入的欢迎消息完成后回到顶部查看；仅欢迎消息时维持回底
          if (_messages.length > 1) {
            _scrollToTop();
          } else {
            _scrollToBottom();
          }
        },
        cancelOnError: true,
      );
    } catch (e) {
      debugPrint('[AI Assistant] Exception in executeAnalyzeSchedule: $e');
      _cancelSlowResponseTimer();
      _cancelNoResponseTimer();
      _hideSlowResponseTip();
      _safeSetState(() {
        _isAnalyzing = false;
        _hasAnalyzed = true;
      });
      _resetRetryState();
      _scrollToBottom();
    }
  }

  List<Course> _getTomorrowCourses(List<Course> courses) {
    final tomorrow = DateTime.now().add(const Duration(days: 1));
    final tomorrowWeekday = tomorrow.weekday;
    final dayIndex = tomorrowWeekday - 1;
    final currentWeek = StorageService.getCurrentWeek();
    return courses.where((c) {
      if (c.day != dayIndex) return false;
      if (c.weeks != null && c.weeks!.isNotEmpty) {
        return _isCourseInWeek(c.weeks!, currentWeek);
      }
      return true;
    }).toList();
  }

  List<Course> _getTodayCourses(List<Course> courses) {
    final today = DateTime.now();
    final dayIndex = today.weekday - 1;
    final currentWeek = StorageService.getCurrentWeek();
    return courses.where((c) {
      if (c.day != dayIndex) return false;
      if (c.weeks != null && c.weeks!.isNotEmpty) {
        return _isCourseInWeek(c.weeks!, currentWeek);
      }
      return true;
    }).toList()
      ..sort((a, b) => a.time.compareTo(b.time));
  }

  bool _isCourseInWeek(String weeks, int currentWeek) {
    final parts = weeks.split(',');
    for (var part in parts) {
      part = part.trim();
      if (part.contains('-')) {
        final range = part.split('-');
        if (range.length == 2) {
          final start = int.tryParse(range[0].trim());
          final end = int.tryParse(range[1].trim());
          if (start != null &&
              end != null &&
              currentWeek >= start &&
              currentWeek <= end) {
            return true;
          }
        }
      } else {
        final week = int.tryParse(part);
        if (week != null && week == currentWeek) {
          return true;
        }
      }
    }
    return false;
  }

  Map<String, dynamic> _getCurrentCourseStatus(List<Course> todayCourses) {
    final now = DateTime.now();
    final timeSlots = StorageService.getTimeSlots();
    final currentPeriod = _getCurrentPeriod(now, timeSlots);

    if (todayCourses.isEmpty) {
      return {
        'status': 'no_class_today',
        'message': '今天没有课程',
      };
    }

    if (currentPeriod == null) {
      final lastPeriodEnd = _getLastPeriodEndTime(timeSlots);
      final firstSlot = timeSlots.isNotEmpty ? timeSlots[0] : null;
      final firstSlotStart =
          firstSlot != null ? _parseTime(firstSlot['start']!, now) : null;

      // 如果在最后一节课结束之后
      if (lastPeriodEnd != null && now.isAfter(lastPeriodEnd)) {
        return {
          'status': 'finished',
          'message': '今天的课程已结束',
        };
      }

      // 如果在第一节课开始之前
      if (firstSlotStart != null && now.isBefore(firstSlotStart)) {
        final waitingMinutes = firstSlotStart.difference(now).inMinutes;
        return {
          'status': 'before_class',
          'firstSlot': firstSlot,
          'waitingMinutes': waitingMinutes,
          'message': '课程还未开始，距离第一节课还有$waitingMinutes分钟',
        };
      }

      // 如果在第一节课开始之后但不在任何课程时间段内（可能是课间或已下课）
      // 查找下一节即将开始的课
      for (int i = 0; i < timeSlots.length; i++) {
        final slotStart = _parseTime(timeSlots[i]['start']!, now);
        final slotEnd = _parseTime(timeSlots[i]['end']!, now);

        // 如果当前时间在这个时间段之前
        if (now.isBefore(slotStart)) {
          final waitingMinutes = slotStart.difference(now).inMinutes;
          // 检查这个时间段是否有课 (c.time 是索引，i 也是索引)
          final courseInSlot =
              todayCourses.where((c) => c.time == i).firstOrNull;
          if (courseInSlot != null) {
            return {
              'status': 'break',
              'currentPeriod': i - 1, // 返回上一节课的索引，用于过滤剩余课程
              'nextCourse': courseInSlot,
              'waitingMinutes': waitingMinutes,
              'message': '课间休息，$waitingMinutes分钟后上${courseInSlot.name}',
            };
          }
        }
      }

      // 默认：今天的课程已结束
      return {
        'status': 'finished',
        'message': '今天的课程已结束',
      };
    }

    final currentCourse = todayCourses
        .where((c) =>
            c.time <= currentPeriod && c.time + c.duration > currentPeriod)
        .firstOrNull;

    if (currentCourse != null) {
      final lastPeriodIndex = currentCourse.time + currentCourse.duration - 1;
      final endSlot = lastPeriodIndex >= 0 && lastPeriodIndex < timeSlots.length
          ? timeSlots[lastPeriodIndex]
          : timeSlots[currentPeriod];
      final endTime = _parseTime(endSlot['end']!, now);
      final remainingMinutes = endTime.difference(now).inMinutes;

      return {
        'status': 'in_class',
        'currentPeriod': currentPeriod,
        'course': currentCourse,
        'remainingMinutes': remainingMinutes,
        'message': '正在上${currentCourse.name}，还有$remainingMinutes分钟下课',
      };
    }

    final nextCourse =
        todayCourses.where((c) => c.time > currentPeriod).firstOrNull;
    if (nextCourse != null) {
      final slot = timeSlots[nextCourse.time];
      final startTime = _parseTime(slot['start']!, now);
      final waitingMinutes = startTime.difference(now).inMinutes;

      return {
        'status': 'break',
        'currentPeriod': currentPeriod,
        'nextCourse': nextCourse,
        'waitingMinutes': waitingMinutes,
        'message': '课间休息，$waitingMinutes分钟后上${nextCourse.name}',
      };
    }

    return {
      'status': 'finished',
      'message': '今天的课程已结束',
    };
  }

  int? _getCurrentPeriod(DateTime now, List<Map<String, String>> timeSlots) {
    for (int i = 0; i < timeSlots.length; i++) {
      final start = _parseTime(timeSlots[i]['start']!, now);
      final end = _parseTime(timeSlots[i]['end']!, now);
      if (now.isAfter(start) && now.isBefore(end)) {
        return i; // 返回索引（从0开始），与 c.time 一致
      }
    }
    return null;
  }

  DateTime _parseTime(String time, DateTime reference) {
    final parts = time.split(':');
    return DateTime(reference.year, reference.month, reference.day,
        int.parse(parts[0]), int.parse(parts[1]));
  }

  DateTime? _getLastPeriodEndTime(List<Map<String, String>> timeSlots) {
    if (timeSlots.isEmpty) return null;
    final now = DateTime.now();
    final lastSlot = timeSlots.last;
    return _parseTime(lastSlot['end']!, now);
  }

  List<Task> _getUpcomingTasks(List<Task> tasks) {
    final now = DateTime.now();
    final weekLater = now.add(const Duration(days: 7));
    return tasks
        .where((t) => t.dueDate.isAfter(now) && t.dueDate.isBefore(weekLater))
        .toList()
      ..sort((a, b) => a.dueDate.compareTo(b.dueDate));
  }

  String _getDayName(int day) {
    const days = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return days[day];
  }

  String _getCourseTimeStr(Course course, List<Map<String, String>> timeSlots) {
    final startTime = course.time + 1;
    final endTime = startTime + course.duration - 1;
    final startSlot = course.time >= 0 && course.time < timeSlots.length
        ? timeSlots[course.time]
        : null;
    final endSlotIndex = course.time + course.duration - 1;
    final endSlot = endSlotIndex >= 0 && endSlotIndex < timeSlots.length
        ? timeSlots[endSlotIndex]
        : null;
    if (startSlot != null && endSlot != null) {
      return '${startSlot['start']}-${endSlot['end']}';
    }
    return '第$startTime-$endTime节';
  }

  String _processAIResponse(String content) {
    try {
      int startIndex = content.indexOf('{');
      if (startIndex == -1) return content;

      int braceCount = 0;
      int endIndex = -1;

      for (int i = startIndex; i < content.length; i++) {
        if (content[i] == '{') {
          braceCount++;
        } else if (content[i] == '}') {
          braceCount--;
          if (braceCount == 0) {
            endIndex = i + 1;
            break;
          }
        }
      }

      if (endIndex == -1) return content;

      final jsonStr = content.substring(startIndex, endIndex);
      debugPrint('[AI Assistant] Matched JSON string: $jsonStr');
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      final action = json['action'] as String?;

      if (action == 'add_task') {
        return _handleAddTask(json, content);
      } else if (action == 'modify_task') {
        return _handleModifyTask(json, content);
      } else if (action == 'delete_task') {
        return _handleDeleteTask(json, content);
      } else if (action == 'add_course') {
        return _handleAddCourse(json, content);
      } else if (action == 'modify_course') {
        return _handleModifyCourse(json, content);
      } else if (action == 'delete_course') {
        return _handleDeleteCourse(json, content);
      }
    } catch (e) {
      debugPrint('Error processing AI response: $e');
    }
    return content;
  }

  String _handleAddTask(Map<String, dynamic> json, String originalContent) {
    try {
      final name = json['name'] as String?;
      final courseName = json['courseName'] as String?;
      final type = json['type'] as String? ?? '其他';
      final dueDateStr = json['dueDate'] as String?;
      final priority = json['priority'] as String? ?? '中';
      final note = json['note'] as String?;

      if (name == null || dueDateStr == null) {
        return originalContent;
      }

      String courseId = 'ai_created';
      String? matchedCourseName;
      if (courseName != null && courseName.isNotEmpty) {
        final courses = StorageService.getCourses();
        debugPrint(
            '🔍 匹配课程: 输入="$courseName", 课程列表=${courses.map((c) => c.name).toList()}');
        final matchedCourses = courses
            .where(
              (c) =>
                  c.name == courseName ||
                  c.name.contains(courseName) ||
                  courseName.contains(c.name),
            )
            .toList();
        debugPrint('🔍 匹配结果: ${matchedCourses.map((c) => c.name).toList()}');
        if (matchedCourses.isNotEmpty) {
          courseId = 'course_name:${matchedCourses.first.name}';
          matchedCourseName = matchedCourses.first.name;
        }
      }

      final now = DateTime.now();
      final dateParts = dueDateStr.split(' ');
      final monthDay = dateParts[0].split('-');
      final hourMinute =
          dateParts.length > 1 ? dateParts[1].split(':') : ['23', '59'];

      final dueDate = DateTime(
        now.year,
        int.parse(monthDay[0]),
        int.parse(monthDay[1]),
        int.parse(hourMinute[0]),
        int.parse(hourMinute[1]),
      );

      final task = Task(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        courseId: courseId,
        name: name,
        type: type,
        dueDate: dueDate,
        priority: priority,
        note: note,
      );

      StorageService.addTask(task);
      _hasSentContext = false;

      debugPrint(
          '🔍 最终结果: courseId=$courseId, matchedCourseName=$matchedCourseName');

      return '✅ 已添加任务：**$name**\n\n'
          '📚 关联课程：${matchedCourseName ?? "通用"}\n'
          '📅 类型：$type\n'
          '⏰ 截止时间：${DateFormat('MM-dd HH:mm').format(dueDate)}\n'
          '🎯 优先级：$priority'
          '${note != null ? '\n📝 备注：$note' : ''}';
    } catch (e) {
      debugPrint('Error adding task: $e');
      return originalContent;
    }
  }

  String _handleModifyTask(Map<String, dynamic> json, String originalContent) {
    try {
      final taskName = json['taskName'] as String?;
      if (taskName == null) return originalContent;

      final tasks = StorageService.getTasks();
      final task = tasks.firstWhere(
        (t) => t.name == taskName,
        orElse: () => throw Exception('Task not found'),
      );

      final newName = json['newName'] as String?;
      final newCourseName = json['newCourseName'] as String?;
      final newType = json['newType'] as String?;
      final newDueDateStr = json['newDueDate'] as String?;
      final newPriority = json['newPriority'] as String?;
      final newNote = json['newNote'] as String?;

      String courseId = task.courseId;
      String? matchedCourseName;
      if (newCourseName != null && newCourseName.isNotEmpty) {
        final courses = StorageService.getCourses();
        final matchedCourses = courses
            .where(
              (c) =>
                  c.name == newCourseName ||
                  c.name.contains(newCourseName) ||
                  newCourseName.contains(c.name),
            )
            .toList();
        if (matchedCourses.isNotEmpty) {
          courseId = 'course_name:${matchedCourses.first.name}';
          matchedCourseName = matchedCourses.first.name;
        }
      }

      DateTime? newDueDate;
      if (newDueDateStr != null) {
        final now = DateTime.now();
        final dateParts = newDueDateStr.split(' ');
        final monthDay = dateParts[0].split('-');
        final hourMinute =
            dateParts.length > 1 ? dateParts[1].split(':') : ['23', '59'];
        newDueDate = DateTime(
          now.year,
          int.parse(monthDay[0]),
          int.parse(monthDay[1]),
          int.parse(hourMinute[0]),
          int.parse(hourMinute[1]),
        );
      }

      final updatedTask = Task(
        id: task.id,
        courseId: courseId,
        name: newName ?? task.name,
        type: newType ?? task.type,
        dueDate: newDueDate ?? task.dueDate,
        priority: newPriority ?? task.priority,
        note: newNote ?? task.note,
        completed: task.completed,
      );

      StorageService.updateTask(updatedTask);
      _hasSentContext = false;

      String? courseDisplayName = matchedCourseName;
      if (courseDisplayName == null && courseId != 'ai_created') {
        if (courseId.startsWith('course_name:')) {
          courseDisplayName = courseId.substring('course_name:'.length);
        } else {
          final courses = StorageService.getCourses();
          final course = courses.where((c) => c.id == courseId).firstOrNull;
          if (course != null) courseDisplayName = course.name;
        }
      }

      return '✅ 已修改任务：**${updatedTask.name}**\n\n'
          '📚 关联课程：${courseDisplayName ?? "通用"}\n'
          '📅 类型：${updatedTask.type}\n'
          '⏰ 截止时间：${DateFormat('MM-dd HH:mm').format(updatedTask.dueDate)}\n'
          '🎯 优先级：${updatedTask.priority}'
          '${updatedTask.note != null ? '\n📝 备注：${updatedTask.note}' : ''}';
    } catch (e) {
      debugPrint('Error modifying task: $e');
      return '❌ 未找到该任务，请检查任务名称是否正确。';
    }
  }

  String _handleDeleteTask(Map<String, dynamic> json, String originalContent) {
    try {
      final taskName = json['taskName'] as String?;
      if (taskName == null) return originalContent;

      final tasks = StorageService.getTasks();
      final task = tasks.firstWhere(
        (t) => t.name == taskName,
        orElse: () => throw Exception('Task not found'),
      );

      StorageService.deleteTask(task.id);
      _hasSentContext = false;

      return '🗑️ 已删除任务：**$taskName**';
    } catch (e) {
      debugPrint('Error deleting task: $e');
      return '❌ 未找到该任务，请检查任务名称是否正确。';
    }
  }

  /// 检测目标时间段与现有课程的占用冲突：同一天 + 节次区间重叠 +
  /// 周次有交集（任一方周次为空视为全周 → 必然重叠）。
  /// [startPeriod] 为 0 基节次（Course.time）；[excludeId] 用于移动
  /// 课程时排除自身。返回冲突课程列表（空 = 无冲突）
  List<Course> _findCourseConflicts({
    required int day,
    required int startPeriod,
    required int duration,
    String? weeks,
    String? excludeId,
  }) {
    final semesterWeeks = StorageService.getSemesterWeeks();
    final targetWeeks =
        parseCourseWeeks(weeks, semesterWeeks); // null/空 → 整学期
    final conflicts = <Course>[];
    for (final c in StorageService.getCourses()) {
      if (excludeId != null && c.id == excludeId) continue;
      if (c.day != day) continue;
      // 节次区间重叠（半开区间 [start, start+duration) ）
      final cStart = c.time;
      final cEnd = cStart + c.duration;
      if (cStart >= startPeriod + duration || cEnd <= startPeriod) continue;
      // 周次交集
      final cWeeks = parseCourseWeeks(c.weeks, semesterWeeks);
      if (!targetWeeks.any(cWeeks.contains)) continue;
      conflicts.add(c);
    }
    return conflicts;
  }

  /// 把冲突课程列表格式化为占用提示（含各自的节次/地点）
  String _formatCourseConflicts(List<Course> conflicts) {
    return conflicts
        .map((c) =>
            '📕 ${c.name}（第${c.time + 1}-${c.time + c.duration}节${c.location != null ? ' · ${c.location}' : ''}）')
        .join('\n');
  }

  String _handleAddCourse(Map<String, dynamic> json, String originalContent) {
    try {
      final name = json['name'] as String?;
      final dayStr = json['day'] as String?;
      final time = json['time'] as int?;
      final duration = json['duration'] as int? ?? 2;
      final location = json['location'] as String?;
      final teacher = json['teacher'] as String?;
      final weeks = json['weeks'] as String?;

      debugPrint(
          '[AI Assistant] _handleAddCourse: name=$name, day=$dayStr, time=$time, duration=$duration, location=$location, teacher=$teacher, weeks=$weeks');
      debugPrint('[AI Assistant] Full JSON: $json');

      if (name == null || dayStr == null || time == null) {
        return originalContent;
      }

      final dayMap = {
        '周一': 0,
        '周二': 1,
        '周三': 2,
        '周四': 3,
        '周五': 4,
        '周六': 5,
        '周日': 6,
        '星期一': 0,
        '星期二': 1,
        '星期三': 2,
        '星期四': 3,
        '星期五': 4,
        '星期六': 5,
        '星期日': 6,
      };
      final day = dayMap[dayStr];
      if (day == null) {
        return '❌ 无法识别的星期：$dayStr，请使用"周一"到"周日"格式。';
      }

      // 目标时间段占用检测：被占用则不添加，回复提示并要求调整时间
      final addConflicts = _findCourseConflicts(
        day: day,
        startPeriod: time - 1,
        duration: duration,
        weeks: weeks,
      );
      if (addConflicts.isNotEmpty) {
        _hasSentContext = false;
        return '⚠️ 添加失败：${_getDayName(day)} 第$time-${time + duration - 1}节 '
            '已有课程占用\n\n'
            '${_formatCourseConflicts(addConflicts)}\n\n'
            '请确认时间并让我调整到空闲时间段（例如"把$name调到周${_getDayName(day).substring(1)}第N节"），'
            '或先让我移走/删除冲突的课程。';
      }

      final course = Course(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: name,
        day: day,
        time: time - 1,
        duration: duration,
        location: location,
        teacher: teacher,
        weeks: weeks,
        color: '#4A90E2',
      );

      StorageService.addCourse(course);
      _hasSentContext = false;

      return '✅ 已添加课程：**$name**\n\n'
          '📅 时间：${_getDayName(day)} 第$time-${time + duration - 1}节\n'
          '📍 地点：${location ?? "未设置"}\n'
          '👨‍🏫 教师：${teacher ?? "未设置"}'
          '${weeks != null ? '\n📆 周次：$weeks' : ''}';
    } catch (e) {
      debugPrint('Error adding course: $e');
      return originalContent;
    }
  }

  String _handleModifyCourse(
      Map<String, dynamic> json, String originalContent) {
    try {
      final courseName = json['courseName'] as String?;
      if (courseName == null) return originalContent;

      final courses = StorageService.getCourses();
      final course = courses.firstWhere(
        (c) => c.name == courseName,
        orElse: () => throw Exception('Course not found'),
      );

      final newName = json['newName'] as String?;
      final newDayStr = json['newDay'] as String?;
      final newTime = json['newTime'] as int?;
      final newDuration = json['newDuration'] as int?;
      final newLocation = json['newLocation'] as String?;
      final newTeacher = json['newTeacher'] as String?;
      final newWeeks = json['newWeeks'] as String?;

      int? newDay;
      if (newDayStr != null) {
        final dayMap = {
          '周一': 0,
          '周二': 1,
          '周三': 2,
          '周四': 3,
          '周五': 4,
          '周六': 5,
          '周日': 6,
          '星期一': 0,
          '星期二': 1,
          '星期三': 2,
          '星期四': 3,
          '星期五': 4,
          '星期六': 5,
          '星期日': 6,
        };
        newDay = dayMap[newDayStr];
      }

      final updatedCourse = Course(
        id: course.id,
        name: newName ?? course.name,
        day: newDay ?? course.day,
        time: newTime != null ? newTime - 1 : course.time,
        duration: newDuration ?? course.duration,
        location: newLocation ?? course.location,
        teacher: newTeacher ?? course.teacher,
        weeks: newWeeks ?? course.weeks,
        color: course.color,
      );

      // 目标时间段占用检测（排除自身）：被占用则不移动，回复提示并
      // 要求调整时间
      final moveConflicts = _findCourseConflicts(
        day: updatedCourse.day,
        startPeriod: updatedCourse.time,
        duration: updatedCourse.duration,
        weeks: updatedCourse.weeks,
        excludeId: course.id,
      );
      if (moveConflicts.isNotEmpty) {
        _hasSentContext = false;
        return '⚠️ 移动失败：${_getDayName(updatedCourse.day)} '
            '第${updatedCourse.time + 1}-${updatedCourse.time + updatedCourse.duration}节 '
            '已有课程占用\n\n'
            '${_formatCourseConflicts(moveConflicts)}\n\n'
            '请确认时间并让我把「${updatedCourse.name}」调整到空闲时间段，'
            '或先处理冲突的课程。';
      }

      StorageService.updateCourse(updatedCourse);
      _hasSentContext = false;

      final displayTime = newTime ?? (course.time + 1);
      return '✅ 已修改课程：**${updatedCourse.name}**\n\n'
          '📅 时间：${_getDayName(updatedCourse.day)} 第$displayTime-${displayTime + updatedCourse.duration - 1}节\n'
          '📍 地点：${updatedCourse.location ?? "未设置"}\n'
          '👨‍🏫 教师：${updatedCourse.teacher ?? "未设置"}'
          '${updatedCourse.weeks != null ? '\n📆 周次：${updatedCourse.weeks}' : ''}';
    } catch (e) {
      debugPrint('Error modifying course: $e');
      return '❌ 未找到该课程，请检查课程名称是否正确。';
    }
  }

  String _handleDeleteCourse(
      Map<String, dynamic> json, String originalContent) {
    try {
      final courseName = json['courseName'] as String?;
      if (courseName == null) return originalContent;

      final courses = StorageService.getCourses();
      final course = courses.firstWhere(
        (c) => c.name == courseName,
        orElse: () => throw Exception('Course not found'),
      );

      StorageService.deleteCourse(course.id);
      _hasSentContext = false;

      return '🗑️ 已删除课程：**$courseName**';
    } catch (e) {
      debugPrint('Error deleting course: $e');
      return '❌ 未找到该课程，请检查课程名称是否正确。';
    }
  }

  String _buildSystemPrompt({bool includeData = false}) {
    if (_isReasoningModel) {
      return '';
    }

    final now = DateTime.now();
    final imageWarning = _supportsImageUpload ? '' : '\n⚠️ 注意：本软件暂未支持上传图片识别功能。';

    String dataSection = '';
    if (includeData) {
      final courses = StorageService.getCourses();
      final tasks = StorageService.getTasks();
      final semesterWeeks = StorageService.getSemesterWeeks();

      // 课程按名称聚合输出（结课周=全部节次周次并集的最大值），
      // 避免模型把单个节次的周次/教师差异误读为整门课结课/换课
      final courseSummaries = aggregateCoursesByName(courses, semesterWeeks);
      final courseSummaryLines = courseSummaries.isEmpty
          ? '暂无课程'
          : courseSummaries.map((s) => s.summaryLine(semesterWeeks)).join('\n');

      final tasksInfo = tasks.map((t) {
        return '${t.name}|${t.type}|${DateFormat('MM-dd HH:mm').format(t.dueDate)}|${t.priority}|${t.note ?? ""}';
      }).join('\n');

      dataSection = '''
📚 当前所有课程（共${courseSummaries.length}门）：
$courseSummaryLines

📝 所有任务（共${tasks.length}个）：
任务名称|类型|截止时间|优先级|备注
${tasksInfo.isEmpty ? '暂无任务' : tasksInfo}

''';
    }

    return '''你是一个智能学习助手，帮助大学生管理课程和任务。你可以：
1. 查看和分析用户的课程表和任务
2. 帮助用户添加、修改、删除课程
3. 帮助用户添加、修改、删除任务
4. 回答学习相关问题
$imageWarning
当前时间：${DateFormat('yyyy-MM-dd HH:mm').format(now)}
当前周次：第${StorageService.getCurrentWeek()}周${StorageService.isHoliday() ? '\n当前状态：假期（${StorageService.isBeforeSemesterStart() ? '新学期尚未开始，建议侧重预习新学期课程、调整作息迎接开学' : '学期已结束，建议侧重复盘上学期、预习下学期'}），用户处于假期中，不必再讨论今日课程安排。' : ''}

$dataSection${includeData ? '' : '（课程和任务数据已在之前的对话中提供）\n\n'}当用户要求添加课程时，请用以下JSON格式回复：
{"action": "add_course", "name": "课程名称", "day": "周一/周二/.../周日", "time": 开始节次(数字), "duration": 持续节数(可选,默认2), "location": "地点(可选)", "teacher": "教师(可选)", "weeks": "周次(可选)"}
⚠️ 重要：当用户说"第X-Y节"时，time=X（开始节次），duration=Y-X+1（持续节数）。例如"1-2节"表示time=1, duration=2；"3-4节"表示time=3, duration=2。

当用户要求修改课程时，请用以下JSON格式回复：
{"action": "modify_course", "courseName": "原课程名称", "newName": "新名称(可选)", "newDay": "新星期(可选)", "newTime": 新开始节次(可选), "newDuration": 新持续节数(可选), "newLocation": "新地点(可选)", "newTeacher": "新教师(可选)", "newWeeks": "新周次(可选)"}
⚠️ 重要：当用户说"改成X-Y节"时，newTime=X（开始节次），newDuration=Y-X+1（持续节数）。

当用户要求删除课程时，请用以下JSON格式回复：
{"action": "delete_course", "courseName": "课程名称"}

当用户要求添加任务时，请用以下JSON格式回复：
{"action": "add_task", "name": "任务名称", "courseName": "关联课程名称（可选，如不指定则为"通用"）", "type": "作业/考试/报告/其他", "dueDate": "MM-dd HH:mm", "priority": "高/中/低", "note": "备注（可选）"}

当用户要求修改任务时，请用以下JSON格式回复：
{"action": "modify_task", "taskName": "原任务名称", "newName": "新名称（可选）", "newCourseName": "新关联课程（可选）", "newType": "新类型（可选）", "newDueDate": "新截止时间（可选）", "newPriority": "新优先级（可选）", "newNote": "新备注（可选）"}

当用户要求删除任务时，请用以下JSON格式回复：
{"action": "delete_task", "taskName": "任务名称"}

$kCourseInterpretationRules

其他情况下，请用简洁友好的方式回答用户问题，可以适当使用emoji。''';
  }

  String _buildContextForR1() {
    final courses = StorageService.getCourses();
    final tasks = StorageService.getTasks();
    final now = DateTime.now();
    final semesterWeeks = StorageService.getSemesterWeeks();

    // 课程按名称聚合输出（结课周=全部节次周次并集的最大值），理由同上
    final courseSummaries = aggregateCoursesByName(courses, semesterWeeks);
    final coursesInfo = courseSummaries.isEmpty
        ? '暂无课程'
        : courseSummaries.map((s) => s.summaryLine(semesterWeeks)).join('\n');

    final tasksInfo = tasks.map((t) {
      return '[${t.priority}] ${t.name} (${t.type}) 截止: ${DateFormat('MM-dd HH:mm').format(t.dueDate)}';
    }).join('\n');

    return '''【背景信息】
当前时间：${DateFormat('yyyy-MM-dd HH:mm').format(now)}
当前周次：第${StorageService.getCurrentWeek()}周${StorageService.isHoliday() ? '\n当前状态：假期（${StorageService.isBeforeSemesterStart() ? '新学期尚未开始，建议侧重预习新学期课程、调整作息迎接开学' : '学期已结束，建议侧重复盘上学期、预习下学期'}），用户处于假期中，不必再讨论今日课程安排。' : ''}

📚 课程数据：
$coursesInfo

📝 任务数据：
${tasksInfo.isEmpty ? '暂无任务' : tasksInfo}

$kCourseInterpretationRules

【能力说明】
你可以帮助用户管理课程和任务：
- 添加课程：{"action": "add_course", "name": "课程名称", "day": "周一/周二/.../周日", "time": 开始节次(数字), "duration": 持续节数(可选,默认2), "location": "地点(可选)", "teacher": "教师(可选)"}
- 修改课程：{"action": "modify_course", "courseName": "原课程名称", "newDay": "新星期(可选)", "newTime": 新节次(可选), ...}
- 删除课程：{"action": "delete_course", "courseName": "课程名称"}
- 添加任务：{"action": "add_task", "name": "任务名称", "courseName": "关联课程名称（可选）", "type": "作业/考试/报告/其他", "dueDate": "MM-dd HH:mm", "priority": "高/中/低"}
- 修改任务：{"action": "modify_task", "taskName": "原任务名称", "newCourseName": "新关联课程（可选）, ...}
- 删除任务：{"action": "delete_task", "taskName": "任务名称"}

⚠️ 重要：当用户说"第X-Y节"或"改成X-Y节"时，time=X（开始节次），duration=Y-X+1（持续节数）。例如"1-2节"表示time=1, duration=2；"3-5节"表示time=3, duration=3。

请根据用户需求执行相应操作。''';
  }

  Future<void> _sendMessage() async {
    // Always sync runtime AI settings before sending so custom API/model edits take effect immediately.
    await AIService.instance.loadConfig();
    await _loadFastModeSetting();

    if (!_aiEnabled) {
      setState(() {
        _messages.add(_ChatMessage(
          role: 'assistant',
          content: '⚠️ AI功能未开启\n\n请前往 **设置** → **AI功能** 开启后再使用AI助手。',
          isError: true,
        ));
      });
      _persistentMessages = List.from(_messages);
      _publishStreamUpdate();
      _scrollToBottom();
      return;
    }

    final text = _messageController.text.trim();
    if ((text.isEmpty && _selectedImageBase64 == null) || _isLoading) return;

    final currentImageBase64 = _selectedImageBase64;
    final currentImagePath = _selectedImagePath;

    String messageText = text;

    _messageController.clear();
    _focusNode.unfocus();

    setState(() {
      _stopRequested = false;
      _messages.add(_ChatMessage(
        role: 'user',
        content: text,
        imagePath: currentImagePath,
        imageAspectRatio: _selectedImageAspectRatio,
      ));
      _selectedImagePath = null;
      _selectedImageBase64 = null;
      _selectedImageAspectRatio = null;
      _isLoading = true;
      _isFirstChunkReceived = false;
      _streamingContent = '';
      _statusMessage = '';
      _isSearching = false;
      _isThinking = false;
      _isThinkingCollapsed = false;
      _thinkingContent = '';
      _showSlowResponseTip = false;
    });
    _persistentMessages = List.from(_messages);
    _publishStreamUpdate();
    _pauseAutoScrollDuringOutput = false;

    _scrollToBottom(force: true);

    // 纯图片/带图消息：Image.file 异步解码，发送当帧 maxScrollExtent
    // 不含图片高度，单次 postFrame 回底不够；图片解码完成后列表变高，
    // 需延迟补偿回底（文字消息同步布局不受影响）
    if (currentImageBase64 != null) {
      for (final delay in const [150, 350, 600, 1000]) {
        Future.delayed(Duration(milliseconds: delay), () {
          if (!mounted || _stopRequested) return;
          if (!_pauseAutoScrollDuringOutput) {
            _scrollToBottom(animated: false, force: true);
          }
        });
      }
    }

    final history = _messages.take(_messages.length - 1).map((msg) {
      // 纯图片消息 content 为空字符串，上游 API 会报
      // "message content cannot be empty"，用占位文本代替
      var content = msg.content;
      if (content.isEmpty && msg.imagePath != null) {
        content = '[图片]';
      }
      return {'role': msg.role, 'content': content};
    }).toList();

    _lastUserMessage = messageText;
    _lastImageBase64 = currentImageBase64;
    _lastHistory = history;
    _retryCount = 0;

    debugPrint('[AI Assistant] New message: "$messageText", starting request');

    _executeSendMessage(
      messageText: messageText,
      imageBase64: currentImageBase64,
      history: history,
    );
  }

  Future<void> _executeSendMessage({
    required String messageText,
    String? imageBase64,
    List<Map<String, String>>? history,
    bool isRetry = false,
  }) async {
    if (_stopRequested) {
      debugPrint(
          '[AI Assistant] Send execution skipped because stop was requested');
      return;
    }
    if (isRetry) {
      debugPrint('[AI Assistant] Retrying message: "$messageText"');
      setState(() {
        _statusMessage = '自动重试中... ($_retryCount/$_maxRetryCount)';
        _isSearching = true;
      });
      _scrollToBottom();
    }

    _startSlowResponseTimer();
    _startNoResponseTimer();

    try {
      String? provider;
      bool supportsWebSearch = true;
      final models = _fastModeEnabled ? _fastModels : _normalModels;
      for (final m in models) {
        if (m['name'] == _selectedModel) {
          provider = m['provider'] as String?;
          supportsWebSearch = m['supportsWebSearch'] as bool? ?? true;
          break;
        }
      }
      provider ??= _currentProvider;
      if (provider == 'custom') {
        supportsWebSearch = false;
        final customModel = (_selectedModel ?? _customModelName).trim();
        final cachedReasoning = await AIService.instance
            .getCachedReasoningCapability(model: customModel);
        if (cachedReasoning != _isReasoningModel ||
            cachedReasoning != _customModelIsReasoning) {
          setState(() {
            _isReasoningModel = cachedReasoning;
            _customModelIsReasoning = cachedReasoning;
          });
        }
      }

      String actualMessage = messageText;
      if (_isReasoningModel && !_hasSentContext) {
        actualMessage = _buildContextForR1() + messageText;
        _hasSentContext = true;
      }

      debugPrint(
          '[AI Assistant] Executing stream request, model: $_selectedModel, provider: $provider');

      final stream = AIService.instance.chatWithModelStream(
        userMessage: actualMessage,
        model: _requestModel,
        systemPrompt: _buildSystemPrompt(includeData: !_hasSentContext),
        history: history,
        fastMode: _fastModeEnabled,
        imageBase64: imageBase64,
        provider: provider,
        enableSearch: _webSearchEnabled &&
            provider == 'doubao' &&
            supportsWebSearch &&
            !_isReasoningModel &&
            imageBase64 == null,
        reasoningEffort: provider == 'custom'
        ? _currentReasoningEffort
        : (provider == 'builtin' ? 'medium' : null),
        owner: _aiRequestOwner,
      );

      if (!_hasSentContext) {
        _hasSentContext = true;
      }

      _streamSubscription = stream.listen(
        (chunk) {
          if (!_isFirstChunkReceived) {
            _cancelSlowResponseTimer();
            _cancelNoResponseTimer();
            _hideSlowResponseTip();
            debugPrint(
                '[AI Assistant] First chunk received, canceling timeout timers');
            _safeSetState(() {
              _isFirstChunkReceived = true;
              _retryCount = 0;
            });
          }
          _safeSetState(() {
            if (chunk.startsWith('【状态】')) {
              _statusMessage = chunk.substring(4);
              _isSearching = true;
              debugPrint('[AI Assistant] Status: $_statusMessage');
            } else if (chunk.startsWith('【思考】')) {
              _cancelNoResponseTimer();
              _cancelSlowResponseTimer();
              _hideSlowResponseTip();
              if (provider == 'custom') {
                _isReasoningModel = true;
                _customModelIsReasoning = true;
              }
              _thinkingContent += chunk.substring(4);
              _isThinking = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _scrollThinkingToBottom();
              });
            } else {
              _streamingContent += chunk;
              _statusMessage = '';
              _isSearching = false;
              if (_isThinking && !_isThinkingCollapsed) {
                _isThinkingCollapsed = true;
              }
            }
          });
          _scrollToBottom();
        },
        onError: (error) {
          debugPrint('[AI Assistant] Stream error: $error');
          final shouldFollowOutput = !_pauseAutoScrollDuringOutput;
          _cancelSlowResponseTimer();
          _cancelNoResponseTimer();
          _hideSlowResponseTip();
          _safeSetState(() {
            _isLoading = false;
            _isFirstChunkReceived = false;
            _streamingContent = '';
            final errStr = error.toString();
            final message = _buildImageAwareErrorMessage(errStr,
                hasImage: imageBase64 != null);
            _messages.add(_ChatMessage(
              role: 'assistant',
              content: message,
              isError: true,
            ));
          });
          _resetRetryState();
          _persistentMessages = List.from(_messages);
          _publishStreamUpdate();
          _syncCurrentSession();
          _ensureFinalScrollToBottom(shouldFollowOutput: shouldFollowOutput);
        },
        onDone: () {
          debugPrint('[AI Assistant] Stream completed');
          _cancelSlowResponseTimer();
          _cancelNoResponseTimer();
          _hideSlowResponseTip();
          final shouldFollowOutput = !_pauseAutoScrollDuringOutput;

          if (!_hasCompletionOutputForCurrentProvider()) {
            debugPrint(
                '[AI Assistant] Stream completed with empty content, retry count: $_retryCount/$_maxRetryCount');
            if (_shouldRetryForAnalyzeCompletion()) {
              unawaited(_retryWithAutoRecovery());
              return;
            } else {
              _safeSetState(() {
                _isLoading = false;
                _isFirstChunkReceived = false;
                _isThinking = false;
                _isThinkingCollapsed = true;
                _retryCount = 0;
                _messages.add(_ChatMessage(
                  role: 'assistant',
                  content:
                      '⚠️ AI未返回任何内容，已自动重试 $_maxRetryCount 次仍无响应。\n\n可能的原因：\n• AI 服务暂时不可用\n• 当前模型响应异常\n\n请稍后重试，或尝试切换其他模型。',
                  isError: true,
                ));
              });
              _resetRetryState();
              _persistentMessages = List.from(_messages);
              _publishStreamUpdate();
              _syncCurrentSession();
              _ensureFinalScrollToBottom(
                  shouldFollowOutput: shouldFollowOutput);
              return;
            }
          }

          _safeSetState(() {
            _isLoading = false;
            _isFirstChunkReceived = false;
            _isThinking = false;
            _isThinkingCollapsed = true;
            _selectedModel ??=
                _displayForStreamedModel(AIService.instance.lastStreamedModel);
            _persistentSelectedModel = _selectedModel;

            final processedContent = _processAIResponse(_streamingContent);
            final thinkingToSave =
                _thinkingContent.isNotEmpty ? _thinkingContent : null;

            _messages.add(_ChatMessage(
              role: 'assistant',
              content: processedContent,
              thinkingContent: thinkingToSave,
            ));
            _streamingContent = '';
            _thinkingContent = '';
          });
          _resetRetryState();
          _persistentMessages = List.from(_messages);
          _publishStreamUpdate();
          _maybeGenerateChatTitle();
          _syncCurrentSession();
          _ensureFinalScrollToBottom(shouldFollowOutput: shouldFollowOutput);
        },
        cancelOnError: true,
      );
    } catch (e) {
      debugPrint('[AI Assistant] Exception in executeSendMessage: $e');
      final shouldFollowOutput = !_pauseAutoScrollDuringOutput;
      _cancelSlowResponseTimer();
      _cancelNoResponseTimer();
      _hideSlowResponseTip();
      _safeSetState(() {
        _isLoading = false;
        _isFirstChunkReceived = false;
        final errStr = e.toString();
        final message =
            _buildImageAwareErrorMessage(errStr, hasImage: imageBase64 != null);
        _messages.add(_ChatMessage(
          role: 'assistant',
          content: message,
          isError: true,
        ));
      });
      _resetRetryState();
      _persistentMessages = List.from(_messages);
      _publishStreamUpdate();
      _syncCurrentSession();
      _ensureFinalScrollToBottom(shouldFollowOutput: shouldFollowOutput);
    }
  }

  void _stopGeneration() {
    debugPrint('[AI Assistant] User stopped generation');
    _stopRequested = true;
    _cancelSlowResponseTimer();
    _cancelNoResponseTimer();
    _hideSlowResponseTip();
    _streamSubscription?.cancel();
    // 停止时也要掐断底层连接：否则请求会在后台跑完才释放占位
    AIService.instance.abortActiveStreams(_aiRequestOwner);
    setState(() {
      if (_isAnalyzing) {
        _isAnalyzing = false;
        _hasAnalyzed = true;
      } else {
        _isLoading = false;
      }
      _isFirstChunkReceived = false;
      if (_streamingContent.isNotEmpty ||
          _thinkingContent.isNotEmpty ||
          _isSearching ||
          _retryCount > 0) {
        _selectedModel ??=
            _displayForStreamedModel(AIService.instance.lastStreamedModel);
        _persistentSelectedModel = _selectedModel;
        final interruptedText =
            _streamingContent.isNotEmpty ? _streamingContent : '⏹️ 已停止重试与生成';
        final interruptedThinking =
            _thinkingContent.isNotEmpty ? _thinkingContent : null;
        _messages.add(_ChatMessage(
          role: 'assistant',
          content: interruptedText,
          isInterrupted: true,
          thinkingContent: interruptedThinking,
        ));
        _streamingContent = '';
        _thinkingContent = '';
        _isThinking = false;
        _isThinkingCollapsed = true;
        _statusMessage = '';
        _isSearching = false;
      }
    });
    _resetRetryState();
    _persistentMessages = List.from(_messages);
    _publishStreamUpdate();
    _syncCurrentSession();
    _scrollToBottom();
  }

  bool _isNearBottom({double threshold = 80}) {
    if (!_scrollController.hasClients) return true;
    final position = _scrollController.position;
    final distanceToBottom =
        max(0.0, position.maxScrollExtent - position.pixels);
    return distanceToBottom <= threshold;
  }

  bool _isOutputInProgress() {
    return _isLoading ||
        _isAnalyzing ||
        _isSearching ||
        _streamingContent.isNotEmpty ||
        _thinkingContent.isNotEmpty;
  }

  bool _handleMessageListScrollNotification(ScrollNotification notification) {
    final isUserDragStart = notification is ScrollStartNotification &&
        notification.dragDetails != null;
    final isUserDragUpdate = notification is ScrollUpdateNotification &&
        notification.dragDetails != null;
    final isUserDragEnd = notification is ScrollEndNotification;

    if (!(isUserDragStart || isUserDragUpdate || isUserDragEnd)) {
      return false;
    }

    if (_isOutputInProgress()) {
      final position = notification.metrics;
      final distanceToBottom =
          max(0.0, position.maxScrollExtent - position.pixels);

      // 拖动期间一律暂停自动跟随，避免 jumpTo 与手指拖动争抢滚动位置造成滚动条跳变；
      // 仅在拖动结束时，若处于底部附近才恢复自动跟随。
      if (isUserDragStart) {
        _pauseAutoScrollDuringOutput = true;
      }

      if (isUserDragUpdate) {
        _pauseAutoScrollDuringOutput = true;
      }

      if (isUserDragEnd && distanceToBottom <= 24) {
        _pauseAutoScrollDuringOutput = false;
      }

      return false;
    }

    if (_pauseAutoScrollDuringOutput && _isNearBottom(threshold: 48)) {
      _pauseAutoScrollDuringOutput = false;
    }

    if (isUserDragEnd &&
        _pauseAutoScrollDuringOutput &&
        _isNearBottom(threshold: 48)) {
      _pauseAutoScrollDuringOutput = false;
    }

    return false;
  }

  void _scrollToBottom({bool animated = true, bool force = false}) {
    if (!force && _pauseAutoScrollDuringOutput) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;

      if (!force && _pauseAutoScrollDuringOutput) {
        return;
      }

      if (animated) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      } else {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  /// 滚动到消息列表顶部：已存在对话时重新生成的欢迎消息插回顶部，
  /// 完成后回到顶部查看新分析
  void _scrollToTop() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
      );
    });
  }

  void _ensureFinalScrollToBottom({required bool shouldFollowOutput}) {
    if (!shouldFollowOutput) {
      return;
    }

    _scrollToBottom(force: true);

    // Rich-text/layout may settle over multiple frames; keep final alignment conservative.
    Future.delayed(const Duration(milliseconds: 80), () {
      if (!mounted) return;
      _scrollToBottom(animated: false, force: true);
    });
    Future.delayed(const Duration(milliseconds: 180), () {
      if (!mounted) return;
      _scrollToBottom(animated: false, force: true);
    });
  }

  void _scrollThinkingToBottom() {
    if (_thinkingScrollController.hasClients) {
      _thinkingScrollController.animateTo(
        _thinkingScrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 50),
        curve: Curves.easeOut,
      );
    }
  }

  void _clearChat() {
    debugPrint('[AI Assistant] Clearing chat');
    _cancelSlowResponseTimer();
    _cancelNoResponseTimer();
    _hideSlowResponseTip();
    _streamSubscription?.cancel();
    AIService.instance.abortActiveStreams(_aiRequestOwner);
    setState(() {
      _messages.clear();
      _selectedModel = null;
      _streamingContent = '';
      _isLoading = false;
      _isFirstChunkReceived = false;
      _hasAnalyzed = false;
      _hasSentContext = false;
    });
    _resetRetryState();
    _persistentMessages = [];
    _persistentSelectedModel = null;
    _persistentChatTitle = null;
    _persistentSavedSessionId = null;
    _titleGeneratedThisSession = false;
    _currentSavedSessionId = null;
    if (mounted) {
      setState(() => _chatTitle = null);
    }
  }

  bool get _hasRealConversation =>
      _messages.any((m) => m.role == 'user' && !m.isWelcome);

  // ==================== 历史对话保存 ====================

  /// 顶栏三点菜单"保存本次对话"：立即保存/覆盖更新当前对话，绿色 toast 反馈
  Future<void> _saveCurrentChat() async {
    if (_isLoading || _isAnalyzing) {
      toastNotification.show(context, '请等待回复完成后再保存', type: ToastType.info);
      return;
    }
    if (!_hasRealConversation) {
      toastNotification.show(context, '当前没有可保存的对话', type: ToastType.info);
      return;
    }
    final now = DateTime.now();
    final id = _currentSavedSessionId ?? 'chat_${now.millisecondsSinceEpoch}';
    final existing = StorageService.getChatSession(id);
    final session = ChatSessionData(
      id: id,
      title: _sanitizeChatTitle(_chatTitle ?? '') ?? _fallbackChatTitle(),
      createdAt: existing != null
          ? (DateTime.tryParse(existing['createdAt']?.toString() ?? '') ?? now)
          : now,
      savedAt: now,
      selectedModel: _selectedModel,
      messages: _serializeMessages(_messages),
    );
    await StorageService.saveChatSession(session.toJson());
    _currentSavedSessionId = id;
    _persistentSavedSessionId = id;
    if (!mounted) return;
    // 顶栏三点菜单按 _currentSavedSessionId 切换"保存/已自动保存"菜单项，
    // 保存后需重建才能立即生效
    setState(() {});
    HapticFeedback.selectionClick();
    toastNotification.show(context, '已保存对话');
  }

  /// AI 标题生成失败时的回退标题：首条真实用户消息截断
  String _fallbackChatTitle() {
    for (final m in _messages) {
      if (m.role == 'user' && !m.isWelcome) {
        final text =
            m.content.isEmpty && m.imagePath != null ? '[图片]' : m.content;
        return _sanitizeChatTitle(text) ?? '未命名对话';
      }
    }
    return '未命名对话';
  }

  /// 标题清洗：去包裹引号/换行/结尾句读，并限长 10 个汉字或 20 个字符
  String? _sanitizeChatTitle(String raw) {
    var t = raw.trim();
    if (t.isEmpty) return null;
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    t = t.replaceFirst(RegExp(r'^标题[:：]\s*'), '');
    const openers = {
      '“': '”',
      '「': '」',
      '『': '』',
      '《': '》',
      '"': '"',
      "'": "'",
      '(': ')',
      '（': '）',
      '【': '】'
    };
    var changed = true;
    while (changed && t.length >= 2) {
      changed = false;
      final closer = openers[t[0]];
      if (closer != null && t.endsWith(closer)) {
        t = t.substring(1, t.length - 1).trim();
        changed = true;
      }
    }
    while (t.isNotEmpty && '。．.，,、！!？?：:；;'.contains(t[t.length - 1])) {
      t = t.substring(0, t.length - 1);
    }
    if (t.isEmpty) return null;
    final sb = StringBuffer();
    int weight = 0;
    for (final rune in t.runes) {
      weight += RegExp(r'[\u4e00-\u9fff]').hasMatch(String.fromCharCode(rune))
          ? 2
          : 1;
      if (weight > 20) break;
      sb.writeCharCode(rune);
    }
    t = sb.toString().trim();
    return t.isEmpty ? null : t;
  }

  /// 首轮真实对话完成（onDone 成功分支）后自动生成会话标题。
  /// 后台静默请求：不赋 _streamSubscription，不受停止按钮/清空取消影响；
  /// 失败静默放弃，保存时回退为用户消息截断标题。
  void _maybeGenerateChatTitle() {
    if (_titleGeneratedThisSession || _isGeneratingTitle) return;
    if (!_hasRealConversation) return;
    final last = _messages.last;
    if (last.role != 'assistant' || last.isError || last.isWelcome) return;
    _generateChatTitle();
  }

  Future<void> _generateChatTitle() async {
    _isGeneratingTitle = true;
    try {
      await AIService.instance.loadConfig();
      final userMsg =
          _messages.firstWhere((m) => m.role == 'user' && !m.isWelcome);
      final assistantMsg = _messages.last;
      final userText = userMsg.content.isEmpty && userMsg.imagePath != null
          ? '[图片]'
          : userMsg.content;
      final buf = StringBuffer();
      await for (final chunk in AIService.instance.chatWithModelStream(
        userMessage: '用户：$userText\n\n助手：${assistantMsg.content}',
        systemPrompt: '你是对话标题生成器。根据给定的一轮对话内容，输出一个能概括对话主题的简短标题。'
            '要求：只输出标题本身，不超过10个汉字（其他语言不超过20个字符），'
            '不要引号、句号或任何额外说明文字。',
      )) {
        if (chunk.startsWith('【状态】') || chunk.startsWith('【思考】')) continue;
        buf.write(chunk);
      }
      final title = _sanitizeChatTitle(buf.toString());
      if (title == null || title.isEmpty) return;
      _safeSetState(() {
        _chatTitle = title;
        _persistentChatTitle = title;
        _titleGeneratedThisSession = true;
      });
      // 标题生成好之前用户可能已保存会话（用的回退临时标题）：
      // AI 标题一生成，立即同步到已存会话记录，不留旧名
      final savedId = _currentSavedSessionId;
      if (savedId != null) {
        final stored = StorageService.getChatSession(savedId);
        if (stored != null && stored['title'] != title) {
          stored['title'] = title;
          await StorageService.saveChatSession(stored);
        }
      }
    } catch (e) {
      debugPrint('[AI Assistant] Generate chat title failed: $e');
    } finally {
      _isGeneratingTitle = false;
    }
  }

  List<Map<String, dynamic>> _serializeMessages(List<_ChatMessage> messages) {
    return messages.map((m) {
      final map = <String, dynamic>{
        'role': m.role,
        'content': m.content,
        'isError': m.isError,
        'isInterrupted': m.isInterrupted,
        'isWelcome': m.isWelcome,
      };
      if (m.thinkingContent != null) map['thinkingContent'] = m.thinkingContent;
      if (m.imagePath != null) map['imagePath'] = m.imagePath;
      if (m.imageAspectRatio != null)
        map['imageAspectRatio'] = m.imageAspectRatio;
      if (m.courses != null) {
        map['courses'] = m.courses!
            .map((c) => {
                  'id': c.id,
                  'name': c.name,
                  'teacher': c.teacher,
                  'location': c.location,
                  'day': c.day,
                  'time': c.time,
                  'duration': c.duration,
                  'weeks': c.weeks,
                  'color': c.color,
                })
            .toList();
      }
      return map;
    }).toList();
  }

  _ChatMessage _chatMessageFromJson(Map<String, dynamic> json) {
    var content = json['content']?.toString() ?? '';
    var imagePath = json['imagePath'] as String?;
    // 图片临时文件可能已被系统清理：降级为占位文本
    if (imagePath != null && !File(imagePath).existsSync()) {
      imagePath = null;
      if (content.isEmpty) content = '[图片已失效]';
    }
    final coursesRaw = json['courses'] as List?;
    return _ChatMessage(
      role: json['role']?.toString() ?? 'assistant',
      content: content,
      isError: json['isError'] as bool? ?? false,
      isInterrupted: json['isInterrupted'] as bool? ?? false,
      isWelcome: json['isWelcome'] as bool? ?? false,
      thinkingContent: json['thinkingContent'] as String?,
      imagePath: imagePath,
      imageAspectRatio: (json['imageAspectRatio'] as num?)?.toDouble(),
      courses: coursesRaw?.map((item) {
        final c = Map<String, dynamic>.from(item as Map);
        return Course(
          id: c['id']?.toString() ?? '',
          name: c['name']?.toString() ?? '',
          teacher: c['teacher']?.toString(),
          location: c['location']?.toString(),
          day: (c['day'] as num?)?.toInt() ?? 0,
          time: (c['time'] as num?)?.toInt() ?? 0,
          duration: (c['duration'] as num?)?.toInt() ?? 1,
          weeks: c['weeks']?.toString(),
          color: c['color']?.toString() ?? '#4A90E2',
        );
      }).toList(),
    );
  }

  /// 恢复已保存的会话到当前对话区
  Future<void> _loadChatSession(Map<String, dynamic> sessionMap) async {
    final id = sessionMap['id']?.toString() ?? '';
    if (id.isEmpty) return;
    final session = ChatSessionData.fromJson(sessionMap);
    // 仅当当前是"从未保存过的新对话"时才需确认（已保存会话之间的切换
    // 不会丢内容：继续聊天会实时同步回原会话记录）
    if (_currentSavedSessionId == null && _hasRealConversation) {
      final confirmed = await _confirmReplaceCurrentChat();
      if (!confirmed || !mounted) return;
    }
    // —— 切换前进行中的工作处理 ——
    if (_isAnalyzing) {
      // 分析中：立即停止（不转入后台）
      _streamSubscription?.cancel();
      _streamSubscription = null;
      // 立即中止：连同底层请求一起掐掉（后台续写的那条已提前摘除登记）
      AIService.instance.abortActiveStreams(_aiRequestOwner);
      _cancelSlowResponseTimer();
      _cancelNoResponseTimer();
      _resetRetryState();
      _isAnalyzing = false;
      _hasAnalyzed = false;
    } else if (_isLoading) {
      if (_currentSavedSessionId != null &&
          _currentSavedSessionId != session.id) {
        // 回答输出阶段且当前对话有归属的已保存会话：
        // 流转入后台继续完成，结束后写回原会话记录
        _detachStreamToBackground(_currentSavedSessionId!);
      } else {
        // 未保存的新对话：立即中断响应，不保存当前对话
        _streamSubscription?.cancel();
        _streamSubscription = null;
        AIService.instance.abortActiveStreams(_aiRequestOwner);
      }
      _cancelSlowResponseTimer();
      _cancelNoResponseTimer();
      _resetRetryState();
    }
    _hideSlowResponseTip();
    _stopRequested = false;
    final restored = session.messages.map(_chatMessageFromJson).toList();
    setState(() {
      _messages = restored;
      _selectedModel = session.selectedModel;
      _persistentSelectedModel = _selectedModel;
      _streamingContent = '';
      _thinkingContent = '';
      _statusMessage = '';
      _isLoading = false;
      _isFirstChunkReceived = false;
      _isSearching = false;
      _isThinking = false;
      _isThinkingCollapsed = true;
      _hasAnalyzed = restored.any((m) => m.isWelcome);
      _hasSentContext = false;
      _analysisTimetableId =
          _hasAnalyzed ? StorageService.currentTimetableId : null;
      _chatTitle = session.title;
      _persistentChatTitle = session.title;
      _currentSavedSessionId = session.id;
      _persistentSavedSessionId = session.id;
      _titleGeneratedThisSession = true;
      _retryCount = 0;
    });
    _persistentMessages = List.from(_messages);
    _publishStreamUpdate();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scrollToBottom(animated: false, force: true);
    });
  }

  Future<bool> _confirmReplaceCurrentChat() async {
    final confirmed = await showBouncyDialog<bool>(
      context: context,
      barrierLabel: '恢复会话',
      shellPadding: EdgeInsets.zero,
      shellBoxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.2),
          blurRadius: 20,
          offset: const Offset(0, 10),
        ),
      ],
      builder: (dialogContext) => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: const Color(0xFF4A90E2).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(Icons.history,
                    color: Color(0xFF4A90E2), size: 28),
              ),
              const SizedBox(height: 16),
              const Text(
                '恢复历史会话',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                '当前对话尚未保存，恢复后将替换为所选会话。',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 14, color: AppColors.of(context).textSecondary),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.of(dialogContext).pop(false),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(
                              color: AppColors.of(context).borderWeak),
                        ),
                      ),
                      child: const Text('取消'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => Navigator.of(dialogContext).pop(true),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF4A90E2),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text('恢复'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    return confirmed ?? false;
  }

  void _onSessionDeleted(String id) {
    if (_currentSavedSessionId == id) {
      _currentSavedSessionId = null;
      _persistentSavedSessionId = null;
    }
  }

  /// 从历史会话继续聊天后，把当前对话实时同步回该会话记录：
  /// 每轮回复完成/出错/被停止后全量写回（更新消息、时间与模型）。
  Future<void> _syncCurrentSession() async {
    final id = _currentSavedSessionId;
    if (id == null || !_hasRealConversation) return;
    final existing = StorageService.getChatSession(id);
    if (existing == null) {
      _currentSavedSessionId = null;
      _persistentSavedSessionId = null;
      return;
    }
    existing['messages'] = _serializeMessages(_messages);
    existing['savedAt'] = DateTime.now().toIso8601String();
    existing['selectedModel'] = _selectedModel;
    if (_chatTitle != null) existing['title'] = _chatTitle;
    await StorageService.saveChatSession(existing);
  }

  /// 切换到其他会话时，把仍在输出中的响应流"脱离"UI 继续在后台消费，
  /// 完成后把结果写回原会话记录（不影响新会话的消息列表）。
  void _detachStreamToBackground(String sessionId) {
    final sub = _streamSubscription;
    _streamSubscription = null;
    // 摘除登记：这条流要交给后台跑完，后续任何 abort 都不应再掐它
    AIService.instance.detachActiveStreams(_aiRequestOwner);
    // 基线消息：当前对话内容（含用户刚发出、尚未写回存储的那条）
    final baseMessages = List<_ChatMessage>.from(_messages);
    var content = _streamingContent;
    var thinking = _thinkingContent;
    final model = _selectedModel ??
        _displayForStreamedModel(AIService.instance.lastStreamedModel);
    _streamingContent = '';
    _thinkingContent = '';
    _statusMessage = '';
    _isSearching = false;
    if (sub == null) return;

    sub.onData((chunk) {
      if (chunk.startsWith('【状态】')) return;
      if (chunk.startsWith('【思考】')) {
        thinking += chunk.substring(4);
        return;
      }
      content += chunk;
    });
    sub.onDone(() {
      _storeBackgroundCompletion(
          sessionId, baseMessages, content, thinking, model,
          errored: false);
    });
    sub.onError((error) {
      debugPrint('[AI Assistant] Background stream error: $error');
      _storeBackgroundCompletion(
          sessionId, baseMessages, content, thinking, model,
          errored: true);
    });
  }

  /// 把后台完成（或中断）的响应写回原会话记录
  Future<void> _storeBackgroundCompletion(
    String sessionId,
    List<_ChatMessage> baseMessages,
    String content,
    String thinking,
    String? model, {
    required bool errored,
  }) async {
    try {
      final stored = StorageService.getChatSession(sessionId);
      if (stored == null) return;
      String processed;
      if (errored) {
        processed = content.isEmpty ? '⏹️ 会话已切换，后台响应中断' : content;
      } else {
        processed =
            content.isEmpty ? '⏹️ 会话已切换，响应在后台结束' : _processAIResponse(content);
      }
      final messages = List<_ChatMessage>.from(baseMessages)
        ..add(_ChatMessage(
          role: 'assistant',
          content: processed,
          isError: errored,
          thinkingContent: thinking.isNotEmpty ? thinking : null,
        ));
      stored['messages'] = _serializeMessages(messages);
      stored['savedAt'] = DateTime.now().toIso8601String();
      stored['selectedModel'] = model;
      await StorageService.saveChatSession(stored);
    } catch (e) {
      debugPrint('[AI Assistant] Store background completion failed: $e');
    }
  }

  void _onSessionRenamed(String id, String newTitle) {
    if (_currentSavedSessionId == id) {
      _safeSetState(() {
        _chatTitle = newTitle;
        _persistentChatTitle = newTitle;
      });
    }
  }

  // ==================== 已保存会话下拉菜单 ====================

  /// 自顶栏向左下弹出的已保存会话菜单：
  /// easeOutBack 过冲缩放（Q弹）+ 位移淡入 + 内容由模糊渐清晰；
  /// 收起时反向：scale 回缩、模糊"向内化开"再淡出。数据由面板自持，
  /// 重命名/删除后面板自行刷新，无需重建 Overlay。
  void _showSavedSessionsMenu() {
    _unfocusBeforeDialog();
    if (_sessionsMenuOverlay != null) return;
    final overlay = Overlay.of(context, rootOverlay: true);
    final controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
      reverseDuration: const Duration(milliseconds: 240),
    );
    final curved = CurvedAnimation(
      parent: controller,
      // 强过冲弹性曲线：t 短暂超出 1.0 再回落，配合面板的位移/缩放
      // 得到"淡入弹出 → 超出 → 收回"的 Q 弹感（面板变换层恒定存在，
      // 过冲值仅驱动参数）
      curve: const Cubic(0.175, 0.885, 0.32, 1.35),
      reverseCurve: Curves.easeInCubic,
    );
    _sessionsMenuController = controller;
    _sessionsMenuCurved = curved;
    final entry = OverlayEntry(
      builder: (context) => SavedSessionsMenuHost(
        animation: curved,
        currentSessionId: _currentSavedSessionId,
        onDismiss: _dismissSessionsMenu,
        onLoadSession: _loadChatSession,
        onRenamed: _onSessionRenamed,
        onDeleted: _onSessionDeleted,
      ),
    );
    _sessionsMenuOverlay = entry;
    overlay.insert(entry);
    _sessionsMenuOpen = true;
    controller.forward();
  }

  Future<void> _dismissSessionsMenu([VoidCallback? then]) async {
    final entry = _sessionsMenuOverlay;
    final controller = _sessionsMenuController;
    final curved = _sessionsMenuCurved;
    if (entry == null || controller == null) {
      then?.call();
      return;
    }
    _sessionsMenuOverlay = null;
    _sessionsMenuController = null;
    _sessionsMenuCurved = null;
    await controller.reverse();
    if (entry.mounted) entry.remove();
    curved?.dispose();
    controller.dispose();
    _sessionsMenuOpen = false;
    // 菜单打开期间的键盘变化被屏蔽，关闭后补一次同步对齐实际键盘状态
    if (mounted) {
      didChangeMetrics();
    }
    then?.call();
  }

  /// 打开对话框/页面前的统一处理：清除当前焦点并隐藏键盘。
  void _unfocusBeforeDialog() {
    _focusNode.unfocus(disposition: UnfocusDisposition.scope);
    SystemChannels.textInput.invokeMethod('TextInput.hide');
  }

  /// 对话框/页面关闭后调用：清除可能被路由焦点恢复机制重新激活的焦点。
  void _unfocusAfterDialog() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusNode.unfocus(disposition: UnfocusDisposition.scope);
      SystemChannels.textInput.invokeMethod('TextInput.hide');
    });
  }

  /// 离开对话页时调用：强制清除输入框焦点并隐藏键盘，防止切回时键盘自动弹出。
  void clearInputFocus() {
    if (!mounted) return;
    _focusNode.unfocus(disposition: UnfocusDisposition.scope);
    FocusManager.instance.primaryFocus?.unfocus();
    SystemChannels.textInput.invokeMethod('TextInput.hide');
  }

  void _navigateToSettings() {
    _unfocusBeforeDialog();
    if (widget.onNavigateToSettings != null) {
      widget.onNavigateToSettings!();
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => const SettingsScreen()),
      ).then((_) {
        _loadFastModeSetting();
        _unfocusAfterDialog();
      });
    }
  }

  void _showModelSelector() {
    _unfocusBeforeDialog();
    if (_currentProvider == 'hunyuan' ||
        _currentProvider == 'glm' ||
        _currentProvider == 'custom' ||
        _currentProvider == 'agnes' ||
        _currentProvider == 'builtin') {
      return;
    }
    final models = _fastModeEnabled ? _fastModels : _normalModels;

    showBouncyDialog(
      context: context,
      barrierLabel: '选择模型',
      shellPadding: EdgeInsets.zero,
      shellBoxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.2),
          blurRadius: 20,
          offset: const Offset(0, 10),
        ),
      ],
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: 400,
              maxHeight: 500,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Opacity(
                  opacity: 0.82,
                  child: Container(
                    padding: const EdgeInsets.all(20),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFF4A90E2), Color(0xFF5BA0F2)],
                      ),
                      borderRadius:
                          BorderRadius.vertical(top: Radius.circular(24)),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(Icons.psychology,
                              color: Colors.white, size: 24),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '选择模型',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                              Text(
                                _fastModeEnabled
                                    ? '切换到普通模式启用图片上传功能'
                                    : '普通模式 · ${models.length}个模型可选',
                                style: TextStyle(
                                    fontSize: 12, color: Colors.white70),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(
                        parent: AlwaysScrollableScrollPhysics()),
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: models.map((model) {
                        final modelName = model['name'] as String;
                        final supportsImage = model['supportsImage'] as bool;
                        final isSelected = _selectedModel == modelName;

                        return GestureDetector(
                          onTap: () {
                            setDialogState(() {
                              _selectedModel = modelName;
                              _persistentSelectedModel = modelName;
                              _supportsImageUpload = supportsImage;
                              if (!supportsImage) {
                                _selectedImagePath = null;
                                _selectedImageBase64 = null;
                                _selectedImageAspectRatio = null;
                              }
                            });
                            setState(() {});
                            Future.delayed(const Duration(milliseconds: 150),
                                () {
                              if (!context.mounted) return;
                              Navigator.pop(context);
                            });
                          },
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? const Color(0xFF4A90E2)
                                      .withValues(alpha: 0.1)
                                  : AppColors.of(context).panel(0.4),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isSelected
                                    ? const Color(0xFF4A90E2)
                                    : AppColors.of(context).panel(0.4),
                                width: isSelected ? 2 : 1,
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  isSelected
                                      ? Icons.check_box
                                      : Icons.check_box_outline_blank,
                                  color: isSelected
                                      ? const Color(0xFF4A90E2)
                                      : AppColors.of(context).textTertiary,
                                  size: 24,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        modelName,
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: isSelected
                                              ? FontWeight.w600
                                              : FontWeight.normal,
                                          color: isSelected
                                              ? const Color(0xFF4A90E2)
                                              : null,
                                        ),
                                      ),
                                      if (supportsImage)
                                        const Text(
                                          '支持图片上传',
                                          style: TextStyle(
                                            color:
                                                Color.fromARGB(255, 72, 72, 72),
                                            fontSize: 10,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: SizedBox(
                    width: double.infinity,
                    child: TextButton(
                      onPressed: () => Navigator.pop(context),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(
                              color: AppColors.of(context).borderWeak),
                        ),
                      ),
                      child: const Text('关闭'),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    ).then((_) => _unfocusAfterDialog());
  }

  /// Agnes AI 配置弹窗：与设置页的 Agnes AI 配置对话框保持一致
  void _showAgnesAIConfig() async {
    _unfocusBeforeDialog();
    final prefs = await SharedPreferences.getInstance();
    final controller =
        TextEditingController(text: prefs.getString('agnes_api_key') ?? '');
    const defaultModel = 'agnes-2.0-flash';
    String selectedModel = prefs.getString('agnes_model') ?? defaultModel;
    if (selectedModel != 'agnes-2.0-flash' &&
        selectedModel != 'agnes-2.5-flash') {
      selectedModel = defaultModel;
    }
    String reasoningEffort = prefs.getString('agnes_reasoning_effort') ?? '';

    if (!mounted) return;

    await showBouncyDialog(
      context: context,
      barrierLabel: 'Agnes AI 配置',
      avoidKeyboard: true,
      shellPadding: const EdgeInsets.all(24),
      shellConstraintsBuilder: (context) {
        final mediaQuery = MediaQuery.of(context);
        final keyboardHeight = mediaQuery.viewInsets.bottom;
        final topInset = mediaQuery.padding.top;
        final screenHeight = mediaQuery.size.height;
        const baseMaxHeight = 620.0;
        double dialogMaxHeight = baseMaxHeight;
        final availableHeight = screenHeight - topInset - keyboardHeight - 24;
        if (availableHeight < dialogMaxHeight) {
          dialogMaxHeight = availableHeight;
        }
        dialogMaxHeight =
            dialogMaxHeight.clamp(300.0, baseMaxHeight).toDouble();
        return BoxConstraints(maxWidth: 420, maxHeight: dialogMaxHeight);
      },
      shellBoxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.2),
          blurRadius: 20,
          offset: const Offset(0, 10),
        ),
      ],
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Agnes AI 配置',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '免费密钥申请地址：https://www.agnes-ai.cn/',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: AppColors.of(context).textSecondary,
                    ),
                  ),
                  const SizedBox(height: 20),
                  AppTextField(
                    contextMenuBuilder: styledEditableContextMenu,
                    controller: controller,
                    decoration: InputDecoration(
                      hintText: '请输入 Agnes AI API Key',
                      filled: true,
                      fillColor: AppColors.of(context).panel(0.4),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide:
                            BorderSide(color: AppColors.of(context).borderWeak),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide:
                            BorderSide(color: AppColors.of(context).borderWeak),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Color(0xFF4A90E2)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Text(
                        '模型',
                        style: TextStyle(
                          fontSize: 14,
                          color: AppColors.of(context).textSecondary,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(
                            color: AppColors.of(context).surface,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                                color: AppColors.of(context).borderWeak),
                          ),
                          child: BlurredDropdown<String>(
                            value: selectedModel,
                            isExpanded: true,
                            icon: const Icon(Icons.expand_more,
                                size: 18, color: Color(0xFF4A90E2)),
                            items: const [
                              DropdownMenuItem(
                                value: 'agnes-2.0-flash',
                                child: Text(
                                  'Agnes 2.0 Flash',
                                  style: TextStyle(fontSize: 13),
                                ),
                              ),
                              DropdownMenuItem(
                                value: 'agnes-2.5-flash',
                                child: Text(
                                  'Agnes 2.5 Flash',
                                  style: TextStyle(fontSize: 13),
                                ),
                              ),
                            ],
                            onChanged: (next) {
                              if (next != null) {
                                setDialogState(() {
                                  selectedModel = next;
                                });
                              }
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // 思考强度：与自定义API同款滑动选项卡（1:1复刻）
                  Text('思考强度',
                      style: TextStyle(
                          fontSize: 13,
                          color: AppColors.of(context).textPrimary)),
                  const SizedBox(height: 8),
                  SegmentedSelector<String>(
                    items: const [
                      SegmentItem(label: '直接回答', value: ''),
                      SegmentItem(label: 'Low', value: 'low'),
                      SegmentItem(label: 'Medium', value: 'medium'),
                      SegmentItem(label: 'High', value: 'high'),
                    ],
                    activeValue: reasoningEffort.isEmpty ? '' : reasoningEffort,
                    onChanged: (v) {
                      setDialogState(() {
                        reasoningEffort = v;
                      });
                    },
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: () => Navigator.pop(context),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: BorderSide(
                                  color: AppColors.of(context).borderWeak),
                            ),
                          ),
                          child: const Text('取消'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () async {
                            final apiKey = controller.text.trim();

                            if (apiKey.isEmpty) {
                              Navigator.pop(context);
                              return;
                            }

                            await prefs.setString('agnes_api_key', apiKey);
                            await prefs.setString('agnes_model', selectedModel);
                            await prefs.setString(
                                'agnes_reasoning_effort', reasoningEffort);
                            await prefs.setString('ai_provider', 'agnes');
                            await prefs.setBool('fast_mode_enabled', false);
                            await prefs.setBool('ai_enabled', true);
                            AIService.instance
                                .setAgnesConfig(apiKey, selectedModel);

                            if (mounted) {
                              Navigator.pop(context);
                              setState(() {
                                _currentProvider = 'agnes';
                                _selectedModel =
                                    _agnesDisplayNameOf(selectedModel);
                                _persistentSelectedModel = _selectedModel;
                                _fastModeEnabled = false;
                                _aiEnabled = true;
                                _supportsImageUpload = true;
                                _isReasoningModel = false;
                              });
                            }
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.isDark(context)
                                ? AppColors.of(context).surfaceAlt
                                : Colors.grey.shade800,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: const Text('保存'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    controller.dispose();
  }

  /// 内置模型节点切换：顶部徽章点击弹出统一样式下拉菜单（AI配置页同款），
  /// 选择节点 1-4 后立即更新徽章显示并持久化
  void _showBuiltinNodeMenu() async {
    _unfocusBeforeDialog();
    final anchorContext = _builtinBadgeKey.currentContext ?? context;
    final result = await showBlurredMenu<int>(
      context: anchorContext,
      value: _builtinNode,
      menuWidth: 120,
      // 徽章较窄：菜单整体左移，右缘与徽章右侧对齐方向平衡
      menuHorizontalShift: -28,
      // 节点 3/4 右侧问号图标的提示文案
      infoMessages: const {
        3: '节点3延迟较高，请优先使用节点1、2。',
        4: '节点4延迟较高，请优先使用节点1、2。',
      },
      // 菜单底部固定展示内置模型今日用量（本地计数，跨天自复位）
      footer: const BuiltinAiUsageBar(),
      items: [
        for (var i = 1; i <= 4; i++)
          DropdownMenuItem<int>(
            value: i,
            child: Text('节点 $i', style: TextStyle(fontSize: 13)),
          ),
      ],
    );
    if (result != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('builtin_node', result);
      if (mounted) {
        setState(() {
          _builtinNode = result;
          _selectedModel = '节点 $result';
          _persistentSelectedModel = _selectedModel;
        });
      }
    }
  }

  void _showCustomAIConfig() async {
    _unfocusBeforeDialog();
    final prefs = await SharedPreferences.getInstance();
    final urlController =
        TextEditingController(text: prefs.getString('custom_api_url') ?? '');
    final keyController =
        TextEditingController(text: prefs.getString('custom_api_key') ?? '');
    final modelController = TextEditingController(
        text: prefs.getString('custom_api_model') ?? 'gpt-4o-mini');
    bool manualVisionOverride =
        prefs.getBool('custom_api_vision_manual_override') ?? false;
    bool manualVisionEnabled =
        prefs.getBool('custom_api_vision_manual_value') ?? false;
    String reasoningEffort =
        prefs.getString('custom_api_reasoning_effort') ?? '';
    bool webSearchEnabled = prefs.getBool('web_search_enabled') ?? false;

    if (!mounted) return;

    await showBouncyDialog(
      context: context,
      barrierLabel: 'AI配置',
      avoidKeyboard: true,
      shellPadding: const EdgeInsets.all(24),
      // 壳总宽/总高约束含壳内边距（与旧版壳外 ConstrainedBox(constraints:) 一致）；
      // 键盘弹出时动态压缩最大高度，闭包内 MediaQuery 依赖使宿主自动重建
      shellConstraintsBuilder: (context) {
        final mediaQuery = MediaQuery.of(context);
        final keyboardHeight = mediaQuery.viewInsets.bottom;
        final topInset = mediaQuery.padding.top;
        final screenHeight = mediaQuery.size.height;
        const baseMaxHeight = 650.0;
        double dialogMaxHeight = baseMaxHeight;
        final availableHeight = screenHeight - topInset - keyboardHeight - 24;
        if (availableHeight < dialogMaxHeight) {
          dialogMaxHeight = availableHeight;
        }
        dialogMaxHeight =
            dialogMaxHeight.clamp(320.0, baseMaxHeight).toDouble();
        return BoxConstraints(maxWidth: 420, maxHeight: dialogMaxHeight);
      },
      shellBoxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.2),
          blurRadius: 20,
          offset: const Offset(0, 10),
        ),
      ],
      builder: (ctx) => _buildCustomAIConfigDialog(
        prefs: prefs,
        urlController: urlController,
        keyController: keyController,
        modelController: modelController,
        manualVisionOverride: manualVisionOverride,
        manualVisionEnabled: manualVisionEnabled,
        reasoningEffort: reasoningEffort,
        webSearchEnabled: webSearchEnabled,
      ),
    );

    urlController.dispose();
    keyController.dispose();
    modelController.dispose();
  }

  Widget _buildCustomAIConfigDialog({
    required SharedPreferences prefs,
    required TextEditingController urlController,
    required TextEditingController keyController,
    required TextEditingController modelController,
    required bool manualVisionOverride,
    required bool manualVisionEnabled,
    required String reasoningEffort,
    required bool webSearchEnabled,
  }) {
    var localWebSearch = webSearchEnabled;

    return StatefulBuilder(
      builder: (builderCtx, setDialogState) {
        return SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '自定义 OpenAI 兼容 API',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                '支持OpenAI格式的API接口',
                style: TextStyle(
                    fontSize: 13, color: AppColors.of(context).textSecondary),
              ),
              const SizedBox(height: 20),
              AppTextField(
                contextMenuBuilder: styledEditableContextMenu,
                controller: urlController,
                decoration: InputDecoration(
                  labelText: 'API 地址',
                  hintText: 'https://api.example.com/v1/chat/completions',
                  filled: true,
                  fillColor: AppColors.of(context).panel(0.4),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 12),
              AppTextField(
                contextMenuBuilder: styledEditableContextMenu,
                controller: keyController,
                decoration: InputDecoration(
                  labelText: 'API Key',
                  hintText: '请输入API密钥',
                  filled: true,
                  fillColor: AppColors.of(context).panel(0.4),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 12),
              AppTextField(
                contextMenuBuilder: styledEditableContextMenu,
                controller: modelController,
                decoration: InputDecoration(
                  labelText: '模型名称',
                  hintText: 'gpt-4o-mini',
                  filled: true,
                  fillColor: AppColors.of(context).panel(0.4),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 12),
              Text('视觉能力支持',
                  style: TextStyle(
                      fontSize: 13, color: AppColors.of(context).textPrimary)),
              const SizedBox(height: 8),
              _buildInlineSegmented(
                labels: const ['自动', '开启', '关闭'],
                activeIndex:
                    !manualVisionOverride ? 0 : (manualVisionEnabled ? 1 : 2),
                onChanged: (idx) => setDialogState(() {
                  if (idx == 0) {
                    manualVisionOverride = false;
                    manualVisionEnabled = false;
                  } else {
                    manualVisionOverride = true;
                    manualVisionEnabled = idx == 1;
                  }
                }),
              ),
              const SizedBox(height: 16),
              Text('思考强度',
                  style: TextStyle(
                      fontSize: 13, color: AppColors.of(context).textPrimary)),
              const SizedBox(height: 8),
              _buildInlineSegmented(
                labels: const ['直接回答', 'Low', 'Medium', 'High'],
                activeIndex: reasoningEffort.isEmpty
                    ? 0
                    : reasoningEffort == 'low'
                        ? 1
                        : reasoningEffort == 'medium'
                            ? 2
                            : 3,
                onChanged: (idx) => setDialogState(() {
                  reasoningEffort = ['', 'low', 'medium', 'high'][idx];
                }),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Text('联网搜索',
                      style: TextStyle(
                          fontSize: 13,
                          color: AppColors.of(context).textPrimary)),
                  const Spacer(),
                  SizedBox(
                    height: 28,
                    child: Switch(
                      value: localWebSearch,
                      activeTrackColor: AppColors.of(context).textSecondary,
                      onChanged: (v) {
                        HapticFeedback.selectionClick();
                        setDialogState(() {
                          localWebSearch = v;
                        });
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(builderCtx),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(
                              color: AppColors.of(context).borderWeak),
                        ),
                      ),
                      child: const Text('取消'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () async {
                        if (urlController.text.trim().isEmpty ||
                            keyController.text.trim().isEmpty) {
                          return;
                        }
                        await prefs.setString(
                            'custom_api_url', urlController.text.trim());
                        await prefs.setString(
                            'custom_api_key', keyController.text.trim());
                        await prefs.setString(
                            'custom_api_model', modelController.text.trim());
                        await prefs.setString('ai_provider', 'custom');
                        await prefs.setBool('fast_mode_enabled', false);
                        await prefs.setBool('ai_enabled', true);
                        await prefs.setString('custom_api_reasoning_effort',
                            reasoningEffort.isNotEmpty ? reasoningEffort : '');
                        await prefs.setBool(
                            'web_search_enabled', localWebSearch);
                        AIService.instance.setCustomApiConfig(
                          apiUrl: urlController.text.trim(),
                          apiKey: keyController.text.trim(),
                          model: modelController.text.trim(),
                        );
                        await AIService.instance.setCustomVisionManualOverride(
                          enabled: manualVisionOverride,
                          supportsVision: manualVisionEnabled,
                        );
                        await AIService.instance.setCustomReasoningEffort(
                          reasoningEffort.isNotEmpty ? reasoningEffort : null,
                        );
                        if (builderCtx.mounted) {
                          Navigator.pop(builderCtx);
                        }
                        _loadFastModeSettingAndAnalyze();
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.isDark(context)
                            ? AppColors.of(context).surfaceAlt
                            : Colors.grey.shade800,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text('保存'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildInlineSegmented({
    required List<String> labels,
    required int activeIndex,
    required ValueChanged<int> onChanged,
  }) {
    return _DragSegmented(
      labels: labels,
      activeIndex: activeIndex,
      onChanged: onChanged,
    );
  }

  Uint8List _compressImageBytes(Uint8List bytes) {
    try {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return bytes;

      final originalSize = bytes.length;
      var resized = decoded;
      const maxDim = 1024;
      if (resized.width > maxDim || resized.height > maxDim) {
        resized = img.copyResize(resized, width: maxDim, height: maxDim);
      }

      final compressed = img.encodeJpg(resized, quality: 70);
      debugPrint(
          '[Image] Compressed: ${(originalSize / 1024).toStringAsFixed(1)}KB → ${(compressed.length / 1024).toStringAsFixed(1)}KB');
      return Uint8List.fromList(compressed);
    } catch (e) {
      debugPrint('[Image] Compression failed: $e');
      return bytes;
    }
  }

  Future<void> _pickImage() async {
    try {
      final ImagePicker picker = ImagePicker();
      final XFile? image = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        maxHeight: 1080,
        imageQuality: 85,
      );

      if (image != null) {
        var bytes = await image.readAsBytes();
        final decoded = img.decodeImage(bytes);
        final aspectRatio =
            decoded != null ? decoded.width / decoded.height : null;
        bytes = _compressImageBytes(bytes);
        setState(() {
          _selectedImagePath = image.path;
          _selectedImageBase64 = base64Encode(bytes);
          _selectedImageAspectRatio = aspectRatio;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollToBottom();
        });
      }
    } catch (e) {
      debugPrint('Error picking image: $e');
    }
  }

  Future<void> _pickImageFromCamera() async {
    try {
      final ImagePicker picker = ImagePicker();
      final XFile? image = await picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1920,
        maxHeight: 1080,
        imageQuality: 85,
      );

      if (image != null) {
        var bytes = await image.readAsBytes();
        final decoded = img.decodeImage(bytes);
        final aspectRatio =
            decoded != null ? decoded.width / decoded.height : null;
        bytes = _compressImageBytes(bytes);
        setState(() {
          _selectedImagePath = image.path;
          _selectedImageBase64 = base64Encode(bytes);
          _selectedImageAspectRatio = aspectRatio;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollToBottom();
        });
      }
    } catch (e) {
      debugPrint('Error picking image from camera: $e');
    }
  }

  String _buildImageAwareErrorMessage(String error, {required bool hasImage}) {
    final lowerError = error.toLowerCase();

    if (!hasImage) {
      return '抱歉，发生了错误：$error';
    }

    if (lowerError.contains('no endpoints found that support image input') ||
        lowerError.contains('does not support image') ||
        lowerError.contains('image input')) {
      if (_currentProvider == 'custom') {
        return '⚠️ 图片发送失败：当前自定义API不支持图片输入\n\n'
            '可能的原因：\n'
            '• 该API端点或模型不支持多模态/视觉输入\n'
            '• 需要更换为支持图片的模型（如 gpt-4o、gemini-2.0-flash-exp 等）\n\n'
            '建议：尝试发送纯文本消息，或在开发者选项中切换到支持图片的API';
      }
      return '⚠️ 图片发送失败：当前模型不支持图片输入\n\n'
          '请尝试发送纯文本消息，或切换到支持视觉的模型';
    }

    if (lowerError.contains('1210') ||
        lowerError.contains('api 调用参数有误') ||
        lowerError.contains('参数有误')) {
      return '⚠️ 图片发送失败：API参数错误，当前模型可能不支持图片输入\n\n'
          '建议：尝试发送纯文本消息，或更换支持多模态的模型';
    }

    if (lowerError.contains('payload') ||
        lowerError.contains('too large') ||
        lowerError.contains('413')) {
      return '⚠️ 图片发送失败：图片体积过大，超出了API的请求限制\n\n'
          '建议：尝试使用更小的图片，或降低图片分辨率后重试';
    }

    return '抱歉，发生了错误：$error';
  }

  /// 文字变化：post-frame 复核输入框内部滚动状态（maxScrollExtent 在布局后
  /// 才可用；高度是否变化由 SizeChangedLayoutNotification 驱动，无需在此处理）
  void _onInputTextChanged() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateInputEdgeFade();
    });
  }

  /// 实测输入区总高度并同步消息列表底部避让
  ///
  /// 触发源是输入区的 SizeChangedLayoutNotification——换行增行、图片预览
  /// 出现/移除、字体缩放、旋转、AnimatedSize 动画逐帧等一切真实尺寸变化
  /// 都会送达。post-frame 读 RenderBox 实际高度，与缓存差 >0.5px 才刷新；
  /// 渐变动画期间每帧收敛到真实值。长高时把列表压到底，保证最新内容
  /// 不被增高的输入区盖住。
  void _syncInputAreaHeight() {
    if (!mounted) return;
    final ctx = _inputAreaKey.currentContext;
    if (ctx == null) return;
    final box = ctx.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final h = box.size.height;
    if ((_inputAreaHeight - h).abs() <= 0.5) return;
    final grew = h > _inputAreaHeight;
    setState(() {
      _inputAreaHeight = h;
    });
    if (grew) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        }
      });
    }
  }

  /// 根据输入框内部滚动位置刷新上下边缘淡出状态：
  /// 仅在文字超出显示区域滚动时生效，且只淡出有剩余内容的一端
  void _updateInputEdgeFade() {
    if (!mounted || !_inputScrollController.hasClients) return;
    final pos = _inputScrollController.position;
    if (!pos.hasContentDimensions) return;
    final maxExtent = pos.maxScrollExtent;
    final next = (
      top: pos.pixels > 0.5,
      bottom: pos.pixels < maxExtent - 0.5,
    );
    if (_inputEdgeFade.value != next) {
      _inputEdgeFade.value = next;
    }
  }

  void _removeImage() {
    setState(() {
      _selectedImagePath = null;
      _selectedImageBase64 = null;
      _selectedImageAspectRatio = null;
    });
  }

  /// 懒创建菜单动画控制器（首次点开菜单时才需要）
  AnimationController _ensureAddMenuController() {
    if (_addMenuController == null) {
      _addMenuController = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 220),
      );
      _addMenuCurved = CurvedAnimation(
        parent: _addMenuController!,
        // 与三点菜单一致：弹出过冲回弹，收起加速退出；
        // easeOutBack 值域会过冲，渲染处需 clamp
        curve: Curves.easeOutBack,
        reverseCurve: Curves.easeInCubic,
      );
    }
    return _addMenuController!;
  }

  void _toggleAddMenu() {
    HapticFeedback.selectionClick();
    final controller = _ensureAddMenuController();
    setState(() {
      _showAddMenu = !_showAddMenu;
    });
    if (_showAddMenu) {
      controller.forward(from: 0);
    } else {
      controller.reverse(from: 1);
    }
  }

  void _closeAddMenu() {
    if (_showAddMenu) {
      setState(() {
        _showAddMenu = false;
      });
      _addMenuController?.reverse(from: 1);
    }
  }

  void _handleMenuSelection(String value) {
    HapticFeedback.selectionClick();
    _closeAddMenu();
    if (value == 'camera') {
      _pickImageFromCamera();
    } else if (value == 'gallery') {
      _pickImage();
    }
  }

  Widget _buildMenuItem({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    BorderRadius borderRadius = BorderRadius.zero,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: borderRadius,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: const Color(0xFF4A90E2), size: 20),
              const SizedBox(width: 12),
              Text(
                label,
                style: TextStyle(
                  fontSize: 15,
                  color: AppColors.of(context).textPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    _unfocusAfterDialog();
  }

  void _showImagePreview(String imagePath,
      {bool useHero = true, int? messageIndex, double? imageAspectRatio}) {
    _unfocusBeforeDialog();
    final heroTag = messageIndex != null
        ? 'image_preview_${messageIndex}_$imagePath'
        : 'image_preview_$imagePath';
    Navigator.of(context)
        .push(
          PageRouteBuilder(
            opaque: false,
            transitionDuration: const Duration(milliseconds: 350),
            reverseTransitionDuration: const Duration(milliseconds: 250),
            barrierDismissible: true,
            barrierLabel: '图片预览',
            barrierColor: Colors.transparent,
            pageBuilder: (context, animation, secondaryAnimation) {
              // 关闭按钮在页面内部 Stack 顶层，由 _routeSettled 控制可见性：
              // Hero 飞行期间 shuttle 位于 Navigator overlay 顶层（所有路由之上），
              // 按钮瞬时隐藏，飞行结束后再淡入（详见 _ImagePreviewPageState.build）
              return _ImagePreviewPage(
                imagePath: imagePath,
                heroTag: heroTag,
                animation: animation,
                useHero: useHero,
                imageAspectRatio: imageAspectRatio,
              );
            },
          ),
        )
        .then((_) => _unfocusAfterDialog());
  }

  @override
  void dispose() {
    // 已保存会话菜单若仍打开：直接移除（State 销毁后无法再走收起动画）
    _sessionsMenuOverlay?.remove();
    _sessionsMenuOverlay = null;
    _sessionsMenuCurved?.dispose();
    _sessionsMenuCurved = null;
    _sessionsMenuController?.dispose();
    _sessionsMenuController = null;
    if (_scrollController.hasClients) {
      _persistentScrollOffset = _scrollController.offset;
    }
    WidgetsBinding.instance.removeObserver(this);
    _streamUpdateTick.removeListener(_handleStreamUpdateTick);
    StorageService.dataChangeListenable
        .removeListener(_handleStorageDataChanged);
    _cancelSlowResponseTimer();
    _cancelNoResponseTimer();
    final pendingSubscription = _streamSubscription;
    _streamSubscription = null;
    unawaited(pendingSubscription?.cancel());
    // 页面销毁：连同底层请求一起中断，避免回调继续写已销毁 State 的状态
    AIService.instance.abortActiveStreams(_aiRequestOwner);
    _messageController.removeListener(_onInputTextChanged);
    _messageController.dispose();
    _inputScrollController.removeListener(_updateInputEdgeFade);
    _inputScrollController.dispose();
    _inputEdgeFade.dispose();
    _headerReveal.dispose();
    _scrollController.dispose();
    _thinkingScrollController.dispose();
    _addMenuCurved?.dispose();
    _addMenuController?.dispose();
    _focusNode.dispose();
    _keyboardDismissAnimController.dispose();
    _keyboardLayoutNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // 使用粒度化的 MediaQuery 访问器：仅依赖 padding/viewPadding，不依赖 viewInsets，
    // 键盘弹出/收起时 viewInsets 变化不会触发主 build（消息列表不重建）。
    final topPadding = MediaQuery.paddingOf(context).top;
    final bottomPadding = MediaQuery.viewPaddingOf(context).bottom;

    // 尾部附加项（加载/流式/慢响应提示），每次主 build 构建一次
    final messageListTrailing = _buildMessageListTrailing();

    return ValueListenableBuilder<
        ({double layoutHeight, double bounceOffset, double rawHeight})>(
      valueListenable: _keyboardLayoutNotifier,
      builder: (context, kl, child) {
        // 键盘驱动的布局参数——仅在此 builder 内计算，不影响主 build
        final mq = MediaQuery.of(context);
        final maxKeyboardHeight = mq.size.height * 0.8;
        final kb = kl.layoutHeight.clamp(0.0, maxKeyboardHeight);
        final double pageBottomInset = kb;
        // 静止底距 = 系统底边距 + 悬浮导航栏块高（15 外边距 + 64 栏体，
        // 见 HomeScreen.navBarBlockHeight）+ 固定呼吸间距 8：原魔法数 100
        // 未含系统底边距，手势条/三键导航机型会与导航栏部分重合。
        // 键盘弹出（kb ≥ base−8）时自动落回 8dp，行为不变
        final double inputBaseBottom =
            bottomPadding + HomeScreen.navBarBlockHeight + 8;
        final double inputBottomPosition = max(8.0, inputBaseBottom - kb);
        final double inputBounceOffset = kl.bounceOffset * 2.2;
        final double inputBottomWithBounce =
            max(0.0, inputBottomPosition - inputBounceOffset);
        // 列表底部避让 = 输入框底距 + 输入区实测总高度 + 呼吸间隙。
        // 高度为 post-frame 实测（SizeChangedLayoutNotification 驱动），
        // 多行增长/图片预览/字体缩放自动跟随，无需估算
        final double listBottomPadding =
            inputBottomPosition + _inputAreaHeight + 8;

        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness:
                Theme.of(context).brightness == Brightness.dark
                    ? Brightness.light
                    : Brightness.dark,
            statusBarBrightness: Theme.of(context).brightness,
            systemNavigationBarColor: Colors.transparent,
            systemNavigationBarIconBrightness:
                Theme.of(context).brightness == Brightness.dark
                    ? Brightness.light
                    : Brightness.dark,
          ),
          child: Scaffold(
            backgroundColor: Theme.of(context).brightness == Brightness.dark
                ? AppPalette.dark.scaffold
                : const Color(0xFFF8F9FC),
            resizeToAvoidBottomInset: false,
            extendBody: true,
            body: Stack(
              children: [
                MediaQuery(
                  data: mq.copyWith(viewInsets: EdgeInsets.zero),
                  child: Padding(
                    padding: EdgeInsets.only(bottom: pageBottomInset),
                    child: GestureDetector(
                      onTap: _closeAddMenu,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: RawScrollbar(
                              controller: _scrollController,
                              // 指示条不伸进标题栏背后：顶点=模糊起始线
                              // （标题栏底缘 topPadding+56）；四角圆润
                              padding: EdgeInsets.only(top: topPadding + 62),
                              radius: const Radius.circular(4),
                              thickness: 4,
                              thumbColor: AppColors.of(context)
                                  .textTertiary
                                  .withValues(alpha: 0.6),
                              child: NotificationListener<ScrollNotification>(
                                onNotification:
                                    _handleMessageListScrollNotification,
                                child: CustomScrollView(
                                  controller: _scrollController,
                                  // 拖动消息列表时自动收起键盘：对话页输入框是
                                  // Positioned 浮层、不在本滚动区内，但 onDrag 只看
                                  // 拖拽是否起于字段的 TextFieldTapRegion，所以照样
                                  // 生效（同 shiguang_school_select_screen 的搜索条）。
                                  // 不设的话默认 none，点过输入框后滚列表焦点会赖着不走
                                  keyboardDismissBehavior:
                                      ScrollViewKeyboardDismissBehavior
                                          .onDrag,
                                  physics: const BouncingScrollPhysics(
                                      parent: AlwaysScrollableScrollPhysics()),
                                  slivers: [
                                    SliverPadding(
                                      padding:
                                          EdgeInsets.only(top: topPadding + 62),
                                    ),
                                    SliverPadding(
                                      padding: EdgeInsets.fromLTRB(
                                          16,
                                          0,
                                          16,
                                          _isEmptyWelcomeState
                                              ? 0
                                              : listBottomPadding),
                                      sliver: _isEmptyWelcomeState
                                          ? _buildWelcomeSliver(listBottomPadding)
                                          : child!,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          _buildPinnedHeader(topPadding),
                          _buildInputArea(inputBottomWithBounce),
                          if (_supportsImageUpload)
                            Positioned(
                              left: 16,
                              bottom: inputBottomWithBounce + 58,
                              child: IgnorePointer(
                                ignoring: !_showAddMenu,
                                // 弹出动画逐帧驱动（对齐三点菜单 _MenuPopTransition）：
                                // 透明度 + 自下方 14px 向上滑入 + 0.85→1 自底部缩放。
                                // 未创建控制器（从未点开过）时按收起态渲染，纯透明不可见
                                child: AnimatedBuilder(
                                  animation: _addMenuCurved ??
                                      kAlwaysDismissedAnimation,
                                  builder: (context, child) {
                                    final t = _addMenuCurved?.value ?? 0.0;
                                    return Opacity(
                                      opacity: t.clamp(0.0, 1.0),
                                      child: Transform.translate(
                                        offset: Offset(0, 14 * (1 - t)),
                                        child: Transform.scale(
                                          scale: 0.85 + 0.15 * t,
                                          alignment: Alignment.bottomCenter,
                                          child: child,
                                        ),
                                      ),
                                    );
                                  },
                                  child: Material(
                                    color: Colors.transparent,
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(16),
                                        boxShadow: [
                                          BoxShadow(
                                            color: Colors.black
                                                .withValues(alpha: 0.15),
                                            blurRadius: 12,
                                            offset: const Offset(0, 4),
                                          ),
                                        ],
                                      ),
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(16),
                                        child: BackdropFilter(
                                          filter: ImageFilter.blur(
                                              sigmaX: 15, sigmaY: 15),
                                          child: Container(
                                            // 样式对齐统一三点菜单（_blurredMenuShell）：
                                            // 宽 160、边框 0.5 白 alpha0.5、无分割线、
                                            // 镂空风格图标；弹出动画保持不变
                                            width: 160,
                                            decoration: BoxDecoration(
                                              color: AppColors.of(context)
                                                  .glassShell
                                                  .withValues(
                                                      alpha: Theme.of(context)
                                                                  .brightness ==
                                                              Brightness.dark
                                                          ? 0.75
                                                          : 0.7),
                                              borderRadius:
                                                  BorderRadius.circular(16),
                                              border: Border.all(
                                                  color: AppColors.of(context)
                                                      .glassBorder,
                                                  width: 0.5),
                                            ),
                                            child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                SizedBox(
                                                  width: double.infinity,
                                                  child: _buildMenuItem(
                                                    icon: Icons
                                                        .camera_alt_outlined,
                                                    label: '拍照',
                                                    onTap: () =>
                                                        _handleMenuSelection(
                                                            'camera'),
                                                    borderRadius:
                                                        const BorderRadius
                                                            .vertical(
                                                            top:
                                                                Radius.circular(
                                                                    16)),
                                                  ),
                                                ),
                                                SizedBox(
                                                  width: double.infinity,
                                                  child: _buildMenuItem(
                                                    icon: Icons
                                                        .photo_library_outlined,
                                                    label: '相册',
                                                    onTap: () =>
                                                        _handleMenuSelection(
                                                            'gallery'),
                                                    borderRadius:
                                                        const BorderRadius
                                                            .vertical(
                                                            bottom:
                                                                Radius.circular(
                                                                    16)),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: bottomPadding + 2,
                  child: IgnorePointer(
                    child: Center(
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 180),
                        opacity: kl.rawHeight > 1 ? 0.0 : 1.0,
                        child: Text(
                          '内容由AI生成',
                          style: TextStyle(
                            fontSize: 9,
                            color: AppColors.of(context).textTertiary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
      // 空会话的主体已改由 _buildWelcomeSliver 顶替，这里只剩消息列表
      child: SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            // 历史消息：按下标懒加载，每条用 RepaintBoundary 隔离重绘
            final msgCount = _messages.length;
            if (index < msgCount) {
              final bubble = RepaintBoundary(
                child: _buildMessageBubble(_messages[index], index),
              );
              // 开启自动课表分析时欢迎的是 AI 气泡而不是空态欢迎页，
              // 建议按钮跟着挂到气泡下面；真正开始对话后撤掉，
              // 免得长会话里翻回顶部还钉着一排"怎么开始"
              if (_messages[index].isWelcome && !_hasRealConversation) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    bubble,
                    _buildWelcomeSuggestions(AppColors.of(context)),
                  ],
                );
              }
              return bubble;
            }
            // 尾部附加项：加载指示/流式气泡/慢响应提示
            final tIndex = index - msgCount;
            return tIndex < messageListTrailing.length
                ? messageListTrailing[tIndex]
                : null;
          },
          childCount: _messages.length + messageListTrailing.length,
        ),
      ),
    );
  }

  Widget _buildSlowResponseTip() {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Flexible(
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF4A90E2).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: const Color(0xFF4A90E2).withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.tips_and_updates_outlined,
                    color: Color(0xFF4A90E2),
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: GestureDetector(
                      onTap: _navigateToSettings,
                      child: const Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: '响应较慢？可前往 ',
                              style: TextStyle(
                                color: Color(0xFF4A90E2),
                                fontSize: 14,
                              ),
                            ),
                            TextSpan(
                              text: '"设置"',
                              style: TextStyle(
                                color: Color(0xFF4A90E2),
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            TextSpan(
                              text: ' → ',
                              style: TextStyle(
                                color: Color(0xFF4A90E2),
                                fontSize: 14,
                              ),
                            ),
                            TextSpan(
                              text: '"开启快速响应"',
                              style: TextStyle(
                                color: Color(0xFF4A90E2),
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            TextSpan(
                              text: ' 提高模型响应速度',
                              style: TextStyle(
                                color: Color(0xFF4A90E2),
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPinnedHeader(double topPadding) {
    // 无界渐变标题栏（同设置页）；标题行保留原「会话标题 + 模型徽章 +
    // 三点菜单」结构，经 titleRow 传入
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      child: GradientBlurHeader(
        topPadding: topPadding,
        title: '课表助手',
        // 雾面曲线整体下移 6px（绘制区不越出标题栏，减弱模式同样
        // 生效）：同高度浓度=原上移 6px 处，标题下方一行可读性↑
        blurCurveShift: 6,
        // 标题栏本体增高 6px：内容区起始位置随之下移（列表顶部偏移
        // 已同步 +6），底部坡面多出 6px 渐变空间
        layoutBottomExtend: 6,
        titleRow: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  // 会话标题生成后与默认文案"课表助手"模糊交叉切换
                  // （动画参考设置页邮箱登录/注册副标题切换）
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    switchInCurve: Curves.easeOut,
                    switchOutCurve: Curves.easeIn,
                    // 左对齐布局：新旧标题交叉过渡时不偏离原左侧位置
                    layoutBuilder: (currentChild, previousChildren) => Stack(
                      alignment: Alignment.centerLeft,
                      children: [
                        ...previousChildren,
                        if (currentChild != null) currentChild,
                      ],
                    ),
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: AnimatedBuilder(
                        animation: animation,
                        builder: (context, grandChild) => ImageFiltered(
                          imageFilter: ImageFilter.blur(
                            sigmaX: 6 * (1.0 - animation.value),
                            sigmaY: 6 * (1.0 - animation.value),
                          ),
                          child: Transform.scale(
                            scale: 0.92 + 0.08 * animation.value,
                            child: grandChild,
                          ),
                        ),
                        child: child,
                      ),
                    ),
                    child: Text(
                      _chatTitle ?? '课表助手',
                      key: ValueKey<String>(_chatTitle ?? '课表助手'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: AppColors.of(context).textPrimary,
                      ),
                    ),
                  ),
                ),
                if (_aiEnabled) ...[
                  if (_fastModeEnabled)
                    FloatingGlassPill(
                      margin: const EdgeInsets.only(right: 8),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      tint: Colors.green.withValues(alpha: 0.15),
                      child: const Text(
                        '快速',
                        style: TextStyle(
                          color: Colors.green,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  if (_selectedModel != null)
                    _currentProvider == 'hunyuan' || _currentProvider == 'glm'
                        ? FloatingGlassPill(
                            // 与 ⋮ 共用同一条浮现进度：贴顶时保留原来的纯色
                            // 底（只没有描边/提亮/投影），下滑后浮出玻璃壳
                            reveal: _headerReveal,
                            showTintAtRest: true,
                            // 原 borderWeak 是实色灰，直接当着色会把玻璃壳
                            // 糊死；换成同为实色的 surfaceAlt 并压到 55%，
                            // 浅色下两档灰几乎同色，深色下仍能比壳亮一档
                            tint: AppColors.of(context)
                                .surfaceAlt
                                .withValues(alpha: 0.55),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  _selectedModel!,
                                  style: TextStyle(
                                    color: AppColors.of(context).textSecondary,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          )
                        : FloatingGlassPill(
                            // 与 ⋮ 共用同一条浮现进度（贴顶时保留原来的蓝色
                            // 纯色底，只是没有描边/提亮/投影）
                            reveal: _headerReveal,
                            showTintAtRest: true,
                            // 锚点 key 挂在胶囊整体上：showBlurredMenu 取
                            // currentContext 的 RenderBox 定位，壳与内层
                            // Row 同盒，菜单位置不变
                            key: _builtinBadgeKey,
                            onTap: _currentProvider == 'custom'
                                ? _showCustomAIConfig
                                : (_currentProvider == 'agnes'
                                    ? _showAgnesAIConfig
                                    : (_currentProvider == 'builtin'
                                        ? _showBuiltinNodeMenu
                                        : _showModelSelector)),
                            tint: const Color(0xFF4A90E2)
                                .withValues(alpha: 0.15),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  _selectedModel!,
                                  style: TextStyle(
                                    color: Color(0xFF4A90E2),
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                const Icon(
                                  Icons.arrow_drop_down,
                                  color: Color(0xFF4A90E2),
                                  size: 16,
                                ),
                              ],
                            ),
                          ),
                  BlurredPopupMenuButton<String>(
                    // 圆盘本身不接管点击（菜单由外层按钮弹出），所以
                    // 关掉"onTap 为空即淡出"，并去掉自带的 8px 内边距，
                    // 让圆盘正好等于点击区；左侧 8px 是与模型徽章的间距
                    // （放在壳外，不算点击区）。
                    iconPadding: EdgeInsets.zero,
                    icon: FloatingGlassButton(
                      dimWhenDisabled: false,
                      // 这颗没有 onTap（点击在外层），按压放大按默认判据会
                      // 被当成"不可点"而关掉，所以显式打开
                      growOnPress: true,
                      reveal: _headerReveal,
                      margin: const EdgeInsets.only(left: 8),
                      child: Icon(Icons.more_vert,
                          size: 22,
                          color: AppColors.of(context).textSecondary),
                    ),
                    menuWidth: 170,
                    items: [
                      const BlurredPopupMenuItem(
                        value: 'clear',
                        icon: Icons.delete_outline,
                        label: '清空当前对话',
                        iconColor: Color(0xFF4A90E2),
                      ),
                      // 已关联保存会话（自动实时同步中）时手动保存无意义；
                      // 首次保存完成后菜单项立即变为"已自动保存"
                      if (_currentSavedSessionId == null)
                        const BlurredPopupMenuItem(
                          value: 'save',
                          icon: Icons.bookmark_add_outlined,
                          label: '保存本次对话',
                          iconColor: Color(0xFF4A90E2),
                        )
                      else
                        BlurredPopupMenuItem(
                          value: 'autosave',
                          icon: Icons.bookmark,
                          label: '已自动保存',
                          iconColor: AppColors.of(context).textSecondary,
                          textColor: AppColors.of(context).textSecondary,
                        ),
                      BlurredPopupMenuItem(
                        value: 'history',
                        icon: Icons.history,
                        label: '已保存的会话',
                        iconColor: Color(0xFF4A90E2),
                      ),
                    ],
                    onSelected: (value) {
                      switch (value) {
                        case 'clear':
                          HapticFeedback.selectionClick();
                          _clearChat();
                          toastNotification.show(context, '已清空当前对话');
                          break;
                        case 'save':
                          _saveCurrentChat();
                          break;
                        case 'history':
                          _showSavedSessionsMenu();
                          break;
                        // 'autosave'：自动同步进行中，点击无操作
                      }
                    },
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 空会话时的消息区主体：整块在"标题栏之下、输入框之上"的真实可见区里
  /// 垂直居中，且只垂直不水平（Column 宽度由最宽的一行决定，横向一起居中
  /// 会把整块推右）。
  ///
  /// 不能用 `SliverFillRemaining`：它算的是 `视口 − 前置 sliver`，
  /// 不减外层 `SliverPadding` 的底部避让量，于是本 sliver 的 scrollExtent
  /// 比视口正好多出 `listBottomPadding`，分析完成后那次 `_scrollToBottom()`
  /// 会把居中的欢迎块整体上推同样的距离——表现就是上留白为 0、空白全堆在底部。
  /// 这里改成用 `SliverLayoutBuilder` 拿到剩余高度、自己减掉底部避让后定高。
  ///
  /// 定高只能用 `minHeight`，不能用 `SizedBox(height:)`：内容（问候+最多 4 行
  /// 课程+问话+三枚按钮）比可见区高时，紧高度会把内容压扁裁切（黄色溢出条），
  /// 而且 sliver 的 scrollExtent 会小于视口、`maxScrollExtent` 变负，
  /// `AlwaysScrollableScrollPhysics` 却照样允许下拉，于是拖出一段没内容的
  /// 区域再弹回。harness 实测：有空间时两者都正好居中，内容 560 > 可见 368 时
  /// 紧高度压成 368、`minHeight` 长到 560 并从顶部铺开。
  Widget _buildWelcomeSliver(double bottomPadding) {
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final visible = constraints.remainingPaintExtent - bottomPadding;
        return SliverToBoxAdapter(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: visible > 0 ? visible : 0),
            child: Center(
              child: SizedBox(
                width: double.infinity,
                child: _buildWelcomeCard(),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildWelcomeCard() {
    if (!_aiEnabled) {
      return Container(
        margin: const EdgeInsets.only(bottom: 12),
        child: Row(
          children: [
            Flexible(
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.bannerBg(context, Colors.orange),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: AppColors.bannerBorder(context, Colors.orange),
                    width: 1.5,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: AppColors.bannerChip(context, Colors.orange),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            Icons.info_outline,
                            color: AppColors.bannerText(context, Colors.orange),
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          'AI 功能未开启',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: AppColors.bannerText(context, Colors.orange),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '请前往"设置" → "AI 功能"开启后使用AI助手。',
                      style: TextStyle(
                        fontSize: 14,
                        color: AppColors.bannerText(context, Colors.orange),
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextButton.icon(
                      onPressed: _navigateToSettings,
                      icon: const Icon(Icons.settings, size: 18),
                      label: const Text('前往设置'),
                      style: TextButton.styleFrom(
                        foregroundColor:
                            AppColors.bannerText(context, Colors.orange),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    final content = _welcomeContent();
    final colors = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 第一行：按时段的大号问候
          Text(
            content.greeting,
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              height: 1.25,
              color: colors.textPrimary,
            ),
          ),
          if (content.sectionTitle != null) ...[
            const SizedBox(height: 20),
            // 课程与时间属于事实，不随机
            Text(
              content.sectionTitle!,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: colors.textSecondary,
              ),
            ),
            for (final line in content.courseLines)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  line,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.4,
                    color: colors.textSecondary,
                  ),
                ),
              ),
            if (content.moreCoursesHint != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  content.moreCoursesHint!,
                  style: TextStyle(
                    fontSize: 13,
                    color: colors.textTertiary,
                  ),
                ),
              ),
          ] else if (content.statusLine != null) ...[
            const SizedBox(height: 20),
            Text(
              content.statusLine!,
              style: TextStyle(
                fontSize: 14,
                height: 1.5,
                color: colors.textSecondary,
              ),
            ),
          ],
          const SizedBox(height: 28),
          Text(
            content.question,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: colors.textPrimary,
            ),
          ),
          _buildWelcomeSuggestions(colors),
        ],
      ),
    );
  }

  /// 三枚建议按钮。空态欢迎页和 AI 生成的欢迎气泡共用这一份，
  /// 保证两种入口下的建议内容与排布完全一致
  Widget _buildWelcomeSuggestions(AppPalette colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 20),
        for (final suggestion in _welcomeContent().suggestions)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _buildWelcomeSuggestionButton(suggestion, colors),
          ),
      ],
    );
  }

  /// 建议按钮：浅灰胶囊，**宽度随标题字数自适应**（左缘对齐，右端收在字后），
  /// 高度固定 38。标题过长时靠 ellipsis 截断，不会撑破消息区宽度
  Widget _buildWelcomeSuggestionButton(
    _WelcomeSuggestion suggestion,
    AppPalette colors,
  ) {
    return Material(
      color: colors.surfaceAlt,
      borderRadius: BorderRadius.circular(19),
      child: InkWell(
        borderRadius: BorderRadius.circular(19),
        onTap: () => _useWelcomeSuggestion(suggestion),
        child: Padding(
          // 不能用 Container(alignment:)：那会让盒子撑满传入约束，
          // 胶囊就永远占满整行。这里靠内边距撑出高度，宽度自然贴着文字
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          child: Text(
            suggestion.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: colors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }

  /// 点建议按钮：把 prompt 填进输入框。[needsInput] 的条目句子里还留着
  /// "____" 要用户自己补，所以只填入并聚焦；其余直接发出去。
  /// 发送后 _messages 非空，欢迎页自然让位给对话，不用额外收尾
  void _useWelcomeSuggestion(_WelcomeSuggestion suggestion) {
    HapticFeedback.selectionClick();
    _messageController.text = suggestion.prompt;
    _messageController.selection = TextSelection.collapsed(
      offset: suggestion.prompt.length,
    );
    if (suggestion.needsInput) {
      _focusNode.requestFocus();
      return;
    }
    _sendMessage();
  }

  /// 空会话且没有任何在途输出——此时消息区让位给默认欢迎页
  bool get _isEmptyWelcomeState =>
      _messages.isEmpty &&
      _streamingContent.isEmpty &&
      !_isFirstChunkReceived &&
      !_isAnalyzing;

  /// 课程行最多列这么多，超出的折成一行"……还有 N 节"
  static const int _welcomeMaxCourseLines = 4;

  /// 建议按钮的坑位数（宽度已改为随标题字数自适应，这里只管数量）
  static const int _welcomeSuggestionSlots = 3;

  /// 时段问候：每档备多套，进一次页面随机取一句。
  /// 23–4 点归"夜深了"，其余按常见作息切档。
  ///
  /// "忙了一天"这类说法预设了今天有课要上，假期和开学前不合语境，
  /// 所以只有 [inSemester] 为真时才放进候选池
  static List<String> _welcomeGreetingForHour(
    int hour, {
    required bool inSemester,
  }) {
    if (hour >= 23 || hour < 5) {
      return const [
        '夜深了，还不想休息吗',
        '这么晚还没睡呀',
        '夜已经深了，还不打算休息吗',
      ];
    }
    if (hour < 8) return const ['早上好', '早安', '早上好呀'];
    if (hour < 11) return const ['上午好', '上午好呀', '新的一天，上午好'];
    if (hour < 14) return const ['中午好', '午安', '中午好，记得吃饭'];
    if (hour < 18) return const ['下午好', '下午好呀', '有点困了吧，下午好'];
    if (!inSemester) return const ['晚上好', '晚上好呀'];
    return const ['晚上好', '晚上好呀', '忙了一天，辛苦了~'];
  }

  static const List<String> _welcomeQuestionCopy = [
    '有什么可以帮到你的吗？😊',
    '有什么想问的吗？😊',
    '今天想聊点什么？😊',
    '需要我帮点什么忙吗？😊',
  ];

  static const List<String> _welcomeHolidayCopy = [
    '当前处于假期状态，尽情享受休息时光~',
    '现在正在放假，好好放松一下吧~',
    '假期进行中，先把闹钟关掉睡个够~',
  ];

  /// 学期开始前（下学期还没开学）——系统里也算假期，但语义是"该准备了"
  static const List<String> _welcomeBeforeSemesterCopy = [
    '还没开学，先把新学期课表导进来、作息调回来吧',
    '开学倒计时，新课表准备好了吗？',
    '下学期就快开始了，趁这几天把教材和课表理顺一下~',
  ];

  static const List<String> _welcomeNoClassCopy = [
    '今明两天都没课，好好休息一下吧',
    '今明两天都没有课，安心睡个懒觉吧',
    '这两天没课，出去走走放松一下~',
  ];

  /// 欢迎页文案签名：时段、学期状态、课表与课程数任一变化就重算一次。
  /// 随机文案必须按签名缓存，否则每次 rebuild 都会换字。
  String _welcomeSignatureNow() {
    final now = DateTime.now();
    return [
      now.year,
      now.month,
      now.day,
      now.hour,
      StorageService.isBeforeSemesterStart(),
      StorageService.isHoliday(),
      StorageService.currentTimetableId,
      StorageService.getCourses().length,
    ].join('|');
  }

  _WelcomeContent _welcomeContent() {
    final signature = _welcomeSignatureNow();
    final cached = _welcomeCache;
    if (cached != null && _welcomeSignature == signature) return cached;
    final content = _computeWelcomeContent();
    _welcomeSignature = signature;
    _welcomeCache = content;
    return content;
  }

  _WelcomeContent _computeWelcomeContent() {
    final now = DateTime.now();
    final random = Random();
    String pick(List<String> pool) => pool[random.nextInt(pool.length)];

    final courses = StorageService.getCourses();
    final timeSlots = StorageService.getTimeSlots();
    // 开学前也要算"不在学期内"：isHoliday() 本就包含它，但分支要分开判
    final beforeSemester = StorageService.isBeforeSemesterStart();
    final inSemester = !beforeSemester && !StorageService.isHoliday();

    String? sectionTitle;
    String? statusLine;
    List<Course> listed = const [];
    String? more;

    // 开学前准备：isHoliday() 把学期开始前也算作假期，这里先拆出来单独配文案
    if (beforeSemester) {
      statusLine = pick(_welcomeBeforeSemesterCopy);
    } else if (!inSemester) {
      statusLine = pick(_welcomeHolidayCopy);
    } else {
      final remaining = _getTodayCourses(courses)
          .where((c) => _courseEndsAfter(c, timeSlots, now))
          .toList();
      if (remaining.isNotEmpty) {
        sectionTitle = '今天剩余课程安排：';
        listed = remaining;
      } else {
        final tomorrow = _getTomorrowCourses(courses)
          ..sort((a, b) => a.time.compareTo(b.time));
        if (tomorrow.isNotEmpty) {
          sectionTitle = '明天课程安排：';
          listed = tomorrow;
        } else {
          statusLine = pick(_welcomeNoClassCopy);
        }
      }
      if (listed.length > _welcomeMaxCourseLines) {
        more = '……还有 ${listed.length - _welcomeMaxCourseLines} 节';
        listed = listed.sublist(0, _welcomeMaxCourseLines);
      }
    }

    return _WelcomeContent(
      greeting: pick(_welcomeGreetingForHour(now.hour, inSemester: inSemester)),
      question: pick(_welcomeQuestionCopy),
      suggestions: _pickWelcomeSuggestions(
        random: random,
        inSemester: inSemester,
        beforeSemester: beforeSemester,
      ),
      sectionTitle: sectionTitle,
      courseLines: [for (final c in listed) _welcomeCourseLine(c, timeSlots)],
      moreCoursesHint: more,
      statusLine: statusLine,
    );
  }

  /// 三枚建议按钮的选取规则：学期中给「数据感知 + 分析 + 引导」各一条，
  /// 三种意图都覆盖到；假期和开学前把第一条换成专属池。
  ///
  /// 带 {course} / {task} 的条目必须先能换成真实名字才进候选，
  /// 课表或任务为空时自动跳过该条、退到同池里不依赖数据的那条；
  /// 整池都凑不出来再按 [_suggSelfIntro]、其余池子的顺序补位
  List<_WelcomeSuggestion> _pickWelcomeSuggestions({
    required Random random,
    required bool inSemester,
    required bool beforeSemester,
  }) {
    final courseNames = StorageService.getCourses()
        .map((c) => c.name.trim())
        .where((n) => n.isNotEmpty)
        .toSet()
        .toList();
    final taskNames = StorageService.getTasks()
        .where((t) => !t.completed)
        .map((t) => t.name.trim())
        .where((n) => n.isNotEmpty)
        .toSet()
        .toList();

    _WelcomeSuggestion? resolve(_WelcomeSuggestion s) {
      final needsCourse = s.prompt.contains('{course}');
      final needsTask = s.prompt.contains('{task}');
      if (!needsCourse && !needsTask) return s;
      if (needsCourse && courseNames.isEmpty) return null;
      if (needsTask && taskNames.isEmpty) return null;
      // 只替换这条 prompt 真正用到的 token。写成链式 replaceAll 会让
      // "只含 {course}"的条目也去索引 taskNames——没有未完成任务时
      // 就是 nextInt(0)，直接 RangeError 崩掉整个欢迎页
      var prompt = s.prompt;
      if (needsCourse) {
        prompt = prompt.replaceAll(
          '{course}',
          courseNames[random.nextInt(courseNames.length)],
        );
      }
      if (needsTask) {
        prompt = prompt.replaceAll(
          '{task}',
          taskNames[random.nextInt(taskNames.length)],
        );
      }
      return _WelcomeSuggestion(s.title, prompt, needsInput: s.needsInput);
    }

    _WelcomeSuggestion? takeOne(List<_WelcomeSuggestion> pool) {
      if (pool.isEmpty) return null;
      final start = random.nextInt(pool.length);
      for (var i = 0; i < pool.length; i++) {
        final resolved = resolve(pool[(start + i) % pool.length]);
        if (resolved != null) return resolved;
      }
      return null;
    }

    final hasCourses = courseNames.isNotEmpty;
    // 第三坑给「解答学习问题 + 你可以帮我做些什么」合并池：六个维度里前四
    // 个已由前两坑覆盖，合并才不会让答疑类永远只能当补位
    final askSlot = [..._suggSelfIntro, ..._suggStudyQa];
    final slots = <List<_WelcomeSuggestion>>[
      if (beforeSemester)
        _suggBeforeSemester
      else if (!inSemester)
        _suggHoliday
      else
        hasCourses ? _suggCourseManage : _suggTaskManage,
      if (beforeSemester)
        _suggCourseManage
      else if (!inSemester)
        _suggTaskAnalyze
      else
        hasCourses ? _suggCourseAnalyze : _suggTaskAnalyze,
      askSlot,
    ];

    final picked = <_WelcomeSuggestion>[];
    final usedTitles = <String>{};
    for (final pool in [...slots, _suggSelfIntro, ..._suggFallbackPools]) {
      if (picked.length >= _welcomeSuggestionSlots) break;
      final candidate = takeOne(
        // 同一条不重复占两个坑
        pool.where((s) => !usedTitles.contains(s.title)).toList(),
      );
      if (candidate == null) continue;
      picked.add(candidate);
      usedTitles.add(candidate.title);
    }
    return picked;
  }

  static const List<List<_WelcomeSuggestion>> _suggFallbackPools = [
    _suggTaskManage,
    _suggCourseManage,
    _suggCourseAnalyze,
    _suggTaskAnalyze,
    _suggStudyQa,
  ];

  /// 该课程所在节次的结束时间是否还没过（今天上完的课不再列进"剩余"）
  bool _courseEndsAfter(
    Course course,
    List<Map<String, String>> timeSlots,
    DateTime now,
  ) {
    if (timeSlots.isEmpty) return true;
    final endIndex = course.time + course.duration - 1;
    if (endIndex < 0 || endIndex >= timeSlots.length) return true;
    final endAt = _parseTime(timeSlots[endIndex]['end']!, now);
    return now.isBefore(endAt);
  }

  /// 一行课程：xx:xx - xx:xx 课程名 老师 地点。
  /// 老师名后不补"老师"二字（直接用课表里存的姓名），该字段为空时整段省略
  String _welcomeCourseLine(
    Course course,
    List<Map<String, String>> timeSlots,
  ) {
    var timeStr = _getCourseTimeStr(course, timeSlots);
    // 有节次表时是 "08:00-09:40"，读起来太挤；退化成"第1-2节"时不动
    if (timeStr.contains(':')) timeStr = timeStr.replaceAll('-', ' - ');
    final teacher = course.teacher?.trim() ?? '';
    final location = course.location?.trim();
    final locationPart =
        (location == null || location.isEmpty) ? '地点待定' : location;
    return [timeStr, course.name, if (teacher.isNotEmpty) teacher, locationPart]
        .join(' ');
  }

  /// 对话消息列表尾部的附加项：加载指示/流式气泡/慢响应提示
  List<Widget> _buildMessageListTrailing() {
    final trailing = <Widget>[];
    if (_isSearching) {
      trailing.add(_buildLoadingIndicator());
    } else if (_streamingContent.isNotEmpty || _thinkingContent.isNotEmpty) {
      // 流式气泡高频重绘，用 RepaintBoundary 隔离，避免牵连历史消息重绘
      trailing.add(RepaintBoundary(child: _buildStreamingBubble()));
    } else if (_isLoading || _isAnalyzing) {
      trailing.add(_buildLoadingIndicator());
    }
    if (_showSlowResponseTip && _shouldShowFastModeSlowTip) {
      trailing.add(_buildSlowResponseTip());
    }
    return trailing;
  }

  /// 长按消息气泡：在长按点弹出统一样式下拉菜单（glass_dialog.dart 的
  /// showBlurredMenu，与三点菜单/热力图筛选同款毛玻璃壳与动效）。
  /// 有文字的消息显示「复制+选取文字」，最后一条普通 AI 消息额外
  /// 显示「重新生成」。
  Future<void> _showMessageActionMenu(
      _ChatMessage message, int messageIndex, Offset globalPos) async {
    final isLast = _messages.isNotEmpty && identical(message, _messages.last);
    final isAssistant = message.role == 'assistant';
    final hasText = message.content.isNotEmpty;
    final canRegenerate =
        isAssistant && isLast && !_isLoading && !message.isWelcome;

    // 无任何可用选项（如非最后一条的纯图片消息）时直接返回
    if (!canRegenerate && !hasText) return;

    HapticFeedback.selectionClick();

    final result = await showBlurredMenu<int>(
      context: context,
      anchorGlobalPosition: globalPos,
      menuWidth: 140,
      items: [
        if (canRegenerate) _messageActionMenuItem(0, Icons.refresh, '重新生成'),
        if (hasText) _messageActionMenuItem(1, Icons.copy_outlined, '复制'),
        if (hasText) _messageActionMenuItem(2, null, '选取文字'),
      ],
    );
    if (result == null || !mounted) return;

    switch (result) {
      case 0:
        _regenerateLastMessage();
      case 1:
        Clipboard.setData(ClipboardData(text: message.content));
        toastNotification.show(context, '已复制');
      case 2:
        _enterSelectMode(messageIndex, globalPos);
    }
  }

  /// 气泡上的快速双击检测（手动计时，不用 DoubleTap 识别器——避免
  /// 它让气泡内所有单击都多等 300ms 的双击消歧）：两次抬起间隔
  /// 300ms 内且位移很近即视为双击，跳过菜单直接进选取模式
  int? _lastTapMessageIndex;
  DateTime? _lastTapTime;
  Offset? _lastTapPosition;

  void _handleBubbleTapUp(
      _ChatMessage message, int messageIndex, TapUpDetails details) {
    final now = DateTime.now();
    final bool isDoubleTap = _lastTapMessageIndex == messageIndex &&
        _lastTapTime != null &&
        _lastTapPosition != null &&
        now.difference(_lastTapTime!).inMilliseconds <= 300 &&
        (details.globalPosition - _lastTapPosition!).distance < 30;
    _lastTapMessageIndex = messageIndex;
    _lastTapTime = now;
    _lastTapPosition = details.globalPosition;
    if (!isDoubleTap) return;
    _lastTapMessageIndex = null;
    _lastTapTime = null;
    _lastTapPosition = null;
    if (message.content.isEmpty) return; // 纯图片等无可选文字
    HapticFeedback.selectionClick();
    _enterSelectMode(messageIndex, details.globalPosition);
  }

  /// 进入选取模式：该消息正文包上 SelectionArea，并自动选中
  /// 按住/双击位置所在的那一行（空白处就近）
  void _enterSelectMode(int messageIndex, Offset globalPos) {
    _safeSetState(() {
      _selectingMessageIndex = messageIndex;
      _selectingPressPosition = globalPos;
    });
  }

  /// 菜单项：图标 + 文字行（图标为 null 时用自绘旗标图标）
  DropdownMenuItem<int> _messageActionMenuItem(
      int value, IconData? icon, String label) {
    return DropdownMenuItem<int>(
      value: value,
      child: Row(
        children: [
          if (icon != null)
            Icon(icon, size: 18, color: AppColors.of(context).textPrimary)
          else
            _FlagSelectionIcon(
                size: 18, color: AppColors.of(context).textPrimary),
          const SizedBox(width: 10),
          Text(label, style: const TextStyle(fontSize: 14)),
        ],
      ),
    );
  }

  /// 流式输出/思考过程正文的选中菜单（原生选中行为 + 模糊样式工具栏）
  Widget _plainSelectionMenuBuilder(
      BuildContext context, SelectableRegionState selectableRegion) {
    return styledSelectableRegionContextMenu(context, selectableRegion);
  }

  /// 消息正文的稳定 GlobalKey：进入/退出选取模式会给正文换父级
  /// （包上/摘掉 SelectionArea），没有 GlobalKey 的话整棵正文子树会被
  /// 销毁重建——markdown 内表格的横向滚动位置、公式组件状态全部丢失
  /// （表现为闪烁后回到最左）。稳定 key 让框架走全球键重挂载，子树
  /// 状态完整保留
  final Map<_ChatMessage, GlobalKey> _messageBodyKeys = {};

  /// 消息正文包装：默认原样返回（长按交给气泡的 GestureDetector 弹
  /// 操作菜单）；该消息处于「选取文字」模式时包上 SelectionArea，
  /// 自动选中长按所在行，点工具栏按钮或选区清空后自动退出
  Widget _buildMessageBodyText({
    required _ChatMessage message,
    required int messageIndex,
    required Widget child,
  }) {
    // 稳定 key 恒定挂载（两种模式都在），保证换父级时子树可重挂载
    final Widget keyed =
        KeyedSubtree(key: _messageBodyKeys.putIfAbsent(message, () => GlobalKey()), child: child);
    if (_selectingMessageIndex != messageIndex) return keyed;
    return _MessageSelectionArea(
      pressPosition: _selectingPressPosition,
      onExit: () => _safeSetState(() {
        _selectingMessageIndex = null;
        _selectingPressPosition = null;
      }),
      scrollController: _scrollController,
      child: keyed,
    );
  }

  Widget _buildMessageBubble(_ChatMessage message, int messageIndex) {
    final isUser = message.role == 'user';
    final hasCourses = message.courses != null && message.courses!.isNotEmpty;

    // 长按气泡呼出操作菜单（复制 / 选取文字 / 重新生成）；快速双击
    // 文字则跳过菜单直接进选取模式并自动选中所在行。菜单先行：
    // 默认态正文不包 SelectionArea，长按/双击属于这里的 GestureDetector；
    // 进入「选取文字」模式后正文包上 SelectionArea，其识别器是子节点、
    // 在竞技场中先声明胜利，手势自动回归选择处理，互不冲突
    return GestureDetector(
      onLongPressStart: (details) {
        _showMessageActionMenu(message, messageIndex, details.globalPosition);
      },
      onTapUp: (details) => _handleBubbleTapUp(message, messageIndex, details),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        child: Row(
          mainAxisAlignment:
              isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Flexible(
              child: isUser &&
                      message.imagePath != null &&
                      message.content.isEmpty
                  ? GestureDetector(
                      onTap: () => _showImagePreview(message.imagePath!,
                          useHero: true,
                          messageIndex: messageIndex,
                          imageAspectRatio: message.imageAspectRatio),
                      child: Hero(
                        tag:
                            'image_preview_${messageIndex}_${message.imagePath}',
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
                              maxWidth: 200,
                              maxHeight: 300,
                            ),
                            child: Image.file(
                              File(message.imagePath!),
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),
                      ),
                    )
                  : Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: message.isError
                            ? (Theme.of(context).brightness == Brightness.dark
                                ? const Color(0xFF3A1A1C)
                                : Colors.red.shade50)
                            : (message.isWelcome
                                ? AppColors.of(context).surface
                                : (isUser
                                    ? const Color(0xFF4A90E2)
                                    : AppColors.of(context).surface)),
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: isUser
                            ? null
                            : [
                                BoxShadow(
                                  color: message.isWelcome
                                      ? const Color(0xFF4A90E2)
                                          .withValues(alpha: 0.12)
                                      : Colors.black.withValues(alpha: 0.05),
                                  blurRadius: message.isWelcome ? 16 : 10,
                                  spreadRadius: message.isWelcome ? 1 : 0,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                        border: message.isWelcome
                            ? Border.all(
                                color: const Color(0xFF4A90E2)
                                    .withValues(alpha: 0.25),
                                width: 1,
                              )
                            : null,
                      ),
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (message.imagePath != null) ...[
                                GestureDetector(
                                  onTap: () => _showImagePreview(
                                      message.imagePath!,
                                      useHero: true,
                                      messageIndex: messageIndex,
                                      imageAspectRatio:
                                          message.imageAspectRatio),
                                  child: Hero(
                                    tag:
                                        'image_preview_${messageIndex}_${message.imagePath}',
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: ConstrainedBox(
                                        constraints: const BoxConstraints(
                                          maxWidth: 200,
                                          maxHeight: 300,
                                        ),
                                        child: Image.file(
                                          File(message.imagePath!),
                                          fit: BoxFit.cover,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 8),
                              ],
                              if (hasCourses) ...[
                                _buildCourseListInBubble(
                                    message.courses!, message),
                                const SizedBox(height: 12),
                              ],
                              if (!isUser &&
                                  message.thinkingContent != null &&
                                  message.thinkingContent!.isNotEmpty) ...[
                                _buildSavedThinkingBubble(message),
                                const SizedBox(height: 12),
                              ],
                              if (isUser && message.content.isNotEmpty)
                                _buildMessageBodyText(
                                  message: message,
                                  messageIndex: messageIndex,
                                  child: Text(
                                    message.content,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                      height: 1.5,
                                    ),
                                  ),
                                )
                              else if (!isUser)
                                Container(
                                  constraints: BoxConstraints(
                                    maxWidth:
                                        MediaQuery.of(context).size.width * 0.8,
                                  ),
                                  child: _buildMessageBodyText(
                                    message: message,
                                    messageIndex: messageIndex,
                                    child: _buildMarkdownContent(
                                      context: context,
                                      message.content,
                                      style: TextStyle(
                                        fontSize: 14,
                                        height: 1.5,
                                        color: message.isError
                                            ? Colors.red
                                            : AppColors.of(context).textPrimary,
                                      ),
                                    ),
                                  ),
                                ),
                              if (message.isInterrupted) ...[
                                const SizedBox(height: 8),
                                Text(
                                  '(已中断)',
                                  style: TextStyle(
                                    color: isUser
                                        ? Colors.white.withValues(alpha: 0.7)
                                        : Colors.orange.shade600,
                                    fontSize: 10,
                                    fontStyle: FontStyle.italic,
                                  ),
                                ),
                              ],
                            ],
                          ),
                          // 重新生成按钮（欢迎消息右上角）：悬浮叠加在内容之上，
                          // 不占用布局空间（思考过程/正文不向下避让）；仅当课表
                          // 已切换（与当前课程分析基于的课表不同）时展示，
                          // 🔁 循环图标 + 极简配色（与 DDL 任务提示一致）
                          if (!isUser &&
                              message.isWelcome &&
                              _isTimetableMismatch)
                            Positioned(
                              top: 0,
                              right: 0,
                              child: GestureDetector(
                                onTap: _regenerateScheduleAnalysis,
                                child: Container(
                                  width: 28,
                                  height: 28,
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.05),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Icon(
                                    Icons.loop,
                                    size: 17,
                                    color: AppColors.of(context).textSecondary,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCourseListInBubble(List<Course> courses, _ChatMessage message) {
    final dayNames = ['', '周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    final messageIndex = _messages.indexOf(message);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.list_alt,
                size: 16, color: AppColors.of(context).textSecondary),
            const SizedBox(width: 6),
            Text(
              '识别到的课程 (${courses.length})',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.of(context).textSecondary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ...courses.asMap().entries.map((entry) {
          final course = entry.value;
          return Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.of(context).surfaceAlt,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.of(context).borderWeak),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        course.name,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.of(context).textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${dayNames[course.day]} 第${course.time}节',
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.of(context).textSecondary,
                        ),
                      ),
                      if (course.location != null || course.teacher != null)
                        Text(
                          [
                            if (course.location != null) course.location!,
                            if (course.teacher != null) course.teacher!,
                          ].join(' · '),
                          style: TextStyle(
                            fontSize: 11,
                            color: AppColors.of(context).textTertiary,
                          ),
                        ),
                      if (course.weeks != null && course.weeks!.isNotEmpty)
                        Text(
                          '周次: ${course.weeks}',
                          style: TextStyle(
                            fontSize: 11,
                            color: AppColors.of(context).textTertiary,
                          ),
                        ),
                    ],
                  ),
                ),
                BlurredPopupMenuButton<String>(
                  icon: Icon(Icons.more_vert,
                      size: 18, color: AppColors.of(context).textSecondary),
                  items: const [
                    BlurredPopupMenuItem(
                        value: 'edit',
                        icon: Icons.edit_outlined,
                        label: '编辑',
                        iconColor: Color(0xFF4A90E2)),
                    BlurredPopupMenuItem(
                        value: 'delete',
                        icon: Icons.delete_outline,
                        label: '删除',
                        iconColor: Colors.red,
                        textColor: Colors.red),
                  ],
                  onSelected: (value) {
                    if (value == 'edit') {
                      _editCourse(course, messageIndex);
                    } else if (value == 'delete') {
                      _deleteCourseFromMessage(course, messageIndex);
                    }
                  },
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  Widget _buildStreamingBubble() {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Flexible(
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.of(context).surface,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 思考过程嵌入在输出框内
                  if (_thinkingContent.isNotEmpty)
                    _buildThinkingContentBubble(),
                  if (_thinkingContent.isNotEmpty &&
                      _streamingContent.isNotEmpty)
                    const SizedBox(height: 12),
                  // 正文内容
                  if (_streamingContent.isNotEmpty)
                    SelectionArea(
                      contextMenuBuilder: _plainSelectionMenuBuilder,
                      child: _buildMarkdownContent(
                        context: context,
                        _streamingContent,
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.5,
                          color: AppColors.of(context).textPrimary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildThinkingContentBubble() {
    final isExpanded = !_isThinkingCollapsed;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.of(context).surfaceAlt,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.of(context).borderWeak),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () {
              setState(() {
                _isThinkingCollapsed = !_isThinkingCollapsed;
              });
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_isThinking && _streamingContent.isEmpty)
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.of(context).textTertiary,
                    ),
                  )
                else
                  Icon(
                    isExpanded ? Icons.expand_less : Icons.expand_more,
                    color: AppColors.of(context).textTertiary,
                    size: 18,
                  ),
                const SizedBox(width: 8),
                Text(
                  _isThinking && _streamingContent.isEmpty ? '思考中...' : '思考过程',
                  style: TextStyle(
                    color: AppColors.of(context).textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            child: isExpanded
                ? Column(
                    children: [
                      const SizedBox(height: 8),
                      Container(
                        constraints: const BoxConstraints(maxHeight: 150),
                        child: SingleChildScrollView(
                          controller: _thinkingScrollController,
                          child: SelectionArea(
                            contextMenuBuilder: _plainSelectionMenuBuilder,
                            child: _buildMarkdownContent(
                              context: context,
                              _thinkingContent,
                              style: TextStyle(
                                fontSize: 12,
                                height: 1.5,
                                color: AppColors.of(context).textPrimary,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingIndicator() {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Flexible(
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.of(context).surface,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.of(context).textSecondary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    _statusMessage.isNotEmpty
                        ? _statusMessage
                        : (_isAnalyzing ? '分析中...' : '思考中...'),
                    style: TextStyle(
                      color: AppColors.of(context).textSecondary,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSavedThinkingBubble(_ChatMessage message) {
    final isExpanded = !message.isThinkingCollapsed;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.of(context).surfaceAlt,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.of(context).borderWeak),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () {
              setState(() {
                message.isThinkingCollapsed = !message.isThinkingCollapsed;
              });
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isExpanded ? Icons.expand_less : Icons.expand_more,
                  color: AppColors.of(context).textTertiary,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Text(
                  '思考过程',
                  style: TextStyle(
                    color: AppColors.of(context).textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            child: isExpanded
                ? Column(
                    children: [
                      const SizedBox(height: 8),
                      Container(
                        constraints: const BoxConstraints(maxHeight: 120),
                        child: SingleChildScrollView(
                          child: SelectionArea(
                            contextMenuBuilder: _plainSelectionMenuBuilder,
                            child: _buildMarkdownContent(
                              context: context,
                              message.thinkingContent!,
                              style: TextStyle(
                                fontSize: 12,
                                height: 1.5,
                                color: AppColors.of(context).textPrimary,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _buildInputArea(double inputBottomPosition) {
    return Positioned(
      left: 16,
      right: 16,
      bottom: inputBottomPosition,
      // 输入区真实尺寸变化（换行增行、图片预览、字体缩放、AnimatedSize
      // 渐变逐帧等）统一由 SizeChangedLayoutNotification 送达，
      // post-frame 实测高度后驱动消息列表底部避让（见 _syncInputAreaHeight）
      child: NotificationListener<SizeChangedLayoutNotification>(
        onNotification: (_) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _syncInputAreaHeight();
          });
          return false;
        },
        child: SizeChangedLayoutNotifier(
          child: Stack(
            key: _inputAreaKey,
            clipBehavior: Clip.none,
            children: [
              // shadow must sit outside ClipRRect: clipping eats shadows drawn inside
              // (same thin shadow as home-screen bottom nav)
              DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(28),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
                      decoration: BoxDecoration(
                        color: AppColors.of(context).glassShell.withValues(
                            alpha:
                                Theme.of(context).brightness == Brightness.dark
                                    ? 0.55
                                    : 0.45),
                        borderRadius: BorderRadius.circular(28),
                        border: Border.all(
                          color: AppColors.of(context).glassBorder,
                          width: 1.5,
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AnimatedSize(
                            duration: const Duration(milliseconds: 250),
                            curve: Curves.easeInOut,
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 200),
                              transitionBuilder: (child, animation) {
                                return FadeTransition(
                                  opacity: animation,
                                  child: SizeTransition(
                                    sizeFactor: animation,
                                    axisAlignment: -1.0,
                                    child: child,
                                  ),
                                );
                              },
                              child: _selectedImagePath != null
                                  ? GestureDetector(
                                      key: const ValueKey('image_selected'),
                                      onTap: () => _showImagePreview(
                                          _selectedImagePath!,
                                          useHero: false,
                                          imageAspectRatio:
                                              _selectedImageAspectRatio),
                                      child: Container(
                                        margin:
                                            const EdgeInsets.only(bottom: 8),
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color:
                                              AppColors.of(context).surfaceAlt,
                                          borderRadius:
                                              BorderRadius.circular(12),
                                        ),
                                        child: Row(
                                          children: [
                                            Icon(Icons.image,
                                                size: 20,
                                                color: AppColors.of(context)
                                                    .textSecondary),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: Text(
                                                '已选择图片（点击预览）',
                                                style: TextStyle(
                                                  fontSize: 13,
                                                  color: AppColors.of(context)
                                                      .textSecondary,
                                                ),
                                              ),
                                            ),
                                            GestureDetector(
                                              onTap: _removeImage,
                                              child: Icon(Icons.close,
                                                  size: 18,
                                                  color: AppColors.of(context)
                                                      .textSecondary),
                                            ),
                                          ],
                                        ),
                                      ),
                                    )
                                  : const SizedBox.shrink(
                                      key: ValueKey('no_image')),
                            ),
                          ),
                          Row(
                            children: [
                              AnimatedSize(
                                duration: const Duration(milliseconds: 250),
                                curve: Curves.easeInOut,
                                clipBehavior: Clip.none,
                                child: AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 200),
                                  transitionBuilder: (child, animation) {
                                    return FadeTransition(
                                      opacity: animation,
                                      child: child,
                                    );
                                  },
                                  child: _supportsImageUpload
                                      ? Material(
                                          key: const ValueKey('add_button'),
                                          color: _showAddMenu
                                              ? const Color(0xFF4A90E2)
                                              : AppColors.of(context)
                                                  .borderWeak,
                                          borderRadius:
                                              BorderRadius.circular(20),
                                          child: InkWell(
                                            onTap: _toggleAddMenu,
                                            customBorder: const CircleBorder(),
                                            child: AnimatedRotation(
                                              turns: _showAddMenu ? 0.125 : 0,
                                              duration: const Duration(
                                                  milliseconds: 200),
                                              child: SizedBox(
                                                width: 40,
                                                height: 40,
                                                child: Icon(
                                                  Icons.add,
                                                  color: _showAddMenu
                                                      ? Colors.white
                                                      : AppColors.of(context)
                                                          .textSecondary,
                                                  size: 24,
                                                ),
                                              ),
                                            ),
                                          ),
                                        )
                                      : const SizedBox.shrink(
                                          key: ValueKey('no_add_button')),
                                ),
                              ),
                              AnimatedSize(
                                duration: const Duration(milliseconds: 250),
                                curve: Curves.easeInOut,
                                child: _supportsImageUpload
                                    ? const SizedBox(
                                        width: 8, key: ValueKey('spacing'))
                                    : const SizedBox.shrink(
                                        key: ValueKey('no_spacing')),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Padding(
                                  // 左内边距 4→2：文字起点再向 + 号靠拢一点（总间隙 16→10），
                                  // 保留最小呼吸感
                                  padding: const EdgeInsets.only(
                                      left: 2, right: 8, top: 10, bottom: 10),
                                  child: _buildFadingTextField(),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  onTap: () {
                                    HapticFeedback.selectionClick();
                                    if (_isLoading || _isAnalyzing) {
                                      _stopGeneration();
                                    } else {
                                      _sendMessage();
                                    }
                                  },
                                  borderRadius: BorderRadius.circular(20),
                                  child: Container(
                                    width: 40,
                                    height: 40,
                                    decoration: BoxDecoration(
                                      gradient: (_isLoading || _isAnalyzing)
                                          ? null
                                          : const LinearGradient(
                                              colors: [
                                                Color(0xFF4A90E2),
                                                Color(0xFF5BA0F2)
                                              ],
                                            ),
                                      color: (_isLoading || _isAnalyzing)
                                          ? Colors.red.shade400
                                          : null,
                                      borderRadius: BorderRadius.circular(20),
                                      boxShadow: [
                                        BoxShadow(
                                          color: (_isLoading || _isAnalyzing
                                                  ? Colors.red
                                                  : const Color(0xFF4A90E2))
                                              .withValues(alpha: 0.3),
                                          blurRadius: 8,
                                          offset: const Offset(0, 2),
                                        ),
                                      ],
                                    ),
                                    child: Icon(
                                      (_isLoading || _isAnalyzing)
                                          ? Icons.stop_rounded
                                          : Icons.send_rounded,
                                      color: Colors.white,
                                      size: 20,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 输入框（多行 + 内部滚动 + 上下边缘淡出）
  ///
  /// maxLines 由 4 提到 5：视口上下各多出约半行作为淡出缓冲——文字超出
  /// 显示区域内部滚动时，有剩余内容的一端在这半行内逐渐淡出（滚动到顶/
  /// 底时只淡出另一端），替代原来的生硬裁切；内容未超出时全不透明渐变，
  /// 视觉等价于无遮罩。淡出状态由 _updateInputEdgeFade 维护
  /// （ValueNotifier 仅重建遮罩子树，滚动逐帧不触发整页重建）。
  ///
  /// 结构必须恒定：无论是否需要淡出都返回同型 ShaderMask→TextField 链。
  /// 若按需切换返回类型（裸输入框 ↔ 遮罩包裹），内容 5↔6 行增减时会
  /// 销毁重建 EditableTextState → 输入连接断开 → 键盘被强制收起（实测）
  Widget _buildFadingTextField() {
    return AnimatedSize(
      // 输入/删行导致的框体高度变化平滑过渡（参数对齐图片预览区动画）。
      // 顶部对齐：增行时新行向下揭示、删行时底部平滑收起，光标贴随文字；
      // 溢出裁切由默认 hardEdge 承担。动画逐帧改变整体尺寸，实测避让
      // （SizeChangedLayoutNotification 驱动）随之逐帧同步，列表不跳变
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
      alignment: Alignment.topCenter,
      child: ValueListenableBuilder<({bool top, bool bottom})>(
        valueListenable: _inputEdgeFade,
        builder: (context, fade, child) {
          final halfLine =
              MediaQuery.textScalerOf(context).scale(15.0) * 1.4 / 2;
          return ShaderMask(
            shaderCallback: (bounds) {
              // 无淡出需求：全不透明渐变，保持树型稳定（见上注释）
              if (!fade.top && !fade.bottom) {
                return const LinearGradient(
                  colors: [Colors.white, Colors.white],
                ).createShader(bounds);
              }
              final h = bounds.height;
              final t = (halfLine / h).clamp(0.0, 0.45);
              return LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  fade.top ? Colors.transparent : Colors.white,
                  Colors.white,
                  Colors.white,
                  fade.bottom ? Colors.transparent : Colors.white,
                ],
                stops: [
                  0.0,
                  fade.top ? t : 0.0,
                  fade.bottom ? 1 - t : 1.0,
                  1.0,
                ],
              ).createShader(bounds);
            },
            blendMode: BlendMode.dstIn,
            child: child,
          );
        },
        child: AppTextField(
          contextMenuBuilder: styledEditableContextMenu,
          controller: _messageController,
          focusNode: _focusNode,
          scrollController: _inputScrollController,
          style: TextStyle(
            fontSize: 15,
            height: 1.4,
          ),
          decoration: InputDecoration(
            hintText: '输入消息...',
            hintStyle: TextStyle(
              color: AppColors.of(context).textTertiary,
              fontSize: 15,
            ),
            border: InputBorder.none,
            contentPadding: EdgeInsets.zero,
            isDense: true,
            filled: true,
            fillColor: Colors.transparent,
          ),
          maxLines: 5,
          minLines: 1,
          // iOS 式超出回弹：内容超出视口后划到顶/底可带惯性冲出边界再弹回
          // （默认 Clamping 到边硬停）。内容未超出时无可滚动范围，短文本
          // 不会被误拖动
          scrollPhysics: const BouncingScrollPhysics(),
          onSubmitted: (_) => _sendMessage(),
        ),
      ),
    );
  }

  void _editCourse(Course course, int messageIndex) {
    _unfocusBeforeDialog();
    CourseDialog.show(
      context: context,
      course: course,
      selectedDay: course.day,
      selectedPeriod: course.time,
    ).then((updatedCourse) {
      _unfocusAfterDialog();
      if (updatedCourse != null) {
        StorageService.updateCourse(updatedCourse);

        setState(() {
          final oldMessage = _messages[messageIndex];
          if (oldMessage.courses != null) {
            final updatedCourses = oldMessage.courses!.map((c) {
              if (c.id == course.id) return updatedCourse;
              return c;
            }).toList();
            _messages[messageIndex] = _ChatMessage(
              role: oldMessage.role,
              content: oldMessage.content,
              isError: oldMessage.isError,
              isInterrupted: oldMessage.isInterrupted,
              isWelcome: oldMessage.isWelcome,
              courses: updatedCourses,
            );
          }
        });
        _persistentMessages = List.from(_messages);
      }
    });
  }

  void _deleteCourseFromMessage(Course course, int messageIndex) {
    _unfocusBeforeDialog();
    showBouncyDialog(
      context: context,
      barrierLabel: '确认删除',
      shellPadding: const EdgeInsets.all(24),
      // 壳总宽约束含壳内边距（与旧版壳外 ConstrainedBox(constraints:) 一致）
      shellMaxWidth: 400,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '确认删除',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          const Text(
            '确定要删除这门课程吗？',
            style: TextStyle(fontSize: 15),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () {
                  StorageService.deleteCourse(course.id);
                  Navigator.pop(context);

                  setState(() {
                    final oldMessage = _messages[messageIndex];
                    if (oldMessage.courses != null) {
                      final updatedCourses = oldMessage.courses!
                          .where((c) => c.id != course.id)
                          .toList();
                      _messages[messageIndex] = _ChatMessage(
                        role: oldMessage.role,
                        content: oldMessage.content,
                        isError: oldMessage.isError,
                        isInterrupted: oldMessage.isInterrupted,
                        isWelcome: oldMessage.isWelcome,
                        courses: updatedCourses.isEmpty ? null : updatedCourses,
                      );
                    }
                  });
                  _persistentMessages = List.from(_messages);
                },
                child: const Text('删除', style: TextStyle(color: Colors.red)),
              ),
            ],
          ),
        ],
      ),
    ).then((_) => _unfocusAfterDialog());
  }
}

/// 欢迎页建议按钮。[title] 要短到能塞进胶囊，[prompt] 是点下去真正发出去的话。
///
/// [needsInput] 为 true 表示这句话里还留着要用户自己补的空（写成"____"），
/// 于是点击只把文字填进输入框并聚焦，不直接发送；否则直接发送。
///
/// prompt 里的 {course} / {task} 会在运行时换成课表与任务里的真实名字，
/// 换不到（课表为空等）时该条不进候选池——所以静态文案里不要出现
/// "我的高数课"这种写死的课程名。
class _WelcomeSuggestion {
  const _WelcomeSuggestion(this.title, this.prompt, {this.needsInput = false});

  final String title;
  final String prompt;
  final bool needsInput;
}

const List<_WelcomeSuggestion> _suggCourseManage = [
  _WelcomeSuggestion(
    '帮我把课表理一遍',
    '我的课表有点乱，帮我看看有没有时间冲突或者排得太挤的地方，缺什么直接问我',
  ),
  _WelcomeSuggestion(
    '加一门新课',
    '我要加一门课，你按我说的记：课程名、周几、第几节到第几节、上到第几周、老师和地点',
  ),
  _WelcomeSuggestion(
    '这门课要调时间',
    '《{course}》这学期要换个时间上，我告诉你新的星期和节次，帮我改过来',
    needsInput: true,
  ),
  _WelcomeSuggestion(
    '这门课结课了，删掉',
    '《{course}》这学期已经上完了，帮我从课表里删掉',
  ),
  _WelcomeSuggestion(
    '把空课时段标出来',
    '我这周哪些时间段是空的？列出来，方便我约自习和运动',
  ),
];

const List<_WelcomeSuggestion> _suggTaskManage = [
  _WelcomeSuggestion(
    '帮我记个作业',
    '帮我记一个《{course}》的作业，内容和截止时间我接着说',
    needsInput: true,
  ),
  _WelcomeSuggestion(
    '按紧急程度排一下',
    '把我所有没完成的任务按截止时间和优先级排个顺序，标出最急的三个',
  ),
  _WelcomeSuggestion(
    '这周末前要交哪些',
    '我这周末之前要交的东西有哪些？按天列出来',
  ),
  _WelcomeSuggestion(
    '这个任务做完了',
    '{task} 已经完成了，帮我删掉',
  ),
  _WelcomeSuggestion(
    '有没有已经拖了的',
    '我有没有已经逾期、或者三天内就要截止的任务？别给我留面子',
  ),
];

const List<_WelcomeSuggestion> _suggCourseAnalyze = [
  _WelcomeSuggestion(
    '我一周上多少节课',
    '统计一下我每周每天的课时分布，哪天最累、哪天最闲',
  ),
  _WelcomeSuggestion(
    '早八有几个',
    '我一周有几节课是第 1-2 节开始的？帮我判断要不要调作息',
  ),
  _WelcomeSuggestion(
    '课表哪里不合理',
    '分析我的课表安排，指出间隔太长、连堂太多、来回赶路不方便的点',
  ),
  _WelcomeSuggestion(
    '这学期什么时候结课',
    '我哪些课先结课、哪些课上到最后一周？给个时间线',
  ),
  _WelcomeSuggestion(
    '给这周排个自习计划',
    '结合我的空课时段和未完成任务，帮我排这周的自习安排，别太满',
  ),
];

const List<_WelcomeSuggestion> _suggTaskAnalyze = [
  _WelcomeSuggestion(
    '今晚先做哪个',
    '我现在最该先做哪个任务？给出理由，不要只按截止时间排',
  ),
  _WelcomeSuggestion(
    '这个作业帮我拆一下',
    '{task} 量比较大，帮我拆成几个能落地的小步骤',
  ),
  _WelcomeSuggestion(
    '按天摊开做进度表',
    '把我剩下的任务分摊到每天，做成一张能打卡的进度表',
  ),
  _WelcomeSuggestion(
    '哪些其实可以延后',
    '我这些任务里哪些不重要、可以往后推？说清楚为什么',
  ),
];

const List<_WelcomeSuggestion> _suggStudyQa = [
  _WelcomeSuggestion(
    '这个知识点没懂',
    '用大白话给我讲清楚____，再举一个生活里的例子',
    needsInput: true,
  ),
  _WelcomeSuggestion(
    '给我出五道题',
    '针对____出 5 道练习题，先别给答案，我做完你再批改',
    needsInput: true,
  ),
  _WelcomeSuggestion(
    '下周要考，怎么突击',
    '我下周要考《{course}》，只剩几天了，帮我排一个突击节奏',
  ),
  _WelcomeSuggestion(
    '用费曼法考考我',
    '我讲一遍____给你听，你挑出我理解错的地方',
    needsInput: true,
  ),
];

const List<_WelcomeSuggestion> _suggSelfIntro = [
  _WelcomeSuggestion(
    '先介绍下你自己',
    '你能帮我做哪些事？结合我现在的课表和任务举三个具体例子',
  ),
  _WelcomeSuggestion(
    '我该问什么',
    '根据我现在的课表和任务，推荐三件我这两天马上用得上的事',
  ),
  _WelcomeSuggestion(
    '一句话改课表怎么说',
    '教我用最省事的一句话就能添加、修改、删除课程和任务的说法',
  ),
];

/// 假期（学期已结束）：欢迎页此时不会列课程，建议也跟着换成假期语境
const List<_WelcomeSuggestion> _suggHoliday = [
  _WelcomeSuggestion(
    '假期定个学习计划',
    '我在放假，帮我定一个每天两小时、能坚持住的学习计划',
  ),
  _WelcomeSuggestion(
    '把没学扎实的补回来',
    '假期时间多，帮我把这学期没学扎实的地方补一补',
  ),
  _WelcomeSuggestion(
    '别让我整个假期摆烂',
    '帮我做一个假期每日打卡表，学习、运动、睡觉都要有',
  ),
];

/// 开学前（新学期还没开始）
const List<_WelcomeSuggestion> _suggBeforeSemester = [
  _WelcomeSuggestion(
    '下学期课表还没导',
    '新学期课表还没导入，教我怎么最快弄进来',
  ),
  _WelcomeSuggestion(
    '开学前该准备什么',
    '新学期有几门新课，帮我列一份开学前该准备的东西',
  ),
  _WelcomeSuggestion(
    '把作息先调回来',
    '还有几天开学，帮我排一个把作息和状态调回来的日程',
  ),
];

/// 默认欢迎页要展示的文案。由 `AIAssistantScreenState` 按签名算好并缓存，
/// 所以一次情境（同一时段、同一学期状态、同一课程集合）内不会因 rebuild 变字。
class _WelcomeContent {
  const _WelcomeContent({
    required this.greeting,
    required this.question,
    required this.suggestions,
    this.sectionTitle,
    this.courseLines = const [],
    this.moreCoursesHint,
    this.statusLine,
  });

  /// 大号第一行：按时段随机
  final String greeting;

  /// 课程行下面那句问话，随机
  final String question;

  /// 「今天剩余课程安排：」/「明天课程安排：」；为 null 表示没有课可列
  final String? sectionTitle;

  /// 每行形如 "08:00 - 09:40 高等数学 王建国 一教201"，属事实不随机
  final List<String> courseLines;

  /// 课程行超过 [_welcomeMaxCourseLines] 时的收尾提示
  final String? moreCoursesHint;

  /// 没有课可列时的一句状态文案（开学前 / 假期 / 今明都没课），随机
  final String? statusLine;

  /// 问话下面那三枚建议按钮，已按当前情境选好并完成动态替换
  final List<_WelcomeSuggestion> suggestions;
}

class _ImagePreviewPage extends StatefulWidget {
  final String imagePath;
  final String heroTag;
  final Animation<double> animation;
  final bool useHero;
  final double? imageAspectRatio;

  const _ImagePreviewPage({
    required this.imagePath,
    required this.heroTag,
    required this.animation,
    this.useHero = true,
    this.imageAspectRatio,
  });

  @override
  State<_ImagePreviewPage> createState() => _ImagePreviewPageState();
}

class _ImagePreviewPageState extends State<_ImagePreviewPage>
    with TickerProviderStateMixin {
  final TransformationController _transformController =
      TransformationController();
  double _dismissProgress = 0.0;
  late final AnimationController _snapController;
  Matrix4 _snapFrom = Matrix4.identity();
  Matrix4 _snapTarget = Matrix4.identity();
  Curve _snapCurve = Curves.easeOutCubic;
  bool _isSnapping = false;
  bool _isClamping = false;
  bool _isInteracting = false;
  double _dragOriginalScale = 1.0;
  double _prevScaleForCheck = 1.0;
  double _snapStartDismissProgress = 0.0;
  bool _isDismissing = false;
  // 路由进场动画（含 Hero 飞行）是否已完全结束：
  // 飞行期间 shuttle 覆盖整屏且位于 Navigator overlay 顶层（所有路由之上），
  // 任何路由页内元素都会被盖住，按钮必须等飞行结束后再淡入
  bool _routeSettled = false;

  @override
  void initState() {
    super.initState();
    _snapController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    _snapController.addListener(_onSnapTick);
    _transformController.addListener(_clampTransform);
    widget.animation.addStatusListener(_onRouteStatusChanged);
    if (widget.animation.status == AnimationStatus.completed) {
      _routeSettled = true;
    }
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_onRouteStatusChanged);
    _snapController.dispose();
    _transformController.dispose();
    super.dispose();
  }

  void _onRouteStatusChanged(AnimationStatus status) {
    if (!mounted) return;
    final settled = status == AnimationStatus.completed;
    if (settled != _routeSettled) {
      setState(() => _routeSettled = settled);
    }
  }

  void _onSnapTick() {
    final t = _snapCurve.transform(_snapController.value);

    final targetProgress = _snapStartDismissProgress * (1.0 - t);
    if (_dismissProgress != targetProgress) {
      _dismissProgress = targetProgress;
      if (mounted) setState(() {});
    }
    final fromScale = _snapFrom.getMaxScaleOnAxis();
    final toScale = _snapTarget.getMaxScaleOnAxis();
    final curScale = fromScale + (toScale - fromScale) * t;

    final fromVec = _snapFrom.getTranslation();
    final toVec = _snapTarget.getTranslation();
    final curTx = fromVec.x + (toVec.x - fromVec.x) * t;
    final curTy = fromVec.y + (toVec.y - fromVec.y) * t;

    final result = Matrix4.identity();
    result.setEntry(0, 0, curScale);
    result.setEntry(1, 1, curScale);
    result.setEntry(2, 2, curScale);
    result.setEntry(0, 3, curTx);
    result.setEntry(1, 3, curTy);
    result.setEntry(3, 3, 1.0);

    _isClamping = true;
    _transformController.value = result;
    _isClamping = false;
  }

  void _clampTransform() {
    if (_isClamping || _isSnapping) return;
    final matrix = _transformController.value;
    final rawScale = matrix.getMaxScaleOnAxis();
    if (rawScale < 0.99) return;
    final screenSize = MediaQuery.of(context).size;
    final rawTx = matrix.getTranslation().x;
    final rawTy = matrix.getTranslation().y;

    double tx;
    double ty = rawTy;
    double visualScale = rawScale;

    final aspectRatio = widget.imageAspectRatio;
    final containerW = screenSize.width;
    final containerH = screenSize.height;
    final imageDisplayW = aspectRatio != null
        ? (aspectRatio >= containerW / containerH
            ? containerW
            : containerH * aspectRatio)
        : containerW;
    final imageDisplayH = aspectRatio != null
        ? (aspectRatio >= containerW / containerH
            ? containerW / aspectRatio
            : containerH)
        : containerH;
    final imageLeft = (containerW - imageDisplayW) / 2;
    final imageTop = (containerH - imageDisplayH) / 2;

    if (rawScale > 1.05) {
      final scaledImageW = imageDisplayW * rawScale;
      final minTx = scaledImageW > containerW
          ? containerW - (imageLeft + imageDisplayW) * rawScale
          : containerW * (1 - rawScale);
      final maxTx = scaledImageW > containerW ? -imageLeft * rawScale : 0.0;
      tx = rawTx.clamp(minTx, maxTx);
      if (!_isInteracting) {
        final scaledimagehForcenter = imageDisplayH * rawScale;
        if (scaledimagehForcenter <= containerH) {
          ty = containerH * (1 - rawScale) / 2;
        }
      }
    } else {
      tx = containerW * (1 - rawScale) / 2;
      if (!_isInteracting) {
        ty = containerH * (1 - rawScale) / 2;
      }
    }

    if (_isInteracting) {
      _prevScaleForCheck = rawScale;
      final centeredTy = containerH * (1 - _dragOriginalScale) / 2;
      final effectiveTranslation = rawTy / _dragOriginalScale;

      final isDismissing = rawTy > centeredTy + 1 && effectiveTranslation > 0;

      if (isDismissing) {
        final progress = (effectiveTranslation / containerH).clamp(0.0, 1.0);
        visualScale = _dragOriginalScale * (1.0 - progress * 0.18);
      } else {
        final scaledImageHCheck = imageDisplayH * rawScale;
        if (scaledImageHCheck <= containerH) {
          ty = containerH * (1 - rawScale) / 2;
        }
      }
    }

    if (rawScale > 1.05) {
      final scaledImageH = imageDisplayH * visualScale;
      if (scaledImageH > containerH) {
        final isDismissing = _isInteracting &&
            rawTy > containerH * (1 - _dragOriginalScale) / 2 + 1 &&
            rawTy / _dragOriginalScale > 0;
        if (!isDismissing) {
          final minTyVertical =
              containerH - (imageTop + imageDisplayH) * visualScale;
          final maxTyVertical = -imageTop * visualScale;
          ty = rawTy.clamp(minTyVertical, maxTyVertical);
        }
      }
    }

    final newMatrix = Matrix4.identity();
    newMatrix.setEntry(0, 0, visualScale);
    newMatrix.setEntry(1, 1, visualScale);
    newMatrix.setEntry(2, 2, visualScale);
    newMatrix.setEntry(0, 3, tx);
    newMatrix.setEntry(1, 3, ty);
    newMatrix.setEntry(3, 3, 1.0);
    _isClamping = true;
    _transformController.value = newMatrix;
    _isClamping = false;
  }

  Future<void> _snapTo(Matrix4 target) async {
    if (_snapController.isAnimating) {
      _snapController.stop();
    }
    _isSnapping = true;
    _snapCurve = Curves.easeOutCubic;
    _snapFrom = Matrix4.copy(_transformController.value);
    _snapTarget = target;
    _snapStartDismissProgress = _dismissProgress;
    _snapController.reset();
    await _snapController.forward();
    _isSnapping = false;
  }

  void _dismiss() {
    if (!mounted || _isDismissing) return;
    _isInteracting = false;

    if (!widget.useHero) {
      final currentMatrix = _transformController.value;
      final currentScale = currentMatrix.getMaxScaleOnAxis();
      final currentTy = currentMatrix.getTranslation().y;
      final screenSize = MediaQuery.of(context).size;
      final needsSnap = (currentScale - 1.0).abs() > 0.02 ||
          (currentTy - screenSize.height * (1 - currentScale) / 2).abs() > 2;

      if (needsSnap) {
        final target = Matrix4.identity();
        target.setEntry(0, 3, screenSize.width * (1 - 1.0) / 2);
        target.setEntry(1, 3, screenSize.height * (1 - 1.0) / 2);
        _snapController.duration = const Duration(milliseconds: 180);
        _snapCurve = Curves.easeOutCubic;
        _isSnapping = true;
        _snapFrom = Matrix4.copy(currentMatrix);
        _snapTarget = target;
        _snapStartDismissProgress = _dismissProgress;
        _snapController.reset();
        _snapController.forward().then((_) {
          _isSnapping = false;
          setState(() {
            _dismissProgress = 0.0;
          });
          if (mounted) Navigator.of(context).pop();
        });
        return;
      }

      setState(() {
        _dismissProgress = 0.0;
      });
      if (mounted) Navigator.of(context).pop();
      return;
    }

    setState(() {
      _dismissProgress = 0.0;
    });
    Navigator.of(context).pop();
  }

  void _animatedDismiss({Offset velocity = Offset.zero}) {
    if (_isDismissing) return;
    _isInteracting = false;
    if (!widget.useHero) {
      _isDismissing = true;
      final screenSize = MediaQuery.of(context).size;
      final currentMatrix = Matrix4.copy(_transformController.value);
      final cur = currentMatrix.getTranslation();

      // 跟随手指：沿实际滑动方向继续位移；立即 pop，
      // 整体淡出（含缩小）交给路由反向动画（250ms），与点击退出结构一致
      var dirX = velocity.dx;
      var dirY = velocity.dy;
      final speedSq = dirX * dirX + dirY * dirY;
      if (speedSq < 100.0) {
        dirX = 0.0; // 纯位移触发（无速度）时默认沿向下方向退出
        dirY = 1.0;
      } else {
        final mag = sqrt(speedSq);
        dirX /= mag;
        dirY /= mag;
      }
      final travel = screenSize.height * 0.35;

      final target = Matrix4.copy(currentMatrix);
      target.setEntry(0, 3, cur.x + dirX * travel);
      target.setEntry(1, 3, cur.y + dirY * travel);

      // 位移动画与路由反向动画（250ms）同步进行、同步结束
      _snapController.duration = const Duration(milliseconds: 250);
      _snapCurve = Curves.easeOutCubic;
      _isSnapping = true;
      _snapFrom = currentMatrix;
      _snapTarget = target;
      _snapStartDismissProgress = _dismissProgress;
      _snapController.reset();
      _snapController.forward().whenComplete(() {
        _isSnapping = false;
      });
      if (mounted) Navigator.of(context).pop();
      if (mounted) setState(() {});
      return;
    }

    setState(() {
      _dismissProgress = 0.0;
    });
    if (mounted) Navigator.of(context).pop();
  }

  void _onDoubleTap() {
    if (_isSnapping || _isDismissing) return;
    final matrix = _transformController.value;
    final scale = matrix.getMaxScaleOnAxis();
    final screenSize = MediaQuery.of(context).size;

    double targetScale;
    if (scale < 1.5) {
      targetScale = 2.0;
    } else {
      targetScale = 1.0;
    }

    final target = Matrix4.identity();
    target.setEntry(0, 0, targetScale);
    target.setEntry(1, 1, targetScale);
    target.setEntry(2, 2, targetScale);
    target.setEntry(0, 3, screenSize.width * (1 - targetScale) / 2);
    target.setEntry(1, 3, screenSize.height * (1 - targetScale) / 2);
    target.setEntry(3, 3, 1.0);

    _dragOriginalScale = targetScale;
    _isInteracting = false;
    _snapTo(target);
    setState(() {
      _dismissProgress = 0.0;
    });
  }

  void _onInteractionStart(ScaleStartDetails details) {
    _isInteracting = true;
    _dragOriginalScale =
        _transformController.value.getMaxScaleOnAxis().clamp(1.0, 4.0);
    if (_dragOriginalScale > 1.05 && _dismissProgress != 0.0) {
      setState(() {
        _dismissProgress = 0.0;
      });
    }
  }

  void _onInteractionUpdate(ScaleUpdateDetails details) {
    if (_isDismissing) return;
    if (_isSnapping) {
      _snapController.stop();
      _isSnapping = false;
    }
    final matrix = _transformController.value;
    final screenSize = MediaQuery.of(context).size;
    final ty = matrix.getTranslation().y;

    final effectiveTranslation = ty / _dragOriginalScale;
    if (effectiveTranslation > 0) {
      final progress =
          (effectiveTranslation / screenSize.height).clamp(0.0, 1.0);
      if (progress != _dismissProgress) {
        setState(() {
          _dismissProgress = progress;
        });
      }
    } else if (_dismissProgress != 0) {
      setState(() {
        _dismissProgress = 0.0;
      });
    }
  }

  void _onInteractionEnd(ScaleEndDetails details) {
    _isInteracting = false;
    final matrix = _transformController.value;
    final currentScale = matrix.getMaxScaleOnAxis();
    final ty = matrix.getTranslation().y;
    final screenSize = MediaQuery.of(context).size;

    final effectiveTranslation = ty / _dragOriginalScale;
    if (effectiveTranslation > screenSize.height * 0.2 ||
        details.velocity.pixelsPerSecond.dy > 800) {
      _animatedDismiss(velocity: details.velocity.pixelsPerSecond);
      return;
    }

    final aspectRatio = widget.imageAspectRatio;
    final imageDisplayHEnd = aspectRatio != null
        ? (aspectRatio >= screenSize.width / screenSize.height
            ? screenSize.width / aspectRatio
            : screenSize.height)
        : screenSize.height;
    final fillsScreen = imageDisplayHEnd * currentScale > screenSize.height;

    if (_dragOriginalScale <= 1.05) {
      final centeredTy = screenSize.height * (1 - _dragOriginalScale) / 2;
      if ((ty - centeredTy).abs() > 1) {
        final target = Matrix4.identity();
        target.setEntry(0, 0, _dragOriginalScale);
        target.setEntry(1, 1, _dragOriginalScale);
        target.setEntry(2, 2, _dragOriginalScale);
        target.setEntry(1, 3, centeredTy);
        target.setEntry(3, 3, 1.0);
        _snapTo(target).then((_) {
          if (mounted)
            setState(() {
              _dismissProgress = 0.0;
            });
        });
        return;
      }
    }

    if (!fillsScreen) {
      final centeredTy = screenSize.height * (1 - currentScale) / 2;
      if ((ty - centeredTy).abs() > 1) {
        final target = Matrix4.identity();
        target.setEntry(0, 0, currentScale);
        target.setEntry(1, 1, currentScale);
        target.setEntry(2, 2, currentScale);
        target.setEntry(0, 3, screenSize.width * (1 - currentScale) / 2);
        target.setEntry(1, 3, centeredTy);
        target.setEntry(3, 3, 1.0);
        _snapTo(target).then((_) {
          if (mounted)
            setState(() {
              _dismissProgress = 0.0;
            });
        });
        return;
      }
    }

    setState(() {
      _dismissProgress = 0.0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    return AnimatedBuilder(
      animation: widget.animation,
      builder: (context, child) {
        final baseOpacity = widget.animation.value;
        final bgOpacity = baseOpacity * (1.0 - _dismissProgress);
        return Container(
          color: Colors.black.withValues(alpha: bgOpacity.clamp(0.0, 0.95)),
          child: child,
        );
      },
      child: GestureDetector(
        onTap: _dismiss,
        child: Stack(
          children: [
            Positioned.fill(
              child: Center(
                child: _buildAnimatedImage(screenSize),
              ),
            ),
            // 关闭按钮：Hero 飞行期间 shuttle 位于 Navigator overlay 顶层，
            // 会盖住任何路由页内元素。飞行期间（路由动画未 completed）用外层
            // Opacity 瞬时隐藏（不跟 150ms 渐隐拖尾），飞行结束后再由内层
            // AnimatedOpacity 淡入；退出时同样瞬时隐藏，避免反向飞行遮挡闪现
            Positioned(
              top: 0,
              right: 0,
              child: SafeArea(
                child: IgnorePointer(
                  ignoring: !_routeSettled,
                  child: Opacity(
                    opacity: _routeSettled ? 1.0 : 0.0,
                    child: AnimatedOpacity(
                      opacity: _routeSettled ? (1.0 - _dismissProgress) : 0.0,
                      duration: const Duration(milliseconds: 150),
                      child: Container(
                        margin: const EdgeInsets.all(12),
                        child: ClipOval(
                          child: BackdropFilter(
                            filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                            child: Container(
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.2),
                                shape: BoxShape.circle,
                              ),
                              child: IconButton(
                                icon: const Icon(Icons.close,
                                    color: Colors.white, size: 22),
                                onPressed: _dismiss,
                                padding: const EdgeInsets.all(8),
                                constraints: const BoxConstraints(
                                    minWidth: 40, minHeight: 40),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAnimatedImage(Size screenSize) {
    final heroChild = SizedBox(
      width: screenSize.width,
      height: screenSize.height,
      child: Image.file(
        File(widget.imagePath),
        fit: BoxFit.contain,
      ),
    );

    final viewer = GestureDetector(
      onDoubleTap: _onDoubleTap,
      child: InteractiveViewer(
        transformationController: _transformController,
        constrained: false,
        minScale: 0.5,
        maxScale: 4.0,
        boundaryMargin: const EdgeInsets.all(1000),
        onInteractionStart: _onInteractionStart,
        onInteractionUpdate: _onInteractionUpdate,
        onInteractionEnd: _onInteractionEnd,
        child: widget.useHero
            ? Hero(
                tag: widget.heroTag,
                flightShuttleBuilder: (
                  flightContext,
                  animation,
                  flightDirection,
                  fromHero,
                  toHero,
                ) {
                  return SizedBox.expand(
                    child:
                        Image.file(File(widget.imagePath), fit: BoxFit.contain),
                  );
                },
                child: heroChild,
              )
            : heroChild,
      ),
    );

    if (!widget.useHero) {
      return ScaleTransition(
        scale: Tween<double>(begin: 0.0, end: 1.0).animate(
          CurvedAnimation(
            parent: widget.animation,
            curve: Curves.easeOutCubic,
          ),
        ),
        child: FadeTransition(
          opacity: widget.animation,
          child: viewer,
        ),
      );
    }

    return viewer;
  }
}

class _ChatMessage {
  final String role;
  final String content;
  final bool isError;
  final bool isInterrupted;
  final bool isWelcome;
  final List<Course>? courses;
  final String? imagePath;
  final double? imageAspectRatio;
  final String? thinkingContent;
  // 历史气泡思考过程默认收起：流式输出时正文开始后会自动折叠思考框，
  // 消息存入历史后若默认展开会出现「部分思考过程被展开」的现象
  bool isThinkingCollapsed = true;

  _ChatMessage({
    required this.role,
    required this.content,
    this.isError = false,
    this.isInterrupted = false,
    this.isWelcome = false,
    this.courses,
    this.imagePath,
    this.imageAspectRatio,
    this.thinkingContent,
  });
}

String _convertLatexForRendering(String content) {
  String result = content;

  final alignPattern = RegExp(
    r'\\begin\{align\*\}([\s\S]*?)\\end\{align\*\}',
    multiLine: true,
  );

  result = result.replaceAllMapped(alignPattern, (match) {
    String alignContent = match.group(1)!;

    alignContent = alignContent.replaceAllMapped(
      RegExp(r'(&=)'),
      (m) => '&=${m.group(0)?.substring(1) ?? '='}',
    );

    alignContent = alignContent.replaceAll(RegExp(r'\\&='), '&=');

    return '\$\$\\begin{array}{rcl}$alignContent\\end{array}\$\$';
  });

  result = result.replaceAllMapped(
    RegExp(r'\\\(([\s\S]*?)\\\)'),
    (match) => '\$${match.group(1)}\$',
  );

  result = result.replaceAllMapped(
    RegExp(r'\\\[([\s\S]*?)\\\]'),
    (match) => '\$\$${match.group(1)}\$\$',
  );

  return result;
}

Widget _buildMarkdownContent(String content,
    {required BuildContext context, TextStyle? style}) {
  var processedContent = _convertLatexForRendering(content);

  processedContent = processedContent
      .replaceAll(RegExp(r'^#### ', multiLine: true), '##### ')
      .replaceAll(RegExp(r'^### ', multiLine: true), '##### ')
      .replaceAll(RegExp(r'^## ', multiLine: true), '##### ')
      .replaceAll(RegExp(r'^# ', multiLine: true), '##### ');

  // 显式注入标题配色：gpt_markdown 的标题样式取自 TextTheme 的
  // title/headline 系列，M3 下这些颜色是 onSurfaceVariant（灰）——
  // 按；包提供的 GptMarkdownTheme 覆盖为 textPrimary，随界面模式切换
  final gptTheme = GptMarkdownThemeData(
    brightness: Theme.of(context).brightness,
    h1: TextStyle(
        fontSize: 26,
        fontWeight: FontWeight.w700,
        color: AppColors.of(context).textPrimary),
    h2: TextStyle(
        fontSize: 23,
        fontWeight: FontWeight.w700,
        color: AppColors.of(context).textPrimary),
    h3: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: AppColors.of(context).textPrimary),
    h4: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: AppColors.of(context).textPrimary),
    h5: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: AppColors.of(context).textPrimary),
    h6: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: AppColors.of(context).textPrimary),
    hrLineColor: AppColors.of(context).borderWeak,
  );
  final markdown = GptMarkdownTheme(
    gptThemeData: gptTheme,
    child: GptMarkdown(
      processedContent,
      // 亮度 key：切界面模式时强制重新生成样式 span——gpt_markdown 的
      // MdWidget 只在 initState/didUpdateWidget(exp 或 config 变化) 时
      // 解析标题等组件样式，纯主题翻转（exp 不变、部分 config 相同）
      // 会漏更新，标题就停留在旧主题的颜色上
      key: ValueKey(Theme.of(context).brightness),
      style: style ?? const TextStyle(fontSize: 14, height: 1.5),
      useDollarSignsForLatex: true,
      tableBuilder: (context, rows, textStyle, config) {
        // gpt_markdown 在解析期一次性调用 tableBuilder 并把 Theme 色值
        // 烘焙进 widget：切换深浅模式包不会重新解析（isSame 不比较
        // tableBuilder），表头背景/边框就停留在旧主题色（标题样式走了
        // GptMarkdownTheme 继承通知所以正常）。包一层 Builder 把主题
        // 读取推迟到构建期：Theme 变化 → Builder 依赖通知重建 → 整表
        // （含行内 MdWidget，挂亮度 key 强制重解析）以新主题重新生成
        // 复制用的块级纯文本：每行单元格以" | "分隔、行间换行
        final tableText = rows
            .map((row) => row.fields.map((f) => f.data.trim()).join(' | '))
            .join('\n');
        // 表格文字不在 Text 渲染对象里，SelectionArea 默认选不中；
        // 包一层块级适配器后整表参与选择（选中即整块，复制出 tableText）
        return SelectableBlockAdapter(
          selectedText: tableText,
          child: Builder(
          builder: (tableContext) {
            final theme = Theme.of(tableContext);
            // 表格比可视宽度长时右缘淡出，提示可以横向滑动
            return FadingEdgeBox(
              physics: const BouncingScrollPhysics(),
              child: Table(
                textDirection: config.textDirection,
                defaultColumnWidth: CustomTableColumnWidth(),
                defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                border: TableBorder.all(
                  width: 1,
                  color: theme.colorScheme.onSurface,
                ),
                children: rows
                    .map((row) => TableRow(
                          decoration: row.isHeader
                              ? BoxDecoration(
                                  color:
                                      theme.colorScheme.surfaceContainerHighest)
                              : null,
                          children: row.fields.map((field) {
                            Widget content = Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              child: MdWidget(
                                key: ValueKey(theme.brightness),
                                tableContext,
                                field.data,
                                false,
                                config: config,
                              ),
                            );
                            switch (field.alignment) {
                              case TextAlign.center:
                                return Center(child: content);
                              case TextAlign.right:
                                return Align(
                                    alignment: Alignment.centerRight,
                                    child: content);
                              default:
                                return Align(
                                    alignment: Alignment.centerLeft,
                                    child: content);
                            }
                          }).toList(),
                        ))
                    .toList(),
              ),
            );
          },
        ),
      );
    },
      latexBuilder: (context, tex, textStyle, inline) {
        if (inline) {
          return Math.tex(
            tex,
            textStyle: textStyle,
            mathStyle: MathStyle.text,
            textScaleFactor: 1,
            settings: const TexParserSettings(strict: Strict.ignore),
          );
        }
        // display 公式同样包块级适配器参与选择（复制出 LaTeX 源码）
        return SelectableBlockAdapter(
          selectedText: tex,
          child: FadingEdgeBox(
            physics: const BouncingScrollPhysics(),
            child: Math.tex(
              tex,
              textStyle: textStyle,
              mathStyle: MathStyle.display,
              textScaleFactor: 1,
              settings: const TexParserSettings(strict: Strict.ignore),
            ),
          ),
        );
      },
    ),
  );

  return markdown;
}

class _DragSegmented extends StatefulWidget {
  final List<String> labels;
  final int activeIndex;
  final ValueChanged<int> onChanged;

  const _DragSegmented({
    required this.labels,
    required this.activeIndex,
    required this.onChanged,
  });

  @override
  State<_DragSegmented> createState() => _DragSegmentedState();
}

class _DragSegmentedState extends State<_DragSegmented> {
  double _dragOffset = 0;
  bool _isDragging = false;
  bool _isLongPressing = false;
  Duration _textAnimDuration = const Duration(milliseconds: 250);

  @override
  Widget build(BuildContext context) {
    final labels = widget.labels;
    return LayoutBuilder(
      builder: (context, constraints) {
        final totalWidth = constraints.maxWidth;
        final n = labels.length;
        final internalWidth = totalWidth - 2;
        final segmentW = internalWidth / n;
        final activeIdx = widget.activeIndex;

        final effectiveIdx = _isDragging
            ? (activeIdx + _dragOffset / segmentW)
                .clamp(0.0, (n - 1).toDouble())
            : activeIdx.toDouble();
        final left = 2.0 + effectiveIdx * segmentW;
        final visualActiveIdx =
            _isDragging ? effectiveIdx.round().clamp(0, n - 1) : activeIdx;

        return GestureDetector(
          onTapUp: (details) {
            final tapX = details.localPosition.dx - 1;
            if (tapX < 0 || tapX >= internalWidth) return;
            final tappedIdx = (tapX / segmentW).floor().clamp(0, n - 1);
            if (tappedIdx == activeIdx) return;
            HapticFeedback.selectionClick();
            widget.onChanged(tappedIdx);
          },
          onHorizontalDragStart: (_) {
            setState(() {
              _isDragging = true;
              _isLongPressing = true;
              _dragOffset = 0;
            });
          },
          onHorizontalDragUpdate: (details) {
            setState(() {
              _dragOffset += details.delta.dx;
              final minOffset = -activeIdx * segmentW;
              final maxOffset = (n - 1 - activeIdx) * segmentW;
              _dragOffset = _dragOffset.clamp(minOffset, maxOffset);
            });
          },
          onHorizontalDragEnd: (details) {
            setState(() {
              _isDragging = false;
              _isLongPressing = false;
            });
            _textAnimDuration = Duration.zero;
            if (mounted) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) {
                  setState(() =>
                      _textAnimDuration = const Duration(milliseconds: 250));
                }
              });
            }
            final velocity = details.primaryVelocity ?? 0;
            final extra = velocity > 0
                ? -segmentW / 3
                : velocity < 0
                    ? segmentW / 3
                    : 0.0;
            final totalOffset = _dragOffset + extra;
            int targetIdx =
                (activeIdx + totalOffset / segmentW).round().clamp(0, n - 1);
            _dragOffset = 0;
            if (targetIdx != activeIdx) {
              HapticFeedback.selectionClick();
              widget.onChanged(targetIdx);
            }
          },
          onHorizontalDragCancel: () {
            setState(() {
              _isDragging = false;
              _isLongPressing = false;
              _dragOffset = 0;
            });
          },
          onLongPressStart: (_) {
            setState(() => _isLongPressing = true);
          },
          onLongPressEnd: (_) {
            setState(() => _isLongPressing = false);
          },
          child: Container(
            height: 40,
            decoration: BoxDecoration(
              color: AppColors.of(context).panel(0.4),
              borderRadius: BorderRadius.circular(10),
              border:
                  Border.all(color: AppColors.of(context).borderWeak, width: 1),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: Stack(
                children: [
                  AnimatedPositioned(
                    duration: _isDragging
                        ? Duration.zero
                        : const Duration(milliseconds: 250),
                    curve: Curves.easeInOut,
                    left: left,
                    top: 2,
                    bottom: 2,
                    child: AnimatedScale(
                      scale: (_isDragging || _isLongPressing) ? 1.04 : 1.0,
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeInOut,
                      child: Container(
                        width: segmentW - 4,
                        decoration: BoxDecoration(
                          // 滑块把手：深色下用中灰与深轨道区分，白字仍可读
                          color: AppColors.isDark(context)
                              ? Colors.grey.shade600
                              : Colors.grey.shade800,
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
                  if (_isDragging)
                    Row(
                      children: labels
                          .map((label) => Expanded(
                                child: Center(
                                  child: AnimatedDefaultTextStyle(
                                    duration: Duration.zero,
                                    style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.normal,
                                        color:
                                            AppColors.of(context).textPrimary),
                                    child: Text(label),
                                  ),
                                ),
                              ))
                          .toList(),
                    ),
                  if (_isDragging)
                    Positioned.fill(
                      child: ShaderMask(
                        shaderCallback: (bounds) {
                          final relLeft = (left / bounds.width).clamp(0.0, 1.0);
                          const edge = 0.015;
                          final relStart = (relLeft - edge).clamp(0.0, 1.0);
                          final relEnd = ((left + segmentW - 4) / bounds.width)
                              .clamp(0.0, 1.0);
                          final relStop = (relEnd + edge).clamp(0.0, 1.0);
                          return LinearGradient(
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                            colors: const [
                              Colors.transparent,
                              Colors.transparent,
                              Colors.white,
                              Colors.white,
                              Colors.transparent,
                              Colors.transparent,
                            ],
                            stops: [
                              0.0,
                              relStart,
                              relLeft,
                              relEnd,
                              relStop,
                              1.0
                            ],
                          ).createShader(bounds);
                        },
                        blendMode: BlendMode.dstIn,
                        child: Row(
                          children: labels
                              .map((label) => Expanded(
                                    child: Center(
                                      child: AnimatedDefaultTextStyle(
                                        key: ValueKey(
                                            Theme.of(context).brightness),
                                        duration: Duration.zero,
                                        style: TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.normal,
                                            color: Colors.white),
                                        child: Text(label),
                                      ),
                                    ),
                                  ))
                              .toList(),
                        ),
                      ),
                    ),
                  if (!_isDragging)
                    Row(
                      children: labels.asMap().entries.map((entry) {
                        return Expanded(
                          child: Center(
                            child: AnimatedDefaultTextStyle(
                              key: ValueKey(Theme.of(context).brightness),
                              duration: _textAnimDuration,
                              curve: Curves.easeInOut,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.normal,
                                color: entry.key == visualActiveIdx
                                    ? Colors.white
                                    : AppColors.of(context).textPrimary,
                              ),
                              child: Text(entry.value),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBaseTextRow(
      List<String> labels, Color color, FontWeight weight) {
    return Row(
      children: labels
          .map((label) => Expanded(
                child: Center(
                  child: Text(label,
                      style: TextStyle(
                          fontSize: 13, fontWeight: weight, color: color)),
                ),
              ))
          .toList(),
    );
  }
}

/// 复刻截图中「选取文字」的旗标图标：左上、右下两个实心圆点为对角
/// 锚点，经短杆连到圆角矩形旗面的左上/右下角（描边）
class _FlagSelectionIcon extends StatelessWidget {
  const _FlagSelectionIcon({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _FlagSelectionIconPainter(color: color),
    );
  }
}

class _FlagSelectionIconPainter extends CustomPainter {
  const _FlagSelectionIconPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // 按 24×24 视口设计，等比缩放到实际绘制尺寸
    canvas.scale(size.width / 24);

    final Paint stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.9
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final Paint dot = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    const Offset topLeft = Offset(6.8, 3.9);
    const Offset bottomRight = Offset(19.2, 19.0);
    const Rect flagRect = Rect.fromLTRB(6.8, 6.0, 19.2, 16.6);

    // 左上/右下短杆：从圆点连到旗面对角
    canvas.drawLine(topLeft, flagRect.topLeft, stroke);
    canvas.drawLine(flagRect.bottomRight, bottomRight, stroke);
    // 旗面：圆角矩形描边
    canvas.drawRRect(
      RRect.fromRectAndRadius(flagRect, const Radius.circular(3.0)),
      stroke,
    );
    // 对角实心圆点
    canvas.drawCircle(topLeft, 1.6, dot);
    canvas.drawCircle(bottomRight, 1.6, dot);
  }

  @override
  bool shouldRepaint(_FlagSelectionIconPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// 「选取文字」模式容器：把消息正文包进 SelectionArea，进入时通过
/// 区域委托派发选区事件，自动选中长按/双击位置所在的那一行（空白处
/// 则就近选一行），并挂载统一玻璃菜单（输入框长按同款，自带复制/
/// 全选）；用户手势接管选区后菜单交给 SDK 路径同款实例，选区被清空
/// （如点击正文其他位置、复制后清除）即自动退出选取模式。
/// SelectionArea 的长按/拖动识别器在竞技场里是子节点、先声明胜利，
/// 会自然压过气泡的 GestureDetector，无需额外判断。
class _MessageSelectionArea extends StatefulWidget {
  const _MessageSelectionArea({
    required this.pressPosition,
    required this.onExit,
    required this.scrollController,
    required this.child,
  });

  /// 进入选取模式前长按的位置（全局坐标），自动选中其所在行
  final Offset? pressPosition;

  /// 退出选取模式（由宿主清理 _selectingMessageIndex）
  final VoidCallback onExit;

  /// 消息列表滚动控制器：滚动时隐藏统一菜单（防错位），停止后在
  /// 当前选区位置重新弹出
  final ScrollController scrollController;

  final Widget child;

  @override
  State<_MessageSelectionArea> createState() => _MessageSelectionAreaState();
}

class _MessageSelectionAreaState extends State<_MessageSelectionArea> {
  /// 正文所在的区域委托与区域状态（Builder 内捕获）：自动选行通过
  /// delegate 的公开 dispatchSelectionEvent 派发拖拽手柄同款选区事件
  /// ——不依赖手势竞技场，任何设备即时生效
  MultiSelectableSelectionContainerDelegate? _delegate;
  SelectableRegionState? _regionState;

  bool _hadSelection = false;

  bool _exited = false;

  /// 自身拖拽手柄拖动中：此间的选区几何变化来自自家派发，滚动偏移
  /// 也来自 SDK 的 bringIntoView，都不算「用户滚动/手势接管」
  bool _draggingOwnHandles = false;

  /// 正文盒子的 LayerLink：手柄用跟随层锚定，滚动时自动吸附选区
  final LayerLink _regionLink = LayerLink();

  /// 滚动停止后的菜单重弹定时器
  Timer? _scrollSettleTimer;

  /// 建立看门狗：自动选行派发后若一段时间内仍未形成任何选区，主动退出。
  /// 没有它，一次失败的进入会让这条消息永久停在「正文已包上 SelectionArea
  /// 却没有选区」的状态——手势被 SelectionArea 接管、长按再也呼不出操作
  /// 菜单，再次双击只是换一个按住点，表现为选取模式在后台越叠越多
  Timer? _establishTimer;
  static const Duration _kEstablishTimeout = Duration(milliseconds: 400);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoSelectLine());
    widget.scrollController.addListener(_handleScrollOffset);
  }

  /// 同一条消息再次进入选取模式（再双击一次 / 菜单里再点一次「选取文字」）：
  /// 容器不会重建，initState 不再走，必须自己清掉旧选区并按新的按住点
  /// 重跑一次自动选行，否则这一次点击完全没有反应
  @override
  void didUpdateWidget(covariant _MessageSelectionArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pressPosition == oldWidget.pressPosition) return;
    _exited = false;
    _hadSelection = false;
    _collapsePending = false;
    _menuAnchorFailures = 0;
    try {
      _delegate?.dispatchSelectionEvent(const ClearSelectionEvent());
    } catch (_) {}
    // 上一次尝试留下的浮层先撤干净，新的按住点重新插入，避免菜单锚在旧位置
    _removeSelectMenuOverlay();
    _removeHandlesOverlay();
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoSelectLine());
  }

  /// 当前是否真的存在选区（派发路径不保证同帧生效：可选对象是帧后注册的）
  bool _selectionExists() {
    try {
      final content = _delegate?.getSelectedContent();
      return content != null && content.plainText.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  void _armEstablishCheck() {
    _establishTimer?.cancel();
    _establishTimer = Timer(_kEstablishTimeout, () {
      _establishTimer = null;
      if (_exited || !mounted) return;
      if (_selectionExists()) return;
      _exit();
    });
  }

  /// 列表滚动：手柄由跟随层自动吸附选区；统一菜单锚点固定会错位，
  /// 滚动期间隐藏，停止滚动 300ms 后在当前选区位置重新弹出。
  /// 例外：自身拖拽手柄引发的滚动（SDK bringIntoView 对齐选区边缘）
  /// 不隐藏菜单，让它原地跟随
  void _handleScrollOffset() {
    if (_exited || !mounted || !_hadSelection) return;
    if (_draggingOwnHandles) {
      _menuOverlayEntry?.markNeedsBuild();
      return;
    }
    _removeSelectMenuOverlay();
    _scrollSettleTimer?.cancel();
    _scrollSettleTimer = Timer(const Duration(milliseconds: 300), () {
      if (_exited || !mounted || !_hadSelection) return;
      _showSelectMenuOverlay();
    });
  }

  @override
  void dispose() {
    widget.scrollController.removeListener(_handleScrollOffset);
    _delegate?.removeListener(_handleDelegateChanged);
    _emptySelectionTimer?.cancel();
    _establishTimer?.cancel();
    _scrollSettleTimer?.cancel();
    _removeSelectMenuOverlay();
    _removeHandlesOverlay();
    super.dispose();
  }

  void _exit() {
    if (_exited || !mounted) return;
    _exited = true;
    _collapsePending = false;
    _emptySelectionTimer?.cancel();
    _emptySelectionTimer = null;
    _establishTimer?.cancel();
    _establishTimer = null;
    _scrollSettleTimer?.cancel();
    _scrollSettleTimer = null;
    _removeSelectMenuOverlay();
    _removeHandlesOverlay();
    // 退出一律清空选区：派发出的高亮不跟着撤，下一次进入选取模式会在
    // 同一条消息上叠出另一层残留选区
    try {
      _delegate?.dispatchSelectionEvent(const ClearSelectionEvent());
    } catch (_) {}
    widget.onExit();
  }

  /// 统一菜单锚点连续构建失败的次数（选区几何无有效端点时
  /// contextMenuAnchors 会抛异常）：持续失败说明选区已不可用，
  /// 超限后强制退出选取模式，避免无菜单的卡死状态
  int _menuAnchorFailures = 0;

  /// 清空判定的安全复查定时器：选区清空时菜单/手柄「视觉立即收起」，
  /// 但模式退出延迟 120ms 复查——派发的边缘更新在真机上可能分帧处理
  /// （pending 重派/布局期），期间会短暂报出「空选区」，立即退出会吞掉
  /// 刚建立的选区；若复查前选区恢复（瞬态抖动），菜单/手柄自动放回
  Timer? _emptySelectionTimer;

  /// 选区清空后、退出复查前的过渡态：此时菜单/手柄已视觉收起，
  /// 若选区恢复需要把它们放回
  bool _collapsePending = false;

  /// 区域委托几何变化：唯一可靠的「选区被清空」信号。派发路径建立的
  /// 选区从未登记进 SDK 的内容判重缓存，清空时 onSelectionChanged 判为
  /// 「无变化」不触发，因此必须自己监听委托。
  /// 防御：委托会在文本子树挂载/布局期通知（片段注册），此时绝不能
  /// 动树（remove entry / setState），一律推迟到帧末；整个回调体兜底
  /// try/catch，任何异常都不能打断通知方（否则会破坏整帧渲染）
  void _handleDelegateChanged() {
    if (_exited || !mounted) return;
    if (_draggingOwnHandles) return; // 自家手柄拖动，非用户接管
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _handleDelegateChanged();
        }
      });
      return;
    }
    try {
      final content = _delegate?.getSelectedContent();
      final bool hasSelection =
          content != null && content.plainText.isNotEmpty;
      if (hasSelection) {
        _emptySelectionTimer?.cancel();
        _emptySelectionTimer = null;
        // 选区存在期间必须保证自绘手柄浮层在屏（幂等：已在屏则直接返回）。
        // 手柄统一由自绘浮层提供后，若这里不兜底，「空态收起 → 退出复查
        // 竞态 → 选区重建」的时序会留下「有选区但无手柄无菜单」的卡态
        _showHandlesOverlay();
        // 瞬时空态恢复：把刚视觉收起的菜单/手柄放回
        if (_collapsePending) {
          _collapsePending = false;
          _showSelectMenuOverlay();
        }
        return;
      }
      if (!_hadSelection) return;
      // 选区清空：菜单/手柄立即视觉收起；退出延迟 120ms 复查，
      // 防止派发边缘更新分帧处理期的瞬时空态误杀刚建立的选区
      _collapsePending = true;
      _removeSelectMenuOverlay();
      _removeHandlesOverlay();
      _emptySelectionTimer?.cancel();
      _emptySelectionTimer = Timer(const Duration(milliseconds: 120), () {
        _emptySelectionTimer = null;
        if (_exited || !mounted) return;
        try {
          final content = _delegate?.getSelectedContent();
          final bool stillEmpty =
              content == null || content.plainText.isEmpty;
          if (stillEmpty && _hadSelection) {
            _collapsePending = false;
            // 选区确实被清空（点击正文其他位置等未点菜单按钮的取消）
            _exit();
          }
        } catch (_) {}
      });
    } catch (_) {
      // 委托状态异常：保持现状，不退出、不破坏界面
    }
  }

  /// SDK 路径的选区回调：用户长按/拖动（选区内容变化）时收起自动
  /// 选行的统一菜单，交给 SDK 同款菜单（contextMenuBuilder）；自绘
  /// 手柄浮层保留（原生手柄已隐藏，见 build 里的
  /// _invisibleSelectionHandleControls），并确保它在屏。
  /// 注意：派发建立的选区不会驱动此回调（SDK 按内容前后判重），
  /// 复制后的收尾改走统一菜单的 onCopyDone 钩子，不依赖它
  void _handleSelectionChanged(SelectedContent? content) {
    if (content != null && content.plainText.isNotEmpty && _hadSelection) {
      _removeSelectMenuOverlay();
      _showHandlesOverlay();
    }
  }

  /// 自动选中 pressPosition 所在的行：在正文渲染树中找到该位置所属
  /// （或就近）的文本行，再向区域委托派发「起点收缩到行首 + 终点扩展
  /// 到行尾」的选区事件（与拖拽手柄同款路径，字符精度），即时生效。
  /// 手柄/选中工具栏由用户后续的原生长按手势照常呼出
  void _autoSelectLine() {
    final Offset? press = widget.pressPosition;
    if (press == null || !mounted) return;
    final RenderObject? rootObject = context.findRenderObject();
    if (rootObject is! RenderBox || !rootObject.hasSize) return;

    _LineTarget? best;
    void visit(RenderObject object) {
      if (object is RenderParagraph) {
        final candidate = _nearestLineInParagraph(object, press);
        if (candidate != null &&
            (best == null || candidate.distance < best!.distance)) {
          best = candidate;
        }
        return; // 段落内部不再下探
      }
      object.visitChildren(visit);
    }

    visit(rootObject);
    final _LineTarget? target = best;
    final delegate = _delegate;
    debugPrint('[选取] 定位行=${target != null} 委托=${delegate != null} '
        '起点=${target?.start} 终点=${target?.end}');
    if (target == null || delegate == null) {
      // 一个可选行都定位不到：不能把这条消息留在选取模式里（SelectionArea
      // 会接管手势，连操作菜单都呼不出来），直接退出
      _exit();
      return;
    }

    // 区域级事件派发：起点收缩到行首、终点扩展到行尾（字符精度）
    delegate.dispatchSelectionEvent(
        SelectionEdgeUpdateEvent.forStart(globalPosition: target.start));
    delegate.dispatchSelectionEvent(
        SelectionEdgeUpdateEvent.forEnd(globalPosition: target.end));
    // 派发路径不经过 onSelectionChanged，手动记录选区已建立
    _hadSelection = true;
    // 统一菜单（输入框长按同款）与两端拖拽手柄均以独立 OverlayEntry
    // 挂载：不触碰正文子树（结构变化会使段落重建、选区丢失）。
    // 手柄先插入、菜单后插入（后插者在最上层，菜单按钮不被手柄
    // 热区遮挡）；两者的 build 均有兜底，异常只降级不破坏渲染帧
    _showHandlesOverlay();
    _showSelectMenuOverlay();
    // 可选对象是帧后注册的，派发的边缘事件要等下一帧才被重放；给一次
    // 建立窗口，窗口内仍无选区就退出，不留空转的选取容器
    _armEstablishCheck();
  }

  /// 统一选中菜单的 OverlayEntry（launcher 探针不可见，菜单由它自管理）
  OverlayEntry? _menuOverlayEntry;

  /// 两端拖拽手柄浮层的 OverlayEntry
  OverlayEntry? _handlesOverlayEntry;

  void _showSelectMenuOverlay() {
    // 自身拖拽手柄期间不弹（菜单已按拖动开始时的约定暂时隐藏，
    // 松手后由 onDragEnd 统一重弹）
    if (_draggingOwnHandles) return;
    if (_menuOverlayEntry != null || !mounted || _regionState == null) return;
    _menuOverlayEntry = OverlayEntry(
      builder: (context) {
        try {
          _menuAnchorFailures = 0;
          return styledSelectableRegionContextMenu(
            context,
            _regionState!,
            // 复制后（Android 清选区 / iOS 保留）统一在此收尾：撤掉菜单与
            // 手柄并退出选取模式，不依赖 onSelectionChanged 的时序
            onCopyDone: () {
              _removeSelectMenuOverlay();
              _removeHandlesOverlay();
              _exit();
            },
          );
        } catch (e) {
          // 派发建立的选区不会填充 SDK 的字形高度缓存，selectableRegion
          // 的 contextMenuAnchors 在其就绪前会空崩溃（release 下破坏整帧，
          // 连带选区高亮一起消失）。降级为本帧不显示并逐帧重试，几何
          // 就绪后菜单自然弹出；持续失败（约 200ms）说明选区已不可用，
          // 强制退出避免「选取模式卡死且无菜单」
          _menuAnchorFailures++;
          debugPrint('[选取] 菜单锚点未就绪 x$_menuAnchorFailures: $e');
          // 这里不再附加 _hadSelection 条件：锚点算不出来时选区多半并不
          // 存在，若继续逐帧 markNeedsBuild 重排自己，就会留下一个永远
          // 空转的菜单浮层（后台越叠越多），必须到上限直接收场
          if (_menuAnchorFailures >= 12) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                _exit();
              }
            });
            return const SizedBox.shrink();
          }
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _menuOverlayEntry != null) {
              _menuOverlayEntry!.markNeedsBuild();
            }
          });
          return const SizedBox.shrink();
        }
      },
    );
    Overlay.of(context, rootOverlay: true).insert(_menuOverlayEntry!);
  }

  void _showHandlesOverlay() {
    if (_handlesOverlayEntry != null ||
        !mounted ||
        _regionState == null ||
        _delegate == null) {
      return;
    }
    // 故障隔离：手柄浮层的任何异常都不应拖累选区与统一菜单
    try {
      _handlesOverlayEntry = OverlayEntry(
        builder: (context) => SelectionHandles(
          delegate: _delegate!,
          link: _regionLink,
          regionContext: _regionState!.context,
          onDragStart: () {
            _draggingOwnHandles = true;
            // 与滚动行为一致：拖动调整选区期间菜单暂时隐藏
            _removeSelectMenuOverlay();
          },
          onDragEnd: () {
            _draggingOwnHandles = false;
            // 拖动可能把选区拖成空（塌缩），补一次退出检查
            _handleDelegateChanged();
            // 未退出则在新的选区位置重新弹出菜单
            if (!_exited && mounted) {
              _showSelectMenuOverlay();
            }
          },
          // 拖动过程中与结束时都让统一菜单锚点随新选区实时更新
          onAdjusted: () => _menuOverlayEntry?.markNeedsBuild(),
        ),
      );
      Overlay.of(context, rootOverlay: true).insert(_handlesOverlayEntry!);
    } catch (e) {
      _handlesOverlayEntry = null;
    }
  }

  void _removeSelectMenuOverlay() {
    // 探针卸载时其会话会播放收起动画后再移除菜单浮层
    _menuOverlayEntry?.remove();
    _menuOverlayEntry = null;
  }

  void _removeHandlesOverlay() {
    _handlesOverlayEntry?.remove();
    _handlesOverlayEntry = null;
  }

  /// 在单个段落里找 pressGlobal 就近的文本行，返回该行首/尾的全局坐标
  _LineTarget? _nearestLineInParagraph(
      RenderParagraph paragraph, Offset pressGlobal) {
    if (!paragraph.hasSize || paragraph.text.toPlainText().trim().isEmpty) {
      return null;
    }

    final Size pSize = paragraph.size;
    final Offset local = paragraph.globalToLocal(pressGlobal);
    final double dx = local.dx.clamp(0.0, pSize.width);
    final double dy = local.dy.clamp(0.0, pSize.height);

    // 按住点（或其在段内的竖向投影）所在行的行高范围
    final TextBox? probeBox = _charBoxAt(
        paragraph, paragraph.getPositionForOffset(Offset(dx, dy)).offset);
    if (probeBox == null) return null;
    final double centerY = (probeBox.top + probeBox.bottom) / 2;

    // 行首 / 行尾字符位置（取该行垂直中心扫左右两端）
    final TextBox? startBox = _charBoxAt(paragraph,
        paragraph.getPositionForOffset(Offset(0, centerY)).offset);
    final TextBox? endBox = _charBoxAt(
        paragraph,
        paragraph
            .getPositionForOffset(Offset(pSize.width, centerY))
            .offset);
    if (startBox == null || endBox == null) return null;

    final Offset start =
        paragraph.localToGlobal(Offset(startBox.left + 2, centerY));
    final Offset end =
        paragraph.localToGlobal(Offset(endBox.right - 2, centerY));

    // 就近距离（段内局部坐标）：按住点到该行竖向带状区间的距离
    //（行内为 0）。注意 probeBox 是局部坐标，不能与全局 pressGlobal 直接比
    final double distance;
    if (local.dy < probeBox.top) {
      distance = probeBox.top - local.dy;
    } else if (local.dy > probeBox.bottom) {
      distance = local.dy - probeBox.bottom;
    } else {
      distance = 0;
    }

    return _LineTarget(start, end, distance);
  }

  /// offset 处单个字符的排版盒（行位置与行高的来源）
  TextBox? _charBoxAt(RenderParagraph paragraph, int offset) {
    final int length = paragraph.text.toPlainText().length;
    if (length == 0) return null;
    final int index = offset.clamp(0, length - 1);
    final List<TextBox> boxes = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: index, extentOffset: index + 1),
    );
    return boxes.isEmpty ? null : boxes.first;
  }

  @override
  Widget build(BuildContext context) {
    return SelectionArea(
      onSelectionChanged: _handleSelectionChanged,
      // 隐藏 SelectableRegion 自带的两端水滴：其拖动手势不支持鼠标
      // （SDK 手柄 supportedDevices 只认 touch/stylus，Windows debug 上
      // 无法拖动），选取模式的手柄统一由自绘浮层 SelectionHandles 接管
      // （GestureDetector 无设备限制，桌面/触摸一致）
      selectionControls: _invisibleSelectionHandleControls,
      contextMenuBuilder: (context, selectableRegion) {
        // SDK 路径（用户长按/拖动）呼出的同款统一菜单
        return styledSelectableRegionContextMenu(context, selectableRegion);
      },
      child: CompositedTransformTarget(
        // 手柄跟随层的锚点盒子：与正文内容盒重合，滚动时跟随层自动换算
        link: _regionLink,
        child: Builder(
          builder: (context) {
            // 捕获正文所在的区域委托与区域状态（build 期查找一次即可）。
            // 子树结构必须保持恒定：任何换父级重构都会使段落渲染对象
            // 重建、派发出的选区丢失；统一菜单因此走独立 OverlayEntry
            if (_delegate == null) {
              _delegate = SelectionContainer.maybeOf(context)
                  as MultiSelectableSelectionContainerDelegate?;
              _regionState ??=
                  context.findAncestorStateOfType<SelectableRegionState>();
              _delegate!.addListener(_handleDelegateChanged);
            }
            return widget.child;
          },
        ),
      ),
    );
  }
}

/// 隐藏 SelectableRegion 自带选择手柄的 controls：
/// buildHandle 返回空、尺寸归零 —— 手柄完全不可见、不可交互，
/// 选取模式的两端拖拽全部交给自绘浮层 SelectionHandles
/// （其手势无设备限制，鼠标/触摸都能拖；原生手柄的 supportedDevices
/// 只认 touch/stylus，桌面 debug 上无法拖动）。
class _InvisibleSelectionHandleControls extends MaterialTextSelectionControls
    with TextSelectionHandleControls {
  @override
  Size getHandleSize(double textLineHeight) => Size.zero;

  @override
  Widget buildHandle(
    BuildContext context,
    TextSelectionHandleType type,
    double textLineHeight, [
    VoidCallback? onTap,
  ]) =>
      const SizedBox.shrink();

  @override
  Offset getHandleAnchor(TextSelectionHandleType type, double textLineHeight) =>
      Offset.zero;
}

final _InvisibleSelectionHandleControls _invisibleSelectionHandleControls =
    _InvisibleSelectionHandleControls();

/// 自动选行的目标：行首/行尾全局坐标 + 到按住点的就近距离
class _LineTarget {
  const _LineTarget(this.start, this.end, this.distance);

  final Offset start;
  final Offset end;
  final double distance;
}
