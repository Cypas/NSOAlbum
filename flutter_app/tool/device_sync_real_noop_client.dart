// Host-side Debug control. Never forward raw machine output to diagnostics.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'device_sync_real_noop_report.dart';

enum NoopTransport { wifi, usb }

final class NoopBenchmarkFailure implements Exception {
  const NoopBenchmarkFailure(this.code);
  final String code;
  @override
  String toString() => 'NoopBenchmarkFailure([REDACTED])';
}

abstract interface class NoopBenchmarkPeer {
  Future<Map<String, Object?>> call(
    String op, {
    Map<String, String> params = const {},
  });
}

final class NoopBenchmarkRound {
  NoopBenchmarkRound._({
    required this.transport,
    required this.phoneToDesktop,
    required this.round,
    required this.timings,
    required this.failure,
    this.desktop,
    this.mobile,
  });
  final NoopTransport transport;
  final bool phoneToDesktop;
  final int round;
  final Map<String, int> timings;
  final String? failure;
  final NoopBenchmarkMetrics? desktop, mobile;
  bool get valid => failure == null && desktop != null && mobile != null;
  Map<String, Object?> toJson() => {
    'transport': transport.name,
    'direction': phoneToDesktop ? 'phone_to_desktop' : 'desktop_to_phone',
    'round': round,
    'valid': valid,
    if (failure != null) 'failure': failure,
    'observed_ms': Map<String, int>.of(timings),
    if (valid) 'desktop': desktop!.toJson(),
    if (valid) 'mobile': mobile!.toJson(),
  };
}

const _safeFailures = {
  'not_strict_noop',
  'ambiguous_usb',
  'confirmation_mismatch',
  'missing_noop_proof',
  'cleanup_unsettled',
  'peer_operation_failed',
  'phase_timeout',
  'terminal_failure',
  'missing_metrics',
  'invalid_metrics',
  'invalid_preview',
  'peer_not_ready',
  'daemon_rpc_failed',
  'daemon_closed',
  'daemon_timeout',
  'not_ready',
  'invalid_request',
  'preview_changed',
  'authorization_required',
  'operation_failed',
  'usb_unavailable',
  'metrics_unavailable',
  'busy',
};
String _fixedFailure(Object? value) =>
    value is String && _safeFailures.contains(value)
    ? value
    : 'peer_operation_failed';
String _name(Object? value) =>
    value is String ? value.replaceAll('_', '').toLowerCase() : '';

final class NoopBenchmarkRunner {
  NoopBenchmarkRunner({
    required this.desktop,
    required this.mobile,
    this.phaseTimeout = const Duration(minutes: 3),
    this.pollInterval = const Duration(milliseconds: 200),
    this.onProgress,
  });
  final NoopBenchmarkPeer desktop, mobile;
  final Duration phaseTimeout, pollInterval;
  final void Function(String)? onProgress;

  Future<void> waitUntilReady() async {
    final deadline = Stopwatch()..start();
    while (true) {
      try {
        final states = await Future.wait([
          desktop.call('status').timeout(phaseTimeout),
          mobile.call('status').timeout(phaseTimeout),
        ]);
        if (states.any((state) => state['active'] == true)) {
          throw const NoopBenchmarkFailure('peer_not_ready');
        }
        if (states.every((state) => state['ready'] == true)) return;
      } on NoopBenchmarkFailure catch (failure) {
        if (failure.code != 'daemon_rpc_failed' &&
            failure.code != 'not_ready') {
          rethrow;
        }
        // app.started precedes registration/startup recovery on some targets.
      }
      if (deadline.elapsed >= phaseTimeout) {
        throw const NoopBenchmarkFailure('phase_timeout');
      }
      await Future<void>.delayed(pollInterval);
    }
  }

