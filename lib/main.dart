import 'dart:async';

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dialogs/ai_consent_dialog.dart';
import 'dialogs/update_dialog.dart';
import 'screens/home_screen.dart';
import 'screens/settings_screen.dart';
import 'services/auth_service.dart';
import 'services/glm_service.dart';
import 'services/notification_service.dart';
import 'services/update_service.dart';
import 'services/wallpaper_storage_service.dart';
import 'services/widget_service.dart';
import 'utils/storage.dart';
import 'widgets/toast_notification.dart';
import 'widgets/glass_dialog.dart';
import 'models/course.dart';
import 'models/task.dart';

const String appVersion = '1.0.7';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // release 包关闭全部 debugPrint 输出（debug 包不受影响）；
  // 诊断用 CrashLog 落盘，不依赖控制台
  if (kReleaseMode) {
    debugPrint = (String? message, {int? wrapWidth}) {};
  }

  await Hive.initFlutter();
  
  Hive.registerAdapter(CourseAdapter());
  Hive.registerAdapter(TaskAdapter());
  
  await StorageService.init();

  // 旧版拼写迁移（Anges → Agnes）：同步旧 prefs 键与 provider 值
  await AIService.migrateLegacyAgnesKeys();

  // 壁纸首帧预载：趁原生启动页保持期间完成 prefs 读取 + 壁纸解码入缓存，
  // 让壁纸与课表同帧渲染（消除课表先出、壁纸后闪）。
  // 600ms 超时保护：超时/失败放弃预载，回退课表页异步加载，不卡启动
  await WallpaperPreload.instance
      .load()
      .timeout(const Duration(milliseconds: 600), onTimeout: () {});

  // 先 runApp，让 UI 尽快显示，避免从小组件进入时白屏卡死
  SystemChrome.setEnabledSystemUIMode(
    SystemUiMode.edgeToEdge,
  );

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
      systemStatusBarContrastEnforced: false,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.dark,
      systemNavigationBarContrastEnforced: false,
    ),
  );

  runApp(const CourseHubApp());

  // 非关键初始化延迟到 runApp 之后执行
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    // 初始化桌面小组件数据
    WidgetService.updateAllWidgets();

    // 壁纸维护：旧 cache 路径迁移到持久目录 + 孤儿文件清理
    WallpaperStorageService.migrateAndCleanup();

    try {
      await NotificationService.instance.init();
      await NotificationService.instance.rescheduleTaskNotifications(StorageService.getTasks());
    } catch (e) {
      debugPrint('Notification init error: $e');
    }

    await AuthService.instance.init();
    await AIService.instance.loadConfig();
  });
}

