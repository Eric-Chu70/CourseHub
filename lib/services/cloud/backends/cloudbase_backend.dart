import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../cloud_backend.dart';

/// CloudBase 环境 ID。公开无妨（性质同 Supabase anon key），安全靠
/// `user_backups` 表的 RLS 策略（`user_id = auth.uid()`，见
/// cloudbase/pg-user-backups.sql），不靠密钥保密。管理员 API Key
/// 严禁打进安装包。
const String kCloudBaseEnvId = 'coursehub-d2gkbrgm7c877557a';

/// 从邮箱推导 CloudBase username。
///
/// 实测（2026-10-02）：注册接口的 username 必须匹配
/// `^[a-z][0-9a-z_-]{5,24}$`（纯小写字母开头、无 @/.），邮箱本体当
/// username 会被拒。故用确定性映射：邮箱清洗 + FNV-1a 指纹后缀——
/// 同一邮箱在注册与登录时推导出同一个 username，用户只需输入邮箱。
String _deriveUsername(String email) {
  final lower = email.trim().toLowerCase();
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(lower)) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  final suffix = hash.toRadixString(16).padLeft(8, '0').substring(0, 6);
  final sanitized = lower.replaceAll(RegExp(r'[^a-z0-9]'), '');
  final stripped = sanitized.replaceFirst(RegExp(r'^[^a-z]+'), '');
  final base = stripped.isEmpty
      ? 'user'
      : (stripped.length > 15 ? stripped.substring(0, 15) : stripped);
  // 形如 zwt70-a1b2c3：总长 8~22，小写字母开头，匹配注册正则
  return '$base-$suffix';
}

/// CloudBase 后端实现（PG 模式环境，2026-10-02 定稿）：
/// HTTP 直连（auth.v1 + PostgREST 风格 /v1/rdb/rest 用户级 Bearer 通道），
/// 与 SupabaseBackend 同为手写 http，不依赖任何第三方 SDK（方案 §2.2/§2.4）。
///
/// 与 Supabase 实现的关键差异（§2.4 事实）：
/// - 登录 `POST /auth/v1/signin` 用 `{username, password}`（邮箱当 username），
///   免验证码；注册必须邮箱验证码三步（send → verify → signup），注册响应
///   自带会话（注册即登录）；
/// - access_token 仅 2 小时且 refresh_token 轮换（旧的立即失效）——刷新后
///   必须回写新 refresh_token，否则每 2 小时硬掉线一次；
/// - 会话存 `cloudbase_*` 命名空间 key，与 supabase_* 互不干扰；
/// - 备份走 PostgreSQL REST（`/v1/rdb/rest/user_backups`，一人一行，
///   payload jsonb），纯 JSON 无 EJSON 包装；上传用
///   `Prefer: resolution=merge-duplicates` 单次调用完成 upsert。
class CloudBaseBackend extends ChangeNotifier implements CloudBackend {
  CloudBaseBackend._internal();
  static final CloudBaseBackend _instance = CloudBaseBackend._internal();
  factory CloudBaseBackend() => _instance;
  static CloudBaseBackend get instance => _instance;

  static const String _baseUrl = 'https://$kCloudBaseEnvId.api.tcloudbasegateway.com';
  static const String _restBase = '$_baseUrl/v1/rdb/rest';
  static const String _table = 'user_backups';

  /// 单请求超时：DB/认证都是秒级接口，20s 足够宽裕；
  /// 后续 CloudRouter（阶段 2.5）的熔断依赖请求可终结
  static const Duration _requestTimeout = Duration(seconds: 20);

  String? _accessToken;
  String? _refreshToken;
  DateTime? _tokenExpiresAt;
  Map<String, dynamic>? _user;
  String? _lastError;
  Future<bool>? _refreshFuture;

  /// 发码 → 注册之间的待验证状态（只存 verification_id，验证码不落盘）
  String? _pendingVerificationId;
  String? _pendingVerificationEmail;

  // ---------------------------------------------------------------------------
  // CloudBackend 接口
  // ---------------------------------------------------------------------------