  Future<NoopBenchmarkRound> runRound({
    required NoopTransport transport,
    required bool phoneToDesktop,
    required int round,
  }) async {
    if (round < 1) throw ArgumentError('Round must be positive');
    final total = Stopwatch()..start();
    final timings = <String, int>{};
    String? failure;
    var ownsDesktop = false, ownsMobile = false;
    NoopBenchmarkMetrics? desktopMetrics, mobileMetrics;
    var phase = Stopwatch()..start();
    Future<Map<String, Object?>> invoke(
      NoopBenchmarkPeer peer,
      String op, {
      Map<String, String> params = const {},
    }) async {
      final result = await peer.call(op, params: params).timeout(phaseTimeout);
      if (result['error'] != null) {
        throw NoopBenchmarkFailure(_fixedFailure(result['error']));
      }
      return result;
    }

    Future<List<Map<String, Object?>>> statuses() =>
        Future.wait([invoke(desktop, 'status'), invoke(mobile, 'status')]);
    Future<List<Map<String, Object?>>> until(
      bool Function(List<Map<String, Object?>>) satisfied,
    ) async {
      final deadline = Stopwatch()..start();
      while (true) {
        final sample = await statuses();
        for (final value in sample) {
          if (value['terminal'] == true &&
              _name(value['stage']) != 'completed') {
            throw const NoopBenchmarkFailure('terminal_failure');
          }
        }
        if (satisfied(sample)) return sample;
        if (deadline.elapsed >= phaseTimeout) {
          throw const NoopBenchmarkFailure('phase_timeout');
        }
        await Future<void>.delayed(pollInterval);
      }
    }

    try {
      onProgress?.call('connecting');
      final readiness = await statuses();
      if (readiness.any((s) => s['ready'] != true || s['active'] == true)) {
        throw const NoopBenchmarkFailure('peer_not_ready');
      }
      ownsDesktop = true;
      final hosted = await invoke(
        desktop,
        'host',
        params: {'transport': transport.name},
      );
      final invitation = hosted['invitation'];
      if (invitation is! String || invitation.isEmpty) {
        throw const NoopBenchmarkFailure('peer_operation_failed');
      }
      ownsMobile = true;
      await invoke(
        mobile,
        'join',
        params: {'transport': transport.name, 'invitation': invitation},
      );
      var authorizationObservedMs = 0;
      var authorizationKnown = true;
      var lastObservation = phase.elapsedMilliseconds;
      void observeAuthorization(List<Map<String, Object?>> sample) {
        final now = phase.elapsedMilliseconds;
        if (sample.last['blocked_authorization'] is! bool) {
          authorizationKnown = false;
        } else if (sample.last['blocked_authorization'] == true) {
          authorizationObservedMs += now - lastObservation;
        }
        lastObservation = now;
      }

      if (transport == NoopTransport.usb) {
        final discoveryDeadline = Stopwatch()..start();
        while (true) {
          observeAuthorization(await statuses());
          Map<String, Object?>? prepared;
          try {
            prepared = await invoke(desktop, 'prepare_usb');
          } on NoopBenchmarkFailure catch (error) {
            if (error.code != 'not_ready' && error.code != 'busy') rethrow;
          }
          if (prepared != null) {
            final choices = prepared['usb_choices'];
            if (choices is! int || choices < 0) {
              throw const NoopBenchmarkFailure('invalid_request');
            }
            if (choices > 1) {
              throw const NoopBenchmarkFailure('ambiguous_usb');
            }
            if (choices == 1) {
              final selection = await invoke(desktop, 'select_usb');
              if (selection['selected'] != true) {
                throw const NoopBenchmarkFailure('usb_unavailable');
              }
              break;
            }
          }
          if (discoveryDeadline.elapsed >= phaseTimeout) {
            throw const NoopBenchmarkFailure('phase_timeout');
          }
          await Future<void>.delayed(pollInterval);
        }
      }
      final pair = await until((sample) {
        observeAuthorization(sample);
        return sample.every((s) => s['confirmation_code'] is String);
      });
      timings['connect_ms'] = phase.elapsedMilliseconds;
      if (authorizationKnown) {
        timings['authorization_wait_observed_ms'] = authorizationObservedMs;
      } else {
        timings['authorization_wait_unknown'] = 1;
      }
      final code = pair.first['confirmation_code'];
      if (code is! String ||
          code.isEmpty ||
          code != pair.last['confirmation_code']) {
        throw const NoopBenchmarkFailure('confirmation_mismatch');
      }
      phase = Stopwatch()..start();
      onProgress?.call('confirming');
      await invoke(mobile, 'confirm', params: {'expected_code': code});
      await until((s) => s.every((v) => _name(v['pairing']) == 'confirmed'));
      timings['confirmation_ms'] = phase.elapsedMilliseconds;
      phase = Stopwatch()..start();
      onProgress?.call('previewing');
      await invoke(
        mobile,
        'configure',
        params: {'phone_to_desktop': '$phoneToDesktop'},
      );
      await until((s) => s.last['preview_available'] == true);
      final preview = await invoke(mobile, 'preview');
      final binding = preview['binding'];
      if (binding is! String || binding.isEmpty) {
        throw const NoopBenchmarkFailure('invalid_preview');
      }
      timings['preview_wait_ms'] = phase.elapsedMilliseconds;
      phase = Stopwatch()..start();
      // Counts and zero byte estimates are never execution authority.
      final guards = await Future.wait([
        invoke(desktop, 'arm', params: {'binding': binding}),
        invoke(mobile, 'arm', params: {'binding': binding}),
      ]);
      if (guards.any((s) => s['armed'] != true)) {
        throw const NoopBenchmarkFailure('not_strict_noop');
      }
      timings['guard_ms'] = phase.elapsedMilliseconds;
      phase = Stopwatch()..start();
      onProgress?.call('applying');
      await invoke(mobile, 'approve');
      await until(
        (s) => s.every(
          (v) =>
              _name(v['stage']) == 'completed' &&
              v['terminal'] == true &&
              v['cleanup_pending'] == false,
        ),
      );
      timings['approval_to_completed_ms'] = phase.elapsedMilliseconds;
      // Completed is a domain state, not proof that the transport ACK/Close
      // and worker drain have frozen both native measurement records.
      phase = Stopwatch()..start();
      final reports = <Map<String, Object?>?>[null, null];
      try {
        final peers = [desktop, mobile];
        while (reports.any((report) => report == null)) {
          final unresolved = [
            for (var i = 0; i < peers.length; i++)
              if (reports[i] == null) i,
          ];
          final remaining = phaseTimeout - phase.elapsed;
          if (remaining <= Duration.zero) {
            throw const NoopBenchmarkFailure('phase_timeout');
          }
          final responses = await Future.wait([
            for (final index in unresolved)
              () async {
                Map<String, Object?> response;
                try {
                  response = await peers[index]
                      .call('report')
                      .timeout(remaining);
                } on NoopBenchmarkFailure catch (error) {
                  response = {'error': _fixedFailure(error.code)};
                }
                final error = response['error'];
                if (error == 'metrics_unavailable' || error == 'busy') {
                  return null;
                }
                if (error != null) {
                  throw NoopBenchmarkFailure(_fixedFailure(error));
                }
                if (response['metrics'] is! String) {
                  throw const NoopBenchmarkFailure('missing_metrics');
                }
                return response;
              }(),
          ], eagerError: true);
          for (var i = 0; i < unresolved.length; i++) {
            final response = responses[i];
            if (response == null) continue;
            // Successful records are final and immutable; do not re-read them
            // while waiting for the other endpoint's transport to settle.
            reports[unresolved[i]] = response;
          }
          if (reports.every((report) => report != null)) break;
          if (phase.elapsed >= phaseTimeout) {
            throw const NoopBenchmarkFailure('phase_timeout');
          }
          await Future<void>.delayed(pollInterval);
        }
      } finally {
        timings['receipt_cleanup_wait_ms'] = phase.elapsedMilliseconds;
      }
      try {
        desktopMetrics = NoopBenchmarkMetrics.parse(
          reports.first!['metrics']! as String,
        );
        mobileMetrics = NoopBenchmarkMetrics.parse(
          reports.last!['metrics']! as String,
        );
      } on FormatException {
        throw const NoopBenchmarkFailure('invalid_metrics');
      }
      if (!desktopMetrics.isGuardedNoop(receiver: phoneToDesktop) ||
          !mobileMetrics.isGuardedNoop(receiver: !phoneToDesktop)) {
        throw const NoopBenchmarkFailure('missing_noop_proof');
      }
    } on TimeoutException {
      failure = 'phase_timeout';
    } on NoopBenchmarkFailure catch (error) {
      failure = _fixedFailure(error.code);
    } catch (_) {
      failure = 'peer_operation_failed';
    } finally {
      phase = Stopwatch()..start();
      onProgress?.call('closing');
      final cleanups = await Future.wait([
        for (final peer in [if (ownsDesktop) desktop, if (ownsMobile) mobile])
          () async {
            try {
              return (await invoke(peer, 'close'))['settled'] == true;
            } catch (_) {
              return false;
            }
          }(),
      ]);
      timings['close_ms'] = phase.elapsedMilliseconds;
      timings['end_to_end_ms'] = total.elapsedMilliseconds;
      if (cleanups.any((settled) => !settled)) failure ??= 'cleanup_unsettled';
    }
    return NoopBenchmarkRound._(
      transport: transport,
      phoneToDesktop: phoneToDesktop,
      round: round,
      timings: Map.unmodifiable(timings),
      failure: failure,
      desktop: desktopMetrics,
      mobile: mobileMetrics,
    );
  }

