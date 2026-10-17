@Tags(['common'])
@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _Child {
  _Child(this.process) {
    final output = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(lines.add)
        .asFuture<void>();
    final diagnostics = process.stderr
        .transform(utf8.decoder)
        .listen(errors.write)
        .asFuture<void>();
    ended = () async {
      final code = await process.exitCode;
      await Future.wait([output, diagnostics]);
      exitStatus = code;
      return code;
    }();
  }
  final Process process;
  final lines = <String>[];
  final errors = StringBuffer();
  late final Future<int> ended;
  int? exitStatus;

  Future<void> waitFor(String line) async {
    final until = DateTime.now().add(const Duration(seconds: 10));
    while (!lines.contains(line)) {
      if (exitStatus != null || DateTime.now().isAfter(until)) {
        fail('Child did not emit $line: $lines; $errors; exit=$exitStatus');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<void> stop() async {
    if (exitStatus != null) return;
    process.stdin.writeln('close');
    try {
      await ended.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      process.kill();
      await ended.timeout(const Duration(seconds: 5));
    }
  }
}

void main() {
  late String dart;
  late Directory root;
  final children = <_Child>[];
  setUpAll(() async {
    final config = File('.dart_tool/package_config.json').absolute;
    final packages =
        jsonDecode(await config.readAsString())['packages'] as List;
    final flutter = packages.cast<Map<String, dynamic>>().firstWhere(
      (entry) => entry['name'] == 'flutter',
    );
    final packageRoot = Directory.fromUri(
      config.uri.resolve(flutter['rootUri'] as String),
    );
    final sdkRoot = packageRoot.parent.parent.path;
    dart = p.join(
      sdkRoot,
      'bin',
      'cache',
      'dart-sdk',
      'bin',
      Platform.isWindows ? 'dart.exe' : 'dart',
    );
    expect(File(dart).existsSync(), isTrue);
  });
  setUp(() async {
    root = await Directory.systemTemp.createTemp('nsoalbum-instance-test-');
    stdout.writeln('Retained synthetic instance scope: ${root.path}');
  });
  tearDown(() async {
    for (final child in children.reversed) {
      await child.stop();
    }
    children.clear();
  });
  Future<_Child> start([String? mode]) async {
    final child = _Child(
      await Process.start(dart, [
        '--packages=${p.absolute('.dart_tool/package_config.json')}',
        p.absolute('test/fixtures/desktop_instance/instance_process.dart'),
        root.path,
        ?mode,
      ]),
    );
    children.add(child);
    return child;
  }

  test(
    'second process activates owner without initializing business again',
    () async {
      final first = await start();
      await first.waitFor('business-started');
      final second = await start();
      expect(await second.ended, 0, reason: second.errors.toString());
      expect(second.lines, ['secondary']);
      await first.waitFor('activated');
      expect(
        first.lines.where((line) => line == 'business-started'),
        hasLength(1),
      );
      expect(first.exitStatus, isNull);
    },
  );

  test('concurrent launches elect exactly one business owner', () async {
    final launched = await Future.wait(List.generate(6, (_) => start()));
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (launched.where((c) => c.lines.contains('primary')).isEmpty &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final owners = launched.where((c) => c.lines.contains('primary')).toList();
    expect(owners, hasLength(1));
    for (final child in launched.where((c) => !identical(c, owners.single))) {
      expect(
        await child.ended.timeout(const Duration(seconds: 10)),
        0,
        reason: child.errors.toString(),
      );
      expect(child.lines, ['secondary']);
    }
    expect(
      launched
          .expand((c) => c.lines)
          .where((line) => line == 'business-started'),
      hasLength(1),
    );
  });

  test(
    'owner process crash releases lock despite retained endpoint file',
    () async {
      final first = await start();
      await first.waitFor('business-started');
      expect(first.process.kill(), isTrue);
      await first.ended;
      expect(File(p.join(root.path, 'owner.json')).existsSync(), isTrue);
      final replacement = await start();
      await replacement.waitFor('business-started');
      expect(replacement.lines, contains('primary'));
    },
  );

  test('owner graceful exit permits another launch', () async {
    final first = await start();
    await first.waitFor('business-started');
    await first.stop();
    expect(await first.ended, 0);
    final replacement = await start();
    await replacement.waitFor('business-started');
  });

  test(
    'held lock without live endpoint fails closed, never starts business',
    () async {
      final holder = await start('hold');
      await holder.waitFor('holder');
      final second = await start();
      expect(await second.ended.timeout(const Duration(seconds: 8)), 73);
      expect(second.lines, isNot(contains('business-started')));
      expect(second.errors.toString(), contains('instance-unavailable'));
      expect(holder.exitStatus, isNull);
    },
  );

  test(
    'invalid and oversized activation requests cannot activate owner',
    () async {
      final first = await start();
      await first.waitFor('business-started');
      final descriptor = jsonDecode(
        await File(p.join(root.path, 'owner.json')).readAsString(),
      ) as Map<String, dynamic>;
      for (final input in ['ACTIVATE invalid\n', '${'x' * 1025}\n']) {
        final socket = await Socket.connect(
          InternetAddress.loopbackIPv4,
          descriptor['port'] as int,
        );
        socket.write(input);
        await socket.flush();
        final response = await utf8.decoder
            .bind(socket)
            .join()
            .timeout(const Duration(seconds: 5));
        expect(response, 'NO\n');
        socket.destroy();
      }
      expect(first.lines, isNot(contains('activated')));
      final valid = await start();
      expect(await valid.ended, 0);
      await first.waitFor('activated');
      expect(first.lines.where((line) => line == 'activated'), hasLength(1));
    },
  );
}
