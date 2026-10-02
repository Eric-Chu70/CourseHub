// 分段滑块选择器（同款用于 AI 配置的思考强度/视觉能力、通知文案风格、
// 界面风格等）。原为设置页私有实现，AI 配置对话框独立成文件后需要共用，
// 故抽出为公共组件。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';

class SegmentItem<T> {
  final String label;
  final T value;
  const SegmentItem({required this.label, required this.value});
}

class SegmentedSelector<T> extends StatefulWidget {
  final List<SegmentItem<T>> items;
  final T activeValue;
  final ValueChanged<T> onChanged;

  /// 浅色模式白把手样式（黑字+投影）：仅「界面风格」滑块使用；
  /// AI 配置的思考强度/视觉支持滑块保持原灰把手白字
  final bool whiteKnobInLight;

  const SegmentedSelector({
    super.key,
    required this.items,
    required this.activeValue,
    required this.onChanged,
    this.whiteKnobInLight = false,
  });

  @override
  State<SegmentedSelector<T>> createState() => _SegmentedSelectorState<T>();
}

class _SegmentedSelectorState<T> extends State<SegmentedSelector<T>> {
  double _dragOffset = 0;
  bool _isDragging = false;
  bool _isLongPressing = false;
  Duration _textAnimDuration = const Duration(milliseconds: 250);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final totalWidth = constraints.maxWidth;
        final n = widget.items.length;
        final internalWidth = totalWidth - 2;
        final segmentW = internalWidth / n;
        final activeIdx =
            widget.items.indexWhere((item) => item.value == widget.activeValue);
        if (activeIdx < 0) return const SizedBox.shrink();

        final effectiveIdx = _isDragging
            ? (activeIdx + _dragOffset / segmentW)
                .clamp(0.0, (n - 1).toDouble())
            : activeIdx.toDouble();
        final left = 2.0 + effectiveIdx * segmentW;
        final visualActiveIdx =
            _isDragging ? effectiveIdx.round().clamp(0, n - 1) : activeIdx;
        final labels = widget.items.map((e) => e.label).toList();

