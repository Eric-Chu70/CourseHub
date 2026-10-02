import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coursehub/config/ai_feature_flags.dart';
import 'package:coursehub/models/task.dart';
import 'package:coursehub/widgets/ddl_ai_insight_card.dart';

void main() {
  // 支撑两个 bug 的承重性质：setter 必须在 await 之前就更新同步缓存，
  // 否则待办页间距（父页 build 时算）和卡片定相（同帧挂载时算）会错开一帧。
  test('setTaskEnabled updates the sync cache before the disk write awaits',
      () async {
    SharedPreferences.setMockInitialValues({});
    expect(AIAutoAnalysisFlags.taskEnabled, isTrue);

    final future = AIAutoAnalysisFlags.setTaskEnabled(false);
    expect(AIAutoAnalysisFlags.taskEnabled, isFalse,
        reason: '缓存必须同步翻转，不能等 prefs 落盘');
    await future;
    expect(AIAutoAnalysisFlags.taskEnabled, isFalse);

    await AIAutoAnalysisFlags.refresh();
    expect(AIAutoAnalysisFlags.taskEnabled, isFalse,
        reason: 'refresh 后磁盘值与缓存一致');
  });

  // Bug 1：关闭自动任务分析时，每次进入待办页都会播一遍折叠动画。
  // 根因是卡片首帧先渲染 idle 骨架、随后才收起 —— 首帧就必须是空的。
  testWidgets('off + no result renders nothing on the very first frame',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'ai_enabled': true,
      'ai_provider': 'agnes',
      AIAutoAnalysisFlags.taskKey: false,
    });
    await AIAutoAnalysisFlags.refresh();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DDLAIInsightCard(
            autoAnalysis: AIAutoAnalysisFlags.taskEnabled,
            tasks: [
              Task(
                id: 't1',
                courseId: 'c1',
                name: '高数作业',
                dueDate: DateTime.now().add(const Duration(days: 1)),
              ),
            ],
          ),
        ),
      ),
    );
    // 量 pumpWidget 自己画出的那一帧：不能再 await pump()，
    // 否则会让 _loadConfigAndAnalyze 的 prefs await 先完成、setState 补上
    // 第二帧，两种实现就都量到 0，测试变假阴性
    final box =
        tester.renderObject<RenderBox>(find.byType(DDLAIInsightCard));
    expect(box.size.height, 0,
        reason: '首帧高度必须为 0，否则 AnimatedSize 会播一遍收起动画');
    expect(DDLAIInsightCard.hasResult, isFalse);
    expect(DDLAIInsightCard.isDismissedThisRun, isFalse);
  });

  // 首次配置的默认值随提供商而变：内置节点花的是应用出的公共额度，
  // 默认关掉两个自动分析；用户自己填 key 的默认开启。
  group('applyFirstRunDefaults', () {
    test('builtin on first run turns both off', () async {
      SharedPreferences.setMockInitialValues({'flutter.ai_enabled': true});
      await AIAutoAnalysisFlags.refresh();
      expect(AIAutoAnalysisFlags.taskEnabled, isTrue); // 未写过 → 默认开

      await AIAutoAnalysisFlags.applyFirstRunDefaults(builtin: true);
      expect(AIAutoAnalysisFlags.taskEnabled, isFalse);
      expect(AIAutoAnalysisFlags.scheduleEnabled, isFalse);

      // 落盘了，重启后仍是关
      await AIAutoAnalysisFlags.refresh();
      expect(AIAutoAnalysisFlags.taskEnabled, isFalse);
      expect(AIAutoAnalysisFlags.scheduleEnabled, isFalse);
    });

    test('own api key on first run keeps both on', () async {
      SharedPreferences.setMockInitialValues({'flutter.ai_enabled': true});
      await AIAutoAnalysisFlags.applyFirstRunDefaults(builtin: false);
      expect(AIAutoAnalysisFlags.taskEnabled, isTrue);
      expect(AIAutoAnalysisFlags.scheduleEnabled, isTrue);
    });

    test('never overwrites a choice the user already made', () async {
      SharedPreferences.setMockInitialValues({
        'flutter.ai_auto_task_analysis': true,
        'flutter.ai_auto_schedule_analysis': true,
      });
      await AIAutoAnalysisFlags.refresh();
      await AIAutoAnalysisFlags.applyFirstRunDefaults(builtin: true);
      expect(AIAutoAnalysisFlags.taskEnabled, isTrue,
          reason: '已经写过就不再替用户改成内置默认');
      expect(AIAutoAnalysisFlags.scheduleEnabled, isTrue);
    });
  });
}
