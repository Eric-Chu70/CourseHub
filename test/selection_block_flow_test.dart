import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// 表格 / display 公式处「选取文字」的端到端回归：复刻 App 的真实链路——
/// 正文先以普通形态挂载 → 双击/菜单进入选取模式时给正文换父级包上
/// SelectionArea（GlobalKey 保序重挂载）→ 帧后按按住点定位行并向区域委托
/// 派发首/尾边缘事件 → 检查选区内容与浮层收尾。
/// 覆盖三个历史缺陷：
/// ① 块级可选对象在「首尾同一个 y」的派发下判为不相交，表格/公式选不中；
/// ② 一次失败的进入把消息卡在「已包 SelectionArea 却无选区」的空转态；
/// ③ 反复进入退出后残留选区/浮层叠加。
import 'package:coursehub/widgets/selectable_block_adapter.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

class _LineTarget {
  const _LineTarget(this.start, this.end, this.distance);
  final Offset start;
  final Offset end;
  final double distance;
}

_LineTarget? _nearestLineInParagraph(
    RenderParagraph paragraph, Offset pressGlobal) {
  if (!paragraph.hasSize || paragraph.text.toPlainText().trim().isEmpty) {
    return null;
  }
  final Size pSize = paragraph.size;
  final Offset local = paragraph.globalToLocal(pressGlobal);
  final double dx = local.dx.clamp(0.0, pSize.width);
  final double dy = local.dy.clamp(0.0, pSize.height);

  TextBox? charBoxAt(int offset) {
    final int length = paragraph.text.toPlainText().length;
    if (length == 0) return null;
    final int index = offset.clamp(0, length - 1);
    final boxes = paragraph.getBoxesForSelection(
        TextSelection(baseOffset: index, extentOffset: index + 1));
    return boxes.isEmpty ? null : boxes.first;
  }

  final probeBox =
      charBoxAt(paragraph.getPositionForOffset(Offset(dx, dy)).offset);
  if (probeBox == null) return null;
  final double centerY = (probeBox.top + probeBox.bottom) / 2;
  final startBox =
      charBoxAt(paragraph.getPositionForOffset(Offset(0, centerY)).offset);
  final endBox = charBoxAt(
      paragraph.getPositionForOffset(Offset(pSize.width, centerY)).offset);
  if (startBox == null || endBox == null) return null;

  final double distance;
  if (local.dy < probeBox.top) {
    distance = probeBox.top - local.dy;
  } else if (local.dy > probeBox.bottom) {
    distance = local.dy - probeBox.bottom;
  } else {
    distance = 0;
  }
  return _LineTarget(
      paragraph.localToGlobal(Offset(startBox.left + 2, centerY)),
      paragraph.localToGlobal(Offset(endBox.right - 2, centerY)),
      distance);
}

/// 进入选取模式的返回值：选区文本 + 是否走到「定位不到就退出」的兜底
class _SelectOutcome {
  _SelectOutcome({
    required this.selectedText,
    required this.targetFound,
    required this.exitedWithoutSelection,
  });
  final String? selectedText;
  final bool targetFound;
  final bool exitedWithoutSelection;
}

/// 宿主：defaultMode 时正文裸挂，selecting 时包一层 SelectionArea
/// （GlobalKey 让子树换父级重挂载，与 App 一致）
class _Host extends StatefulWidget {
  const _Host({
    required this.markdown,
    required this.bodyKey,
    required this.onOutcome,
    required this.onExitRequest,
  });
  final String markdown;
  final GlobalKey bodyKey;
  final ValueChanged<_SelectOutcome> onOutcome;
  final VoidCallback onExitRequest;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  bool _selecting = false;
  Offset? _press;

  void enterSelect(Offset press) {
    setState(() {
      _selecting = true;
      _press = press;
    });
  }