  Future<List<NoopBenchmarkRound>> runMatrix({
    List<NoopTransport> transports = NoopTransport.values,
    List<bool> directions = const [false, true],
    int rounds = 3,
  }) async {
    if (rounds < 1 || rounds > 3) {
      throw ArgumentError('One to three rounds required');
    }
    final results = <NoopBenchmarkRound>[];
    for (final transport in transports) {
      for (final direction in directions) {
        for (var round = 1; round <= rounds; round++) {
          final result = await runRound(
            transport: transport,
            phoneToDesktop: direction,
            round: round,
          );
          results.add(result);
          if (!result.valid) return results;
        }
      }
    }
    return results;
  }
}

/// Flutter's daemon resolves the UI isolate. Its authenticated VM address, app
/// ID and all request payloads remain in this live controller's memory only.
final class FlutterMachinePeer implements NoopBenchmarkPeer {
  FlutterMachinePeer.forProtocol({
    required void Function(String) send,
    this.onProgress,
    this.mobile = false,
  })
    // ignore: prefer_initializing_formals
    : _send = send;
  final void Function(String) _send;
  final void Function(String)? onProgress;
  final bool mobile;
  final _reportedProgress = <String>{};
  final _started = Completer<void>();
  final _pending = <int, Completer<Map<String, Object?>>>{};
  int _nextId = 0;
  String? _appId, _authenticatedWsUri;
  bool get hasDebugChannel => !_closed && _authenticatedWsUri != null;
  bool _closed = false;
  Process? _process;
  final List<StreamSubscription<String>> _subscriptions = [];

