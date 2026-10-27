@Tags(['platform-android'])
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler_platform_interface/permission_handler_platform_interface.dart';
import 'package:squid_album/src/platform/android_storage_access.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('io.github.cypas.nsoalbum/storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late _StorageFixture fixture;

  setUp(() {
    fixture = _StorageFixture();
    messenger.setMockMethodCallHandler(channel, fixture.handle);
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'ordinary Android startup alone enables the optional permission flow',
    () {
      expect(
        androidStorageStartupEnabled(
          isAndroid: true,
          isTest: false,
          safeMode: false,
          ciSmoke: false,
        ),
        isTrue,
      );
      for (final values in [
        (false, false, false, false),
        (true, true, false, false),
        (true, false, true, false),
        (true, false, false, true),
      ]) {
        expect(
          androidStorageStartupEnabled(
            isAndroid: values.$1,
            isTest: values.$2,
            safeMode: values.$3,
            ciSmoke: values.$4,
          ),
          isFalse,
        );
      }
    },
  );

  test('first startup requests once and rechecks the actual grant', () async {
    final access = AndroidStorageAccess(permissions: fixture.permissions);
    fixture.permissions.afterRequest = () => fixture.allowed = true;

    expect(
      await access.request(automatic: true),
      AndroidStorageAccessState.allowed,
    );
    expect(fixture.requested, isTrue);
    expect(fixture.permissions.requests, [
      [Permission.manageExternalStorage],
    ]);
    expect(fixture.releases, 1);
    expect(fixture.reserved, isFalse);
  });

  test(
    'denial does not relaunch on another startup but manual retry works',
    () async {
      final access = AndroidStorageAccess(permissions: fixture.permissions);
      expect(
        await access.request(automatic: true),
        AndroidStorageAccessState.denied,
      );
      expect(
        await AndroidStorageAccess(permissions: fixture.permissions)
            .request(automatic: true),
        AndroidStorageAccessState.denied,
      );
      expect(fixture.permissions.requests, hasLength(1));
      fixture.permissions.afterRequest = () => fixture.allowed = true;
      expect(await access.request(), AndroidStorageAccessState.allowed);
      expect(fixture.permissions.requests, hasLength(2));
      expect(fixture.reserved, isFalse);
    },
  );

  test('already granted and API below 30 never open settings', () async {
    final access = AndroidStorageAccess(permissions: fixture.permissions);
    fixture.allowed = true;
    expect(
      await access.request(automatic: true),
      AndroidStorageAccessState.allowed,
    );
    fixture.allowed = false;
    fixture.supported = false;
    expect(
      await access.request(automatic: true),
      AndroidStorageAccessState.notRequired,
    );
    expect(fixture.permissions.requests, isEmpty);
    expect(fixture.requested, isFalse);
  });

  test(
    'native permission ownership defers storage without marking it requested',
    () async {
      final access = AndroidStorageAccess(permissions: fixture.permissions);
      fixture.reserved = true;
      expect(
        await access.request(automatic: true),
        AndroidStorageAccessState.busy,
      );
      expect(fixture.permissions.requests, isEmpty);
      expect(fixture.requested, isFalse);
      fixture.reserved = false;
      expect(
        await access.request(automatic: true),
        AndroidStorageAccessState.denied,
      );
      expect(fixture.permissions.requests, hasLength(1));
    },
  );

  test('concurrent requests share a single settings operation', () async {
    final access = AndroidStorageAccess(permissions: fixture.permissions);
    final pending = Completer<void>();
    fixture.permissions.pending = pending.future;
    final first = access.request(automatic: true);
    final second = access.request();
    await Future<void>.delayed(Duration.zero);
    expect(fixture.permissions.requests, hasLength(1));
    pending.complete();
    expect(await first, AndroidStorageAccessState.denied);
    expect(await second, AndroidStorageAccessState.denied);
    expect(fixture.releases, 1);
  });

  test('plugin success cannot substitute for the real Android grant', () async {
    fixture.permissions.returned = PermissionStatus.granted;
    final access = AndroidStorageAccess(permissions: fixture.permissions);
    expect(
      await access.request(automatic: true),
      AndroidStorageAccessState.denied,
    );
    expect(await access.status(), AndroidStorageAccessState.denied);
  });

  test(
    'failed settings launch releases ownership and remains manually retryable',
    () async {
      final access = AndroidStorageAccess(permissions: fixture.permissions);
      fixture.permissions.failure = StateError('synthetic settings failure');
      expect(
        await access.request(automatic: true),
        AndroidStorageAccessState.unavailable,
      );
      expect(fixture.requested, isTrue);
      expect(fixture.reserved, isFalse);
      fixture.permissions.failure = null;
      expect(await access.request(), AndroidStorageAccessState.denied);
      expect(fixture.permissions.requests, hasLength(2));
    },
  );
}

class _StorageFixture {
  final permissions = _Permissions();
  bool supported = true;
  bool allowed = false;
  bool requested = false;
  bool reserved = false;
  int releases = 0;

  Future<Object?> handle(MethodCall call) async {
    switch (call.method) {
      case 'allFilesAccessStatus':
        return {
          'supported': supported,
          'allowed': allowed,
          'requested': requested,
        };
      case 'beginAllFilesAccessRequest':
        if (reserved) return false;
        reserved = true;
        requested = true;
        return true;
      case 'endAllFilesAccessRequest':
        reserved = false;
        releases++;
        return null;
      default:
        throw MissingPluginException();
    }
  }
}

class _Permissions extends PermissionHandlerPlatform {
  final requests = <List<Permission>>[];
  PermissionStatus returned = PermissionStatus.denied;
  void Function()? afterRequest;
  Future<void>? pending;
  Object? failure;

  @override
  Future<Map<Permission, PermissionStatus>> requestPermissions(
    List<Permission> permissions,
  ) async {
    requests.add(List.of(permissions));
    if (failure case final error?) throw error;
    await pending;
    afterRequest?.call();
    return {for (final permission in permissions) permission: returned};
  }
}
