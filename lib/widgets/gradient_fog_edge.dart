import 'package:flutter/material.dart';

/// 单向雾化边缘：浓度从贴边那一端最强、向内侧按 smoothstep 衰减归零
/// （零导数收尾，不出分界线）。方向由 [anchor] 决定，贴顶/贴底通用。
///
/// **只有渐变，不挂任何 BackdropFilter**——这是定稿形态：先前做过分带
/// 渐进模糊的版本，在弹窗里会显出一条与输入条割裂的"模糊带"，观感不如
/// 纯雾化干净，且减弱/非减弱两套分支反而增加维护面。现在两种模式同一份
/// 雾化，行为一致。
///
/// 用法上它是"贴在某个控件背后的一层雾"：把本组件放在 `Stack` 的第一层、
/// 目标控件放在其上，控件就仿佛从雾里浮出来（对话弹窗的输入条即如此，
/// 雾的上沿正好是输入条顶边，消息列表从其下方穿过）。
class GradientFogEdge extends StatelessWidget {
  const GradientFogEdge({
    super.key,
    required this.color,
    this.height = 72,
    this.maxScrim = 0.70,
    this.decayBand = 0.40,
    this.anchor = Alignment.bottomCenter,
  });

  /// 雾化基色（与标题栏同源：`AppColors.of(context).glassShell`）
  final Color color;

  /// 雾层总高
  final double height;

  /// 贴边端的最大浓度
  final double maxScrim;

  /// 衰减带占比：从贴边端算起，超过此比例的部分才升到满浓度
  final double decayBand;

  /// 贴边方向：bottomCenter = 底部最浓、向上归零；topCenter 反之
  final Alignment anchor;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: DecoratedBox(
          decoration: BoxDecoration(gradient: _gradient()),
        ),
      ),
    );
  }

  /// 雾化渐变：与标题栏非 reduce 路径同一条曲线（贴边满浓度，随衰减带
  /// 归零），只是方向可配。粗采样会把收尾渲染成直线崖，故按 0.2 步长加密。
  LinearGradient _gradient() {
    double ss(double t) => t * t * (3 - 2 * t);
    final start = (1.0 - decayBand).clamp(0.0, 0.9);
    final span = 1.0 - start;
    final toward = anchor == Alignment.bottomCenter
        ? Alignment.topCenter
        : Alignment.bottomCenter;
    return LinearGradient(
      begin: anchor,
      end: toward,
      colors: [
        color.withValues(alpha: maxScrim),
        color.withValues(alpha: maxScrim),
        for (final f in const [0.2, 0.4, 0.6, 0.8])
          color.withValues(alpha: maxScrim * (1 - ss(f))),
        color.withValues(alpha: 0.0),
      ],
      stops: [
        0.0,
        start,
        for (final f in const [0.2, 0.4, 0.6, 0.8]) start + span * f,
        1.0,
      ],
    );
  }
}
