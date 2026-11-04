// Local host diagnostics only. VM URI/auth and raw RPC/Timeline responses stay
// in this process; only fixed summaries are written to the requested report.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

import 'gallery_perf_report.dart';
import 'gallery_framework_profile.dart';
import 'gallery_framework_report.dart';

const _extension = 'ext.squid_album.galleryPerf';
const _rpcTimeout = Duration(seconds: 20);
const _preRoll = Duration(milliseconds: 1200);
const _pauseKinds = {
  'PauseStart',
  'PauseExit',
  'PauseBreakpoint',
  'PauseInterrupted',
  'PauseException',
  'PausePostRequest',
  'Resume',
};

Future<T> _rpc<T>(Future<T> operation) => operation.timeout(_rpcTimeout);

/// One-shot, read-only VM configuration for the launcher's in-memory service.
/// No isolate identity, source data or flag/error text leaves this function.
Future<Map<String, Object?>> inspectGalleryConfiguration(
  VmService service,
) async {
  final flags = await _rpc(service.getFlagList());
  final vm = await _rpc(service.getVM());
  Isolate? root;
  for (final ref in vm.isolates ?? <IsolateRef>[]) {
    if (ref.id == null) continue;
    try {
      final isolate = await _rpc(service.getIsolate(ref.id!));
      if (isolate.extensionRPCs?.contains(_extension) == true) {
        root = isolate;
        break;
      }
    } on SentinelException {
      // A short-lived worker is not the application isolate.
    }
  }
  final profiler = flags.flags
      ?.where((flag) => flag.name == 'profiler')
      .firstOrNull;
  final period = flags.flags
      ?.where((flag) => flag.name == 'profile_period')
      .firstOrNull;
  final pause = root?.pauseEvent?.kind;
  return {
    'extensionPresent': root != null,
    'profilerFlagPresent': profiler != null,
    'profilerEnabled': profilerFlagEnabled(flags),
    'profilePeriodMicros': int.tryParse(period?.valueAsString ?? ''),
    'pauseState': _pauseKinds.contains(pause) ? pause : 'unknown',
  };
}

/// A comparison-mode pre-roll never drives input. Replay begins only after the
/// host resets samplers and starts the definitive recording on the real page.
Map<String, String> galleryStartArguments({
  required String scenario,
  required String coverMode,
  required bool definitive,
  bool replayWheel = false,
}) => {
  'scenario': scenario,
  'coverMode': coverMode,
  if (definitive && replayWheel) 'drive': 'wheel',
};

Future<Map<String, dynamic>> _extensionCall(
  VmService service,
  String isolate,
  String action,
  Map<String, String> arguments,
) async {
  final result = await _rpc(
    service.callServiceExtension(
      _extension,
      isolateId: isolate,
      args: {'action': action, ...arguments},
    ),
  );
  final json = result.json;
  if (json == null || json['ok'] != true) {
    const safeReasons = {
      'disabled',
      'unavailable',
      'invalid_action',
      'invalid_scenario',
      'invalid_cover_mode',
      'not_recording',
      'drive_unavailable',
      'invalid_drive',
    };
    final reason = json?['reason'];
    throw GalleryCaptureFailure(
      safeReasons.contains(reason) ? reason as String : 'extension_failed',
    );
  }
  return json;
}