  @override
  String get id => 'cloudbase';

  /// envId 是编译期常量，配置恒齐；「可用」指配置层面，
  /// 服务端状态（登录方式未开等）通过具体操作的错误返回表达
  @override
  bool get isAvailable => true;

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
    final id = (user['sub'] ?? user['user_id'])?.toString();
    if (id == null || id.isEmpty) return null;
    return CloudAccount(
      userId: id,
      email: user['email']?.toString(),
      displayName: () {
        // username 是推导出来的机器名（zwt70-a1b2c3 形态），不作为展示名，
        // 让 UI 回退到 email；仅取用户自设的 name 字段（如有）
        final name = user['name']?.toString();
        return (name != null && name.isNotEmpty) ? name : null;
      }(),
      avatarUrl: () {
        final picture = user['picture']?.toString();
        return (picture == null || picture.isEmpty) ? null : picture;
      }(),
    );
  }

  @override
  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();

    _accessToken = prefs.getString('cloudbase_access_token');
    _refreshToken = prefs.getString('cloudbase_refresh_token');
    final expiresAtMs = prefs.getInt('cloudbase_token_expires_at');
    _tokenExpiresAt = expiresAtMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(expiresAtMs);

    final userJson = prefs.getString('cloudbase_user');
    if (userJson != null) {
      try {
        _user = jsonDecode(userJson) as Map<String, dynamic>;
      } catch (_) {
        _user = null;
      }
    }

    notifyListeners();
  }

  @override
  Future<AuthResult> signIn(String account, String password) async {
    _lastError = null;
    if (!isStrongPassword(password)) {
      _lastError = '密码需至少8位，且必须包含字母和数字';
      return AuthResult.failure(_lastError);
    }

    try {
      final response = await _post(
        '$_baseUrl/auth/v1/signin',
        authenticated: false,
        body: {
          'username': _deriveUsername(account),
          'password': password,
        },
      );

      if (response.statusCode != 200) {
        _lastError = _extractAuthError(response.body, fallback: '登录失败，请检查邮箱或密码是否正确');
        debugPrint('CloudBase 登录失败: ${response.statusCode} - ${response.body}');
        return AuthResult.failure(_lastError);
      }

      final payload = jsonDecode(response.body);
      if (payload is! Map<String, dynamic> || !await _persistTokens(payload)) {
        _lastError = '登录成功但保存会话失败';
        return AuthResult.failure(_lastError);
      }

      if (!await _fetchAndPersistUser()) {
        _lastError ??= '登录成功但获取用户信息失败';
        return AuthResult.failure(_lastError);
      }
      notifyListeners();
      return const AuthResult.ok();
    } catch (e) {
      _lastError = _describeNetworkError(e, '登录请求异常');
      debugPrint('CloudBase 登录失败: $e');
      return AuthResult.failure(_lastError);
    }
  }

  @override
  Future<AuthResult> sendRegisterCode(String account) async {
    _lastError = null;
    try {
      // target=ANY：注册时用户尚不存在，不要求账号已存在
      final response = await _post(
        '$_baseUrl/auth/v1/verification',
        authenticated: false,
        body: {'target': 'ANY', 'email': account},
      );

      if (response.statusCode != 200) {
        _lastError = _extractAuthError(response.body, fallback: '验证码发送失败');
        debugPrint('CloudBase 发送验证码失败: ${response.statusCode} - ${response.body}');
        return AuthResult.failure(_lastError);
      }

      final payload = jsonDecode(response.body);
      final verificationId =
          payload is Map<String, dynamic> ? payload['verification_id']?.toString() ?? '' : '';
      if (verificationId.isEmpty) {
        _lastError = '验证码发送失败';
        return AuthResult.failure(_lastError);
      }
      _pendingVerificationId = verificationId;
      _pendingVerificationEmail = account;
      return const AuthResult.ok();
    } catch (e) {
      _lastError = _describeNetworkError(e, '验证码发送失败');
      debugPrint('CloudBase 发送验证码失败: $e');
      return AuthResult.failure(_lastError);
    }
  }

  @override
  Future<AuthResult> register(
    String account,
    String password, {
    String? verificationCode,
  }) async {
    _lastError = null;
    if (!isStrongPassword(password)) {
      _lastError = '密码需至少8位，且必须包含字母和数字';
      return AuthResult.failure(_lastError);
    }
    final code = verificationCode?.trim() ?? '';
    if (code.isEmpty) {
      _lastError = '请输入邮箱验证码';
      return AuthResult.failure(_lastError);
    }
    final verificationId = _pendingVerificationId;
    if (verificationId == null ||
        _pendingVerificationEmail != account ||
        verificationId.isEmpty) {
      _lastError = '请先获取邮箱验证码';
      return AuthResult.failure(_lastError);
    }

    try {
      // 第一步：验证码换 verification_token（600 秒有效）
      final verifyResponse = await _post(
        '$_baseUrl/auth/v1/verification/verify',
        authenticated: false,
        body: {'verification_id': verificationId, 'verification_code': code},
      );
      if (verifyResponse.statusCode != 200) {
        _lastError = _extractAuthError(verifyResponse.body, fallback: '验证码错误，请重新输入');
        debugPrint('CloudBase 验证码校验失败: ${verifyResponse.statusCode} - ${verifyResponse.body}');
        return AuthResult.failure(_lastError);
      }
      final verifyPayload = jsonDecode(verifyResponse.body);
      final verificationToken = verifyPayload is Map<String, dynamic>
          ? verifyPayload['verification_token']?.toString() ?? ''
          : '';
      if (verificationToken.isEmpty) {
        _lastError = '验证码校验失败，请重试';
        return AuthResult.failure(_lastError);
      }

      // 第二步：注册。username 由邮箱确定性推导（邮箱本体不匹配注册正则，
      // 见 _deriveUsername 注释；登录时用同一推导，用户感知仍是「邮箱+密码」）。
      final signupResponse = await _post(
        '$_baseUrl/auth/v1/signup',
        authenticated: false,
        body: {
          'email': account,
          'verification_token': verificationToken,
          'username': _deriveUsername(account),
          'password': password,
        },
      );
      if (signupResponse.statusCode != 200) {
        _lastError = _extractAuthError(signupResponse.body, fallback: '注册失败');
        debugPrint('CloudBase 注册失败: ${signupResponse.statusCode} - ${signupResponse.body}');
        return AuthResult.failure(_lastError);
      }

      // 注册响应即标准 token 响应（注册即登录）
      final payload = jsonDecode(signupResponse.body);
      if (payload is! Map<String, dynamic> || !await _persistTokens(payload)) {
        _lastError = '注册成功但保存会话失败';
        return AuthResult.failure(_lastError);
      }
      _pendingVerificationId = null;
      _pendingVerificationEmail = null;

      if (!await _fetchAndPersistUser()) {
        _lastError ??= '注册成功但获取用户信息失败';
        return AuthResult.failure(_lastError);
      }
      notifyListeners();
      return const AuthResult.ok();
    } catch (e) {
      _lastError = _describeNetworkError(e, '注册请求异常');
      debugPrint('CloudBase 注册失败: $e');
      return AuthResult.failure(_lastError);
    }
  }

  @override
  Future<void> signOut() async {
    // 服务端登出 best-effort：token 已失效/网络断也要完成本地登出
    try {
      await _post('$_baseUrl/auth/v1/user/signout', authenticated: true, body: {});
    } catch (e) {
      debugPrint('CloudBase 服务端登出失败（忽略）: $e');
    }
    await expireSessionPreserveUser();
  }

  @override
  Future<void> clearLocalAccountData() async {
    _accessToken = null;
    _refreshToken = null;
    _tokenExpiresAt = null;
    _user = null;
    _lastError = null;
    _pendingVerificationId = null;
    _pendingVerificationEmail = null;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('cloudbase_access_token');
    await prefs.remove('cloudbase_refresh_token');
    await prefs.remove('cloudbase_token_expires_at');
    await prefs.remove('cloudbase_user');

    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 会话与刷新（§2.4 修正 2：refresh_token 轮换，必须回写）
  // ---------------------------------------------------------------------------

  Future<bool> _persistTokens(Map<String, dynamic> payload) async {
    final accessToken = payload['access_token']?.toString() ?? '';
    final refreshToken = payload['refresh_token']?.toString() ?? '';
    if (accessToken.isEmpty || refreshToken.isEmpty) return false;
    final expiresIn = (payload['expires_in'] as num?)?.toInt() ?? 7200;

    _accessToken = accessToken;
    _refreshToken = refreshToken;
    _tokenExpiresAt = DateTime.now().add(Duration(seconds: expiresIn));

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('cloudbase_access_token', accessToken);
    await prefs.setString('cloudbase_refresh_token', refreshToken);
    await prefs.setInt(
      'cloudbase_token_expires_at',
      _tokenExpiresAt!.millisecondsSinceEpoch,
    );
    return true;
  }

  Future<bool> _fetchAndPersistUser() async {
    final response = await _get('$_baseUrl/auth/v1/user/me', authenticated: true);
    if (response.statusCode != 200) {
      _lastError = _extractAuthError(response.body, fallback: '获取用户信息失败');
      return false;
    }
    final user = jsonDecode(response.body);
    if (user is! Map<String, dynamic>) {
      _lastError = '获取用户信息失败';
      return false;
    }
    _user = user;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('cloudbase_user', jsonEncode(user));
    return true;
  }

  /// 惰性刷新（single-flight）：并发 401 只发一次刷新请求。
  /// 轮换语义下这里绝不能并发重试——第二次会用已作废的 refresh_token，
  /// 直接把会话刷没。
  Future<bool> refreshSession() {
    return _refreshFuture ??= _doRefreshSession().whenComplete(() {
      _refreshFuture = null;
    });
  }

  Future<bool> _doRefreshSession() async {
    final refreshToken = _refreshToken;
    if (refreshToken == null || refreshToken.isEmpty) return false;

    try {
      final response = await _post(
        '$_baseUrl/auth/v1/token',
        authenticated: false,
        body: {'grant_type': 'refresh_token', 'refresh_token': refreshToken},
      );

      if (response.statusCode != 200) {
        // 400/401：refresh_token 已失效（轮换作废/被撤销），会话真过期；
        // 5xx 等其余状态视为服务端暂时故障，不动会话，下次操作再试
        if (response.statusCode == 400 || response.statusCode == 401) {
          await expireSessionPreserveUser(message: '登录已过期，请重新登录');
        }
        return false;
      }

      final payload = jsonDecode(response.body);
      if (payload is! Map<String, dynamic> || !await _persistTokens(payload)) {
        return false;
      }
      debugPrint('CloudBase 会话已刷新（refresh_token 轮换回写完成）');
      return true;
    } catch (e) {
      // 网络异常不等于会话过期，保留会话下次再试
      debugPrint('CloudBase 刷新会话失败（网络异常，保留会话）: $e');
      return false;
    }
  }

  Future<void> expireSessionPreserveUser({String? message}) async {
    _accessToken = null;
    _refreshToken = null;
    _tokenExpiresAt = null;
    if (message != null && message.trim().isNotEmpty) {
      _lastError = message.trim();
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('cloudbase_access_token');
    await prefs.remove('cloudbase_refresh_token');
    await prefs.remove('cloudbase_token_expires_at');

    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 备份 CRUD（PostgREST /v1/rdb/rest，RLS 限定本人，语义与 SupabaseBackend 对齐）
  // ---------------------------------------------------------------------------

  bool get _isSessionReady {
    return hasSession && (account?.userId.isNotEmpty ?? false);
  }

  /// 带鉴权的请求执行：收到 401 时先惰性刷新（single-flight）再重试一次。
  /// fetch/upload/delete 三个操作幂等，重试安全。
  Future<http.Response> _sendWithRefresh(
    Future<http.Response> Function() send,
  ) async {
    var response = await send();
    if (response.statusCode == 401 && await refreshSession()) {
      response = await send();
    }
    return response;
  }

  Future<Map<String, String>> _dbHeaders({String? prefer}) async {
    final headers = await _baseHeaders();
    headers['Authorization'] = 'Bearer ${_accessToken ?? ''}';
    if (prefer != null) headers['Prefer'] = prefer;
    return headers;
  }

  @override
  Future<CloudBackupSnapshot?> fetchBackup() async {
    _lastError = null;

    if (!_isSessionReady) {
      _lastError = '请先完成登录';
      return null;
    }

    final userId = account!.userId;
    final uri = Uri.parse('$_restBase/$_table').replace(queryParameters: {
      'select': 'payload,updated_at',
      'user_id': 'eq.$userId',
      'limit': '1',
    });

    try {
      final response = await _sendWithRefresh(() async {
        return http
            .get(uri, headers: await _dbHeaders())
            .timeout(_requestTimeout);
      });
      if (response.statusCode != 200) {
        _lastError = _extractDbError(response.body, fallback: '获取云端备份失败');
        return null;
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! List || decoded.isEmpty) {
        return null; // 没有云端备份（非错误）
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

      final updatedAtMs = _parseMillis(row['updated_at']);
      return CloudBackupSnapshot(
        payload: payload,
        updatedAt: updatedAtMs == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(updatedAtMs),
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

    final userId = account!.userId;
    // 单次调用完成 upsert（主键 user_id 冲突时整行覆盖，payload 不是 merge）
    final uri = Uri.parse('$_restBase/$_table');

    try {
      final response = await _sendWithRefresh(() async {
        return http
            .post(
              uri,
              headers: await _dbHeaders(prefer: 'resolution=merge-duplicates'),
              body: jsonEncode({
                'user_id': userId,
                'payload': payload,
                'updated_at': DateTime.now().millisecondsSinceEpoch,
              }),
            )
            .timeout(_requestTimeout);
      });

      if (response.statusCode != 200 &&
          response.statusCode != 201 &&
          response.statusCode != 204) {
        _lastError = _extractDbError(response.body, fallback: '上传云端备份失败');
        debugPrint('CloudBase 上传备份失败: ${response.statusCode} - ${response.body}');
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

    final userId = account!.userId;
    final uri = Uri.parse('$_restBase/$_table').replace(queryParameters: {
      'user_id': 'eq.$userId',
    });

    try {
      final response = await _sendWithRefresh(() async {
        return http
            .delete(
              uri,
              headers: await _dbHeaders(prefer: 'return=representation'),
            )
            .timeout(_requestTimeout);
      });

      if (response.statusCode != 200 && response.statusCode != 204) {
        // 某些配置可能缺 DELETE 策略；回退为覆盖空 payload
        final fallbackSuccess = await uploadBackup(emptyBackupPayload());
        if (fallbackSuccess) {
          return true;
        }
        _lastError = _extractDbError(response.body, fallback: '删除云端备份失败');
        return false;
      }

      // return=representation 返回被删行：非空说明确实删掉了
      final deletedRows = jsonDecode(response.body);
      if (deletedRows is List && deletedRows.isNotEmpty) {
        return true;
      }

      // 0 行可能是「本来就没有」（幂等成功）也可能是被 RLS 静默拦下，
      // 拉一次确认实际状态
      final remaining = await fetchBackup();
      final verifyError = _lastError;
      if (remaining == null && verifyError == null) {
        return true;
      }
      if (remaining != null) {
        final fallbackSuccess = await uploadBackup(emptyBackupPayload());
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

  // ---------------------------------------------------------------------------
  // HTTP 工具
  // ---------------------------------------------------------------------------

  Future<Map<String, String>> _baseHeaders() async {
    return {
      'Content-Type': 'application/json',
      'x-device-id': await ensureCloudDeviceId(),
    };
  }

  Future<http.Response> _get(String url, {required bool authenticated}) async {
    final headers = await _baseHeaders();
    if (authenticated) {
      headers['Authorization'] = 'Bearer ${_accessToken ?? ''}';
    }
    return http.get(Uri.parse(url), headers: headers).timeout(_requestTimeout);
  }

  Future<http.Response> _post(
    String url, {
    required bool authenticated,
    Map<String, dynamic>? body,
  }) async {
    final headers = await _baseHeaders();
    if (authenticated) {
      headers['Authorization'] = 'Bearer ${_accessToken ?? ''}';
    }
    return http
        .post(Uri.parse(url), headers: headers, body: jsonEncode(body ?? {}))
        .timeout(_requestTimeout);
  }

  int? _parseMillis(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  /// 错误体兼容 `{code, message}`（网关标准）与 `{error, error_description}` 两种结构
  (String, String) _extractErrorParts(String responseBody) {
    try {
      final decoded = jsonDecode(responseBody);
      if (decoded is Map<String, dynamic>) {
        final code = (decoded['error'] ?? decoded['code'])?.toString() ?? '';
        final description =
            (decoded['error_description'] ?? decoded['message'] ?? decoded['msg'])?.toString() ?? '';
        return (code.trim(), description.trim());
      }
    } catch (_) {
      // 非 JSON 响应体，走 fallback
    }
    return ('', '');
  }

  String _extractAuthError(String responseBody, {required String fallback}) {
    final (code, description) = _extractErrorParts(responseBody);
    if (code.isEmpty && description.isEmpty) return fallback;
    return _mapAuthErrorToChinese(code, description: description, fallback: fallback);
  }

  String _mapAuthErrorToChinese(
    String code, {
    required String description,
    required String fallback,
  }) {
    final normalized = code.trim().toLowerCase();
    switch (normalized) {
      case 'invalid_username_or_password':
        return '用户名或密码错误';
      case 'captcha_required':
        return '操作过于频繁，请稍后再试';
      case 'invalid_status':
        return '账号已被临时锁定，请稍后再试';
      case 'password_not_set':
        return '该账号未设置密码，请重新注册';
      case 'invalid_verification_code':
        return '验证码错误，请重新输入';
      case 'rate_limit_exceeded':
        return '操作过于频繁，请 60 秒后再试';
      case 'user_not_found':
        return '该用户不存在';
      case 'invalid_email':
        return '邮箱格式不正确';
      case 'verification_expired':
        return '验证码已过期，请重新获取';
      case 'email_already_exists':
      case 'user_already_exists':
        return '该邮箱已注册，请直接登录';
    }
    if (normalized.contains('not enabled') || normalized.contains('disabled')) {
      return '当前登录方式未开启，请检查 CloudBase 控制台的登录方式配置';
    }
    if (description.isNotEmpty) return description;
    if (normalized.isNotEmpty) return code;
    return fallback;
  }

  String _extractDbError(String responseBody, {required String fallback}) {
    final (code, message) = _extractErrorParts(responseBody);
    final normalized = code.trim().toUpperCase();
    switch (normalized) {
      case 'PERMISSION_DENIED':
        return '云端备份权限被拒绝，请确认已在 SQL 编辑器执行 cloudbase/pg-user-backups.sql（建表 + RLS）';
      case 'INVALID_REQUEST':
        final lower = message.toLowerCase();
        if (lower.contains('permission') || lower.contains('denied')) {
          return '云端备份权限被拒绝，请确认已在 SQL 编辑器执行 cloudbase/pg-user-backups.sql（建表 + RLS）';
        }
        return message.isNotEmpty ? message : fallback;
      case 'RESOURCE_NOT_FOUND':
        return '云端备份表不存在，请先在 SQL 编辑器执行 cloudbase/pg-user-backups.sql';
      case 'RESOURCE_UNAVAILABLE':
      case 'OPERATION_FAILED':
        return '云端数据库暂时不可用，请稍后再试';
    }
    if (message.isNotEmpty) return message;
    return fallback;
  }

  String _describeNetworkError(Object e, String prefix) {
    if (e is TimeoutException) return '$prefix: 网络请求超时';
    return '$prefix: ${e.toString()}';
  }
}
