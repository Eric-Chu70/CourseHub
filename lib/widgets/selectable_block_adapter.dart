// 可选中"块"适配器：让 Table / LaTeX 公式这类**非文本渲染**的内容
// 参与 SelectionArea 的选择（高亮 + 复制 + 手柄定位）。
//
// 原理（改写自 gpt_markdown 1.1.5 的 custom_widgets/selectable_adapter.dart，
// MIT）：SelectionArea 的选择机制要求文本的渲染对象实现 Selectable 并注册
// 到 SelectionRegistrar；Table / Math.tex 内部的文字不满足，因此把整个内容
// 块作为一个"原子级"Selectable 注册 —— 选中语义是**整块**：
//   - 拖动选择：光标矩形与块相交即整块选中；
//   - 复制：返回 [selectedText]（调用方生成的块级纯文本）；
//   - 手柄：把两端 LayerLink 推给渲染层，由 SelectionArea 的手柄浮层定位。
// 外层不在 SelectionArea 内（SelectionContainer 为 null）时原样返回 child，
// 零开销。
//
// 使用：`SelectableBlockAdapter(selectedText: 纯文本, child: 内容)`。
// 两条使用路径：AI 对话页的 tableBuilder（表格）与 latexBuilder（display 公式）。

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

class SelectableBlockAdapter extends StatelessWidget {
  const SelectableBlockAdapter({
    super.key,
    required this.child,
    required this.selectedText,
  });

  final Widget child;
  final String selectedText;

  @override
  Widget build(BuildContext context) {
    final SelectionRegistrar? registrar = SelectionContainer.maybeOf(context);
    // 两种形态必须返回同一种 widget 形状。以前「不在选择区域里就把 child
    // 原样返回」，于是进入/退出选取模式时同一位置的子 widget 类型在
    // child 与 MouseRegion(块渲染对象) 之间来回换，框架只能销毁重建那条
    // 子树：表格里 FadingEdgeBox 的 State 跟着重建，_fade 退回初始的
    // (false,false)，第一帧完全没有淡出遮罩（帧后才补回来）＝闪一下，
    // 顺带把表格的横向滚动位置重置回最左。现在恒定包一层，registrar 为空
    // 时块渲染对象不注册也不画高亮，等价于原来的「零开销直通」，但子树
    // 不再被拆。鼠标光标只在真有选择区域时才切成文本光标，平时保持继承。
    return MouseRegion(
      cursor: registrar != null ? SystemMouseCursors.text : MouseCursor.defer,
      child: _SelectableBlockRender(
        registrar: registrar,
        selectedText: selectedText,
        child: child,
      ),
    );
  }
}

class _SelectableBlockRender extends SingleChildRenderObjectWidget {
  const _SelectableBlockRender({
    required this.registrar,
    required Widget child,
    required this.selectedText,
  }) : super(child: child);

  /// 为空表示当前不在选择区域里：块渲染对象照在树里，但不向任何注册器
  /// 登记，也不画高亮（保持 widget 形状恒定，见 build 里的说明）。
  final SelectionRegistrar? registrar;
  final String selectedText;

