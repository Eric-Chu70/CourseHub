// 设置页「AI配置」多阶段对话框：主菜单 → Agnes AI 配置 / 自定义 API 配置
// 融合在**同一个对话框**内完成（旧实现是「主对话框 + 两个子对话框」，
// 点进子配置时旧框关闭、新框弹出，连续开关造成视觉断裂）。
//
// 动效与云端数据管理对话框（dialogs/cloud_data_manager_dialog.dart）同源：
//  1. 阶段切换：旧内容模糊淡出、新内容自模糊中清晰淡入（同检查更新对话框）。
//     Stack 尺寸只由新内容决定，旧内容顶部锚定悬浮退场（不能垂直居中，
//     否则旧内容会在第一帧跳到新高度的居中位置）；
//  2. 高度：整块内容由 AnimatedSize 平滑收缩/展开，按钮与壳高度逐帧跟随
//     （主菜单 ≈444 / Agnes ≈340 / 自定义 ≈560，三者高度差很大，
//     若直接换框会瞬间跳变）。ClipRect 包在 AnimatedSize 外层，
//     旧内容超出部分随动画中的实时高度逐步被底边裁掉。
//  3. 「减弱动态效果」开启时退化为单纯淡入淡出。
//
// 三个阶段的 UI 均 1:1 沿用原设置页实现（含各自的头部形态与按钮），
// 只是不再各自弹窗。

import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/ai_feature_flags.dart';
import '../screens/ai_assistant_screen.dart';
import '../services/glm_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_text_field.dart';
import '../widgets/blur_selection_menu.dart';
import '../widgets/builtin_ai_usage_bar.dart';
import '../widgets/glass_dialog.dart';
import '../widgets/segmented_selector.dart';
import '../widgets/toast_notification.dart';

/// 自定义 API 的视觉能力模式（与原设置页同款三态）
enum _CustomVisionMode {
  auto,
  enabled,
  disabled,
}

/// 阶段
enum _AIConfigStage {
  /// 主菜单：内置模型卡片 + 推荐选项（Agnes / 自定义 API）
  menu,

  /// Agnes AI 配置：密钥 + 模型 + 思考强度
  agnes,

  /// 自定义 OpenAI 兼容 API：地址 / 密钥 / 模型 + 视觉 + 思考 + 联网
  custom,
}

/// 壳高度上限：按最高的自定义 API 阶段取（原该子对话框的 650），
/// 另两个阶段内容天然更矮
const double _baseMaxShellHeight = 650.0;

/// 内容区高度上限 = 壳上限 − 上下 shellPadding(24×2)。
/// 给定上限后 SingleChildScrollView 取内容自然高度，只有超出时才滚动
const double _contentMaxHeight = _baseMaxShellHeight - 24.0 * 2;

/// 打开 AI 配置对话框。
///
/// [onConfigSaved]：任一阶段保存成功后回调（设置页据此刷新自己的
/// 状态与「AI配置」项小字）
Future<void> showAIConfigDialog(
  BuildContext context, {
  Future<void> Function()? onConfigSaved,
}) async {
  final reduceMotion = await readReduceMotionPref();
  if (!context.mounted) return;
  await showBouncyDialog(
    context: context,
    barrierLabel: 'AI功能配置',
    shellPadding: const EdgeInsets.all(24),
    // 三个阶段壳宽统一 420（原主对话框 400、两个子对话框 420），
    // 阶段切换时宽度不再跳变
    shellMaxWidth: 420,
    shellMaxHeight: _baseMaxShellHeight,
    // 配置阶段有输入框：键盘弹出时整壳上移避让
    avoidKeyboard: true,
    shellConstraintsBuilder: _aiConfigShellConstraints,
    shellBoxShadow: const [
      BoxShadow(
        color: Color(0x33000000),
        blurRadius: 20,
        offset: Offset(0, 10),
      ),
    ],
    reduceMotion: reduceMotion,
    builder: (context) => _AIConfigBody(
      reduceMotion: reduceMotion,
      onConfigSaved: onConfigSaved,
    ),
  );
}

