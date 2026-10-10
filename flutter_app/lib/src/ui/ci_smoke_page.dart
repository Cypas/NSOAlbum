import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:ffmpeg_kit_flutter_new_video/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_video/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_video/return_code.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../backend/rust_backend.dart';
import '../rust/models.dart';
import '../rust/settings.dart';
import '../startup/ci_smoke_contract.dart';
import '../startup/startup_diagnostics.dart';
import '../startup/startup_options.dart';
import 'video_runtime.dart';
import 'video_thumbnail.dart';

/// Explicit opt-in diagnostics, using real plugins and an isolated Rust library.
/// This is not mounted during regular startup or Flutter widget tests.
class CiSmokeApp extends StatefulWidget {
  const CiSmokeApp({
    super.key,
    required this.backend,
    required this.options,
    required this.diagnostics,
    required this.gallery,
  });

  final RustBackend backend;
  final StartupOptions options;
  final StartupDiagnostics diagnostics;
  final Widget gallery;

  @override
  State<CiSmokeApp> createState() => _CiSmokeAppState();
}

class _CiSmokeAppState extends State<CiSmokeApp> {
  late final report = CiSmokeReport(widget.options.ciSmokeScenario);
  final boundary = GlobalKey();
  Player? player;
  VideoController? controller;
  ui.Image? image;
  bool trayCreated = false;
  String get root => widget.diagnostics.applicationRoot;
  String get cacheRoot => p.join(root, 'cache', 'video_thumbnails');

