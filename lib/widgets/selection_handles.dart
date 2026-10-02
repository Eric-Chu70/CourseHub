import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// 自动选行后的两端拖拽手柄：外观取 material 选择手柄，拖动时向区域
/// 委托派发选区边缘更新事件（与系统拖拽手柄同款路径），选区实时跟随
/// 手指；松手后通知宿主让统一菜单锚点随新选区更新。
///
/// 定位：[CompositedTransformFollower] 跟随 [link] 所锚定的正文盒子，
/// 手柄偏移用选区几何的局部坐标（滚动时局部坐标不变，跟随层自动完成
/// 屏幕空间的换算）——列表滚动时手柄始终吸附在选区两端。
///
/// 需要外层已处于一个 [Overlay] 中（通常作为独立 OverlayEntry 挂载在
/// 根 Overlay，避免触碰正文子树导致段落重建、选区丢失）。
class SelectionHandles extends StatefulWidget {
  const SelectionHandles({
    super.key,
    required this.delegate,
    required this.link,
    required this.regionContext,
    required this.onAdjusted,
    this.onDragStart,
    this.onDragEnd,
  });

  final MultiSelectableSelectionContainerDelegate delegate;

  /// 锚定正文盒子的 LayerLink（宿主用 CompositedTransformTarget 挂在
  /// 正文外层）：定位用，滚动时跟随层自动换算
  final LayerLink link;

  /// 区域状态的 context：仅用于拖动起点把局部边缘换算成全局坐标
  /// （拖动增量基于全局指针位移）
  final BuildContext regionContext;
  final VoidCallback onAdjusted;

  /// 拖动开始/结束：宿主据此区分「自身手柄拖动」与「用户手势接管」，
  /// 拖动期间的选区几何变化不应触发菜单/手柄的接管收起
  final VoidCallback? onDragStart;
  final VoidCallback? onDragEnd;

  @override
  State<SelectionHandles> createState() => _SelectionHandlesState();
}

class _SelectionHandlesState extends State<SelectionHandles> {
  /// 触摸区：以 teardrop 为中心四周各扩 14px（气泡自带内边距，
  /// teardrop 完全在屏内，直接按它即可拖动）
  static const EdgeInsets _touchInsets = EdgeInsets.all(14);

  Offset? _startDragPointer;
  Offset? _startDragEdge;
  Offset? _endDragPointer;
  Offset? _endDragEdge;

  static bool _finite(Offset o) => o.dx.isFinite && o.dy.isFinite;

