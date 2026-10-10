import 'package:path/path.dart' as p;

class StartupOptions {
  const StartupOptions({
    this.safeMode = false,
    this.disableVideo = false,
    this.disableIme = false,
    this.softwareRendering = false,
    this.ciSmokeRoot,
    this.ciSmokeScenario = 'normal',
    this.ciSmokeFailure,
  });

  final bool safeMode;
  final bool disableVideo;
  final bool disableIme;
  final bool softwareRendering;
  final String? ciSmokeRoot;
  final String ciSmokeScenario;
  final String? ciSmokeFailure;
  bool get ciSmoke => ciSmokeRoot != null;

  bool get disableDesktopLifecycle => safeMode || ciSmoke;
  bool get disableAutomaticSync => safeMode || ciSmoke;
  bool get disableVideoThumbnails => safeMode || disableVideo;
  bool get disableMtpDetection => safeMode || ciSmoke;

  static StartupOptions parse(Iterable<String> arguments) {
    var safeMode = false;
    var disableVideo = false;
    var disableIme = false;
    var softwareRendering = false;
    var smoke = false;
    String? root;
    var scenario = 'normal';
    String? failure;

    for (final argument in arguments) {
      if (argument == '--ci-smoke') smoke = true;
      if (argument.startsWith('--ci-smoke-root=')) {
        root = argument.substring('--ci-smoke-root='.length);
      }
      if (argument.startsWith('--ci-smoke-scenario=')) {
        scenario = argument.substring('--ci-smoke-scenario='.length);
      }
      if (argument.startsWith('--ci-smoke-fail=')) {
        failure = argument.substring('--ci-smoke-fail='.length);
      }
      switch (argument.trim().toLowerCase()) {
        case '--safe-mode':
          safeMode = true;
        case '--safe-mode=no-video':
          disableVideo = true;
        case '--safe-mode=no-ime':
          disableIme = true;
        case '--safe-mode=software':
          softwareRendering = true;
      }
    }
    if (smoke &&
        (root == null || !p.isAbsolute(root) || root == p.rootPrefix(root))) {
      throw const FormatException(
        'CI smoke requires --ci-smoke-root=<absolute isolated directory>',
      );
    }
    if (!smoke && (root != null || failure != null || scenario != 'normal')) {
      throw const FormatException('Diagnostic parameters require --ci-smoke');
    }
    if (!const ['normal', 'reopen', 'safe'].contains(scenario)) {
      throw const FormatException('Unknown CI smoke scenario');
    }
    if (smoke && (scenario == 'safe') != safeMode) {
      throw const FormatException(
        'Safe smoke requires --safe-mode and safe scenario together',
      );
    }

    return StartupOptions(
      safeMode: safeMode,
      disableVideo: disableVideo,
      disableIme: disableIme,
      softwareRendering: softwareRendering,
      ciSmokeRoot: smoke ? root : null,
      ciSmokeScenario: scenario,
      ciSmokeFailure: failure,
    );
  }
}
