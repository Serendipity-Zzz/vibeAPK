import 'package:flutter_test/flutter_test.dart';

import 'package:karaoke_app/main.dart';

void main() {
  testWidgets('home page smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('导入伴奏'), findsOneWidget);
    expect(find.text('K 歌伴唱'), findsOneWidget);
    expect(find.text('请先导入伴奏并搜索歌词'), findsOneWidget);
  });
}
