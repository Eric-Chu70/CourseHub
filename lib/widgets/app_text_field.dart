import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';

/// 全局统一的光标（闪烁竖线）样式：主题蓝、2.0px 圆头、高度 17px（比整行高
/// 收敛，接近文字实际高度）、平滑淡入淡出。
/// 所有输入框通过 AppTextField / AppTextFormField 使用；调用点仍可按需
/// 覆盖任意参数（含光标参数），默认值即全局样式。
const double _kCursorWidth = 2.0;
const Radius _kCursorRadius = Radius.circular(1.0);
const double _kCursorHeight = 17.0;
const Color _kCursorColor = Color(0xFF4A90E2);

/// 与 SDK 私有默认实现等价的上下文菜单构建（公开 API 复刻，行为一致）。
/// SDK 构造函数的默认值引用私有符号，子类无法直接转发，此处按原逻辑重写。
Widget _defaultContextMenuBuilder(
  BuildContext context,
  EditableTextState editableTextState,
) {
  if (SystemContextMenu.isSupportedByField(editableTextState)) {
    return SystemContextMenu.editableText(editableTextState: editableTextState);
  }
  return AdaptiveTextSelectionToolbar.editableText(
    editableTextState: editableTextState,
  );
}

/// 统一样式的 [TextField]：仅覆盖光标默认值，其余参数全部原样转发。
///
/// 参数列表与 Flutter 3.41 的 TextField 构造函数逐一对应（省略两个已废弃
/// 参数 toolbarOptions / scribbleEnabled，项目未使用）；默认值与 SDK 一致，
/// 升级 Flutter 时如构造签名变化需同步检查本文件。
class AppTextField extends TextField {
  const AppTextField({
    super.key,
    super.groupId = EditableText,
    super.controller,
    super.focusNode,
    super.undoController,
    super.decoration = const InputDecoration(),
    super.keyboardType,
    super.textInputAction,
    super.textCapitalization = TextCapitalization.none,
    super.style,
    super.strutStyle,
    super.textAlign = TextAlign.start,
    super.textAlignVertical,
    super.textDirection,
    super.readOnly = false,
    super.showCursor,
    super.autofocus = false,
    super.statesController,
    super.obscuringCharacter = '•',
    super.obscureText = false,
    super.autocorrect,
    super.smartDashesType,
    super.smartQuotesType,
    super.enableSuggestions = true,
    super.maxLines = 1,
    super.minLines,
    super.expands = false,
    super.maxLength,
    super.maxLengthEnforcement,
    super.onChanged,
    super.onEditingComplete,
    super.onSubmitted,
    super.onAppPrivateCommand,
    super.inputFormatters,
    super.enabled,
    super.ignorePointers,
    super.cursorWidth = _kCursorWidth,
    super.cursorHeight = _kCursorHeight,
    super.cursorRadius = _kCursorRadius,
    super.cursorOpacityAnimates = true,
    super.cursorColor = _kCursorColor,
    super.cursorErrorColor,
    super.selectionHeightStyle,
    super.selectionWidthStyle,
    super.keyboardAppearance,
    super.scrollPadding = const EdgeInsets.all(20.0),
    super.dragStartBehavior = DragStartBehavior.start,
    super.enableInteractiveSelection,
    super.selectAllOnFocus,
    super.selectionControls,
    super.onTap,
    super.onTapAlwaysCalled = false,
    super.onTapOutside,
    super.onTapUpOutside,
    super.mouseCursor,
    super.buildCounter,
    super.scrollController,
    super.scrollPhysics,
    super.autofillHints = const <String>[],
    super.contentInsertionConfiguration,
    super.clipBehavior = Clip.hardEdge,
    super.restorationId,
    super.stylusHandwritingEnabled = EditableText.defaultStylusHandwritingEnabled,
    super.enableIMEPersonalizedLearning = true,
    super.contextMenuBuilder = _defaultContextMenuBuilder,
    super.canRequestFocus = true,
    super.spellCheckConfiguration,
    super.magnifierConfiguration,
    super.hintLocales,
  });
}

/// 统一样式的 [TextFormField]：转发语义同 [AppTextField]。
/// 注意 TextFormField 构造函数本身非 const（内部持 builder 闭包），
/// 此处同样不加 const。
class AppTextFormField extends TextFormField {
  AppTextFormField({
    super.key,
    super.groupId = EditableText,
    super.controller,
    super.initialValue,
    super.focusNode,
    super.forceErrorText,
    super.decoration = const InputDecoration(),
    super.keyboardType,
    super.textCapitalization = TextCapitalization.none,
    super.textInputAction,
    super.style,
    super.strutStyle,
    super.textDirection,
    super.textAlign = TextAlign.start,
    super.textAlignVertical,
    super.autofocus = false,
    super.readOnly = false,
    super.showCursor,
    super.obscuringCharacter = '•',
    super.obscureText = false,
    super.autocorrect = true,
    super.smartDashesType,
    super.smartQuotesType,
    super.enableSuggestions = true,
    super.maxLengthEnforcement,
    super.maxLines = 1,
    super.minLines,
    super.expands = false,
    super.maxLength,
    super.onChanged,
    super.onTap,
    super.onTapAlwaysCalled = false,
    super.onTapOutside,
    super.onTapUpOutside,
    super.onEditingComplete,
    super.onFieldSubmitted,
    super.onSaved,
    super.validator,
    super.errorBuilder,
    super.inputFormatters,
    super.enabled,
    super.ignorePointers,
    super.cursorWidth = _kCursorWidth,
    super.cursorHeight = _kCursorHeight,
    super.cursorRadius = _kCursorRadius,
    super.cursorColor = _kCursorColor,
    super.cursorErrorColor,
    super.cursorOpacityAnimates = true,
    super.keyboardAppearance,
    super.scrollPadding = const EdgeInsets.all(20.0),
    super.enableInteractiveSelection,
    super.selectAllOnFocus,
    super.selectionControls,
    super.buildCounter,
    super.scrollPhysics,
    super.autofillHints,
    super.autovalidateMode,
    super.scrollController,
    super.restorationId,
    super.enableIMEPersonalizedLearning = true,
    super.mouseCursor,
    super.contextMenuBuilder = _defaultContextMenuBuilder,
    super.spellCheckConfiguration,
    super.magnifierConfiguration,
    super.undoController,
    super.onAppPrivateCommand,
    super.selectionHeightStyle,
    super.selectionWidthStyle,
    super.dragStartBehavior = DragStartBehavior.start,
    super.contentInsertionConfiguration,
    super.statesController,
    super.stylusHandwritingEnabled = EditableText.defaultStylusHandwritingEnabled,
    super.canRequestFocus = true,
    super.hintLocales,
    super.clipBehavior = Clip.hardEdge,
  });
}
