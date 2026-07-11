import 'package:pocketbase/pocketbase.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PocketBaseService {
  static final PocketBaseService _instance = PocketBaseService._internal();
  factory PocketBaseService() => _instance;
  PocketBaseService._internal();

  static PocketBaseService get instance => _instance;

  late final PocketBase _pb;
  late final SharedPreferences _prefs;

  static const String baseUrl = 'http://127.0.0.1:8090';
  static const String _authTokenKey = 'pb_auth_token';
  static const String _authProviderKey = 'pb_auth_provider';

  bool _isInitialized = false;

  PocketBase get pb => _pb;
  bool get isAuthenticated => _pb.authStore.isValid;
  String? get userId => _pb.authStore.model?.id;
  String? get userEmail => _pb.authStore.model?.data['email'];
  String? get userName => _pb.authStore.model?.data['name'];
  String? get authProvider => _prefs.getString(_authProviderKey);

  Future<void> init() async {
    if (_isInitialized) return;

    _prefs = await SharedPreferences.getInstance();
    _pb = PocketBase(baseUrl);

    final savedToken = _prefs.getString(_authTokenKey);
    if (savedToken != null && savedToken.isNotEmpty) {
      _pb.authStore.save(savedToken, null);
    }

    _pb.authStore.onChange.listen((event) async {
      if (_pb.authStore.isValid) {
        await _prefs.setString(_authTokenKey, _pb.authStore.token);
      } else {
        await _prefs.remove(_authTokenKey);
        await _prefs.remove(_authProviderKey);
      }
    });

    _isInitialized = true;
  }

  Future<void> saveAuthProvider(String provider) async {
    await _prefs.setString(_authProviderKey, provider);
  }

  Future<void> signOut() async {
    _pb.authStore.clear();
    await _prefs.remove(_authTokenKey);
    await _prefs.remove(_authProviderKey);
  }

  Future<List<RecordModel>> getCourses() async {
    if (!isAuthenticated) throw Exception('用户未登录');
    
    final records = await _pb.collection('courses').getFullList(
      sort: '-created',
      filter: 'userId = "$userId"',
    );
    return records;
  }

  Future<RecordModel> createCourse(Map<String, dynamic> data) async {
    if (!isAuthenticated) throw Exception('用户未登录');
    
    data['userId'] = userId;
    return await _pb.collection('courses').create(body: data);
  }

  Future<RecordModel> updateCourse(String courseId, Map<String, dynamic> data) async {
    if (!isAuthenticated) throw Exception('用户未登录');
    
    return await _pb.collection('courses').update(courseId, body: data);
  }

  Future<void> deleteCourse(String courseId) async {
    if (!isAuthenticated) throw Exception('用户未登录');
    
    await _pb.collection('courses').delete(courseId);
  }

  Future<void> syncCourses(List<Map<String, dynamic>> localCourses) async {
    if (!isAuthenticated) return;

    for (final course in localCourses) {
      try {
        final existing = await _pb.collection('courses').getFirstListItem(
          'localId = "${course['id']}" && userId = "$userId"',
        );
        await updateCourse(existing.id, course);
      } catch (e) {
        await createCourse({...course, 'localId': course['id']});
      }
    }
  }

  Future<void> uploadOCRResult(String ocrText, Map<String, dynamic> parsedData) async {
    if (!isAuthenticated) throw Exception('用户未登录');
    
    await _pb.collection('ocr_history').create(body: {
      'userId': userId,
      'rawText': ocrText,
      'parsedData': parsedData,
    });
  }
}
