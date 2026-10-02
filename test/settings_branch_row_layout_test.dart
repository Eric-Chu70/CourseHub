import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coursehub/models/course.dart';
import 'package:coursehub/models/task.dart';
import 'package:coursehub/screens/settings_screen.dart';
import 'package:coursehub/services/auth_service.dart';
import 'package:coursehub/theme/theme_controller.dart';
import 'package:coursehub/utils/storage.dart';

/// 设置页「分支子项行」的几何回归：圈过的三个子选项（课前通知时间 /
/// 提前提醒时间 / 通知文案风格）要与「AI 功能」下的子选项用同一套标题
/// 字号与行高，当前值从标题下方挪到右侧紧贴 >，组内分隔条合并掉。
///
/// 这里量的是 RenderBox，不靠肉眼：
/// - 标题左缘与字号字重对齐 AI 子项
/// - 行高 36（右侧是 40 高的分段滑块时整行长到 40，竖干跟着拉满）
/// - 相邻两行的竖干首尾相接（组内不再有分隔条的断口）
/// - 值文本与标题同一行、右缘贴箭头左缘
///
/// 「实时课程提醒」组只在安卓出现（`_liveUpdateAvailable` 跟平台走），
/// 测试机上整块不渲染，所以走「任务临期通知」那一组——两组的子项用的是
/// 同一个 `_buildBranchRow` 与同一个 `_buildBranchValueTrailing`。
Finder branchPainters() => find.byWidgetPredicate(
      (widget) =>
          widget is CustomPaint &&
          widget.painter?.runtimeType.toString() == '_BranchConnectorPainter',
    );

Rect _rect(WidgetTester tester, Finder finder) {
  final box = tester.renderObject<RenderBox>(finder);
  return box.localToGlobal(Offset.zero) & box.size;
}

/// 全部竖干区（分支连接线的绘制盒），按纵向从上到下排
List<Rect> _branchRects(WidgetTester tester) {
  final rects = branchPainters()
      .evaluate()
      .map((element) => _rect(tester, find.byWidget(element.widget)))
      .toList()
    ..sort((a, b) => a.top.compareTo(b.top));
  return rects;
}

/// 与某个标题同一行的那段竖干（纵向中心最接近）
Rect _branchOfRow(WidgetTester tester, String title) {
  final center = _rect(tester, find.text(title)).center.dy;
  var best = _branchRects(tester).first;
  var bestGap = double.infinity;
  for (final rect in _branchRects(tester)) {
    final gap = (rect.center.dy - center).abs();
    if (gap < bestGap) {
      bestGap = gap;
      best = rect;
    }
  }
  return best;
}

