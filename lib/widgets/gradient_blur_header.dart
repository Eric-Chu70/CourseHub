import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_theme.dart';

/// 「减弱动态效果」全局缓存标志：SharedPreferences 无同步 API，
/// 由 [ReduceMotionFlag.refresh] 异步预热（App 启动及设置页切换时调用），
/// 标题栏等小部件经 [ReduceMotionFlag.value] 同步读取，
/// 避免每个页面重复写加载样板。
class ReduceMotionFlag {
  ReduceMotionFlag._();

  static bool _value = false;

  static bool get value => _value;

  static Future<void> refresh() async {
    final prefs = await SharedPreferences.getInstance();
    _value = prefs.getBool('reduce_motion_enabled') ?? false;
  }
}

/// 渐进模糊标题栏（参考 MIUI 日历/设置的无界标题栏）。
///
/// 三种形态：
/// - **着色器（Impeller）**：单 pass 渐变 blur + 渐变雾化，模糊半径与
///   雾化强度从顶到底单调衰减归零（shaders/gradient_blur.frag）；
/// - **Skia 回退**：分带渐进模糊——窄带 ClipRect 各挂一个 σ 递减的
///   BackdropFilter（底缘 σ→0 即清晰），叠加渐变雾化。分带在 σ 步进
///   大时有可见条带，仅作为无法使用着色器时的兜底；
/// - **reduceMotion**：无模糊，纯 glassShell 雾化渐变，顶部（含状态栏）
///   完全实心不透明，向下渐隐。
///
/// 共同点：底缘模糊/雾化都归零——无分隔线、无硬边（"无界"）。
///
/// 已知取舍：**路由进/退场动画期间，屏幕左缘会出现一条竖直黑带**，动画
/// 结束即消失。这是着色器路径固有的坐标原点错位，不是可以就地修掉的 bug，
/// 排查结论记录如下以免重复踩：着色器用 [FlutterFragCoord] 得到渲染目标
/// （屏幕）坐标，再用 `uv = frag / u_size` 去采背景纹理，静止时两者原点
/// 重合所以成立；转场期间路由被平移并被单独合成，背景纹理原点不再等于
/// 屏幕原点，而 Dart 侧没有任何 uniform 能拿到那个图层偏移，越界的 suv 被
/// clamp 钉到纹理边缘那一列、采到空的透明黑。黑带只依赖 x（浓度曲线只读
/// yTop），所以是贴边窄带而非整块发黑。
/// 试过并**否决**的两种改法：①转场期间不挂 BackdropFilter 只画雾化——
/// 被揭开那一页标题栏底下有内容，能明显看出"模糊没了"；②改走均匀高斯
/// 模糊保底——转场那 300ms 与静止时的渐变糊不一致。用户裁定：一体性优先，
/// 接受黑带（"黑色就黑色"）。
///
/// 注意：不能用 ShaderMask 包 BackdropFilter 做渐变遮罩——ShaderMask
/// 会创建 saveLayer，BackdropFilter 在其中采样到的背景是空的，模糊会
/// 整个失效；ClipRect 只做裁剪不建层，BackdropFilter 可正常采样。
class GradientBlurHeader extends StatefulWidget {
  const GradientBlurHeader({
    super.key,
    required this.topPadding,
    this.barHeight = 56,
    required this.title,
    this.titleRow,
    this.titleLift = 3,
    this.blurDecayBand = 0.40,
    this.blurBottomExtend = 0,
    this.layoutBottomExtend = 0,
    this.blurCurveShift = 0,
    this.reduceMotionFadeStart = 0.42,
    this.reduceMotionTopAlpha = 1.0,
    this.reduceMotionBottomAlpha = 0.95,
    this.reduceMotionBottomMidAlpha,
    this.reduceMotion,
  });

  /// 状态栏高度（标题栏整体从屏幕最顶端画起）
  final double topPadding;

  /// 标题行高度
  final double barHeight;

  final String title;

