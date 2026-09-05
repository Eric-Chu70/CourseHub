import 'dart:async' show unawaited;
import 'dart:collection' show UnmodifiableListView;
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show HapticFeedback, SystemChannels, rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/course.dart';
import '../services/shiguang/shiguang_bridge.dart';
import '../services/shiguang/shiguang_course_converter.dart';
import '../services/shiguang/shiguang_index_service.dart';
import '../services/shiguang/shiguang_models.dart';
import '../services/shiguang/shiguang_request_proxy.dart';
import '../utils/storage.dart';
import '../widgets/blur_selection_menu.dart';
import '../widgets/glass_dialog.dart';
import '../widgets/shiguang_import_preview_dialog.dart';
import '../widgets/toast_notification.dart';

/// 教务系统导入 - WebView 页。
///
/// 用户在本页内登录教务系统并导航到课表页面，点击悬浮「开始导入」按钮
/// 注入适配脚本；脚本通过 ShiguangBridge 回传课程数据，经转换预览后落库。
class ShiguangWebImportScreen extends StatefulWidget {
  final ShiguangSchool school;
  final ShiguangAdapter adapter;

  const ShiguangWebImportScreen({
    super.key,
    required this.school,
    required this.adapter,
  });

  @override
  State<ShiguangWebImportScreen> createState() =>
      _ShiguangWebImportScreenState();
}

