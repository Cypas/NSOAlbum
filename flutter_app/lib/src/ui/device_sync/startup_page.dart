import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../../app_branding.dart';
import '../../backend/app_backend.dart';
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
  Widget? _readyApplication;
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
    if (widget.controller.phase != BootstrapPhase.closing &&
        widget.controller.phase != BootstrapPhase.closed) {
      unawaited(widget.controller.close().catchError((Object _) {}));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final settings = controller.backend?.settings;
      final language =
          settings?.language ??
          (PlatformDispatcher.instance.locale.languageCode == 'zh'
              ? 'zh'
              : 'en');
      final closing =
          controller.phase == BootstrapPhase.closing ||
          controller.phase == BootstrapPhase.closed;
      if (controller.phase == BootstrapPhase.ready ||
          (_readyApplication != null && closing)) {
        _readyApplication ??= widget.application(controller.backend!);
        return Stack(
          fit: StackFit.expand,
          textDirection: TextDirection.ltr,
          children: [
            AbsorbPointer(
              absorbing: closing,
              child: ExcludeFocus(
                excluding: closing,
                child: _readyApplication!,
              ),
            ),
            if (closing &&
                (controller.closeFeedback || controller.closeError != null))
              Positioned(
                left: 16,
                right: 16,
                bottom: 24,
                child: SafeArea(
                  child: Center(
                    child: Theme(
                      data: widget.theme(settings?.theme ?? 'ocean'),
                      child: _CloseNotice(
                        language: language,
                        failed: controller.closeError != null,
                        onRetry: controller.requestCloseRetry,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      }
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

class _CloseNotice extends StatelessWidget {
  const _CloseNotice({
    required this.language,
    required this.failed,
    required this.onRetry,
  });
  final String language;
  final bool failed;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.ltr,
    child: Semantics(
      liveRegion: true,
      child: Material(
        elevation: 6,
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (failed)
                      const Icon(Icons.warning_amber_rounded)
                    else
                      const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        language == 'zh'
                            ? failed
                                  ? '当前操作尚未安全结束，窗口将保持打开。'
                                  : '正在结束当前操作'
                            : failed
                            ? 'The current operation could not finish safely. The window will remain open.'
                            : 'Finishing current operations',
                      ),
                    ),
                  ],
                ),
                if (failed && onRetry != null)
                  TextButton(
                    onPressed: onRetry,
                    child: Text(language == 'zh' ? '重试关闭' : 'Retry closing'),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
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
    final interrupted = controller.startup?.interruptedRecovery == true;
    final showFeedback =
        failed || interrupted || (closing && controller.closeFeedback);
    if (!showFeedback) {
      // Normal core preparation/recovery still runs before the gallery is
      // usable, but a branded spinner screen adds no actionable information.
      // Keep the window surface stable and reserve visible feedback for
      // interrupted recovery, failures, or a close that takes unusually long.
      return Scaffold(
        body: ColoredBox(color: Theme.of(context).scaffoldBackgroundColor),
      );
    }
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
                    _feedbackTitle(
                      context,
                      closeFailed: closeFailed,
                      closing: closing,
                      failed: failed,
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

  String _feedbackTitle(
    BuildContext context, {
    required bool closeFailed,
    required bool closing,
    required bool failed,
  }) {
    if (closeFailed) {
      return context.l10n.select(zh: '无法安全关闭', en: 'Unable to close safely');
    }
    if (closing && controller.closeFeedback) {
      return context.l10n.select(
        zh: '正在结束当前操作',
        en: 'Finishing current operations',
      );
    }
    if (failed) {
      return context.l10n.select(zh: '数据检查未完成', en: 'Data check incomplete');
    }
    return context.l10n.select(
      zh: '上次同步未正常完成，正在校验数据',
      en: 'The previous sync did not finish. Checking data.',
    );
  }
}
