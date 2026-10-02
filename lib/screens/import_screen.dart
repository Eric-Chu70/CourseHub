import 'dart:ui';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:convert';
import 'dart:io';
import '../utils/storage.dart';
import '../widgets/toast_notification.dart';
import '../widgets/ai_processing_dialog.dart';
import '../widgets/glass_dialog.dart';
import '../services/glm_service.dart';
import '../models/course.dart';
import '../utils/course_color_palette.dart';
import '../widgets/blur_selection_menu.dart';
import '../widgets/gradient_blur_header.dart';
import 'shiguang_school_select_screen.dart';
import '../services/shiguang/shiguang_index_service.dart';
import '../services/shiguang/shiguang_models.dart';
import '../widgets/app_text_field.dart';
import '../dialogs/cloud_data_manager_dialog.dart';

class ImportScreen extends StatefulWidget {
  const ImportScreen({super.key});

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  bool _isImporting = false;

  /// 「教务系统导入」副标题里的高校数量：取学校索引里的真实高校条数，
  /// 前 5 条通用条目（通用工具 + 四大通用教务，`isGeneric`）不计入。
  /// null = 还没拿到或拉取失败，此时副标题回退成原来的 150+。
  ///
  /// 数据源是 [ShiguangIndexService.schoolsOrNull] 而不是本页自己的字段：
  /// 本页压在教务系统卡片之上打开的「选择学校」页返回时并不会重建，
  /// 只在 initState 算一次就得切走再切回才更新；listen 服务的发布源，
  /// 选择页刷新完数字当场就跟着变。
  String _shiguangCardSubtitle(List<ShiguangSchool>? schools) => schools == null
      ? '适配 150+ 所高校教务系统一键导入'
      : '适配 ${_realSchoolCount(schools)} 所高校教务系统一键导入';

  @override
  void initState() {
    super.initState();
    _ensureShiguangIndex();
  }

  /// 进入导入页时确保索引被读过一次：缓存能给就直接发布；一小时内没拉过
  /// （与选择学校页同一个冷却窗口）才补一次网络，离线/失败保留上一次
  /// 的数字或回退 150+，不因为取数量而把页面卡在加载态。
  Future<void> _ensureShiguangIndex() async {
    final cached = await ShiguangIndexService.peekCachedIndex();
    if (cached != null && cached.withinAutoRefreshCooldown) return;
    try {
      await ShiguangIndexService.getSchoolIndex();
    } catch (_) {
      // 拿不到就维持现状（有缓存显示缓存，否则回退 150+）
    }
  }

  /// 只数真实高校：索引前 5 条是通用工具与通用教务（id 在
  /// genericFolderIds 里），不算一所学校，不计进副标题。
  static int _realSchoolCount(List<ShiguangSchool> schools) =>
      schools.where((s) => !s.isGeneric).length;

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;

