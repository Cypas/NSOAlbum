@Tags(['platform-windows'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/ui/media_metadata_editor.dart';
import 'package:squid_album/src/ui/media_viewer.dart';
import 'package:squid_album/src/ui/video_editor.dart';
import 'package:squid_album/src/ui/video_preview.dart';
import 'package:squid_album/src/ui/video_thumbnail.dart';

import 'home_shell_test.dart' show FakeBackend;
import 'layout_viewport.dart';

// Explicit `flutter run --debug -d windows -t <this file>` only. Host widget
// suites skip; the live target uses real decoders and an in-memory backend.
Future<void> main() async {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final native = Platform.isWindows && binding is LiveTestWidgetsFlutterBinding;
  if (native) {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (binding.platformDispatcher.views.first.physicalSize.isEmpty) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('Windows native viewport did not initialize.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
  group(
    'Windows synthetic native media viewer',
    () {
      testWidgets(
        'immersive action shares video controls without replacing the player',
        (tester) async {
          final (assets, backend) = await _fixture();
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          try {
            await tester.pumpWidget(_app(backend, assets));
            final active = await _readyVideo(tester, assets.first.id);
            final media = find.byType(VideoPreview).first;
            await mouse.addPointer(location: tester.getCenter(media));
            await mouse.moveTo(tester.getCenter(media));
            final action = find.byKey(const Key('media-viewer-immersive'));
            await _pumpUntil(
              tester,
              () => action.hitTestable().evaluate().length == 1,
            );
            final rect = tester.getRect(media);
            final button = tester.getCenter(action);
            expect(rect.contains(button), isTrue);
            expect(button.dx, greaterThan(rect.center.dx));
            expect(button.dy, greaterThan(rect.center.dy));
            final previousPlayer = active.player;
            final previousController = active.controller;
            final position = active.player.state.position;
            await tester.tap(action);
            await _pumpUntil(
              tester,
              () =>
                  find.byKey(const Key('media-viewer-note')).evaluate().isEmpty,
            );
            final retained = await _readyVideo(tester, assets.first.id);
            expect(identical(retained.player, previousPlayer), isTrue);
            expect(identical(retained.controller, previousController), isTrue);
            expect(retained.player.state.position, position);
            await mouse.moveTo(const Offset(2, 2));
            await _pumpUntil(
              tester,
              () => action.hitTestable().evaluate().isEmpty,
            );
            await mouse.moveTo(tester.getCenter(media));
            await _pumpUntil(
              tester,
              () => action.hitTestable().evaluate().length == 1,
            );
            await tester.tap(action);
            await _pumpUntil(
              tester,
              () => find
                  .byKey(const Key('media-viewer-note'))
                  .evaluate()
                  .isNotEmpty,
            );
            expect(tester.takeException(), isNull);
          } finally {
            await mouse.removePointer();
            await _releaseViewer(tester);
          }
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );

      for (final language in ['zh', 'en']) {
        for (final width in [640.0, 800.0]) {
          testWidgets(
            'large-text video metadata remains usable at $width/$language',
            (tester) async {
              await useLayoutTestViewport(tester, Size(width, 600));
              final (assets, backend) = await _fixture();
              try {
                await tester.pumpWidget(
                  _app(backend, assets, language: language, textScale: 2),
                );
                await _readyVideo(tester, assets.first.id);
                final metadata = find.byKey(
                  const Key('media-viewer-edit-metadata'),
                );
                await tester.ensureVisible(metadata);
                await tester.pump(const Duration(milliseconds: 100));
                expect(metadata.hitTestable(), findsOneWidget);
                expect(tester.takeException(), isNull);
                await tester.tap(metadata);
                await _pumpUntil(
                  tester,
                  () => find.byType(MediaMetadataEditor).evaluate().isNotEmpty,
                );
                Navigator.of(tester.element(find.byType(MediaMetadataEditor)))
                    .pop();
                await _pumpUntil(
                  tester,
                  () => find.byType(MediaMetadataEditor).evaluate().isEmpty,
                );
                expect(backend.noteUpdates, isEmpty);
                expect(backend.tagUpdates, isEmpty);
                expect(tester.takeException(), isNull);
              } finally {
                await _releaseViewer(tester);
              }
            },
            timeout: const Timeout(Duration(minutes: 2)),
          );
        }
      }

      for (final (button, editor) in [
        ('media-viewer-edit-metadata', MediaMetadataEditor),
        ('media-viewer-edit-video', VideoEditorPage),
      ]) {
        testWidgets(
          '$button waits for admitted playback and keeps its source paused',
          (tester) async {
            final (assets, backend) = await _fixture();
            final gate = Completer<void>();
            Future<void>? command;
            var openedBeforePause = false;
            var playingInEditor = false;
            var resumed = false;
            try {
              await tester.pumpWidget(_app(backend, assets));
              final active = await _readyVideo(tester, assets.first.id);
              final started = Completer<void>();
              command = active.playbackLifecycle.runCommand(() async {
                started.complete();
                await gate.future;
                await active.player.play();
              }) as Future<void>;
              await started.future;
              await tester.tap(find.byKey(Key(button)));
              await tester.pump(const Duration(milliseconds: 100));
              openedBeforePause = find.byType(editor).evaluate().isNotEmpty;
              gate.complete();
              await command;
              await _pumpUntil(
                tester,
                () => find.byType(editor).evaluate().isNotEmpty,
              );
              await tester.pump(const Duration(milliseconds: 250));
              playingInEditor = active.player.state.playing as bool;
              Navigator.of(tester.element(find.byType(editor))).pop();
              await _pumpUntil(
                tester,
                () => find.byType(editor).evaluate().isEmpty,
              );
              await active.playbackLifecycle.play();
              resumed = active.player.state.playing as bool;
            } finally {
              if (!gate.isCompleted) gate.complete();
              await command;
              await _releaseViewer(tester);
            }
            expect(
              openedBeforePause,
              isFalse,
              reason: 'Editor navigation must wait behind admitted playback.',
            );
            expect(playingInEditor, isFalse);
            expect(resumed, isTrue);
            expect(backend.noteUpdates, isEmpty);
            expect(backend.tagUpdates, isEmpty);
            expect(tester.takeException(), isNull);
          },
          timeout: const Timeout(Duration(minutes: 3)),
        );
      }

      testWidgets('a later swipe invalidates an editor waiting for playback', (
        tester,
      ) async {
        final (assets, backend) = await _fixture();
        final gate = Completer<void>();
        Future<void>? command;
        var staleEditor = false;
        var selectedNext = false;
        try {
          await tester.pumpWidget(_app(backend, assets));
          final active = await _readyVideo(tester, assets.first.id);
          final started = Completer<void>();
          command = active.playbackLifecycle.runCommand(() async {
            started.complete();
            await gate.future;
            await active.player.play();
          }) as Future<void>;
          await started.future;
          await tester.tap(find.byKey(const Key('media-viewer-edit-video')));
          await tester.pump(const Duration(milliseconds: 100));
          expect(find.byType(VideoEditorPage), findsNothing);
          await tester.drag(find.byType(PageView), const Offset(-650, 0));
          final pager = tester.widget<PageView>(find.byType(PageView));
          await _pumpUntil(
            tester,
            () => (pager.controller!.page! - 1).abs() < .001,
          );
          expect(pager.controller!.page, closeTo(1, .01));
          gate.complete();
          await command;
          await tester.pump(const Duration(seconds: 1));
          staleEditor = find.byType(VideoEditorPage).evaluate().isNotEmpty;
          selectedNext = find
              .text(assets[1].originalName, skipOffstage: false)
              .evaluate()
              .isNotEmpty;
        } finally {
          if (!gate.isCompleted) gate.complete();
          await command;
          await _releaseViewer(tester);
        }
        expect(selectedNext, isTrue);
        expect(
          staleEditor,
          isFalse,
          reason: 'A later swipe must cancel the superseded editor request.',
        );
        expect(backend.noteUpdates, isEmpty);
        expect(backend.tagUpdates, isEmpty);
        expect(tester.takeException(), isNull);
      }, timeout: const Timeout(Duration(minutes: 3)));

      for (final overwrite in [false, true]) {
        testWidgets(
          'editor result preserves a playable source (overwrite=$overwrite)',
          (tester) async {
            final (assets, backend) = await _fixture();
            final replacement = MediaAsset(
              id: overwrite ? assets.first.id : 3,
              sha256: assets.last.sha256,
              originalName: 'synthetic-edited.mp4',
              storagePath: assets.last.storagePath,
              kind: MediaKind.video,
              importedAt: DateTime.utc(2026, 10, 22),
              gameName: 'Synthetic game',
              favorite: false,
              tags: const ['Edited'],
            );
            try {
              await tester.pumpWidget(_app(backend, assets));
              final source = await _readyVideo(tester, assets.first.id);
              await tester.tap(
                find.byKey(const Key('media-viewer-edit-video')),
              );
              await _pumpUntil(
                tester,
                () => find.byType(VideoEditorPage).evaluate().length == 1,
              );
              final dynamic editor = tester.state(find.byType(VideoEditorPage));
              await _pumpUntil(
                tester,
                () => (editor.duration as Duration) > Duration.zero,
              );
              // Only the viewer's route-result handoff is tested here.
              // FFmpeg/Rust writes have separate native smoke coverage.
              Navigator.of(tester.element(find.byType(VideoEditorPage))).pop(
                VideoEditorResult(asset: replacement, overwrite: overwrite),
              );
              await _pumpUntil(
                tester,
                () =>
                    find.byType(VideoEditorPage).evaluate().isEmpty &&
                    find.text(replacement.originalName).evaluate().length == 1,
              );
              if (!overwrite) {
                await tester.tap(
                  find.byKey(const Key('media-viewer-previous')),
                );
                await _pumpUntil(
                  tester,
                  () =>
                      find.text(assets.first.originalName).evaluate().length ==
                      1,
                );
              }
              final current = await _readyVideo(tester, assets.first.id);
              expect(
                current.playbackLifecycle.disposed,
                isFalse,
                reason:
                    'The source must remain usable after returning from edit.',
              );
              await current.playbackLifecycle.play();
              expect(current.player.state.playing, isTrue);
              if (overwrite) {
                expect(identical(current, source), isFalse);
                expect(source.playbackLifecycle.disposed, isTrue);
              } else {
                expect(identical(current, source), isTrue);
              }
            } finally {
              await _releaseViewer(tester);
            }
            expect(tester.takeException(), isNull);
          },
          timeout: const Timeout(Duration(minutes: 3)),
        );
      }

      testWidgets(
        'adjacent native videos stay bounded and only the current video plays',
        (tester) async {
          final (assets, backend) = await _fixture(count: 5);
          final observed = <dynamic>{};
          try {
            await tester.pumpWidget(_app(backend, assets, autoPlay: true));
            for (var index = 0; index < assets.length; index++) {
              if (index > 0) {
                await tester.tap(find.byKey(const Key('media-viewer-next')));
              }
              await _pumpUntil(
                tester,
                () =>
                    find.text(assets[index].originalName).evaluate().isNotEmpty,
              );
              final current = await _readyVideo(tester, assets[index].id);
              await _pumpUntil(
                tester,
                () => current.player.state.playing as bool,
              );
              await (current.controller.waitUntilFirstFrameRendered
                  as Future<void>);
              final gate = find.descendant(
                of: _video(assets[index].id),
                matching: find.byType(VideoFirstFrameCover),
              );
              await _pumpUntil(
                tester,
                () => (tester.state(gate) as dynamic).rendered as bool,
              );
              await _pumpUntil(tester, () {
                for (final dynamic state in tester.stateList(_allVideos())) {
                  if (identical(state, current)) continue;
                  final neighborGate = find.descendant(
                    of: _video(state.widget.asset.id as int),
                    matching: find.byType(
                      VideoFirstFrameCover,
                      skipOffstage: false,
                    ),
                  );
                  if (neighborGate.evaluate().length != 1 ||
                      (tester.state(neighborGate) as dynamic).rendered !=
                          true ||
                      state.player.state.playing != false) {
                    return false;
                  }
                }
                return true;
              });
              final states = tester.stateList(_allVideos()).toList();
              expect(states.length, inInclusiveRange(1, 3));
              for (final dynamic state in states) {
                observed.add(state);
                if (!identical(state, current)) {
                  expect(state.player.state.playing, isFalse);
                }
              }
              expect(
                find.descendant(
                  of: _video(assets[index].id),
                  matching: find.byType(CircularProgressIndicator),
                ),
                findsNothing,
              );
            }
          } finally {
            await _releaseViewer(tester);
          }
          for (final dynamic state in observed) {
            await state.release();
            expect(state.playbackLifecycle.disposed, isTrue);
          }
          expect(tester.takeException(), isNull);
        },
        timeout: const Timeout(Duration(minutes: 3)),
      );
    },
    skip: native ? false : 'Requires an explicitly launched Windows Debug app and real media plugins.',
  );
}

Finder _video(int id) => find.byWidgetPredicate(
  (widget) =>
      widget.key is GlobalKey &&
      widget.key.toString().contains('video-viewer-$id'),
  skipOffstage: false,
);

Future<dynamic> _readyVideo(WidgetTester tester, int id) async {
  final output = _video(id);
  await _pumpUntil(tester, () => output.evaluate().length == 1);
  final dynamic active = tester.state(output);
  await (active.opening as Future<void>);
  await _pumpUntil(
    tester,
    () => (active.player.state.duration as Duration) > Duration.zero,
  );
  return active;
}

Future<(List<MediaAsset>, FakeBackend)> _fixture({int count = 2}) async {
  final root = await Directory.systemTemp.createTemp(
    'nsoalbum-desktop-viewer-',
  );
  final seed = base64Decode(
    (await rootBundle.loadString('assets/ci/synthetic-h264-aac.base64'))
        .replaceAll(RegExp(r'\s'), ''),
  );
  final assets = <MediaAsset>[];
  for (var id = 1; id <= count; id++) {
    final box = ByteData(8)..setUint32(0, 9);
    box.buffer.asUint8List().setRange(4, 8, ascii.encode('free'));
    final bytes = [...seed, ...box.buffer.asUint8List(), id];
    final file = File(p.join(root.path, 'synthetic-$id.mp4'));
    await file.writeAsBytes(bytes);
    assets.add(
      MediaAsset(
        id: id,
        sha256: sha256.convert(bytes).toString(),
        originalName: 'synthetic-$id.mp4',
        storagePath: file.path,
        kind: MediaKind.video,
        importedAt: DateTime.utc(2026, 10, 21),
        gameName: 'Synthetic game',
        favorite: false,
        tags: const ['Synthetic tag'],
      ),
    );
  }
  VideoThumbnailCache.configureCacheRoot(root.path);
  return (assets, FakeBackend(mediaItems: assets));
}

Widget _app(
  FakeBackend backend,
  List<MediaAsset> assets, {
  bool autoPlay = false,
  String language = 'en',
  double textScale = 1,
}) => MaterialApp(
  locale: Locale(language),
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context)
        .copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: MediaViewer(
    backend: backend,
    items: assets,
    initialIndex: 0,
    autoPlayVideo: autoPlay,
    compactTagDisplay: false,
  ),
);

Finder _allVideos() => find.byWidgetPredicate(
  (widget) =>
      widget.key is GlobalKey &&
      widget.key.toString().contains('video-viewer-'),
  skipOffstage: false,
);

Future<void> _releaseViewer(WidgetTester tester) async {
  final states = tester.stateList(_allVideos()).toList();
  await tester.pumpWidget(const SizedBox.shrink());
  for (final dynamic state in states) {
    await state.release();
  }
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Synthetic native desktop condition not ready.');
    }
    await tester.pump(const Duration(milliseconds: 50));
  }
}