  void _dispatchEdge(bool isStart, Offset globalPosition) {
    widget.delegate.dispatchSelectionEvent(
      isStart
          ? SelectionEdgeUpdateEvent.forStart(globalPosition: globalPosition)
          : SelectionEdgeUpdateEvent.forEnd(globalPosition: globalPosition),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 整个 build 兜底：任何异常都降级为不显示，绝不打断渲染帧
    // （Overlay entry 的 build/layout 异常在 release 下会破坏整帧，
    // 连带选区高亮与统一菜单一起消失）
    try {
      return _buildHandles(context);
    } catch (e) {
      debugPrint('[SelectionHandles] build 降级: $e');
      return const SizedBox.shrink();
    }
  }

  Widget _buildHandles(BuildContext context) {
    final SelectionGeometry geometry = widget.delegate.value;
    final SelectionPoint? start = geometry.startSelectionPoint;
    final SelectionPoint? end = geometry.endSelectionPoint;
    if (start == null || end == null) return const SizedBox.shrink();
    // 坐标必须有限；病态值（变换异常等）直接降级为不显示
    if (!_finite(start.localPosition) || !_finite(end.localPosition)) {
      debugPrint('[SelectionHandles] 坐标非有限值，降级不显示');
      return const SizedBox.shrink();
    }

    // 跟随层锚定正文盒子：局部偏移恒定，滚动/布局变化由跟随层自动换算
    return Positioned.fill(
      child: CompositedTransformFollower(
        link: widget.link,
        showWhenUnlinked: false,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            _handle(
              isStart: true,
              local: start.localPosition,
              lineHeight: start.lineHeight,
            ),
            _handle(
              isStart: false,
              local: end.localPosition,
              lineHeight: end.lineHeight,
            ),
          ],
        ),
      ),
    );
  }

  /// 手柄视觉尺寸：水滴造型，尖角在顶部中央、正对选区端点，
  /// 垂直悬挂在选中线下方，不向左右偏移
  static const double _dropWidth = 24;
  static const double _dropHeight = 26;

  Widget _handle({
    required bool isStart,
    required Offset local,
    required double lineHeight,
  }) {
    const EdgeInsets touchInsets = _touchInsets;
    final Color color = Theme.of(context).colorScheme.primary;

    // 尖角（顶部中央）对准选区端点：水平居中于端点 x，垂直从线的
    // 下缘开始向下悬挂，不向左右偏移
    return Positioned(
      left: local.dx - _dropWidth / 2 - touchInsets.left,
      top: local.dy - touchInsets.top,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (details) {
          widget.onDragStart?.call();
          // 拖动基准换算成全局坐标：增量派发的边缘事件需要全局位置
          final RenderObject? box = widget.regionContext.findRenderObject();
          // 派发点取该行垂直中心：贴着行底边的 y 会被亲和性解析到行尾
          final Offset globalBase = (box is RenderBox && box.attached)
              ? box.localToGlobal(local - Offset(0, lineHeight / 2))
              : local;
          debugPrint('[手柄] globalBase=$globalBase local=$local');
          if (isStart) {
            _startDragPointer = details.globalPosition;
            _startDragEdge = globalBase;
          } else {
            _endDragPointer = details.globalPosition;
            _endDragEdge = globalBase;
          }
        },
        onPanUpdate: (details) {
          // 实时读字段（不能用 build 期捕获的闭包值：onPanStart 在
          // 构建之后才写入基准，闭包里是过期的 null）
          final Offset? pointer = isStart ? _startDragPointer : _endDragPointer;
          final Offset? edgeBase = isStart ? _startDragEdge : _endDragEdge;
          if (pointer == null || edgeBase == null) return;
          final Offset edge = edgeBase + (details.globalPosition - pointer);
          _dispatchEdge(isStart, edge);
          // 拖动中让统一菜单锚点实时跟随新选区
          widget.onAdjusted();
          setState(() {}); // 选区几何已更新，两端手柄跟随
        },
        onPanEnd: (details) {
          final Offset? pointer = isStart ? _startDragPointer : _endDragPointer;
          final Offset? edgeBase = isStart ? _startDragEdge : _endDragEdge;
          if (pointer == null || edgeBase == null) return;
          final Offset edge = edgeBase + (details.globalPosition - pointer);
          _dispatchEdge(isStart, edge);
          if (isStart) {
            _startDragPointer = null;
            _startDragEdge = null;
          } else {
            _endDragPointer = null;
            _endDragEdge = null;
          }
          setState(() {});
          widget.onDragEnd?.call();
          widget.onAdjusted();
        },
        child: Padding(
          padding: touchInsets,
          child: SizedBox(
            width: _dropWidth,
            height: _dropHeight,
            child: CustomPaint(
              painter: _SelectionDropPainter(color: color),
            ),
          ),
        ),
      ),
    );
  }
}


/// 手柄水滴造型：圆滴 + 顶部小尖角，尖角指向选区端点
class _SelectionDropPainter extends CustomPainter {
  const _SelectionDropPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final double cx = size.width / 2;
    final double cy = size.height * 0.64;
    final double r = size.width * 0.42;
    canvas.drawCircle(Offset(cx, cy), r, paint);
    final Path tip = Path()
      ..moveTo(cx - r * 0.62, cy - r * 0.55)
      ..lineTo(cx, 0)
      ..lineTo(cx + r * 0.62, cy - r * 0.55)
      ..close();
    canvas.drawPath(tip, paint);
  }

  @override
  bool shouldRepaint(_SelectionDropPainter oldDelegate) =>
      oldDelegate.color != color;
}
