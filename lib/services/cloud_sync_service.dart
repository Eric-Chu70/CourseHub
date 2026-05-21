import 'dart:convert';

import 'package:http/http.dart' as http;

import 'auth_service.dart';

class CloudBackupSnapshot {
  const CloudBackupSnapshot({
    required this.payload,
    this.updatedAt,
  });

  final Map<String, dynamic> payload;
  final DateTime? updatedAt;
}

class CloudSyncService {
  CloudSyncService._internal();

  static final CloudSyncService _instance = CloudSyncService._internal();
  factory CloudSyncService() => _instance;

  static CloudSyncService get instance => _instance;

  final SupabaseService _supabase = SupabaseService.instance;

  String? _lastError;
  String? get lastError => _lastError;

  bool get _isSessionReady {
    return _supabase.isConfigured &&
        (_supabase.supabaseUrl?.isNotEmpty ?? false) &&
        (_supabase.anonKey?.isNotEmpty ?? false) &&
        (_supabase.accessToken?.isNotEmpty ?? false) &&
        (_supabase.userId?.isNotEmpty ?? false);
  }

  Map<String, String> _headers() {
    return {
      'apikey': _supabase.anonKey!,
      'Authorization': 'Bearer ${_supabase.accessToken!}',
      'Content-Type': 'application/json',
    };
  }

  bool _isJwtExpiredError(String message, {String? code}) {
    final normalized = message.trim().toLowerCase();
    final normalizedCode = (code ?? '').trim().toLowerCase();
    return normalized.contains('jwt expired') ||
        normalized.contains('token has expired') ||
        normalized.contains('expired jwt') ||
        normalizedCode == 'jwt_expired' ||
        normalizedCode == 'token_expired';
  }

