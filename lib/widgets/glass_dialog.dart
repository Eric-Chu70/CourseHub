import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 读取全局「减弱动态效果」开关（设置页个性化，默认关闭）。
/// 对话框打开路径上读取（SharedPreferences 首次加载后有缓存，开销可忽略）
Future<bool> readReduceMotionPref() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool('reduce_motion_enabled') ?? false;
}

/// 苹果 G2 风格对话框外壳：大圆角(24) + 半透明白色遮罩（无额外模糊）。
///
/// 说明：本组件不再自带 BackdropFilter 模糊，因为调用方通常已通过
/// `showGeneralDialog` 的 pageBuilder 顶层 `BackdropFilter(blur: 5)`
/// 对背景做了模糊处理。这里仅提供半透明白色遮罩 + 圆角 + 边框 + 阴影。
///
/// 用法：将对话框最外层 `Container(decoration: BoxDecoration(color: Colors.white, ...))`
/// 替换为 `GlassDialogShell(child: 原child)`，即可获得通透外观。
class GlassDialogShell extends StatelessWidget {
  final Widget child;
  final double radius;
  final EdgeInsets? padding;
  final List<BoxShadow>? boxShadow;

  /// 传入时对对话框背后做局部高斯模糊（嵌在圆角裁剪内，
  /// 模糊区域与对话框圆角矩形完全一致）。
  final double? blurSigma;

  /// 白底不透明度。默认 0.7（透出背景偏灰）；
  /// 搭配 blurSigma 时建议 0.85+ 以获得纯净白底。
  final double backgroundAlpha;

  const GlassDialogShell({
    super.key,
    required this.child,
    this.radius = 24,
    this.padding,
    this.boxShadow,
    this.blurSigma,
    this.backgroundAlpha = 0.7,
  });

  @override
  Widget build(BuildContext context) {
    final BorderRadius borderRadius = BorderRadius.circular(radius);
    Widget content = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: backgroundAlpha),
        borderRadius: borderRadius,
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.6),
          width: 0.5,
        ),
      ),
      child: child,
    );
    // 阴影裁切修复：阴影（blur 24 + offset 12）绘制在壳矩形之外，
    // 若画在 ClipRRect 内会被圆角矩形裁得只剩贴边一缕（甚至全无）。
    // 把阴影提到裁剪外层的 DecoratedBox 上：阴影完整绘制在壳背后，
    // 裁剪只管模糊与内容的圆角收敛。
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: boxShadow ??
            [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.12),
                blurRadius: 24,
                offset: const Offset(0, 12),
              ),
            ],
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: blurSigma == null
            ? content
            : Stack(
                children: [
                  // 提亮层：模糊前先垫一层半透明白，中和外层遮罩的压暗，
                  // 模糊采样到偏亮的底 → 呈"白磨砂"而非"灰磨砂"（白与模糊兼得）
                  Positioned.fill(
                    child: ColoredBox(
                      color: Colors.white.withValues(alpha: 0.4),
                    ),
                  ),
                  BackdropFilter(
                    filter:
                        ImageFilter.blur(sigmaX: blurSigma!, sigmaY: blurSigma!),
                    child: content,
                  ),
                ],
              ),
      ),
    );
  }
}

class GlassDialog {
  static Future<T?> show<T>({
    required BuildContext context,
    required Widget child,
    double? maxWidth,
    double? maxHeight,
  }) {
    return showBouncyDialog<T>(
      context: context,
      barrierLabel: 'Dismiss',
      // 约束在壳外侧（含壳内边距），与旧版 Container(constraints:) 包壳语义一致
      shellMaxWidth: maxWidth ?? 400,
      shellMaxHeight: maxHeight ?? MediaQuery.of(context).size.height * 0.8,
      builder: (context) => child,
    );
  }

  static Widget buildHeader({
    required String title,
    required VoidCallback onClose,
    IconData? icon,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF4A90E2).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: const Color(0xFF4A90E2), size: 20),
                ),
                const SizedBox(width: 12),
              ],
              Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          GestureDetector(
            onTap: onClose,
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(Icons.close, size: 18, color: Colors.grey.shade700),
            ),
          ),
        ],
      ),
    );
  }

  static Widget buildButton({
    required String text,
    required VoidCallback onPressed,
    bool isPrimary = true,
  }) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: isPrimary ? const Color(0xFF4A90E2) : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: isPrimary ? null : Border.all(color: Colors.white.withValues(alpha: 0.4)),
        ),
        child: Center(
          child: Text(
            text,
            style: TextStyle(
              color: isPrimary ? Colors.white : Colors.grey.shade700,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================
// 模糊下拉选择框 & 弹出菜单
// ============================================================

/// 统一的模糊菜单外壳：ClipRRect + BackdropFilter + 半透明白色。
Widget _blurredMenuShell({
  required Widget child,
  double radius = 16,
  double blurSigma = 20,
  double alpha = 0.7,
}) {
  return DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.15),
          blurRadius: 12,
          offset: const Offset(0, 4),
        ),
      ],
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: alpha),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.5),
              width: 0.5,
            ),
          ),
          child: Material(
            color: Colors.transparent,
            child: child,
          ),
        ),
      ),
    ),
  );
}

