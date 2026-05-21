import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dialogs/ai_consent_dialog.dart';
import 'screens/home_screen.dart';
import 'screens/settings_screen.dart';
import 'services/auth_service.dart';
import 'services/glm_service.dart';
import 'services/notification_service.dart';
import 'utils/storage.dart';
import 'models/course.dart';
import 'models/task.dart';

const String appVersion = '1.0.5';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  await Hive.initFlutter();
  
  Hive.registerAdapter(CourseAdapter());
  Hive.registerAdapter(TaskAdapter());
  
  await StorageService.init();
  
  try {
    await NotificationService.instance.init();
    await NotificationService.instance.rescheduleTaskNotifications(StorageService.getTasks());
  } catch (e) {
    debugPrint('Notification init error: $e');
  }
  
  await AuthService.instance.init();
  await AIService.instance.loadConfig();
  
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
  @override
  void initState() {
    super.initState();
    _checkAndShowWelcome();
  }

  Future<void> _checkAndShowWelcome() async {
    final prefs = await SharedPreferences.getInstance();
    final lastVersion = prefs.getString('last_app_version');
    
    if (lastVersion != appVersion) {
      await prefs.setString('last_app_version', appVersion);
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _showWelcomeDialog();
        });
      }
    }
  }

  void _showWelcomeDialog() {
    final maxDialogHeight = MediaQuery.of(context).size.height - 48;

    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '欢迎',
      transitionDuration: const Duration(milliseconds: 400),
      pageBuilder: (context, animation, secondaryAnimation) {
        return Center(
          child: Material(
            color: Colors.transparent,
            child: FadeTransition(
              opacity: animation,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.9, end: 1.0).animate(
                  CurvedAnimation(parent: animation, curve: Curves.easeOut),
                ),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 32),
                  padding: const EdgeInsets.all(28),
                  constraints: BoxConstraints(maxHeight: maxDialogHeight),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.15),
                        blurRadius: 30,
                        offset: const Offset(0, 15),
                      ),
                    ],
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '👋 欢迎使用 CourseHub',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF1A1A2E),
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
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
                            child: const Text('开始使用', style: TextStyle(fontSize: 16)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    ).whenComplete(() {
      _showAIConsentPromptAfterWelcome();
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
    return const HomeScreen();
  }
}
