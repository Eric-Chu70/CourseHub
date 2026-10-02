import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// 直接问答：块级可选对象（表格 / display 公式的
/// _RenderSelectableBlock）在「已注册完成」之后，能否被区域委托的
/// 边缘事件选中？以及选中后 contextMenuAnchors 是否可用。
/// 单趟挂载，不做 GlobalKey 换父级，排除重建时序干扰。
import 'package:coursehub/widgets/selectable_block_adapter.dart';

void main() {
  testWidgets('块级可选对象：注册后整块选中', (tester) async {
    MultiSelectableSelectionContainerDelegate? delegate;
    SelectableRegionState? region;

    final tableKey = GlobalKey();

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SelectionArea(
          child: Builder(builder: (context) {
            delegate = SelectionContainer.maybeOf(context)
                as MultiSelectableSelectionContainerDelegate?;
            region ??= context.findAncestorStateOfType<SelectableRegionState>();
            return Column(
              children: [
                const Text('一段普通正文'),
                // 表格：App 同款「键 + 块适配器」
                SelectableBlockAdapter(
                  selectedText: 'A | B\n甲 | 乙',
                  child: Table(
                    key: tableKey,
                    defaultColumnWidth: const FixedColumnWidth(80),
                    border: TableBorder.all(width: 1, color: Colors.black),
                    children: const [
                      TableRow(children: [
                        Text('A', key: Key('a')),
                        Text('B', key: Key('b')),
                      ]),
                      TableRow(children: [
                        Text('甲'),
                        Text('乙'),
                      ]),
                    ],
                  ),
                ),
              ],
            );
          }),
        ),
      ),
    ));

    // 等注册（_additions 是帧后 flush）
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final blockFinder = find.byWidgetPredicate(
        (w) => '${w.runtimeType}'.contains('SelectableBlockAdapter'));
    expect(blockFinder, findsOneWidget);
    final blockBox =
        (tester.renderObject(blockFinder) as RenderBox?)!;
    final blockRect = blockBox.localToGlobal(Offset.zero) & blockBox.size;
    final d = delegate!;
    debugPrint('[直测] 委托=${delegate.runtimeType} '
        '可选对象=${d.selectables.map((s) => s.runtimeType).toList()}');

    // ① 现有算法：按「表格左上角那一行」派发首尾边缘
    final lineY = blockRect.top + 10;
    d.dispatchSelectionEvent(SelectionEdgeUpdateEvent.forStart(
        globalPosition: Offset(blockRect.left + 2, lineY)));
    d.dispatchSelectionEvent(SelectionEdgeUpdateEvent.forEnd(
        globalPosition: Offset(blockRect.right - 2, lineY)));
    await tester.pump();
    debugPrint('[直测] ①行内派发后 选区=[${d.getSelectedContent()?.plainText}] '
        '几何=${d.value.status} '
        '首点=${d.value.startSelectionPoint != null} '
        '末点=${d.value.endSelectionPoint != null}');
    final first = d.getSelectedContent()?.plainText;

    // ② 整块派发：左上→右下
    d.dispatchSelectionEvent(const ClearSelectionEvent());
    await tester.pump();
    d.dispatchSelectionEvent(SelectionEdgeUpdateEvent.forStart(
        globalPosition: blockRect.topLeft + const Offset(1, 1)));
    d.dispatchSelectionEvent(SelectionEdgeUpdateEvent.forEnd(
        globalPosition: blockRect.bottomRight - const Offset(1, 1)));
    await tester.pump();
    debugPrint('[直测] ②整块派发后 选区=[${d.getSelectedContent()?.plainText}] '
        '几何=${d.value.status}');
    final second = d.getSelectedContent()?.plainText;

    // ③ 菜单锚点在块选中态下是否可用
    String? anchorError;
    Offset? anchor;
    try {
      anchor = region!.contextMenuAnchors.primaryAnchor;
    } catch (e) {
      anchorError = '$e';
    }
    debugPrint('[直测] 菜单锚点=$anchor 异常=$anchorError');

    // ③ 同一行内、只差 1px 高度：验证「零高度矩形」是不是根因
    d.dispatchSelectionEvent(const ClearSelectionEvent());
    await tester.pump();
    d.dispatchSelectionEvent(SelectionEdgeUpdateEvent.forStart(
        globalPosition: Offset(blockRect.left + 2, lineY)));
    d.dispatchSelectionEvent(SelectionEdgeUpdateEvent.forEnd(
        globalPosition: Offset(blockRect.right - 2, lineY + 1)));
    await tester.pump();
    debugPrint('[直测] ③同线差1px 选区=[${d.getSelectedContent()?.plainText}] '
        '几何=${d.value.status}');
    final String? third = d.getSelectedContent()?.plainText;

    // ④ 只点在块内（首尾同点，模拟单行选中退化成零面积）
    d.dispatchSelectionEvent(const ClearSelectionEvent());
    await tester.pump();
    d.dispatchSelectionEvent(SelectionEdgeUpdateEvent.forStart(
        globalPosition: Offset(blockRect.left + 2, lineY)));
    d.dispatchSelectionEvent(SelectionEdgeUpdateEvent.forEnd(
        globalPosition: Offset(blockRect.left + 40, lineY)));
    await tester.pump();
    debugPrint('[直测] ④块内同线短距 选区=[${d.getSelectedContent()?.plainText}] '
        '几何=${d.value.status}');

    expect(first, isNotNull, reason: '①行内派发应能选中表格块');
    expect(second, isNotNull, reason: '②整块派发应能选中表格块');
    expect(third, isNotNull, reason: '③只差 1px 高度就能选中＝零高度矩形是根因');
    expect(anchorError, isNull, reason: '块选中态下菜单锚点应可计算');
  });
}
