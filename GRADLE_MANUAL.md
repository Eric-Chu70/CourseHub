# Gradle 手动安装指南

如果自动下载 Gradle 失败，请手动下载：

## 方法 1：手动下载 Gradle

### 步骤 1：下载 Gradle
访问以下任一地址下载 Gradle 8.14.3：

- 腾讯云镜像：https://mirrors.cloud.tencent.com/gradle/gradle-8.14.3-bin.zip
- 阿里云镜像：https://maven.aliyun.com/repository/public/org/gradle/gradle/8.14.3/gradle-8.14.3-bin.zip
- 官方地址：https://services.gradle.org/distributions/gradle-8.14.3-bin.zip

### 步骤 2：找到 Gradle 缓存目录
默认位置：
```
C:\Users\你的用户名\.gradle\wrapper\dists\gradle-8.14.3-bin\
```

### 步骤 3：解压 Gradle
1. 在 `gradle-8.14.3-bin` 目录下会看到一个随机字符串文件夹（如 `abc123def456`）
2. 将下载的 zip 文件解压到这个随机字符串文件夹内
3. 解压后应该有 `gradle-8.14.3` 文件夹

### 步骤 4：重启 Android Studio
关闭并重新打开项目，Gradle 会检测到本地文件

## 方法 2：使用已安装的 Gradle

如果你已经安装了 Gradle：

### 步骤 1：创建 local.properties
在 `flutter/android/` 目录下创建 `local.properties` 文件：

```properties
flutter.sdk=C:\\src\\flutter
sdk.dir=C:\\Users\\你的用户名\\AppData\\Local\\Android\\Sdk
```

### 步骤 2：配置 Gradle
在 `flutter/gradle/wrapper/gradle-wrapper.properties` 中指定本地 Gradle 路径

## 方法 3：使用代理

### 步骤 1：配置代理
在 Android Studio 中：
1. **File** → **Settings** → **Appearance & Behavior** → **System Settings** → **HTTP Proxy**
2. 选择 **Manual proxy configuration**
3. 输入你的代理服务器和端口

### 步骤 2：重试 Gradle 同步
点击 **File** → **Sync Project with Gradle Files**

## 常见问题

### Q: 找不到 .gradle 文件夹
A: 这是隐藏文件夹，需要在文件资源管理器中勾选"显示隐藏的项目"

### Q: 解压后还是报错
A: 确保解压后的目录结构是：
```
gradle-8.14.3-bin/
└── [随机字符串]/
    ├── gradle-8.14.3/
    │   ├── bin/
    │   ├── lib/
    │   └── ...
    └── gradle-8.14.3-bin.zip
```

### Q: 想使用其他 Gradle 版本
A: 修改 `gradle-wrapper.properties` 中的 `distributionUrl`

## 推荐的 Gradle 版本

- **Gradle**: 8.14.3
- **Android Gradle Plugin**: 8.1.0
- **Kotlin**: 1.9.0

这些版本已经在 `build.gradle` 中配置好了。
