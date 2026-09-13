import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coursehub/models/course.dart';
import 'package:coursehub/models/task.dart';
import 'package:coursehub/screens/ai_sessions_menu_panel.dart';
import 'package:coursehub/utils/storage.dart';

/// 复现会话面板删除确认死机（UI 流层面）：
/// 打开面板 → 三点菜单 → 删除 → 确认对话框弹出。
///
/// 死机根因：旧实现给 BouncyDialogHost 传了带过冲的 CurvedAnimation
/// （easeOutBack），而 BouncyDialogHost 约定接收线性 0→1 动画（与
/// showBouncyDialog 的路由动画一致）、曲线由内部自行应用——过冲值
/// t>1 进入内部 Curve.transform 触发断言风暴，打开动画期间每帧构建
/// 失败，全屏 OverlayEntry 变 ErrorWidget 吞掉所有点击（表现为死机）。
///
/// 注意：本文件不验证"确认删除后数据落盘"——Hive 文件写入的 Future
/// 在 FakeAsync 区不完成，且经 runAsync 冲刷一次后 FileWriter 队列
/// 会卡死并污染后续用例；落盘验证见 sessions_menu_delete_flow_test。
void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final tmp = await Directory.systemTemp.createTemp('sessions_delete_test');
    Hive.init(tmp.path);
    if (!Hive.isAdapterRegistered(0)) Hive.registerAdapter(CourseAdapter());
    if (!Hive.isAdapterRegistered(1)) Hive.registerAdapter(TaskAdapter());
    await StorageService.init();
    final now = DateTime.now();
    for (var i = 1; i <= 4; i++) {
      await StorageService.saveChatSession({
        'id': 's$i',
        'title': '会话${["一", "二", "三", "四"][i - 1]}',
        'savedAt': now.subtract(Duration(minutes: 10 - i)).toIso8601String(),
        'messages': <Map<String, dynamic>>[],
      });
    }
  });

  Future<void> pumpPanel(WidgetTester tester) async {
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

  testWidgets('删除确认对话框弹出后应能正常收敛', (tester) async {
    await pumpPanel(tester);

    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('删除'));
    await tester.pump(const Duration(milliseconds: 50));

    // 打开动画期间不应抛出任何构建异常（死机根因）
    final exceptionDuringOpen = tester.takeException();
    expect(exceptionDuringOpen, isNull,
        reason: '打开动画期间不应有构建异常');

    expect(find.text('删除会话'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('删除会话'), findsOneWidget,
        reason: '动画结束后对话框应稳定显示（不得持续调度帧）');
  });

  testWidgets('点击取消后对话框收起且可再次打开', (tester) async {
    await pumpPanel(tester);

    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('删除会话'), findsNothing);

    // 再次打开：控制器应可正常复用，无 use-after-dispose
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('删除会话'), findsOneWidget);
  });

  testWidgets('收起动画期间连点删除按钮不得二次 dispose 控制器', (tester) async {
    await pumpPanel(tester);

    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // 连点两次删除按钮：第二次应被收起中标志挡住，收尾不得对已
    // dispose 的控制器二次操作（旧实现双回调二次 dispose 会抛异常）
    final button = find.widgetWithText(ElevatedButton, '删除');
    await tester.tap(button);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(button, warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull,
        reason: '收起期间重复触发不得对已 dispose 的控制器再次操作');
    expect(find.text('删除会话'), findsNothing,
        reason: '收起动画播完后对话框应移除');
  });
}
