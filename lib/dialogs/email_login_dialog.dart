// 邮箱登录 / 注册：表单本体（EmailLoginForm）+ 弹出式用法（showEmailLoginDialog）。
//
// 这份实现从设置页「电子邮箱登录」对话框原样搬过来，目的只有一个：
// 让**设置页的独立弹窗**与**云端数据管理对话框的登录阶段**共用同一份 UI。
// 云端数据管理在两种情况下需要登录（未直接弹出)：
//   1. 打开时已知未登录 → 弹 toast 提示，同时以登录表单作为首个阶段；
//   2. 拉取云端数据时登录失效 → 失败阶段的「重试」变为「重新登录」，
//      点击后原地过渡到登录表单（同一对话框内的阶段切换，带连贯动画）。
// 若两边各写一份，UI 必然随时间漂移，所以由这里统一维护。

import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_text_field.dart';
import '../widgets/glass_dialog.dart';
import '../widgets/toast_notification.dart';

/// 登录 / 注册对话框的基础壳高上限：注册模式比登录多确认密码框与
/// 邮箱验证码框（CloudBase 注册硬约束），取消按钮必须完整露出、
/// 无需翻页，故按注册模式内容取
const double _baseMaxShellHeight = 680.0;

/// 表单内容区的高度上限（= 壳上限 − 上下 shellPadding 24×2）
const double _loginContentMaxHeight = _baseMaxShellHeight - 24.0 * 2;

/// 邮箱登录 / 注册对话框（设置页「电子邮箱登录」入口调用）。
///
/// [afterSuccess]：默认收尾（关闭弹窗 + 成功 toast）之后触发的额外处理，
/// 例如设置页登录后的云端数据同步。
Future<void> showEmailLoginDialog(
  BuildContext context, {
  Future<void> Function(bool isRegisterMode)? afterSuccess,
}) {
  // 弹出动画（约 150ms）期间 TextField 仍会重建，立即 dispose 会触发
  // "TextEditingController used after being disposed"，由表单内部延迟释放
  return showBouncyDialog(
    context: context,
    barrierLabel: '电子邮箱登录',
    shellPadding: const EdgeInsets.all(24),
    shellBoxShadow: const [
      BoxShadow(
        color: Color(0x33000000),
        blurRadius: 20,
        offset: Offset(0, 10),
      ),
    ],
    avoidKeyboard: true,
    shellConstraintsBuilder: emailLoginShellConstraints,
    builder: (context) => EmailLoginForm(
      initialEmail: AuthService.instance.userEmail,
      maxContentHeight: _loginContentMaxHeight,
      // 弹窗本体将被 pop，成功 toast 挂到宿主页面的 context 上更稳妥
      toastHostContext: context,
      afterSuccess: afterSuccess,
      onCancel: () => Navigator.pop(context),
    ),
  );
}

/// 登录表单阶段的壳尺寸约束：宽 420，高上限 620（注册模式比登录多一个
/// 确认密码框，取消按钮必须完整露出、无需翻页，故基础值按注册模式取），
/// 键盘弹出时按剩余可用高度压缩，下限 260。
/// 云端数据管理对话框的登录阶段也用同一份，保证两边的可用高度一致。
BoxConstraints emailLoginShellConstraints(BuildContext context) {
  final mediaQuery = MediaQuery.of(context);
  final keyboardHeight = mediaQuery.viewInsets.bottom;
  final topInset = mediaQuery.padding.top;
  final screenHeight = mediaQuery.size.height;
  double dialogMaxHeight = _baseMaxShellHeight;
  final availableHeight = screenHeight - topInset - keyboardHeight - 24;
  if (availableHeight < dialogMaxHeight) {
    dialogMaxHeight = availableHeight;
  }
  dialogMaxHeight =
      dialogMaxHeight.clamp(260.0, _baseMaxShellHeight).toDouble();
  return BoxConstraints(maxWidth: 420, maxHeight: dialogMaxHeight);
}

/// 邮箱登录 / 注册表单本体（不含对话框外壳）。
///
/// 两种用法：
/// - **弹出式**（[toastHostContext] 非空、[onSuccess] 为 null）：成功后自行
///   关闭所在的对话框并弹成功 toast，再回调 [afterSuccess]；
/// - **嵌入式**（[onSuccess] 返回 true，云端数据管理用法）：成功后**不**退出
///   所在对话框，由外层自己决定去向（例如切回菜单阶段）。
class EmailLoginForm extends StatefulWidget {
  const EmailLoginForm({
    super.key,
    this.initialEmail,
    this.maxContentHeight,
    this.toastHostContext,
    this.onSuccess,
    this.afterSuccess,
    this.onCancel,
  });

