import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/ui/account_tools/splatnet_close.dart';
import 'package:squid_album/src/ui/account_tools/splatnet_profile_cleanup.dart';
import 'package:squid_album/src/ui/account_tools/web_resource_lifecycle.dart';

void main() {
  test(
    'owned reclamation deletes only the retired child, never its sibling',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'splatnet-cleanup-test-',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final retired = await Directory('${root.path}/session-retired').create();
      final active = await Directory('${root.path}/session-active').create();
      await File('${retired.path}/synthetic-cache').writeAsString('retired');
      await File('${active.path}/synthetic-cache').writeAsString('active');
      await deleteOwnedSplatNetProfile(retired, root.absolute.path);
      await deleteOwnedSplatNetProfile(retired, root.absolute.path);
      expect(await retired.exists(), isFalse);
      expect(
        await File('${active.path}/synthetic-cache').readAsString(),
        'active',
      );
      await expectLater(
        deleteOwnedSplatNetProfile(root, root.absolute.path),
        throwsStateError,
      );
      expect(await active.exists(), isTrue);
    },
  );

  testWidgets('a locked retired profile does not poison close or reentry', (
    tester,
  ) async {
    final resources = WebResourceLifecycle();
    var attempts = 0;
    var released = false;
    var returned = false;
    Object? failure;
    final issues = <String>[];
    final closing = resources.close(() async {
      released = true;
      await retireSplatNetProfile(
        deleteProfile: () async {
          attempts++;
          if (attempts == 1) {
            throw const FileSystemException(
              'synthetic locked profile',
              'synthetic-session',
              OSError('access denied', 5),
            );
          }
        },
        onIssue: issues.add,
      );
    });
    final returning = closeSplatNetAndReturn(
      closeResources: () => closing,
      onCleanupError: (error) => failure = error,
      returnToCaller: () async => returned = true,
    );
    await tester.pump();
    expect(released, isTrue);
    expect(
      returned,
      isTrue,
      reason: 'File reclamation is not native isolation.',
    );
    expect(failure, isNull);
    await closing;
    await resources.close(() async => fail('duplicate native release'));
    await returning;
    expect(issues, ['splatnet_profile_cleanup_deferred']);
    await tester.pump(const Duration(seconds: 1));
    expect(attempts, 2);
  });

  testWidgets('persistent profile locks have bounded path-free diagnostics', (
    tester,
  ) async {
    var attempts = 0;
    final issues = <String>[];
    var finished = false;
    final cleanup = retireSplatNetProfile(
      deleteProfile: () async {
        attempts++;
        throw const FileSystemException(
          'synthetic locked profile',
          'private-profile-name',
          OSError('access denied', 5),
        );
      },
      onIssue: issues.add,
    ).then((_) => finished = true);
    await tester.pump();
    expect(finished, isTrue);
    await cleanup;
    for (var round = 0; round < 8; round++) {
      await tester.pump(const Duration(seconds: 31));
    }
    final finalAttempts = attempts;
    await tester.pump(const Duration(minutes: 5));
    expect(attempts, finalAttempts, reason: 'Do not retry without a bound.');
    expect(finalAttempts, greaterThan(4));
    expect(finalAttempts, lessThanOrEqualTo(10));
    expect(issues, [
      'splatnet_profile_cleanup_deferred',
      'splatnet_profile_cleanup_incomplete',
    ]);
    expect(issues.join(), isNot(contains('private-profile-name')));
  });

  test('non-filesystem failures remain fatal to the isolation gate', () async {
    final resources = WebResourceLifecycle();
    final closing = resources.close(() async {
      await retireSplatNetProfile(
        deleteProfile: () async => throw StateError('unsafe profile owner'),
        onIssue: (_) => fail('unsafe ownership must not be ignored'),
      );
    });
    await expectLater(closing, throwsStateError);
    await expectLater(
      resources.close(() async => fail('release must not be retried')),
      throwsStateError,
    );
  });

  test('native release failure never starts filesystem reclamation', () async {
    final resources = WebResourceLifecycle();
    var deleted = false;
    Future<void> release() async {
      throw StateError('native release failed');
    }

    await expectLater(
      resources.close(() async {
        await release();
        await retireSplatNetProfile(
          deleteProfile: () async => deleted = true,
          onIssue: (_) {},
        );
      }),
      throwsStateError,
    );
    expect(deleted, isFalse);
  });
}
