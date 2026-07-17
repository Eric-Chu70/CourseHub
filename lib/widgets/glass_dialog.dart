import 'dart:ui';
import 'package:flutter/material.dart';

/// 苹果 G2 风格对话框外壳：大圆角(24) + 半透明白色遮罩（无额外模糊）。
///
/// 说明：本组件不再自带 BackdropFilter 模糊，因为调用方通常已通过
/// `showGeneralDialog` 的 pageBuilder 顶层 `BackdropFilter(blur: 5)`
/// 对背景做了模糊处理。这里仅提供半透明白色遮罩 + 圆角 + 边框 + 阴影。
///
/// 用法：将对话框最外层 `Container(decoration: BoxDecoration(color: Colors.white, ...))`
/// 替换为 `GlassDialogShell(child: 原child)`，即可获得通透外观。
class GlassDialogShell extends StatelessWidget {
  final Widget child;
  final double radius;
  final EdgeInsets? padding;
  final List<BoxShadow>? boxShadow;

  const GlassDialogShell({
    super.key,
    required this.child,
    this.radius = 24,
    this.padding,
    this.boxShadow,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.6),
            width: 0.5,
          ),
          boxShadow: boxShadow ??
              [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.12),
                  blurRadius: 24,
                  offset: const Offset(0, 12),
                ),
              ],
        ),
        child: child,
      ),
    );
  }
}

class GlassDialog {
  static Future<T?> show<T>({
    required BuildContext context,
    required Widget child,
    double? maxWidth,
    double? maxHeight,
  }) {
    return showGeneralDialog<T>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Dismiss',
      barrierColor: Colors.black.withValues(alpha: 0.3),
      transitionDuration: const Duration(milliseconds: 250),
      pageBuilder: (context, animation, secondaryAnimation) {
        return Center(
          child: Material(
            color: Colors.transparent,
            child: FadeTransition(
              opacity: animation,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.9, end: 1.0).animate(
                  CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
                ),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 24),
                  constraints: BoxConstraints(
                    maxWidth: maxWidth ?? 400,
                    maxHeight: maxHeight ?? MediaQuery.of(context).size.height * 0.8,
                  ),
                  child: GlassDialogShell(child: child),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  static Widget buildHeader({
    required String title,
    required VoidCallback onClose,
    IconData? icon,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF4A90E2).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: const Color(0xFF4A90E2), size: 20),
                ),
                const SizedBox(width: 12),
              ],
              Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          GestureDetector(
            onTap: onClose,
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(Icons.close, size: 18, color: Colors.grey.shade700),
            ),
          ),
        ],
      ),
    );
  }

  static Widget buildButton({
    required String text,
    required VoidCallback onPressed,
    bool isPrimary = true,
  }) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: isPrimary ? const Color(0xFF4A90E2) : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: isPrimary ? null : Border.all(color: Colors.white.withValues(alpha: 0.4)),
        ),
        child: Center(
          child: Text(
            text,
            style: TextStyle(
              color: isPrimary ? Colors.white : Colors.grey.shade700,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================
// 模糊下拉选择框 & 弹出菜单
// ============================================================

/// 统一的模糊菜单外壳：ClipRRect + BackdropFilter + 半透明白色。
Widget _blurredMenuShell({
  required Widget child,
  double radius = 16,
  double blurSigma = 20,
  double alpha = 0.7,
}) {
  return DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.15),
          blurRadius: 12,
          offset: const Offset(0, 4),
        ),
      ],
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: alpha),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.5),
              width: 0.5,
            ),
          ),
          child: Material(
            color: Colors.transparent,
            child: child,
          ),
        ),
      ),
    ),
  );
}

/// 模糊下拉选择框 — 替代 DropdownButton，弹出菜单带毛玻璃模糊效果。
///
/// 用法：将 `DropdownButtonHideUnderline(child: DropdownButton(...))`
/// 替换为 `BlurredDropdown(...)`，外层 Container 保持不变。
class BlurredDropdown<T> extends StatefulWidget {
  final T value;
  final List<DropdownMenuItem<T>>? items;
  final ValueChanged<T?>? onChanged;
  final bool isExpanded;
  final Widget? icon;
  final double menuRadius;

  const BlurredDropdown({
    super.key,
    required this.value,
    required this.items,
    this.onChanged,
    this.isExpanded = false,
    this.icon,
    this.menuRadius = 16,
  });

  @override
  State<BlurredDropdown<T>> createState() => _BlurredDropdownState<T>();
}

