import 'package:flutter/material.dart';

class CourseColorPalette {
  static const List<Color> primaryColors = [
    Color(0xFF4A90E2),
    Color(0xFFE74C3C),
    Color(0xFF27AE60),
    Color(0xFFF39C12),
    Color(0xFF9B59B6),
    Color(0xFF1ABC9C),
    Color(0xFFE91E63),
    Color(0xFF00ACC1),
    Color(0xFF795548),
    Color(0xFF607D8B),
    Color(0xFFFF5722),
    Color(0xFF3F51B5),
    Color(0xFF2E7D32),
    Color(0xFFC2185B),
    Color(0xFF6D4C41),
  ];

  static const List<String> primaryHexColors = [
    '#4A90E2',
    '#E74C3C',
    '#27AE60',
    '#F39C12',
    '#9B59B6',
    '#1ABC9C',
    '#E91E63',
    '#00ACC1',
    '#795548',
    '#607D8B',
    '#FF5722',
    '#3F51B5',
    '#2E7D32',
    '#C2185B',
    '#6D4C41',
  ];

  static const List<String> extendedHexColors = [
    ...primaryHexColors,
    '#00897B',
    '#7B1FA2',
    '#EF6C00',
    '#1565C0',
    '#AD1457',
    '#37474F',
    '#D84315',
    '#5E35B1',
  ];

  static String normalizeHexColor(String? rawColor, {required String fallbackHex}) {
    final normalizedFallback = _normalizeHexUnsafe(fallbackHex) ?? '#4A90E2';
    final normalized = _normalizeHexUnsafe(rawColor);
    if (normalized == null) {
      return normalizedFallback;
    }

    if (_isTooLight(normalized)) {
      return normalizedFallback;
    }
    return normalized;
  }

  static String colorToHex(Color color) {
    final rgb = color.toARGB32().toRadixString(16).substring(2).toUpperCase();
    return '#$rgb';
  }

  static String? _normalizeHexUnsafe(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim().toUpperCase();
    if (trimmed.isEmpty) return null;
    final withHash = trimmed.startsWith('#') ? trimmed : '#$trimmed';
    if (!RegExp(r'^#[0-9A-F]{6}$').hasMatch(withHash)) {
      return null;
    }
    return withHash;
  }

  static bool _isTooLight(String hex) {
    try {
      final value = int.parse('FF${hex.substring(1)}', radix: 16);
      final color = Color(value);
      return color.computeLuminance() > 0.78;
    } catch (_) {
      return false;
    }
  }
}