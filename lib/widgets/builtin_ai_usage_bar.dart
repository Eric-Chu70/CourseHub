import 'package:flutter/material.dart';

import '../services/glm_service.dart';
import '../theme/app_theme.dart';

/// 内置模型「今日用量」百分比 + 进度条。
///
/// AI 配置对话框的内置模型卡片与对话页节点菜单底部共用。
/// 数据源是本地每日计数（AIService，发起请求即 +1，跨天自复位），
/// 分母为本地每日限量（与服务端 device_daily 默认值对齐）——
/// 展示为体验层提示，真正的执法在中转服务端。
class BuiltinAiUsageBar extends StatefulWidget {
  const BuiltinAiUsageBar({super.key, this.inline = false});

  /// true：文字与进度条同行，进度条占满右侧剩余宽度（用于卡片）；
  /// false：文字在上、进度条在下（用于窄菜单底部）
  final bool inline;

  @override
  State<BuiltinAiUsageBar> createState() => _BuiltinAiUsageBarState();
}

class _BuiltinAiUsageBarState extends State<BuiltinAiUsageBar> {
  late final Future<int> _usageFuture =
      AIService.instance.builtinDailyUsageCount();

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    const fill = Color(0xFF4A90E2);

    return FutureBuilder<int>(
      future: _usageFuture,
      builder: (context, snapshot) {
        // future 还在 pending 时回退到同步缓存，而不是 0：这条会在 AI 配置
        // 对话框切阶段的动画里被重建，回退成 0 就会看到「33% → 0% → 33%」
        // 的闪跳（缓存由 AIService 在读/写用量时维护，跨天自动失效）
        final count =
            snapshot.data ?? AIService.lastKnownBuiltinUsage ?? 0;
        final limit = AIService.builtinDailyLimit;
        final factor = limit <= 0 ? 0.0 : (count / limit).clamp(0.0, 1.0);
        final percent = (factor * 100).round();

        final label = Text(
          '今日用量 $percent%',
          style: TextStyle(fontSize: 11, color: palette.textSecondary),
        );
        // 进度条：主色填充 + 主色低透明轨道（深浅色模式均成立）
        final bar = Container(
          height: 4,
          decoration: BoxDecoration(
            color: fill.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(999),
          ),
          alignment: AlignmentDirectional.centerStart,
          child: FractionallySizedBox(
            widthFactor: factor,
            child: Container(
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
        );

        if (widget.inline) {
          return Row(
            children: [
              label,
              const SizedBox(width: 10),
              Expanded(child: bar),
            ],
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            label,
            const SizedBox(height: 5),
            bar,
          ],
        );
      },
    );
  }
}