/// 键盘弹出时压缩最大高度，保证输入框与底部按钮完整可见
BoxConstraints _aiConfigShellConstraints(BuildContext context) {
  final mediaQuery = MediaQuery.of(context);
  final keyboardHeight = mediaQuery.viewInsets.bottom;
  final topInset = mediaQuery.padding.top;
  final screenHeight = mediaQuery.size.height;
  double dialogMaxHeight = _baseMaxShellHeight;
  final availableHeight = screenHeight - topInset - keyboardHeight - 24;
  if (availableHeight < dialogMaxHeight) {
    dialogMaxHeight = availableHeight;
  }
  dialogMaxHeight =
      dialogMaxHeight.clamp(300.0, _baseMaxShellHeight).toDouble();
  return const BoxConstraints(maxWidth: 420)
      .copyWith(maxHeight: dialogMaxHeight);
}

class _AIConfigBody extends StatefulWidget {
  const _AIConfigBody({
    required this.reduceMotion,
    this.onConfigSaved,
  });

  final bool reduceMotion;
  final Future<void> Function()? onConfigSaved;

  @override
  State<_AIConfigBody> createState() => _AIConfigBodyState();
}

class _AIConfigBodyState extends State<_AIConfigBody> {
  _AIConfigStage _stage = _AIConfigStage.menu;

  // ---- 主菜单 ----
  int _builtinNode = 1;
  bool _isBuiltinProvider = false;
  bool _isAgnesProvider = false;
  bool _isCustomProvider = false;
  bool _providerConfigured = false;

  // ---- Agnes ----
  late final TextEditingController _agnesKeyController;
  String _agnesModel = 'agnes-2.0-flash';
  String _agnesReasoningEffort = '';

