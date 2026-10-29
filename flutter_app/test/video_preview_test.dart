import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/ui/video_preview.dart';
import 'package:squid_album/src/ui/video_preview_prefetch.dart';
import 'package:squid_album/src/ui/video_thumbnail.dart';

final _pixel = Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/XyoAAAAASUVORK5CYII=',
  ),
);

void main() {
  test('desktop controls label fullscreen actions distinctly', () {
    final theme = appDesktopVideoControlsThemeData(
      onToggleImmersive: () {},
      immersive: false,
      immersiveTooltip: '应用内全屏',
      systemFullscreenTooltip: '全屏',
      immersiveKey: const Key('test-immersive'),
      systemFullscreenKey: const Key('test-system-fullscreen'),
    );

    expect(theme.bottomButtonBar, hasLength(8));
    final tooltips = theme.bottomButtonBar.whereType<Tooltip>().toList();
    expect(tooltips, hasLength(2));
    final immersive = tooltips.singleWhere(
      (tooltip) => tooltip.message == '应用内全屏',
    );
    final system = tooltips.singleWhere((tooltip) => tooltip.message == '全屏');
    expect(immersive.child, isA<MaterialDesktopCustomButton>());
    expect(system.child, isA<MaterialDesktopFullscreenButton>());
    expect(
      (immersive.child as MaterialDesktopCustomButton).key,
      const Key('test-immersive'),
    );
    expect(
      (system.child as MaterialDesktopFullscreenButton).key,
      const Key('test-system-fullscreen'),
    );
    final immersiveIconSize =
        (immersive.child as MaterialDesktopCustomButton).iconSize!;
    final systemIconSize =
        MaterialDesktopVideoControlsThemeData().buttonBarButtonSize;
    expect(immersiveIconSize, lessThan(systemIconSize));
    expect(systemIconSize - immersiveIconSize, lessThanOrEqualTo(12));
  });

  for (final androidDecoder in [false, true]) {
    testWidgets(
      'first-frame reveal retains progress controls and slider state (android=$androidDecoder)',
      (tester) async {
        final frame = Completer<void>();
        final decoded = StreamController<bool>.broadcast();
        addTearDown(decoded.close);
        await tester.pumpWidget(
          _app(
            VideoFirstFrameCover(
              identity: 'first-open-controls',
              firstFrame: frame.future,
              thumbnail: Future.value(VideoThumbnailData(bytes: _pixel)),
              decoderReady: androidDecoder ? decoded.stream : null,
              decoderInitiallyReady: !androidDecoder,
              showLoadingIndicator: false,
              child: const _ProgressControlsProbe(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final controls = tester.state(find.byType(_ProgressControlsProbe));
        final slider = find.byKey(const Key('retained-progress-slider'));
        final sliderState = tester.state(slider);
        final bounds = tester.getRect(slider);
        await tester.tapAt(
          Offset(bounds.left + bounds.width * .75, bounds.center.dy),
        );
        await tester.pumpAndSettle();
        final selected = tester.widget<Slider>(slider).value;
        expect(selected, greaterThan(.4));
        frame.complete();
        await tester.pump();
        if (androidDecoder) {
          expect(
            find.byKey(const Key('video-first-frame-cover')),
            findsOneWidget,
          );
          decoded.add(true);
        }
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('video-first-frame-cover')), findsNothing);
        expect(
          tester.state(find.byType(_ProgressControlsProbe)),
          same(controls),
          reason: 'Revealing decoded media must not unmount the progress component.',
        );
        expect(tester.state(slider), same(sliderState));
        expect(tester.widget<Slider>(slider).value, selected);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('neighbor poster without a cached cover never shows a spinner', (
    tester,
  ) async {
    final root = await tester.runAsync(
      () => Directory.systemTemp.createTemp('nso-poster-cover-'),
    );
    addTearDown(() => root!.delete(recursive: true));
    VideoThumbnailCache.configureCacheRoot(root!.path);
    await tester.pumpWidget(_app(VideoPoster(asset: _asset(99))));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byKey(const Key('video-preview-placeholder')), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test(
    'adjacent warmup waits for decoded output after an early texture frame',
    () async {
      final player = _WarmupPlayer(volume: 37);
      addTearDown(player.close);
      final frame = Completer<void>();
      final interrupted = Completer<void>();
      final warming = warmVideoPreview(
        player: player,
        firstFrame: frame.future,
        interrupted: interrupted.future,
        requireDecodedOutput: true,
      );
      await player.started.future;
      frame.complete();
      player.emitVideoParams(const VideoParams(w: 160, h: 96));
      await Future<void>.delayed(Duration.zero);
      expect(player.state.playing, isTrue);
      expect(player.state.volume, 0);
      expect(player.params.hasListener, isTrue);

      player.emitVideoParams(
        const VideoParams(w: 160, h: 96, pixelformat: 'yuv420p'),
      );
      await warming;
      expect(player.state.playing, isFalse);
      expect(player.state.volume, 37);
      expect(player.events, ['volume:0.0', 'play', 'pause', 'volume:37.0']);
      expect(player.params.hasListener, isFalse);
    },
  );

  test(
    'cancelled warmup pauses and restores the original muted volume',
    () async {
      final player = _WarmupPlayer(volume: 0);
      addTearDown(player.close);
      final interrupted = Completer<void>();
      final warming = warmVideoPreview(
        player: player,
        firstFrame: Completer<void>().future,
        interrupted: interrupted.future,
        requireDecodedOutput: true,
      );
      await player.started.future;
      interrupted.complete();
      await warming;
      expect(player.state.playing, isFalse);
      expect(player.state.volume, 0);
      expect(player.params.hasListener, isFalse);
    },
  );

  test(
    'failed warmup restores volume before a later current-page command',
    () async {
      final player = _WarmupPlayer(volume: 24)..failPlay = true;
      addTearDown(player.close);
      await expectLater(
        warmVideoPreview(
          player: player,
          firstFrame: Completer<void>().future,
          interrupted: Completer<void>().future,
          requireDecodedOutput: true,
        ),
        throwsStateError,
      );
      expect(player.events, ['volume:0.0', 'play', 'pause', 'volume:24.0']);
      expect(player.state.playing, isFalse);
      expect(player.params.hasListener, isFalse);
    },
  );

  test(
    'desktop warmup requires a frame but not an Android decoder signal',
    () async {
      final player = _WarmupPlayer(volume: 62);
      addTearDown(player.close);
      final frame = Completer<void>();
      final warming = warmVideoPreview(
        player: player,
        firstFrame: frame.future,
        interrupted: Completer<void>().future,
        requireDecodedOutput: false,
      );
      await player.started.future;
      expect(player.params.hasListener, isFalse);
      frame.complete();
      await warming;
      expect(player.state.playing, isFalse);
      expect(player.state.volume, 62);
    },
  );

  test(
    'warmup timeout releases its decoder listener and restores volume',
    () async {
      final player = _WarmupPlayer(volume: 41);
      addTearDown(player.close);
      await expectLater(
        warmVideoPreview(
          player: player,
          firstFrame: Completer<void>().future,
          interrupted: Completer<void>().future,
          requireDecodedOutput: true,
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(player.state.playing, isFalse);
      expect(player.state.volume, 41);
      expect(player.params.hasListener, isFalse);
    },
  );

  for (final (message, showsError) in [
    ('Could not open codec.', false),
    ('Error reading from stream.', true),
  ]) {
    testWidgets(
      'decoded rendered output classifies late playback message: $message',
      (tester) async {
        final frame = Completer<void>();
        final decoded = StreamController<bool>.broadcast();
        final errors = StreamController<String>.broadcast();
        addTearDown(decoded.close);
        addTearDown(errors.close);
        await tester.pumpWidget(
          _app(
            VideoFirstFrameCover(
              identity: 'late-decoder-message',
              firstFrame: frame.future,
              thumbnail: Future.value(VideoThumbnailData(bytes: _pixel)),
              playbackErrors: errors.stream,
              decoderReady: decoded.stream,
              decoderInitiallyReady: false,
              showLoadingIndicator: false,
              child: const Text('Rendered video'),
            ),
          ),
        );
        frame.complete();
        decoded.add(true);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('video-first-frame-cover')), findsNothing);

        errors.add(message);
        await tester.pumpAndSettle();
        expect(
          find.text('Unable to play this video'),
          showsError ? findsOneWidget : findsNothing,
        );
        expect(
          find.byKey(const Key('video-first-frame-cover')),
          showsError ? findsOneWidget : findsNothing,
        );
        expect(find.byType(CircularProgressIndicator), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  test(
    'decoded video requires decoder output, not only container dimensions',
    () {
      expect(hasDecodedVideo(const VideoParams(w: 1280, h: 720)), isFalse);
      expect(
        hasDecodedVideo(
          const VideoParams(pixelformat: 'yuv420p', w: 0, h: 720),
        ),
        isFalse,
      );
      expect(
        hasDecodedVideo(
          const VideoParams(pixelformat: 'yuv420p', w: 1280, h: 720),
        ),
        isTrue,
      );
      expect(
        hasDecodedVideo(
          const VideoParams(pixelformat: 'mediacodec', w: 1920, h: 1080),
        ),
        isTrue,
      );
    },
  );

  testWidgets(
    'early texture readiness keeps the cover until decoded output recovers',
    (tester) async {
      final frame = Completer<void>();
      final decoded = StreamController<bool>.broadcast();
      final errors = StreamController<String>.broadcast();
      addTearDown(decoded.close);
      addTearDown(errors.close);
      await tester.pumpWidget(
        _app(
          VideoFirstFrameCover(
            identity: 'early-texture',
            firstFrame: frame.future,
            thumbnail: Future.value(VideoThumbnailData(bytes: _pixel)),
            playbackErrors: errors.stream,
            decoderReady: decoded.stream,
            decoderInitiallyReady: false,
            showLoadingIndicator: false,
            child: const Text('Playback controls'),
          ),
        ),
      );

      frame.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('video-first-frame-cover')), findsOneWidget);
      errors.add('Could not open codec.');
      await tester.pumpAndSettle();
      expect(find.text('Unable to play this video'), findsOneWidget);
      decoded.add(false);
      await tester.pumpAndSettle();
      expect(find.text('Unable to play this video'), findsOneWidget);
      decoded.add(true);
      await tester.pumpAndSettle();
      expect(find.text('Unable to play this video'), findsNothing);
      expect(find.byKey(const Key('video-first-frame-cover')), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'cached initial cover is visible before the async thumbnail completes',
    (tester) async {
      final frame = Completer<void>();
      final thumbnail = Completer<VideoThumbnailData>();
      await tester.pumpWidget(
        _app(
          VideoFirstFrameCover(
            identity: 'cached-initial-cover',
            firstFrame: frame.future,
            thumbnail: thumbnail.future,
            initialThumbnail: VideoThumbnailData(bytes: _pixel),
            showLoadingIndicator: false,
            child: const Text('Playback controls'),
          ),
        ),
      );

      expect(find.byKey(const Key('video-first-frame-cover')), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'first-frame cover fades for 120ms after frame and decoded output',
    (tester) async {
      final frame = Completer<void>();
      final decoded = StreamController<bool>.broadcast();
      addTearDown(decoded.close);
      await tester.pumpWidget(
        _app(
          VideoFirstFrameCover(
            identity: 'fade-cover',
            firstFrame: frame.future,
            thumbnail: Future.value(VideoThumbnailData(bytes: _pixel)),
            decoderReady: decoded.stream,
            decoderInitiallyReady: false,
            showLoadingIndicator: false,
            child: const Text('Playback controls'),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('video-first-frame-cover')), findsOneWidget);

      frame.complete();
      await tester.pump();
      expect(find.byKey(const Key('video-first-frame-cover')), findsOneWidget);

      decoded.add(true);
      await tester.pump();
      expect(find.byKey(const Key('video-first-frame-cover')), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 119));
      expect(find.byKey(const Key('video-first-frame-cover')), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 2));
      expect(find.byKey(const Key('video-first-frame-cover')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('a rendered fallback frame clears a preceding decoder error', (
    tester,
  ) async {
    final frame = Completer<void>();
    final errors = StreamController<String>.broadcast();
    addTearDown(errors.close);
    await tester.pumpWidget(
      _app(
        VideoFirstFrameCover(
          identity: 'recovering-decoder',
          firstFrame: frame.future,
          thumbnail: Future.value(VideoThumbnailData(bytes: _pixel)),
          playbackErrors: errors.stream,
          showLoadingIndicator: false,
          child: const Text('Playback controls'),
        ),
      ),
    );
    errors.add('synthetic hardware decoder initialization failed');
    await tester.pump();
    expect(find.text('Unable to play this video'), findsOneWidget);

    frame.complete();
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('Unable to play this video'), findsNothing);
    expect(find.byKey(const Key('video-first-frame-cover')), findsNothing);
    expect(find.text('Playback controls'), findsOneWidget);

    errors.add('synthetic terminal decoder failure after first frame');
    await tester.pump();
    await tester.pump();
    expect(find.text('Unable to play this video'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('old decoder errors cannot cover a different video', (
    tester,
  ) async {
    final oldFrame = Completer<void>();
    final newFrame = Completer<void>();
    final errors = StreamController<String>.broadcast();
    addTearDown(errors.close);
    await tester.pumpWidget(
      _app(
        VideoFirstFrameCover(
          identity: 'old',
          firstFrame: oldFrame.future,
          thumbnail: Future.value(const VideoThumbnailData()),
          playbackErrors: errors.stream,
          child: const SizedBox(),
        ),
      ),
    );
    await tester.pumpWidget(
      _app(
        VideoFirstFrameCover(
          identity: 'new',
          firstFrame: newFrame.future,
          thumbnail: Future.value(const VideoThumbnailData()),
          child: const SizedBox(),
        ),
      ),
    );
    errors.add('synthetic obsolete decoder error');
    oldFrame.complete();
    await tester.pump();
    expect(find.text('Unable to play this video'), findsNothing);
    expect(find.byKey(const Key('video-first-frame-cover')), findsOneWidget);
    newFrame.complete();
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('video-first-frame-cover')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'a rendered frame does not suppress an explicit opening failure',
    (tester) async {
      final frame = Completer<void>();
      await tester.pumpWidget(
        _app(
          VideoFirstFrameCover(
            identity: 'explicit-failure',
            firstFrame: frame.future,
            thumbnail: Future.value(const VideoThumbnailData()),
            error: StateError('synthetic opening failure'),
            showLoadingIndicator: false,
            child: const SizedBox(),
          ),
        ),
      );
      frame.complete();
      await tester.pump();
      expect(find.text('Unable to play this video'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('poster stays until rendered frame, not thumbnail completion', (
    tester,
  ) async {
    final frame = Completer<void>();
    await tester.pumpWidget(
      _app(
        VideoFirstFrameCover(
          identity: 'a',
          firstFrame: frame.future,
          thumbnail: Future.value(VideoThumbnailData(bytes: _pixel)),
          child: const Text('Playback controls'),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('video-first-frame-cover')), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('Playback controls'), findsOneWidget);
    await tester.pump(const Duration(seconds: 20));
    expect(find.byKey(const Key('video-first-frame-cover')), findsOneWidget);
    frame.complete();
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('video-first-frame-cover')), findsNothing);
    expect(find.text('Playback controls'), findsOneWidget);
  });

  testWidgets('old frame and cover callbacks cannot reveal a new video', (
    tester,
  ) async {
    final oldFrame = Completer<void>();
    final newFrame = Completer<void>();
    final oldPoster = Completer<VideoThumbnailData>();
    await tester.pumpWidget(
      _app(
        VideoFirstFrameCover(
          identity: 'old',
          firstFrame: oldFrame.future,
          thumbnail: oldPoster.future,
          child: const SizedBox(),
        ),
      ),
    );
    await tester.pumpWidget(
      _app(
        VideoFirstFrameCover(
          identity: 'new',
          firstFrame: newFrame.future,
          thumbnail: Future.value(const VideoThumbnailData()),
          child: const SizedBox(),
        ),
      ),
    );
    oldFrame.complete();
    oldPoster.complete(VideoThumbnailData(bytes: _pixel));
    await tester.pump();
    expect(find.byType(Image), findsNothing);
    expect(find.byKey(const Key('video-first-frame-cover')), findsOneWidget);
    newFrame.complete();
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('video-first-frame-cover')), findsNothing);
  });

  testWidgets('missing cover has visible loading then stable playback error', (
    tester,
  ) async {
    final frame = Completer<void>();
    final missing = Completer<VideoThumbnailData>();
    await tester.pumpWidget(
      _app(
        VideoFirstFrameCover(
          identity: 'a',
          firstFrame: frame.future,
          thumbnail: missing.future,
          child: const Text('Playback controls'),
        ),
      ),
    );
    missing.completeError(StateError('missing cover'));
    await tester.pump();
    expect(find.byKey(const Key('video-preview-loading')), findsOneWidget);
    frame.completeError(StateError('native output failed'));
    await tester.pump();
    expect(find.text('Unable to play this video'), findsOneWidget);
    expect(find.byKey(const Key('video-preview-loading')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'android-style cover can keep a stable placeholder without spinner',
    (tester) async {
      final frame = Completer<void>();
      final missing = Completer<VideoThumbnailData>();
      await tester.pumpWidget(
        _app(
          VideoFirstFrameCover(
            identity: 'android',
            firstFrame: frame.future,
            thumbnail: missing.future,
            showLoadingIndicator: false,
            child: const SizedBox(),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('video-preview-loading')), findsNothing);
      expect(
        find.byKey(const Key('video-preview-placeholder')),
        findsOneWidget,
      );
      missing.completeError(StateError('missing cover'));
      await tester.pump();
      expect(find.byKey(const Key('video-preview-loading')), findsNothing);
      frame.complete();
    },
  );

  testWidgets(
    'a corrupt poster does not reintroduce a disabled loading spinner',
    (tester) async {
      final frame = Completer<void>();
      await tester.pumpWidget(
        _app(
          VideoFirstFrameCover(
            identity: 'corrupt-poster',
            firstFrame: frame.future,
            thumbnail: Future.value(
              VideoThumbnailData(bytes: Uint8List.fromList([1, 2, 3])),
            ),
            showLoadingIndicator: false,
            child: const SizedBox(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        find.byKey(const Key('video-preview-placeholder')),
        findsOneWidget,
      );
      frame.complete();
    },
  );

  test(
    'rapid prefetch updates keep one active request and latest neighbors only',
    () async {
      final first = Completer<void>();
      final loaded = <int>[];
      var active = 0, peak = 0;
      final prefetch = MediaPreviewPrefetch(
        warm: (asset) async {
          loaded.add(asset.id);
          active++;
          if (active > peak) peak = active;
          if (loaded.length == 1) await first.future;
          active--;
        },
      );
      final items = List.generate(10, _asset);
      prefetch.around(items, 1);
      await Future<void>.delayed(Duration.zero);
      prefetch.around(items, 3);
      prefetch.around(items, 7);
      first.complete();
      await Future<void>.delayed(Duration.zero);
      expect(loaded, [0, 6, 8]);
      expect(peak, 1);
      prefetch.dispose();
      prefetch.around(items, 5);
      await Future<void>.delayed(Duration.zero);
      expect(loaded, [0, 6, 8]);
    },
  );

  test('leaving cancels queued neighbor work', () async {
    final first = Completer<void>();
    final loaded = <int>[];
    final prefetch = MediaPreviewPrefetch(
      warm: (asset) async {
        loaded.add(asset.id);
        await first.future;
      },
    );
    prefetch.around(List.generate(4, _asset), 1);
    prefetch.dispose();
    first.complete();
    await Future<void>.delayed(Duration.zero);
    expect(loaded, [0]);
  });
}

Widget _app(Widget child) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: const [AppLocalizations.delegate],
  home: Scaffold(body: SizedBox(width: 400, height: 250, child: child)),
);

MediaAsset _asset(int index) => MediaAsset(
  id: index,
  sha256: 'sha-$index',
  originalName: '$index.mp4',
  storagePath: 'missing-$index.mp4',
  kind: MediaKind.video,
  gameName: 'Game',
  favorite: false,
  tags: const [],
);

class _ProgressControlsProbe extends StatefulWidget {
  const _ProgressControlsProbe();

  @override
  State<_ProgressControlsProbe> createState() => _ProgressControlsProbeState();
}

class _ProgressControlsProbeState extends State<_ProgressControlsProbe> {
  double value = .2;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.bottomCenter,
    child: Slider(
      key: const Key('retained-progress-slider'),
      value: value,
      onChanged: (next) => setState(() => value = next),
    ),
  );
}

class _WarmupPlayer implements Player {
  _WarmupPlayer({required double volume}) : state = PlayerState(volume: volume);

  @override
  PlayerState state;
  final events = <String>[];
  final started = Completer<void>();
  final params = StreamController<VideoParams>.broadcast();
  bool failPlay = false;
  @override
  late final stream = _WarmupStream(params.stream);

  void emitVideoParams(VideoParams value) {
    state = state.copyWith(videoParams: value);
    params.add(value);
  }

  @override
  Future<void> setVolume(double value) async {
    events.add('volume:$value');
    state = state.copyWith(volume: value);
  }

  @override
  Future<void> play() async {
    events.add('play');
    started.complete();
    if (failPlay) throw StateError('synthetic warmup decoder failure');
    state = state.copyWith(playing: true);
  }

  @override
  Future<void> pause() async {
    events.add('pause');
    state = state.copyWith(playing: false);
  }

  Future<void> close() => params.close();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected warmup player boundary');
}

class _WarmupStream implements PlayerStream {
  _WarmupStream(this.videoParams);
  @override
  final Stream<VideoParams> videoParams;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected warmup stream boundary');
}
