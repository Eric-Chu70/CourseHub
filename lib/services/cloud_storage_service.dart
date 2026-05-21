import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'auth_service.dart';
import '../utils/storage.dart';

class CloudStorageService {
  final String appId;
  final String appKey;
  final String apiUrl;
  
  String? _sessionToken;
  
  CloudStorageService({
    required this.appId,
    required this.appKey,
    required this.apiUrl,
  });
  
  Map<String, String> get _headers => {
    'X-LC-Id': appId,
    'X-LC-Key': appKey,
    'Content-Type': 'application/json',
    if (_sessionToken != null) 'X-LC-Session': _sessionToken!,
  };

  Future<void> initSession() async {
    if (AuthService.currentUserId == null || AuthService.currentApiKey == null) {
      throw Exception('用户未登录');
    }
    
    final response = await http.post(
      Uri.parse('$apiUrl/1.1/login'),
      headers: {
        'X-LC-Id': appId,
        'X-LC-Key': appKey,
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'username': _hashApiKey(AuthService.currentApiKey!),
        'password': AuthService.currentApiKey,
      }),
    );
    
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      _sessionToken = data['sessionToken'];
    } else {
      throw Exception('获取会话失败');
    }
  }

  Future<SyncResult> uploadAllData() async {
    final result = SyncResult();
    
    try {
      if (_sessionToken == null) await initSession();
      
      final localData = StorageService.exportData();
      
      final existingData = await _fetchCloudData();
      
      if (existingData != null) {
        await _updateCloudData(existingData['objectId'], localData);
        result.action = SyncAction.updated;
      } else {
        await _createCloudData(localData);
        result.action = SyncAction.created;
      }
      
      result.success = true;
      result.timestamp = DateTime.now();
    } catch (e) {
      result.success = false;
      result.errorMessage = e.toString();
    }
    
    return result;
  }

  Future<SyncResult> downloadAllData({bool merge = true}) async {
    final result = SyncResult();
    
    try {
      if (_sessionToken == null) await initSession();
      
      final cloudData = await _fetchCloudData();
      
      if (cloudData == null) {
        result.success = false;
        result.errorMessage = '云端暂无数据';
        return result;
      }
      
      final data = Map<String, dynamic>.from(cloudData['data'] ?? {});
      
      if (merge) {
        final importResult = await StorageService.importData(
          data,
          mode: ImportMode.merge,
        );
        result.imported = importResult.summary;
      } else {
        await StorageService.clearAllData();
        final importResult = await StorageService.importData(
          data,
          mode: ImportMode.replace,
        );
        result.imported = importResult.summary;
      }
      
      result.success = true;
      result.timestamp = DateTime.now();
    } catch (e) {
      result.success = false;
      result.errorMessage = e.toString();
    }
    
    return result;
  }

  Future<Map<String, dynamic>?> _fetchCloudData() async {
    final userId = AuthService.currentUserId;
    if (userId == null) return null;
    
    final response = await http.get(
      Uri.parse('$apiUrl/1.1/classes/UserData?where=${Uri.encodeComponent(jsonEncode({'userId': userId}))}'),
      headers: _headers,
    );
    
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      final results = data['results'] as List;
      if (results.isNotEmpty) {
        return results.first as Map<String, dynamic>;
      }
    }
    
    return null;
  }

  Future<void> _createCloudData(Map<String, dynamic> data) async {
    final userId = AuthService.currentUserId;
    if (userId == null) throw Exception('用户未登录');
    
    final response = await http.post(
      Uri.parse('$apiUrl/1.1/classes/UserData'),
      headers: _headers,
      body: jsonEncode({
        'userId': userId,
        'data': data,
      }),
    );
    
    if (response.statusCode != 201) {
      final error = jsonDecode(response.body);
      throw Exception(error['error'] ?? '创建失败');
    }
  }

  Future<void> _updateCloudData(String objectId, Map<String, dynamic> data) async {
    final response = await http.put(
      Uri.parse('$apiUrl/1.1/classes/UserData/$objectId'),
      headers: _headers,
      body: jsonEncode({
        'data': data,
      }),
    );
    
    if (response.statusCode != 200) {
      final error = jsonDecode(response.body);
      throw Exception(error['error'] ?? '更新失败');
    }
  }

  Future<DateTime?> getLastSyncTime() async {
    final cloudData = await _fetchCloudData();
    if (cloudData == null) return null;
    
    final updatedAt = cloudData['updatedAt'];
    if (updatedAt != null) {
      return DateTime.parse(updatedAt);
    }
    
    return null;
  }

  String _hashApiKey(String apiKey) {
    final bytes = utf8.encode(apiKey);
    final hash = sha256.convert(bytes);
    return 'ds_${hash.toString().substring(0, 16)}';
  }
}

enum SyncAction {
  created,
  updated,
}

class SyncResult {
  bool success = false;
  String? errorMessage;
  SyncAction? action;
  DateTime? timestamp;
  String? imported;
  
  String get displayText {
    if (!success) return errorMessage ?? '同步失败';
    
    final actionText = action == SyncAction.created ? '已上传' : '已更新';
    final timeText = timestamp != null 
        ? '${timestamp!.year}-${timestamp!.month.toString().padLeft(2, '0')}-${timestamp!.day.toString().padLeft(2, '0')} ${timestamp!.hour.toString().padLeft(2, '0')}:${timestamp!.minute.toString().padLeft(2, '0')}'
        : '';
    
    if (imported != null && imported!.isNotEmpty) {
      return '$actionText ($imported) $timeText';
    }
    
    return '$actionText $timeText';
  }
}
