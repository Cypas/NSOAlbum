@Tags(['platform-android'])
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:squid_album/src/release_update.dart';
import 'package:squid_album/src/state/android_update_controller.dart';

import 'android_release_update_test.dart' show metadata;

class FixtureReleaseService extends ReleaseUpdateService {
  FixtureReleaseService(String root) : super(applicationRoot: root);
  Map<String, dynamic> json = metadata();
  Object? failure;
  int checks = 0;

  @override
  Future<LatestReleaseInfo?> checkLatestRelease(String currentVersion) async {
    checks++;
    if (failure != null) throw failure!;
    return latestReleaseInfoFromGithubJson(json, currentVersion);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('io.github.cypas.nsoalbum/update');
  late Directory root;
  late FixtureReleaseService service;
  late AndroidUpdateController controller;
  late List<MethodCall> calls;
  late Map<String, Object?> nativeStatus;
  Object? nativeFailure;
  var invalidateOnInstall = false;

  setUp(() async {
    PackageInfo.setMockInitialValues(
      appName: 'NSOAlbum',
      packageName: 'io.github.cypas.nsoalbum',
      version: '0.2.14',
      buildNumber: '47',
      buildSignature: '',
    );
    root = await Directory.systemTemp.createTemp('nsoalbum-android-update-');
    service = FixtureReleaseService(root.path);
    calls = [];
    nativeFailure = null;
    invalidateOnInstall = false;
    nativeStatus = {
      'state': 'idle',
      'version': null,
      'received': 0,
      'total': 0,
      'error': null,
      'notificationAllowed': false,
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'install' && invalidateOnInstall) {
            nativeStatus = {
              ...nativeStatus,
              'state': 'failed',
              'error': 'HASH_MISMATCH',
            };
            throw PlatformException(code: 'HASH_MISMATCH');
          }
          if (nativeFailure != null && call.method == 'install') {
            throw nativeFailure!;
          }
          if (call.method == 'requestNotifications') return false;
          if (call.method == 'install') return null;
          if (call.method == 'startDownload') {
            nativeStatus = {
              ...nativeStatus,
              'state': 'downloading',
              'version': '0.3.0',
              'total': 1024,
            };
          }
          return nativeStatus;
        });
    controller = AndroidUpdateController(
      allowPackageUpdates: true,
      releaseService: service,
      channel: channel,
      versionLoader: () async => '0.2.14+47',
    );
  });

  tearDown(() async {
    controller.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await service.close();
    await root.delete(recursive: true);
  });

  Future<void> check({
    bool automatic = false,
    AndroidUpdateAction action = AndroidUpdateAction.later,
  }) => controller.check(
    automatic: automatic,
    language: 'en',
    confirm: (_) async => action,
  );

  test(
    'Debug manually checks versions without downloading release APKs',
    () async {
      final debug = AndroidUpdateController(
        releaseService: service,
        versionLoader: () async => '0.2.14+47',
      );
      addTearDown(debug.dispose);
      await debug.check(
        automatic: false,
        language: 'en',
        confirm: (_) async => AndroidUpdateAction.download,
      );
      expect(service.checks, 1);
      expect(debug.updateStatus, UpdateStatusKind.available);
      expect(debug.latestRelease!.version, '0.3.0');
      expect(debug.canDownload, false);
      await debug.download(language: 'en');
      expect(calls, isEmpty);
    },
  );

  test('Debug never starts automatic checks or restores APK tasks', () async {
    final debug = AndroidUpdateController(
      releaseService: service,
      versionLoader: () async => '0.2.14+47',
    );
    addTearDown(debug.dispose);
    await debug.check(
      automatic: true,
      language: 'en',
      confirm: (_) async => AndroidUpdateAction.later,
    );
    await debug.restore();
    debug.setForeground(true);
    await Future<void>.delayed(Duration.zero);
    expect(service.checks, 0);
    expect(calls, isEmpty);
  });

  test(
    'Debug cannot install even if a ready package status is present',
    () async {
      final debug = AndroidUpdateController(releaseService: service);
      addTearDown(debug.dispose);
      debug.status = const AndroidUpdateStatus(
        state: AndroidUpdateState.ready,
        version: '0.3.0',
      );
      expect(debug.canInstall, false);
      await debug.install();
      expect(calls, isEmpty);
    },
  );

  test('availability requires explicit download confirmation', () async {
    await check();
    expect(controller.latestRelease!.version, '0.3.0');
    expect(controller.canDownload, true);
    expect(controller.status.state, AndroidUpdateState.idle);
    expect(calls.where((call) => call.method == 'startDownload'), isEmpty);
  });

  test('production Android metadata lookup never uses a mirror API', () async {
    final client = RecordingClient();
    await HttpOverrides.runZoned(() async {
      final ownedController = AndroidUpdateController(
        applicationRoot: root.path,
        versionLoader: () async => '0.2.14+47',
      );
      try {
        await ownedController.check(
          automatic: false,
          language: 'en',
          confirm: (_) async => AndroidUpdateAction.later,
        );
        expect(client.urls.map((url) => url.toString()).toList(), [
          'https://api.github.com/repos/Cypas/NSOAlbum/releases/latest',
        ]);
        expect(ownedController.updateStatus, UpdateStatusKind.failed);
      } finally {
        ownedController.dispose();
      }
    }, createHttpClient: (_) => client);
  });

  test(
    'notification denial still starts confirmed download with safe payload',
    () async {
      await check(action: AndroidUpdateAction.download);
      expect(controller.status.state, AndroidUpdateState.downloading);
      expect(controller.status.notificationAllowed, false);
      final download = calls.singleWhere(
        (call) => call.method == 'startDownload',
      );
      expect(download.arguments, {
        'version': '0.3.0',
        'url': 'https://github.com/Cypas/NSOAlbum/releases/download/v0.3.0/NSOAlbum-Android-arm64-0.3.0.apk',
        'sha256': 'a' * 64,
        'size': 1024,
        'userAgent': 'Cypas-NSOAlbum/0.2.14',
        'language': 'en',
      });
    },
  );

  test(
    'restored verified package offers install even with no notifications',
    () async {
      nativeStatus = {...nativeStatus, 'state': 'ready', 'version': '0.3.0'};
      await controller.restore();
      expect(controller.canInstall, true);
      expect(controller.message('en'), contains('ready'));
      await controller.install();
      expect(calls.where((call) => call.method == 'install'), hasLength(1));
    },
  );

  test(
    'automatic checks respect natural day and manual checks bypass it',
    () async {
      await check(automatic: true);
      await check(automatic: true);
      expect(service.checks, 1);
      await check();
      expect(service.checks, 2);
    },
  );

  test(
    'ignore is persistent but manual confirmation bypasses ignore',
    () async {
      await check(action: AndroidUpdateAction.ignore);
      expect(await service.ignoredReleaseVersion(), '0.3.0');
      var confirmations = 0;
      await controller.check(
        automatic: true,
        language: 'en',
        confirm: (_) async {
          confirmations++;
          return AndroidUpdateAction.later;
        },
      );
      expect(confirmations, 0);
      await check();
      expect(controller.canDownload, true);
    },
  );

  test('missing verified Android asset never starts download', () async {
    service.json['assets'] = [];
    await check(action: AndroidUpdateAction.download);
    expect(controller.canDownload, false);
    expect(controller.message('en'), contains('No verified Android package'));
    expect(calls.where((call) => call.method == 'startDownload'), isEmpty);
  });

  test('duplicate checks cannot open a second confirmation', () async {
    final confirmation = Completer<AndroidUpdateAction?>();
    final first = controller.check(
      automatic: false,
      language: 'en',
      confirm: (_) => confirmation.future,
    );
    while (service.checks == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    await check(action: AndroidUpdateAction.download);
    confirmation.complete(AndroidUpdateAction.later);
    await first;
    expect(service.checks, 1);
    expect(calls.where((call) => call.method == 'startDownload'), isEmpty);
  });

  test('lookup errors are readable and do not expose remote details', () async {
    service.failure = const SocketException('token=private&account=secret');
    await check(automatic: true);
    expect(controller.updateStatus, UpdateStatusKind.failed);
    expect(
      controller.message('en'),
      'Unable to check for updates. Try again later.',
    );
    expect(controller.message('zh'), contains('检查更新失败'));
    expect(await service.isAutomaticCheckDue(), false);
  });

  test(
    'native verification errors remain readable without exposing paths',
    () async {
      nativeStatus = {
        ...nativeStatus,
        'state': 'failed',
        'error': 'SIGNATURE_MISMATCH',
      };
      await controller.restore();
      expect(controller.canInstall, false);
      expect(controller.message('en'), contains('signature'));
      expect(controller.message('zh'), contains('签名'));
    },
  );

  test(
    'install permission request preserves verified ready button for retry',
    () async {
      nativeStatus = {...nativeStatus, 'state': 'ready', 'version': '0.3.0'};
      await controller.restore();
      nativeFailure = PlatformException(code: 'INSTALL_PERMISSION_REQUIRED');
      await controller.install();
      expect(controller.canInstall, true);
      expect(controller.message('en'), contains('system settings'));
      nativeFailure = null;
      await controller.install();
      expect(calls.where((call) => call.method == 'install'), hasLength(2));
    },
  );

  test('install-time invalidation removes the stale install button and permits redownload', () async {
    await check();
    nativeStatus = {...nativeStatus, 'state': 'ready', 'version': '0.3.0'};
    await controller.restore();
    invalidateOnInstall = true;
    await controller.install();
    expect(controller.status.state, AndroidUpdateState.failed);
    expect(controller.canInstall, false);
    expect(controller.canDownload, true);
    expect(controller.message('en'), contains('could not be verified'));
  });

  test('successful restoration clears a transient status-read error', () async {
    var failed = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
          if (failed) throw const FormatException('fixture status unavailable');
          return {...nativeStatus, 'state': 'ready', 'version': '0.3.0'};
        });
    await controller.restore();
    expect(
      controller.message('en'),
      contains('Unable to read update progress'),
    );
    failed = false;
    await controller.restore();
    expect(controller.message('en'), contains('ready to install'));
    expect(controller.canInstall, true);
  });

  test('manual Android checks are available outside tests and diagnostics', () {
    expect(
      androidUpdateChecksEnabled(
        isAndroid: true,
        isTest: false,
        safeMode: false,
        ciSmoke: false,
      ),
      true,
    );
    for (final input in [
      (false, false, false, false),
      (true, true, false, false),
      (true, false, true, false),
      (true, false, false, true),
    ]) {
      expect(
        androidUpdateChecksEnabled(
          isAndroid: input.$1,
          isTest: input.$2,
          safeMode: input.$3,
          ciSmoke: input.$4,
        ),
        false,
      );
    }
  });

  test('startup updates require actual Android Release outside tests and diagnostics', () {
    expect(
      androidUpdateStartupEnabled(
        isAndroid: true,
        releaseMode: true,
        isTest: false,
        safeMode: false,
        ciSmoke: false,
      ),
      true,
    );
    for (final input in [
      (false, true, false, false, false),
      (true, false, false, false, false),
      (true, true, true, false, false),
      (true, true, false, true, false),
      (true, true, false, false, true),
    ]) {
      expect(
        androidUpdateStartupEnabled(
          isAndroid: input.$1,
          releaseMode: input.$2,
          isTest: input.$3,
          safeMode: input.$4,
          ciSmoke: input.$5,
        ),
        false,
      );
    }
  });

  testWidgets(
    'foreground polling restores ready state and stops after completion',
    (tester) async {
      nativeStatus = {
        ...nativeStatus,
        'state': 'downloading',
        'version': '0.3.0',
      };
      await controller.restore();
      nativeStatus = {...nativeStatus, 'state': 'ready'};
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(controller.canInstall, true);
      final callCount = calls.length;
      await tester.pump(const Duration(seconds: 4));
      expect(calls.length, callCount);
      controller.setForeground(false);
    },
  );

  testWidgets('disposing stops download status polling', (tester) async {
    nativeStatus = {
      ...nativeStatus,
      'state': 'downloading',
      'version': '0.3.0',
    };
    final ownedController = AndroidUpdateController(allowPackageUpdates: true);
    await ownedController.restore();
    ownedController.dispose();
    final callCount = calls.length;
    await tester.pump(const Duration(seconds: 4));
    expect(calls.length, callCount);
  });

  testWidgets('background status resumes without polling while suspended', (
    tester,
  ) async {
    nativeStatus = {
      ...nativeStatus,
      'state': 'downloading',
      'version': '0.3.0',
    };
    await controller.restore();
    controller.setForeground(false);
    final callCount = calls.length;
    await tester.pump(const Duration(seconds: 4));
    expect(calls.length, callCount);
    nativeStatus = {...nativeStatus, 'state': 'ready'};
    controller.setForeground(true);
    await tester.pump();
    expect(controller.canInstall, true);
  });
}

class RecordingClient implements HttpClient {
  final urls = <Uri>[];

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    urls.add(url);
    throw const SocketException('fixture offline');
  }

  @override
  set findProxy(String Function(Uri)? value) {}

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
