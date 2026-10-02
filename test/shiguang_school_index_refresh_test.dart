import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 教务系统导入「选择学校」列表的进入策略回归：
/// 每次进页面先用缓存把懒加载列表铺出来，同时只补一次自动刷新，
/// 冷却一小时（一小时内已拉过就不再自动打网络，手动刷新不受限）。
/// 这里验的是服务侧那三条判据（有无缓存 / 是否 TTL 过期 / 是否在冷却期），
/// 页面里「铺列表 + 触发一次刷新」的接线依赖 http 顶层调用，不可注入，
/// 未被本测试覆盖。
import 'package:coursehub/services/shiguang/shiguang_index_service.dart';

String _cacheJson({
  required DateTime fetchedAt,
  int schoolCount = 3,
}) {
  return jsonEncode({
    'fetchedAt': fetchedAt.toIso8601String(),
    'schools': [
      for (int i = 0; i < schoolCount; i++)
        {
          'id': 'SCHOOL_$i',
          'name': '学校$i',
          'initial': 'A',
          'resource_folder': 'folder_$i',
        }
    ],
  });
}

const String _indexCacheKey = 'shiguang_index_cache_v1';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('缓存新鲜（30 分钟前）：列表可用且处于一小时冷却期',
      () async {
    SharedPreferences.setMockInitialValues({
      _indexCacheKey:
          _cacheJson(fetchedAt: DateTime.now().subtract(const Duration(minutes: 30))),
    });

    final peek = await ShiguangIndexService.peekCachedIndex();
    expect(peek, isNotNull, reason: '有缓存就应立刻铺列表，不该整屏 loading');
    expect(peek!.schools.length, 3);
    expect(peek.stale, isFalse);
    expect(peek.withinAutoRefreshCooldown, isTrue,
        reason: '距上次拉取不足一小时，进页面不该再自动刷新');
  });

  test('缓存 2 小时前：不在冷却期，进页面应自动刷一次', () async {
    SharedPreferences.setMockInitialValues({
      _indexCacheKey:
          _cacheJson(fetchedAt: DateTime.now().subtract(const Duration(hours: 2))),
    });

    final peek = await ShiguangIndexService.peekCachedIndex();
    expect(peek, isNotNull);
    expect(peek!.withinAutoRefreshCooldown, isFalse);
    expect(peek.stale, isFalse, reason: '2 小时还在 3 天 TTL 内，不该报失效');
  });

  test('冷却边界：恰好一小时算出冷却期（不再自动刷）', () async {
    for (final offset in const [
      Duration(minutes: 59),
      Duration(hours: 1, minutes: 1),
    ]) {
      SharedPreferences.setMockInitialValues({
        _indexCacheKey:
            _cacheJson(fetchedAt: DateTime.now().subtract(offset)),
      });
      final peek = await ShiguangIndexService.peekCachedIndex();
      expect(peek!.withinAutoRefreshCooldown, offset < const Duration(hours: 1),
          reason: '冷却窗口应以一小时为界（当前偏移 $offset）');
    }
  });

  test('缓存超过 3 天：列表照常用，但标记为可能过期', () async {
    SharedPreferences.setMockInitialValues({
      _indexCacheKey:
          _cacheJson(fetchedAt: DateTime.now().subtract(const Duration(days: 4))),
    });

    final peek = await ShiguangIndexService.peekCachedIndex();
    expect(peek, isNotNull);
    expect(peek!.stale, isTrue);
    expect(peek.withinAutoRefreshCooldown, isFalse);
  });

  test('无缓存 / 缓存不可用：返回 null，页面走整屏加载', () async {
    expect(await ShiguangIndexService.peekCachedIndex(), isNull,
        reason: '首次使用没有缓存');

    SharedPreferences.setMockInitialValues({
      _indexCacheKey: jsonEncode({
        'fetchedAt': DateTime.now().toIso8601String(),
        'schools': const <Map<String, dynamic>>[],
      }),
    });
    expect(await ShiguangIndexService.peekCachedIndex(), isNull,
        reason: '缓存里学校为空等同没有缓存');

    SharedPreferences.setMockInitialValues({_indexCacheKey: '不是 json'});
    expect(await ShiguangIndexService.peekCachedIndex(), isNull,
        reason: '缓存损坏不能把页面卡死');
  });

  test('时间戳缺失或损坏：按冷却期外处理，宁可多刷一次', () async {
    for (final fetchedAt in ['', 'not-a-time']) {
      SharedPreferences.setMockInitialValues({
        _indexCacheKey: '{"fetchedAt":"$fetchedAt","schools":['
            '{"id":"S1","name":"学校一","initial":"A",'
            '"resource_folder":"f1"}]}',
      });
      final peek = await ShiguangIndexService.peekCachedIndex();
      expect(peek, isNotNull);
      expect(peek!.withinAutoRefreshCooldown, isFalse,
          reason: '没有可用时间戳时应允许刷新（fetchedAt="$fetchedAt"）');
    }
  });
}
