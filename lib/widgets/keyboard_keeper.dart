import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// 键盘守护：内联重命名编辑期的"焦点在但键盘没了"自愈器。
///
/// 背景：键盘弹出过程会触发框架重建，某些结构变化会把刚获得焦点的
/// EditableText 连同**存活的输入连接**一并销毁重建（clearClient → 键盘
/// 收起）。重建后的新 State 继承了仍持有焦点的 FocusNode——没有焦点
/// 变化事件，它**永远不会重开连接**，键盘就此消失且焦点守卫无感知
/// （表现为"键盘弹出后 0.5s 内意外收起/秒收"）。
///
/// 做法：进入编辑后的有界窗口内周期检查"编辑框仍持焦但 viewInsets 为
/// 零"，命中则 unfocus + requestFocus 强制重开连接。三重有界保证不误伤：
/// - 仅 Android/iOS 启用（桌面无软键盘，viewInsets 恒 0 会误判）；
/// - 窗口 2s（覆盖"延迟聚焦 → 键盘弹出 → 弹出后重建杀连接"全链路）；
/// - 最多自愈 3 次（用户主动收键盘不会反复被弹回）。
class KeyboardKeeper {
  KeyboardKeeper({required this.isFocused, required this.refocus});

  /// 编辑框当前是否持有焦点（编辑态已结束时应返回 false）
  final bool Function() isFocused;

  /// 强制重开输入连接：unfocus + requestFocus
  final VoidCallback refocus;

  Timer? _timer;
  int _rekicksLeft = 3;
  bool _disposed = false;

  /// [context] 用于读取当前 View 的 viewInsets（判断键盘是否真的在屏上）
  void arm(BuildContext context) {
    if (_disposed) return;
    if (kIsWeb) return;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
        break;
      default:
        return;
    }
    final deadline = DateTime.now().add(const Duration(milliseconds: 2000));
    _timer = Timer.periodic(const Duration(milliseconds: 120), (timer) {
      if (_disposed ||
          _rekicksLeft <= 0 ||
          DateTime.now().isAfter(deadline) ||
          !context.mounted ||
          !isFocused()) {
        timer.cancel();
        return;
      }
      final view = View.of(context);
      if (view.viewInsets.bottom != 0) return;
      // 焦点在但键盘没了：强制重开连接。
      // unfocus 与 requestFocus 必须隔帧——同一帧内连发会被框架合并成
      // 一次焦点应用（起止相同 = 无变化事件），EditableText 不会重新
      // 打开输入连接，自愈空转。
      _rekicksLeft--;
      refocus();
    });
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}
