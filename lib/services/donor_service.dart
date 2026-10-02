import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// 打赏者记录：署名（微信打赏 ID）+ 金额（元）。
class DonationRecord {
  const DonationRecord({required this.wechatId, required this.amount});

  final String wechatId;
  final double amount;

  factory DonationRecord.fromJson(Map<String, dynamic> json) =>
      DonationRecord(
        wechatId: json['wechatId']?.toString() ?? '',
        amount: (json['amount'] as num?)?.toDouble() ?? 0,
      );

  Map<String, dynamic> toJson() => {'wechatId': wechatId, 'amount': amount};
}

/// 打赏者名单服务。
///
/// 名单维护在 CloudBase 静态托管的 `donors.json`（与 latest.json 同源）：
/// 收到打赏后手动编辑上传，全员即时生效、无需发版。文件结构：
/// ```json
/// { "donors": [ { "wechatId": "昵称", "amount": 6.66 } ] }
/// ```
/// 数组顺序即展示顺序（新的写前面）。署名只放用户同意公开的称呼。
///
/// 容错链：网络拉取（8s 超时）→ 失败读本地缓存（上次成功的结果）→
/// 再没有 → 空列表（UI 显示空态）。打赏名单是纯展示，任何失败都静默。
class DonorService {
  DonorService._internal();

  static const String _donorsJsonUrl =
      'https://coursehub-d2gkbrgm7c877557a-1412312719.tcloudbaseapp.com/donors.json';
  static const String _cachePrefKey = 'donors_cache';

  // 24 小时节流：上次网络刷新时间（会话内缓存 + 磁盘持久化）。
  // 窗口内再打开打赏对话框直接读本地缓存，不触发网络
  static const String _lastFetchAtKey = 'donors_last_fetch_at';
  static const Duration _refreshInterval = Duration(hours: 24);
  static DateTime? _sessionLastFetch;

  /// 拉取打赏者名单（按维护顺序返回）。永不抛异常：失败回落缓存/空列表。
  static Future<List<DonationRecord>> fetchDonors() async {
    try {
      final resp = await http
          .get(Uri.parse(_donorsJsonUrl))
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode == 200) {
        final result = _parse(resp.body);
        if (result != null) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_cachePrefKey, resp.body);
          return result;
        }
      }
    } catch (e) {
      debugPrint('[DonorService] 拉取打赏名单失败（走缓存）: $e');
    }
    return lastKnownDonors();
  }

  /// 打赏对话框展示用：**24 小时内最多触发一次网络刷新**（云端流量优化），
  /// 刷新后窗口内再打开直接展示本地缓存。窗口外刷新一次——无论成败都记入
  /// 窗口（请求消耗已发生）。永不抛异常。
  static Future<List<DonationRecord>> fetchDonorsForDisplay() async {
    final prefs = await SharedPreferences.getInstance();
    final last = _sessionLastFetch ?? _lastFetchFrom(prefs);
    if (last != null && DateTime.now().difference(last) < _refreshInterval) {
      _sessionLastFetch = last;
      return lastKnownDonors();
    }

    // 刷新窗口开启：先记账（网络消耗已发生），成败都不再重试
    _sessionLastFetch = DateTime.now();
    await prefs.setInt(
      _lastFetchAtKey,
      _sessionLastFetch!.millisecondsSinceEpoch,
    );

    try {
      final resp = await http
          .get(Uri.parse(_donorsJsonUrl))
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode == 200) {
        final result = _parse(resp.body);
        if (result != null) {
          await prefs.setString(_cachePrefKey, resp.body);
          return result;
        }
      }
    } catch (e) {
      debugPrint('[DonorService] 拉取打赏名单失败（走缓存）: $e');
    }
    return lastKnownDonors();
  }

  static DateTime? _lastFetchFrom(SharedPreferences prefs) {
    final ms = prefs.getInt(_lastFetchAtKey);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  /// 上次成功拉到的名单（本地缓存）；从未成功过 → 空列表
  static Future<List<DonationRecord>> lastKnownDonors() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString(_cachePrefKey);
      if (cached != null) return _parse(cached) ?? const [];
    } catch (_) {
      // 缓存损坏按空名单处理
    }
    return const [];
  }

  /// 解析 donors.json；结构不对返回 null（避免把脏数据当空名单覆盖缓存）
  static List<DonationRecord>? _parse(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) return null;
      final list = decoded['donors'];
      if (list is! List) return null;
      return list
          .whereType<Map<String, dynamic>>()
          .map(DonationRecord.fromJson)
          .toList();
    } catch (_) {
      return null;
    }
  }
}
