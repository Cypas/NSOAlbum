import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/ui/video_viewer_lifecycle.dart';

void main() {
  test(
    'queued controls cannot survive leaving and returning to a video',
    () async {
      final started = Completer<void>();
      final finish = Completer<void>();
      final events = <String>[];
      final lifecycle = VideoViewerLifecycle(
        initiallyActive: true,
        pause: () async => events.add('pause'),
        play: () async => events.add('play'),
        disposePlayer: () async => events.add('dispose'),
      );
      final admitted = lifecycle.runCommand(() async {
        started.complete();
        await finish.future;
      });
      await started.future;
      final staleSeek = lifecycle.runCommand(
        () async => events.add('old-seek'),
      );
      final leaving = lifecycle.updateActive(false, autoPlay: false);
      final returning = lifecycle.updateActive(true, autoPlay: false);
      finish.complete();
      await Future.wait([admitted, staleSeek, leaving, returning]);
      expect(events, ['pause']);
      await lifecycle.dispose();
    },
  );

  test('superseded activation cannot autoplay after a paused return', () async {
    final started = Completer<void>();
    final finish = Completer<void>();
    var plays = 0;
    final lifecycle = VideoViewerLifecycle(
      initiallyActive: false,
      pause: () async {},
      play: () async => plays++,
      disposePlayer: () async {},
    );
    final prewarming = lifecycle.prewarm((_) async {
      started.complete();
      await finish.future;
    });
    await started.future;
    final firstArrival = lifecycle.updateActive(true, autoPlay: true);
    final leaving = lifecycle.updateActive(false, autoPlay: false);
    final pausedReturn = lifecycle.updateActive(true, autoPlay: false);
    finish.complete();
    await Future.wait([prewarming, firstArrival, leaving, pausedReturn]);
    expect(plays, 0);
    await lifecycle.dispose();
  });

  test(
    'prewarming an adjacent player is interrupted and paused on activation',
    () async {
      final warming = Completer<void>();
      final events = <String>[];
      final lifecycle = VideoViewerLifecycle(
        initiallyActive: false,
        pause: () async => events.add('pause'),
        play: () async => events.add('play'),
        disposePlayer: () async => events.add('dispose'),
      );

      final prewarming = lifecycle.prewarm((interrupted) async {
        events.add('warm');
        warming.complete();
        await interrupted;
      });
      await warming.future;
      final activation = lifecycle.updateActive(true, autoPlay: false);
      await prewarming;
      await activation;

      expect(events, ['warm', 'pause']);
      await lifecycle.play();
      expect(events, ['warm', 'pause', 'play']);
      await lifecycle.dispose();
    },
  );

  test(
    'a completed prewarm leaves the adjacent player paused without autoplay',
    () async {
      final events = <String>[];
      final lifecycle = VideoViewerLifecycle(
        initiallyActive: false,
        pause: () async => events.add('pause'),
        play: () async => events.add('play'),
        disposePlayer: () async => events.add('dispose'),
      );

      await lifecycle.prewarm((_) async => events.add('rendered'));
      await lifecycle.updateActive(true, autoPlay: false);

      expect(events, ['rendered', 'pause']);
      await lifecycle.dispose();
    },
  );

  test('disposing an adjacent player interrupts its pending prewarm before cleanup', () async {
    final warming = Completer<void>();
    final events = <String>[];
    final lifecycle = VideoViewerLifecycle(
      initiallyActive: false,
      pause: () async => events.add('pause'),
      play: () async => events.add('play'),
      disposePlayer: () async => events.add('dispose'),
    );

    final prewarming = lifecycle.prewarm((interrupted) async {
      events.add('warm');
      warming.complete();
      await interrupted;
    });
    await warming.future;
    await lifecycle.dispose();
    await prewarming;

    expect(events, ['warm', 'pause', 'dispose']);
  });

  test(
    'manual play finishing after navigation leaves the old video paused',
    () async {
      final started = Completer<void>();
      final allowed = Completer<void>();
      var playing = false;
      final lifecycle = VideoViewerLifecycle(
        initiallyActive: true,
        pause: () async => playing = false,
        play: () async {
          started.complete();
          await allowed.future;
          playing = true;
        },
        disposePlayer: () async {},
      );

      final playingCommand = lifecycle.play();
      await started.future;
      final leaving = lifecycle.updateActive(false, autoPlay: false);
      allowed.complete();
      await Future.wait([playingCommand, leaving]);

      expect(playing, isFalse);
      await lifecycle.dispose();
    },
  );

  test('manual play completes before the native player is destroyed', () async {
    final started = Completer<void>();
    final allowed = Completer<void>();
    var destroyed = false;
    var playedAfterDestruction = false;
    final lifecycle = VideoViewerLifecycle(
      initiallyActive: true,
      pause: () async {},
      play: () async {
        started.complete();
        await allowed.future;
        playedAfterDestruction = destroyed;
      },
      disposePlayer: () async => destroyed = true,
    );

    final playingCommand = lifecycle.play();
    await started.future;
    final disposing = lifecycle.dispose();
    await Future<void>.delayed(Duration.zero);
    final destroyedBeforePlaySettled = destroyed;
    allowed.complete();
    await Future.wait([playingCommand, disposing]);

    expect(destroyed, isTrue);
    expect(destroyedBeforePlaySettled, isFalse);
    expect(playedAfterDestruction, isFalse);
  });

  test('manual play is ignored for a departed or disposed video', () async {
    var plays = 0;
    final lifecycle = VideoViewerLifecycle(
      initiallyActive: false,
      pause: () async {},
      play: () async => plays++,
      disposePlayer: () async {},
    );

    await lifecycle.play();
    expect(plays, 0);
    await lifecycle.dispose();
    await lifecycle.play();
    expect(plays, 0);
  });

  test(
    'pausing for an editor keeps the current video available for manual resume',
    () async {
      var playing = false;
      final lifecycle = VideoViewerLifecycle(
        initiallyActive: true,
        pause: () async => playing = false,
        play: () async => playing = true,
        disposePlayer: () async {},
      );

      await lifecycle.play();
      await lifecycle.pause();
      expect(playing, isFalse);
      await lifecycle.play();
      expect(playing, isTrue);
      await lifecycle.dispose();
    },
  );

  test('queued controls are dropped on departure and a failed command does not block disposal', () async {
    final started = Completer<void>();
    final allowed = Completer<void>();
    final events = <String>[];
    final lifecycle = VideoViewerLifecycle(
      initiallyActive: true,
      pause: () async => events.add('pause'),
      play: () async {},
      disposePlayer: () async => events.add('dispose'),
    );
    final seeking = lifecycle.runCommand(() async {
      started.complete();
      await allowed.future;
      throw StateError('synthetic seek failure');
    });
    final rejected = expectLater(seeking, throwsStateError);
    await started.future;
    final volume = lifecycle.runCommand(() async => events.add('volume'));
    final leaving = lifecycle.updateActive(false, autoPlay: false);
    final disposing = lifecycle.dispose();
    allowed.complete();
    await Future.wait([rejected, volume, leaving, disposing]);

    expect(events, ['pause', 'dispose']);
  });

  test('inactive adjacent player stays paused and is reusable after a quick swipe back', () async {
    final events = <String>[];
    final lifecycle = VideoViewerLifecycle(
      initiallyActive: false,
      pause: () async => events.add('pause'),
      play: () async => events.add('play'),
      disposePlayer: () async => events.add('dispose'),
    );

    await lifecycle.updateActive(false, autoPlay: true);
    await lifecycle.updateActive(true, autoPlay: true);
    await lifecycle.updateActive(false, autoPlay: true);
    await lifecycle.updateActive(true, autoPlay: false);

    expect(events, ['play', 'pause']);
    expect(lifecycle.disposed, isFalse);

    await lifecycle.dispose();
    expect(events, ['play', 'pause', 'pause', 'dispose']);
    await lifecycle.dispose();
    expect(events, ['play', 'pause', 'pause', 'dispose']);
  });

  test(
    'offscreen player never starts when automatic playback is disabled',
    () async {
      final events = <String>[];
      final lifecycle = VideoViewerLifecycle(
        initiallyActive: false,
        pause: () async => events.add('pause'),
        play: () async => events.add('play'),
        disposePlayer: () async => events.add('dispose'),
      );

      await lifecycle.updateActive(true, autoPlay: false);
      await lifecycle.updateActive(false, autoPlay: false);

      expect(events, ['pause']);
      await lifecycle.dispose();
      expect(events, ['pause', 'pause', 'dispose']);
    },
  );

  test('late play completion leaves a departed video paused', () async {
    final playStarted = Completer<void>();
    final playAllowed = Completer<void>();
    var playing = false;
    final lifecycle = VideoViewerLifecycle(
      initiallyActive: false,
      pause: () async => playing = false,
      play: () async {
        playStarted.complete();
        await playAllowed.future;
        playing = true;
      },
      disposePlayer: () async {},
    );

    final activating = lifecycle.updateActive(true, autoPlay: true);
    await playStarted.future;
    final departing = lifecycle.updateActive(false, autoPlay: true);
    playAllowed.complete();
    await Future.wait([activating, departing]);

    expect(playing, isFalse);
    await lifecycle.dispose();
  });

  test(
    'disposal settles an in-flight play before destroying its player',
    () async {
      final playStarted = Completer<void>();
      final playAllowed = Completer<void>();
      var playing = false;
      var destroyed = false;
      var commandAfterDestruction = false;
      final lifecycle = VideoViewerLifecycle(
        initiallyActive: false,
        pause: () async {
          commandAfterDestruction |= destroyed;
          playing = false;
        },
        play: () async {
          playStarted.complete();
          await playAllowed.future;
          commandAfterDestruction |= destroyed;
          playing = true;
        },
        disposePlayer: () async => destroyed = true,
      );

      final activating = lifecycle.updateActive(true, autoPlay: true);
      await playStarted.future;
      final disposing = lifecycle.dispose();
      playAllowed.complete();
      await Future.wait([activating, disposing]);

      expect(destroyed, isTrue);
      expect(playing, isFalse);
      expect(commandAfterDestruction, isFalse);
      await lifecycle.dispose();
    },
  );
}