  void exitSelect() {
    if (!_selecting) return;
    setState(() {
      _selecting = false;
      _press = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final Widget body = KeyedSubtree(
      key: widget.bodyKey,
      child: _markdown(widget.markdown),
    );
    return SingleChildScrollView(
      child: _selecting
          ? _SelectContainer(
              pressPosition: _press!,
              onOutcome: widget.onOutcome,
              onExitRequest: widget.onExitRequest,
              child: body,
            )
          : body,
    );
  }
}

/// 复刻 _MessageSelectionArea 的派发与兜底（含定位不到即退出）
class _SelectContainer extends StatefulWidget {
  const _SelectContainer({
    required this.pressPosition,
    required this.onOutcome,
    required this.onExitRequest,
    required this.child,
  });
  final Offset pressPosition;
  final ValueChanged<_SelectOutcome> onOutcome;
  final VoidCallback onExitRequest;
  final Widget child;

  @override
  State<_SelectContainer> createState() => _SelectContainerState();
}

class _SelectContainerState extends State<_SelectContainer> {
  MultiSelectableSelectionContainerDelegate? _delegate;
  bool _exited = false;

  void _exit() {
    if (_exited || !mounted) return;
    _exited = true;
    try {
      _delegate?.dispatchSelectionEvent(const ClearSelectionEvent());
    } catch (_) {}
    widget.onExitRequest();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoSelectLine());
  }

  void _autoSelectLine() {
    final rootObject = context.findRenderObject();
    if (rootObject is! RenderBox || !rootObject.hasSize) {
      _exit();
      return;
    }
    _LineTarget? best;
    void visit(RenderObject object) {
      if (object is RenderParagraph) {
        final candidate = _nearestLineInParagraph(object, widget.pressPosition);
        if (candidate != null &&
            (best == null || candidate.distance < best!.distance)) {
          best = candidate;
        }
        return;
      }
      object.visitChildren(visit);
    }

    visit(rootObject);
    final delegate = _delegate;
    if (best == null || delegate == null) {
      widget.onOutcome(_SelectOutcome(
        selectedText: null,
        targetFound: false,
        exitedWithoutSelection: true,
      ));
      // App 的兜底：定位不到不能把消息留在选取模式里
      _exit();
      return;
    }
    delegate.dispatchSelectionEvent(
        SelectionEdgeUpdateEvent.forStart(globalPosition: best!.start));
    delegate.dispatchSelectionEvent(
        SelectionEdgeUpdateEvent.forEnd(globalPosition: best!.end));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onOutcome(_SelectOutcome(
        selectedText: delegate.getSelectedContent()?.plainText,
        targetFound: true,
        exitedWithoutSelection: false,
      ));
    });
  }

  @override
  Widget build(BuildContext context) {
    return SelectionArea(
      child: Builder(builder: (context) {
        _delegate ??= SelectionContainer.maybeOf(context)
            as MultiSelectableSelectionContainerDelegate?;
        return widget.child;
      }),
    );
  }
}

/// App 的 tableBuilder / latexBuilder 同款结构
Widget _markdown(String content) {
  return GptMarkdown(
    content,
    style: const TextStyle(fontSize: 14, height: 1.5),
    useDollarSignsForLatex: true,
    tableBuilder: (context, rows, textStyle, config) {
      final tableText = rows
          .map((row) => row.fields.map((f) => f.data.trim()).join(' | '))
          .join('\n');
      return SelectableBlockAdapter(
        selectedText: tableText,
        child: Table(
          defaultColumnWidth: const FixedColumnWidth(70),
          border: TableBorder.all(width: 1, color: Colors.black),
          children: rows
              .map((row) => TableRow(
                    children: row.fields
                        .map((field) => Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              child: MdWidget(context, field.data, false,
                                  config: config),
                            ))
                        .toList(),
                  ))
              .toList(),
        ),
      );
    },
    latexBuilder: (context, tex, textStyle, inline) {
      if (inline) {
        return Math.tex(tex,
            textStyle: textStyle,
            mathStyle: MathStyle.text,
            textScaleFactor: 1,
            settings: const TexParserSettings(strict: Strict.ignore));
      }
      return SelectableBlockAdapter(
        selectedText: tex,
        child: Math.tex(tex,
            textStyle: textStyle,
            mathStyle: MathStyle.display,
            textScaleFactor: 1,
            settings: const TexParserSettings(strict: Strict.ignore)),
      );
    },
  );
}

