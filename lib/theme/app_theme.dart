import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 品牌主色（深浅两套主题共用）
const Color kAppSeedColor = Color(0xFF4A90E2);

/// 语义色令牌：深浅两套调色板。UI 通过 `AppColors.of(context)` 取用，
/// 禁止再新增硬编码 Colors.white / Colors.black / Colors.grey.shade*。
///
/// 深色玻璃拟态翻译规则（相对浅色）：
/// - 白色半透明壳 → 近黑半透明壳（glassShell 色相平移，alpha 不变）；
/// - 提亮层（模糊前垫白）→ 极淡白（防止深色磨砂发闷）；
/// - 白描边 → 低透明白细描边；
/// - 文字/图标反色；blur 强度、圆角、布局全部不动。
class AppPalette {
  final Brightness brightness;

  /// 页面/脚手架底色
  final Color scaffold;

  /// 卡片、分组实底
  final Color surface;

  /// 次级底：输入框填充、内嵌条、关闭按钮等
  final Color surfaceAlt;

  /// 轻覆盖层（悬停高亮、浅色遮罩条）
  final Color overlaySoft;

  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;

  /// 弱描边/分隔线
  final Color borderWeak;

  /// 玻璃壳基色（配合 alpha 使用：浅色=白，深色=近黑）
  final Color glassShell;

  /// 模糊前提亮层基色
  final Color glassHighlight;

  /// 玻璃壳描边
  final Color glassBorder;

  /// 壳外阴影基色
  final Color shadow;

  /// 内容层面板：叠在壳/页面底上的白色半透明矩形（输入框底、内嵌条、
  /// 禁用块等）。深色下压成低 alpha 的白，保持"比底亮一档"的层次
  /// （直接沿用浅色 alpha 会在深玻璃上发灰刺眼）。
  Color panel(double alpha) => brightness == Brightness.dark
      ? Colors.white.withValues(alpha: (alpha * 0.15).clamp(0.03, 0.10))
      : Colors.white.withValues(alpha: alpha);

  /// 圆形复选框等控件的未选中底色
  Color get chipIdle => brightness == Brightness.dark
      ? Colors.white.withValues(alpha: 0.12)
      : Colors.black.withValues(alpha: 0.10);

  const AppPalette({
    required this.brightness,
    required this.scaffold,
    required this.surface,
    required this.surfaceAlt,
    required this.overlaySoft,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.borderWeak,
    required this.glassShell,
    required this.glassHighlight,
    required this.glassBorder,
    required this.shadow,
  });

  static const AppPalette light = AppPalette(
    brightness: Brightness.light,
    scaffold: Colors.white,
    surface: Colors.white,
    surfaceAlt: Color(0xFFF3F4F6),
    overlaySoft: Color(0x0A000000),
    textPrimary: Color(0xFF1A1A2E),
    textSecondary: Color(0xFF757575),
    textTertiary: Color(0xFF9E9E9E),
    borderWeak: Color(0xFFEEEEEE),
    glassShell: Colors.white,
    glassHighlight: Color(0x66FFFFFF),
    glassBorder: Color(0x99FFFFFF),
    shadow: Colors.black,
  );

  static const AppPalette dark = AppPalette(
    brightness: Brightness.dark,
    scaffold: Color(0xFF111114),
    surface: Color(0xFF1B1B1F),
    surfaceAlt: Color(0xFF26262B),
    overlaySoft: Color(0x0FFFFFFF),
    textPrimary: Color(0xFFECECF1),
    textSecondary: Color(0xFFA9A9B2),
    textTertiary: Color(0xFF85858E),
    borderWeak: Color(0x1AFFFFFF),
    glassShell: Color(0xFF101014),
    glassHighlight: Color(0x0DFFFFFF),
    glassBorder: Color(0x1AFFFFFF),
    shadow: Colors.black,
  );
}

/// 语义色调取入口：`AppColors.of(context).textPrimary` 等。
/// 跟随 MaterialApp themeMode 注入的局部 Theme 自动切换深浅。
class AppColors {
  AppColors._();

  static AppPalette of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? AppPalette.dark
          : AppPalette.light;

  static AppPalette ofBrightness(Brightness brightness) =>
      brightness == Brightness.dark ? AppPalette.dark : AppPalette.light;

  static bool isDark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;

  /// 彩色提示横幅（蓝/橙/红…）：底色。浅色=粉彩 shade50，
  /// 深色=基色低透明（避免高亮粉彩色块在深底上刺眼）。
  static Color bannerBg(BuildContext context, MaterialColor base) =>
      isDark(context)
          ? base.withValues(alpha: 0.12)
          : base.shade50;

  /// 横幅描边
  static Color bannerBorder(BuildContext context, MaterialColor base) =>
      isDark(context)
          ? base.withValues(alpha: 0.35)
          : base.shade100;

  /// 横幅内图标/文字。浅色=深色 shade700 保证对比，深色=浅色 shade300。
  static Color bannerText(BuildContext context, MaterialColor base) =>
      isDark(context)
          ? base.shade300
          : base.shade700;

  /// 横幅内小图标底芯片
  static Color bannerChip(BuildContext context, MaterialColor base) =>
      isDark(context)
          ? base.withValues(alpha: 0.20)
          : base.shade100;
}

/// MaterialApp 的深浅两套 ThemeData。
/// 未迁移到语义令牌的旧屏在 home_screen 被局部锁定浅色 Theme，
/// 因此这里可以放心让深色套整体翻转 Material 组件默认样式。
ThemeData buildAppTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  return ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: kAppSeedColor,
      brightness: brightness,
    ),
    useMaterial3: true,
    fontFamily: 'Microsoft YaHei',
    scaffoldBackgroundColor:
        isDark ? AppPalette.dark.scaffold : AppPalette.light.scaffold,
    // 全局光标颜色兜底：统一封装 widgets/app_text_field.dart 已按输入框
    // 设置主题蓝光标，此处覆盖未来未经封装的输入组件（选中高亮/拖拽手柄
    // 不受影响，仍走主题色）
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: kAppSeedColor,
    ),
    appBarTheme: AppBarTheme(
      centerTitle: true,
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor:
          isDark ? AppPalette.dark.scaffold : AppPalette.light.scaffold,
      foregroundColor:
          isDark ? AppPalette.dark.textPrimary : AppPalette.light.textPrimary,
      systemOverlayStyle: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness:
            isDark ? Brightness.light : Brightness.dark,
        statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
        systemStatusBarContrastEnforced: true,
      ),
    ),
    cardTheme: const CardThemeData(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      filled: true,
      fillColor: isDark ? const Color(0xFF232328) : Colors.grey[50],
    ),
  );
}
