@Tags(['common'])
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/release_update.dart';
import 'package:squid_album/src/ui/home_shell.dart';

// Exercises the macOS update branch, not a real native browser or DMG install.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _FixtureReleaseService service;
  late Map<String, dynamic> metadata;
  late BuildContext context;
  late List<Object> errors;
  late List<MethodCall> browserCalls;
  late Future<void> pendingCheck;
  var installs = 0;
  const browserChannel = MethodChannel('plugins.flutter.io/url_launcher');

  setUp(() async {
    root = await Directory.systemTemp.createTemp('nsoalbum-macos-update-');
    service = _FixtureReleaseService(root: root.path, metadata: () => metadata);
    installs = 0;
    errors = [];
    browserCalls = [];
    metadata = {
      'tag_name': 'v0.2.13',
      'draft': false,
      'prerelease': false,
      'body': 'Improved media previews.',
      'assets': [
        for (final architecture in ['arm64', 'x64'])
          {
            'name': 'NSOAlbum-macOS-$architecture-0.2.13.dmg',
            'browser_download_url':
                'https://github.com/Cypas/NSOAlbum/releases/download/v0.2.13/NSOAlbum-macOS-$architecture-0.2.13.dmg',
          },
      ],
    };
    PackageInfo.setMockInitialValues(
      appName: 'NSOAlbum',
      packageName: 'io.squidalbum',
      version: '0.2.12',
      buildNumber: '45',
      buildSignature: '',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(browserChannel, (call) async {
          browserCalls.add(call);
          return true;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(browserChannel, null);
    await service.close();
    await root.delete(recursive: true);
  });

  Future<void> mount(WidgetTester tester, {String language = 'zh'}) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: Locale(language),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Builder(
          builder: (value) {
            context = value;
            return const Scaffold(body: Text('Library remains available'));
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> startCheck(
    WidgetTester tester, {
    bool automatic = false,
    String architecture = 'arm64',
  }) async {
    var completed = false;
    // File-based daily/ignore state uses real IO, unlike the HTTP fixture.
    await tester.runAsync(() async {
      pendingCheck = showLatestReleaseUpdate(
        context,
        automatic: automatic,
        macosArchitecture: architecture,
        updateService: service,
        onInstall: (_) async => installs++,
        onError: (error, _) async => errors.add(error),
      );
      pendingCheck.then((_) => completed = true);
      for (var attempt = 0; attempt < 100; attempt++) {
        if (completed || find.byType(AlertDialog).evaluate().isNotEmpty) return;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();
  }

  Future<void> finishCheck(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => pendingCheck.timeout(const Duration(seconds: 5)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('macOS update opens Releases without downloading or installing', (
    tester,
  ) async {
    await mount(tester);
    await startCheck(tester);
    expect(find.textContaining('0.2.13'), findsWidgets);
    expect(find.text('Improved media previews.'), findsOneWidget);
    expect(find.text('前往下载'), findsOneWidget);
    expect(find.text('安装并退出'), findsNothing);
    await tester.tap(find.text('前往下载'));
    await finishCheck(tester);
    expect(browserCalls, hasLength(1));
    expect(
      (browserCalls.single.arguments as Map)['url'],
      'https://github.com/Cypas/NSOAlbum/releases',
    );
    expect((browserCalls.single.arguments as Map)['useWebView'], false);
    expect(installs, 0);
    expect(Directory('${root.path}/updates').existsSync(), false);
    expect(errors, isEmpty);
  });

  testWidgets(
    'missing matching DMG still shows version and a download-page link',
    (tester) async {
      (metadata['assets'] as List).removeLast(); // Only arm64 remains.
      await mount(tester, language: 'en');
      await startCheck(tester, architecture: 'x64');
      expect(
        find.textContaining('No macOS x64 DMG is available'),
        findsOneWidget,
      );
      expect(find.text('Go to downloads'), findsOneWidget);
      expect(find.textContaining('Windows installer'), findsNothing);
      expect(installs, 0);
      await tester.tap(find.text('Later'));
      await finishCheck(tester);
    },
  );

  testWidgets('postponing or dismissing never ignores the release', (
    tester,
  ) async {
    await mount(tester);
    await startCheck(tester);
    await tester.tap(find.byKey(const Key('macos-update-later')));
    await finishCheck(tester);
    expect(await tester.runAsync(service.ignoredReleaseVersion), isNull);

    await startCheck(tester);
    Navigator.of(context).pop();
    await finishCheck(tester);
    expect(await tester.runAsync(service.ignoredReleaseVersion), isNull);
    expect(browserCalls, isEmpty);
    expect(installs, 0);
  });

  testWidgets(
    'daily automatic checks are throttled but manual checks still work',
    (tester) async {
      await mount(tester);
      await tester.runAsync(service.recordAutomaticCheck);
      await startCheck(tester, automatic: true);
      await finishCheck(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(browserCalls, isEmpty);

      await startCheck(tester);
      expect(find.text('前往下载'), findsOneWidget);
      await tester.tap(find.byKey(const Key('macos-update-later')));
      await finishCheck(tester);
    },
  );

  testWidgets(
    'ignoring is persistent and suppresses only that release version',
    (tester) async {
      await mount(tester);
      await startCheck(tester);
      await tester.tap(find.byKey(const Key('macos-update-ignore')));
      await finishCheck(tester);
      expect(await tester.runAsync(service.ignoredReleaseVersion), '0.2.13');

      // Simulate another app instance, reading the same persisted state.
      service = _FixtureReleaseService(
        root: root.path,
        metadata: () => metadata,
      );
      await startCheck(tester, automatic: true);
      await finishCheck(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(browserCalls, isEmpty);
      expect(await tester.runAsync(service.isAutomaticCheckDue), false);

      metadata['tag_name'] = 'v0.2.14';
      await tester.runAsync(
        () =>
            File('${root.path}/update-check-v1.txt')
                .writeAsString('2000-01-01'),
      );
      await startCheck(tester, automatic: true);
      expect(find.textContaining('0.2.14'), findsOneWidget);
      await tester.tap(find.byKey(const Key('macos-update-later')));
      await finishCheck(tester);
      expect(await tester.runAsync(service.ignoredReleaseVersion), '0.2.13');
    },
  );

  testWidgets('a failed browser launch leaves the app usable with an error', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(browserChannel, (_) async => false);
    await mount(tester, language: 'en');
    await startCheck(tester, automatic: true);
    await tester.tap(find.text('Go to downloads'));
    await finishCheck(tester);
    expect(
      find.text('Unable to open GitHub Releases. Please try again later.'),
      findsOneWidget,
    );
    expect(errors, hasLength(1));
    expect(installs, 0);
    expect(find.text('Library remains available'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'macOS check never falls through to an available Windows installer',
    (tester) async {
      (metadata['assets'] as List).add({
        'name': 'NSOAlbum-0.2.13-Setup.exe',
        'browser_download_url': 'https://github.com/Cypas/NSOAlbum/releases/download/v0.2.13/NSOAlbum-0.2.13-Setup.exe',
        'digest': 'sha256:${'a' * 64}',
      });
      await mount(tester);
      await startCheck(tester);
      expect(find.text('前往下载'), findsOneWidget);
      expect(find.text('下载更新'), findsNothing);
      await tester.tap(find.byKey(const Key('macos-update-later')));
      await finishCheck(tester);
      expect(installs, 0);
      expect(browserCalls, isEmpty);
      expect(Directory('${root.path}/updates').existsSync(), false);
    },
  );

  testWidgets(
    'a failed automatic lookup records the day and leaves the gallery usable',
    (tester) async {
      service.failure = const SocketException('Fixture network unavailable');
      await mount(tester);
      await startCheck(tester, automatic: true);
      await finishCheck(tester);
      expect(errors, hasLength(1));
      expect(await tester.runAsync(service.isAutomaticCheckDue), false);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Library remains available'), findsOneWidget);
      expect(browserCalls, isEmpty);
      expect(installs, 0);
    },
  );

  testWidgets('manual checks report latest without offering a download', (
    tester,
  ) async {
    metadata['tag_name'] = 'v0.2.12';
    await mount(tester, language: 'en');
    await startCheck(tester);
    await finishCheck(tester);
    expect(find.text('You are using the latest version.'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(browserCalls, isEmpty);
    expect(installs, 0);
  });
}

// Replace only remote retrieval; real parsing, state files and UI remain active.
class _FixtureReleaseService extends ReleaseUpdateService {
  _FixtureReleaseService({required String root, required this.metadata})
    : super(applicationRoot: root);

  final Map<String, dynamic> Function() metadata;
  Object? failure;

  @override
  Future<LatestReleaseInfo?> checkLatestRelease(String currentVersion) async {
    if (failure != null) throw failure!;
    return latestReleaseInfoFromGithubJson(metadata(), currentVersion);
  }
}
