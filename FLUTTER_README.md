# CourseHub Flutter 版本 - 构建指南

## 项目说明

这是用 Flutter 重写的 CourseHub 课程表管理应用，完全解决了之前 Web 版本的布局问题。

## 环境要求

1. **Flutter SDK** (3.0.0 或更高版本)
2. **Android Studio** (最新版)
3. **Android SDK** (API 21+)

## 安装 Flutter

### Windows 安装步骤

1. 下载 Flutter SDK：
   - 访问 https://docs.flutter.dev/get-started/install/windows
   - 下载最新版本的 Flutter SDK

2. 解压到目录（例如 `C:\src\flutter`）

3. 添加 Flutter 到环境变量：
   - 右键"此电脑" → 属性 → 高级系统设置
   - 环境变量 → Path → 新建
   - 添加 `C:\src\flutter\bin`

4. 验证安装：
   ```bash
   flutter doctor
   ```

5. 接受 Android 许可协议：
   ```bash
   flutter doctor --android-licenses
   ```

## 构建 APK

### 步骤 1：打开项目

在 Android Studio 中打开 `CourseHub` 文件夹

### 步骤 2：获取依赖

```bash
flutter pub get
```

### 步骤 3：运行构建（生成代码）

```bash
flutter pub run build_runner build --delete-conflicting-outputs
```

### 步骤 4：构建 APK

```bash
flutter build apk --release
```

APK 文件位置：
```
build/app/outputs/flutter-apk/app-release.apk
```

## 功能特性

### ✅ 已完成
- 底部导航栏（固定在底部）
- 课程表界面（按星期查看）
- 添加/编辑/删除课程
- DDL 任务列表
- 数据导出
- 设置（清除数据）
- 本地存储（Hive）

### 🔄 待开发
- 图片 OCR 识别
- JSON 导入
- 任务添加对话框
- 课程表网格视图
- 通知提醒

## 项目结构

```
lib/
├── main.dart                 # 应用入口
├── models/                   # 数据模型
│   ├── course.dart          # 课程模型
│   └── task.dart            # 任务模型
├── screens/                  # 界面
│   ├── home_screen.dart     # 主界面
│   ├── timetable_screen.dart # 课程表
│   ├── heatmap_screen.dart  # DDL 热度
│   ├── import_screen.dart   # 导入
│   └── settings_screen.dart # 设置
├── dialogs/                  # 对话框
│   └── course_dialog.dart   # 课程编辑
├── widgets/                  # 组件
│   └── course_card.dart     # 课程卡片
└── utils/                    # 工具类
    └── storage.dart         # 本地存储
```

## 常见问题

### Q: 构建失败，提示找不到 Flutter
A: 确保 Flutter 已添加到环境变量，运行 `flutter doctor` 检查

### Q: 代码生成失败
A: 运行 `flutter pub run build_runner build --delete-conflicting-outputs`

### Q: APK 太大
A: 这是正常的，Flutter 引擎包含在 APK 中。可以构建 App Bundle 减小体积

### Q: 如何调试
A: 连接 Android 设备，运行 `flutter run`

## 优势对比

| 特性 | Web 版本 | Flutter 版本 |
|------|---------|------------|
| 底部导航栏 | ❌ 样式问题 | ✅ 原生组件 |
| 课程表布局 | ❌ CSS Grid 问题 | ✅ 完美适配 |
| 性能 | ⚠️ WebView | ✅ 原生渲染 |
| 横竖屏 | ❌ 布局混乱 | ✅ 自动适配 |
| 触摸反馈 | ⚠️ 手动实现 | ✅ 内置支持 |
| 动画流畅度 | ⚠️ 可能卡顿 | ✅ 60fps |

## 下一步

1. 测试应用功能
2. 根据需要调整 UI
3. 添加缺失的功能（OCR、任务编辑等）
4. 打包发布

## 技术支持

- Flutter 官方文档：https://flutter.dev
- Hive 文档：https://docs.hivedb.dev
