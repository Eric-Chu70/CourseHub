import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// 自动选行 + 统一菜单回归测试：复刻真实链路——
/// 长按消息 → showBlurredMenu 统一下拉菜单 → 点「选取文字」→ 菜单路由
/// 关闭 → 挂载选取容器（SelectionArea）→ 区域委托派发选区事件自动选中
/// 长按所在行 → 统一玻璃菜单（输入框长按同款）与两端拖拽手柄出现 →
/// 点复制 → onCopyDone 收尾退出，统一菜单与手柄消失。
import 'package:coursehub/widgets/blur_selection_menu.dart';
import 'package:coursehub/widgets/glass_dialog.dart';
import 'package:coursehub/widgets/selection_handles.dart';

/// 行定位目标：行首/行尾全局坐标 + 到按住点的就近距离
class _LineTarget {
  const _LineTarget(this.start, this.end, this.distance);
  final Offset start;
  final Offset end;
  final double distance;
}

/// 与 App 的 _nearestLineInParagraph 同款：按住点就近找行
_LineTarget? _nearestLineInParagraph(
    RenderParagraph paragraph, Offset pressGlobal) {
  if (!paragraph.hasSize || paragraph.text.toPlainText().trim().isEmpty) {
    return null;
  }
  final Size pSize = paragraph.size;
  final Offset local = paragraph.globalToLocal(pressGlobal);
  final double dx = local.dx.clamp(0.0, pSize.width);
  final double dy = local.dy.clamp(0.0, pSize.height);

  final TextBox? probeBox = _charBoxAt(
      paragraph, paragraph.getPositionForOffset(Offset(dx, dy)).offset);
  if (probeBox == null) return null;
  final double centerY = (probeBox.top + probeBox.bottom) / 2;

  final TextBox? startBox = _charBoxAt(
      paragraph, paragraph.getPositionForOffset(Offset(0, centerY)).offset);
  final TextBox? endBox = _charBoxAt(
      paragraph,
      paragraph.getPositionForOffset(Offset(pSize.width, centerY)).offset);
  if (startBox == null || endBox == null) return null;

  final Offset start =
      paragraph.localToGlobal(Offset(startBox.left + 2, centerY));
  final Offset end = paragraph.localToGlobal(Offset(endBox.right - 2, centerY));

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

TextBox? _charBoxAt(RenderParagraph paragraph, int offset) {
  final int length = paragraph.text.toPlainText().length;
  if (length == 0) return null;
  final int index = offset.clamp(0, length - 1);
  final List<TextBox> boxes = paragraph.getBoxesForSelection(
    TextSelection(baseOffset: index, extentOffset: index + 1),
  );
  return boxes.isEmpty ? null : boxes.first;
}

/// 复刻 _MessageSelectionArea：SelectionArea + 派发自动选行 +
/// 独立 OverlayEntry 挂载统一菜单与手柄 + onCopyDone 收尾退出
class _Host extends StatefulWidget {
  const _Host({
    required this.onAutoSelectResult,
    this.onDelegate,
  });
  final ValueChanged<String?> onAutoSelectResult;
  final ValueChanged<MultiSelectableSelectionContainerDelegate>? onDelegate;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  MultiSelectableSelectionContainerDelegate? _delegate;
  SelectableRegionState? _regionState;
  final LayerLink regionLink = LayerLink();
  OverlayEntry? menuEntry;
  OverlayEntry? handlesEntry;
  bool exited = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoSelectLine());
  }

  @override
  void dispose() {
    menuEntry?.remove();
    handlesEntry?.remove();
    super.dispose();
  }

  void _autoSelectLine() {
    final RenderObject? rootObject = context.findRenderObject();
    if (rootObject is! RenderBox || !rootObject.hasSize) return;

    // 按住点取自身第一行中心（等价于用户在该行长按）
    _LineTarget? best;
    void visit(RenderObject object) {
      if (object is RenderParagraph) {
        final candidate = _nearestLineInParagraph(
            object, object.localToGlobal(Offset(
                object.size.width / 2, object.size.height / 2)));
        if (candidate != null &&
            (best == null || candidate.distance < best!.distance)) {
          best = candidate;
        }
        return;
      }
      object.visitChildren(visit);
    }

    visit(rootObject);
    final _LineTarget? target = best;
    final delegate = _delegate;
    if (target == null || delegate == null) return;

    // 区域级事件派发：起点收缩到行首、终点扩展到行尾（字符精度）
    delegate.dispatchSelectionEvent(
        SelectionEdgeUpdateEvent.forStart(globalPosition: target.start));
    delegate.dispatchSelectionEvent(
        SelectionEdgeUpdateEvent.forEnd(globalPosition: target.end));

    // 手柄浮层先插入、统一菜单后插入：菜单渲染在最上层，避免手柄的
    // 触摸热区盖住菜单按钮
    handlesEntry = OverlayEntry(
      builder: (context) => SelectionHandles(
        delegate: delegate,
        link: regionLink,
        regionContext: _regionState!.context,
        onAdjusted: () => menuEntry?.markNeedsBuild(),
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(handlesEntry!);
    menuEntry = OverlayEntry(
      builder: (context) => styledSelectableRegionContextMenu(
        context,
        _regionState!,
        // 与 App 一致：复制后收尾退出，不依赖 onSelectionChanged
        onCopyDone: () {
          menuEntry?.remove();
          menuEntry = null;
          handlesEntry?.remove();
          handlesEntry = null;
          exited = true;
        },
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(menuEntry!);

    // 派发路径不触发 onSelectionChanged，直接读取实际选中内容
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onAutoSelectResult(delegate.getSelectedContent()?.plainText);
    });
  }

  @override
  Widget build(BuildContext context) {
    return SelectionArea(
      contextMenuBuilder: (context, selectableRegion) {
        // SDK 路径（用户长按/拖动）呼出的同款统一菜单
        return styledSelectableRegionContextMenu(context, selectableRegion);
      },
      child: CompositedTransformTarget(
        link: regionLink,
        child: Builder(builder: (context) {
          if (_delegate == null) {
            _delegate = SelectionContainer.maybeOf(context)
                as MultiSelectableSelectionContainerDelegate?;
            _regionState ??=
                context.findAncestorStateOfType<SelectableRegionState>();
            widget.onDelegate?.call(_delegate!);
          }
          return const Padding(
            // 模拟气泡内边距（真机手柄位置受此影响）
            padding: EdgeInsets.only(left: 14),
            child: Text('这是一个足够长的单段落文本内容需要换行显示测试选取功能的效果',
                style: TextStyle(fontSize: 14, height: 1.5)),
          );
        }),
      ),
    );
  }
}

void main() {
  testWidgets('真实菜单流程后自动选行、统一菜单与手柄出现、复制后全部消失',
      (tester) async {
    String? autoSelectResult;
    MultiSelectableSelectionContainerDelegate? delegateProbe;

    late StateSetter setOuterState;
    bool hostMounted = false;
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(builder: (context, setState) {
        setOuterState = setState;
        return Scaffold(
          body: ListView(children: [
            ListTile(
              title: const Text('消息占位（长按我）'),
              onLongPress: () async {
                final result = await showBlurredMenu<int>(
                  context: context,
                  anchorGlobalPosition: const Offset(100, 100),
                  menuWidth: 140,
                  items: const [
                    DropdownMenuItem<int>(value: 1, child: Text('复制')),
                    DropdownMenuItem<int>(value: 2, child: Text('选取文字')),
                  ],
                );
                if (result == 2) {
                  setOuterState(() => hostMounted = true);
                }
              },
            ),
            if (hostMounted)
              _Host(
                onAutoSelectResult: (s) => autoSelectResult = s,
                onDelegate: (d) => delegateProbe = d,
              ),
          ]),
        );
      }),
    ));
    await tester.pumpAndSettle();

    // 长按占位消息 → 弹出统一下拉菜单 → 点「选取文字」
    await tester.longPress(find.text('消息占位（长按我）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('选取文字'));
    await tester.pumpAndSettle();

    // 派发与菜单挂载完成
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 行内容精确选中
    expect(autoSelectResult, isNotNull, reason: '真实路由流程后自动选行应产生选区');
    expect(autoSelectResult,
        '这是一个足够长的单段落文本内容需要换行显示测试选取功能的效果');

    // 统一玻璃菜单应已绘制到根 Overlay（测试平台无中文本地化，标签为英文）
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Select all'), findsOneWidget);

    // 两端拖拽手柄应已挂载
    expect(find.byType(SelectionHandles), findsOneWidget,
        reason: '自动选行后应显示可拖拽的选区手柄');

    // 拖动起点手柄向右 → 选区应缩小（手柄可拖）
    // 自家手柄的 GestureDetector 带 onPanStart（区分 controls 内部的）
    final handleGestureFinder = find.byWidgetPredicate((w) =>
        w is GestureDetector &&
        w.onPanStart != null &&
        '${w.runtimeType}'.isNotEmpty);
    expect(handleGestureFinder, findsNWidgets(2), reason: '两端应各有一个手柄');
    final startCenter = tester.getCenter(handleGestureFinder.first);
    debugPrint('[拖动] 手柄中心=$startCenter '
        '拖动前=[${delegateProbe?.getSelectedContent()?.plainText}]');
    final drag = await tester.startGesture(startCenter);
    await tester.pump();
    await drag.moveBy(const Offset(48, 0));
    await tester.pump();
    await drag.up();
    await tester.pump(const Duration(milliseconds: 300));
    final afterDrag = delegateProbe?.getSelectedContent()?.plainText;
    debugPrint('[拖动] 拖动后选区=[$afterDrag]');
    expect(afterDrag, isNotNull, reason: '拖动手柄应仍在选取模式内');
    expect(afterDrag!.length, lessThan(autoSelectResult!.length),
        reason: '向右拖动起点手柄应缩小选区');

    // 复制流程：onCopyDone 收尾 → 统一菜单与手柄都应消失
    await tester.tap(find.text('Copy'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Copy'), findsNothing, reason: '复制后选中菜单应消失');
    expect(find.byType(SelectionHandles), findsNothing,
        reason: '复制后拖拽手柄应消失');
  });
}
