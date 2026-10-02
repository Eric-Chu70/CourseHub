import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 标题栏悬浮件的外观参数（集中一处，便于按"一档一档"微调）。
///
/// 深浅两档分开：浅色下白壳叠在白标题栏上几乎同色，悬浮感主要来自投影；
/// 深色下壳比标题栏雾面更暗一档，靠描边+顶部提亮浮起，投影只作补强。
class FloatingGlassSpec {
  FloatingGlassSpec._();

  /// 圆钮默认直径（同时是点击区）
  static const double defaultSize = 36;

  /// 玻璃壳填充不透明度
  static const double shellAlphaLight = 0.55;
  static const double shellAlphaDark = 0.72;

  /// 顶部提亮层渐变归位点（到此高度占比处回到纯壳色）
  static const double sheenStop = 0.55;

  /// 描边宽度
  static const double borderWidth = 1;

  /// 投影：不透明度（浅/深）/ 模糊半径 / 纵向偏移
  static const double shadowAlphaLight = 0.12;
  static const double shadowAlphaDark = 0.35;
  static const double shadowBlur = 12;
  static const Offset shadowOffset = Offset(0, 3);

  /// 禁用态整体不透明度（含投影一起淡，不留"看不见却压着阴影"的贴片感）
  static const double disabledOpacity = 0.35;

  /// 按住后的目标倍率（1.0 为不放大）。圆钮按压反馈，见 [_PressGrow]。
  /// 实际峰值会略高于这个值——回弹曲线先冲过 [pressScale] 再收住。
  static const double pressScale = 1.2;

  /// 放大与回弹的时长：按下冲到超出、松开落回原尺寸，各走一次同一个补间
  static const Duration pressDuration = Duration(milliseconds: 150);

  /// 回弹曲线：easeOutBack 的输出先越过 1.0 再收回，所以按下会"涨过头"
  /// 一点（1.2 → 峰值约 1.22）再稳在 1.2；反向同理，松开时先压到约 0.98
  /// 再回到 1.0。来回两端都带回弹，用的仍是同一个 [pressDuration]。
  static const Curve pressCurve = Curves.easeOutBack;

  /// 胶囊的按住倍率，比圆盘的 [pressScale] 小一档。
  ///
  /// 圆盘是 36 的等边盒，涨到 1.2 每边只出去 3.6px；徽章胶囊宽 100+px
  /// （模型名一长就更宽），同样 1.2 每边出去 10px 以上，而它与 ⋮ 之间只有
  /// 8px 呼吸位——按下去就直接压在邻座圆盘上。所以胶囊单独一档，曲线与
  /// 时长共用，回弹手感一致。
  static const double pillPressScale = 1.08;

  /// 淡入淡出时长
  static const Duration duration = Duration(milliseconds: 200);

  /// 浮现跨度：列表滚动多少逻辑px 后玻璃壳完全成形
  static const double revealSpan = 28;

  /// 浮现动画时长（固定，不随剩余距离缩放）：甩动时不让壳一两帧扫完，
  /// 中途反向也从当前位置用同样节奏接着走
  static const Duration revealDuration = Duration(milliseconds: 220);
}

/// 把页面 [ScrollController] 的偏移换算成"标题栏悬浮件浮现进度"。
///
/// **不直接把像素映射给界面**——那样快速甩动时 0..[span] 一两帧就扫完，
/// 回弹时 `position.pixels` 还会变负被 clamp 成 0，观感就是"遮罩闪一下
/// 没了"。这里只把偏移算成一个目标值交给 [AnimationController]：固定
/// [duration] 的补间，逐帧推进的是动画自己的 value。中途反向时
/// `animateTo` 从当前 value 接着走（不跳回 0 重来），所以连续回顶再下滑
/// 时两段动画首尾相接、速度连续。
///
/// 本身即 [ValueListenable]，消费方在叶子节点上用 [Opacity] 接收，逐帧
/// 成本只有合成；页面不因滚动重建。
class HeaderReveal implements ValueListenable<double> {
  HeaderReveal(
    this._scroll, {
    required TickerProvider vsync,
    double span = FloatingGlassSpec.revealSpan,
    Duration duration = FloatingGlassSpec.revealDuration,
  })  : _span = span,
        _anim = AnimationController(
          vsync: vsync,
          duration: duration,
          lowerBound: 0,
          upperBound: 1,
        ) {
    _scroll.addListener(_onScroll);
    // 首帧直接落位，避免打开页面时壳从 0 空放一次动画
    _anim.value = _targetFor(_scroll.hasClients ? _scroll.position.pixels : 0);
  }

