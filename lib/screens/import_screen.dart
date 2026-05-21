import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:io';
import '../utils/storage.dart';
import '../widgets/toast_notification.dart';
import '../widgets/ai_processing_dialog.dart';
import '../services/auth_service.dart';
import '../services/cloud_sync_service.dart';
import '../services/ocr_service.dart';
import '../services/glm_service.dart';
import '../models/course.dart';
import '../utils/course_color_palette.dart';

class ImportScreen extends StatefulWidget {
  const ImportScreen({super.key});

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  bool _isImporting = false;
  static const int _maxCloudTimetableCount = 5;

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;
    
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FC),
      body: Stack(
        children: [
          CustomScrollView(
            physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
            slivers: [
              SliverPadding(
                padding: EdgeInsets.only(top: topPadding + 56),
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
                          onTap: _isImporting ? null : () => _showImageSourceDialog(context),
                        ),
                        const SizedBox(height: 12),
                        _buildImportCard(
                          context,
                          icon: Icons.code,
                          color: Colors.green,
                          title: 'JSON 导入',
                          subtitle: '从 JSON 文件导入课程表数据',
                          onTap: _isImporting ? null : () => _showImportOptions(context),
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
                const SizedBox(
                  height: 56,
                  child: Center(
                    child: Text(
                      '导入导出',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1A1A2E),
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

  Widget _buildImportCard(
    BuildContext context, {
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    VoidCallback? onTap,
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
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: onTap == null ? Colors.grey.shade300 : Colors.grey.shade400,
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
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.blue.shade100),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline, color: Colors.blue.shade700, size: 20),
              const SizedBox(width: 8),
              Text(
                '使用说明',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: Colors.blue.shade700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildInfoItem('导入仅影响当前课表，不会修改其他课表数据'),
          _buildInfoItem('合并模式：保留现有数据，添加新数据'),
          _buildInfoItem('替换模式：清空当前课表后导入新数据'),
          _buildInfoItem('导出的 JSON 文件可用于备份或迁移数据'),
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
              color: Colors.blue.shade400,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                color: Colors.blue.shade700,
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
                color: Colors.white.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.8),
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
                                color: Colors.grey.shade100,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(Icons.close, size: 18, color: Colors.grey.shade600),
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

  Future<void> _importFromFile(BuildContext context) async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json', 'txt'],
      );

      if (result != null && result.files.single.path != null) {
        final file = File(result.files.single.path!);
        final content = await file.readAsString();
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
    
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '粘贴JSON',
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, animation, secondaryAnimation) {
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
        dialogMaxHeight = dialogMaxHeight.clamp(260.0, baseMaxHeight).toDouble();

        return BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
          child: Center(
            child: Material(
              color: Colors.transparent,
              child: FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.9, end: 1.0).animate(
                    CurvedAnimation(parent: animation, curve: Curves.easeOut),
                  ),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                    margin: EdgeInsets.only(
                      left: 24,
                      right: 24,
                      top: keyboardHeight > 0 ? topInset + 8 : 0,
                      bottom: keyboardHeight > 0 ? keyboardHeight + 8 : 0,
                    ),
                    padding: const EdgeInsets.all(24),
                    constraints: BoxConstraints(maxWidth: 400, maxHeight: dialogMaxHeight),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.2),
                          blurRadius: 20,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
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
                            color: Colors.grey.shade600,
                          ),
                        ),
                        const SizedBox(height: 20),
                        Expanded(
                          child: TextField(
                            controller: controller,
                            maxLines: null,
                            expands: true,
                            decoration: InputDecoration(
                              hintText: '在此粘贴 JSON 数据...',
                              hintStyle: TextStyle(color: Colors.grey.shade400),
                              filled: true,
                              fillColor: Colors.grey.shade50,
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
                                    side: BorderSide(color: Colors.grey.shade300),
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
    
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '选择导入模式',
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, animation, secondaryAnimation) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
              child: Center(
                child: Material(
                  color: Colors.transparent,
                  child: FadeTransition(
                    opacity: animation,
                    child: ScaleTransition(
                      scale: Tween<double>(begin: 0.9, end: 1.0).animate(
                        CurvedAnimation(parent: animation, curve: Curves.easeOut),
                      ),
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 24),
                        padding: const EdgeInsets.all(24),
                        constraints: const BoxConstraints(maxWidth: 400),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.2),
                              blurRadius: 20,
                              offset: const Offset(0, 10),
                            ),
                          ],
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
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
                              onTap: () => setDialogState(() => selectedMode = ImportMode.merge),
                            ),
                            const SizedBox(height: 12),
                            _buildModeOption(
                              title: '替换导入',
                              subtitle: '清空现有数据后导入',
                              icon: Icons.refresh,
                              color: Colors.orange,
                              isSelected: selectedMode == ImportMode.replace,
                              onTap: () => setDialogState(() => selectedMode = ImportMode.replace),
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
                                        side: BorderSide(color: Colors.grey.shade300),
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
                        ),
                      ),
                    ),
                  ),
                ),
              ),
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
          color: isSelected ? color.withValues(alpha: 0.1) : Colors.grey.shade50,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? color : Colors.grey.shade200,
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
                      color: isSelected ? color : Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
            ),
            if (isSelected)
              Icon(Icons.check_circle, color: color, size: 22),
          ],
        ),
      ),
    );
  }

  Future<void> _performImport(BuildContext context, Map<String, dynamic> data, ImportMode mode) async {
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

  void _showCloudDataManagerDialog() {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '云端数据管理',
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        return BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
          child: Center(
            child: Material(
              color: Colors.transparent,
              child: FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.9, end: 1.0).animate(
                    CurvedAnimation(parent: animation, curve: Curves.easeOut),
                  ),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 24),
                    padding: const EdgeInsets.all(24),
                    constraints: const BoxConstraints(maxWidth: 420),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.2),
                          blurRadius: 20,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [Color(0xFF4A90E2), Color(0xFF5BA0F2)],
                            ),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: const Icon(
                            Icons.cloud_sync_rounded,
                            size: 32,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          '云端数据管理',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '请选择你要执行的云端操作',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey.shade600,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 20),
                        _buildCloudActionTile(
                          icon: Icons.cloud_upload_rounded,
                          color: Colors.green,
                          title: '备份数据到云端',
                          subtitle: '可多选课表备份（含任务和设置）',
                          onTap: () async {
                            Navigator.pop(dialogContext);
                            await _backupToCloud();
                          },
                        ),
                        const SizedBox(height: 10),
                        _buildCloudActionTile(
                          icon: Icons.cloud_download_rounded,
                          color: const Color(0xFF4A90E2),
                          title: '从云端同步数据',
                          subtitle: '支持合并到本地或云端覆盖本地',
                          onTap: () async {
                            Navigator.pop(dialogContext);
                            await _syncFromCloud();
                          },
                        ),
                        const SizedBox(height: 10),
                        _buildCloudActionTile(
                          icon: Icons.folder_open_rounded,
                          color: Colors.orange,
                          title: '管理云端数据',
                          subtitle: '查看云端课表列表并删除',
                          onTap: () async {
                            Navigator.pop(dialogContext);
                            await _manageCloudData();
                          },
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: TextButton(
                            onPressed: () => Navigator.pop(dialogContext),
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                                side: BorderSide(color: Colors.grey.shade300),
                              ),
                            ),
                            child: const Text('关闭'),
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
      },
    );
  }

  Widget _buildCloudActionTile({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: Ink(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.2)),
        ),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.2),
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
                          color: color,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade600,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: Colors.grey.shade400),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _backupToCloud() async {
    if (!_isCloudLoginReady()) {
      return;
    }

    final timetables = StorageService.getTimetables();
    if (timetables.isEmpty) {
      toastNotification.show(context, '当前没有可备份的课表', type: ToastType.info);
      return;
    }

    final selectedIds = await _showCloudBackupTimetableMultiSelectDialog(timetables);
    if (selectedIds == null || selectedIds.isEmpty) {
      return;
    }

    final cloudSync = CloudSyncService.instance;
    final selectedPayload = StorageService.exportSelectedDataByTimetableIds(selectedIds);
    final selectedNames = StorageService.getCloudBackupTimetableNames(selectedPayload);
    if (selectedNames.isEmpty) {
      toastNotification.show(context, '所选课表没有可备份的数据', type: ToastType.info);
      return;
    }

    final cloudBackup = await cloudSync.fetchBackup();
    if (!mounted) return;

    if (cloudBackup == null && cloudSync.lastError != null) {
      toastNotification.show(context, cloudSync.lastError!, type: ToastType.error);
      return;
    }

    final payload = cloudBackup == null
        ? selectedPayload
        : _mergeSelectedTimetablesIntoCloudPayload(
            cloudPayload: cloudBackup.payload,
            selectedPayload: selectedPayload,
          );

    final cloudCount = StorageService.getCloudBackupTimetableNames(payload).length;
    if (cloudCount > _maxCloudTimetableCount) {
      toastNotification.show(
        context,
        '云端最多保留 $_maxCloudTimetableCount 张课表，当前将达到 $cloudCount 张，请减少备份选择或先删除部分云端课表',
        type: ToastType.error,
      );
      return;
    }

    final success = await cloudSync.uploadBackup(payload);

    if (!mounted) return;

    toastNotification.show(
      context,
      success
          ? (cloudBackup == null
              ? '已备份 ${selectedNames.length} 个课表到云端'
              : '已合并备份 ${selectedNames.length} 个课表，云端现有 $cloudCount 张课表')
          : (cloudSync.lastError ?? '云端备份失败，请稍后重试'),
      type: success ? ToastType.success : ToastType.error,
    );
  }

  Map<String, dynamic> _mergeSelectedTimetablesIntoCloudPayload({
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
      'currentTimetableId': (selectedCurrentId != null && selectedCurrentId.isNotEmpty)
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
          named[entry.key as String] = Map<String, dynamic>.from(entry.value as Map);
        }
      }
    }

    final hasLegacyData =
        (payload['courses'] is List) || (payload['tasks'] is List) || (payload['settings'] is Map);
    if (hasLegacyData && !named.containsKey('当前课表')) {
      named['当前课表'] = {
        'courses': payload['courses'] is List ? List<dynamic>.from(payload['courses'] as List) : <dynamic>[],
        'tasks': payload['tasks'] is List ? List<dynamic>.from(payload['tasks'] as List) : <dynamic>[],
        'settings': payload['settings'] is Map
            ? Map<String, dynamic>.from(payload['settings'] as Map)
            : <String, dynamic>{},
      };
    }

    return named;
  }

  Future<List<String>?> _showCloudBackupTimetableMultiSelectDialog(List<TimetableInfo> timetables) {
    return showGeneralDialog<List<String>>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '选择备份课表',
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        final selectedIds = timetables.map((t) => t.id).toSet();

        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
              child: Center(
                child: Material(
                  color: Colors.transparent,
                  child: FadeTransition(
                    opacity: animation,
                    child: ScaleTransition(
                      scale: Tween<double>(begin: 0.9, end: 1.0).animate(
                        CurvedAnimation(parent: animation, curve: Curves.easeOut),
                      ),
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 24),
                        padding: const EdgeInsets.all(24),
                        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 560),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.2),
                              blurRadius: 20,
                              offset: const Offset(0, 10),
                            ),
                          ],
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 64,
                              height: 64,
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                  colors: [Color(0xFF4A90E2), Color(0xFF5BA0F2)],
                                ),
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: const Icon(
                                Icons.library_add_check_rounded,
                                size: 32,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 16),
                            const Text(
                              '选择要备份的课表',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '可多选，未选中的课表不会上传',
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.grey.shade600,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                TextButton(
                                  onPressed: () {
                                    setDialogState(() {
                                      selectedIds
                                        ..clear()
                                        ..addAll(timetables.map((t) => t.id));
                                    });
                                  },
                                  child: const Text('全选'),
                                ),
                                TextButton(
                                  onPressed: () {
                                    setDialogState(() {
                                      selectedIds.clear();
                                    });
                                  },
                                  child: const Text('清空'),
                                ),
                              ],
                            ),
                            Flexible(
                              child: ScrollConfiguration(
                                behavior: ScrollConfiguration.of(dialogContext).copyWith(
                                  physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                                ),
                                child: ListView.builder(
                                  itemCount: timetables.length,
                                  itemBuilder: (context, index) {
                                    final timetable = timetables[index];
                                    final selected = selectedIds.contains(timetable.id);
                                    return Padding(
                                      padding: const EdgeInsets.only(bottom: 10),
                                      child: _buildSelectableTimetableTile(
                                        title: timetable.name,
                                        subtitle: '创建于 ${_formatDateTime(timetable.createdAt)}',
                                        selected: selected,
                                        onTap: () {
                                          setDialogState(() {
                                            if (selected) {
                                              selectedIds.remove(timetable.id);
                                            } else {
                                              selectedIds.add(timetable.id);
                                            }
                                          });
                                        },
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: TextButton(
                                    onPressed: () => Navigator.pop(dialogContext),
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
                                    onPressed: selectedIds.isEmpty
                                        ? null
                                        : () => Navigator.pop(dialogContext, selectedIds.toList()),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF4A90E2),
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(vertical: 14),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                    ),
                                    child: const Text('开始备份'),
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
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _syncFromCloud() async {
    if (!_isCloudLoginReady()) {
      return;
    }

    final cloudSync = CloudSyncService.instance;
    final backup = await cloudSync.fetchBackup();

    if (!mounted) return;

    if (backup == null && cloudSync.lastError != null) {
      toastNotification.show(context, cloudSync.lastError!, type: ToastType.error);
      return;
    }

    if (backup == null) {
      toastNotification.show(context, '云端暂无备份数据', type: ToastType.info);
      return;
    }

    final timetableNames = StorageService.getCloudBackupTimetableNames(backup.payload);
    if (timetableNames.isEmpty) {
      toastNotification.show(context, '云端备份中未找到可同步课表', type: ToastType.error);
      return;
    }

    final selectedTimetable = await _showCloudTimetableSelectorDialog(
      timetableNames,
      updatedAt: backup.updatedAt,
    );
    if (selectedTimetable == null) return;

    final mode = await _showCloudSyncModeDialog(backup.updatedAt, selectedTimetable);
    if (mode == null) return;

    final selectedPayload = StorageService.getCloudBackupTimetableData(backup.payload, selectedTimetable);
    if (selectedPayload == null) {
      toastNotification.show(context, '选中的课表数据不存在或已损坏', type: ToastType.error);
      return;
    }

    final result = await StorageService.importData(selectedPayload, mode: mode);
    if (!mounted) return;

    if (!result.success) {
      toastNotification.show(
        context,
        result.errorMessage ?? '从云端同步失败，请稍后再试',
        type: ToastType.error,
      );
      return;
    }

    toastNotification.show(
      context,
      mode == ImportMode.merge
          ? '已将“$selectedTimetable”合并到本地：${result.summary}'
          : '已用“$selectedTimetable”覆盖当前课表：${result.summary}',
      type: ToastType.success,
    );
  }

  Future<void> _manageCloudData() async {
    if (!_isCloudLoginReady()) {
      return;
    }

    final cloudSync = CloudSyncService.instance;
    final backup = await cloudSync.fetchBackup();

    if (!mounted) return;

    if (backup == null && cloudSync.lastError != null) {
      toastNotification.show(context, cloudSync.lastError!, type: ToastType.error);
      return;
    }

    if (backup == null) {
      toastNotification.show(context, '云端暂无备份数据', type: ToastType.info);
      return;
    }

    final selectedForDelete = await _showCloudDeleteSelectorDialog(
      backup.payload,
      updatedAt: backup.updatedAt,
    );

    if (!mounted || selectedForDelete == null || selectedForDelete.isEmpty) {
      return;
    }

    final nextPayload = _removeTimetablesFromCloudPayload(
      backup.payload,
      selectedForDelete.toSet(),
    );

    final remainingNames = StorageService.getCloudBackupTimetableNames(nextPayload);
    final success = remainingNames.isEmpty
        ? await cloudSync.deleteBackup()
        : await cloudSync.uploadBackup(nextPayload);

    if (!mounted) return;

    toastNotification.show(
      context,
      success
          ? '已删除 ${selectedForDelete.length} 个云端课表'
          : (cloudSync.lastError ?? '删除云端课表失败，请稍后重试'),
      type: success ? ToastType.success : ToastType.error,
    );
  }

  Future<List<String>?> _showCloudDeleteSelectorDialog(
    Map<String, dynamic> payload, {
    DateTime? updatedAt,
  }) {
    final timetableNames = StorageService.getCloudBackupTimetableNames(payload);
    if (timetableNames.isEmpty) {
      return Future.value(<String>[]);
    }

    return showGeneralDialog<List<String>>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '管理云端课表',
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        final selectedNames = <String>{};

        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
              child: Center(
                child: Material(
                  color: Colors.transparent,
                  child: FadeTransition(
                    opacity: animation,
                    child: ScaleTransition(
                      scale: Tween<double>(begin: 0.9, end: 1.0).animate(
                        CurvedAnimation(parent: animation, curve: Curves.easeOut),
                      ),
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 24),
                        padding: const EdgeInsets.all(24),
                        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 560),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.2),
                              blurRadius: 20,
                              offset: const Offset(0, 10),
                            ),
                          ],
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 64,
                              height: 64,
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                  colors: [Color(0xFFFF9800), Color(0xFFFFB74D)],
                                ),
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: const Icon(
                                Icons.folder_open_rounded,
                                size: 32,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 16),
                            const Text(
                              '管理云端课表',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '云端更新时间：${_formatDateTime(updatedAt)}',
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.grey.shade600,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                TextButton(
                                  onPressed: () {
                                    setDialogState(() {
                                      selectedNames
                                        ..clear()
                                        ..addAll(timetableNames);
                                    });
                                  },
                                  child: const Text('全选'),
                                ),
                                TextButton(
                                  onPressed: () {
                                    setDialogState(() {
                                      selectedNames.clear();
                                    });
                                  },
                                  child: const Text('清空'),
                                ),
                              ],
                            ),
                            Flexible(
                              child: ScrollConfiguration(
                                behavior: ScrollConfiguration.of(dialogContext).copyWith(
                                  physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                                ),
                                child: ListView.builder(
                                  itemCount: timetableNames.length,
                                  itemBuilder: (context, index) {
                                    final name = timetableNames[index];
                                    final selected = selectedNames.contains(name);
                                    return Padding(
                                      padding: const EdgeInsets.only(bottom: 10),
                                      child: _buildSelectableTimetableTile(
                                        title: name,
                                        subtitle: '从云端备份中删除此课表',
                                        selected: selected,
                                        onTap: () {
                                          setDialogState(() {
                                            if (selected) {
                                              selectedNames.remove(name);
                                            } else {
                                              selectedNames.add(name);
                                            }
                                          });
                                        },
                                        selectedColor: Colors.red,
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: TextButton(
                                    onPressed: () => Navigator.pop(dialogContext),
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
                                    onPressed: selectedNames.isEmpty
                                        ? null
                                        : () => Navigator.pop(dialogContext, selectedNames.toList()),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.red,
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(vertical: 14),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                    ),
                                    child: const Text('删除选中'),
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
              ),
            );
          },
        );
      },
    );
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
      final nextNamed = Map<String, dynamic>.from(namedTimetables as Map);
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

  bool _isCloudLoginReady() {
    final auth = AuthService.instance;
    if (auth.isAuthenticated) {
      return true;
    }

    toastNotification.show(
      context,
      '请先登录账号，再使用云端数据管理',
      type: ToastType.info,
    );
    return false;
  }

  Future<String?> _showCloudTimetableSelectorDialog(
    List<String> timetableNames, {
    DateTime? updatedAt,
  }) {
    return showGeneralDialog<String>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '选择要同步的课表',
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        return BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
          child: Center(
            child: Material(
              color: Colors.transparent,
              child: FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.9, end: 1.0).animate(
                    CurvedAnimation(parent: animation, curve: Curves.easeOut),
                  ),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 24),
                    padding: const EdgeInsets.all(24),
                    constraints: const BoxConstraints(maxWidth: 420, maxHeight: 520),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.2),
                          blurRadius: 20,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [Color(0xFF4A90E2), Color(0xFF5BA0F2)],
                            ),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: const Icon(
                            Icons.list_alt_rounded,
                            size: 32,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          '选择要同步的课表',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '云端更新时间：${_formatDateTime(updatedAt)}',
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey.shade600,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Flexible(
                          child: ScrollConfiguration(
                            behavior: ScrollConfiguration.of(dialogContext).copyWith(
                              physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                            ),
                            child: SingleChildScrollView(
                              child: Column(
                                children: timetableNames
                                    .map(
                                      (name) => Padding(
                                        padding: const EdgeInsets.only(bottom: 10),
                                        child: _buildCloudActionTile(
                                          icon: Icons.calendar_month_rounded,
                                          color: const Color(0xFF4A90E2),
                                          title: name,
                                          subtitle: '同步此课表到当前设备',
                                          onTap: () => Navigator.pop(dialogContext, name),
                                        ),
                                      ),
                                    )
                                    .toList(),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: TextButton(
                            onPressed: () => Navigator.pop(dialogContext),
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
                      ],
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

  Future<ImportMode?> _showCloudSyncModeDialog(DateTime? updatedAt, String timetableName) {
    return showGeneralDialog<ImportMode>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '选择云端同步模式',
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        return BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
          child: Center(
            child: Material(
              color: Colors.transparent,
              child: FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.9, end: 1.0).animate(
                    CurvedAnimation(parent: animation, curve: Curves.easeOut),
                  ),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 24),
                    padding: const EdgeInsets.all(24),
                    constraints: const BoxConstraints(maxWidth: 420),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.2),
                          blurRadius: 20,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [Color(0xFF4A90E2), Color(0xFF5BA0F2)],
                            ),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: const Icon(
                            Icons.cloud_download_rounded,
                            size: 32,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          '选择同步方式',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '已选择课表：$timetableName',
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey.shade700,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '云端更新时间：${_formatDateTime(updatedAt)}',
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey.shade600,
                          ),
                        ),
                        const SizedBox(height: 20),
                        _buildCloudActionTile(
                          icon: Icons.merge_type,
                          color: Colors.green,
                          title: '合并到本地',
                          subtitle: '保留现有数据，并补充云端数据',
                          onTap: () => Navigator.pop(dialogContext, ImportMode.merge),
                        ),
                        const SizedBox(height: 10),
                        _buildCloudActionTile(
                          icon: Icons.system_update_alt_rounded,
                          color: Colors.orange,
                          title: '云端覆盖本地',
                          subtitle: '清空当前课表数据后导入云端数据',
                          onTap: () => Navigator.pop(dialogContext, ImportMode.replace),
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: TextButton(
                            onPressed: () => Navigator.pop(dialogContext),
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
                      ],
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

  Widget _buildSelectableTimetableTile({
    required String title,
    required String subtitle,
    required bool selected,
    required VoidCallback onTap,
    Color selectedColor = const Color(0xFF4A90E2),
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected ? selectedColor.withValues(alpha: 0.12) : Colors.grey.shade50,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? selectedColor : Colors.grey.shade300,
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
                  color: selected ? selectedColor : Colors.grey.shade400,
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
                      color: selected ? selectedColor : Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDateTime(DateTime? time) {
    if (time == null) {
      return '未知';
    }
    final local = time.toLocal();
    return '${local.year}-${_twoDigits(local.month)}-${_twoDigits(local.day)} ${_twoDigits(local.hour)}:${_twoDigits(local.minute)}';
  }

  String _twoDigits(int value) {
    return value.toString().padLeft(2, '0');
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
                color: Colors.white.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.8),
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
                                color: Colors.grey.shade100,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(Icons.close, size: 18, color: Colors.grey.shade600),
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
      final XFile? image = await picker.pickImage(source: source, imageQuality: 85);
      
      if (image == null) return;
      
      await AIProcessingDialog.show(
        context,
        imagePath: image.path,
        onCompleted: (courses) async {
          await _importParsedCourses(context, courses);
        },
      );
      
    } catch (e) {
      if (mounted) {
        toastNotification.show(context, '操作失败：$e', type: ToastType.error);
      }
    }
  }

  Future<void> _importParsedCourses(BuildContext context, List<CourseData> courses) async {
    try {
      await StorageService.resetCurrentWeek();
      
      final baseTime = DateTime.now().millisecondsSinceEpoch;
      final courseList = courses.asMap().entries.map((entry) {
        final index = entry.key;
        final c = entry.value;
        final timeSlot = (c.period ?? _getTimeSlot(c.startTime ?? '08:00')) - 1;
        final fallbackColor = CourseColorPalette.extendedHexColors[
          index % CourseColorPalette.extendedHexColors.length
        ];
        return Course(
          id: '${baseTime}_${index}_${c.name.hashCode}',
          name: c.name,
          teacher: c.teacher ?? '',
          location: c.location ?? '',
          day: c.dayOfWeek - 1,
          time: timeSlot,
          duration: c.duration ?? _calculateDuration(c.startTime ?? '08:00', c.endTime ?? '09:40'),
          weeks: c.weeks ?? (c.startWeek != null && c.endWeek != null ? '${c.startWeek}-${c.endWeek}' : null),
          color: CourseColorPalette.normalizeHexColor(c.color, fallbackHex: fallbackColor),
        );
      }).toList();

      final data = {
        'courses': courseList.map((c) => {
          'id': c.id,
          'name': c.name,
          'teacher': c.teacher,
          'location': c.location,
          'day': c.day,
          'time': c.time,
          'duration': c.duration,
          'weeks': c.weeks,
          'color': c.color,
        }).toList(),
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
    final minute = int.tryParse(startTime.split(':').length > 1 ? startTime.split(':')[1] : '0') ?? 0;
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
      final startMinutes = int.parse(startParts[0]) * 60 + int.parse(startParts[1]);
      final endMinutes = int.parse(endParts[0]) * 60 + int.parse(endParts[1]);
      return ((endMinutes - startMinutes) / 90).round().clamp(1, 3);
    } catch (e) {
      return 2;
    }
  }
}
