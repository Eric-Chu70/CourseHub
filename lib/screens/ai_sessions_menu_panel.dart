import 'package:flutter/material.dart';
import 'dart:ui';
import 'package:intl/intl.dart';
import '../utils/storage.dart';
import '../widgets/glass_dialog.dart';
import '../widgets/toast_notification.dart';
import '../widgets/app_text_field.dart';
import '../widgets/blur_selection_menu.dart';
import '../widgets/keyboard_keeper.dart';

/// 已保存会话下拉菜单面板（自 AI 页顶栏向左下弹出）。
/// 样式区别于通用弹窗：毛玻璃 + 白色高光描边；弹出为 easeOutBack
/// 过冲缩放（Q 弹）+ 位移淡入 + 内容由模糊渐清晰，收起时缩放回缩、
/// 模糊"向内化开"后再淡出。
///
/// 注意：BackdropFilter 不能被 Opacity 包裹（会采样到透明黑导致面板
/// 发黑），因此外壳不做整体透明度动画——改为动画化模糊 sigma、背景/
/// 描边 alpha 与内容透明度。会话数据自持，重命名/删除后自行刷新；
/// 条目的三点子菜单也在本浮层 Stack 内渲染（Navigator 路由会在根
/// Overlay 之下，无法盖住本面板）。
class SavedSessionsMenuHost extends StatefulWidget {
  const SavedSessionsMenuHost({
    super.key,
    required this.animation,
    required this.currentSessionId,
    required this.onDismiss,
    required this.onLoadSession,
    required this.onRenamed,
    required this.onDeleted,
  });

  /// 父级持有并驱动 reverse（收起动画完成后父级移除浮层）
  final Animation<double> animation;
  /// 当前对话对应的会话 id（在列表中高亮显示）
  final String? currentSessionId;
  final void Function([VoidCallback? then]) onDismiss;
  final void Function(Map<String, dynamic> session) onLoadSession;
  final void Function(String id, String newTitle) onRenamed;
  final void Function(String id) onDeleted;

  @override
  State<SavedSessionsMenuHost> createState() => _SavedSessionsMenuHostState();
}

