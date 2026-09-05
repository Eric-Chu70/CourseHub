import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yaml/yaml.dart';

import 'shiguang_models.dart';

/// 拾光适配器仓库（shiguang_warehouse）索引与脚本拉取服务。
///
/// 数据源为 GitHub 仓库的静态文件，采用双源回退（raw.githubusercontent → jsdelivr）
/// + SharedPreferences 缓存（TTL 3 天，网络失败时回退旧缓存）。
class ShiguangIndexService {
  ShiguangIndexService._();

  static const List<String> _baseUrls = [
    'https://raw.githubusercontent.com/XingHeYuZhuan/shiguang_warehouse/main/',
    'https://cdn.jsdelivr.net/gh/XingHeYuZhuan/shiguang_warehouse@main/',
  ];

  static const Duration _timeout = Duration(seconds: 10);
  static const Duration _cacheTtl = Duration(days: 3);

  static const String _indexCacheKey = 'shiguang_index_cache_v1';
  static const String _adaptersCachePrefix = 'shiguang_adapters_';
  static const String _recentSchoolsKey = 'shiguang_recent_schools_v1';
  static const String _lastUrlPrefix = 'shiguang_last_url_';

  /// 适配脚本源码的会话级内存缓存（folder → script path → source）。
  static final Map<String, String> _scriptCache = {};

  /// 获取学校索引；[forceRefresh] 为 true 时跳过缓存。
  /// 返回 (学校列表, 是否来自过期缓存)。
  static Future<(List<ShiguangSchool>, bool stale)> getSchoolIndex(
      {bool forceRefresh = false}) async {
    final cached = await _readCache(_indexCacheKey);
    if (!forceRefresh && cached != null) {
      final schools = _parseSchools(cached['schools']);
      if (schools.isNotEmpty) {
        final fetchedAt = DateTime.tryParse(cached['fetchedAt']?.toString() ?? '');
        final isStale = fetchedAt == null ||
            DateTime.now().difference(fetchedAt) > _cacheTtl;
        return (schools, isStale);
      }
    }

    final yamlText = await _fetchText('index/root_index.yaml');
    if (yamlText == null) {
      if (cached != null) {
        final schools = _parseSchools(cached['schools']);
        if (schools.isNotEmpty) return (schools, true);
      }
      throw Exception('无法获取学校索引，请检查网络后重试');
    }

    final schools = _parseYamlSchools(yamlText);
    if (schools.isEmpty) throw Exception('学校索引解析结果为空');

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_indexCacheKey, jsonEncode({
      'fetchedAt': DateTime.now().toIso8601String(),
      'schools': schools.map((s) => s.toJson()).toList(),
    }));