/// 模糊下拉选择框 — 替代 DropdownButton，弹出菜单带毛玻璃模糊效果。
///
/// 用法：将 `DropdownButtonHideUnderline(child: DropdownButton(...))`
/// 替换为 `BlurredDropdown(...)`，外层 Container 保持不变。
class BlurredDropdown<T> extends StatefulWidget {
  // 允许为 null：无匹配项时不显示对勾，按钮显示 hint（如内置模型"未使用"态）
  final T? value;
  final List<DropdownMenuItem<T>>? items;
  final ValueChanged<T?>? onChanged;
  final bool isExpanded;
  final Widget? icon;
  // 未展开时显示在当前项左侧的前缀图标（如节点图标）
  final Widget? prefixIcon;
  // 无匹配项时按钮内显示的占位内容
  final Widget? hint;
  // 菜单项文字右侧问号图标的提示文案（点击向菜单左侧弹出气泡）
  final Map<T, String>? infoMessages;
  final double menuRadius;
  // 弹出菜单宽度：默认与触发框同宽，触发框较窄时可单独指定更宽的菜单
  final double? menuWidth;

  const BlurredDropdown({
    super.key,
    required this.value,
    required this.items,
    this.onChanged,
    this.isExpanded = false,
    this.icon,
    this.prefixIcon,
    this.hint,
    this.infoMessages,
    this.menuRadius = 16,
    this.menuWidth,
  });

  @override
  State<BlurredDropdown<T>> createState() => _BlurredDropdownState<T>();
}

class _BlurredDropdownState<T> extends State<BlurredDropdown<T>> {
  /// 焦点锚点：打开菜单前把焦点转移到这里。菜单经 showGeneralDialog
  /// 推入子路由，pop 时 Flutter 会对下层路由执行焦点恢复（沿 scope 的
  /// focusedChild 链向下钻取）；unfocus 不清除该链，若链尾仍是输入框，
  /// 收起菜单就会重新聚焦输入框导致键盘反复弹出。提前将焦点转到本锚点，
  /// 恢复终点即为锚点（无输入连接，不弹键盘）
  final FocusNode _anchorNode = FocusNode(debugLabel: 'BlurredDropdownAnchor');

  @override
  void dispose() {
    _anchorNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    DropdownMenuItem<T>? currentItem;
    for (final item in widget.items ?? <DropdownMenuItem<T>>[]) {
      if (item.value == widget.value) {
        currentItem = item;
        break;
      }
    }

    return Focus(
      focusNode: _anchorNode,
      skipTraversal: true,
      child: GestureDetector(
        onTap: _showMenu,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            mainAxisSize: widget.isExpanded ? MainAxisSize.max : MainAxisSize.min,
            children: [
              if (widget.prefixIcon != null) ...[
                widget.prefixIcon!,
                const SizedBox(width: 6),
              ],
              if (widget.isExpanded)
                Expanded(child: currentItem?.child ?? widget.hint ?? const SizedBox())
              else
                currentItem?.child ?? widget.hint ?? const SizedBox(),
              const SizedBox(width: 4),
              widget.icon ??
                  Icon(Icons.expand_more, size: 20, color: Colors.grey.shade600),
            ],
          ),
        ),
      ),
    );
  }

  void _showMenu() async {
    // 打开菜单前转移焦点到锚点：切断子路由 pop 后焦点恢复到输入框的链路，
    // 同时键盘随失焦自然收起（与系统下拉框行为一致）
    _anchorNode.requestFocus();
    final result = await showBlurredMenu<T>(
      context: context,
      items: widget.items,
      value: widget.value,
      menuRadius: widget.menuRadius,
      menuWidth: widget.menuWidth,
      infoMessages: widget.infoMessages,
    );

    if (result != null && widget.onChanged != null) {
      widget.onChanged!(result);
    }
  }
}

