import 'dart:ui';
import 'package:flutter/material.dart';

enum ToastType { success, error, info }

class ToastNotification {
  static final ToastNotification _instance = ToastNotification._internal();
  factory ToastNotification() => _instance;
  ToastNotification._internal();

  OverlayEntry? _overlayEntry;
  AnimationController? _animationController;

  void show(
    BuildContext context,
    String message, {
    ToastType type = ToastType.success,
    Duration duration = const Duration(milliseconds: 2000),
    VoidCallback? onTap,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    _removeExisting();

    _overlayEntry = OverlayEntry(
      builder: (context) => _ToastWidget(
        message: message,
        type: type,
        duration: duration,
        onTap: onTap,
        actionLabel: actionLabel,
        onAction: onAction,
        onDismiss: _removeExisting,
      ),
    );

    Overlay.of(context).insert(_overlayEntry!);
  }

  void _removeExisting() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  void dismiss() {
    _removeExisting();
  }
}

class _ToastWidget extends StatefulWidget {
  final String message;
  final ToastType type;
  final Duration duration;
  final VoidCallback? onTap;
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback onDismiss;

  const _ToastWidget({
    required this.message,
    required this.type,
    this.duration = const Duration(milliseconds: 2000),
    this.onTap,
    this.actionLabel,
    this.onAction,
    required this.onDismiss,
  });

  @override
  State<_ToastWidget> createState() => _ToastWidgetState();
}

class _ToastWidgetState extends State<_ToastWidget> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<Offset> _slideAnimation;
  late Animation<double> _fadeAnimation;
  // 收场标志：自动超时与用户点击都可能触发收场，保证只执行一次
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );

    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    ));

    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    ));

    _controller.forward();

    Future.delayed(widget.duration, _dismiss);
  }

  void _dismiss() {
    if (_dismissed || !mounted) return;
    _dismissed = true;
    _controller.reverse().then((_) {
      if (mounted) widget.onDismiss();
    });
  }

  /// 点击 toast：先开始收场动画，随后立即触发点击回调
  /// （如弹出更新对话框），收场与后续动作互不阻塞
  void _handleTap() {
    _dismiss();
    widget.onTap?.call();
  }

  /// 点击右侧动作按钮（如「不再提示」）：与整条点击同样先收场再回调。
  /// 嵌套在整条 GestureDetector 内部，手势竞技场内层识别器优先，
  /// 动作按钮区域点击不会触发整条的 onTap
  void _handleActionTap() {
    _dismiss();
    widget.onAction?.call();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;
    final isSuccess = widget.type == ToastType.success;
    final isInfo = widget.type == ToastType.info;
    final bgColor = isSuccess
        ? const Color(0xFF4CAF50)
        : isInfo
            ? const Color(0xFF2196F3)
            : const Color(0xFFE53935);

    // toast 药丸本体：带 onTap 时包 GestureDetector（仅药丸区域可点，
    // 不占满整行，避免误触 toast 两侧的页面内容）
    Widget toastCard = ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width - 32,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: bgColor.withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.2),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: bgColor.withValues(alpha: 0.3),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  isSuccess ? Icons.check_circle_outline : Icons.error_outline,
                  color: Colors.white,
                  size: 22,
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Padding(
                    // 与 22px 图标顶部对齐时 13px 小字的光学微调
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      widget.message,
                      softWrap: true,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
                // 右侧动作按钮（如「不再提示」）：白色小字不加粗 + 下划线，
                // 点击触发 onAction；仅在传入 actionLabel 时显示
                if (widget.actionLabel != null) ...[
                  const SizedBox(width: 10),
                  GestureDetector(
                    onTap: _handleActionTap,
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 4, left: 2, right: 2),
                      child: Text(
                        widget.actionLabel!,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w400,
                          decoration: TextDecoration.underline,
                          decorationColor:
                              Colors.white.withValues(alpha: 0.85),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    if (widget.onTap != null) {
      toastCard = GestureDetector(
        onTap: _handleTap,
        behavior: HitTestBehavior.opaque,
        child: toastCard,
      );
    }

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: EdgeInsets.only(top: 16 + topPadding, left: 16, right: 16),
          child: SlideTransition(
            position: _slideAnimation,
            child: FadeTransition(
              opacity: _fadeAnimation,
              child: Center(
                child: toastCard,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final toastNotification = ToastNotification();