  /// 预填邮箱（设置页填入上次登录账号）
  final String? initialEmail;

  /// 内容最大高度：由调用方按自身对话框壳的可用高度给出。
  /// 非空时表单在该高度内可滚动（键盘弹出、字号放大等场景不溢出）；
  /// 为空则完全按内容自然高度收缩（适用于外层本来就给了有界约束的用法）
  final double? maxContentHeight;

  /// 成功 toast 的宿主 context：弹出式用法下表单所在的路由会被 pop，
  /// toast 必须挂在外层仍然存活的 context 上
  final BuildContext? toastHostContext;

  /// 登录 / 注册成功回调。返回 true 表示调用方已自行接管后续
  /// （不执行默认的「关闭弹窗 + 成功 toast」），返回 false/null 走默认收尾
  final FutureOr<bool> Function(bool isRegisterMode)? onSuccess;

  /// 默认收尾（关闭弹窗 + 成功 toast）之后触发
  final Future<void> Function(bool isRegisterMode)? afterSuccess;

  /// 底部「取消」按钮回调：弹出式是关闭对话框，嵌入式由外层决定去向
  final VoidCallback? onCancel;

  @override
  State<EmailLoginForm> createState() => _EmailLoginFormState();
}

class _EmailLoginFormState extends State<EmailLoginForm> {
  late final TextEditingController _emailController =
      TextEditingController(text: widget.initialEmail ?? '');
  late final TextEditingController _passwordController =
      TextEditingController();
  late final TextEditingController _confirmPasswordController =
      TextEditingController();
  late final TextEditingController _verificationCodeController =
      TextEditingController();

  bool _isRegisterMode = false;
  bool _isSubmitting = false;
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;

  // 注册验证码两件套（CloudBase 注册硬约束；Supabase 路径不显示）
  bool _isSendingCode = false;
  int _resendCountdown = 0;
  Timer? _resendTimer;

  bool get _needsVerificationCode =>
      AuthService.instance.registrationRequiresCode;

  @override
  void dispose() {
    _resendTimer?.cancel();
    // 弹出动画期间 TextField 仍会重建，延迟到动画结束后再释放
    final controllers = [
      _emailController,
      _passwordController,
      _confirmPasswordController,
      _verificationCodeController,
    ];
    Future<void>.delayed(const Duration(milliseconds: 300), () {
      for (final controller in controllers) {
        controller.dispose();
      }
    });
    super.dispose();
  }

  bool get _isEmailValid =>
      RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(_emailController.text.trim());

  bool get _isPasswordValid =>
      AuthService.isStrongPassword(_passwordController.text);

  bool get _isVerificationCodeValid =>
      RegExp(r'^\d{6}$').hasMatch(_verificationCodeController.text.trim());

  bool get _canSubmit =>
      !_isSubmitting &&
      _isEmailValid &&
      _isPasswordValid &&
      (!_isRegisterMode ||
          (_confirmPasswordController.text == _passwordController.text &&
              (!_needsVerificationCode || _isVerificationCodeValid)));

