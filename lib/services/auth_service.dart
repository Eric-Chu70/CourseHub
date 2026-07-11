import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

final RegExp _strongPasswordPattern = RegExp(r'^(?=.*[A-Za-z])(?=.*\d).{8,}$');

bool isStrongPassword(String password) {
  return _strongPasswordPattern.hasMatch(password);
}

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

class SupabaseService extends ChangeNotifier {
  static final SupabaseService _instance = SupabaseService._internal();
  factory SupabaseService() => _instance;
  SupabaseService._internal();

  static SupabaseService get instance => _instance;

  static const String _defaultSupabaseUrl = 'https://jnwhpbkhvumiyjwyjwhu.supabase.co';
  static const String _defaultAnonKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Impud2hwYmtodnVtaXlqd3lqd2h1Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzM4MzMxNjksImV4cCI6MjA4OTQwOTE2OX0.0hoiAxYNvLvvk1SyK-dbTs9hAjGOndmHTDH9l_1SUa8';

  String? _supabaseUrl = _defaultSupabaseUrl;
  String? _anonKey = _defaultAnonKey;
  String? _accessToken;
  String? _refreshToken;
  Map<String, dynamic>? _user;
  String? _lastError;

  bool get isConfigured => _supabaseUrl != null && _anonKey != null;
  bool get isAuthenticated => _accessToken != null && _user != null;
  String? get accessToken => _accessToken;
  String? get supabaseUrl => _supabaseUrl;
  String? get anonKey => _anonKey;
  String? get userName => _user?['user_metadata']?['full_name'] ?? _user?['user_metadata']?['name'];
  String? get userEmail => _user?['email'];
  String? get userAvatar => _user?['user_metadata']?['avatar_url'];
  String? get userId => _user?['id'];
  String? get lastError => _lastError;

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

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    
    _accessToken = prefs.getString('supabase_access_token');
    _refreshToken = prefs.getString('supabase_refresh_token');
    
    final userJson = prefs.getString('supabase_user');
    if (userJson != null) {
      _user = jsonDecode(userJson);
    }
    
    notifyListeners();
  }

  Future<bool> _fetchAndPersistUser(String accessToken, String refreshToken) async {
    _clearLastError();
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

  Future<bool> _persistSessionFromPayload(Map<String, dynamic> payload) async {
    final accessToken = payload['access_token'] as String?;
    final refreshToken = payload['refresh_token'] as String?;

    if (accessToken == null || accessToken.isEmpty || refreshToken == null || refreshToken.isEmpty) {
      return false;
    }

    return await _fetchAndPersistUser(accessToken, refreshToken);
  }

  Future<bool> signInWithEmailPassword(String email, String password) async {
    if (!isConfigured) {
      throw Exception('请先配置 Supabase URL 和 Anon Key');
    }

    _clearLastError();
    if (!isStrongPassword(password)) {
      _lastError = '密码需至少8位，且必须包含字母和数字';
      return false;
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
          'email': email,
          'password': password,
        }),
      );

      if (response.statusCode != 200) {
        _lastError = _extractAuthError(response.body, fallback: '登录失败，请检查邮箱或密码');
        debugPrint('邮箱密码登录失败: ${response.statusCode} - ${response.body}');
        return false;
      }

      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      final persisted = await _persistSessionFromPayload(payload);
      if (!persisted) {
        _lastError ??= '登录成功但保存会话失败';
        debugPrint('邮箱密码登录成功，但会话令牌缺失');
      }
      return persisted;
    } catch (e) {
      _lastError = '登录请求异常: ${e.toString()}';
      debugPrint('邮箱密码登录失败: $e');
      return false;
    }
  }

  Future<bool> registerWithEmailPassword(String email, String password) async {
    if (!isConfigured) {
      throw Exception('请先配置 Supabase URL 和 Anon Key');
    }

    _clearLastError();
    if (!isStrongPassword(password)) {
      _lastError = '密码需至少8位，且必须包含字母和数字';
      return false;
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
          'email': email,
          'password': password,
        }),
      );

      if (response.statusCode != 200 && response.statusCode != 201) {
        _lastError = _extractAuthError(response.body, fallback: '注册失败');
        debugPrint('邮箱密码注册失败: ${response.statusCode} - ${response.body}');
        return false;
      }

      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      final hasSession = await _persistSessionFromPayload(payload);
      if (hasSession) {
        return true;
      }

      // If signup returns no session (for example email confirmation is enabled),
      // try password login once for projects that disable confirmation.
      final signedIn = await signInWithEmailPassword(email, password);
      if (!signedIn) {
        _lastError ??= '注册成功但自动登录失败，请检查是否关闭了邮箱确认';
        debugPrint('邮箱密码注册成功，但自动登录失败');
      }
      return signedIn;
    } catch (e) {
      _lastError = '注册请求异常: ${e.toString()}';
      debugPrint('邮箱密码注册失败: $e');
      return false;
    }
  }

  Future<bool> handleAuthCallback(String accessToken, String refreshToken) async {
    try {
      return await _fetchAndPersistUser(accessToken, refreshToken);
    } catch (e) {
      debugPrint('处理认证回调失败: $e');
      return false;
    }
  }

  Future<void> signOut() async {
    await expireSessionPreserveUser();
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

  Map<String, dynamic>? get user => _user;
}

