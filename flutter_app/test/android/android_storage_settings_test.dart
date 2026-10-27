@Tags(['platform-android'])
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler_platform_interface/permission_handler_platform_interface.dart';
import 'package:squid_album/main.dart';
import 'package:squid_album/src/platform/android_storage_access.dart';
import 'package:squid_album/src/ui/platform_ui.dart';

import '../home_shell_test.dart' show FakeBackend;

void main() {
  const channel = MethodChannel('io.github.cypas.nsoalbum/storage');
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'settings hides all-files recovery UI while permission status remains isolated',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'STORAGE_ACCESS_UNAVAILABLE');
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(
        SquidAlbumApp(
          backend: FakeBackend(mediaItems: []),
          uiPlatform: AppUiPlatform.android,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(NavigationDestination).at(3));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('android-storage-permission-card')),
        findsNothing,
      );
      expect(find.byKey(const Key('android-storage-permission')), findsNothing);
      expect(
        await AndroidStorageAccess(channel: channel).status(),
        AndroidStorageAccessState.unavailable,
      );
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    'settings hides busy all-files UI without changing permission flow state',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final oldPermissions = PermissionHandlerPlatform.instance;
      final permissions = _Permissions();
      PermissionHandlerPlatform.instance = permissions;
      addTearDown(() => PermissionHandlerPlatform.instance = oldPermissions);
      var busy = true;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'allFilesAccessStatus') {
          return {'supported': true, 'allowed': false, 'requested': true};
        }
        if (call.method == 'beginAllFilesAccessRequest') return !busy;
        if (call.method == 'endAllFilesAccessRequest') return null;
        throw MissingPluginException();
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(
        SquidAlbumApp(
          backend: FakeBackend(mediaItems: []),
          uiPlatform: AppUiPlatform.android,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(NavigationDestination).at(3));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('android-storage-permission-card')),
        findsNothing,
      );
      expect(find.byKey(const Key('android-storage-permission')), findsNothing);
      expect(permissions.requests, 0);
      final access = AndroidStorageAccess(channel: channel);
      expect(await access.request(), AndroidStorageAccessState.busy);
      busy = false;
      expect(await access.request(), AndroidStorageAccessState.denied);
      expect(permissions.requests, 1);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets('settings hides denied all-files retry UI without blocking', (
    tester,
  ) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final oldPermissions = PermissionHandlerPlatform.instance;
    final permissions = _Permissions();
    PermissionHandlerPlatform.instance = permissions;
    addTearDown(() => PermissionHandlerPlatform.instance = oldPermissions);
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'allFilesAccessStatus') {
        return {'supported': true, 'allowed': false, 'requested': true};
      }
      if (call.method == 'beginAllFilesAccessRequest') return true;
      if (call.method == 'endAllFilesAccessRequest') return null;
      throw MissingPluginException();
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
      SquidAlbumApp(
        backend: FakeBackend(mediaItems: []),
        uiPlatform: AppUiPlatform.android,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(NavigationDestination).at(3));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('android-storage-permission-card')),
      findsNothing,
    );
    expect(find.byKey(const Key('android-storage-permission')), findsNothing);
    expect(permissions.requests, 0);
    final access = AndroidStorageAccess(channel: channel);
    expect(await access.request(), AndroidStorageAccessState.denied);
    expect(permissions.requests, 1);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(await access.request(), AndroidStorageAccessState.denied);
    expect(permissions.requests, 2);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant({TargetPlatform.android}));
}

class _Permissions extends PermissionHandlerPlatform {
  int requests = 0;

  @override
  Future<Map<Permission, PermissionStatus>> requestPermissions(
    List<Permission> permissions,
  ) async {
    if (permissions.length != 1 ||
        permissions.single != Permission.manageExternalStorage) {
      throw StateError('Unexpected permission');
    }
    requests++;
    return {Permission.manageExternalStorage: PermissionStatus.denied};
  }
}