Future<void> _pumpSettings(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(400, 3000));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    MultiProvider(
      // .value 而不是 create：ThemeController/AuthService 都是单例，
      // create 版会在用例结束时 dispose 掉单例，后面每个用例都踩雷
      providers: [
        ChangeNotifierProvider.value(value: AuthService.instance),
        ChangeNotifierProvider.value(value: ThemeController.instance),
      ],
      child: const MaterialApp(home: SettingsScreen()),
    ),
  );
  // 首帧 + 几轮异步加载（prefs / 通知设置 / AI 配置在这几轮里落地）
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final tmp = await Directory.systemTemp.createTemp('settings_branch_row');
    Hive.init(tmp.path);
    if (!Hive.isAdapterRegistered(0)) Hive.registerAdapter(CourseAdapter());
    if (!Hive.isAdapterRegistered(1)) Hive.registerAdapter(TaskAdapter());
    await StorageService.init();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({
      // 任务临期通知：开，只给小时档（值文本应为「2 小时」）
      'task_notification_enabled': true,
      'task_notification_days': 0,
      'task_notification_hours': 2,
      'task_notification_minutes': 0,
      // AI 功能：开（内置节点即视为已配置，总开关不会被自动关掉）
      'ai_enabled': true,
      'ai_provider': 'builtin',
      'builtin_node': 1,
      'ai_consent_accepted': true,
    });
  });

  testWidgets('子项标题与 AI 子项同一套字号字重、同一左缘', (tester) async {
    await _pumpSettings(tester);

    final aiTitle = find.text('自动任务分析');
    final notifyTitle = find.text('提前提醒时间');
    expect(aiTitle, findsOneWidget, reason: 'AI 子项没渲染，探针失去意义');
    expect(notifyTitle, findsOneWidget);

    final aiStyle = tester.widget<Text>(aiTitle).style!;
    final notifyStyle = tester.widget<Text>(notifyTitle).style!;
    expect(notifyStyle.fontSize, aiStyle.fontSize,
        reason: '标题字号要跟 AI 子项一致');
    expect(notifyStyle.fontWeight, aiStyle.fontWeight,
        reason: '标题字重要跟 AI 子项一致');
    expect(notifyStyle.fontSize, 14);
    expect(notifyStyle.fontWeight, FontWeight.w500);

    expect(_rect(tester, notifyTitle).left, _rect(tester, aiTitle).left,
        reason: '标题左缘要跟 AI 子项对齐（都是 54）');
  });

  testWidgets('行高压到与 AI 子项同级：36；分段滑块那行随控件长到 40',
      (tester) async {
    await _pumpSettings(tester);

    // 四段竖干 = 任务通知的两个子项 + AI 的两个子项
    expect(branchPainters(), findsNWidgets(4));

    expect(_branchOfRow(tester, '提前提醒时间').height, 36,
        reason: '单行子项行高要跟 AI 子项一致（36）');
    expect(_branchOfRow(tester, '自动任务分析').height, 36);
    expect(_branchOfRow(tester, '通知文案风格').height, closeTo(40, 0.5),
        reason: '右侧是 40 高的分段滑块，整行随控件长，竖干要拉满不留缺口');
  });

  testWidgets('组内分隔条合并：两行竖干首尾相接', (tester) async {
    await _pumpSettings(tester);

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('notify-options-visible')),
        matching: find.byType(Divider),
      ),
      findsNothing,
      reason: '子项要合成一块，组内分隔条得合并掉',
    );

    final rects = _branchRects(tester);
    expect(rects.length, 4);
    // 任务通知组的两个子项相邻（AI 组那两行排在更下面）
    final first = _branchOfRow(tester, '提前提醒时间');
    final second = _branchOfRow(tester, '通知文案风格');
    expect(second.top, greaterThanOrEqualTo(first.bottom - 0.01));
    final gap = second.top - first.bottom;
    expect(gap, closeTo(0, 0.01),
        reason: '同一组内相邻两行之间没有分隔条，竖干应接得上（实测断口 $gap px）');
  });

  testWidgets('当前值挪到右侧紧贴 >，不再挂在标题下面', (tester) async {
    await _pumpSettings(tester);

    final title = find.text('提前提醒时间');
    final value = find.text('2 小时');
    expect(value, findsOneWidget, reason: '值文本仍要在行里，只是换了位置');

    final titleRect = _rect(tester, title);
    final valueRect = _rect(tester, value);
    // 同一行：纵向中心对齐（挂在标题下的 subtitle 会明显低一截）
    expect((valueRect.center.dy - titleRect.center.dy).abs(), lessThan(1.5),
        reason: '值文本还挂在标题下方（subtitle 位置）');

    final chevron = find.descendant(
      // find.ancestor 的结果是「由近及远」，所以 .first 才是这一行自己的
      // 分支壳；用 .last 会拿到页面最外层那个 Stack，把别的行也框进来
      of: find.ancestor(of: title, matching: find.byType(Stack)).first,
      matching: find.byIcon(Icons.chevron_right),
    );
    expect(chevron, findsOneWidget);
    final chevronRect = _rect(tester, chevron);
    expect(valueRect.right, lessThanOrEqualTo(chevronRect.left + 0.01),
        reason: '值文本不该压到箭头上面');
    expect(chevronRect.left - valueRect.right, lessThan(8),
        reason: '值文本要靠近 >，不能隔着一大段空白');
    expect(valueRect.right, greaterThan(titleRect.right),
        reason: '值文本应排在标题右侧的尾部区域');
  });

  testWidgets('分支组是卡片最后一项时，滑块下面留白不再贴着卡片边', (tester) async {
    await _pumpSettings(tester);

    final card = find.ancestor(
        of: find.text('任务临期通知'), matching: find.byType(Card));
    expect(card, findsWidgets);
    // Card 的外框含 margin，量 Material 才是卡片真正的底边
    final panel =
        find.descendant(of: card.first, matching: find.byType(Material)).first;
    final selector = find.byWidgetPredicate(
      (widget) =>
          widget.runtimeType.toString().startsWith('SegmentedSelector<'),
    );
    final inRow = find.descendant(
      of: find
          .ancestor(of: find.text('通知文案风格'), matching: find.byType(Stack))
          .first,
      matching: selector,
    );
    final gap = _rect(tester, panel).bottom - _rect(tester, inRow).bottom;
    expect(gap, closeTo(9, 0.5),
        reason: '滑块 40 高正好撑满分支行，卡片底边得留出一口气（实测 $gap px）');
  });

  testWidgets('通知文案风格的三选项控件不动：仍是同款分段滑块', (tester) async {
    await _pumpSettings(tester);

    // 泛型实参不同的 SegmentedSelector 是不同类型，byType 认不到，按类名前缀挑
    final selectorFinder = find.byWidgetPredicate(
      (widget) => widget.runtimeType.toString().startsWith('SegmentedSelector<'),
    );
    final rowStack = find
        .ancestor(of: find.text('通知文案风格'), matching: find.byType(Stack))
        .first;
    final inRow = find.descendant(of: rowStack, matching: selectorFinder);
    expect(inRow, findsOneWidget, reason: '滑块应还钉在这一行的尾部');
    expect(_rect(tester, inRow).width, closeTo(150, 0.5),
        reason: '滑块宽度维持 150，不随本次改动变');
    for (final label in const ['轻松', '严肃', '鸡血']) {
      expect(find.text(label), findsWidgets);
    }
  });
}
