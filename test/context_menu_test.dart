import 'package:coursehub/widgets/app_text_field.dart';
import 'package:coursehub/widgets/blur_selection_menu.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 输入框上下文菜单回归测试：
/// 1. 空输入框长按应呼出玻璃菜单显示「粘贴」（剪贴板有内容时）
/// 2. 剪贴板状态异步就绪（真机平台调用延迟）时菜单应自行重建补上粘贴
/// 3. 选中文字时菜单默认展示「复制、剪切、全选」，分享等其余按钮后置
/// 4. AppTextField 默认菜单即玻璃菜单
/// 5. 点击空白收起时，退场动画播放的是展示时的那批按钮（内容冻结）
/// 6. hasStrings 恒 false 的 ROM（MIUI 剪贴板限制）上仍提供可用的粘贴
///
/// debugDefaultTargetPlatformOverride 必须在测试体内复位：flutter_test 的
/// 基础变量校验先于 package:test 的 tearDown 执行。

const Duration _kPlatformClipboardDelay = Duration(milliseconds: 50);

void _mockClipboard(String text, {Duration delay = Duration.zero}) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (MethodCall call) async {
    if (call.method == 'Clipboard.getData') {
      return <String, dynamic>{'text': text};
    }
    if (call.method == 'Clipboard.hasStrings') {
      if (delay > Duration.zero) {
        await Future<void>.delayed(delay);
      }
      return <String, dynamic>{'value': text.isNotEmpty};
    }
    return null;
  });
}

Future<void> _pumpField(
  WidgetTester tester,
  TextEditingController controller, {
  bool focusFirst = false,
  bool useDefaultMenu = false,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Center(
        // useDefaultMenu：完全不传 contextMenuBuilder，验证 AppTextField
        // 构造函数默认值即为玻璃菜单
        child: useDefaultMenu
            ? AppTextField(controller: controller)
            : AppTextField(
                controller: controller,
                contextMenuBuilder: styledEditableContextMenu,
              ),
      ),
    ),
  ));
  if (focusFirst) {
    await tester.tap(find.byType(AppTextField));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }
}

