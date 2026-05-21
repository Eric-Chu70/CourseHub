# CourseHub

> 一款现代化的课程表管理应用，集成 AI 智能助手、DDL 热力图、云端同步等功能。

---

## 关于 AI 功能

**由于目前资金短缺，已移除所有内建模型支持。** 使用者需要自行解决 API 接入问题。接入 API 后即可体验满血 AI 功能，包括 AI 对话、图片识别导入课程表等。AI 功能的质量优劣完全取决于使用者自己所提供的模型能力强弱。

**如果选择不接入 API，依然可以正常使用应用的其它全部功能**（课表管理、DDL 追踪、数据导入导出、云端同步等）。

---

## 特色功能

### 课表管理

- 可视化周课表网格，支持左右滑动切换教学周
- 支持创建、切换、删除多个课表（如"秋季学期"、"春季学期"）
- 课程卡片显示课程名、教师、教室，支持自定义颜色
- 支持跨节课程（连续多节同一课程）
- 自动高亮当天列，显示实际日期

### DDL 热力图

- 月历热力图视图，颜色深浅反映每日任务密度
- 任务统计卡片：总任务数、即将到期（3天内）、已逾期
- 支持任务优先级（高/中/低）、类型（作业/考试/报告/其他）
- 任务与课程关联，完成状态一键切换
- 自定义到期提醒通知，支持设置提前提醒时间和通知风格

### AI 智能助手

- 对话式 AI 学习助手，自动分析课表并提供个性化学习建议
- 流式输出，实时逐字显示 AI 回复
- 支持推理模型（如 DeepSeek-R1），可展开查看思考过程
- 支持图片上传，视觉模型可直接识别图片内容
- Markdown 渲染，支持数学公式（LaTeX）
- 支持联网搜索能力（部分模型）

### 图片识别导入

- 拍照或从相册选择课程表图片，自动 OCR 识别并导入
- 使用 Google ML Kit 本地文字识别，隐私安全
- 识别结果经 AI 或正则解析为结构化课程数据

### 数据管理

- JSON 文件导入（支持合并/替换模式）
- 剪贴板粘贴 JSON 导入
- 一键导出全部数据为 JSON 文件
- Supabase 云端备份与恢复，支持多课表选择性同步

### 云端同步

- 注册账号后可将课表备份至云端
- 支持最多 5 个课表的云端存储
- 可选择性下载、合并或覆盖本地数据

### 个性化壁纸

- 可为您的课表页更换自己心仪的壁纸
- 支持透明度50%-100%调整
- 支持课程卡片模糊蒙版

---

## AI 功能开启与使用方法

### 第一步：获取 API

本应用支持以下 AI 服务提供商，任选其一即可：

| 提供商 | 说明 | 所需信息 |
|--------|------|----------|
| 混元 Lite | 腾讯云提供，速度快，完全免费 | Secret ID + Secret Key |
| GLM-4.7-Flash | 智谱 AI 提供，完全免费 | API Key |
| 自定义 OpenAI 兼容 API | 任意兼容 OpenAI 格式的接口 | API 地址 + API Key + 模型名称 |

### 第二步：配置 API

1. 打开应用，进入 **设置** 页面
2. 点击 **AI 功能** 开关
3. 阅读并同意隐私说明
4. 在弹出的 AI 功能配置界面中选择你想要的提供商
5. 填入对应的 API 密钥信息并保存

### 第三步：使用 AI 功能

配置完成后，你可以：

- **AI 对话**：进入"对话"标签页，与 AI 学习助手聊天，它会自动分析你的课表和任务
- **图片识别导入**：进入"导入"标签页，选择"图片识别"，拍照或选择课程表图片即可自动导入
- **自定义 API 视觉能力**：在自定义 API 配置中，可手动设置视觉能力支持（自动/开启/关闭）

### 注意事项

- 免费模型由第三方平台提供，你的数据可能被平台方收集，请勿上传个人隐私信息
- AI 识别结果仅供参考，请自行核对准确性
- 不同模型的能力差异较大，高质量模型通常能提供更准确的识别和更有价值的建议
- 如未配置 API，AI 相关功能将保持关闭状态，不影响其它功能使用

---

## 技术栈

- **框架**：Flutter 3.x
- **本地存储**：Hive + SharedPreferences
- **状态管理**：Provider
- **后端服务**：Supabase（认证 + 云端同步）
- **OCR**：Google ML Kit（本地文字识别）
- **UI 设计**：Material Design 3，毛玻璃风格，动画过渡，触觉反馈

---

## 构建

### 环境要求

- Flutter SDK >=3.0.0 <4.0.0
- Android Studio / VS Code
- Java 17+（Android 构建）

