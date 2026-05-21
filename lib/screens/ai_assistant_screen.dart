import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';
import '../services/glm_service.dart';
import '../utils/storage.dart';
import '../models/course.dart';
import '../models/task.dart';
import '../dialogs/course_dialog.dart';
import 'settings_screen.dart';

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

class AIAssistantScreenState extends State<AIAssistantScreen> with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  static List<_ChatMessage> _persistentMessages = [];
  static String? _persistentSelectedModel;
  static bool _hasAnalyzed = false;
  static double _persistentScrollOffset = 0.0;
  static bool _needsRefresh = false;
  static bool _isAnalyzing = false;
  static final ValueNotifier<int> _streamUpdateTick = ValueNotifier<int>(0);
  
  static bool _isLoading = false;
  static bool _isFirstChunkReceived = false;
  bool _fastModeEnabled = false;
  bool _showSlowResponseTip = false;
  bool _aiEnabled = false;
  bool _supportsImageUpload = false;
  static bool _isSearching = false;
  static bool _isReasoningModel = false;
  bool _hasSentContext = false;
  static bool _isThinking = false;
  static bool _isThinkingCollapsed = false;
  bool _showAddMenu = false;
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
  double _inputAreaExtraHeight = 0;
  double _textLinesExtraHeight = 0;
  static const double _kTextLineHeight = 21.0;
  late final AnimationController _keyboardDismissAnimController;
  Animation<double>? _keyboardDismissAnimation;
  Animation<double>? _keyboardDismissBounceAnimation;
  int _retryCount = 0;
  static const int _maxRetryCount = 2;
  static const Duration _noResponseTimeout = Duration(seconds: 30);
  Timer? _noResponseTimer;
  String? _lastUserMessage;
  String? _lastImageBase64;
  List<Map<String, String>>? _lastHistory;
  bool _stopRequested = false;
  late List<_ChatMessage> _messages;
  late String? _selectedModel;
  String? _selectedImagePath;
  String? _selectedImageBase64;
  double? _selectedImageAspectRatio;
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
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
    final changed =
        persistentLast.role != localLast.role ||
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

  void scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottom();
    });
  }

  void saveScrollPosition() {
    if (_scrollController.hasClients) {
      _persistentScrollOffset = _scrollController.offset;
      debugPrint('[AI Assistant] Saved scroll position: $_persistentScrollOffset');
    }
  }

  void restoreScrollPosition() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients && _persistentScrollOffset > 0) {
        _scrollController.jumpTo(_persistentScrollOffset);
        debugPrint('[AI Assistant] Restored scroll position: $_persistentScrollOffset');
      }
    });
  }

  static const List<Map<String, dynamic>> _fastModels = [
    {'name': 'DeepSeek-R1', 'supportsImage': false, 'provider': 'doubao', 'supportsWebSearch': false, 'isReasoningModel': true},
    {'name': 'DeepSeek-V3.2', 'supportsImage': false, 'provider': 'doubao', 'supportsWebSearch': true},
    {'name': 'DeepSeek-V3.1', 'supportsImage': false, 'provider': 'doubao', 'supportsWebSearch': true},
  ];

  static const List<Map<String, dynamic>> _doubaoNormalModels = [
    {'name': 'DeepSeek-R1', 'supportsImage': false, 'provider': 'doubao', 'supportsWebSearch': false, 'isReasoningModel': true},
    {'name': 'DeepSeek-V3.2', 'supportsImage': false, 'provider': 'doubao', 'supportsWebSearch': true},
    {'name': 'DeepSeek-V3.1', 'supportsImage': false, 'provider': 'doubao', 'supportsWebSearch': true},
    {'name': 'Doubao-Seed-2.0-pro', 'supportsImage': true, 'provider': 'doubao', 'supportsWebSearch': true},
    {'name': 'Doubao-Seed-2.0-mini', 'supportsImage': true, 'provider': 'doubao', 'supportsWebSearch': true},
    {'name': 'GLM-4.7', 'supportsImage': false, 'provider': 'doubao', 'supportsWebSearch': true},
  ];

  static const List<Map<String, dynamic>> _hunyuanModels = [
    {'name': 'hunyuan-lite', 'supportsImage': false, 'provider': 'hunyuan', 'supportsWebSearch': false},
  ];

  static const List<Map<String, dynamic>> _glmModels = [
    {'name': 'GLM-4.7-Flash', 'supportsImage': false, 'provider': 'glm', 'supportsWebSearch': false},
  ];

  List<Map<String, dynamic>> get _normalModels {
    if (_currentProvider == 'hunyuan') {
      return _hunyuanModels;
    } else if (_currentProvider == 'glm') {
      return _glmModels;
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
    _messageController.addListener(_updateTextLinesExtraHeight);
    _messages = _persistentMessages;
    _selectedModel = _persistentSelectedModel;
    _loadFastModeSettingAndAnalyze();

    _keyboardDismissAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    _keyboardDismissAnimController.addListener(() {
      final animation = _keyboardDismissAnimation;
      final bounceAnimation = _keyboardDismissBounceAnimation;
      if ((animation == null && bounceAnimation == null) || !mounted) return;
      setState(() {
        if (animation != null) {
          _layoutKeyboardHeight = animation.value;
        }
        _keyboardDismissBounceOffset = bounceAnimation?.value ?? 0;
      });
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
    final provider = prefs.getString('ai_provider') ?? 'hunyuan';
    _customModelName = (prefs.getString('custom_api_model')?.trim().isNotEmpty ?? false)
        ? prefs.getString('custom_api_model')!.trim()
        : 'gpt-4o-mini';
    debugPrint('Fast mode setting loaded: $fastModeEnabled, AI enabled: $aiEnabled, Provider: $provider');
    
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
    } else if (provider == 'custom') {
      defaultModel = _customModelName;
      fastModeAvailable = false;
      customReasoning = await AIService.instance.getCachedReasoningCapability(model: _customModelName);
      customVision = await AIService.instance.getCustomVisionSupport(model: _customModelName) ?? false;
    }
    
    final actualFastModeEnabled = fastModeAvailable ? fastModeEnabled : false;
    
    final providerChanged = _currentProvider.isNotEmpty && provider != _currentProvider;
    
    String? newSelectedModel = _selectedModel;
    
    List<Map<String, dynamic>> providerModels;
    if (provider == 'hunyuan') {
      providerModels = _hunyuanModels;
    } else if (provider == 'glm') {
      providerModels = _glmModels;
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
        debugPrint('[AI Assistant] Init: Provider changed to $provider, new model: $newSelectedModel');
      } else {
        final modelNames = providerModels.map((m) => m['name'] as String).toList();
        newSelectedModel = _getRandomModel(modelNames);
        debugPrint('[AI Assistant] Init: Provider changed to $provider, random model: $newSelectedModel');
      }
    } else if (_selectedModel == null) {
      if (actualFastModeEnabled) {
        final fastModelNames = _fastModels.map((m) => m['name'] as String).toList();
        newSelectedModel = _getRandomModel(fastModelNames);
        debugPrint('[AI Assistant] Init: No model selected, fast mode enabled, random model: $newSelectedModel');
      } else if (defaultModel != null) {
        newSelectedModel = defaultModel;
        debugPrint('[AI Assistant] Init: No model selected, using default: $newSelectedModel');
      } else {
        final modelNames = providerModels.map((m) => m['name'] as String).toList();
        newSelectedModel = _getRandomModel(modelNames);
        debugPrint('[AI Assistant] Init: No model selected, $provider random model: $newSelectedModel');
      }
    }

    final activeModels = actualFastModeEnabled ? _fastModels : providerModels;
    final activeModelNames = activeModels.map((m) => m['name'] as String).toList();
    final modelStillAvailable =
        newSelectedModel != null && activeModelNames.contains(newSelectedModel);
    if (!modelStillAvailable && activeModelNames.isNotEmpty) {
      newSelectedModel = _getRandomModel(activeModelNames);
      debugPrint('[AI Assistant] Init: Switched mode/provider, previous model unavailable, random fallback: $newSelectedModel');
    }
    
    final reasoningEffortStr = prefs.getString('custom_api_reasoning_effort') ?? '';
    final webSearchEnabled = prefs.getBool('web_search_enabled') ?? false;
    
    setState(() {
      _fastModeEnabled = actualFastModeEnabled;
      _aiEnabled = aiEnabled;
      _currentProvider = provider;
      _customModelIsReasoning = customReasoning;
      _customModelSupportsVision = customVision;
      _currentReasoningEffort = reasoningEffortStr.isNotEmpty ? reasoningEffortStr : null;
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
    
    if (!_aiEnabled) {
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

  void _startKeyboardDismissAnimation() {
    if (_layoutKeyboardHeight <= 0.5) {
      if (_layoutKeyboardHeight != 0 || _keyboardDismissBounceOffset != 0) {
        setState(() {
          _layoutKeyboardHeight = 0;
          _keyboardDismissBounceOffset = 0;
        });
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
        tween: Tween(begin: 0.0, end: 3.5).chain(CurveTween(curve: Curves.easeOut)),
        weight: 12,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 3.5, end: 0.0).chain(CurveTween(curve: Curves.easeOutBack)),
        weight: 13,
      ),
    ]).animate(_keyboardDismissAnimController);
    _keyboardDismissAnimController.forward(from: 0);
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    final view = View.of(context);
    final mediaQuery = MediaQuery.maybeOf(context);
    final keyboardHeight = mediaQuery?.viewInsets.bottom ?? (view.viewInsets.bottom / view.devicePixelRatio);
    final isKeyboardVisible = keyboardHeight > 0;
    final previousKeyboardHeight = _lastKeyboardHeight;
    final wasVisible = previousKeyboardHeight > 0;
    final isKeyboardRising = keyboardHeight > previousKeyboardHeight + 0.5;
    final isKeyboardFalling = keyboardHeight < previousKeyboardHeight - 0.5;
    final shouldStickToBottom = _isNearBottom();
    
    debugPrint('didChangeMetrics: keyboardHeight=$keyboardHeight, wasVisible=$wasVisible, isKeyboardVisible=$isKeyboardVisible');
    
    _lastKeyboardHeight = keyboardHeight;

    if (isKeyboardRising || (isKeyboardVisible && !isKeyboardFalling)) {
      if (_keyboardDismissAnimController.isAnimating) {
        _keyboardDismissAnimController.stop();
      }
      final shouldUpdateHeight = (_layoutKeyboardHeight - keyboardHeight).abs() > 0.5;
      final shouldResetBounce = _keyboardDismissBounceOffset != 0;
      if (shouldUpdateHeight || shouldResetBounce) {
        setState(() {
          if (shouldUpdateHeight) {
            _layoutKeyboardHeight = keyboardHeight;
          }
          if (shouldResetBounce) {
            _keyboardDismissBounceOffset = 0;
          }
        });
      }
    } else if (isKeyboardFalling && !_keyboardDismissAnimController.isAnimating) {
      _startKeyboardDismissAnimation();
    } else if (!isKeyboardVisible && !_keyboardDismissAnimController.isAnimating && (_layoutKeyboardHeight != 0 || _keyboardDismissBounceOffset != 0)) {
      setState(() {
        _layoutKeyboardHeight = 0;
        _keyboardDismissBounceOffset = 0;
      });
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
    final provider = prefs.getString('ai_provider') ?? 'hunyuan';
    _customModelName = (prefs.getString('custom_api_model')?.trim().isNotEmpty ?? false)
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
    } else if (provider == 'custom') {
      defaultModel = _customModelName;
      fastModeAvailable = false;
      customReasoning = await AIService.instance.getCachedReasoningCapability(model: _customModelName);
      customVision = await AIService.instance.getCustomVisionSupport(model: _customModelName) ?? false;
    }
    
    final newFastModeEnabled = fastModeAvailable ? (prefs.getBool('fast_mode_enabled') ?? false) : false;
    final newAiEnabled = prefs.getBool('ai_enabled') ?? false;
    
    final providerChanged = _currentProvider.isNotEmpty && provider != _currentProvider;
    
    String? newSelectedModel = _selectedModel;
    
    List<Map<String, dynamic>> providerModels;
    if (provider == 'hunyuan') {
      providerModels = _hunyuanModels;
    } else if (provider == 'glm') {
      providerModels = _glmModels;
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
        debugPrint('[AI Assistant] Provider changed to $provider, new model: $newSelectedModel');
      } else {
        final modelNames = providerModels.map((m) => m['name'] as String).toList();
        newSelectedModel = _getRandomModel(modelNames);
        debugPrint('[AI Assistant] Provider changed to $provider, random model: $newSelectedModel');
      }
    } else if (_selectedModel == null) {
      if (newFastModeEnabled) {
        final fastModelNames = _fastModels.map((m) => m['name'] as String).toList();
        newSelectedModel = _getRandomModel(fastModelNames);
        debugPrint('[AI Assistant] No model selected, fast mode enabled, random model: $newSelectedModel');
      } else if (defaultModel != null) {
        newSelectedModel = defaultModel;
        debugPrint('[AI Assistant] No model selected, using default: $newSelectedModel');
      } else {
        final modelNames = providerModels.map((m) => m['name'] as String).toList();
        newSelectedModel = _getRandomModel(modelNames);
        debugPrint('[AI Assistant] No model selected, $provider random model: $newSelectedModel');
      }
    }

    final activeModels = newFastModeEnabled ? _fastModels : providerModels;
    final activeModelNames = activeModels.map((m) => m['name'] as String).toList();
    final modelStillAvailable =
        newSelectedModel != null && activeModelNames.contains(newSelectedModel);
    if (!modelStillAvailable && activeModelNames.isNotEmpty) {
      newSelectedModel = _getRandomModel(activeModelNames);
      debugPrint('[AI Assistant] Runtime refresh: previous model unavailable in current mode, random fallback: $newSelectedModel');
    }
    
    setState(() {
      _fastModeEnabled = newFastModeEnabled;
      _aiEnabled = newAiEnabled;
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
  }

  void _triggerCustomVisionProbeSilently() {
    if (_currentProvider != 'custom') return;
    final model = (_selectedModel ?? _customModelName).trim();
    if (model.isEmpty) return;

    unawaited(() async {
      final manualOverride = await AIService.instance.isCustomVisionManualOverrideEnabled();
      if (manualOverride) return;

      final probed = await AIService.instance.probeCustomVisionSupport(model: model);
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
    if (!_needsRefresh) {
      return;
    }
    _needsRefresh = false;
    await _loadFastModeSetting();
  }

  void _startSlowResponseTimer() {
    _cancelSlowResponseTimer();
    _slowResponseTimer = Timer(const Duration(seconds: 10), () {
      if (_shouldShowFastModeSlowTip && (_isLoading || _isAnalyzing) && !_isFirstChunkReceived) {
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
    debugPrint('[AI Assistant] Starting no-response timer (${_noResponseTimeout.inSeconds}s), retry count: $_retryCount/$_maxRetryCount');
    _noResponseTimer = Timer(_noResponseTimeout, () {
      if ((_isLoading || _isAnalyzing) && !_stopRequested) {
        debugPrint('[AI Assistant] No response timeout triggered, isFirstChunkReceived: $_isFirstChunkReceived');
        if (_retryCount < _maxRetryCount) {
          _retryWithAutoRecovery();
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
    final hasOutput = requireContent ? _streamingContent.isNotEmpty : _hasStreamingOutput();
    return !hasOutput && _canAutoRetryNow();
  }

  bool _shouldRetryForAnalyzeCompletion() {
    final requireContentForCurrentProvider = _currentProvider != 'doubao';
    return _shouldRetryForEmptyCompletion(requireContent: requireContentForCurrentProvider);
  }

  bool _hasCompletionOutputForCurrentProvider() {
    if (_currentProvider == 'doubao') {
      return _hasStreamingOutput();
    }
    return _streamingContent.isNotEmpty;
  }

  void _retryWithAutoRecovery() {
    if (_stopRequested) {
      debugPrint('[AI Assistant] Retry skipped because stop was requested');
      return;
    }
    debugPrint('[AI Assistant] Auto-retrying request, attempt ${_retryCount + 1}/$_maxRetryCount');
    _retryCount++;
    
    _streamSubscription?.cancel();
    _cancelSlowResponseTimer();
    
    setState(() {
      _isFirstChunkReceived = false;
      _streamingContent = '';
      _statusMessage = '';
      _isSearching = false;
      _isThinking = false;
      _thinkingContent = '';
    });

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
        content: '⚠️ 请求超时，已自动重试 $_maxRetryCount 次仍无响应。\n\n可能的原因：\n• 网络连接不稳定\n• AI 服务暂时不可用\n• 当前模型响应较慢\n\n请检查网络连接后重试，或尝试切换其他模型。',
        isError: true,
      ));
    });
    _persistentMessages = List.from(_messages);
    _publishStreamUpdate();
    _scrollToBottom();
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

  Future<void> _executeAnalyzeSchedule({bool isRetry = false}) async {
    if (_stopRequested) {
      debugPrint('[AI Assistant] Analyze execution skipped because stop was requested');
      return;
    }
    if (isRetry) {
      debugPrint('[AI Assistant] Retrying schedule analysis');
      setState(() {
        _statusMessage = '自动重试中... (${_retryCount}/$_maxRetryCount)';
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

    final coursesInfo = courses.map((c) {
      final startTime = c.time + 1;
      final endTime = startTime + c.duration - 1;
      return {
        'name': c.name,
        'teacher': c.teacher ?? '未知',
        'location': c.location ?? '未知',
        'day': _getDayName(c.day),
        'time': '第${startTime}-${endTime}节',
        'weeks': c.weeks ?? '全周',
      };
    }).toList();

    final tasksInfo = upcomingTasks.map((t) => {
      'name': t.name,
      'type': t.type,
      'dueDate': DateFormat('MM-dd HH:mm').format(t.dueDate),
      'priority': t.priority,
    }).toList();

    String prompt;
    final now = DateTime.now();
    final timeSlots = StorageService.getTimeSlots();
    final currentPeriodFromStatus = currentStatus['currentPeriod'] as int?;
    
    if (currentStatus['status'] == 'finished') {
      final tomorrowInfo = tomorrowCourses.isEmpty 
        ? '明天没有课程 🎉' 
        : tomorrowCourses.map((c) {
            final timeStr = _getCourseTimeStr(c, timeSlots);
            return '• $timeStr ${c.name} (${c.teacher ?? '未知'}) @ ${c.location ?? '未知'}';
          }).join('\n');
      
      prompt = '''📚 当前所有课程（共${courses.length}门，当前第${StorageService.getCurrentWeek()}周）：
${coursesInfo.isEmpty ? '暂无课程' : coursesInfo.map((c) => '• ${c['day']} ${c['time']} ${c['name']} (${c['teacher']}) @ ${c['location']}${c['weeks'] != '全周' ? ' [${c['weeks']}周]' : ''}').join('\n')}

📅 明天的课程：
$tomorrowInfo

📝 近期待办任务（7天内，共${upcomingTasks.length}个）：
${tasksInfo.isEmpty ? '暂无待办任务 ✨' : tasksInfo.map((t) => '• [${t['priority']}] ${t['name']} (${t['type']}) 截止: ${t['dueDate']}').join('\n')}

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
        
        prompt = '''📚 当前所有课程（共${courses.length}门，当前第${StorageService.getCurrentWeek()}周）：
${coursesInfo.isEmpty ? '暂无课程' : coursesInfo.map((c) => '• ${c['day']} ${c['time']} ${c['name']} (${c['teacher']}) @ ${c['location']}${c['weeks'] != '全周' ? ' [${c['weeks']}周]' : ''}').join('\n')}

📅 今天没有课程 🎉

📅 明天的课程：
$tomorrowInfo

📝 近期待办任务（7天内，共${upcomingTasks.length}个）：
${tasksInfo.isEmpty ? '暂无待办任务 ✨' : tasksInfo.map((t) => '• [${t['priority']}] ${t['name']} (${t['type']}) 截止: ${t['dueDate']}').join('\n')}

今天没有课程，请用简洁友好的方式，适当使用emoji：
1. 告知用户今天没有课程
2. 简要介绍明天的课程安排（如果有课的话）
3. 提醒近期重要的任务截止时间
4. 给出学习建议

直接开始回答，不要有开场白。''';
        
        try {
          debugPrint('[AI Assistant] Executing analyze stream request, model: $_selectedModel');
          
          final stream = AIService.instance.chatWithModelStream(
            userMessage: prompt,
            model: _selectedModel,
            systemPrompt: '你是一个学习助手，帮助大学生管理课程和任务，解决学习问题。使用markdown格式。',
            fastMode: _fastModeEnabled,
            provider: _currentProvider,
            reasoningEffort: _currentReasoningEffort,
          );

          _streamSubscription = stream.listen(
            (chunk) {
              if (!_isFirstChunkReceived) {
                _cancelSlowResponseTimer();
                _cancelNoResponseTimer();
                _hideSlowResponseTip();
                debugPrint('[AI Assistant] First chunk received in analyze, canceling timeout timers');
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
              debugPrint('[AI Assistant] Analyze stream completed (no_class_today)');
              _cancelSlowResponseTimer();
              _cancelNoResponseTimer();
              _hideSlowResponseTip();
              
              if (!_hasCompletionOutputForCurrentProvider()) {
                debugPrint('[AI Assistant] Analyze stream completed with empty content, retry count: $_retryCount/$_maxRetryCount');
                if (_shouldRetryForAnalyzeCompletion()) {
                  _retryWithAutoRecovery();
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
                _selectedModel ??= AIService.instance.lastStreamedModel;
                _persistentSelectedModel = _selectedModel;
                final thinkingToSave = _thinkingContent.isNotEmpty ? _thinkingContent : null;
                _messages.add(_ChatMessage(
                  role: 'assistant',
                  content: _streamingContent,
                  isWelcome: true,
                  thinkingContent: thinkingToSave,
                ));
                _streamingContent = '';
                _thinkingContent = '';
                _hasAnalyzed = true;
              });
              _persistentMessages = List.from(_messages);
              _publishStreamUpdate();
              _resetRetryState();
              _updateSupportsImageUpload();
              _scrollToBottom();
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

      prompt = '''📚 当前所有课程（共${courses.length}门，当前第${StorageService.getCurrentWeek()}周）：
${coursesInfo.isEmpty ? '暂无课程' : coursesInfo.map((c) => '• ${c['day']} ${c['time']} ${c['name']} (${c['teacher']}) @ ${c['location']}${c['weeks'] != '全周' ? ' [${c['weeks']}周]' : ''}').join('\n')}

📅 今天的课程安排：
$todayInfo

📝 近期待办任务（7天内，共${upcomingTasks.length}个）：
${tasksInfo.isEmpty ? '暂无待办任务 ✨' : tasksInfo.map((t) => '• [${t['priority']}] ${t['name']} (${t['type']}) 截止: ${t['dueDate']}').join('\n')}

请用简洁友好的方式，适当使用emoji：
1. 根据当前时间提醒用户课程状态（如正在上课还有几分钟下课，或课间休息几分钟后上课）
2. 介绍今天剩余的课程安排
3. 提醒近期重要的任务截止时间
4. 给出学习建议

直接开始回答，不要有开场白。''';
    }

    try {
      debugPrint('[AI Assistant] Executing analyze stream request, model: $_selectedModel');
      
      final stream = AIService.instance.chatWithModelStream(
        userMessage: prompt,
        model: _selectedModel,
        systemPrompt: '你是一个学习助手，帮助大学生管理课程和任务，解决学习问题。使用markdown格式。',
        fastMode: _fastModeEnabled,
        provider: _currentProvider,
        reasoningEffort: _currentReasoningEffort,
      );

      _streamSubscription = stream.listen(
        (chunk) {
          if (!_isFirstChunkReceived) {
            _cancelSlowResponseTimer();
            _cancelNoResponseTimer();
            _hideSlowResponseTip();
            debugPrint('[AI Assistant] First chunk received in analyze, canceling timeout timers');
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
            debugPrint('[AI Assistant] Analyze stream completed with empty content, retry count: $_retryCount/$_maxRetryCount');
            if (_shouldRetryForAnalyzeCompletion()) {
              _retryWithAutoRecovery();
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
            _selectedModel ??= AIService.instance.lastStreamedModel;
            _persistentSelectedModel = _selectedModel;
            final thinkingToSave = _thinkingContent.isNotEmpty ? _thinkingContent : null;
            _messages.add(_ChatMessage(
              role: 'assistant',
              content: _streamingContent,
              isWelcome: true,
              thinkingContent: thinkingToSave,
            ));
            _streamingContent = '';
            _thinkingContent = '';
            _hasAnalyzed = true;
          });
          _persistentMessages = List.from(_messages);
          _publishStreamUpdate();
          _resetRetryState();
          _updateSupportsImageUpload();
          _scrollToBottom();
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
    }).toList()..sort((a, b) => a.time.compareTo(b.time));
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
          if (start != null && end != null && currentWeek >= start && currentWeek <= end) {
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
      final firstSlotStart = firstSlot != null ? _parseTime(firstSlot['start']!, now) : null;
      
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
          final courseInSlot = todayCourses.where((c) => c.time == i).firstOrNull;
          if (courseInSlot != null) {
            return {
              'status': 'break',
              'currentPeriod': i - 1,  // 返回上一节课的索引，用于过滤剩余课程
              'nextCourse': courseInSlot,
              'waitingMinutes': waitingMinutes,
              'message': '课间休息，${waitingMinutes}分钟后上${courseInSlot.name}',
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

    final currentCourse = todayCourses.where((c) => 
      c.time <= currentPeriod && c.time + c.duration > currentPeriod
    ).firstOrNull;

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

    final nextCourse = todayCourses.where((c) => c.time > currentPeriod).firstOrNull;
    if (nextCourse != null) {
      final slot = timeSlots[nextCourse.time];
      final startTime = _parseTime(slot['start']!, now);
      final waitingMinutes = startTime.difference(now).inMinutes;
      
      return {
        'status': 'break',
        'currentPeriod': currentPeriod,
        'nextCourse': nextCourse,
        'waitingMinutes': waitingMinutes,
        'message': '课间休息，${waitingMinutes}分钟后上${nextCourse.name}',
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
    return tasks.where((t) => t.dueDate.isAfter(now) && t.dueDate.isBefore(weekLater))
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
    final startSlot = course.time >= 0 && course.time < timeSlots.length ? timeSlots[course.time] : null;
    final endSlotIndex = course.time + course.duration - 1;
    final endSlot = endSlotIndex >= 0 && endSlotIndex < timeSlots.length ? timeSlots[endSlotIndex] : null;
    if (startSlot != null && endSlot != null) {
      return '${startSlot['start']}-${endSlot['end']}';
    }
    return '第${startTime}-${endTime}节';
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
        debugPrint('🔍 匹配课程: 输入="$courseName", 课程列表=${courses.map((c) => c.name).toList()}');
        final matchedCourses = courses.where(
          (c) => c.name == courseName || c.name.contains(courseName) || courseName.contains(c.name),
        ).toList();
        debugPrint('🔍 匹配结果: ${matchedCourses.map((c) => c.name).toList()}');
        if (matchedCourses.isNotEmpty) {
          courseId = 'course_name:${matchedCourses.first.name}';
          matchedCourseName = matchedCourses.first.name;
        }
      }
      
      final now = DateTime.now();
      final dateParts = dueDateStr.split(' ');
      final monthDay = dateParts[0].split('-');
      final hourMinute = dateParts.length > 1 ? dateParts[1].split(':') : ['23', '59'];
      
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
      
      debugPrint('🔍 最终结果: courseId=$courseId, matchedCourseName=$matchedCourseName');
      
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
        final matchedCourses = courses.where(
          (c) => c.name == newCourseName || c.name.contains(newCourseName) || newCourseName.contains(c.name),
        ).toList();
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
        final hourMinute = dateParts.length > 1 ? dateParts[1].split(':') : ['23', '59'];
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

  String _handleAddCourse(Map<String, dynamic> json, String originalContent) {
    try {
      final name = json['name'] as String?;
      final dayStr = json['day'] as String?;
      final time = json['time'] as int?;
      final duration = json['duration'] as int? ?? 2;
      final location = json['location'] as String?;
      final teacher = json['teacher'] as String?;
      final weeks = json['weeks'] as String?;
      
      debugPrint('[AI Assistant] _handleAddCourse: name=$name, day=$dayStr, time=$time, duration=$duration, location=$location, teacher=$teacher, weeks=$weeks');
      debugPrint('[AI Assistant] Full JSON: $json');
      
      if (name == null || dayStr == null || time == null) {
        return originalContent;
      }
      
      final dayMap = {
        '周一': 0, '周二': 1, '周三': 2, '周四': 3, '周五': 4, '周六': 5, '周日': 6,
        '星期一': 0, '星期二': 1, '星期三': 2, '星期四': 3, '星期五': 4, '星期六': 5, '星期日': 6,
      };
      final day = dayMap[dayStr];
      if (day == null) {
        return '❌ 无法识别的星期：$dayStr，请使用"周一"到"周日"格式。';
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

  String _handleModifyCourse(Map<String, dynamic> json, String originalContent) {
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
          '周一': 0, '周二': 1, '周三': 2, '周四': 3, '周五': 4, '周六': 5, '周日': 6,
          '星期一': 0, '星期二': 1, '星期三': 2, '星期四': 3, '星期五': 4, '星期六': 5, '星期日': 6,
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

  String _handleDeleteCourse(Map<String, dynamic> json, String originalContent) {
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
      
      final coursesInfo = courses.map((c) {
        final startTime = c.time + 1;
        final endTime = startTime + c.duration - 1;
        return '${c.name}|${_getDayName(c.day)}|第${startTime}-${endTime}节|${c.duration}节|${c.location ?? "未知"}|${c.teacher ?? "未知"}|${c.weeks ?? "全周"}';
      }).join('\n');

      final tasksInfo = tasks.map((t) {
        return '${t.name}|${t.type}|${DateFormat('MM-dd HH:mm').format(t.dueDate)}|${t.priority}|${t.note ?? ""}';
      }).join('\n');
      
      dataSection = '''
📚 当前所有课程（共${courses.length}门）：
课程名称|星期|开始节次|持续节数|地点|教师|周次
${coursesInfo.isEmpty ? '暂无课程' : coursesInfo}

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
当前周次：第${StorageService.getCurrentWeek()}周

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

其他情况下，请用简洁友好的方式回答用户问题，可以适当使用emoji。''';
  }

  String _buildContextForR1() {
    final courses = StorageService.getCourses();
    final tasks = StorageService.getTasks();
    final now = DateTime.now();
    
    final coursesInfo = courses.map((c) {
      final startTime = c.time + 1;
      final endTime = startTime + (c.duration ?? 2) - 1;
      return '${_getDayName(c.day)}第${startTime}-${endTime}节: ${c.name} @${c.location ?? "未知"} ${c.teacher ?? ""} ${c.weeks != null ? "(周次: ${c.weeks})" : ""}';
    }).join('\n');

    final tasksInfo = tasks.map((t) {
      return '[${t.priority}] ${t.name} (${t.type}) 截止: ${DateFormat('MM-dd HH:mm').format(t.dueDate)}';
    }).join('\n');

    return '''【背景信息】
当前时间：${DateFormat('yyyy-MM-dd HH:mm').format(now)}
当前周次：第${StorageService.getCurrentWeek()}周

📚 课程数据：
${coursesInfo.isEmpty ? '暂无课程' : coursesInfo}

📝 任务数据：
${tasksInfo.isEmpty ? '暂无任务' : tasksInfo}

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
      _inputAreaExtraHeight = 0;
      _textLinesExtraHeight = 0;
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

    final history = _messages
        .take(_messages.length - 1)
        .map((msg) => {'role': msg.role, 'content': msg.content})
        .toList();

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
      debugPrint('[AI Assistant] Send execution skipped because stop was requested');
      return;
    }
    if (isRetry) {
      debugPrint('[AI Assistant] Retrying message: "$messageText"');
      setState(() {
        _statusMessage = '自动重试中... (${_retryCount}/$_maxRetryCount)';
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
        final cachedReasoning = await AIService.instance.getCachedReasoningCapability(model: customModel);
        if (cachedReasoning != _isReasoningModel || cachedReasoning != _customModelIsReasoning) {
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

      debugPrint('[AI Assistant] Executing stream request, model: $_selectedModel, provider: $provider');

      final stream = AIService.instance.chatWithModelStream(
        userMessage: actualMessage,
        model: _selectedModel,
        systemPrompt: _buildSystemPrompt(includeData: !_hasSentContext),
        history: history,
        fastMode: _fastModeEnabled,
        imageBase64: imageBase64,
        provider: provider,
        enableSearch: _webSearchEnabled && provider == 'doubao' && supportsWebSearch && !_isReasoningModel && imageBase64 == null,
        reasoningEffort: provider == 'custom' ? _currentReasoningEffort : null,
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
            debugPrint('[AI Assistant] First chunk received, canceling timeout timers');
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
            final message = _buildImageAwareErrorMessage(errStr, hasImage: imageBase64 != null);
            _messages.add(_ChatMessage(
              role: 'assistant',
              content: message,
              isError: true,
            ));
          });
          _resetRetryState();
          _persistentMessages = List.from(_messages);
          _publishStreamUpdate();
          _ensureFinalScrollToBottom(shouldFollowOutput: shouldFollowOutput);
        },
        onDone: () {
          debugPrint('[AI Assistant] Stream completed');
          _cancelSlowResponseTimer();
          _cancelNoResponseTimer();
          _hideSlowResponseTip();
          final shouldFollowOutput = !_pauseAutoScrollDuringOutput;
          
          if (!_hasCompletionOutputForCurrentProvider()) {
            debugPrint('[AI Assistant] Stream completed with empty content, retry count: $_retryCount/$_maxRetryCount');
            if (_shouldRetryForAnalyzeCompletion()) {
              _retryWithAutoRecovery();
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
                  content: '⚠️ AI未返回任何内容，已自动重试 $_maxRetryCount 次仍无响应。\n\n可能的原因：\n• AI 服务暂时不可用\n• 当前模型响应异常\n\n请稍后重试，或尝试切换其他模型。',
                  isError: true,
                ));
              });
              _resetRetryState();
              _persistentMessages = List.from(_messages);
              _publishStreamUpdate();
              _ensureFinalScrollToBottom(shouldFollowOutput: shouldFollowOutput);
              return;
            }
          }
          
          _safeSetState(() {
            _isLoading = false;
            _isFirstChunkReceived = false;
            _isThinking = false;
            _isThinkingCollapsed = true;
            _selectedModel ??= AIService.instance.lastStreamedModel;
            _persistentSelectedModel = _selectedModel;
            
            final processedContent = _processAIResponse(_streamingContent);
            final thinkingToSave = _thinkingContent.isNotEmpty ? _thinkingContent : null;
            
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
        final message = _buildImageAwareErrorMessage(errStr, hasImage: imageBase64 != null);
        _messages.add(_ChatMessage(
          role: 'assistant',
          content: message,
          isError: true,
        ));
      });
      _resetRetryState();
      _persistentMessages = List.from(_messages);
      _publishStreamUpdate();
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
    setState(() {
      if (_isAnalyzing) {
        _isAnalyzing = false;
        _hasAnalyzed = true;
      } else {
        _isLoading = false;
      }
      _isFirstChunkReceived = false;
      if (_streamingContent.isNotEmpty || _thinkingContent.isNotEmpty || _isSearching || _retryCount > 0) {
        _selectedModel ??= AIService.instance.lastStreamedModel;
        _persistentSelectedModel = _selectedModel;
        final interruptedText = _streamingContent.isNotEmpty ? _streamingContent : '⏹️ 已停止重试与生成';
        final interruptedThinking = _thinkingContent.isNotEmpty ? _thinkingContent : null;
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
    _scrollToBottom();
  }

  bool _isNearBottom({double threshold = 80}) {
    if (!_scrollController.hasClients) return true;
    final position = _scrollController.position;
    final distanceToBottom = max(0.0, position.maxScrollExtent - position.pixels);
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
    final isUserDragStart = notification is ScrollStartNotification && notification.dragDetails != null;
    final isUserDragUpdate = notification is ScrollUpdateNotification && notification.dragDetails != null;
    final isUserDragEnd = notification is ScrollEndNotification;

    if (!(isUserDragStart || isUserDragUpdate || isUserDragEnd)) {
      return false;
    }

    if (_isOutputInProgress()) {
      final position = notification.metrics;
      final distanceToBottom = max(0.0, position.maxScrollExtent - position.pixels);

      // User drag away from bottom pauses auto-follow; drag back to bottom resumes it.
      if (isUserDragStart) {
        _pauseAutoScrollDuringOutput = true;
      }

      if (isUserDragUpdate) {
        if (distanceToBottom <= 24) {
          _pauseAutoScrollDuringOutput = false;
        } else {
          _pauseAutoScrollDuringOutput = true;
        }
      }

      if (isUserDragEnd && distanceToBottom <= 24) {
        _pauseAutoScrollDuringOutput = false;
      }

      return false;
    }

    if (_pauseAutoScrollDuringOutput && _isNearBottom(threshold: 48)) {
      _pauseAutoScrollDuringOutput = false;
    }

    if (isUserDragEnd && _pauseAutoScrollDuringOutput && _isNearBottom(threshold: 48)) {
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
  }

  void _navigateToSettings() {
    if (widget.onNavigateToSettings != null) {
      widget.onNavigateToSettings!();
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => const SettingsScreen()),
      ).then((_) {
        _loadFastModeSetting();
      });
    }
  }

  void _showModelSelector() {
    if (_currentProvider == 'hunyuan' || _currentProvider == 'glm' || _currentProvider == 'custom') {
      return;
    }
    final models = _fastModeEnabled ? _fastModels : _normalModels;
    
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '选择模型',
      barrierColor: Colors.black.withValues(alpha: 0.5),
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, animation, secondaryAnimation) {
        return BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
          child: Center(
            child: Material(
              color: Colors.transparent,
              child: FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.9, end: 1.0).animate(
                    CurvedAnimation(parent: animation, curve: Curves.easeOut),
                  ),
                  child: StatefulBuilder(
                    builder: (context, setDialogState) {
                      return Container(
                        margin: const EdgeInsets.symmetric(horizontal: 24),
                        constraints: const BoxConstraints(
                          maxWidth: 400,
                          maxHeight: 500,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.2),
                              blurRadius: 20,
                              offset: const Offset(0, 10),
                            ),
                          ],
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(20),
                              decoration: const BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: [Color(0xFF4A90E2), Color(0xFF5BA0F2)],
                                ),
                                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withValues(alpha: 0.2),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: const Icon(Icons.psychology, color: Colors.white, size: 24),
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
                                          _fastModeEnabled ? '切换到普通模式启用图片上传功能' : '普通模式 · ${models.length}个模型可选',
                                          style: const TextStyle(fontSize: 12, color: Colors.white70),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Flexible(
                              child: SingleChildScrollView(
                                physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
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
                                        Future.delayed(const Duration(milliseconds: 150), () {
                                          Navigator.pop(context);
                                        });
                                      },
                                      child: Container(
                                        margin: const EdgeInsets.only(bottom: 12),
                                        padding: const EdgeInsets.all(14),
                                        decoration: BoxDecoration(
                                          color: isSelected 
                                              ? const Color(0xFF4A90E2).withValues(alpha: 0.1)
                                              : Colors.grey.shade50,
                                          borderRadius: BorderRadius.circular(12),
                                          border: Border.all(
                                            color: isSelected 
                                                ? const Color(0xFF4A90E2)
                                                : Colors.grey.shade200,
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
                                                  : Colors.grey.shade400,
                                              size: 24,
                                            ),
                                            const SizedBox(width: 12),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    modelName,
                                                    style: TextStyle(
                                                      fontSize: 14,
                                                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                                                      color: isSelected ? const Color(0xFF4A90E2) : null,
                                                    ),
                                                  ),
                                                  if (supportsImage)
                                                    Text(
                                                      '支持图片上传',
                                                      style: TextStyle(
                                                        color: const Color.fromARGB(255, 72, 72, 72),
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
                                      side: BorderSide(color: Colors.grey.shade300),
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
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _showCustomAIConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final urlController = TextEditingController(text: prefs.getString('custom_api_url') ?? '');
    final keyController = TextEditingController(text: prefs.getString('custom_api_key') ?? '');
    final modelController = TextEditingController(text: prefs.getString('custom_api_model') ?? 'gpt-4o-mini');
    bool manualVisionOverride = prefs.getBool('custom_api_vision_manual_override') ?? false;
    bool manualVisionEnabled = prefs.getBool('custom_api_vision_manual_value') ?? false;
    String reasoningEffort = prefs.getString('custom_api_reasoning_effort') ?? '';
    bool webSearchEnabled = prefs.getBool('web_search_enabled') ?? false;

    if (!mounted) return;

    await showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'AI配置',
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (ctx, animation, secondaryAnimation) {
        return _buildCustomAIConfigDialog(
          prefs: prefs,
          urlController: urlController,
          keyController: keyController,
          modelController: modelController,
          manualVisionOverride: manualVisionOverride,
          manualVisionEnabled: manualVisionEnabled,
          reasoningEffort: reasoningEffort,
          webSearchEnabled: webSearchEnabled,
          animation: animation,
        );
      },
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
    required Animation<double> animation,
  }) {
    final mediaQuery = MediaQuery.of(context);
    final keyboardHeight = mediaQuery.viewInsets.bottom;
    var localWebSearch = webSearchEnabled;
    final topInset = mediaQuery.padding.top;
    final screenHeight = mediaQuery.size.height;
    const baseMaxHeight = 650.0;
    double dialogMaxHeight = baseMaxHeight;
    final availableHeight = screenHeight - topInset - keyboardHeight - 24;
    if (availableHeight < dialogMaxHeight) {
      dialogMaxHeight = availableHeight;
    }
    dialogMaxHeight = dialogMaxHeight.clamp(320.0, baseMaxHeight).toDouble();

    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
      child: Center(
        child: Material(
          color: Colors.transparent,
          child: FadeTransition(
            opacity: animation,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.9, end: 1.0).animate(
                CurvedAnimation(parent: animation, curve: Curves.easeOut),
              ),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                margin: EdgeInsets.only(
                  left: 24,
                  right: 24,
                  top: keyboardHeight > 0 ? topInset + 8 : 0,
                  bottom: keyboardHeight > 0 ? keyboardHeight + 8 : 0,
                ),
                padding: const EdgeInsets.all(24),
                constraints: BoxConstraints(maxWidth: 420, maxHeight: dialogMaxHeight),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.2),
                      blurRadius: 20,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: StatefulBuilder(
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
                            style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                          ),
                          const SizedBox(height: 20),
                          TextField(
                            controller: urlController,
                            decoration: InputDecoration(
                              labelText: 'API 地址',
                              hintText: 'https://api.example.com/v1/chat/completions',
                              filled: true,
                              fillColor: Colors.grey.shade50,
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: keyController,
                            decoration: InputDecoration(
                              labelText: 'API Key',
                              hintText: '请输入API密钥',
                              filled: true,
                              fillColor: Colors.grey.shade50,
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: modelController,
                            decoration: InputDecoration(
                              labelText: '模型名称',
                              hintText: 'gpt-4o-mini',
                              filled: true,
                              fillColor: Colors.grey.shade50,
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                          ),
                          const SizedBox(height: 12),
                          const Text('视觉能力支持', style: TextStyle(fontSize: 13, color: Colors.black87)),
                          const SizedBox(height: 8),
                          _buildInlineSegmented(
                            labels: const ['自动', '开启', '关闭'],
                            activeIndex: !manualVisionOverride
                                ? 0
                                : (manualVisionEnabled ? 1 : 2),
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
                          const Text('思考强度', style: TextStyle(fontSize: 13, color: Colors.black87)),
                          const SizedBox(height: 8),
                          _buildInlineSegmented(
                            labels: const ['直接回答', 'Low', 'Medium', 'High'],
                            activeIndex: reasoningEffort.isEmpty ? 0
                                : reasoningEffort == 'low' ? 1
                                : reasoningEffort == 'medium' ? 2
                                : 3,
                            onChanged: (idx) => setDialogState(() {
                              reasoningEffort = ['', 'low', 'medium', 'high'][idx];
                            }),
                          ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              const Text('联网搜索', style: TextStyle(fontSize: 13, color: Colors.black87)),
                              const Spacer(),
                              SizedBox(
                                height: 28,
                                child: Switch(
                                  value: localWebSearch,
                                  activeTrackColor: Colors.grey.shade700,
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
                                      side: BorderSide(color: Colors.grey.shade300),
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
                                    await prefs.setString('custom_api_url', urlController.text.trim());
                                    await prefs.setString('custom_api_key', keyController.text.trim());
                                    await prefs.setString('custom_api_model', modelController.text.trim());
                                    await prefs.setString('ai_provider', 'custom');
                                    await prefs.setBool('fast_mode_enabled', false);
                                    await prefs.setBool('ai_enabled', true);
                                    await prefs.setString('custom_api_reasoning_effort', reasoningEffort.isNotEmpty ? reasoningEffort : '');
                                    await prefs.setBool('web_search_enabled', localWebSearch);
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
                                    Navigator.pop(builderCtx);
                                    _loadFastModeSettingAndAnalyze();
                                  },
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.grey.shade800,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(vertical: 14),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
                ),
              ),
            ),
          ),
        ),
      ),
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
      final maxDim = 1024;
      if (resized.width > maxDim || resized.height > maxDim) {
        resized = img.copyResize(resized, width: maxDim, height: maxDim);
      }

      final compressed = img.encodeJpg(resized, quality: 70);
      debugPrint('[Image] Compressed: ${(originalSize / 1024).toStringAsFixed(1)}KB → ${(compressed.length / 1024).toStringAsFixed(1)}KB');
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
        final aspectRatio = decoded != null ? decoded.width / decoded.height : null;
        bytes = _compressImageBytes(bytes);
        setState(() {
          _selectedImagePath = image.path;
          _selectedImageBase64 = base64Encode(bytes);
          _selectedImageAspectRatio = aspectRatio;
          _inputAreaExtraHeight = 44;
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
        final aspectRatio = decoded != null ? decoded.width / decoded.height : null;
        bytes = _compressImageBytes(bytes);
        setState(() {
          _selectedImagePath = image.path;
          _selectedImageBase64 = base64Encode(bytes);
          _selectedImageAspectRatio = aspectRatio;
          _inputAreaExtraHeight = 44;
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

    if (lowerError.contains('payload') || lowerError.contains('too large') || lowerError.contains('413')) {
      return '⚠️ 图片发送失败：图片体积过大，超出了API的请求限制\n\n'
          '建议：尝试使用更小的图片，或降低图片分辨率后重试';
    }

    return '抱歉，发生了错误：$error';
  }

  void _updateTextLinesExtraHeight() {
    if (!mounted) return;
    final text = _messageController.text;
    int lines;
    if (text.isEmpty) {
      lines = 1;
    } else {
      const approxCharsPerLine = 25;
      final splitLines = text.split('\n');
      int totalLines = 0;
      for (final line in splitLines) {
        totalLines += (line.length / approxCharsPerLine).ceil().clamp(1, 4);
      }
      lines = totalLines.clamp(1, 4);
    }
    final extraHeight = (lines - 1) * _kTextLineHeight;
    if (_textLinesExtraHeight != extraHeight) {
      final isGrowing = extraHeight > _textLinesExtraHeight;
      setState(() {
        _textLinesExtraHeight = extraHeight;
      });
      if (isGrowing) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
          }
        });
      }
    }
  }

  void _removeImage() {
    setState(() {
      _selectedImagePath = null;
      _selectedImageBase64 = null;
      _selectedImageAspectRatio = null;
      _inputAreaExtraHeight = 0;
    });
  }

  void _toggleAddMenu() {
    HapticFeedback.selectionClick();
    setState(() {
      _showAddMenu = !_showAddMenu;
    });
  }

  void _closeAddMenu() {
    if (_showAddMenu) {
      setState(() {
        _showAddMenu = false;
      });
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
                style: const TextStyle(
                  fontSize: 15,
                  color: Color(0xFF333333),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showImagePreview(String imagePath, {bool useHero = true, int? messageIndex, double? imageAspectRatio}) {
    final heroTag = messageIndex != null
        ? 'image_preview_${messageIndex}_$imagePath'
        : 'image_preview_$imagePath';
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        transitionDuration: const Duration(milliseconds: 350),
        reverseTransitionDuration: const Duration(milliseconds: 250),
        barrierDismissible: true,
        barrierLabel: '图片预览',
        barrierColor: Colors.transparent,
        pageBuilder: (context, animation, secondaryAnimation) {
          return _ImagePreviewPage(
            imagePath: imagePath,
            heroTag: heroTag,
            animation: animation,
            useHero: useHero,
            imageAspectRatio: imageAspectRatio,
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    if (_scrollController.hasClients) {
      _persistentScrollOffset = _scrollController.offset;
    }
    WidgetsBinding.instance.removeObserver(this);
    _streamUpdateTick.removeListener(_handleStreamUpdateTick);
    _cancelSlowResponseTimer();
    _cancelNoResponseTimer();
    _messageController.removeListener(_updateTextLinesExtraHeight);
    _messageController.dispose();
    _scrollController.dispose();
    _thinkingScrollController.dispose();
    _focusNode.dispose();
    _keyboardDismissAnimController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;
    final bottomPadding = MediaQuery.of(context).viewPadding.bottom;
    final rawKeyboardHeight = MediaQuery.of(context).viewInsets.bottom;
    final maxKeyboardHeight = MediaQuery.of(context).size.height * 0.8;
    
    final double kb = _layoutKeyboardHeight.clamp(0.0, maxKeyboardHeight);
    final bool isActive = rawKeyboardHeight > 1 || kb > 1;
    final double pageBottomInset = kb;

    // Restore linear input movement for keyboard show/hide.
    final double inputBottomPosition = max(8.0, 100.0 - kb);
    final double inputBounceOffset = _keyboardDismissBounceOffset * 2.2;
    final double inputBottomWithBounce = max(0.0, inputBottomPosition - inputBounceOffset);
    const double inputBaseHeight = 60;
    final double listBottomPadding = inputBottomPosition + inputBaseHeight + _inputAreaExtraHeight + _textLinesExtraHeight + 8;
    
    debugPrint('Build: kb=$kb, rawKb=$rawKeyboardHeight, isActive=$isActive, pageInset=$pageBottomInset, inputPos=$inputBottomPosition, inputBounce=$inputBounceOffset');

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.dark,
      ),
      child: Scaffold(
        backgroundColor: const Color(0xFFF8F9FC),
        resizeToAvoidBottomInset: false,
        extendBody: true,
        body: Stack(
          children: [
            MediaQuery(
              data: MediaQuery.of(context).copyWith(viewInsets: EdgeInsets.zero),
              child: Padding(
                padding: EdgeInsets.only(bottom: pageBottomInset),
                child: GestureDetector(
                  onTap: _closeAddMenu,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: NotificationListener<ScrollNotification>(
                          onNotification: _handleMessageListScrollNotification,
                          child: CustomScrollView(
                            controller: _scrollController,
                            physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                            slivers: [
                              SliverPadding(
                                padding: EdgeInsets.only(top: topPadding + 70),
                              ),
                              SliverPadding(
                                padding: EdgeInsets.fromLTRB(16, 0, 16, listBottomPadding),
                                sliver: SliverList(
                                  delegate: SliverChildListDelegate([
                                    if (_messages.isEmpty && _streamingContent.isEmpty && !_isFirstChunkReceived && !_isAnalyzing)
                                      _buildWelcomeCard()
                                    else ...[
                                      ..._messages.asMap().entries.map((e) => _buildMessageBubble(e.value, e.key)),
                                      if (_isSearching)
                                        _buildLoadingIndicator()
                                      else if (_streamingContent.isNotEmpty || _thinkingContent.isNotEmpty)
                                        _buildStreamingBubble()
                                      else if (_isLoading || _isAnalyzing) ...[
                                        _buildLoadingIndicator(),
                                      ],
                                      if (_showSlowResponseTip && _shouldShowFastModeSlowTip)
                                        _buildSlowResponseTip(),
                                    ],
                                  ]),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      _buildPinnedHeader(topPadding),
                      _buildInputArea(inputBottomWithBounce),
                      if (_supportsImageUpload)
                        Positioned(
                          left: 16,
                          bottom: inputBottomWithBounce + 58,
                          child: AnimatedOpacity(
                            opacity: _showAddMenu ? 1.0 : 0.0,
                            duration: const Duration(milliseconds: 200),
                            child: IgnorePointer(
                              ignoring: !_showAddMenu,
                              child: Material(
                                color: Colors.transparent,
                                child: Container(
                                  width: 120,
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(16),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withValues(alpha: 0.15),
                                        blurRadius: 12,
                                        offset: const Offset(0, 4),
                                      ),
                                    ],
                                  ),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(16),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        SizedBox(
                                          width: double.infinity,
                                          child: _buildMenuItem(
                                            icon: Icons.camera_alt,
                                            label: '拍照',
                                            onTap: () => _handleMenuSelection('camera'),
                                            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                                          ),
                                        ),
                                        Divider(height: 1, color: Colors.grey.shade200),
                                        SizedBox(
                                          width: double.infinity,
                                          child: _buildMenuItem(
                                            icon: Icons.photo_library,
                                            label: '相册',
                                            onTap: () => _handleMenuSelection('gallery'),
                                            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
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
                    opacity: rawKeyboardHeight > 1 ? 0.0 : 1.0,
                    child: Text(
                      '内容由AI生成',
                      style: TextStyle(
                        fontSize: 9,
                        color: Colors.grey.shade400,
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
                  Icon(
                    Icons.tips_and_updates_outlined,
                    color: const Color(0xFF4A90E2),
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: GestureDetector(
                      onTap: _navigateToSettings,
                      child: Text.rich(
                        TextSpan(
                          children: [
                            const TextSpan(
                              text: '响应较慢？可前往 ',
                              style: TextStyle(
                                color: Color(0xFF4A90E2),
                                fontSize: 14,
                              ),
                            ),
                            const TextSpan(
                              text: '"设置"',
                              style: TextStyle(
                                color: Color(0xFF4A90E2),
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const TextSpan(
                              text: ' → ',
                              style: TextStyle(
                                color: Color(0xFF4A90E2),
                                fontSize: 14,
                              ),
                            ),
                            const TextSpan(
                              text: '"开启快速响应"',
                              style: TextStyle(
                                color: Color(0xFF4A90E2),
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const TextSpan(
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
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      child: ClipRRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFFF8F9FC).withValues(alpha: 0.75),
              border: Border(
                bottom: BorderSide(color: Colors.grey.shade200, width: 0.5),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(height: topPadding),
                SizedBox(
                  height: 56,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'AI 对话',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF1A1A2E),
                            ),
                          ),
                        ),
                        if (_aiEnabled) ...[
                          if (_fastModeEnabled)
                            Container(
                              margin: const EdgeInsets.only(right: 8),
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.green.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(12),
                              ),
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
                                ? Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: Colors.grey.shade200,
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          _selectedModel!,
                                          style: TextStyle(
                                            color: Colors.grey.shade600,
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                  )
                                : GestureDetector(
                                    onTap: _currentProvider == 'custom' ? _showCustomAIConfig : _showModelSelector,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF4A90E2).withValues(alpha: 0.15),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            _selectedModel!,
                                            style: const TextStyle(
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
                                  ),
                          if (_messages.isNotEmpty || _streamingContent.isNotEmpty)
                            IconButton(
                              onPressed: () {
                                HapticFeedback.selectionClick();
                                _clearChat();
                              },
                              icon: Icon(Icons.delete_outline, color: Colors.grey.shade600),
                            ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
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
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: Colors.orange.shade200,
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
                            color: Colors.orange.shade100,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            Icons.info_outline,
                            color: Colors.orange.shade700,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          'AI 功能未开启',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Colors.orange.shade800,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '请前往"设置" → "AI 功能"开启后使用AI助手。',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.orange.shade700,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextButton.icon(
                      onPressed: _navigateToSettings,
                      icon: const Icon(Icons.settings, size: 18),
                      label: const Text('前往设置'),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.orange.shade700,
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
    
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Flexible(
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF4A90E2).withValues(alpha: 0.15),
                    blurRadius: 20,
                    spreadRadius: 2,
                    offset: const Offset(0, 4),
                  ),
                ],
                border: Border.all(
                  color: const Color(0xFF4A90E2).withValues(alpha: 0.3),
                  width: 1.5,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: const Color(0xFF4A90E2).withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(
                          Icons.auto_awesome,
                          color: Color(0xFF4A90E2),
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Text(
                        'AI 学习助手',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF1A1A2E),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '我可以帮你分析课程安排、管理学习任务、解答学习问题。有什么想问的吗？',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey.shade700,
                      height: 1.5,
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

  Widget _buildMessageBubble(_ChatMessage message, int messageIndex) {
    final isUser = message.role == 'user';
    final hasCourses = message.courses != null && message.courses!.isNotEmpty;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flexible(
            child: isUser && message.imagePath != null && message.content.isEmpty
                ? GestureDetector(
                    onTap: () => _showImagePreview(message.imagePath!, useHero: true, messageIndex: messageIndex, imageAspectRatio: message.imageAspectRatio),
                    child: Hero(
                      tag: 'image_preview_${messageIndex}_${message.imagePath}',
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
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
                    ? Colors.red.shade50
                    : (message.isWelcome 
                        ? Colors.white
                        : (isUser ? const Color(0xFF4A90E2) : Colors.white)),
                borderRadius: BorderRadius.circular(16),
                boxShadow: isUser
                    ? null
                    : [
                        BoxShadow(
                          color: message.isWelcome 
                              ? const Color(0xFF4A90E2).withValues(alpha: 0.12)
                              : Colors.black.withValues(alpha: 0.05),
                          blurRadius: message.isWelcome ? 16 : 10,
                          spreadRadius: message.isWelcome ? 1 : 0,
                          offset: const Offset(0, 2),
                        ),
                      ],
                border: message.isWelcome
                    ? Border.all(
                        color: const Color(0xFF4A90E2).withValues(alpha: 0.25),
                        width: 1,
                      )
                    : null,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (message.imagePath != null) ...[
                    GestureDetector(
                      onTap: () => _showImagePreview(message.imagePath!, useHero: true, messageIndex: messageIndex, imageAspectRatio: message.imageAspectRatio),
                      child: Hero(
                        tag: 'image_preview_${messageIndex}_${message.imagePath}',
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
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
                    _buildCourseListInBubble(message.courses!, message),
                    const SizedBox(height: 12),
                  ],
                  if (!isUser && message.thinkingContent != null && message.thinkingContent!.isNotEmpty) ...[
                    _buildSavedThinkingBubble(message),
                    const SizedBox(height: 12),
                  ],
                  if (isUser && message.content.isNotEmpty)
                    SelectionArea(
                      child: Text(
                        message.content,
                        style: TextStyle(
                          color: isUser ? Colors.white : Colors.grey.shade800,
                          fontSize: 14,
                          height: 1.5,
                        ),
                      ),
                    )
                  else if (!isUser)
                    Container(
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.of(context).size.width * 0.8,
                      ),
                      child: SelectionArea(
                        child: _buildMarkdownContent(
                          message.content,
                          style: TextStyle(
                            fontSize: 14,
                            height: 1.5,
                            color: message.isError ? Colors.red : Colors.grey.shade800,
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
            ),
          ),
        ],
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
            Icon(Icons.list_alt, size: 16, color: Colors.grey.shade600),
            const SizedBox(width: 6),
            Text(
              '识别到的课程 (${courses.length})',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade700,
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
              color: Colors.grey.shade50,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        course.name,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF1A1A2E),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${dayNames[course.day]} 第${course.time}节',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey.shade600,
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
                            color: Colors.grey.shade500,
                          ),
                        ),
                      if (course.weeks != null && course.weeks!.isNotEmpty)
                        Text(
                          '周次: ${course.weeks}',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey.shade500,
                          ),
                        ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  icon: Icon(Icons.more_vert, size: 18, color: Colors.grey.shade600),
                  onOpened: () {
                    HapticFeedback.selectionClick();
                  },
                  onSelected: (value) {
                    if (value == 'edit') {
                      _editCourse(course, messageIndex);
                    } else if (value == 'delete') {
                      _deleteCourseFromMessage(course, messageIndex);
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: 'edit',
                      child: Row(
                        children: [
                          Icon(Icons.edit_outlined, size: 18),
                          SizedBox(width: 8),
                          Text('编辑'),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'delete',
                      child: Row(
                        children: [
                          Icon(Icons.delete_outline, size: 18, color: Colors.red),
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
                color: Colors.white,
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
                  if (_thinkingContent.isNotEmpty && _streamingContent.isNotEmpty)
                    const SizedBox(height: 12),
                  // 正文内容
                  if (_streamingContent.isNotEmpty)
                    SelectionArea(
                      child: _buildMarkdownContent(
                        _streamingContent,
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.5,
                          color: Colors.grey.shade800,
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
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
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
                      color: Colors.grey.shade500,
                    ),
                  )
                else
                  Icon(
                    isExpanded ? Icons.expand_less : Icons.expand_more,
                    color: Colors.grey.shade500,
                    size: 18,
                  ),
                const SizedBox(width: 8),
                Text(
                  _isThinking && _streamingContent.isEmpty 
                      ? '思考中...' 
                      : '思考过程',
                  style: TextStyle(
                    color: Colors.grey.shade600,
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
                            child: _buildMarkdownContent(
                              _thinkingContent,
                              style: const TextStyle(
                                fontSize: 12,
                                height: 1.5,
                                color: Colors.black87,
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
                color: Colors.white,
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
                      color: Colors.grey.shade600,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    _statusMessage.isNotEmpty 
                        ? _statusMessage 
                        : (_isAnalyzing ? '分析中...' : '思考中...'),
                    style: TextStyle(
                      color: Colors.grey.shade600,
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
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
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
                  color: Colors.grey.shade500,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Text(
                  '思考过程',
                  style: TextStyle(
                    color: Colors.grey.shade600,
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
                            child: _buildMarkdownContent(
                              message.thinkingContent!,
                              style: const TextStyle(
                                fontSize: 12,
                                height: 1.5,
                                color: Colors.black87,
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
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(28),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 25, sigmaY: 25),
              child: Container(
                padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.6),
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    ),
                  ],
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
                                onTap: () => _showImagePreview(_selectedImagePath!, useHero: false, imageAspectRatio: _selectedImageAspectRatio),
                                child: Container(
                                  margin: const EdgeInsets.only(bottom: 8),
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: Colors.grey.shade100,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(Icons.image, size: 20, color: Colors.grey.shade600),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          '已选择图片（点击预览）',
                                          style: TextStyle(
                                            fontSize: 13,
                                            color: Colors.grey.shade700,
                                          ),
                                        ),
                                      ),
                                      GestureDetector(
                                        onTap: _removeImage,
                                        child: Icon(Icons.close, size: 18, color: Colors.grey.shade600),
                                      ),
                                    ],
                                  ),
                                ),
                              )
                            : const SizedBox.shrink(key: ValueKey('no_image')),
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
                                    color: _showAddMenu ? const Color(0xFF4A90E2) : Colors.grey.shade200,
                                    borderRadius: BorderRadius.circular(20),
                                    child: InkWell(
                                      onTap: _toggleAddMenu,
                                      customBorder: const CircleBorder(),
                                      child: AnimatedRotation(
                                        turns: _showAddMenu ? 0.125 : 0,
                                        duration: const Duration(milliseconds: 200),
                                        child: SizedBox(
                                          width: 40,
                                          height: 40,
                                          child: Icon(
                                            Icons.add,
                                            color: _showAddMenu ? Colors.white : Colors.grey.shade700,
                                            size: 24,
                                          ),
                                        ),
                                      ),
                                    ),
                                  )
                                : const SizedBox.shrink(key: ValueKey('no_add_button')),
                          ),
                        ),
                        AnimatedSize(
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeInOut,
                          child: _supportsImageUpload ? const SizedBox(width: 8, key: ValueKey('spacing')) : const SizedBox.shrink(key: ValueKey('no_spacing')),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                            child: TextField(
                              controller: _messageController,
                              focusNode: _focusNode,
                              style: const TextStyle(
                                fontSize: 15,
                                height: 1.4,
                              ),
                              decoration: InputDecoration(
                                hintText: '输入消息...',
                                hintStyle: TextStyle(
                                  color: Colors.grey.shade400,
                                  fontSize: 15,
                                ),
                                border: InputBorder.none,
                                contentPadding: EdgeInsets.zero,
                                isDense: true,
                                filled: true,
                                fillColor: Colors.transparent,
                              ),
                              maxLines: 4,
                              minLines: 1,
                              onSubmitted: (_) => _sendMessage(),
                            ),
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
                                        colors: [Color(0xFF4A90E2), Color(0xFF5BA0F2)],
                                      ),
                                color: (_isLoading || _isAnalyzing) ? Colors.red.shade400 : null,
                                borderRadius: BorderRadius.circular(20),
                                boxShadow: [
                                  BoxShadow(
                                    color: (_isLoading || _isAnalyzing ? Colors.red : const Color(0xFF4A90E2)).withValues(alpha: 0.3),
                                    blurRadius: 8,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: Icon(
                                (_isLoading || _isAnalyzing) ? Icons.stop_rounded : Icons.send_rounded,
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
        ],
      ),
    );
  }

  void _editCourse(Course course, int messageIndex) {
    CourseDialog.show(
      context: context,
      course: course,
      selectedDay: course.day,
      selectedPeriod: course.time,
    ).then((updatedCourse) {
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
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: const Text('确定要删除这门课程吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              StorageService.deleteCourse(course.id);
              Navigator.pop(context);
              
              setState(() {
                final oldMessage = _messages[messageIndex];
                if (oldMessage.courses != null) {
                  final updatedCourses = oldMessage.courses!.where((c) => c.id != course.id).toList();
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
    );
  }
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

class _ImagePreviewPageState extends State<_ImagePreviewPage> with SingleTickerProviderStateMixin {
  final TransformationController _transformController = TransformationController();
  double _dismissProgress = 0.0;
  late final AnimationController _snapController;
  Matrix4 _snapFrom = Matrix4.identity();
  Matrix4 _snapTarget = Matrix4.identity();
  Curve _snapCurve = Curves.easeOutCubic;
  bool _isSnapping = false;
  bool _isClamping = false;
  bool _isInteracting = false;
  double _dragOriginalScale = 1.0;
  bool _isDismissing = false;
  double _prevScaleForCheck = 1.0;

  @override
  void initState() {
    super.initState();
    _snapController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    _snapController.addListener(_onSnapTick);
    _transformController.addListener(_clampTransform);
  }

  @override
  void dispose() {
    _snapController.dispose();
    _transformController.dispose();
    super.dispose();
  }

  void _onSnapTick() {
    final t = _snapCurve.transform(_snapController.value);

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
        ? (aspectRatio >= containerW / containerH ? containerW : containerH * aspectRatio)
        : containerW;
    final imageDisplayH = aspectRatio != null
        ? (aspectRatio >= containerW / containerH ? containerW / aspectRatio : containerH)
        : containerH;
    final imageLeft = (containerW - imageDisplayW) / 2;
    final imageTop = (containerH - imageDisplayH) / 2;

    if (rawScale > 1.05) {
      final scaledImageW = imageDisplayW * rawScale;
      final minTx = scaledImageW > containerW
          ? containerW - (imageLeft + imageDisplayW) * rawScale
          : containerW * (1 - rawScale);
      final maxTx = scaledImageW > containerW
          ? -imageLeft * rawScale
          : 0.0;
      tx = rawTx.clamp(minTx, maxTx);
      if (!_isInteracting) {
        final scaledImageH_forCenter = imageDisplayH * rawScale;
        if (scaledImageH_forCenter <= containerH) {
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
          final minTyVertical = containerH - (imageTop + imageDisplayH) * visualScale;
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
    _snapController.reset();
    await _snapController.forward();
    _isSnapping = false;
  }

  void _dismiss() {
    if (!mounted) return;
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
        _snapController.reset();
        _snapController.forward().then((_) {
          _isSnapping = false;
          setState(() { _dismissProgress = 0.0; });
          if (mounted) Navigator.of(context).pop();
        });
        return;
      }

      setState(() { _dismissProgress = 0.0; });
      if (mounted) Navigator.of(context).pop();
      return;
    }

    setState(() { _dismissProgress = 0.0; });
    Navigator.of(context).pop();
  }

  void _animatedDismiss() {
    _isInteracting = false;
    if (!widget.useHero) {
      _isDismissing = true;
      setState(() {});
      final screenSize = MediaQuery.of(context).size;
      final currentMatrix = _transformController.value;

      final target = Matrix4.identity();
      target.setEntry(0, 0, 0.01);
      target.setEntry(1, 1, 0.01);
      target.setEntry(2, 2, 0.01);
      target.setEntry(0, 3, screenSize.width * (1 - 0.01) / 2);
      target.setEntry(1, 3, screenSize.height * (1 - 0.01) / 2);
      target.setEntry(3, 3, 1.0);

      _snapController.duration = const Duration(milliseconds: 280);
      _snapCurve = Curves.easeOutCubic;
      _isSnapping = true;
      _snapFrom = Matrix4.copy(currentMatrix);
      _snapTarget = target;
      _snapController.reset();
      _snapController.forward().then((_) {
        _isSnapping = false;
        setState(() { _dismissProgress = 0.0; });
        if (mounted) Navigator.of(context).pop();
      });
      return;
    }

    setState(() { _dismissProgress = 0.0; });
    if (mounted) Navigator.of(context).pop();
  }

  void _onDoubleTap() {
    if (_isSnapping) return;
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
    setState(() { _dismissProgress = 0.0; });
  }

  void _onInteractionStart(ScaleStartDetails details) {
    _isInteracting = true;
    _dragOriginalScale = _transformController.value.getMaxScaleOnAxis().clamp(1.0, 4.0);
    if (_dragOriginalScale > 1.05 && _dismissProgress != 0.0) {
      setState(() { _dismissProgress = 0.0; });
    }
  }

  void _onInteractionUpdate(ScaleUpdateDetails details) {
    if (_isSnapping) {
      _snapController.stop();
      _isSnapping = false;
    }
    final matrix = _transformController.value;
    final screenSize = MediaQuery.of(context).size;
    final ty = matrix.getTranslation().y;

    final effectiveTranslation = ty / _dragOriginalScale;
    if (effectiveTranslation > 0) {
      final progress = (effectiveTranslation / screenSize.height).clamp(0.0, 1.0);
      if (progress != _dismissProgress) {
        setState(() { _dismissProgress = progress; });
      }
    } else if (_dismissProgress != 0) {
      setState(() { _dismissProgress = 0.0; });
    }
  }

  void _onInteractionEnd(ScaleEndDetails details) {
    _isInteracting = false;
    final matrix = _transformController.value;
    final currentScale = matrix.getMaxScaleOnAxis();
    final ty = matrix.getTranslation().y;
    final screenSize = MediaQuery.of(context).size;

    final effectiveTranslation = ty / _dragOriginalScale;
    if (effectiveTranslation > screenSize.height * 0.2 || details.velocity.pixelsPerSecond.dy > 800) {
      _animatedDismiss();
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
          if (mounted) setState(() { _dismissProgress = 0.0; });
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
          if (mounted) setState(() { _dismissProgress = 0.0; });
        });
        return;
      }
    }

    setState(() { _dismissProgress = 0.0; });
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
            Positioned(
              top: 0,
              right: 0,
              child: SafeArea(
                child: AnimatedOpacity(
                  opacity: 1.0 - _dismissProgress,
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
                            icon: const Icon(Icons.close, color: Colors.white, size: 22),
                            onPressed: _dismiss,
                            padding: const EdgeInsets.all(8),
                            constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
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
                  flightContext, animation, flightDirection, fromHero, toHero,
                ) {
                  return SizedBox.expand(
                    child: Image.file(File(widget.imagePath), fit: BoxFit.contain),
                  );
                },
                child: heroChild,
              )
            : heroChild,
      ),
    );

    if (!widget.useHero) {
      if (_isDismissing) {
        return viewer;
      }
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
  bool isThinkingCollapsed;

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
    this.isThinkingCollapsed = true,
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

Widget _buildMarkdownContent(String content, {TextStyle? style}) {
  var processedContent = _convertLatexForRendering(content);
  
  processedContent = processedContent
      .replaceAll(RegExp(r'^#### ', multiLine: true), '##### ')
      .replaceAll(RegExp(r'^### ', multiLine: true), '##### ')
      .replaceAll(RegExp(r'^## ', multiLine: true), '##### ')
      .replaceAll(RegExp(r'^# ', multiLine: true), '##### ');
  
  final markdown = GptMarkdown(
    processedContent,
    style: style ?? const TextStyle(fontSize: 14, height: 1.5),
    useDollarSignsForLatex: true,
    tableBuilder: (context, rows, textStyle, config) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        child: Table(
          textDirection: config.textDirection,
          defaultColumnWidth: CustomTableColumnWidth(),
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          border: TableBorder.all(
            width: 1,
            color: Theme.of(context).colorScheme.onSurface,
          ),
          children: rows.map((row) => TableRow(
            decoration: row.isHeader
                ? BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest)
                : null,
            children: row.fields.map((field) {
              Widget content = Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: MdWidget(context, field.data, false, config: config),
              );
              switch (field.alignment) {
                case TextAlign.center:
                  return Center(child: content);
                case TextAlign.right:
                  return Align(alignment: Alignment.centerRight, child: content);
                default:
                  return Align(alignment: Alignment.centerLeft, child: content);
              }
            }).toList(),
          )).toList(),
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
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        child: Math.tex(
          tex,
          textStyle: textStyle,
          mathStyle: MathStyle.display,
          textScaleFactor: 1,
          settings: const TexParserSettings(strict: Strict.ignore),
        ),
      );
    },
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
            ? (activeIdx + _dragOffset / segmentW).clamp(0.0, (n - 1).toDouble())
            : activeIdx.toDouble();
        final left = 2.0 + effectiveIdx * segmentW;
        final visualActiveIdx = _isDragging ? effectiveIdx.round().clamp(0, n - 1) : activeIdx;

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
                  setState(() => _textAnimDuration = const Duration(milliseconds: 250));
                }
              });
            }
            final velocity = details.primaryVelocity ?? 0;
            final extra = velocity > 0 ? -segmentW / 3 : velocity < 0 ? segmentW / 3 : 0.0;
            final totalOffset = _dragOffset + extra;
            int targetIdx = (activeIdx + totalOffset / segmentW).round().clamp(0, n - 1);
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
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.grey.shade300, width: 1),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: Stack(
                children: [
                  AnimatedPositioned(
                    duration: _isDragging ? Duration.zero : const Duration(milliseconds: 250),
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
                          color: Colors.grey.shade800,
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
                  if (_isDragging)
                    Row(
                      children: labels.map((label) => Expanded(
                        child: Center(
                          child: AnimatedDefaultTextStyle(
                            duration: Duration.zero,
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.normal, color: Colors.black87),
                            child: Text(label),
                          ),
                        ),
                      )).toList(),
                    ),
                  if (_isDragging)
                    Positioned.fill(
                      child: ShaderMask(
                        shaderCallback: (bounds) {
                          final relLeft = (left / bounds.width).clamp(0.0, 1.0);
                          final edge = 0.015;
                          final relStart = (relLeft - edge).clamp(0.0, 1.0);
                          final relEnd = ((left + segmentW - 4) / bounds.width).clamp(0.0, 1.0);
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
                            stops: [0.0, relStart, relLeft, relEnd, relStop, 1.0],
                          ).createShader(bounds);
                        },
                        blendMode: BlendMode.dstIn,
                        child: Row(
                          children: labels.map((label) => Expanded(
                            child: Center(
                              child: AnimatedDefaultTextStyle(
                                duration: Duration.zero,
                                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.normal, color: Colors.white),
                                child: Text(label),
                              ),
                            ),
                          )).toList(),
                        ),
                      ),
                    ),
                  if (!_isDragging)
                    Row(
                      children: labels.asMap().entries.map((entry) {
                        return Expanded(
                          child: Center(
                            child: AnimatedDefaultTextStyle(
                              duration: _textAnimDuration,
                              curve: Curves.easeInOut,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.normal,
                                color: entry.key == visualActiveIdx ? Colors.white : Colors.black87,
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

  Widget _buildBaseTextRow(List<String> labels, Color color, FontWeight weight) {
    return Row(
      children: labels.map((label) => Expanded(
        child: Center(
          child: Text(label, style: TextStyle(fontSize: 13, fontWeight: weight, color: color)),
        ),
      )).toList(),
    );
  }
}
