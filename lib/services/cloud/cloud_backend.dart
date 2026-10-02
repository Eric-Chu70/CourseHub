/// 云后端抽象与公共值类型。
///
/// 所有实现必须遵守的约束：
/// - [CloudBackend.restore] 只读本地存储，不发网络请求，不阻塞启动；
/// - 失败通过返回值表达（AuthResult / null / false + lastError），不向 UI 抛异常；
/// - 三个备份操作语义幂等，可被上层路由安全重试。
///
/// 阶段 2.5 的 CloudRouter 将插在门面层与本抽象之间，
/// 按远程配置 + 熔断状态在多个实现间自动路由。
library;

import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// 后端无关的账号视图
class CloudAccount {
  const CloudAccount({
    required this.userId,
    this.email,
    this.displayName,
    this.avatarUrl,
  });

  final String userId;
  final String? email;
  final String? displayName;
  final String? avatarUrl;
}

/// 登录 / 注册结果
class AuthResult {
  const AuthResult.ok()
      : success = true,
        error = null;

  const AuthResult.failure([this.error])
      : success = false;

  final bool success;
  final String? error;
}

/// 云端备份快照
class CloudBackupSnapshot {
  const CloudBackupSnapshot({
    required this.payload,
    this.updatedAt,
  });

  final Map<String, dynamic> payload;
  final DateTime? updatedAt;
}

final RegExp _strongPasswordPattern = RegExp(r'^(?=.*[A-Za-z])(?=.*\d).{8,}$');

/// 密码强度要求：至少 8 位且同时包含字母和数字
bool isStrongPassword(String password) {
  return _strongPasswordPattern.hasMatch(password);
}

/// 「空备份」判定（各后端拉取共用）：空 namedTimetables 且无任何旧版
/// 数据结构时视为没有备份（返回 null 快照，UI 按「云端无备份」处理）。
bool isEmptyBackupPayload(Map<String, dynamic> payload) {
  final namedTimetables = payload['namedTimetables'];
  final hasLegacyData = (payload['courses'] is List) ||
      (payload['tasks'] is List) ||
      (payload['settings'] is Map);
  return namedTimetables is Map && namedTimetables.isEmpty && !hasLegacyData;
}

/// 空备份内容（各后端「删除失败回退覆盖空 payload」共用）
Map<String, dynamic> emptyBackupPayload() {
  return {
    'version': '2.0',
    'backupType': 'full_named_timetables',
    'namedTimetables': <String, dynamic>{},
  };
}

/// 全 App 共享的设备识别号持久化 key 与生成逻辑。
///
/// 身份：应用内随机生成的串（非 IMEI/OAID 等硬件标识，无隐私合规问题），
/// 首次生成后持久化，之后所有需要「设备身份」的请求都带它：
/// CloudBase HTTP 请求（x-device-id 头）与 AI 中转的每日限量（阶段 3）。
/// CloudBase 文档约束：device id 长度需小于 72。
const String kCloudDeviceIdPrefKey = 'cloudbase_device_id';

final Random _deviceRandom = Random.secure();

Future<String> ensureCloudDeviceId() async {
  final prefs = await SharedPreferences.getInstance();
  var id = prefs.getString(kCloudDeviceIdPrefKey);
  if (id == null || id.isEmpty) {
    final values = List<int>.generate(16, (_) => _deviceRandom.nextInt(256));
    id = 'cb-${values.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
    await prefs.setString(kCloudDeviceIdPrefKey, id);
  }
  return id;
}

/// 登录 + 备份的统一插槽。
/// [id] 取值：'supabase' | 'cloudbase' | 'none'
abstract class CloudBackend {
  String get id;

  /// 配置齐全且未被降级
  bool get isAvailable;

  /// 冷启动恢复本地会话（只读本地，不联网）
  Future<void> restore();

  Future<AuthResult> signIn(String account, String password);

  /// [verificationCode] 仅验证码型后端（如 CloudBase 邮箱注册）需要
  Future<AuthResult> register(
    String account,
    String password, {
    String? verificationCode,
  });

  /// 发送注册验证码；不支持的后端返回 failure
  Future<AuthResult> sendRegisterCode(String account);

  Future<void> signOut();

  Future<void> clearLocalAccountData();

  CloudAccount? get account;
  String? get accessToken;
  bool get hasSession;
  String? get lastError;

  Future<CloudBackupSnapshot?> fetchBackup();
  Future<bool> uploadBackup(Map<String, dynamic> payload);
  Future<bool> deleteBackup();
}
