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
              find.bySemanticsLabel(
                RegExp(locale == 'zh' ? '显示操作栏' : 'Show controls'),
              ),
              findsOneWidget,
            );
            expect(
              find.byKey(const Key('android-detail-overlay')),
              findsNothing,
            );
            await tester.tap(media);
            await tester.pumpAndSettle();
            expect(
              find.bySemanticsLabel(
                RegExp(locale == 'zh' ? '隐藏操作栏' : 'Hide controls'),
              ),
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

    expect(find.byType(PageView), findsOneWidget);
    final pager = tester.widget<PageView>(find.byType(PageView));
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
    expect(find.text('2 / 2'), findsOneWidget);
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
    final name = tester.widget<Text>(
      find.byKey(const Key('android-detail-filename')),
    );
    expect(name.maxLines, 1);
    expect(name.overflow, TextOverflow.ellipsis);
    expect(find.text('1 / 2'), findsOneWidget);
    final preview = find.byKey(const Key('android-detail-media'));
    final size = tester.getSize(preview);
    expect(size.height, greaterThan(300));
    await tester.drag(preview, const Offset(-250, 0));
    await tester.pumpAndSettle();
    expect(find.text('2 / 2'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const Key('android-detail-filename')))
          .data,
      items[1].originalName,
    );
    await tester.tap(preview);
    await tester.pump();
    expect(find.byKey(const Key('android-detail-overlay')), findsNothing);
    await tester.tap(preview);
    await tester.pump();
    expect(find.byKey(const Key('android-detail-overlay')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'swiping with unsaved note requires confirmation and keeps input',
    (tester) async {
      await tester.pumpWidget(_app([_image(1), _image(2)]));
      await tester.pump();
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
      expect(find.text('1 / 2'), findsOneWidget);
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
      final media = find.byKey(const Key('android-detail-media'));
      await tester.tap(media);
      await tester.pump();
      expect(find.byKey(const Key('android-detail-overlay')), findsNothing);
      await tester.drag(media, const Offset(-250, 0));
      await tester.pumpAndSettle();
      expect(find.text('2 / 2'), findsOneWidget);
      expect(find.byTooltip('More'), findsOneWidget);
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
            find.textContaining(locale == 'zh' ? '未知' : 'Unknown'),
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
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: AndroidMediaViewer(backend: backend ?? FakeBackend(), items: items),
);

class _FailNoteBackend extends FakeBackend {
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
