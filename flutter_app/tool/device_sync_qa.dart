// Standalone Debug app: fresh synthetic library + in-memory credentials only.
// Uses the real page/transport/preview/apply stack, never the personal library.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:squid_album/main.dart' show SquidAlbumApp;
import 'package:squid_album/src/backend/rust_backend.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/rust/bridge.dart' as native;
import 'package:squid_album/src/startup/startup_options.dart';
import 'package:squid_album/src/startup/ci_smoke_contract.dart';
import 'package:squid_album/src/state/settings_copy.dart';
import 'package:squid_album/src/ui/android/android_theme.dart';
import 'package:squid_album/src/ui/device_sync/device_sync_page.dart';
import 'package:squid_album/src/ui/device_sync/page_access.dart';
import 'package:squid_album/src/ui/video_thumbnail.dart';

import 'device_sync_qa_root.dart';
import 'device_sync_qa_fixture.dart';

const _throughputQa = bool.fromEnvironment('DEVICE_SYNC_THROUGHPUT_QA');

Future<void> main() async {
  if (!kDebugMode) throw StateError('Synthetic device QA requires Debug');
  WidgetsFlutterBinding.ensureInitialized();
  final root = await createDeviceSyncQaRoot();
  // Standalone synthetic test entrypoint: never fall through to OS credentials.
  // ignore: invalid_use_of_visible_for_testing_member
  FlutterSecureStorage.setMockInitialValues({});
  final backend = await RustBackend.prepare(applicationRoot: root.path);
  if (!(await native.probeLibraryRoot(libraryRoot: root.path))
      .databaseReadable) {
    throw StateError(
      'Synthetic root does not own the native Core. Start a new process; '
      'hot restart cannot replace a process-owned Rust Core.',
    );
  }
  VideoThumbnailCache.configureCacheRoot(root.path);
  // Persist a contained media path before startup initializes settings. Fresh
  // real-user defaults may intentionally resolve outside the application root.
  await native.saveSettings(
    settings: copyAppSettings(
      backend.settings,
      libraryPath: p.join(root.path, 'media'),
      autoSyncOnLaunch: false,
      language: 'en',
    ),
  );
  await backend.deviceSyncStartup.start();
  if (!backend.deviceSyncStartup.ready) {
    throw StateError(
      'Synthetic startup failed: ${backend.deviceSyncStartup.error}',
    );
  }
  if (!_throughputQa) {
    final image = File(
      p.join(root.path, 'synthetic-${Platform.operatingSystem}.png'),
    );
    await image.writeAsBytes([
      ...base64Decode(syntheticQaPngBase64),
      ...ascii.encode(Platform.operatingSystem),
    ]);
    await backend.importCustomFiles([
      image.path,
    ], 'Synthetic ${Platform.operatingSystem}');
  }
  runApp(_QaApp(backend: backend));
}

class _QaApp extends StatefulWidget {
  const _QaApp({required this.backend});
  final RustBackend backend;
  @override
  State<_QaApp> createState() => _QaAppState();
}

class _QaAppState extends State<_QaApp> {
  final semantics = SemanticsBinding.instance.ensureSemantics();
  @override
  void dispose() {
    semantics.dispose();
    unawaited(widget.backend.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    theme: androidTheme('ocean'),
    home: _QaHome(backend: widget.backend),
  );
}

class _QaHome extends StatelessWidget {
  const _QaHome({required this.backend});
  final RustBackend backend;

  Future<void> prepareThroughputFixture({bool realistic = false}) async {
    if (!_throughputQa) throw StateError('Not the throughput QA entry');
    final root = Directory(p.dirname(p.dirname(backend.logFilePath)));
    final files = realistic
        ? await createDeviceSyncRealisticThroughputFixture(
            root,
            videoSeed: base64Decode(
              (await rootBundle.loadString(
                'assets/ci/synthetic-h264-aac.base64',
              )).replaceAll(RegExp(r'\s'), ''),
            ),
          )
        : await createDeviceSyncThroughputFixture(root);
    await backend.importCustomFiles(
      files.map((file) => file.path).toList(),
      'Synthetic throughput fixture',
    );
  }

  Future<void> addSample() async {
    final root = Directory(p.dirname(p.dirname(backend.logFilePath)));
    final marker = File(p.join(root.path, CiSmokeRoot.marker));
    if (!await marker.exists() ||
        await marker.readAsString() != 'NSOAlbum isolated CI library v1') {
      throw StateError('Synthetic root ownership missing');
    }
    final id = DateTime.now().microsecondsSinceEpoch;
    final image = File(p.join(root.path, 'synthetic-added-$id.png'));
    await image.writeAsBytes([
      ...base64Decode(syntheticQaPngBase64),
      ...ascii.encode('${Platform.operatingSystem}-$id'),
    ]);
    await backend.importCustomFiles([
      image.path,
    ], 'Synthetic ${Platform.operatingSystem}');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Synthetic device QA — no personal data')),
    body: Center(
      child: Wrap(
        spacing: 16,
        children: [
          FilledButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => DeviceSyncPage(
                  access: BackendDeviceSyncPageAccess(backend),
                  mobile: Platform.isAndroid,
                ),
              ),
            ),
            child: const Text('Open real device sync page'),
          ),
          OutlinedButton(
            onPressed: () async {
              await addSample();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Added one synthetic media')),
                );
              }
            },
            child: const Text('Add one new synthetic sample'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SquidAlbumApp(
                  backend: backend,
                  startupOptions: const StartupOptions(safeMode: true),
                ),
              ),
            ),
            child: const Text('Inspect synthetic gallery'),
          ),
        ],
      ),
    ),
  );
}