  Future<String> _extractAndHandleError(String body, {required String fallback}) async {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final code = decoded['code']?.toString();
        final candidates = [
          decoded['message'],
          decoded['error_description'],
          decoded['error'],
          decoded['hint'],
        ];
        for (final item in candidates) {
          if (item is String && item.trim().isNotEmpty) {
            if (_isJwtExpiredError(item, code: code)) {
              await _supabase.expireSessionPreserveUser(message: '登录已过期，请重新登录');
              return '登录已过期，请重新登录';
            }
            return item.trim();
          }
        }
        if (code != null && code.trim().isNotEmpty && _isJwtExpiredError(code, code: code)) {
          await _supabase.expireSessionPreserveUser(message: '登录已过期，请重新登录');
          return '登录已过期，请重新登录';
        }
      }
    } catch (_) {
      // keep fallback
    }

    if (_isJwtExpiredError(fallback)) {
      await _supabase.expireSessionPreserveUser(message: '登录已过期，请重新登录');
      return '登录已过期，请重新登录';
    }

    return fallback;
  }

  String _extractError(String body, {required String fallback}) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final candidates = [
          decoded['message'],
          decoded['error_description'],
          decoded['error'],
          decoded['hint'],
        ];
        for (final item in candidates) {
          if (item is String && item.trim().isNotEmpty) {
            return item.trim();
          }
        }
      }
    } catch (_) {
      // Keep fallback when body cannot be parsed.
    }
    return fallback;
  }

  Map<String, dynamic> _emptyBackupPayload() {
    return {
      'version': '2.0',
      'backupType': 'full_named_timetables',
      'namedTimetables': <String, dynamic>{},
    };
  }

  Future<CloudBackupSnapshot?> fetchBackup() async {
    _lastError = null;

    if (!_isSessionReady) {
      _lastError = '请先完成登录';
      return null;
    }

    final userId = _supabase.userId!;
    final uri = Uri.parse(
      '${_supabase.supabaseUrl}/rest/v1/user_backups?select=payload,updated_at&user_id=eq.$userId&limit=1',
    );

    try {
      final response = await http.get(uri, headers: _headers());
      if (response.statusCode != 200) {
        _lastError = await _extractAndHandleError(response.body, fallback: '获取云端备份失败');
        return null;
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! List || decoded.isEmpty) {
        return null;
      }

      final row = decoded.first;
      if (row is! Map<String, dynamic>) {
        _lastError = '云端备份数据格式异常';
        return null;
      }

      final rawPayload = row['payload'];
      if (rawPayload is! Map) {
        _lastError = '云端备份内容为空或格式异常';
        return null;
      }

      final payload = Map<String, dynamic>.from(rawPayload);
      if (payload.isEmpty) {
        return null;
      }

      final namedTimetables = payload['namedTimetables'];
      final hasLegacyData = (payload['courses'] is List) || (payload['tasks'] is List) || (payload['settings'] is Map);
      if (namedTimetables is Map && namedTimetables.isEmpty && !hasLegacyData) {
        return null;
      }

      final updatedAtRaw = row['updated_at']?.toString();
      return CloudBackupSnapshot(
        payload: payload,
        updatedAt: updatedAtRaw == null ? null : DateTime.tryParse(updatedAtRaw),
      );
    } catch (e) {
      _lastError = '获取云端备份失败: ${e.toString()}';
      return null;
    }
  }

  Future<bool> uploadBackup(Map<String, dynamic> payload) async {
    _lastError = null;

    if (!_isSessionReady) {
      _lastError = '请先完成登录';
      return false;
    }

    final userId = _supabase.userId!;
    final updateUri = Uri.parse('${_supabase.supabaseUrl}/rest/v1/user_backups?user_id=eq.$userId');
    final insertUri = Uri.parse('${_supabase.supabaseUrl}/rest/v1/user_backups');

    try {
      // Use PATCH first to fully replace payload instead of JSON merge on upsert.
      final updateResponse = await http.patch(
        updateUri,
        headers: {
          ..._headers(),
          'Prefer': 'return=representation',
        },
        body: jsonEncode({
          'payload': payload,
        }),
      );

      if (updateResponse.statusCode == 200) {
        final decoded = jsonDecode(updateResponse.body);
        if (decoded is List && decoded.isNotEmpty) {
          return true;
        }
      } else if (updateResponse.statusCode == 204) {
        return true;
      } else {
        _lastError = await _extractAndHandleError(updateResponse.body, fallback: '上传云端备份失败');
        return false;
      }

      // No existing row was updated; insert a fresh backup row.
      final insertResponse = await http.post(
        insertUri,
        headers: {
          ..._headers(),
          'Prefer': 'return=minimal',
        },
        body: jsonEncode({
          'user_id': userId,
          'payload': payload,
        }),
      );

      if (insertResponse.statusCode != 200 && insertResponse.statusCode != 201 && insertResponse.statusCode != 204) {
        _lastError = await _extractAndHandleError(insertResponse.body, fallback: '上传云端备份失败');
        return false;
      }

      return true;
    } catch (e) {
      _lastError = '上传云端备份失败: ${e.toString()}';
      return false;
    }
  }

  Future<bool> deleteBackup() async {
    _lastError = null;

    if (!_isSessionReady) {
      _lastError = '请先完成登录';
      return false;
    }

    final userId = _supabase.userId!;
    final uri = Uri.parse('${_supabase.supabaseUrl}/rest/v1/user_backups?user_id=eq.$userId');

    try {
      final response = await http.delete(
        uri,
        headers: {
          ..._headers(),
          // Ask PostgREST to return deleted rows so we can detect no-op deletes.
          'Prefer': 'return=representation',
        },
      );

      if (response.statusCode != 200 && response.statusCode != 204) {
        // Some projects may miss DELETE policy; fall back to overwrite with empty payload.
        final fallbackSuccess = await uploadBackup(_emptyBackupPayload());
        if (fallbackSuccess) {
          return true;
        }
        _lastError = await _extractAndHandleError(response.body, fallback: '删除云端备份失败');
        return false;
      }

      if (response.statusCode == 200) {
        try {
          final decoded = jsonDecode(response.body);
          if (decoded is List && decoded.isNotEmpty) {
            return true;
          }
        } catch (_) {
          // Fall through to verification below.
        }
      }

      // 200/204 may still be a no-op under some RLS setups. Verify actual state.
      final remaining = await fetchBackup();
      final verifyError = _lastError;
      if (remaining == null && verifyError == null) {
        return true;
      }

      // Backup still exists; force overwrite to an empty payload.
      if (remaining != null) {
        final fallbackSuccess = await uploadBackup(_emptyBackupPayload());
        if (fallbackSuccess) {
          return true;
        }
      }

      _lastError = verifyError ?? _lastError ?? '删除云端备份失败';
      return false;
    } catch (e) {
      _lastError = '删除云端备份失败: ${e.toString()}';
      return false;
    }
  }
}