    return Scaffold(
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? AppPalette.dark.scaffold
          : const Color(0xFFF8F9FC),
      body: Stack(
        children: [
          CustomScrollView(
            physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics()),
            slivers: [
              SliverPadding(
                padding: EdgeInsets.only(top: topPadding + 62),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 140),
                sliver: SliverList(
                  delegate: SliverChildListDelegate([
                    Column(
                      children: [
                        _buildImportCard(
                          context,
                          icon: Icons.image,
                          color: Colors.blue,
                          title: '图片识别',
                          subtitle: '上传课程表图片，自动识别',
                          onTap: _isImporting
                              ? null
                              : () => _showImageSourceDialog(context),
                        ),
                        const SizedBox(height: 12),
                        ValueListenableBuilder<List<ShiguangSchool>?>(
                          valueListenable: ShiguangIndexService.schoolsOrNull,
                          builder: (context, schools, _) => _buildImportCard(
                            context,
                            icon: Icons.school,
                            // 回退：这张卡的紫不是品牌强调色，而是五张导入卡
                            // 互相区分的色标（图片=蓝 / 教务=紫 / JSON=绿 /
                            // 导出=橙 / 云端=蓝）。改成 4A90E2 后它跟第一张
                            // Colors.blue 几乎同色，色标意义就没了。
                            color: const Color(0xFF9B59B6),
                            title: '教务系统导入',
                            titleTrailing: const _ShiguangHelpIcon(),
                            // 拿到真实条数就不再加「+」；回退态维持原文案
                            subtitle: _shiguangCardSubtitle(schools),
                            onTap: _isImporting
                                ? null
                                : () => _openShiguangImport(context),
                          ),
                        ),
                        const SizedBox(height: 12),
                        _buildImportCard(
                          context,
                          icon: Icons.code,
                          color: Colors.green,
                          title: 'JSON 导入',
                          subtitle: '从 JSON 文件导入课程表数据',
                          onTap: _isImporting
                              ? null
                              : () => _showImportOptions(context),
                        ),
                        const SizedBox(height: 12),
                        _buildImportCard(
                          context,
                          icon: Icons.download,
                          color: Colors.orange,
                          title: '导出数据',
                          subtitle: '将当前数据导出为 JSON 文件',
                          onTap: () => _exportData(context),
                        ),
                        const SizedBox(height: 12),
                        _buildImportCard(
                          context,
                          icon: Icons.cloud_sync_rounded,
                          color: const Color(0xFF4A90E2),
                          title: '云端数据管理',
                          subtitle: '备份到云端、云端同步、删除云端数据',
                          onTap: _showCloudDataManagerDialog,
                        ),
                        const SizedBox(height: 24),
                        _buildInfoCard(),
                      ],
                    ),
                  ]),
                ),
              ),
            ],
          ),
          _buildPinnedHeader(topPadding),
        ],
      ),
    );
  }

  Widget _buildPinnedHeader(double topPadding) {
    // 无界渐变标题栏（同设置页）：模糊/雾化自顶部向底缘衰减归零
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      child: GradientBlurHeader(
        topPadding: topPadding,
        title: '导入导出',
        // 雾面曲线整体下移 6px（绘制区不越出标题栏，减弱模式同样
        // 生效）：同高度浓度=原上移 6px 处，标题下方一行可读性↑
        blurCurveShift: 6,
        // 标题栏本体增高 6px：内容区起始位置随之下移（列表顶部偏移
        // 已同步 +6），底部坡面多出 6px 渐变空间
        layoutBottomExtend: 6,
      ),
    );
  }

  Widget _buildImportCard(
    BuildContext context, {
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    VoidCallback? onTap,
    Widget? titleTrailing,
  }) {
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  color: color.withAlpha(25),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: color, size: 24),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        if (titleTrailing != null) ...[
                          const SizedBox(width: 6),
                          titleTrailing,
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.of(context).textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: onTap == null
                    ? AppColors.of(context).borderWeak
                    : AppColors.of(context).textTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfoCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.bannerBg(context, Colors.blue),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.bannerBorder(context, Colors.blue)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline,
                  color: AppColors.bannerText(context, Colors.blue), size: 20),
              const SizedBox(width: 8),
              Text(
                '使用说明',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: AppColors.bannerText(context, Colors.blue),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildInfoItem('导入仅影响当前课表，不会修改其他课表数据'),
          _buildInfoItem('合并模式：保留现有数据，添加新数据'),
          _buildInfoItem('替换模式：清空当前课表后导入新数据'),
          _buildInfoItem('导出的 JSON 文件可用于备份或迁移数据'),
          _buildInfoItem('暂不支持云端备份AI配置（安全风险高）'),
        ],
      ),
    );
  }

  Widget _buildInfoItem(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 6),
            width: 4,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.bannerText(context, Colors.blue),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                color: AppColors.bannerText(context, Colors.blue),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showImportOptions(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        margin: const EdgeInsets.all(16),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.of(context)
                    .glassShell
                    .withValues(alpha: AppColors.isDark(context) ? 0.82 : 0.35),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: AppColors.of(context).glassBorder,
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.15),
                    blurRadius: 25,
                    spreadRadius: 2,
                    offset: const Offset(0, -4),
                  ),
                  BoxShadow(
                    color: Colors.white.withValues(alpha: 0.6),
                    blurRadius: 0,
                    offset: const Offset(0, -1),
                  ),
                ],
              ),
              child: SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            '选择导入方式',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          GestureDetector(
                            onTap: () => Navigator.pop(context),
                            child: Container(
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(
                                color: AppColors.of(context).surfaceAlt,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(Icons.close,
                                  size: 18,
                                  color: AppColors.of(context).textSecondary),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          Expanded(
                            child: _buildImportOptionCard(
                              icon: Icons.folder_open,
                              label: '从文件',
                              color: Colors.green,
                              onTap: () {
                                Navigator.pop(context);
                                _importFromFile(context);
                              },
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildImportOptionCard(
                              icon: Icons.paste,
                              label: '粘贴JSON',
                              color: Colors.blue,
                              onTap: () {
                                Navigator.pop(context);
                                _showPasteJsonDialog(context);
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildImportOptionCard({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 20),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withValues(alpha: 0.2)),
        ),
        child: Column(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color, size: 24),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 教务系统导入入口：WebView 引擎不支持 Web 平台。
  void _openShiguangImport(BuildContext context) {
    if (kIsWeb) {
      toastNotification.show(
        context,
        '教务系统导入目前不支持 Web 端使用',
        type: ToastType.info,
      );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const ShiguangSchoolSelectScreen(),
      ),
    );
  }

  Future<void> _importFromFile(BuildContext context) async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json', 'txt'],
      );

      if (result != null && result.files.single.path != null) {
        final file = File(result.files.single.path!);
        final content = await file.readAsString();
        if (!mounted) return;
        await _processJsonData(context, content);
      }
    } catch (e) {
      if (mounted) {
        toastNotification.show(context, '读取文件失败：$e', type: ToastType.error);
      }
    }
  }

  void _showPasteJsonDialog(BuildContext context) {
    final controller = TextEditingController();

    showBouncyDialog(
      context: context,
      barrierLabel: '粘贴JSON',
      shellPadding: const EdgeInsets.all(24),
      shellBoxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.2),
          blurRadius: 20,
          offset: const Offset(0, 10),
        ),
      ],
      avoidKeyboard: true,
      // 壳总宽/总高约束含壳内边距（与旧版壳外 Container(constraints:) 一致）；
      // 键盘弹出时动态压缩最大高度，闭包内 MediaQuery 依赖使宿主自动重建
      shellConstraintsBuilder: (context) {
        final mediaQuery = MediaQuery.of(context);
        final keyboardHeight = mediaQuery.viewInsets.bottom;
        final topInset = mediaQuery.padding.top;
        final screenHeight = mediaQuery.size.height;
        const baseMaxHeight = 500.0;
        double dialogMaxHeight = baseMaxHeight;
        final availableHeight = screenHeight - topInset - keyboardHeight - 24;
        if (availableHeight < dialogMaxHeight) {
          dialogMaxHeight = availableHeight;
        }
        dialogMaxHeight =
            dialogMaxHeight.clamp(260.0, baseMaxHeight).toDouble();
        return BoxConstraints(maxWidth: 400, maxHeight: dialogMaxHeight);
      },
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
                    colors: [Color(0xFF4CAF50), Color(0xFF81C784)],
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.paste,
                  size: 32,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              '粘贴 JSON 数据',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '粘贴课程表 JSON 数据进行导入',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: AppColors.of(context).textSecondary,
              ),
            ),
            const SizedBox(height: 20),
            Expanded(
              child: AppTextField(
                contextMenuBuilder: styledEditableContextMenu,
                controller: controller,
                maxLines: null,
                expands: true,
                decoration: InputDecoration(
                  hintText: '在此粘贴 JSON 数据...',
                  hintStyle:
                      TextStyle(color: AppColors.of(context).textTertiary),
                  filled: true,
                  fillColor: AppColors.of(context).panel(0.4),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side:
                            BorderSide(color: AppColors.of(context).borderWeak),
                      ),
                    ),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () async {
                      Navigator.pop(context);
                      await _processJsonData(context, controller.text);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('导入'),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Future<void> _processJsonData(BuildContext context, String jsonStr) async {
    if (jsonStr.trim().isEmpty) {
      toastNotification.show(context, 'JSON 数据为空', type: ToastType.error);
      return;
    }

    try {
      final data = json.decode(jsonStr);
      if (data is! Map<String, dynamic>) {
        toastNotification.show(context, 'JSON 格式无效', type: ToastType.error);
        return;
      }

      _showImportModeDialog(context, data);
    } catch (e) {
      toastNotification.show(context, 'JSON 解析失败：$e', type: ToastType.error);
    }
  }

  void _showImportModeDialog(BuildContext context, Map<String, dynamic> data) {
    ImportMode selectedMode = ImportMode.merge;

    showBouncyDialog(
      context: context,
      barrierLabel: '选择导入模式',
      shellPadding: const EdgeInsets.all(24),
      // 壳总宽约束含壳内边距（与旧版壳外 ConstrainedBox(constraints:) 一致）
      shellMaxWidth: 400,
      shellBoxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.2),
          blurRadius: 20,
          offset: const Offset(0, 10),
        ),
      ],
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
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
                      Icons.settings_suggest,
                      size: 32,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  '选择导入模式',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 20),
                _buildModeOption(
                  title: '合并导入',
                  subtitle: '保留现有数据，添加新数据',
                  icon: Icons.merge_type,
                  color: Colors.green,
                  isSelected: selectedMode == ImportMode.merge,
                  onTap: () =>
                      setDialogState(() => selectedMode = ImportMode.merge),
                ),
                const SizedBox(height: 12),
                _buildModeOption(
                  title: '替换导入',
                  subtitle: '清空现有数据后导入',
                  icon: Icons.refresh,
                  color: Colors.orange,
                  isSelected: selectedMode == ImportMode.replace,
                  onTap: () =>
                      setDialogState(() => selectedMode = ImportMode.replace),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.pop(context),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(
                                color: AppColors.of(context).borderWeak),
                          ),
                        ),
                        child: const Text('取消'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () async {
                          Navigator.pop(context);
                          await _performImport(context, data, selectedMode);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF4A90E2),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: const Text('开始导入'),
                      ),
                    ),
                  ],
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildModeOption({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isSelected
              ? color.withValues(alpha: 0.1)
              : AppColors.of(context).panel(0.4),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? color : AppColors.of(context).borderWeak,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: color, size: 20),
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
                      color: isSelected
                          ? color
                          : AppColors.of(context).textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.of(context).textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            if (isSelected) Icon(Icons.check_circle, color: color, size: 22),
          ],
        ),
      ),
    );
  }

  Future<void> _performImport(
      BuildContext context, Map<String, dynamic> data, ImportMode mode) async {
    setState(() => _isImporting = true);

    try {
      final result = await StorageService.importData(data, mode: mode);

      if (mounted) {
        if (result.success) {
          toastNotification.show(
            context,
            '导入成功！${result.summary}',
            type: ToastType.success,
          );
        } else {
          toastNotification.show(
            context,
            result.errorMessage ?? '导入失败',
            type: ToastType.error,
          );
        }
      }
    } catch (e) {
      if (mounted) {
        toastNotification.show(context, '导入失败：$e', type: ToastType.error);
      }
    } finally {
      if (mounted) {
        setState(() => _isImporting = false);
      }
    }
  }

  Future<void> _exportData(BuildContext context) async {
    try {
      final data = StorageService.exportData();
      final jsonStr = const JsonEncoder.withIndent('  ').convert(data);

      await Share.share(
        jsonStr,
        subject: 'CourseHub 数据备份 ${DateTime.now().toString().split(' ').first}',
      );

      if (mounted) {
        toastNotification.show(context, '导出成功', type: ToastType.success);
      }
    } catch (e) {
      if (mounted) {
        toastNotification.show(context, '导出失败：$e', type: ToastType.error);
      }
    }
  }

  /// 云端数据管理：多阶段对话框（主菜单 → 备份 / 同步 / 删除都在同一个
  /// 对话框内完成，阶段切换带模糊淡入淡出过渡 + 高度连贯变化）。
  /// 执行结果由对话框返回，这里统一 toast 提示。
  Future<void> _showCloudDataManagerDialog() async {
    final result = await showCloudDataManagerDialog(context);
    if (!mounted || result == null) return;
    toastNotification.show(
      context,
      result.message,
      type: result.success ? ToastType.success : ToastType.error,
    );
  }

  void _showImageSourceDialog(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        margin: const EdgeInsets.all(16),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.of(context)
                    .glassShell
                    .withValues(alpha: AppColors.isDark(context) ? 0.82 : 0.35),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: AppColors.of(context).glassBorder,
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.15),
                    blurRadius: 25,
                    spreadRadius: 2,
                    offset: const Offset(0, -4),
                  ),
                  BoxShadow(
                    color: Colors.white.withValues(alpha: 0.6),
                    blurRadius: 0,
                    offset: const Offset(0, -1),
                  ),
                ],
              ),
              child: SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            '选择图片来源',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          GestureDetector(
                            onTap: () => Navigator.pop(context),
                            child: Container(
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(
                                color: AppColors.of(context).surfaceAlt,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(Icons.close,
                                  size: 18,
                                  color: AppColors.of(context).textSecondary),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          Expanded(
                            child: _buildImportOptionCard(
                              icon: Icons.camera_alt,
                              label: '拍照',
                              color: Colors.blue,
                              onTap: () {
                                Navigator.pop(context);
                                _recognizeFromImage(ImageSource.camera);
                              },
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildImportOptionCard(
                              icon: Icons.photo_library,
                              label: '相册',
                              color: Colors.green,
                              onTap: () {
                                Navigator.pop(context);
                                _recognizeFromImage(ImageSource.gallery);
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _recognizeFromImage(ImageSource source) async {
    try {
      final picker = ImagePicker();
      final XFile? image =
          await picker.pickImage(source: source, imageQuality: 85);

      if (image == null) return;
      if (!mounted) return;

      await AIProcessingDialog.show(
        context,
        imagePath: image.path,
        onCompleted: (courses) async {
          if (!mounted) return;
          await _importParsedCourses(context, courses);
        },
      );
    } catch (e) {
      if (mounted) {
        toastNotification.show(context, '操作失败：$e', type: ToastType.error);
      }
    }
  }

  Future<void> _importParsedCourses(
      BuildContext context, List<CourseData> courses) async {
    try {
      await StorageService.resetCurrentWeek();
      if (!mounted) return;

      final baseTime = DateTime.now().millisecondsSinceEpoch;
      final courseList = courses.asMap().entries.map((entry) {
        final index = entry.key;
        final c = entry.value;
        final timeSlot = (c.period ?? _getTimeSlot(c.startTime ?? '08:00')) - 1;
        final fallbackColor = CourseColorPalette.extendedHexColors[
            index % CourseColorPalette.extendedHexColors.length];
        return Course(
          id: '${baseTime}_${index}_${c.name.hashCode}',
          name: c.name,
          teacher: c.teacher ?? '',
          location: c.location ?? '',
          day: c.dayOfWeek - 1,
          time: timeSlot,
          duration: c.duration ??
              _calculateDuration(c.startTime ?? '08:00', c.endTime ?? '09:40'),
          weeks: c.weeks ??
              (c.startWeek != null && c.endWeek != null
                  ? '${c.startWeek}-${c.endWeek}'
                  : null),
          color: CourseColorPalette.normalizeHexColor(c.color,
              fallbackHex: fallbackColor),
        );
      }).toList();

      final data = {
        'courses': courseList
            .map((c) => {
                  'id': c.id,
                  'name': c.name,
                  'teacher': c.teacher,
                  'location': c.location,
                  'day': c.day,
                  'time': c.time,
                  'duration': c.duration,
                  'weeks': c.weeks,
                  'color': c.color,
                })
            .toList(),
      };

      await _performImport(context, data, ImportMode.merge);
    } catch (e) {
      if (mounted) {
        toastNotification.show(context, '导入失败：$e', type: ToastType.error);
      }
    }
  }

  int _getTimeSlot(String? startTime) {
    if (startTime == null) return 1;
    final hour = int.tryParse(startTime.split(':')[0]) ?? 8;
    final minute = int.tryParse(
            startTime.split(':').length > 1 ? startTime.split(':')[1] : '0') ??
        0;
    final totalMinutes = hour * 60 + minute;

    if (totalMinutes >= 7 * 60 + 30 && totalMinutes < 10 * 60) return 1;
    if (totalMinutes >= 10 * 60 && totalMinutes < 12 * 60 + 30) return 3;
    if (totalMinutes >= 13 * 60 + 30 && totalMinutes < 16 * 60) return 5;
    if (totalMinutes >= 16 * 60 && totalMinutes < 18 * 60 + 30) return 7;
    if (totalMinutes >= 18 * 60 + 30 && totalMinutes < 21 * 60) return 9;
    return 1;
  }

  int _calculateDuration(String? startTime, String? endTime) {
    if (startTime == null || endTime == null) return 2;
    try {
      final startParts = startTime.split(':');
      final endParts = endTime.split(':');
      final startMinutes =
          int.parse(startParts[0]) * 60 + int.parse(startParts[1]);
      final endMinutes = int.parse(endParts[0]) * 60 + int.parse(endParts[1]);
      return ((endMinutes - startMinutes) / 90).round().clamp(1, 3);
    } catch (e) {
      return 2;
    }
  }
}

/// 「教务系统导入」标题问号：点击在问号下方弹出两段说明气泡
/// （样式与动画同设置页问号提示：easeOutBack 弹出 / easeInCubic
/// 收回，220ms），点击空白处收回。
class _ShiguangHelpIcon extends StatefulWidget {
  const _ShiguangHelpIcon();

  @override
  State<_ShiguangHelpIcon> createState() => _ShiguangHelpIconState();
}

class _ShiguangHelpIconState extends State<_ShiguangHelpIcon> {
  final GlobalKey _iconKey = GlobalKey();
  OverlayEntry? _tipEntry;
  bool _tipVisible = false;

  void _toggleTip() {
    if (_tipEntry != null) {
      _removeTip();
      return;
    }
    final iconBox = _iconKey.currentContext?.findRenderObject() as RenderBox?;
    if (iconBox == null) return;
    final iconPos = iconBox.localToGlobal(Offset.zero);
    final iconSize = iconBox.size;
    // 气泡水平居中（两侧各留 16px 屏幕边距），纵向自问号下方弹出。
    final top = iconPos.dy + iconSize.height + 6;
    _tipVisible = true;
    _tipEntry = OverlayEntry(
      builder: (context) => Stack(
        children: [
          // 透明屏障：点击气泡以外的任意处收回。
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _removeTip,
            ),
          ),
          _ShiguangHelpTip(
            visible: _tipVisible,
            top: top,
            onDismissed: () {
              _tipEntry?.remove();
              _tipEntry = null;
            },
          ),
        ],
      ),
    );
    Overlay.of(context).insert(_tipEntry!);
  }

  void _removeTip() {
    if (_tipEntry == null) return;
    // 翻转 visible 触发收回动画，动画完成后由 onDismissed 移除 entry。
    _tipVisible = false;
    _tipEntry!.markNeedsBuild();
  }

  @override
  void dispose() {
    // 页面关闭时同步移除气泡。
    _tipEntry?.remove();
    _tipEntry = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: _iconKey,
      behavior: HitTestBehavior.opaque,
      onTap: _toggleTip,
      child: Icon(
        Icons.help_outline,
        size: 16,
        color: AppColors.of(context).textTertiary,
      ),
    );
  }
}

/// 教务系统导入说明气泡：水平居中（两侧各留 16px 屏幕边距），
/// 自问号下方弹出（下滑出 + 淡入），收回时向上缩回并淡出，
/// 两段文字（说明 + 鸣谢）。
class _ShiguangHelpTip extends StatefulWidget {
  final bool visible;
  final double top;
  final VoidCallback? onDismissed;

  const _ShiguangHelpTip({
    required this.visible,
    required this.top,
    this.onDismissed,
  });

  @override
  State<_ShiguangHelpTip> createState() => _ShiguangHelpTipState();
}

class _ShiguangHelpTipState extends State<_ShiguangHelpTip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

  late final CurvedAnimation _curved = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutBack,
    reverseCurve: Curves.easeInCubic,
  );

  @override
  void initState() {
    super.initState();
    if (widget.visible) {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(covariant _ShiguangHelpTip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible == oldWidget.visible) return;
    if (widget.visible) {
      _controller.forward();
    } else {
      _controller.reverse().whenCompleteOrCancel(() {
        if (mounted) widget.onDismissed?.call();
      });
    }
  }

  @override
  void dispose() {
    _curved.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 水平居中：两侧各留 16px 屏幕边距，内容不足时收缩换行。
    final maxTipWidth = MediaQuery.of(context).size.width - 32;
    return Positioned(
      left: 16,
      right: 16,
      top: widget.top,
      child: AnimatedBuilder(
        animation: _curved,
        builder: (context, child) {
          final t = _curved.value;
          return Opacity(
            // easeOutBack 会过冲超过 1.0，透明度需夹取。
            opacity: t.clamp(0.0, 1.0),
            child: Transform.translate(
              // 自问号图标处（上方）向下滑出；收回时向上缩回图标处。
              offset: Offset(0, -14 * (1 - t)),
              child: Transform.scale(
                // 顶部对齐缩放：视觉上自图标处向下展开/向上收起。
                scale: 0.85 + 0.15 * t,
                alignment: Alignment.topCenter,
                child: child,
              ),
            ),
          );
        },
        child: Align(
          alignment: Alignment.topCenter,
          child: Material(
            color: Colors.transparent,
            child: Container(
              constraints: BoxConstraints(maxWidth: maxTipWidth),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.of(context).surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.of(context).borderWeak),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.15),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '如未适配您所在的高校，建议使用图片识别导入，更加高效便捷',
                    style: TextStyle(
                        fontSize: 12, color: AppColors.of(context).textPrimary),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '适配作者鸣谢：GitHub@shiguang_warehouse',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.of(context).textTertiary,
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
}