  static Future<FlutterMachinePeer> launch({
    required String device,
    required String workingDirectory,
    String flutter = 'flutter',
    void Function(String)? onProgress,
  }) async {
    if (!RegExp(r'^[A-Za-z0-9_.:\-]+$').hasMatch(device)) {
      throw const NoopBenchmarkFailure('invalid_request');
    }
    final process = await Process.start(
      flutter,
      [
        'run',
        '--debug',
        '-d',
        device,
        '-t',
        'tool/device_sync_real_noop.dart',
        '--dart-define=DEVICE_SYNC_REAL_NOOP=true',
        '--machine',
        '--no-pub',
      ],
      workingDirectory: workingDirectory,
      runInShell: Platform.isWindows,
    );
    final peer = FlutterMachinePeer.forProtocol(
      send: process.stdin.writeln,
      onProgress: onProgress,
      mobile: device != 'windows',
    );
    peer._process = process;
    peer._subscriptions.add(
      process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(peer.acceptLine),
    );
    peer._subscriptions.add(
      process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((_) {}),
    );
    unawaited(process.exitCode.then((_) => peer.protocolClosed()));
    try {
      await peer.waitUntilStarted();
    } catch (_) {
      await peer.shutdown();
      rethrow;
    }
    return peer;
  }

  void acceptLine(String line) {
    Object? decoded;
    try {
      decoded = jsonDecode(line);
    } catch (_) {
      return;
    }
    if (decoded is! List) return;
    for (final message in decoded) {
      if (message is! Map) continue;
      final id = message['id'];
      if (id is int && _pending.containsKey(id)) {
        final pending = _pending.remove(id)!;
        if (message['error'] != null) {
          // Never propagate arbitrary daemon exception strings.
          final error = message['error'];
          String code = 'daemon_rpc_failed';
          if (error is String && _safeFailures.contains(error)) code = error;
          if (error is Map && _safeFailures.contains(error['message'])) {
            code = error['message'] as String;
          }
          pending.completeError(NoopBenchmarkFailure(code));
        } else if (message['result'] case final Map result) {
          pending.complete(Map<String, Object?>.from(result));
        } else {
          pending.completeError(
            const NoopBenchmarkFailure('daemon_rpc_failed'),
          );
        }
      }
      final params = message['params'];
      if (params is! Map) continue;
      final app = params['appId'];
      if (app is! String || app.isEmpty) continue;
      if (message['event'] == 'app.progress' && params['finished'] != true) {
        final text = params['message'];
        String? code;
        if (text is String) {
          if (!mobile && text.startsWith('Building Windows application')) {
            code = 'building_windows';
          } else if (mobile && text.startsWith('Running Gradle task ')) {
            code = 'building_android';
          } else if (text.startsWith('Installing ')) {
            code = 'installing';
          } else if (text.startsWith('Syncing files to device ') ||
              text.startsWith('Launching ')) {
            code = 'launching';
          }
        }
        if (code != null && _reportedProgress.add(code)) onProgress?.call(code);
      }
      if (message['event'] == 'app.debugPort') {
        _appId = app;
        if (params['wsUri'] case final String address) {
          _authenticatedWsUri = address;
        }
      } else if (message['event'] == 'app.started') {
        _appId = app;
        if (!_started.isCompleted) _started.complete();
      } else if (message['event'] == 'app.stop' && app == _appId) {
        protocolClosed();
      }
    }
  }

