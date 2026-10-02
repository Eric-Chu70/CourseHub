import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coursehub/services/glm_service.dart';
import 'package:coursehub/widgets/builtin_ai_usage_bar.dart';

/// 「今日用量」条在重建的第一帧不许闪回 0%。
///
/// 他 2026-10-02 报：AI 配置对话框里点开节点选择、进入另一个对话框的动画期间，
/// 原对话框这条会从 33% 先跳到 0% 再跳回来。原因是条上的数字取自
/// FutureBuilder，State 一旦被重建、future 还在 pending 就只能回退成 0。
/// 现在改成回退到 AIService 的同步缓存，而缓存按日期键存，跨天不会把
/// 昨天的数顶进今天。
String _todayKey() {
  final now = DateTime.now();
  return '${now.year}-${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';
}

/// 用量存储格式：{date, count}；10 / 30 次 = 33%
String _usageJson(String date, int count) =>
    jsonEncode({'date': date, 'count': count});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('首帧读到 33%，State 重建后的首帧仍是 33%（不闪 0%）',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'builtin_ai_daily_usage': _usageJson(_todayKey(), 10),
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: BuiltinAiUsageBar(inline: true)),
      ),
    );
    await tester.pump(); // 让第一次磁盘读落地
    expect(find.text('今日用量 33%'), findsOneWidget);

    // 换 key 重挂 = State 整个重建，等价于对话框切阶段动画里的那次重建。
    // 断言只看这一帧：future 还没回来，能显示 33% 只可能是走了同步缓存
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BuiltinAiUsageBar(key: UniqueKey(), inline: true),
        ),
      ),
    );
    expect(find.text('今日用量 0%'), findsNothing,
        reason: '重建的第一帧闪回了 0%，说明没吃到同步缓存');
    expect(find.text('今日用量 33%'), findsOneWidget);
  });

  test('缓存按日期键存：磁盘只有昨天的计数时，缓存记的是今天 0 而不是 10',
      () async {
    SharedPreferences.setMockInitialValues({
      'builtin_ai_daily_usage': _usageJson('2000-01-01', 10),
    });
    expect(await AIService.instance.builtinDailyUsageCount(), 0,
        reason: '跨天本地计数复位');
    expect(AIService.lastKnownBuiltinUsage, 0,
        reason: '同步缓存认领的是"今天 0 次"，昨天的 10 不该被带过来');
  });
}
