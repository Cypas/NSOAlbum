import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';

String accountToolSafeDiagnostic(Object error) => error
    .toString()
    .replaceAll(
      RegExp(
        r'''\b(?:proxy-authorization|authorization|set-cookie|cookie)["']?\s*[:=][^\r\n]*''',
        caseSensitive: false,
      ),
      '[credential header redacted]',
    )
    .replaceAll(
      RegExp(r'''\bnpf[a-z0-9]*://[^\s<>"']+''', caseSensitive: false),
      '[authorization callback redacted]',
    )
    .replaceAll(
      RegExp(r'https?://[^\s?#]+[?#][^\s]+', caseSensitive: false),
      '[URL parameters redacted]',
    )
    .replaceAll(
      RegExp(
        r'''(?:[a-z_]*token|authorization|cookie)["'\s:=]+[^\s,;}\]]+''',
        caseSensitive: false,
      ),
      '[credential redacted]',
    )
    .replaceAllMapped(
      RegExp(r'\b([a-z][a-z0-9+.-]*://)[^/\s]*@', caseSensitive: false),
      (match) => '${match.group(1)}[proxy credentials redacted]@',
    );

String accountToolErrorText(AppLocalizations l10n, Object error) {
  final text = error.toString().toLowerCase();
  if (text.contains('proxy')) {
    return l10n.select(
      zh: '当前内嵌浏览器无法使用此代理配置。请调整应用代理后重试；页面不会绕过代理连接。',
      en: 'The embedded browser cannot use this proxy configuration. Update the app proxy and retry; it will not connect without the proxy.',
    );
  }
  if (text.contains('webview2')) {
    return l10n.select(
      zh: '请安装 Microsoft Edge WebView2 运行时后重试。',
      en: 'Install the Microsoft Edge WebView2 Runtime and try again.',
    );
  }
  if (text.contains('429') || text.contains('rate')) {
    return l10n.select(
      zh: '请求过于频繁，请一分钟后再试。',
      en: 'Too many requests. Try again in one minute.',
    );
  }
  if (text.contains('cancel')) {
    return l10n.select(zh: '操作已取消。', en: 'Operation cancelled.');
  }
  if (text.contains('membership')) {
    return l10n.select(
      zh: '此账号需要有效的 Nintendo Switch Online 会员。',
      en: 'This account needs an active Nintendo Switch Online membership.',
    );
  }
  if (text.contains('no equipment') ||
      text.contains('no_equipment') ||
      (text.contains('equipment') && text.contains('unavailable'))) {
    return l10n.select(
      zh: '此账号暂无可导出的装备资料。',
      en: 'There is no equipment available to export for this account.',
    );
  }
  if (text.contains('battle') || text.contains('player_id')) {
    return l10n.select(
      zh: '暂时无法获取玩家信息。请完成一场喷射战士 3 在线对战后重试。',
      en: 'Player information is unavailable. Complete an online Splatoon 3 battle and try again.',
    );
  }
  if (text.contains('registered') ||
      text.contains('204') ||
      text.contains('splatnet is not available for this account')) {
    return l10n.select(
      zh: '此账号尚无可用的喷射战士 3 在线资料。',
      en: 'No online Splatoon 3 profile is available for this account.',
    );
  }
  if (text.contains('auth') ||
      text.contains('token') ||
      text.contains('sign_in') ||
      text.contains('account')) {
    return l10n.select(
      zh: '账号登录状态不可用，请重新登录后重试。',
      en: 'The account session is unavailable. Sign in again and retry.',
    );
  }
  return l10n.select(
    zh: '请求未完成，请检查网络连接后重试。',
    en: 'The request could not be completed. Check your connection and retry.',
  );
}

class AccountToolError extends StatelessWidget {
  const AccountToolError({super.key, required this.error, this.onRetry});
  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Semantics(
        liveRegion: true,
        child: Text(
          accountToolErrorText(context.l10n, error),
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ),
      if (onRetry != null)
        TextButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh),
          label: Text(context.l10n.select(zh: '重试', en: 'Retry')),
        ),
      ExpansionTile(
        title: Text(context.l10n.select(zh: '诊断信息', en: 'Diagnostic details')),
        children: [
          SelectableText(accountToolSafeDiagnostic(error)),
          TextButton.icon(
            onPressed: () => Clipboard.setData(
              ClipboardData(text: accountToolSafeDiagnostic(error)),
            ),
            icon: const Icon(Icons.copy_outlined),
            label: Text(context.l10n.select(zh: '复制', en: 'Copy')),
          ),
        ],
      ),
    ],
  );
}
