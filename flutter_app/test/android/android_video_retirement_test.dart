@Tags(['platform-android'])
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
// The adapter coordinates this version-pinned native boundary without loading it.
// ignore: implementation_imports
import 'package:media_kit_video/src/video_controller/android_video_controller/android_video_controller.dart';
// Match the actual controller's lock rather than a test-only scheduling model.
// ignore: depend_on_referenced_packages
import 'package:synchronized/synchronized.dart';
import 'package:squid_album/src/ui/android/android_video_retirement.dart';

void main() {
  test(
    'retirement drains an admitted surface seek before destroying its player',
    () async {
      final player = _Player();
      final output = _Output(player);
      final started = Completer<void>();
      final finish = Completer<void>();
      output.pending = () async {
        started.complete();
        await finish.future;
        await player.seek(Duration.zero);
      };
      output.wid.value = 1;
      await started.future;
      var retired = false;
      final retirement = retireAndroidVideoOutput(
        output,
        player.dispose,
      ).then((_) => retired = true);
      await Future<void>.delayed(Duration.zero);
      expect(retired, isFalse);
      expect(player.disposed, isFalse);

      finish.complete();
      await retirement;
      expect(player.operations, ['seek', 'dispose']);
      expect(output.parameters.hasListener, isFalse);
      await output.close();
    },
  );

  test('retired surface and parameter updates cannot issue commands after disposal', () async {
    final player = _Player();
    final output = _Output(player);
    await retireAndroidVideoOutput(output, player.dispose);
    output.wid.value = 3;
    output.parameters.add(const VideoParams(w: 1280, h: 720));
    await Future<void>.delayed(Duration.zero);
    await output.lock.synchronized(() async {});

    expect(player.operations, ['dispose']);
    expect(output.parameters.hasListener, isFalse);
    await output.close();
  });

  test('retirement also destroys outputs without an Android surface', () async {
    final player = _Player();
    await retireAndroidVideoOutput(null, player.dispose);
    expect(player.operations, ['dispose']);
  });
}

class _Player implements Player {
  final operations = <String>[];
  bool disposed = false;

  @override
  Future<void> seek(Duration position) async {
    if (disposed) throw StateError('command reached disposed player');
    operations.add('seek');
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    operations.add('dispose');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected player boundary');
}

class _Output implements AndroidVideoController {
  _Output(this.player) {
    wid.addListener(widListener);
    videoParamsSubscription = parameters.stream.listen((_) {
      unawaited(widListener());
    });
  }
  @override
  final _Player player;
  @override
  final wid = ValueNotifier<int?>(null);
  @override
  final lock = Lock();
  final parameters = StreamController<VideoParams>.broadcast();
  Future<void> Function()? pending;
  @override
  StreamSubscription<VideoParams>? videoParamsSubscription;

  @override
  Future<void> widListener() =>
      lock.synchronized(() => pending?.call() ?? player.seek(Duration.zero));

  Future<void> close() async {
    wid.removeListener(widListener);
    await videoParamsSubscription?.cancel();
    await parameters.close();
    wid.dispose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected Android video output boundary');
}