  /// 标题行上移量（逻辑px）：默认 3——配合 blurCurveShift 下移 6 的
  /// 曲线，标题相对曲线回撤 3px，落在底缘缓坡更从容的位置（原 6 曾
  /// 贴满浓度平台）；课表页标题行是双行表头，传 0 贴回底缘
  final double titleLift;

  /// 模糊衰减带高度占比（0..1）：底缘向上到此比例处爬升到满模糊。
  /// 默认 0.40 适配 56 高的单行标题带；课表页双行带更高，需收窄
  /// （0.18）才能让雾面顶到网格线头，否则带底露出一截清晰壁纸
  final double blurDecayBand;

  /// 模糊区向下延伸量（逻辑px）：标题栏布局高度不变、元素不动，仅把
  /// 模糊/雾化的归零点下移到「标题栏底缘 + 此值」处——课表页用它把
  /// 模糊起始线下探顶到网格线顶端，同时拉长衰减带放缓梯度
  final double blurBottomExtend;

  /// 标题栏布局增高量（逻辑px，默认 0）：标题栏本体向下加高此距离，
  /// 页面内容起始位置随之下移——底部坡面因此多出这段渐变空间（与
  /// blurBottomExtend 只多画不动布局不同，这是真实布局变化）。四页
  /// 传 6，页面内容区顶部偏移需同步 +6；课表页不动布局，传 0
  final double layoutBottomExtend;

  /// 雾面曲线整体下移量（逻辑px，默认 0）：与 blurBottomExtend 不同，
  /// 绘制区不越出标题栏底缘——同一高度压上原来上移此距离处的浓度
  /// （标题可读性↑），最后一段收口回零，绝不糊到标题栏下方的真实
  /// 内容。对话/设置/导入/待办四页传 6
  final double blurCurveShift;

  /// 减弱动态模式下坡面拐点的高度占比（0..1）：最顶缘 1.0 起连续
  /// 递减，过此拐点后底部渐隐加速、底缘归零。越小底部坡面越长越缓
  /// （默认 0.42 四页）；课表页双行表头贴底，传 0.50 坡短而陡
  final double reduceMotionFadeStart;

  /// 减弱动态模式下顶缘最大浓度（0..1）：默认 1.0（顶缘全实心，
  /// 区段内降 0.02 到 s 拐点）；课表页顶栏单独设坡面策略传 0.97，
  /// 最高只到 0.97 不到 1
  final double reduceMotionTopAlpha;

  /// 减弱动态模式底部 25% 区段的顶点浓度（默认 0.95 四页；课表页
  /// 沿用出厂那一版传 0.85）
  final double reduceMotionBottomAlpha;

  /// 底部 25% 区段是否在 12.5% 处经过一个中间拐点（课表页传 0.5，
  /// 即 0→0.5→bottomAlpha 两段线性）；null 时 0→bottomAlpha 单段线性
  final double? reduceMotionBottomMidAlpha;

  /// 自定义标题行内容（如带操作按钮的标题栏）；null 时居中显示 [title]。
  /// 高度须与 [barHeight] 一致。
  final Widget? titleRow;

  /// 「减弱动态效果」开启时走无模糊纯渐变遮罩；
  /// null 时同步读取 [ReduceMotionFlag.value]
  final bool? reduceMotion;

  @override
  State<GradientBlurHeader> createState() => _GradientBlurHeaderState();
}

class _GradientBlurHeaderState extends State<GradientBlurHeader> {
  // 是否启用着色器路径。若真机上着色器仍表现异常（不模糊/打散），
  // 置 false 一秒切回「整块均匀模糊 + 渐变压暗遮罩」的保底形态
  static const bool _useShader = true;

  // 着色器路径最大模糊半径（逻辑px，传 uniform 前乘 DPR）。
  // 分布：顶部 60% 维持此最高模糊，底部 40% 由 0 平滑递增至最高
  static const double _maxRadiusPx = 20;

  // 均匀模糊保底路径的 sigma（逻辑px）
  static const double _uniformBlurSigma = 14;

  // 渐变遮罩顶部最大强度：浅色 70% / 深色 55%。遮罩与模糊共用
  // teBlur 曲线（顶部满浓度，随模糊坡同步渐弱到底缘归零）
  static const double _maxScrimLight = 0.70;
  static const double _maxScrimDark = 0.55;

