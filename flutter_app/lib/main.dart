import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'src/backend/app_backend.dart';
import 'src/backend/rust_backend.dart';
import 'src/l10n/app_localizations.dart';
import 'src/platform/windows_ime_context.dart';
import 'src/rust/settings.dart';
import 'src/state/automatic_sync_coordinator.dart';
import 'src/state/settings_controller.dart';
import 'src/state/sync_controller.dart';
import 'src/startup/startup_diagnostics.dart';
import 'src/startup/startup_options.dart';
import 'src/ui/home_shell.dart';
import 'src/ui/video_runtime.dart';

Future<void> main(List<String> arguments) async {
  final startupOptions = StartupOptions.parse(arguments);
  WidgetsFlutterBinding.ensureInitialized();
  StartupDiagnostics? diagnostics;
  try {
    diagnostics = await StartupDiagnostics.open(startupOptions);
    await diagnostics.phase(
      'process-start',
      'exe=${Platform.resolvedExecutable}; os=${Platform.operatingSystemVersion}; '
          'args=${arguments.where((arg) => arg.startsWith('--safe-mode')).join(',')}',
    );
  } catch (_) {
    // The regular backend logger will be created as soon as Rust initializes.
  }
  await diagnostics?.phase('flutter-binding-ready');
  WindowsImeContextCoordinator.instance.start(
    enabled: !startupOptions.disableIme && !startupOptions.safeMode,
  );
  await diagnostics?.phase(
    startupOptions.disableIme || startupOptions.safeMode
        ? 'ime-coordinator-disabled'
        : 'ime-coordinator-started',
  );
  await diagnostics?.phase(
    startupOptions.disableVideoThumbnails
        ? 'media-kit-disabled'
        : 'media-kit-deferred',
  );
  RustBackend? backend;
  Object? startupError;
  try {
    await diagnostics?.phase('rust-core-initialization-start');
    backend = await RustBackend.open(logger: diagnostics?.logger)
        .timeout(const Duration(seconds: 30));
    await diagnostics?.phase('rust-core-initialization-complete');
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      unawaited(
        backend!.logError(
          'Unhandled Flutter framework error',
          details.exception,
          details.stack,
        ),
      );
      unawaited(
        diagnostics?.failure(
              'flutter-framework-error',
              details.exception,
              details.stack,
            ) ??
            Future<void>.value(),
      );
    };
    PlatformDispatcher.instance.onError = (error, stackTrace) {
      unawaited(
        backend!.logError('Unhandled asynchronous error', error, stackTrace),
      );
      unawaited(
        diagnostics?.failure(
              'unhandled-asynchronous-error',
              error,
              stackTrace,
            ) ??
            Future<void>.value(),
      );
      return false;
    };
  } catch (error) {
    startupError = error;
    await diagnostics?.failure('rust-core-initialization', error);
  }
  await diagnostics?.phase('run-app-start');
  runApp(
    SquidAlbumApp(
      backend: backend,
      startupError: startupError,
      startupOptions: startupOptions,
      diagnostics: diagnostics,
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(diagnostics?.phase('first-frame') ?? Future<void>.value());
  });
}

class SquidAlbumApp extends StatefulWidget {
  const SquidAlbumApp({
    super.key,
    this.backend,
    this.startupError,
    this.startupOptions = const StartupOptions(),
    this.diagnostics,
  });

  final AppBackend? backend;
  final Object? startupError;
  final StartupOptions startupOptions;
  final StartupDiagnostics? diagnostics;

  @override
  State<SquidAlbumApp> createState() => _SquidAlbumAppState();
}

class DesktopWindowFrame extends StatelessWidget {
  const DesktopWindowFrame({
    super.key,
    required this.child,
    required this.title,
  });

  final Widget child;
  final String title;

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows ||
        Platform.environment.containsKey('FLUTTER_TEST')) {
      return child;
    }
    return Column(
      children: [
        DesktopTitleBar(title: title, iconAsset: 'assets/tray/app_icon.png'),
        Expanded(child: child),
      ],
    );
  }
}

