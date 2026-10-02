// 导入页「云端数据管理」多阶段对话框：主菜单 → 备份 / 同步 / 删除，
// 全流程在同一对话框内完成（旧实现每步都「关闭当前框 + 弹新框」，
// 连续开关造成视觉断裂）。
//
// 动效取法（对齐两处已有实现）：
//  1. 检查更新对话框（dialogs/update_dialog.dart）：阶段切换时旧内容
//     模糊淡出、新内容自模糊中清晰淡入；布局尺寸只由新内容决定
//     （旧内容 Positioned 悬浮退场、不参与定尺寸），切换不产生
//     「先高后低」的跳位；
//  2. 设置页邮箱登录/注册对话框：内容高度变化时用 AnimatedSize 平滑
//     收缩/展开（确认密码字段展开动画 + 各输入框 AnimatedSize），
//     下方元素与壳高度逐帧跟随。这里把 AnimatedSize 用在 body 区：
//     各阶段内容高度不同，高度差由 AnimatedSize 在 220ms 内连贯过渡，
//     按钮行与对话框壳同步升降，不硬跳。
//     例外：「进行中」与「失败」两个阶段共用同一套固定 300 高布局
//     （1:1 复刻 update_dialog 的骨架），加载失败转失败态时高度不变，
//     只有图标/文案/按钮做模糊切换。
import 'dart:ui';
import 'package:flutter/material.dart';
import 'email_login_dialog.dart';
import '../services/auth_service.dart';
import '../services/cloud_sync_service.dart';
import '../theme/app_theme.dart';
import '../utils/storage.dart';
import '../widgets/glass_dialog.dart';
import '../widgets/fading_edge_list.dart';
import '../widgets/toast_notification.dart';

/// 云端最多保留的课表数（与导入页原备份上限一致）
const int _maxCloudTimetableCount = 5;

/// 列表可视高度上限：扣除图标/标题/副标题/按钮后的
/// 可用高度约 224（超出部分列表内滚动）
const double _listMaxHeight = 224.0;

/// 单个课表条目估算高度（内容 ≈59 + 条目间距 10）
const double _tileExtent = 70.0;

/// 未登录时的顶部 toast 文案（与旧版「直接提示并返回」保持一致，
/// 只是现在提示的同时把登录表单一并打开）
const String _loginRequiredToast = '请先登录账号，再使用云端数据管理';

/// 登录阶段的内容可用高度：壳总高 620（同设置页「邮箱账号」对话框）
/// 减去上下各 24 边距。给定确定高度后表单在该高度内可滚动，
/// 与弹出式用法的观感完全对齐
const double _loginContentMaxHeight = 620.0 - 24.0 * 2;

/// 对话框执行结果：由调用方统一 toast（本对话框关闭后才提示，
/// 避免提示条压在对话框上）
class CloudManagerResult {
  const CloudManagerResult({required this.success, required this.message});

  final bool success;
  final String message;
}

/// 对话框阶段
enum _CloudStage {
  /// 主菜单：三个云端操作入口
  menu,

  /// 进行中：拉取云端数据 / 上传备份 / 删除 / 导入
  busy,

  /// 选择要备份的本地课表（多选）
  backupSelect,

  /// 选择要同步的云端课表（单选）
  syncPick,

  /// 选择同步方式（合并 / 覆盖）
  syncMode,

  /// 选择要删除的云端课表（多选）
  deletePick,

  /// 失败（可重试；若为登录态失效，主按钮改为「重新登录」）
  error,

  /// 邮箱登录 / 注册：嵌入对话框内的一个阶段。
  /// 两种来源：① 打开时已知未登录 → 作为首个阶段；② 中途登录失效 →
  /// 由失败阶段的「重新登录」切过来。UI 与设置页「邮箱账号」对话框同源
  /// （dialogs/email_login_dialog.dart），切换走与其他阶段一样的过渡
  login,
}

/// 打开云端数据管理对话框，返回执行结果（用户直接关闭则为 null）。
///
/// 未登录时**不再**只提示就返回：表现为顶部 toast 说明原因，同时打开同
/// 一个对话框并以「登录」作为首个阶段——登录成功后原地连贯过渡到操作
/// 菜单，省掉「登录框关闭 → 用户再次点入口」这一步
Future<CloudManagerResult?> showCloudDataManagerDialog(
  BuildContext context, {
  bool? reduceMotion,
}) async {
  // 全局「减弱动态效果」：未显式指定时读取设置页开关
  final bool rm = reduceMotion ?? await readReduceMotionPref();
  if (!context.mounted) return null;

  final needsLogin = !AuthService.instance.isAuthenticated;

  return showBouncyDialog<CloudManagerResult>(
    context: context,
    barrierLabel: '云端数据管理',
    shellPadding: const EdgeInsets.all(24),
    // 壳总宽/总高约束含壳内边距（与旧版壳外 ConstrainedBox 语义一致）。
    // 上限按登录阶段满展开所需取 620（同设置页「邮箱账号」对话框），
    // 其余阶段内容天然更矮（列表定高 224），提高上限不影响它们
    shellMaxWidth: 420,
    shellMaxHeight: 620,
    // 登录阶段有输入框：键盘弹出时整壳上移避让
    avoidKeyboard: true,
    // 键盘弹出时压缩最大高度，保证输入框与「取消」按钮完整可见
    shellConstraintsBuilder: emailLoginShellConstraints,
    shellBoxShadow: [
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.2),
        blurRadius: 20,
        offset: const Offset(0, 10),
      ),
    ],
    reduceMotion: rm,
    builder: (context) =>
        _CloudManagerBody(reduceMotion: rm, startAtLogin: needsLogin),
  );
}

