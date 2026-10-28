@Tags(['platform-android'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/ui/android/android_media_viewer.dart';
import 'package:squid_album/src/ui/android/android_theme.dart';

import '../home_shell_test.dart' show FakeBackend;
import '../layout_viewport.dart';

void main() {
  for (final locale in ['en', 'zh']) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        '$locale ${scale}x compact metadata actions retain accessible touch targets',
        (tester) async {
          final semantics = tester.ensureSemantics();
          try {
            await useLayoutTestViewport(tester, const Size(320, 720));
            await tester.pumpWidget(
              _app([_image(1)], locale: locale, scale: scale),
            );
            await tester.pumpAndSettle();
            await tester.tap(find.byKey(const Key('android-detail-toggle')));
            await tester.pumpAndSettle();
            final addTag = find.byKey(const Key('android-inline-add-tag'));
            await tester.ensureVisible(addTag);
            await tester.pumpAndSettle();
            expect(
              tester.getSemantics(addTag).getSemanticsData().tooltip,
              locale == 'zh' ? '新增标签' : 'Add tag',
            );
            await expectLater(
              tester,
              meetsGuideline(androidTapTargetGuideline),
            );
            await expectLater(
              tester,
              meetsGuideline(labeledTapTargetGuideline),
            );
            final media = find.byKey(const Key('android-detail-media'));
            await tester.tap(media);
            await tester.pumpAndSettle();
            expect(
              find.byKey(const Key('android-detail-overlay')),
              findsOneWidget,
            );
            expect(
              find.byKey(const Key('android-detail-information')),
              findsOneWidget,
            );
            await tester.tap(addTag);
            await tester.pumpAndSettle();
            expect(
              find.byKey(const Key('android-inline-tag-input')),
              findsOneWidget,
            );
            expect(tester.takeException(), isNull);
          } finally {
            semantics.dispose();
          }
        },
      );
    }
  }

  testWidgets('media swipes animate through a shared pager', (tester) async {
    await tester.pumpWidget(_app([_image(1), _image(2)]));
    await tester.pump();
    await tester.tap(find.byKey(const Key('android-detail-toggle')));
    await tester.pumpAndSettle();

    final pagerFinder = find.byKey(const Key('android-detail-media'));
    expect(pagerFinder, findsOneWidget);
    final pager = tester.widget<PageView>(pagerFinder);
    await tester.drag(
      find.byKey(const Key('android-detail-media')),
      const Offset(-250, 0),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 70));

    expect(pager.controller!.page, greaterThan(0));
    expect(pager.controller!.page, lessThan(1));
    await tester.pumpAndSettle();
    expect(pager.controller!.page, 1);
    expect(
      tester
          .widget<Text>(find.byKey(const Key('android-detail-filename')))
          .data,
      _image(2).originalName,
    );
  });

  testWidgets('detail image decodes at viewport physical size with zoom room', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(720, 1600);
    tester.view.devicePixelRatio = 2;
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_app([_image(1), _image(2)]));
    await tester.pump();

    final image = tester.widget<Image>(find.byType(Image).first);
    expect(image.image, isA<ResizeImage>());
    final decoded = image.image as ResizeImage;
    expect(decoded.width, 1080);
    expect(decoded.height, 2400);
  });

  testWidgets('detail page changes briefly fade without replacing the pager', (
    tester,
  ) async {
    await tester.pumpWidget(_app([_image(1), _image(2)]));
    await tester.pump();
    final media = find.byKey(const Key('android-detail-media'));
    final pager = tester.widget<PageView>(find.byType(PageView));

    await tester.drag(media, const Offset(-250, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));

    final fadeFinder = find.byKey(const Key('android-detail-page-fade'));
    expect(fadeFinder, findsOneWidget);
    final fade = tester.widget<FadeTransition>(fadeFinder);
    expect(fade.opacity.value, greaterThan(0));
    expect(fade.opacity.value, lessThan(1));
    expect(
      tester.widget<PageView>(find.byType(PageView)).controller,
      same(pager.controller),
    );

    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FadeTransition>(
            find.byKey(const Key('android-detail-page-fade')),
          )
          .opacity
          .value,
      1,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('detail uses a light overlay, single-line filename and swipe', (
    tester,
  ) async {
    final items = [_image(1), _image(2)];
    await tester.pumpWidget(_app(items));
    await tester.pump();
    expect(find.byType(AppBar), findsNothing);
    expect(find.byTooltip('Next'), findsNothing);
    expect(find.byTooltip('Previous'), findsNothing);
    final preview = find.byKey(const Key('android-detail-media'));
    final size = tester.getSize(preview);
    expect(size.height, greaterThan(300));
    await tester.tap(find.byKey(const Key('android-detail-toggle')));
    await tester.pumpAndSettle();
    final name = tester.widget<Text>(
      find.byKey(const Key('android-detail-filename')),
    );
    expect(name.maxLines, 1);
    expect(name.overflow, TextOverflow.ellipsis);
    expect(find.text('1 / 2'), findsNothing);
    await tester.drag(preview, const Offset(-250, 0));
    await tester.pumpAndSettle();
    expect(find.text('2 / 2'), findsNothing);
    expect(
      tester
          .widget<Text>(find.byKey(const Key('android-detail-filename')))
          .data,
      items[1].originalName,
    );
    await tester.tap(preview);
    await tester.pump();
    expect(find.byKey(const Key('android-detail-overlay')), findsOneWidget);
    await tester.tap(preview);
    await tester.pump();
    expect(find.byKey(const Key('android-detail-overlay')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'normal viewer keeps metadata hidden and exposes prototype action dock',
    (tester) async {
      await tester.pumpWidget(_app([_image(1)]));
      await tester.pump();

      expect(find.byKey(const Key('android-detail-information')), findsNothing);
      expect(
        find.byKey(const Key('android-detail-action-dock')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('android-detail-favorite')), findsOneWidget);
      expect(find.byKey(const Key('android-detail-edit')), findsOneWidget);
      expect(find.byKey(const Key('android-detail-filmstrip')), findsOneWidget);
      expect(find.byTooltip('In-app fullscreen'), findsNothing);
    },
  );

  testWidgets('image normal mode toggles a black fully immersive canvas', (
    tester,
  ) async {
    await tester.pumpWidget(_app([_image(1)]));
    await tester.pumpAndSettle();
    final preview = find.byKey(const Key('android-detail-media'));
    final canvas = find.byKey(
      const ValueKey(('android-media-page', 1, 'image-1')),
    );
    final surfaceColor = Theme.of(tester.element(canvas)).colorScheme.surface;
    expect(tester.widget<ColoredBox>(canvas).color, surfaceColor);
    final previewRectBefore = tester.getRect(preview);

    await tester.tap(preview);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('android-detail-immersive')), findsOneWidget);
    expect(find.byKey(const Key('android-detail-overlay')), findsNothing);
    expect(
      tester
          .widget<Visibility>(
            find.byKey(const Key('android-detail-filmstrip-visibility')),
          )
          .visible,
      isFalse,
    );
    expect(
      tester
          .widget<Visibility>(
            find.byKey(const Key('android-detail-action-dock-visibility')),
          )
          .visible,
      isFalse,
    );
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      Colors.black,
    );
    expect(tester.widget<ColoredBox>(canvas).color, Colors.black);
    expect(tester.getRect(preview), previewRectBefore);

    await tester.tap(preview);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('android-detail-immersive')), findsNothing);
    expect(find.byKey(const Key('android-detail-overlay')), findsOneWidget);
    expect(
      tester
          .widget<Visibility>(
            find.byKey(const Key('android-detail-filmstrip-visibility')),
          )
          .visible,
      isTrue,
    );
    expect(
      tester
          .widget<Visibility>(
            find.byKey(const Key('android-detail-action-dock-visibility')),
          )
          .visible,
      isTrue,
    );
    expect(tester.getRect(preview), previewRectBefore);
  });

  testWidgets(
    'immersive media keeps geometry when system bar padding changes',
    (tester) async {
      final backend = _ViewerBackend([_image(1)]);
      await tester.pumpWidget(
        _app(
          [_image(1)],
          backend: backend,
          padding: const EdgeInsets.fromLTRB(0, 24, 0, 12),
        ),
      );
      await tester.pumpAndSettle();
      final preview = find.byKey(const Key('android-detail-media'));
      final before = tester.getRect(preview);

      await tester.tap(preview);
      await tester.pumpAndSettle();
      await tester.pumpWidget(_app([_image(1)], backend: backend));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('android-detail-immersive')), findsOneWidget);
      expect(tester.getRect(preview), before);
    },
  );

  testWidgets(
    'image more menu contains only album actions and toggles closed',
    (tester) async {
      await tester.pumpWidget(_app([_image(1)]));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('android-detail-more')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('android-detail-more-menu')), findsOneWidget);
      expect(find.text('Copy to album'), findsOneWidget);
      expect(find.text('Move to album'), findsOneWidget);
      expect(find.text('Capture current frame'), findsNothing);
      expect(find.text('View media details'), findsNothing);
      expect(find.text('Edit tags and note'), findsNothing);
      final menu = find.byKey(const Key('android-detail-more-menu'));
      final menuRect = tester.getRect(menu);
      final scaffoldRect = tester.getRect(find.byType(Scaffold));
      expect(menuRect.width, lessThanOrEqualTo(232));
      expect(scaffoldRect.right - menuRect.right, closeTo(12, 0.01));
      expect(menuRect.height, lessThan(scaffoldRect.height * .42));

      await tester.tap(find.byKey(const Key('android-detail-more')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('android-detail-more-menu')), findsNothing);

      await tester.tap(find.byKey(const Key('android-detail-more')));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(24, 24));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('android-detail-more-menu')), findsNothing);
      expect(find.byKey(const Key('android-detail-overlay')), findsOneWidget);
      expect(
        find.byKey(const Key('android-detail-action-dock')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('android-detail-more')));
      await tester.pumpAndSettle();
      final filmstrip = find.byKey(const Key('android-detail-filmstrip'));
      final firstThumbnail = find
          .descendant(of: filmstrip, matching: find.byType(InkWell))
          .first;
      await tester.tap(firstThumbnail);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('android-detail-more-menu')), findsNothing);
      expect(find.byKey(const Key('android-detail-overlay')), findsOneWidget);
    },
  );

  for (final variant in [
    (locale: 'zh', width: 360.0, scale: 2.0),
    (locale: 'en', width: 320.0, scale: 2.0),
  ]) {
    testWidgets(
      'right-aligned more menu stays compact in ${variant.locale} at 2x',
      (tester) async {
        tester.view.physicalSize = Size(variant.width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          _app([_image(1)], locale: variant.locale, scale: variant.scale),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('android-detail-more')));
        await tester.pumpAndSettle();

        final menuRect = tester.getRect(
          find.byKey(const Key('android-detail-more-menu')),
        );
        final scaffoldRect = tester.getRect(find.byType(Scaffold));
        expect(menuRect.width, lessThanOrEqualTo(232));
        expect(scaffoldRect.right - menuRect.right, closeTo(12, 0.01));
        expect(menuRect.height, lessThan(scaffoldRect.height * .42));
        expect(tester.takeException(), isNull);
      },
    );
  }

  test('video and image more actions use the reduced action sets', () {
    expect(androidViewerMoreActionsFor(MediaKind.video), [
      AndroidViewerMoreAction.copyToAlbum,
      AndroidViewerMoreAction.moveToAlbum,
      AndroidViewerMoreAction.captureFrame,
    ]);
    expect(androidViewerMoreActionsFor(MediaKind.image), [
      AndroidViewerMoreAction.copyToAlbum,
      AndroidViewerMoreAction.moveToAlbum,
    ]);
  });

  testWidgets(
    'image viewer does not expose immersive action and keeps details behind the toggle',
    (tester) async {
      await tester.pumpWidget(_app([_image(1)]));
      await tester.pump();

      expect(find.byTooltip('In-app fullscreen'), findsNothing);
      await tester.tap(find.byKey(const Key('android-detail-toggle')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('android-detail-information')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('android-detail-filmstrip')), findsNothing);
      expect(find.byKey(const Key('android-detail-action-dock')), findsNothing);
    },
  );

  testWidgets(
    'swiping with unsaved note requires confirmation and keeps input',
    (tester) async {
      await tester.pumpWidget(_app([_image(1), _image(2)]));
      await tester.pump();
      await tester.tap(find.byKey(const Key('android-detail-toggle')));
      await tester.pumpAndSettle();
      final edit = find.byKey(const Key('android-inline-edit-note'));
      await tester.ensureVisible(edit);
      await tester.tap(edit);
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('android-inline-note-input')),
        'Unsaved',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await tester.drag(
        find.byKey(const Key('android-detail-media')),
        const Offset(-200, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('Discard unsaved changes?'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const Key('android-detail-filename')))
            .data,
        _image(1).originalName,
      );
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('android-inline-note-input')),
            )
            .controller!
            .text,
        'Unsaved',
      );
    },
  );

  testWidgets('failed inline note save retains draft and can be retried', (
    tester,
  ) async {
    final backend = _FailNoteBackend();
    await tester.pumpWidget(_app([_image(1)], backend: backend));
    await tester.pump();
    await tester.tap(find.byKey(const Key('android-detail-toggle')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const Key('android-inline-edit-note')),
    );
    await tester.tap(find.byKey(const Key('android-inline-edit-note')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('android-inline-note-input')),
      'Keep my draft',
    );
    final save = find.byKey(const Key('android-inline-save-note'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pump();
    await tester.pump(const Duration(seconds: 9));
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('android-inline-note-input')))
          .controller!
          .text,
      'Keep my draft',
    );
    backend.fail = false;
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pump();
    expect(backend.noteUpdates[1], 'Keep my draft');
    expect(find.byKey(const Key('android-inline-note-input')), findsNothing);
    expect(find.text('Keep my draft'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'swipe restores controls so the next media keeps its actions reachable',
    (tester) async {
      await tester.pumpWidget(_app([_image(1), _image(2)]));
      await tester.pump();
      await tester.tap(find.byKey(const Key('android-detail-toggle')));
      await tester.pumpAndSettle();
      final media = find.byKey(const Key('android-detail-media'));
      await tester.tap(media);
      await tester.pump();
      expect(find.byKey(const Key('android-detail-overlay')), findsOneWidget);
      await tester.drag(media, const Offset(-250, 0));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const Key('android-detail-filename')))
            .data,
        _image(2).originalName,
      );
      expect(find.byKey(const Key('android-detail-action-dock')), findsNothing);
      expect(
        find.byKey(const Key('android-detail-information')),
        findsOneWidget,
      );
    },
  );

  registerAndroidDetailLayoutTests();
}

