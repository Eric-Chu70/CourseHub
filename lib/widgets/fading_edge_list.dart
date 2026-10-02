// 边缘淡出雾化遮罩的滚动列表（纵向 / 横向通用）。
//
// 由来：课表列表（云端数据管理对话框）与「选择学校」页的最近使用横滑行
// 都需要「内容超出可视范围后，仍有内容的一侧在边缘渐隐」的效果，写法
// 最早来自 AI 输入框 `_buildFadingTextField`。三处各写一份必然漂移，
// 故抽成这一个组件。
//
// 要点：
// 1. 结构恒定：无论当前是否淡出，都返回同型的 ShaderMask → ListView 链，
//    不做「按需切换子树」，避免列表被销毁重建导致滚动位置丢失；
//    未滚动的一侧只是把渐变该端设为全不透明，视觉等价无遮罩；
// 2. 只有遮罩子树随滚动状态重建（ValueNotifier + ValueListenableBuilder），
//    滚动逐帧不触发宿主页面整体重建；
// 3. 首帧布局完成后才能读到 maxScrollExtent，故淡出状态在
//    addPostFrameCallback 里初始化；itemCount/尺寸变化时重新采样。

import 'dart:ui';

import 'package:flutter/material.dart';

class FadingEdgeList extends StatefulWidget {
  const FadingEdgeList({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.scrollDirection = Axis.vertical,
    this.height,
    this.width,
    this.padding = EdgeInsets.zero,
    this.physics = const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics()),
    this.fadeExtent = 26.0,
    this.shrinkWrap = false,
    this.controller,
  });

  final int itemCount;
  final Widget Function(BuildContext, int) itemBuilder;

  /// 外部滚动控制器：宿主需要自己驱动滚动时用（如 AI 对话要"回底"），
  /// 传入后本组件不再自建控制器，也**不负责 dispose** 它。
  final ScrollController? controller;

  /// 滚动方向：纵向时淡出上下边缘，横向时淡出左右边缘
  final Axis scrollDirection;

  /// 可视高度（纵向用法；定高时外层 AnimatedSize 才有确定尺寸可动画）
  final double? height;

  /// 可视宽度（横向用法可留空，由父级约束决定）
  final double? width;

  final EdgeInsetsGeometry padding;
  final ScrollPhysics physics;

  /// 单端淡出带长度（约条目尺寸的 1/3：看得清渐变又不吞掉一整条）
  final double fadeExtent;

  /// 内容自撑模式：true 时 ListView 加 shrinkWrap，高度贴合内容，
  /// 由调用方提供 maxHeight 约束（内容超出约束才滚动）。
  /// false（默认）为常规列表，占满 [height] / 父级给定的有界高度
  final bool shrinkWrap;

  @override
  State<FadingEdgeList> createState() => _FadingEdgeListState();
}

class _FadingEdgeListState extends State<FadingEdgeList> {
  /// 未传外部控制器时才自建；dispose 也只回收自建的这一个
  ScrollController? _owned;
  ScrollController get _controller =>
      widget.controller ?? (_owned ??= ScrollController());

  // start = 纵向的上 / 横向的左；end = 纵向的下 / 横向的右
  final ValueNotifier<({bool start, bool end})> _fade =
      ValueNotifier((start: false, end: false));