class CourseHubApp extends StatelessWidget {
  const CourseHubApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: AuthService.instance),
      ],
      child: MaterialApp(
        title: 'CourseHub',
        debugShowCheckedModeBanner: false,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [
          Locale('zh', 'CN'),
          Locale('en', 'US'),
        ],
        locale: const Locale('zh', 'CN'),
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF4A90E2),
            brightness: Brightness.light,
          ),
          useMaterial3: true,
          fontFamily: 'Microsoft YaHei',
          appBarTheme: const AppBarTheme(
            centerTitle: true,
            elevation: 0,
            scrolledUnderElevation: 0,
            systemOverlayStyle: SystemUiOverlayStyle(
              statusBarColor: Colors.transparent,
              statusBarIconBrightness: Brightness.dark,
              statusBarBrightness: Brightness.light,
              systemStatusBarContrastEnforced: true,
            ),
          ),
          cardTheme: const CardThemeData(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(12)),
            ),
          ),
          inputDecorationTheme: InputDecorationTheme(
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            filled: true,
            fillColor: Colors.grey[50],
          ),
        ),
        home: const MainScreen(),
      ),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  /// 上次按系统返回的时间戳：2 秒内连按两次才退出应用
  int _lastBackPressTime = 0;

  /// 原生退出通道：走 MainActivity 自绘固定时长关闭动画，动画播完立即杀进程
  static const MethodChannel _exitChannel = MethodChannel('coursehub/app');

  /// 启动提示链（欢迎/更新完成对话框 + AI 同意提示）完成信号：
  /// 启动更新检查发现新版本时，等链结束后再弹绿色 toast，避免提示叠加
  final Completer<void> _startupPromptsDone = Completer<void>();

  @override
  void initState() {
    super.initState();
    _checkAndShowWelcome();
    _checkUpdateOnStartup();
  }

  /// 启动静默检查更新（每次冷启动一次）：联网拉取 latest.json，
  /// 超时/失败/无新版本一律静默放弃、不打扰用户；
  /// 发现新版本则等启动提示链结束后弹绿色 toast，点击进入更新对话框
  /// （直接复用启动时拿到的版本信息，跳过对话框内的重复检查）。
  /// 检查与启动提示链并行进行，网络慢时提示链先行、互不阻塞。
  /// 门槛：设置页「自动检查软件升级」开关关闭时直接跳过（不发网络请求）；
  /// 点击 toast 右侧「忽略」记录该版本号，忽略记录不低于线上最新版本时
  /// 静默跳过，发布更新的版本后自动恢复推送。
  /// 设置页手动检查不受门槛影响。
  Future<void> _checkUpdateOnStartup() async {
    // 自动检查开关关闭：完全静默
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool('auto_update_check') ?? true)) return;

    final result = await UpdateService.checkForUpdate(appVersion);
    if (!result.hasUpdate || result.info == null) return;
    final info = result.info!;

    // 仅忽略此版本：忽略记录 >= 最新版本时静默跳过
    final ignored = prefs.getString('ignored_update_version');
    if (ignored != null &&
        UpdateService.compareVersions(ignored, info.version) >= 0) {
      return;
    }

    // 等待欢迎/AI 同意对话框链结束，避免提示叠加
    await _startupPromptsDone.future;
    if (!mounted) return;

    toastNotification.show(
      context,
      '新版本v${info.version}现已可用！',
      type: ToastType.success,
      duration: const Duration(milliseconds: 5000),
      onTap: () {
        if (!mounted) return;
        showUpdateDialog(context, preloadedInfo: info);
      },
      actionLabel: '忽略',
      onAction: () async {
        // 忽略此版本：记录版本号，本版本不再提示（新版本发布后自动恢复）
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('ignored_update_version', info.version);
        // 等绿色提示收场动画（约 300ms）结束后再弹蓝色确认提示
        await Future.delayed(const Duration(milliseconds: 350));
        if (!mounted) return;
        toastNotification.show(
          context,
          '此版本更新不再提示',
          type: ToastType.info,
        );
      },
    );
  }

  Future<void> _checkAndShowWelcome() async {
    final prefs = await SharedPreferences.getInstance();
    final lastVersion = prefs.getString('last_app_version');

    if (lastVersion != appVersion) {
      await prefs.setString('last_app_version', appVersion);
      if (mounted) {
        // 首次进入（无历史版本记录）显示完整欢迎对话框；
        // 版本更新（有历史版本）显示轻量更新完成对话框
        final isFirstLaunch = lastVersion == null;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _showWelcomeDialog(isUpdate: !isFirstLaunch);
        });
        return; // 链尾由 _showWelcomeDialog 的 whenComplete 收尾
      }
    }
    // 常规启动（无版本变化）或页面已卸载：提示链视为立即完成
    if (!_startupPromptsDone.isCompleted) _startupPromptsDone.complete();
  }

  void _showWelcomeDialog({bool isUpdate = false}) {
    final maxDialogHeight = MediaQuery.of(context).size.height - 48;

    showBouncyDialog(
      context: context,
      barrierLabel: '欢迎',
      margin: const EdgeInsets.symmetric(horizontal: 32),
      shellPadding: const EdgeInsets.all(28),
      shellBoxShadow: [
        BoxShadow(
          color: Colors.black.withOpacity(0.15),
          blurRadius: 30,
          offset: const Offset(0, 15),
        ),
      ],
      backgroundAlpha: 1.0,
      builder: (context) => ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxDialogHeight),
        child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isUpdate ? '✅ 更新已完成！v$appVersion' : '👋 欢迎使用 CourseHub',
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF1A1A2E),
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (!isUpdate) ...[
                          const SizedBox(height: 4),
                          Text(
                            'v$appVersion',
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.grey[400],
                            ),
                          ),
                          const SizedBox(height: 24),
                          _buildFeatureItemRich(
                            '📅 智能化的课程及任务管理',
                            '一句话搞定课程和任务编辑，省心省事',
                          ),
                          const SizedBox(height: 16),
                          _buildFeatureItemRich(
                            '🤖 你的知心学习搭子',
                            '提供课程分析与学习建议，支持接入主流AI平台',
                          ),
                          const SizedBox(height: 16),
                          _buildFeatureItemRich(
                            '☁️ 登陆账号数据云端同步',
                            '支持多课表备份、同步与云端数据管理',
                          ),
                          const SizedBox(height: 28),
                        ],
                        if (isUpdate) const SizedBox(height: 28),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: () => Navigator.pop(context),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF4A90E2),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: Text(
                              isUpdate ? '继续' : '开始使用',
                              style: const TextStyle(fontSize: 16),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
    ).whenComplete(() async {
      await _showAIConsentPromptAfterWelcome();
      // 提示链收尾：通知启动更新检查可以弹 toast 了
      if (!_startupPromptsDone.isCompleted) _startupPromptsDone.complete();
    });
  }

  Future<void> _showAIConsentPromptAfterWelcome() async {
    if (!mounted) return;

    final prefs = await SharedPreferences.getInstance();
    final hasShownPrompt = prefs.getBool('ai_welcome_prompt_shown') ?? false;
    if (hasShownPrompt) {
      return;
    }

    await prefs.setBool('ai_welcome_prompt_shown', true);

    final aiEnabled = prefs.getBool('ai_enabled') ?? false;
    final consentAccepted = prefs.getBool('ai_consent_accepted') ?? false;
    if (aiEnabled || consentAccepted || !mounted) {
      return;
    }

    final accepted = await AIConsentDialog.show(context);
    if (accepted && mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => const SettingsScreen(autoShowAIConfig: true)),
      );
    }
  }

  Widget _buildFeatureItemRich(String title, String description) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: Color(0xFF333333),
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 4),
        Text(
          description,
          style: TextStyle(
            fontSize: 13,
            color: Colors.grey[600],
            height: 1.4,
          ),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // 双击返回退出：页面切换不依赖 Navigator 路由，系统返回默认直接退出。
    // 拦截第一次返回，顶部蓝色 info toast 提示「再按一次退出程序」，
    // 2 秒内再按才真正退出
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - _lastBackPressTime < 2000) {
          // 正常 finish 播放自绘固定时长关闭动画（图标归位）；进程终止由
          // MainActivity 按「动画时长 × 系统缩放」精确延迟执行（等效
          // force-stop 的干净状态，但动画播完立即杀，兼容各品牌动画时长）
          _exitChannel.invokeMethod('exitApp');
        } else {
          _lastBackPressTime = now;
          toastNotification.show(context, '再按一次退出程序', type: ToastType.info);
        }
      },
      child: const HomeScreen(),
    );
  }
}