void registerAndroidDetailLayoutTests() {
  for (final locale in ['en', 'zh']) {
    for (final brightness in Brightness.values) {
      testWidgets(
        '$locale $brightness narrow large text metadata remains usable',
        (tester) async {
          await useLayoutTestViewport(tester, const Size(320, 720));
          await tester.pumpWidget(
            _app([_image(1)], locale: locale, brightness: brightness, scale: 2),
          );
          await tester.pump();
          await tester.tap(find.byKey(const Key('android-detail-toggle')));
          await tester.pumpAndSettle();
          expect(
            tester.getSize(find.byType(Scaffold).first).width,
            320,
            reason: 'The matrix must render at its requested viewport.',
          );
          expect(
            find.text('Full custom tag without truncation'),
            findsOneWidget,
          );
          final imported = find.byKey(const Key('android-detail-imported'));
          await tester.ensureVisible(imported);
          await tester.pump();
          expect(find.textContaining('2026-10-18 12:34:56'), findsOneWidget);
          expect(find.textContaining('123456'), findsNothing);
          expect(
            find.textContaining(locale == 'zh' ? '未记录' : 'Not recorded'),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}

Widget _app(
  List<MediaAsset> items, {
  String locale = 'en',
  Brightness brightness = Brightness.light,
  double scale = 1,
  FakeBackend? backend,
  EdgeInsets padding = EdgeInsets.zero,
}) => MaterialApp(
  locale: Locale(locale),
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  theme: androidTheme('ocean').copyWith(
    brightness: brightness,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xff5577e8),
      brightness: brightness,
    ),
  ),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context)
        .copyWith(textScaler: TextScaler.linear(scale), padding: padding),
    child: child!,
  ),
  home: AndroidMediaViewer(
    backend: backend ?? _ViewerBackend(items),
    items: items,
  ),
);

class _ViewerBackend extends FakeBackend {
  _ViewerBackend(this.items);
  final List<MediaAsset> items;

  @override
  Future<MediaDetails> loadMediaDetails(int mediaId) async {
    final item = items.firstWhere((value) => value.id == mediaId);
    return MediaDetails(
      media: item,
      storagePath: item.storagePath,
      sizeBytes: BigInt.from(123456),
      createdAt: item.importedAt,
      importedAt: item.importedAt,
      capturedAt: item.capturedAt,
      sources: const [],
    );
  }
}

class _FailNoteBackend extends _ViewerBackend {
  _FailNoteBackend() : super([_image(1)]);
  bool fail = true;
  @override
  Future<void> setNote(int id, String note) async {
    if (fail) throw StateError('Synthetic save failure');
    await super.setNote(id, note);
  }
}

MediaAsset _image(int id) => MediaAsset(
  id: id,
  sha256: 'image-$id',
  originalName: 'A very long filename that must not size the preview $id.png',
  storagePath: 'missing-$id.png',
  kind: MediaKind.image,
  importedAt: DateTime(2026, 10, 18, 12, 34, 56, 123, 456),
  gameName: 'Game title in full',
  favorite: false,
  tags: const ['Full custom tag without truncation'],
);