    return (schools, false);
  }

  /// 获取某学校的适配器列表。
  static Future<List<ShiguangAdapter>> getAdapters(ShiguangSchool school,
      {bool forceRefresh = false}) async {
    final cacheKey = '$_adaptersCachePrefix${school.resourceFolder}_v1';
    final cached = await _readCache(cacheKey);
    if (!forceRefresh && cached != null) {
      final adapters = _parseAdapters(cached['adapters']);
      if (adapters.isNotEmpty) return adapters;
    }

    final yamlText =
        await _fetchText('resources/${school.resourceFolder}/adapters.yaml');
    if (yamlText == null) {
      if (cached != null) {
        final adapters = _parseAdapters(cached['adapters']);
        if (adapters.isNotEmpty) return adapters;
      }
      throw Exception('无法获取 ${school.name} 的适配器信息');
    }

    final adapters = _parseYamlAdapters(yamlText);
    if (adapters.isEmpty) throw Exception('${school.name} 没有可用适配器');

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(cacheKey, jsonEncode({
      'fetchedAt': DateTime.now().toIso8601String(),
      'adapters': adapters.map((a) => a.toJson()).toList(),
    }));

    return adapters;
  }

  /// 拉取适配脚本源码（会话内存缓存）。
  static Future<String> fetchAdapterScript(
      ShiguangSchool school, ShiguangAdapter adapter) async {
    final cacheKey = '${school.resourceFolder}/${adapter.assetJsPath}';
    final cached = _scriptCache[cacheKey];
    if (cached != null) return cached;

    final script = await _fetchText(
        'resources/${school.resourceFolder}/${adapter.assetJsPath}');
    if (script == null || script.isEmpty) {
      throw Exception('适配脚本下载失败，请检查网络后重试');
    }
    _scriptCache[cacheKey] = script;
    return script;
  }

  // ---------- 最近使用 ----------

  static Future<void> saveRecentSchool(ShiguangSchool school) async {
    final prefs = await SharedPreferences.getInstance();
    final recent = <ShiguangSchool>[];
    // 只保留具体学校，通用教务不记入最近使用。
    if (!school.isGeneric) recent.add(school);
    for (final json in (prefs.getStringList(_recentSchoolsKey) ?? [])) {
      try {
        final s = ShiguangSchool.fromJson(
            Map<String, dynamic>.from(jsonDecode(json) as Map));
        if (s.id != school.id && recent.every((e) => e.id != s.id)) {
          recent.add(s);
        }
      } catch (_) {}
      if (recent.length >= 5) break;
    }
    await prefs.setStringList(
        _recentSchoolsKey, recent.map((s) => jsonEncode(s.toJson())).toList());
  }

  static Future<List<ShiguangSchool>> getRecentSchools() async {
    final prefs = await SharedPreferences.getInstance();
    final result = <ShiguangSchool>[];
    for (final json in (prefs.getStringList(_recentSchoolsKey) ?? [])) {
      try {
        result.add(ShiguangSchool.fromJson(
            Map<String, dynamic>.from(jsonDecode(json) as Map)));
      } catch (_) {}
    }
    return result;
  }

  /// 从最近使用中移除指定学校。
  static Future<void> removeRecentSchool(ShiguangSchool school) async {
    final prefs = await SharedPreferences.getInstance();
    final current = await getRecentSchools();
    current.removeWhere((s) => s.id == school.id);
    await prefs.setStringList(
        _recentSchoolsKey, current.map((s) => jsonEncode(s.toJson())).toList());
  }

  // ---------- URL 记忆 ----------

  static Future<String?> getLastUrl(String adapterId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('$_lastUrlPrefix$adapterId');
  }

  static Future<void> saveLastUrl(String adapterId, String url) async {
    if (url.trim().isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_lastUrlPrefix$adapterId', url.trim());
  }

  // ---------- UA 模式记忆 ----------

  static const String _desktopUaKey = 'shiguang_desktop_ua_v1';

  /// 是否使用电脑版 UA（默认手机版，与拾光原 App 一致）。
  static Future<bool> getUseDesktopUa() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_desktopUaKey) ?? false;
  }

  static Future<void> saveUseDesktopUa(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_desktopUaKey, value);
  }

  // ---------- 内部工具 ----------

  /// 双源回退拉取仓库文本文件；全部失败返回 null（由调用方决定是否用缓存）。
  static Future<String?> _fetchText(String repoPath) async {
    Object? lastError;
    for (final baseUrl in _baseUrls) {
      try {
        final response = await http
            .get(Uri.parse('$baseUrl$repoPath'))
            .timeout(_timeout);
        if (response.statusCode == 200 && response.body.isNotEmpty) {
          return response.body;
        }
        lastError = Exception('HTTP ${response.statusCode}');
      } catch (e) {
        lastError = e;
      }
    }
    if (lastError != null) {
      // ignore: avoid_print
      print('[ShiguangIndexService] 拉取 $repoPath 失败: $lastError');
    }
    return null;
  }

  static Future<Map<String, dynamic>?> _readCache(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) return null;
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return null;
    }
  }

  static List<ShiguangSchool> _parseYamlSchools(String yamlText) {
    try {
      final doc = loadYaml(yamlText) as YamlMap?;
      final schoolsNode = doc?['schools'];
      if (schoolsNode is! YamlList) return [];
      return schoolsNode
          .map((node) => ShiguangSchool.fromYaml(node))
          .where((s) => s.id.isNotEmpty && s.resourceFolder.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  static List<ShiguangAdapter> _parseYamlAdapters(String yamlText) {
    try {
      final doc = loadYaml(yamlText) as YamlMap?;
      final adaptersNode = doc?['adapters'];
      if (adaptersNode is! YamlList) return [];
      return adaptersNode
          .map((node) => ShiguangAdapter.fromYaml(node))
          .where((a) => a.adapterId.isNotEmpty && a.assetJsPath.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  static List<ShiguangSchool> _parseSchools(dynamic raw) {
    if (raw is! List) return [];
    return raw
        .map((item) {
          try {
            return ShiguangSchool.fromJson(
                Map<String, dynamic>.from(item as Map));
          } catch (_) {
            return null;
          }
        })
        .whereType<ShiguangSchool>()
        .where((s) => s.id.isNotEmpty && s.resourceFolder.isNotEmpty)
        .toList();
  }

  static List<ShiguangAdapter> _parseAdapters(dynamic raw) {
    if (raw is! List) return [];
    return raw
        .map((item) {
          try {
            return ShiguangAdapter.fromJson(
                Map<String, dynamic>.from(item as Map));
          } catch (_) {
            return null;
          }
        })
        .whereType<ShiguangAdapter>()
        .where((a) => a.adapterId.isNotEmpty && a.assetJsPath.isNotEmpty)
        .toList();
  }
}