class DesktopTitleBar extends StatefulWidget {
  const DesktopTitleBar({
    super.key,
    required this.title,
    required this.iconAsset,
  });

  final String title;
  final String iconAsset;

  @override
  State<DesktopTitleBar> createState() => _DesktopTitleBarState();
}

class _DesktopTitleBarState extends State<DesktopTitleBar> with WindowListener {
  bool maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    unawaited(_refreshMaximized());
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _refreshMaximized() async {
    if (!Platform.isWindows) return;
    final value = await windowManager.isMaximized();
    if (mounted) setState(() => maximized = value);
  }

  Future<void> _toggleMaximize() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
    await _refreshMaximized();
  }

  @override
  void onWindowMaximize() => unawaited(_refreshMaximized());

  @override
  void onWindowUnmaximize() => unawaited(_refreshMaximized());

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      key: const Key('desktop-titlebar'),
      height: 40,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surface,
          border: Border(
            bottom: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: .7),
            ),
          ),
        ),
        child: DragToMoveArea(
          child: Row(
            children: [
              const SizedBox(width: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(7),
                child: Image.asset(
                  widget.iconAsset,
                  key: const Key('desktop-titlebar-icon'),
                  width: 24,
                  height: 24,
                ),
              ),
              const SizedBox(width: 9),
              Text(
                widget.title,
                key: const Key('desktop-titlebar-title'),
                style: TextStyle(
                  fontFamily: 'SmileySans',
                  color: scheme.onSurface,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              WindowCaptionButton.minimize(
                key: const Key('desktop-titlebar-minimize'),
                brightness: Theme.of(context).brightness,
                onPressed: () => windowManager.minimize(),
              ),
              maximized
                  ? WindowCaptionButton.unmaximize(
                      key: const Key('desktop-titlebar-maximize'),
                      brightness: Theme.of(context).brightness,
                      onPressed: _toggleMaximize,
                    )
                  : WindowCaptionButton.maximize(
                      key: const Key('desktop-titlebar-maximize'),
                      brightness: Theme.of(context).brightness,
                      onPressed: _toggleMaximize,
                    ),
              WindowCaptionButton.close(
                key: const Key('desktop-titlebar-close'),
                brightness: Theme.of(context).brightness,
                onPressed: () => windowManager.close(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SquidAlbumAppState extends State<SquidAlbumApp>
    with WindowListener, TrayListener {
  final navigatorKey = GlobalKey<NavigatorState>();
  SettingsController? settings;
  SyncController? sync;
  AutomaticSyncCoordinator? automaticSync;
  bool desktopLifecycleReady = false;
  bool quitting = false;
  bool startupSyncStarted = false;

  bool get supportsDesktopLifecycle =>
      widget.backend is RustBackend &&
      (Platform.isWindows || Platform.isMacOS) &&
      !widget.startupOptions.disableDesktopLifecycle;

  @override
  void initState() {
    super.initState();
    final backend = widget.backend;
    if (backend != null) {
      settings = SettingsController(backend)..addListener(_settingsChanged);
      sync = SyncController(backend);
      automaticSync = AutomaticSyncCoordinator(backend, settings!, sync!);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (supportsDesktopLifecycle) {
          unawaited(
            widget.diagnostics?.runGuarded(
                  'desktop-lifecycle',
                  _initializeDesktopLifecycle,
                ) ??
                _initializeDesktopLifecycle(),
          );
        } else {
          unawaited(
            widget.diagnostics?.phase(
                  widget.startupOptions.disableDesktopLifecycle
                      ? 'desktop-lifecycle-disabled'
                      : 'desktop-lifecycle-unsupported',
                ) ??
                Future<void>.value(),
          );
        }
        if (Platform.isWindows &&
            !kDebugMode &&
            !widget.startupOptions.safeMode) {
          unawaited(_checkForUpdates(automatic: true));
        }
        if (!Platform.environment.containsKey('FLUTTER_TEST') &&
            !widget.startupOptions.disableVideoThumbnails &&
            !widget.startupOptions.safeMode) {
          unawaited(
            widget.diagnostics?.runGuarded(
                  'media-player-prewarm',
                  VideoRuntime.prewarm,
                ) ??
                VideoRuntime.prewarm(),
          );
        } else {
          unawaited(
            widget.diagnostics?.phase('media-player-prewarm-disabled') ??
                Future<void>.value(),
          );
        }
        if (!widget.startupOptions.disableAutomaticSync) {
          unawaited(
            widget.diagnostics?.runGuarded(
                  'automatic-sync-start',
                  () => automaticSync!.start(),
                ) ??
                automaticSync!.start(),
          );
          unawaited(_runStartupSync());
        } else {
          unawaited(
            widget.diagnostics?.phase('automatic-sync-disabled') ??
                Future<void>.value(),
          );
        }
      });
    }
  }

  @override
  void dispose() {
    settings?.removeListener(_settingsChanged);
    if (desktopLifecycleReady) {
      windowManager.removeListener(this);
      trayManager.removeListener(this);
      unawaited(trayManager.destroy());
    }
    automaticSync?.dispose();
    sync?.dispose();
    settings?.dispose();
    super.dispose();
  }

  Future<void> _initializeDesktopLifecycle() async {
    if (!supportsDesktopLifecycle || desktopLifecycleReady) return;
    try {
      await windowManager.ensureInitialized();
      if (Platform.isWindows) {
        await widget.diagnostics?.phase(
          'native-renderer-compatibility-enabled',
        );
        await windowManager.setTitleBarStyle(
          TitleBarStyle.hidden,
          windowButtonVisibility: false,
        );
        await widget.diagnostics?.phase('custom-titlebar-enabled');
      }
      windowManager.addListener(this);
      trayManager.addListener(this);
      await windowManager.setPreventClose(true);
      await trayManager.setIcon(
        Platform.isWindows
            ? 'assets/tray/app_icon.ico'
            : 'assets/tray/app_icon.png',
      );
      desktopLifecycleReady = true;
      await _updateDesktopChrome();
    } catch (error, stackTrace) {
      await widget.backend?.logError(
        'Failed to initialize desktop tray lifecycle',
        error,
        stackTrace,
      );
    }
  }

  void _settingsChanged() {
    if (desktopLifecycleReady) unawaited(_updateDesktopChrome());
  }

  Future<void> _updateDesktopChrome() async {
    final title = settings?.value.language == 'en' ? 'Fresh Album' : '鱿型相册';
    await windowManager.setTitle(title);
    await trayManager.setToolTip(title);
    await _updateTrayMenu();
  }

  Future<void> _updateTrayMenu() async {
    final english = settings?.value.language == 'en';
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'show', label: english ? 'Show main window' : '展示主页面'),
          MenuItem(key: 'sync', label: english ? 'Sync album now' : '立刻同步相册'),
          MenuItem.separator(),
          MenuItem(key: 'exit', label: english ? 'Exit' : '退出'),
        ],
      ),
    );
  }

  Future<void> _runStartupSync() async {
    if (widget.startupOptions.disableAutomaticSync) return;
    if (startupSyncStarted || settings?.value.autoSyncOnLaunch != true) return;
    startupSyncStarted = true;
    if (await widget.backend?.isSignedIn != true) return;
    await sync?.run();
  }

  Future<void> _checkForUpdates({required bool automatic}) async {
    final context = navigatorKey.currentContext;
    final backend = widget.backend;
    if (context == null || backend == null) return;
    await showLatestReleaseUpdate(
      context,
      automatic: automatic,
      onInstall: _installUpdate,
      onError: (error, stackTrace) => backend.logError(
        'Failed to check or install application update',
        error,
        stackTrace,
      ),
    );
  }

  Future<void> _installUpdate(File installer) async {
    await Process.start(
      installer.path,
      const [],
      mode: ProcessStartMode.detached,
    );
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (!desktopLifecycleReady) await _initializeDesktopLifecycle();
    await _quitApplication();
  }

  Future<void> _showMainWindow() async {
    if (!supportsDesktopLifecycle) return;
    await windowManager.show();
    await windowManager.restore();
    await windowManager.focus();
  }

  Future<void> _quitApplication() async {
    if (quitting) return;
    quitting = true;
    try {
      if (desktopLifecycleReady) {
        await trayManager.destroy();
        await windowManager.setPreventClose(false);
        await windowManager.close();
      }
    } catch (error, stackTrace) {
      quitting = false;
      await widget.backend?.logError(
        'Failed to exit application',
        error,
        stackTrace,
      );
    }
  }

  Future<void> _handleWindowClose() async {
    if (quitting) return;
    final controller = settings;
    if (controller == null) {
      await _quitApplication();
      return;
    }
    var behavior = controller.value.closeBehavior;
    if (behavior == 'ask') {
      final context = navigatorKey.currentContext;
      if (context == null) return;
      final result = await showDialog<_ClosePromptResult>(
        context: context,
        barrierDismissible: false,
        builder: (context) => const _CloseBehaviorDialog(),
      );
      if (result == null) return;
      behavior = result.behavior;
      if (result.remember) {
        try {
          await controller.save(
            _settingsWithCloseBehavior(controller.value, behavior),
          );
        } catch (_) {
          return;
        }
      }
    }
    if (behavior == 'minimize_to_tray') {
      await windowManager.hide();
      return;
    }
    await _quitApplication();
  }

  @override
  void onWindowClose() => unawaited(_handleWindowClose());

  @override
  void onTrayIconMouseDown() => unawaited(_showMainWindow());

  @override
  void onTrayIconRightMouseDown() => unawaited(
    // tray_manager still exposes the Windows foreground workaround here.
    // ignore: deprecated_member_use
    trayManager.popUpContextMenu(bringAppToFront: true),
  );

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        unawaited(_showMainWindow());
      case 'sync':
        unawaited(sync?.run());
      case 'exit':
        unawaited(_quitApplication());
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = settings;
    if (controller == null) {
      return MaterialApp(
        onGenerateTitle: (context) =>
            context.l10n.select(zh: '鱿型相册', en: 'Fresh Album'),
        debugShowCheckedModeBanner: false,
        theme: _themeFor('ocean'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: DesktopWindowFrame(
          title: 'Fresh Album',
          child: StartupErrorPage(error: widget.startupError),
        ),
      );
    }
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => MaterialApp(
        navigatorKey: navigatorKey,
        onGenerateTitle: (context) =>
            context.l10n.select(zh: '鱿型相册', en: 'Fresh Album'),
        debugShowCheckedModeBanner: false,
        theme: _themeFor(controller.value.theme),
        locale: Locale(controller.value.language),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: DesktopWindowFrame(
          title: controller.value.language == 'en' ? 'Fresh Album' : '鱿型相册',
          child: HomeShell(
            backend: widget.backend!,
            settings: controller,
            syncController: sync,
            onNintendoAccountChanged: widget.startupOptions.disableAutomaticSync
                ? null
                : automaticSync?.accountChanged,
            enableVideoFeatures: !widget.startupOptions.disableVideoThumbnails,
            enableMtpDetection: !widget.startupOptions.disableMtpDetection,
            startupDiagnostics: widget.diagnostics,
            onCheckForUpdates: () => _checkForUpdates(automatic: false),
            onInstallUpdate: _installUpdate,
          ),
        ),
      ),
    );
  }
}