  @override
  _RenderSelectableBlock createRenderObject(BuildContext context) {
    return _RenderSelectableBlock(
      _selectionColorOf(context),
      registrar,
      selectedText,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSelectableBlock renderObject,
  ) {
    renderObject
      ..selectionColor = _selectionColorOf(context)
      ..registrar = registrar
      // 复制用的块级纯文本要跟着更新：流式输出时同一个表格块会被重新
      // 解析出新的行，只在建对象时写入会让复制拿到旧内容
      ..selectedText = selectedText;
  }

  /// 平时（没有选择区域）也可能被构建，`DefaultSelectionStyle` 的选中色
  /// 不一定给得出，取不到就退回主题的高亮色，别用 `!` 崩在渲染期
  static Color _selectionColorOf(BuildContext context) =>
      DefaultSelectionStyle.of(context).selectionColor ??
      Theme.of(context).colorScheme.primary.withValues(alpha: 0.3);
}

class _RenderSelectableBlock extends RenderProxyBox
    with Selectable, SelectionRegistrant {
  _RenderSelectableBlock(
    Color selectionColor,
    SelectionRegistrar? registrar,
    this.selectedText,
  )   : _selectionColor = selectionColor,
        _geometry = ValueNotifier<SelectionGeometry>(_noSelection) {
    this.registrar = registrar;
    _geometry.addListener(markNeedsPaint);
  }

  String selectedText;

  static const SelectionGeometry _noSelection = SelectionGeometry(
    status: SelectionStatus.none,
    hasContent: true,
  );
  final ValueNotifier<SelectionGeometry> _geometry;
  Color get selectionColor => _selectionColor;
  Color _selectionColor;
  set selectionColor(Color value) {
    if (_selectionColor == value) return;
    _selectionColor = value;
    markNeedsPaint();
  }

  // ValueListenable APIs

  @override
  void addListener(VoidCallback listener) => _geometry.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _geometry.removeListener(listener);

  @override
  SelectionGeometry get value => _geometry.value;

  // Selectable APIs.

  @override
  List<Rect> get boundingBoxes => <Rect>[paintBounds];

  // Adjust this value to enlarge or shrink the selection highlight.
  static const double _padding = 0.0;
  Rect _getSelectionHighlightRect() {
    return Rect.fromLTWH(
      0 - _padding,
      0 - _padding,
      size.width + _padding * 2,
      size.height + _padding * 2,
    );
  }

  Offset? _start;
  Offset? _end;
  void _updateGeometry() {
    if (_start == null || _end == null) {
      _geometry.value = _noSelection;
      return;
    }
    final Rect renderObjectRect = Rect.fromLTWH(0, 0, size.width, size.height);
    // 首尾两端在同一行上（自动选行就是按「行首→行尾、同一个 y」派发的）
    // 时 Rect.fromPoints 得到零高度矩形，而 Rect.isEmpty 把宽或高为 0 也
    // 判为空 → intersect 视为「不相交」→ 整块永远选不中，表现为表格 /
    // display 公式处双击、菜单「选取文字」都没反应。本块的语义是
    // 「相交即整块选中」，故先把拖拽矩形补足到至少 1px 见方再判相交。
    final Rect dragRect = Rect.fromPoints(_start!, _end!).inflate(0.5);
    if (renderObjectRect.intersect(dragRect).isEmpty) {
      _geometry.value = _noSelection;
    } else {
      final Rect selectionRect = _getSelectionHighlightRect();
      final SelectionPoint firstSelectionPoint = SelectionPoint(
        localPosition: selectionRect.bottomLeft,
        lineHeight: selectionRect.size.height,
        handleType: TextSelectionHandleType.left,
      );
      final SelectionPoint secondSelectionPoint = SelectionPoint(
        localPosition: selectionRect.bottomRight,
        lineHeight: selectionRect.size.height,
        handleType: TextSelectionHandleType.right,
      );
      final bool isReversed;
      if (_start!.dy > _end!.dy) {
        isReversed = true;
      } else if (_start!.dy < _end!.dy) {
        isReversed = false;
      } else {
        isReversed = _start!.dx > _end!.dx;
      }
      _geometry.value = SelectionGeometry(
        status: SelectionStatus.uncollapsed,
        hasContent: true,
        startSelectionPoint:
            isReversed ? secondSelectionPoint : firstSelectionPoint,
        endSelectionPoint:
            isReversed ? firstSelectionPoint : secondSelectionPoint,
        selectionRects: <Rect>[selectionRect],
      );
    }
  }

  @override
  SelectionResult dispatchSelectionEvent(SelectionEvent event) {
    SelectionResult result = SelectionResult.none;
    switch (event.type) {
      case SelectionEventType.startEdgeUpdate:
      case SelectionEventType.endEdgeUpdate:
        final Rect renderObjectRect = Rect.fromLTWH(
          0,
          0,
          size.width,
          size.height,
        );
        // Normalize offset in case it is out side of the rect.
        final Offset point = globalToLocal(
          (event as SelectionEdgeUpdateEvent).globalPosition,
        );
        final Offset adjustedPoint = SelectionUtils.adjustDragOffset(
          renderObjectRect,
          point,
        );
        if (event.type == SelectionEventType.startEdgeUpdate) {
          _start = adjustedPoint;
        } else {
          _end = adjustedPoint;
        }
        result = SelectionUtils.getResultBasedOnRect(renderObjectRect, point);
      case SelectionEventType.clear:
        _start = _end = null;
      case SelectionEventType.selectAll:
      case SelectionEventType.selectWord:
      case SelectionEventType.selectParagraph:
        _start = Offset.zero;
        _end = Offset.infinite;
      case SelectionEventType.granularlyExtendSelection:
        result = SelectionResult.end;
        final GranularlyExtendSelectionEvent extendSelectionEvent =
            event as GranularlyExtendSelectionEvent;
        // Initialize the offset it there is no ongoing selection.
        if (_start == null || _end == null) {
          if (extendSelectionEvent.forward) {
            _start = _end = Offset.zero;
          } else {
            _start = _end = Offset.infinite;
          }
        }
        // Move the corresponding selection edge.
        final Offset newOffset =
            extendSelectionEvent.forward ? Offset.infinite : Offset.zero;
        if (extendSelectionEvent.isEnd) {
          if (newOffset == _end) {
            result =
                extendSelectionEvent.forward
                    ? SelectionResult.next
                    : SelectionResult.previous;
          }
          _end = newOffset;
        } else {
          if (newOffset == _start) {
            result =
                extendSelectionEvent.forward
                    ? SelectionResult.next
                    : SelectionResult.previous;
          }
          _start = newOffset;
        }
      case SelectionEventType.directionallyExtendSelection:
        result = SelectionResult.end;
        final DirectionallyExtendSelectionEvent extendSelectionEvent =
            event as DirectionallyExtendSelectionEvent;
        // Convert to local coordinates.
        final double horizontalBaseLine = globalToLocal(Offset(event.dx, 0)).dx;
        final Offset newOffset;
        final bool forward;
        switch (extendSelectionEvent.direction) {
          case SelectionExtendDirection.backward:
          case SelectionExtendDirection.previousLine:
            forward = false;
            // Initialize the offset it there is no ongoing selection.
            if (_start == null || _end == null) {
              _start = _end = Offset.infinite;
            }
            // Move the corresponding selection edge.
            if (extendSelectionEvent.direction ==
                    SelectionExtendDirection.previousLine ||
                horizontalBaseLine < 0) {
              newOffset = Offset.zero;
            } else {
              newOffset = Offset.infinite;
            }
          case SelectionExtendDirection.nextLine:
          case SelectionExtendDirection.forward:
            forward = true;
            // Initialize the offset it there is no ongoing selection.
            if (_start == null || _end == null) {
              _start = _end = Offset.zero;
            }
            // Move the corresponding selection edge.
            if (extendSelectionEvent.direction ==
                    SelectionExtendDirection.nextLine ||
                horizontalBaseLine > size.width) {
              newOffset = Offset.zero;
            } else {
              newOffset = Offset.infinite;
            }
        }
        if (extendSelectionEvent.isEnd) {
          if (newOffset == _end) {
            result = forward
                ? SelectionResult.next
                : SelectionResult.previous;
          }
          _end = newOffset;
        } else {
          if (newOffset == _start) {
            result = forward
                ? SelectionResult.next
                : SelectionResult.previous;
          }
          _start = newOffset;
        }
    }
    _updateGeometry();
    return result;
  }

  // This method is called when users want to copy selected content in this
  // widget into clipboard.
  @override
  SelectedContent? getSelectedContent() {
    return value.hasSelection ? SelectedContent(plainText: selectedText) : null;
  }

  @override
  SelectedContentRange? getSelection() {
    if (!value.hasSelection) {
      return null;
    }
    return const SelectedContentRange(startOffset: 0, endOffset: 1);
  }

  @override
  int get contentLength => 1;

  LayerLink? _startHandle;
  LayerLink? _endHandle;

  @override
  void pushHandleLayers(LayerLink? startHandle, LayerLink? endHandle) {
    if (_startHandle == startHandle && _endHandle == endHandle) {
      return;
    }
    _startHandle = startHandle;
    _endHandle = endHandle;
    markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    if (!_geometry.value.hasSelection) {
      return;
    }
    // Draw the selection highlight.
    final Paint selectionPaint =
        Paint()
          ..style = PaintingStyle.fill
          ..color = _selectionColor;
    context.canvas.drawRect(
      _getSelectionHighlightRect().shift(offset),
      selectionPaint,
    );

    // Push the layer links if any.
    if (_startHandle != null) {
      context.pushLayer(
        LeaderLayer(
          link: _startHandle!,
          offset: offset + value.startSelectionPoint!.localPosition,
        ),
        (PaintingContext context, Offset offset) {},
        Offset.zero,
      );
    }
    if (_endHandle != null) {
      context.pushLayer(
        LeaderLayer(
          link: _endHandle!,
          offset: offset + value.endSelectionPoint!.localPosition,
        ),
        (PaintingContext context, Offset offset) {},
        Offset.zero,
      );
    }
  }

  @override
  void dispose() {
    _geometry.dispose();
    _startHandle = null;
    _endHandle = null;
    super.dispose();
  }
}