  Future<void> waitUntilStarted() => _started.future.timeout(
    const Duration(minutes: 15),
    onTimeout: () => throw const NoopBenchmarkFailure('daemon_timeout'),
  );

  @override
  Future<Map<String, Object?>> call(
    String op, {
    Map<String, String> params = const {},
  }) async {
    if (_closed || _appId == null) {
      throw const NoopBenchmarkFailure('daemon_closed');
    }
    final id = ++_nextId;
    final pending = Completer<Map<String, Object?>>();
    _pending[id] = pending;
    _send(
      jsonEncode([
        {
          'id': id,
          'method': 'app.callServiceExtension',
          'params': {
            'appId': _appId,
            'methodName': 'ext.squid_album.realNoopBenchmark',
            'params': {'op': op, ...params},
          },
        },
      ]),
    );
    try {
      return await pending.future.timeout(
        const Duration(minutes: 3),
        onTimeout: () => throw const NoopBenchmarkFailure('daemon_timeout'),
      );
    } finally {
      _pending.remove(id);
    }
  }

  void protocolClosed() {
    if (_closed) return;
    _closed = true;
    _authenticatedWsUri = null;
    if (!_started.isCompleted) {
      _started.completeError(const NoopBenchmarkFailure('daemon_closed'));
    }
    for (final pending in _pending.values) {
      pending.completeError(const NoopBenchmarkFailure('daemon_closed'));
    }
    _pending.clear();
  }

  Future<void> shutdown() async {
    if (!_closed) {
      try {
        await call('shutdown');
      } catch (_) {}
    }
    // Do not force-kill an owner that may still be draining recovery work.
    await _process?.stdin.close();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    protocolClosed();
  }

  @override
  String toString() => 'FlutterMachinePeer([REDACTED])';
}