Future<Map<String, Object?>> captureGallery({
  required String serviceUri,
  required Duration duration,
  required String scenario,
  required String coverMode,
  bool replayWheel = false,
  bool profileFramework = false,
  void Function(String)? status,
}) async {
  final uri = Uri.tryParse(serviceUri.trim());
  if (uri == null ||
      !{'ws', 'wss'}.contains(uri.scheme) ||
      !{'localhost', '127.0.0.1', '::1'}.contains(uri.host)) {
    throw const GalleryCaptureFailure('invalid_service_uri');
  }
  VmService? service;
  GalleryFrameworkProfile? frameworkProfile;
  StreamSubscription<Event>? gcSubscription;
  GalleryGcWindow? gcWindow;
  List<String>? previousTimelineStreams;
  var started = false;
  String? isolateId;
  String isolatePauseState = 'unknown';
  try {
    service = await vmServiceConnectUri(uri.toString()).timeout(_rpcTimeout);
    final connectedService = service;
    final vm = await _rpc(service.getVM());
    // Flutter's UI isolate advertises this extension. Name alone is ambiguous
    // when a background compute isolate is alive.
    for (final ref in vm.isolates ?? <IsolateRef>[]) {
      final id = ref.id;
      if (id == null) continue;
      try {
        final isolate = await _rpc(service.getIsolate(id));
        if (isolate.extensionRPCs?.contains(_extension) == true) {
          isolateId = id;
          if (profileFramework) {
            frameworkProfile = GalleryFrameworkProfile((
              method,
              arguments,
            ) async {
              final response = await _rpc(
                connectedService.callServiceExtension(
                  method,
                  isolateId: id,
                  args: arguments,
                ),
              );
              return response.json ?? {};
            });
            await frameworkProfile.enable(
              (isolate.extensionRPCs ?? []).toSet(),
            );
          }
          final pause = isolate.pauseEvent?.kind;
          if (_pauseKinds.contains(pause)) isolatePauseState = pause!;
          break;
        }
      } on SentinelException {
        // A compute isolate may end between getVM and getIsolate.
      }
    }
    if (isolateId == null) {
      throw const GalleryCaptureFailure('isolate_unavailable');
    }
    final flags = await _rpc(service.getFlagList());
    final profiler = flags.flags
        ?.where((flag) => flag.name == 'profiler')
        .firstOrNull;
    final profilerEnabled = profilerFlagEnabled(flags);
    final profilePeriod = flags.flags
        ?.where((flag) => flag.name == 'profile_period')
        .firstOrNull;
    final timelineFlags = await _rpc(service.getVMTimelineFlags());
    previousTimelineStreams = timelineFlags.recordedStreams;
    final streams = (timelineFlags.availableStreams ?? <String>[])
        .where({'Dart', 'GC', 'Embedder'}.contains)
        .toList();
    await _rpc(service.setVMTimelineFlags(streams));
    // Enter the comparison mode before the measured window. A second start
    // resets counters without changing mode again, excluding card invalidation
    // and cancellation caused by the diagnostic mode switch itself.
    await _extensionCall(
      service,
      isolateId,
      'start',
      galleryStartArguments(
        scenario: scenario,
        coverMode: coverMode,
        definitive: false,
        replayWheel: replayWheel,
      ),
    );
    started = true;
    await Future<void>.delayed(_preRoll);
    await _rpc(service.clearVMTimeline());
    await _rpc(service.clearCpuSamples(isolateId));
    String gcReason = 'ok';
    try {
      await _rpc(service.streamListen(EventStreams.kGC));
      gcWindow = GalleryGcWindow(isolateId);
      gcSubscription = service.onGCEvent.listen(gcWindow.receive);
    } catch (error) {
      gcReason = captureFailureReason(error);
    }
    final before = (await _rpc(service.getVMTimelineMicros())).timestamp;
    if (before == null || before < 0) {
      throw const GalleryCaptureFailure('invalid_time_boundary');
    }
    await _extensionCall(
      service,
      isolateId,
      'start',
      galleryStartArguments(
        scenario: scenario,
        coverMode: coverMode,
        definitive: true,
        replayWheel: replayWheel,
      ),
    );
    started = true;
    gcWindow?.start();
    status?.call('capture_started');
    await Future<void>.delayed(duration);
    // Bound host sampling before stop restores normal covers. The restoration
    // is teardown work and must not appear as a scrolling CPU hotspot.
    gcWindow?.stop();
    final after = (await _rpc(service.getVMTimelineMicros())).timestamp;
    final snapshot = await _extensionCall(service, isolateId, 'stop', {});
    started = false;
    await frameworkProfile?.restore();
    if (after == null || after <= before) {
      throw const GalleryCaptureFailure('invalid_time_boundary');
    }
    status?.call('capture_stopped');
    Map<String, Object?> cpu;
    CpuSamples? sampledCpu;
    try {
      final capturedCpu = await _rpc(
        service.getCpuSamples(isolateId, before, after - before),
      );
      sampledCpu = capturedCpu;
      cpu = summarizeCpuSamples(
        capturedCpu,
        profilerEnabled: profilerEnabled,
        requestedOriginMicros: before,
        requestedExtentMicros: after - before,
      );
    } catch (error) {
      cpu = captureFailureSummary(error);
    }
    Map<String, Object?> timeline;
    try {
      final events = await _rpc(
        service.getVMTimeline(
          timeOriginMicros: before,
          timeExtentMicros: after - before,
        ),
      );
      timeline = summarizeTimeline(
        (events.traceEvents ?? <TimelineEvent>[]).map(
          (event) => event.json ?? <String, dynamic>{},
        ),
      );
      timeline['coverage'] = summarizeTimelineCoverage(
        events,
        requestedOriginMicros: before,
        requestedExtentMicros: after - before,
      );
      timeline['recorder'] =
          const {
            'Ring',
            'Endless',
            'Startup',
            'Callback',
            'Systrace',
            'Macos',
            'Fuchsia',
            'null',
          }.contains(timelineFlags.recorderName)
          ? timelineFlags.recorderName
          : 'other';
      timeline['frameAttribution'] = summarizeFrameAttribution(
        (events.traceEvents ?? <TimelineEvent>[]).map(
          (event) => event.json ?? <String, dynamic>{},
        ),
        snapshot,
      );
      if (profileFramework) {
        timeline['frameworkComponents'] = summarizeFrameworkComponents(
          (events.traceEvents ?? <TimelineEvent>[]).map(
            (event) => event.json ?? <String, dynamic>{},
          ),
        );
      }
      if (sampledCpu != null) {
        timeline['slowFrameCpu'] = summarizeFrameCpu(
          sampledCpu,
          (timeline['frameAttribution'] as Map)['slowFrames'] as List,
        );
      }
    } catch (error) {
      timeline = captureFailureSummary(error);
    }
    return {
      'schema': 1,
      'reason': 'ok',
      'input': replayWheel ? 'flutter_pointer_scroll_replay' : 'manual',
      'requestedDurationMicros': duration.inMicroseconds,
      'preRollMicros': _preRoll.inMicroseconds,
      'observedDurationMicros': after - before,
      'profilerEnabled': profilerEnabled,
      'profilerFlagPresent': profiler != null,
      'isolatePauseState': isolatePauseState,
      'profilePeriodMicros': int.tryParse(profilePeriod?.valueAsString ?? ''),
      'frameworkProfiling': frameworkProfile?.summary ?? {'requested': false},
      'gallery': sanitizeGallerySnapshot(snapshot),
      'cpu': cpu,
      'timeline': timeline,
      'gcStream': {
        'reason': gcReason,
        'basis': 'received_during_window',
        'mainIsolateEvents': gcWindow?.events ?? 0,
      },
    };
  } finally {
    gcWindow?.stop();
    await frameworkProfile?.restore();
    if (service != null) {
      if (started && isolateId != null) {
        try {
          await _extensionCall(service, isolateId, 'stop', {});
        } catch (_) {
          // Do not obscure the original fixed failure code.
        }
      }
      if (previousTimelineStreams != null) {
        try {
          await _rpc(service.setVMTimelineFlags(previousTimelineStreams));
        } catch (_) {}
      }
      await gcSubscription?.cancel();
      await service.dispose();
    }
  }
}

