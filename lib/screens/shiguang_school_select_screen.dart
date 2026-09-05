import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/shiguang/shiguang_index_service.dart';
import '../services/shiguang/shiguang_models.dart';
import '../widgets/blur_selection_menu.dart';
import '../widgets/glass_dialog.dart';
import '../widgets/toast_notification.dart';
import 'shiguang_web_import_screen.dart';

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
class _FlatItem {
  final String? letter;
  final ShiguangSchool? school;

  const _FlatItem.section(this.letter) : school = null;
  const _FlatItem.card(this.school) : letter = null;

  bool get isSection => letter != null;
}

class _ShiguangSchoolSelectScreenState
    extends State<ShiguangSchoolSelectScreen>
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

  /// 固定标题栏总高度（状态栏 + 56 标题行）：导航跳转偏移与滚动
  /// 高亮跟随都以它为视口顶端基准。
  double _pinnedHeaderHeight = 0;

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

  /// 扁平列表固定行高（导航跳转 offset 按此精确计算）。
  static const double _kSectionHeaderHeight = 44;
  static const double _kSchoolCardHeight = 72;
  static const double _kNavItemHeight = 16;

  @override
  void initState() {
    super.initState();
    _refreshSpinController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _loadReduceMotion();
    _loadIndex();
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

  Future<void> _loadIndex({bool forceRefresh = false}) async {
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

  /// 扁平化学校列表（分组头 + 学校卡），供懒加载 builder 消费。
  List<_FlatItem> _buildFlatItems(Map<String, List<ShiguangSchool>> groups) {
    final flat = <_FlatItem>[];
    for (final entry in groups.entries) {
      flat.add(_FlatItem.section(entry.key));
      for (final school in entry.value) {
        flat.add(_FlatItem.card(school));
      }
    }
    return flat;
  }

  /// 计算每个字母分组头在滚动坐标系中的偏移（前置区域高度实测 + 行高累加）。
  Map<String, double> _computeLetterOffsets(
      List<_FlatItem> flat, double topPadding) {
    if (_leadingHeight <= 0) return {};
    final offsets = <String, double>{};
    double y = topPadding + 64 + _leadingHeight;
    for (final item in flat) {
      if (item.isSection) offsets[item.letter!] = y;
      y += item.isSection ? _kSectionHeaderHeight : _kSchoolCardHeight;
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
                    colors: [Color(0xFF9B59B6), Color(0xFFAF7AC5)],
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
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '该学校有 ${adapters.length} 个适配器，请选择',
              style: TextStyle(
                fontSize: 13,
                color: Colors.grey.shade600,
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

  Widget _buildAdapterOption(
      ShiguangAdapter adapter, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade200),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: const Color(0xFF9B59B6).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.code,
                size: 20,
                color: Color(0xFF9B59B6),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    adapter.adapterName,
                    style: const TextStyle(
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
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                  const SizedBox(height: 4),
                  Text(
                    '分类：${adapter.category.label} · 维护：${adapter.maintainer}',
                    style: TextStyle(
                      fontSize: 10,
                      color: Colors.grey.shade500,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 20, color: Colors.grey.shade400),
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
    final viewportTop = _scrollController.position.pixels + _pinnedHeaderHeight;
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
    final target = (offset - _pinnedHeaderHeight)
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
    final index =
        (dy / _kNavItemHeight).floor().clamp(0, letters.length - 1);
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
    _pinnedHeaderHeight = topPadding + 56;
    final groups = _groupedSchools;
    final flat = _buildFlatItems(groups);
    _letterOffsetsCache = _computeLetterOffsets(flat, topPadding);

    // 前置区域高度实测（含首次布局与内容变化，稳定后不再触发 setState）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final size = _leadingKey.currentContext?.size;
      if (size != null && size.height != _leadingHeight && mounted) {
        setState(() => _leadingHeight = size.height);
      }
    });

    final navLetters = groups.keys
        .where((k) => RegExp(r'^[A-Z]$').hasMatch(k))
        .toList();

    return Scaffold(
      // 搜索框位于顶部，键盘弹出无需压缩页面，避免整页重布局卡顿。
      resizeToAvoidBottomInset: false,
      backgroundColor: const Color(0xFFF8F9FC),
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
                    padding: EdgeInsets.only(top: topPadding + 64),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      // key 必须挂在盒子组件上（sliver 的 context.size 拿不到内容高度）。
                      key: _leadingKey,
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildSearchField(),
                          if (_stale) ...[
                            const SizedBox(height: 12),
                            _buildStaleBanner(),
                          ],
                          const SizedBox(height: 16),
                          // 搜索展示结果时通用教务区向上折叠收起
                          // （高度渐收、顶部对齐），清空搜索后展开恢复。
                          if (_genericSchools.isNotEmpty)
                            TweenAnimationBuilder<double>(
                              tween: Tween(
                                  end: _query.isEmpty ? 1.0 : 0.0),
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
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
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
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          final item = flat[index];
                          if (item.isSection) {
                            return _buildSectionHeader(item.letter!);
                          }
                          return _buildSchoolCard(item.school!);
                        },
                        childCount: flat.length,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          _buildPinnedHeader(topPadding),
          if (navLetters.isNotEmpty && _query.isEmpty && !_loading && _error == null)
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
            transform: Matrix4.translationValues(
                _navVisible ? -6.0 : 28.0, 0, 0),
            margin: const EdgeInsets.only(right: 2),
            padding:
                const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.grey.shade200),
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
                                  color: Color(0xFF9B59B6),
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
                                    : const Color(0xFF9B59B6)
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
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      child: ClipRRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFFF8F9FC).withValues(alpha: 0.75),
              border: Border(
                bottom: BorderSide(color: Colors.grey.shade200, width: 0.5),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(height: topPadding),
                SizedBox(
                  height: 56,
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: () => Navigator.pop(context),
                        child: Container(
                          width: 56,
                          height: 56,
                          margin: const EdgeInsets.only(left: 4),
                          child: const Icon(
                            Icons.arrow_back_ios_new,
                            size: 18,
                            color: Color(0xFF1A1A2E),
                          ),
                        ),
                      ),
                      const Expanded(
                        child: Text(
                          '选择学校',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF1A1A2E),
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: _refreshing
                            ? null
                            : () => _loadIndex(forceRefresh: true),
                        child: Container(
                          width: 56,
                          height: 56,
                          margin: const EdgeInsets.only(right: 4),
                          alignment: Alignment.center,
                          // 刷新中原图标自转（由 _refreshSpinController 驱动，
                          // 停止后 reset 归正角度）。
                          child: RotationTransition(
                            turns: _refreshSpinController,
                            child: const Icon(
                              Icons.refresh,
                              size: 22,
                              color: Color(0xFF9B59B6),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
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
            valueColor: AlwaysStoppedAnimation(Color(0xFF9B59B6)),
          ),
          const SizedBox(height: 16),
          Text(
            '正在获取学校列表...',
            style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
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
            const Text(
              '获取学校列表失败',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: Color(0xFF1A1A2E),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _error ?? '',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () => _loadIndex(forceRefresh: true),
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重试'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF9B59B6),
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

  Widget _buildSearchField() {
    return TextField(
      contextMenuBuilder: styledEditableContextMenu,
      controller: _searchController,
      focusNode: _searchFocus,
      onChanged: (v) => setState(() => _query = v.trim()),
      textInputAction: TextInputAction.search,
      textAlignVertical: TextAlignVertical.center,
      decoration: InputDecoration(
        hintText: '搜索学校名称 / 英文缩写',
        hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 13),
        prefixIcon: const Icon(Icons.search,
            size: 20, color: Color(0xFF9B59B6)),
        suffixIcon: _query.isNotEmpty
            ? GestureDetector(
                onTap: () {
                  _searchController.clear();
                  setState(() => _query = '');
                },
                child:
                    Icon(Icons.close, size: 18, color: Colors.grey.shade400),
              )
            : null,
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.8),
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(vertical: 13, horizontal: 4),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey.shade200),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey.shade200),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF9B59B6), width: 2),
        ),
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
          Icon(Icons.info_outline, size: 16, color: Colors.orange.shade700),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '网络不佳，当前展示的是缓存数据，可能不是最新',
              style: TextStyle(fontSize: 12, color: Colors.orange.shade800),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: Color(0xFF1A1A2E),
      ),
    );
  }

  Widget _buildGenericCards() {
    return Column(
      children: [
        for (final school in _genericSchools) ...[
          _buildSchoolCard(school, icon: Icons.hub, fixedHeight: false),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  /// 最近使用标题行：固定行高，避免「完成」按钮出现/消失时高度跳变。
  Widget _buildRecentTitleRow() {
    return SizedBox(
      height: 24,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Text(
            '最近使用',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: Color(0xFF1A1A2E),
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
                  color: const Color(0xFF9B59B6).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color:
                        const Color(0xFF9B59B6).withValues(alpha: 0.4),
                  ),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check, size: 13, color: Color(0xFF9B59B6)),
                    SizedBox(width: 3),
                    Text(
                      '完成',
                      style: TextStyle(
                        fontSize: 12,
                        color: Color(0xFF9B59B6),
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
  Widget _buildRecentRow() {
    return SizedBox(
      height: 56,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        // 两侧留白：最后一个 chip 的删除按钮负向偏移不被视口裁切。
        padding: const EdgeInsets.symmetric(horizontal: 8),
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
                      sizeFactor: AlwaysStoppedAnimation(
                          (1.0 - t).clamp(0.0, 1.0)),
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
      ),
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
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                // 背景恒定不变：编辑态若淡化（0.08→0.04）在浅色底上
                // 近乎白色，观感像「变白」；编辑态仅由边框加深 + 删除
                // 按钮指示。
                color: const Color(0xFF9B59B6).withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: const Color(0xFF9B59B6)
                      .withValues(alpha: editing ? 0.4 : 0.25),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.history,
                      size: 14, color: Color(0xFF9B59B6)),
                  const SizedBox(width: 6),
                  Text(
                    school.name,
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF9B59B6),
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
                    color: Colors.grey.shade500,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 1.5),
                  ),
                  child: const Icon(Icons.close,
                      size: 10, color: Colors.white),
                ),
              ),
            ),
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
            color: const Color(0xFF9B59B6).withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            letter,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Color(0xFF9B59B6),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSchoolCard(ShiguangSchool school,
      {IconData icon = Icons.school, bool fixedHeight = true}) {
    final isGeneric = school.isGeneric;
    final color =
        isGeneric ? const Color(0xFF9B59B6) : const Color(0xFF4A90E2);

    Widget card = Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: InkWell(
        onTap: () => _onSchoolTap(school),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: color, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  school.name,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1A1A2E),
                  ),
                ),
              ),
              Icon(Icons.chevron_right, size: 20, color: Colors.grey.shade400),
            ],
          ),
        ),
      ),
    );

    // 列表区行高固定（卡片 64 + 底部间距 8 = 72，与导航 offset 计算一致）；
    // 通用教务区保持自然流式。
    if (fixedHeight) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: SizedBox(height: _kSchoolCardHeight - 8, child: card),
      );
    }
    return card;
  }
}
