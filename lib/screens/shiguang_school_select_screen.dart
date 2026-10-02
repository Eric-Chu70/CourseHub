import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/shiguang/shiguang_index_service.dart';
import '../services/shiguang/shiguang_models.dart';
import '../widgets/blur_selection_menu.dart';
import '../widgets/floating_glass_button.dart';
import '../widgets/glass_dialog.dart';
import '../widgets/fading_edge_list.dart';
import '../widgets/gradient_blur_header.dart';
import '../widgets/toast_notification.dart';
import 'shiguang_web_import_screen.dart';
import '../widgets/app_text_field.dart';

/// 教务系统导入 - 学校选择页。
///
/// 数据来自 shiguang_warehouse 仓库索引：顶部为通用教务系统（正方/超星/
/// 青果/URP）卡片 + 最近使用（横向滑动一行，长按可编辑删除），下方为按
/// 首字母分组的学校列表（懒加载 + 搜索过滤 + 右侧 A-Z 导航条）。
class ShiguangSchoolSelectScreen extends StatefulWidget {
  const ShiguangSchoolSelectScreen({super.key});

  @override
  State<ShiguangSchoolSelectScreen> createState() =>
      _ShiguangSchoolSelectScreenState();
}

/// 扁平化列表项：分组头或学校卡（供懒加载 builder 使用）。
/// 同一个首字母的学校：一个字母头 + 一张合并卡（设置页同款）。
class _LetterGroup {
  final String letter;
  final List<ShiguangSchool> schools;

  const _LetterGroup(this.letter, this.schools);
}