Future<void> main(List<String> arguments) async {
  String? output;
  try {
    final options = <String, String>{};
    for (var i = 0; i < arguments.length; i += 2) {
      if (!arguments[i].startsWith('--') || i + 1 >= arguments.length) {
        throw const GalleryCaptureFailure('invalid_arguments');
      }
      options[arguments[i].substring(2)] = arguments[i + 1];
    }
    if (options.keys.any(
      (key) => !const {
        'platform',
        'mode',
        'scenario',
        'cover-mode',
        'repetition',
        'duration-ms',
        'output',
      }.contains(key),
    )) {
      throw const GalleryCaptureFailure('invalid_arguments');
    }
    output = options['output'];
    final duration = int.tryParse(options['duration-ms'] ?? '20000');
    final repetition = int.tryParse(options['repetition'] ?? '1');
    final scenario = options['scenario'] ?? 'normalDown';
    final coverMode = options['cover-mode'] ?? 'normal';
    if (!{'windows', 'android'}.contains(options['platform']) ||
        !{'debug', 'profile'}.contains(options['mode']) ||
        !galleryScenarios.contains(scenario) ||
        !galleryCoverModes.contains(coverMode) ||
        duration == null ||
        duration < 100 ||
        duration > 120000 ||
        repetition == null ||
        repetition < 1 ||
        repetition > 100 ||
        output == null ||
        !File(output).isAbsolute ||
        !await File(output).parent.exists()) {
      throw const GalleryCaptureFailure('invalid_arguments');
    }
    // Input is intentionally not accepted as a command-line argument or file:
    // authentication-bearing VM addresses must not enter process listings,
    // reports, shell history or logs.
    final serviceUri = await stdin
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(_rpcTimeout);
    final report = await captureGallery(
      serviceUri: serviceUri,
      duration: Duration(milliseconds: duration),
      scenario: scenario,
      coverMode: coverMode,
      status: stderr.writeln,
    );
    report.addAll({
      'platform': options['platform'],
      'mode': options['mode'],
      'repetition': repetition,
    });
    await File(output).writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
      flush: true,
    );
    stdout.writeln('capture_report_written');
  } catch (error) {
    final reason = captureFailureReason(error);
    stderr.writeln(reason);
    // No guessed output path is used after argument validation failures.
    exitCode = 1;
  }
}
