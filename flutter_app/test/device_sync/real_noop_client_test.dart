import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/device_sync_real_noop_client.dart';

const _metrics =
    'device_sync_metrics valid=true session_ms=2100 operation_ms=900 '
    'media_bytes=0 snapshot_ms=500 preview_ms=200 transfer_ms=100 '
    'verify_ms=150 apply_ms=350 receipt_ms=300 benchmark_noop_armed=1 '
    'strict_noop_applied=1 apply_snapshot_us=25000 apply_snapshot_count=1';

void main() {
  test(
    'valid round requires both native guards, completion and settled close',
    () async {
      final desktop = _Peer(mobile: false);
      final mobile = _Peer(mobile: true);
      final result = await _runner(desktop, mobile).runRound(
        transport: NoopTransport.wifi,
        phoneToDesktop: false,
        round: 1,
      );
      expect(result.valid, isTrue);
      expect(desktop.operations, contains('arm'));
      expect(mobile.operations.where((op) => op == 'approve'), hasLength(1));
      expect(desktop.operations.last, 'close');
      expect(mobile.operations.last, 'close');
      expect(mobile.configuration, {'phone_to_desktop': 'false'});
      final json = result.toJson();
      expect(json['desktop'], containsPair('apply_ms', 350));
      expect(json['mobile'], containsPair('apply_snapshot_us', 25000));
      expect(jsonEncode(json), isNot(contains('private')));
      expect(jsonEncode(json), isNot(contains('invitation')));
      expect(jsonEncode(json), isNot(contains('confirmation_code')));
      final timing = json['observed_ms']! as Map;
      expect(timing.containsKey('authorization_wait_observed_ms'), isFalse);
      expect(timing['authorization_wait_unknown'], 1);
    },
  );

  test(
    'one failed no-op guard never approves and still closes both peers',
    () async {
      final desktop = _Peer(mobile: false)..armed = false;
      final mobile = _Peer(mobile: true);
      final result = await _runner(
        desktop,
        mobile,
      ).runRound(transport: NoopTransport.usb, phoneToDesktop: true, round: 1);
      expect(result.valid, isFalse);
      expect(result.failure, 'not_strict_noop');
      expect(mobile.operations, isNot(contains('approve')));
      expect(desktop.operations.last, 'close');
      expect(mobile.operations.last, 'close');
    },
  );

  test('ambiguous USB candidates fail without guessing a storage', () async {
    final desktop = _Peer(mobile: false)..usbChoices = 2;
    final mobile = _Peer(mobile: true);
    final result = await _runner(
      desktop,
      mobile,
    ).runRound(transport: NoopTransport.usb, phoneToDesktop: false, round: 1);
    expect(result.valid, isFalse);
    expect(result.failure, 'ambiguous_usb');
    expect(mobile.operations, isNot(contains('configure')));
  });

  test(
    'USB discovery is explicit and status cannot recreate selection identity',
    () async {
      final desktop = _Peer(mobile: false)
        ..usbPreparePending = 2
        ..statusUsbChoices = 2;
      final mobile = _Peer(mobile: true);
      final result = await _runner(
        desktop,
        mobile,
      ).runRound(transport: NoopTransport.usb, phoneToDesktop: false, round: 1);
      expect(result.valid, isTrue);
      expect(
        desktop.operations.where((op) => op == 'prepare_usb'),
        hasLength(3),
      );
      expect(
        desktop.operations.where((op) => op == 'select_usb'),
        hasLength(1),
      );
      expect(
        desktop.operations.indexOf('prepare_usb'),
        lessThan(desktop.operations.indexOf('select_usb')),
      );
      expect(mobile.operations.where((op) => op == 'approve'), hasLength(1));
    },
  );

  test(
    'completed state waits for both immutable final native metrics',
    () async {
      final desktop = _Peer(mobile: false)
        ..reportErrors.add('metrics_unavailable');
      final mobile = _Peer(mobile: true)
        ..reportErrors.addAll(['busy', 'metrics_unavailable']);
      final result =
          await _runner(
            desktop,
            mobile,
            pollInterval: const Duration(milliseconds: 1),
          ).runRound(
            transport: NoopTransport.wifi,
            phoneToDesktop: false,
            round: 1,
          );
      expect(result.valid, isTrue);
      expect(desktop.operations.where((op) => op == 'report'), hasLength(2));
      expect(mobile.operations.where((op) => op == 'report'), hasLength(3));
      expect(mobile.operations.where((op) => op == 'approve'), hasLength(1));
      final timings = result.toJson()['observed_ms']! as Map;
      expect(timings['receipt_cleanup_wait_ms'], greaterThanOrEqualTo(2));
      expect(result.toJson()['mobile'], containsPair('apply_ms', 350));
    },
  );

  test(
    'unknown final metrics error fails once without retry or sensitive output',
    () async {
      final desktop = _Peer(mobile: false)
        ..reportErrors.add('private-account-failure');
      final mobile = _Peer(mobile: true);
      final result = await _runner(desktop, mobile).runRound(
        transport: NoopTransport.wifi,
        phoneToDesktop: false,
        round: 1,
      );
      expect(result.valid, isFalse);
      expect(desktop.operations.where((op) => op == 'report'), hasLength(1));
      expect(jsonEncode(result.toJson()), isNot(contains('private')));
      expect(result.toJson().containsKey('desktop'), isFalse);
    },
  );

  test(
    'permanently unavailable final metrics expire without fabricating zeros',
    () async {
      final desktop = _Peer(mobile: false)..reportUnavailableForever = true;
      final mobile = _Peer(mobile: true);
      final result =
          await _runner(
            desktop,
            mobile,
            phaseTimeout: const Duration(milliseconds: 20),
            pollInterval: const Duration(milliseconds: 1),
          ).runRound(
            transport: NoopTransport.wifi,
            phoneToDesktop: false,
            round: 1,
          );
      expect(result.valid, isFalse);
      expect(result.failure, 'phase_timeout');
      expect(
        desktop.operations.where((op) => op == 'report').length,
        greaterThan(1),
      );
      expect(result.toJson().containsKey('desktop'), isFalse);
      expect(result.toJson().containsKey('mobile'), isFalse);
      expect(desktop.operations.last, 'close');
      expect(mobile.operations.last, 'close');
    },
  );

  test(
    'unknown final error is not hidden by another pending receipt',
    () async {
      final pendingReceipt = Completer<Map<String, Object?>>();
      final desktop = _Peer(mobile: false)
        ..reportErrors.add('private-native-error');
      final mobile = _Peer(mobile: true)..reportReply = pendingReceipt;
      late NoopBenchmarkRound result;
      try {
        result =
            await _runner(
              desktop,
              mobile,
              phaseTimeout: const Duration(milliseconds: 30),
            ).runRound(
              transport: NoopTransport.wifi,
              phoneToDesktop: false,
              round: 1,
            );
      } finally {
        pendingReceipt.complete({'metrics': _metrics});
      }
      expect(result.valid, isFalse);
      expect(result.failure, 'peer_operation_failed');
      expect(desktop.operations.where((op) => op == 'report'), hasLength(1));
      expect(mobile.operations.where((op) => op == 'report'), hasLength(1));
    },
  );

  test(
    'mismatched confirmation codes stop before confirmation or configure',
    () async {
      final desktop = _Peer(mobile: false)..code = 'not-the-peer-code';
      final mobile = _Peer(mobile: true);
      final result = await _runner(desktop, mobile).runRound(
        transport: NoopTransport.wifi,
        phoneToDesktop: false,
        round: 1,
      );
      expect(result.valid, isFalse);
      expect(result.failure, 'confirmation_mismatch');
      expect(mobile.operations, isNot(contains('confirm')));
      expect(mobile.operations, isNot(contains('configure')));
    },
  );

  test('zero-byte report without receiver apply proof is invalid', () async {
    final desktop = _Peer(mobile: false);
    final mobile = _Peer(mobile: true)
      ..metrics = _metrics.replaceFirst(
        'strict_noop_applied=1',
        'strict_noop_applied=0',
      );
    final result = await _runner(
      desktop,
      mobile,
    ).runRound(transport: NoopTransport.wifi, phoneToDesktop: false, round: 1);
    expect(result.valid, isFalse);
    expect(result.failure, 'missing_noop_proof');
  });

  test('a failed cleanup cannot enter successful samples', () async {
    final desktop = _Peer(mobile: false)..settled = false;
    final mobile = _Peer(mobile: true);
    final result = await _runner(
      desktop,
      mobile,
    ).runRound(transport: NoopTransport.wifi, phoneToDesktop: false, round: 1);
    expect(result.valid, isFalse);
    expect(result.failure, 'cleanup_unsettled');
    expect(result.toJson()['desktop'], isNull);
  });

  test(
    'preexisting sessions are rejected without closing another owner',
    () async {
      final desktop = _Peer(mobile: false)..active = true;
      final mobile = _Peer(mobile: true);
      final result = await _runner(desktop, mobile).runRound(
        transport: NoopTransport.wifi,
        phoneToDesktop: false,
        round: 1,
      );
      expect(result.failure, 'peer_not_ready');
      expect(desktop.operations, isNot(contains('close')));
      expect(mobile.operations, isNot(contains('close')));
    },
  );

  test(
    'ready wait allows recovery to finish before beginning a round',
    () async {
      final desktop = _Peer(mobile: false)..notReadySamples = 2;
      final mobile = _Peer(mobile: true);
      await _runner(desktop, mobile).waitUntilReady();
      expect(desktop.operations.where((op) => op == 'status'), hasLength(3));
      expect(desktop.operations, isNot(contains('host')));
    },
  );

  test(
    'complete matrix reports independent native medians for all groups',
    () async {
      final desktop = _Peer(mobile: false);
      final mobile = _Peer(mobile: true);
      final rounds = await _runner(desktop, mobile).runMatrix();
      expect(rounds, hasLength(12));
      expect(rounds.every((round) => round.valid), isTrue);
      final summary = summarizeNoopRounds(rounds);
      final medians = summary['medians']! as Map;
      expect(medians, hasLength(4));
      final wifi = medians['wifi_desktop_to_phone']! as Map;
      expect(wifi['completed_rounds'], 3);
      expect(wifi['desktop_median'], containsPair('session_ms', 2100));
      expect(wifi['desktop_median'], containsPair('apply_ms', 350));
    },
  );

  test(
    'known authorization observations are distinct from missing telemetry',
    () async {
      final desktop = _Peer(mobile: false);
      final mobile = _Peer(mobile: true)..authorizationState = false;
      final result = await _runner(desktop, mobile).runRound(
        transport: NoopTransport.wifi,
        phoneToDesktop: false,
        round: 1,
      );
      final times = result.toJson()['observed_ms']! as Map;
      expect(times['authorization_wait_observed_ms'], 0);
      expect(times.containsKey('authorization_wait_unknown'), isFalse);
    },
  );

  test(
    'matrix stops on first difference rather than reconciling libraries',
    () async {
      final desktop = _Peer(mobile: false)..armed = false;
      final mobile = _Peer(mobile: true);
      final results = await _runner(desktop, mobile).runMatrix();
      expect(results, hasLength(1));
      expect(desktop.operations.where((op) => op == 'host'), hasLength(1));
      expect(mobile.operations, isNot(contains('approve')));
    },
  );

  test(
    'errors and unknown report fields cannot leak through failure output',
    () async {
      final desktop = _Peer(mobile: false)..throwOnArm = true;
      final mobile = _Peer(mobile: true);
      final result = await _runner(desktop, mobile).runRound(
        transport: NoopTransport.wifi,
        phoneToDesktop: false,
        round: 1,
      );
      expect(result.failure, 'peer_operation_failed');
      expect(jsonEncode(result.toJson()), isNot(contains('private')));
    },
  );

  test(
    'machine protocol keeps authenticated data private and uses request IDs',
    () async {
      final sent = <String>[];
      final peer = FlutterMachinePeer.forProtocol(send: sent.add);
      peer.acceptLine('arbitrary private log text');
      peer.acceptLine(
        jsonEncode([
          {
            'event': 'app.debugPort',
            'params': {
              'appId': 'private-app',
              'wsUri': 'ws://localhost/private-auth=/ws',
            },
          },
        ]),
      );
      peer.acceptLine(
        jsonEncode([
          {
            'event': 'app.started',
            'params': {'appId': 'private-app'},
          },
        ]),
      );
      await peer.waitUntilStarted();
      expect(peer.hasDebugChannel, isTrue);
      final pending = peer.call('status');
      final request = (jsonDecode(sent.single) as List).single as Map;
      expect(request['method'], 'app.callServiceExtension');
      expect(
        (request['params'] as Map)['methodName'],
        'ext.squid_album.realNoopBenchmark',
      );
      peer.acceptLine(
        jsonEncode([
          {
            'id': request['id'],
            'result': {'ready': true, 'private-extra': 'private-value'},
          },
        ]),
      );
      expect((await pending)['ready'], isTrue);
      expect(peer.toString(), isNot(contains('private')));
      peer.protocolClosed();
      expect(peer.hasDebugChannel, isFalse);
    },
  );

  test(
    'machine RPC failures never expose raw errors or leave pending calls',
    () async {
      final sent = <String>[];
      final peer = FlutterMachinePeer.forProtocol(send: sent.add);
      peer.acceptLine(
        '[{"event":"app.started","params":{"appId":"private-app"}}]',
      );
      final pending = peer.call('status');
      final request = (jsonDecode(sent.single) as List).single as Map;
      peer.acceptLine(
        jsonEncode([
          {
            'id': request['id'],
            'error': {'message': 'private-account private-invitation'},
          },
        ]),
      );
      await expectLater(
        pending,
        throwsA(
          isA<NoopBenchmarkFailure>().having(
            (failure) => failure.code,
            'fixed failure',
            'daemon_rpc_failed',
          ),
        ),
      );
      peer.protocolClosed();
    },
  );

  test(
    'machine progress exposes fixed phase codes without raw private messages',
    () async {
      final progress = <String>[];
      final peer = FlutterMachinePeer.forProtocol(
        send: (_) {},
        onProgress: progress.add,
        mobile: true,
      );
      for (final message in [
        "Running Gradle task 'assembleDebug'...",
        'Installing private-path/app-debug.apk...',
        'Installing private-path/app-debug.apk...',
        'Syncing files to device private-device...',
        'private-token private-auth unknown diagnostics',
      ]) {
        peer.acceptLine(
          jsonEncode([
            {
              'event': 'app.progress',
              'params': {
                'appId': 'private-app',
                'message': message,
                'finished': false,
              },
            },
          ]),
        );
      }
      expect(progress, ['building_android', 'installing', 'launching']);
      expect(jsonEncode(progress), isNot(contains('private')));
      peer.acceptLine(
        '[{"event":"app.started","params":{"appId":"private-app"}}]',
      );
      await peer.waitUntilStarted();
      peer.protocolClosed();
    },
  );
}