void main() {
  testWidgets('表格处双击：整块选中并复制出表格文本', (tester) async {
    final bodyKey = GlobalKey();
    _SelectOutcome? outcome;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: _Host(
          bodyKey: bodyKey,
          markdown: '| 课程 | 时间 |\n|---|---|\n| 高数 | 周一 |\n',
          onOutcome: (o) => outcome = o,
          onExitRequest: () {},
        ),
      ),
    ));
    await tester.pump();

    final press = tester.getCenter(find.byType(Table));
    tester
        .state<_HostState>(find.byType(_Host))
        .enterSelect(press);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    debugPrint('[表格] 定位行=${outcome?.targetFound} '
        '选区=[${outcome?.selectedText}]');
    expect(outcome, isNotNull);
    expect(outcome!.targetFound, isTrue);
    expect(outcome!.selectedText, contains('高数'));
    expect(outcome!.selectedText, contains('周一'));
  });

  testWidgets('display 公式处双击：整块选中并复制出 LaTeX 源码', (tester) async {
    final bodyKey = GlobalKey();
    _SelectOutcome? outcome;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: _Host(
          bodyKey: bodyKey,
          markdown: '\$\$\n\\int_0^1 x^2 dx\n\$\$\n',
          onOutcome: (o) => outcome = o,
          onExitRequest: () {},
        ),
      ),
    ));
    await tester.pump();

    final press = tester.getCenter(find.byType(Math));
    tester.state<_HostState>(find.byType(_Host)).enterSelect(press);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    debugPrint('[公式] 定位行=${outcome?.targetFound} '
        '选区=[${outcome?.selectedText}]');
    expect(outcome, isNotNull);
    expect(outcome!.targetFound, isTrue);
    expect(outcome!.selectedText, contains('\\int'));
  });

  testWidgets('普通正文行：逐行选中（对照组）', (tester) async {
    final bodyKey = GlobalKey();
    _SelectOutcome? outcome;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: _Host(
          bodyKey: bodyKey,
          markdown: '这是一段普通文字内容用来做对照组',
          onOutcome: (o) => outcome = o,
          onExitRequest: () {},
        ),
      ),
    ));
    await tester.pump();

    final press = tester.getCenter(find.byType(RichText).first);
    tester.state<_HostState>(find.byType(_Host)).enterSelect(press);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(outcome!.targetFound, isTrue);
    expect(outcome!.selectedText, contains('普通文字'));
  });

  testWidgets('反复进入退出 5 次：不残留选区', (tester) async {
    final bodyKey = GlobalKey();
    final outcomes = <_SelectOutcome>[];
    _HostState? host;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: _Host(
          bodyKey: bodyKey,
          markdown: '| 甲 | 乙 |\n|---|---|\n| 丙 | 丁 |\n',
          onOutcome: (o) => outcomes.add(o),
          onExitRequest: () => host?.exitSelect(),
        ),
      ),
    ));
    await tester.pump();
    host = tester.state<_HostState>(find.byType(_Host));
    final press = tester.getCenter(find.byType(Table));

    for (int i = 0; i < 5; i++) {
      host.enterSelect(press + Offset(0, i.toDouble()));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      host.exitSelect();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    final stale = outcomes
        .where((o) => o.selectedText == null && o.targetFound)
        .toList();
    debugPrint('[反复] 次数=${outcomes.length} 空转态=${stale.length}');
    expect(outcomes.length, 5, reason: '五次进入都应产生一次结果');
    expect(stale, isEmpty, reason: '不应有「派发后仍无选区」的空转进入');
    // 退出后正文不应再被 SelectionArea 包着
    expect(find.byType(SelectionArea), findsNothing);
  });
}
