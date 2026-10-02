import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import '../services/glm_service.dart';
import '../models/task.dart';
import '../utils/storage.dart';

/// DDL 页面 AI 任务建议框
/// - 打开 DDL 页面时自动触发 AI 分析（独立于对话页）
/// - 分析中显示 skeleton + shimmer
/// - 仅提取"任务建议"部分文字（不带标题）用打字机效果显示
/// - 内存级缓存（仅本次 App 运行期间有效）
class DDLAIInsightCard extends StatefulWidget {
  /// 对外只读：本次 App 运行期间是否被用户点叉关闭（供 DDL 页收窄间距）
  static bool get isDismissedThisRun => _DDLAIInsightCardState._dismissedByUser;

  /// 对外只读：是否已有可保留的分析结果。子开关关闭时，DDL 页据此和
  /// [isDismissedThisRun] 一起判断该收起还是保留——两者都是同步量，
  /// DDL 页与卡片在同一帧里算出的结论必然一致
  static bool get hasResult =>
      _DDLAIInsightCardState._hasAnalyzed &&
      _DDLAIInsightCardState._cachedInsight != null &&
      _DDLAIInsightCardState._cachedInsight!.isNotEmpty;
  final List<Task> tasks;

  /// 「设置 → AI设置 → 自动任务分析」子开关（由 DDL 页从
  /// [AIAutoAnalysisFlags] 的同步缓存读出后传入）。关闭时不再发起新的分析，
  /// 但已生成的结果原样保留；无结果可展示时整块收起。
  final bool autoAnalysis;
  // 高度变化回调，用于通知父 widget 更新布局
  final ValueChanged<double>? onHeightChanged;

  const DDLAIInsightCard({
    super.key,
    required this.tasks,
    this.autoAnalysis = true,
    this.onHeightChanged,
  });

  @override
  State<DDLAIInsightCard> createState() => _DDLAIInsightCardState();
}

enum _InsightPhase { idle, loading, typing, done, error, disabled, hidden }

