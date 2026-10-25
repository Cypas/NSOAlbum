import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:squid_album/src/backend/app_backend.dart';
import 'package:squid_album/src/backend/account_name_history.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/ui/media_metadata_editor.dart';
import 'package:squid_album/src/ui/media_viewer.dart';
import 'package:squid_album/src/ui/media_details_dialog.dart';

import 'home_shell_test.dart' show FakeBackend;
import 'layout_viewport.dart';

final image = MediaAsset(
  id: 1,
  sha256: 'synthetic-secret-hash',
  originalName: 'synthetic.png',
  storagePath: 'C:/synthetic/original.png',
  kind: MediaKind.image,
  gameName: 'Synthetic game',
  favorite: false,
  tags: const [],
);

class DetailsBackend extends FakeBackend {
  DetailsBackend()
    : super(
        signedIn: true,
        accountProfiles: const [
          NintendoAccountProfile(accountId: 'synthetic-a', nickname: 'Alice'),
          NintendoAccountProfile(accountId: 'synthetic-b', nickname: 'Bob'),
        ],
      );
  @override
  Future<MediaDetails> loadMediaDetails(int mediaId) async => MediaDetails(
    media: image,
    storagePath: image.storagePath,
    sizeBytes: BigInt.from(1536),
    createdAt: DateTime(2026, 10, 24, 18, 3, 4, 908, 975),
    importedAt: DateTime(2026, 10, 24, 18, 3, 4, 908, 975),
    capturedAt: DateTime(2026, 10, 22, 23, 29, 31),
    sources: const [
      MediaSourceDetails(sourceType: 'nso', provider: 'nso_coral:synthetic-b'),
      MediaSourceDetails(sourceType: 'nso', provider: 'nso_coral:missing'),
    ],
  );
}

Widget app(Widget child, {String locale = 'zh', double scale = 1}) =>
    MaterialApp(
      locale: Locale(locale),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: child,
    );

Future<void> showViewer(
  WidgetTester tester, {
  String locale = 'zh',
  AppBackend? backend,
  double width = 1100,
  double scale = 1,
}) async {
  await useLayoutTestViewport(tester, Size(width, 800));
  await tester.pumpWidget(
    app(
      MediaViewer(
        backend: backend ?? DetailsBackend(),
        items: [image],
        initialIndex: 0,
        autoPlayVideo: false,
        compactTagDisplay: true,
      ),
      locale: locale,
      scale: scale,
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'narrow large-text image actions stay reachable without overflow',
    (tester) async {
      await showViewer(tester, width: 640, scale: 2);
      expect(tester.takeException(), isNull);
      final details = find.byKey(const Key('media-viewer-details'));
      await tester.ensureVisible(details);
      await tester.pumpAndSettle();
      expect(details.hitTestable(), findsOneWidget);
    },
  );
  testWidgets(
    'removed account history resolves sources without an active login',
    (tester) async {
      await showViewer(tester, backend: _HistoryBackend());
      await tester.tap(find.byKey(const Key('media-viewer-details')));
      await tester.pumpAndSettle();
      expect(find.text('NSO · Previous Bob'), findsOneWidget);
      expect(find.textContaining('nso_coral:'), findsNothing);
    },
  );

  testWidgets('missing times do not fall back to legacy created time', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        MediaDetailsDialog(
          details: MediaDetails(
            media: image,
            storagePath: image.storagePath,
            sizeBytes: BigInt.zero,
            createdAt: DateTime(2026, 10, 24),
            sources: const [],
          ),
          onOpenDirectory: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('录入时间：未记录'), findsOneWidget);
    expect(find.text('拍摄时间：未记录'), findsOneWidget);
    expect(find.textContaining('2026-10-24'), findsNothing);
  });

  testWidgets('image has no immersive action and details is the last action', (
    tester,
  ) async {
    await showViewer(tester);
    expect(find.byKey(const Key('media-viewer-immersive')), findsNothing);
    expect(
      tester.getCenter(find.byKey(const Key('media-viewer-details'))).dx,
      greaterThan(
        tester
            .getCenter(find.byKey(const Key('media-viewer-edit-metadata')))
            .dx,
      ),
    );
  });

  for (final locale in ['zh', 'en']) {
    testWidgets(
      'details uses only whole-second import and capture time in $locale',
      (tester) async {
        await showViewer(tester, locale: locale);
        await tester.tap(find.byKey(const Key('media-viewer-details')));
        await tester.pumpAndSettle();
        expect(
          find.textContaining(locale == 'zh' ? '创建时间：' : 'Created:'),
          findsNothing,
        );
        expect(
          find.text(
            '${locale == 'zh' ? '录入时间：' : 'Imported: '}2026-10-24 18:03:04',
          ),
          findsOneWidget,
        );
        expect(
          find.text(
            '${locale == 'zh' ? '拍摄时间：' : 'Captured: '}2026-10-22 23:29:31',
          ),
          findsOneWidget,
        );
        expect(
          find.text(
            locale == 'zh'
                ? '媒体大小：1.50 KB'
                : 'Media size: 1.50 KB',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('.908975'), findsNothing);
        expect(find.text('NSO · Bob'), findsOneWidget);
        expect(
          find.text(locale == 'zh' ? 'NSO · 未知账号' : 'NSO · Unknown account'),
          findsOneWidget,
        );
        expect(find.textContaining('nso_coral:'), findsNothing);
        expect(find.text(image.storagePath), findsOneWidget);
      },
    );
  }

  testWidgets('metadata editor does not expose technical identity', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        Scaffold(
          body: MediaMetadataEditor(backend: FakeBackend(), asset: image),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining(image.storagePath), findsNothing);
    expect(find.textContaining(image.sha256), findsNothing);
    expect(find.byKey(const Key('save-media-metadata')), findsOneWidget);
  });
}

class _HistoryBackend extends DetailsBackend
    implements NintendoAccountNameHistoryBackend {
  @override
  Future<List<NintendoAccountNameRecord>>
  listNintendoAccountNameHistory() async => const [
    NintendoAccountNameRecord(
      accountId: 'synthetic-b',
      nickname: 'Previous Bob',
      updatedAt: null,
    ),
  ];
}
