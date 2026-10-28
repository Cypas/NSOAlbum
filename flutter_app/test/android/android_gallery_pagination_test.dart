@Tags(['platform-android'])
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/state/library_controller.dart';
import 'package:squid_album/src/state/settings_controller.dart';
import 'package:squid_album/src/ui/android/android_library_page.dart';
import 'package:squid_album/src/ui/android/android_media_viewer.dart';

import '../home_shell_test.dart' show FakeBackend;
import '../layout_viewport.dart';

MediaAsset media(int id) => MediaAsset(
  id: id,
  sha256: 'synthetic-$id',
  originalName: 'capture-$id.png',
  storagePath: 'missing-synthetic-$id.png',
  kind: MediaKind.image,
  importedAt: DateTime.utc(2026, 1, 1).add(Duration(seconds: id)),
  gameName: 'Game',
  favorite: false,
  tags: const [],
);

class PagedBackend extends FakeBackend {
  PagedBackend()
    : super(mediaItems: List.generate(180, (index) => media(index + 1)));
  final requests = <GalleryPageRequest>[];
  Completer<void>? nextGate;
  @override
  Future<GalleryPage> listMediaPage(GalleryPageRequest request) async {
    requests.add(request);
    if (request.cursor != null) await nextGate?.future;
    return super.listMediaPage(request);
  }
}

void main() {
  testWidgets('album game filters exclude games from other albums', (
    tester,
  ) async {
    await useLayoutTestViewport(tester, const Size(360, 720));
    final backend = FakeBackend(
      mediaItems: [
        media(1),
        MediaAsset(
          id: 2,
          sha256: 'other-game',
          originalName: 'other.png',
          storagePath: 'missing-other.png',
          kind: MediaKind.image,
          importedAt: DateTime.utc(2026, 1, 1),
          gameName: 'Outside album',
          favorite: false,
          tags: const [],
        ),
      ],
      albumMediaIds: {
        42: {1},
      },
    );
    final controller = LibraryController(backend, albumId: 42);
    final settings = SettingsController(backend);
    addTearDown(controller.dispose);
    addTearDown(settings.dispose);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const [AppLocalizations.delegate],
        supportedLocales: AppLocalizations.supportedLocales,
        home: AndroidLibraryPage(controller: controller, settings: settings),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Filter'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilterChip, 'Game'), findsOneWidget);
    expect(find.widgetWithText(FilterChip, 'Outside album'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Android starts with a bounded page and loads another near the edge',
    (tester) async {
      await useLayoutTestViewport(tester, const Size(360, 720));
      final backend = PagedBackend();
      final controller = LibraryController(backend);
      final settings = SettingsController(backend);
      addTearDown(controller.dispose);
      addTearDown(settings.dispose);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: const [AppLocalizations.delegate],
          supportedLocales: AppLocalizations.supportedLocales,
          home: AndroidLibraryPage(controller: controller, settings: settings),
        ),
      );
      await tester.pumpAndSettle();
      expect(backend.requests.length, 1);
      expect(controller.items.length, 60);
      expect(find.byKey(const ValueKey('android-media-121')), findsNothing);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -12000));
      await tester.pumpAndSettle();
      expect(backend.requests.length, 2);
      expect(controller.items.length, 120);
      expect(
        backend.requests.every((request) => request.query.limit == 60),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Android swipe navigation continues through adjacent SQL pages', (
    tester,
  ) async {
    final backend = PagedBackend();
    final query = GalleryQuery(
      kind: GalleryKindFilter.all,
      limit: 2,
      offset: 0,
      favoriteOnly: false,
      newestFirst: true,
      gameNames: const [],
    );
    final first = await backend.listMediaPage(
      GalleryPageRequest(query: query, direction: GalleryPageDirection.forward),
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const [AppLocalizations.delegate],
        supportedLocales: AppLocalizations.supportedLocales,
        home: AndroidMediaViewer(
          backend: backend,
          items: first.items,
          initialIndex: 1,
          galleryQuery: query,
          initialPage: first,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('android-detail-toggle')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const Key('android-detail-filename')))
          .data,
      'capture-179.png',
    );
    for (final id in [178, 177, 176, 175]) {
      await tester.drag(
        find.byKey(const Key('android-detail-media')),
        const Offset(-250, 0),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const Key('android-detail-filename')))
            .data,
        'capture-$id.png',
      );
    }
    for (final id in [176, 177, 178, 179, 180, 180]) {
      await tester.drag(
        find.byKey(const Key('android-detail-media')),
        const Offset(250, 0),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const Key('android-detail-filename')))
            .data,
        'capture-$id.png',
      );
    }
    expect(find.text('1 / 2'), findsNothing);
    expect(backend.requests.length, greaterThanOrEqualTo(4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android closing drops a delayed adjacent page', (tester) async {
    final backend = PagedBackend();
    final scope = GalleryQuery(
      kind: GalleryKindFilter.all,
      limit: 2,
      offset: 0,
      favoriteOnly: false,
      newestFirst: true,
      gameNames: const [],
    );
    final first = await backend.listMediaPage(
      GalleryPageRequest(query: scope, direction: GalleryPageDirection.forward),
    );
    backend.nextGate = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const [AppLocalizations.delegate],
        supportedLocales: AppLocalizations.supportedLocales,
        home: AndroidMediaViewer(
          backend: backend,
          items: first.items,
          initialIndex: 1,
          galleryQuery: scope,
          initialPage: first,
        ),
      ),
    );
    await tester.pump();
    expect(backend.requests.length, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    backend.nextGate!.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
