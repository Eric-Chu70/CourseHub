// 加号 FAB 的「添加」底部弹出框（课表页 / 待办页共用）。
//
// 原为 timetable_screen 与 heatmap_screen 各自维护的一份几乎相同的实现，
// 抽到这里统一管理，避免双实现漂移；两页只传各自的课程/任务点击回调。
//
// 结构与动效：
// - 第一页：标题「添加」+ AI 引导入口行（紫色，星闪图标）+ 课程/任务两大卡；
// - 点击 AI 入口整体平滑左移切入第二页（AI 引导页），标题左侧出现与关闭
//   按钮对称的返回按钮，可平滑左移回第一页；关闭按钮位置恒定不参与切换；
// - 页面切换 = ClipRect 内的 AnimatedSwitcher 双向 SlideTransition
//   （旧页滑出左缘、新页自右缘滑入，反向相反），高度变化由外层
//   AnimatedSize 连贯过渡（与设置页「检查更新」对话框同款高度策略，
//   但内容切换是横滑而非模糊淡入淡出）；
// - AI 引导页：SegmentedSelector 切换课表/任务 + 右侧「复制模板」按钮，
//   下方提示词框 PageView 三页（添加/删除/管理）横向滑动，无操作 5s
//   自动按顺序轮播循环，手动滑动后计时器重置；底部「前往对话页」按钮
//   关闭弹出框并跳转对话页 Tab。

import 'dart:async';

import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import '../widgets/segmented_selector.dart';
import '../widgets/toast_notification.dart';

/// AI 引导页主色（紫色系）：入口行、复制按钮、「前往对话页」按钮共用。
const Color _kAiAccent = Color(0xFF9C6ADE);

/// 提示词条目：展示版（带具体虚拟信息，让用户看懂怎么问）
/// 与复制版（xxx 占位模板，用户粘贴后自己填）成对出现。
class _PromptItem {
  final String sample;
  final String template;
  const _PromptItem(this.sample, this.template);
}

/// 课表 / 任务各自的「添加 / 删除 / 管理」三条提示词。
const Map<String, List<_PromptItem>> _kPromptSets = {
  'course': [
    _PromptItem(
      '帮我添加一个课程，课程名是高等数学，老师是张伟，地点是教学楼A-301，'
          '上课时间是第1-16周，每周一第3节到第4节',
      '帮我添加一个课程，课程名是xxx，老师xxx，地点xxx，'
          '上课时间是第x-x周，节次第x节到第x节',
    ),
    _PromptItem(
      '帮我把高等数学这门课删掉，它是每周一第3节到第4节的课',
      '帮我删除课程xxx，上课时间是第x-x周，节次第x节到第x节',
    ),
    _PromptItem(
      '帮我看看周三有哪些课，再把大学英语调到周五第1节到第2节，'
          '地点换成外语楼B-201',
      '帮我查看周x的课，并把课程xxx调整到周x第x节到第x节，地点xxx',
    ),
  ],
  'task': [
    _PromptItem(
      '帮我添加一个任务，任务是完成线性代数作业，截止时间是本周五22:00，优先级高',
      '帮我添加一个任务，任务是xxx，截止时间是xx，优先级x',
    ),
    _PromptItem(
      '帮我把「完成线性代数作业」这个任务删掉',
      '帮我删除任务xxx',
    ),
    _PromptItem(
      '帮我看看这周有哪些未完成的任务，把实验报告的截止时间延到下周三18:00',
      '帮我查看未完成的任务，并把任务xxx的截止时间改为xx',
    ),
  ],
};

/// 弹出「添加」底部对话框。各回调在弹出框关闭前的原页面上下文中执行。
Future<void> showAddOptionsSheet(
  BuildContext context, {
  required VoidCallback onCourse,
  required VoidCallback onTask,
  required VoidCallback onGoToChat,
}) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (context) => _AddOptionsSheet(
      onCourse: onCourse,
      onTask: onTask,
      onGoToChat: onGoToChat,
    ),
  );
}

class _AddOptionsSheet extends StatefulWidget {
  final VoidCallback onCourse;
  final VoidCallback onTask;
  final VoidCallback onGoToChat;

  const _AddOptionsSheet({
    required this.onCourse,
    required this.onTask,
    required this.onGoToChat,
  });

  @override
  State<_AddOptionsSheet> createState() => _AddOptionsSheetState();
}

class _AddOptionsSheetState extends State<_AddOptionsSheet> {
  /// 当前页：0 = 添加选项页，1 = AI 引导页
  int _page = 0;