  final ScrollController _scroll;
  final double _span;
  final AnimationController _anim;
  double _target = 0;

  @override
  double get value => _anim.value;

  @override
  void addListener(VoidCallback listener) => _anim.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _anim.removeListener(listener);

  /// 滚动偏移 → 目标进度：**连续无级**，中间值（0.31、0.77…）原样透传，
  /// 不做档位量化。曲线用一条 smoothstep（3t²-2t³）：首尾零导数，起步不
  /// 会"突然蒙上一层纱"，到位也不会"啪"地收住。整段只用这一条，不串联
  /// 第二条——短区间内嵌套 smoothstep 会渲染成肉眼可见的台阶。
  double _targetFor(double pixels) {
    final t = (pixels / _span).clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }

  void _onScroll() {
    final next = _targetFor(
        _scroll.hasClients ? _scroll.position.pixels : 0.0);
    if (next == _target) return;
    _target = next;
    _anim.animateTo(next, curve: Curves.easeOutCubic);
  }

  /// 外部在滚动偏移被程序性设定（如恢复上次阅读位置）后补一次同步
  void sync() => _onScroll();

  /// 页面 dispose 时调用（不是接口要求，[ValueListenable] 没有 dispose）
  void dispose() {
    _scroll.removeListener(_onScroll);
    _anim.dispose();
  }
}

/// 标题栏悬浮玻璃圆钮。观感参照 HyperOS 设置页：列表贴顶时是无界图标，
/// 内容滚进标题栏后才浮出圆盘与投影（传 [reveal] 实现；不传则常驻）。
///
/// 为什么不用 BackdropFilter：[GradientBlurHeader] 已经对标题栏背景做过
/// 一次渐进模糊，按钮再采一层几乎看不出差别，却要在滚动时每帧重新采样。
/// 悬浮感由三个静态属性表达：半透明壳、描边+顶部提亮、壳外投影。
///
/// 投影为什么单独一层：Material 的 `_RenderInkFeatures.paint` 会先
/// `clipRect(Offset.zero & size)` 再画所有墨迹（含 [Ink] 的装饰），投影
/// 挂在 [Ink] 上就会被裁成方块（实测圆盘外有一圈硬边）。这里整层壳是
/// Material 之外的普通 [Container]——子树走 `super.paint`，不经过那个
/// clipRect，投影因此能完整溢出。
///
/// 性能：壳层整体只被 [Opacity] 控制浓度，壳本身是值相等的 [BoxDecoration]
/// 且包在 [RepaintBoundary] 里——父级逐帧重建时 decoration 判等不标脏，
/// 投影的高斯不会每帧重跑；浮现过程改的只是 OpacityLayer 的 alpha。
class FloatingGlassButton extends StatelessWidget {
  const FloatingGlassButton({
    super.key,
    required this.child,
    this.onTap,
    this.size,
    this.tint,
    this.borderRadius,
    this.dimWhenDisabled = true,
    this.growOnPress,
    this.reveal,
    this.margin,
  });

  /// 图标内容（一般是一个 [Icon]）
  final Widget child;

  /// 点击回调；null 视为禁用，整块降到 [FloatingGlassSpec.disabledOpacity]
  final VoidCallback? onTap;

  /// 直径，同时作为点击区；null 取 [FloatingGlassSpec.defaultSize]
  final double? size;

  /// 叠加在玻璃壳上的着色，null 为纯玻璃
  final Color? tint;

  /// null 为正圆；传值则为圆角方形
  final BorderRadius? borderRadius;

  /// onTap 为 null 时是否淡出。只是暂时不可点（如刷新进行中、图标正在
  /// 自转）时传 false，保持满浓度
  final bool dimWhenDisabled;

  /// 按住时整颗圆盘放大到 [FloatingGlassSpec.pressScale]，松开回弹。
  /// null 时跟随 [onTap]：不可点就不给按压反馈。
  /// 圆盘自己不接管点击、菜单由外层控件弹出的场合（对话页的 ⋮）显式传
  /// true，否则那颗按下去永远不动。
  final bool? growOnPress;

  /// 浮现进度（0..1）：null 表示常驻。0 时无界（只剩图标），1 时玻璃壳
  /// 与投影完全成形
  final ValueListenable<double>? reveal;

  /// 与相邻控件的间距（投影画在壳外，所以这里是壳外的呼吸位）
  final EdgeInsets? margin;