        return GestureDetector(
          onTapUp: (details) {
            final tapX = details.localPosition.dx - 1;
            if (tapX < 0 || tapX >= internalWidth) return;
            final tappedIdx = (tapX / segmentW).floor().clamp(0, n - 1);
            if (tappedIdx == activeIdx) return;
            HapticFeedback.selectionClick();
            widget.onChanged(widget.items[tappedIdx].value);
          },
          onHorizontalDragStart: (_) {
            setState(() {
              _isDragging = true;
              _isLongPressing = true;
              _dragOffset = 0;
            });
          },
          onHorizontalDragUpdate: (details) {
            setState(() {
              _dragOffset += details.delta.dx;
              final minOffset = -activeIdx * segmentW;
              final maxOffset = (n - 1 - activeIdx) * segmentW;
              _dragOffset = _dragOffset.clamp(minOffset, maxOffset);
            });
          },
          onHorizontalDragEnd: (details) {
            setState(() {
              _isDragging = false;
              _isLongPressing = false;
            });
            _textAnimDuration = Duration.zero;
            if (mounted) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) {
                  setState(() =>
                      _textAnimDuration = const Duration(milliseconds: 250));
                }
              });
            }
            final velocity = details.primaryVelocity ?? 0;
            final extra = velocity > 0
                ? -segmentW / 3
                : velocity < 0
                    ? segmentW / 3
                    : 0.0;
            final totalOffset = _dragOffset + extra;
            int targetIdx =
                (activeIdx + totalOffset / segmentW).round().clamp(0, n - 1);
            _dragOffset = 0;
            if (targetIdx != activeIdx) {
              HapticFeedback.selectionClick();
              widget.onChanged(widget.items[targetIdx].value);
            }
          },
          onHorizontalDragCancel: () {
            setState(() {
              _isDragging = false;
              _isLongPressing = false;
              _dragOffset = 0;
            });
          },
          onLongPressStart: (_) {
            setState(() => _isLongPressing = true);
          },
          onLongPressEnd: (_) {
            setState(() => _isLongPressing = false);
          },
          child: Container(
            height: 40,
            decoration: BoxDecoration(
              color: AppColors.of(context).panel(0.4),
              borderRadius: BorderRadius.circular(10),
              border:
                  Border.all(color: AppColors.of(context).borderWeak, width: 1),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: Stack(
                children: [
                  AnimatedPositioned(
                    duration: _isDragging
                        ? Duration.zero
                        : const Duration(milliseconds: 250),
                    curve: Curves.easeInOut,
                    left: left,
                    top: 2,
                    bottom: 2,
                    child: AnimatedScale(
                      scale: (_isDragging || _isLongPressing) ? 1.04 : 1.0,
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeInOut,
                      child: Container(
                        width: segmentW - 4,
                        decoration: BoxDecoration(
                          // 滑块把手：深色下用中灰与深轨道区分，白字仍可读
                          color: AppColors.isDark(context)
                              ? Colors.grey.shade600
                              : (widget.whiteKnobInLight
                                  ? Colors.white
                                  : Colors.grey.shade800),
                          borderRadius: BorderRadius.circular(8),
                          boxShadow: (AppColors.isDark(context) ||
                                  !widget.whiteKnobInLight)
                              ? null
                              : [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.18),
                                    blurRadius: 6,
                                    offset: const Offset(0, 1),
                                  ),
                                ],
                        ),
                      ),
                    ),
                  ),
                  if (_isDragging)
                    Row(
                      children: labels
                          .map((label) => Expanded(
                                child: Center(
                                  child: AnimatedDefaultTextStyle(
                                    key: ValueKey(Theme.of(context).brightness),
                                    duration: Duration.zero,
                                    style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.normal,
                                        color:
                                            AppColors.of(context).textPrimary),
                                    child: Text(label),
                                  ),
                                ),
                              ))
                          .toList(),
                    ),
                  if (_isDragging)
                    Positioned.fill(
                      child: ShaderMask(
                        shaderCallback: (bounds) {
                          final relLeft = (left / bounds.width).clamp(0.0, 1.0);
                          const edge = 0.015;
                          final relStart = (relLeft - edge).clamp(0.0, 1.0);
                          final relEnd = ((left + segmentW - 4) / bounds.width)
                              .clamp(0.0, 1.0);
                          final relStop = (relEnd + edge).clamp(0.0, 1.0);
                          return LinearGradient(
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                            colors: const [
                              Colors.transparent,
                              Colors.transparent,
                              Colors.white,
                              Colors.white,
                              Colors.transparent,
                              Colors.transparent,
                            ],
                            stops: [
                              0.0,
                              relStart,
                              relLeft,
                              relEnd,
                              relStop,
                              1.0
                            ],
                          ).createShader(bounds);
                        },
                        blendMode: BlendMode.dstIn,
                        child: Row(
                          children: labels
                              .map((label) => Expanded(
                                    child: Center(
                                      child: AnimatedDefaultTextStyle(
                                        duration: Duration.zero,
                                        style: TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.normal,
                                            color: (widget.whiteKnobInLight &&
                                                    !AppColors.isDark(context))
                                                ? const Color(0xFF1A1A2E)
                                                : Colors.white),
                                        child: Text(label),
                                      ),
                                    ),
                                  ))
                              .toList(),
                        ),
                      ),
                    ),
                  if (!_isDragging)
                    Row(
                      children: labels.asMap().entries.map((entry) {
                        return Expanded(
                          child: Center(
                            child: AnimatedDefaultTextStyle(
                              key: ValueKey(Theme.of(context).brightness),
                              duration: _textAnimDuration,
                              curve: Curves.easeInOut,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.normal,
                                color: entry.key == visualActiveIdx
                                    ? ((widget.whiteKnobInLight &&
                                            !AppColors.isDark(context))
                                        ? const Color(0xFF1A1A2E)
                                        : Colors.white)
                                    : AppColors.of(context).textPrimary,
                              ),
                              child: Text(entry.value),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBaseTextRow(
      List<String> labels, Color color, FontWeight weight) {
    return Row(
      children: labels
          .map((label) => Expanded(
                child: Center(
                  child: Text(label,
                      style: TextStyle(
                          fontSize: 13, fontWeight: weight, color: color)),
                ),
              ))
          .toList(),
    );
  }
}