### 构建 APK

```bash
cd flutter
flutter pub get
flutter build apk --release
```

产物路径：`flutter/build/app/outputs/flutter-apk/app-release.apk`

---

## 开源许可

本项目基于 MIT 许可证开源。

---

# CourseHub

> A modern course timetable management app with an integrated AI assistant, DDL heatmap, cloud sync, and more.

---

## About AI Features

**Due to funding constraints, all built-in model support has been removed.** Users need to provide their own API access. Once an API is configured, you can enjoy full AI capabilities including AI chat, image-based timetable recognition, and more. The quality of AI features depends entirely on the capability of the model you provide.

**If you choose not to configure an API, all other features of the app remain fully functional** (timetable management, DDL tracking, data import/export, cloud sync, etc.).

---

## Features

### Timetable Management

- Visual weekly timetable grid with swipe navigation between teaching weeks
- Create, switch, and delete multiple timetables (e.g., "Fall Semester", "Spring Semester")
- Course cards display course name, teacher, and location with customizable colors
- Support for multi-period courses (consecutive class slots)
- Auto-highlight current day column with actual calendar dates

### DDL Heatmap

- Monthly calendar heatmap view where color intensity reflects daily task density
- Task statistics cards: total tasks, due soon (within 3 days), and overdue
- Task priority levels (high/medium/low) and types (homework/exam/report/other)
- Tasks linked to specific courses with one-tap completion toggle
- Customizable deadline reminder notifications with configurable advance time and notification style

### AI Study Assistant

- Conversational AI assistant that automatically analyzes your timetable and provides personalized study advice
- Streaming output with real-time token-by-token display
- Reasoning model support (e.g., DeepSeek-R1) with expandable thinking process view
- Image upload support for vision-capable models
- Markdown rendering with LaTeX math equation support
- Web search capability (for supported models)

### Image Recognition Import

- Take a photo or select a timetable image from gallery for automatic OCR recognition and import
- Uses Google ML Kit for on-device text recognition, ensuring privacy
- Recognition results parsed into structured course data via AI or regex

### Data Management

- JSON file import with merge/replace modes
- Clipboard paste JSON import
- One-tap export of all data as a formatted JSON file
- Supabase cloud backup and restore with selective multi-timetable sync

### Cloud Sync

- Register an account to back up timetables to the cloud
- Support for up to 5 timetables in cloud storage
- Selective download, merge, or overwrite local data

---

## Getting Started with AI Features

### Step 1: Obtain an API

The app supports the following AI providers — choose any one:

| Provider | Description | Required Info |
|----------|-------------|---------------|
| Hunyuan Lite | By Tencent Cloud, fast and completely free | Secret ID + Secret Key |
| GLM-4.7-Flash | By Zhipu AI, completely free | API Key |
| Custom OpenAI-compatible API | Any OpenAI-format compatible endpoint | API URL + API Key + Model Name |

### Step 2: Configure the API

1. Open the app and go to the **Settings** page
2. Toggle the **AI Features** switch on
3. Read and accept the privacy notice
4. Select your preferred provider in the AI configuration dialog
5. Enter the corresponding API credentials and save

### Step 3: Use AI Features

Once configured, you can:

- **AI Chat**: Go to the "Chat" tab to talk with the AI study assistant, which automatically analyzes your courses and tasks
- **Image Recognition Import**: Go to the "Import" tab, select "Image Recognition", take a photo or choose a timetable image to auto-import
- **Custom API Vision**: In custom API settings, manually set vision capability support (Auto/Enabled/Disabled)

### Important Notes

- Free models are provided by third-party platforms; your data may be collected by these platforms. Do not upload any personal or sensitive information.
- AI recognition results are for reference only. Please verify accuracy yourself.
- Model capabilities vary significantly. Higher-quality models generally provide more accurate recognition and more valuable suggestions.
- If no API is configured, AI features will remain disabled without affecting other app functionality.

---

## Tech Stack

- **Framework**: Flutter 3.x
- **Local Storage**: Hive + SharedPreferences
- **State Management**: Provider
- **Backend**: Supabase (authentication + cloud sync)
- **OCR**: Google ML Kit (on-device text recognition)
- **UI Design**: Material Design 3, glassmorphism, animated transitions, haptic feedback

---

## Build

### Requirements

- Flutter SDK >=3.0.0 <4.0.0
- Android Studio / VS Code
- Java 17+ (for Android builds)

### Build APK

```bash
cd flutter
flutter pub get
flutter build apk --release
```

Output: `flutter/build/app/outputs/flutter-apk/app-release.apk`

---

## License

This project is open-sourced under the MIT License.
