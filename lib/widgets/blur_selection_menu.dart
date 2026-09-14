import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// 通用「模糊 + 动画」文本选中/输入框上下文菜单。
///
/// 保持横向排布、纯文字按钮（无图标），外观与动效复用全局下拉菜单
/// （glass_dialog.dart 的 _blurredMenuShell / _MenuPopTransition）同款规格：
/// 毛玻璃白壳（半透明白 + 白色细描边 + 背景高斯模糊）+ 自锚点方向弹出、
/// 带轻微回弹的缩放淡入动画，收回时反向缩回锚点处。
///
/// 动画实现说明：SDK 移除上下文菜单的 OverlayEntry 是瞬时完成的（点按钮、
/// 点外部都会直接 remove），菜单 widget 没有机会播放退场动画。因此
/// contextMenuBuilder 返回的只是一个"生命周期探针"（空 widget + 会话），
/// 真正的菜单画在自管理的 OverlayEntry 里：探针 dispose 时通知会话播放
/// 退场动画，动画结束后再摘掉自己的 entry。
///
/// 两处真机问题修正：
/// 1. 收起内容冻结——SDK 移除菜单 entry 的同一帧选区往往已折叠，若重建时
///    活取 SDK 按钮列表，收起动画播的会是内容被抽换后的菜单；配置在探针
///    重建时刻物化成快照（见 _MenuConfig.items），退场内容与展示时一致。
/// 2. 乐观粘贴——SDK 用 Clipboard.hasStrings 决定「粘贴」是否出现，部分
///    ROM 对前台应用也返回 false（状态恒 notPasteable），剪贴板有内容却
///    不给粘贴按钮；输入框可写而列表缺「粘贴」时本地合成（见
///    _withOptimisticPaste），并在弹出时主动刷新一次剪贴板状态
///    （见 _refreshClipboardIfNeeded）。
///
/// 用法：
///   TextField(contextMenuBuilder: styledEditableContextMenu, ...)
///   SelectionArea(contextMenuBuilder: styledSelectableRegionContextMenu, ...)

/// 菜单估算高度（单行按钮 + 内边距），用于判断菜单能否放在选区上方。
const double _kEstimatedToolbarHeight = 48;

/// 菜单与屏幕左右边缘的预留边距：选项较多时菜单也不会顶到屏幕两端。
const double _kMenuScreenMargin = 8.0;

/// 收起动画时长（与下拉菜单同款 220ms）。
const Duration _kMenuAnimationDuration = Duration(milliseconds: 220);

/// 行为修正只作用于桌面端：移动端 SDK 默认行为（Android 复制后清选中、
/// 全选后回弹菜单；iOS 复制后保留选中并弹"已复制"提示）符合平台惯例，不改。
bool get _isDesktop => switch (defaultTargetPlatform) {
      TargetPlatform.windows || TargetPlatform.linux || TargetPlatform.macOS => true,
      _ => false,
    };

/// 输入框（EditableText）用的 contextMenuBuilder。
Widget styledEditableContextMenu(BuildContext context, EditableTextState editableTextState) {
  return _SelectionMenuLauncher(
    anchors: editableTextState.contextMenuAnchors,
    // 实时取按钮项而非快照：空输入框长按时「粘贴」按钮依赖剪贴板状态
    // 异步查询，首次构建可能拿不到，菜单需在状态就绪后自行重建。
    // mounted 守卫：输入框先行销毁而菜单还在收起动画中时，
    // 取值会访问已失效的 RenderEditable
    itemsGetter: () => editableTextState.mounted
        ? editableTextState.contextMenuButtonItems
        : const <ContextMenuButtonItem>[],
    clipboardStatus: editableTextState.clipboardStatus,
    // 粘贴动作：SDK 的 clipboardStatus 通道失灵（部分 ROM 对前台应用也返回
    // false，状态恒为 notPasteable）时，菜单用它本地合成乐观粘贴按钮
    onPaste: editableTextState.widget.readOnly
        ? null
        : () => editableTextState.pasteText(SelectionChangedCause.toolbar),
    // 桌面端 SDK 全选后只 hideToolbar 不回弹菜单，这里补一次回弹
    onSelectAll: () {
      editableTextState.selectAll(SelectionChangedCause.toolbar);
      if (_isDesktop) {
        SchedulerBinding.instance.addPostFrameCallback((Duration _) {
          if (editableTextState.mounted) {
            editableTextState.showToolbar();
          }
        });
      }
    },
  );
}

