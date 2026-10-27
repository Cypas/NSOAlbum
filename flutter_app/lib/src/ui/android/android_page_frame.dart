import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../backend/app_logger.dart';
import '../account_tools/account_tool_errors.dart';
import 'android_back_guard.dart';
import 'android_layout.dart';
import '../scroll_to_top_button.dart';

class AndroidPageFrame extends StatelessWidget {
  const AndroidPageFrame({
    super.key,
    required this.title,
    required this.child,
    this.actions,
    this.toolbarTitle,
    this.toolbarHeight,
    this.secondary = false,
    this.onBack,
    this.scrollController,
    this.scrollToTopTooltip,
  });

  final String title;
  final Widget child;
  final List<Widget>? actions;
  final Widget? toolbarTitle;
  final double? toolbarHeight;
  final bool secondary;
  final VoidCallback? onBack;
  final ScrollController? scrollController;
  final String? scrollToTopTooltip;

  @override
  Widget build(BuildContext context) {
    final hasAppBar = secondary || (actions?.isNotEmpty ?? false);
    return Scaffold(
      appBar: hasAppBar
          ? AppBar(
              automaticallyImplyLeading: false,
              toolbarHeight: toolbarHeight ?? (secondary ? 48 : null),
              leading: secondary
                  ? IconButton(
                      key: const Key('android-page-back'),
                      tooltip: context.l10n.select(zh: '返回', en: 'Back'),
                      icon: const Icon(Icons.arrow_back, size: 20),
                      onPressed: onBack ?? () => AndroidBackGuard.back(context),
                    )
                  : null,
              title:
                  toolbarTitle ??
                  (secondary
                      ? Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        )
                      : null),
              actions: actions,
            )
          : null,
      body: SafeArea(
        top: !hasAppBar,
        child: Stack(
          children: [
            child,
            if (scrollController != null && scrollToTopTooltip != null)
              Positioned(
                right: 16,
                bottom: 18,
                child: ScrollToTopButton(
                  controller: scrollController!,
                  tooltip: scrollToTopTooltip!,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class AndroidPageList extends StatelessWidget {
  const AndroidPageList({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => ListView(
    padding: EdgeInsets.all(
      androidPagePadding(MediaQuery.sizeOf(context).width),
    ),
    children: [
      for (final child in children)
        Padding(padding: const EdgeInsets.only(bottom: 12), child: child),
    ],
  );
}

String androidSafeDiagnostic(Object error) => sanitizeDiagnostic(
  error.toString().replaceAll(
    RegExp(r'npf[^:\s]+://[^\s]+'),
    '[callback redacted]',
  ),
);

String androidReadableError(BuildContext context, Object error) {
  final condition = nintendoConditionText(context.l10n, error);
  if (condition != null) return condition;
  final value = error.toString().toLowerCase();
  if (value.contains('storage') && value.contains('unavailable')) {
    return context.l10n.select(
      zh: '图库存储不可用，请重新连接存储设备后再试。',
      en: 'Library storage is unavailable. Reconnect it and try again.',
    );
  }
  if (value.contains('network') ||
      value.contains('socket') ||
      value.contains('dns') ||
      value.contains('timeout')) {
    return context.l10n.select(
      zh: '网络请求失败，请检查连接后重试。',
      en: 'Network request failed. Check your connection and try again.',
    );
  }
  if (value.contains('rate limited') || value.contains('429')) {
    return context.l10n.select(
      zh: '请求过于频繁，一分钟后再试。',
      en: 'Too many requests. Try again in one minute.',
    );
  }
  if (value.contains('cancelled') || value.contains('canceled')) {
    return context.l10n.select(zh: '操作已取消。', en: 'Operation cancelled.');
  }
  if (value.contains('pending') && value.contains('sign')) {
    return context.l10n.select(
      zh: '请先打开登录页面后再输入回调地址。',
      en: 'Open the sign-in page before entering the callback URL.',
    );
  }
  if (value.contains('nxapi')) {
    if (value.contains('incompatible_client') ||
        value.contains('compatibility identifier is outdated')) {
      return context.l10n.select(
        zh: 'Nintendo 登录服务协议已更新，请更新应用后重试。',
        en: 'The Nintendo sign-in service protocol has changed. Update the app and try again.',
      );
    }
    return context.l10n.select(
      zh: 'Nintendo 登录服务请求失败，请稍后重试。',
      en: 'The Nintendo sign-in service request failed. Please try again later.',
    );
  }
  if (value.contains('authentication') ||
      value.contains('sign in') ||
      value.contains('token')) {
    return context.l10n.select(
      zh: '登录状态无效，请重新登录。',
      en: 'Sign-in is no longer valid. Please sign in again.',
    );
  }
  return context.l10n.select(
    zh: '操作未完成，请重试。',
    en: 'The operation could not be completed. Please try again.',
  );
}

final _androidNotices = <OverlayState, OverlayEntry>{};
final _androidNoticeMessages = <OverlayState, String>{};

void androidMessage(BuildContext context, Object error, {bool? isError}) {
  if (!context.mounted) return;
  // flutter_rust_bridge returns Rust errors as strings. Success must be explicit;
  // an explicit severity also allows callers to supply already localized text.
  final failed = isError ?? true;
  final message = failed && (error is! String || isError == null)
      ? androidReadableError(context, error)
      : androidSafeDiagnostic(error);
  final diagnostic = failed ? androidSafeDiagnostic(error) : null;
  final overlay = Overlay.of(context, rootOverlay: true);
  if (_androidNoticeMessages[overlay] == message &&
      _androidNotices[overlay]?.mounted == true) {
    return;
  }
  final previous = _androidNotices.remove(overlay);
  if (previous?.mounted == true) previous!.remove();
  late final OverlayEntry entry;
  final top =
      MediaQuery.paddingOf(context).top +
      MediaQuery.sizeOf(context).height * .23;
  void close() {
    if (entry.mounted) entry.remove();
    if (identical(_androidNotices[overlay], entry)) {
      _androidNotices.remove(overlay);
      _androidNoticeMessages.remove(overlay);
    }
  }

  entry = OverlayEntry(
    builder: (_) => _AndroidNotice(
      message: message,
      diagnostic: diagnostic,
      failed: failed,
      top: top,
      duration: Duration(seconds: failed ? 8 : 2),
      onClose: close,
      onDispose: () {
        if (identical(_androidNotices[overlay], entry)) {
          _androidNotices.remove(overlay);
          _androidNoticeMessages.remove(overlay);
        }
      },
    ),
  );
  _androidNotices[overlay] = entry;
  _androidNoticeMessages[overlay] = message;
  overlay.insert(entry);
}

class _AndroidNotice extends StatefulWidget {
  const _AndroidNotice({
    required this.message,
    required this.diagnostic,
    required this.failed,
    required this.top,
    required this.duration,
    required this.onClose,
    required this.onDispose,
  });
  final String message;
  final String? diagnostic;
  final bool failed;
  final double top;
  final Duration duration;
  final VoidCallback onClose;
  final VoidCallback onDispose;
  @override
  State<_AndroidNotice> createState() => _AndroidNoticeState();
}

class _AndroidNoticeState extends State<_AndroidNotice> {
  Timer? timer;
  @override
  void initState() {
    super.initState();
    timer = Timer(widget.duration, widget.onClose);
  }

  @override
  void dispose() {
    timer?.cancel();
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Positioned(
      top: widget.top,
      left: 20,
      right: 20,
      child: Material(
        key: const Key('android-notice-bubble'),
        elevation: 8,
        borderRadius: BorderRadius.circular(16),
        color: widget.failed
            ? colors.errorContainer
            : colors.secondaryContainer,
        child: Semantics(
          liveRegion: true,
          child: Padding(
            padding: const EdgeInsets.only(left: 16, top: 8, bottom: 8),
            child: Row(
              children: [
                Icon(
                  widget.failed
                      ? Icons.error_outline
                      : Icons.check_circle_outline,
                  size: 22,
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(widget.message)),
                if (widget.failed && widget.diagnostic != null)
                  IconButton(
                    key: const Key('android-notice-copy-diagnostic'),
                    tooltip: context.l10n.select(
                      zh: '复制诊断信息',
                      en: 'Copy diagnostic',
                    ),
                    onPressed: () => Clipboard.setData(
                      ClipboardData(text: widget.diagnostic!),
                    ),
                    icon: const Icon(Icons.copy_outlined, size: 20),
                  ),
                IconButton(
                  tooltip: context.l10n.select(
                    zh: '隐藏提示',
                    en: 'Dismiss message',
                  ),
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.close, size: 20),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
