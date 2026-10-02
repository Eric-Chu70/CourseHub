import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../cloud_backend.dart';

bool _isJwtExpiredMessage(String message, {String? code}) {
  final normalized = message.trim().toLowerCase();
  final normalizedCode = (code ?? '').trim().toLowerCase();
  return normalized.contains('jwt expired') ||
      normalized.contains('token has expired') ||
      normalized.contains('expired jwt') ||
      normalizedCode == 'jwt_expired' ||
      normalizedCode == 'token_expired';
}

String _mapAuthErrorToChinese(String message, {String? code}) {
  final normalized = message.trim().toLowerCase();
  final normalizedCode = (code ?? '').trim().toLowerCase();

  if (_isJwtExpiredMessage(message, code: code)) {
    return '登录已过期，请重新登录';
  }

  if (normalized.contains('user already registered')) {
    return '该邮箱已注册，请直接登录';
  }
  if (normalized.contains('user not found') ||
      normalized.contains('no user found') ||
      normalized.contains('email not found') ||
      normalized.contains('account not found') ||
      (normalized.contains('not found') && normalized.contains('user')) ||
      normalizedCode == 'user_not_found' ||
      normalizedCode == 'email_not_found') {
    return '该用户不存在';
  }
  if (normalized.contains('invalid login credentials')) {
    return '邮箱或密码错误';
  }
  if (normalized.contains('email not confirmed')) {
    return '邮箱未验证，请先完成邮箱验证';
  }
  if (normalized.contains('signup is disabled') || normalized.contains('email signups are disabled')) {
    return '当前项目未开启邮箱注册，请在 Supabase 控制台开启';
  }
  if (normalized.contains('password should be at least') || normalized.contains('password is too weak')) {
    return '密码强度不足，请使用至少8位且包含字母和数字';
  }
  if (normalized.contains('email rate limit exceeded') || normalizedCode == 'over_email_send_rate_limit') {
    return '请求过于频繁，请稍后再试';
  }
  if (normalized.contains('invalid email')) {
    return '邮箱格式不正确';
  }
  if (normalized.contains('database error saving new user')) {
    return '注册失败，服务器保存用户信息时出错';
  }
  if (normalized.contains('for security purposes, you can only request this after')) {
    return '请求过于频繁，请稍后再试';
  }
  if (normalizedCode == 'email_address_not_authorized') {
    return '当前邮箱地址未被授权发送（内置邮件服务仅允许团队邮箱）';
  }

  return message;
}

/// Supabase 后端实现：登录（GoTrue REST）+ 备份（PostgREST user_backups）。
/// 由原 auth_service.dart 的 SupabaseService 与 cloud_sync_service.dart 的
/// 网络部分原样迁入；会话存储 key 保持不变（supabase_*），已登录用户无感。
class SupabaseBackend extends ChangeNotifier implements CloudBackend {
  SupabaseBackend._internal();
  static final SupabaseBackend _instance = SupabaseBackend._internal();
  factory SupabaseBackend() => _instance;
  static SupabaseBackend get instance => _instance;

  static const String _defaultSupabaseUrl = 'https://jnwhpbkhvumiyjwyjwhu.supabase.co';
  static const String _defaultAnonKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Impud2hwYmtodnVtaXlqd3lqd2h1Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzM4MzMxNjksImV4cCI6MjA4OTQwOTE2OX0.0hoiAxYNvLvvk1SyK-dbTs9hAjGOndmHTDH9l_1SUa8';

  String? _supabaseUrl = _defaultSupabaseUrl;
  String? _anonKey = _defaultAnonKey;
  String? _accessToken;
  String? _refreshToken;
  Map<String, dynamic>? _user;
  String? _lastError;

  Future<bool>? _refreshFuture;

  bool get isConfigured => _supabaseUrl != null && _anonKey != null;

  String? get supabaseUrl => _supabaseUrl;
  String? get anonKey => _anonKey;
  Map<String, dynamic>? get user => _user;
  String? get userId => _user?['id']?.toString();
  String? get userName => _user?['user_metadata']?['full_name'] ?? _user?['user_metadata']?['name'];

  void _clearLastError() {
    _lastError = null;
  }

  String _extractAuthError(String responseBody, {String fallback = '请求失败'}) {
    try {
      final decoded = jsonDecode(responseBody);
      if (decoded is Map<String, dynamic>) {
        final code = decoded['code']?.toString();
        final candidates = [decoded['error_description'], decoded['msg'], decoded['message'], decoded['error']];
        for (final item in candidates) {
          if (item is String && item.trim().isNotEmpty) {
            return _mapAuthErrorToChinese(item.trim(), code: code);
          }
        }
        if (code != null && code.trim().isNotEmpty) {
          return _mapAuthErrorToChinese(code.trim(), code: code);
        }
      }
    } catch (_) {
      // Keep fallback if response isn't a JSON object.
    }
    return fallback;
  }

