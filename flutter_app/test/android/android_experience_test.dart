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
import 'package:squid_album/src/ui/android/android_layout.dart';
import 'package:squid_album/src/ui/android/android_media_card.dart';
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

MediaAsset media(int id) => MediaAsset(
  id: id,
  sha256: 'fixture-$id',
  originalName: 'private-file-$id.png',
  storagePath: 'missing.png',
  kind: MediaKind.image,
  capturedAt: DateTime(2026, 10, 13, 1, 2, 3, 456, 789),
  importedAt: DateTime(2026, 10, 14, 9, 8, 7, 654, 321),
  gameName: '超级马力欧奥德赛',
  favorite: false,
  tags: const ['abcdefghijklm', '我的自定义标签'],
  note: 'Hidden card note',
);

void main() {
  testWidgets('mobile settings offer confirmed private storage, not a proxy', (
    tester,
  ) async {
    final backend = StorageBackend();
    await tester.pumpWidget(
      SquidAlbumApp(backend: backend, uiPlatform: AppUiPlatform.android),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(NavigationDestination).at(3));
    await tester.pumpAndSettle();
    expect(find.text('网络代理'), findsNothing);
    final choose = find.byKey(const Key('android-storage-location'));
    expect(choose, findsOneWidget);
    await tester.ensureVisible(choose);
    await tester.tap(choose);
    await tester.pumpAndSettle();
    await tester.tap(find.text('SD 卡'));
    await tester.pumpAndSettle();
    expect(backend.settings.libraryPath, isNot('/sd/app/NSOAlbum/media'));
    await tester.tap(find.byKey(const Key('android-confirm-storage')));
    await tester.pumpAndSettle();
    expect(backend.settings.libraryPath, '/sd/app/NSOAlbum/media');
  });
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
      expect(find.text('private-file-1.png'), findsWidgets);
      await tester.scrollUntilVisible(
        find.text('拍摄/创建时间：2026-10-13 01:02:03'),
        180,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('拍摄/创建时间：2026-10-13 01:02:03'), findsOneWidget);
      expect(find.text('导入时间：2026-10-14 09:08:07'), findsOneWidget);
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
  test('normal phone width fits two columns; enlarged text can use one', () {
    expect(
      androidGalleryColumns(
        width: 336,
        preferredColumns: 2,
        textScaler: TextScaler.noScaling,
        spacing: 8,
      ),
      2,
    );
    expect(
      androidGalleryColumns(
        width: 296,
        preferredColumns: 2,
        textScaler: const TextScaler.linear(2),
        spacing: 8,
      ),
      1,
    );
  });
  testWidgets('media cards show truncated tags rather than filename and note', (
    tester,
  ) async {
    final backend = FakeBackend(mediaItems: [media(1)]);
    await tester.pumpWidget(
      SquidAlbumApp(backend: backend, uiPlatform: AppUiPlatform.android),
    );
    await tester.pumpAndSettle();
    expect(find.text('private-file-1.png'), findsNothing);
    expect(find.text('Hidden card note'), findsNothing);
    expect(find.text('超级马力欧..'), findsOneWidget);
    expect(find.text('abcdefghij..'), findsOneWidget);
    expect(find.byType(AndroidMediaCard), findsOneWidget);
  });
  testWidgets(
    'navigation disappears in a secondary route and returns after back',
    (tester) async {
      final backend = FakeBackend(mediaItems: []);
      await tester.pumpWidget(
        SquidAlbumApp(backend: backend, uiPlatform: AppUiPlatform.android),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(NavigationDestination).at(2));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('android-import-entry')));
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsNothing);
      await tester.tap(find.byKey(const Key('android-page-back')));
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsOneWidget);
    },
  );
}