class _CloudManagerBody extends StatefulWidget {
  const _CloudManagerBody({
    required this.reduceMotion,
    this.startAtLogin = false,
  });

  final bool reduceMotion;

  /// 已知未登录：以登录阶段开场（打开的同时由调用方弹 toast）
  final bool startAtLogin;

  @override
  State<_CloudManagerBody> createState() => _CloudManagerBodyState();
}

class _CloudManagerBodyState extends State<_CloudManagerBody> {
  _CloudStage _stage = _CloudStage.menu;

  // 进行中阶段的标题/说明（不同流程文案不同）
  String _busyTitle = '处理中';
  String _busyLabel = '正在处理，请稍候…';

  // 失败阶段的标题/说明与重试入口
  String _errorTitle = '操作失败';
  String _errorText = '';
  VoidCallback? _retryAction;
  // 失败源于登录态失效：主按钮由「重试」改为「重新登录」
  bool _reloginRequired = false;

  // 进入登录阶段前的阶段：登录取消/成功后回到这里；
  // null 表示没有可回退的阶段（未登录开场），取消即关闭整个对话框
  _CloudStage? _stageBeforeLogin;

  // 备份流程：本地课表列表与多选集合
  List<TimetableInfo> _localTimetables = const <TimetableInfo>[];
  final Set<String> _selectedLocalIds = <String>{};

  // 同步/删除流程：云端备份快照
  Map<String, dynamic>? _cloudPayload;
  List<String> _cloudNames = const <String>[];
  DateTime? _cloudUpdatedAt;
  final Set<String> _selectedCloudNames = <String>{};
  String? _syncTimetableName;

  bool get _isBusy => _stage == _CloudStage.busy;
  bool get _isLoginStage => _stage == _CloudStage.login;

