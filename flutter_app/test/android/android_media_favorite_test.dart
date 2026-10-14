import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/ui/android/android_media_card.dart';

import '../home_shell_test.dart' show FakeBackend;

MediaAsset _image(bool favorite) => MediaAsset(
  id: 1,
  sha256: 'favorite-fixture',
  originalName: 'test.png',
  storagePath: 'missing.png',
  kind: MediaKind.image,
  importedAt: DateTime(2026, 10, 14),
  gameName: '',
  favorite: favorite,
  tags: const [],
);

Widget _host(Widget card) => MaterialApp(
  locale: const Locale('zh'),
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: Center(child: SizedBox(width: 180, height: 180, child: card)),
  ),
);

void main() {
  testWidgets('favorite toggles between a red filled heart and an outline', (
    tester,
  ) async {
    var favorite = false;
    var opens = 0;
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) => AndroidMediaCard(
            asset: _image(favorite),
            settings: FakeBackend().settings,
            onOpen: () => opens++,
            onMenu: () {},
            onFavorite: () => setState(() => favorite = !favorite),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.favorite_border), findsOneWidget);
    await tester.tap(find.byTooltip('收藏'));
    await tester.pumpAndSettle();
    final heart = tester.widget<Icon>(find.byIcon(Icons.favorite));
    expect(heart.color, Colors.red);
    expect(find.byIcon(Icons.favorite_border), findsNothing);
    expect(opens, 0);
    await tester.tap(find.byTooltip('收藏'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.favorite), findsNothing);
    expect(find.byIcon(Icons.favorite_border), findsOneWidget);
    expect(
      tester.widget<Icon>(find.byIcon(Icons.favorite_border)).color,
      isNot(Colors.red),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('smaller favorite icon retains a full touch target', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(
        AndroidMediaCard(
          asset: _image(false),
          settings: FakeBackend().settings,
          onOpen: () {},
          onMenu: () {},
          onFavorite: () => taps++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byIcon(Icons.favorite_border)).width,
      lessThan(20),
    );
    final surface = find.descendant(
      of: find.byType(IconButton),
      matching: find.byType(Material),
    );
    expect(tester.getSize(surface.first).width, lessThan(32));
    final target = tester.getSize(find.byType(IconButton));
    expect(target.width, greaterThanOrEqualTo(48));
    expect(target.height, greaterThanOrEqualTo(48));
    await tester.tap(find.byTooltip('收藏'));
    await tester.pump();
    expect(taps, 1);
    expect(tester.takeException(), isNull);
  });
}
