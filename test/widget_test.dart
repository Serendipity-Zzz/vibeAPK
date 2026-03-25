import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:karaoke_app/main.dart';

void main() {
  testWidgets('home page smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    expect(find.byType(Scaffold), findsOneWidget);
    expect(find.text('K 歌伴唱'), findsOneWidget);
    expect(find.text('本地导入伴奏'), findsOneWidget);
    expect(find.text('搜索导入伴奏'), findsOneWidget);
    expect(find.text('搜索导入歌词'), findsOneWidget);
    expect(find.text('本地导入 LRC'), findsOneWidget);
    expect(find.byIcon(Icons.search), findsOneWidget);
    expect(find.byIcon(Icons.save_alt), findsOneWidget);
  });
}