class _DDLAIInsightCardState extends State<DDLAIInsightCard>
    with TickerProviderStateMixin {
  _InsightPhase _phase = _InsightPhase.idle;

  // 打字机显示的内容（仅任务建议部分，不带标题）
  String _typewriterContent = '';
  // 当前打字机显示位置
  int _typewriterIndex = 0;
  Timer? _typewriterTimer;

  // Shimmer 动画
  late final AnimationController _shimmerController;

  // 关闭（叉号）动画：参数对齐课程删除动画（220ms easeInCubic，
  // 模糊增大 + 向内缩小 + 淡出），播完转入 hidden（本次运行不再加载）
  AnimationController? _dismissController;
  CurvedAnimation? _dismissCurved;

  // 流式累加（static：跨实例存活，切页不中断）
  static String _streamingContent = '';
  static StreamSubscription<String>? _streamSubscription;
  static bool _isAnalyzing = false;
  static bool _hasError = false;
  // 失败原因（AiException 的人话文案）：显示在「分析失败」下面，
  // 一眼能分清是额度、网络还是中转挂了
  static String? _lastError;
  // 本次分析的发起人：把底层 HttpClient 登记到 AIService，让「重试」能真正
  // 掐断上一次还卡着的请求（取消订阅做不到，见 _analyzeDDL 注释）
  static final Object _aiRequestOwner = Object();
  // 首字节看门狗：任务分析只要 200 字，30s 还没吐第一个字就是死连接
  // （与对话页 _noResponseTimeout 同值）
  static const Duration _firstByteTimeout = Duration(seconds: 30);
  // 清场后退避：等旧 socket 真正释放再发新请求（与对话页 _retryBackoffStep 同值）
  static const Duration _retryBackoff = Duration(milliseconds: 800);
  static Timer? _firstByteTimer;
  // 跨实例通信：后台流完成后通知新实例同步 UI
  static final ValueNotifier<int> _streamUpdateTick = ValueNotifier<int>(0);

  bool _aiEnabled = false;
  String _currentProvider = '';

  // 内存级缓存（仅本次 App 运行期间有效，与对话页完全解耦）
  static String? _cachedInsight;
  static bool _hasAnalyzed = false;

  // 本次分析基于的课表 id：切换课表后与之不同时，标题行展示"重新生成"按钮
  static String? _analysisTimetableId;
  // 本次分析基于的未完成任务快照（id+截止日+名称）：新增/删除/勾选完成/
  // 编辑任务后与快照不同时，同样展示"重新生成"按钮
  static Set<String>? _analysisTaskSnapshot;
  // 用户点击叉号关闭后，本次 App 运行期间不再加载（直到 App 终止）
  static bool _dismissedByUser = false;

  @override
  void initState() {
    super.initState();
    _shimmerController = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    );
    _streamUpdateTick.addListener(_handleStreamUpdateTick);
    // 定相全部在首帧同步完成：缓存命中直接渲染最终高度，子开关关闭且无
    // 结果可保留则首帧即为收起——否则会先以 idle 相态渲染一帧，再经
    // AnimatedSize 收起/撑高（每次进入 DDL 页"往下弹出一次"的根源）
    if (_dismissedByUser) {
      _phase = _InsightPhase.hidden;
    } else if (DDLAIInsightCard.hasResult) {
      final extracted = _extractInsightText(_cachedInsight!);
      _typewriterContent = extracted;
      _typewriterIndex = extracted.length;
      _phase = _InsightPhase.done;
    } else if (_isAnalyzing) {
      _phase = _InsightPhase.loading;
      _shimmerController.repeat();
    } else if (!widget.autoAnalysis) {
      _phase = _InsightPhase.hidden;
    } else {
      _loadConfigAndAnalyze();
    }
  }

  @override
  void didUpdateWidget(DDLAIInsightCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.autoAnalysis == oldWidget.autoAnalysis) return;
    // 子开关翻转：重新定相。关掉时已有结果继续保留、无结果则收起；
    // 打开时若本次还没分析过则补发一次
    _loadConfigAndAnalyze();
  }

  @override
  void dispose() {
    _shimmerController.dispose();
    _typewriterTimer?.cancel();
    _streamUpdateTick.removeListener(_handleStreamUpdateTick);
    _dismissCurved?.dispose();
    _dismissController?.dispose();
    // 注意：不取消 _streamSubscription，也不停首字节看门狗——让后台流和它的
    // 超时保护继续运行（看门狗只碰 static 状态），切回本页还能正常收尾
    super.dispose();
  }

  /// 后台流状态变化时同步 UI
  void _handleStreamUpdateTick() {
    if (!mounted || _dismissedByUser) return;
    if (_isAnalyzing) {
      // 后台仍在分析中，显示 loading
      if (_phase != _InsightPhase.loading) {
        setState(() => _phase = _InsightPhase.loading);
        _shimmerController.repeat();
      }
    } else if (DDLAIInsightCard.hasResult) {
      // 后台分析完成，显示结果
      _shimmerController.stop();
      _startTypewriterFromContent(_cachedInsight!, useTypewriter: true);
    } else if (_hasError) {
      _shimmerController.stop();
      setState(() => _phase = _InsightPhase.error);
    }
  }

  Future<void> _loadConfigAndAnalyze() async {
    // 用户已点击叉号关闭：本次 App 运行期间不再加载，直到 App 终止
    if (_dismissedByUser) {
      if (mounted) setState(() => _phase = _InsightPhase.hidden);
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    _aiEnabled = prefs.getBool('ai_enabled') ?? false;
    // 与 AIService.loadConfig 一致：只认内置/Agnes/自定义，历史遗留值回落内置
    String provider = prefs.getString('ai_provider') ?? 'builtin';
    if (provider != 'builtin' && provider != 'agnes' && provider != 'custom') {
      provider = 'builtin';
    }
    _currentProvider = provider;

    if (!_aiEnabled) {
      if (mounted) setState(() => _phase = _InsightPhase.disabled);
      return;
    }

    // 内存缓存命中（非首次进入，直接显示完整文字，不使用打字机）
    if (DDLAIInsightCard.hasResult) {
      _startTypewriterFromContent(_cachedInsight!, useTypewriter: false);
      return;
    }

    // 后台正在分析中，显示 loading 等待结果
    if (_isAnalyzing) {
      if (mounted) {
        setState(() => _phase = _InsightPhase.loading);
        _shimmerController.repeat();
      }
      return;
    }

    // 「自动任务分析」子开关关闭：上面已经放过「有结果→保留展示」和
    // 「在跑→等它跑完」，走到这里意味着要发起一次新的分析——不再发起，
    // 整块收起（下次进入同样不生成，直到重新打开）
    if (!widget.autoAnalysis) {
      widget.onHeightChanged?.call(0);
      if (mounted) setState(() => _phase = _InsightPhase.hidden);
      return;
    }

    if (widget.tasks.isEmpty) {
      if (mounted) setState(() => _phase = _InsightPhase.idle);
      return;
    }

    _analyzeDDL();
  }

  Future<void> _analyzeDDL() async {
    if (_isAnalyzing) return;
    // 先占住在飞标记：下面的退避是异步的，期间不再接受第二次触发
    _isAnalyzing = true;
    _hasError = false;
    _lastError = null;
    _streamingContent = '';
    if (mounted) {
      setState(() => _phase = _InsightPhase.loading);
      _shimmerController.repeat();
    }

    // 未完成任务快照在退避之前就取好，且全程用这份局部副本：退避后卡片
    // 可能已被切页销毁（widget 读不到），后台分析仍要按发起时的任务跑完
    final pendingTasks = widget.tasks.where((t) => !t.completed).toList();
    // 记录本次分析基于的未完成任务快照：任务增删/编辑/勾选完成后
    // 与快照不同时展示"重新生成"
    _analysisTaskSnapshot = pendingTasks
        .map((t) => '${t.id}|${t.dueDate.toIso8601String()}|${t.name}')
        .toSet();

    // 清场：取消订阅 ≠ 中断请求。上一次（含切页后仍在后台跑的那次）多半卡在
    // 等服务端首字节，它的 socket 会一直挂着；不清掉就发新请求，新旧请求会挤
    // 在同一个云托管实例上一起排队超时——表现就是「重试每次都失败，退出重进
    // 一遍就好」（退出时系统把连接全断了）。与对话页的自动重试同款处理。
    final pendingSubscription = _streamSubscription;
    _streamSubscription = null;
    // 刻意不 await：async* 订阅的 cancel() 要等生成器退出才完成，卡住时永不返回
    unawaited(pendingSubscription?.cancel());
    final aborted = AIService.instance.abortActiveStreams(_aiRequestOwner);
    if (aborted > 0) {
      debugPrint('[DDL Insight] Aborted $aborted stale request(s) before retry');
      await Future<void>.delayed(_retryBackoff);
      if (!_isAnalyzing) return; // 退避期间被叉号关闭 / 其他流程接管
    }

    final tasksInfo = pendingTasks.asMap().entries.map((e) {
      final t = e.value;
      return '${e.key + 1}. ${t.name} - 截止: ${t.dueDate.year}/${t.dueDate.month}/${t.dueDate.day}';
    }).join('\n');

    final overdueTasks =
        pendingTasks.where((t) => t.dueDate.isBefore(DateTime.now())).length;
    final today = DateTime.now();
    final upcomingTasks = pendingTasks.where((t) {
      final diff = t.dueDate.difference(today).inDays;
      return diff >= 0 && diff <= 3;
    }).length;

    // 独立的任务分析提示词（与对话页完全解耦）
    // 简化版：仅输出任务建议，200字以内，无emoji
    final prompt = '''当前待办任务（共${pendingTasks.length}个，已逾期$overdueTasks个，即将到期$upcomingTasks个）：
$tasksInfo

请用简洁的中文分析任务安排，按以下格式输出（不要使用emoji，总字数控制在200字以内）：

## 任务建议
（按优先级给出3条以内的安排建议，每条一行，包含具体任务和时间建议）

## 学习建议
（1条简短的学习方法或注意事项）

直接开始回答，不要开场白。''';

    try {
      _startFirstByteWatchdog();
      final stream = AIService.instance.chatWithModelStream(
        userMessage: prompt,
        systemPrompt: '你是学习助手。回答简洁有重点，不使用emoji，总字数不超过200字。',
        provider: _currentProvider,
        owner: _aiRequestOwner,
      );

      _streamSubscription = stream.listen(
        (chunk) {
          // 首字节已到：看门狗交班给流本身
          _stopFirstByteWatchdog();
          _streamingContent += chunk;
        },
        onError: (error) {
          _stopFirstByteWatchdog();
          _isAnalyzing = false;
          _hasError = true;
          _lastError = _describeError(error);
          _streamUpdateTick.value = _streamUpdateTick.value + 1;
        },
        onDone: () {
          _stopFirstByteWatchdog();
          _isAnalyzing = false;
          if (_streamingContent.isNotEmpty) {
            _cachedInsight = _streamingContent;
            _hasAnalyzed = true;
            _hasError = false;
            // 记录本次分析基于的课表：切换课表后与之不同时展示"重新生成"
            _analysisTimetableId = StorageService.currentTimetableId;
          } else {
            _hasError = true;
            _lastError = '服务端没有返回内容，可再试一次或切换 AI 服务';
          }
          _streamUpdateTick.value = _streamUpdateTick.value + 1;
        },
      );
    } catch (e) {
      _stopFirstByteWatchdog();
      _isAnalyzing = false;
      _hasError = true;
      _lastError = _describeError(e);
      _streamUpdateTick.value = _streamUpdateTick.value + 1;
    }
  }

  /// 首字节看门狗：到点仍没有任何内容，就判定这次请求死了 —— 先强制断开
  /// 自己的连接（否则它会继续占着中转/上游通道），再落到失败态等用户重试
  void _startFirstByteWatchdog() {
    _firstByteTimer?.cancel();
    _firstByteTimer = Timer(_firstByteTimeout, () {
      if (!_isAnalyzing || _streamingContent.isNotEmpty) return;
      debugPrint(
          '[DDL Insight] No first byte within ${_firstByteTimeout.inSeconds}s');
      _stopFirstByteWatchdog();
      final staleSubscription = _streamSubscription;
      _streamSubscription = null;
      unawaited(staleSubscription?.cancel());
      AIService.instance.abortActiveStreams(_aiRequestOwner);
      _isAnalyzing = false;
      _hasError = true;
      _lastError = '等待响应超时（${_firstByteTimeout.inSeconds} 秒），已断开本次连接';
      _streamUpdateTick.value = _streamUpdateTick.value + 1;
    });
  }

  void _stopFirstByteWatchdog() {
    _firstByteTimer?.cancel();
    _firstByteTimer = null;
  }

  /// 失败原因转成人话（AiException 已带中文文案，其他类型截断防刷屏）
  static String _describeError(Object error) {
    final text = error is AiException ? error.message : error.toString();
    return text.length > 60 ? '${text.substring(0, 60)}…' : text;
  }

  /// 从完整内容中提取"任务建议"部分（不带标题）——纯函数，无副作用
  String _extractInsightText(String fullContent) {
    // 正则匹配"任务建议"和"学习建议"部分
    // 支持 markdown 标题（## 任务建议）或加粗（**任务建议**）
    final taskSuggestRegex = RegExp(
      r'(?:^|\n)(?:##\s*)?\*{0,2}(?:任务建议|任务推荐|建议任务)\*{0,2}\s*[:：]?\s*\n?',
      multiLine: true,
    );
    final studySuggestRegex = RegExp(
      r'(?:^|\n)(?:##\s*)?\*{0,2}(?:学习建议|学习推荐|学习方法)\*{0,2}\s*[:：]?\s*\n?',
      multiLine: true,
    );

    final taskMatch = taskSuggestRegex.firstMatch(fullContent);
    final studyMatch = studySuggestRegex.firstMatch(fullContent);

    if (taskMatch != null) {
      final typewriterStart = taskMatch.end;
      final typewriterEnd = studyMatch != null ? studyMatch.start : fullContent.length;
      return fullContent.substring(typewriterStart, typewriterEnd).trim();
    }
    // 没匹配到任务建议，显示全部内容
    return fullContent.trim();
  }

  /// 从完整内容提取文字后启动打字机
  /// [useTypewriter] 为 true 时使用打字机效果，否则直接显示完整文字
  void _startTypewriterFromContent(String fullContent, {required bool useTypewriter}) {
    _typewriterContent = _extractInsightText(fullContent);

    if (_typewriterContent.isEmpty) {
      if (mounted) setState(() => _phase = _InsightPhase.done);
      return;
    }

    if (!useTypewriter) {
      // 非首次进入，直接显示完整文字
      if (mounted) {
        setState(() {
          _phase = _InsightPhase.done;
          _typewriterIndex = _typewriterContent.length;
        });
        _measureHeight();
      }
      return;
    }

    if (mounted) {
      setState(() {
        _phase = _InsightPhase.typing;
        _typewriterIndex = 0;
      });
      _startTypewriter();
    }
  }

  void _startTypewriter() {
    _typewriterTimer?.cancel();
    _typewriterTimer = Timer.periodic(const Duration(milliseconds: 30), (timer) {
      if (_typewriterIndex < _typewriterContent.length) {
        _typewriterIndex++;
        if (mounted) setState(() {});
      } else {
        timer.cancel();
        if (mounted) {
          setState(() => _phase = _InsightPhase.done);
          // 打字机完成后测量最终高度（仅在 phase 变化时测量，避免每帧触发回调）
          _measureHeight();
        }
      }
    });
  }

  final GlobalKey _containerKey = GlobalKey();

  /// 当前未完成任务快照（与 _analysisTaskSnapshot 同构可比）
  Set<String> _currentTaskSnapshot() {
    return widget.tasks
        .where((t) => !t.completed)
        .map((t) => '${t.id}|${t.dueDate.toIso8601String()}|${t.name}')
        .toSet();
  }

  /// 是否需要展示"重新生成"按钮：已有分析结果，且当前课表或未完成任务
  /// 集合（新增/删除/勾选完成/编辑）与分析时不同（正常情况不展示）
  bool get _needsRegenerate =>
      _analysisTimetableId != null &&
      (_analysisTimetableId != StorageService.currentTimetableId ||
          _analysisTaskSnapshot == null ||
          !_setEquals(_analysisTaskSnapshot!, _currentTaskSnapshot()));

  static bool _setEquals(Set<String> a, Set<String> b) {
    if (a.length != b.length) return false;
    for (final v in a) {
      if (!b.contains(v)) return false;
    }
    return true;
  }

  /// 叉号关闭：参数对齐课表/课程删除动画（220ms easeInCubic，
  /// 模糊增大 + 向内缩小 + 淡出），播完置 hidden——本次 App 运行
  /// 期间不再加载，直到 App 终止
  void _dismissInsight() {
    if (_dismissController != null && _dismissController!.isAnimating) return;
    _dismissCurved?.dispose();
    _dismissController?.dispose();
    _dismissController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _dismissCurved = CurvedAnimation(
      parent: _dismissController!,
      curve: Curves.easeInCubic,
    );
    setState(() {});
    _dismissController!.forward(from: 0).whenComplete(() {
      if (!mounted) return;
      _dismissedByUser = true;
      _shimmerController.stop();
      _typewriterTimer?.cancel();
      widget.onHeightChanged?.call(0);
      setState(() => _phase = _InsightPhase.hidden);
    });
  }

  /// 重新生成：丢弃缓存结果，按当前课表/任务重新分析
  void _regenerate() {
    if (_isAnalyzing) return;
    _cachedInsight = null;
    _hasAnalyzed = false;
    _hasError = false;
    _lastError = null;
    _analysisTimetableId = null;
    _analysisTaskSnapshot = null;
    _typewriterContent = '';
    _typewriterIndex = 0;
    _typewriterTimer?.cancel();
    _shimmerController.repeat();
    setState(() => _phase = _InsightPhase.loading);
    _analyzeDDL();
  }

  void _measureHeight() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _containerKey.currentContext;
      if (ctx != null && widget.onHeightChanged != null) {
        final box = ctx.findRenderObject() as RenderBox?;
        if (box != null && box.hasSize) {
          widget.onHeightChanged!(box.size.height);
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // 已被用户关闭：本次 App 运行期间不再展示（外层 AnimatedSize 平滑收起）
    if (_phase == _InsightPhase.hidden) {
      return const SizedBox.shrink();
    }

    Widget card = RepaintBoundary(
      child: Container(
        key: _containerKey,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.of(context).surface,
          borderRadius: BorderRadius.circular(16),
          // 柔光参数与对话页分析完成气泡样式完全一致
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF4A90E2).withValues(alpha: 0.12),
              blurRadius: 16,
              spreadRadius: 1,
              offset: const Offset(0, 2),
            ),
          ],
          border: Border.all(
            color: const Color(0xFF4A90E2).withValues(alpha: 0.25),
            width: 1,
          ),
        ),
        child: _buildContent(),
      ),
    );

    // 关闭动画播放中：模糊增大 + 向内缩小 + 淡出（逐帧驱动）
    if (_dismissController != null && _dismissController!.isAnimating) {
      card = AnimatedBuilder(
        animation: _dismissCurved ?? kAlwaysDismissedAnimation,
        builder: (context, child) {
          final t = _dismissCurved?.value ?? 0.0;
          return IgnorePointer(
            child: Opacity(
              opacity: (1.0 - t).clamp(0.0, 1.0),
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(
                  sigmaX: 14 * t,
                  sigmaY: 14 * t,
                ),
                child: Transform.scale(
                  scale: 1.0 - 0.45 * t,
                  child: child,
                ),
              ),
            ),
          );
        },
        child: card,
      );
    }

    return card;
  }

  Widget _buildContent() {
    switch (_phase) {
      case _InsightPhase.disabled:
        return _buildDisabledContent();
      case _InsightPhase.idle:
        return _buildIdleContent();
      case _InsightPhase.loading:
        return _buildActionWrapper(_buildSkeletonWithShimmer());
      case _InsightPhase.typing:
      case _InsightPhase.done:
        return _buildActionWrapper(_buildInsightContent());
      case _InsightPhase.error:
        return _buildErrorContent();
      case _InsightPhase.hidden:
        return const SizedBox.shrink();
    }
  }

  /// 右上角操作按钮（叉号 + 可选的重新生成），叠加在内容之上：
  /// 按钮仅覆盖右上角，不占用正文空间（下方文字不避让）
  Widget _buildActionWrapper(Widget content) {
    return Stack(
      children: [
        content,
        Positioned(
          top: 0,
          right: 0,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 重新生成：仅当课表已切换（与当前分析基于的课表不同）时展示，
              // 🔁 循环图标 + 与叉号一致的极简配色
              if (_needsRegenerate)
                GestureDetector(
                  onTap: _regenerate,
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
              if (_needsRegenerate) const SizedBox(width: 8),
              GestureDetector(
                onTap: _dismissInsight,
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    Icons.close,
                    size: 17,
                    color: AppColors.of(context).textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDisabledContent() {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: AppColors.bannerChip(context, Colors.orange),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(Icons.info_outline, color: AppColors.bannerText(context, Colors.orange), size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            '开启 AI 功能后可自动分析任务',
            style: TextStyle(fontSize: 13, color: AppColors.of(context).textSecondary),
          ),
        ),
      ],
    );
  }

  Widget _buildIdleContent() {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: const Color(0xFF4A90E2).withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(Icons.auto_awesome,
              color: Color(0xFF4A90E2), size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            '暂无任务需要分析',
            style: TextStyle(fontSize: 13, color: AppColors.of(context).textSecondary),
          ),
        ),
      ],
    );
  }

  /// Skeleton 加载：三行灰底条条 + 白色刷新波浪 shimmer
  Widget _buildSkeletonWithShimmer() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 标题行
        _buildShimmerLine(fraction: 0.4, height: 14),
        const SizedBox(height: 12),
        // 三行灰底条条（首条右端避开右上角的叉号/重新生成按钮）
        Padding(
          padding: EdgeInsets.only(right: _needsRegenerate ? 72 : 36),
          child: _buildShimmerLine(fraction: 1.0, height: 10),
        ),
        const SizedBox(height: 8),
        _buildShimmerLine(fraction: 0.85, height: 10),
        const SizedBox(height: 8),
        _buildShimmerLine(fraction: 0.7, height: 10),
      ],
    );
  }

  Widget _buildShimmerLine({required double fraction, required double height}) {
    return FractionallySizedBox(
      alignment: Alignment.centerLeft,
      widthFactor: fraction,
      child: AnimatedBuilder(
        animation: _shimmerController,
        builder: (context, child) {
          return ShaderMask(
            shaderCallback: (bounds) {
              final progress = _shimmerController.value;
              return LinearGradient(
                begin: Alignment(-1 + progress * 2, 0),
                end: Alignment(progress * 2, 0),
                colors: Theme.of(context).brightness == Brightness.dark
                    ? const [
                        Color(0x1AFFFFFF),
                        Color(0x33FFFFFF),
                        Color(0x1AFFFFFF),
                      ]
                    : const [
                        Color(0xFFEEEEEE),
                        Colors.white,
                        Color(0xFFEEEEEE),
                      ],
                stops: const [0.0, 0.5, 1.0],
              ).createShader(bounds);
            },
            child: Container(
              height: height,
              decoration: BoxDecoration(
                color: AppColors.of(context).borderWeak,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildInsightContent() {
    final showCursor = _phase == _InsightPhase.typing;
    final typewriterText =
        _typewriterContent.substring(0, _typewriterIndex);

    final markdownStyle = TextStyle(
        fontSize: 12,
        height: 1.4,
        color: AppColors.of(context).textPrimary);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 标题行
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xFF4A90E2).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.auto_awesome,
                  color: Color(0xFF4A90E2), size: 16),
            ),
            const SizedBox(width: 8),
            Text(
              'AI任务提示',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.of(context).textPrimary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        // Stack：不可见的完整文字决定尺寸（保持 Container 稳定，柔光不跳变），
        // 可见的打字机文字叠加在顶部
        Stack(
          children: [
            // 不可见的完整文字，仅用于撑开 Stack 高度
            Opacity(
              opacity: 0,
              child: GptMarkdown(
                _typewriterContent,
                style: markdownStyle,
              ),
            ),
            // 可见的打字机文字，顶部对齐
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: GptMarkdown(
                typewriterText + (showCursor ? '▋' : ''),
                style: markdownStyle,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildErrorContent() {
    final error = _lastError;
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: AppColors.bannerBg(context, Colors.red),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(Icons.error_outline, color: AppColors.bannerText(context, Colors.red), size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '分析失败，点击重试',
                style: TextStyle(fontSize: 13, color: AppColors.of(context).textSecondary),
              ),
              // 失败原因副标题：额度 / 网络 / 中转挂了在这里就能分辨
              // （重试前会先断掉上一次卡住的连接，见 _analyzeDDL）
              if (error != null && error.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  error,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.3,
                    color: AppColors.of(context).textTertiary,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: _analyzeDDL,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF4A90E2).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              '重试',
              style: TextStyle(
                fontSize: 12,
                color: Color(0xFF4A90E2),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
