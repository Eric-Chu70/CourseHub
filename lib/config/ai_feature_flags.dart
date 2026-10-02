import 'package:shared_preferences/shared_preferences.dart';

/// 「AI设置 → AI 功能」下的两个子开关。
///
/// 两者从属于 AI 功能总开关：总开关关闭时子项不展示、也不生效
/// （调用方需同时判断 ai_enabled）。默认值取 true——首次 AI 功能配置正常
/// （能开启总开关）时两个子项即为开启，用户没主动关过就不需要写入偏好。
///
/// 这里刻意做成「同步缓存 + 异步预热」，理由和 ReduceMotionFlag 一样：
/// 待办页的上下间距（父页 build 时算）和 AI 卡片的定相（同一帧挂载时算）
/// 必须读到同一个值。若各自 await SharedPreferences，两者会错开一帧，
/// 表现为「关闭时每次进入都播一遍折叠动画」和「重新打开时顶间距要等
/// 分析跑完才复原」。缓存由 [refresh] 在 runApp 前预热，之后由 setter
/// 就地更新，因此任何时刻同步读到的都是最新值。
class AIAutoAnalysisFlags {
  AIAutoAnalysisFlags._();

  /// 待办页 AI 任务分析模块
  static const String taskKey = 'ai_auto_task_analysis';

  /// 对话页进入时自动分析课表（关闭后直接展示默认欢迎消息）
  static const String scheduleKey = 'ai_auto_schedule_analysis';

  static bool _task = true;
  static bool _schedule = true;

  static bool get taskEnabled => _task;

  static bool get scheduleEnabled => _schedule;

  /// 从磁盘预热缓存。App 启动时（runApp 之前）await 一次即可；
  /// 运行期的变更全部经下面两个 setter 走，无需再 refresh。
  static Future<void> refresh() async {
    final prefs = await SharedPreferences.getInstance();
    _task = prefs.getBool(taskKey) ?? true;
    _schedule = prefs.getBool(scheduleKey) ?? true;
  }

  static Future<void> setTaskEnabled(bool value) async {
    _task = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(taskKey, value);
  }

  static Future<void> setScheduleEnabled(bool value) async {
    _schedule = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(scheduleKey, value);
  }

  /// 首次配置 AI 时按所选提供商落默认值。
  ///
  /// 内置节点走的是应用出的公共额度，让它默认开着两个自动分析会白耗公共
  /// 资源，所以选内置时两个都置 false；用户自己填 key 的（Agnes 要填
  /// `agnes_api_key`、自定义要填 `custom_api_key`）默认 true。
  ///
  /// 只在偏好里从没写过该键时才写——用户手动拨过开关之后，切换提供商
  /// 不再覆盖他的选择。判断用 `containsKey` 而不是读值，因为"没写过"
  /// 和"写过 false"在 `getBool(key) ?? true` 下结果是一样的。
  static Future<void> applyFirstRunDefaults({required bool builtin}) async {
    final prefs = await SharedPreferences.getInstance();
    final value = !builtin;
    if (!prefs.containsKey(taskKey)) {
      _task = value;
      await prefs.setBool(taskKey, value);
    }
    if (!prefs.containsKey(scheduleKey)) {
      _schedule = value;
      await prefs.setBool(scheduleKey, value);
    }
  }
}