  // 状态栏区（标题栏上半段）额外遮罩最大强度：自中点向顶部线性加深，
  // 保证状态栏图标可读（浅色=白底配深色图标 / 深色=暗底配浅色图标）
  static const double _statusScrimLight = 0.45;
  static const double _statusScrimDark = 0.50;

  // Skia 分带回退的最大 sigma（逻辑px）
  static const double _fallbackSigma = 20;

  static ui.FragmentProgram? _cachedProgram;
  static Future<ui.FragmentProgram>? _programLoader;

  ui.FragmentProgram? _program;

  @override
  void initState() {
    super.initState();
    _loadProgram();
  }

  Future<void> _loadProgram() async {
    if (!ui.ImageFilter.isShaderFilterSupported) return; // Skia：直接走分带
    try {
      _cachedProgram ??= await (_programLoader ??=
          ui.FragmentProgram.fromAsset('shaders/gradient_blur.frag'));
      if (mounted) {
        setState(() => _program = _cachedProgram);
      }
    } catch (_) {
      // 着色器资产缺失/编译失败：静默走分带回退
    }
  }

  @override
  Widget build(BuildContext context) {
    final height = widget.topPadding + widget.barHeight;
    // 布局增高量：标题栏本体向下加高（页面内容起始位置随之下移），
    // 底部坡面由此多出这段渐变空间
    final layoutHeight = height + widget.layoutBottomExtend;
    // 模糊/雾化实际绘制高度：布局高再叠 extend 下探
    final blurHeight = layoutHeight + widget.blurBottomExtend;
    // 标题仍钉在原布局底缘上方 titleLift 处 → 相对模糊区底缘为
    // layoutExtend + extend + lift
    final titleBottom =
        widget.titleLift + widget.blurBottomExtend + widget.layoutBottomExtend;
    final dark = AppColors.isDark(context);
    // 雾化/磨砂基色：浅色=白（增白磨砂），深色=近黑（压暗磨砂）
    final Color scrim = AppColors.of(context).glassShell;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;

        // 标题行固定钉在标题栏底部（状态栏 padding 之下）
        final Widget titleRow = SizedBox(
          height: widget.barHeight,
          child: widget.titleRow ??
              Center(
                child: Text(
                  widget.title,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: AppColors.of(context).textPrimary,
                  ),
                ),
              ),
        );

