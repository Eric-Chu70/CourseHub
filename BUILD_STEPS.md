# Flutter 项目构建步骤

## 第一次运行前的准备

### 1. 安装 Flutter

**Windows 用户**：
1. 下载 Flutter SDK：https://docs.flutter.dev/get-started/install/windows
2. 解压到 `C:\src\flutter`（不要放在桌面或中文路径）
3. 添加 `C:\src\flutter\bin` 到环境变量 Path
4. 重启终端或 Android Studio

### 2. 验证安装

打开终端运行：
```bash
flutter doctor
```

如果看到 Android Studio 和 Android SDK 的提示，需要：
```bash
flutter doctor --android-licenses
```
全部输入 `y` 同意许可协议

### 3. 安装 Android Studio 插件

1. 打开 Android Studio
2. **File** → **Settings** → **Plugins**
3. 搜索 **Flutter** 并安装
4. 重启 Android Studio

## 构建项目

### 步骤 1：打开项目

在 Android Studio 中：
- **File** → **Open**
- 选择项目的 `flutter` 文件夹

### 步骤 2：等待 Gradle 同步

打开项目后，Android Studio 会自动同步 Gradle，等待底部进度条完成

### 步骤 3：获取 Flutter 依赖

在终端运行（Android Studio 底部 Terminal）：
```bash
flutter pub get
```

### 步骤 4：生成代码（Hive 需要）

```bash
flutter pub run build_runner build --delete-conflicting-outputs
```

### 步骤 5：运行应用

1. 确保已选择设备（模拟器或真机）
2. 点击绿色运行按钮（▶️）或按 `Shift + F10`
3. 第一次运行会编译，需要几分钟

## 构建 APK

### Debug APK（用于测试）

```bash
flutter build apk --debug
```

输出位置：`build/app/outputs/flutter-apk/app-debug.apk`

### Release APK（用于发布）

```bash
flutter build apk --release
```

输出位置：`build/app/outputs/flutter-apk/app-release.apk`

## 常见问题

### Q: 找不到 flutter 命令
**A**: 确保 Flutter 已添加到环境变量，运行 `flutter doctor` 检查

### Q: Gradle 同步失败
**A**: 
- 检查网络连接
- **File** → **Invalidate Caches / Restart**
- 删除 `.gradle` 文件夹重新同步

### Q: 代码生成失败
**A**: 运行 `flutter pub run build_runner build --delete-conflicting-outputs`

### Q: 应用闪退
**A**: 查看 Logcat 日志，可能是 Hive 适配器未生成，运行步骤 4

### Q: 找不到设备
**A**: 
- 连接 Android 手机并开启 USB 调试
- 或创建模拟器：**Tools** → **Device Manager**

## 调试技巧

### 热重载
修改代码后按 `Ctrl + S`，应用会自动更新

### 查看日志
- **View** → **Tool Windows** → **Run**
- 或使用 `print('调试信息')`

### 断点调试
1. 在代码行号旁点击设置断点
2. 按 `Shift + F9` 启动调试
3. 查看变量和调用栈

## 项目结构说明

```
flutter/
├── lib/                    # 源代码
│   ├── main.dart          # 入口
│   ├── models/            # 数据模型（Course, Task）
│   ├── screens/           # 界面
│   ├── dialogs/           # 对话框
│   ├── widgets/           # 组件
│   └── utils/             # 工具类
├── android/               # Android 原生项目
│   ├── app/
│   │   ├── src/main/     # Android 源代码
│   │   └── build.gradle  # Android 构建配置
│   └── build.gradle      # 项目级构建配置
├── pubspec.yaml          # Flutter 依赖配置
└── analysis_options.yaml # 代码分析配置
```

## 下一步

1. ✅ 运行应用查看效果
2. ✅ 测试添加课程功能
3. ✅ 测试 DDL 功能
4. 🔄 完善导入导出功能
5. 🔄 添加通知提醒

## 有用的命令

```bash
# 检查 Flutter 环境
flutter doctor

# 清理构建缓存
flutter clean

# 获取依赖
flutter pub get

# 运行测试
flutter test

# 格式化代码
flutter format .

# 分析代码
flutter analyze

# 升级 Flutter
flutter upgrade
```

## 资源链接

- Flutter 官方文档：https://flutter.dev
- Dart 语言指南：https://dart.dev
- Material Design 3：https://m3.material.io
- Hive 文档：https://docs.hivedb.dev
