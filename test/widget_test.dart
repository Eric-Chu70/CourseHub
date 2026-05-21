import 'package:flutter_test/flutter_test.dart';
import 'package:coursehub/main.dart';

void main() {
  testWidgets('App starts correctly', (WidgetTester tester) async {
    await tester.pumpWidget(const CourseHubApp());
    expect(find.text('课程表'), findsOneWidget);
  });
}