/// 独立弹出统一样式下拉菜单（与 BlurredDropdown 同款菜单壳与动效）：
/// 锚定 [context] 对应的控件，供顶部徽章等非下拉框场景复用。
/// 返回用户选中的值（未选择/点击遮罩关闭返回 null）。
Future<T?> showBlurredMenu<T>({
  required BuildContext context,
  required List<DropdownMenuItem<T>>? items,
  T? value,
  double menuRadius = 16,
  double? menuWidth,
  Map<T, String>? infoMessages,
  double menuHorizontalShift = 0,
}) async {
  final renderBox = context.findRenderObject() as RenderBox;
  final position = renderBox.localToGlobal(Offset.zero);
  final size = renderBox.size;
  final width = menuWidth ?? size.width;
  final screenWidth = MediaQuery.of(context).size.width;
  final screenHeight = MediaQuery.of(context).size.height;

  final spaceBelow = screenHeight - position.dy - size.height;
  final itemCount = items?.length ?? 0;
  // 菜单最多同框显示 4 项（单项≈48px），超出滚动，避免长列表拉满整屏；
  // ≤4 项时放宽高度上限（含文字缩放留量），保证全部同框显示、不出滚动条
  var menuMaxHeight = spaceBelow > 50 ? spaceBelow : 250.0;
  final maxMenuHeight = itemCount <= 4 ? 224.0 : 192.0;
  if (menuMaxHeight > maxMenuHeight) menuMaxHeight = maxMenuHeight;

  // 选中项索引与各项 Key：打开后定位滚动到选中项
  int selectedIndex = -1;
  for (var i = 0; i < itemCount; i++) {
    if (items![i].value == value) {
      selectedIndex = i;
      break;
    }
  }
  final itemKeys = List<GlobalKey>.generate(itemCount, (_) => GlobalKey());
  // 问号图标锚点 key（仅带提示文案的项会挂到图标上）
  final infoKeys = List<GlobalKey>.generate(itemCount, (_) => GlobalKey());
  // 问号提示气泡状态：可见性 / 文案 / 垂直位置 / 触发的项索引
  bool infoVisible = false;
  String? infoText;
  double? infoTop;
  int? activeInfoIndex;
  // 水平偏移（负值向左）：徽章等小型锚点的菜单比锚点宽时整体左移对齐。
  // 右侧留 16px 屏幕边距：贴右缘的锚点（如对话页徽章）菜单右缘与锚点右缘对齐，
  // 而不是被 clamp 推到紧贴屏幕边缘
  final rightBound =
      (screenWidth - width - 16).clamp(0.0, screenWidth - width);
  final menuLeft =
      (position.dx + menuHorizontalShift).clamp(0.0, rightBound);

  final result = await showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Dropdown',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 220),
    // 菜单自身带弹出动画，外层不再叠加淡入淡出
    transitionBuilder: (context, animation, secondaryAnimation, child) =>
        child,
    pageBuilder: (context, animation, secondaryAnimation) {
      // 首帧布局完成后定位滚动：选中项滚到菜单顶部（同框最多 4 项）
      if (selectedIndex >= 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final itemContext = itemKeys[selectedIndex].currentContext;
          if (itemContext != null) {
            Scrollable.ensureVisible(
              itemContext,
              duration: Duration.zero,
              alignment: 0.0,
            );
          }
        });
      }
      return StatefulBuilder(
        builder: (context, setMenuState) {
          return Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    // 关闭菜单时提示气泡同步收回（随菜单退出动画一起滑回）
                    setMenuState(() => infoVisible = false);
                    Navigator.pop(context);
                  },
                ),
              ),
              Positioned(
                left: menuLeft,
                top: position.dy + size.height + 4,
                width: width,
                child: _MenuPopTransition(
                  animation: animation,
                  child: Material(
                    color: Colors.transparent,
                    child: _blurredMenuShell(
                      radius: menuRadius,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxHeight: menuMaxHeight),
                        child: ListView.builder(
                          shrinkWrap: true,
                          padding: EdgeInsets.zero,
                          // 顶端/底端超出回弹（iOS 风格）
                          physics: const BouncingScrollPhysics(),
                          itemCount: itemCount,
                          itemBuilder: (context, index) {
                            final item = items![index];
                            final isSelected = item.value == value;
                            final hasInfo = infoMessages != null &&
                                item.value != null &&
                                infoMessages.containsKey(item.value);
                            return InkWell(
                              key: itemKeys[index],
                              onTap: () {
                                // 选中项关闭菜单时提示气泡同步收回
                                setMenuState(() => infoVisible = false);
                                Navigator.pop(context, item.value);
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 12),
                                child: Row(
                                  children: [
                                    Expanded(child: item.child),
                                    // 问号图标靠内（紧贴文字），不挤占右侧勾号槽位
                                    if (hasInfo) ...[
                                      const SizedBox(width: 6),
                                      GestureDetector(
                                        key: infoKeys[index],
                                        behavior: HitTestBehavior.opaque,
                                        onTap: () {
                                          final iconContext =
                                              infoKeys[index].currentContext;
                                          final iconBox = iconContext
                                              ?.findRenderObject() as RenderBox?;
                                          setMenuState(() {
                                            if (infoVisible &&
                                                activeInfoIndex == index) {
                                              // 再次点击同一图标：收回气泡
                                              infoVisible = false;
                                            } else {
                                              activeInfoIndex = index;
                                              infoText =
                                                  infoMessages![item.value];
                                              if (iconBox != null) {
                                                infoTop = iconBox
                                                        .localToGlobal(
                                                            Offset.zero)
                                                        .dy -
                                                    6;
                                              }
                                              infoVisible = true;
                                            }
                                          });
                                        },
                                        child: Icon(
                                          Icons.help_outline,
                                          size: 15,
                                          color: Colors.grey.shade500,
                                        ),
                                      ),
                                    ],
                                    // 勾号固定槽位：位置恒定，未选中时留空占位
                                    SizedBox(
                                      width: 24,
                                      child: isSelected
                                          ? const Icon(Icons.check,
                                              size: 16,
                                              color: Color(0xFF4A90E2))
                                          : null,
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // 问号提示气泡：向菜单左侧弹出（收回时向右滑回），与触发图标垂直对齐
              if (infoText != null)
                _MenuInfoTooltip(
                  visible: infoVisible,
                  text: infoText!,
                  right: screenWidth - menuLeft + 8,
                  top: infoTop ?? 0,
                  onDismissed: () {
                    setMenuState(() {
                      infoText = null;
                      activeInfoIndex = null;
                    });
                  },
                ),
            ],
          );
        },
      );
    },
  );

  return result;
}

/// 菜单项问号提示气泡：向菜单左侧弹出（自菜单侧向左滑出 + 淡入），
/// 收回时向右滑回菜单侧并淡出；[visible] 翻转驱动进出场动画
class _MenuInfoTooltip extends StatefulWidget {
  final bool visible;
  final String text;
  final double right;
  final double top;
  final VoidCallback? onDismissed;

  const _MenuInfoTooltip({
    required this.visible,
    required this.text,
    required this.right,
    required this.top,
    this.onDismissed,
  });

  @override
  State<_MenuInfoTooltip> createState() => _MenuInfoTooltipState();
}

class _MenuInfoTooltipState extends State<_MenuInfoTooltip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

  // 与菜单弹出同款曲线：打开自锚点方向弹出（轻微回弹），收回缩回锚点处
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
  void didUpdateWidget(covariant _MenuInfoTooltip oldWidget) {
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

  @override
  Widget build(BuildContext context) {
    // 智能换行：气泡自右缘定位向左展开，最大宽度不超过
    // 屏幕宽度减去右侧偏移和 16px 左边距，窄屏时长文字自动折行
    final maxTipWidth =
        MediaQuery.of(context).size.width - widget.right - 16;
    return Positioned(
      right: widget.right,
      top: widget.top,
      child: AnimatedBuilder(
        animation: _curved,
        builder: (context, child) {
          final t = _curved.value;
          return Opacity(
            // easeOutBack 会过冲超过 1.0，透明度需夹取
            opacity: t.clamp(0.0, 1.0),
            child: Transform.translate(
              // 自菜单侧（右）向左滑出；收回时向右缩回菜单侧
              offset: Offset(14 * (1 - t), 0),
              child: Transform.scale(
                // 右侧对齐缩放：视觉上自菜单侧向左展开/向右收起（同菜单动效）
                scale: 0.85 + 0.15 * t,
                alignment: Alignment.centerRight,
                child: child,
              ),
            ),
          );
        },
        child: Material(
          color: Colors.transparent,
          child: Container(
            constraints: BoxConstraints(maxWidth: maxTipWidth),
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.shade300),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.15),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Text(
              widget.text,
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 菜单弹出过渡（参考长按课程块菜单的灵动效果）：
/// 打开时自锚点方向向下弹出（自顶部展开 + 轻微回弹 overshoot），
/// 关闭时向上缩回收起到锚点处。
class _MenuPopTransition extends StatefulWidget {
  final Animation<double> animation;
  final Widget child;

  const _MenuPopTransition({
    required this.animation,
    required this.child,
  });

  @override
  State<_MenuPopTransition> createState() => _MenuPopTransitionState();
}

class _MenuPopTransitionState extends State<_MenuPopTransition> {
  late final CurvedAnimation _curved;

  @override
  void initState() {
    super.initState();
    _curved = CurvedAnimation(
      parent: widget.animation,
      curve: Curves.easeOutBack,
      reverseCurve: Curves.easeInCubic,
    );
  }

  @override
  void dispose() {
    _curved.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _curved,
      builder: (context, child) {
        final t = _curved.value;
        return Opacity(
          // easeOutBack 会过冲超过 1.0，透明度需夹取
          opacity: t.clamp(0.0, 1.0),
          child: Transform.translate(
            // 自锚点上方滑入，收起时缩回锚点
            offset: Offset(0, -14 * (1 - t)),
            child: Transform.scale(
              // 顶部对齐缩放：视觉上自锚点向下展开/向上收起
              scale: 0.85 + 0.15 * t,
              alignment: Alignment.topCenter,
              child: child,
            ),
          ),
        );
      },
      child: widget.child,
    );
  }
}

/// 模糊弹出菜单项
class BlurredPopupMenuItem<T> {
  final T value;
  final IconData icon;
  final String label;
  final Color? iconColor;
  final Color? textColor;

  const BlurredPopupMenuItem({
    required this.value,
    required this.icon,
    required this.label,
    this.iconColor,
    this.textColor,
  });
}

/// 模糊弹出菜单按钮 — 替代 PopupMenuButton，弹出菜单带毛玻璃模糊效果。
class BlurredPopupMenuButton<T> extends StatefulWidget {
  final Widget icon;
  final List<BlurredPopupMenuItem<T>> items;
  final ValueChanged<T>? onSelected;
  final double radius;
  final EdgeInsets iconPadding;
  final double menuWidth;

  const BlurredPopupMenuButton({
    super.key,
    required this.icon,
    required this.items,
    this.onSelected,
    this.radius = 16,
    this.iconPadding = const EdgeInsets.all(8),
    this.menuWidth = 160,
  });

  @override
  State<BlurredPopupMenuButton<T>> createState() =>
      _BlurredPopupMenuButtonState<T>();
}

class _BlurredPopupMenuButtonState<T> extends State<BlurredPopupMenuButton<T>> {
  /// 焦点锚点：同 BlurredDropdown，打开菜单前转移焦点，避免子路由 pop 后
  /// 焦点恢复钻回输入框导致键盘反复弹出
  final FocusNode _anchorNode =
      FocusNode(debugLabel: 'BlurredPopupMenuButtonAnchor');

  @override
  void dispose() {
    _anchorNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _anchorNode,
      skipTraversal: true,
      child: GestureDetector(
        onTap: () => _showMenu(context),
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: widget.iconPadding,
          child: widget.icon,
        ),
      ),
    );
  }

  void _showMenu(BuildContext context) async {
    // 打开菜单前转移焦点到锚点：切断子路由 pop 后焦点恢复到输入框的链路
    _anchorNode.requestFocus();
    final renderBox = context.findRenderObject() as RenderBox;
    final position = renderBox.localToGlobal(Offset.zero);
    final size = renderBox.size;
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;

    final left = (position.dx + size.width - widget.menuWidth)
        .clamp(8.0, screenWidth - widget.menuWidth - 8);
    final top = (position.dy + size.height + 4)
        .clamp(0.0, screenHeight - widget.items.length * 48 - 16);

    final result = await showGeneralDialog<T>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Menu',
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 220),
      // 菜单自身带弹出动画，外层不再叠加淡入淡出
      transitionBuilder: (context, animation, secondaryAnimation, child) =>
          child,
      pageBuilder: (context, animation, secondaryAnimation) {
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.pop(context),
              ),
            ),
            Positioned(
              left: left,
              top: top,
              child: _MenuPopTransition(
                animation: animation,
                child: Material(
                  color: Colors.transparent,
                  child: _blurredMenuShell(
                    radius: widget.radius,
                    child: SizedBox(
                      width: widget.menuWidth,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: widget.items.map((item) {
                          return InkWell(
                            onTap: () => Navigator.pop(context, item.value),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 12),
                              child: Row(
                                children: [
                                  Icon(item.icon,
                                      size: 20,
                                      color: item.iconColor ??
                                          const Color(0xFF4A90E2)),
                                  const SizedBox(width: 12),
                                  Text(
                                    item.label,
                                    style: TextStyle(
                                        fontSize: 15,
                                        color: item.textColor ??
                                            const Color(0xFF333333)),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );

    if (result != null && widget.onSelected != null) {
      widget.onSelected!(result);
    }
  }
}

// ============================================================
// 关于式弹性对话框（孔洞遮罩 + 果冻开闭动画）
// ============================================================

/// 「关于」式弹性对话框宿主：自绘带孔洞的压暗遮罩 + 果冻开闭动画。
///
/// showGeneralDialog 的 barrierColor 会把整屏（含对话框背后）压暗，壳内
/// BackdropFilter 采样到暗背景导致毛玻璃发灰。这里 barrierColor 置为透明，
/// 由本组件绘制压暗层，并在对话框壳矩形处挖一个跟随动画的圆角孔洞：
/// 孔洞内保留原始亮度背景，毛玻璃白净不发灰；四周仅压暗不模糊。
///
/// 动画（开闭均 400ms）：
/// - 打开：easeOutBack 果冻回弹 + 自下方 16px 弹起 + 内容由 sigma10 模糊逐渐变清晰；
/// - 关闭：收缩至 0.62 + 加速下坠 56px + 内容逐渐化开「坠入雾中」。
/// 壳（圆角/边框/阴影）全程保持清晰，仅内容参与聚焦动画（避免壳圆角锯齿）。
///
/// 孔洞对齐原理：clipper 在绘制阶段（getClip）同步测量壳的当帧真实绘制
/// 矩形（localToGlobal 已含键盘避让 AnimatedPadding 的内插位置与
/// Transform 的 scale/dy），孔洞与壳零帧差、精确贴边；另有帧末兜底循环
/// 在壳仍在移动时触发重绘，保证 AnimatedPadding 独立动画期间
/// （viewInsets 已稳定、本组件不再重建）遮罩也能持续刷新。
class BouncyDialogHost extends StatefulWidget {
  const BouncyDialogHost({
    super.key,
    required this.animation,
    required this.child,
    this.margin = const EdgeInsets.symmetric(horizontal: 24),
    this.shellPadding = const EdgeInsets.all(24),
    this.shellBoxShadow,
    this.backgroundBlurSigma = 5,
    this.backgroundAlpha = 0.70,
    this.radius = 24,
    this.avoidKeyboard = false,
    this.shellWidth,
    this.shellMaxWidth,
    this.shellMaxHeight,
    this.shellConstraintsBuilder,
    this.reduceMotion = false,
  });

  final Animation<double> animation;

  /// 减弱动态效果：壳背景仅保留半透明（去除 BackdropFilter 模糊），
  /// 四周压暗遮罩/裁切与开闭动画不变，移除内容的模糊淡入淡出。
  final bool reduceMotion;

  /// 对话框内容（壳由本组件提供；内容模糊动画仅作用于内容，壳保持清晰）
  final Widget child;

  /// 壳外边距（原调用方 Padding(horizontal: 24) 的替代）
  final EdgeInsetsGeometry margin;

  /// 壳内边距（GlassDialogShell.padding）
  final EdgeInsets shellPadding;

  /// 壳阴影（GlassDialogShell.boxShadow）
  final List<BoxShadow>? shellBoxShadow;

  /// 壳内背景高斯模糊浓度（毛玻璃）
  final double backgroundBlurSigma;

  /// 白底不透明度
  final double backgroundAlpha;

  final double radius;

  /// 键盘弹出时壳上移避让（margin 上下动态加键盘高度与顶部安全区）
  final bool avoidKeyboard;

  /// 壳固定总宽（含 shellPadding，等价于旧版壳外 Container(width:)）。
  /// 约束作用在壳外侧：ConstrainedBox 只传约束不裁剪，不影响壳外阴影。
  final double? shellWidth;

  /// 壳最大总宽（含 shellPadding，等价于旧版壳外 Container(constraints:)）
  final double? shellMaxWidth;

  /// 壳最大总高（含 shellPadding）
  final double? shellMaxHeight;

  /// 动态壳约束（如键盘弹出后压缩最大高度）：在宿主 build 时求值，
  /// 闭包内读取 MediaQuery 会在宿主上注册依赖，viewInsets 变化自动重建。
  /// 优先级高于 shellMaxWidth/shellMaxHeight。
  final BoxConstraints Function(BuildContext context)? shellConstraintsBuilder;

  @override
  State<BouncyDialogHost> createState() => _BouncyDialogHostState();
}

class _BouncyDialogHostState extends State<BouncyDialogHost> {
  final GlobalKey _shellKey = GlobalKey();

  /// 帧末壳矩形快照：仅用于兜底循环的变化检测，不参与孔洞计算
  Rect? _lastSyncedShellRect;

  /// 兜底循环占用标志：防止 build 与帧末回调双重注册
  bool _holeSyncScheduled = false;

  @override
  void initState() {
    super.initState();
    _scheduleHoleSync();
  }

  /// 兜底重绘循环（持续）：孔洞位置由 clipper 在绘制阶段同步测量（零帧
  /// 滞后），但对话框内容尺寸变化（StatefulBuilder 内 setDialogState 改
  /// 变字段数/展开折叠，如邮箱登录切换注册/登录模式、日期选择器切换
  /// 视图）不会触发本组件 build，遮罩分支可能收不到重绘调度——每帧
  /// 帧末比对壳矩形，变化就 setState 触发重绘让 clipper 重测。性能设计：
  /// - setState 仅作重绘驱动，不传递位置数据（无滞后、不重建内容树，
  ///   AnimatedBuilder 的 child 缓存使 rebuild 只涉及轻量外层包装）；
  /// - 开闭动画期间 AnimatedBuilder 已每帧驱动重绘，跳过冗余 setState；
  /// - 循环持续运行（不因静止停止）——内容尺寸变化随时可能发生，
  ///   静止时仅 1 次 localToGlobal + Rect 比较（AOT 下 <0.5μs，可忽略）；
  /// - 对话框关闭（unmount）后自动停止。
  void _scheduleHoleSync() {
    if (_holeSyncScheduled || !mounted) return;
    _holeSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _holeSyncScheduled = false;
      if (!mounted) return;
      final ro = _shellKey.currentContext?.findRenderObject();
      if (ro is RenderBox && ro.attached && ro.hasSize) {
        final rect = ro.localToGlobal(Offset.zero) & ro.size;
        if (_lastSyncedShellRect != rect) {
          _lastSyncedShellRect = rect;
          if (!widget.animation.isAnimating) {
            setState(() {});
          }
        }
        _scheduleHoleSync(); // 持续监控（含内容尺寸变化）
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // 幂等启动兜底循环（壳静止时自动停止，任何重建源都会重启它）
    _scheduleHoleSync();
    var effectiveMargin = widget.margin;
    if (widget.avoidKeyboard) {
      final mq = MediaQuery.of(context);
      final keyboardHeight = mq.viewInsets.bottom;
      if (keyboardHeight > 0) {
        effectiveMargin = effectiveMargin.resolve(Directionality.of(context)).copyWith(
          top: mq.padding.top + 8,
          bottom: keyboardHeight + 8,
        );
      }
    }
    return AnimatedBuilder(
      animation: widget.animation,
      builder: (context, child) {
        final t = widget.animation.value;
        final isReverse = widget.animation.status == AnimationStatus.reverse;
        // 关闭进度：0(全显)→1(消失)
        final closeU =
            isReverse ? Curves.easeInCubic.transform(1.0 - t) : 0.0;
        final double scale;
        final double dy;
        final double opacity;
        final double blurSigma;
        if (isReverse) {
          scale = 1.0 - 0.38 * closeU;
          dy = 56.0 * closeU;
          opacity = (1.0 - Curves.easeIn.transform(closeU)).clamp(0.0, 1.0);
          blurSigma = 10.0 * closeU;
        } else {
          scale = 0.86 + 0.14 * Curves.easeOutBack.transform(t);
          dy = 16.0 * (1.0 - Curves.easeOutCubic.transform(t));
          opacity = Curves.easeOut.transform(t).clamp(0.0, 1.0);
          blurSigma =
              10.0 * (1.0 - Curves.easeOut.transform(t)).clamp(0.0, 1.0);
        }
        // 遮罩透明度：与对话框同步淡入淡出
        final barrierAlpha = 0.5 *
            (isReverse ? (1.0 - closeU) : Curves.easeOut.transform(t));
        // 孔洞：旧机制（帧末测量→setState→下一帧生效）在键盘弹出/收起时
        // 恒定滞后壳 1 帧，且 viewInsets 归零后 build 停止、测量停止注册，
        // AnimatedPadding 回落尾段孔洞冻结在旧位置（收起回弹不跟随、
        // 裁切范围偏下）。现改为 clipper 在绘制阶段同步测量壳的当帧真实
        // 绘制矩形（含键盘避让内插与 scale/dy）——零帧差，**零外扩**
        // 精确贴壳：压暗边界与对话框壳边缘完全重合，藏在壳（半透明白
        // 玻璃 + 0.5px 白描边）之下，任何方向都不露出未压暗的亮边。
        // 壳内 BackdropFilter 边缘采样到的少量压暗像素被毛玻璃自身
        // 模糊，呈自然明暗过渡而非亮圈；壳阴影伸出壳外的部分画在压暗
        // 层之上，被孔洞外的压暗直接衬底（「原阴影裁切」观感）。
        // 孔洞圆角 = 壳圆角×scale，与壳经 Transform.scale 后的实际
        // 绘制圆角一致（圆角不匹配时角部会漏亮缝）
        final holeClipper = _InvertedRRectClipper(
          shellKey: _shellKey,
          radius: widget.radius,
          scale: scale,
        );
        // 内容聚焦动画（壳保持清晰避免圆角锯齿）
        // 始终包裹 ImageFiltered（即使 sigma≈0），避免开/闭动画期间
        // blurSigma 跨越 0.01 阈值时 widget 树结构变化（插入/移除
        // ImageFiltered）导致内容子树 element 重新 mount——StatefulWidget
        // 重建会丢失滚动位置/选中态（时间选择器滚轮跳回 initialItem、
        // 日历页跳回首页等「关闭瞬间显示原值」bug）
        Widget content = widget.reduceMotion
            ? (child ?? const SizedBox.shrink())
            : ImageFiltered(
                imageFilter: ImageFilter.blur(
                  sigmaX: blurSigma,
                  sigmaY: blurSigma,
                  tileMode: TileMode.clamp,
                ),
                child: child ?? const SizedBox.shrink(),
              );
        return Stack(
          children: [
            // 自绘压暗遮罩（孔洞处不压暗；IgnorePointer 让点击穿透到路由遮罩以关闭）
            Positioned.fill(
              child: IgnorePointer(
                child: ClipPath(
                  // clipper 每次绘制同步测量壳矩形，孔洞与壳零帧差
                  clipper: holeClipper,
                  child: ColoredBox(
                    color: Colors.black
                        .withValues(alpha: barrierAlpha.clamp(0.0, 1.0)),
                  ),
                ),
              ),
            ),
            Center(
              child: Opacity(
                opacity: opacity,
                child: Transform.translate(
                  offset: Offset(0, dy),
                  child: Transform.scale(
                    scale: scale,
                    // Material 提供文字默认样式（否则继承错误样式出现红字黄下划线）
                    child: Material(
                      type: MaterialType.transparency,
                      // 对话框级焦点作用域 + dummy 锚点：首帧无焦点时由它占位，
                      // 点击壳空白处经 onTap 的 unfocus 收起键盘（无害兜底）。
                      // 注意：真正防止「子路由（下拉/三点菜单）pop 后焦点恢复
                      // 钻回输入框、键盘反复弹出」的，是菜单组件（BlurredDropdown/
                      // BlurredPopupMenuButton）打开菜单前把焦点转移到自身的无输入
                      // 连接锚点节点——unfocus 不清除 scope 的 focusedChild 链，
                      // 单靠这里的 dummy（autofocus 仅首帧生效）拦不住焦点恢复
                      child: FocusScope(
                        child: Focus(
                          autofocus: true,
                          child: GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onTap: () => FocusScope.of(context).unfocus(),
                            child: AnimatedPadding(
                              duration: const Duration(milliseconds: 200),
                              curve: Curves.easeOut,
                              padding: effectiveMargin,
                              child: _sizedShell(content),
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
        );
      },
      child: widget.child,
    );
  }

  /// 壳尺寸约束：约束包在壳（GlassDialogShell）外侧，shellPadding 计入
  /// 总宽/总高，与旧版「壳外 Container(width:/constraints:)」语义一致。
  /// ConstrainedBox/SizedBox 只传约束不裁剪，壳外阴影（DecoratedBox）不受影响。
  Widget _sizedShell(Widget content) {
    final Widget shell = GlassDialogShell(
      key: _shellKey,
      padding: widget.shellPadding,
      boxShadow: widget.shellBoxShadow,
      // 减弱动态效果：壳背景仅半透明白（无模糊时提高不透明度避免过透）
      blurSigma: widget.reduceMotion ? null : widget.backgroundBlurSigma,
      backgroundAlpha: widget.reduceMotion ? 0.94 : widget.backgroundAlpha,
      radius: widget.radius,
      child: content,
    );
    if (widget.shellWidth != null) {
      return SizedBox(width: widget.shellWidth!, child: shell);
    }
    BoxConstraints? constraints =
        widget.shellConstraintsBuilder?.call(context);
    if (constraints == null &&
        (widget.shellMaxWidth != null || widget.shellMaxHeight != null)) {
      constraints = BoxConstraints(
        maxWidth: widget.shellMaxWidth ?? double.infinity,
        maxHeight: widget.shellMaxHeight ?? double.infinity,
      );
    }
    if (constraints != null) {
      return ConstrainedBox(constraints: constraints, child: shell);
    }
    return shell;
  }
}

/// showBouncyDialog：关于式弹性对话框入口。
///
/// 替代手写 `showGeneralDialog + BackdropFilter + Center + Material +
/// FadeTransition + ScaleTransition + Padding + GlassDialogShell` 的通用模式：
/// 四周仅压暗（孔洞遮罩）、对话框背后白净毛玻璃、果冻回弹开闭 + 内容
/// 聚焦/化开动画。`builder` 返回对话框**内容**（壳由本组件提供）。
Future<T?> showBouncyDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  String barrierLabel = 'Dialog',
  bool useRootNavigator = false,
  RouteSettings? routeSettings,
  EdgeInsetsGeometry margin = const EdgeInsets.symmetric(horizontal: 24),
  EdgeInsets shellPadding = const EdgeInsets.all(24),
  List<BoxShadow>? shellBoxShadow,
  double backgroundBlurSigma = 5,
  double backgroundAlpha = 0.70,
  double radius = 24,
  bool avoidKeyboard = false,
  double? shellWidth,
  double? shellMaxWidth,
  double? shellMaxHeight,
  BoxConstraints Function(BuildContext context)? shellConstraintsBuilder,
  bool? reduceMotion,
}) async {
  // 全局「减弱动态效果」：未显式指定时自动读取设置页开关——
  // 全应用对话框（含 GlassDialog.show / CourseDialog.show 等封装）
  // 经此入口统一生效：壳背景仅半透明无模糊、四周压暗裁切与开闭
  // 动画不变、移除内容模糊淡入淡出
  final bool effectiveReduceMotion =
      reduceMotion ?? await readReduceMotionPref();
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: barrierLabel,
    // 压暗遮罩由 BouncyDialogHost 自绘（带跟随动画的孔洞）
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 400),
    useRootNavigator: useRootNavigator,
    routeSettings: routeSettings,
    pageBuilder: (context, animation, secondaryAnimation) {
      return BouncyDialogHost(
        animation: animation,
        margin: margin,
        shellPadding: shellPadding,
        shellBoxShadow: shellBoxShadow,
        backgroundBlurSigma: backgroundBlurSigma,
        backgroundAlpha: backgroundAlpha,
        radius: radius,
        avoidKeyboard: avoidKeyboard,
        shellWidth: shellWidth,
        shellMaxWidth: shellMaxWidth,
        shellMaxHeight: shellMaxHeight,
        shellConstraintsBuilder: shellConstraintsBuilder,
        reduceMotion: effectiveReduceMotion,
        child: Builder(builder: builder),
      );
    },
  );
}

/// 全屏矩形挖去一个圆角矩形孔洞的裁剪器。
///
/// 孔洞矩形在 getClip（绘制阶段）同步测量壳的当帧真实绘制矩形：
/// localToGlobal 沿 RenderObject 树向上收集全部祖先变换，天然包含
/// 键盘避让 AnimatedPadding 的当帧内插位置与开闭动画 Transform 的
/// scale/dy——孔洞与壳零帧差，彻底消除旧「帧末测量→setState→下一帧
/// 生效」机制在键盘弹出/收起期间的 1 帧滞后，以及 viewInsets 稳定后
/// 测量停止注册、AnimatedPadding 回落尾段孔洞冻结导致的裁切偏移。
class _InvertedRRectClipper extends CustomClipper<Path> {
  /// 壳（GlassDialogShell）的 Key，绘制时反查其 RenderBox 实时位置
  final GlobalKey shellKey;

  /// 壳圆角（未缩放值）
  final double radius;

  /// 当帧动画 scale：孔洞圆角 = 壳圆角×scale，与壳经 Transform.scale
  /// 后的实际绘制圆角一致（圆角不匹配时角部会漏亮缝）
  final double scale;

  _InvertedRRectClipper({
    required this.shellKey,
    required this.radius,
    required this.scale,
  });

  Rect? _measureShellRect() {
    final ro = shellKey.currentContext?.findRenderObject();
    if (ro is RenderBox && ro.attached && ro.hasSize) {
      // 两角点分别过 localToGlobal：含 Transform 祖先的当帧动画值，
      // 得到壳的当帧真实绘制矩形（缩放后），可直接作孔洞，无需反推
      final topLeft = ro.localToGlobal(Offset.zero);
      final bottomRight = ro.localToGlobal(ro.size.bottomRight(Offset.zero));
      return Rect.fromLTRB(
          topLeft.dx, topLeft.dy, bottomRight.dx, bottomRight.dy);
    }
    return null;
  }

  @override
  Path getClip(Size size) {
    final shell = _measureShellRect();
    final full = Path()..addRect(Offset.zero & size);
    if (shell == null) {
      // 首帧壳尚未挂载：暂不挖洞（全屏压暗），下一帧起恒可测得
      return full;
    }
    return Path.combine(
      PathOperation.difference,
      full,
      Path()
        ..addRRect(
            RRect.fromRectAndRadius(shell, Radius.circular(radius * scale))),
    );
  }

  @override
  bool shouldReclip(_InvertedRRectClipper oldClipper) => true;
}
