import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 课程实时提醒的偏好快照
class LiveCourseUpdateSettings {
  final bool enabled;

  /// 提前多少分钟出现胶囊（0 = 上课那一刻才出现）
  final int leadMinutes;

  const LiveCourseUpdateSettings({
    required this.enabled,
    required this.leadMinutes,
  });
}

/// 安卓 16 实时活动（Live Updates）通道
///
/// 走的是 AOSP 统一标准：一条 ongoing + promoted-ongoing 的通知，由系统渲染成
/// 状态栏胶囊（小米超级岛 / OPPO 流体云 / vivo 原子通知同源），不接任何厂商私有
/// 协议、不需要白名单申请，也不需要服务端推送。
///
/// 展示与刷新全在原生侧由精确闹钟驱动（ClassLiveUpdateManager / Scheduler），
/// Flutter 进程不在也能跑完「课前出现 → 课中进度 → 下课消失」整个周期；
/// Dart 这边只负责三件事：读写偏好、把偏好同步给原生、课表变更后请原生重算。
class LiveUpdateService {
  LiveUpdateService._();

  static final LiveUpdateService instance = LiveUpdateService._();

  static const MethodChannel _channel = MethodChannel('coursehub/live_update');

  static const String _enabledKey = 'live_course_update_enabled';
  static const String _leadMinutesKey = 'live_course_update_lead_minutes';

  static const int defaultLeadMinutes = 10;

  /// 「课前通知时间」只允许这几档（0 = 仅上课时通知），不给自由滚轮取值
  static const List<int> leadChoices = <int>[0, 3, 5, 10, 15, 20, 30];

  /// 落偏好时吸附到最近的允许档位：老版本存过 1/2/12 这类值，不吸附就会
  /// 出现副标题与弹窗选中项不一致
  static int snapLead(int minutes) {
    var best = leadChoices.first;
    for (final choice in leadChoices) {
      if ((choice - minutes).abs() < (best - minutes).abs()) best = choice;
    }
    return best;
  }

  /// 该平台是否存在这条通道（仅安卓；Windows/Linux 预览与 iOS 一律不走）
  bool get platformSupported => !kIsWeb && Platform.isAndroid;

  Future<LiveCourseUpdateSettings> getSettings() async {
    final prefs = await SharedPreferences.getInstance();
    return LiveCourseUpdateSettings(
      enabled: prefs.getBool(_enabledKey) ?? false,
      leadMinutes:
          prefs.getInt(_leadMinutesKey) ?? defaultLeadMinutes,
    );
  }

  /// 落偏好 + 立刻同步给原生重排展示与闹钟
  Future<void> saveSettings({
    required bool enabled,
    required int leadMinutes,
  }) async {
    final lead = snapLead(leadMinutes);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, enabled);
    await prefs.setInt(_leadMinutesKey, lead);
    await _invoke('configure', {
      'enabled': enabled,
      'leadMinutes': lead,
    });
  }

  /// 启动时把 SharedPreferences 里的配置推给原生：原生闹钟链路读的是自己那份
  /// 私有偏好，必须靠这一步对齐（覆盖安装后尤其重要）
  Future<void> syncToNative() async {
    final settings = await getSettings();
    await _invoke('configure', {
      'enabled': settings.enabled,
      'leadMinutes': snapLead(settings.leadMinutes),
    });
  }

  /// 课表/学期配置变更后请原生按当前时间重算一次
  Future<void> refresh() async {
    await _invoke('refresh', null);
  }

  /// 示例胶囊的存活时长，与原生 ClassLiveUpdateManager.TEST_DURATION_MINUTES 一致
  static const int testDurationMinutes = 10;

  /// 立即显示一条示例胶囊：走的是与真实提醒完全相同的渲染路径，
  /// 用来在不改课表、不在上课时间的情况下确认系统到底会不会「上岛」。
  /// 返回 false = 原生侧调用本身抛了，跟"系统放没放行"是两回事
  Future<bool> startTest() => _invoke('startTest', null);

  Future<bool> stopTest() => _invoke('stopTest', null);

  /// 读系统自己对"这条通知能不能被提升成实时活动"的判定结果
  Future<Map<String, dynamic>> diagnose() async {
    if (!platformSupported) return const {};
    try {
      final map =
          await _channel.invokeMethod<Map<dynamic, dynamic>>('diagnose');
      return map?.cast<String, dynamic>() ?? const {};
    } catch (e) {
      debugPrint('[LiveUpdate] diagnose failed: $e');
      return const {};
    }
  }

  /// 判定结果压成一行，直接放在「测试实时活动」的副标题上方便截图
  ///
  /// 权限 ✗ + 放行 ✗ → uses-permission 声明了却没被授予，说明它是特权/签名级，
  ///   第三方走不通这条标准通道，得退回小米私有焦点通知协议；
  /// 权限 ✓ + 放行 ✗ → 权限拿到了系统仍不放行，最可能是 targetSdk 门槛；
  /// 放行 ✓ 形态 ✗ → 我们的通知本身不合格式要求；
  /// 两项都 ✓ 却仍不上岛 → 澎湃的岛只认小米私有协议。
  static String describeDiagnosis(Map<String, dynamic> d) {
    if (d.isEmpty) return '未取到系统判定';
    String mark(bool v) => v ? '✓' : '✗';
    final shape = d['promotable'] == true && d['promotedFlag'] == true;
    return '系统放行 ${mark(d['canPostPromoted'] == true)}'
        ' · 权限 ${mark(d['promotedPermission'] == true)}'
        ' · 形态 ${mark(shape)}'
        ' · SDK ${d['sdkInt'] ?? '-'}/target ${d['targetSdk'] ?? '-'}';
  }

  /// 系统是否支持实时活动形态（Android 16 起）；不支持时原生降级为普通常驻通知
  Future<bool> isSupported() async {
    if (!platformSupported) return false;
    try {
      final value = await _channel.invokeMethod<bool>('isSupported');
      return value ?? false;
    } catch (e) {
      debugPrint('[LiveUpdate] isSupported failed: $e');
      return false;
    }
  }

  /// 返回 false 表示原生侧抛了异常（例如通知构造失败），调用方必须把它和
  /// "系统未放行实时活动"区分开——之前正是把两者混成一句文案，把一次崩溃
  /// 报成了"未放行"，白查一轮
  Future<bool> _invoke(String method, Map<String, dynamic>? args) async {
    if (!platformSupported) return false;
    try {
      await _channel.invokeMethod<void>(method, args);
      return true;
    } catch (e) {
      debugPrint('[LiveUpdate] $method failed: $e');
      return false;
    }
  }

  /// 「课前通知时间」子项的展示文案：只有 7 个档位，0 档读作"仅上课时通知"
  String formatLeadText(int minutes) {
    final snapped = snapLead(minutes);
    if (snapped <= 0) return '仅上课时通知';
    return '$snapped 分钟';
  }
}