  @override
  Widget build(BuildContext context) {
    final d = size ?? FloatingGlassSpec.defaultSize;
    final grow = growOnPress ?? (onTap != null);
    Widget result = _FloatingGlass(
      onTap: onTap,
      tint: tint,
      reveal: reveal,
      dimWhenDisabled: dimWhenDisabled,
      radius: borderRadius ?? BorderRadius.circular(d / 2),
      child: SizedBox(width: d, height: d, child: Center(child: child)),
    );
    if (grow) result = _PressGrow(child: result);
    // 间距留在缩放之外：放大围绕圆盘自身的中心。包在里面的话，带 margin
    // 的那颗会边涨边朝"圆盘+间距"那个偏心盒的中心横移
    if (margin != null) {
      result = Padding(padding: margin!, child: result);
    }
    return result;
  }
}

/// 按住放大、松开回弹。
///
/// 为什么用 [Listener] 而不是 InkWell 的 onTapDown/onTapUp：对话页那颗 ⋮
/// 圆盘根本没有 onTap（点击由外层菜单按钮的 GestureDetector 接管），InkWell
/// 识别不出 tap，按压回调一次都不会触发。[Listener] 只旁观
/// 原始指针事件、不进手势竞技场，既不打断外层的点击，也不抢自带的水波纹。
///
/// 逐帧只有 AnimatedScale 的变换矩阵，壳与投影跟着一起缩放，不重建装饰。
///
/// [Listener] 套在缩放之外是有意的：它是这一层最先的 RenderObject，尺寸与
/// 位置都还是版图里那个未放大的盒。菜单锚点（对话页徽章的 GlobalKey、
/// ⋮ 外层那颗）取的都是它的 `localToGlobal`，所以按住不放的那 150ms 里
/// 量到的仍是原位，不会出现"按下去才弹出的菜单偏了几像素"。
class _PressGrow extends StatefulWidget {
  const _PressGrow({
    this.scale = FloatingGlassSpec.pressScale,
    this.alignment = Alignment.center,
    required this.child,
  });

  /// 按住后的目标倍率
  final double scale;

  /// 缩放围绕哪一点，见 [FloatingGlassPill.growAlignment]
  final Alignment alignment;

  final Widget child;

  @override
  State<_PressGrow> createState() => _PressGrowState();
}

class _PressGrowState extends State<_PressGrow> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (value == _pressed) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      // 旁观而不吞事件：外层同一只手的一次点击照常收到
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _setPressed(true),
      onPointerUp: (_) => _setPressed(false),
      onPointerCancel: (_) => _setPressed(false),
      child: AnimatedScale(
        scale: _pressed ? widget.scale : 1.0,
        duration: FloatingGlassSpec.pressDuration,
        curve: FloatingGlassSpec.pressCurve,
        alignment: widget.alignment,
        child: widget.child,
      ),
    );
  }
}

/// 标题栏悬浮玻璃胶囊（对话页模型徽章一类）。
///
/// 形状、内边距与圆角保持各页原样，只把原来的纯色底换成"玻璃壳 + 着色"，
/// 并补上描边与投影。
class FloatingGlassPill extends StatelessWidget {
  const FloatingGlassPill({
    super.key,
    required this.child,
    this.onTap,
    this.tint,
    this.padding = const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    this.margin,
    this.radius = 12,
    this.reveal,
    this.showTintAtRest = false,
    this.growOnPress,
    this.growAlignment = Alignment.center,
  });

  final Widget child;
  final VoidCallback? onTap;
  final Color? tint;
  final EdgeInsets padding;

  /// 玻璃壳外的间距（投影画在壳外，原来靠 margin 让位的写法照旧有效）
  final EdgeInsets? margin;
  final double radius;

  /// 同 [FloatingGlassButton.growOnPress]：null 时跟随 [onTap]（只展示、
  /// 不可点的胶囊按下去不动）。倍率走 [FloatingGlassSpec.pillPressScale]，
  /// 比圆盘小一档——理由见那条注释。
  final bool? growOnPress;

  /// 放大时围绕哪一点。胶囊靠右排在标题栏里，涨开的那一侧容易压到邻居的
  /// 圆盘，所以这里可以改成 [Alignment.centerRight]——右缘钉住，只朝标题
  /// 方向涨，竖向仍是上下对称的那一下回弹。
  final Alignment growAlignment;

  /// 同 [FloatingGlassButton.reveal]
  final ValueListenable<double>? reveal;

  /// 贴顶（reveal=0）时不彻底无界，仍保留 [tint] 那块纯色底——只是没有
  /// 描边、提亮和投影。给原本就有底色、只靠颜色表意的胶囊用（模型徽章）
  final bool showTintAtRest;