  // ---------------------------------------------------------------------------
  // CloudBackend 接口
  // ---------------------------------------------------------------------------

  @override
  String get id => 'supabase';

  @override
  bool get isAvailable => isConfigured;

  @override
  bool get hasSession => _accessToken != null && _user != null;

  @override
  String? get accessToken => _accessToken;

  @override
  String? get lastError => _lastError;

  @override
  CloudAccount? get account {
    final user = _user;
    if (user == null) return null;
    final id = user['id']?.toString();
    if (id == null || id.isEmpty) return null;
    final metadata = user['user_metadata'];
    String? metadataField(String key) =>
        metadata is Map<String, dynamic> ? metadata[key]?.toString() : null;
    return CloudAccount(
      userId: id,
      email: user['email']?.toString(),
      displayName: () {
        final fullName = metadataField('full_name');
        final name = metadataField('name');
        if (fullName != null && fullName.isNotEmpty) return fullName;
        if (name != null && name.isNotEmpty) return name;
        return null;
      }(),
      avatarUrl: () {
        final avatar = metadataField('avatar_url');
        return (avatar == null || avatar.isEmpty) ? null : avatar;
      }(),
    );
  }

  @override
  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();

    _accessToken = prefs.getString('supabase_access_token');
    _refreshToken = prefs.getString('supabase_refresh_token');

    final userJson = prefs.getString('supabase_user');
    if (userJson != null) {
      _user = jsonDecode(userJson);
    }