        Widget content;
        if (widget.reduceMotion ?? ReduceMotionFlag.value) {
          // 减弱动态：无模糊，纯雾化渐变。底部 25% 的形状分页可配
          // （reduceMotionBottomAlpha / reduceMotionBottomMidAlpha），
          // 25% 线以上一律线性过渡到 s 拐点 topAlpha-0.02，再到顶缘
          // topAlpha。底缘必须零导数收尾（斜率折角=可见分界线）；
          // 但短段内串联多条 smoothstep 会把变化挤成"杠"（2026-09-26
          // 实测两条杠），所以整段只用一条。
          // blurCurveShift 只属于非减弱（模糊）路径；减弱路径不下移
          // ——四页带矮，曲线下移会把高浓度顶到贴底，收尾必然成崖。
          // 整条曲线按 1/48 密度采样成 stops（粗采样会把收尾在两个
          // 采样点间退化成直线崖）。
          final s = widget.reduceMotionFadeStart;
          final topAlpha = widget.reduceMotionTopAlpha;
          final bottomAlpha = widget.reduceMotionBottomAlpha;
          final midAlpha = widget.reduceMotionBottomMidAlpha;
          final ramp = 1.0 - s;
          double baseA(double t) {
            if (t <= 0) return 0;
            // 底部 25%：四页 0 → bottomAlpha 单段线性；课表页保持
            // 出厂那版 0 → 0.5（12.5% 处）→ bottomAlpha 两段线性。
            // 一律线性：smoothstep 会把变化集中到段中点，每段各渲染
            // 成一条"杠"（2026-09-26 实测两条杠）。
            if (t <= 0.25) {
              final u = t * 4.0;
              if (midAlpha == null) {
                // 四页：整段一条 smoothstep。线性收尾会在带底留下
                // 「每像素 1 级 → 0」的斜率折角，那就是一条可见分界
                // 线（2026-09-26 量过像素确认）；这里让坡以零导数贴底。
                return bottomAlpha * u * u * (3 - 2 * u);
              }
              // 课表页（出厂版）：0 → mid（12.5%）→ bottomAlpha 两段线性
              return u <= 0.5
                  ? midAlpha * u * 2.0
                  : midAlpha + (bottomAlpha - midAlpha) * (u * 2.0 - 1.0);
            }
            // 25% 线 → s 拐点：bottomAlpha 线性过渡到 topAlpha-0.02
            if (t <= ramp) {
              return bottomAlpha +
                  (topAlpha - 0.02 - bottomAlpha) * (t - 0.25) / (ramp - 0.25);
            }
            if (t < 1) return topAlpha - 0.02 + 0.02 * (t - ramp) / (1 - ramp);
            return topAlpha;
          }

          const n = 48;
          final gradStops = <double>[];
          final gradColors = <Color>[];
          for (var i = 0; i <= n; i++) {
            final pos = i / n;
            gradStops.add(pos);
            gradColors.add(
              scrim.withValues(
                alpha: baseA(1.0 - pos).clamp(0.0, 1.0),
              ),
            );
          }
          content = SizedBox(
            height: blurHeight,
            width: width,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: gradColors,
                  stops: gradStops,
                ),
              ),
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: EdgeInsets.only(bottom: titleBottom),
                  child: titleRow,
                ),
              ),
            ),
          );
        } else if (_useShader &&
            _program != null &&
            ui.ImageFilter.isShaderFilterSupported) {
          // Impeller：单 pass 渐变 blur（36 点黄金角螺旋 + 每像素随机
          // 旋转抖动）+ 渐进压暗。FragCoord 是物理像素坐标（实测：原点
          // 在屏幕顶部），uniform 尺寸类参数必须乘 DPR；ClipRect 必须
          // 保留——BackdropFilter 的作用范围是整个背景层，不裁剪会把
          // 整页内容都模糊掉
          final dpr = MediaQuery.devicePixelRatioOf(context);
          final shader = _program!.fragmentShader()
            ..setFloat(0, width * dpr)
            ..setFloat(1, blurHeight * dpr)
            ..setFloat(2, blurHeight * dpr) // u_header_h：归零点=下探后的模糊底缘
            ..setFloat(3, _maxRadiusPx * dpr)
            ..setFloat(4, dark ? _maxScrimDark : _maxScrimLight)
            ..setFloat(5, dark ? _statusScrimDark : _statusScrimLight)
            ..setFloat(6, scrim.r)
            ..setFloat(7, scrim.g)
            ..setFloat(8, scrim.b)
            ..setFloat(9, 1.0)
            ..setFloat(10, widget.blurDecayBand)
            ..setFloat(11, widget.blurCurveShift * dpr);
          content = ClipRect(
            child: BackdropFilter(
              filter: ui.ImageFilter.shader(shader),
              child: SizedBox(
                height: blurHeight,
                width: width,
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: EdgeInsets.only(bottom: titleBottom),
                    child: titleRow,
                  ),
                ),
              ),
            ),
          );
        } else if (!_useShader || !ui.ImageFilter.isShaderFilterSupported) {
          // 均匀模糊保底（着色器被禁用 / 不支持着色器的环境，如 Windows
          // 桌面 Skia）：整块均匀高斯模糊 + 渐进压暗遮罩——无渐变模糊，
          // 但观感是「正常模糊」
          content = ClipRect(
            child: SizedBox(
              height: blurHeight,
              width: width,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: BackdropFilter(
                      filter: ui.ImageFilter.blur(
                          sigmaX: _uniformBlurSigma, sigmaY: _uniformBlurSigma),
                      child: const SizedBox.expand(),
                    ),
                  ),
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: _scrimCurveGradient(
                            scrim, dark ? _maxScrimDark : _maxScrimLight),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: titleBottom,
                    child: titleRow,
                  ),
                ],
              ),
            ),
          );
        } else {
          // Skia 回退：分带渐进模糊 + 渐变雾化。
          // 各带 sigma 自顶部向底缘 smoothstep 递减至 0（底缘完全清晰）
          content = ClipRect(
            child: SizedBox(
              height: blurHeight,
              width: width,
              child: Stack(
                children: [
                  ..._buildProgressiveBlurBands(width, blurHeight),
                  Positioned.fill(
                    // 渐变遮罩（与着色器路径一致）：与模糊共用 teBlur
                    // 曲线，顶部满浓度随模糊坡同步渐弱到底缘归零
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: _scrimCurveGradient(
                            scrim, dark ? _maxScrimDark : _maxScrimLight),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: titleBottom,
                    child: titleRow,
                  ),
                ],
              ),
            ),
          );
        }

        // 布局高度 = 原高度 + layoutBottomExtend（标题栏本体加高，
        // 内容区随之下移）；extend>0 时雾面再经 OverflowBox 向下多画
        return SizedBox(
          height: layoutHeight,
          width: width,
          child: OverflowBox(
            alignment: Alignment.topCenter,
            minHeight: layoutHeight,
            maxHeight: blurHeight,
            child: content,
          ),
        );
      },
    );
  }

  /// 「遮罩与模糊共用曲线」渐变（对齐 shader 的 u_max_scrim × teBlur）：
  /// 顶缘到模糊衰减带顶（1-band 处）满浓度，随后按 smoothstep 采样
  /// 缓降，底缘零导数归零——模糊渐强处遮罩同步渐强
  LinearGradient _scrimCurveGradient(Color scrim, double maxA) {
    double ss(double t) => t * t * (3 - 2 * t);
    final start = (1.0 - widget.blurDecayBand).clamp(0.0, 0.9);
    final span = 1.0 - start;
    return LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        scrim.withValues(alpha: maxA),
        scrim.withValues(alpha: maxA),
        for (final f in const [0.2, 0.4, 0.6, 0.8])
          scrim.withValues(alpha: maxA * (1 - ss(f))),
        scrim.withValues(alpha: 0.0),
      ],
      stops: [
        0.0,
        start,
        for (final f in const [0.2, 0.4, 0.6, 0.8]) start + span * f,
        1.0,
      ],
    );
  }

  /// 分带渐进模糊：约 4px 一条窄带，sigma 按「顶部 60% 平台 + 底部
  /// 40% smoothstep 递增至 0（底缘完全清晰，无底噪）」分布（与着色器
  /// 模糊曲线一致）；各带向下搭接 1px 防 ClipRect 取整造成的发丝缝
  List<Widget> _buildProgressiveBlurBands(double width, double height) {
    final bands = <Widget>[];
    const bandH = 4.0;
    final count = (height / bandH).ceil();
    final shiftFrac = (widget.blurCurveShift / height).clamp(0.0, 0.2);
    for (var i = 0; i < count; i++) {
      final top = i * bandH;
      final centerT = 1 - (top + bandH / 2) / height;
      // 曲线整体下移：同高度取上移 shiftFrac 处的浓度；底缘
      // shiftFrac 段再乘 smoothstep 收口因子精确归零（与着色器一致）
      final t = (centerT + shiftFrac).clamp(0.0, 1.0);
      final tt = (t / widget.blurDecayBand - 1).clamp(0.0, 1.0);
      var smooth = tt * tt * (3 - 2 * tt);
      if (shiftFrac > 0) {
        final x = (centerT / shiftFrac).clamp(0.0, 1.0);
        smooth *= x * x * (3 - 2 * x);
      }
      final sigma = _fallbackSigma * smooth;
      if (sigma < 0.1) continue; // 底缘近零带：不挂滤镜，等价于清晰
      bands.add(
        Positioned(
          left: 0,
          right: 0,
          top: top,
          height: bandH + 1.0,
          child: ClipRect(
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
    }
    return bands;
  }
}