Map<String, Object?> summarizeNoopRounds(List<NoopBenchmarkRound> rounds) {
  final groups = <String, Map<String, Object?>>{};
  for (final transport in NoopTransport.values) {
    for (final direction in [false, true]) {
      final complete = rounds
          .where(
            (r) =>
                r.valid &&
                r.transport == transport &&
                r.phoneToDesktop == direction,
          )
          .toList();
      if (complete.isEmpty) continue;
      Map<String, num> medians(
        Map<String, int> Function(NoopBenchmarkRound) select,
      ) {
        final keys = complete
            .map(select)
            .map((v) => v.keys.toSet())
            .reduce((a, b) => a.intersection(b));
        return {
          for (final key in keys)
            key: benchmarkMedian(complete.map((v) => select(v)[key]!).toList()),
        };
      }

      groups['${transport.name}_${direction ? 'phone_to_desktop' : 'desktop_to_phone'}'] =
          {
            'completed_rounds': complete.length,
            'observed_ms_median': medians((r) => r.timings),
            'desktop_median': medians((r) => r.desktop!.values),
            'mobile_median': medians((r) => r.mobile!.values),
          };
    }
  }
  return {'rounds': rounds.map((r) => r.toJson()).toList(), 'medians': groups};
}

Future<void> main(List<String> arguments) async {
  String? device, output;
  for (var i = 0; i < arguments.length; i++) {
    if (arguments[i] == '--device' && i + 1 < arguments.length) {
      device = arguments[++i];
    } else if (arguments[i] == '--output' && i + 1 < arguments.length) {
      output = arguments[++i];
    } else {
      stderr.writeln(
        'Usage: dart tool/device_sync_real_noop_client.dart --device <adb target> [--output <numeric report.json>]',
      );
      exitCode = 64;
      return;
    }
  }
  if (device == null || device == 'windows') {
    stderr.writeln('An explicit Android target is required');
    exitCode = 64;
    return;
  }
  // The maintainer sets this to the verified, non-destructively updated build
  // copy. A source checkout must never silently become a native output root.
  final buildSource = Platform.environment['NSOALBUM_REAL_NOOP_SOURCE'];
  if (buildSource == null ||
      !await Directory(buildSource).exists() ||
      !await FileSystemEntity.identical(buildSource, Directory.current.path)) {
    stderr.writeln(
      'Run from the verified build copy and set NSOALBUM_REAL_NOOP_SOURCE to that Flutter project directory',
    );
    exitCode = 64;
    return;
  }
  if (output != null && await File(output).exists()) {
    stderr.writeln(
      'The numeric report destination already exists; choose a new file',
    );
    exitCode = 64;
    return;
  }
  FlutterMachinePeer? desktop, mobile;
  try {
    // Sequential starts avoid racing native builds against the fixed caches.
    stdout.writeln('Starting Windows Debug benchmark');
    desktop = await FlutterMachinePeer.launch(
      device: 'windows',
      workingDirectory: Directory.current.path,
      onProgress: stdout.writeln,
    );
    stdout.writeln('Starting Android Debug benchmark');
    mobile = await FlutterMachinePeer.launch(
      device: device,
      workingDirectory: Directory.current.path,
      onProgress: stdout.writeln,
    );
    final runner = NoopBenchmarkRunner(
      desktop: desktop,
      mobile: mobile,
      onProgress: stdout.writeln,
    );
    await runner.waitUntilReady();
    final rounds = await runner.runMatrix();
    final report = summarizeNoopRounds(rounds);
    if (output != null) {
      await File(output).writeAsString(
        '${const JsonEncoder.withIndent('  ').convert(report)}\n',
      );
    }
    stdout.writeln(jsonEncode(report));
    if (rounds.length != 12 || rounds.any((r) => !r.valid)) exitCode = 1;
  } catch (_) {
    stderr.writeln(
      'Benchmark stopped safely; no complete valid matrix is available',
    );
    exitCode = 1;
  } finally {
    await Future.wait([
      if (desktop != null) desktop.shutdown(),
      if (mobile != null) mobile.shutdown(),
    ]);
  }
}