NoopBenchmarkRunner _runner(
  _Peer desktop,
  _Peer mobile, {
  Duration phaseTimeout = const Duration(seconds: 1),
  Duration pollInterval = Duration.zero,
}) {
  desktop.remote = mobile;
  mobile.remote = desktop;
  return NoopBenchmarkRunner(
    desktop: desktop,
    mobile: mobile,
    phaseTimeout: phaseTimeout,
    pollInterval: pollInterval,
  );
}

final class _Peer implements NoopBenchmarkPeer {
  _Peer({required this.mobile});
  final bool mobile;
  _Peer? remote;
  final operations = <String>[];
  Map<String, String>? configuration;
  bool active = false, confirmed = false, configured = false, applied = false;
  bool armed = true, settled = true, throwOnArm = false;
  int usbChoices = 1, statusUsbChoices = 0, usbPreparePending = 0;
  final reportErrors = <String>[];
  bool reportUnavailableForever = false;
  Completer<Map<String, Object?>>? reportReply;
  int notReadySamples = 0;
  bool? authorizationState;
  String code = 'private-pairing-code';
  String metrics = _metrics;

  @override
  Future<Map<String, Object?>> call(
    String op, {
    Map<String, String> params = const {},
  }) async {
    operations.add(op);
    switch (op) {
      case 'host':
        confirmed = configured = applied = false;
        active = true;
        return {'invitation': 'private-invitation'};
      case 'join':
        confirmed = configured = applied = false;
        active = true;
        return {};
      case 'status':
        return {
          'ready': notReadySamples-- <= 0,
          'active': active,
          'stage': applied || remote?.applied == true
              ? 'completed'
              : configured || remote?.configured == true
              ? 'awaitingApproval'
              : 'pairing',
          'pairing': confirmed || remote?.confirmed == true
              ? 'confirmed'
              : 'awaitingConfirmation',
          'controller': mobile,
          'source': !mobile,
          'terminal': applied || remote?.applied == true,
          'cleanup_pending': false,
          'confirmation_code': code,
          'preview_available': configured || remote?.configured == true,
          'usb_choices': statusUsbChoices,
          if (authorizationState != null)
            'blocked_authorization': authorizationState,
        };
      case 'confirm':
        confirmed = true;
        return {};
      case 'prepare_usb':
        return {'usb_choices': usbPreparePending-- > 0 ? 0 : usbChoices};
      case 'select_usb':
        return {'selected': true};
      case 'configure':
        configuration = Map.of(params);
        configured = true;
        return {};
      case 'preview':
        return {'binding': 'private-preview-binding'};
      case 'arm':
        if (throwOnArm) throw StateError('private-token private-path');
        return {'armed': armed};
      case 'approve':
        applied = true;
        return {};
      case 'report':
        if (reportReply != null) return reportReply!.future;
        if (reportUnavailableForever) return {'error': 'metrics_unavailable'};
        if (reportErrors.isNotEmpty) return {'error': reportErrors.removeAt(0)};
        applied = true;
        return {
          'metrics': metrics,
          'private-path': 'private-media-path',
          'private-account': 'private-account',
          'cleanup_ms': 13,
        };
      case 'close':
        active = false;
        return {'settled': settled};
    }
    throw StateError('Unexpected operation');
  }
}
