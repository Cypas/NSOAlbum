import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vm_service/vm_service.dart';

import '../tool/gallery_perf_capture.dart';
import '../tool/gallery_perf_report.dart';

void main() {
  test('slow-frame CPU attribution excludes samples between frames', () {
    final samples = CpuSamples(
      sampleCount: 3,
      functions: [
        ProfileFunction(
          kind: 'Dart',
          function: FuncRef(name: 'RenderSliverGrid.performLayout'),
        ),
        ProfileFunction(
          kind: 'Dart',
          function: FuncRef(name: 'DpapiJsonFileMapStorage.load'),
        ),
      ],
      samples: [
        CpuSample(timestamp: 105, stack: [0]),
        CpuSample(timestamp: 125, stack: [1]),
        CpuSample(timestamp: 205, stack: [1]),
      ],
    );
    final result = summarizeFrameCpu(samples, [
      {'startMicros': 100, 'endMicros': 120},
      {'startMicros': 200, 'endMicros': 220},
    ]);
    final first = result.first['cpu'] as Map;
    final second = result.last['cpu'] as Map;
    expect(first['withinWindowSamples'], 1);
    expect(second['withinWindowSamples'], 1);
    expect(
      (first['topInclusive'] as List).single['name'],
      'RenderSliverGrid.performLayout',
    );
    expect((second['topInclusive'] as List).single['inclusiveTicks'], 1);
  });

  test(
    'current Flutter root stages survive the fixed-label timeline boundary',
    () {
      final report = summarizeTimeline([
        {'name': 'BUILD', 'ph': 'X', 'ts': 100, 'dur': 20},
        {'name': 'LAYOUT (root)', 'ph': 'X', 'ts': 120, 'dur': 30},
        {'name': 'SEMANTICS (root)', 'ph': 'X', 'ts': 150, 'dur': 40},
        {'name': 'PAINT (root)', 'ph': 'X', 'ts': 190, 'dur': 10},
        {
          'name': 'UPDATING COMPOSITING BITS (root)',
          'ph': 'X',
          'ts': 200,
          'dur': 5,
        },
        {'name': 'FINALIZE TREE', 'ph': 'X', 'ts': 205, 'dur': 5},
        {'name': 'POST_FRAME', 'ph': 'X', 'ts': 210, 'dur': 5},
        {'name': 'LAYOUT private-account', 'ph': 'X', 'ts': 100, 'dur': 999},
      ]);
      final stages = report['stages'] as Map;
      expect((stages['BUILD'] as Map?)?['totalMicros'], 20);
      expect((stages['LAYOUT (root)'] as Map?)?['totalMicros'], 30);
      expect((stages['SEMANTICS (root)'] as Map?)?['totalMicros'], 40);
      expect((stages['PAINT (root)'] as Map?)?['totalMicros'], 10);
      expect(
        (stages['UPDATING COMPOSITING BITS (root)'] as Map?)?['totalMicros'],
        5,
      );
      expect((stages['FINALIZE TREE'] as Map?)?['totalMicros'], 5);
      expect((stages['POST_FRAME'] as Map?)?['totalMicros'], 5);
      expect(report.toString(), isNot(contains('private')));
    },
  );

  test('per-frame attribution clips and unions nested stages, not async wait as CPU', () {
    final report = summarizeFrameAttribution(
      [
        {'name': 'BUILD', 'ph': 'B', 'ts': 90, 'pid': 1, 'tid': 2},
        {'name': 'unknown-private', 'ph': 'B', 'ts': 110, 'pid': 1, 'tid': 2},
        {'ph': 'E', 'ts': 120, 'pid': 1, 'tid': 2},
        {'ph': 'E', 'ts': 140, 'pid': 1, 'tid': 2},
        {'name': 'LAYOUT (root)', 'ph': 'X', 'ts': 140, 'dur': 40},
        {'name': 'LAYOUT', 'ph': 'X', 'ts': 150, 'dur': 10},
        {'name': 'SEMANTICS (root)', 'ph': 'X', 'ts': 185, 'dur': 30},
      ],
      {
        'frameWindows': [
          {
            'startMicros': 100,
            'endMicros': 200,
            'uiMicros': 100,
            'rasterMicros': 2,
            'budgetMicros': 50,
          },
        ],
        'work': {
          'spans': [
            {
              'startMicros': 80,
              'endMicros': 220,
              'keyGroup': 'tokens',
              'callers': ['AutomaticSyncCoordinator._reschedule'],
              'complete': true,
            },
          ],
        },
      },
    );
    final frame = (report['slowFrames'] as List).single as Map;
    final phases = frame['phases'] as Map;
    expect(phases['build'], 40);
    expect(phases['layout'], 40);
    expect(phases['semantics'], 15);
    expect(frame['accountedMicros'], 95);
    expect(frame['unattributedMicros'], 5);
    expect(frame['secureReadOverlapMicros'], 100);
    expect(frame['secureReadCallers'], [
      'AutomaticSyncCoordinator._reschedule',
    ]);
    expect(frame.containsKey('secureReadCpuMicros'), false);
    expect(report.toString(), isNot(contains('private')));
  });

  test('host rejects malformed timing spans and unknown storage callers', () {
    final report = sanitizeGallerySnapshot({
      'frameWindows': [
        {'startMicros': 10, 'endMicros': 5, 'uiMicros': 9},
        {
          'startMicros': 10,
          'endMicros': 20,
          'uiMicros': 10,
          'rasterMicros': 3,
          'budgetMicros': 16,
          'path': 'private',
        },
      ],
      'work': {
        'started': 1,
        'completed': 1,
        'dropped': 0,
        'spans': [
          {
            'startMicros': 10,
            'endMicros': 20,
            'keyGroup': 'profiles',
            'callers': ['RustBackend._readCachedProfiles', 'private-token'],
            'complete': true,
            'failed': false,
            'value': 'private',
          },
        ],
      },
    });
    expect(report['frameWindows'], hasLength(1));
    expect((report['work'] as Map)['spans'], hasLength(1));
    expect(report.toString(), isNot(contains('private')));
  });

  test(
    'drag summaries retain only known phases, policies and numeric metrics',
    () {
      final report = sanitizeGallerySnapshot({
        'loadingPolicy': 'settled',
        'selectedLoadingPolicy': 'immediate',
        'loadingAdmission': 'paused',
        'dragFrames': {
          'moving': {
            'count': 2,
            'overBudget': 1,
            'ui': {'p95': 18000},
          },
          'private-name': {'count': 2},
        },
        'dragCounters': {
          'moving': {'dragDeferred': 4, 'private-path': 900},
          'private-name': {'queued': 1},
        },
        'timings': {
          'dragImageLatency': {'count': 2, 'p95': 230000},
        },
      });
      expect(report['loadingPolicy'], 'settled');
      expect(report['selectedLoadingPolicy'], 'immediate');
      expect(report['loadingAdmission'], 'paused');
      expect(((report['dragFrames'] as Map)['moving'] as Map)['count'], 2);
      expect(
        ((report['dragCounters'] as Map)['moving'] as Map)['dragDeferred'],
        4,
      );
      expect(report.toString(), isNot(contains('private')));
      expect((report['timings'] as Map)['dragImageLatency'], isNotNull);
    },
  );

  test('wheel replay starts only in the definitive capture window', () {
    expect(
      galleryStartArguments(
        scenario: 'normalDown',
        coverMode: 'placeholder',
        definitive: false,
        replayWheel: true,
      ),
      {'scenario': 'normalDown', 'coverMode': 'placeholder'},
    );
    expect(
      galleryStartArguments(
        scenario: 'normalDown',
        coverMode: 'placeholder',
        definitive: true,
        replayWheel: true,
      ),
      {'scenario': 'normalDown', 'coverMode': 'placeholder', 'drive': 'wheel'},
    );
    expect(
      galleryStartArguments(
        scenario: 'reverse',
        coverMode: 'normal',
        definitive: true,
      ),
      {'scenario': 'reverse', 'coverMode': 'normal'},
    );
  });

  test('CPU report ranks real ticks without exporting script paths', () {
    final report = summarizeCpuSamples(
      CpuSamples(
        sampleCount: 10,
        samplePeriod: 1000,
        timeOriginMicros: 100,
        timeExtentMicros: 10000,
        functions: [
          ProfileFunction(
            kind: 'Dart',
            exclusiveTicks: 6,
            inclusiveTicks: 8,
            resolvedUrl: r'file:///C:/private/album/image.dart',
            function: FuncRef(id: 'objects/1', name: '_MediaCard.build'),
          ),
          ProfileFunction(
            kind: 'Native',
            exclusiveTicks: 4,
            inclusiveTicks: 4,
            function: NativeFunction(name: r'C:\private\media\personal.jpg'),
          ),
        ],
      ),
      profilerEnabled: true,
    );
    expect(report['reason'], 'ok');
    expect(report['sampleCount'], 10);
    final top = (report['topSelf'] as List).first as Map;
    expect(top['name'], '_MediaCard.build');
    expect(top['selfPercent'], 60);
    expect(top['inclusivePercent'], 80);
    expect(report.toString(), isNot(contains('private')));
    expect(report.toString(), isNot(contains('objects/1')));
  });

  test(
    'CPU names qualify class and closure owners without library metadata',
    () {
      final report = summarizeCpuSamples(
        CpuSamples(
          sampleCount: 10,
          functions: [
            ProfileFunction(
              kind: 'Dart',
              exclusiveTicks: 7,
              inclusiveTicks: 9,
              resolvedUrl: 'file:///private/library.dart',
              function: FuncRef(
                name: '<anonymous closure>',
                owner: FuncRef(
                  name: 'load',
                  owner: ClassRef(name: 'DpapiJsonFileMapStorage'),
                ),
              ),
            ),
            ProfileFunction(
              kind: 'Dart',
              exclusiveTicks: 1,
              inclusiveTicks: 1,
              function: FuncRef(
                name: 'read',
                owner: LibraryRef(
                  name: 'private_library',
                  uri: 'file:///private/source.dart',
                ),
              ),
            ),
          ],
        ),
        profilerEnabled: true,
      );
      final rows = report['topDartSelf'] as List;
      expect(
        (rows.first as Map)['name'],
        'DpapiJsonFileMapStorage.load.<anonymous closure>',
      );
      expect(report.toString(), isNot(contains('private')));
      expect(report.toString(), isNot(contains('file:')));
    },
  );

  test('CPU ranks keep up to 100 Dart rows without unbounded output', () {
    final report = summarizeCpuSamples(
      CpuSamples(
        sampleCount: 1000,
        functions: [
          for (var i = 0; i < 120; i++)
            ProfileFunction(
              kind: 'Dart',
              exclusiveTicks: 120 - i,
              inclusiveTicks: 120 - i,
              function: FuncRef(
                name: 'method$i',
                owner: ClassRef(name: 'Card'),
              ),
            ),
        ],
      ),
      profilerEnabled: true,
    );
    expect((report['topDartSelf'] as List).length, 100);
    expect((report['topSelf'] as List).length, 100);
    expect(
      ((report['topDartSelf'] as List).last as Map)['name'],
      'Card.method99',
    );
  });

  test(
    'storage caller chains retain only sanitized symbols and real counts',
    () {
      final functions = [
        ProfileFunction(
          function: NativeFunction(name: 'NtDeviceIoControlFile'),
        ),
        ProfileFunction(function: FuncRef(name: 'CryptUnprotectData')),
        ProfileFunction(
          function: FuncRef(
            name: '<anonymous closure>',
            owner: FuncRef(
              name: 'load',
              owner: ClassRef(name: 'DpapiJsonFileMapStorage'),
            ),
          ),
        ),
        ProfileFunction(
          function: FuncRef(
            name: 'read',
            owner: ClassRef(name: 'FlutterSecureStorageWindows'),
          ),
        ),
        ProfileFunction(
          resolvedUrl: 'file:///private/account.dart',
          function: FuncRef(
            name: '_readStoredAccountTokens',
            owner: ClassRef(name: 'RustBackend'),
          ),
        ),
        ProfileFunction(
          function: NativeFunction(name: r'C:\private\credentials.dat'),
        ),
      ];
      final result = summarizeStorageCallerChains(
        CpuSamples(
          sampleCount: 4,
          functions: functions,
          samples: [
            CpuSample(stack: [0, 1, 2, 3, 4, 5]),
            CpuSample(stack: [0, 1, 2, 3, 4, 5], truncated: true),
            CpuSample(stack: [0, 1, 2, 3, 4]),
            CpuSample(stack: [0]),
          ],
        ),
      );
      expect(result['reason'], 'ok');
      final targets = result['targets'] as Map;
      final crypto = targets['CryptUnprotectData'] as Map;
      expect(crypto['matchedSamples'], 3);
      expect(crypto['percentOfAllSamples'], 75);
      final top = (crypto['topChains'] as List).first as Map;
      expect(top['samples'], 2);
      expect(top['truncatedSamples'], 1);
      expect(top['chain'], [
        'CryptUnprotectData',
        'DpapiJsonFileMapStorage.load.<anonymous closure>',
        'FlutterSecureStorageWindows.read',
        'RustBackend._readStoredAccountTokens',
        'redacted_function',
      ]);
      expect(
        (targets['DpapiJsonFileMapStorage.load'] as Map)['matchedSamples'],
        3,
      );
      expect(result.toString(), isNot(contains('private')));
      expect(result.toString(), isNot(contains('credentials.dat')));
      expect(result.toString(), isNot(contains('file:')));
    },
  );

  test('storage caller summary bounds chain count and aggregation memory', () {
    final result = summarizeStorageCallerChains(
      CpuSamples(
        sampleCount: 10,
        functions: [
          ProfileFunction(function: FuncRef(name: 'CryptUnprotectData')),
          for (var i = 0; i < 10; i++)
            ProfileFunction(function: FuncRef(name: 'caller$i')),
        ],
        samples: [
          for (var i = 1; i <= 10; i++) CpuSample(stack: [0, i]),
        ],
      ),
      maxPaths: 5,
      maxFrames: 2,
      maxUniquePaths: 8,
    );
    final target = (result['targets'] as Map)['CryptUnprotectData'] as Map;
    expect(target['matchedSamples'], 10);
    expect((target['topChains'] as List).length, 5);
    expect(target['overflowPathSamples'], 2);
    expect(
      (target['topChains'] as List).every(
        (row) => ((row as Map)['chain'] as List).length <= 2,
      ),
      isTrue,
    );
    expect(
      summarizeStorageCallerChains(CpuSamples(sampleCount: 10))['reason'],
      'stacks_unavailable',
    );
  });

  test('stack ranking and caller counts ignore stale table ticks and time', () {
    final samples = CpuSamples(
      sampleCount: 4,
      functions: [
        ProfileFunction(
          kind: 'Dart',
          exclusiveTicks: 100,
          inclusiveTicks: 200,
          function: FuncRef(name: 'CryptUnprotectData'),
        ),
        ProfileFunction(
          kind: 'Dart',
          exclusiveTicks: 1,
          inclusiveTicks: 1,
          function: FuncRef(
            name: 'build',
            owner: ClassRef(name: 'Card'),
          ),
        ),
      ],
      samples: [
        CpuSample(timestamp: 500, stack: [0]),
        CpuSample(timestamp: 1000, stack: [0, 1]),
        CpuSample(timestamp: 1100, stack: [1]),
        CpuSample(timestamp: 1200, stack: [1]),
      ],
    );
    final ranks = summarizeCpuSampleStacks(
      samples,
      requestedOriginMicros: 1000,
      requestedExtentMicros: 500,
    );
    expect(ranks['withinWindowSamples'], 3);
    expect(ranks['outsideWindowSamples'], 1);
    final top = (ranks['topSelf'] as List).first as Map;
    expect(top['name'], 'Card.build');
    expect(top['selfTicks'], 2);
    final callers = summarizeStorageCallerChains(
      samples,
      requestedOriginMicros: 1000,
      requestedExtentMicros: 500,
    );
    expect(callers['firstReturnedSampleMicros'], 500);
    expect(callers['lastReturnedSampleMicros'], 1200);
    final crypto = (callers['targets'] as Map)['CryptUnprotectData'] as Map;
    expect(crypto['matchedSamples'], 1);
    expect(
      ((crypto['functionTableTicks'] as List).first as Map)['inclusiveTicks'],
      200,
    );
  });

  test(
    'Timeline coverage exposes retained versus requested source interval',
    () {
      final coverage = summarizeTimelineCoverage(
        Timeline(timeOriginMicros: 1500, timeExtentMicros: 500),
        requestedOriginMicros: 1000,
        requestedExtentMicros: 1000,
      );
      expect(coverage['reason'], 'partial');
      expect(coverage['requestedOriginMicros'], 1000);
      expect(coverage['requestedExtentMicros'], 1000);
      expect(coverage['returnedOriginMicros'], 1500);
      expect(coverage['returnedExtentMicros'], 500);
      expect(coverage['overlapRatio'], .5);
      expect(
        summarizeTimelineCoverage(
          Timeline(timeOriginMicros: 500, timeExtentMicros: 2000),
          requestedOriginMicros: 1000,
          requestedExtentMicros: 1000,
        )['reason'],
        'complete',
      );
      expect(
        summarizeTimelineCoverage(
          Timeline(),
          requestedOriginMicros: 1000,
          requestedExtentMicros: 1000,
        )['reason'],
        'unavailable',
      );
    },
  );

  test('sampling failures distinguish disabled, empty, timeout and RPC', () {
    expect(
      summarizeCpuSamples(
        CpuSamples(sampleCount: 0),
        profilerEnabled: false,
      )['reason'],
      'profile_disabled',
    );
    expect(
      summarizeCpuSamples(
        CpuSamples(sampleCount: 0),
        profilerEnabled: true,
      )['reason'],
      'zero_samples',
    );
    expect(
      captureFailureReason(TimeoutException('private token')),
      'request_timeout',
    );
    expect(
      captureFailureReason(RPCError('secret', 123, 'private')),
      'rpc_error',
    );
    expect(
      captureFailureReason(StateError('private token')),
      'operation_failed',
    );
  });

  test('RPC diagnostic preserves numeric code without message or details', () {
    final summary = captureFailureSummary(
      RPCError('private_method', 100, 'private token', {'path': 'private'}),
    );
    expect(summary, {'reason': 'rpc_error', 'rpcCode': 100});
    expect(summary.toString(), isNot(contains('private')));
    expect(captureFailureSummary(TimeoutException('private')), {
      'reason': 'request_timeout',
    });
  });

  test('missing profiler flag remains unknown rather than enabled', () {
    expect(profilerFlagEnabled(FlagList(flags: [])), isNull);
    expect(
      profilerFlagEnabled(
        FlagList(
          flags: [Flag(name: 'profiler', valueAsString: 'true')],
        ),
      ),
      isTrue,
    );
    expect(
      profilerFlagEnabled(
        FlagList(
          flags: [Flag(name: 'profiler', valueAsString: 'false')],
        ),
      ),
      isFalse,
    );
    expect(
      summarizeCpuSamples(
        CpuSamples(sampleCount: 0),
        profilerEnabled: null,
      )['reason'],
      'zero_samples',
    );
  });

  test('GC callback counts only the definitive active capture window', () {
    final window = GalleryGcWindow('isolates/1');
    final mainGc = Event(
      kind: EventKind.kGC,
      isolate: IsolateRef(id: 'isolates/1'),
    );
    window.receive(mainGc); // Subscription/pre-roll.
    window.start();
    window.receive(mainGc);
    window.receive(
      Event(
        kind: EventKind.kGC,
        isolate: IsolateRef(id: 'isolates/2'),
      ),
    );
    expect(window.events, 1);
    window.stop();
    window.receive(mainGc); // Stop/drain/restore and later RPCs.
    expect(window.events, 1);
    window.start();
    expect(window.events, 0);
    window.receive(mainGc);
    expect(window.events, 1);
  });

  test(
    'timeline report pairs begin/end and counts GC without raw arguments',
    () {
      final report = summarizeTimeline([
        {'name': 'gallery.cardBuild', 'ph': 'B', 'ts': 100, 'pid': 1, 'tid': 2},
        {'name': 'unapproved', 'ph': 'B', 'ts': 150, 'pid': 1, 'tid': 2},
        {'ph': 'E', 'ts': 200, 'pid': 1, 'tid': 2},
        {'ph': 'E', 'ts': 350, 'pid': 1, 'tid': 2},
        {'name': 'gallery.cardBuild', 'ph': 'X', 'ts': 400, 'dur': 500},
        {'name': 'CollectNewGeneration', 'ph': 'X', 'ts': 500, 'dur': 1000},
        {
          'name': r'File.read C:\private\media.jpg',
          'ph': 'X',
          'ts': 600,
          'dur': 900,
          'args': {'token': 'private'},
        },
      ]);
      final stages = report['stages'] as Map;
      expect((stages['gallery.cardBuild'] as Map)['count'], 2);
      expect((stages['gallery.cardBuild'] as Map)['totalMicros'], 750);
      expect(report['gcSliceCount'], 1);
      expect(report['gcMicros'], 1000);
      expect(report.toString(), isNot(contains('private')));
    },
  );

  test('nested GC timeline slices do not double-count observed duration', () {
    final report = summarizeTimeline([
      {'name': 'Scavenge', 'ph': 'X', 'ts': 100, 'dur': 300},
      {'name': 'CollectNewGeneration', 'ph': 'X', 'ts': 120, 'dur': 180},
      {'name': 'CollectNewGeneration', 'ph': 'X', 'ts': 600, 'dur': 50},
    ]);
    expect(report['gcMicros'], 350);
    expect(report['gcSliceCount'], 3);
    expect(report['gcMicrosBasis'], 'union_of_named_slices');
  });

  test('Timeline pairs spans even when VM events arrive unordered', () {
    final report = summarizeTimeline([
      {'ph': 'E', 'ts': 400, 'pid': 1, 'tid': 1},
      {'name': 'gallery.cardLayout', 'ph': 'B', 'ts': 100, 'pid': 1, 'tid': 1},
    ]);
    expect(
      ((report['stages'] as Map)['gallery.cardLayout'] as Map)['totalMicros'],
      300,
    );
    expect(report['unmatchedBoundaries'], 0);
  });

  test('timeline pairs async spans independently from synchronous lanes', () {
    final report = summarizeTimeline([
      {'name': 'gallery.diskRead', 'ph': 'b', 'ts': 200, 'pid': 1, 'id': 'a'},
      {'name': 'gallery.diskRead', 'ph': 'b', 'ts': 250, 'pid': 1, 'id': 'b'},
      {'ph': 'e', 'ts': 400, 'pid': 1, 'id': 'a'},
      {'ph': 'e', 'ts': 650, 'pid': 1, 'id': 'b'},
    ]);
    final stages = report['stages'] as Map;
    expect((stages['gallery.diskRead'] as Map)['count'], 2);
    expect((stages['gallery.diskRead'] as Map)['totalMicros'], 600);
    expect(report['unmatchedBoundaries'], 0);
  });

  test('gallery response exports approved numeric fields only', () {
    final result = sanitizeGallerySnapshot({
      'ok': true,
      'scenario': 'normalDown',
      'coverMode': 'normal',
      'counters': {'cardMount': 14, 'cachedAfterCancel': 3, r'C:\private': 123},
      'timings': {
        'cardBuild': {'count': 14, 'p95': 900, 'path': 'secret'},
        'cacheStat': {'count': 2, 'p95': 400},
        'cacheRoot': {'count': 1, 'p95': 100},
        'cacheCleanup': {'count': 1, 'p95': 200},
      },
      'frames': {
        'count': 10,
        'ui': {'p95': 20000},
        'overBudgetRatio': .4,
      },
      'gallery': {'loaded': 60, 'total': 800, 'account': 'secret'},
      'imageCache': {
        'entries': 40,
        'bytes': 12345,
        'live': 8,
        'pending': 0,
        'maxBytes': 104857600,
        'maxEntries': 1000,
      },
      'background': {
        'syncBusy': 1,
        'importBusy': 0,
        'syncBusyObserved': 1,
        'importBusyObserved': -1,
        'cacheActive': 2,
        'cachePending': 4,
        'cacheActiveAtStart': 1,
        'cachePendingAtStart': 3,
        'cacheCarryoverFinished': 1,
        'account': 'secret',
      },
      'marks': [
        {'scenario': 'reverse', 'micros': 20000},
        {'scenario': 'private_token', 'micros': 1},
      ],
      'uri': 'ws://localhost/private=/ws',
    });
    expect((result['counters'] as Map)['cardMount'], 14);
    expect((result['counters'] as Map)['cachedAfterCancel'], 3);
    expect((result['gallery'] as Map)['total'], 800);
    expect((result['imageCache'] as Map)['entries'], 40);
    expect((result['imageCache'] as Map)['maxBytes'], 104857600);
    expect((result['imageCache'] as Map)['maxEntries'], 1000);
    expect(result['background'], {
      'syncBusy': 1,
      'importBusy': 0,
      'syncBusyObserved': 1,
      'importBusyObserved': -1,
      'cacheActive': 2,
      'cachePending': 4,
      'cacheActiveAtStart': 1,
      'cachePendingAtStart': 3,
      'cacheCarryoverFinished': 1,
    });
    expect(((result['timings'] as Map)['cacheStat'] as Map)['count'], 2);
    expect(((result['timings'] as Map)['cacheRoot'] as Map)['p95'], 100);
    expect(((result['timings'] as Map)['cacheCleanup'] as Map)['p95'], 200);
    expect((result['marks'] as List).length, 1);
    expect(result.toString(), isNot(contains('private')));
    expect(result.toString(), isNot(contains('secret')));
    expect(result.containsKey('uri'), isFalse);
  });
}