class _ClosePromptResult {
  const _ClosePromptResult({required this.behavior, required this.remember});

  final String behavior;
  final bool remember;
}

class _CloseBehaviorDialog extends StatefulWidget {
  const _CloseBehaviorDialog();

  @override
  State<_CloseBehaviorDialog> createState() => _CloseBehaviorDialogState();
}

class _CloseBehaviorDialogState extends State<_CloseBehaviorDialog> {
  bool remember = false;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.l10n.select(zh: '关闭鱿型相册', en: 'Close Fresh Album')),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.l10n.select(
            zh: '你希望退出软件，还是让软件继续在系统托盘运行？',
            en: 'Would you like to exit, or keep the app running in the system tray?',
          ),
        ),
        const SizedBox(height: 12),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: remember,
          onChanged: (value) => setState(() => remember = value ?? false),
          title: Text(
            context.l10n.select(zh: '记住本次选择', en: 'Remember my choice'),
          ),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(context.l10n.select(zh: '取消', en: 'Cancel')),
      ),
      FilledButton.tonalIcon(
        onPressed: () => Navigator.pop(
          context,
          _ClosePromptResult(behavior: 'minimize_to_tray', remember: remember),
        ),
        icon: const Icon(Icons.minimize_rounded),
        label: Text(context.l10n.select(zh: '最小化到托盘', en: 'Minimize to tray')),
      ),
      FilledButton.icon(
        onPressed: () => Navigator.pop(
          context,
          _ClosePromptResult(behavior: 'exit', remember: remember),
        ),
        icon: const Icon(Icons.exit_to_app_rounded),
        label: Text(context.l10n.select(zh: '退出', en: 'Exit')),
      ),
    ],
  );
}