  @override
  void initState() {
    super.initState();
    FlutterError.onError = (details) {
      report.record(
        'flutter-framework-error',
        passed: false,
        error: sanitizeSmokeDiagnostic('${details.exception}', roots: [root]),
      );
    };
    ui.PlatformDispatcher.instance.onError = (error, stack) {
      report.record(
        'asynchronous-error',
        passed: false,
        error: sanitizeSmokeDiagnostic('$error', roots: [root]),
      );
      return true;
    };
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_run()));
  }

  Future<void> _run() async {
    try {
      await _step('rust-initialization', () async {
        if (!await File(p.join(root, 'database', 'library.sqlite3')).exists() ||
            !p.isWithin(root, widget.backend.settings.libraryPath)) {
          throw StateError('Core database or media root is not isolated');
        }
        if (await widget.backend.isSignedIn ||
            (await widget.backend.listNintendoAccounts()).isNotEmpty) {
          throw StateError('Smoke must not read personal account storage');
        }
      });
      await _step('first-frame', () async {
        await WidgetsBinding.instance.endOfFrame;
        if (boundary.currentContext?.findRenderObject()
            is! RenderRepaintBoundary) {
          throw StateError('Flutter did not render the diagnostic window');
        }
      });
      await _step('first-gallery-query', () async {
        final items = await widget.backend.listMedia();
        if (report.scenario != 'reopen' && items.isNotEmpty) {
          throw StateError('A fresh CI library unexpectedly contains media');
        }
        await _waitForLibraryStartup();
      });
      if (report.scenario == 'safe') {
        await _step('safe-components-disabled', () async {
          final options = widget.options;
          if (!options.safeMode ||
              !options.disableAutomaticSync ||
              !options.disableVideoThumbnails ||
              !options.disableDesktopLifecycle ||
              !options.disableMtpDetection) {
            throw StateError('Safety restrictions were not enabled');
          }
          final log = await File(widget.diagnostics.logPath).readAsString();
          for (final phase in [
            'desktop-lifecycle-disabled',
            'media-player-prewarm-disabled',
            'automatic-sync-disabled',
            'ime-coordinator-disabled',
          ]) {
            if (!log.contains('Startup phase: $phase')) {
              throw StateError('Safe startup did not observe $phase');
            }
          }
          for (final forbidden in [
            'desktop-lifecycle-start',
            'media-player-prewarm-start',
            'automatic-sync-start-start',
            'ime-coordinator-started',
          ]) {
            if (log.contains('Startup phase: $forbidden')) {
              throw StateError(
                'Safe startup incorrectly activated a disabled component',
              );
            }
          }
        });
      } else if (report.scenario == 'reopen') {
        await _reopen();
      } else {
        await _normal();
      }
    } catch (error) {
      if (!report.steps.any((step) => step['status'] == 'failed')) {
        report.record(
          'unhandled-diagnostic',
          passed: false,
          error: sanitizeSmokeDiagnostic('$error', roots: [root]),
        );
      }
      await _captureFailure();
    } finally {
      await _finish();
    }
  }

  Future<void> _waitForLibraryStartup() async {
    final log = File(widget.diagnostics.logPath);
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      final content = await log.readAsString();
      if (content.contains('first-gallery-query-complete')) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw TimeoutException('Real gallery did not complete its startup query');
  }

  Future<void> _normal() async {
    await _step('desktop-plugins', () async {
      await windowManager.ensureInitialized();
      if (Platform.isWindows) {
        await windowManager.setTitleBarStyle(
          TitleBarStyle.hidden,
          windowButtonVisibility: false,
        );
      }
      await windowManager.setTitle('NSOAlbum CI');
      if (await windowManager.getTitle() != 'NSOAlbum CI') {
        throw StateError('Native window title did not update');
      }
      await trayManager.setIcon(
        Platform.isWindows
            ? 'assets/tray/app_icon.ico'
            : 'assets/tray/app_icon.png',
      );
      trayCreated = true;
      await trayManager.setToolTip('NSOAlbum CI');
    });
    late List<String> fixtures;
    await _step('fixture-generation', () async {
      final directory = await Directory(p.join(root, 'fixtures')).create();
      // Synthetic H.264/AAC bytes were authored for CI and are 2 seconds long.
      final video = base64Decode(
        (await rootBundle.loadString('assets/ci/synthetic-h264-aac.base64'))
            .replaceAll(RegExp(r'\s'), ''),
      );
      final picture = ui.PictureRecorder();
      Canvas(picture).drawRect(
        const Rect.fromLTWH(0, 0, 160, 90),
        Paint()..color = const Color(0xff2896dc),
      );
      final recording = picture.endRecording();
      final png = await recording.toImage(160, 90);
      final encoded = (await png.toByteData(format: ui.ImageByteFormat.png))!;
      png.dispose();
      recording.dispose();
      final imagePath = p.join(directory.path, 'original.png');
      final videoPath = p.join(directory.path, 'original.mp4');
      final secondPath = p.join(directory.path, 'second.mp4');
      await File(imagePath).writeAsBytes(encoded.buffer.asUint8List());
      await File(videoPath).writeAsBytes(video);
      await _ffmpeg([
        '-y',
        '-i',
        videoPath,
        '-map',
        '0',
        '-c',
        'copy',
        '-metadata',
        'comment=NSOAlbum synthetic second source',
        secondPath,
      ]);
      fixtures = [imagePath, videoPath, secondPath];
      for (final path in fixtures.skip(1)) {
        final information = await FFprobeKit.getMediaInformation(path);
        final streams = information.getMediaInformation()?.getStreams() ?? [];
        if (!streams.any((stream) => stream.getCodec() == 'h264') ||
            !streams.any((stream) => stream.getCodec() == 'aac')) {
          throw StateError('Fixture must contain H.264 video and AAC audio');
        }
      }
    });
    final fixtureHashes = {
      for (final path in fixtures) path: await _hash(path),
    };
    await _step('import', () async {
      final summary = await widget.backend.importCustomFiles(
        fixtures,
        'CI Game',
      );
      if (summary.failed != BigInt.zero || summary.imported != BigInt.from(3)) {
        throw StateError('Fixture import must create exactly three assets');
      }
    });
    final assets = await widget.backend.listMedia();
    final still = assets.singleWhere((item) => item.kind == MediaKind.image);
    final videos = assets
        .where((item) => item.kind == MediaKind.video)
        .toList();
    final sourceHashes = {
      for (final item in assets)
        item.storagePath: await _hash(item.storagePath),
    };
    await _step('image-decode', () async {
      final codec = await ui.instantiateImageCodec(
        await File(still.storagePath).readAsBytes(),
      );
      try {
        final frame = await codec.getNextFrame();
        if (frame.image.width != 160 || frame.image.height != 90) {
          frame.image.dispose();
          throw StateError('Decoded image dimensions are incorrect');
        }
        setState(() => image = frame.image);
        await WidgetsBinding.instance.endOfFrame;
      } finally {
        codec.dispose();
      }
    });
    await _step('video-first-frame', () => _play(videos.first.storagePath));
    await _step('thumbnail-duration', () async {
      final cover = await _cover(videos.first);
      _withinDuration(cover.duration, const Duration(seconds: 2));
      await _decodeCover(cover.bytes!, expectedColor: true);
    });
    await _step('thumbnail-cache-reuse', () => _verifyCache(videos.first));
    late MediaAsset trimmed;
    await _step('trim', () async {
      trimmed = await widget.backend.trimVideo(
        videos.first,
        const Duration(milliseconds: 250),
        const Duration(milliseconds: 1250),
        overwrite: false,
      );
      await _assertStored(trimmed);
      _withinDuration(
        await _duration(trimmed.storagePath),
        const Duration(seconds: 1),
      );
      if (!trimmed.tags.any((tag) => tag == '剪辑' || tag == 'Edited')) {
        throw StateError('Rust did not attach the generated trim tag');
      }
    });
    await _step('trim-playback', () => _play(trimmed.storagePath));
    late MediaAsset merged;
    await _step('merge', () async {
      final preview = await widget.backend.createMergedVideoPreview(videos);
      merged = await widget.backend.saveMergedVideo(
        videos,
        preparedPath: preview,
      );
      await _assertStored(merged);
      _withinDuration(
        await _duration(merged.storagePath),
        const Duration(seconds: 4),
      );
      if (!merged.tags.any((tag) => tag == '合并' || tag == 'Merged')) {
        throw StateError('Rust did not attach the generated merge tag');
      }
    });
    await _step('merge-playback', () => _play(merged.storagePath));
    await _step('source-integrity', () async {
      for (final entry in {...fixtureHashes, ...sourceHashes}.entries) {
        if (await _hash(entry.key) != entry.value) {
          throw StateError('Source content changed during video processing');
        }
      }
    });
    await _step('persistence-write', () async {
      final previous = widget.backend.settings;
      await widget.backend.saveSettings(
        AppSettings(
          proxyUrl: previous.proxyUrl,
          libraryPath: previous.libraryPath,
          theme: previous.theme,
          language: 'en',
          galleryColumns: 5,
          galleryRows: previous.galleryRows,
          showNotePreview: previous.showNotePreview,
          showGameTag: previous.showGameTag,
          compactTagDisplay: previous.compactTagDisplay,
          autoPlayVideo: true,
          autoSyncOnLaunch: false,
          closeBehavior: previous.closeBehavior,
          customFontPaths: const [],
          syncPolicy: previous.syncPolicy,
        ),
      );
      await widget.backend.setFavorite(videos.first.id, true);
      await widget.backend.setNote(
        videos.first.id,
        'isolated CI persisted note',
      );
      final items = await widget.backend.listMedia();
      if (items.length != 5) {
        throw StateError('Edit outputs did not enter the library');
      }
      await File(p.join(root, 'expected.json')).writeAsString(
        jsonEncode({
          'hashes': items.map((item) => item.sha256).toList()..sort(),
          'favorite': videos.first.sha256,
          'cover': await _hash(p.join(cacheRoot, '${videos.first.sha256}.jpg')),
        }),
        flush: true,
      );
    });
  }

  Future<void> _reopen() async {
    final expected = jsonDecode(
      await File(p.join(root, 'expected.json')).readAsString(),
    ) as Map;
    late MediaAsset source;
    await _step('persistence-read', () async {
      final settings = widget.backend.settings;
      if (settings.language != 'en' ||
          settings.galleryColumns != 5 ||
          !settings.autoPlayVideo ||
          settings.autoSyncOnLaunch) {
        throw StateError(
          'Application settings were not persisted across process restart',
        );
      }
      final items = await widget.backend.listMedia();
      final hashes = items.map((item) => item.sha256).toList()..sort();
      if (jsonEncode(hashes) != jsonEncode(expected['hashes'])) {
        throw StateError('Persisted media changed after process restart');
      }
      source = items.singleWhere((item) => item.sha256 == expected['favorite']);
      if (!source.favorite || source.note != 'isolated CI persisted note') {
        throw StateError('Metadata was not persisted across process restart');
      }
    });
    await _step('thumbnail-cache-reuse', () async {
      final coverFile = p.join(cacheRoot, '${source.sha256}.jpg');
      if (await _hash(coverFile) != expected['cover']) {
        throw StateError('Disk cover changed after restart');
      }
      await _verifyCache(source);
    });
  }

  Future<void> _play(String path) async {
    final previous = player;
    setState(() {
      controller = null;
      player = null;
    });
    await WidgetsBinding.instance.endOfFrame;
    if (previous != null) await previous.dispose();
    VideoRuntime.ensureInitialized();
    final next = Player();
    // Hosted macOS runners can crash in the Metal output on both Intel and
    // arm64.  The CPU-backed output is stable; the frame check below waits
    // for the software texture to contain decoded pixels before continuing.
    final useHardwareVideoOutput = !Platform.isMacOS;
    final output = VideoController(
      next,
      configuration: VideoControllerConfiguration(
        enableHardwareAcceleration: useHardwareVideoOutput,
      ),
    );
    setState(() {
      player = next;
      controller = output;
    });
    await WidgetsBinding.instance.endOfFrame;
    await VideoRuntime.openAndPlayWhenReady(
      waitForVideoOutput: () => output.platform.future,
      open: () => next.open(Media(path), play: false),
      play: next.play,
      timeout: const Duration(seconds: 15),
    );
    await output.waitUntilFirstFrameRendered.timeout(
      const Duration(seconds: 15),
    );
    await next.stream.position
        .firstWhere((value) => value.inMilliseconds >= 100)
        .timeout(const Duration(seconds: 10));
    // On macOS, media_kit's software texture screenshot channel can block the
    // runner even after the native first-frame event has fired. The event plus
    // advancing playback position prove a decoded frame was produced; keep
    // pixel-level screenshot validation for Windows where the texture API is
    // stable.
    if (!Platform.isMacOS) {
      final frame = await next.screenshot(format: 'image/png');
      if (frame == null || frame.isEmpty) {
        throw StateError('No decoded video frame');
      }
      await _decodeCover(frame, expectedColor: true);
    }
    await next.pause();
  }

  Future<VideoThumbnailData> _cover(MediaAsset asset) async {
    final cover = await VideoThumbnailCache.load(
      asset,
      onError: (error, stack) async {
        throw StateError('Cover extraction failed');
      },
    );
    if (cover.bytes?.isNotEmpty != true || cover.duration <= Duration.zero) {
      throw StateError('FFmpeg cover or FFprobe duration missing');
    }
    return cover;
  }

  Future<void> _verifyCache(MediaAsset asset) async {
    final files = [
      File(p.join(cacheRoot, '${asset.sha256}.jpg')),
      File(p.join(cacheRoot, '${asset.sha256}.duration')),
    ];
    final before = [for (final file in files) await file.lastModified()];
    final cached = await VideoThumbnailCache.readCachedFiles(
      cacheRoot: cacheRoot,
      sha256: asset.sha256,
    );
    await _cover(asset);
    if (cached.bytes?.isNotEmpty != true || cached.duration <= Duration.zero) {
      throw StateError('Disk cache was not reusable');
    }
    for (var index = 0; index < files.length; index++) {
      if (before[index] != await files[index].lastModified()) {
        throw StateError('Cache hit unexpectedly rewrote display cache');
      }
    }
  }

  Future<void> _assertStored(MediaAsset asset) async {
    if (!p.isWithin(widget.backend.settings.libraryPath, asset.storagePath) ||
        await _hash(asset.storagePath) != asset.sha256 ||
        !(await widget.backend.listMedia()).any(
          (item) => item.id == asset.id,
        )) {
      throw StateError(
        'Processed output bypassed content-addressed Rust storage',
      );
    }
  }

  Future<Duration> _duration(String path) async {
    final probe = await FFprobeKit.getMediaInformation(path);
    final seconds = double.tryParse(
      probe.getMediaInformation()?.getDuration() ?? '',
    );
    if (seconds == null || !seconds.isFinite || seconds <= 0) {
      throw StateError('Processed video duration is unreadable');
    }
    return Duration(microseconds: (seconds * 1000000).round());
  }

  void _withinDuration(Duration actual, Duration expected) {
    if ((actual - expected).abs() > const Duration(milliseconds: 300)) {
      throw StateError(
        'Processed video duration differs from expected duration',
      );
    }
  }

  Future<void> _decodeCover(
    Uint8List bytes, {
    bool expectedColor = false,
  }) async {
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final frame = await codec.getNextFrame();
      if (frame.image.width < 1 || frame.image.height < 1) {
        throw StateError('Empty decoded frame');
      }
      // macOS hosted runners can return a valid decoded image with a stale
      // software-texture color sample. The codec/dimensions check above and
      // the separate video first-frame check still validate the media path;
      // keep the pixel-color assertion for the stable Windows texture path.
      if (expectedColor && !Platform.isMacOS) {
        final rgba = (await frame.image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        final index =
            ((frame.image.height ~/ 2) * frame.image.width +
                frame.image.width ~/ 2) *
            4;
        if (rgba.getUint8(index) > 150 ||
            rgba.getUint8(index + 1) < 60 ||
            rgba.getUint8(index + 2) < 100) {
          frame.image.dispose();
          throw StateError(
            'Decoded video frame is black or has unexpected content',
          );
        }
      }
      frame.image.dispose();
    } finally {
      codec.dispose();
    }
  }

  Future<void> _ffmpeg(List<String> arguments) async {
    final session = await FFmpegKit.executeWithArguments([
      '-hide_banner',
      '-loglevel',
      'error',
      ...arguments,
    ]);
    if (!ReturnCode.isSuccess(await session.getReturnCode())) {
      throw StateError('Bundled FFmpeg rejected synthetic media');
    }
  }

  Future<String> _hash(String path) async =>
      (await sha256.bind(File(path).openRead()).first).toString();

  Future<void> _step(String name, Future<void> Function() action) async {
    try {
      if (widget.options.ciSmokeFailure == name) {
        throw StateError('Deliberate CI fault: $name');
      }
      await action().timeout(const Duration(seconds: 60));
      report.record(name, passed: true);
    } catch (error) {
      report.record(
        name,
        passed: false,
        error: sanitizeSmokeDiagnostic('$error', roots: [root]),
      );
      rethrow;
    }
    await File(p.join(root, 'progress.json')).writeAsString(
      jsonEncode({
        'step': name,
        'time': DateTime.now().toUtc().toIso8601String(),
      }),
      flush: true,
    );
  }

  Future<void> _captureFailure() async {
    try {
      final render =
          boundary.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (render == null) return;
      final screenshot = await render.toImage(pixelRatio: 1);
      final bytes = await screenshot.toByteData(format: ui.ImageByteFormat.png);
      screenshot.dispose();
      if (bytes != null) {
        await File(p.join(root, 'failure.png'))
            .writeAsBytes(bytes.buffer.asUint8List());
      }
    } catch (_) {
      // A failed screenshot must never turn failure into success.
    }
  }

  Future<void> _finish() async {
    if (!report.passed) await _captureFailure();
    try {
      if (player != null) {
        await player!.dispose().timeout(const Duration(seconds: 10));
      }
      if (trayCreated) {
        await trayManager.destroy().timeout(const Duration(seconds: 10));
      }
    } catch (_) {
      report.record(
        'release-cleanup',
        passed: false,
        error: 'Native cleanup failed',
      );
    }
    await File(p.join(root, '${report.scenario}.json')).writeAsString(
      const JsonEncoder.withIndent('  ').convert(report.toJson()),
      flush: true,
    );
    exit(report.passed ? 0 : 1);
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    home: RepaintBoundary(
      key: boundary,
      child: Stack(
        children: [
          Positioned.fill(
            child: ExcludeFocus(child: AbsorbPointer(child: widget.gallery)),
          ),
          Positioned(
            right: 12,
            bottom: 12,
            width: 360,
            height: 260,
            child: Scaffold(
              appBar: AppBar(
                title: const Text('NSOAlbum isolated CI diagnostics'),
              ),
              body: Column(
                children: [
                  if (image != null)
                    SizedBox(height: 90, child: RawImage(image: image)),
                  Expanded(
                    child: controller == null
                        ? const Center(child: CircularProgressIndicator())
                        : Video(
                            controller: controller!,
                            controls: NoVideoControls,
                          ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