class AuthService extends ChangeNotifier {
  static final AuthService _instance = AuthService._internal();
  factory AuthService() => _instance;
  AuthService._internal() {
    _supabase.addListener(_handleSupabaseChanged);
  }

  static AuthService get instance => _instance;

  final SupabaseService _supabase = SupabaseService.instance;

  bool _isLoading = false;
  String? _error;

  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get isAuthenticated => _supabase.isAuthenticated;
  String? get userName => _supabase.userName;
  String? get userEmail => _supabase.userEmail;
  String? get userAvatar => _supabase.userAvatar;
  bool get isConfigured => _supabase.isConfigured;
  static bool isStrongPassword(String password) => _strongPasswordPattern.hasMatch(password);

  void _handleSupabaseChanged() {
    notifyListeners();
  }

  Future<void> init() async {
    await _supabase.init();
    notifyListeners();
  }

  Future<void> configure(String url, String anonKey) async {
    try {
      _setLoading(true);
      await _supabase.configure(url, anonKey);
      notifyListeners();
    } catch (e) {
      _setError('配置失败: ${e.toString()}');
    } finally {
      _setLoading(false);
    }
  }

  Future<bool> signInWithEmailPassword(String email, String password) async {
    try {
      _setLoading(true);
      _clearError();

      if (!_supabase.isConfigured) {
        _setError('请先配置 Supabase');
        return false;
      }

      final success = await _supabase.signInWithEmailPassword(email, password);
      if (!success) {
        _setError(_supabase.lastError ?? '登录失败，请检查邮箱或密码是否正确');
      }
      return success;
    } catch (e) {
      _setError('邮箱密码登录失败: ${e.toString()}');
      return false;
    } finally {
      _setLoading(false);
    }
  }

  Future<bool> registerWithEmailPassword(String email, String password) async {
    try {
      _setLoading(true);
      _clearError();

      if (!_supabase.isConfigured) {
        _setError('请先配置 Supabase');
        return false;
      }

      final success = await _supabase.registerWithEmailPassword(email, password);
      if (!success) {
        _setError(_supabase.lastError ?? '注册失败');
      }
      return success;
    } catch (e) {
      _setError('邮箱密码注册失败: ${e.toString()}');
      return false;
    } finally {
      _setLoading(false);
    }
  }

  Future<bool> handleAuthCallback(String accessToken, String refreshToken) async {
    try {
      _setLoading(true);
      final success = await _supabase.handleAuthCallback(accessToken, refreshToken);
      notifyListeners();
      return success;
    } catch (e) {
      _setError('认证回调处理失败: ${e.toString()}');
      return false;
    } finally {
      _setLoading(false);
    }
  }

  Future<void> signOut() async {
    try {
      _setLoading(true);
      await _supabase.signOut();
      notifyListeners();
    } catch (e) {
      _setError('登出失败: ${e.toString()}');
    } finally {
      _setLoading(false);
    }
  }

  Future<void> clearConfig() async {
    try {
      _setLoading(true);
      await _supabase.clearConfig();
      notifyListeners();
    } catch (e) {
      _setError('清除配置失败: ${e.toString()}');
    } finally {
      _setLoading(false);
    }
  }

  Future<void> clearLocalAccountData() async {
    try {
      _setLoading(true);
      await _supabase.clearLocalAccountData();
      notifyListeners();
    } catch (e) {
      _setError('清除账号信息失败: ${e.toString()}');
    } finally {
      _setLoading(false);
    }
  }

  void _setLoading(bool value) {
    _isLoading = value;
    notifyListeners();
  }

  void _setError(String error) {
    _error = error;
    notifyListeners();
  }

  void _clearError() {
    _error = null;
  }

  void clearError() {
    _clearError();
    notifyListeners();
  }
}