Future<void> _longPress(WidgetTester tester, {bool onText = false}) async {
  // onText 时按在文字上（触发 Android 长按选词），否则按输入框中央
  final Rect field = tester.getRect(find.byType(AppTextField));
  final Offset position =
      onText ? field.topLeft + Offset(30, field.height / 2) : field.center;
  final TestGesture gesture = await tester.startGesture(position);
  await tester.pump(const Duration(milliseconds: 600));
  await gesture.up();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Finder _styledMenuButtons() {
  return find.descendant(
    of: find.byWidgetPredicate((w) => w is BackdropFilter),
    matching: find.byType(TextButton),
  );
}

void main() {
  void androidMenuTest(String description, Future<void> Function(WidgetTester) body) {
    testWidgets(description, (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await body(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  androidMenuTest('空输入框长按呼出菜单显示粘贴（聚焦态）', (tester) async {
    _mockClipboard('mock content');
    final controller = TextEditingController();
    await _pumpField(tester, controller, focusFirst: true);
    await _longPress(tester);
    expect(find.descendant(of: _styledMenuButtons(), matching: find.text('Paste')),
        findsOneWidget);
  });

  androidMenuTest('空输入框长按呼出菜单显示粘贴（未聚焦态）', (tester) async {
    _mockClipboard('mock content');
    final controller = TextEditingController();
    await _pumpField(tester, controller);
    await _longPress(tester);
    expect(find.descendant(of: _styledMenuButtons(), matching: find.text('Paste')),
        findsOneWidget);
  });

  androidMenuTest('剪贴板状态延迟就绪时菜单自愈补上粘贴按钮', (tester) async {
    _mockClipboard('mock content', delay: _kPlatformClipboardDelay);
    final controller = TextEditingController();
    await _pumpField(tester, controller, focusFirst: true);
    final Rect field = tester.getRect(find.byType(AppTextField));
    final TestGesture gesture = await tester.startGesture(field.center);
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.up();
    // 只推进一帧：剪贴板查询尚未完成，菜单此时拿不到粘贴按钮
    await tester.pump();
    // 推进超过平台延迟：剪贴板状态就绪，菜单须自行重建出粘贴按钮
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.descendant(of: _styledMenuButtons(), matching: find.text('Paste')),
        findsOneWidget);
  });

  androidMenuTest('AppTextField 默认菜单即玻璃菜单', (tester) async {
    _mockClipboard('mock content');
    final controller = TextEditingController();
    await _pumpField(tester, controller, focusFirst: true, useDefaultMenu: true);
    await _longPress(tester);
    expect(find.descendant(of: _styledMenuButtons(), matching: find.text('Paste')),
        findsOneWidget);
  });

  androidMenuTest('选中文字默认展示 复制/剪切/全选，分享后置', (tester) async {
    _mockClipboard('mock content');
    final controller = TextEditingController(text: 'hello world');
    await _pumpField(tester, controller, focusFirst: true);
    await _longPress(tester, onText: true);

    final List<Text> labels = tester
        .widgetList<Text>(
            find.descendant(of: _styledMenuButtons(), matching: find.byType(Text)))
        .toList();
    expect(labels, isNotEmpty);
    expect(labels.first.data, 'Copy');
    expect(labels[1].data, 'Cut');
    expect(labels[2].data, 'Select all');
    // 分享不在默认展示的前三项中，仍在菜单里靠滑动可见
    expect(labels.take(3).map((t) => t.data), isNot(contains('Share')));
    expect(labels.map((t) => t.data), contains('Share'));
  });

  androidMenuTest('点击空白收起时退场动画内容冻结不抽换', (tester) async {
    _mockClipboard('mock content');
    final controller = TextEditingController(text: 'hello world');
    await _pumpField(tester, controller, focusFirst: true);
    await _longPress(tester, onText: true);
    // _longPress 末帧菜单才挂载，弹出动画尚未播完；推满 220ms 使其到位
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.descendant(of: _styledMenuButtons(), matching: find.text('Copy')),
        findsOneWidget);

    // 点击输入框内空白处（文字后方）：选区折叠，菜单收起
    final Rect field = tester.getRect(find.byType(AppTextField));
    await tester.tapAt(field.centerRight + const Offset(-10, 0));
    await tester.pump();
    // 收起动画（220ms）中段：卡片仍在缩回，按钮必须是展示时的那批——
    // 若此时活取 SDK 按钮列表，折叠选区只剩「粘贴/全选」，内容被抽换
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.descendant(of: _styledMenuButtons(), matching: find.text('Copy')),
        findsOneWidget);
    expect(find.descendant(of: _styledMenuButtons(), matching: find.text('Cut')),
        findsOneWidget);
    expect(find.descendant(of: _styledMenuButtons(), matching: find.text('Select all')),
        findsOneWidget);
    // 动画播完 entry 摘除
    await tester.pump(const Duration(milliseconds: 400));
    expect(_styledMenuButtons(), findsNothing);
  });

  androidMenuTest('hasStrings 恒 false 的 ROM 上仍提供可用的粘贴按钮', (tester) async {
    // 模拟 MIUI 等 ROM 的剪贴板隐私限制：hasStrings 永远 false
    // （SDK 状态恒 notPasteable，不给粘贴按钮），但 getData 能读到内容
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (MethodCall call) async {
      if (call.method == 'Clipboard.getData') {
        return <String, dynamic>{'text': 'pasted text'};
      }
      if (call.method == 'Clipboard.hasStrings') {
        return <String, dynamic>{'value': false};
      }
      return null;
    });
    final controller = TextEditingController();
    await _pumpField(tester, controller, focusFirst: true);
    await _longPress(tester);
    // 菜单弹出时会主动刷新一次剪贴板状态，刷新后依然没有 SDK 粘贴按钮，
    // 此时须由乐观粘贴兜底
    await tester.pump(const Duration(milliseconds: 300));
    final Finder paste =
        find.descendant(of: _styledMenuButtons(), matching: find.text('Paste'));
    expect(paste, findsOneWidget);

    await tester.tap(paste);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.text, 'pasted text');
  });
}
