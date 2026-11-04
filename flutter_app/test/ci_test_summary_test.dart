@Tags(['common'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late List<Map<String, Object?>> events;
  const nativeReason =
      'Requires Android SDK/JDK and NSO_VERIFY_ANDROID_BUILD=1';
  const sources = {
    'test/shared_test.dart': 'library;',
    'test/windows_test.dart': "@Tags(['platform-windows'])\nlibrary;",
    'test/macos_test.dart': "@Tags(['platform-macos'])\nlibrary;",
    'test/android/widget_test.dart': "@Tags(['platform-android'])\nlibrary;",
    'test/android/native_test.dart': "@Tags(['native-android'])\nlibrary;",
  };

  setUp(() async {
    root = await Directory.systemTemp.createTemp('nso-ci-categories-');
    for (final entry in sources.entries) {
      final file = File(p.join(root.path, entry.key));
      await file.parent.create(recursive: true);
      await file.writeAsString(entry.value);
    }
    events = [];
    var id = 0;
    for (final path in sources.keys) {
      events.add({
        'type': 'suite',
        'suite': {'id': ++id, 'path': path},
      });
      if (id == 5) {
        events.add({
          'type': 'group',
          'group': {
            'id': 10,
            'metadata': {'skipReason': nativeReason},
          },
        });
      }
      events.add({
        'type': 'testStart',
        'test': {
          'id': id,
          'suiteID': id,
          'name': 'case $id',
          'groupIDs': id == 5 ? [10] : [],
        },
      });
      events.add({
        'type': 'testDone',
        'testID': id,
        'result': 'success',
        'hidden': false,
        'skipped': id == 5,
      });
    }
    events.add({'type': 'done', 'success': true});
  });
  tearDown(() => root.delete(recursive: true));

  Future<ProcessResult> summarize({bool missingLogs = false}) async {
    if (!missingLogs) {
      await File(p.join(root.path, 'flutter.jsonl'))
          .writeAsString('${events.map(jsonEncode).join('\n')}\n');
      await File(p.join(root.path, 'rust.log')).writeAsString(
        'test result: ok. 1 passed; 0 failed; 0 ignored; '
        '0 measured; 0 filtered out; finished in 0.01s\n',
      );
    }
    return Process.run(
      'pwsh',
      [
        '-NoProfile',
        '-File',
        p.absolute('tool/ci_native.ps1'),
        '-ProjectDirectory',
        root.path,
        '-FlutterMachineLog',
        p.join(root.path, 'flutter.jsonl'),
        '-RustLog',
        p.join(root.path, 'rust.log'),
        '-ReportsDirectory',
        p.join(root.path, 'reports'),
        '-SummaryPath',
        p.join(root.path, 'summary.md'),
      ],
      environment: {'GITHUB_STEP_SUMMARY': ''},
    );
  }

  Future<Map<String, dynamic>> report() async =>
      (jsonDecode(
            await File(p.join(root.path, 'reports', 'test-counts.json'))
                .readAsString(),
          ) as Map<String, dynamic>)['flutter']
          as Map<String, dynamic>;

  // Misclassifying either Android tag, omitting it from the output, or counting
  // the same test in Common and Android must fail these real script assertions.
  test(
    'Android functional and native suites are counted once in JSON and summary',
    () async {
      final result = await summarize();
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      final flutter = await report();
      final categories = flutter['Categories'] as Map;
      expect(
        categories.keys,
        unorderedEquals(['Common', 'Windows', 'macOS', 'Android']),
      );
      expect(flutter['Total'], 5);
      expect(flutter['Passed'], 4);
      expect(flutter['Skipped'], 1);
      expect(categories['Android'], {
        'Status': 'passed-with-skips',
        'Total': 2,
        'Passed': 1,
        'Failed': 0,
        'Skipped': 1,
      });
      for (final name in ['Common', 'Windows', 'macOS']) {
        expect((categories[name] as Map)['Passed'], 1);
        expect((categories[name] as Map)['Total'], 1);
      }
      expect(flutter['SkippedTests'], [
        {'Name': 'case 5', 'Category': 'Android', 'Reason': nativeReason},
      ]);
      final summary = await File(p.join(root.path, 'summary.md'))
          .readAsString();
      expect(
        summary,
        contains('| Flutter Android | passed-with-skips | 2 | 1 | 0 | 1 |'),
      );
    },
  );

  for (final form in ['absolute', 'forward-slash', 'relative-native']) {
    test('Android nested suite classification accepts $form paths', () async {
      for (final event in events.where((event) => event['type'] == 'suite')) {
        final suite = event['suite'] as Map;
        final path = suite['path'] as String;
        suite['path'] = switch (form) {
          'absolute' => p.join(root.path, path),
          'forward-slash' => p.join(root.path, path).replaceAll(r'\', '/'),
          _ => p.joinAll(p.posix.split(path)),
        };
      }
      expect((await summarize()).exitCode, 0);
      final flutter = await report();
      expect(
        (flutter['Categories'] as Map)['Android']['Total'],
        2,
        reason:
            'root=${root.path}; suites=${events.where((e) => e['type'] == 'suite').toList()}; categories=${flutter['Categories']}',
      );
    });
  }

  test('dual Android tags do not duplicate native test counts', () async {
    await File(
      p.join(root.path, 'test/android/native_test.dart'),
    ).writeAsString("@Tags(['platform-android', 'native-android'])\nlibrary;");
    expect((await summarize()).exitCode, 0);
    final flutter = await report();
    expect((flutter['Categories'] as Map)['Android']['Total'], 2);
    expect(flutter['Total'], 5);
  });

  test('a wholly skipped Android category is not reported as passed', () async {
    (events.firstWhere(
      (event) => event['type'] == 'testDone' && event['testID'] == 4,
    ))['skipped'] = true;
    expect((await summarize()).exitCode, 0);
    final flutter = await report();
    expect((flutter['Categories'] as Map)['Android']['Status'], 'skipped');
    expect((flutter['Categories'] as Map)['Android']['Passed'], 0);
    expect((flutter['Categories'] as Map)['Android']['Skipped'], 2);
  });

  test(
    'Android prefix classifies only that test in a mixed portable suite',
    () async {
      final testEvent =
          events.firstWhere(
                (event) =>
                    event['type'] == 'testStart' &&
                    (event['test'] as Map)['id'] == 1,
              )['test']
              as Map;
      testEvent['name'] = '[Android] mixed test';
      events.insertAll(events.length - 1, [
        {
          'type': 'testStart',
          'test': {'id': 6, 'suiteID': 1, 'name': 'shared behavior'},
        },
        {
          'type': 'testDone',
          'testID': 6,
          'result': 'success',
          'hidden': false,
          'skipped': false,
        },
      ]);
      expect((await summarize()).exitCode, 0);
      final flutter = await report();
      expect((flutter['Categories'] as Map)['Android']['Total'], 3);
      expect((flutter['Categories'] as Map)['Common']['Total'], 1);
      expect(flutter['Total'], 6);
    },
  );

  test(
    'Android failure rejects the run while preserving category diagnostics',
    () async {
      final event = events.firstWhere(
        (event) => event['type'] == 'testDone' && event['testID'] == 4,
      );
      event['result'] = 'failure';
      events.last['success'] = false;
      expect((await summarize()).exitCode, isNot(0));
      final flutter = await report();
      expect(flutter['Success'], isFalse);
      expect((flutter['Categories'] as Map)['Android']['Status'], 'failed');
      expect((flutter['Categories'] as Map)['Android']['Failed'], 1);
      expect(flutter['FailedTests'], [
        {'Name': 'case 4', 'Category': 'Android'},
      ]);
    },
  );

  test(
    'truncated logs retain observed Android counts but cannot pass',
    () async {
      events.removeLast();
      expect((await summarize()).exitCode, isNot(0));
      final flutter = await report();
      expect(flutter['Status'], 'incomplete');
      expect((flutter['Categories'] as Map)['Android']['Status'], 'incomplete');
      expect((flutter['Categories'] as Map)['Android']['Passed'], 1);
      expect(flutter['Success'], isFalse);
    },
  );

  test('missing logs report Android not-run with unavailable counts', () async {
    expect((await summarize(missingLogs: true)).exitCode, isNot(0));
    final flutter = await report();
    expect((flutter['Categories'] as Map)['Android'], {
      'Status': 'not-run',
      'Total': null,
      'Passed': null,
      'Failed': null,
      'Skipped': null,
    });
  });

  test('complete log with no Android tests reports Android not-run with zero counts', () async {
    events.removeWhere(
      (event) => switch (event['type']) {
        'suite' =>
          (event['suite'] as Map)['id'] == 4 ||
              (event['suite'] as Map)['id'] == 5,
        'testStart' =>
          (event['test'] as Map)['id'] == 4 ||
              (event['test'] as Map)['id'] == 5,
        'testDone' => event['testID'] == 4 || event['testID'] == 5,
        _ => false,
      },
    );
    expect((await summarize()).exitCode, 0);
    final flutter = await report();
    expect((flutter['Categories'] as Map)['Android'], {
      'Status': 'not-run',
      'Total': 0,
      'Passed': 0,
      'Failed': 0,
      'Skipped': 0,
    });
  });
}