  /// 发送注册验证码：成功后进入 60 秒倒计时（服务端同邮箱 60 秒限一次）
  Future<void> _sendVerificationCode() async {
    if (_isSendingCode || _resendCountdown > 0 || !_isEmailValid) return;
    setState(() => _isSendingCode = true);

    final auth = AuthService.instance;
    final sent =
        await auth.sendRegisterCode(_emailController.text.trim());
    if (!mounted) return;
    setState(() => _isSendingCode = false);

    if (!sent) {
      toastNotification.show(
        context,
        auth.error ?? '验证码发送失败，请稍后再试',
        type: ToastType.error,
      );
      return;
    }

    setState(() => _resendCountdown = 60);
    _resendTimer?.cancel();
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _resendCountdown--);
      if (_resendCountdown <= 0) {
        timer.cancel();
      }
    });

    toastNotification.show(
      context,
      '验证码已发送，请查收邮箱（6 位数字，10 分钟内有效）',
      type: ToastType.success,
    );
  }

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() => _isSubmitting = true);

    final auth = AuthService.instance;
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final success = _isRegisterMode
        ? await auth.registerWithEmailPassword(
            email,
            password,
            verificationCode: _needsVerificationCode
                ? _verificationCodeController.text.trim()
                : null,
          )
        : await auth.signInWithEmailPassword(email, password);
    if (!mounted) return;

    setState(() => _isSubmitting = false);

    if (!success) {
      toastNotification.show(
        context,
        auth.error ??
            (_isRegisterMode ? '注册失败，请稍后重试' : '登录失败，请检查邮箱和密码'),
        type: ToastType.error,
      );
      return;
    }

    // 外层接管（云端数据管理：留在同一个对话框里切阶段）
    final handled = await widget.onSuccess?.call(_isRegisterMode) ?? false;
    if (handled) return;
    if (!mounted) return;

    if (Navigator.of(context).canPop()) {
      Navigator.pop(context);
    }
    final hostContext = widget.toastHostContext;
    final message = _isRegisterMode ? '注册并登录成功' : '登录成功';
    if (hostContext != null && hostContext.mounted) {
      toastNotification.show(hostContext, message, type: ToastType.success);
    } else if (mounted) {
      toastNotification.show(context, message, type: ToastType.success);
    }
    await widget.afterSuccess?.call(_isRegisterMode);
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final confirmPassword = _confirmPasswordController.text;

    // 内容本体 = 滚动容器 + Column：内容不足时贴合内容高度，
    // 超过 [maxContentHeight]（下面套的 ConstrainedBox）时在上限内滚动
    final form = SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Opacity(
            opacity: 0.82,
            child: Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: const Color(0xFF4A90E2),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(
                Icons.email_rounded,
                size: 32,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            '邮箱账号',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          // 登录/注册副标题切换：模糊淡出淡入（与确认密码框的
          // 模糊动效呼应），新旧文案交叉过渡不跳变
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: (child, animation) => FadeTransition(
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
            ),
            child: Text(
              _isRegisterMode ? '使用邮箱和密码创建账号' : '使用邮箱和密码登录',
              key: ValueKey<bool>(_isRegisterMode),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: palette.textSecondary,
              ),
            ),
          ),
          const SizedBox(height: 20),
          // AnimatedSize：错误文案出现/消失时输入框高度平滑过渡
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: AppTextField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              enabled: !_isSubmitting,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: '请输入邮箱地址',
                errorText:
                    email.isEmpty || _isEmailValid ? null : '邮箱格式不正确',
                prefixIcon: const Icon(Icons.email_outlined),
                filled: true,
                fillColor: palette.panel(0.4),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 14),
              ),
            ),
          ),
          // 验证码两件套（输入框 + 发送按钮）：仅注册模式且当前后端要求
          // 验证码（CloudBase）时出现，复用确认密码框的占位展开+模糊淡入动画
          _FieldSlotAppear(
            visible: _isRegisterMode && _needsVerificationCode,
            child: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: AnimatedSize(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                alignment: Alignment.topCenter,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: AppTextField(
                        controller: _verificationCodeController,
                        keyboardType: TextInputType.number,
                        enabled: !_isSubmitting,
                        maxLength: 6,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          counterText: '',
                          hintText: '邮箱验证码',
                          errorText: _verificationCodeController.text.isEmpty ||
                                  _isVerificationCodeValid
                              ? null
                              : '验证码为 6 位数字',
                          prefixIcon: const Icon(Icons.verified_outlined),
                          filled: true,
                          fillColor: palette.panel(0.4),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 14),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      height: 48,
                      child: ElevatedButton(
                        onPressed:
                            (_isSendingCode || _resendCountdown > 0 || !_isEmailValid)
                                ? null
                                : _sendVerificationCode,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF4A90E2),
                          foregroundColor: Colors.white,
                          disabledBackgroundColor:
                              const Color(0xFF4A90E2).withValues(alpha: 0.38),
                          disabledForegroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: Text(
                          _isSendingCode
                              ? '发送中...'
                              : (_resendCountdown > 0
                                  ? '${_resendCountdown}s 后重发'
                                  : '发送验证码'),
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: AppTextField(
              controller: _passwordController,
              keyboardType: TextInputType.visiblePassword,
              obscureText: _obscurePassword,
              enabled: !_isSubmitting,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: '请输入密码',
                errorText: password.isEmpty || _isPasswordValid
                    ? null
                    : '密码需至少8位，且包含字母和数字',
                prefixIcon: const Icon(Icons.lock_outline_rounded),
                suffixIcon: IconButton(
                  onPressed: () {
                    setState(() => _obscurePassword = !_obscurePassword);
                  },
                  icon: Icon(_obscurePassword
                      ? Icons.visibility_off
                      : Icons.visibility),
                ),
                filled: true,
                fillColor: palette.panel(0.4),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 14),
              ),
            ),
          ),
          // 确认密码框常驻树内，由占位展开+模糊淡入动画
          // 控制显隐（动画组件复刻课表切换对话框新增课表）
          _FieldSlotAppear(
            visible: _isRegisterMode,
            child: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: AnimatedSize(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                alignment: Alignment.topCenter,
                child: AppTextField(
                  controller: _confirmPasswordController,
                  keyboardType: TextInputType.visiblePassword,
                  obscureText: _obscureConfirmPassword,
                  enabled: !_isSubmitting,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: '请再次输入密码',
                    errorText: confirmPassword.isEmpty ||
                            confirmPassword == password
                        ? null
                        : '两次密码输入不一致',
                    prefixIcon: const Icon(Icons.lock_reset_rounded),
                    suffixIcon: IconButton(
                      onPressed: () {
                        setState(() =>
                            _obscureConfirmPassword = !_obscureConfirmPassword);
                      },
                      icon: Icon(_obscureConfirmPassword
                          ? Icons.visibility_off
                          : Icons.visibility),
                    ),
                    filled: true,
                    fillColor: palette.panel(0.4),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 14),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _canSubmit ? _submit : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4A90E2),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              icon: Icon(_isRegisterMode
                  ? Icons.person_add_alt_1_rounded
                  : Icons.login_rounded),
              label: Text(
                _isSubmitting
                    ? '处理中...'
                    : (_isRegisterMode ? '注册并登录' : '登录'),
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _isSubmitting
                ? null
                : () {
                    setState(() => _isRegisterMode = !_isRegisterMode);
                    AuthService.instance.clearError();
                  },
            child: Text(_isRegisterMode ? '已有账号？去登录' : '没有账号？去注册'),
          ),
          const SizedBox(height: 8),
          // 与设置页其他对话框的取消按钮统一样式
          // （默认主题色文字 + 灰描边）
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: _isSubmitting ? null : widget.onCancel,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: palette.borderWeak),
                ),
              ),
              child: const Text('取消'),
            ),
          ),
        ],
      ),
    );

    // 高度在给定上限内**自撑**：SingleChildScrollView 在 loose 约束下取
    // 内容自然高度，只有内容超过 maxHeight 时才停在上限并可滚动。
    // 注意不能像早先那样用 SizedBox(height: maxHeight) 定高——那会把
    // 登录模式（内容约 500）也撑到上限，底部白留一两百的空白
    final maxHeight = widget.maxContentHeight;
    if (maxHeight == null) return form;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: form,
    );
  }
}

