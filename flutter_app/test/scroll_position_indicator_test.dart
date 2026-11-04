import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/ui/scroll_position_indicator.dart';

void main() {
  testWidgets('scrolling briefly shows an approximate position and total', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _app(controller, totalCount: 100, loadedCount: 100),
    );

    final indicator = find.byKey(const Key('scroll-position-indicator'));
    expect(tester.widget<AnimatedOpacity>(indicator).opacity, 0);

    controller.jumpTo(600);
    await tester.pump();
    expect(tester.widget<AnimatedOpacity>(indicator).opacity, 1);
    expect(find.textContaining('约第'), findsOneWidget);
    expect(find.textContaining('共 100 项'), findsOneWidget);
  });

  testWidgets('unknown total reports loaded count and active counting', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _app(controller, totalCount: null, loadedCount: 60, counting: true),
    );

    controller.jumpTo(300);
    await tester.pump();
    expect(find.text('已加载 60 项 · 正在统计'), findsOneWidget);
  });
}

Widget _app(
  ScrollController controller, {
  required int loadedCount,
  required int? totalCount,
  bool counting = false,
}) => MaterialApp(
  locale: const Locale('zh'),
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: Stack(
      children: [
        ListView.builder(
          controller: controller,
          itemExtent: 80,
          itemCount: 100,
          itemBuilder: (context, index) => Text('$index'),
        ),
        ScrollPositionIndicator(
          controller: controller,
          loadedCount: loadedCount,
          totalCount: totalCount,
          counting: counting,
        ),
      ],
    ),
  ),
);
