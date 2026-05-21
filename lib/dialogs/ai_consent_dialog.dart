import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AIConsentDialog {
  static Future<bool> show(BuildContext context) async {
    bool consentChecked = false;

    final result = await showGeneralDialog<bool>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'AI功能说明',
      barrierColor: Colors.black.withValues(alpha: 0.5),
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
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
                        constraints: const BoxConstraints(maxWidth: 400, maxHeight: 500),
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
                                  colors: [Color(0xFF9C27B0), Color(0xFFBA68C8)],
                                ),
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: const Icon(
                                Icons.auto_awesome,
                                size: 32,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 16),
                            const Text(
                              '启动AI服务',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 16),
                            Expanded(
                              child: SingleChildScrollView(
                                child: Container(
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    color: Colors.grey.shade50,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: const Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '功能说明：\n\n'
                                        '1. AI智能识别：上传课程表图片，自动识别并导入课程信息。\n\n'
                                        '2. AI学习助手：智能分析您的课程安排，提供学习建议和任务提醒。\n\n'
                                        '3. 对话功能：与AI助手对话，解答学习相关问题。\n\n'
                                        '4. 本功能需要网络连接，AI识别结果仅供参考，请自行核对准确性。\n\n',
                                        style: TextStyle(
                                          fontSize: 13,
                                          height: 1.5,
                                          color: Color(0xFF333333),
                                        ),
                                      ),
                                      Text(
                                        '注意事项：\n'
                                        '免费体验模型由第三方平台提供，您的数据可能会被平台方收集，请不要上传任何个人隐私信息！',
                                        style: TextStyle(
                                          fontSize: 13,
                                          height: 1.5,
                                          color: Colors.red,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
                            Row(
                              children: [
                                Checkbox(
                                  value: consentChecked,
                                  onChanged: (value) {
                                    setDialogState(() {
                                      consentChecked = value ?? false;
                                    });
                                  },
                                  activeColor: const Color(0xFF4A90E2),
                                ),
                                Expanded(
                                  child: GestureDetector(
                                    onTap: () {
                                      setDialogState(() {
                                        consentChecked = !consentChecked;
                                      });
                                    },
                                    child: const Text(
                                      '我已阅读并理解上述说明，同意使用AI功能',
                                      style: TextStyle(fontSize: 13),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            Row(
                              children: [
                                Expanded(
                                  child: TextButton(
                                    onPressed: () => Navigator.pop(dialogContext, false),
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
                                    onPressed: consentChecked
                                        ? () async {
                                            final prefs = await SharedPreferences.getInstance();
                                            await prefs.setBool('ai_consent_accepted', true);

                                            if (dialogContext.mounted) {
                                              Navigator.pop(dialogContext, true);
                                            }
                                          }
                                        : null,
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF4A90E2),
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(vertical: 14),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                    ),
                                    child: const Text('同意并开启'),
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

    return result ?? false;
  }
}