AppSettings _settingsWithCloseBehavior(
  AppSettings value,
  String closeBehavior,
) => AppSettings(
  proxyUrl: value.proxyUrl,
  libraryPath: value.libraryPath,
  theme: value.theme,
  language: value.language,
  galleryColumns: value.galleryColumns,
  galleryRows: value.galleryRows,
  showNotePreview: value.showNotePreview,
  showGameTag: value.showGameTag,
  compactTagDisplay: value.compactTagDisplay,
  autoPlayVideo: value.autoPlayVideo,
  autoSyncOnLaunch: value.autoSyncOnLaunch,
  closeBehavior: closeBehavior,
  syncPolicy: value.syncPolicy,
);

ThemeData _themeFor(String name) {
  final seed = switch (name) {
    'teal' => const Color(0xff159b88),
    'orange' => const Color(0xffdf754d),
    'purple' => const Color(0xff8562ca),
    'rose' => const Color(0xffcf5d82),
    _ => const Color(0xff5577e8),
  };
  final lightScheme = ColorScheme.fromSeed(seedColor: seed).copyWith(
    surface: const Color(0xffeef1f6),
    surfaceContainerLowest: const Color(0xffe9edf4),
    surfaceContainerLow: const Color(0xfff3f5f9),
    surfaceContainer: const Color(0xfff7f9fc),
    surfaceContainerHigh: const Color(0xfffbfcfe),
    surfaceContainerHighest: const Color(0xffffffff),
  );
  return ThemeData(
    fontFamily: 'SmileySans',
    textTheme: Typography.material2021().black.apply(fontFamily: 'SmileySans'),
    colorScheme: lightScheme,
    scaffoldBackgroundColor: const Color(0xffe9edf4),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(14)),
        side: BorderSide(color: const Color(0xffd7dfeb)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xfff7f9fc),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Color(0xffd7dfeb)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Color(0xffd7dfeb)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: seed, width: 1.6),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: const Color(0xfff7f9fc),
      selectedColor: lightScheme.primaryContainer,
      checkmarkColor: lightScheme.onPrimaryContainer,
      shape: const StadiumBorder(),
      side: const BorderSide(color: Color(0xffd7dfeb)),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      labelStyle: TextStyle(
        color: lightScheme.onSurfaceVariant,
        fontWeight: FontWeight.w600,
        fontFamily: 'SmileySans',
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        side: const BorderSide(color: Color(0xffdce4ef)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        ),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 72,
      indicatorShape: const StadiumBorder(),
      labelTextStyle: WidgetStatePropertyAll(
        TextStyle(fontWeight: FontWeight.w700, color: seed),
      ),
    ),
    useMaterial3: true,
  );
}

class StartupErrorPage extends StatelessWidget {
  const StartupErrorPage({super.key, this.error});

  final Object? error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline_rounded, size: 52),
                const SizedBox(height: 16),
                Text(
                  context.l10n.select(
                    zh: '鱿型相册核心初始化失败',
                    en: 'Failed to initialize Fresh Album core',
                  ),
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                SelectableText(
                  error?.toString() ??
                      context.l10n.select(zh: '未知错误', en: 'Unknown error'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
