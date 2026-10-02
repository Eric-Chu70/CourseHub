import 'cloud/backends/cloudbase_backend.dart';
import 'cloud/backends/supabase_backend.dart';
import 'cloud/cloud_backend.dart';

export 'cloud/cloud_backend.dart' show CloudBackupSnapshot;

/// 云端备份门面。
///
/// 公开 API 与阶段 1 完全一致（fetchBackup / uploadBackup / deleteBackup /
/// lastError / CloudBackupSnapshot）。
///
/// [_backend] 是阶段 2 的后端选择点，与 AuthService 同一策略（默认 CloudBase）。
/// 阶段 2.5 由 CloudRouter 在这一个选择点接管，并叠加镜像双写与恢复对账。
class CloudSyncService {
  CloudSyncService._internal();

  static final CloudSyncService _instance = CloudSyncService._internal();
  factory CloudSyncService() => _instance;

  static CloudSyncService get instance => _instance;

  final SupabaseBackend _supabase = SupabaseBackend.instance;
  final CloudBaseBackend _cloudbase = CloudBaseBackend.instance;

  CloudBackend get _backend {
    if (_cloudbase.isAvailable) return _cloudbase;
    return _supabase;
  }

  String? get lastError => _backend.lastError;

  Future<CloudBackupSnapshot?> fetchBackup() {
    return _backend.fetchBackup();
  }

  Future<bool> uploadBackup(Map<String, dynamic> payload) {
    // 注入 updatedAt（毫秒时间戳）供跨端 LWW 冲突解决与恢复对账（§11.3）；
    // 双端写同一份 payload，时间戳语义对齐。schemaVersion 由 payload
    // 自带的 version 字段承担，不再重复注入。
    return _backend.uploadBackup({
      ...payload,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<bool> deleteBackup() {
    return _backend.deleteBackup();
  }
}