/// 文字选中区（SelectableRegion）用的 contextMenuBuilder。
Widget styledSelectableRegionContextMenu(
  BuildContext context,
  SelectableRegionState selectableRegionState,
) {
  return _SelectionMenuLauncher(
    anchors: selectableRegionState.contextMenuAnchors,
    itemsGetter: () => selectableRegionState.contextMenuButtonItems,
    // 带 toolbar cause 的全选会在 SDK 内部重新弹出菜单（移动端同款路径）
    onSelectAll: () => selectableRegionState.selectAll(SelectionChangedCause.toolbar),
    // 桌面端 SDK 复制后只收菜单不清除选中，这里补齐；移动端 SDK 已按平台
    // 惯例处理（Android 已清、iOS 刻意保留），不再额外干预
    onCopyDone: _isDesktop ? () => selectableRegionState.clearSelection() : null,
  );
}

/// 菜单配置：锚点 + 按钮项获取器 + 平台行为修正回调。SDK 每次重建菜单
/// （如拖动选区）时都会调 contextMenuBuilder，探针据此把最新配置同步给
/// 菜单；菜单自身也监听剪贴板状态，粘贴按钮可用性变化时即时重建。
///
/// [items] 在构造时把 [itemsGetter] 的结果物化成快照：SDK 移除菜单 entry
/// （点外部收起）的同一帧里，选区往往已折叠，此时任何重建若再活取 SDK
/// 状态，收起动画播的就会是内容被抽换后的菜单（复制/剪切/全选消失）。
/// 物化后菜单只渲染探针重建时刻的按钮，收起动画内容与展示时一致。
class _MenuConfig {
  _MenuConfig({
    required this.anchors,
    required this.itemsGetter,
    this.clipboardStatus,
    this.onPaste,
    this.onSelectAll,
    this.onCopyDone,
  }) : items = itemsGetter();

  final TextSelectionToolbarAnchors anchors;
  final List<ContextMenuButtonItem> Function() itemsGetter;
  final List<ContextMenuButtonItem> items;
  final Listenable? clipboardStatus;
  final VoidCallback? onPaste;
  final VoidCallback? onSelectAll;
  final VoidCallback? onCopyDone;
}

/// 生命周期探针：本体不可见，只负责把菜单元数据同步给会话，
/// 并在自身 dispose（= SDK 移除菜单 entry）时触发挥器的收起动画。
class _SelectionMenuLauncher extends StatefulWidget {
  const _SelectionMenuLauncher({
    required this.anchors,
    required this.itemsGetter,
    this.clipboardStatus,
    this.onPaste,
    this.onSelectAll,
    this.onCopyDone,
  });

  final TextSelectionToolbarAnchors anchors;
  final List<ContextMenuButtonItem> Function() itemsGetter;
  final Listenable? clipboardStatus;
  final VoidCallback? onPaste;
  final VoidCallback? onSelectAll;
  final VoidCallback? onCopyDone;

  @override
  State<_SelectionMenuLauncher> createState() => _SelectionMenuLauncherState();
}

class _SelectionMenuLauncherState extends State<_SelectionMenuLauncher> {
  _MenuSession? _session;

