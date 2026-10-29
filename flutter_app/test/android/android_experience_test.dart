@Tags(['platform-android'])
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/main.dart';
import 'package:squid_album/src/backend/app_backend.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/ui/android/android_media_card.dart';
import 'package:squid_album/src/ui/android/android_media_viewer.dart';
import 'package:squid_album/src/ui/android/android_page_frame.dart';
import 'package:squid_album/src/ui/platform_ui.dart';

import '../home_shell_test.dart' show FakeBackend;

class StorageBackend extends FakeBackend implements MobileStorageBackend {
  @override
  Future<List<MobileStorageLocation>> mobileStorageLocations() async => const [
    MobileStorageLocation(
      id: 'internal',
      path: '/private/NSOAlbum/media',
      removable: false,
    ),
    MobileStorageLocation(
      id: 'sd',
      path: '/sd/app/NSOAlbum/media',
      removable: true,
    ),
  ];
}

MediaAsset media(int id, {bool unknownDates = false}) => MediaAsset(
  id: id,
  sha256: 'fixture-$id',
  originalName: 'private-file-$id.png',
  storagePath: 'missing.png',
  kind: MediaKind.image,
  capturedAt: unknownDates ? null : DateTime(2026, 10, 13, 1, 2, 3, 456, 789),
  importedAt: unknownDates ? null : DateTime(2026, 10, 14, 9, 8, 7, 654, 321),
  gameName: '超级马力欧奥德赛',
  favorite: false,
  tags: const ['abcdefghijklm', '我的自定义标签'],
  note: 'Hidden card note',
);

void main() => registerAndroidExperienceTests();

