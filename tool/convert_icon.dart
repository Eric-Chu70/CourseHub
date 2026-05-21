import 'dart:io';
import 'package:image/image.dart';

void main() async {
  const jpgPath = r'c:\Users\Eric Chu\Desktop\CrouseHub\CrouseHub\CourseHub.jpg';
  const pngPath = r'c:\Users\Eric Chu\Desktop\CrouseHub\CrouseHub\flutter\assets\icon\app_icon.png';
  
  final jpgBytes = await File(jpgPath).readAsBytes();
  final image = decodeImage(jpgBytes);
  
  if (image != null) {
    final pngBytes = encodePng(image);
    await File(pngPath).writeAsBytes(pngBytes);
    print('Converted JPG to PNG successfully');
    print('PNG file size: ${pngBytes.length} bytes');
  } else {
    print('Failed to decode JPG');
  }
}
