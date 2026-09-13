import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coursehub/models/course.dart';
import 'package:coursehub/models/task.dart';
import 'package:coursehub/screens/ai_sessions_menu_panel.dart';
import 'package:coursehub/utils/storage.dart';

/// 删除确认"确认删除"后的完整数据流验证（独立文件 = 独立 isolate，
/// 不受其他测试的 Hive FileWriter 卡死状态污染）。
///
/// Hive 文件写入的 Future 依赖真实 IO，FakeAsync 区不完成：本用例
/// 在触发删除后经 runAsync 冲刷一次真实事件循环。仅此一次——
/// 第二次 fake 区写入 + runAsync 冲刷会永久卡死（FileWriter 队列
/// 的续延挂在已暂停的 fake 事件循环上），故本文件只放一个用例。
void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final tmp = await Directory.systemTemp.createTemp('sessions_delete_flow');
    Hive.init(tmp.path);
    if (!Hive.isAdapterRegistered(0)) Hive.registerAdapter(CourseAdapter());
    if (!Hive.isAdapterRegistered(1)) Hive.registerAdapter(TaskAdapter());
    await StorageService.init();
    final now = DateTime.now();
    await StorageService.saveChatSession({
      'id': 's1',
      'title': '会话一',
      'savedAt': now.subtract(const Duration(minutes: 5)).toIso8601String(),
      'messages': <Map<String, dynamic>>[],
    });
    await StorageService.saveChatSession({
      'id': 's2',
      'title': '会话二',
      'savedAt': now.toIso8601String(),
      'messages': <Map<String, dynamic>>[],
    });
  });

  testWidgets('确认删除后被删行淡出塌缩、下行上移补位、面板高度同步收缩', (tester) async {
    String? deletedId;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SavedSessionsMenuHost(
            animation: kAlwaysCompleteAnimation,
            currentSessionId: null,
            onDismiss: ([VoidCallback? then]) => then?.call(),
            onLoadSession: (_) {},
            onRenamed: (_, __) {},
            onDeleted: (id) => deletedId = id,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    // 面板高度 = 面板内 BackdropFilter 的渲染高度（host 内唯一：
    // 删除确认层已关闭，toast 挂在根 Overlay 不属于 host 子树）
    double panelHeight() => tester.getSize(find
            .descendant(
                of: find.byType(SavedSessionsMenuHost),
                matching: find.byType(BackdropFilter)))
        .height;

    // 2 个会话：2 * 64 + 16 = 144；首行为最新会话 s2（会话二）
    expect(panelHeight(), closeTo(144, 0.5));
    final secondRowTopBefore =
        tester.getTopLeft(find.text('会话一')).dy;

    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(find.widgetWithText(ElevatedButton, '删除'));
    await tester.pumpAndSettle();
    // 冲刷真实事件循环让 Hive 落盘 Future 完成
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.takeException(), isNull);
    expect(deletedId, 's2');

    // vanish 阶段中点（已播 ~110ms / 220ms）：被删行仍在树中向中心
    // 坍缩淡出，但占位高度不变——面板高度与下行位置均不动
    await tester.pump(const Duration(milliseconds: 94));
    expect(find.text('会话二'), findsOneWidget,
        reason: 'vanish 阶段被删行应保留在树中播放坍缩淡出');
    expect(panelHeight(), closeTo(144, 0.5),
        reason: 'vanish 阶段面板高度应保持不变');
    expect(tester.getTopLeft(find.text('会话一')).dy,
        closeTo(secondRowTopBefore, 0.5),
        reason: 'vanish 阶段下行位置应保持不变');

    // vanish 播完（~220ms）：行已不可见但占位仍在，高度仍未动
    await tester.pump(const Duration(milliseconds: 110));
    expect(find.text('会话二'), findsOneWidget,
        reason: 'collapse 开始前被删行占位应仍在树中');
    expect(panelHeight(), closeTo(144, 0.5),
        reason: 'collapse 开始前面板高度应保持不变');

    // collapse 阶段中点（~320ms = 220 + 100/200，easeOutCubic(0.5)≈0.875）：
    // 占位塌缩过半，面板高度收缩、下行上移补位
    await tester.pump(const Duration(milliseconds: 100));
    final midHeight = panelHeight();
    expect(midHeight, greaterThan(80), reason: 'collapse 中点面板高度应仍高于目标值');
    expect(midHeight, lessThan(144), reason: 'collapse 中点面板高度应低于起始值');
    final secondRowTopMid = tester.getTopLeft(find.text('会话一')).dy;
    expect(secondRowTopMid, lessThan(secondRowTopBefore - 20),
        reason: 'collapse 中点下行应已明显上移补位');
    expect(secondRowTopMid, greaterThan(secondRowTopBefore - 64),
        reason: 'collapse 中点下行上移量不得超过一行高度');

    // 退场播完：数据移除、面板收缩到 1 行高度
    await tester.pumpAndSettle();
    expect(find.text('会话二'), findsNothing, reason: '退场完成后被删行应移除');
    expect(find.text('会话一'), findsOneWidget, reason: '剩余会话应保留');
    expect(panelHeight(), closeTo(80, 0.5), reason: '退场后面板应为 1 行高度');
    // 泵完 toast 自动消失计时器（2s）与退场动画
    await tester.pump(const Duration(milliseconds: 2200));
    await tester.pumpAndSettle();
  });
}