class _ShiguangWebImportScreenState extends State<ShiguangWebImportScreen>
    with TickerProviderStateMixin {
  InAppWebViewController? _webController;
  final TextEditingController _urlController = TextEditingController();
  final FocusNode _urlFocus = FocusNode();

  bool _pageLoaded = false;
  bool _importRunning = false;
  bool _loading = false;

  /// 帮助悬浮卡片（Overlay）是否可见。
  bool _helpVisible = false;
  OverlayEntry? _helpEntry;
  /// 帮助卡展开时按返回：先播放收回动画，动画完成后真正退出。
  bool _pendingPop = false;

  // ---------- 底部网址导航条 ----------

  /// 形态：true = 完全形态（后退/前进 + 输入框），false = 精简形态（锁 + 域名）。
  bool _barExpanded = true;
  /// 滚动方向检测（onScrollChanged 不带 oldY，自行记录上次位置）。
  double _lastScrollY = 0;
  bool _canGoBack = false;
  bool _canGoForward = false;
  /// 减弱动态效果：导航条无模糊高不透明、帮助卡片无缩放动画。
  bool _reduceMotion = false;
  /// 加载中图标的持续旋转动画（🔄）。
  late final AnimationController _spinController;
  /// 安全锁显隐动画（屏幕级持久控制器）：图标原地 scale + 淡入淡出
  /// [+ 模糊]，宽度位移与图标共用同一动画值（[_lockCurved]），逐帧同步
  /// ——不存在 AnimatedContainer 隐式补间被子树重建打断的闪现问题。
  /// 持久化的关键——锁图标分属全量/精简两个子树，AnimatedSwitcher 切换
  /// 形态时子树 State 会被销毁重建，若控制器放在子组件内，重建的新实例
  /// 直接以满态出现（动画「没生效」的根因）。控制器挂在屏幕 State 上，
  /// 两种形态共用同一动画值，切换无缝衔接。
  late final AnimationController _lockCtrl;
  late final CurvedAnimation _lockCurved;
  /// 当前是否显示锁（驱动精简条总宽目标计算，见 [_compactBarWidth]）。
  bool _lockVisible = false;
  /// 用户在预览对话框手动取消导入：脚本 catch 随后的失败弹窗
  /// （showAlert「导入失败」）降级为顶部提示，不再弹对话框。
  bool _importCancelled = false;
  /// 缓存的 WebView 实例：父级 setState（导航条形态切换等）不再重建平台视图，
  /// 避免 WebView 子树反复重建导致的交互卡顿。
  Widget? _cachedWebView;
  /// UA 模式：默认手机版（系统默认 UA，与拾光原 App 一致，适配脚本的选择器
  /// 对应手机 UA 渲染的 DOM）；个别学校教务只有 PC 页面时手动切换。
  bool _useDesktopUa = false;
  bool _uaPrefLoaded = false;
  /// UA 切换后待恢复的网址：平台视图重建后加载，保证不丢当前页面。
  String? _pendingUrlAfterRebuild;

  // 桌面版 UA：WakeUp 同款做法——取系统真实 UA 反转 Mobile/Android 字样
  // （服务器识别不到移动标识返回桌面版，但保留真实 Chromium 版本号，
  // 不伪造版本号导致前端按新特性输出旧内核跑不动的代码）。
  // 兜底：未取到系统 UA 前用固定串（内核 124+，风险极低）。
  String? _realSystemUa;
  static const String _fallbackDesktopUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  String get _desktopUa {
    final ua = _realSystemUa;
    if (ua == null || ua.isEmpty) return _fallbackDesktopUa;
    return ua.replaceAll('Mobile', 'eliboM').replaceAll('Android', 'diordnA');
  }

  /// 手机模式清洗后的 UA（去除 WebView 指纹标记）。每个会话从系统 UA
  /// 现取现清洗（保证 Chromium 版本号与真实内核一致），未取到前为 null
  /// （首跳以系统默认 UA 的空白页创建）。
  String? _mobileUaClean;
  /// WebView 重建代号：UA 清洗后需在同模式下强制重建平台视图，
  /// 变更 ValueKey 保证旧实例销毁、新实例带新 UA 创建。
  int _webviewGen = 0;

  /// 主文档请求头代理：重写 sec-ch-ua 等 WebView 指纹头（内核网络层
  /// 生成，JS 无法改写，shouldInterceptRequest 是唯一改写点）。
  late final ShiguangRequestProxy _reqProxy = ShiguangRequestProxy(
    acceptLanguage: _deviceAcceptLanguage(),
  );

  /// 按设备 locale 生成 Accept-Language（内核网络层会发该头，但
  /// shouldInterceptRequest 层不可见，代理需自行补齐）。
  static String _deviceAcceptLanguage() {
    try {
      final locales =
          WidgetsBinding.instance.platformDispatcher.locales;
      if (locales.isEmpty) return 'zh-CN,zh;q=0.9,en;q=0.8';
      final first = locales.first;
      final primary = (first.countryCode?.isNotEmpty ?? false)
          ? '${first.languageCode}-${first.countryCode}'
          : first.languageCode;
      final parts = <String>[primary];
      if (first.languageCode != primary) {
        parts.add('${first.languageCode};q=0.9');
      }
      parts.add('en;q=0.8');
      return parts.join(',');
    } catch (_) {
      return 'zh-CN,zh;q=0.9,en;q=0.8';
    }
  }

  /// 清洗 UA 中的 WebView 指纹：移除「; wv」与「Version/4.0 」标记
  /// （两者均为 Android WebView 独有，任何浏览器 UA 都没有；瑞数等
  /// WAF 据此识别 WebView 并循环下发挑战页，导致 VMP 永不通过）。
  static String _sanitizeUa(String ua) => ua
      .replaceAll('; wv', '')
      .replaceAll(' wv)', ')')
      .replaceAll('Version/4.0 ', '')
      .replaceAll(RegExp(r'\s{2,}'), ' ')
      .trim();

  @override
  void initState() {
    super.initState();
    _initUrl();
    _loadUaPref();
    _loadReduceMotion();
    // 焦点变化驱动右侧按钮形态：输入中 → 前往，非输入 → 刷新。
    _urlFocus.addListener(_onUrlFocusChanged);
    _spinController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _lockCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _lockCurved = CurvedAnimation(
      parent: _lockCtrl,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
  }

  void _onUrlFocusChanged() {
    if (mounted) setState(() {});
    // 焦点变化影响锁显隐（输入状态隐藏锁）。
    _updateLockVisibility();
  }

  /// 锁显隐目标：非加载中 + 当前地址为 https + 网址输入框未聚焦
  /// （真浏览器行为：解析中无锁；http 明文不显示；输入中地址栏让位）。
  bool _computeLockTarget() {
    if (_loading) return false;
    if (_urlFocus.hasFocus) return false;
    final text = _urlController.text;
    if (text.isEmpty) return false;
    final uri = Uri.tryParse(text.startsWith('http') ? text : 'https://$text');
    return uri?.scheme == 'https';
  }

  /// 统一锁状态更新入口：目标变化时翻转 [_lockVisible] 并驱动
  /// [_lockCtrl] forward/reverse。所有影响条件的事件（加载态切换 /
  /// 页面 URL 更新 / 焦点变化）都调用本方法，避免散落的 setState
  /// 遗漏某条路径导致锁状态不同步。
  void _updateLockVisibility() {
    final target = _computeLockTarget();
    if (target == _lockVisible) return;
    setState(() => _lockVisible = target);
    if (target) {
      _lockCtrl.forward();
    } else {
      _lockCtrl.reverse();
    }
  }

  // 反爬（瑞数等）环境对抗已下沉到本地补丁的 flutter_inappwebview_android
  // （local_plugins/，见 pubspec.yaml dependency_overrides）：不再向页面
  // 注入 window.flutter_inappwebview 桥对象与插件常驻脚本（Promise polyfill /
  // 桥胶水 / window.print 覆写 / 焦点失焦监听 / keydown 监听），页面环境
  // 等价于纯净原生 WebView；导入通信走控制台通道（ShiguangBridge.glueJs），
  // 因此无需任何 document-start 伪装脚本。

  Future<void> _loadReduceMotion() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _reduceMotion = prefs.getBool('reduce_motion_enabled') ?? false;
    });
  }

  /// 统一的加载状态入口：旋转动画只在加载期间运行。
  /// repeat() 常驻会让整页永远无法进入 idle（每帧都在渲染），是交互卡顿根源之一。
  void _setLoading(bool value) {
    if (_loading == value) return;
    setState(() => _loading = value);
    // 加载完成（true→false）→ 锁平滑滑入；开始加载 → 锁淡出。
    _updateLockVisibility();
    if (value) {
      _spinController.repeat();
    } else {
      _spinController.stop();
    }
  }

  Future<void> _loadUaPref() async {
    final desktop = await ShiguangIndexService.getUseDesktopUa();
    // 一次性清空 WebView HTTP 缓存：旧版本被瑞数挑战污染的响应可能已被
    // 缓存为 JS 子资源，环境修复后残留缓存仍会复现「$ is not defined」。
    String? storedRawUa;
    try {
      final prefs = await SharedPreferences.getInstance();
      // 原始系统 UA（含 wv 标记）：供桌面版派生跨会话使用（内存中的
      // _realSystemUa 每会话由手机模式首跳重新捕获刷新）。
      storedRawUa = prefs.getString('sg_system_ua_raw');
      if (prefs.getBool('sg_import_cache_cleared') != true) {
        await prefs.setBool('sg_import_cache_cleared', true);
        await InAppWebViewController.clearAllCache();
      }
    } catch (_) {}
    if (storedRawUa != null && storedRawUa.isNotEmpty) {
      _realSystemUa ??= storedRawUa;
    }
    if (!mounted) return;
    setState(() {
      _useDesktopUa = desktop;
      _uaPrefLoaded = true;
    });
  }

  /// 切换手机版/电脑版页面：销毁并重建 WebView（带新 UA 的平台视图），
  /// 确保立即生效。Cookie 全局持久，登录态不丢；当前页面重建后自动恢复。
  Future<void> _toggleUaMode() async {
    final controller = _webController;
    if (controller == null) return;
    final useDesktop = !_useDesktopUa;
    var currentUrl = '';
    try {
      currentUrl = (await controller.getUrl())?.toString() ?? '';
    } catch (_) {}
    await ShiguangIndexService.saveUseDesktopUa(useDesktop);
    if (!mounted) return;
    setState(() {
      _useDesktopUa = useDesktop;
      _pendingUrlAfterRebuild = currentUrl;
      _webController = null;
      // 置空缓存触发平台视图重建：setSettings 对已创建 WebView 的
      // userAgent 修改不生效（需退出重进），重建才是可靠路径。
      _cachedWebView = null;
      _setLoading(true);
    });
    toastNotification.show(
      context,
      useDesktop ? '已切换为电脑版页面' : '已切换为手机版页面',
      type: ToastType.info,
    );
  }

  /// 长按 UA 按钮：WebView 内核诊断（UA、Chromium 版本评估 + 升级指引）。
  Future<void> _showWebviewDiagnostics() async {
    var ua = '';
    try {
      ua = await _webController?.evaluateJavascript(
              source: 'navigator.userAgent') as String? ??
          '';
    } catch (_) {}

    // 解析 Chromium 主版本（Chrome/xx）。
    final match = RegExp(r'Chrome/(\d+)').firstMatch(ua);
    final chromeVersion = match != null ? int.parse(match.group(1)!) : null;

    String assessment;
    if (chromeVersion == null) {
      assessment = '未能识别内核版本';
    } else if (chromeVersion >= 80) {
      assessment = '内核较新，一般可正常渲染现代网页';
    } else if (chromeVersion >= 60) {
      assessment = '内核偏旧，部分新网页可能加载异常';
    } else {
      assessment = '内核过旧，很多现代网页会缺失元素。'
          '建议更新系统 WebView 组件';
    }

    if (!mounted) return;
    await showBouncyDialog<void>(
      context: context,
      barrierLabel: 'WebView 诊断',
      shellPadding: const EdgeInsets.all(24),
      shellMaxWidth: 420,
      shellBoxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.2),
          blurRadius: 20,
          offset: const Offset(0, 10),
        ),
      ],
      builder: (context) {
        return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                          colors: [Color(0xFF9B59B6), Color(0xFFAF7AC5)]),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.memory,
                        size: 22, color: Colors.white),
                  ),
                  const SizedBox(width: 12),
                  const Text(
                    'WebView 内核诊断',
                    style: TextStyle(
                        fontSize: 17, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                'Chromium 内核版本：${chromeVersion ?? '未知'}',
                style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1A1A2E)),
              ),
              const SizedBox(height: 6),
              Text('评估：$assessment',
                  style: TextStyle(
                      fontSize: 13, color: Colors.grey.shade700)),
              const SizedBox(height: 12),
              // 清除 WebView 缓存 + Cookie 并刷新：瑞数把环境判定编码在
              // 客户端生成的 T cookie 里（Bk8UVSeWhgi3T 等 13 位随机名），
              // 补环境修复后必须清掉旧 cookie 重新过挑战，否则服务端
              // 沿用旧判定继续返回降级页面。缓存里也可能有被污染的
              // 挑战响应。
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () async {
                    try {
                      await InAppWebViewController.clearAllCache();
                      await CookieManager.instance().deleteAllCookies();
                      await _webController?.reload();
                    } catch (_) {}
                    if (context.mounted) {
                      Navigator.pop(context);
                      toastNotification.show(context, '已清除缓存和 Cookie 并刷新',
                          type: ToastType.success);
                    }
                  },
                  icon: const Icon(Icons.cleaning_services,
                      size: 16, color: Color(0xFF9B59B6)),
                  label: const Text('清除缓存和 Cookie 并刷新',
                      style: TextStyle(color: Color(0xFF9B59B6))),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(
                        color: Colors.deepPurple.shade200, width: 1.2),
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              if (ua.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('User-Agent：',
                    style: TextStyle(
                        fontSize: 11, color: Colors.grey.shade500)),
                const SizedBox(height: 4),
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 90),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SingleChildScrollView(
                    child: Text(
                      ua,
                      style: TextStyle(
                          fontSize: 10, color: Colors.grey.shade600),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF9B59B6),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('知道了'),
                ),
              ),
            ],
        );
      },
    );
  }

  Future<void> _initUrl() async {
    var url = widget.adapter.importUrl;
    if (url.isEmpty) {
      url = await ShiguangIndexService.getLastUrl(widget.adapter.adapterId) ??
          '';
    }
    if (mounted) {
      setState(() => _urlController.text = url);
    }
  }

  @override
  void dispose() {
    _reqProxy.dispose();
    _clearInputFocus();
    _urlFocus.removeListener(_onUrlFocusChanged);
    _urlController.dispose();
    _urlFocus.dispose();
    _spinController.dispose();
    _lockCurved.dispose();
    _lockCtrl.dispose();
    _helpEntry?.remove();
    _helpEntry = null;
    super.dispose();
  }

  /// 清除网址输入框焦点并收起键盘（参考对话页 clearInputFocus 做法）：
  /// 防止离开页面后焦点残留、键盘在切页时自动弹出。
  void _clearInputFocus() {
    _urlFocus.unfocus(disposition: UnfocusDisposition.scope);
    SystemChannels.textInput.invokeMethod('TextInput.hide');
  }

  // ---------- WebView 事件 ----------

  Future<void> _onWebViewCreated(InAppWebViewController controller) async {
    _webController = controller;

    // 手机模式首跳（每会话一次，_mobileUaClean 为 null 时）：WebView 以
    // 空白页 + 系统默认 UA 创建，此处捕获真实 UA → 清洗 WebView 指纹
    // （「; wv」/「Version/4.0」标记，瑞数按此识别 WebView 循环下发
    // 挑战页）→ 重建 WebView 用干净 UA 加载目标页（不与目标站交互，
    // 不产生脏 Cookie/缓存）。重建后 _pendingUrlAfterRebuild / 
    // initialUrlRequest / lastUrl 逻辑自动恢复页面。
    if (!_useDesktopUa && _mobileUaClean == null) {
      String? raw;
      try {
        raw = await controller.evaluateJavascript(
            source: 'navigator.userAgent') as String?;
      } catch (_) {}
      if (raw != null && raw.isNotEmpty) {
        final clean = _sanitizeUa(raw);
        _realSystemUa = raw;
        // 持久化原始 UA：桌面版派生在「会话直接以电脑模式进入」时使用。
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('sg_system_ua_raw', raw);
        } catch (_) {}
        if (!mounted || _webController != controller) return;
        if (clean != raw) {
          // 重建：gen 变更触发平台视图重建（同模式下 setSettings 修改
          // UA 对当前页不可靠，重建才是可靠路径——与 UA 切换一致）。
          setState(() {
            _mobileUaClean = clean;
            _webviewGen++;
            _webController = null;
            _cachedWebView = null;
          });
          return;
        }
        // 系统 UA 本就不含标记（部分定制内核）：直接采用，无需重建。
        _mobileUaClean = clean;
      } else {
        // 捕获失败：退回持久化的原始 UA 清洗；仍无则保持系统默认。
        final fallback = _realSystemUa;
        if (fallback != null && fallback.isNotEmpty) {
          _mobileUaClean = _sanitizeUa(fallback);
        }
      }
    }

    // UA 切换触发的平台视图重建：恢复切换前的页面（Cookie 持久，登录态不丢）。
    if (_pendingUrlAfterRebuild != null) {
      final url = _pendingUrlAfterRebuild!;
      _pendingUrlAfterRebuild = null;
      if (url.isNotEmpty && mounted && _webController == controller) {
        _setLoading(true);
        await controller
            .loadUrl(urlRequest: URLRequest(url: WebUri(url)));
      }
      return;
    }

    // 通用适配器没有预设网址：自动恢复上次输入的教务网址。
    if (widget.adapter.importUrl.isEmpty) {
      final lastUrl =
          await ShiguangIndexService.getLastUrl(widget.adapter.adapterId);
      if (lastUrl != null &&
          lastUrl.isNotEmpty &&
          mounted &&
          _webController == controller) {
        _urlController.text = lastUrl;
        _setLoading(true);
        await controller
            .loadUrl(urlRequest: URLRequest(url: WebUri(lastUrl)));
      }
    }
  }

  void _onLoadStop(InAppWebViewController controller, WebUri? url) async {
    final urlStr = url?.toString() ?? '';
    if (urlStr.isEmpty || urlStr == 'about:blank') {
      // about:blank（含首跳 UA 捕获页 / VMP 弹出的空白窗口）：做一次
      // chrome 补环境兜底注入——document-start 的 origin 规则不覆盖
      // 无源页面（about:blank），瑞数若在空白页上下文里做二次检测，
      // 这里保证 chrome 对象同样存在（幂等，已存在则直接返回）。
      try {
        await controller.evaluateJavascript(
            source: ShiguangBridge.chromeEnvJs);
      } catch (_) {}
      return;
    }
    // 桥胶水不在加载期注入（零环境痕迹），仅在 _startImport 时注入。
    if (url != null && mounted) {
      _urlController.text = urlStr;
      // URL 变化后同步锁显隐（http↔https 切换）；随后 _setLoading(false)
      // 也会兜底更新，此处先按新地址计算。
      _updateLockVisibility();
      await ShiguangIndexService.saveLastUrl(
          widget.adapter.adapterId, urlStr);
    }
    if (mounted) {
      setState(() => _pageLoaded = true);
      _setLoading(false);
    }
  }

  // ---------- 桥回调 ----------

  void _onBridgeToast(String message) {
    if (!mounted || message.isEmpty) return;
    toastNotification.show(context, message, type: ToastType.info);
  }

  Future<bool> _onBridgeAlert(
      String title, String message, String btnText) async {
    if (!mounted) return false;
    return await showBouncyDialog<bool>(
          context: context,
          barrierLabel: title.isEmpty ? '提示' : title,
          shellPadding: const EdgeInsets.all(24),
          shellMaxWidth: 400,
          shellConstraintsBuilder: (context) =>
              const BoxConstraints(maxWidth: 400, maxHeight: 480),
          builder: (context) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(colors: [
                      Color(0xFF9B59B6),
                      Color(0xFFAF7AC5)
                    ]),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.school,
                      size: 28, color: Colors.white),
                ),
                const SizedBox(height: 14),
                Text(
                  title.isEmpty ? '提示' : title,
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 10),
                Flexible(
                  child: SingleChildScrollView(
                    child: Text(
                      message,
                      style: TextStyle(
                          fontSize: 13,
                          height: 1.5,
                          color: Colors.grey.shade700),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(context, true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF9B59B6),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text(btnText.isEmpty ? '确定' : btnText),
                  ),
                ),
              ],
            );
          },
        ) ??
        false;
  }

  Future<void> _onBridgeSaveCourses(String jsonString) async {
    // 每次保存开始复位取消标志（上一次导入的取消不应影响本轮）。
    _importCancelled = false;
    final parsed = jsonDecode(jsonString);
    final result = ShiguangCourseConverter.convert(
      parsed,
      idPrefix: 'sg_${widget.school.id}',
    );
    if (result.courses.isEmpty) {
      throw Exception(
          '未解析到有效课程${result.skippedCount > 0 ? '（跳过 ${result.skippedCount} 条无效数据）' : ''}');
    }

    if (!mounted) throw Exception('页面已关闭');

    final mode = await ShiguangImportPreviewDialog.show(
      context,
      courses: result.courses,
      skippedCount: result.skippedCount,
      schoolName: widget.school.name,
    );
    if (mode == null) {
      // 手动取消：置标志让脚本 catch 随后的失败弹窗降级为顶部提示；
      // 仍 reject（不放行脚本走「导入成功」收尾）。
      _importCancelled = true;
      throw Exception('已取消导入');
    }
    if (!mounted) throw Exception('页面已关闭');

    // 与 JSON/AI 导入保持一致的落库链路。
    await StorageService.resetCurrentWeek();
    final data = {
      'courses': result.courses
          .map((Course c) => {
                'id': c.id,
                'name': c.name,
                'teacher': c.teacher,
                'location': c.location,
                'day': c.day,
                'time': c.time,
                'duration': c.duration,
                'weeks': c.weeks,
                'color': c.color,
              })
          .toList(),
    };
    final importResult =
        await StorageService.importData(data, mode: mode);
    if (!importResult.success) {
      throw Exception(importResult.errorMessage ?? '导入失败');
    }
    if (mounted) {
      toastNotification.show(
        context,
        '导入成功（${importResult.summary}）',
        type: ToastType.success,
      );
    }
  }

  void _onBridgeCompletion() {
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  // ---------- 控制台桥通道（JS → Dart 唯一通道） ----------

  /// 解析并分发 [[SG]] 前缀的控制台桥消息（见 [ShiguangBridge.glueJs]）。
  Future<void> _handleBridgeConsoleMessage(
      InAppWebViewController controller, String raw) async {
    final Map<String, dynamic> msg;
    try {
      msg = jsonDecode(raw.substring(ShiguangBridge.magicPrefix.length))
          as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final id = msg['id'];
    switch (msg['fn']) {
      case 'toast':
        _onBridgeToast((msg['msg'] ?? '').toString());
        break;
      case 'alert':
        // 手动取消导入后的首个失败弹窗（脚本 catch 收尾）降级为顶部
        // 提示：取消是用户主动行为，弹「导入失败」对话框造成误解；
        // resolve(true) 让脚本继续自身清理流程。
        if (_importCancelled) {
          _importCancelled = false;
          if (mounted) {
            toastNotification.show(context, '已取消导入',
                type: ToastType.info);
          }
          _sgResolveValue(controller, id, true);
          break;
        }
        final ok = await _onBridgeAlert(
          (msg['title'] ?? '').toString(),
          (msg['message'] ?? '').toString(),
          (msg['btnText'] ?? '').toString(),
        );
        _sgResolveValue(controller, id, ok);
        break;
      case 'save':
        // 大数据不走控制台（消息可能被截断）：JS 侧先存
        // window.__sgSavePayload，这里拉取后走统一导入链路。
        try {
          final payload = (await controller.evaluateJavascript(
                  source: 'window.__sgSavePayload')) as String?;
          if (payload == null || payload.isEmpty) {
            throw Exception('未收到课程数据');
          }
          await _onBridgeSaveCourses(payload);
          _sgResolveValue(controller, id, true);
        } catch (e) {
          // 拒绝（reject）而非 resolve(false)：适配脚本普遍不检查
          // saveImportedCourses 的返回值（UESTC 等），resolve(false) 会
          // 放行脚本继续走「导入成功」提示（取消后仍显示成功的根因）。
          // reject 让脚本 await 抛异常、进自身 catch 统一收尾（抽查
          // 8 校脚本均有 catch），失败 toast 由脚本弹出，此处不再重复。
          var msg = e.toString();
          if (msg.startsWith('Exception: ')) msg = msg.substring(11);
          _sgRejectValue(controller, id, msg);
        }
        break;
      case 'selection':
        // 拾光协议 v2：单选对话框。取消返回 null（脚本判 null/-1 均为取消）。
        try {
          final idx = await _onBridgeSingleSelection(
            (msg['title'] ?? '').toString(),
            (msg['labels'] ?? '[]').toString(),
            msg['defaultIdx'] is num ? msg['defaultIdx'] as num : 0,
          );
          _sgResolveValue(controller, id, idx);
        } catch (_) {
          _sgResolveValue(controller, id, null);
        }
        break;
      case 'prompt':
        // 拾光协议 v2：输入对话框。返回文本，取消返回 null。
        try {
          final text = await _onBridgePrompt(
            (msg['title'] ?? '').toString(),
            (msg['message'] ?? '').toString(),
            (msg['defaultText'] ?? '').toString(),
          );
          _sgResolveValue(controller, id, text);
        } catch (_) {
          _sgResolveValue(controller, id, null);
        }
        break;
      case 'timeSlots':
        // 作息时间段：落 SharedPreferences（脚本侧已 try-catch，
        // 失败不影响导入主流程，但尽量返回成功避免误报）。
        try {
          await _onBridgeSaveTimeSlots((msg['payload'] ?? '[]').toString());
          _sgResolveValue(controller, id, true);
        } catch (_) {
          _sgResolveValue(controller, id, false);
        }
        break;
      case 'config':
        // 课程配置（semesterTotalWeeks 等）：落 SharedPreferences。
        try {
          await _onBridgeSaveConfig((msg['payload'] ?? '{}').toString());
          _sgResolveValue(controller, id, true);
        } catch (_) {
          _sgResolveValue(controller, id, false);
        }
        break;
      case 'completion':
        _onBridgeCompletion();
        break;
    }
  }

  /// 桥 Promise 结果回填：调用页面内 window.__sgResolve(id, true, value)。
  ///
  /// value 为 null / bool / num；通过 ok=true + value 复用胶水的
  /// `value !== undefined ? value : true` 语义（null 恰好 !== undefined，
  /// 会被原样 resolve，满足单选「取消返回 null」的协议）。
  void _sgResolveValue(InAppWebViewController controller, dynamic id, dynamic value) {
    String js;
    if (value == null) {
      js = 'null';
    } else if (value is bool) {
      js = value ? 'true' : 'false';
    } else if (value is num) {
      js = '$value';
    } else {
      js = jsonEncode(value.toString());
    }
    unawaited(controller.evaluateJavascript(
        source: 'window.__sgResolve && window.__sgResolve($id, true, $js)'));
  }

  /// 桥 Promise 失败回填：reject(Error(errorMessage))。
  ///
  /// 适配脚本普遍不检查 saveImportedCourses 等的返回值，resolve(false)
  /// 会放行脚本继续走「导入成功」流程（取消后仍弹成功提示的根因）；
  /// reject 让 await 抛异常、进脚本自身 catch 统一收尾。
  void _sgRejectValue(InAppWebViewController controller, dynamic id, String errorMessage) {
    unawaited(controller.evaluateJavascript(
        source:
            'window.__sgResolve && window.__sgResolve($id, false, ${jsonEncode(errorMessage)})'));
  }

  /// 桥单选对话框（拾光 showSingleSelection）：返回选中索引，取消 null。
  Future<int?> _onBridgeSingleSelection(
      String title, String labelsJson, num defaultIdx) async {
    if (!mounted) return null;
    List<String> labels;
    try {
      labels = (jsonDecode(labelsJson) as List)
          .map((e) => e.toString())
          .toList(growable: false);
    } catch (_) {
      return null;
    }
    if (labels.isEmpty) return null;

    return showBouncyDialog<int>(
      context: context,
      barrierLabel: title.isEmpty ? '请选择' : title,
      shellPadding: const EdgeInsets.all(24),
      shellMaxWidth: 400,
      shellConstraintsBuilder: (context) =>
          const BoxConstraints(maxWidth: 400, maxHeight: 460),
      builder: (context) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [
                  Color(0xFF9B59B6),
                  Color(0xFFAF7AC5)
                ]),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(Icons.list_alt,
                  size: 28, color: Colors.white),
            ),
            const SizedBox(height: 14),
            Text(
              title.isEmpty ? '请选择' : title,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: labels.length,
                itemBuilder: (context, i) {
                  final selected = i == defaultIdx;
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Material(
                      color: selected
                          ? const Color(0xFF9B59B6).withValues(alpha: 0.12)
                          : Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => Navigator.pop(context, i),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 11),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  labels[i],
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: selected
                                        ? const Color(0xFF9B59B6)
                                        : Colors.grey.shade800,
                                    fontWeight: selected
                                        ? FontWeight.w600
                                        : FontWeight.normal,
                                  ),
                                ),
                              ),
                              if (selected)
                                const Icon(Icons.check_rounded,
                                    size: 18, color: Color(0xFF9B59B6)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.grey.shade600,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('取消'),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 桥输入对话框（拾光 showPrompt）：返回输入文本，取消 null。
  Future<String?> _onBridgePrompt(
      String title, String message, String defaultText) async {
    if (!mounted) return null;
    final controller = TextEditingController(text: defaultText);
    final result = await showBouncyDialog<String>(
      context: context,
      barrierLabel: title.isEmpty ? '请输入' : title,
      shellPadding: const EdgeInsets.all(24),
      shellMaxWidth: 400,
      shellConstraintsBuilder: (context) =>
          const BoxConstraints(maxWidth: 400, maxHeight: 460),
      builder: (context) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [
                  Color(0xFF9B59B6),
                  Color(0xFFAF7AC5)
                ]),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(Icons.edit_note,
                  size: 28, color: Colors.white),
            ),
            const SizedBox(height: 14),
            Text(
              title.isEmpty ? '请输入' : title,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
            if (message.isNotEmpty) ...[
              const SizedBox(height: 10),
              Flexible(
                child: SingleChildScrollView(
                  child: Text(
                    message,
                    style: TextStyle(
                        fontSize: 13,
                        height: 1.5,
                        color: Colors.grey.shade700),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(
                filled: true,
                fillColor: Colors.grey.shade100,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 12),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.grey.shade600,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () =>
                        Navigator.pop(context, controller.text),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF9B59B6),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('确定'),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
    controller.dispose();
    return result;
  }

  /// 作息时间段存储：按适配器隔离（拾光语义：预设作息，可在导入
  /// 预览/设置侧后续消费）。
  Future<void> _onBridgeSaveTimeSlots(String payload) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'sg_time_slots_${widget.adapter.adapterId}', payload);
  }

  /// 课程配置存储（semesterTotalWeeks 等），按适配器隔离。
  Future<void> _onBridgeSaveConfig(String payload) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'sg_course_config_${widget.adapter.adapterId}', payload);
  }

  /// JS alert/confirm 对话框：转成 App 风格弹窗（返回 true = 确定）。
  Future<bool?> _showJsDialog(String message,
      {required bool showCancel}) {
    return showBouncyDialog<bool>(
      context: context,
      barrierLabel: '网页消息',
      shellPadding: const EdgeInsets.all(24),
      shellMaxWidth: 400,
      shellBoxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.2),
          blurRadius: 20,
          offset: const Offset(0, 10),
        ),
      ],
      builder: (context) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                    colors: [Color(0xFF9B59B6), Color(0xFFAF7AC5)]),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(Icons.language,
                  size: 28, color: Colors.white),
            ),
            const SizedBox(height: 14),
            const Text(
              '网页消息',
              style:
                  TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            Flexible(
              child: SingleChildScrollView(
                child: Text(
                  message,
                  style: TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      color: Colors.grey.shade700),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                if (showCancel) ...[
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      style: TextButton.styleFrom(
                        padding:
                            const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(color: Colors.grey.shade300),
                        ),
                      ),
                      child: const Text('取消'),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(context, true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF9B59B6),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('确定'),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  // ---------- 导入动作 ----------

  Future<void> _startImport() async {
    final controller = _webController;
    if (controller == null || !_pageLoaded || _importRunning) return;

    // 新一轮导入：复位上一轮可能残留的取消标志（脚本 catch 若只 toast
    // 不弹窗，标志不会被 alert 消费，须在此兜底清除，避免误吞本轮弹窗）。
    _importCancelled = false;
    setState(() => _importRunning = true);
    try {
      // 1. 拉取适配脚本。
      toastNotification.show(context, '正在获取适配脚本...',
          type: ToastType.info);
      final script =
          await ShiguangIndexService.fetchAdapterScript(
              widget.school, widget.adapter);

      // 2. 注入拾光桥胶水（控制台通道版）：仅在用户点击导入时创建
      //    window.shiguangBridge，页面加载期零环境痕迹（对抗瑞数等
      //    反爬 WAF 的 window 指纹检测）。
      await controller.evaluateJavascript(source: ShiguangBridge.glueJs);

      // 3. 页面缺少 jQuery 时注入兜底库（适配脚本依赖 window.jQuery）。
      final hasJQuery = await controller
          .evaluateJavascript(source: 'typeof window.jQuery');
      if (hasJQuery == null || hasJQuery.toString() == 'undefined') {
        await _injectJquery(controller);
      }

      // 4. 注入适配脚本（IIFE，注入即执行导入流程）。
      await controller.evaluateJavascript(source: script);
    } catch (e) {
      if (mounted) {
        toastNotification.show(context, '导入脚本执行失败：$e',
            type: ToastType.error);
      }
    } finally {
      if (mounted) {
        setState(() => _importRunning = false);
      }
    }
  }

  Future<void> _injectJquery(InAppWebViewController controller) async {
    try {
      final jquery = await rootBundle
          .loadString('assets/shiguang/jquery-3.7.1.min.js');
      // 页面自身可能用 $（prototype.js 等老库），注入后恢复原 $，
      // 适配脚本只依赖 window.jQuery，不受影响。
      await controller.evaluateJavascript(source: '''
(function() {
  if (window.jQuery) return;
  var oldDollar = window.\$;
  $jquery
  if (oldDollar !== undefined) { window.\$ = oldDollar; }
})();
''');
    } catch (_) {
      // 注入失败交由适配脚本自身的 jQuery 检测提示。
    }
  }

  // ---------- URL 导航 ----------

  void _goToUrl() {
    final controller = _webController;
    if (controller == null) return;
    // 前往前收起键盘。
    _urlFocus.unfocus();
    var url = _urlController.text.trim();
    if (url.isEmpty) {
      toastNotification.show(context, '请输入教务系统网址',
          type: ToastType.info);
      return;
    }
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
      _urlController.text = url;
    }
    final uri = WebUri(url);
    _setLoading(true);
    controller.loadUrl(urlRequest: URLRequest(url: uri));
  }

  /// WebView 滚动方向 → 导航条形态：
  /// 向下滑浏览内容（滚动位置增大）切精简；回滑（位置减小）恢复完全形态。
  void _onWebScrollChanged(int y) {
    final delta = y - _lastScrollY;
    _lastScrollY = y.toDouble();
    // 输入框聚焦（编辑中）或正在加载时保持完全形态。
    if (_urlFocus.hasFocus || _loading) return;
    if (delta > 8 && _barExpanded) {
      setState(() => _barExpanded = false);
    } else if (delta < -8 && !_barExpanded) {
      setState(() => _barExpanded = true);
    }
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    // 细粒度依赖（仅 padding aspect）：键盘 viewInsets 每帧变化时
    // 不触发本组件 rebuild。
    final topPadding = MediaQuery.paddingOf(context).top;

    return PopScope(
      // 帮助卡展开时拦截返回：先播放收回动画再真正退出，避免 Overlay
      // 随页面销毁导致卡片闪现消失。
      canPop: _helpEntry == null,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _pendingPop = true;
        _removeHelpCard();
      },
      child: Scaffold(
        // 键盘弹出时不压缩 WebView；底部导航条自行随 viewInsets 上移。
        resizeToAvoidBottomInset: false,
        backgroundColor: const Color(0xFFF8F9FC),
        body: Column(
          children: [
            _buildPinnedHeader(topPadding),
            Expanded(child: _buildWebView()),
          ],
        ),
      ),
    );
  }

  Widget _buildPinnedHeader(double topPadding) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF8F9FC).withValues(alpha: 0.95),
        border: Border(
          bottom: BorderSide(color: Colors.grey.shade200, width: 0.5),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(height: topPadding),
          SizedBox(
            height: 52,
            child: Row(
              children: [
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    width: 48,
                    height: 52,
                    margin: const EdgeInsets.only(left: 4),
                    child: const Icon(
                      Icons.arrow_back_ios_new,
                      size: 18,
                      color: Color(0xFF1A1A2E),
                    ),
                  ),
                ),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.school.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF1A1A2E),
                        ),
                      ),
                      Text(
                        widget.adapter.adapterName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
                // UA 模式切换：电脑+右下角小手机的组合图标；
                // 灰色 = 手机 UA，紫色 = 电脑 UA。长按弹内核诊断。
                GestureDetector(
                  onTap: _toggleUaMode,
                  onLongPress: _showWebviewDiagnostics,
                  child: SizedBox(
                    width: 44,
                    height: 52,
                    child: Center(
                      child: _buildUaComboIcon(),
                    ),
                  ),
                ),
                // 帮助：点击弹出居中悬浮帮助卡片（使用步骤）。
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _toggleHelpCard,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 16),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.help_outline,
                            size: 18, color: Colors.deepPurple.shade400),
                        const SizedBox(width: 3),
                        Text(
                          '帮助',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Colors.deepPurple.shade400,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// UA 切换纯图标：灰色 = 当前手机 UA；紫色 = 当前电脑 UA。
  Widget _buildUaComboIcon() {
    final color = _useDesktopUa
        ? const Color(0xFF9B59B6)
        : Colors.grey.shade500;
    return Icon(Icons.desktop_windows, size: 24, color: color);
  }

  // ---------- 底部网址导航条 ----------

  /// 当前应显示的域名（精简形态文案）；解析失败退回原始输入。
  String _currentDomain() {
    final text = _urlController.text;
    if (text.isEmpty) return '输入教务系统网址';
    final uri = Uri.tryParse(
        text.startsWith('http') ? text : 'https://$text');
    final host = uri?.host ?? '';
    return host.isEmpty ? text : host;
  }

  /// 用 TextPainter 实测精简形态的内容宽度（锁 + 完整域名 + 内边距）。
  /// 不设固定上限：主域名必须完整展现（如 eams.uestc.edu.cn），
  /// 仅以屏幕宽度 - 32（左右悬浮边距）为界，超长域名单行省略。
  double _compactBarWidth(BuildContext context) {
    final maxW = MediaQuery.sizeOf(context).width - 32;
    final tp = TextPainter(
      text: TextSpan(
        text: _currentDomain(),
        style: TextStyle(
          fontSize: 11,
          color: const Color(0xFF1A1A2E),
          fontWeight: FontWeight.w500,
          // 与实际 Text 完全同字体：全局主题 Microsoft YaHei 会被实际
          // 渲染继承，测量若按默认字体则偏窄 → 域名尾部被截断（.cn 变 …）。
          fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
        ),
      ),
      // 与实际 Text 一致的字体缩放：大字体模式下测量若按 1.0 计算，
      // 实际渲染更宽 → 域名尾部被 ellipsis 截断（.cn 变 ...）。
      textScaler: MediaQuery.textScalerOf(context),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: maxW);
    // 锁区宽（锁 10.5 + 间距 5，随 _lockVisible 折叠）+ 12*2(左右内边距)
    // + 8(余量：含 border 3px)。
    final lockWidth = _lockVisible ? 10.5 + 5 : 0.0;
    return math.max(76.0, math.min(tp.width + lockWidth + 24 + 8, maxW));
  }

  /// 底部悬浮网址导航条：白底 + 模糊（减弱动态效果时无模糊高不透明）。
  /// 完全形态：[<] [>] [🔒 网址输入框 🔄]；精简形态：[🔒 域名]（宽度收缩）。
  Widget _buildBottomUrlBar() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      // 方案 b（键盘卡顿）：viewInsets 依赖收敛到本 Builder——键盘动画
      // 每帧变化时只重建导航条自身，页面其余部分（WebView/Header/
      // 导入按钮）零 rebuild。直接跟随 viewInsets（键盘动画期间逐帧
      // 更新），不加 AnimatedPadding：动画会在每帧 viewInsets 变化时
      // 重启，永远追不上键盘导致"滞后感"。
      child: Builder(
        builder: (bc) {
          final viewInsets = MediaQuery.viewInsetsOf(bc).bottom;
          final safeBottom = MediaQuery.paddingOf(bc).bottom;
          // 网页内部元素聚焦弹键盘（网址输入框未聚焦）→ 导航条临时缩减
          // 为精简形态（腾出可视区域），键盘收起后恢复滚动驱动的原形态。
          // 网址输入框自身聚焦时保持完全形态（输入状态）。
          final webKeyboard = viewInsets > 0 && !_urlFocus.hasFocus;
          final expanded = _barExpanded && !webKeyboard;
          return Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              bottom: viewInsets + safeBottom + 12,
            ),
            child: LayoutBuilder(builder: (context, constraints) {
              return Center(
                child: GestureDetector(
                  // 点击导航条非输入区域（完全形态下）脱焦收键盘；
                  // 输入框/按钮/精简条各有自己的手势，竞技场中子级胜出不受影响。
                  onTap: () {
                    if (expanded) _clearInputFocus();
                  },
                  child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeInOutCubic,
                  width: expanded
                      ? constraints.maxWidth
                      : _compactBarWidth(bc),
              // 完全形态高 50；精简形态进一步收窄到 38（更短更窄）。
              height: expanded ? 50.0 : 38.0,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(expanded ? 25 : 19),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(expanded ? 25 : 19),
                child: BackdropFilter(
                  // 纹理合成模式下开销可控（此前卡顿主因是混合合成，已切换）。
                  // 减弱动态效果：不模糊，白底提高到 0.94（与玻璃弹窗约定一致）。
                  filter: ImageFilter.blur(
                    sigmaX: _reduceMotion ? 0 : 20,
                    sigmaY: _reduceMotion ? 0 : 20,
                  ),
                  child: Container(
                    decoration: BoxDecoration(
                      color: _reduceMotion
                          ? Colors.white.withValues(alpha: 0.94)
                          : Colors.white.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(expanded ? 25 : 19),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.6),
                        width: 1.5,
                      ),
                    ),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      switchInCurve: Curves.easeOut,
                      switchOutCurve: Curves.easeIn,
                      transitionBuilder: (child, anim) =>
                          FadeTransition(opacity: anim, child: child),
                      child: expanded
                          ? KeyedSubtree(
                              key: const ValueKey('url_bar_full'),
                              child: _buildFullBarContent(),
                            )
                          : KeyedSubtree(
                              key: const ValueKey('url_bar_compact'),
                              child: _buildCompactBarContent(),
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        }),
      );
        },
      ),
    );
  }

  /// 完全形态内容：后退/前进 + 无边框网址输入（左实心锁，右 → 前往）。
  Widget _buildFullBarContent() {
    const black = Color(0xFF1A1A2E);
    final focused = _urlFocus.hasFocus;
    return Row(
      children: [
        // 输入状态下后退/前进收起：向左滑出 + 宽度折叠（网址区随左边界
        // 平滑外扩）；失焦时向右滑入恢复。OverflowBox 保持按钮固有
        // 尺寸，容器 clip 随宽度动画裁切。
        AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOutCubic,
          width: focused ? 0.0 : 76.0,
          height: 50,
          clipBehavior: Clip.hardEdge,
          decoration: const BoxDecoration(color: Colors.transparent),
          child: IgnorePointer(
            ignoring: focused,
            child: OverflowBox(
              alignment: Alignment.centerLeft,
              maxWidth: 76,
              child: AnimatedSlide(
                offset: focused ? const Offset(-1, 0) : Offset.zero,
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeInOutCubic,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 后退 <
                    GestureDetector(
                      onTap: _canGoBack ? () => _webController?.goBack() : null,
                      child: SizedBox(
                        width: 38,
                        height: 50,
                        child: Center(
                          child: Icon(
                            Icons.chevron_left,
                            size: 26,
                            color: _canGoBack ? black : Colors.grey.shade300,
                          ),
                        ),
                      ),
                    ),
                    // 前进 >
                    GestureDetector(
                      onTap:
                          _canGoForward ? () => _webController?.goForward() : null,
                      child: SizedBox(
                        width: 38,
                        height: 50,
                        child: Center(
                          child: Icon(
                            Icons.chevron_right,
                            size: 26,
                            color:
                                _canGoForward ? black : Colors.grey.shade300,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        // 实心黑锁：真浏览器行为——解析中 / http / 输入聚焦时无锁，
        // https 加载完成后出现。图标「原地」scale + 淡入 [+ 模糊]：
        // OverflowBox 不裁切（无 Clip），图标固定在最终位置（左缘 +12）
        // 只做自身出现动画，不随宽度裁切产生扫出效果；宽度 = 27 * t
        // 与图标共用同一动画值逐帧驱动——地址栏文本随宽度连续右移避让
        // / 左移回填，任何子树重建（形态切换）读当前 t 即无跳变。
        // 焦点 / 加载态切换统一由 _computeLockTarget 驱动 forward/reverse。
        AnimatedBuilder(
          animation: _lockCurved,
          child: IgnorePointer(
            child: OverflowBox(
              alignment: Alignment.centerLeft,
              maxWidth: 27,
              child: _LockAppear(
                animation: _lockCurved,
                reduceMotion: _reduceMotion,
                child: const Padding(
                  padding: EdgeInsets.only(left: 12, right: 2),
                  child: Icon(Icons.lock, size: 13, color: black),
                ),
              ),
            ),
          ),
          builder: (context, child) => SizedBox(
            width: 27.0 * _lockCurved.value,
            height: 50,
            child: child,
          ),
        ),
        // 无边框网址输入框：右侧刷新按钮
        // （加载中转 🔄，完成后静止 🔄，点击刷新或前往新输入的网址）。
        Expanded(
          child: TextField(
            contextMenuBuilder: styledEditableContextMenu,
            controller: _urlController,
            focusNode: _urlFocus,
            onSubmitted: (_) => _goToUrl(),
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.go,
            textAlignVertical: TextAlignVertical.center,
            style: const TextStyle(
              fontSize: 13,
              color: black,
            ),
            decoration: InputDecoration(
              hintText: '输入教务系统网址',
              hintStyle: TextStyle(
                color: Colors.grey.shade400,
                fontSize: 12.5,
              ),
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(vertical: 13, horizontal: 4),
              // 覆盖全局主题的灰色填充（filled grey[50]），参考对话页输入框。
              filled: true,
              fillColor: Colors.transparent,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              suffixIcon: _loading
                  ? Padding(
                      padding: const EdgeInsets.only(right: 14),
                      child: RotationTransition(
                        turns: _spinController,
                        child: const Icon(
                          Icons.sync,
                          size: 17,
                          color: black,
                        ),
                      ),
                    )
                  // 输入中 → 前往按钮（黑色 →，点击导航新网址）；
                  // 非输入 → 静止 🔄（刷新或前往被修改的网址）。
                  : _urlFocus.hasFocus
                      ? GestureDetector(
                          onTap: _goToUrl,
                          behavior: HitTestBehavior.opaque,
                          child: const Padding(
                            padding: EdgeInsets.only(right: 14),
                            child: Icon(
                              Icons.arrow_forward,
                              size: 19,
                              color: black,
                            ),
                          ),
                        )
                      : GestureDetector(
                          onTap: _onRefreshPressed,
                          behavior: HitTestBehavior.opaque,
                          child: const Padding(
                            padding: EdgeInsets.only(right: 14),
                            child: Icon(
                              Icons.sync,
                              size: 18,
                              color: black,
                            ),
                          ),
                        ),
              suffixIconConstraints: const BoxConstraints(
                minWidth: 33,
                minHeight: 33,
              ),
            ),
          ),
        ),
        const SizedBox(width: 2),
      ],
    );
  }

  /// 静止 🔄 按钮点击：输入的网址与当前页一致 → 刷新；
  /// 被改成了新网址 → 前往（跳转）。
  Future<void> _onRefreshPressed() async {
    final controller = _webController;
    if (controller == null) return;
    final typed = _urlController.text.trim();
    var current = '';
    try {
      current = (await controller.getUrl())?.toString() ?? '';
    } catch (_) {}
    // 归一化比较（自动补 https:// 前缀的逻辑与 _goToUrl 一致）。
    final normalized = typed.startsWith('http') ? typed : 'https://$typed';
    if (typed.isEmpty || normalized == current) {
      _setLoading(true);
      await controller.reload();
    } else {
      _goToUrl();
    }
  }

  /// 精简形态内容：实心锁 + 完整域名（点击恢复完全形态并聚焦输入）。
  /// 更小字号/图标/内边距，宽度按域名实际长度伸展（超屏才省略）。
  Widget _buildCompactBarContent() {
    const black = Color(0xFF1A1A2E);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.selectionClick();
        setState(() => _barExpanded = true);
        // 形态展开动画进行中同步弹键盘，保持即时可编辑。
        _urlFocus.requestFocus();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 锁同全量形态：原地 scale + 淡入 [+ 模糊]（无裁切，图标固定
            // 在最终位置），宽度 = 15.5 * t 与图标共用 _lockCurved 逐帧
            // 驱动，域名文本连续右移避让 / 左移回填；精简条总宽目标由
            // _compactBarWidth 的 _lockVisible 布尔驱动（单次翻转，
            // 外层 AnimatedContainer 平滑补间）。
            AnimatedBuilder(
              animation: _lockCurved,
              child: IgnorePointer(
                child: OverflowBox(
                  alignment: Alignment.centerLeft,
                  maxWidth: 15.5,
                  child: _LockAppear(
                    animation: _lockCurved,
                    reduceMotion: _reduceMotion,
                    child: const Padding(
                      padding: EdgeInsets.only(right: 5),
                      child: Icon(Icons.lock, size: 10.5, color: black),
                    ),
                  ),
                ),
              ),
              builder: (context, child) => SizedBox(
                width: 15.5 * _lockCurved.value,
                height: 38,
                child: child,
              ),
            ),
            Flexible(
              child: Text(
                _currentDomain(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: black,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- 帮助悬浮卡片 ----------

  /// 切换帮助卡片：已开则收回，未开则自顶栏下方居中弹出。
  void _toggleHelpCard() {
    if (_helpEntry != null) {
      _removeHelpCard();
      return;
    }
    _helpVisible = true;
    _helpEntry = OverlayEntry(
      builder: (context) => Stack(
        children: [
          // 透明屏障：点击卡片以外的任意处收回。
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _removeHelpCard,
            ),
          ),
          _ShiguangHelpCard(
            visible: _helpVisible,
            text: '使用步骤：${widget.adapter.description}\n'
                '1. 在底部输入教务系统网址并前往（通用适配需自行输入）\n'
                '2. 登录教务系统，切换到课表查询页面并加载出课表\n'
                '3. 点击「开始导入」按钮，解析完成后确认导入\n\n'
                '页面显示异常时，可点右上角组合图标切换手机/电脑版；'
                '长按该图标可查看 WebView 内核诊断。',
            onDismissed: () {
              _helpEntry?.remove();
              _helpEntry = null;
              // 帮助卡收回动画完成后：若退出被拦截过，现在真正退出。
              if (_pendingPop) {
                _pendingPop = false;
                if (mounted) Navigator.pop(context);
              }
            },
          ),
        ],
      ),
    );
    Overlay.of(context).insert(_helpEntry!);
    // 触发 rebuild：PopScope.canPop 需随帮助卡展开切换为 false。
    setState(() {});
  }

  void _removeHelpCard() {
    if (_helpEntry == null) return;
    // 翻转 visible 触发收回动画，动画完成后由 onDismissed 移除 entry。
    _helpVisible = false;
    setState(() {});
    _helpEntry!.markNeedsBuild();
  }

  Widget _buildWebView() {
    // 等 UA 偏好加载完成再创建 WebView，确保初始 UA 正确。
    if (!_uaPrefLoaded) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation(Color(0xFF9B59B6)),
          ),
        ),
      );
    }

    final initialUrl = widget.adapter.importUrl;
    // 手机模式首跳：以空白页创建（userAgent = null → 系统默认），
    // 由 _onWebViewCreated 捕获 UA 清洗后重建，避免脏 UA 触发挑战。
    final blankFirst = !_useDesktopUa && _mobileUaClean == null;

    return Stack(
      children: [
        // 只构建一次：导航条形态切换/图标变化等 setState 不再重建
        // InAppWebView 子树（平台视图重建是切换 UA 等操作卡顿的主因）。
        // UA 切换时显式置空 _cachedWebView 触发带新配置的重建。
        // 外层 Listener：触摸网页区域（事件会被平台视图消费）时让网址
        // 输入框脱焦收键盘 —— Listener 在命中路径上必收回调，不受消费影响。
        _cachedWebView ??= Listener(
          onPointerDown: (_) {
            if (_urlFocus.hasFocus) _clearInputFocus();
          },
          child: InAppWebView(
          // gen 参与-key：UA 清洗后的同模式重建（gen++）必须销毁旧平台
          // 视图、以新 initialSettings 创建，否则复用旧实例 UA 不生效。
          key: ValueKey(
              'shiguang_webview_${_useDesktopUa ? 'd' : 'm'}_$_webviewGen'),
          initialUrlRequest: !blankFirst && initialUrl.isNotEmpty
              ? URLRequest(url: WebUri(initialUrl))
              : null,
          // Chrome 环境补全（document-start、主世界、所有 frame）：经
          // WebViewCompat.addDocumentStartJavaScript 原生层注入，先于
          // 页面（含瑞数 VMP）脚本执行，无注入痕迹。WebView 没有
          // window.chrome（Chrome 独有），瑞数据此识别 WebView。
          initialUserScripts: UnmodifiableListView([
            UserScript(
              source: ShiguangBridge.chromeEnvJs,
              injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
            ),
          ]),
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            // 手机版：清洗后 UA（无 wv/Version 指纹，首跳 null=系统默认
            // 供捕获）；电脑版：反转派生 UA 同样过一遍清洗。
            userAgent:
                _useDesktopUa ? _sanitizeUa(_desktopUa) : _mobileUaClean,
            supportZoom: true,
            // 教务系统多为老式站点，允许混合内容加载。
            mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
            // 纹理合成模式（SurfaceAndroidView）：WebView 渲染为纹理参与
            // Flutter 合成，键盘/导航条动画不再与平台线程逐帧同步排队。
            // 混合合成（ExpensiveAndroidView）曾导致整页交互慢动作。
            useHybridComposition: false,
            // 禁用系统字体缩放：防止大字体模式破坏教务页面布局。
            textZoom: 100,
            // 桌面版页面需要宽视口 + 概览缩放，否则按 980px 错误渲染。
            useWideViewPort: true,
            loadWithOverviewMode: true,
            // 老式教务站点依赖 localStorage / sessionDatabase。
            domStorageEnabled: true,
            databaseEnabled: true,
            // 关键：不开 supportMultipleWindows（与 WakeUp/原生默认一致）。
            // 瑞数等反爬 WAF 的挑战 JS 会探测 window.open 环境，开启后
            // 探测被引向 onCreateWindow（拿到 null Window）→ 被判定为
            // 异常环境 → 子资源请求被持续返回 HTML 挑战页 → 脚本拒绝执行。
            // 关闭后 window.open 直接在当前 WebView 内导航（经典行为）。
            supportMultipleWindows: false,
            allowFileAccess: true,
            allowContentAccess: true,
            // 允许跨源资源访问：老教务页面协议/域混杂时保证元素可加载。
            allowFileAccessFromFileURLs: true,
            allowUniversalAccessFromFileURLs: true,
            thirdPartyCookiesEnabled: true,
            // 移除 X-Requested-With 请求头：Android WebView 默认携带
            // app 包名（浏览器从不发送该头），是 WebView 的显著指纹，
            // 瑞数等 WAF 可据此识别并持续下发挑战页。空集合 = 所有
            // 来源均不携带；内核不支持时自动跳过。
            requestedWithHeaderOriginAllowList: const <String>{},
            // 请求头观测（诊断）：shouldInterceptRequest 回调需要此开关。
            // 回调仅记录主文档请求头（验证 X-Requested-With 是否真的
            // 移除、客户端提示头形态），始终返回 null = 请求原样放行
            //（POST 体不受影响）。代价：所有资源请求经一次阻塞式 Dart
            // 往返，教务页请求量小，可接受。
            useShouldInterceptRequest: true,
          ),
          onWebViewCreated: _onWebViewCreated,
          onLoadStop: _onLoadStop,
          // 主文档请求头代理：主文档 GET 在 Dart 侧重发并重写 WebView
          // 指纹头（sec-ch-ua 品牌 → Google Chrome，补 Accept-Language /
          // Sec-Fetch-*，Cookie 从 CookieManager 拼装），返回
          // WebResourceResponse；POST（无请求体可取）与子资源透传。
          shouldInterceptRequest: (controller, request) async {
            if (request.isForMainFrame == true) {
              if (ShiguangRequestProxy.shouldProxy(request)) {
                final proxied = await _reqProxy.fetch(request);
                if (proxied != null) return proxied;
              }
            }
            return null;
          },
          onLoadStart: (controller, url) {
            // 兜底注入 Chrome 补环境：document-start 的 origin 规则不覆盖
            // about:blank，而瑞数 VMP 会把页面弹到 about:blank 做二次校验
            // （onLoadStop 探针曾在 about:blank 上下文里测到 chrome:
            // undefined）。此注入幂等（http 页面上 window.chrome 已存在
            // 直接返回），专门补 about:blank 的空窗。
            unawaited(controller
                .evaluateJavascript(source: ShiguangBridge.chromeEnvJs)
                .catchError((_) => null));
            setState(() {
              _pageLoaded = false;
              // 加载时导航条保持完全形态（前往按钮转为 🔄）。
              _barExpanded = true;
              _lastScrollY = 0;
            });
            _setLoading(true);
          },
          // 滚动方向驱动导航条完全/精简形态切换。
          onScrollChanged: (controller, x, y) => _onWebScrollChanged(y),
          // 导航历史变化 → 刷新后退/前进可用态。
          onUpdateVisitedHistory: (controller, url, isReload) async {
            final canBack = await controller.canGoBack();
            final canForward = await controller.canGoForward();
            if (mounted &&
                (canBack != _canGoBack || canForward != _canGoForward)) {
              setState(() {
                _canGoBack = canBack;
                _canGoForward = canForward;
              });
            }
          },
          // window.open 弹窗统一在当前 WebView 内打开。
          onCreateWindow: (controller, createWindowRequest) async {
            final uri = createWindowRequest.request.url;
            if (uri != null) {
              await controller
                  .loadUrl(urlRequest: URLRequest(url: uri));
            }
            return true;
          },
          onReceivedServerTrustAuthRequest: (controller, challenge) async {
            // 大量教务系统使用自签/过期证书，直接放行。
            return ServerTrustAuthResponse(
              action: ServerTrustAuthResponseAction.PROCEED,
            );
          },
          onConsoleMessage: (controller, message) {
            // 控制台桥通道：优先识别 [[SG]] 前缀的桥消息（JS→Dart）。
            final text = message.message;
            if (text.startsWith(ShiguangBridge.magicPrefix)) {
              _handleBridgeConsoleMessage(controller, text);
              return;
            }
            if (kDebugMode) {
              debugPrint('[WebView] $text');
            }
          },
          // 教务页面大量使用 alert/confirm（登录校验、菜单跳转、错误提示），
          // 不接管会被 WebView 静默吞掉（confirm 返回 false），流程中断后
          // 表现为页面元素加载不出来。
          onJsAlert: (controller, request) async {
            await _showJsDialog(request.message ?? '',
                showCancel: false);
            return JsAlertResponse(
                action: JsAlertResponseAction.CONFIRM);
          },
          onJsConfirm: (controller, request) async {
            final confirmed = await _showJsDialog(
                request.message ?? '',
                showCancel: true);
            return JsConfirmResponse(
              action: confirmed == true
                  ? JsConfirmResponseAction.CONFIRM
                  : JsConfirmResponseAction.CANCEL,
            );
          },
          onReceivedError: (controller, request, error) {
            // 主文档加载失败时复位进度条（onLoadStop 不会触发）。
            if (request.isForMainFrame == true && mounted) {
              _setLoading(false);
            }
          },
          ),
        ),
        if (_loading)
          const Positioned(
            top: 4,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(
              minHeight: 2,
              backgroundColor: Colors.transparent,
              valueColor: AlwaysStoppedAnimation(Color(0xFF9B59B6)),
            ),
          ),
        if (!_pageLoaded && !_loading && initialUrl.isEmpty)
          _buildEmptyHint(),
        // 「开始导入」悬浮按钮：位于底部导航条上方（paddingOf 细粒度：
        // 键盘动画帧不重建）。
        Positioned(
          left: 0,
          right: 0,
          bottom: MediaQuery.paddingOf(context).bottom + 76,
          child: Center(child: _buildImportButton()),
        ),
        // 底部悬浮网址导航条（完全/精简双形态）。
        _buildBottomUrlBar(),
      ],
    );
  }

  Widget _buildEmptyHint() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.travel_explore,
              size: 48, color: Colors.grey.shade300),
          const SizedBox(height: 12),
          Text(
            '在下方输入你的教务系统网址并前往',
            style: TextStyle(fontSize: 13, color: Colors.grey.shade500),
          ),
        ],
      ),
    );
  }

  Widget _buildImportButton() {
    final enabled = _pageLoaded && !_importRunning;
    return GestureDetector(
      onTap: enabled ? _startImport : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: [
            enabled ? const Color(0xFF9B59B6) : Colors.grey.shade400,
            enabled ? const Color(0xFFAF7AC5) : Colors.grey.shade300,
          ]),
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(
              color: (enabled ? const Color(0xFF9B59B6) : Colors.grey)
                  .withValues(alpha: 0.35),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: _importRunning
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  valueColor: AlwaysStoppedAnimation(Colors.white),
                ),
              )
            : const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.download_rounded,
                      size: 20, color: Colors.white),
                  SizedBox(width: 8),
                  Text(
                    '开始导入',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// 教务导入帮助卡片：屏幕居中（两侧与屏幕边界保留 16px），
/// 自顶栏下方向下弹出；动画同设置页问号提示（220ms，
/// easeOutBack 弹出 / easeInCubic 收回），减弱动态效果时仅淡入淡出。
class _ShiguangHelpCard extends StatefulWidget {
  final bool visible;
  final String text;
  final VoidCallback? onDismissed;

  const _ShiguangHelpCard({
    required this.visible,
    required this.text,
    this.onDismissed,
  });

  @override
  State<_ShiguangHelpCard> createState() => _ShiguangHelpCardState();
}

class _ShiguangHelpCardState extends State<_ShiguangHelpCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

  late final CurvedAnimation _curved = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutBack,
    reverseCurve: Curves.easeInCubic,
  );

  @override
  void initState() {
    super.initState();
    if (widget.visible) {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(covariant _ShiguangHelpCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible == oldWidget.visible) return;
    if (widget.visible) {
      _controller.forward();
    } else {
      _controller.reverse().whenCompleteOrCancel(() {
        if (mounted) widget.onDismissed?.call();
      });
    }
  }

  @override
  void dispose() {
    _curved.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 细粒度依赖（仅 padding aspect）：键盘 viewInsets 每帧变化时
    // 不触发本组件 rebuild。
    final topPadding = MediaQuery.paddingOf(context).top;
    return Positioned(
      left: 16,
      right: 16,
      // 顶栏（状态栏 + 52 标题行）下方，视觉上自顶栏处向下展开。
      top: topPadding + 52 + 12,
      child: Center(
        child: AnimatedBuilder(
          animation: _curved,
          builder: (context, child) {
            final t = _curved.value;
            return Opacity(
              // easeOutBack 会过冲超过 1.0，透明度需夹取
              opacity: t.clamp(0.0, 1.0),
              // 减弱动态效果时也保留弹出/收起动画（本卡位移幅度小，
              // 是信息定位动画而非装饰性动效）。
              child: Transform.translate(
                // 自顶栏处（上方）向下滑出；收回时向上缩回
                offset: Offset(0, -14 * (1 - t)),
                child: Transform.scale(
                  // 顶部对齐缩放：视觉上自顶栏处向下展开/向上收起
                  scale: 0.85 + 0.15 * t,
                  alignment: Alignment.topCenter,
                  child: child,
                ),
              ),
            );
          },
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade300),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.15),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.help_outline,
                          size: 15, color: Colors.deepPurple.shade400),
                      const SizedBox(width: 6),
                      Text(
                        '教务系统导入帮助',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: Colors.grey.shade700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    widget.text,
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade600,
                      height: 1.6,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 安全锁出现/消失动画表现：参考设置页登录/注册切换的副标题出现效果
/// （原地 scale 0.55→1 + 淡入淡出；未开启减弱动态效果时叠加模糊
/// sigma 14→0，满态跳过模糊层省开销）。动画值来自屏幕级
/// [_ShiguangWebImportScreenState] 的 [_lockCurved]（全量/精简两处锁
/// 共用），本组件无状态——控制器随 AnimatedSwitcher 子树销毁重建会
/// 导致动画丢失（直接满态出现），这正是锁动画「不生效」的根因，故
/// 动画状态必须上提到屏幕级。地址栏的避让/回填位移由外层以同一动画
/// 值驱动的宽度（27 * t / 15.5 * t）实现，与图标逐帧同步、无闪现。
class _LockAppear extends StatelessWidget {
  final Animation<double> animation;
  final bool reduceMotion;
  final Widget child;

  const _LockAppear({
    required this.animation,
    required this.reduceMotion,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final t = animation.value.clamp(0.0, 1.0);
        return Opacity(
          opacity: t,
          child: Transform.scale(
            scale: 0.55 + 0.45 * t,
            child: (reduceMotion || t >= 1.0)
                ? child
                : ImageFiltered(
                    imageFilter: ImageFilter.blur(
                      sigmaX: 14 * (1 - t),
                      sigmaY: 14 * (1 - t),
                    ),
                    child: child,
                  ),
          ),
        );
      },
      child: child,
    );
  }
}