class _BlurredDropdownState<T> extends State<BlurredDropdown<T>> {
  @override
  Widget build(BuildContext context) {
    DropdownMenuItem<T>? currentItem;
    for (final item in widget.items ?? <DropdownMenuItem<T>>[]) {
      if (item.value == widget.value) {
        currentItem = item;
        break;
      }
    }

    return GestureDetector(
      onTap: _showMenu,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          mainAxisSize: widget.isExpanded ? MainAxisSize.max : MainAxisSize.min,
          children: [
            if (widget.isExpanded)
              Expanded(child: currentItem?.child ?? const SizedBox())
            else
              currentItem?.child ?? const SizedBox(),
            const SizedBox(width: 4),
            widget.icon ??
                Icon(Icons.expand_more, size: 20, color: Colors.grey.shade600),
          ],
        ),
      ),
    );
  }

  void _showMenu() async {
    final renderBox = context.findRenderObject() as RenderBox;
    final position = renderBox.localToGlobal(Offset.zero);
    final size = renderBox.size;
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;

    final spaceBelow = screenHeight - position.dy - size.height;
    final menuMaxHeight = spaceBelow > 50 ? spaceBelow : 250.0;

    final result = await showGeneralDialog<T>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Dropdown',
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 150),
      pageBuilder: (context, animation, secondaryAnimation) {
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.pop(context),
              ),
            ),
            Positioned(
              left: position.dx.clamp(0.0, screenWidth - size.width),
              top: position.dy + size.height + 4,
              width: size.width,
              child: FadeTransition(
                opacity: CurvedAnimation(
                    parent: animation, curve: Curves.easeOut),
                child: Material(
                  color: Colors.transparent,
                  child: _blurredMenuShell(
                    radius: widget.menuRadius,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: menuMaxHeight),
                      child: ListView.builder(
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        itemCount: widget.items?.length ?? 0,
                        itemBuilder: (context, index) {
                          final item = widget.items![index];
                          final isSelected = item.value == widget.value;
                          return InkWell(
                            onTap: () => Navigator.pop(context, item.value),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 12),
                              child: Row(
                                children: [
                                  Expanded(child: item.child),
                                  if (isSelected) ...[
                                    const SizedBox(width: 8),
                                    const Icon(Icons.check,
                                        size: 16, color: Color(0xFF4A90E2)),
                                  ],
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );

    if (result != null && widget.onChanged != null) {
      widget.onChanged!(result);
    }
  }
}

/// 模糊弹出菜单项
class BlurredPopupMenuItem<T> {
  final T value;
  final IconData icon;
  final String label;
  final Color? iconColor;
  final Color? textColor;

  const BlurredPopupMenuItem({
    required this.value,
    required this.icon,
    required this.label,
    this.iconColor,
    this.textColor,
  });
}

/// 模糊弹出菜单按钮 — 替代 PopupMenuButton，弹出菜单带毛玻璃模糊效果。
class BlurredPopupMenuButton<T> extends StatelessWidget {
  final Widget icon;
  final List<BlurredPopupMenuItem<T>> items;
  final ValueChanged<T>? onSelected;
  final double radius;
  final EdgeInsets iconPadding;
  final double menuWidth;

  const BlurredPopupMenuButton({
    super.key,
    required this.icon,
    required this.items,
    this.onSelected,
    this.radius = 16,
    this.iconPadding = const EdgeInsets.all(8),
    this.menuWidth = 160,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _showMenu(context),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: iconPadding,
        child: icon,
      ),
    );
  }

  void _showMenu(BuildContext context) async {
    final renderBox = context.findRenderObject() as RenderBox;
    final position = renderBox.localToGlobal(Offset.zero);
    final size = renderBox.size;
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;

    final left = (position.dx + size.width - menuWidth)
        .clamp(8.0, screenWidth - menuWidth - 8);
    final top = (position.dy + size.height + 4)
        .clamp(0.0, screenHeight - items.length * 48 - 16);

    final result = await showGeneralDialog<T>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Menu',
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 150),
      pageBuilder: (context, animation, secondaryAnimation) {
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.pop(context),
              ),
            ),
            Positioned(
              left: left,
              top: top,
              child: FadeTransition(
                opacity: CurvedAnimation(
                    parent: animation, curve: Curves.easeOut),
                child: Material(
                  color: Colors.transparent,
                  child: _blurredMenuShell(
                    radius: radius,
                    child: SizedBox(
                      width: menuWidth,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: items.map((item) {
                          return InkWell(
                            onTap: () => Navigator.pop(context, item.value),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 12),
                              child: Row(
                                children: [
                                  Icon(item.icon,
                                      size: 20,
                                      color: item.iconColor ??
                                          const Color(0xFF4A90E2)),
                                  const SizedBox(width: 12),
                                  Text(
                                    item.label,
                                    style: TextStyle(
                                        fontSize: 15,
                                        color: item.textColor ??
                                            const Color(0xFF333333)),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );

    if (result != null && onSelected != null) {
      onSelected!(result);
    }
  }
}