  @override
  void initState() {
    super.initState();
    if (widget.startAtLogin) {
      // 未登录开场：登录阶段就是首个阶段，没有可回退的阶段
      _stage = _CloudStage.login;
      _stageBeforeLogin = null;
      // 与对话框出现同一帧弹顶部 toast 说明为何直接就是登录界面
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _toast(_loginRequiredToast, ToastType.info);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // 语义色在 build 顶层取一次：切换子树（AnimatedSwitcher 的进出子项）
    // 内不做任何继承查找——重试瞬间旧子项可能已处于停用态，子树内的
    // Theme 查找会抛 "deactivated ancestor"（同更新对话框的处理）
    final palette = AppColors.of(context);

    // 高度连贯变化：整块内容（含加载态的固定 300 高布局、登录表单）尺寸
    // 随阶段变化，AnimatedSize 平滑收缩或展开，按钮行与对话框壳逐帧跟随。
    // ClipRect 必须包在 AnimatedSize **外层**：裁剪边界跟随动画中的实时
    // 高度 H(t)，旧内容以完整原始高度渲染、随收缩逐步被底边吃掉；放内层
    // 会在第一帧就被新内容目标高度整段硬切（同 add_options_sheet 的教训）
    return ClipRect(
      child: AnimatedSize(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        alignment: Alignment.topCenter,
        child: _blurSwitch(_buildLayout(palette)),
      ),
    );
  }

  Widget _buildLayout(AppPalette palette) {
    if (_isBusy) return _buildBusyLayout(palette);
    if (_isLoginStage) return _buildLoginLayout();
    // 失败阶段与加载阶段共用固定 300 高布局：加载转失败时对话框
    // 高度保持不变，只做内容模糊切换
    if (_stage == _CloudStage.error) return _buildErrorLayout(palette);
    return _buildStageLayout(palette);
  }

  /// 登录阶段：直接嵌设置页「邮箱账号」对话框的同源实现
  /// （dialogs/email_login_dialog.dart 的 EmailLoginForm），
  /// 自己的图标/标题/输入框/按钮全在里面，不走常规阶段的骨架。
  /// onSuccess 返回 true 表示登录成功后由本对话框切阶段，而非关闭弹窗
  Widget _buildLoginLayout() {
    return EmailLoginForm(
      initialEmail: AuthService.instance.userEmail,
      maxContentHeight: _loginContentMaxHeight,
      onSuccess: (isRegisterMode) async {
        _returnFromLogin(
          message: isRegisterMode ? '注册并登录成功' : '登录成功',
        );
        return true;
      },
      onCancel: () {
        final back = _stageBeforeLogin;
        if (back == null) {
          Navigator.pop(context);
          return;
        }
        setState(() => _stage = back);
      },
    );
  }

  /// 登录成功：回到操作菜单重新开始。
  /// 上一轮流程的上下文（已选课表、云端快照）建立于失效的登录态之上，
  /// 一律作废，避免拿到半旧的数据；过渡仍在同一对话框内连贯完成
  void _returnFromLogin({String message = '登录成功'}) {
    setState(() {
      _localTimetables = const <TimetableInfo>[];
      _selectedLocalIds.clear();
      _cloudPayload = null;
      _cloudNames = const <String>[];
      _cloudUpdatedAt = null;
      _selectedCloudNames.clear();
      _syncTimetableName = null;
      _reloginRequired = false;
      _retryAction = null;
      _retryLoadCloud = null;
      _stage = _CloudStage.menu;
    });
    _toast(message, ToastType.success);
  }

  /// 常规阶段骨架：图标 → 标题 → 副标题 → 内容区 → 按钮
  Widget _buildStageLayout(AppPalette palette) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _blurSwitch(_buildIcon()),
        const SizedBox(height: 16),
        _blurSwitch(Text(
          _stageTitle(),
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        )),
        const SizedBox(height: 8),
        // 副标题固定两行高度：各阶段文案行数不同（1~2 行），固定占位
        // 后高度差全部集中在内容区，由外层 AnimatedSize 统一过渡，
        // 标题/按钮不会因文案换行而瞬时位移
        _blurSwitch(SizedBox(
          height: 36,
          child: Center(
            child: Text(
              _stageSubtitle(),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: palette.textSecondary),
            ),
          ),
        )),
        const SizedBox(height: 16),
        _blurSwitch(_buildBody(palette)),
        const SizedBox(height: 16),
        _blurSwitch(_buildActions(palette)),
      ],
    );
  }

  /// 加载阶段：1:1 复刻「检查更新」对话框（dialogs/update_dialog.dart 的
  /// checking 阶段）——同样的 300 高内容框、同样的元素顺序与间距，
  /// 内容区 Expanded 垂直居中、按钮固定在底部，只有文案不同：
  ///   图标 64（Padding 16 内嵌蓝色细环转圈）→ 16 → 标题（20 bold）→
  ///   12 → 说明（14 / textSecondary 居中）→ 底部整宽「取消」
  /// 宽度不跟随（本对话框统一 420，update_dialog 是 360）：壳宽按阶段
  /// 变化会破坏整体统一性，高度与内部布局对齐即可
  Widget _buildBusyLayout(AppPalette palette) {
    return SizedBox(
      width: double.infinity,
      height: 300,
      child: Column(
        children: [
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildIcon(),
                const SizedBox(height: 16),
                Text(
                  _busyTitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Text(
                  _busyLabel,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 14, color: palette.textSecondary),
                ),
              ],
            ),
          ),
          Row(
            children: [
              _secondaryButton('取消', () => Navigator.pop(context), palette),
            ],
          ),
        ],
      ),
    );
  }

  /// 失败阶段：与加载阶段共用同一套 300 高固定布局（同「检查更新」
  /// 对话框的骨架），「正在获取…」失败转「获取数据失败」时对话框
  /// 高度纹丝不动，只有图标/文案/按钮随阶段模糊切换。
  /// 元素顺序与间距对齐加载阶段：图标 64 → 16 → 标题（20 bold）→
  /// 12 → 失败原因（14 / textSecondary，最多两行）→ 8 → 补充提示
  /// （13 / textTertiary）；底部按钮行与加载阶段同高（关闭 + 重试 /
  /// 重新登录，登录态失效时主按钮换文案）。
  Widget _buildErrorLayout(AppPalette palette) {
    return SizedBox(
      width: double.infinity,
      height: 300,
      child: Column(
        children: [
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildIcon(),
                const SizedBox(height: 16),
                Text(
                  _errorTitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Text(
                  _errorText,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, color: palette.textSecondary),
                ),
                const SizedBox(height: 8),
                Text(
                  _reloginRequired ? '登录后可从「操作菜单」继续刚才的云端操作' : '请检查网络连接后重试',
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: palette.textTertiary),
                ),
              ],
            ),
          ),
          Row(
            children: [
              _secondaryButton('关闭', () => Navigator.pop(context), palette),
              const SizedBox(width: 12),
              // 登录态失效时重跑原位任务毫无意义：主按钮直接换成「重新登录」
              if (_reloginRequired)
                _primaryButton('重新登录', _enterLoginStage)
              else
                _primaryButton('重试', _retryAction),
            ],
          ),
        ],
      ),
    );
  }

  /// 阶段切换过渡（与更新对话框同款）：旧内容模糊淡出，新内容自模糊中
  /// 清晰淡入，交叉过渡不跳变；「减弱动态效果」开启时退化为单纯淡入淡出。
  ///
  /// Stack 尺寸只由新内容决定（旧内容悬浮退场、不参与定尺寸），但旧内容
  /// **顶部锚定**而非垂直居中——若居中，阶段一变旧内容会在动画第一帧被
  /// 瞬间挪到「新高度的居中位置」，先跳变再淡出（新旧高度差越大越明显）。
  /// 顶部锚定后旧内容位置纹丝不动，超出部分由外层 AnimatedSize 的实时
  /// 高度 H(t) 逐步裁掉（见 build 注释）。旧内容放 Stack **上层**退场，
  /// 避免模糊淡出的过程被新内容盖住。
  Widget _blurSwitch(Widget child) => AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        transitionBuilder: (child, animation) {
          if (widget.reduceMotion) {
            return FadeTransition(opacity: animation, child: child);
          }
          return FadeTransition(
            opacity: animation,
            child: AnimatedBuilder(
              animation: animation,
              builder: (context, grandChild) => ImageFiltered(
                imageFilter: ImageFilter.blur(
                  sigmaX: 6 * (1.0 - animation.value),
                  sigmaY: 6 * (1.0 - animation.value),
                ),
                child: Transform.scale(
                  scale: 0.92 + 0.08 * animation.value,
                  child: grandChild,
                ),
              ),
              child: child,
            ),
          );
        },
        // 强制满宽（各阶段壳宽统一 420，不随阶段变化——加载态只对齐全高
        // 与内部布局，宽度保持统一性）：否则 Stack 收缩到新内容的自然宽度
        // 时，Positioned 悬浮的退场内容会被挤压换行一帧。
        // 旧内容只给水平约束、不参与定尺寸，垂直位置跟随 Stack 的
        // topCenter 对齐（即原顶部位置）
        layoutBuilder: (currentChild, previousChildren) => SizedBox(
          width: double.infinity,
          child: Stack(
            alignment: Alignment.topCenter,
            clipBehavior: Clip.none,
            children: [
              if (currentChild != null) currentChild,
              for (final Widget child in previousChildren)
                Positioned(
                  left: 0,
                  right: 0,
                  child: child,
                ),
            ],
          ),
        ),
        child: KeyedSubtree(key: ValueKey<_CloudStage>(_stage), child: child),
      );

  // ============================================================
  // 各阶段内容
  // ============================================================

  Widget _buildIcon() {
    const blue = Color(0xFF4A90E2);
    switch (_stage) {
      case _CloudStage.menu:
        return _gradientIcon(
            Icons.cloud_sync_rounded, const [blue, Color(0xFF5BA0F2)]);
      case _CloudStage.busy:
        // 进行中：完全复刻「检查更新」对话框的加载态——64 容器内嵌 32
        // 的蓝色细环转圈，无底板、无图标（与 update_dialog 的 checking
        // 阶段逐像素一致）
        return const SizedBox(
          width: 64,
          height: 64,
          child: Padding(
            padding: EdgeInsets.all(16),
            child: CircularProgressIndicator(
              color: Color(0xFF4A90E2),
              strokeWidth: 3,
            ),
          ),
        );
      case _CloudStage.backupSelect:
        return _gradientIcon(
            Icons.library_add_check_rounded, const [blue, Color(0xFF5BA0F2)]);
      case _CloudStage.syncPick:
        return _gradientIcon(
            Icons.list_alt_rounded, const [blue, Color(0xFF5BA0F2)]);
      case _CloudStage.syncMode:
        return _gradientIcon(
            Icons.cloud_download_rounded, const [blue, Color(0xFF5BA0F2)]);
      case _CloudStage.deletePick:
        return _gradientIcon(Icons.folder_open_rounded,
            const [Color(0xFFFF9800), Color(0xFFFFB74D)]);
      case _CloudStage.error:
        return _reloginRequired
            ? Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: const Color(0xFFFF9800).withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(Icons.lock_reset_rounded,
                    size: 32, color: Colors.white),
              )
            : Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(Icons.cloud_off_rounded,
                    size: 36, color: Colors.white),
              );
      case _CloudStage.login:
        // 登录阶段自带图标（表单内部），此分支仅为 switch 穷尽
        return const SizedBox.shrink();
    }
  }

  Widget _gradientIcon(IconData icon, List<Color> colors) {
    return Opacity(
      opacity: 0.82,
      child: Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: colors),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Icon(icon, size: 32, color: Colors.white),
      ),
    );
  }

  String _stageTitle() {
    switch (_stage) {
      case _CloudStage.menu:
        return '云端数据管理';
      case _CloudStage.busy:
        return _busyTitle;
      case _CloudStage.backupSelect:
        return '选择要备份的课表';
      case _CloudStage.syncPick:
        return '选择要同步的课表';
      case _CloudStage.syncMode:
        return '选择同步方式';
      case _CloudStage.deletePick:
        return '管理云端课表';
      case _CloudStage.error:
        return _errorTitle;
      case _CloudStage.login:
        return '邮箱账号';
    }
  }

  String _stageSubtitle() {
    switch (_stage) {
      case _CloudStage.menu:
        return '请选择你要执行的云端操作';
      case _CloudStage.busy:
        return _busyLabel;
      case _CloudStage.backupSelect:
        return '可多选，未选中的课表不会上传';
      case _CloudStage.syncPick:
        return '云端更新时间：${_formatDateTime(_cloudUpdatedAt)}';
      case _CloudStage.syncMode:
        return '已选择课表：${_syncTimetableName ?? '-'}\n'
            '云端更新时间：${_formatDateTime(_cloudUpdatedAt)}';
      case _CloudStage.deletePick:
        return '云端更新时间：${_formatDateTime(_cloudUpdatedAt)}';
      case _CloudStage.error:
        return _errorText;
      case _CloudStage.login:
        return '请先登录账号，再继续云端操作';
    }
  }

  Widget _buildBody(AppPalette palette) {
    switch (_stage) {
      case _CloudStage.menu:
        return _buildActionGroup([
          _buildActionTile(
            icon: Icons.cloud_upload_rounded,
            title: '备份数据到云端',
            subtitle: '可多选课表备份（含任务和设置）',
            onTap: _startBackupFlow,
          ),
          _buildActionTile(
            icon: Icons.cloud_download_rounded,
            title: '从云端同步数据',
            subtitle: '支持合并到本地或云端覆盖本地',
            onTap: _startSyncFlow,
          ),
          _buildActionTile(
            icon: Icons.folder_open_rounded,
            title: '管理云端数据',
            subtitle: '查看云端课表列表并删除',
            onTap: _startDeleteFlow,
          ),
        ]);
      case _CloudStage.busy:
        // 加载阶段不走这里（整块由 _buildBusyLayout 1:1 复刻「检查更新」
        // 对话框），保留分支仅为 switch 穷尽
        return const SizedBox.shrink();
      case _CloudStage.backupSelect:
        return _buildTimetableList(
          count: _localTimetables.length,
          header: _buildSelectHeader(
            count: _localTimetables.length,
            selectedCount: _selectedLocalIds.length,
            onSelectAll: () {
              setState(() {
                _selectedLocalIds
                  ..clear()
                  ..addAll(_localTimetables.map((t) => t.id));
              });
            },
            onClear: () => setState(() => _selectedLocalIds.clear()),
          ),
          itemBuilder: (context, index) {
            final timetable = _localTimetables[index];
            final selected = _selectedLocalIds.contains(timetable.id);
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _buildSelectableTile(
                palette: palette,
                title: timetable.name,
                subtitle: '创建于 ${_formatDateTime(timetable.createdAt)}',
                selected: selected,
                onTap: () {
                  setState(() {
                    if (selected) {
                      _selectedLocalIds.remove(timetable.id);
                    } else {
                      _selectedLocalIds.add(timetable.id);
                    }
                  });
                },
              ),
            );
          },
        );
      case _CloudStage.syncPick:
        // 单选：点选即进入「选择同步方式」，无需主按钮。
        // 同样走定高列表（课表最多 5 张，超出部分滚动），避免课表多时
        // 内容高度溢出壳上限
        return _buildTimetableList(
          count: _cloudNames.length,
          maxHeight: _listMaxHeight + 44,
          itemBuilder: (context, index) {
            final name = _cloudNames[index];
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _buildSelectableTile(
                palette: palette,
                title: name,
                subtitle: '同步此课表到当前设备',
                selected: _syncTimetableName == name,
                onTap: () {
                  setState(() {
                    _syncTimetableName = name;
                    _stage = _CloudStage.syncMode;
                  });
                },
              ),
            );
          },
        );
      case _CloudStage.syncMode:
        return _buildActionGroup([
          _buildActionTile(
            icon: Icons.merge_type,
            title: '合并到本地',
            subtitle: '保留现有数据，并补充云端数据',
            onTap: () => _submitSync(ImportMode.merge),
          ),
          _buildActionTile(
            icon: Icons.system_update_alt_rounded,
            title: '云端覆盖本地',
            subtitle: '清空当前课表数据后导入云端数据',
            onTap: () => _submitSync(ImportMode.replace),
          ),
        ]);
      case _CloudStage.deletePick:
        return _buildTimetableList(
          count: _cloudNames.length,
          header: _buildSelectHeader(
            count: _cloudNames.length,
            selectedCount: _selectedCloudNames.length,
            accentColor: Colors.red,
            onSelectAll: () {
              setState(() {
                _selectedCloudNames
                  ..clear()
                  ..addAll(_cloudNames);
              });
            },
            onClear: () => setState(() => _selectedCloudNames.clear()),
          ),
          itemBuilder: (context, index) {
            final name = _cloudNames[index];
            final selected = _selectedCloudNames.contains(name);
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _buildSelectableTile(
                palette: palette,
                title: name,
                subtitle: '从云端备份中删除此课表',
                selected: selected,
                selectedColor: Colors.red,
                onTap: () {
                  setState(() {
                    if (selected) {
                      _selectedCloudNames.remove(name);
                    } else {
                      _selectedCloudNames.add(name);
                    }
                  });
                },
              ),
            );
          },
        );
      case _CloudStage.error:
        // 失败阶段整块由 _buildErrorLayout 提供（与加载阶段同套 300 高
        // 布局），常规骨架的 body 分支不会被使用，此处仅为 switch 穷尽
        return const SizedBox.shrink();
      case _CloudStage.login:
        // 登录阶段整块由 _buildLoginLayout 提供（表单内含自有标题与按钮），
        // 常规骨架的 body 分支不会被使用，此处仅为 switch 穷尽
        return const SizedBox.shrink();
    }
  }

  Widget _buildActions(AppPalette palette) {
    switch (_stage) {
      case _CloudStage.menu:
        return Row(
          children: [
            _secondaryButton('关闭', () => Navigator.pop(context), palette),
          ],
        );
      case _CloudStage.busy:
        // 加载阶段的按钮由 _buildBusyLayout 自带（同「检查更新」的整宽
        // 「取消」），此处仅为 switch 穷尽
        return Row(
          children: [
            _secondaryButton('取消', () => Navigator.pop(context), palette),
          ],
        );
      case _CloudStage.backupSelect:
        return Row(
          children: [
            _secondaryButton(
                '返回', () => setState(() => _stage = _CloudStage.menu), palette),
            const SizedBox(width: 12),
            _primaryButton(
              '开始备份',
              _selectedLocalIds.isEmpty ? null : _submitBackup,
            ),
          ],
        );
      case _CloudStage.syncPick:
        return Row(
          children: [
            _secondaryButton(
                '返回', () => setState(() => _stage = _CloudStage.menu), palette),
          ],
        );
      case _CloudStage.syncMode:
        return Row(
          children: [
            _secondaryButton(
              '返回',
              () => setState(() => _stage = _CloudStage.syncPick),
              palette,
            ),
          ],
        );
      case _CloudStage.deletePick:
        return Row(
          children: [
            _secondaryButton(
                '返回', () => setState(() => _stage = _CloudStage.menu), palette),
            const SizedBox(width: 12),
            _primaryButton(
              '删除选中',
              _selectedCloudNames.isEmpty ? null : _submitDelete,
              color: Colors.red,
            ),
          ],
        );
      case _CloudStage.error:
        // 失败阶段的按钮由 _buildErrorLayout 自带（关闭 + 重试/重新登录），
        // 此处仅为 switch 穷尽
        return const SizedBox.shrink();
      case _CloudStage.login:
        // 登录阶段的按钮在表单内部；仅为 switch 穷尽
        return const SizedBox.shrink();
    }
  }

  /// 切到登录阶段：记录来源阶段，取消时回退到这里
  void _enterLoginStage() {
    setState(() {
      _stageBeforeLogin =
          _stage == _CloudStage.login ? _stageBeforeLogin : _stage;
      _stage = _CloudStage.login;
    });
  }

  /// 判断一次云端失败是否源于登录态问题（而非单纯的网络/服务端故障）：
  /// CloudSyncService 在会话失效时会给「请先完成登录」「登录已过期，
  /// 请重新登录」，过期时还会把本地会话置为失效
  bool _isAuthFailure(String? error) {
    if (!AuthService.instance.isAuthenticated) return true;
    final text = error ?? '';
    return text.contains('登录') &&
        (text.contains('过期') || text.contains('请先完成登录'));
  }

  // ============================================================
  // 通用控件（沿用导入页原有样式）
  // ============================================================

  /// 灰底 + borderWeak 描边圆角卡并列多行，行间细分隔线（左缩进对齐文字）
  Widget _buildActionGroup(List<Widget> tiles) {
    final palette = AppColors.of(context);
    if (tiles.isEmpty) return const SizedBox.shrink();
    return Material(
      color: palette.surfaceAlt,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: palette.borderWeak),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < tiles.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                thickness: 1,
                indent: 66,
                color: palette.borderWeak,
              ),
            tiles[i],
          ],
        ],
      ),
    );
  }

  Widget _buildActionTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final palette = AppColors.of(context);
    const blue = Color(0xFF4A90E2);
    return InkWell(
      onTap: _isBusy ? null : onTap,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: blue.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: blue, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: palette.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style:
                        TextStyle(fontSize: 12, color: palette.textSecondary),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: palette.textTertiary),
          ],
        ),
      ),
    );
  }

  /// 课表列表：高度按条目数估算并夹在上限内（超出滚动），
  /// 固定高度保证 AnimatedSize 有确定尺寸可动画（不随父约束浮动）
  Widget _buildTimetableList({
    required int count,
    required Widget Function(BuildContext, int) itemBuilder,
    double maxHeight = _listMaxHeight,
    Widget? header,
  }) {
    final listHeight =
        (count * _tileExtent).clamp(_tileExtent, maxHeight).toDouble();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (header != null) ...[
          header,
          const SizedBox(height: 4),
        ],
        // 定高 + 内部滚动 + 上下边缘淡出（超出可视高度后才淡出）
        FadingEdgeList(
          height: listHeight,
          itemCount: count,
          itemBuilder: itemBuilder,
        ),
      ],
    );
  }

  /// 多选列表头部：全选 / 清空 + 已选计数
  Widget _buildSelectHeader({
    required int count,
    required int selectedCount,
    required VoidCallback onSelectAll,
    required VoidCallback onClear,
    Color accentColor = const Color(0xFF4A90E2),
  }) {
    final allSelected = count > 0 && selectedCount == count;
    return Row(
      children: [
        TextButton(
          onPressed: onSelectAll,
          child: Text(allSelected ? '已全选' : '全选'),
        ),
        TextButton(onPressed: onClear, child: const Text('清空')),
        const Spacer(),
        Text(
          '已选 $selectedCount / $count',
          style: TextStyle(fontSize: 12, color: accentColor),
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  Widget _buildSelectableTile({
    required AppPalette palette,
    required String title,
    required String subtitle,
    required bool selected,
    required VoidCallback onTap,
    Color selectedColor = const Color(0xFF4A90E2),
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      // 不挂 key：AnimatedSwitcher 的退场子项处于停用态，子树内若做
      // Theme/MediaQuery 继承查找会抛 "deactivated ancestor"
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected
              ? selectedColor.withValues(alpha: 0.12)
              : palette.panel(0.4),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? selectedColor : palette.borderWeak,
            width: selected ? 1.6 : 1.0,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: selected ? selectedColor : Colors.transparent,
                borderRadius: BorderRadius.circular(7),
                border: Border.all(
                  color: selected ? selectedColor : palette.textTertiary,
                ),
              ),
              child: selected
                  ? const Icon(Icons.check, size: 16, color: Colors.white)
                  : null,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: selected ? selectedColor : palette.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style:
                        TextStyle(fontSize: 12, color: palette.textSecondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _secondaryButton(
      String text, VoidCallback? onPressed, AppPalette palette) {
    return Expanded(
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: palette.borderWeak),
          ),
        ),
        child: Text(text),
      ),
    );
  }

  Widget _primaryButton(String text, VoidCallback? onPressed,
      {Color color = const Color(0xFF4A90E2)}) {
    return Expanded(
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        child: Text(text),
      ),
    );
  }

  // ============================================================
  // 流程
  // ============================================================

  void _toast(String message, ToastType type) {
    if (!mounted) return;
    toastNotification.show(context, message, type: type);
  }

  void _enterBusy(String title, String label) {
    setState(() {
      _stage = _CloudStage.busy;
      _busyTitle = title;
      _busyLabel = label;
    });
  }

  /// [requireRelogin]：本次失败源于登录态失效，失败阶段的主按钮改为
  /// 「重新登录」（跳到登录阶段），而不是原样重试
  void _enterError(String title, String text, VoidCallback retry,
      {bool requireRelogin = false}) {
    setState(() {
      _stage = _CloudStage.error;
      _errorTitle = title;
      _errorText = text;
      _retryAction = requireRelogin ? null : retry;
      _reloginRequired = requireRelogin;
    });
  }

  /// 失败进入点：自动判定是不是登录态问题，并按需要把按钮换成「重新登录」
  void _enterCloudFailure(String title, String error, VoidCallback retry) {
    if (!mounted) return;
    final relogin = _isAuthFailure(error);
    _enterError(title, error, retry, requireRelogin: relogin);
  }

  /// 结束后关闭对话框并把结果交给调用方 toast
  void _finish({required bool success, required String message}) {
    if (!mounted) return;
    Navigator.pop(
        context, CloudManagerResult(success: success, message: message));
  }

  // ---- 备份 ----

  void _startBackupFlow() {
    final timetables = StorageService.getTimetables();
    if (timetables.isEmpty) {
      _toast('当前没有可备份的课表', ToastType.info);
      return;
    }
    setState(() {
      _localTimetables = timetables;
      _selectedLocalIds
        ..clear()
        ..addAll(timetables.map((t) => t.id));
      _stage = _CloudStage.backupSelect;
    });
  }

  Future<void> _submitBackup() async {
    final selectedIds = _selectedLocalIds.toList();
    if (selectedIds.isEmpty) return;
    _enterBusy('正在备份到云端', '正在上传所选课表…');

    final selectedPayload =
        StorageService.exportSelectedDataByTimetableIds(selectedIds);
    final selectedNames =
        StorageService.getCloudBackupTimetableNames(selectedPayload);
    if (selectedNames.isEmpty) {
      _toast('所选课表没有可备份的数据', ToastType.info);
      if (!mounted) return;
      setState(() => _stage = _CloudStage.backupSelect);
      return;
    }

    final cloudSync = CloudSyncService.instance;
    final cloudBackup = await cloudSync.fetchBackup();
    if (!mounted) return;
    if (cloudBackup == null && cloudSync.lastError != null) {
      _enterCloudFailure('获取云端数据失败', cloudSync.lastError!, _submitBackup);
      return;
    }

    final payload = cloudBackup == null
        ? selectedPayload
        : _mergeSelectedIntoCloudPayload(
            cloudPayload: cloudBackup.payload,
            selectedPayload: selectedPayload,
          );
    final cloudCount =
        StorageService.getCloudBackupTimetableNames(payload).length;
    if (cloudCount > _maxCloudTimetableCount) {
      _toast(
        '云端最多保留 $_maxCloudTimetableCount 张课表，当前将达到 $cloudCount 张，'
        '请减少备份选择或先删除部分云端课表',
        ToastType.error,
      );
      if (!mounted) return;
      setState(() => _stage = _CloudStage.backupSelect);
      return;
    }

    final success = await cloudSync.uploadBackup(payload);
    if (!mounted) return;
    if (!success) {
      _enterCloudFailure(
          '备份失败', cloudSync.lastError ?? '云端备份失败，请稍后重试', _submitBackup);
      return;
    }
    _finish(
      success: true,
      message: cloudBackup == null
          ? '已备份 ${selectedNames.length} 个课表到云端'
          : '已合并备份 ${selectedNames.length} 个课表，云端现有 $cloudCount 张课表',
    );
  }

  Map<String, dynamic> _mergeSelectedIntoCloudPayload({
    required Map<String, dynamic> cloudPayload,
    required Map<String, dynamic> selectedPayload,
  }) {
    final mergedNamed = _extractNamedTimetables(cloudPayload)
      ..addAll(_extractNamedTimetables(selectedPayload));

    final selectedCurrentId = selectedPayload['currentTimetableId']?.toString();
    final cloudCurrentId = cloudPayload['currentTimetableId']?.toString();

    return {
      'version': '2.0',
      'backupType': 'full_named_timetables',
      'currentTimetableId':
          (selectedCurrentId != null && selectedCurrentId.isNotEmpty)
              ? selectedCurrentId
              : cloudCurrentId,
      'namedTimetables': mergedNamed,
    };
  }

  Map<String, dynamic> _extractNamedTimetables(Map<String, dynamic> payload) {
    final named = <String, dynamic>{};

    final namedTimetables = payload['namedTimetables'];
    if (namedTimetables is Map) {
      for (final entry in namedTimetables.entries) {
        if (entry.key is String && entry.value is Map) {
          named[entry.key as String] =
              Map<String, dynamic>.from(entry.value as Map);
        }
      }
    }

    // 旧版备份（无 namedTimetables）：兜底成一张名为「当前课表」的课表
    final hasLegacyData = (payload['courses'] is List) ||
        (payload['tasks'] is List) ||
        (payload['settings'] is Map);
    if (hasLegacyData && !named.containsKey('当前课表')) {
      named['当前课表'] = {
        'courses': payload['courses'] is List
            ? List<dynamic>.from(payload['courses'] as List)
            : <dynamic>[],
        'tasks': payload['tasks'] is List
            ? List<dynamic>.from(payload['tasks'] as List)
            : <dynamic>[],
        'settings': payload['settings'] is Map
            ? Map<String, dynamic>.from(payload['settings'] as Map)
            : <String, dynamic>{},
      };
    }

    return named;
  }

  // ---- 同步 / 删除：共用云端快照拉取 ----

  /// 拉取云端备份并写入状态；失败/空数据自行处理后返回 false
  Future<bool> _loadCloudSnapshot() async {
    _enterBusy('正在获取云端数据', '正在读取云端备份…');
    final cloudSync = CloudSyncService.instance;
    final backup = await cloudSync.fetchBackup();
    if (!mounted) return false;

    if (backup == null && cloudSync.lastError != null) {
      _enterCloudFailure(
          '获取云端数据失败', cloudSync.lastError!, _retryLoadCloud ?? () {});
      return false;
    }
    if (backup == null) {
      _toast('云端暂无备份数据', ToastType.info);
      if (!mounted) return false;
      setState(() => _stage = _CloudStage.menu);
      return false;
    }

    final names = StorageService.getCloudBackupTimetableNames(backup.payload);
    if (names.isEmpty) {
      _toast('云端备份中未找到可同步课表', ToastType.error);
      if (!mounted) return false;
      setState(() => _stage = _CloudStage.menu);
      return false;
    }

    setState(() {
      _cloudPayload = backup.payload;
      _cloudNames = names;
      _cloudUpdatedAt = backup.updatedAt;
    });
    return true;
  }

  /// 重试入口：记录当前流程，失败阶段「重试」按原流程重跑
  VoidCallback? _retryLoadCloud;

  Future<void> _startSyncFlow() async {
    _retryLoadCloud = _startSyncFlow;
    if (!await _loadCloudSnapshot()) return;
    setState(() => _stage = _CloudStage.syncPick);
  }

  Future<void> _startDeleteFlow() async {
    _retryLoadCloud = _startDeleteFlow;
    if (!await _loadCloudSnapshot()) return;
    setState(() {
      _selectedCloudNames.clear();
      _stage = _CloudStage.deletePick;
    });
  }

  Future<void> _submitSync(ImportMode mode) async {
    final name = _syncTimetableName;
    final cloudPayload = _cloudPayload;
    if (name == null || cloudPayload == null) return;
    _enterBusy(
      '正在同步数据',
      mode == ImportMode.merge ? '正在合并云端课表到本地…' : '正在用云端课表覆盖本地…',
    );

    final selectedPayload =
        StorageService.getCloudBackupTimetableData(cloudPayload, name);
    if (selectedPayload == null) {
      _toast('选中的课表数据不存在或已损坏', ToastType.error);
      if (!mounted) return;
      setState(() => _stage = _CloudStage.syncPick);
      return;
    }

    final result = await StorageService.importData(selectedPayload, mode: mode);
    if (!mounted) return;
    _finish(
      success: result.success,
      message: result.success
          ? (mode == ImportMode.merge
              ? '已将“$name”合并到本地：${result.summary}'
              : '已用“$name”覆盖当前课表：${result.summary}')
          : (result.errorMessage ?? '从云端同步失败，请稍后再试'),
    );
  }

  Future<void> _submitDelete() async {
    final cloudPayload = _cloudPayload;
    if (cloudPayload == null || _selectedCloudNames.isEmpty) return;
    final deleteCount = _selectedCloudNames.length;
    _enterBusy('正在删除云端课表', '正在更新云端备份…');

    final nextPayload = _removeTimetablesFromCloudPayload(
      cloudPayload,
      _selectedCloudNames.toSet(),
    );
    final remainingNames =
        StorageService.getCloudBackupTimetableNames(nextPayload);
    final cloudSync = CloudSyncService.instance;
    final success = remainingNames.isEmpty
        ? await cloudSync.deleteBackup()
        : await cloudSync.uploadBackup(nextPayload);
    if (!mounted) return;

    if (!success) {
      _enterCloudFailure(
          '删除失败', cloudSync.lastError ?? '删除云端课表失败，请稍后重试', _submitDelete);
      return;
    }
    _finish(success: true, message: '已删除 $deleteCount 个云端课表');
  }

  Map<String, dynamic> _removeTimetablesFromCloudPayload(
    Map<String, dynamic> payload,
    Set<String> namesToDelete,
  ) {
    final nextPayload = Map<String, dynamic>.from(payload);
    final namedTimetables = payload['namedTimetables'];
    final removeLegacyCurrent = namesToDelete.contains('当前课表');

    if (removeLegacyCurrent) {
      nextPayload
        ..remove('courses')
        ..remove('tasks')
        ..remove('settings');
    }

    if (namedTimetables is Map) {
      final nextNamed = Map<String, dynamic>.from(namedTimetables);
      for (final name in namesToDelete) {
        nextNamed.remove(name);
      }
      nextPayload['namedTimetables'] = nextNamed;
    } else if (removeLegacyCurrent) {
      nextPayload['namedTimetables'] = <String, dynamic>{};
    }

    if (StorageService.getCloudBackupTimetableNames(nextPayload).isEmpty) {
      return {
        'version': '2.0',
        'backupType': 'full_named_timetables',
        'namedTimetables': <String, dynamic>{},
      };
    }

    return nextPayload;
  }

  String _formatDateTime(DateTime? time) {
    if (time == null) return '未知';
    final local = time.toLocal();
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${twoDigits(local.month)}-${twoDigits(local.day)} '
        '${twoDigits(local.hour)}:${twoDigits(local.minute)}';
  }
}