  // ---- 自定义 API ----
  late final TextEditingController _urlController;
  late final TextEditingController _keyController;
  late final TextEditingController _modelController;
  bool _visionOverride = false;
  bool _visionEnabled = false;
  String _customReasoningEffort = '';
  bool _webSearchEnabled = false;

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _agnesKeyController = TextEditingController();
    _urlController = TextEditingController();
    _keyController = TextEditingController();
    _modelController = TextEditingController();
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final provider = prefs.getString('ai_provider') ?? 'builtin';
    final agnesModel = prefs.getString('agnes_model') ?? 'agnes-2.0-flash';
    setState(() {
      _builtinNode = (prefs.getInt('builtin_node') ?? 1).clamp(1, 4);
      _isBuiltinProvider = provider == 'builtin';
      _isAgnesProvider = provider == 'agnes';
      _isCustomProvider = provider == 'custom';
      _providerConfigured = _isAgnesProvider || _isCustomProvider;
      _agnesKeyController.text = prefs.getString('agnes_api_key') ?? '';
      _agnesModel =
          (agnesModel == 'agnes-2.0-flash' || agnesModel == 'agnes-2.5-flash')
              ? agnesModel
              : 'agnes-2.0-flash';
      _agnesReasoningEffort = prefs.getString('agnes_reasoning_effort') ?? '';
      _urlController.text = prefs.getString('custom_api_url') ?? '';
      _keyController.text = prefs.getString('custom_api_key') ?? '';
      _modelController.text =
          prefs.getString('custom_api_model') ?? 'gpt-4o-mini';
      _visionOverride =
          prefs.getBool('custom_api_vision_manual_override') ?? false;
      _visionEnabled = prefs.getBool('custom_api_vision_manual_value') ?? false;
      _customReasoningEffort =
          prefs.getString('custom_api_reasoning_effort') ?? '';
      _webSearchEnabled = prefs.getBool('web_search_enabled') ?? false;
    });
  }

  @override
  void dispose() {
    // 与邮箱登录表单同理：弹出/切换动画期间 TextField 仍会重建，
    // 立即 dispose 会触发 "TextEditingController used after being disposed"
    final controllers = [
      _agnesKeyController,
      _urlController,
      _keyController,
      _modelController,
    ];
    Future<void>.delayed(const Duration(milliseconds: 300), () {
      for (final controller in controllers) {
        controller.dispose();
      }
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 语义色在 build 顶层取一次：AnimatedSwitcher 的退场子项处于停用态，
    // 子树内做 Theme/MediaQuery 继承查找会抛 "deactivated ancestor"
    final palette = AppColors.of(context);

    // 高度：整块内容由 AnimatedSize 平滑收缩/展开，按钮与壳高度逐帧跟随
    // （主菜单 ≈444 / Agnes ≈340 / 自定义 ≈560，三者高度差很大，
    // 若直接换框会瞬间跳变）。
    // ClipRect 必须包在 AnimatedSize **外层**：裁剪边界跟随动画中的实时
    // 高度 H(t)，旧内容以完整原始高度渲染、随收缩逐步被底边吃掉；放内层
    // 会在第一帧就被新内容目标高度整段硬切（同 add_options_sheet 的教训）
    return ClipRect(
      child: AnimatedSize(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        alignment: Alignment.topCenter,
        child: _blurSwitch(_buildLayout(palette)),
      ),
    );
  }

  Widget _buildLayout(AppPalette palette) {
    switch (_stage) {
      case _AIConfigStage.menu:
        return _buildMenuLayout(palette);
      case _AIConfigStage.agnes:
        return _buildAgnesLayout(palette);
      case _AIConfigStage.custom:
        return _buildCustomLayout(palette);
    }
  }

  /// 阶段切换过渡：模糊淡出 / 自模糊中清晰淡入，交叉过渡不跳变。
  ///
  /// Stack 尺寸只由新内容决定（旧内容悬浮退场、不参与定尺寸），但旧内容
  /// **顶部锚定**而非垂直居中——若居中，阶段一变旧内容会在动画第一帧被
  /// 瞬间挪到「新高度的居中位置」，先跳变再淡出（三个阶段高度差很大，
  /// 跳变尤其明显）。顶部锚定后旧内容位置纹丝不动，超出部分由外层
  /// AnimatedSize 的实时高度 H(t) 逐步裁掉（见 build 注释）。旧内容放
  /// Stack **上层**退场，避免模糊淡出的过程被新内容盖住。
  Widget _blurSwitch(Widget child) => AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        transitionBuilder: (child, animation) {
          if (widget.reduceMotion) {
            return FadeTransition(opacity: animation, child: child);
          }
          return FadeTransition(
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
          );
        },
        // 强制满宽（三阶段壳宽统一 420）：否则 Stack 收缩到新内容的自然
        // 宽度时，Positioned 悬浮的退场内容会被挤压换行一帧。
        // 旧内容只给水平约束、不参与定尺寸，垂直位置跟随 Stack 的
        // topCenter 对齐（即原顶部位置）
        layoutBuilder: (currentChild, previousChildren) => SizedBox(
          width: double.infinity,
          child: Stack(
            alignment: Alignment.topCenter,
            clipBehavior: Clip.none,
            children: [
              if (currentChild != null) currentChild,
              for (final Widget child in previousChildren)
                Positioned(
                  left: 0,
                  right: 0,
                  child: child,
                ),
            ],
          ),
        ),
        child:
            KeyedSubtree(key: ValueKey<_AIConfigStage>(_stage), child: child),
      );

  // ============================================================
  // 主菜单
  // ============================================================

  Widget _buildMenuLayout(AppPalette palette) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: palette.surfaceAlt,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.auto_awesome,
                size: 24,
                color: palette.textPrimary,
              ),
            ),
            const SizedBox(width: 12),
            const Text(
              'AI功能配置',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '选择或配置AI服务提供商',
          style: TextStyle(fontSize: 13, color: palette.textSecondary),
        ),
        const SizedBox(height: 20),
        // 内容区：贴合内容，超出上限时滚动（不再依赖 Expanded + 有界高度）
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: _contentMaxHeight),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 8),
                // 内置模型（限时免费）：与推荐选项相互独立，
                // 选中任意节点即切换到内置模型
                _buildBuiltinModelCard(palette),
                const SizedBox(height: 24),
                _buildSectionDivider(palette),
                const SizedBox(height: 16),
                _buildRecommendedOption(
                  palette: palette,
                  title: 'Agnes AI',
                  subtitle: '输入Agnes AI密钥（免费使用），开箱即用',
                  iconAsset: 'assets/icon/agnes_icon.png',
                  color: const Color(0xFF4A90E2),
                  isSelected: _providerConfigured && _isAgnesProvider,
                  onTap: () => setState(() => _stage = _AIConfigStage.agnes),
                ),
                const SizedBox(height: 12),
                _buildCustomAPIOption(
                  palette: palette,
                  title: '自定义 OpenAI 兼容 API',
                  subtitle: '输入您的API地址和密钥',
                  icon: Icons.api,
                  isSelected: _providerConfigured && _isCustomProvider,
                  onTap: () => setState(() => _stage = _AIConfigStage.custom),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        _fullWidthButton('关闭', () => Navigator.pop(context), palette),
      ],
    );
  }

  /// 内置模型（限时免费）卡片：右侧统一样式下拉切换节点 1-4。
  /// 与推荐选项相互独立：未启用时选项框显示"未使用"且菜单无对勾，
  /// 选中任意节点即切换到内置模型（推荐选项随之取消勾选）
  Widget _buildBuiltinModelCard(AppPalette palette) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF4A90E2).withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: const Color(0xFF4A90E2).withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 上半：文字区（标题 + 描述）与节点下拉垂直居中
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          '内置模型',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 6),
                        // 限时免费标签：浅蓝底胶囊，稍深蓝小字
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.isDark(context)
                                ? const Color(0xFF4A90E2).withValues(alpha: 0.18)
                                : const Color(0xFFE3F0FB),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: const Color(0xFF3B82C4)
                                  .withValues(alpha: 0.45),
                            ),
                          ),
                          child: Text(
                            '限时免费',
                            style: TextStyle(
                              fontSize: 10,
                              color: AppColors.isDark(context)
                                  ? const Color(0xFF9CC8F5)
                                  : const Color(0xFF3B82C4),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '高峰时段可能响应缓慢或无响应',
                      style: TextStyle(
                          fontSize: 12, color: palette.textSecondary),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                // 固定宽度（收起态选项框）：菜单宽度由下方 menuWidth 单独指定
                width: 128,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: palette.surface,
                  borderRadius: BorderRadius.circular(8),
                  // 灰描边仅减弱动态时显示：正常模式白底经毛玻璃本就有边界
                  border: Border.all(
                    color: widget.reduceMotion
                        ? palette.chipIdle
                        : palette.panel(0.4),
                  ),
                ),
                child: BlurredDropdown<int>(
                  prefixIcon: const Icon(Icons.hub_outlined,
                      size: 16, color: Color(0xFF4A90E2)),
                  value: _isBuiltinProvider ? _builtinNode : null,
                  isExpanded: true,
                  menuWidth: 120,
                  hint: Text(
                    '未使用',
                    style:
                        TextStyle(fontSize: 13, color: palette.textTertiary),
                  ),
                  icon: const Icon(Icons.expand_more,
                      size: 18, color: Color(0xFF4A90E2)),
                  items: [
                    for (var i = 1; i <= 4; i++)
                      DropdownMenuItem<int>(
                        value: i,
                        child: Text(
                          '节点 $i',
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                  ],
                  onChanged: (next) async {
                    if (next != null) await _selectBuiltinNode(next);
                  },
                  infoMessages: const {
                    3: '节点3延迟较高，请优先使用节点1、2。',
                    4: '节点4延迟较高，请优先使用节点1、2。',
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // 今日用量：文字居左，进度条同行占满右侧剩余宽度
          const BuiltinAiUsageBar(inline: true),
        ],
      ),
    );
  }

  Future<void> _selectBuiltinNode(int node) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('builtin_node', node);
    await prefs.setString('ai_provider', 'builtin');
    await prefs.setBool('fast_mode_enabled', false);
    await prefs.setBool('ai_enabled', true);
    // 内置节点是应用出的公共额度：首次配置选它时把两个自动分析默认关掉，
    // 免得一进待办页/对话页就白耗公共资源。用户自己填 key 的 Agnes /
    // 自定义仍是默认开启（偏好里没写过即为 true）。手动拨过开关的不再覆盖
    await AIAutoAnalysisFlags.applyFirstRunDefaults(builtin: true);
    // 同步后端服务的节点状态（路由按节点选 endpoint）
    await AIService.instance.setBuiltinNode(node);
    AIAssistantScreenState.markNeedsRefresh();
    if (!mounted) return;
    setState(() {
      _builtinNode = node;
      _isBuiltinProvider = true;
      _isAgnesProvider = false;
      _isCustomProvider = false;
      _providerConfigured = false;
    });
    await widget.onConfigSaved?.call();
  }

  Widget _buildSectionDivider(AppPalette palette) {
    return Row(
      children: [
        Expanded(
          child: Container(height: 1, color: palette.panel(0.4)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            '推荐选项',
            style: TextStyle(fontSize: 12, color: palette.textTertiary),
          ),
        ),
        Expanded(
          child: Container(height: 1, color: palette.panel(0.4)),
        ),
      ],
    );
  }

  Widget _buildRecommendedOption({
    required AppPalette palette,
    required String title,
    required String subtitle,
    IconData? icon,
    String? iconAsset,
    required Color color,
    required bool isSelected,
    required VoidCallback onTap,
    bool disabled = false,
  }) {
    return GestureDetector(
      onTap: disabled ? null : onTap,
      child: Opacity(
        opacity: disabled ? 0.5 : 1.0,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color:
                isSelected ? color.withValues(alpha: 0.1) : palette.panel(0.4),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              // 未选中描边：减弱动态时改浅灰（白描边与近实底壳背景融合）
              color: isSelected
                  ? color
                  : (widget.reduceMotion
                      ? palette.chipIdle
                      : palette.panel(0.4)),
              width: isSelected ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: iconAsset != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: Image.asset(
                          iconAsset,
                          width: 20,
                          height: 20,
                          fit: BoxFit.cover,
                        ),
                      )
                    : Icon(icon, size: 20, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: isSelected ? color : null,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style:
                          TextStyle(fontSize: 12, color: palette.textSecondary),
                    ),
                  ],
                ),
              ),
              // 未选中时显示与自定义API同款箭头
              if (isSelected)
                Icon(Icons.check_circle, color: color, size: 20)
              else
                Icon(Icons.chevron_right, color: palette.textTertiary),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCustomAPIOption({
    required AppPalette palette,
    required String title,
    required String subtitle,
    required IconData icon,
    bool isSelected = false,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFF4A90E2).withValues(alpha: 0.1)
              : palette.panel(0.4),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected
                ? const Color(0xFF4A90E2)
                : (widget.reduceMotion ? palette.chipIdle : palette.panel(0.4)),
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: isSelected
                    ? const Color(0xFF4A90E2).withValues(alpha: 0.2)
                    : palette.panel(0.4),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                icon,
                size: 20,
                color: isSelected
                    ? const Color(0xFF4A90E2)
                    : palette.textSecondary,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: isSelected ? const Color(0xFF4A90E2) : null,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style:
                        TextStyle(fontSize: 12, color: palette.textSecondary),
                  ),
                ],
              ),
            ),
            isSelected
                ? const Icon(Icons.check_circle,
                    color: Color(0xFF4A90E2), size: 20)
                : Icon(Icons.chevron_right, color: palette.textTertiary),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // Agnes AI 配置
  // ============================================================

  Widget _buildAgnesLayout(AppPalette palette) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: _contentMaxHeight),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  'Agnes AI 配置',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 6),
                // 带圈问号：点击向右弹出推荐说明气泡
                _AgnesHelpIcon(reduceMotion: widget.reduceMotion),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '免费密钥申请地址：https://www.agnes-ai.cn/',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: palette.textSecondary),
            ),
            const SizedBox(height: 20),
            AppTextField(
              controller: _agnesKeyController,
              decoration: InputDecoration(
                hintText: '请输入 Agnes AI API Key',
                filled: true,
                fillColor: palette.panel(0.4),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                      color: widget.reduceMotion
                          ? palette.chipIdle
                          : palette.panel(0.4)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                      color: widget.reduceMotion
                          ? palette.chipIdle
                          : palette.panel(0.4)),
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
                  style: TextStyle(fontSize: 14, color: palette.textSecondary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: palette.surface,
                      borderRadius: BorderRadius.circular(12),
                      // 灰描边仅减弱动态时显示：正常模式白底经毛玻璃本就有边界
                      border: Border.all(
                        color: widget.reduceMotion
                            ? palette.chipIdle
                            : palette.panel(0.4),
                      ),
                    ),
                    // BlurredDropdown：与全局毛玻璃风格统一的下拉菜单
                    child: BlurredDropdown<String>(
                      value: _agnesModel,
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
                          setState(() => _agnesModel = next);
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
                style: TextStyle(fontSize: 13, color: palette.textPrimary)),
            const SizedBox(height: 8),
            SegmentedSelector<String>(
              items: const [
                SegmentItem(label: '直接回答', value: ''),
                SegmentItem(label: 'Low', value: 'low'),
                SegmentItem(label: 'Medium', value: 'medium'),
                SegmentItem(label: 'High', value: 'high'),
              ],
              activeValue:
                  _agnesReasoningEffort.isEmpty ? '' : _agnesReasoningEffort,
              onChanged: (v) => setState(() => _agnesReasoningEffort = v),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: _outlineButton(
                      '取消',
                      () => setState(() => _stage = _AIConfigStage.menu),
                      palette),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _primaryButton('保存', _saving ? null : _saveAgnes),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveAgnes() async {
    final apiKey = _agnesKeyController.text.trim();
    if (apiKey.isEmpty) {
      toastNotification.show(context, '请填写 Agnes AI API Key',
          type: ToastType.error);
      return;
    }
    setState(() => _saving = true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('agnes_api_key', apiKey);
    await prefs.setString('agnes_model', _agnesModel);
    await prefs.setString('agnes_reasoning_effort', _agnesReasoningEffort);
    await prefs.setString('ai_provider', 'agnes');
    AIAssistantScreenState.markNeedsRefresh();
    await prefs.setBool('fast_mode_enabled', false);
    await prefs.setBool('ai_enabled', true);
    AIService.instance.setAgnesConfig(apiKey, _agnesModel);
    if (!mounted) return;
    setState(() {
      _saving = false;
      _isAgnesProvider = true;
      _isCustomProvider = false;
      _isBuiltinProvider = false;
      _providerConfigured = true;
      // 回到主菜单：与旧实现「保存后关闭子框、回到主框」的落点一致，
      // 但现在是同一框内的连贯过渡
      _stage = _AIConfigStage.menu;
    });
    _toast('已切换到Agnes AI模型', ToastType.success);
    await widget.onConfigSaved?.call();
  }

  // ============================================================
  // 自定义 OpenAI 兼容 API 配置
  // ============================================================

  Widget _buildCustomLayout(AppPalette palette) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: _contentMaxHeight),
      child: SingleChildScrollView(
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
              style: TextStyle(fontSize: 13, color: palette.textSecondary),
            ),
            const SizedBox(height: 20),
            AppTextField(
              controller: _urlController,
              decoration: InputDecoration(
                labelText: 'API 地址',
                hintText: 'https://api.example.com/v1/chat/completions',
                filled: true,
                fillColor: palette.panel(0.4),
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 12),
            AppTextField(
              controller: _keyController,
              decoration: InputDecoration(
                labelText: 'API Key',
                hintText: '请输入API密钥',
                filled: true,
                fillColor: palette.panel(0.4),
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 12),
            AppTextField(
              controller: _modelController,
              decoration: InputDecoration(
                labelText: '模型名称',
                hintText: 'gpt-4o-mini',
                filled: true,
                fillColor: palette.panel(0.4),
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 12),
            Text('视觉能力支持',
                style: TextStyle(fontSize: 13, color: palette.textPrimary)),
            const SizedBox(height: 8),
            SegmentedSelector<_CustomVisionMode>(
              items: const [
                SegmentItem(label: '自动', value: _CustomVisionMode.auto),
                SegmentItem(label: '开启', value: _CustomVisionMode.enabled),
                SegmentItem(label: '关闭', value: _CustomVisionMode.disabled),
              ],
              activeValue: !_visionOverride
                  ? _CustomVisionMode.auto
                  : (_visionEnabled
                      ? _CustomVisionMode.enabled
                      : _CustomVisionMode.disabled),
              onChanged: (mode) {
                setState(() {
                  if (mode == _CustomVisionMode.auto) {
                    _visionOverride = false;
                    _visionEnabled = false;
                  } else {
                    _visionOverride = true;
                    _visionEnabled = mode == _CustomVisionMode.enabled;
                  }
                });
              },
            ),
            const SizedBox(height: 16),
            Text('思考强度',
                style: TextStyle(fontSize: 13, color: palette.textPrimary)),
            const SizedBox(height: 8),
            SegmentedSelector<String>(
              items: const [
                SegmentItem(label: '直接回答', value: ''),
                SegmentItem(label: 'Low', value: 'low'),
                SegmentItem(label: 'Medium', value: 'medium'),
                SegmentItem(label: 'High', value: 'high'),
              ],
              activeValue:
                  _customReasoningEffort.isEmpty ? '' : _customReasoningEffort,
              onChanged: (v) => setState(() => _customReasoningEffort = v),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Text('联网搜索',
                    style: TextStyle(fontSize: 13, color: palette.textPrimary)),
                const Spacer(),
                SizedBox(
                  height: 28,
                  child: Switch(
                    value: _webSearchEnabled,
                    activeTrackColor: palette.textSecondary,
                    onChanged: (v) {
                      HapticFeedback.selectionClick();
                      setState(() => _webSearchEnabled = v);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: _outlineButton(
                      '取消',
                      () => setState(() => _stage = _AIConfigStage.menu),
                      palette),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _primaryButton('保存', _saving ? null : _saveCustom),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveCustom() async {
    final url = _urlController.text.trim();
    final key = _keyController.text.trim();
    final model = _modelController.text.trim();
    if (url.isEmpty || key.isEmpty) {
      toastNotification.show(context, '请填写API地址和密钥', type: ToastType.error);
      return;
    }
    setState(() => _saving = true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('custom_api_url', url);
    await prefs.setString('custom_api_key', key);
    await prefs.setString('custom_api_model', model);
    await prefs.setString('ai_provider', 'custom');
    AIAssistantScreenState.markNeedsRefresh();
    await prefs.setBool('fast_mode_enabled', false);
    await prefs.setBool('ai_enabled', true);
    await prefs.setString('custom_api_reasoning_effort',
        _customReasoningEffort.isNotEmpty ? _customReasoningEffort : '');
    await prefs.setBool('web_search_enabled', _webSearchEnabled);

    AIService.instance.setCustomApiConfig(
      apiUrl: url,
      apiKey: key,
      model: model,
    );
    await AIService.instance.setCustomVisionManualOverride(
      enabled: _visionOverride,
      supportsVision: _visionEnabled,
    );
    await AIService.instance.setCustomReasoningEffort(
      _customReasoningEffort.isNotEmpty ? _customReasoningEffort : null,
    );
    if (!mounted) return;
    setState(() {
      _saving = false;
      _isCustomProvider = true;
      _isAgnesProvider = false;
      _isBuiltinProvider = false;
      _providerConfigured = true;
      _stage = _AIConfigStage.menu;
    });
    _toast('自定义API已保存', ToastType.success);
    await widget.onConfigSaved?.call();
  }

  // ============================================================
  // 通用控件
  // ============================================================

  void _toast(String message, ToastType type) {
    if (!mounted) return;
    toastNotification.show(context, message, type: type);
  }

  Widget _fullWidthButton(
      String text, VoidCallback? onPressed, AppPalette palette) {
    return SizedBox(
      width: double.infinity,
      child: _outlineButton(text, onPressed, palette),
    );
  }

  Widget _outlineButton(
      String text, VoidCallback? onPressed, AppPalette palette) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: palette.borderWeak),
        ),
      ),
      child: Text(text),
    );
  }

  Widget _primaryButton(String text, VoidCallback? onPressed) {
    return ElevatedButton(
      onPressed: onPressed,
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
      child: Text(text),
    );
  }
}

/// Agnes AI 配置对话框标题问号：点击向下弹出推荐说明气泡
/// （样式与动画同问号提示框），点击空白处收回
class _AgnesHelpIcon extends StatefulWidget {
  final bool reduceMotion;

  const _AgnesHelpIcon({required this.reduceMotion});

  @override
  State<_AgnesHelpIcon> createState() => _AgnesHelpIconState();
}

class _AgnesHelpIconState extends State<_AgnesHelpIcon> {
  final GlobalKey _iconKey = GlobalKey();
  OverlayEntry? _tipEntry;
  bool _tipVisible = false;

  void _toggleTip() {
    if (_tipEntry != null) {
      _removeTip();
      return;
    }
    final iconBox = _iconKey.currentContext?.findRenderObject() as RenderBox?;
    if (iconBox == null) return;
    final iconPos = iconBox.localToGlobal(Offset.zero);
    final iconSize = iconBox.size;
    final screenWidth = MediaQuery.of(context).size.width;
    // 气泡固定 300 宽（窄屏收缩至屏幕宽减 32），左缘对齐问号左侧并
    // 夹在屏幕内（左右各留 16px 边距）
    final tipWidth = (screenWidth - 32).clamp(120.0, 300.0).toDouble();
    final left = (iconPos.dx - 12)
        .clamp(16.0, (screenWidth - tipWidth - 16).clamp(16.0, double.infinity))
        .toDouble();
    // 气泡顶边位于问号图标下方 6px（向下弹出）
    final top = iconPos.dy + iconSize.height + 6;
    _tipVisible = true;
    _tipEntry = OverlayEntry(
      builder: (context) => Stack(
        children: [
          // 透明屏障：点击气泡以外的任意处收回
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _removeTip,
            ),
          ),
          _AgnesHelpTip(
            visible: _tipVisible,
            left: left,
            top: top,
            width: tipWidth,
            reduceMotion: widget.reduceMotion,
            onDismissed: () {
              _tipEntry?.remove();
              _tipEntry = null;
            },
          ),
        ],
      ),
    );
    Overlay.of(context).insert(_tipEntry!);
  }

  void _removeTip() {
    if (_tipEntry == null) return;
    // 翻转 visible 触发收回动画，动画完成后由 onDismissed 移除 entry
    _tipVisible = false;
    _tipEntry!.markNeedsBuild();
  }

  @override
  void dispose() {
    // 对话框关闭时同步移除气泡
    _tipEntry?.remove();
    _tipEntry = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: _iconKey,
      behavior: HitTestBehavior.opaque,
      onTap: _toggleTip,
      child: Icon(
        Icons.help_outline,
        size: 16,
        color: AppColors.of(context).textTertiary,
      ),
    );
  }
}

/// 标题问号（向下弹出通用版）：点击在问号下方弹出说明气泡
/// （样式与动画同问号提示框），点击空白处收回

class _AgnesHelpTip extends StatefulWidget {
  final bool visible;
  final double left;
  final double top;
  final double width;
  final bool reduceMotion;
  final VoidCallback? onDismissed;

  const _AgnesHelpTip({
    required this.visible,
    required this.left,
    required this.top,
    required this.width,
    required this.reduceMotion,
    this.onDismissed,
  });

  @override
  State<_AgnesHelpTip> createState() => _AgnesHelpTipState();
}

class _AgnesHelpTipState extends State<_AgnesHelpTip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

  // 与问号提示同款曲线：弹出轻微回弹，收回缩回锚点处
  late final CurvedAnimation _curved = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutBack,
    reverseCurve: Curves.easeInCubic,
  );

  @override
  void initState() {
    super.initState();
    if (widget.visible) {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(covariant _AgnesHelpTip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible == oldWidget.visible) return;
    if (widget.visible) {
      _controller.forward();
    } else {
      _controller.reverse().whenCompleteOrCancel(() {
        if (mounted) widget.onDismissed?.call();
      });
    }
  }

  @override
  void dispose() {
    _curved.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _openUrl() async {
    final uri = Uri.parse('https://www.agnes-ai.cn/');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: widget.left,
      top: widget.top,
      child: AnimatedBuilder(
        animation: _curved,
        builder: (context, child) {
          final t = _curved.value;
          return Opacity(
            // easeOutBack 会过冲超过 1.0，透明度需夹取
            opacity: t.clamp(0.0, 1.0),
            child: Transform.translate(
              // 自问号图标处（上方）向下滑出；收回时向上缩回图标处
              offset: Offset(0, -14 * (1 - t)),
              child: Transform.scale(
                // 顶部对齐缩放：视觉上自问号处向下展开/向上收起
                scale: 0.85 + 0.15 * t,
                alignment: Alignment.topCenter,
                child: child,
              ),
            ),
          );
        },
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: widget.width,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.of(context).surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.of(context).borderWeak),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.15),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '为什么推荐使用此供应商？',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: AppColors.of(context).textSecondary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Agnes AI现面向全球用户针对部分模型提供免费API，经测试这些模型足以发挥出CourseHub的全部Agent能力。在使用过程中，我们推荐您将思考强度设置为Medium。',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.of(context).textSecondary,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '您可在如下网址注册一个账号获取API并开始免费使用CourseHub的所有功能。',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.of(context).textSecondary,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 4),
                GestureDetector(
                  onTap: _openUrl,
                  child: const Text(
                    'https://www.agnes-ai.cn/',
                    style: TextStyle(
                      fontSize: 12,
                      color: Color(0xFF4A90E2),
                      decoration: TextDecoration.underline,
                      decorationColor: Color(0xFF4A90E2),
                      height: 1.5,
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
}
