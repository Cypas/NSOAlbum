class StartupOptions {
  const StartupOptions({
    this.safeMode = false,
    this.disableVideo = false,
    this.disableIme = false,
    this.softwareRendering = false,
  });

  final bool safeMode;
  final bool disableVideo;
  final bool disableIme;
  final bool softwareRendering;

  bool get disableDesktopLifecycle => safeMode;
  bool get disableAutomaticSync => safeMode;
  bool get disableVideoThumbnails => safeMode || disableVideo;
  bool get disableMtpDetection => safeMode;

  static StartupOptions parse(Iterable<String> arguments) {
    var safeMode = false;
    var disableVideo = false;
    var disableIme = false;
    var softwareRendering = false;

    for (final argument in arguments) {
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

    return StartupOptions(
      safeMode: safeMode,
      disableVideo: disableVideo,
      disableIme: disableIme,
      softwareRendering: softwareRendering,
    );
  }
}
