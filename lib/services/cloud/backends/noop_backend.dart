import '../cloud_backend.dart';

/// 降级后端：云端不可用（未配置/熔断/两端皆断）时的兜底。
/// 零网络请求，所有操作返回明确的不可用状态——本地功能完全不受影响。
class NoopBackend implements CloudBackend {
  const NoopBackend();

  static const String _unavailableMessage = '云端暂不可用，请稍后再试';

  @override
  String get id => 'none';

  @override
  bool get isAvailable => false;

  @override
  Future<void> restore() async {}

  @override
  CloudAccount? get account => null;

  @override
  String? get accessToken => null;

  @override
  bool get hasSession => false;

  @override
  String? get lastError => _unavailableMessage;

  @override
  Future<AuthResult> signIn(String account, String password) async {
    return const AuthResult.failure(_unavailableMessage);
  }

  @override
  Future<AuthResult> register(
    String account,
    String password, {
    String? verificationCode,
  }) async {
    return const AuthResult.failure(_unavailableMessage);
  }

  @override
  Future<AuthResult> sendRegisterCode(String account) async {
    return const AuthResult.failure(_unavailableMessage);
  }

  @override
  Future<void> signOut() async {}

  @override
  Future<void> clearLocalAccountData() async {}

  @override
  Future<CloudBackupSnapshot?> fetchBackup() async => null;

  @override
  Future<bool> uploadBackup(Map<String, dynamic> payload) async => false;

  @override
  Future<bool> deleteBackup() async => false;
}
