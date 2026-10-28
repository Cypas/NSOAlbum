import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/main.dart';
import 'package:squid_album/src/backend/app_backend.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/state/settings_copy.dart';

import 'home_shell_test.dart' show FakeBackend;

class _DelayedAccountsBackend extends FakeBackend {
  _DelayedAccountsBackend(this.gate);

  final Completer<void> gate;

  @override
  Future<List<NintendoAccountProfile>> listNintendoAccounts() async {
    await gate.future;
    return super.listNintendoAccounts();
  }

  @override
  Future<String?> get selectedNintendoAccountId async {
    await gate.future;
    return super.selectedNintendoAccountId;
  }
}

void main() {
  testWidgets('desktop transfer page shows neutral account loading state', (
    tester,
  ) async {
    final gate = Completer<void>();
    final backend = _DelayedAccountsBackend(gate);
    await tester.pumpWidget(SquidAlbumApp(backend: backend));
    await tester.pumpAndSettle();

    await tester.tap(find.text('导入与同步').last);
    await tester.pump();

    expect(find.byKey(const Key('nintendo-account-loading')), findsOneWidget);
    expect(find.text('尚未连接 Nintendo Account'), findsNothing);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('nintendo-account-loading')), findsNothing);
  });

  testWidgets(
    'desktop library keeps search expanded and centers search and kind filters',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(SquidAlbumApp(backend: FakeBackend()));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('library-search')), findsOneWidget);
      expect(find.byKey(const Key('library-search-toggle')), findsNothing);
      expect(find.byKey(const Key('library-search-back')), findsNothing);
      expect(find.byKey(const Key('library-filter')), findsOneWidget);
      expect(
        find.byKey(const Key('desktop-search-filter-group')),
        findsOneWidget,
      );

      final header = tester.getRect(find.byKey(const Key('page-header')));
      expect(
        tester.getSize(find.byKey(const Key('page-header-extent'))).height,
        64,
      );
      expect(header.top, closeTo(2, 0.01));
      final search = tester.getRect(find.byKey(const Key('library-search')));
      final filter = tester.getRect(find.byKey(const Key('library-filter')));
      final searchGroupCenter = (search.left + filter.right) / 2;
      expect(searchGroupCenter, closeTo(header.center.dx, 1));

      final kindFilter = tester.getRect(
        find.byKey(const Key('desktop-gallery-kind-filter')),
      );
      expect(kindFilter.height, lessThanOrEqualTo(36));
      expect(kindFilter.center.dx, closeTo(header.center.dx, 1));
      final firstCard = tester.getRect(
        find.byKey(const ValueKey('media-card-1')),
      );
      expect(firstCard.top - kindFilter.bottom, lessThanOrEqualTo(8));

      await tester.tap(find.byKey(const Key('library-filter')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('desktop-library-filter-dialog')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('desktop-filter-cancel')), findsOneWidget);
    },
  );

  testWidgets(
    'desktop library uses the compact stacked header on narrow windows',
    (tester) async {
      tester.view.physicalSize = const Size(900, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(SquidAlbumApp(backend: FakeBackend()));
      await tester.pumpAndSettle();

      expect(
        tester.getSize(find.byKey(const Key('page-header-extent'))).height,
        112,
      );
      expect(find.byKey(const Key('library-search')), findsOneWidget);
      expect(
        find.byKey(const Key('desktop-gallery-kind-filter')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('desktop cards never show note previews', (tester) async {
    final asset = _asset(
      1,
      importedAt: DateTime.now(),
      note: 'Hidden desktop note',
    );
    final backend = FakeBackend(
      mediaItems: [asset],
      albumItems: [
        AlbumSummary(
          id: 9,
          name: 'Trip',
          description: '',
          albumType: 'manual',
          pinned: false,
          mediaCount: BigInt.one,
        ),
      ],
      albumMediaIds: {
        9: {1},
      },
    );
    backend.settings = copyAppSettings(backend.settings, showNotePreview: true);
    await tester.pumpWidget(SquidAlbumApp(backend: backend));
    await tester.pumpAndSettle();

    expect(find.text('Hidden desktop note'), findsNothing);

    await tester.tap(find.text('相册').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Trip'));
    await tester.pumpAndSettle();

    expect(find.text('Hidden desktop note'), findsNothing);
  });

  testWidgets(
    'desktop date grouping applies and clears from the filter draft',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final today = DateUtils.dateOnly(DateTime.now());
      final yesterday = today.subtract(const Duration(days: 1));
      final backend = FakeBackend(
        mediaItems: [
          _asset(1, importedAt: today.add(const Duration(hours: 9))),
          _asset(2, importedAt: yesterday.add(const Duration(hours: 9))),
          _asset(3),
        ],
      );
      await tester.pumpWidget(SquidAlbumApp(backend: backend));
      await tester.pumpAndSettle();

      expect(find.text('今天'), findsNothing);
      await tester.tap(find.byKey(const Key('library-filter')));
      await tester.pumpAndSettle();
      final grouping = find.byKey(const Key('desktop-filter-group-by-date'));
      await tester.ensureVisible(grouping);
      await tester.tap(grouping);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('desktop-filter-apply')));
      await tester.pumpAndSettle();

      expect(find.text('今天'), findsOneWidget);
      expect(find.text('昨天'), findsOneWidget);
      expect(find.text('日期未知'), findsOneWidget);

      await tester.tap(find.byKey(const Key('library-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('desktop-filter-clear')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('desktop-filter-apply')));
      await tester.pumpAndSettle();
      expect(find.text('今天'), findsNothing);
    },
  );

  testWidgets('desktop date grouping emits one header across pagination', (
    tester,
  ) async {
    final importedAt = DateUtils.dateOnly(DateTime.now())
        .add(const Duration(hours: 9));
    final backend = FakeBackend(
      mediaItems: [
        for (var id = 1; id <= 65; id++) _asset(id, importedAt: importedAt),
      ],
    );
    await tester.pumpWidget(SquidAlbumApp(backend: backend));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('library-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('desktop-filter-group-by-date')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('desktop-filter-apply')));
    await tester.pumpAndSettle();

    final scrollView = tester.widget<CustomScrollView>(
      find.byType(CustomScrollView),
    );
    scrollView.controller!.jumpTo(
      scrollView.controller!.position.maxScrollExtent,
    );
    await tester.pumpAndSettle();
    scrollView.controller!.jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.text('今天'), findsOneWidget);
  });

  testWidgets('desktop albums page provides a scroll-to-top control', (
    tester,
  ) async {
    await tester.pumpWidget(SquidAlbumApp(backend: FakeBackend()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('相册').last);
    await tester.pumpAndSettle();

    expect(find.byTooltip('回到顶部'), findsOneWidget);
  });
}

MediaAsset _asset(int id, {DateTime? importedAt, String? note}) => MediaAsset(
  id: id,
  sha256: 'desktop-$id',
  originalName: 'desktop-$id.png',
  storagePath: 'missing-$id.png',
  kind: MediaKind.image,
  capturedAt: importedAt,
  importedAt: importedAt,
  gameName: 'Splatoon 3',
  favorite: false,
  note: note,
  tags: const [],
);