class _SavedSessionsMenuHostState extends State<SavedSessionsMenuHost>
    with TickerProviderStateMixin {
  static const double _itemHeight = 64.0;
  static const int _maxVisible = 5;
  static const double _itemMenuWidth = 120.0;
  static const double _itemMenuRowHeight = 44.0;

  List<Map<String, dynamic>> _sessions = [];
  bool _closing = false;

  // 条目三点子菜单（本 Stack 内渲染，最多同时一个）
  int? _itemMenuIndex;
  /// 命中三点时记录的图标屏上位置（本 Stack 本地坐标）。列表条数超过
  /// _maxVisible 可上下滚动，行内 index 推不出真实位置（滚动后按
  /// index 定位会向下错位一格），必须以实际渲染盒锚定
  Rect? _itemMenuAnchor;
  bool _itemMenuOpen = false;
  AnimationController? _itemMenuController;
  CurvedAnimation? _itemMenuCurved;

  // 内联重命名（参考课表切换器：行内编辑框 + 三点/勾勾切换）
  int? _editingIndex;
  TextEditingController? _editController;
  FocusNode? _editFocusNode;
  // 已退场、等待淡出动画播完后释放的焦点节点（防重复 dispose）
  final Set<FocusNode> _retiredEditFocusNodes = {};
  // 焦点守卫监听（节点 → 监听回调），退场时移除
  final Map<FocusNode, VoidCallback> _focusGuardListeners = {};
  /// 焦点守卫（编辑期持续武装）：进入编辑后焦点被意外抢走（面板重建、
  /// 框架内隐式 unfocus 等）自动抢回，键盘弹出后不再"秒收"。
  /// 用户主动转移焦点的入口显式解除：
  /// - 点按任一行三点（_openItemMenu，键盘随菜单打开正常收起）
  /// - 勾勾提交/失焦退出编辑（_exitEditMode，编辑态本身结束）
  /// - 面板整体收起（barrier onTap 先走 _exitEditMode）
  bool _focusGuardActive = false;
  /// 键盘守护：自愈"焦点在但键盘连接被框架重建销毁"的键盘消失
  KeyboardKeeper? _keyboardKeeper;
  // 删除确认（内嵌于面板 Stack 的自持层，不走路由——非路由面板条目
  // 压不到 Navigator 推入的对话框路由）
  AnimationController? _deleteConfirmController;
  String? _deleteId;
  String? _deleteTitle;
  bool _deleteConfirmReduceMotion = false;
  // 收起中标志：遮罩 onTap 与壳内透明层 onTap 会在同帧双触发关闭，
  // 二次进入直接返回，避免 whenCompleteOrCancel 注册两次导致
  // controller 二次 dispose
  bool _deleteConfirmClosing = false;
  // 行退场动画（会话 id → 控制器，总时长 420ms 两阶段，对齐课表切换器
  // 的删除课表动画）：先 vanish（前 220ms easeInCubic）——被删行原地
  // 模糊增大 + 向自身中心点坍缩缩小 + 淡出，占位高度不变；再 collapse
  //（后 200ms easeOutCubic，与 easeInCubic 收尾速度衔接连续）——占位
  // 高度塌缩，下方行平滑上移补位、面板高度同步收缩；全部播完才真正
  // 从数据中移除，避免列表瞬间重排
  final Map<String, AnimationController> _removingRows = {};

  // 单控制器映射两阶段进度：value * 420 = 已播毫秒数
  double _vanishT(AnimationController c) => Curves.easeInCubic
      .transform(((c.value * 420) / 220).clamp(0.0, 1.0));
  double _collapseT(AnimationController c) => Curves.easeOutCubic
      .transform(((c.value * 420 - 220) / 200).clamp(0.0, 1.0));

  @override
  void initState() {
    super.initState();
    _sessions = StorageService.getChatSessions();
  }

  @override
  void dispose() {
    final current = _editFocusNode;
    if (current != null) {
      final listener = _focusGuardListeners.remove(current);
      if (listener != null) current.removeListener(listener);
      current.dispose();
    }
    _itemMenuCurved?.dispose();
    _itemMenuController?.dispose();
    for (final controller in _removingRows.values) {
      controller.dispose();
    }
    _removingRows.clear();
    _deleteConfirmController?.dispose();
    super.dispose();
  }

  void _reloadList() {
    _sessions = StorageService.getChatSessions();
  }

  void _close([VoidCallback? then]) {
    if (_closing) return;
    _closing = true;
    widget.onDismiss(then);
  }

  // ==================== 条目三点子菜单 ====================

  void _toggleItemMenu(int index, BuildContext anchorContext) {
    if (_itemMenuOpen && _itemMenuIndex == index) {
      _closeItemMenu();
      return;
    }
    _captureMenuAnchor(anchorContext);
    _openItemMenu(index);
  }

  /// 记录三点图标的真实屏上位置：localToGlobal 已把列表滚动位移与
  /// 面板入场变换计入，转回本 Stack 本地坐标后供子菜单定位。
  /// 紧随其后的 _openItemMenu 会触发重建，这里无需 setState
  void _captureMenuAnchor(BuildContext anchorContext) {
    final anchorBox = anchorContext.findRenderObject();
    final stackBox = context.findRenderObject();
    if (anchorBox is! RenderBox ||
        stackBox is! RenderBox ||
        !anchorBox.attached ||
        !anchorBox.hasSize ||
        !stackBox.attached) {
      return;
    }
    _itemMenuAnchor =
        stackBox.globalToLocal(anchorBox.localToGlobal(Offset.zero)) &
            anchorBox.size;
  }

  void _openItemMenu(int index) {
    // 打开三点菜单时解除焦点守卫：若正处于编辑态，让键盘随焦点被
    // 菜单锚点收起（与课表切换器一致），选择重命名后再聚焦新编辑框
    _focusGuardActive = false;
    // 快速切换锚点时直接销毁旧菜单（无收起动画，保持跟手）
    _itemMenuCurved?.dispose();
    _itemMenuController?.dispose();
    final controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      reverseDuration: const Duration(milliseconds: 200),
    );
    final curved = CurvedAnimation(
      parent: controller,
      curve: Curves.easeOutBack,
      reverseCurve: Curves.easeInCubic,
    );
    setState(() {
      _itemMenuIndex = index;
      _itemMenuOpen = true;
      _itemMenuController = controller;
      _itemMenuCurved = curved;
    });
    controller.forward();
  }

  Future<void> _closeItemMenu() async {
    if (!_itemMenuOpen) return;
    _itemMenuOpen = false;
    final controller = _itemMenuController;
    final curved = _itemMenuCurved;
    if (controller == null) {
      if (mounted) {
        setState(() => _itemMenuIndex = null);
      }
      return;
    }
    await controller.reverse();
    if (!mounted) return;
    setState(() {
      if (_itemMenuController == controller) {
        _itemMenuController = null;
        _itemMenuCurved = null;
        _itemMenuIndex = null;
      }
    });
    curved?.dispose();
    controller.dispose();
  }

  // ==================== 内联重命名 ====================

  void _startInlineRename(int index) {
    if (index >= _sessions.length) return;
    // 旧编辑框是 AnimatedSwitcher 的出场子项，还会挂 ~220ms 播淡出动画：
    // controller/焦点节点不能同步释放，延迟到动画播完再清（保留前一行的淡出）
    _retireEditFocusNode(_editFocusNode);
    _editController = null;
    final controller = TextEditingController(
      text: (_sessions[index]['title'] as String?) ?? '',
    );
    final focusNode = FocusNode(debugLabel: 'sessionRename');
    // 子菜单控制器不能在这里 dispose：_closeItemMenu 的收尾（reverse 完成后）
    // 会释放它们，这里只把字段置空避免其 setState 再触发重建
    setState(() {
      _itemMenuController = null;
      _itemMenuCurved = null;
      _itemMenuIndex = null;
      _itemMenuOpen = false;
      _editController = controller;
      _editFocusNode = focusNode;
      _editingIndex = index;
    });
    _installFocusGuard(focusNode, index);
    // 武装焦点守卫（编辑期持续有效）：进入编辑后短时间内焦点被抢
    // （路由 pop 恢复、面板重建等）自动抢回，键盘弹出后不再秒收；
    // 点按任一行三点菜单时由 _openItemMenu 显式解除
    _focusGuardActive = true;
    // 武装键盘守护：键盘弹出过程的框架重建可能把刚拿到焦点的
    // EditableText 连同存活连接一起销毁重建（新 State 继承焦点却不会
    // 重开连接 → 键盘消失且守卫无感知），窗口内检测到"焦点在键盘没了"
    // 就强制重开连接
    _keyboardKeeper?.dispose();
    _keyboardKeeper = KeyboardKeeper(
      isFocused: () => mounted && _editingIndex == index && focusNode.hasFocus,
      refocus: () {
        focusNode.unfocus();
        // 必须隔帧再聚焦：同帧 unfocus+requestFocus 会被框架合并成一次
        // 焦点应用（起止相同=无变化事件），EditableText 不会重开连接
        WidgetsBinding.instance.addPostFrameCallback((_) {
          focusNode.requestFocus();
        });
      },
    )..arm(context);
    // 主动聚焦闪烁光标：Overlay 内 autofocus 不够可靠，用户需看到光标
    // 才知道该行进入了编辑态
    WidgetsBinding.instance.addPostFrameCallback((_) {
      focusNode.requestFocus();
    });
  }

  /// 焦点守卫：编辑期间焦点被意外抢走时自动抢回（对抗键盘弹出后又
  /// 自动收起）；用户主动意图（打开其他三点菜单、提交/退出编辑）会
  /// 显式解除守卫，不在此处争夺。
  void _installFocusGuard(FocusNode node, int index) {
    void listener() {
      if (!mounted || _editFocusNode != node || _editingIndex != index) return;
      if (node.hasFocus) return;
      if (!_focusGuardActive) return;
      // 节点已从树上摘除（面板正在关闭等）时不抢
      if (node.context == null) return;
      Future.delayed(const Duration(milliseconds: 60), () {
        if (!mounted || _editFocusNode != node || _editingIndex != index) return;
        if (node.hasFocus) return;
        if (!_focusGuardActive) return;
        if (node.context == null) return;
        node.requestFocus();
      });
    }

    node.addListener(listener);
    _focusGuardListeners[node] = listener;
  }

  /// 焦点节点延迟释放：等出场动画播完后 dispose（TextEditingController
  /// 无原生资源，交给 GC 即可）
  void _retireEditFocusNode(FocusNode? node) {
    if (node == null || _retiredEditFocusNodes.contains(node)) return;
    final listener = _focusGuardListeners.remove(node);
    if (listener != null) node.removeListener(listener);
    _retiredEditFocusNodes.add(node);
    Future.delayed(const Duration(milliseconds: 400), () {
      node.dispose();
      _retiredEditFocusNodes.remove(node);
    });
  }

  void _exitEditMode() {
    // 编辑态结束，守卫随编辑态一并解除（焦点不再被抢回）
    _focusGuardActive = false;
    _keyboardKeeper?.dispose();
    _keyboardKeeper = null;
    FocusManager.instance.primaryFocus?.unfocus();
    _retireEditFocusNode(_editFocusNode);
    _editFocusNode = null;
    _editController = null;
    if (_editingIndex != null) {
      setState(() => _editingIndex = null);
    }
  }

  Future<void> _commitInlineRename() async {
    final index = _editingIndex;
    if (index == null || index >= _sessions.length) return;
    final session = _sessions[index];
    final id = session['id']?.toString() ?? '';
    final newTitle = _editController?.text.trim() ?? '';
    final oldTitle = (session['title'] as String?) ?? '未命名对话';
    _exitEditMode();
    if (id.isEmpty || newTitle.isEmpty || newTitle == oldTitle) return;
    final stored = StorageService.getChatSession(id);
    if (stored == null) return;
    stored['title'] = newTitle;
    await StorageService.saveChatSession(stored);
    widget.onRenamed(id, newTitle);
    if (!mounted) return;
    setState(_reloadList);
    toastNotification.show(context, '已重命名：$newTitle');
  }

  // ==================== build ====================

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final menuWidth = (mq.size.width * 2 / 3).clamp(240.0, 380.0);
    final panelTop = mq.padding.top + 60.0;
    final double contentHeight;
    if (_sessions.isEmpty) {
      contentHeight = 96;
    } else {
      contentHeight =
          (_sessions.length > _maxVisible ? _maxVisible : _sessions.length) * _itemHeight + 16;
    }

    return Stack(
      children: [
          // 全屏透明屏障：先收起子菜单/编辑态，再次点击才以收起动画关闭面板
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                if (_itemMenuOpen) {
                  _closeItemMenu();
                } else if (_editingIndex != null) {
                  _exitEditMode();
                } else {
                  _close();
                }
              },
              child: const SizedBox.expand(),
            ),
          ),
          Positioned(
            top: panelTop,
            right: 48,
            // 屏蔽层必须始终以同一类型存在于树中：之前"菜单开着才包
            // GestureDetector"的条件写法会在进编辑态的同一帧改变子树
            // 层级，面板整棵重挂，AnimatedSwitcher 的入场动画全部丢失。
            // 现在恒定包裹：子菜单打开时 AbsorbPointer 吸收面板内命中、
            // 仅由本层 onTap 收起子菜单；关闭时完全透传。
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _itemMenuOpen ? _closeItemMenu : null,
              child: AbsorbPointer(
                absorbing: _itemMenuOpen,
                child: _buildAnimatedPanel(menuWidth, contentHeight),
              ),
            ),
          ),
          if (_itemMenuController != null && _itemMenuIndex != null)
            _buildPositionedItemMenu(panelTop),
          // 删除确认层：内嵌于面板 Stack（层级恒定在行与面板之上），
          // 自带全屏遮罩——遮罩把面板与背景一起统一压暗，点击遮罩
          // 关闭确认；不再走路由对话框（非路由面板条目压不到路由）。
          if (_deleteConfirmController != null && _deleteId != null)
            ..._buildDeleteConfirm(),
      ],
    );
  }

  /// 删除确认层：遮罩（点击关闭）+ BouncyDialogHost 果冻确认卡片。
  /// BouncyDialogHost 的遮罩本身 IgnorePointer，穿透到下方我们自己的
  /// 遮罩 GestureDetector 上统一处理关闭。
  List<Widget> _buildDeleteConfirm() {
    return [
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _closeDeleteConfirm(),
          child: const SizedBox.expand(),
        ),
      ),
      Positioned.fill(
        child: BouncyDialogHost(
          animation: _deleteConfirmController!,
          shellPadding: EdgeInsets.zero,
          shellBoxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.2),
              blurRadius: 20,
              offset: const Offset(0, 10),
            ),
          ],
          reduceMotion: _deleteConfirmReduceMotion,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 340),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(Icons.delete_outline,
                        color: Colors.red, size: 28),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    '删除会话',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '确定要删除"${_deleteTitle}"吗？\n删除后无法恢复。',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: () => _closeDeleteConfirm(),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: BorderSide(color: Colors.grey.shade300),
                            ),
                          ),
                          child: const Text('取消'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () => _closeDeleteConfirm(confirmed: true),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: const Text('删除'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ];
  }

  /// 子菜单定位：以命中时记录的三点真实屏上位置（_itemMenuAnchor）
  /// 锚定所在行下方右侧；底部空间不足时改为行上方。
  /// 列表可上下滚动（条数超过 _maxVisible），按 index 估算会在滚动后
  /// 向下错位一格，故必须用实际渲染盒位置。
  Widget _buildPositionedItemMenu(double panelTop) {
    final mq = MediaQuery.of(context);
    const menuHeight = _itemMenuRowHeight * 2 + 8;
    final anchor = _itemMenuAnchor;
    if (anchor == null) {
      // 理论上不可达（命中时渲染盒必已布局）；兜底退化为 index 估算
      final index = _itemMenuIndex ?? 0;
      final fallbackRowBottom = panelTop + 8 + (index + 1) * _itemHeight + 4;
      var fallbackTop = fallbackRowBottom;
      if (fallbackTop + menuHeight > mq.size.height - 16) {
        fallbackTop = panelTop + 8 + index * _itemHeight - 4 - menuHeight;
      }
      fallbackTop = fallbackTop.clamp(8.0, mq.size.height - menuHeight - 8);
      return Positioned(top: fallbackTop, right: 54, child: _buildItemMenu());
    }
    // 三点图标在行内垂直居中：由图标中心反推行上下沿，与行的间距
    // 保持原样（行底 +4 / 行顶 -4）
    final rowTop = anchor.center.dy - _itemHeight / 2;
    final rowBottom = rowTop + _itemHeight;
    var top = rowBottom + 4;
    if (top + menuHeight > mq.size.height - 16) {
      top = rowTop - 4 - menuHeight;
    }
    top = top.clamp(8.0, mq.size.height - menuHeight - 8);
    return Positioned(top: top, right: 54, child: _buildItemMenu());
  }

  // ==================== 面板（毛玻璃 + 高光描边） ====================

  Widget _buildAnimatedPanel(double width, double contentHeight) {
    return AnimatedBuilder(
      animation: widget.animation,
      builder: (context, child) {
        // 不做 clamped>=1 的裸子树切换：入场曲线带过冲（t 短暂 >1，
        // "超出收回"的 Q 弹感），且结构一旦切换会把整个面板子树连同
        // 刚拿到焦点的 EditableText 销毁重建——活连接被 clearClient
        // 收掉键盘，新 State 继承焦点却不会重开（首次进入编辑键盘
        // 闪现的根因）。包裹层恒定存在，动画仅驱动参数。
        final t = widget.animation.value;
        return Transform.translate(
          // 弹出方向：自锚点向左下落位；t>1 时自然反向过冲再收回
          offset: Offset(20 * (1 - t), -16 * (1 - t)),
          child: Transform.scale(
            // 锚定右上角缩放；过冲曲线令缩放短暂超出 1.0 后回弹
            alignment: Alignment.topRight,
            scale: 0.82 + 0.18 * t,
            child: child,
          ),
        );
      },
      child: _buildPanel(width, contentHeight),
    );
  }

  Widget _buildPanel(double width, double contentHeight) {
    // 高度驱动：入场动画 + 全部退场中的行控制器。退场 tick 时重算
    // 塌缩后的高度，面板底边与行塌缩逐帧同步
    final driver = _removingRows.isEmpty
        ? widget.animation
        : Listenable.merge([widget.animation, ..._removingRows.values]);
    return AnimatedBuilder(
      animation: driver,
      builder: (context, _) {
        final clamped = widget.animation.value.clamp(0.0, 1.0);
        // 所有滤镜/透明度在前 60% 进度内完成：最后几帧与成型面板完全
        // 一致（仅剩 easeOutBack 的缩放回弹），消除收尾衔接跳变。
        // ImageFiltered 只包内容不包外壳（外壳含 BackdropFilter，被
        // 包裹时采样异常且移除瞬间会跳变）；Opacity 同理不包外壳。
        final settle = (clamped / 0.6).clamp(0.0, 1.0);
        // 退场行占位塌缩量（与行 collapse 阶段同曲线同帧）：vanish 阶段
        //（前 220ms）面板高度不动，collapse 阶段逐帧同步收缩。塌缩量按
        // "已塌缩行数 × 行高"累计，并以 (基础高度 - 目标高度) 封顶：
        // 列表被 _maxVisible 封顶时（会话数超上限）删行不改变目标高度，
        // 塌缩量为 0，被裁剪的下行自然滚入补位；删光全部会话时目标为
        // 空态 96（大于 1 行高度，塌缩量 0、残余变化交给补间）。退场
        // 结束移除数据后基础高度变小、塌缩量归零，二者相抵高度连续
        var removalDelta = 0.0;
        if (_removingRows.isNotEmpty) {
          var collapsedRows = 0.0;
          for (final controller in _removingRows.values) {
            collapsedRows += _collapseT(controller);
          }
          final targetCount = _sessions.length - _removingRows.length;
          final targetHeight = targetCount <= 0
              ? 96.0
              : (targetCount > _maxVisible
                      ? _maxVisible
                      : targetCount) *
                      _itemHeight +
                  16;
          final maxDelta = contentHeight - targetHeight;
          removalDelta = (collapsedRows * _itemHeight)
              .clamp(0.0, maxDelta < 0 ? 0.0 : maxDelta);
        }
        final effectiveHeight =
            (contentHeight - removalDelta).clamp(0.0, double.infinity);
        return TweenAnimationBuilder<double>(
          tween: Tween<double>(end: effectiveHeight),
          duration: _removingRows.isEmpty
              ? const Duration(milliseconds: 250)
              : Duration.zero,
          curve: Curves.easeInOutCubic,
          builder: (context, animatedHeight, child) => Container(
            width: width,
            height: animatedHeight,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.16 * settle),
                  blurRadius: 28,
                  offset: const Offset(0, 14),
                ),
              ],
            ),
            child: child!,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: BackdropFilter(
              // 模糊随弹出渐强/收起时"向内化开"；不用 Opacity 包裹
              // BackdropFilter（会采样到透明黑使面板发黑）。
              // sigma 取较小值：过大时背景文字被强烈糊化反而显黑
              filter: ImageFilter.blur(
                sigmaX: 10 * settle,
                sigmaY: 10 * settle,
              ),
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.white.withValues(alpha: 0.42 * settle),
                      Colors.white.withValues(alpha: 0.26 * settle),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.7 * settle),
                    width: 1.2,
                  ),
                ),
                child: Material(
                  color: Colors.transparent,
                  child: Opacity(
                    opacity: settle,
                    child: _buildList(),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildList() {
    if (_sessions.isEmpty) {
      return Center(
        child: Text(
          '暂无保存的会话',
          style: TextStyle(fontSize: 13, color: Colors.grey.shade500),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      // 超出范围上下滑动带回弹；面板外壳高度由退场塌缩量逐帧驱动，
      // 视口有界，内容不足一屏也可拖动回弹
      physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
      itemCount: _sessions.length,
      // 分隔线随被删行一同塌缩（collapse 阶段）：中间行退场带其上方的
      // 线（index+1 行退场 → 该线塌缩）；首行退场上方无线、改为带下方
      // 第一条线，避免行塌缩完成后残留一条多余细线
      separatorBuilder: (context, index) {
        final divider = Container(
          height: 0.5,
          margin: const EdgeInsets.symmetric(horizontal: 16),
          color: Colors.grey.shade300,
        );
        var collapseCtrl = index + 1 < _sessions.length
            ? _removingRows[_sessions[index + 1]['id']?.toString() ?? '']
            : null;
        if (collapseCtrl == null && index == 0 && _sessions.isNotEmpty) {
          collapseCtrl =
              _removingRows[_sessions[0]['id']?.toString() ?? ''];
        }
        final ctrl = collapseCtrl;
        if (ctrl == null) return divider;
        return AnimatedBuilder(
          animation: ctrl,
          builder: (context, child) {
            final t = _collapseT(ctrl);
            return Align(
              heightFactor: 1.0 - t,
              child: child,
            );
          },
          child: divider,
        );
      },
      itemBuilder: (context, index) => _buildSessionItem(_sessions[index], index),
    );
  }

  Widget _buildSessionItem(Map<String, dynamic> session, int index) {
    final id = session['id']?.toString() ?? '';
    final isCurrent = widget.currentSessionId != null && widget.currentSessionId == id;
    final isEditing = _editingIndex == index;
    final title = (session['title'] as String?) ?? '未命名对话';
    final savedAt =
        DateTime.tryParse(session['savedAt']?.toString() ?? '') ?? DateTime.now();
    final messageCount = (session['messages'] as List?)?.length ?? 0;
    final subtitle =
        '${DateFormat('M月d日 HH:mm').format(savedAt)} · $messageCount 条消息';

    final row = SizedBox(
      height: _itemHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        // GestureDetector 包裹整块底板矩形（标题区+三点槽位）：
        // 深色选中矩形的整个区域点按都加载会话；仅三点图标近旁的
        // 子识别器（更深层）弹出条目菜单，勾勾（编辑态）优先提交
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // 编辑态不拦截：输入框自身的点击手势需要生效。
          // 立即加载会话（不等面板收起动画），点按体感即时
          onTap: isEditing
              ? null
              : () {
                  widget.onLoadSession(session);
                  _close();
                },
          child: Container(
            // 当前正在聊天的会话：圆角矩形深色底层遮罩
            decoration: isCurrent
                ? BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(12),
                  )
                : null,
            child: Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 8, right: 4),
                    child: SizedBox(
                      height: double.infinity,
                      // 标题 ↔ 编辑框 morph（与课表切换器同款）：提交/切换
                      // 时旧编辑框模糊淡出、新内容模糊淡入（与入场对称）。
                      // 退场动画期间旧编辑框多挂 ~220ms：其连接在焦点转移
                      // 时（勾勾提交先 unfocus；切换时新框 postFrame 抢焦）
                      // 即已关闭，退场 dispose 不会发送 clearClient 收走
                      // 新键盘；万一有时序抖动，KeyboardKeeper 会在窗口内
                      // 把键盘拉回
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 220),
                        switchInCurve: Curves.easeOut,
                        switchOutCurve: Curves.easeIn,
                        transitionBuilder: (child, animation) =>
                            blurredMorphTransition(
                          child,
                          animation,
                          alignment: Alignment.centerLeft,
                        ),
                        layoutBuilder: (currentChild, previousChildren) => Stack(
                          alignment: Alignment.centerLeft,
                          children: [
                            ...previousChildren,
                            if (currentChild != null) currentChild,
                          ],
                        ),
                        child: isEditing
                            ? SizedBox(
                                key: const ValueKey('edit'),
                                width: double.infinity,
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: _buildEditField(),
                                ),
                              )
                            : SizedBox(
                                key: const ValueKey('title'),
                                width: double.infinity,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text(
                                      title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                        color: Color(0xFF1A1A2E),
                                      ),
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      subtitle,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.grey.shade500,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                      ),
                    ),
                  ),
                ),
                // 三点 ↔ 勾勾：等尺寸槽位（40x40），morph 后位置不偏移。
                // 三点菜单触发区缩到图标近旁（24x24 居中）：整块深色底板
                // 矩形（含槽位空白、标题上下空白）点按都加载会话，只有
                // 贴近三点图标本身才弹出菜单；勾勾（编辑态提交）保持
                // 40x40 大热区（编辑态下行的点击手势本就不拦截）
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  switchInCurve: Curves.easeOut,
                  switchOutCurve: Curves.easeIn,
                  transitionBuilder: blurredMorphTransition,
                  child: isEditing
                      ? GestureDetector(
                          key: const ValueKey('check'),
                          behavior: HitTestBehavior.opaque,
                          onTap: _commitInlineRename,
                          child: const SizedBox(
                            width: 40,
                            height: 40,
                            child: Icon(Icons.check, size: 22, color: Colors.black),
                          ),
                        )
                      : SizedBox(
                          key: const ValueKey('menu'),
                          width: 40,
                          height: 40,
                          child: Center(
                            // Builder 提供三点自身的 context：命中时取其
                            // 渲染盒作为菜单锚点（列表可滚动，index 推
                            // 不出真实屏上位置，见 _captureMenuAnchor）
                            child: Builder(
                              builder: (anchorContext) => GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () =>
                                    _toggleItemMenu(index, anchorContext),
                                child: SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: Icon(
                                    Icons.more_vert,
                                    size: 18,
                                    color: _itemMenuOpen &&
                                            _itemMenuIndex == index
                                        ? Colors.black
                                        : Colors.grey.shade500,
                                  ),
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
    );

    // 退场中（对齐课表切换器删除动画）：vanish 阶段占位高度不变，
    // 行内容向自身中心点坍缩——模糊增大 + 缩小 + 淡出；collapse 阶段
    // 占位高度塌缩（heightFactor），下方行逐帧上移补位。
    // IgnorePointer 让退场行不可再交互
    final removalCtrl = _removingRows[id];
    if (removalCtrl == null) return row;
    return AnimatedBuilder(
      animation: removalCtrl,
      builder: (context, child) {
        final vanishT = _vanishT(removalCtrl);
        final collapseT = _collapseT(removalCtrl);
        return IgnorePointer(
          child: Align(
            heightFactor: 1.0 - collapseT,
            child: Opacity(
              opacity: (1.0 - vanishT).clamp(0.0, 1.0),
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(
                  sigmaX: 14 * vanishT,
                  sigmaY: 14 * vanishT,
                ),
                child: Transform.scale(
                  // 默认中心对齐：向行自身中心点坍缩
                  scale: 1.0 - 0.45 * vanishT,
                  child: child,
                ),
              ),
            ),
          ),
        );
      },
      child: row,
    );
  }

  /// 内联重命名编辑框：纯通透（无底板无边框），左对齐标题文本位置。
  /// 必须显式 filled:false——全局 inputDecorationTheme 默认 grey50 填充
  Widget _buildEditField() {
    return AppTextField(
      contextMenuBuilder: styledEditableContextMenu,
      controller: _editController!,
      focusNode: _editFocusNode,
      autofocus: true,
      style: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: Color(0xFF1A1A2E),
      ),
      decoration: const InputDecoration(
        isDense: true,
        filled: false,
        contentPadding: EdgeInsets.zero,
        border: InputBorder.none,
        hintText: '输入新的会话标题',
      ),
      onSubmitted: (_) => _commitInlineRename(),
    );
  }

  /// 条目三点子菜单：与统一样式下拉菜单同款毛玻璃壳，
  /// easeOutBack 自锚点弹出 / easeInCubic 缩回锚点。
  /// 同面板：模糊 sigma 与内容透明度分开动画，避免 Opacity
  /// 包裹 BackdropFilter 采样到透明黑发黑。
  Widget _buildItemMenu() {
    return AnimatedBuilder(
      animation: _itemMenuController!,
      builder: (context, _) {
        final t = _itemMenuCurved?.value ?? 0.0;
        final clamped = t.clamp(0.0, 1.0);
        return Transform.translate(
          offset: Offset(0, -14 * (1 - t)),
          child: Transform.scale(
            alignment: Alignment.topRight,
            scale: 0.85 + 0.15 * t,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.15 * clamped),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: BackdropFilter(
                  filter: ImageFilter.blur(
                    sigmaX: 14 * clamped,
                    sigmaY: 14 * clamped,
                  ),
                  child: Container(
                    width: _itemMenuWidth,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.8 * clamped),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.5 * clamped),
                        width: 0.5,
                      ),
                    ),
                    child: Material(
                      color: Colors.transparent,
                      child: Opacity(
                        opacity: clamped,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildItemMenuRow(
                        icon: Icons.edit_outlined,
                        label: '重命名',
                        color: const Color(0xFF4A90E2),
                        labelColor: const Color(0xFF333333),
                        onTap: _onRenameTapped,
                      ),
                      _buildItemMenuRow(
                        icon: Icons.delete_outline,
                        label: '删除',
                        color: Colors.red,
                        labelColor: Colors.red,
                        onTap: _onDeleteTapped,
                      ),
                    ],
                  ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildItemMenuRow({
    required IconData icon,
    required String label,
    required Color color,
    required Color labelColor,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        height: _itemMenuRowHeight,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 10),
            // 文字不跟随图标着色（删除保持红色）
            Text(label, style: TextStyle(fontSize: 14, color: labelColor)),
          ],
        ),
      ),
    );
  }

  void _onRenameTapped() {
    final index = _itemMenuIndex;
    if (index == null || index >= _sessions.length) return;
    _closeItemMenu();
    _startInlineRename(index);
  }

  void _onDeleteTapped() {
    final index = _itemMenuIndex;
    if (index == null || index >= _sessions.length) return;
    final session = _sessions[index];
    final id = session['id']?.toString() ?? '';
    final title = (session['title'] as String?) ?? '未命名对话';
    _closeItemMenu();
    _openDeleteConfirm(id, title);
  }

  // ==================== 删除 ====================

  /// 打开内嵌删除确认（自持层，不走路由）：先读"减弱动态效果"偏好，
  /// 与全局对话框行为保持一致。
  /// 注意：BouncyDialogHost 约定接收线性 0→1 动画（与 showBouncyDialog
  /// 的路由动画一致），开闭曲线由其内部自行应用；此处不得再包
  /// CurvedAnimation——easeOutBack 过冲值 >1 传入内部 Curve.transform
  /// 会触发断言风暴，面板浮层整层构建失败（表现为死机）。
  Future<void> _openDeleteConfirm(String id, String title) async {
    if (_deleteConfirmController != null) return;
    _deleteConfirmReduceMotion = await readReduceMotionPref();
    final controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
      reverseDuration: const Duration(milliseconds: 400),
    );
    setState(() {
      _deleteId = id;
      _deleteTitle = title;
      _deleteConfirmController = controller;
    });
    controller.forward();
  }

  /// 关闭删除确认；[confirmed] 为 true 时在收起动画播完后执行删除
  void _closeDeleteConfirm({bool confirmed = false}) {
    final controller = _deleteConfirmController;
    final id = _deleteId;
    if (controller == null || _deleteConfirmClosing) return;
    _deleteConfirmClosing = true;
    controller.reverse().whenCompleteOrCancel(() {
      if (!mounted) return;
      setState(() {
        if (_deleteConfirmController == controller) {
          _deleteConfirmController = null;
          _deleteId = null;
          _deleteTitle = null;
          _deleteConfirmClosing = false;
        }
      });
      controller.dispose();
      if (confirmed && id != null) {
        _performDelete(id);
      }
    });
  }

  Future<void> _performDelete(String id) async {
    await StorageService.deleteChatSession(id);
    widget.onDeleted(id);
    if (!mounted) return;
    toastNotification.show(context, '已删除会话');
    // 行退场动画：数据仍保留该行（渲染为退场态），播完后才移除。
    // 用 id 而非 index 键控——退场期间再删其他行时，先完成的退场会
    // 触发数据刷新使 index 重排，index 键会错位指到别的行
    if (!_sessions.any((s) => s['id']?.toString() == id)) {
      setState(_reloadList);
      return;
    }
    final controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    void onDone(AnimationStatus status) {
      if (status != AnimationStatus.completed) return;
      controller.removeStatusListener(onDone);
      if (!mounted) return; // State.dispose 兜底释放 controller
      setState(() {
        _removingRows.remove(id);
        _reloadList();
      });
      controller.dispose();
    }

    controller.addStatusListener(onDone);
    setState(() => _removingRows[id] = controller);
    controller.forward();
  }
}