/// 占位展开 + 模糊淡入的出现动画容器。
///
/// 阶段一（0 ~ 200/420）占位自顶部展开，把下方元素与所在对话框的高度
/// 逐帧推下去；阶段二（200/420 ~ 1）内容自模糊中清晰放大到位。
/// 组件形态原样搬自设置页（原本是那里的私有实现）。
class _FieldSlotAppear extends StatefulWidget {
  const _FieldSlotAppear({required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  State<_FieldSlotAppear> createState() => _FieldSlotAppearState();
}

class _FieldSlotAppearState extends State<_FieldSlotAppear>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
    value: widget.visible ? 1.0 : 0.0,
  );

  static const double _expandFraction = 200 / 420;

  // 阶段一：占位展开（0 ~ 200/420）；阶段二：出现（200/420 ~ 1）
  late final Animatable<double> _expandChain = CurveTween(
    curve: const Interval(0.0, _expandFraction, curve: Curves.easeInCubic),
  );
  late final Animatable<double> _appearChain = CurveTween(
    curve: const Interval(_expandFraction, 1.0, curve: Curves.easeOutCubic),
  );

  @override
  void didUpdateWidget(covariant _FieldSlotAppear oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible == oldWidget.visible) return;
    if (widget.visible) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final expand = _expandChain.transform(_controller.value);
        final appear = _appearChain.transform(_controller.value);
        return SizeTransition(
          sizeFactor: AlwaysStoppedAnimation(expand.clamp(0.0, 1.0)),
          axisAlignment: -1.0,
          child: Opacity(
            opacity: appear.clamp(0.0, 1.0),
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(
                sigmaX: 14 * (1.0 - appear),
                sigmaY: 14 * (1.0 - appear),
              ),
              child: Transform.scale(
                scale: 0.55 + 0.45 * appear,
                child: child,
              ),
            ),
          ),
        );
      },
      child: widget.child,
    );
  }
}
