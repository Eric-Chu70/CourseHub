import 'dart:io';

import 'package:coursehub/main.dart';
import 'package:coursehub/models/course.dart';
import 'package:coursehub/models/task.dart';
import 'package:coursehub/utils/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    // 直接 pump CourseHubApp 不经过 main()，runApp 前的初始化不会执行。
    // 测试环境必须手工完成 Hive 初始化（注册适配器 + 打开框），
    // 否则 HomeScreen 首帧读 StorageService._coursesBox（late 字段）
    // 会抛 LateInitializationError，测试挂死在启动阶段。
    Hive.init(
      Directory.systemTemp.createTempSync('coursehub_widget_test').path,
    );
    Hive.registerAdapter(CourseAdapter());
    Hive.registerAdapter(TaskAdapter());

    // 关掉启动更新检查（避免测试发起真实网络请求）并标记当前版本
    // （跳过欢迎/更新完成对话框，测试聚焦「启动并渲染主页」本身）
    SharedPreferences.setMockInitialValues({
      'auto_update_check': false,
      'last_app_version': appVersion,
    });
    await StorageService.init();
  });

  testWidgets('App starts correctly', (WidgetTester tester) async {
    await tester.pumpWidget(const CourseHubApp());
    // 等首帧 + 启动淡入推进，底部导航文字即可见
    await tester.pump(const Duration(milliseconds: 100));
    // 断言底部导航的「课表」标签：旧断言找的是课表页头部标题「课程表」，
    // 但头部重构（GradientBlurHeader 传 titleRow 后 title 不再渲染）后
    // 该文字已不出现在界面上；导航标签是启动后稳定渲染的文字
    expect(find.text('课表'), findsOneWidget);
  });
}