  @override
  void initState() {
    super.initState();
    _controller.addListener(_updateFade);
    // 首帧布局完成后才能读到 maxScrollExtent
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateFade());
  }

  @override
  void didUpdateWidget(covariant FadingEdgeList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.itemCount != widget.itemCount ||
        oldWidget.height != widget.height ||
        oldWidget.width != widget.width) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _updateFade());
    }
  }

  void _updateFade() {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    // 无可滚动范围（内容未超出）时两端都不淡出
    final bool canScroll = position.maxScrollExtent > 1;
    final next = (
      start: canScroll && position.pixels > 1,
      end: canScroll && position.pixels < position.maxScrollExtent - 1,
    );
    if (next.start != _fade.value.start || next.end != _fade.value.end) {
      _fade.value = next;
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_updateFade);
    _owned?.dispose();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<({bool start, bool end})>(
      valueListenable: _fade,
      builder: (context, fade, _) {
        return ShaderMask(
          shaderCallback: (bounds) {
            if (!fade.start && !fade.end) {
              return const LinearGradient(
                colors: [Colors.white, Colors.white],
              ).createShader(bounds);
            }
            // 沿滚动轴计算淡出带占比（夹在 45% 以内，避免半个列表都糊掉）
            final extent = widget.scrollDirection == Axis.vertical
                ? bounds.height
                : bounds.width;
            final t = (widget.fadeExtent / extent).clamp(0.0, 0.45);
            return LinearGradient(
              begin: widget.scrollDirection == Axis.vertical
                  ? Alignment.topCenter
                  : Alignment.centerLeft,
              end: widget.scrollDirection == Axis.vertical
                  ? Alignment.bottomCenter
                  : Alignment.centerRight,
              colors: [
                fade.start ? Colors.transparent : Colors.white,
                Colors.white,
                Colors.white,
                fade.end ? Colors.transparent : Colors.white,
              ],
              stops: [
                0.0,
                fade.start ? t : 0.0,
                fade.end ? 1 - t : 1.0,
                1.0,
              ],
            ).createShader(bounds);
          },
          blendMode: BlendMode.dstIn,
          child: SizedBox(
            height: widget.height,
            width: widget.width,
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(context)
                  .copyWith(physics: widget.physics),
              child: ListView.builder(
                controller: _controller,
                scrollDirection: widget.scrollDirection,
                padding: widget.padding,
                physics: widget.physics,
                // shrinkWrap：高度贴合内容（需调用方给 maxHeight 约束）；
                // 常规模式：占满父级给定的有界高度
                shrinkWrap: widget.shrinkWrap,
                itemCount: widget.itemCount,
                itemBuilder: widget.itemBuilder,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 任意内容的单轴滚动淡出包装（非列表场景）：
/// AI 回复里的横向 Markdown 表格、长公式等——内容比可视宽度长时，
/// 仍有内容的一侧在边缘 [fadeExtent] 内渐隐，提示可以滑动。
/// 淡出判定与 [FadingEdgeList] 同一套机制。
class FadingEdgeBox extends StatefulWidget {
  const FadingEdgeBox({
    super.key,
    required this.child,
    this.axis = Axis.horizontal,
    this.physics = const BouncingScrollPhysics(),
    this.fadeExtent = 24.0,
  });

  /// 滚动内容（不含滚动容器，本组件内部包 SingleChildScrollView）
  final Widget child;
  final Axis axis;
  final ScrollPhysics physics;
  final double fadeExtent;

  @override
  State<FadingEdgeBox> createState() => _FadingEdgeBoxState();
}

class _FadingEdgeBoxState extends State<FadingEdgeBox> {
  final ScrollController _controller = ScrollController();
  final ValueNotifier<({bool start, bool end})> _fade =
      ValueNotifier((start: false, end: false));

  @override
  void initState() {
    super.initState();
    _controller.addListener(_updateFade);
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateFade());
  }

  void _updateFade() {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    final bool canScroll = position.maxScrollExtent > 1;
    final next = (
      start: canScroll && position.pixels > 1,
      end: canScroll && position.pixels < position.maxScrollExtent - 1,
    );
    if (next.start != _fade.value.start || next.end != _fade.value.end) {
      _fade.value = next;
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_updateFade);
    _controller.dispose();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<({bool start, bool end})>(
      valueListenable: _fade,
      builder: (context, fade, _) {
        return ShaderMask(
          shaderCallback: (bounds) {
            if (!fade.start && !fade.end) {
              return const LinearGradient(
                colors: [Colors.white, Colors.white],
              ).createShader(bounds);
            }
            final extent = widget.axis == Axis.vertical
                ? bounds.height
                : bounds.width;
            final t = (widget.fadeExtent / extent).clamp(0.0, 0.45);
            return LinearGradient(
              begin: widget.axis == Axis.vertical
                  ? Alignment.topCenter
                  : Alignment.centerLeft,
              end: widget.axis == Axis.vertical
                  ? Alignment.bottomCenter
                  : Alignment.centerRight,
              colors: [
                fade.start ? Colors.transparent : Colors.white,
                Colors.white,
                Colors.white,
                fade.end ? Colors.transparent : Colors.white,
              ],
              stops: [
                0.0,
                fade.start ? t : 0.0,
                fade.end ? 1 - t : 1.0,
                1.0,
              ],
            ).createShader(bounds);
          },
          blendMode: BlendMode.dstIn,
          child: SingleChildScrollView(
            controller: _controller,
            scrollDirection: widget.axis,
            physics: widget.physics,
            child: widget.child,
          ),
        );
      },
    );
  }
}