  _MenuConfig get _currentConfig => _MenuConfig(
        anchors: widget.anchors,
        itemsGetter: widget.itemsGetter,
        clipboardStatus: widget.clipboardStatus,
        onPaste: widget.onPaste,
        onSelectAll: widget.onSelectAll,
        onCopyDone: widget.onCopyDone,
      );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_session == null) {
      _session = _MenuSession(_currentConfig);
      // 不能在 build/layout 阶段向 Overlay 插入 entry（相当于对别的
      // element 调 setState），推迟到当前帧结束后再挂载
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _session!.mount(Overlay.of(context, rootOverlay: true));
        } else {
          _session!.dismiss();
        }
      });
    }
  }

  @override
  void didUpdateWidget(covariant _SelectionMenuLauncher oldWidget) {
    super.didUpdateWidget(oldWidget);
    _session?.update(_currentConfig);
  }

  @override
  void dispose() {
    // SDK 已移除菜单 entry：让扬声器播放收起动画
    _session?.dismiss();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// 一次菜单展示的会话：持有自管理的 OverlayEntry 与配置/收起信号。
class _MenuSession {
  _MenuSession(_MenuConfig config) : _configNotifier = ValueNotifier<_MenuConfig?>(config);

  final ValueNotifier<_MenuConfig?> _configNotifier;
  final ValueNotifier<bool> _dismissedNotifier = ValueNotifier<bool>(false);
  OverlayEntry? _entry;
  Timer? _fallbackTimer;

  void mount(OverlayState overlay) {
    if (_dismissedNotifier.value) {
      return;
    }
    _entry = OverlayEntry(builder: (BuildContext context) => _OverlayMenu(session: this));
    overlay.insert(_entry!);
  }

  void update(_MenuConfig config) {
    if (!_dismissedNotifier.value) {
      _configNotifier.value = config;
    }
  }

  /// 剪贴板状态变化后的定向刷新：只重新物化按钮项，锚点与回调保持不变。
  /// 收起中不刷新，保证退场动画内容冻结在最后展示的状态。
  void refreshItems() {
    if (_dismissedNotifier.value) {
      return;
    }
    final _MenuConfig? config = _configNotifier.value;
    if (config == null) {
      return;
    }
    _configNotifier.value = _MenuConfig(
      anchors: config.anchors,
      itemsGetter: config.itemsGetter,
      clipboardStatus: config.clipboardStatus,
      onPaste: config.onPaste,
      onSelectAll: config.onSelectAll,
      onCopyDone: config.onCopyDone,
    );
  }

  /// 触发收起：菜单widget 监听到信号后反向播放动画，结束后自行摘除 entry。
  void dismiss() {
    if (_dismissedNotifier.value) {
      return;
    }
    _dismissedNotifier.value = true;
    // 兜底：极端时序下菜单 widget 可能已不在树上听不到信号，
    // 超时后强制移除 entry，避免残留
    _fallbackTimer = Timer(const Duration(milliseconds: 500), _removeEntry);
  }

  void _removeEntry() {
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    final OverlayEntry? entry = _entry;
    _entry = null;
    if (entry != null && entry.mounted) {
      entry.remove();
      entry.dispose();
    }
  }
}

/// 自管理 OverlayEntry 里的菜单本体：全屏定位层 + 动画卡片。
class _OverlayMenu extends StatefulWidget {
  const _OverlayMenu({required this.session});

  final _MenuSession session;

  @override
  State<_OverlayMenu> createState() => _OverlayMenuState();
}

class _OverlayMenuState extends State<_OverlayMenu> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _kMenuAnimationDuration,
  );

  // 与 _MenuPopTransition 同款曲线：弹出带轻微回弹，收起干脆缩回
  late final CurvedAnimation _animation = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutBack,
    reverseCurve: Curves.easeInCubic,
  );

  @override
  void initState() {
    super.initState();
    _controller.forward();
    widget.session._dismissedNotifier.addListener(_handleDismissed);
    widget.session._configNotifier.addListener(_handleConfigChanged);
    widget.session._configNotifier.value?.clipboardStatus?.addListener(_handleClipboardChanged);
    _refreshClipboardIfNeeded();
  }

  void _handleDismissed() {
    _controller.reverse().whenCompleteOrCancel(() {
      widget.session._removeEntry();
    });
  }

  void _handleConfigChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  /// 剪贴板状态就绪（unknown → pasteable/notPasteable）时重建菜单：
  /// 空输入框长按场景下「粘贴」按钮是否可用取决于这次异步查询结果，
  /// SDK 不会为它主动重建 context menu
  void _handleClipboardChanged() {
    if (mounted && !widget.session._dismissedNotifier.value) {
      widget.session.refreshItems();
    }
  }

  /// SDK 只在部分路径（showToolbar）刷新剪贴板状态；应用内「复制」按钮
  /// 直接写 Clipboard 不经过它，状态可能停留在旧的 notPasteable，导致
  /// 明明有内容可贴却不出粘贴按钮。菜单弹出时若缺粘贴按钮则主动刷新一次。
  void _refreshClipboardIfNeeded() {
    final _MenuConfig? config = widget.session._configNotifier.value;
    if (config == null || config.onPaste == null) {
      return;
    }
    final bool hasPaste = config.items.any(
      (ContextMenuButtonItem item) => item.type == ContextMenuButtonType.paste,
    );
    if (!hasPaste && config.clipboardStatus is ClipboardStatusNotifier) {
      (config.clipboardStatus as ClipboardStatusNotifier).update();
    }
  }

  @override
  void dispose() {
    widget.session._dismissedNotifier.removeListener(_handleDismissed);
    widget.session._configNotifier.removeListener(_handleConfigChanged);
    widget.session._configNotifier.value?.clipboardStatus
        ?.removeListener(_handleClipboardChanged);
    _animation.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final _MenuConfig? config = widget.session._configNotifier.value;
    if (config == null) {
      return const SizedBox.shrink();
    }
    final List<ContextMenuButtonItem> items =
        _withOptimisticPaste(_orderedItems(config.items), config);
    if (items.isEmpty) {
      return const SizedBox.shrink();
    }

    final TextSelectionToolbarAnchors anchors = config.anchors;
    final bool dismissing = widget.session._dismissedNotifier.value;

    // 判断菜单将放在选区上方还是下方（与 Material 工具栏同款判断），
    // 决定展开/收起动画的方向：始终"自锚点方向弹出、缩回锚点处"
    final double paddingAbove = MediaQuery.paddingOf(context).top;
    final bool fitsAbove = anchors.primaryAnchor.dy - paddingAbove >= _kEstimatedToolbarHeight;

    final List<Widget> buttons = <Widget>[];
    for (int i = 0; i < items.length; i++) {
      if (i > 0) {
        buttons.add(_divider());
      }
      buttons.add(_MenuButton(
        item: items[i],
        onPressed: _resolveOnPressed(config, items[i]),
      ));
    }

    // 默认展示宽度只预留前三个按钮（复制/剪切/全选）的长度，分享等
    // 其余按钮向后排布，需左右滑动才可见；同时不超过屏幕宽度减去
    // 两侧预留边距，避免菜单顶到屏幕两端
    final double maxWidth = math.min(
      _measureButtonsWidth(context, items.take(3).toList()),
      MediaQuery.sizeOf(context).width - _kMenuScreenMargin * 2,
    );

    // 与 _blurredMenuShell 同款毛玻璃外壳
    final Widget menu = DecoratedBox(
      decoration: BoxDecoration(
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
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.5),
                width: 0.5,
              ),
            ),
            child: Material(
              color: Colors.transparent,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxWidth),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  // 左右滑到顶都有触底回弹（rubber band）效果
                  physics: const BouncingScrollPhysics(
                    parent: AlwaysScrollableScrollPhysics(),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: buttons,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    return Positioned.fill(
      child: CustomSingleChildLayout(
        delegate: _ToolbarLayoutDelegate(
          anchorAbove: anchors.primaryAnchor,
          anchorBelow: anchors.secondaryAnchor ?? anchors.primaryAnchor,
        ),
        child: IgnorePointer(
          ignoring: dismissing,
          // 菜单点击归入文本域 TapRegion 组：点菜单不算"点外部"，
          // 由按钮自身的 onPressed 决定收起时机
          child: TextFieldTapRegion(
            child: AnimatedBuilder(
              animation: _animation,
              builder: (BuildContext context, Widget? child) {
                final double t = _animation.value;
                return Opacity(
                  // easeOutBack 会过冲超过 1.0，透明度需夹取
                  opacity: t.clamp(0.0, 1.0),
                  child: Transform.translate(
                    // 菜单在选区上方时自下（锚点侧）向上弹出，下方时自上向下
                    offset: Offset(0, (fitsAbove ? 14 : -14) * (1 - t)),
                    child: Transform.scale(
                      scale: 0.85 + 0.15 * t,
                      // 缩放对齐锚点侧：视觉上自锚点展开/缩回锚点
                      alignment:
                          fitsAbove ? Alignment.bottomCenter : Alignment.topCenter,
                      child: child,
                    ),
                  ),
                );
              },
              child: menu,
            ),
          ),
        ),
      ),
    );
  }

  Widget _divider() {
    return Container(
      width: 0.5,
      height: 18,
      // 竖直方向由 Row 居中；水平留 2px 与按钮文字隔开
      margin: const EdgeInsets.symmetric(horizontal: 2),
      color: Colors.grey.shade400,
    );
  }

  /// 调整按钮顺序：复制、剪切、全选三个核心按钮排在最前
  /// （与 Android 惯例顺序一致），分享等其余按钮自然向后排布，
  /// 需要滑动菜单才可见。
  List<ContextMenuButtonItem> _orderedItems(List<ContextMenuButtonItem> items) {
    const List<ContextMenuButtonType> leadingTypes = <ContextMenuButtonType>[
      ContextMenuButtonType.copy,
      ContextMenuButtonType.cut,
      ContextMenuButtonType.selectAll,
    ];
    final Map<ContextMenuButtonType, ContextMenuButtonItem> leading =
        <ContextMenuButtonType, ContextMenuButtonItem>{};
    final List<ContextMenuButtonItem> rest = <ContextMenuButtonItem>[];
    for (final ContextMenuButtonItem item in items) {
      if (leadingTypes.contains(item.type)) {
        leading[item.type] ??= item;
      } else {
        rest.add(item);
      }
    }
    if (leading.isEmpty) {
      return items;
    }
    return <ContextMenuButtonItem>[
      for (final ContextMenuButtonType type in leadingTypes)
        if (leading[type] != null) leading[type]!,
      ...rest,
    ];
  }

  /// 乐观粘贴：SDK 用 Clipboard.hasStrings 决定「粘贴」是否出现，部分 ROM
  /// （如 MIUI 的剪贴板隐私限制）对前台应用也返回 false，状态恒为
  /// notPasteable——剪贴板明明有内容却永远不给粘贴按钮。输入框可写而按钮
  /// 列表缺「粘贴」时本地补一个，点击走 pasteText（真读不到内容时它自行
  /// no-op，无副作用）。SDK 自己给出粘贴按钮时（hasPaste）不做任何干预。
  List<ContextMenuButtonItem> _withOptimisticPaste(
    List<ContextMenuButtonItem> items,
    _MenuConfig config,
  ) {
    if (config.onPaste == null) {
      return items;
    }
    final bool hasPaste = items.any(
      (ContextMenuButtonItem item) => item.type == ContextMenuButtonType.paste,
    );
    if (hasPaste) {
      return items;
    }
    return <ContextMenuButtonItem>[
      ...items,
      ContextMenuButtonItem(
        type: ContextMenuButtonType.paste,
        onPressed: config.onPaste,
      ),
    ];
  }

  /// 用 TextPainter 量出前几个按钮的自然宽度（文字宽 + 左右各 16 内边距
  /// + 按钮间分隔线），作为菜单默认展示宽度。
  double _measureButtonsWidth(
    BuildContext context,
    List<ContextMenuButtonItem> leading,
  ) {
    final TextScaler textScaler = MediaQuery.textScalerOf(context);
    final TextDirection textDirection = Directionality.of(context);
    double width = 0;
    for (int i = 0; i < leading.length; i++) {
      final TextPainter painter = TextPainter(
        text: TextSpan(
          text: AdaptiveTextSelectionToolbar.getButtonLabel(context, leading[i]),
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
        textScaler: textScaler,
        textDirection: textDirection,
      )..layout();
      width += painter.width + 32;
      painter.dispose();
      if (i > 0) {
        width += 4.5; // 分隔线 0.5 + 两侧 margin 2 + 2
      }
    }
    return width;
  }

  /// 解析按钮最终点击行为：按类型挂平台行为修正回调（全选回弹菜单、
  /// 桌面端复制后清选中），未命中修正项的按钮保持原行为。
  VoidCallback? _resolveOnPressed(_MenuConfig config, ContextMenuButtonItem item) {
    if (item.onPressed == null) {
      return null;
    }
    switch (item.type) {
      case ContextMenuButtonType.selectAll:
        return config.onSelectAll ?? item.onPressed;
      case ContextMenuButtonType.copy:
        return () {
          item.onPressed!();
          config.onCopyDone?.call();
        };
      default:
        return item.onPressed;
    }
  }
}

