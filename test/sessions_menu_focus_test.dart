import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:coursehub/models/course.dart';
import 'package:coursehub/models/task.dart';
import 'package:coursehub/screens/ai_sessions_menu_panel.dart';
import 'package:coursehub/utils/storage.dart';
import 'package:coursehub/widgets/app_text_field.dart';

/// 复现会话面板重命名编辑流的焦点丢失问题：
/// 1) 进入编辑（无既有编辑态）
/// 2) 切换编辑对象（A 编辑中 → 打开 B 三点 → 重命名）
///
/// 跟踪三类证据：
/// - primaryFocus 变化轨迹（FocusManager 全局监听，输出到测试日志）
/// - 编辑框 FocusNode 在动画/延迟完成后是否仍持有焦点
/// - EditableText 的 Element 是否被销毁重建（重建会关闭键盘连接，
///   且新 State 拿到的节点仍持有焦点 → 永远不会重开连接）
void main() {
  setUpAll(() async {
    final tmp = await Directory.systemTemp.createTemp('sessions_menu_focus_test');
    Hive.init(tmp.path);
    if (!Hive.isAdapterRegistered(0)) Hive.registerAdapter(CourseAdapter());
    if (!Hive.isAdapterRegistered(1)) Hive.registerAdapter(TaskAdapter());
    await StorageService.init();
    final now = DateTime.now();
    await StorageService.saveChatSession({
      'id': 's1',
      'title': '会话一',
      'savedAt': now.subtract(const Duration(minutes: 1)).toIso8601String(),
      'messages': <Map<String, dynamic>>[],
    });
    await StorageService.saveChatSession({
      'id': 's2',
      'title': '会话二',
      'savedAt': now.toIso8601String(),
      'messages': <Map<String, dynamic>>[],
    });
  });

  testWidgets('进入编辑：焦点应稳定保持在编辑框上', (tester) async {
    final probe = _FocusProbe()..install();
    addTearDown(probe.uninstall);
    await _pumpPanel(tester);

    // 打开第一行的三点菜单 → 重命名
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();

    final node = tester.widget<AppTextField>(find.byType(AppTextField).first).focusNode!;
    expect(node.hasFocus, isTrue, reason: '进入编辑后编辑框应获得焦点');
    final firstEditable = tester.element(find.byType(EditableText).first);

    // 模拟用户停留：持续泵 1.5s，观察焦点/元素是否变化
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(node.hasFocus, isTrue, reason: '停留 1.5s 后焦点仍应在编辑框上');

    final lastEditable = tester.element(find.byType(EditableText).first);
    expect(
      identical(firstEditable, lastEditable),
      isTrue,
      reason: '进入编辑：EditableText 的 Element 被销毁重建了——旧 State dispose 会'
          '关闭键盘连接，而新 State 拿到的节点仍持有焦点，永远不会再打开连接'
          '（键盘消失且焦点守卫无感知）',
    );
  });

  testWidgets('切换编辑对象：A 编辑中切到 B，焦点应稳定保持在 B 编辑框上', (tester) async {
    final probe = _FocusProbe()..install();
    addTearDown(probe.uninstall);
    await _pumpPanel(tester);

    // 进入 A（第一行）的编辑态
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    final nodeA = tester.widget<AppTextField>(find.byType(AppTextField).first).focusNode!;
    expect(nodeA.hasFocus, isTrue, reason: 'A 进入编辑应获得焦点');

    // 编辑 A 的同时打开 B（第二行）的三点菜单 → 重命名
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();

    final nodeB = tester.widget<AppTextField>(find.byType(AppTextField).first).focusNode!;
    expect(identical(nodeA, nodeB), isFalse, reason: '切换后应使用新的编辑框节点');
    expect(nodeB.hasFocus, isTrue, reason: '切换到 B 后 B 编辑框应获得焦点');
    final firstEditable = tester.element(find.byType(EditableText).first);

    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(nodeB.hasFocus, isTrue, reason: '停留 1.5s 后 B 编辑框焦点应保持');

    final lastEditable = tester.element(find.byType(EditableText).first);
    expect(
      identical(firstEditable, lastEditable),
      isTrue,
      reason: '切换编辑：EditableText 的 Element 被销毁重建了——旧 State dispose 会'
          '关闭键盘连接，而新 State 拿到的节点仍持有焦点，永远不会再打开连接'
          '（键盘消失且焦点守卫无感知）',
    );
  });

  testWidgets('面板入场收尾不得销毁编辑框：入场动画运行中进入编辑，'
      '跨越 t=1 后 EditableText 元素必须原样存活', (tester) async {
    _FocusProbe()..install();
    // 真实入场动画（480ms 强过冲曲线）：打开面板后立即进入编辑，
    // 使编辑态跨越入场收尾（旧实现在 t>=1 时把面板从 Transform 包裹
    // 切回裸子树，整个面板连同持焦编辑框被销毁重建 → 键盘闪没）
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: _PanelHarness())),
    );
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('重命名'));
    await tester.pump(const Duration(milliseconds: 100));

    final node = tester.widget<AppTextField>(find.byType(AppTextField).first).focusNode!;
    final firstEditable = tester.element(find.byType(EditableText).first);

    // 泵过入场收尾（t 越过 1.0 的时刻）
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    final lastEditable = tester.element(find.byType(EditableText).first);
    expect(
      identical(firstEditable, lastEditable),
      isTrue,
      reason: '入场收尾时面板子树被销毁重建——若编辑框连接已打开，'
          'dispose 会 clearClient 收掉键盘，新 State 继承焦点却不再重开'
          '（首次进入编辑键盘闪现的根因）',
    );
    expect(node.hasFocus, isTrue, reason: '跨越入场收尾后焦点应保持在编辑框上');
  });
}

/// 面板宿主：持真实入场动画（与 _showSavedSessionsMenu 同参数）
class _PanelHarness extends StatefulWidget {
  @override
  State<_PanelHarness> createState() => _PanelHarnessState();
}

class _PanelHarnessState extends State<_PanelHarness>
    with SingleTickerProviderStateMixin {
  late final controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 480),
    reverseDuration: const Duration(milliseconds: 260),
  );
  late final curved = CurvedAnimation(
    parent: controller,
    curve: const Cubic(0.175, 0.885, 0.32, 1.35),
    reverseCurve: Curves.easeInCubic,
  );

  @override
  void initState() {
    super.initState();
    controller.forward();
  }

  @override
  void dispose() {
    curved.dispose();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SavedSessionsMenuHost(
      animation: curved,
      currentSessionId: null,
      onDismiss: ([VoidCallback? then]) => then?.call(),
      onLoadSession: (_) {},
      onRenamed: (_, __) {},
      onDeleted: (_) {},
    );
  }
}

Future<void> _pumpPanel(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SavedSessionsMenuHost(
          animation: kAlwaysCompleteAnimation,
          currentSessionId: null,
          onDismiss: ([VoidCallback? then]) => then?.call(),
          onLoadSession: (_) {},
          onRenamed: (_, __) {},
          onDeleted: (_) {},
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
}

/// 记录 primaryFocus 变化轨迹（输出到测试日志，用于定位抢焦来源）
class _FocusProbe {
  VoidCallback? _remove;

  void install() {
    void onChange() {
      final primary = FocusManager.instance.primaryFocus;
      debugPrint(
        '[focus-probe] primary → ${primary?.debugLabel ?? primary?.runtimeType ?? 'null'}',
      );
    }

    FocusManager.instance.addListener(onChange);
    _remove = () => FocusManager.instance.removeListener(onChange);
  }

  void uninstall() => _remove?.call();
}
