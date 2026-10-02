import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'timetable_screen.dart';
import 'heatmap_screen.dart';
import 'import_screen.dart';
import 'ai_assistant_screen.dart';
import 'settings_screen.dart';
import '../theme/app_theme.dart';
import '../utils/storage.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  /// 悬浮导航栏块总占位高度 = 底部外边距 15（Stack 里 Positioned
  /// bottom: 15 + 系统底边距）+ 栏体高 64。
  /// 「系统底边距 + 本值」即导航栏顶边位置，供对话页输入框等
  /// 需要悬停在导航栏上方的布局作基准
  static const double navBarBlockHeight = 15 + 64;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  int _currentIndex = 0;
  int? _pressedIndex;
  int? _hoveredIndex;
  double _dragOffset = 0;
  bool _isDragging = false;

  static const _widgetChannel = MethodChannel('coursehub/widget');

  final _timetableKey = GlobalKey<TimetableScreenState>();
  final _heatmapKey = GlobalKey<HeatmapScreenState>();
  final _aiAssistantKey = GlobalKey<AIAssistantScreenState>();

  late final List<Widget> _screens;

  late final AnimationController _iconController;
  late final PageController _pageController;

  late final AnimationController _navBarAnimController;
  late final Animation<double> _navBarAnimation;

  late final AnimationController _fabAnimController;
  late final Animation<Offset> _fabSlideAnimation;

  double _lastScrollOffset = 0;
  bool _navBarVisible = true;
  bool _fabVisible = true;

  /// 课表页是否停在「本周」：false 时 FAB 左侧淡入「今」按钮（由课表屏上报）
  bool _viewingThisWeek = true;
  bool _wallpaperEnabled = false;
  static const double _scrollThreshold = 50.0;

  static const double _itemWidth = 60.0;
  static const double _itemMargin = 2.0;
  static const double _navPadding = 16.0;

  @override
  void initState() {
    super.initState();
    // 深色模式渐进迁移：已语义化改造的设置页跟随全局主题；
    // 未迁移的大屏先局部锁定浅色 Theme 保持自身自洽（内部硬编码
    // 浅色不与深色脚手架/默认文字色混色），迁移一屏解禁一屏
    _screens = [
      // 课表屏已语义化（壁纸分支保持独立明暗逻辑），跟随全局深浅
      TimetableScreen(
        key: _timetableKey,
        onScrollDirectionChanged: _onScrollDirectionChanged,
        onViewedWeekChanged: _onViewedWeekChanged,
      ),
      // 热力图已语义化，跟随全局深浅
      HeatmapScreen(key: _heatmapKey),
      // AI 对话屏已语义化，跟随全局深浅
      AIAssistantScreen(
        key: _aiAssistantKey,
        onKeyboardShown: _onKeyboardShown,
        onKeyboardHidden: _onKeyboardHidden,
        onNavigateToSettings: () => _onTabChanged(4),
      ),
      // 导入屏已语义化，跟随全局深浅
      const ImportScreen(),
      const SettingsScreen(),
    ];

    _iconController = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );

    _pageController = PageController();

    _navBarAnimController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _navBarAnimation = CurvedAnimation(
      parent: _navBarAnimController,
      curve: Curves.easeOutCubic,
    );
    _navBarAnimController.forward();

    _fabAnimController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _fabSlideAnimation = Tween<Offset>(
      begin: Offset.zero,
      end: const Offset(1.5, 0),
    ).animate(CurvedAnimation(
      parent: _fabAnimController,
      curve: Curves.easeOutCubic,
    ));

    StorageService.dataChangeListenable.addListener(_onStorageDataChanged);
    _loadWallpaperEnabled();
    WidgetsBinding.instance.addObserver(this);
    _checkWidgetRoute();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    StorageService.dataChangeListenable.removeListener(_onStorageDataChanged);
    _iconController.dispose();
    _pageController.dispose();
    _navBarAnimController.dispose();
    _fabAnimController.dispose();
    super.dispose();
  }

  void _onStorageDataChanged() {
    if (!mounted) return;

    if (_currentIndex == 0) {
      _timetableKey.currentState?.refreshData();
    } else if (_currentIndex == 1) {
      _heatmapKey.currentState?.refreshData();
    } else {
      // 当前不在课表页/待办页时，标记需要在切回时刷新
      TimetableScreenState.markNeedsRefresh();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkWidgetRoute();
    }
  }

  Future<void> _checkWidgetRoute() async {
    try {
      final route = await _widgetChannel.invokeMethod<String>('getWidgetRoute');
      if (route != null && route.contains('timetable') && mounted) {
        _onTabChanged(0);
      }
    } catch (_) {}
  }

  void _onTabChanged(int index, {bool withHaptic = false}) {
    if (withHaptic && _currentIndex != index) {
      HapticFeedback.selectionClick();
    }

    _iconController.forward(from: 0);

    if (!_fabVisible && (index == 0 || index == 1)) {
      _fabVisible = true;
    }

    if (index != 0) {
      _navBarVisible = true;
      _navBarAnimController.animateTo(1, duration: Duration.zero);
    }

    if (_currentIndex == index) return;

    if (_currentIndex == 1 && index != 1) {
      _heatmapKey.currentState?.clearRetainedCompletedTasks();
    }

    if (_currentIndex == 0 && index != 0) {
      _timetableKey.currentState?.clearRetainedCompletedTasks();
    }

    if (_currentIndex == 2) {
      _aiAssistantKey.currentState?.saveScrollPosition();
      // 离开对话页时强制清除输入框焦点，防止切回时键盘自动弹出
      _aiAssistantKey.currentState?.clearInputFocus();
    }

    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );

    setState(() {
      _currentIndex = index;
    });

    if (index == 0) {
      _timetableKey.currentState?.refreshIfNeeded();
      _loadWallpaperEnabled();
    } else if (index == 1) {
      _heatmapKey.currentState?.refreshData();
    } else if (index == 2) {
      _aiAssistantKey.currentState?.refreshRuntimeConfig();
      _aiAssistantKey.currentState?.restoreScrollPosition();
    }
  }

  double _getSliderLeft() {
    return _itemMargin + (_itemWidth + _itemMargin * 2) * _currentIndex;
  }

  void _handleScroll(ScrollNotification notification) {
    if (_currentIndex != 0) return;

    if (notification is ScrollStartNotification) {
      if (notification.dragDetails != null) {
        _lastScrollOffset = notification.metrics.pixels;
      }
    } else if (notification is ScrollUpdateNotification) {
      final metrics = notification.metrics;

      if (metrics.axis != Axis.vertical) return;

      final isUserDrag = notification.dragDetails != null;
      if (!isUserDrag) return;

      final currentOffset = metrics.pixels;
      final delta = currentOffset - _lastScrollOffset;

      if (delta.abs() > 1) {
        if (delta > 0 && _navBarVisible) {
          _hideNavBar();
          _lastScrollOffset = currentOffset;
        } else if (delta < 0 && !_navBarVisible) {
          _showNavBar();
          _lastScrollOffset = currentOffset;
        }
      }
    }
  }

  void _hideNavBar({bool animated = true}) {
    if (_navBarVisible) {
      _navBarVisible = false;
      if (animated) {
        _navBarAnimController.reverse();
      } else {
        _navBarAnimController.animateTo(0, duration: Duration.zero);
      }
      setState(() {
        _fabVisible = false;
      });
    }
  }

  void _showNavBar() {
    if (!_navBarVisible) {
      _navBarVisible = true;
      _navBarAnimController.forward();
      setState(() {
        _fabVisible = true;
      });
    }
  }

  void _onScrollDirectionChanged(bool isScrollingDown) {
    if (_currentIndex != 0) return;

    if (isScrollingDown && _navBarVisible) {
      _hideNavBar();
    } else if (!isScrollingDown && !_navBarVisible) {
      _showNavBar();
    }
  }

  /// 课表屏浏览周次变化：停在非本周时，FAB 左侧淡入「今」按钮
  void _onViewedWeekChanged(bool viewingThisWeek) {
    if (!mounted || _viewingThisWeek == viewingThisWeek) return;
    setState(() {
      _viewingThisWeek = viewingThisWeek;
    });
  }

  void _onKeyboardShown() {
    // Keep nav bar layout independent from keyboard state.
  }

  void _onKeyboardHidden() {
    // Keep nav bar layout independent from keyboard state.
  }

  void _onFABPressed() {
    if (_currentIndex == 0) {
      _timetableKey.currentState
          ?.showAddOptions(onGoToChat: () => _onTabChanged(2));
    } else if (_currentIndex == 1) {
      _heatmapKey.currentState
          ?.showAddOptions(onGoToChat: () => _onTabChanged(2));
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).viewPadding.bottom;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Theme.of(context).brightness == Brightness.dark
            ? Brightness.light
            : Brightness.dark,
        statusBarBrightness: Theme.of(context).brightness,
        systemStatusBarContrastEnforced: false,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarDividerColor: Colors.transparent,
        systemNavigationBarIconBrightness:
            Theme.of(context).brightness == Brightness.dark
                ? Brightness.light
                : Brightness.dark,
        systemNavigationBarContrastEnforced: false,
      ),
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        extendBody: true,
        extendBodyBehindAppBar: true,
        backgroundColor: Theme.of(context).brightness == Brightness.dark
            ? AppPalette.dark.scaffold
            : const Color(0xFFF5F7FA),
        body: NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            _handleScroll(notification);
            return false;
          },
          child: Stack(
            children: [
              SafeArea(
                top: false,
                bottom: false,
                child: PageView(
                  controller: _pageController,
                  physics: const NeverScrollableScrollPhysics(),
                  onPageChanged: (index) {
                    // 页面切换动画结束后才暂停/恢复视频（切换过程中继续播放）
                    _timetableKey.currentState
                        ?.onTabVisibilityChanged(index == 0);
                  },
                  children: _screens,
                ),
              ),
              // FAB - 只在课表页和待办页显示
              _buildFABWithAnimation(bottomPadding),
              // 「今」- 课表页浏览非本周时贴在 FAB 左侧
              _buildThisWeekButton(bottomPadding),
              Positioned(
                left: 0,
                right: 0,
                bottom: 15 + bottomPadding,
                child: Center(
                  child: _buildFloatingNavBar(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _loadWallpaperEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool('wallpaper_enabled') ?? false;
    final path = prefs.getString('wallpaper_path');
    final hasImage = path != null && path.isNotEmpty;
    final wallpaperEnabled = enabled && hasImage;
    if (mounted && _wallpaperEnabled != wallpaperEnabled) {
      setState(() {
        _wallpaperEnabled = wallpaperEnabled;
      });
    }
  }

  Widget _buildFABWithAnimation(double bottomPadding) {
    final bool shouldShow =
        (_currentIndex == 0 || _currentIndex == 1) && _fabVisible;

    return AnimatedPositioned(
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
      right: shouldShow ? 16 : -80,
      bottom: 100 + bottomPadding,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 350),
        opacity: shouldShow ? 1.0 : 0.0,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Stack(
              children: [
                if (_wallpaperEnabled)
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        color: AppColors.of(context)
                            .glassShell
                            .withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: const Color(0xFF4A90E2).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: _onFABPressed,
                      borderRadius: BorderRadius.circular(16),
                      child: const Center(
                        child:
                            Icon(Icons.add, color: Color(0xFF4A90E2), size: 28),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 「今」按钮：课表屏停在非本周时出现，点击回到本周（假期回假期页）。
  ///
  /// 显隐与 FAB 共用同一闸门（课表页 + FAB 未被滚动收起），避免滚动收起时
  /// 只剩一个孤立按钮；位置固定在 FAB 左侧（16 右边距 + 56 宽 + 12 间距），
  /// 出现/消失为淡入淡出 + 缩放（0.8 → 1.0），不参与位移。外观刻意与 FAB
  /// 逐项对齐（同一圆角/模糊/底色），两处样式若要改需同步。
  Widget _buildThisWeekButton(double bottomPadding) {
    final bool shouldShow =
        _currentIndex == 0 && _fabVisible && !_viewingThisWeek;

    return Positioned(
      right: 84,
      bottom: 100 + bottomPadding,
      child: AnimatedScale(
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
        scale: shouldShow ? 1.0 : 0.8,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
          opacity: shouldShow ? 1.0 : 0.0,
          child: IgnorePointer(
            ignoring: !shouldShow,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                child: Stack(
                  children: [
                    if (_wallpaperEnabled)
                      Positioned.fill(
                        child: Container(
                          decoration: BoxDecoration(
                            color: AppColors.of(context)
                                .glassShell
                                .withValues(alpha: 0.35),
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                      ),
                    Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        color: const Color(0xFF4A90E2).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () =>
                              _timetableKey.currentState?.goToThisWeek(),
                          borderRadius: BorderRadius.circular(16),
                          child: const Center(
                            child: Text(
                              '今',
                              style: TextStyle(
                                color: Color(0xFF4A90E2),
                                fontSize: 24,
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
      ),
    );
  }

  Widget _buildFloatingNavBar() {
    return AnimatedBuilder(
      animation: _navBarAnimation,
      builder: (context, child) {
        final t = _navBarAnimation.value;
        return Transform.translate(
          offset: Offset(0, (1 - t) * 100),
          // 外壳（毛玻璃）只位移、不参与淡出：Opacity 图层会隔离
          // BackdropFilter 的背景采样，包在外壳上时动画全程失去模糊
          // （Opacity(1.0) 被短路不建图层，静止时才恢复）。位移本身
          // 不影响背景采样，100px 足以把整条栏送出屏幕外
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: _navPadding),
            // 阴影须放在 ClipRRect 外层：裁剪会吃掉内部绘制的阴影，
            // 之前阴影在内部容器上实际从未显示
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(32),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(32),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                child: Container(
                  height: 64,
                  decoration: BoxDecoration(
                    color: AppColors.of(context).glassShell.withValues(
                        alpha: Theme.of(context).brightness == Brightness.dark
                            ? 0.55
                            : 0.45),
                    borderRadius: BorderRadius.circular(32),
                    border: Border.all(
                      color: AppColors.of(context).glassBorder,
                      width: 1.5,
                    ),
                  ),
                  // 淡出只作用于图标内容层，毛玻璃壳体全程保持
                  child: Opacity(
                    opacity: t,
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        );
      },
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedPositioned(
            duration:
                _isDragging ? Duration.zero : const Duration(milliseconds: 280),
            curve: const Cubic(0.34, 1.15, 0.64, 1.0),
            left: _getSliderLeft() + _dragOffset,
            child: AnimatedScale(
              scale: _pressedIndex == _currentIndex ? 1.10 : 1.0,
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              child: Container(
                width: _itemWidth,
                height: 52,
                decoration: BoxDecoration(
                  color: const Color(0xFF4A90E2).withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(26),
                ),
              ),
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 每项双图标：未选中描边 / 选中实底（系统导航栏惯例）。
              // 待办=任务清单，对话=自绘正圆气球（内置气泡均为圆角矩形
              // 或带加号，不够圆润），导入=向下箭头，设置=齿轮
              _buildNavItem(
                  0, Icons.calendar_month_outlined, Icons.calendar_month, '课表'),
              _buildNavItem(1, Icons.checklist_outlined, Icons.checklist, '待办'),
              _buildNavItem(
                2,
                Icons.chat_bubble_outline,
                Icons.chat_bubble,
                '对话',
                customIcon: (highlighted, color) =>
                    _RoundBubbleIcon(filled: highlighted, color: color),
              ),
              _buildNavItem(3, Icons.download_outlined, Icons.download, '导入'),
              _buildNavItem(4, Icons.settings_outlined, Icons.settings, '设置'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildNavItem(
    int index,
    IconData icon,
    IconData activeIcon,
    String label, {
    Widget Function(bool highlighted, Color color)? customIcon,
  }) {
    final isSelected = _currentIndex == index;

    if (isSelected) {
      return GestureDetector(
        onHorizontalDragStart: (_) {
          setState(() {
            _isDragging = true;
            _pressedIndex = index;
            _hoveredIndex = index;
          });
        },
        onHorizontalDragUpdate: (details) {
          setState(() {
            _dragOffset += details.delta.dx;
            const itemExtent = _itemWidth + _itemMargin * 2;
            final minDrag = -itemExtent * _currentIndex;
            final maxDrag = itemExtent * (4 - _currentIndex);
            _dragOffset = _dragOffset.clamp(minDrag, maxDrag);
            _hoveredIndex = _currentIndex + (_dragOffset / itemExtent).round();
            _hoveredIndex = _hoveredIndex!.clamp(0, 4);
          });
        },
        onHorizontalDragEnd: (_) {
          const itemExtent = _itemWidth + _itemMargin * 2;
          final targetIndex =
              _currentIndex + (_dragOffset / itemExtent).round();
          final newIndex = targetIndex.clamp(0, 4);
          if (newIndex != _currentIndex) {
            _onTabChanged(newIndex, withHaptic: true);
          }
          setState(() {
            _isDragging = false;
            _pressedIndex = null;
            _hoveredIndex = null;
            _dragOffset = 0;
          });
        },
        onTap: () => _onTabChanged(index, withHaptic: true),
        onTapDown: (_) {
          setState(() {
            _pressedIndex = index;
          });
        },
        onTapUp: (_) {
          setState(() {
            _pressedIndex = null;
          });
        },
        onTapCancel: () {
          setState(() {
            _pressedIndex = null;
          });
        },
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: _itemWidth + _itemMargin * 2,
          height: 64,
          child: Center(
            child: SizedBox(
              width: _itemWidth,
              height: 52,
              child: _buildAnimatedIcon(
                  icon, activeIcon, label, isSelected, _hoveredIndex == index,
                  customIcon: customIcon),
            ),
          ),
        ),
      );
    }

    return GestureDetector(
      onTap: () => _onTabChanged(index, withHaptic: true),
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: _itemWidth + _itemMargin * 2,
        height: 64,
        child: Center(
          child: SizedBox(
            width: _itemWidth,
            height: 52,
            child: _buildNavContent(icon, activeIcon, label, isSelected,
                _hoveredIndex == index && _isDragging,
                customIcon: customIcon),
          ),
        ),
      ),
    );
  }

  Widget _buildAnimatedIcon(
    IconData icon,
    IconData activeIcon,
    String label,
    bool isSelected,
    bool isHovered, {
    Widget Function(bool highlighted, Color color)? customIcon,
  }) {
    return AnimatedBuilder(
      animation: _iconController,
      builder: (context, child) {
        final bounceValue = TweenSequence<double>([
          TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.85), weight: 30),
          TweenSequenceItem(tween: Tween(begin: 0.85, end: 1.1), weight: 30),
          TweenSequenceItem(tween: Tween(begin: 1.1, end: 1.0), weight: 40),
        ]).evaluate(
            CurvedAnimation(parent: _iconController, curve: Curves.easeOut));

        final rotateValue = TweenSequence<double>([
          TweenSequenceItem(tween: Tween(begin: 0.0, end: -0.1), weight: 30),
          TweenSequenceItem(tween: Tween(begin: -0.1, end: 0.05), weight: 30),
          TweenSequenceItem(tween: Tween(begin: 0.05, end: 0.0), weight: 40),
        ]).evaluate(
            CurvedAnimation(parent: _iconController, curve: Curves.easeOut));

        return Transform.scale(
          scale: bounceValue,
          child: Transform.rotate(
            angle: rotateValue,
            child: child,
          ),
        );
      },
      child: _buildNavContent(icon, activeIcon, label, isSelected, isHovered,
          customIcon: customIcon),
    );
  }

  Widget _buildNavContent(
    IconData icon,
    IconData activeIcon,
    String label,
    bool isSelected,
    bool isHovered, {
    Widget Function(bool highlighted, Color color)? customIcon,
  }) {
    final isHighlighted = isHovered || (!_isDragging && isSelected);
    final highlightColor = isHighlighted
        ? const Color(0xFF4A90E2)
        : AppColors.of(context).textSecondary;
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // 选中（或拖动悬停预选）时切实底字形，未选中保持描边；
        // customIcon 优先（自绘图标自带描边/实底两态）
        if (customIcon != null)
          SizedBox(
            width: 24,
            height: 24,
            child: customIcon(isHighlighted, highlightColor),
          )
        else
          Icon(
            isHighlighted ? activeIcon : icon,
            size: 24,
            color: highlightColor,
          ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: isHighlighted
                ? const Color(0xFF4A90E2)
                : AppColors.of(context).textSecondary,
            fontWeight: isHighlighted ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ],
    );
  }
}

/// 自绘对话气球：轮廓取自 Material 字体 maps_ugc（0xe3ca）的真实字形
/// 外轮廓（fontTools 从 materialicons-regular.otf 提取，翻转 Y 并归一化），
/// 字形里自带的加号换成三个对话点：描边态轮廓线+实心点，
/// 实底态（选中）三点镂空。描边 2dp 与 M3 outlined 图标笔画一致。
class _RoundBubbleIcon extends StatelessWidget {
  final bool filled;
  final Color color;
  final double size;

  const _RoundBubbleIcon(
      {required this.filled, required this.color, this.size = 24});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _RoundBubblePainter(filled: filled, color: color),
    );
  }
}

class _RoundBubblePainter extends CustomPainter {
  final bool filled;
  final Color color;

  _RoundBubblePainter({required this.filled, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final balloon = _balloonPath(size.width, size.height);

    // 三个对话点：水平居中一排（替代 maps_ugc 字形自带的加号）
    final dotR = size.width * 0.055;
    final dots = Path()
      ..addOval(Rect.fromCircle(
          center: Offset(size.width * 0.34, size.height * 0.50), radius: dotR))
      ..addOval(Rect.fromCircle(
          center: Offset(size.width * 0.50, size.height * 0.50), radius: dotR))
      ..addOval(Rect.fromCircle(
          center: Offset(size.width * 0.66, size.height * 0.50), radius: dotR));

    if (filled) {
      // 实底态：三点从气球中镂空（真透明孔洞，透出胶囊底色）
      final path = Path.combine(PathOperation.difference, balloon, dots);
      canvas.drawPath(path, Paint()..color = color);
    } else {
      // 描边态：轮廓线 + 实心小点（同 sms_outlined 画法）
      canvas.drawPath(
        balloon,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round,
      );
      canvas.drawPath(dots, Paint()..color = color);
    }
  }

  /// maps_ugc 气球外轮廓：正圆（圆心 0.5,0.5 半径 0.416）在左下被尾巴
  /// 缺口打断——两条直线交汇于尾尖 (0.041, 0.959)，非凸出三角形。
  static Path _balloonPath(double w, double h) {
    return Path()
      ..moveTo(w * 0.5000, h * 0.0840)
      ..cubicTo(w * 0.2695, h * 0.0840, w * 0.0840, h * 0.2695, w * 0.0840,
          h * 0.5000)
      ..cubicTo(w * 0.0840, h * 0.5645, w * 0.0977, h * 0.6250, w * 0.1230,
          h * 0.6797)
      ..lineTo(w * 0.0410, h * 0.9590)
      ..lineTo(w * 0.3203, h * 0.8770)
      ..cubicTo(w * 0.3750, h * 0.9023, w * 0.4355, h * 0.9160, w * 0.5000,
          h * 0.9160)
      ..cubicTo(w * 0.7305, h * 0.9160, w * 0.9160, h * 0.7305, w * 0.9160,
          h * 0.5000)
      ..cubicTo(w * 0.9160, h * 0.2695, w * 0.7305, h * 0.0840, w * 0.5000,
          h * 0.0840)
      ..close();
  }

  @override
  bool shouldRepaint(_RoundBubblePainter oldDelegate) =>
      oldDelegate.filled != filled || oldDelegate.color != color;
}
