// 共享更新对话框：检查 → 发现新版本 → 下载 → 安装在同一对话框内完成。
// 供两处入口复用：
//  1. 设置页「检查更新」按钮：打开即自动联网检查；
//  2. 启动静默检查（main.dart）：检查已在外部完成，传入 [preloadedInfo]
//     直接进入「发现新版本」阶段，跳过重复转圈。
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import '../main.dart' show appVersion;
import '../services/update_service.dart';
import '../widgets/glass_dialog.dart';
import '../widgets/toast_notification.dart';

/// 更新阶段（更新对话框）
enum UpdatePhase {
  checking, // 检查中
  available, // 发现新版本
  upToDate, // 已是最新
  error, // 检查失败
  downloading, // 下载中
  downloaded, // 下载完成
  downloadFailed, // 下载失败
}

/// 更新对话框：检查 → 发现新版本 → 下载 → 安装在同一对话框内完成。
/// 各阶段共用固定壳尺寸（宽 360 × 内容高 380），不随内容变化，
/// 内容垂直居中，切换阶段无尺寸跳变。
///
/// [preloadedInfo] 已知的新版本信息（外部检查过）：跳过检查直接展示
/// 「发现新版本」；不传则打开即自动检查。
/// [reduceMotion] 减弱动态效果；不传（null）时读取全局设置开关。
Future<void> showUpdateDialog(
  BuildContext context, {
  bool? reduceMotion,
  AppUpdateInfo? preloadedInfo,
}) async {
  // 全局「减弱动态效果」：未显式指定时自动读取设置页开关
  final bool rm = reduceMotion ?? await readReduceMotionPref();
  if (!context.mounted) return;

  UpdatePhase phase =
      preloadedInfo != null ? UpdatePhase.available : UpdatePhase.checking;
  AppUpdateInfo? updateInfo = preloadedInfo;
  String? checkError;
  CancelToken? downloadToken;
  int receivedBytes = 0;
  int totalBytes = 0;
  String? apkPath;
  // 自动检查只触发一次：防止检查完成后 setState 重建 builder 再次
  // 调用 startCheck 造成「检查 → 结果 → 又检查」死循环；
  // 已有外部检查结果（preloadedInfo）时不再自动检查
  bool autoCheckStarted = preloadedInfo != null;
  // 请求进行中标志：不能用 phase == checking 判断（phase 初始值即为
  // checking，会导致打开对话框时的首次自动检查被防重入拦截、请求
  // 根本发不出去，转圈永不结束）
  bool isChecking = false;

  // 对话框可能已被关闭（外部点击），setDialogState 需容错
  void Function(VoidCallback)? setDs;
  void safeSetState(VoidCallback fn) {
    try {
      setDs?.call(fn);
    } catch (_) {}
  }

  // 阶段切换过渡（与登录对话框副标题同款动效）：旧内容模糊淡出，
  // 新内容自模糊中清晰淡入，交叉过渡不跳变；
  // 「减弱动态效果」开启时退化为单纯淡入淡出（无模糊、无缩放）
  Widget blurSwitch(Widget child) => AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        transitionBuilder: (child, animation) {
          if (rm) {
            return FadeTransition(opacity: animation, child: child);
          }
          return FadeTransition(
            opacity: animation,
            child: AnimatedBuilder(
              animation: animation,
              builder: (context, grandChild) => ImageFiltered(
                imageFilter: ImageFilter.blur(
                  sigmaX: 6 * (1.0 - animation.value),
                  sigmaY: 6 * (1.0 - animation.value),
                ),
                child: Transform.scale(
                  scale: 0.92 + 0.08 * animation.value,
                  child: grandChild,
                ),
              ),
              child: child,
            ),
          );
        },
        // Stack 尺寸只由新内容决定（旧内容仅水平约束、垂直居中悬浮，
        // 不参与定尺寸）：新内容一进来整块布局就落到最终位置，图标/
        // 标题不会因旧的高内容淡出期间还撑着布局而先高后低地跳动
        layoutBuilder: (currentChild, previousChildren) => Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            for (final Widget child in previousChildren)
              Positioned(left: 0, right: 0, child: child),
            if (currentChild != null) currentChild,
          ],
        ),
        child: child,
      );

  Future<void> startCheck() async {
    if (isChecking) return;
    isChecking = true;
    safeSetState(() => phase = UpdatePhase.checking);
    final result = await UpdateService.checkForUpdate(appVersion);
    isChecking = false;
    safeSetState(() {
      if (result.error != null) {
        phase = UpdatePhase.error;
        checkError = result.error;
      } else if (result.hasUpdate) {
        phase = UpdatePhase.available;
        updateInfo = result.info;
      } else {
        phase = UpdatePhase.upToDate;
      }
    });
  }

  Future<void> startDownload() async {
    final info = updateInfo;
    if (info == null) return;
    // 本地已有该版本的完整安装包（上次下载/安装残留）：跳过下载，
    // 直接进入「下载完成」
    final String? localPath = await UpdateService.findLocalInstaller(info);
    if (localPath != null) {
      safeSetState(() {
        apkPath = localPath;
        phase = UpdatePhase.downloaded;
      });
      return;
    }
    downloadToken = CancelToken();
    safeSetState(() {
      phase = UpdatePhase.downloading;
      receivedBytes = 0;
      totalBytes = 0;
    });
    // 进度回调节流：约 10 次/秒刷新 UI
    DateTime lastUi = DateTime.now();
    final path = await UpdateService.downloadApk(
      info,
      cancelToken: downloadToken,
      onProgress: (received, total) {
        final now = DateTime.now();
        final finished = total > 0 && received >= total;
        if (!finished && now.difference(lastUi).inMilliseconds < 100) {
          return;
        }
        lastUi = now;
        safeSetState(() {
          receivedBytes = received;
          totalBytes = total;
        });
      },
    );
    safeSetState(() {
      if (path == null) {
        // 用户手动取消：静默回到「发现新版本」，不作为失败提示
        if (downloadToken?.isCancelled ?? false) {
          phase = UpdatePhase.available;
        } else {
          phase = UpdatePhase.downloadFailed;
        }
      } else {
        phase = UpdatePhase.downloaded;
        apkPath = path;
      }
    });
  }

  Future<void> install() async {
    if (apkPath == null) return;
    final String path = apkPath!;
    // Android 拉起系统 APK 安装器；桌面平台按扩展名直接运行安装包
    final bool ok = Platform.isAndroid
        ? await UpdateService.installApk(path)
        : await UpdateService.launchInstaller(path);
    if (!ok && context.mounted) {
      toastNotification.show(context, '无法启动安装器，请手动安装',
          type: ToastType.error);
      return;
    }
    // 安装器已成功拉起：自动清理本地安装包（Android 的安装包正被系统
    // 安装器读取，不删；桌面安装包可能仍被安装进程占用，由服务端
    // 延迟重试删除）。不 await，后台静默清理。
    if (!Platform.isAndroid) {
      UpdateService.deleteInstallerLater(path);
    }
  }

  // 统一次按钮：灰描边 TextButton（与关于对话框「检查更新」及全应用对话框一致）
  Widget buildSecondaryButton(String text, VoidCallback? onPressed) {
    return Expanded(
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: Colors.grey.shade300),
          ),
        ),
        child: Text(text),
      ),
    );
  }

  // 统一主按钮：蓝色 ElevatedButton
  Widget buildPrimaryButton(String text, VoidCallback? onPressed) {
    return Expanded(
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF4A90E2),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        child: Text(text),
      ),
    );
  }

  await showBouncyDialog(
    context: context,
    barrierLabel: '检查更新',
    shellPadding: const EdgeInsets.all(24),
    shellWidth: 360,
    reduceMotion: rm,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) {
        // 捕获 setState 引用（供异步回调容错刷新）
        setDs = setDialogState;
        // 打开即开始检查（仅首次；重试由按钮显式触发）
        if (!autoCheckStarted) {
          autoCheckStarted = true;
          startCheck();
        }

        // 阶段性内容（图标 + 标题 + 正文）
        Widget icon;
        String title;
        List<Widget> body;
        List<Widget> actions;

        switch (phase) {
          case UpdatePhase.checking:
            icon = const SizedBox(
              width: 64,
              height: 64,
              child: Padding(
                padding: EdgeInsets.all(16),
                child: CircularProgressIndicator(
                  color: Color(0xFF4A90E2),
                  strokeWidth: 3,
                ),
              ),
            );
            title = '检查更新';
            body = [
              Text(
                '正在检查更新…',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey.shade600,
                ),
              ),
            ];
            actions = [];

          case UpdatePhase.upToDate:
            icon = Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(
                Icons.check_circle_rounded,
                size: 36,
                color: Colors.white,
              ),
            );
            title = '已是最新版本';
            body = [
              Text(
                '当前版本 v$appVersion',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey.shade600,
                ),
              ),
            ];
            actions = [
              buildPrimaryButton('确定', () => Navigator.pop(context)),
            ];

          case UpdatePhase.error:
            icon = Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(
                Icons.cloud_off_rounded,
                size: 36,
                color: Colors.white,
              ),
            );
            title = '检查更新失败';
            body = [
              Text(
                checkError ?? '网络连接失败',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey.shade600,
                ),
              ),
            ];
            actions = [
              buildSecondaryButton('关闭', () => Navigator.pop(context)),
              buildPrimaryButton('重试', startCheck),
            ];

          case UpdatePhase.available:
            final info = updateInfo!;
            icon = Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: const Color(0xFF4A90E2),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(
                Icons.system_update_alt_rounded,
                size: 32,
                color: Colors.white,
              ),
            );
            title = '发现新版本';
            body = [
              // 版本信息卡片：当前版本 / 最新版本
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Text(
                          '当前版本',
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey.shade500,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          'v$appVersion',
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Text(
                          '最新版本',
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey.shade500,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          'v${info.version}',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF4A90E2),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // 更新说明（可选，超过两行限高滚动 + 触底回弹）
              if (info.notes != null && info.notes!.isNotEmpty) ...[
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  // 两行文字高度：13px × 1.6 行高 × 2 行
                  constraints: const BoxConstraints(maxHeight: 42),
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics(),
                    ),
                    child: Text(
                      info.notes!,
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey.shade600,
                        height: 1.6,
                      ),
                    ),
                  ),
                ),
              ],
            ];
            actions = [
              buildSecondaryButton('取消', () => Navigator.pop(context)),
              buildPrimaryButton('下载更新', startDownload),
            ];

          case UpdatePhase.downloading:
            final info = updateInfo!;
            final progress =
                totalBytes > 0 ? receivedBytes / totalBytes : null;
            final receivedMb =
                (receivedBytes / 1024 / 1024).toStringAsFixed(1);
            final totalMb = totalBytes > 0
                ? (totalBytes / 1024 / 1024).toStringAsFixed(1)
                : null;
            icon = Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: const Color(0xFF4A90E2),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(
                Icons.download_rounded,
                size: 32,
                color: Colors.white,
              ),
            );
            title = '正在下载 v${info.version}';
            body = [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 8,
                  backgroundColor: Colors.grey.shade200,
                  valueColor:
                      const AlwaysStoppedAnimation(Color(0xFF4A90E2)),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                totalMb != null
                    ? '$receivedMb MB / $totalMb MB${progress != null ? ' · ${(progress * 100).toInt()}%' : ''}'
                    : '已下载 $receivedMb MB',
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey.shade600,
                ),
              ),
            ];
            actions = [
              buildSecondaryButton('取消下载', () {
                downloadToken?.cancel();
                // 取消后回到「发现新版本」，可重新下载
                setDialogState(() => phase = UpdatePhase.available);
              }),
            ];

          case UpdatePhase.downloaded:
            final info = updateInfo!;
            icon = Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(
                Icons.check_circle_rounded,
                size: 36,
                color: Colors.white,
              ),
            );
            title = '下载完成';
            if (Platform.isAndroid) {
              body = [
                Text(
                  'v${info.version} 已下载完成，\n安装完成后旧版本数据将自动保留。',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey.shade600,
                    height: 1.5,
                  ),
                ),
              ];
              actions = [
                buildSecondaryButton('以后再说', () => Navigator.pop(context)),
                buildPrimaryButton('立即安装', install),
              ];
            } else {
              // 桌面平台：显示下载路径，可在文件管理器中定位
              body = [
                Text(
                  'v${info.version} 已下载完成。',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey.shade600,
                    height: 1.5,
                  ),
                ),
                if (apkPath != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    apkPath!,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade500,
                    ),
                  ),
                ],
              ];
              actions = [
                buildSecondaryButton('关闭', () => Navigator.pop(context)),
                buildPrimaryButton('安装', install),
              ];
            }

          case UpdatePhase.downloadFailed:
            icon = Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(
                Icons.error_outline_rounded,
                size: 36,
                color: Colors.white,
              ),
            );
            title = '下载失败';
            body = [
              Text(
                '下载中断或网络不稳定，请重试。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey.shade600,
                ),
              ),
            ];
            actions = [
              buildSecondaryButton('关闭', () => Navigator.pop(context)),
              buildPrimaryButton('重试下载', startDownload),
            ];
        }

        // 固定尺寸：各阶段共用同一壳尺寸，不随内容变化。
        // 内容区居中，按钮固定在底部（与内容多寡无关，位置恒定）。
        // 图标/标题/正文/按钮四类元素均以阶段为 key 走模糊淡出淡入；
        // 布局尺寸由 layoutBuilder 固定跟随新内容，动画全程在最终位置
        // 进行，不会因新旧内容高度差产生位移
        return SizedBox(
          width: double.infinity,
          height: 300,
          child: Column(
            children: [
              // 内容区：弹性占位，剩余空间上下均分使内容视觉居中
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    blurSwitch(
                      KeyedSubtree(
                        key: ValueKey<UpdatePhase>(phase),
                        child: icon,
                      ),
                    ),
                    const SizedBox(height: 16),
                    blurSwitch(
                      KeyedSubtree(
                        key: ValueKey<UpdatePhase>(phase),
                        child: Text(
                          title,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    blurSwitch(
                      KeyedSubtree(
                        key: ValueKey<UpdatePhase>(phase),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: body,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // 按钮区：固定在底部
              blurSwitch(
                KeyedSubtree(
                  key: ValueKey<UpdatePhase>(phase),
                  child: Row(
                    children: [
                      for (int i = 0; i < actions.length; i++) ...[
                        if (i > 0) const SizedBox(width: 12),
                        actions[i],
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}