class _ShiguangSchoolSelectScreenState extends State<ShiguangSchoolSelectScreen>
    with TickerProviderStateMixin {
  List<ShiguangSchool> _schools = [];
  List<ShiguangSchool> _recentSchools = [];
  bool _loading = true;
  bool _refreshing = false;
  bool _stale = false; // 数据来自过期缓存（网络失败回退）
  bool _editingRecent = false; // 最近使用编辑模式（长按进入）
  String? _error;
  String _query = '';
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final ScrollController _scrollController = ScrollController();

  /// 标题栏悬浮件浮现进度：列表贴顶时为 0（返回/刷新保持无界图标），
  /// 内容滚进标题栏后浮出玻璃壳与投影。目标值由滚动偏移给出，实际浓度
  /// 走固定时长补间，所以甩动和回弹都不会让壳闪一下消失。
  late final HeaderReveal _headerReveal =
      HeaderReveal(_scrollController, vsync: this);

  /// 刷新按钮旋转动画：点按后原 refresh 图标自转（替代进度圈）。
  late final AnimationController _refreshSpinController;

  // 最近使用 chip 删除动画（参数对齐切换课表页删除动画）：
  // 阶段一 vanish——原位模糊增大 + 向内缩小 + 淡出（220ms easeInCubic）；
  // 阶段二 collapse——占位宽度收起、后续 chip 平滑左移补位
  //（200ms easeOutCubic，与 vanish 收尾速度衔接连续），播完才真正删数据。
  AnimationController? _chipVanishCtrl;
  CurvedAnimation? _chipVanishCurved;
  String? _vanishingChipId;
  AnimationController? _chipCollapseCtrl;
  CurvedAnimation? _chipCollapseCurved;
  String? _collapsingChipId;

  /// 减弱动态效果：删除动画跳过模糊（保留缩小 + 淡出 + 占位收起），
  /// 与导入页锁图标 / 玻璃弹窗等的分级规则一致。
  bool _reduceMotion = false;

  /// 固定区总高 = 状态栏 + 标题栏(56+6) + 悬浮搜索条(8+50+12)。
  /// A-Z 跳转目标与滚动高亮的"视口顶端"都以它为基准——搜索条现在是固定
  /// 的，列表内容真正开始可见的位置比标题栏底还要再低一截。
  double _pinnedTopHeight = 0;

  /// 前置区域（搜索框/通用教务/最近使用/标题）的实际高度，用于 A-Z 跳转。
  final GlobalKey _leadingKey = GlobalKey();
  double _leadingHeight = 0;

  // A-Z 导航条状态：列表滚动时淡入，2 秒无滑动自动淡出（拖动字母期间不隐藏）。
  bool _navVisible = false;
  bool _navDragging = false;
  // 字母跳转动画进行中（此间滚动回写暂停，手指选择优先）。
  bool _navJumping = false;
  // 连续跳转序号：防止旧 animateTo 的完成回调误清 _navJumping。
  int _navJumpSeq = 0;
  Timer? _navHideTimer;
  String? _activeNavLetter;

  /// 扁平列表分组头固定行高（导航跳转 offset 按此精确计算）。
  static const double _kSectionHeaderHeight = 44;

  /// 合并卡内单行高度。原来每所学校一张独立卡（卡 64 + 底部间隙 8 = 72），
  /// 同字母合并成一张卡后既没有间隙、也没有左侧图标底座，收到 56。
  /// offset 计算完全靠这个常量，改行高必须同时改这里。
  static const double _kSchoolRowHeight = 56;

  /// 合并卡内分隔线左缩进：与行内文字左缘对齐（卡片内 padding 14）
  static const double _kRowDividerIndent = 14;

  /// 卡内行分隔线占位高度。Divider 是**占布局**的实体行，不是叠绘：
  /// 一张 N 行的合并卡实际高 = N×56 + (N-1)×1。offset 必须一起算，
  /// 否则每组少算 (N-1)px，逐组累积——表现就是"只有 A 跳得准，越往下
  /// 偏得越多"。
  static const double _kRowDividerHeight = 1;

  /// 本页强调色统一走主题蓝（原为教务紫 0xFF4A90E2）
  static const Color _kAccent = kAppSeedColor;
  static const double _kNavItemHeight = 16;

  // ---------- 悬浮搜索条（观感与几何对齐 WebView 页底部网址栏） ----------

  /// 圆角照搬网址栏完全形态的 25。条高固定 50，25 才是货真价实的两端
  /// 半圆（stadium）；若让高度由 InputDecorator 自己撑（约 48），半径会
  /// 被裁到 24，两处观感就对不齐了
  static const double _kSearchBarRadius = 25;
  static const double _kSearchBarHeight = 50;

  /// 标题栏底 → 搜索条顶。0：胶囊自带 1.5 描边和外投影，视觉呼吸位已经
  /// 够，再留间距整条就显得往下掉
  static const double _kSearchBarGapAbove = 0;

  /// 搜索条底 → 列表内容顶
  static const double _kSearchBarGapBelow = 12;

  /// 左右内缩：沿用前置区原来 fromLTRB(16, …) 的 16，位置不横移
  static const double _kSearchBarSideInset = 16;

  /// 毛玻璃 sigma，与 WebView 页底部网址栏同档 15（减弱动态效果时不模糊）；
  /// 两处要调一起调
  static const double _kSearchBarBlurSigma = 15;

  /// 固定区中标题栏以下占的高度（8 + 50 + 12 = 70）
  static const double _kPinnedBlockBelowHeader = _kSearchBarGapAbove +
      _kSearchBarHeight + _kSearchBarGapBelow;

  @override
  void initState() {
    super.initState();
    _refreshSpinController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _loadReduceMotion();
    _hydrateFromCacheThenAutoRefresh();
  }

  /// 进入页面的加载策略：
  /// 1) 有缓存就立刻把懒加载列表铺出来（不再整屏 loading 挡住），
  ///    同时按冷却窗口决定是否在后台补一次自动刷新；
  /// 2) 一小时内已经拉过一次（自动或手动都算）就不再自动打网络；
  /// 3) 完全没有缓存（首次使用）才走原来的整屏加载；
  /// 4) 右上角手动刷新按钮永远可用，不受冷却影响。
  Future<void> _hydrateFromCacheThenAutoRefresh() async {
    final cached = await ShiguangIndexService.peekCachedIndex();
    if (!mounted) return;
    if (cached == null) {
      await _loadIndex();
      return;
    }
    final recent = await ShiguangIndexService.getRecentSchools();
    if (!mounted) return;
    setState(() {
      _schools = cached.schools;
      _recentSchools = recent;
      _stale = cached.stale;
      _loading = false;
      _error = null;
    });
    if (cached.withinAutoRefreshCooldown) return;
    if (!mounted) return;
    _loadIndex(forceRefresh: true, auto: true);
  }

  Future<void> _loadReduceMotion() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final reduce = prefs.getBool('reduce_motion_enabled') ?? false;
    if (reduce == _reduceMotion) return;
    setState(() => _reduceMotion = reduce);
  }

  @override
  void dispose() {
    _clearInputFocus();
    _searchController.dispose();
    _searchFocus.dispose();
    _headerReveal.dispose();
    _scrollController.dispose();
    _navHideTimer?.cancel();
    _refreshSpinController.dispose();
    _chipVanishCurved?.dispose();
    _chipVanishCtrl?.dispose();
    _chipCollapseCurved?.dispose();
    _chipCollapseCtrl?.dispose();
    super.dispose();
  }

  /// 清除搜索框焦点并收起键盘（参考对话页 clearInputFocus 做法）：
  /// 防止返回/切页后焦点残留、键盘自动弹出。
  void _clearInputFocus() {
    _searchFocus.unfocus(disposition: UnfocusDisposition.scope);
    SystemChannels.textInput.invokeMethod('TextInput.hide');
  }

  /// [forceRefresh] 跳过缓存读、直取网络；[auto] 表示这次是进页面时的
  /// 自动刷新：列表已经铺在屏上，失败时不能用错误页把列表整块换掉，
  /// 只在顶部挂失效提示。
  Future<void> _loadIndex({bool forceRefresh = false, bool auto = false}) async {
    if (forceRefresh) {
      _refreshSpinController.repeat();
      setState(() => _refreshing = true);
    } else {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final (schools, stale) =
          await ShiguangIndexService.getSchoolIndex(forceRefresh: forceRefresh);
      final recent = await ShiguangIndexService.getRecentSchools();
      if (!mounted) return;
      _refreshSpinController
        ..stop()
        ..reset();
      setState(() {
        _schools = schools;
        _recentSchools = recent;
        _stale = stale;
        _loading = false;
        _refreshing = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      _refreshSpinController
        ..stop()
        ..reset();
      if (auto && _schools.isNotEmpty) {
        // 已有列表可看：静默失败，收起刷新动效并提示数据可能过期
        setState(() {
          _refreshing = false;
          _stale = true;
        });
        return;
      }
      setState(() {
        _loading = false;
        _refreshing = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  // ---------- 数据视图 ----------

  List<ShiguangSchool> get _genericSchools =>
      _schools.where((s) => s.isGeneric).toList();

  List<ShiguangSchool> get _normalSchools =>
      _schools.where((s) => !s.isGeneric).toList();

  Map<String, List<ShiguangSchool>> get _groupedSchools {
    final filtered = _normalSchools.where((s) {
      if (_query.isEmpty) return true;
      final q = _query.toLowerCase();
      return s.name.toLowerCase().contains(q) ||
          s.id.toLowerCase().contains(q) ||
          s.initial.toLowerCase().contains(q);
    }).toList();

    final groups = <String, List<ShiguangSchool>>{};
    for (final school in filtered) {
      final key = school.initial.isEmpty ? '#' : school.initial;
      groups.putIfAbsent(key, () => []).add(school);
    }
    final keys = groups.keys.toList()
      ..sort((a, b) {
        // 字母在前，# 及其他符号在后。
        final aIsLetter = RegExp(r'^[A-Z]$').hasMatch(a);
        final bIsLetter = RegExp(r'^[A-Z]$').hasMatch(b);
        if (aIsLetter && !bIsLetter) return -1;
        if (!aIsLetter && bIsLetter) return 1;
        return a.compareTo(b);
      });
    return {for (final k in keys) k: groups[k]!};
  }

  /// 按首字母成组（组内即一张合并卡），供懒加载 builder 与 offset 计算共用。
  List<_LetterGroup> _buildGroups(Map<String, List<ShiguangSchool>> groups) {
    return [
      for (final entry in groups.entries)
        _LetterGroup(entry.key, entry.value),
    ];
  }

  /// 计算每个字母分组头在滚动坐标系中的偏移（固定区高度 + 前置区域实测
  /// 高度 + 行高累加）。[pinnedTop] 就是列表内容真正开始排布的文档坐标，
  /// 与 SliverPadding 的顶部偏移同一个表达式，两处必须同步。
  ///
  /// 同字母合并成一张卡后，一个组的占位 = 字母头 44 + N × 行高 56
  /// + (N-1) × 分隔线 1，组内不再有 8px 间隙，所以累加式与旧的
  /// "每项独立卡 72" 完全不同。分隔线那一项容易漏，见 [_kRowDividerHeight]。
  Map<String, double> _computeLetterOffsets(
      List<_LetterGroup> groups, double pinnedTop) {
    if (_leadingHeight <= 0) return {};
    final offsets = <String, double>{};
    double y = pinnedTop + _leadingHeight;
    for (final group in groups) {
      offsets[group.letter] = y;
      final n = group.schools.length;
      y += _kSectionHeaderHeight +
          n * _kSchoolRowHeight +
          (n > 1 ? (n - 1) * _kRowDividerHeight : 0);
    }
    return offsets;
  }

  // ---------- 交互 ----------

  Future<void> _onSchoolTap(ShiguangSchool school) async {
    // 适配器列表未缓存时需网络拉取（可达数秒），期间页面零反馈，
    // 观感像「没点到」：延迟 300ms 出顶部蓝色提示（缓存命中时
    // 无感不闪），拉取结束后立即收起。
    var toastShown = false;
    final toastTimer = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      toastShown = true;
      toastNotification.show(
        context,
        '正在获取 ${school.name} 适配信息…',
        type: ToastType.info,
        duration: const Duration(seconds: 15),
      );
    });
    try {
      final adapters = await ShiguangIndexService.getAdapters(school);
      toastTimer.cancel();
      if (toastShown) toastNotification.dismiss();
      if (!mounted) return;

      await ShiguangIndexService.saveRecentSchool(school);
      if (!mounted) return;
      // 最近使用栏即时同步（内存态跟随持久化更新），无需重进页面。
      if (!school.isGeneric) {
        setState(() {
          _recentSchools.removeWhere((s) => s.id == school.id);
          _recentSchools.insert(0, school);
          if (_recentSchools.length > 5) _recentSchools.removeLast();
        });
      }

      if (adapters.length == 1) {
        _openWebView(school, adapters.first);
        return;
      }

      await _showAdapterPicker(school, adapters);
    } catch (e) {
      toastTimer.cancel();
      if (toastShown) toastNotification.dismiss();
      if (mounted) {
        toastNotification.show(
          context,
          e.toString().replaceFirst('Exception: ', ''),
          type: ToastType.error,
        );
      }
    }
  }

  Future<void> _removeRecentSchool(ShiguangSchool school) async {
    // 动画进行中忽略重复删除（控制器单轨，避免状态竞争）。
    if (_vanishingChipId != null || _collapsingChipId != null) return;
    HapticFeedback.selectionClick();
    // 阶段一 vanish：原位模糊增大 + 向内缩小 + 淡出（220ms easeInCubic）。
    _vanishingChipId = school.id;
    _chipVanishCurved?.dispose();
    _chipVanishCtrl?.dispose();
    _chipVanishCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _chipVanishCurved = CurvedAnimation(
      parent: _chipVanishCtrl!,
      curve: Curves.easeInCubic,
    );
    setState(() {});
    await _chipVanishCtrl!.forward(from: 0);
    if (!mounted) return;
    // 阶段二 collapse：占位宽度收起，后续 chip 平滑左移补位（200ms
    // easeOutCubic，与 vanish 的 easeInCubic 收尾速度衔接连续）。
    _vanishingChipId = null;
    _collapsingChipId = school.id;
    _chipCollapseCurved?.dispose();
    _chipCollapseCtrl?.dispose();
    _chipCollapseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _chipCollapseCurved = CurvedAnimation(
      parent: _chipCollapseCtrl!,
      curve: Curves.easeOutCubic,
    );
    setState(() {});
    await _chipCollapseCtrl!.forward(from: 0);
    if (!mounted) return;
    // 全部播完才真正删除数据（持久化 + 内存态同步移除）。
    await ShiguangIndexService.removeRecentSchool(school);
    if (!mounted) return;
    setState(() {
      _recentSchools.removeWhere((s) => s.id == school.id);
      // 删空后退出编辑模式（整个区块会隐藏，避免残留状态）。
      if (_recentSchools.isEmpty) _editingRecent = false;
      _collapsingChipId = null;
    });
  }

  Future<void> _showAdapterPicker(
      ShiguangSchool school, List<ShiguangAdapter> adapters) async {
    final selected = await showBouncyDialog<ShiguangAdapter>(
      context: context,
      barrierLabel: '选择适配器',
      shellPadding: const EdgeInsets.all(24),
      shellMaxWidth: 400,
      shellBoxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.2),
          blurRadius: 20,
          offset: const Offset(0, 10),
        ),
      ],
      builder: (context) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Opacity(
              opacity: 0.82,
              child: Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF4A90E2), Color(0xFF5BA0F2)],
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.extension,
                  size: 32,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              school.name,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '该学校有 ${adapters.length} 个适配器，请选择',
              style: TextStyle(
                fontSize: 13,
                color: AppColors.of(context).textSecondary,
              ),
            ),
            const SizedBox(height: 16),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final adapter in adapters) ...[
                      _buildAdapterOption(adapter, () {
                        Navigator.pop(context, adapter);
                      }),
                      if (adapter != adapters.last) const SizedBox(height: 10),
                    ],
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );

    if (selected != null && mounted) {
      _openWebView(school, selected);
    }
  }

  Widget _buildAdapterOption(ShiguangAdapter adapter, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.of(context).panel(0.5),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.of(context).borderWeak),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: const Color(0xFF4A90E2).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.code,
                size: 20,
                color: Color(0xFF4A90E2),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    adapter.adapterName,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Colors.black87,
                    ),
                  ),
                  if (adapter.description.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      adapter.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.of(context).textSecondary,
                      ),
                    ),
                  ],
                  const SizedBox(height: 4),
                  Text(
                    '分类：${adapter.category.label} · 维护：${adapter.maintainer}',
                    style: TextStyle(
                      fontSize: 10,
                      color: AppColors.of(context).textTertiary,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right,
                size: 20, color: AppColors.of(context).textTertiary),
          ],
        ),
      ),
    );
  }

  void _openWebView(ShiguangSchool school, ShiguangAdapter adapter) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ShiguangWebImportScreen(
          school: school,
          adapter: adapter,
        ),
      ),
    );
  }

  // ---------- A-Z 导航条 ----------

  /// 列表滚动：导航条淡入、指示跟随当前分组字母，并重置 2 秒隐藏计时。
  /// 导航条拖动 / 字母跳转动画期间不回写字母（手指选择优先，避免滚动
  /// 跟随与手指选择互相打架）。
  void _onListScrolled() {
    if (!_navVisible) {
      setState(() => _navVisible = true);
    }
    if (!_navDragging && !_navJumping) {
      _syncActiveLetterFromScroll();
    }
    _scheduleNavHide();
  }

  /// 由当前滚动位置反推所在分组字母，更新导航条指示。
  /// `_letterOffsetsCache` 按字母序生成（Map 保持插入顺序），遍历天然
  /// 有序；视口顶端 = 滚动偏移 + 标题栏高度（与 [_jumpToLetter] 基准一致）。
  void _syncActiveLetterFromScroll() {
    if (!_scrollController.hasClients || _letterOffsetsCache.isEmpty) return;
    final viewportTop = _scrollController.position.pixels + _pinnedTopHeight;
    String? current;
    for (final entry in _letterOffsetsCache.entries) {
      if (entry.value > viewportTop) break;
      current = entry.key;
    }
    if (current != _activeNavLetter && mounted) {
      setState(() => _activeNavLetter = current);
    }
  }

  void _jumpToLetter(String letter) {
    final offsets = _letterOffsetsCache;
    final offset = offsets[letter];
    if (offset == null || !_scrollController.hasClients) return;
    // 分组头定位到固定标题栏正下方：直接跳 offset 会落在视口顶端，
    // 字母头被标题栏遮盖。
    final target = (offset - _pinnedTopHeight)
        .clamp(0.0, _scrollController.position.maxScrollExtent);
    // 跳转动画期间暂停滚动回写（手指选择优先）；序号防旧回调误清。
    final seq = ++_navJumpSeq;
    _navJumping = true;
    _scrollController
        .animateTo(
      target,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    )
        .whenComplete(() {
      if (seq == _navJumpSeq) _navJumping = false;
    });
  }

  void _scheduleNavHide() {
    _navHideTimer?.cancel();
    _navHideTimer = Timer(const Duration(seconds: 2), () {
      if (mounted && _navVisible && !_navDragging) {
        setState(() => _navVisible = false);
      }
    });
  }

  /// 导航条触摸：换算触点对应字母并跳转（点击与拖动共用）。
  void _onNavPointer(double dy, List<String> letters) {
    if (letters.isEmpty) return;
    final index = (dy / _kNavItemHeight).floor().clamp(0, letters.length - 1);
    final letter = letters[index];
    if (letter != _activeNavLetter) {
      HapticFeedback.selectionClick();
      setState(() => _activeNavLetter = letter);
      _jumpToLetter(letter);
    }
  }

  Map<String, double> _letterOffsetsCache = {};

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;
    // 固定区 = 状态栏 + 标题栏(56 + layoutBottomExtend 6) + 悬浮搜索条
    // (8 + 50 + 12)。A-Z 跳转与视口顶部计算、列表顶部偏移都以它为准。
    _pinnedTopHeight = topPadding + 62 + _kPinnedBlockBelowHeader;
    final groups = _groupedSchools;
    final letterGroups = _buildGroups(groups);
    _letterOffsetsCache = _computeLetterOffsets(letterGroups, _pinnedTopHeight);

    // 前置区域高度实测（含首次布局与内容变化，稳定后不再触发 setState）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final size = _leadingKey.currentContext?.size;
      if (size != null && size.height != _leadingHeight && mounted) {
        setState(() => _leadingHeight = size.height);
      }
    });

    final navLetters =
        groups.keys.where((k) => RegExp(r'^[A-Z]$').hasMatch(k)).toList();

    return Scaffold(
      // 搜索框位于顶部，键盘弹出无需压缩页面，避免整页重布局卡顿。
      resizeToAvoidBottomInset: false,
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? AppPalette.dark.scaffold
          : const Color(0xFFF8F9FC),
      body: Stack(
        children: [
          if (_loading) _buildLoading(),
          if (!_loading && _error != null) _buildError(),
          if (!_loading && _error == null)
            // 点击列表区域让搜索框脱焦收键盘（搜索框自身在竞技场中胜出，不受影响）。
            GestureDetector(
              onTap: _clearInputFocus,
              child: NotificationListener<ScrollNotification>(
                onNotification: (notification) {
                  if (notification.depth == 0 &&
                      (notification is ScrollUpdateNotification ||
                          notification is UserScrollNotification)) {
                    _onListScrolled();
                  }
                  return false;
                },
                child: CustomScrollView(
                  controller: _scrollController,
                  // 列表滚动时自动收起键盘（焦点脱落的另一种路径）。
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  physics: const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics()),
                  slivers: [
                    SliverPadding(
                      // 列表内容从固定区（标题栏 + 悬浮搜索条）下方开始，
                      // 与 _pinnedTopHeight 同一个表达式，两处必须同步
                      padding: EdgeInsets.only(top: _pinnedTopHeight),
                    ),
                    SliverToBoxAdapter(
                      child: Padding(
                        // key 必须挂在盒子组件上（sliver 的 context.size 拿不到内容高度）。
                        key: _leadingKey,
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // 搜索条已移入固定区，前置区从失效提示开始；
                            // 原本挂在提示前面的 12px 是"搜索条→提示"的
                            // 间距，一并去掉，改由提示自己向下留 16
                            if (_stale) ...[
                              _buildStaleBanner(),
                              const SizedBox(height: 16),
                            ],
                            // 搜索展示结果时通用教务区向上折叠收起
                            // （高度渐收、顶部对齐），清空搜索后展开恢复。
                            if (_genericSchools.isNotEmpty)
                              TweenAnimationBuilder<double>(
                                tween: Tween(end: _query.isEmpty ? 1.0 : 0.0),
                                duration: const Duration(milliseconds: 250),
                                curve: Curves.easeInOutCubic,
                                builder: (context, t, child) => ClipRect(
                                  child: Align(
                                    alignment: Alignment.topCenter,
                                    heightFactor: t,
                                    child: child,
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _buildSectionTitle('通用教务系统'),
                                    const SizedBox(height: 12),
                                    _buildGenericCards(),
                                    const SizedBox(height: 24),
                                  ],
                                ),
                              ),
                            if (_recentSchools.isNotEmpty &&
                                _query.isEmpty) ...[
                              _buildRecentTitleRow(),
                              const SizedBox(height: 8),
                              _buildRecentRow(),
                              const SizedBox(height: 24),
                            ],
                            _buildSectionTitle(
                                '全部学校（${_normalSchools.length}）'),
                            const SizedBox(height: 12),
                          ],
                        ),
                      ),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                      sliver: SliverList(
                        // 懒加载：首帧只构建可见项，修复切页/键盘弹收卡顿。
                        // 一项 = 一个字母组（字母头 + 该字母的合并卡）
                        delegate: SliverChildBuilderDelegate(
                          (context, index) =>
                              _buildLetterGroup(letterGroups[index]),
                          childCount: letterGroups.length,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          _buildPinnedHeader(topPadding),
          if (!_loading && _error == null) _buildPinnedSearchBar(topPadding),
          if (navLetters.isNotEmpty &&
              _query.isEmpty &&
              !_loading &&
              _error == null)
            _buildNavBar(navLetters),
        ],
      ),
    );
  }

  /// 右侧 A-Z 导航条：列表滚动时从右边界向左淡入弹出，2 秒无滑动自动隐藏。
  Widget _buildNavBar(List<String> letters) {
    final navHeight = letters.length * _kNavItemHeight;
    final screenH = MediaQuery.of(context).size.height;
    final navTop = (screenH - navHeight) / 2 + 40;

    return Positioned(
      top: navTop,
      right: 0,
      child: IgnorePointer(
        ignoring: !_navVisible,
        child: AnimatedOpacity(
          opacity: _navVisible ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            // 隐藏时贴右边界外，显示时向左滑入。
            transform:
                Matrix4.translationValues(_navVisible ? -6.0 : 28.0, 0, 0),
            margin: const EdgeInsets.only(right: 2),
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
            decoration: BoxDecoration(
              color: AppColors.of(context).glassShell.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.of(context).borderWeak),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08),
                  blurRadius: 12,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            // 手势直接包裹字母列：localPosition 从首个字母算起，无 padding 偏移。
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) {
                _navDragging = true;
                _onNavPointer(d.localPosition.dy, letters);
              },
              onTapUp: (_) {
                _navDragging = false;
                _scheduleNavHide();
              },
              onVerticalDragStart: (d) {
                _navDragging = true;
                _onNavPointer(d.localPosition.dy, letters);
              },
              onVerticalDragUpdate: (d) =>
                  _onNavPointer(d.localPosition.dy, letters),
              onVerticalDragEnd: (_) {
                _navDragging = false;
                // 保留手指最后选择的字母：跳转动画期间（_navJumping）滚动
                // 回写已暂停，动画结束后由下一次列表滚动自然接管。
                _scheduleNavHide();
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final letter in letters)
                    SizedBox(
                      width: 20,
                      height: _kNavItemHeight,
                      child: Center(
                        child: Container(
                          width: _kNavItemHeight - 2,
                          height: _kNavItemHeight - 2,
                          decoration: _activeNavLetter == letter
                              ? const BoxDecoration(
                                  color: _kAccent,
                                  shape: BoxShape.circle,
                                )
                              : null,
                          child: Center(
                            child: Text(
                              letter,
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: _activeNavLetter == letter
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                color: _activeNavLetter == letter
                                    ? Colors.white
                                    : _kAccent
                                        .withValues(alpha: 0.7),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPinnedHeader(double topPadding) {
    // 无界渐变标题栏（同导入/设置/待办/对话四页）：模糊+雾化自顶部
    // 向底缘衰减归零，无分隔硬边。layoutBottomExtend 6 让标题栏本体
    // 增高到 topPadding+62（内容起始偏移已同步 +6），底部坡面多出这
    // 段渐变空间；blurCurveShift 6 把雾面曲线下压，标题行可读性↑
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      child: GradientBlurHeader(
        topPadding: topPadding,
        title: '选择学校',
        blurCurveShift: 6,
        layoutBottomExtend: 6,
        titleRow: SizedBox(
          height: 56,
          child: Row(
            children: [
              // 悬浮玻璃圆钮：外层 56×56 槽位与原来一致（标题按 Expanded
              // 居中，不因按钮变小而偏移），圆钮在槽内居中——原实现漏了
              // alignment，图标其实贴在 56 盒的左上角。
              Container(
                width: 56,
                height: 56,
                margin: const EdgeInsets.only(left: 4),
                alignment: Alignment.center,
                child: FloatingGlassButton(
                  onTap: () => Navigator.pop(context),
                  reveal: _headerReveal,
                  child: Icon(
                    Icons.arrow_back_ios_new,
                    size: 18,
                    color: AppColors.of(context).textPrimary,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  '选择学校',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: AppColors.of(context).textPrimary,
                  ),
                ),
              ),
              Container(
                width: 56,
                height: 56,
                margin: const EdgeInsets.only(right: 4),
                alignment: Alignment.center,
                // 刷新中只让玻璃壳内的图标自转（_refreshSpinController
                // 驱动，停止后 reset 归正角度），壳本身不动；此时按钮只是
                // 暂时不可点，不淡出。
                child: FloatingGlassButton(
                  onTap: _refreshing
                      ? null
                      : () => _loadIndex(forceRefresh: true),
                  dimWhenDisabled: false,
                  reveal: _headerReveal,
                  child: RotationTransition(
                    turns: _refreshSpinController,
                    // 图标色与左侧返回键统一走 textPrimary（浅黑/深白），
                    // 不再用页面强调紫——两颗圆钮同为一组，颜色不该分档
                    child: Icon(
                      Icons.refresh,
                      size: 22,
                      color: AppColors.of(context).textPrimary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLoading() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation(Color(0xFF4A90E2)),
          ),
          const SizedBox(height: 16),
          Text(
            '正在获取学校列表...',
            style: TextStyle(
                fontSize: 14, color: AppColors.of(context).textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.wifi_off,
                size: 36,
                color: Colors.orange,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              '获取学校列表失败',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: AppColors.of(context).textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _error ?? '',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 13, color: AppColors.of(context).textSecondary),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () => _loadIndex(forceRefresh: true),
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重试'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4A90E2),
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 固定悬浮搜索条：贴在标题栏正下方，不随列表滚动。两态由 [_headerReveal]
  /// 连续渐变（与两颗圆钮同一条进度、同一套 28px + smoothstep + 220ms）：
  ///
  /// - **贴顶（进度 0）**：HyperOS 通讯录那种纯色浅灰胶囊——`surfaceAlt`
  ///   实色，无模糊、无描边、无投影。
  /// - **有内容滚到条底下（进度 1）**：毛玻璃形态，照搬 WebView 页底部网址
  ///   栏完全形态——半径 25 / 高 50 / ClipRRect + BackdropFilter sigma 15 /
  ///   glassBorder 1.5 描边 / glassShell 0.55 底色（减弱动态时不模糊、底色
  ///   提到浅色 0.94、深色 0.85）+ 一层外投影。
  ///
  /// 四层自下而上：投影（Opacity = v）→ 玻璃体（常驻）→ 浅灰贴顶层
  /// （Opacity = 1 - v）→ 输入内容。**方向是灰层淡出而不是玻璃层淡入**，
  /// 因为 BackdropFilter 一旦被 Opacity 包住就会采样到透明黑；玻璃层常驻、
  /// 只让不透明灰壳盖在它上面消失，渐变同样成立。输入内容单独一层，
  /// 不会被任何一层背景盖住。
  ///
  /// 输入框自身的 filled 与三档 OutlineInputBorder 全部清空，底色和描边
  /// 统一交给上面两层。
  Widget _buildPinnedSearchBar(double topPadding) {
    final palette = AppColors.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final radius = BorderRadius.circular(_kSearchBarRadius);

    return Positioned(
      left: 0,
      right: 0,
      top: topPadding + 62 + _kSearchBarGapAbove,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: _kSearchBarSideInset),
        child: SizedBox(
          height: _kSearchBarHeight,
          // Stack 必须 clipBehavior: Clip.none：默认 hardEdge 会按条自身的
          // 方框裁掉外溢的投影，切回一个矩形边
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: ValueListenableBuilder<double>(
                  valueListenable: _headerReveal,
                  child: RepaintBoundary(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: radius,
                        boxShadow: [
                          BoxShadow(
                            color: palette.shadow.withValues(alpha: 0.08),
                            blurRadius: 16,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                    ),
                  ),
                  builder: (context, value, cachedShadow) => Opacity(
                    // 平方曲线：投影在后半段才展开（见灰层注释里的排布）
                    opacity: value * value,
                    child: cachedShadow,
                  ),
                ),
              ),
              // 玻璃体常驻：它带着 BackdropFilter，整段被 Opacity 包住会
              // 采样到透明黑，所以它自己绝不参与淡入淡出
              Positioned.fill(
                child: ClipRRect(
                  borderRadius: radius,
                  child: BackdropFilter(
                    filter: ImageFilter.blur(
                      sigmaX: _reduceMotion ? 0 : _kSearchBarBlurSigma,
                      sigmaY: _reduceMotion ? 0 : _kSearchBarBlurSigma,
                    ),
                    child: Container(
                      decoration: BoxDecoration(
                        color: palette.glassShell.withValues(
                          alpha:
                              _reduceMotion ? (isDark ? 0.85 : 0.94) : 0.55,
                        ),
                        borderRadius: radius,
                        // 描边恒定：聚焦不再改色改宽（紫色焦点环被否掉）。
                        // 一个搜索框的聚焦反馈由光标 + 键盘承担就够了，
                        // 也就不需要给 FocusNode 挂监听、聚焦时整条重建
                        border: Border.all(
                          color: palette.glassBorder,
                          width: 1.5,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // 贴顶形态：HyperOS 通讯录那种纯色浅灰胶囊（无模糊、无描边、
              // 无投影）。它压在玻璃体之上做**淡出**（1 - 进度），而不是给
              // 玻璃体做淡入——这样渐变成立的同时，BackdropFilter 始终不被
              // Opacity 包住。进度到 1 时 Opacity 为 0，Flutter 直接跳过绘制
              Positioned.fill(
                child: ValueListenableBuilder<double>(
                  valueListenable: _headerReveal,
                  child: RepaintBoundary(
                    child: Container(
                      decoration: BoxDecoration(
                        color: palette.surfaceAlt,
                        borderRadius: radius,
                      ),
                    ),
                  ),
                  builder: (context, value, cachedRest) => Opacity(
                    // 与投影层错开排布：两层都用线性 v 时，进度刚到一半灰壳
                    // 还有一半浓度，而投影已经半强——投影先于本体出现，回顶
                    // 时反过来就是"阴影先重一下再消失"，看着像闪。改成平方
                    // 曲线后：v=0.5 时灰壳只剩 0.25、投影也只有 0.25，先让
                    // 灰壳化开露出玻璃，投影再跟着长起来；反向同理，两个
                    // 方向都对称。
                    opacity: (1 - value) * (1 - value),
                    child: cachedRest,
                  ),
                ),
              ),
              // 输入内容压在最上层，两层背景都盖不到它
              Positioned.fill(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: _buildSearchField(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSearchField() {
    return AppTextField(
      contextMenuBuilder: styledEditableContextMenu,
      controller: _searchController,
      focusNode: _searchFocus,
      onChanged: (v) => setState(() => _query = v.trim()),
      textInputAction: TextInputAction.search,
      textAlignVertical: TextAlignVertical.center,
      decoration: InputDecoration(
        hintText: '搜索学校名称 / 英文缩写',
        hintStyle:
            TextStyle(color: AppColors.of(context).textTertiary, fontSize: 13),
        // 搜索图标：紫色改成与提示文字同款的灰；再加 8px 左内边距把它
        // 整体右移一点（默认是在 44 宽盒里居中）
        prefixIcon: Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Icon(Icons.search,
              size: 20, color: AppColors.of(context).textTertiary),
        ),
        suffixIcon: _query.isNotEmpty
            ? GestureDetector(
                onTap: () {
                  _searchController.clear();
                  setState(() => _query = '');
                },
                child: Icon(Icons.close,
                    size: 18, color: AppColors.of(context).textTertiary),
              )
            : null,
        // 底色与描边都交给外层悬浮玻璃壳，这里三档边框一律清空。
        //
        // 垂直居中的做法：isCollapsed 把 InputDecorator 自己的上下内边距
        // 全部清零，由外层固定的 50 高盒 + textAlignVertical.center 决定
        // 文字位置。原先 isDense + contentPadding vertical:15 会和 prefix
        // 的 44 高约束盒互相顶，实测文字比胶囊中心低约 7 逻辑px。
        // prefix / suffix 的约束高度直接对齐条高，两个图标才跟着一起居中。
        filled: false,
        isCollapsed: true,
        contentPadding:
            const EdgeInsets.symmetric(vertical: 0, horizontal: 4),
        prefixIconConstraints:
            const BoxConstraints(minWidth: 44, minHeight: _kSearchBarHeight),
        suffixIconConstraints:
            const BoxConstraints(minWidth: 40, minHeight: _kSearchBarHeight),
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
      ),
      style: const TextStyle(fontSize: 13),
    );
  }

  Widget _buildStaleBanner() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.orange.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline,
              size: 16, color: AppColors.bannerText(context, Colors.orange)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '网络不佳，当前展示的是缓存数据，可能不是最新',
              style: TextStyle(
                  fontSize: 12,
                  color: AppColors.bannerText(context, Colors.orange)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: AppColors.of(context).textPrimary,
      ),
    );
  }

  /// 通用教务系统：与字母分组同款合并卡（原来是一所学校一张卡、卡间 8px
  /// 间隙，现已统一收进一张卡）
  Widget _buildGenericCards() {
    return _buildMergedCard(_genericSchools);
  }

  /// 最近使用标题行：固定行高，避免「完成」按钮出现/消失时高度跳变。
  Widget _buildRecentTitleRow() {
    return SizedBox(
      height: 24,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            '最近使用',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: AppColors.of(context).textPrimary,
            ),
          ),
          const Spacer(),
          if (_editingRecent)
            GestureDetector(
              onTap: () => setState(() => _editingRecent = false),
              child: Container(
                height: 22,
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 9),
                decoration: BoxDecoration(
                  color: _kAccent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _kAccent.withValues(alpha: 0.4),
                  ),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check, size: 13, color: _kAccent),
                    SizedBox(width: 3),
                    Text(
                      '完成',
                      style: TextStyle(
                        fontSize: 12,
                        color: _kAccent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 最近使用：横向单行滑动（触底回弹），长按进入编辑模式后可删除。
  /// 左右边缘加淡出雾化遮罩（与课表列表同款 FadingEdgeList）：内容横向
  /// 溢出时，仍有内容的一侧在边缘渐隐，提示"还能继续滑"
  Widget _buildRecentRow() {
    return FadingEdgeList(
      scrollDirection: Axis.horizontal,
      height: 56,
      // 触底回弹（与其它横滑行一致）
      physics: const BouncingScrollPhysics(),
      // 两侧留白：最后一个 chip 的删除按钮负向偏移不被视口裁切。
      padding: const EdgeInsets.symmetric(horizontal: 8),
      // 横滑 chip 高度约 40，淡出带取 24（略小于纵向的 26）：
      // 横向上一个 chip 宽度不大，太宽会把整个 chip 糊掉
      fadeExtent: 24,
      itemCount: _recentSchools.length,
      itemBuilder: (context, index) {
        final school = _recentSchools[index];
        Widget cell = Padding(
          padding: const EdgeInsets.only(right: 12),
          child: Center(child: _buildRecentChip(school)),
        );
        if (school.id == _vanishingChipId) {
          // 阶段一 vanish：原位模糊增大 + 向内缩小 + 淡出
          //（参数对齐课表删除动画），逐帧驱动；减弱动态效果时
          // 跳过模糊，仅保留缩小 + 淡出。
          cell = Padding(
            padding: const EdgeInsets.only(right: 12),
            child: AnimatedBuilder(
              animation: _chipVanishCurved ?? kAlwaysDismissedAnimation,
              builder: (context, child) {
                final t = _chipVanishCurved?.value ?? 0.0;
                final scaled = Transform.scale(
                  scale: 1.0 - 0.45 * t,
                  child: child,
                );
                return IgnorePointer(
                  child: Opacity(
                    opacity: (1.0 - t).clamp(0.0, 1.0),
                    child: _reduceMotion
                        ? scaled
                        : ImageFiltered(
                            imageFilter: ImageFilter.blur(
                              sigmaX: 14 * t,
                              sigmaY: 14 * t,
                            ),
                            child: scaled,
                          ),
                  ),
                );
              },
              child: Center(child: _buildRecentChip(school)),
            ),
          );
        } else if (school.id == _collapsingChipId) {
          // 阶段二 collapse：chip 已完全不可见，占位宽度（含右侧
          // 12px 间距）逐帧收起，后续 chip 平滑左移补位。
          cell = AnimatedBuilder(
            animation: _chipCollapseCurved ?? kAlwaysDismissedAnimation,
            builder: (context, child) {
              final t = _chipCollapseCurved?.value ?? 0.0;
              return IgnorePointer(
                child: Opacity(
                  opacity: 0.0,
                  child: SizeTransition(
                    axis: Axis.horizontal,
                    sizeFactor:
                        AlwaysStoppedAnimation((1.0 - t).clamp(0.0, 1.0)),
                    axisAlignment: -1.0,
                    child: child,
                  ),
                ),
              );
            },
            child: cell,
          );
        }
        return cell;
      },
    );
  }

  Widget _buildRecentChip(ShiguangSchool school) {
    final editing = _editingRecent;
    // 顶部/右侧预留 6px：删除按钮负向偏移后仍在可命中区域内
    // （Stack 越界部分绘制可见但不可点击，Padding 包裹即可）。
    return Padding(
      padding: const EdgeInsets.only(top: 6, right: 6),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          GestureDetector(
            onTap: editing ? null : () => _onSchoolTap(school),
            onLongPress: () {
              HapticFeedback.mediumImpact();
              setState(() => _editingRecent = true);
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                // 背景恒定不变：编辑态若淡化（0.08→0.04）在浅色底上
                // 近乎白色，观感像「变白」；编辑态仅由边框加深 + 删除
                // 按钮指示。
                color: _kAccent.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: _kAccent
                      .withValues(alpha: editing ? 0.4 : 0.25),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.history, size: 14, color: _kAccent),
                  const SizedBox(width: 6),
                  Text(
                    school.name,
                    style: const TextStyle(
                      fontSize: 13,
                      color: _kAccent,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 编辑模式：右上角删除按钮（灰色配色）。
          if (editing)
            Positioned(
              top: -6,
              right: -6,
              child: GestureDetector(
                onTap: () => _removeRecentSchool(school),
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: AppColors.of(context).textTertiary,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 1.5),
                  ),
                  child: const Icon(Icons.close, size: 10, color: Colors.white),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 一个字母组：字母头（固定 44 高）+ 该字母下所有学校的合并卡。
  /// 组内无间隙，与设置页 `_buildSettingsGroup` 同款。
  Widget _buildLetterGroup(_LetterGroup group) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSectionHeader(group.letter),
        _buildMergedCard(group.schools),
      ],
    );
  }

  /// 合并卡：一张 Card 里竖排若干学校行，行间 1px 分隔线（左缩进对齐文字
  /// 左缘），Card 自带 borderWeak 描边，所以行本身不再各自描边。
  Widget _buildMergedCard(List<ShiguangSchool> schools) {
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppColors.of(context).borderWeak),
      ),
      child: Column(
        children: [
          for (var i = 0; i < schools.length; i++) ...[
            if (i > 0)
              Divider(
                // 占位高度与 offset 计算共用同一个常量，两边不可能再算岔
                height: _kRowDividerHeight,
                thickness: _kRowDividerHeight,
                indent: _kRowDividerIndent,
                color: AppColors.of(context).borderWeak,
              ),
            _buildSchoolRow(schools[i]),
          ],
        ],
      ),
    );
  }

  /// 字母分组头（固定行高，供导航跳转 offset 计算）。
  Widget _buildSectionHeader(String letter) {
    return SizedBox(
      height: _kSectionHeaderHeight,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: _kAccent.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            letter,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: _kAccent,
            ),
          ),
        ),
      ),
    );
  }

  /// 卡内单行：定高 56（offset 计算依赖），左侧图标底座已去掉，
  /// 名称直接顶到卡片左内边距。
  Widget _buildSchoolRow(ShiguangSchool school) {
    return SizedBox(
      height: _kSchoolRowHeight,
      child: InkWell(
        onTap: () => _onSchoolTap(school),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  school.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.of(context).textPrimary,
                  ),
                ),
              ),
              Icon(Icons.chevron_right,
                  size: 20, color: AppColors.of(context).textTertiary),
            ],
          ),
        ),
      ),
    );
  }
}
