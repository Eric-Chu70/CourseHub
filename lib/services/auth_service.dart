import 'package:flutter/foundation.dart';

import 'cloud/backends/cloudbase_backend.dart';
import 'cloud/backends/supabase_backend.dart';
import 'cloud/cloud_backend.dart' as cloud;

/// 云端账号门面。
///
/// 公开 API 与阶段 1 完全一致（新增项均为可选项：注册验证码参数与
/// [sendRegisterCode]，供 CloudBase 注册流程使用，旧调用方零改动）。
///
/// [_backend] 是阶段 2 的后端选择点：默认 CloudBase（迁移目标，境内可达），
/// 未配置时理论上回退 Supabase。阶段 2.5 由 CloudRouter 在这一个选择点
/// 接管（远程配置 + 熔断 + 内联故障转移），UI 与业务层不再变动。
class AuthService extends ChangeNotifier {
  static final AuthService _instance = AuthService._internal();
  factory AuthService() => _instance;
  AuthService._internal() {
    _supabase.addListener(_handleBackendChanged);
    _cloudbase.addListener(_handleBackendChanged);
  }

  static AuthService get instance => _instance;

  final SupabaseBackend _supabase = SupabaseBackend.instance;
  final CloudBaseBackend _cloudbase = CloudBaseBackend.instance;

  cloud.CloudBackend get _backend {
    if (_cloudbase.isAvailable) return _cloudbase;
    return _supabase;
  }

  /// 当前生效后端 id（'cloudbase' | 'supabase' | 'none'）。
  /// UI 据此决定注册是否需要邮箱验证码（CloudBase API 硬约束）。
  String get activeBackendId => _backend.id;

  /// 注册是否需要邮箱验证码：CloudBase 的 OpenAPI 明确不允许仅用
  /// 用户名密码注册（§2.4 修正 1），Supabase 路径保持免验证码
  bool get registrationRequiresCode => _backend.id == 'cloudbase';

  bool _isLoading = false;
  String? _error;

  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get isAuthenticated => _backend.hasSession;
  String? get userName => _backend.account?.displayName;
  String? get userEmail => _backend.account?.email;
  String? get userAvatar => _backend.account?.avatarUrl;
  bool get isConfigured => _backend.isAvailable;
  static bool isStrongPassword(String password) => cloud.isStrongPassword(password);

  void _handleBackendChanged() {
    notifyListeners();
  }

  /// 冷启动恢复：两个后端各自的命名空间会话都恢复（互不干扰），
  /// 生效后端由 [_backend] 决定。只读本地，不联网，不阻塞启动。
  Future<void> init() async {
    await Future.wait([
      _supabase.restore(),
      _cloudbase.restore(),
    ]);
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

      if (!_backend.isAvailable) {
        _setError('云端服务未配置');
        return false;
      }

      final result = await _backend.signIn(email, password);
      if (!result.success) {
        _setError(result.error ?? '登录失败，请检查邮箱或密码是否正确');
      }
      return result.success;
    } catch (e) {
      _setError('邮箱密码登录失败: ${e.toString()}');
      return false;
    } finally {
      _setLoading(false);
    }
  }

  /// [verificationCode] 仅 CloudBase 注册需要（邮箱验证码）；Supabase 路径忽略
  Future<bool> registerWithEmailPassword(
    String email,
    String password, {
    String? verificationCode,
  }) async {
    try {
      _setLoading(true);
      _clearError();

      if (!_backend.isAvailable) {
        _setError('云端服务未配置');
        return false;
      }

      final result = await _backend.register(
        email,
        password,
        verificationCode: verificationCode,
      );
      if (!result.success) {
        _setError(result.error ?? '注册失败');
      }
      return result.success;
    } catch (e) {
      _setError('邮箱密码注册失败: ${e.toString()}');
      return false;
    } finally {
      _setLoading(false);
    }
  }

  /// 发送注册邮箱验证码（仅验证码型后端支持）。
  /// 返回是否发送成功；失败原因看 [error]。
  Future<bool> sendRegisterCode(String email) async {
    try {
      _setLoading(true);
      _clearError();

      final result = await _backend.sendRegisterCode(email);
      if (!result.success) {
        _setError(result.error ?? '验证码发送失败');
      }
      return result.success;
    } catch (e) {
      _setError('验证码发送失败: ${e.toString()}');
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
      // 登出的是当前生效后端的会话；另一端会话按 §11.2 保留
      // （双端会话分命名空间隔离，故障转移时可直接复用对端会话）
      await _backend.signOut();
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

  /// 清除本地账号数据：双端一起清（语义是「抹掉本机账号痕迹」）
  Future<void> clearLocalAccountData() async {
    try {
      _setLoading(true);
      await _supabase.clearLocalAccountData();
      await _cloudbase.clearLocalAccountData();
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