  @override
  Widget build(BuildContext context) {
    final grow = growOnPress ?? (onTap != null);
    Widget result = _FloatingGlass(
      onTap: onTap,
      tint: tint,
      reveal: reveal,
      margin: margin,
      showTintAtRest: showTintAtRest,
      radius: BorderRadius.circular(radius),
      child: Padding(padding: padding, child: child),
    );
    if (grow) {
      result = _PressGrow(
        scale: FloatingGlassSpec.pillPressScale,
        alignment: growAlignment,
        child: result,
      );
    }
    return result;
  }
}

/// 圆钮与胶囊共用的外壳：投影 + 提亮渐变 + 描边 + 水波纹。
class _FloatingGlass extends StatelessWidget {
  const _FloatingGlass({
    required this.child,
    required this.onTap,
    required this.radius,
    required this.tint,
    this.reveal,
    this.dimWhenDisabled = true,
    this.margin,
    this.showTintAtRest = false,
  });

  final Widget child;
  final VoidCallback? onTap;
  final BorderRadius radius;
  final Color? tint;
  final ValueListenable<double>? reveal;
  final bool dimWhenDisabled;
  final EdgeInsets? margin;
  final bool showTintAtRest;

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    final isDark = palette.brightness == Brightness.dark;
    final enabled = onTap != null;
    final dim = !enabled && dimWhenDisabled;

    // 玻璃壳基色 → 叠各页原有着色 → 顶部再铺一层提亮
    final Color base = palette.glassShell.withValues(
      alpha: isDark
          ? FloatingGlassSpec.shellAlphaDark
          : FloatingGlassSpec.shellAlphaLight,
    );
    final Color shellColor =
        tint == null ? base : Color.alphaBlend(tint!, base);
    final Color sheenColor =
        Color.alphaBlend(palette.glassHighlight, shellColor);

    final decoration = BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [sheenColor, shellColor],
        stops: const [0, FloatingGlassSpec.sheenStop],
      ),
      border: Border.all(
        color: palette.glassBorder,
        width: FloatingGlassSpec.borderWidth,
      ),
      borderRadius: radius,
      boxShadow: [
        BoxShadow(
          color: palette.shadow.withValues(
            alpha: isDark
                ? FloatingGlassSpec.shadowAlphaDark
                : FloatingGlassSpec.shadowAlphaLight,
          ),
          blurRadius: FloatingGlassSpec.shadowBlur,
          offset: FloatingGlassSpec.shadowOffset,
        ),
      ],
    );

    // 壳层整层受浮现进度控制。壳本身作为固定实例传进 builder，逐帧只换
    // Opacity 的值，不重建装饰、不重跑投影
    final Widget shell = RepaintBoundary(
      child: Container(decoration: decoration),
    );
    // 贴顶时的"原有底色"：只有着色、没有描边/提亮/投影的纯色芯片。与玻璃
    // 壳按同一条进度做 1-v / v 交叉淡入淡出，两端各自精确等于"改动前"和
    // "下滑后"，也不会像两层同时在场那样在中间档叠出第三种浓度
    final Widget? rest = (showTintAtRest && tint != null)
        ? RepaintBoundary(
            child: Container(
              decoration: BoxDecoration(color: tint, borderRadius: radius),
            ),
          )
        : null;
    final ValueListenable<double>? progress = reveal;

    final List<Widget> layers = <Widget>[];
    if (rest != null && progress != null) {
      layers.add(Positioned.fill(
        child: ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (context, value, _) => Stack(
            children: [
              Positioned.fill(
                child: Opacity(opacity: 1 - value, child: rest),
              ),
              Positioned.fill(
                child: Opacity(opacity: value, child: shell),
              ),
            ],
          ),
        ),
      ));
    } else {
      layers.add(Positioned.fill(
        child: progress == null
            ? shell
            : ValueListenableBuilder<double>(
                valueListenable: progress,
                child: shell,
                builder: (context, value, cachedShell) =>
                    Opacity(opacity: value, child: cachedShell),
              ),
      ));
    }
    // 图标压在壳层之上：浮现过程中图标始终满浓度
    layers.add(child);

    Widget result = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: Stack(
          alignment: Alignment.center,
          children: layers,
        ),
      ),
    );

    if (margin != null) {
      result = Padding(padding: margin!, child: result);
    }
    return AnimatedOpacity(
      duration: FloatingGlassSpec.duration,
      opacity: dim ? FloatingGlassSpec.disabledOpacity : 1,
      child: result,
    );
  }
}