class _MenuButton extends StatelessWidget {
  const _MenuButton({required this.item, required this.onPressed});

  final ContextMenuButtonItem item;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final bool enabled = onPressed != null;

    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: Colors.black87,
        disabledForegroundColor: Colors.black38,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        // 固定高度 48：无论按钮数量多少、字体度量如何浮动，
        // 菜单卡片高度恒定（与 _kEstimatedToolbarHeight 一致）
        minimumSize: const Size(0, 48),
        maximumSize: const Size.fromHeight(48),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: const RoundedRectangleBorder(),
      ),
      child: Text(
        AdaptiveTextSelectionToolbar.getButtonLabel(context, item),
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: enabled ? Colors.black87 : Colors.black38,
        ),
      ),
    );
  }
}

/// 与 SDK 的 TextSelectionToolbarLayoutDelegate 同款定位逻辑（选区上方
/// 放得下则放上方，水平方向居中于锚点并夹取在屏幕内），区别在于水平
/// 方向预留屏幕边距，避免选项较多时菜单顶到屏幕两端。
class _ToolbarLayoutDelegate extends SingleChildLayoutDelegate {
  _ToolbarLayoutDelegate({
    required this.anchorAbove,
    required this.anchorBelow,
  });

  final Offset anchorAbove;
  final Offset anchorBelow;

  /// 尽可能把宽为 [width] 的子组件居中在 [position] 上，且不越过
  /// [min]..[max] 区间。
  static double _centerOn(double position, double width, double min, double max) {
    // 左边越界：尽量靠左
    if (position - width / 2.0 < min) {
      return min;
    }
    // 右边越界：尽量靠右
    if (position + width / 2.0 > max) {
      return max - width;
    }
    return position - width / 2.0;
  }

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return constraints.loosen();
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final bool fitsAbove = anchorAbove.dy >= childSize.height;
    final Offset anchor = fitsAbove ? anchorAbove : anchorBelow;
    return Offset(
      _centerOn(
        anchor.dx,
        childSize.width,
        _kMenuScreenMargin,
        math.max(_kMenuScreenMargin, size.width - _kMenuScreenMargin),
      ),
      fitsAbove ? math.max(0.0, anchor.dy - childSize.height) : anchor.dy,
    );
  }

  @override
  bool shouldRelayout(_ToolbarLayoutDelegate oldDelegate) {
    return anchorAbove != oldDelegate.anchorAbove ||
        anchorBelow != oldDelegate.anchorBelow;
  }
}