    notifyListeners();
  }

  @override
  Future<AuthResult> signIn(String account, String password) async {
    if (!isConfigured) {
      return const AuthResult.failure('云端服务未配置');
    }

    _clearLastError();
    if (!isStrongPassword(password)) {
      _lastError = '密码需至少8位，且必须包含字母和数字';
      return AuthResult.failure(_lastError);
    }

    try {
      final response = await http.post(
        Uri.parse('$_supabaseUrl/auth/v1/token?grant_type=password'),
        headers: {
          'Content-Type': 'application/json',
          'apikey': _anonKey!,
          'Authorization': 'Bearer $_anonKey',
        },
        body: jsonEncode({
          'email': account,
          'password': password,
        }),
      );

      if (response.statusCode != 200) {
        _lastError = _extractAuthError(response.body, fallback: '登录失败，请检查邮箱或密码');
        debugPrint('邮箱密码登录失败: ${response.statusCode} - ${response.body}');
        return AuthResult.failure(_lastError);
      }

      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      final persisted = await _fetchAndPersistUser(
        payload['access_token'] as String? ?? '',
        payload['refresh_token'] as String? ?? '',
      );
      if (!persisted) {
        _lastError ??= '登录成功但保存会话失败';
        debugPrint('邮箱密码登录成功，但会话令牌缺失');
        return AuthResult.failure(_lastError);
      }
      return const AuthResult.ok();
    } catch (e) {
      _lastError = '登录请求异常: ${e.toString()}';
      debugPrint('邮箱密码登录失败: $e');
      return AuthResult.failure(_lastError);
    }
  }

  @override
  Future<AuthResult> register(
    String account,
    String password, {
    String? verificationCode,
  }) async {
    if (!isConfigured) {
      return const AuthResult.failure('云端服务未配置');
    }

    _clearLastError();
    if (!isStrongPassword(password)) {
      _lastError = '密码需至少8位，且必须包含字母和数字';
      return AuthResult.failure(_lastError);
    }

    try {
      final response = await http.post(
        Uri.parse('$_supabaseUrl/auth/v1/signup'),
        headers: {
          'Content-Type': 'application/json',
          'apikey': _anonKey!,
          'Authorization': 'Bearer $_anonKey',
        },
        body: jsonEncode({
          'email': account,
          'password': password,
        }),
      );

      if (response.statusCode != 200 && response.statusCode != 201) {
        _lastError = _extractAuthError(response.body, fallback: '注册失败');
        debugPrint('邮箱密码注册失败: ${response.statusCode} - ${response.body}');
        return AuthResult.failure(_lastError);
      }

      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      final accessToken = payload['access_token'] as String?;
      final refreshToken = payload['refresh_token'] as String?;
      if (accessToken != null && accessToken.isNotEmpty && refreshToken != null && refreshToken.isNotEmpty) {
        final persisted = await _fetchAndPersistUser(accessToken, refreshToken);
        if (persisted) {
          return const AuthResult.ok();
        }
      }

      // If signup returns no session (for example email confirmation is enabled),
      // try password login once for projects that disable confirmation.
      final signedIn = await signIn(account, password);
      if (!signedIn.success) {
        _lastError ??= '注册成功但自动登录失败，请检查是否关闭了邮箱确认';
        debugPrint('邮箱密码注册成功，但自动登录失败');
        return AuthResult.failure(_lastError);
      }
      return const AuthResult.ok();
    } catch (e) {
      _lastError = '注册请求异常: ${e.toString()}';
      debugPrint('邮箱密码注册失败: $e');
      return AuthResult.failure(_lastError);
    }
  }

  @override
  Future<AuthResult> sendRegisterCode(String account) async {
    return const AuthResult.failure('当前登录方式无需验证码');
  }

  @override
  Future<void> signOut() async {
    await expireSessionPreserveUser();
  }

  @override
  Future<void> clearLocalAccountData() async {
    _accessToken = null;
    _refreshToken = null;
    _user = null;
    _clearLastError();

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('supabase_access_token');
    await prefs.remove('supabase_refresh_token');
    await prefs.remove('supabase_user');

    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Supabase 专有接口（门面经类型化引用调用）
  // ---------------------------------------------------------------------------

  Future<bool> _fetchAndPersistUser(String accessToken, String refreshToken) async {
    _clearLastError();
    if (accessToken.isEmpty || refreshToken.isEmpty) {
      return false;
    }
    final response = await http.get(
      Uri.parse('$_supabaseUrl/auth/v1/user'),
      headers: {
        'Authorization': 'Bearer $accessToken',
        'apikey': _anonKey!,
      },
    );

    if (response.statusCode != 200) {
      _lastError = _extractAuthError(response.body, fallback: '获取用户信息失败');
      return false;
    }

    _accessToken = accessToken;
    _refreshToken = refreshToken;
    _user = jsonDecode(response.body);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('supabase_access_token', accessToken);
    await prefs.setString('supabase_refresh_token', refreshToken);
    await prefs.setString('supabase_user', jsonEncode(_user));

    notifyListeners();
    return true;
  }

  Future<void> configure(String url, String anonKey) async {
    _supabaseUrl = url.replaceAll(RegExp(r'/+$'), '');
    _anonKey = anonKey;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('supabase_url_auth', _supabaseUrl!);
    await prefs.setString('supabase_anon_key', _anonKey!);

    notifyListeners();
  }

  Future<bool> handleAuthCallback(String accessToken, String refreshToken) async {
    try {
      return await _fetchAndPersistUser(accessToken, refreshToken);
    } catch (e) {
      debugPrint('处理认证回调失败: $e');
      return false;
    }
  }

  Future<void> expireSessionPreserveUser({String? message}) async {
    _accessToken = null;
    _refreshToken = null;
    if (message != null && message.trim().isNotEmpty) {
      _lastError = message.trim();
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('supabase_access_token');
    await prefs.remove('supabase_refresh_token');

    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 会话刷新（修复 §7 的「refreshToken 存而不用」bug）
  // ---------------------------------------------------------------------------

  /// 惰性刷新（single-flight）：并发过期只发一次刷新请求。
  /// Supabase 同样轮换 refresh_token，绝不能并发重试——第二次会用已作废的
  /// refresh_token，直接把会话刷没。
  Future<bool> refreshSession() {
    return _refreshFuture ??= _doRefreshSession().whenComplete(() {
      _refreshFuture = null;
    });
  }

  Future<bool> _doRefreshSession() async {
    final refreshToken = _refreshToken;
    if (refreshToken == null || refreshToken.isEmpty) return false;

    try {
      final response = await http.post(
        Uri.parse('$_supabaseUrl/auth/v1/token?grant_type=refresh_token'),
        headers: {
          'Content-Type': 'application/json',
          'apikey': _anonKey!,
          'Authorization': 'Bearer $_anonKey',
        },
        body: jsonEncode({'refresh_token': refreshToken}),
      );

      if (response.statusCode != 200) {
        // 400/401：refresh_token 已失效，会话真过期；
        // 5xx 视为服务端暂时故障，不动会话，下次操作再试
        if (response.statusCode == 400 || response.statusCode == 401) {
          await expireSessionPreserveUser(message: '登录已过期，请重新登录');
        }
        return false;
      }

      final payload = jsonDecode(response.body);
      if (payload is! Map<String, dynamic>) return false;
      final accessToken = payload['access_token']?.toString() ?? '';
      final newRefreshToken = payload['refresh_token']?.toString() ?? '';
      if (accessToken.isEmpty || newRefreshToken.isEmpty) return false;

      // 轮换：必须回写新 refresh_token（旧的已立即失效）
      _accessToken = accessToken;
      _refreshToken = newRefreshToken;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('supabase_access_token', accessToken);
      await prefs.setString('supabase_refresh_token', newRefreshToken);
      notifyListeners();
      return true;
    } catch (e) {
      // 网络异常不等于会话过期，保留会话下次再试
      debugPrint('Supabase 刷新会话失败（网络异常，保留会话）: $e');
      return false;
    }
  }

  /// 带鉴权的请求执行：响应表明 JWT 过期时先惰性刷新再重试一次。
  /// 备份三个操作幂等，重试安全；刷新失败走原有的过期处理路径。
  Future<http.Response> _sendWithRefresh(
    Future<http.Response> Function() send,
  ) async {
    var response = await send();
    if (_isJwtExpiredMessage(response.body) && await refreshSession()) {
      response = await send();
    }
    return response;
  }

  Future<void> clearConfig() async {
    await signOut();

    _supabaseUrl = null;
    _anonKey = null;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('supabase_url_auth');
    await prefs.remove('supabase_anon_key');
    await prefs.remove('supabase_user');
    _user = null;

    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 备份 CRUD（原 cloud_sync_service.dart 网络部分原样迁入）
  // ---------------------------------------------------------------------------

  bool get _isSessionReady {
    return isConfigured &&
        (_supabaseUrl?.isNotEmpty ?? false) &&
        (_anonKey?.isNotEmpty ?? false) &&
        (_accessToken?.isNotEmpty ?? false) &&
        (userId?.isNotEmpty ?? false);
  }

  Map<String, String> _headers() {
    return {
      'apikey': _anonKey!,
      'Authorization': 'Bearer ${_accessToken!}',
      'Content-Type': 'application/json',
    };
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
            if (_isJwtExpiredMessage(item, code: code)) {
              await expireSessionPreserveUser(message: '登录已过期，请重新登录');
              return '登录已过期，请重新登录';
            }
            return item.trim();
          }
        }
        if (code != null && code.trim().isNotEmpty && _isJwtExpiredMessage(code, code: code)) {
          await expireSessionPreserveUser(message: '登录已过期，请重新登录');
          return '登录已过期，请重新登录';
        }
      }
    } catch (_) {
      // keep fallback
    }

    if (_isJwtExpiredMessage(fallback)) {
      await expireSessionPreserveUser(message: '登录已过期，请重新登录');
      return '登录已过期，请重新登录';
    }

    return fallback;
  }

  Map<String, dynamic> _emptyBackupPayload() => emptyBackupPayload();

  @override
  Future<CloudBackupSnapshot?> fetchBackup() async {
    _lastError = null;

    if (!_isSessionReady) {
      _lastError = '请先完成登录';
      return null;
    }

    final userId = this.userId!;
    final uri = Uri.parse(
      '$_supabaseUrl/rest/v1/user_backups?select=payload,updated_at&user_id=eq.$userId&limit=1',
    );

    try {
      final response =
          await _sendWithRefresh(() => http.get(uri, headers: _headers()));
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
      if (isEmptyBackupPayload(payload)) {
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

  @override
  Future<bool> uploadBackup(Map<String, dynamic> payload) async {
    _lastError = null;

    if (!_isSessionReady) {
      _lastError = '请先完成登录';
      return false;
    }

    final userId = this.userId!;
    final updateUri = Uri.parse('$_supabaseUrl/rest/v1/user_backups?user_id=eq.$userId');
    final insertUri = Uri.parse('$_supabaseUrl/rest/v1/user_backups');

    try {
      // Use PATCH first to fully replace payload instead of JSON merge on upsert.
      final updateResponse = await _sendWithRefresh(
        () => http.patch(
          updateUri,
          headers: {
            ..._headers(),
            'Prefer': 'return=representation',
          },
          body: jsonEncode({
            'payload': payload,
          }),
        ),
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
      final insertResponse = await _sendWithRefresh(
        () => http.post(
          insertUri,
          headers: {
            ..._headers(),
            'Prefer': 'return=minimal',
          },
          body: jsonEncode({
            'user_id': userId,
            'payload': payload,
          }),
        ),
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

  @override
  Future<bool> deleteBackup() async {
    _lastError = null;

    if (!_isSessionReady) {
      _lastError = '请先完成登录';
      return false;
    }

    final userId = this.userId!;
    final uri = Uri.parse('$_supabaseUrl/rest/v1/user_backups?user_id=eq.$userId');

    try {
      final response = await _sendWithRefresh(
        () => http.delete(
          uri,
          headers: {
            ..._headers(),
            // Ask PostgREST to return deleted rows so we can detect no-op deletes.
            'Prefer': 'return=representation',
          },
        ),
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
