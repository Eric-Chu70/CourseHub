import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 进/出「选取文字」时表格边缘淡出遮罩闪一下的回归：块适配器在两种
/// 形态下必须返回同一种 widget 形状，否则 FadingEdgeBox 会被销毁重建。
///
/// App 的真实形态：正文外面平时没有 SelectionArea，进入选取模式时才包上
/// （靠 KeyedSubtree 的全球键把正文子树重挂载保住滚动位置）。此时
/// SelectableBlockAdapter.build 的返回值从「直接 child」变成
/// 「MouseRegion(_SelectableBlockRender(child))」——同一位置的子 widget
/// 类型换了，框架只能销毁重建那条子树，里面的 FadingEdgeBox 一起重建，
/// 它的 _fade 回到初始 (false,false)：第一帧完全没有淡出，帧后
/// _updateFade 才把遮罩放回来＝闪一下。
///
/// 自检：每次切换都断言 SelectionArea 的有无与 FadingEdgeBox 上方的
/// MouseRegion 祖先确实变了，避免探针本身空转（widget 换了但没触发重建
/// 的话，identical 当然还是 true，那是假通过）。
import 'package:coursehub/widgets/fading_edge_list.dart';
import 'package:coursehub/widgets/selectable_block_adapter.dart';

void main() {
  testWidgets('进/出选取模式不应重建表格的 FadingEdgeBox State', (tester) async {
    bool selecting = false;
    late void Function(void Function()) setOuter;
    final bodyKey = GlobalKey();
    final fadeFinder = find.byType(FadingEdgeBox);

        // 选择区域在不在，用块适配器上方有没有 SelectionContainer 来判：
    // 块适配器现在两种形态都包 MouseRegion（形状必须恒定），不能再拿它
    // 当「是否处于选取模式」的凭据。
    bool hasSelectionContainer() => tester
        .element(find.byType(SelectableBlockAdapter))
        .findAncestorWidgetOfExactType<SelectionContainer>() != null;

    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(builder: (context, setState) {
        setOuter = setState;
        final Widget body = KeyedSubtree(
          key: bodyKey,
          child: const SelectableBlockAdapter(
            selectedText: 'x',
            child: SizedBox(
              width: 1000,
              height: 60,
              child: FadingEdgeBox(
                child: Row(children: [Text('甲'), Text('乙')]),
              ),
            ),
          ),
        );
        return Scaffold(
          body: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: selecting ? SelectionArea(child: body) : body,
          ),
        );
      }),
    ));
    for (int i = 0; i < 3; i++) {
      await tester.pump();
    }
    final State before = tester.state(fadeFinder);
    expect(tester.any(find.byType(SelectionArea)), isFalse);
    expect(hasSelectionContainer(), isFalse, reason: '自检：平时没有选择区域');
    debugPrint('[遮罩] 平时 SelectionArea=false');

    void toggle(bool value) {
      setOuter(() => selecting = value);
    }

    toggle(true);
    for (int i = 0; i < 3; i++) {
      await tester.pump();
    }
    final State enter = tester.state(fadeFinder);
    expect(tester.any(find.byType(SelectionArea)), isTrue);
    expect(hasSelectionContainer(), isTrue, reason: '自检：进入后已有选择区域');
    debugPrint('[遮罩] 进入后 SelectionArea=true '
        '同实例=${identical(before, enter)}');

    toggle(false);
    for (int i = 0; i < 3; i++) {
      await tester.pump();
    }
    final State exit = tester.state(fadeFinder);
    expect(tester.any(find.byType(SelectionArea)), isFalse);
    expect(hasSelectionContainer(), isFalse);
    debugPrint('[遮罩] 退出后 SelectionArea=false '
        '同实例=${identical(before, exit)}');

    expect(identical(before, enter), isTrue,
        reason: '进入选取模式重建了 FadingEdgeBox＝_fade 归零，遮罩会闪一下');
    expect(identical(before, exit), isTrue,
        reason: '退出选取模式同样不该重建');
  });
}
