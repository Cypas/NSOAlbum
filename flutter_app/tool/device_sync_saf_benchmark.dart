// Synthetic native transport diagnostics only; no Rust core, accounts or media.
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:squid_album/src/platform/device_sync_saf.dart';

class SafBenchmarkResult {
  SafBenchmarkResult(this.verifiedBytes, this.elapsed);
  final int verifiedBytes;
  final Duration elapsed;
}

class SafTransferBenchmark {
  SafTransferBenchmark(this.saf, {this.onProgress});
  final DeviceSyncSaf saf;
  final void Function(int completed, int total)? onProgress;
  bool _running = false;
  int _epoch = 0;
  final session = List.generate(
    16,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  Future<SafBenchmarkResult> send({required int blockCount}) =>
      _run(blockCount, sending: true);

  Future<SafBenchmarkResult> receive({required int blockCount}) =>
      _run(blockCount, sending: false);

  Future<void> cancel() async {
    _epoch++;
    await saf.cancel();
  }

  Future<SafBenchmarkResult> _run(int count, {required bool sending}) async {
    if (count < 1 || count > 1024) throw ArgumentError('Invalid probe volume');
    if (_running) throw StateError('Probe already running');
    _running = true;
    final epoch = _epoch;
    final payload = Uint8List.fromList(
      List.generate(65536, (i) => (i * 37) & 255),
    );
    final watch = Stopwatch()..start();
    var lastProgress = Duration.zero;
    var completed = 0;
    var written = 0;
    final outstanding = <String>[];
    String name(int index) =>
        '${index.toRadixString(16).padLeft(16, '0')}.block';
    void check() {
      if (epoch != _epoch) throw StateError('Probe cancelled');
      if (watch.elapsed - lastProgress > const Duration(seconds: 60)) {
        throw StateError('Probe peer made no progress');
      }
    }

    try {
      await saf.openSession(session, session);
      while (completed < count) {
        check();
        final before = completed;
        if (sending) {
          while (written < count && outstanding.length < 4) {
            check();
            final next = name(written);
            await saf.writeCiphertextBlock(next, payload);
            outstanding.add(next);
            written++;
          }
          final remaining = await saf.listBlocks('mobile');
          check();
          final retired = outstanding.length - remaining.length;
          if (retired < 0 ||
              !listEquals(remaining, outstanding.skip(retired).toList())) {
            throw StateError('Probe mailbox changed');
          }
          outstanding.removeRange(0, retired);
          completed += retired;
        } else {
          final names = await saf.listBlocks('desktop');
          check();
          if (names.contains(name(completed))) {
            final current = name(completed);
            final bytes = await saf.readBlock('desktop', current);
            check();
            if (!listEquals(bytes, payload)) {
              throw StateError('Synthetic byte mismatch');
            }
            await saf.acknowledgeBlock('desktop', current);
            completed++;
          }
        }
        if (completed > before) {
          lastProgress = watch.elapsed;
          onProgress?.call(completed, count);
        } else {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }
      check();
      await saf.close();
      return SafBenchmarkResult(completed * payload.length, watch.elapsed);
    } catch (_) {
      await saf.cancel();
      rethrow;
    } finally {
      _running = false;
    }
  }
}
