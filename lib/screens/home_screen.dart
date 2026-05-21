import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'timetable_screen.dart';
import 'heatmap_screen.dart';
import 'import_screen.dart';
import 'ai_assistant_screen.dart';
import 'settings_screen.dart';
import '../utils/storage.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  int _currentIndex = 0;
  int? _pressedIndex;
  int? _hoveredIndex;
  double _dragOffset = 0;
  bool _isDragging = false;
  
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
  bool _wallpaperEnabled = false;
  static const double _scrollThreshold = 50.0;
  
  static const double _itemWidth = 60.0;
  static const double _itemMargin = 2.0;
  static const double _navPadding = 16.0;

  @override
  void initState() {
    super.initState();
    _screens = [
      TimetableScreen(
        key: _timetableKey,
        onScrollDirectionChanged: _onScrollDirectionChanged,
      ),
      HeatmapScreen(key: _heatmapKey),
      AIAssistantScreen(
        key: _aiAssistantKey,
        onKeyboardShown: _onKeyboardShown,
        onKeyboardHidden: _onKeyboardHidden,
        onNavigateToSettings: () => _onTabChanged(4),
      ),
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
  }

  @override
  void dispose() {
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
    }
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
      _timetableKey.currentState?.refreshData();
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
  
  void _onKeyboardShown() {
    // Keep nav bar layout independent from keyboard state.
  }

  void _onKeyboardHidden() {
    // Keep nav bar layout independent from keyboard state.
  }
  
  void _onFABPressed() {
    if (_currentIndex == 0) {
      _timetableKey.currentState?.showAddOptions();
    } else if (_currentIndex == 1) {
      _heatmapKey.currentState?.showAddOptions();
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).viewPadding.bottom;
    
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
        systemStatusBarContrastEnforced: false,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarDividerColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.dark,
        systemNavigationBarContrastEnforced: false,
      ),
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        extendBody: true,
        extendBodyBehindAppBar: true,
        backgroundColor: const Color(0xFFF5F7FA),
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
                  children: _screens,
                ),
              ),
              // FAB - 只在课表页和DDL页显示
              _buildFABWithAnimation(bottomPadding),
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
    final bool shouldShow = (_currentIndex == 0 || _currentIndex == 1) && _fabVisible;
    
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
                        color: Colors.white.withValues(alpha: 0.35),
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
                        child: Icon(Icons.add, color: Color(0xFF4A90E2), size: 28),
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

  Widget _buildFloatingNavBar() {
    return AnimatedBuilder(
      animation: _navBarAnimation,
      builder: (context, child) {
        return Transform.translate(
          offset: Offset(0, (1 - _navBarAnimation.value) * 100),
          child: Opacity(
            opacity: _navBarAnimation.value,
            child: child,
          ),
        );
      },
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: _navPadding),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(32),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 25, sigmaY: 25),
            child: Container(
              height: 64,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(32),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.6),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.06),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  AnimatedPositioned(
                    duration: _isDragging ? Duration.zero : const Duration(milliseconds: 280),
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
                      _buildNavItem(0, Icons.calendar_today_outlined, '课表'),
                      _buildNavItem(1, Icons.local_fire_department_outlined, 'DDL'),
                      _buildNavItem(2, Icons.chat_bubble_outline, '对话'),
                      _buildNavItem(3, Icons.file_upload_outlined, '导入'),
                      _buildNavItem(4, Icons.settings_outlined, '设置'),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem(int index, IconData icon, String label) {
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
          final targetIndex = _currentIndex + (_dragOffset / itemExtent).round();
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
              child: _buildAnimatedIcon(icon, label, isSelected, _hoveredIndex == index),
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
            child: _buildNavContent(icon, label, isSelected, _hoveredIndex == index && _isDragging),
          ),
        ),
      ),
    );
  }

  Widget _buildAnimatedIcon(IconData icon, String label, bool isSelected, bool isHovered) {
    return AnimatedBuilder(
      animation: _iconController,
      builder: (context, child) {
        final bounceValue = TweenSequence<double>([
          TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.85), weight: 30),
          TweenSequenceItem(tween: Tween(begin: 0.85, end: 1.1), weight: 30),
          TweenSequenceItem(tween: Tween(begin: 1.1, end: 1.0), weight: 40),
        ]).evaluate(CurvedAnimation(parent: _iconController, curve: Curves.easeOut));
        
        final rotateValue = TweenSequence<double>([
          TweenSequenceItem(tween: Tween(begin: 0.0, end: -0.1), weight: 30),
          TweenSequenceItem(tween: Tween(begin: -0.1, end: 0.05), weight: 30),
          TweenSequenceItem(tween: Tween(begin: 0.05, end: 0.0), weight: 40),
        ]).evaluate(CurvedAnimation(parent: _iconController, curve: Curves.easeOut));
        
        return Transform.scale(
          scale: bounceValue,
          child: Transform.rotate(
            angle: rotateValue,
            child: child,
          ),
        );
      },
      child: _buildNavContent(icon, label, isSelected, isHovered),
    );
  }

  Widget _buildNavContent(IconData icon, String label, bool isSelected, bool isHovered) {
    final isHighlighted = isHovered || (!_isDragging && isSelected);
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(
          icon,
          size: 24,
          color: isHighlighted ? const Color(0xFF4A90E2) : Colors.grey.shade700,
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: isHighlighted ? const Color(0xFF4A90E2) : Colors.grey.shade700,
            fontWeight: isHighlighted ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ],
    );
  }
}
