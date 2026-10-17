import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../../app_branding.dart';
import '../../backend/app_backend.dart';
import '../../backend/device_sync/startup_lifecycle.dart';
import '../../l10n/app_localizations.dart';
import '../../startup/application_bootstrap.dart';

class DeviceSyncStartupApp extends StatefulWidget {
  const DeviceSyncStartupApp({
    super.key,
    required this.controller,
    required this.application,
    required this.theme,
    required this.frame,
  });
  final ApplicationBootstrap controller;
  final Widget Function(AppBackend) application;
  final ThemeData Function(String) theme;
  final Widget Function(Widget, String) frame;
  @override
  State<DeviceSyncStartupApp> createState() => _DeviceSyncStartupAppState();
}

class _DeviceSyncStartupAppState extends State<DeviceSyncStartupApp> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(widget.controller.start());
    });
  }

  @override
  void dispose() {
    // Disposal is only a fallback; native destruction uses the waiting owner.
    // The owner reports close failures while this widget may no longer exist.
    unawaited(widget.controller.close().catchError((Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      if (controller.phase == BootstrapPhase.ready) {
        return widget.application(controller.backend!);
      }
      final settings = controller.backend?.settings;
      final language =
          settings?.language ??
          (PlatformDispatcher.instance.locale.languageCode == 'zh'
              ? 'zh'
              : 'en');
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: widget.theme(settings?.theme ?? 'ocean'),
        locale: Locale(language),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: controller.phase == BootstrapPhase.localOnly
            ? Column(
                children: [
                  SafeArea(
                    bottom: false,
                    child: _DeferredNotice(controller: controller),
                  ),
                  Expanded(child: widget.application(controller.backend!)),
                ],
              )
            : widget.frame(
                DeviceSyncStartupPage(controller: controller),
                language == 'en' ? appEnglishName : appChineseName,
              ),
      );
    },
  );
}

class _DeferredNotice extends StatelessWidget {
  const _DeferredNotice({required this.controller});
  final ApplicationBootstrap controller;
  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.secondaryContainer,
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Wrap(
        spacing: 16,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            context.l10n.select(
              zh: '账号功能已暂停，完成恢复检查后可用。',
              en: 'Account features are paused until the recovery check completes.',
            ),
          ),
          TextButton.icon(
            onPressed: () => unawaited(controller.resumeRecovery()),
            icon: const Icon(Icons.restore),
            label: Text(
              context.l10n.select(zh: '检查并恢复', en: 'Check and restore'),
            ),
          ),
        ],
      ),
    ),
  );
}

class DeviceSyncStartupPage extends StatelessWidget {
  const DeviceSyncStartupPage({super.key, required this.controller});
  final ApplicationBootstrap controller;
  @override
  Widget build(BuildContext context) {
    final phase = controller.phase;
    final closeFailed = controller.closeError != null;
    final closing =
        phase == BootstrapPhase.closing || phase == BootstrapPhase.closed;
    final failed =
        closeFailed ||
        phase == BootstrapPhase.failed ||
        phase == BootstrapPhase.timedOut;
    final restoring = controller.startup?.phase == DeviceStartupPhase.restoring;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!failed)
                    const CircularProgressIndicator()
                  else
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 36,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  const SizedBox(height: 20),
                  Text(
                    closeFailed
                        ? context.l10n.select(
                            zh: '无法安全关闭',
                            en: 'Unable to close safely',
                          )
                        : closing
                        ? context.l10n.select(
                            zh: '正在安全关闭',
                            en: 'Closing safely',
                          )
                        : failed
                        ? context.l10n.select(
                            zh: '数据检查未完成',
                            en: 'Data check incomplete',
                          )
                        : restoring
                        ? context.l10n.select(
                            zh: '正在恢复数据',
                            en: 'Restoring data',
                          )
                        : context.l10n.select(
                            zh: '正在检查数据',
                            en: 'Checking data',
                          ),
                    style: Theme.of(context).textTheme.titleLarge,
                    textAlign: TextAlign.center,
                  ),
                  if (failed) ...[
                    const SizedBox(height: 12),
                    Text(
                      context.l10n.select(
                        zh: closeFailed
                            ? '数据操作未能安全结束，窗口将保持打开。请检查安全存储和图库是否可用。'
                            : controller.busy
                            ? '正在等待当前检查安全结束。'
                            : '数据仍受保护。请重试；若问题持续，请检查安全存储和图库是否可用。',
                        en: closeFailed
                            ? 'A data operation could not finish safely. The window will remain open. Check that protected storage and the library are available.'
                            : controller.busy
                            ? 'Waiting for the current check to finish safely.'
                            : 'Your data remains protected. Retry, or check that protected storage and the library are available.',
                      ),
                      textAlign: TextAlign.center,
                    ),
                    if (!closing) ...[
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: controller.busy
                            ? null
                            : () => unawaited(controller.start()),
                        icon: const Icon(Icons.refresh),
                        label: Text(context.l10n.select(zh: '重试', en: 'Retry')),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