  /// 最近一次切换的方向（true = 向前进入 AI 页，false = 返回），
  /// 决定 AnimatedSwitcher 里新旧页各自的滑动方向
  bool _forward = true;

  /// AI 引导页内的分类：course / task
  String _category = 'course';

  late final PageController _promptController = PageController();
  int _promptPage = 0;
  Timer? _promptTimer;

  @override
  void initState() {
    super.initState();
    _startPromptTimer();
  }

  @override
  void dispose() {
    _promptTimer?.cancel();
    _promptController.dispose();
    super.dispose();
  }

  /// 切换页面（0 ↔ 1），记录方向供滑动过渡使用
  void _switchPage(int target) {
    setState(() {
      _forward = target > _page;
      _page = target;
    });
  }

  /// 提示词自动轮播：无操作每 5s 切到下一条，顺序循环；
  /// 每次翻页（含用户手动滑动触发的）都重置计时器
  void _startPromptTimer() {
    _promptTimer?.cancel();
    _promptTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted || !_promptController.hasClients) return;
      final next = (_promptPage + 1) % _kPromptSets[_category]!.length;
      _promptController.animateToPage(
        next,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOutCubic,
      );
    });
  }

  void _copyCurrentTemplate() {
    final prompts = _kPromptSets[_category]!;
    final template = prompts[_promptPage.clamp(0, prompts.length - 1)].template;
    Clipboard.setData(ClipboardData(text: template));
    HapticFeedback.selectionClick();
    toastNotification.show(context, '已复制');
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(16),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
          child: Container(
            decoration: BoxDecoration(
              color: AppColors.of(context)
                  .glassShell
                  .withValues(alpha: AppColors.isDark(context) ? 0.82 : 0.35),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: AppColors.of(context).glassBorder,
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.15),
                  blurRadius: 25,
                  spreadRadius: 2,
                  offset: const Offset(0, -4),
                ),
                BoxShadow(
                  color: Colors.white.withValues(alpha: 0.6),
                  blurRadius: 0,
                  offset: const Offset(0, -1),
                ),
              ],
            ),
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildTitleBar(),
                  // 高度连贯变化 + 自然裁切，两层的分工（顺序不能反）：
                  // AnimatedSize 负责把对话框高度从 H_old 平滑过渡到 H_new；
                  // Stack 尺寸只由新页决定（旧页 Positioned 悬浮退场），避免
                  // "切换结束后高度再跳一下"。
                  // 关键：ClipRect 必须包在 AnimatedSize **外层**。放内层时它
                  // 裁剪的是 Stack（高度恒为新页目标高度 H_new），旧页底部会在
                  // 切换第一帧就被按目标高度整段切掉（"前往对话页"瞬间消失）。
                  // 放外层后，裁剪边界跟着对话框**动画中的实时高度 H(t)** 走：
                  // 旧页以完整原始高度渲染，随高度收缩逐步被底边吃掉。
                  ClipRect(
                    child: AnimatedSize(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOutCubic,
                      alignment: Alignment.topCenter,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        switchInCurve: Curves.easeInOutCubic,
                        switchOutCurve: Curves.easeInOutCubic,
                        transitionBuilder: (child, animation) {
                          final idx = (child.key as ValueKey<int>).value;
                          final isIncoming = idx == _page;
                          // 纯横向滑动 + 淡入淡出：两页高度接近后，纵向位移
                          // 已无必要（此前为「底部被硬切」加的下沉，现在由
                          // ClipRect 在 AnimatedSize 外层自然裁切即可）
                          final outX = _forward ? -0.35 : 0.35;
                          // 新页从反方向一侧进入；旧页向 outX 方向滑出。
                          // 出场动画由 AnimatedSwitcher 反向播放（1→0），故
                          // Tween(begin: 偏移, end: zero) 恰为 原位→偏移
                          final beginX = isIncoming ? -outX : outX;
                          return FadeTransition(
                            opacity: animation,
                            child: SlideTransition(
                              position: Tween<Offset>(
                                begin: Offset(beginX, 0),
                                end: Offset.zero,
                              ).animate(animation),
                              child: child,
                            ),
                          );
                        },
                        // 旧页悬浮在**上层**退场：否则会被上层的新页盖住，
                        // 看不到它的位移；旧页不参与定尺寸（Stack 高度只由
                        // 新页决定），高度不同也不跳位
                        layoutBuilder:
                            (currentChild, previousChildren) => Stack(
                          alignment: Alignment.topCenter,
                          clipBehavior: Clip.none,
                          children: [
                            if (currentChild != null) currentChild,
                            for (final child in previousChildren)
                              Positioned(left: 0, right: 0, child: child),
                          ],
                        ),
                        child: _page == 0
                            ? _buildOptionsPage(
                                key: const ValueKey<int>(0))
                            : _buildAiGuidePage(
                                key: const ValueKey<int>(1)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 标题栏：左侧标题区（随页面横滑切换，AI 页含返回按钮）+
  /// 右侧关闭按钮（位置恒定，不参与切换、不消失重现）
  Widget _buildTitleBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
      child: Row(
        children: [
          Expanded(
            child: ClipRect(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                switchInCurve: Curves.easeInOutCubic,
                switchOutCurve: Curves.easeInOutCubic,
                transitionBuilder: (child, animation) {
                  // 标题区与内容区同款节奏：滑动 + 淡入淡出（含返回按钮）
                  final idx = (child.key as ValueKey<int>).value;
                  final isIncoming = idx == _page;
                  final beginX = isIncoming
                      ? (_forward ? 1.0 : -1.0)
                      : (_forward ? -1.0 : 1.0);
                  return FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: Offset(beginX, 0),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  );
                },
                // 左对齐布局（AnimatedSwitcher 默认居中，会把「添加」挤到
                // 中间导致不对齐）；旧标题水平悬浮退场，宽度由新标题决定
                layoutBuilder: (currentChild, previousChildren) => Stack(
                  alignment: AlignmentDirectional.centerStart,
                  clipBehavior: Clip.none,
                  children: [
                    for (final child in previousChildren)
                      Positioned(left: 0, right: 0, child: child),
                    if (currentChild != null) currentChild,
                  ],
                ),
                child: _page == 0
                    ? SizedBox(
                        key: const ValueKey<int>(0),
                        width: double.infinity,
                        child: const Text(
                          '添加',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      )
                    : SizedBox(
                        key: const ValueKey<int>(1),
                        width: double.infinity,
                        child: Row(
                          children: [
                            _buildBackButton(),
                            const SizedBox(width: 10),
                            Expanded(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: AlignmentDirectional.centerStart,
                                child: Text(
                                  '使用课表助手管理课程和任务',
                                  style: TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.of(context).textPrimary,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
            ),
          ),
          _buildCloseButton(),
        ],
      ),
    );
  }

  /// 返回按钮：与关闭按钮同款 32×32 圆角方块，对称呼应
  Widget _buildBackButton() {
    return GestureDetector(
      onTap: () => _switchPage(0),
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: AppColors.of(context).surfaceAlt,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          Icons.arrow_back_ios_new,
          size: 15,
          color: AppColors.of(context).textSecondary,
        ),
      ),
    );
  }

  Widget _buildCloseButton() {
    return GestureDetector(
      onTap: () => Navigator.pop(context),
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: AppColors.of(context).surfaceAlt,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(Icons.close,
            size: 18, color: AppColors.of(context).textSecondary),
      ),
    );
  }

  /// 第一页：AI 引导入口行 + 课程/任务两大卡
  Widget _buildOptionsPage({required Key key}) {
    return Column(
      key: key,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _buildAiEntry(),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: _buildAddOptionCard(
                  icon: Icons.book,
                  label: '课程',
                  color: const Color(0xFF4A90E2),
                  // 关闭弹出框的动作统一在这里做：页面回调只管业务
                  // （弹课程/任务对话框等），否则双页各自维护容易漏 pop
                  onTap: () {
                    Navigator.pop(context);
                    widget.onCourse();
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildAddOptionCard(
                  icon: Icons.task_alt,
                  label: '任务',
                  color: Colors.orange,
                  onTap: () {
                    Navigator.pop(context);
                    widget.onTask();
                  },
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  /// AI 引导入口行：紫色系圆角矩形，星闪图标 + 文案 + 右箭头
  Widget _buildAiEntry() {
    return InkWell(
      onTap: () => _switchPage(1),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: _kAiAccent.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _kAiAccent.withValues(alpha: 0.2)),
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: _kAiAccent.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.auto_awesome,
                  size: 19, color: _kAiAccent),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '使用课表助手添加',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: _kAiAccent,
                ),
              ),
            ),
            Icon(Icons.chevron_right,
                size: 20, color: _kAiAccent.withValues(alpha: 0.7)),
          ],
        ),
      ),
    );
  }

  /// 第二页（AI 引导页）：分类滑块 + 复制模板 / 提示词轮播框 / 前往对话页
  Widget _buildAiGuidePage({required Key key}) {
    final prompts = _kPromptSets[_category]!;
    return Column(
      key: key,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: SegmentedSelector<String>(
                  // 设置页「切换界面风格」同款：浅色模式白把手黑字样式
                  whiteKnobInLight: true,
                  items: const [
                    SegmentItem(label: '课表', value: 'course'),
                    SegmentItem(label: '任务', value: 'task'),
                  ],
                  activeValue: _category,
                  onChanged: (value) {
                    if (value == _category) return;
                    setState(() {
                      _category = value;
                      _promptPage = 0;
                    });
                    _promptController.jumpToPage(0);
                    _startPromptTimer();
                  },
                ),
              ),
              const SizedBox(width: 12),
              _buildCopyButton(),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _buildPromptCarousel(prompts),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _buildGoToChatButton(),
        ),
        // 底部只留很小间距：SafeArea 还会垫入系统手势条高度，
        // 这里给大了会出现按钮下方一大段空白
        const SizedBox(height: 6),
      ],
    );
  }

  /// 复制模板按钮：复制当前轮播那条提示词对应的 xxx 占位模板
  Widget _buildCopyButton() {
    return GestureDetector(
      onTap: _copyCurrentTemplate,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: _kAiAccent.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _kAiAccent.withValues(alpha: 0.25)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.copy_outlined, size: 15, color: _kAiAccent),
            const SizedBox(width: 5),
            Text(
              '复制模板',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: _kAiAccent,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 提示词轮播框：PageView 三页横滑（添加/删除/管理），
  /// 底部居中三个小圆点指示当前条目
  Widget _buildPromptCarousel(List<_PromptItem> prompts) {
    // 框高不再拍脑袋定死：用 TextPainter 按当前实际宽度量出本分类
    // 三条提示词中最长那条的真实高度，框高贴合内容（上下各留固定边距），
    // 不再为「假设的 4 行」预留大片空白。分类切换时最长条目行数不同，
    // 高度用 AnimatedContainer 平滑过渡
    return LayoutBuilder(builder: (context, constraints) {
      const hPad = 16.0, vTop = 9.0, vBottom = 20.0;
      final style = TextStyle(
        fontSize: 13,
        height: 1.55,
        color: AppColors.of(context).textPrimary,
      );
      double maxTextH = 0;
      for (final p in prompts) {
        final tp = TextPainter(
          text: TextSpan(text: p.sample, style: style),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: constraints.maxWidth - hPad * 2);
        maxTextH = math.max(maxTextH, tp.height);
        tp.dispose();
      }
      return AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        height: math.max(maxTextH + vTop + vBottom, 72.0),
      decoration: BoxDecoration(
        // 半透明底板（不纯色）：毛玻璃壳上再叠一层通透面板
        color: AppColors.of(context).surfaceAlt.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.of(context).borderWeak),
      ),
      child: Stack(
        children: [
          PageView.builder(
            controller: _promptController,
            itemCount: prompts.length,
            onPageChanged: (index) {
              setState(() => _promptPage = index);
              // 手动滑动 / 自动翻页后都重置 5s 计时
              _startPromptTimer();
            },
            itemBuilder: (context, index) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 9, 16, 20),
                child: Center(
                  child: Text(
                    prompts[index].sample,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.55,
                      color: AppColors.of(context).textPrimary,
                    ),
                  ),
                ),
              );
            },
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 8,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < prompts.length; i++)
                  Container(
                    width: 5,
                    height: 5,
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i == _promptPage
                          ? _kAiAccent
                          : _kAiAccent.withValues(alpha: 0.25),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
      );
    });
  }

  /// 前往对话页：关闭弹出框后跳转对话页 Tab（回调由 home_screen 传入）
  Widget _buildGoToChatButton() {
    return InkWell(
      onTap: () {
        Navigator.pop(context);
        widget.onGoToChat();
      },
      borderRadius: BorderRadius.circular(14),
      child: Container(
        height: 46,
        decoration: BoxDecoration(
          color: _kAiAccent.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _kAiAccent.withValues(alpha: 0.25)),
        ),
        child: Center(
          child: Text(
            '前往对话页',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: _kAiAccent,
            ),
          ),
        ),
      ),
    );
  }

  /// 课程/任务两大卡（与原两页实现同款样式）
  Widget _buildAddOptionCard({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 20),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withValues(alpha: 0.2)),
        ),
        child: Column(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color, size: 24),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
