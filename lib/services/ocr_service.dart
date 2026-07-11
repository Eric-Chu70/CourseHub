import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

class OCRResult {
  final String text;
  final List<TextBlock> blocks;
  final Duration processingTime;

  OCRResult({
    required this.text,
    required this.blocks,
    required this.processingTime,
  });
}

class OCRService {
  static final OCRService _instance = OCRService._internal();
  factory OCRService() => _instance;
  OCRService._internal();

  static OCRService get instance => _instance;

  final TextRecognizer _textRecognizer = TextRecognizer(script: TextRecognitionScript.chinese);

  Future<OCRResult> recognizeText(String imagePath) async {
    final stopwatch = Stopwatch()..start();

    try {
      final inputImage = InputImage.fromFilePath(imagePath);
      final RecognizedText recognizedText = await _textRecognizer.processImage(inputImage);

      String fullText = recognizedText.text;
      List<TextBlock> blocks = recognizedText.blocks;

      stopwatch.stop();

      return OCRResult(
        text: fullText,
        blocks: blocks,
        processingTime: stopwatch.elapsed,
      );
    } catch (e) {
      stopwatch.stop();
      throw OCRException('文字识别失败: $e');
    }
  }

  Future<OCRResult> recognizeTextFromBytes({
    required Uint8List bytes,
    required int width,
    required int height,
    required InputImageRotation rotation,
  }) async {
    final stopwatch = Stopwatch()..start();

    try {
      final inputImage = InputImage.fromBytes(
        bytes: bytes,
        metadata: InputImageMetadata(
          size: Size(width.toDouble(), height.toDouble()),
          rotation: rotation,
          format: InputImageFormat.nv21,
          bytesPerRow: width,
        ),
      );

      final RecognizedText recognizedText = await _textRecognizer.processImage(inputImage);

      stopwatch.stop();

      return OCRResult(
        text: recognizedText.text,
        blocks: recognizedText.blocks,
        processingTime: stopwatch.elapsed,
      );
    } catch (e) {
      stopwatch.stop();
      throw OCRException('文字识别失败: $e');
    }
  }

  Future<void> close() async {
    await _textRecognizer.close();
  }

  String extractScheduleText(OCRResult result) {
    final lines = result.text.split('\n');
    final scheduleLines = <String>[];

    for (final line in lines) {
      final trimmedLine = line.trim();
      if (trimmedLine.isEmpty) continue;

      if (_isScheduleLine(trimmedLine)) {
        scheduleLines.add(trimmedLine);
      }
    }

    if (scheduleLines.isEmpty) {
      return result.text;
    }

    return scheduleLines.join('\n');
  }

  bool _isScheduleLine(String line) {
    final schedulePatterns = [
      RegExp(r'[周星期]'),
      RegExp(r'[一二三四五六日天]'),
      RegExp(r'\d{1,2}[:：]\d{2}'),
      RegExp(r'第?\d+节'),
      RegExp(r'[\u4e00-\u9fa5]{2,}'),
      RegExp(r'\d+[-~]\d+周'),
      RegExp(r'\d{3,4}'),
    ];

    int matchCount = 0;
    for (final pattern in schedulePatterns) {
      if (pattern.hasMatch(line)) {
        matchCount++;
      }
    }

    return matchCount >= 1;
  }
}

class OCRException implements Exception {
  final String message;
  OCRException(this.message);

  @override
  String toString() => 'OCRException: $message';
}
