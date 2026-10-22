@Tags(['platform-android', 'native-android'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:ffmpeg_kit_flutter_new_video/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_video/return_code.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/backend/app_logger.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/state/settings_copy.dart';
import 'package:squid_album/src/ui/android/android_media_viewer.dart';
import 'package:squid_album/src/ui/android/android_metadata_editor.dart';
import 'package:squid_album/src/ui/android/android_theme.dart';
import 'package:squid_album/src/ui/android/android_video_surface.dart';
import 'package:squid_album/src/ui/android/android_video_editor.dart';
import 'package:squid_album/src/ui/video_preview.dart';
import 'package:squid_album/src/ui/video_thumbnail.dart';

import '../home_shell_test.dart' show FakeBackend;

// Run this file with `flutter run --debug -t ... -d <android-device>`.
// Live binding exercises the actual Android texture/decoder, without opening
// Rust, system credentials or a personal library. Host suites skip explicitly.
Future<void> main() async {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  if (binding is LiveTestWidgetsFlutterBinding) {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (binding.platformDispatcher.views.first.physicalSize.isEmpty) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('Android viewport was not initialized.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
  group(
    'Android synthetic native media viewer',
    () {
      testWidgets(
        'a held media response keeps the cached cover visibly painted until real decoded output',
        (tester) async {
          final (root, _, _) = await _fixture(count: 0);
          final bytes = base64Decode(
            (await rootBundle.loadString('assets/ci/synthetic-h264-aac.base64'))
                .replaceAll(RegExp(r'\s'), ''),
          );
          final source = File(p.join(root.path, 'slow-synthetic.mp4'));
          await source.writeAsBytes([
            ...bytes,
            0,
            0,
            0,
            9,
            102,
            114,
            101,
            101,
            231,
          ]);
          final asset = _asset(
            231,
            source.path,
            sha256.convert(await source.readAsBytes()).toString(),
          );
          final recorder = ui.PictureRecorder();
          Canvas(recorder).drawColor(const Color(0xff23be5a), BlendMode.src);
          final picture = recorder.endRecording();
          final poster = await picture.toImage(32, 18);
          final posterData = await poster.toByteData(
            format: ui.ImageByteFormat.png,
          );
          poster.dispose();
          picture.dispose();
          final cache = Directory(
            p.join(root.path, 'cache', 'video_thumbnails'),
          );
          await cache.create(recursive: true);
          await File(p.join(cache.path, '${asset.sha256}.jpg'))
              .writeAsBytes(posterData!.buffer.asUint8List());
          await File(p.join(cache.path, '${asset.sha256}.duration'))
              .writeAsString('1500');
          final gate = Completer<void>();
          final arrived = Completer<void>();
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          final subscription = server.listen((request) async {
            request.response.headers.contentType = ContentType('video', 'mp4');
            final payload = await source.readAsBytes();
            request.response.contentLength = payload.length;
            if (request.method != 'HEAD') {
              if (!arrived.isCompleted) arrived.complete();
              await gate.future;
              request.response.add(payload);
            }
            await request.response.close();
          });
          final boundaryKey = GlobalKey();
          final swipes = <int>[];
          try {
            await tester.pumpWidget(
              MaterialApp(
                locale: const Locale('en'),
                supportedLocales: AppLocalizations.supportedLocales,
                localizationsDelegates: const [
                  AppLocalizations.delegate,
                  GlobalMaterialLocalizations.delegate,
                  GlobalWidgetsLocalizations.delegate,
                  GlobalCupertinoLocalizations.delegate,
                ],
                theme: androidTheme('ocean'),
                home: Scaffold(
                  body: RepaintBoundary(
                    key: boundaryKey,
                    child: AndroidVideoSurface(
                      path: 'http://127.0.0.1:${server.port}/synthetic.mp4',
                      cover: asset,
                      autoPlay: true,
                      onSwipe: swipes.add,
                    ),
                  ),
                ),
              ),
            );
            await _pumpUntil(tester, () => arrived.isCompleted);
            await _pumpUntil(tester, () {
              final images = find.descendant(
                of: find.byKey(const Key('video-first-frame-cover')),
                matching: find.byType(RawImage),
              );
              return images.evaluate().length == 1 &&
                  tester.widget<RawImage>(images).image != null;
            });
            await tester.pump(const Duration(seconds: 3));
            final active = tester.state<AndroidVideoSurfaceState>(
              _activeSurface(),
            );
            expect(hasDecodedVideo(active.player.state.videoParams), isFalse);
            expect(find.byType(CircularProgressIndicator), findsNothing);
            final seek = find.byKey(const Key('android-video-seek'));
            final initialSeekState = tester.state(seek);
            final initialSeekBounds = tester.getRect(seek);
            final previewBounds = tester.getRect(find.byType(VideoPreview));
            expect(
              initialSeekBounds.left >= previewBounds.left &&
                  initialSeekBounds.top >= previewBounds.top &&
                  initialSeekBounds.right <= previewBounds.right &&
                  initialSeekBounds.bottom <= previewBounds.bottom,
              isTrue,
              reason:
                  'The playback controls must stay inside the video region.',
            );
            final coverRect = tester.getRect(
              find.byKey(const Key('video-first-frame-cover')),
            );
            final boundaryRect = tester.getRect(find.byKey(boundaryKey));
            final boundary =
                boundaryKey.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final capture = await boundary.toImage(pixelRatio: 1);
            List<int>? heldTrackPixel;
            final trackX =
                (initialSeekBounds.left -
                        boundaryRect.left +
                        initialSeekBounds.width * .75)
                    .round();
            final trackY = (initialSeekBounds.center.dy - boundaryRect.top)
                .round();
            try {
              final rgba = await capture.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              );
              final x =
                  (coverRect.left - boundaryRect.left + coverRect.width * .25)
                      .round();
              final y =
                  (coverRect.top - boundaryRect.top + coverRect.height * .5)
                      .round();
              final offset = (y * capture.width + x) * 4;
              final trackOffset = (trackY * capture.width + trackX) * 4;
              heldTrackPixel = rgba!.buffer.asUint8List().sublist(
                trackOffset,
                trackOffset + 4,
              );
              expect(
                rgba.buffer.asUint8List().sublist(offset, offset + 4),
                [35, 190, 90, 255],
                reason: 'The poster must be painted above the opening native texture, not merely mounted.',
              );
              final png = await capture.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await File(p.join(root.path, 'held-cover.png'))
                  .writeAsBytes(png!.buffer.asUint8List());
            } finally {
              capture.dispose();
            }
            debugPrint(
              'SLOW_FRAME_QA heldPosterPixel=35,190,90,255 evidence_id=${p.basename(root.path)}',
            );
            gate.complete();
            await _pumpUntil(tester, () {
              return active.ready &&
                  hasDecodedVideo(active.player.state.videoParams) &&
                  find
                      .byKey(const Key('video-first-frame-cover'))
                      .evaluate()
                      .isEmpty;
            }, details: () => _nativeReadiness(tester));
            await active.player.pause();
            await tester.pump();
            expect(tester.state(seek), same(initialSeekState));
            expect(tester.getRect(seek), initialSeekBounds);
            final revealed = await boundary.toImage(pixelRatio: 1);
            try {
              final rgba = await revealed.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              );
              final trackOffset = (trackY * revealed.width + trackX) * 4;
              expect(
                rgba!.buffer.asUint8List().sublist(
                  trackOffset,
                  trackOffset + 4,
                ),
                heldTrackPixel,
                reason: 'Preparing-to-ready must not repaint the Android progress track to a new color.',
              );
            } finally {
              revealed.dispose();
            }
            expect(find.byType(CircularProgressIndicator), findsNothing);
            await tester.drag(seek, const Offset(80, 0));
            await tester.pump();
            expect(swipes, isEmpty, reason: 'Scrubbing must not switch media.');
            await tester.dragFrom(
              tester.getRect(find.byType(VideoPreview)).centerLeft +
                  const Offset(180, 0),
              const Offset(-140, 0),
            );
            expect(swipes, [
              1,
            ], reason: 'The video area must still allow paging.');
            debugPrint(
              'SLOW_FRAME_QA decodedFrameVisible=true progressStateRetained=true progressPaintRetained=true controlsInsideVideo=true scrubDoesNotPage=true',
            );
            expect(tester.takeException(), isNull);
          } finally {
            if (!gate.isCompleted) gate.complete();
            await _releaseViewer(tester);
            await server.close(force: true);
            await subscription.cancel();
          }
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );

      for (final (label, editorType) in [
        ('Edit tags and note', AndroidMetadataEditor),
        ('Trim video', AndroidVideoEditor),
      ]) {
        testWidgets(
          'opening $label waits for queued playback and leaves the source paused',
          (tester) async {
            final (_, assets, backend) = await _fixture();
            final asset = assets.first;
            final gate = Completer<void>();
            Future<void>? queuedPlay;
            AndroidVideoSurfaceState? surface;
            var editorOpenedBeforePause = false;
            var sourcePlayingInEditor = false;
            var resumedAfterReturning = false;
            try {
              await tester.pumpWidget(_app(backend, [asset]));
              final output = find.byType(AndroidVideoSurface);
              await _pumpUntil(tester, () {
                if (output.evaluate().length != 1) return false;
                return tester.state<AndroidVideoSurfaceState>(output).ready;
              });
              surface = tester.state<AndroidVideoSurfaceState>(output);
              final active = surface;
              final started = Completer<void>();
              queuedPlay = active.playbackLifecycle.runCommand(() async {
                started.complete();
                await gate.future;
                await active.player.play();
              });
              await started.future;
              await tester.tap(find.byTooltip('More'));
              await tester.pumpAndSettle();
              await tester.tap(find.text(label));
              await tester.pump(const Duration(milliseconds: 100));
              editorOpenedBeforePause = find
                  .byType(editorType)
                  .evaluate()
                  .isNotEmpty;

              gate.complete();
              await queuedPlay;
              await _pumpUntil(
                tester,
                () => find.byType(editorType).evaluate().isNotEmpty,
              );
              await tester.pump(const Duration(milliseconds: 200));
              sourcePlayingInEditor = active.player.state.playing;
              await tester.pageBack();
              await _pumpUntil(
                tester,
                () => find.byType(editorType).evaluate().isEmpty,
              );
              await active.playbackLifecycle.play();
              resumedAfterReturning = active.player.state.playing;
            } finally {
              if (!gate.isCompleted) gate.complete();
              await queuedPlay;
              await tester.pumpWidget(const SizedBox.shrink());
              await surface?.release();
              await tester.pump(const Duration(milliseconds: 300));
              // Retain this small owned fixture/cache as native failure evidence.
              // No user files or existing test directories are deleted.
            }
            expect(
              editorOpenedBeforePause,
              isFalse,
              reason:
                  'Navigation must wait behind an admitted playback command.',
            );
            expect(sourcePlayingInEditor, isFalse);
            expect(resumedAfterReturning, isTrue);
            expect(backend.noteUpdates, isEmpty);
            expect(backend.tagUpdates, isEmpty);
            expect(tester.takeException(), isNull);
          },
          timeout: const Timeout(Duration(minutes: 3)),
        );
      }

      testWidgets(
        'swiping while an editor waits cancels the superseded edit request',
        (tester) async {
          final (_, assets, backend) = await _fixture();
          final gate = Completer<void>();
          Future<void>? queuedPlay;
          var staleEditorOpened = false;
          var secondMediaSelected = false;
          try {
            await tester.pumpWidget(_app(backend, assets));
            final output = _activeSurface();
            await _pumpUntil(
              tester,
              () => tester.state<AndroidVideoSurfaceState>(output).ready,
            );
            final surface = tester.state<AndroidVideoSurfaceState>(output);
            final started = Completer<void>();
            queuedPlay = surface.playbackLifecycle.runCommand(() async {
              started.complete();
              await gate.future;
              await surface.player.play();
            });
            await started.future;
            await tester.tap(find.byTooltip('More'));
            await tester.pumpAndSettle();
            await tester.tap(find.text('Edit tags and note'));
            await tester.pump(const Duration(milliseconds: 100));
            expect(find.byType(AndroidMetadataEditor), findsNothing);
            await tester.drag(
              find.byKey(const Key('android-detail-media')),
              const Offset(-260, 0),
            );
            await tester.pump(const Duration(milliseconds: 50));
            gate.complete();
            await queuedPlay;
            await tester.pump(const Duration(seconds: 1));
            staleEditorOpened = find
                .byType(AndroidMetadataEditor)
                .evaluate()
                .isNotEmpty;
            secondMediaSelected = find
                .text('2 / 2', skipOffstage: false)
                .evaluate()
                .isNotEmpty;
          } finally {
            if (!gate.isCompleted) gate.complete();
            await queuedPlay;
            await _releaseViewer(tester);
          }
          expect(secondMediaSelected, isTrue);
          expect(
            staleEditorOpened,
            isFalse,
            reason: 'A later swipe must invalidate the waiting editor request.',
          );
          expect(backend.noteUpdates, isEmpty);
          expect(backend.tagUpdates, isEmpty);
          expect(tester.takeException(), isNull);
        },
        timeout: const Timeout(Duration(minutes: 3)),
      );

      testWidgets(
        'warms both adjacent videos and retires players outside the three-item window',
        (tester) async {
          final (_, assets, backend) = await _fixture(count: 5);
          try {
            await tester.pumpWidget(_app(backend, assets, initialIndex: 2));
            await _pumpUntil(tester, () {
              final warm = _activeVideoSurfaces(tester);
              return warm.length == 3 &&
                  warm.every((surface) => surface.ready) &&
                  warm
                      .where(
                        (surface) => surface.widget.cover.id != assets[2].id,
                      )
                      .every((surface) => _isPrewarmed(tester, surface));
            }, details: () => 'warm=${_surfaceSummary(tester)}');

            final firstWindow = _activeVideoSurfaces(tester);
            expect(
              firstWindow.map((surface) => surface.widget.cover.id).toSet(),
              {assets[1].id, assets[2].id, assets[3].id},
            );
            final previous = firstWindow.singleWhere(
              (surface) => surface.widget.cover.id == assets[1].id,
            );
            expect(previous.player.state.playing, isFalse);
            expect(previous.player.state.volume, 100);
            expect(
              tester
                  .state<AndroidVideoSurfaceState>(_activeSurface())
                  .player
                  .state
                  .playing,
              isFalse,
            );

            await tester.drag(
              find.byKey(const Key('android-detail-media')),
              const Offset(-260, 0),
            );
            await _pumpUntil(
              tester,
              () => find.text('4 / 5').evaluate().isNotEmpty,
            );
            await _pumpUntil(tester, () {
              final warm = _activeVideoSurfaces(tester);
              return warm.length == 3 &&
                  warm.every((surface) => surface.ready) &&
                  warm
                      .where(
                        (surface) => surface.widget.cover.id != assets[3].id,
                      )
                      .every((surface) => _isPrewarmed(tester, surface)) &&
                  warm.any(
                    (surface) => surface.widget.cover.id == assets[4].id,
                  );
            }, details: () => 'warm=${_surfaceSummary(tester)}');

            expect(previous.released, isTrue);
            final current = _activeVideoSurfaces(
              tester,
            ).singleWhere((surface) => surface.widget.cover.id == assets[3].id);
            expect(current.player.state.playing, isFalse);
            expect(current.player.state.volume, 100);
            expect(
              _activeVideoSurfaces(tester)
                  .map((surface) => surface.widget.cover.id)
                  .toSet(),
              {assets[2].id, assets[3].id, assets[4].id},
            );
            expect(
              _activeVideoSurfaces(tester)
                  .where((surface) => !surface.widget.active)
                  .every((surface) => !surface.player.state.playing),
              isTrue,
            );
            expect(tester.takeException(), isNull);
          } finally {
            await _releaseViewer(tester);
          }
        },
        timeout: const Timeout(Duration(minutes: 3)),
      );

      for (final autoPlay in [false, true]) {
        testWidgets(
          'a decoder failure keeps navigation usable and the next video plays (autoPlay=$autoPlay)',
          (tester) async {
            final (root, assets, backend) = await _fixture();
            final badFile = File(p.join(root.path, 'invalid-synthetic.mp4'));
            final badBytes = utf8.encode(
              'This is deliberately not a media container.',
            );
            await badFile.writeAsBytes(badBytes);
            final invalid = _asset(
              3,
              badFile.path,
              sha256.convert(badBytes).toString(),
            );
            final items = [invalid, assets.first];
            final errorSubscriptions = <StreamSubscription<String>>[];
            try {
              await tester.pumpWidget(_app(backend, items, autoPlay: autoPlay));
              await _pumpUntil(
                tester,
                () => find
                    .descendant(
                      of: _activeSurface(),
                      matching: find.text('Unable to play this video'),
                    )
                    .evaluate()
                    .isNotEmpty,
              );
              for (final output in tester.stateList<AndroidVideoSurfaceState>(
                find.byType(AndroidVideoSurface, skipOffstage: false),
              )) {
                errorSubscriptions.add(
                  output.player.stream.error.listen((message) {
                    debugPrint(
                      'NATIVE_MEDIA_ERROR media=${output.widget.cover.id} '
                      '${sanitizeDiagnostic(message)}',
                    );
                  }),
                );
              }
              expect(
                find.descendant(
                  of: _activeSurface(),
                  matching: find.byType(CircularProgressIndicator),
                ),
                findsNothing,
              );
              await tester.drag(
                find.byKey(const Key('android-detail-media')),
                const Offset(-260, 0),
              );
              await _pumpUntil(
                tester,
                () => find.text('2 / 2').evaluate().isNotEmpty,
              );
              await _pumpUntil(
                tester,
                () =>
                    tester
                        .widget<PageView>(
                          find.byKey(const Key('android-detail-media')),
                        )
                        .controller!
                        .page ==
                    1,
              );
              await _pumpUntil(tester, () {
                final active = _activeSurface();
                return active.evaluate().length == 1 &&
                    tester.state<AndroidVideoSurfaceState>(active).ready;
              });
              if (!autoPlay) {
                expect(
                  tester
                      .state<AndroidVideoSurfaceState>(_activeSurface())
                      .player
                      .state
                      .playing,
                  isFalse,
                );
                await tester.tap(
                  find.descendant(
                    of: _activeSurface(),
                    matching: find.byKey(const Key('android-video-toggle')),
                  ),
                );
              }
              await _pumpUntil(tester, () {
                final output = _activeSurface();
                if (output.evaluate().length != 1) return false;
                final active = tester.state<AndroidVideoSurfaceState>(output);
                return active.ready &&
                    active.player.state.playing &&
                    hasDecodedVideo(active.player.state.videoParams) &&
                    find
                        .descendant(
                          of: _activeSurface(),
                          matching: find.byKey(
                            const Key('video-first-frame-cover'),
                          ),
                        )
                        .evaluate()
                        .isEmpty;
              }, details: () => _nativeReadiness(tester));
              expect(
                find.descendant(
                  of: _activeSurface(),
                  matching: find.byType(CircularProgressIndicator),
                ),
                findsNothing,
              );
              expect(tester.takeException(), isNull);
            } finally {
              for (final subscription in errorSubscriptions) {
                await subscription.cancel();
              }
              await _releaseViewer(tester);
            }
          },
          timeout: const Timeout(Duration(minutes: 3)),
        );
      }

      testWidgets(
        'trim editor exposes one playback toggle that follows the native player',
        (tester) async {
          final (root, assets, backend) = await _fixture();
          try {
            await tester.pumpWidget(_trimEditor(backend, assets.first));
            final controls = find
                .ancestor(
                  of: find.textContaining('Selection '),
                  matching: find.byType(Wrap),
                )
                .first;
            expect(
              find.descendant(of: controls, matching: find.byType(IconButton)),
              findsOneWidget,
              reason: 'The selection controls must not expose separate play and pause buttons.',
            );
            final toggle = find.byKey(
              const Key('android-trim-playback-toggle'),
            );
            await _pumpUntil(tester, () => toggle.evaluate().length == 1);
            expect(find.byTooltip('Play selection'), findsNothing);
            expect(find.byTooltip('Pause'), findsNothing);
            final dynamic state = tester.state(find.byType(AndroidVideoEditor));
            await tester.tap(toggle);
            await _pumpUntil(
              tester,
              () =>
                  state.player.state.playing == true &&
                  tester.widget<IconButton>(toggle).tooltip == 'Pause',
            );
            await tester.tap(toggle);
            await _pumpUntil(
              tester,
              () =>
                  state.player.state.playing == false &&
                  tester.widget<IconButton>(toggle).tooltip == 'Play',
            );
            expect(
              find.byKey(const Key('android-trim-playback-toggle')),
              findsOneWidget,
            );
            expect(tester.takeException(), isNull);
          } finally {
            await _releaseTrimEditor(tester);
          }
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );

      testWidgets(
        'large encoded videos survive repeated paging with bounded players and release',
        (tester) async {
          final (root, assets, backend) = await _largeFixture();
          final seen = <AndroidVideoSurfaceState>{};
          var success = false;
          try {
            debugPrint('LARGE_VIDEO_QA phase=baseline');
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump(const Duration(seconds: 4));
            await tester.pumpWidget(
              _app(backend, assets, initialIndex: 2, autoPlay: true),
            );
            await _pumpUntil(
              tester,
              () => _settledLargeWindow(tester, assets[2].id),
              details: () => _surfaceSummary(tester),
            );
            seen.addAll(_activeVideoSurfaces(tester));
            debugPrint('LARGE_VIDEO_QA phase=warm');
            await tester.pump(const Duration(seconds: 4));

            var current = 2;
            var direction = 1;
            final timings = <int>[];
            for (var step = 0; step < 32; step++) {
              if (current == assets.length - 1) direction = -1;
              if (current == 0) direction = 1;
              current += direction;
              final elapsed = Stopwatch()..start();
              await tester.drag(
                find.byKey(const Key('android-detail-media')),
                Offset(-260.0 * direction, 0),
              );
              await _pumpUntil(
                tester,
                () =>
                    find
                        .text('${current + 1} / ${assets.length}')
                        .evaluate()
                        .isNotEmpty &&
                    tester
                            .widget<PageView>(
                              find.byKey(const Key('android-detail-media')),
                            )
                            .controller!
                            .page ==
                        current,
              );
              timings.add(elapsed.elapsedMilliseconds);
              final window = _activeVideoSurfaces(tester);
              seen.addAll(window);
              expect(window.length, inInclusiveRange(1, 3));
              expect(
                window.every(
                  (surface) =>
                      surface.widget.active ||
                      !surface.player.state.playing ||
                      surface.player.state.volume == 0,
                ),
                isTrue,
                reason: 'A neighboring player may prepare only while muted.',
              );
              expect(
                find.descendant(
                  of: _activeSurface(),
                  matching: find.byType(CircularProgressIndicator),
                ),
                findsNothing,
              );
              expect(
                seen
                    .where((surface) => !window.contains(surface))
                    .every((surface) => surface.released),
                isTrue,
              );
              if ((step + 1) % 8 == 0) {
                await _pumpUntil(
                  tester,
                  () => _settledLargeWindow(tester, assets[current].id),
                  details: () => _surfaceSummary(tester),
                );
                debugPrint('LARGE_VIDEO_QA phase=round-${(step + 1) ~/ 8}');
                await tester.pump(const Duration(seconds: 3));
              }
              expect(tester.takeException(), isNull);
            }
            debugPrint(
              'LARGE_VIDEO_QA gestures=${timings.length} '
              'maxPagingMs=${timings.reduce((a, b) => a > b ? a : b)} '
              'playersCreated=${seen.length}',
            );
            await _releaseViewer(tester);
            expect(seen.every((surface) => surface.released), isTrue);
            seen.clear();
            debugPrint('LARGE_VIDEO_QA phase=released');
            await tester.pump(const Duration(seconds: 8));
            if (const bool.fromEnvironment('NSOALBUM_VIDEO_CYCLE_QA')) {
              // Native media_kit disposal currently schedules final mpv destroy
              // five seconds later. Sample stable post-exit boundaries beyond
              // that delay, without retaining disposed surfaces in this test.
              for (var cycle = 1; cycle <= 4; cycle++) {
                await _enterExitLargeVideoCycle(tester, backend, assets, cycle);
              }
            }
            expect(tester.takeException(), isNull);
            success = true;
          } finally {
            await _releaseViewer(tester);
            // Only this invocation's owned synthetic root is removed on success.
            // A failure retains its generated media for diagnosis.
            if (success) await root.delete(recursive: true);
            debugPrint('LARGE_VIDEO_QA phase=${success ? 'done' : 'failed'}');
          }
        },
        skip: !const bool.fromEnvironment('NSOALBUM_LARGE_VIDEO_QA'),
        timeout: const Timeout(Duration(minutes: 8)),
      );
    },
    skip: Platform.isAndroid
        ? false
        : 'Requires an Android ARM64 Debug device with real media plugins.',
  );
}

Future<void> _enterExitLargeVideoCycle(
  WidgetTester tester,
  FakeBackend backend,
  List<MediaAsset> assets,
  int cycle,
) async {
  await tester.pumpWidget(
    _app(backend, assets, initialIndex: 2, autoPlay: true),
  );
  await _pumpUntil(
    tester,
    () => _settledLargeWindow(tester, assets[2].id),
    details: () => _surfaceSummary(tester),
  );
  debugPrint('LARGE_VIDEO_QA phase=cycle-$cycle-open');
  await tester.pump(const Duration(seconds: 3));
  await _releaseViewer(tester);
  expect(find.byType(AndroidVideoSurface, skipOffstage: false), findsNothing);
  await tester.pump(const Duration(seconds: 12));
  debugPrint('LARGE_VIDEO_QA phase=cycle-$cycle-released');
  await tester.pump(const Duration(seconds: 4));
  expect(tester.takeException(), isNull);
}

bool _settledLargeWindow(WidgetTester tester, int currentId) {
  final window = _activeVideoSurfaces(tester);
  final expected = currentId == 1 || currentId == 5 ? 2 : 3;
  if (window.length != expected) return false;
  final current = window.where(
    (surface) => surface.widget.cover.id == currentId,
  );
  if (current.length != 1) return false;
  return current.single.ready &&
      current.single.player.state.playing &&
      hasDecodedVideo(current.single.player.state.videoParams) &&
      current.single.player.state.duration >= const Duration(seconds: 29) &&
      find
          .descendant(
            of: _activeSurface(),
            matching: find.byKey(const Key('video-first-frame-cover')),
          )
          .evaluate()
          .isEmpty &&
      window
          .where((surface) => !surface.widget.active)
          .every((surface) => _isPrewarmed(tester, surface));
}

Future<(Directory, List<MediaAsset>, FakeBackend)> _largeFixture() async {
  final (root, _, backend) = await _fixture(count: 0);
  final seed = File(p.join(root.path, 'seed.mp4'));
  await seed.writeAsBytes(
    base64Decode(
      (await rootBundle.loadString('assets/ci/synthetic-h264-aac.base64'))
          .replaceAll(RegExp(r'\s'), ''),
    ),
  );
  final encoded = File(p.join(root.path, 'encoded-source.mp4'));
  debugPrint('LARGE_VIDEO_QA phase=encoding');
  final session = await FFmpegKit.executeWithArguments([
    '-hide_banner',
    '-loglevel',
    'error',
    '-n',
    '-stream_loop',
    '-1',
    '-i',
    seed.path,
    '-an',
    '-vf',
    'scale=1280:720,noise=alls=50:allf=t',
    '-r',
    '30',
    '-t',
    '30',
    '-c:v',
    'mpeg4',
    '-b:v',
    '16M',
    '-maxrate',
    '16M',
    '-bufsize',
    '32M',
    '-pix_fmt',
    'yuv420p',
    '-threads',
    '2',
    '-movflags',
    '+faststart',
    encoded.path,
  ]);
  if (!ReturnCode.isSuccess(await session.getReturnCode())) {
    throw StateError(
      'Bundled FFmpeg could not encode the large synthetic fixture.',
    );
  }
  final length = await encoded.length();
  expect(length, inInclusiveRange(40 * 1024 * 1024, 128 * 1024 * 1024));
  final assets = <MediaAsset>[];
  for (var id = 1; id <= 5; id++) {
    final file = await encoded.copy(p.join(root.path, 'large-$id.mp4'));
    final trailer = ByteData(9)
      ..setUint32(0, 9)
      ..setUint8(8, id);
    trailer.buffer.asUint8List().setRange(4, 8, ascii.encode('free'));
    final output = file.openWrite(mode: FileMode.append);
    output.add(trailer.buffer.asUint8List());
    await output.close();
    final digest = await sha256.bind(file.openRead()).first;
    assets.add(_asset(id, file.path, digest.toString()));
  }
  backend.mediaItems = assets;
  debugPrint('LARGE_VIDEO_QA bytesPerVideo=$length videos=${assets.length}');
  return (root, assets, backend);
}

Finder _activeSurface() => find.byWidgetPredicate(
  (widget) => widget is AndroidVideoSurface && widget.active,
);

Future<(Directory, List<MediaAsset>, FakeBackend)> _fixture({
  int count = 2,
}) async {
  final root = await Directory.systemTemp.createTemp('nsoalbum-viewer-qa-');
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
    assets.add(_asset(id, file.path, sha256.convert(bytes).toString()));
  }
  final backend = FakeBackend(mediaItems: assets);
  backend.settings = copyAppSettings(
    backend.settings,
    language: 'en',
    autoPlayVideo: false,
  );
  VideoThumbnailCache.configureCacheRoot(root.path);
  return (root, assets, backend);
}

MediaAsset _asset(int id, String path, String digest) => MediaAsset(
  id: id,
  sha256: digest,
  originalName: p.basename(path),
  storagePath: path,
  kind: MediaKind.video,
  importedAt: DateTime.utc(2026, 10, 21),
  gameName: 'Synthetic game',
  favorite: false,
  tags: const ['Synthetic tag'],
);

Widget _app(
  FakeBackend backend,
  List<MediaAsset> items, {
  bool? autoPlay,
  int initialIndex = 0,
}) => MaterialApp(
  locale: const Locale('en'),
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  theme: androidTheme('ocean'),
  home: AndroidMediaViewer(
    backend: backend,
    items: items,
    initialIndex: initialIndex,
    autoPlay: autoPlay,
  ),
);

List<AndroidVideoSurfaceState> _activeVideoSurfaces(WidgetTester tester) =>
    tester
        .stateList<AndroidVideoSurfaceState>(
          find.byType(AndroidVideoSurface, skipOffstage: false),
        )
        .where((surface) => !surface.released)
        .toList(growable: false);

String _surfaceSummary(WidgetTester tester) => [
  for (final surface in _activeVideoSurfaces(tester))
    '${surface.widget.cover.id}:ready=${surface.ready}:active=${surface.widget.active}:playing=${surface.player.state.playing}:prewarmed=${_isPrewarmed(tester, surface)}',
].join(',');

bool _isPrewarmed(WidgetTester tester, AndroidVideoSurfaceState surface) {
  final output = find.byWidgetPredicate(
    (widget) =>
        widget is AndroidVideoSurface &&
        widget.cover.id == surface.widget.cover.id,
    skipOffstage: false,
  );
  final gate = find.descendant(
    of: output,
    matching: find.byType(VideoFirstFrameCover, skipOffstage: false),
  );
  if (gate.evaluate().length != 1) return false;
  final dynamic state = tester.state(gate);
  return state.rendered == true &&
      state.decoded == true &&
      !surface.player.state.playing &&
      surface.player.state.volume == 100;
}

Widget _trimEditor(FakeBackend backend, MediaAsset source) => MaterialApp(
  locale: const Locale('en'),
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  theme: androidTheme('ocean'),
  home: AndroidVideoEditor(backend: backend, source: source),
);

Future<void> _releaseViewer(WidgetTester tester) async {
  final surfaces = tester
      .stateList<AndroidVideoSurfaceState>(
        find.byType(AndroidVideoSurface, skipOffstage: false),
      )
      .toList();
  await tester.pumpWidget(const SizedBox.shrink());
  await Future.wait(surfaces.map((surface) => surface.release()));
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _releaseTrimEditor(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 300));
}

String _nativeReadiness(WidgetTester tester) {
  final active = _activeSurface();
  if (active.evaluate().length != 1) {
    return 'activeSurfaces=${active.evaluate().length}';
  }
  final surface = tester.state<AndroidVideoSurfaceState>(active);
  final gate = find.descendant(
    of: active,
    matching: find.byType(VideoFirstFrameCover),
  );
  final gateState = gate.evaluate().length == 1
      ? tester.state(gate) as dynamic
      : null;
  return 'ready=${surface.ready} '
      'decoded=${hasDecodedVideo(surface.player.state.videoParams)} '
      'playing=${surface.player.state.playing} '
      'coverGate=${gateState != null} '
      'rendered=${gateState?.rendered} '
      'gateDecoded=${gateState?.decoded} '
      'gateFailed=${gateState?.failed} '
      'playbackError=${gateState?.playbackError != null} '
      'error=${sanitizeDiagnostic('${gateState?.playbackError ?? 'none'}')}';
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() ready, {
  String Function()? details,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException(
        'Synthetic native media condition was not ready.'
        '${details == null ? '' : ' ${details()}'}',
      );
    }
    await tester.pump(const Duration(milliseconds: 50));
  }
}