void registerAndroidExperienceTests({bool layoutOnly = false}) {
  if (layoutOnly) return;

  for (final language in ['zh', 'en']) {
    testWidgets(
      'Android account errors distinguish unlinked users ($language)',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(language),
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) => Text(
                androidReadableError(
                  context,
                  'provider failed: nintendo_account_not_linked (status 9407)',
                ),
              ),
            ),
          ),
        );
        expect(
          find.text(
            language == 'zh'
                ? '此 Nintendo Account 尚未关联 Switch 用户。请在主机上完成关联后重试。'
                : 'This Nintendo Account is not linked to a Switch user. Link it on your console and try again.',
          ),
          findsOneWidget,
        );
        expect(
          find.textContaining('nintendo_account_not_linked'),
          findsNothing,
        );
      },
    );
  }

  for (final locale in ['zh', 'en']) {
    testWidgets(
      'unknown imported detail survives inline edits and navigation in $locale',
      (tester) async {
        final unknown = media(1, unknownDates: true);
        final backend = FakeBackend(mediaItems: [unknown, media(2)]);
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(locale),
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            home: AndroidMediaViewer(
              backend: backend,
              items: [unknown, media(2)],
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('android-detail-toggle')));
        await tester.pumpAndSettle();
        final imported = find.byKey(const Key('android-detail-imported'));
        await tester.ensureVisible(imported);
        expect(imported, findsOneWidget);
        final unknownImported = find.descendant(
          of: imported,
          matching: find.textContaining(
            locale == 'zh' ? '未记录' : 'Not recorded',
          ),
        );
        expect(unknownImported, findsOneWidget);
        final add = find.byKey(const Key('android-inline-add-tag'));
        await tester.ensureVisible(add);
        await tester.tap(add);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('android-inline-tag-input')),
          'New',
        );
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        final edit = find.byKey(const Key('android-inline-edit-note'));
        await tester.ensureVisible(edit);
        await tester.tap(edit);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('android-inline-note-input')),
          'Updated note',
        );
        final save = find.byKey(const Key('android-inline-save-note'));
        await tester.ensureVisible(save);
        await tester.tap(save);
        await tester.pumpAndSettle();
        await tester.ensureVisible(imported);
        expect(unknownImported, findsOneWidget);
        expect(find.text('Updated note'), findsOneWidget);
        expect(find.text('New'), findsOneWidget);
        await tester.drag(
          find.byKey(const Key('android-detail-media')),
          const Offset(-250, 0),
        );
        await tester.pumpAndSettle();
        final known = find.descendant(
          of: imported,
          matching: find.textContaining('2026-10-14 09:08:07'),
        );
        await tester.ensureVisible(imported);
        expect(known, findsOneWidget);
        await tester.drag(
          find.byKey(const Key('android-detail-media')),
          const Offset(250, 0),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(imported);
        expect(unknownImported, findsOneWidget);
        expect(find.text('Updated note'), findsOneWidget);
        expect(find.text('New'), findsOneWidget);
        expect(find.text('private-file-1.png'), findsWidgets);
        expect(find.text('超级马力欧奥德赛'), findsWidgets);
        expect(find.textContaining('1970'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'mobile settings hide storage controls without changing storage backend',
    (tester) async {
      final backend = StorageBackend();
      await tester.pumpWidget(
        SquidAlbumApp(backend: backend, uiPlatform: AppUiPlatform.android),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(NavigationDestination).at(3));
      await tester.pumpAndSettle();
      expect(find.text('网络代理'), findsNothing);
      expect(find.byKey(const Key('android-storage-location')), findsNothing);
      expect(find.byKey(const Key('android-storage-card')), findsNothing);
      expect(backend.settings.libraryPath, 'C:/library');
    },
  );
  testWidgets('albums use gallery columns and the latest member as cover', (
    tester,
  ) async {
    final backend = FakeBackend(
      mediaItems: [media(1), media(2)],
      albumMediaIds: {
        1: {1},
        2: {2},
      },
      albumItems: [
        AlbumSummary(
          id: 2,
          name: 'Recent',
          description: '',
          albumType: 'normal',
          pinned: false,
          mediaCount: BigInt.two,
        ),
        AlbumSummary(
          id: 1,
          name: '收藏',
          description: '',
          albumType: 'smart',
          pinned: true,
          systemKey: 'favorites',
          mediaCount: BigInt.one,
        ),
      ],
    );
    await tester.pumpWidget(
      SquidAlbumApp(backend: backend, uiPlatform: AppUiPlatform.android),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(NavigationDestination).at(1));
    await tester.pumpAndSettle();
    expect(find.byType(GridView), findsOneWidget);
    final grid = tester.widget<GridView>(find.byType(GridView));
    expect(
      (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
          .crossAxisCount,
      4, // Test's wide screen and existing saved preference are preserved.
    );
    final covers = tester
        .widgetList<AndroidMediaThumbnail>(find.byType(AndroidMediaThumbnail))
        .toList();
    expect(covers.map((cover) => cover.asset.id), [1, 2]);
    final cardRect = tester.getRect(
      find.byKey(const ValueKey('android-album-1')),
    );
    final coverFinder = find.descendant(
      of: find.byKey(const ValueKey('android-album-1')),
      matching: find.byType(AndroidMediaThumbnail),
    );
    final coverRect = tester.getRect(coverFinder);
    expect(coverRect.width / coverRect.height, closeTo(16 / 9, .02));
    expect(cardRect.height, greaterThan(coverRect.height));
    expect(
      (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
          .mainAxisExtent,
      lessThan(coverRect.height + 130),
      reason: 'The compact height applies to the full card, not the preview.',
    );
  });
  testWidgets('network errors use an upper bubble without exposing raw URLs', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => androidMessage(
                context,
                StateError(
                  'network error: request failed https://example.invalid/?token=private',
                ),
              ),
              child: const Text('trigger'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('trigger'));
    await tester.pump();
    expect(find.byType(SnackBar), findsNothing);
    expect(find.byKey(const Key('android-notice-bubble')), findsOneWidget);
    expect(find.textContaining('example.invalid'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
  testWidgets('failed bubble copies only sanitized diagnostics and expires', (
    tester,
  ) async {
    final clipboard = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard.add(
              (call.arguments as Map<Object?, Object?>)['text']! as String,
            );
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => androidMessage(
                context,
                StateError(
                  'network error {"access_token":"private-json"} '
                  'Authorization: Bearer private-bearer '
                  'https://example.invalid/path?secret=private-query',
                ),
              ),
              child: const Text('trigger-copy'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('trigger-copy'));
    await tester.pump();
    expect(find.text('网络请求失败，请检查连接后重试。'), findsOneWidget);
    await tester.tap(find.byTooltip('复制诊断信息'));
    await tester.pump();
    expect(clipboard, hasLength(1));
    expect(clipboard.single, contains('network error'));
    for (final secret in ['private-json', 'private-bearer', 'private-query']) {
      expect(clipboard.single, isNot(contains(secret)));
    }
    await tester.pump(const Duration(seconds: 8));
    expect(find.byKey(const Key('android-notice-bubble')), findsNothing);
  });
  testWidgets(
    'metadata is visible and tags/notes can be edited without opening another page',
    (tester) async {
      final backend = FakeBackend(mediaItems: [media(1)]);
      await tester.pumpWidget(
        SquidAlbumApp(backend: backend, uiPlatform: AppUiPlatform.android),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('android-media-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('android-detail-toggle')));
      await tester.pumpAndSettle();
      expect(find.text('private-file-1.png'), findsWidgets);
      await tester.ensureVisible(
        find.byKey(const Key('android-detail-captured')),
      );
      expect(find.textContaining('2026-10-13 01:02:03'), findsOneWidget);
      expect(find.textContaining('2026-10-14 09:08:07'), findsOneWidget);
      final add = find.byKey(const Key('android-inline-add-tag'));
      await tester.ensureVisible(add);
      await tester.tap(add);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('android-inline-tag-input')),
        'New',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(backend.tagUpdates[1], ['abcdefghijklm', '我的自定义标签', 'New']);
      await tester.ensureVisible(add);
      await tester.tap(add);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('android-inline-tag-input')),
        'new',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(backend.tagUpdates[1], ['abcdefghijklm', '我的自定义标签', 'New']);
      final editNote = find.byKey(const Key('android-inline-edit-note'));
      await tester.ensureVisible(editNote);
      await tester.tap(editNote);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('android-inline-note-input')),
        'A note',
      );
      await tester.ensureVisible(
        find.byKey(const Key('android-inline-save-note')),
      );
      await tester.tap(find.byKey(const Key('android-inline-save-note')));
      await tester.pumpAndSettle();
      expect(backend.noteUpdates[1], 'A note');
    },
  );
}
