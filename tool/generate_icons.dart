import 'dart:io';
import 'dart:math';
import 'package:image/image.dart';

void main() async {
  final outputDir = Directory('assets/icon');
  
  if (!await outputDir.exists()) {
    await outputDir.create(recursive: true);
  }
  
  print('Generating CourseHub app icons...');
  
  final mainIcon = generateCourseHubIcon(1024, isForeground: false);
  final foregroundIcon = generateCourseHubIcon(1024, isForeground: true);
  
  await File('${outputDir.path}/app_icon.png').writeAsBytes(encodePng(mainIcon));
  await File('${outputDir.path}/app_icon_foreground.png').writeAsBytes(encodePng(foregroundIcon));
  
  print('Icons generated successfully!');
  print('Main icon: ${outputDir.path}/app_icon.png');
  print('Foreground icon: ${outputDir.path}/app_icon_foreground.png');
}

Image generateCourseHubIcon(int size, {required bool isForeground}) {
  final img = Image(width: size, height: size);
  
  final center = size / 2;
  final radius = size / 2;
  final innerPadding = size * 0.22;
  
  const primaryR = 74, primaryG = 144, primaryB = 226;
  const whiteR = 255, whiteG = 255, whiteB = 255;
  
  final iconR = isForeground ? primaryR : whiteR;
  final iconG = isForeground ? primaryG : whiteG;
  final iconB = isForeground ? primaryB : whiteB;
  
  for (int y = 0; y < size; y++) {
    for (int x = 0; x < size; x++) {
      final dx = x - center;
      final dy = y - center;
      final distance = sqrt(dx * dx + dy * dy);
      
      if (!isForeground && distance <= radius) {
        img.setPixelRgba(x, y, primaryR, primaryG, primaryB, 255);
      } else if (!isForeground) {
        img.setPixelRgba(x, y, 0, 0, 0, 0);
      }
      
      if (isForeground) {
        img.setPixelRgba(x, y, 0, 0, 0, 0);
      }
    }
  }
  
  final calendarLeft = innerPadding;
  final calendarTop = innerPadding;
  final calendarRight = size - innerPadding;
  final calendarBottom = size - innerPadding;
  final calendarWidth = calendarRight - calendarLeft;
  final headerHeight = size * 0.12;
  final lineWidth = max((size * 0.06).toInt(), 2);
  
  drawCalendarOutline(img, 
    calendarLeft.toInt(), 
    (calendarTop + size * 0.06).toInt(), 
    calendarRight.toInt(), 
    calendarBottom.toInt(), 
    lineWidth, 
    iconR, iconG, iconB
  );
  
  fillRectPixels(img,
    (calendarLeft + lineWidth / 2).toInt(),
    (calendarTop + size * 0.06).toInt(),
    (calendarRight - lineWidth / 2).toInt(),
    (calendarTop + size * 0.06 + headerHeight).toInt(),
    iconR, iconG, iconB
  );
  
  final hookWidth = size * 0.04;
  final hookHeight = size * 0.08;
  final hookY = calendarTop + size * 0.02;
  
  final leftHookX = calendarLeft + calendarWidth * 0.28;
  final rightHookX = calendarLeft + calendarWidth * 0.72;
  
  fillRoundedRectPixels(img,
    (leftHookX - hookWidth / 2).toInt(),
    hookY.toInt(),
    (leftHookX + hookWidth / 2).toInt(),
    (hookY + hookHeight).toInt(),
    max((hookWidth / 2).toInt(), 2),
    iconR, iconG, iconB
  );
  
  fillRoundedRectPixels(img,
    (rightHookX - hookWidth / 2).toInt(),
    hookY.toInt(),
    (rightHookX + hookWidth / 2).toInt(),
    (hookY + hookHeight).toInt(),
    max((hookWidth / 2).toInt(), 2),
    iconR, iconG, iconB
  );
  
  final gridStartY = calendarTop + size * 0.06 + headerHeight + size * 0.04;
  final gridHeight = calendarBottom - gridStartY - size * 0.04;
  final cellHeight = gridHeight / 3;
  final cellWidth = calendarWidth / 4;
  
  final dotRadius = max((size * 0.025).toInt(), 2);
  final highlightDots = [(1, 1), (2, 2), (0, 2)];
  
  for (int row = 0; row < 3; row++) {
    for (int col = 0; col < 4; col++) {
      final cx = (calendarLeft + col * cellWidth + cellWidth / 2).toInt();
      final cy = (gridStartY + row * cellHeight + cellHeight / 2).toInt();
      
      final isHighlight = highlightDots.contains((col, row));
      final currentDotRadius = isHighlight ? (dotRadius * 1.5).toInt() : dotRadius;
      
      if (isHighlight) {
        fillCirclePixels(img, cx, cy, currentDotRadius, iconR, iconG, iconB, 255);
      } else {
        fillCirclePixels(img, cx, cy, currentDotRadius, iconR, iconG, iconB, 102);
      }
    }
  }
  
  return img;
}

void drawCalendarOutline(Image img, int x1, int y1, int x2, int y2, int thickness, int r, int g, int b) {
  for (int t = 0; t < thickness; t++) {
    for (int x = x1; x <= x2; x++) {
      img.setPixelRgba(x, y1 + t, r, g, b, 255);
      img.setPixelRgba(x, y2 - t, r, g, b, 255);
    }
    for (int y = y1; y <= y2; y++) {
      img.setPixelRgba(x1 + t, y, r, g, b, 255);
      img.setPixelRgba(x2 - t, y, r, g, b, 255);
    }
  }
}

void fillRectPixels(Image img, int x1, int y1, int x2, int y2, int r, int g, int b) {
  for (int y = y1; y <= y2; y++) {
    for (int x = x1; x <= x2; x++) {
      if (x >= 0 && x < img.width && y >= 0 && y < img.height) {
        img.setPixelRgba(x, y, r, g, b, 255);
      }
    }
  }
}

void fillRoundedRectPixels(Image img, int x1, int y1, int x2, int y2, int radius, int r, int g, int b) {
  fillRectPixels(img, x1 + radius, y1, x2 - radius, y2, r, g, b);
  fillRectPixels(img, x1, y1 + radius, x2, y2 - radius, r, g, b);
  fillCirclePixels(img, x1 + radius, y1 + radius, radius, r, g, b, 255);
  fillCirclePixels(img, x2 - radius, y1 + radius, radius, r, g, b, 255);
  fillCirclePixels(img, x1 + radius, y2 - radius, radius, r, g, b, 255);
  fillCirclePixels(img, x2 - radius, y2 - radius, radius, r, g, b, 255);
}

void fillCirclePixels(Image img, int cx, int cy, int radius, int r, int g, int b, int a) {
  for (int y = cy - radius; y <= cy + radius; y++) {
    for (int x = cx - radius; x <= cx + radius; x++) {
      final dx = x - cx;
      final dy = y - cy;
      if (dx * dx + dy * dy <= radius * radius) {
        if (x >= 0 && x < img.width && y >= 0 && y < img.height) {
          img.setPixelRgba(x, y, r, g, b, a);
        }
      }
    }
  }
}
