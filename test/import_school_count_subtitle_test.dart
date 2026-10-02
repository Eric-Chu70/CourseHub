import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 教务系统导入副标题的高校数量：显示索引里的真实高校条数，
/// 前 5 条通用条目（通用工具 + 四大通用教务，`isGeneric`）不计入。
/// 拿不到时回退原文案 150+。缓存新鲜（一小时内）不补网络请求。
/// 数字来自服务的发布源，学校选择页刷新后本页不必重建也跟着变。
import 'package:coursehub/screens/import_screen.dart';
import 'package:coursehub/services/shiguang/shiguang_index_service.dart';

const String _indexCacheKey = 'shiguang_index_cache_v1';

String _cacheJson({
  required DateTime fetchedAt,
  required int count,
}) {
  return jsonEncode({
    'fetchedAt': fetchedAt.toIso8601String(),
    'schools': [
      for (int i = 0; i < count; i++)
        {
          'id': 'SCHOOL_$i',
          'name': '学校$i',
          'initial': 'A',
          'resource_folder': 'folder_$i',
        }
    ],
  });
}

/// 造一份「5 条通用条目 + N 所真实高校」的缓存：通用条目 id 取自
/// genericFolderIds 且共用同一个 resource_folder，用来证明它们被排除在
/// 高校数量之外（若被计入，显示的就是 3+5=8）。
String _cacheJsonWithGenerics({required DateTime fetchedAt, int real = 3}) {
  final schools = <Map<String, dynamic>>[
    for (final id in const [
      'GLOBAL_TOOLS',
      'zhengfang_jiaowu',
      'chaoxing_jiaowu',
      'qingguo_jiaowu',
      'urp_jiaowu',
    ])
      {
        'id': id,
        'name': '通用教务',
        'initial': '通',
        'resource_folder': 'zhengfang_jiaowu',
      },
    for (int i = 0; i < real; i++)
      {
        'id': 'SCHOOL_$i',
        'name': '学校$i',
        'initial': 'A',
        'resource_folder': 'folder_$i',
      },
  ];
  return jsonEncode({
    'fetchedAt': fetchedAt.toIso8601String(),
    'schools': schools,
  });
}

Future<void> _pumpImport(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: ImportScreen()));
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 服务的发布源是静态的、跨用例存活：不清掉的话「无缓存」那条会读到
    // 上一个用例发布的列表，回退文案的断言就失去意义
    ShiguangIndexService.resetPublishedSchoolsForTest();
  });

  testWidgets('8 条真实高校（无通用条目）：副标题显示 8，不是 150+',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      _indexCacheKey: _cacheJson(
        fetchedAt: DateTime.now().subtract(const Duration(minutes: 5)),
        count: 8,
      ),
    });

    await _pumpImport(tester);

    expect(find.text('适配 8 所高校教务系统一键导入'), findsOneWidget);
    expect(find.text('适配 150+ 所高校教务系统一键导入'), findsNothing);
  });

  testWidgets('通用条目不计入：3 所高校 + 5 条通用 = 显示 3', (tester) async {
    SharedPreferences.setMockInitialValues({
      _indexCacheKey: _cacheJsonWithGenerics(
        fetchedAt: DateTime.now().subtract(const Duration(minutes: 5)),
        real: 3,
      ),
    });

    await _pumpImport(tester);

    // 通用工具 + 四大通用教务是「通用系统入口」，不是一所高校
    expect(find.text('适配 3 所高校教务系统一键导入'), findsOneWidget,
        reason: '5 条通用条目不能加进高校数量');
    expect(find.text('适配 8 所高校教务系统一键导入'), findsNothing);
  });

  testWidgets('无缓存且拉取失败：回退原文案 150+', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await _pumpImport(tester);
    await tester.pump();

    expect(find.text('适配 150+ 所高校教务系统一键导入'), findsOneWidget);
  });

  testWidgets('学校选择页刷新出新的索引：导入页不重建也当场跟着变', (tester) async {
    SharedPreferences.setMockInitialValues({
      _indexCacheKey: _cacheJson(
        fetchedAt: DateTime.now().subtract(const Duration(minutes: 5)),
        count: 8,
      ),
    });

    await _pumpImport(tester);
    expect(find.text('适配 8 所高校教务系统一键导入'), findsOneWidget);

    // 选择学校页那次刷新：索引换了、服务把新列表发布出来。
    // 全程不重新 pumpWidget——导入页压在导航栈底，返回时本来就不会重建，
    // 这正是「必须切走再切回才更新」的成因
    SharedPreferences.setMockInitialValues({
      _indexCacheKey: _cacheJson(fetchedAt: DateTime.now(), count: 12),
    });
    await ShiguangIndexService.peekCachedIndex();
    await tester.pump();

    expect(find.text('适配 12 所高校教务系统一键导入'), findsOneWidget,
        reason: '数量应随学校选择页的刷新立即更新');
    expect(find.text('适配 8 所高校教务系统一键导入'), findsNothing);
  });
}
