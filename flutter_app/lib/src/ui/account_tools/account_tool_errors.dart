import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../backend/app_logger.dart';

String accountToolSafeDiagnostic(Object error) => sanitizeDiagnostic(
  (error is FileSystemException && error.path?.isNotEmpty == true
          ? error.toString().replaceAll(error.path!, '<redacted-path>')
          : error.toString())
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
          r'''(?<![A-Za-z0-9_./])(?:[a-z_]*token|authorization|cookie)["'\s:=]+[^\s,;}\]]+''',
          caseSensitive: false,
        ),
        '[credential redacted]',
      )
      .replaceAllMapped(
        RegExp(r'\b([a-z][a-z0-9+.-]*://)[^/\s]*@', caseSensitive: false),
        (match) => '${match.group(1)}[proxy credentials redacted]@',
      ),
);

String? nintendoConditionText(AppLocalizations l10n, Object error) {
  final text = error.toString().toLowerCase();
  if (text.contains('network error:')) {
    final stage = RegExp(r'\bstage=([a-z_]+)\b').firstMatch(text)?.group(1);
    final service = switch (stage) {
      'nxapi' ||
      'nxapi_config' ||
      'nxapi_oauth' ||
      'nxapi_attestation' ||
      'nxapi_encrypt' ||
      'nxapi_decrypt' => l10n.select(zh: 'NXAPI 服务', en: 'The NXAPI service'),
      'nintendo_oauth' || 'nintendo_profile' => l10n.select(
        zh: 'Nintendo 登录服务',
        en: 'The Nintendo sign-in service',
      ),
      'coral' => 'Nintendo Switch Online',
      'splatnet' => l10n.select(zh: '鱿鱼圈', en: 'SplatNet'),
      _ => l10n.select(zh: '网络请求', en: 'The network request'),
    };
    return text.contains('reason=timeout')
        ? l10n.select(
            zh: '$service连接超时，请检查网络或代理后重试。',
            en: '$service timed out. Check your connection or proxy and retry.',
          )
        : l10n.select(
            zh: '$service连接失败，请检查网络或代理后重试。',
            en: '$service could not connect. Check your connection or proxy and retry.',
          );
  }
  final code = RegExp(r'\b(?:splatnet|nintendo|nso)_[a-z_]+\b')
      .allMatches(text)
      .map((match) => match[0])
      .firstOrNull;
  final messages = switch (code) {
    'splatnet_access_restricted' => (
      '此账号的鱿鱼圈访问受限，可能已被封禁。请以任天堂官方提示为准。',
      'SplatNet access is restricted for this account and may be suspended. Check Nintendo’s official notices.',
    ),
    'nintendo_account_not_linked' => (
      '此 Nintendo Account 尚未关联 Switch 用户。请在主机上完成关联后重试。',
      'This Nintendo Account is not linked to a Switch user. Link it on your console and try again.',
    ),
    'nintendo_user_not_activated' => (
      '此账号尚未完成 Nintendo Switch Online 初始化。请先在官方应用中完成设置。',
      'Nintendo Switch Online setup is incomplete for this account. Complete setup in the official app first.',
    ),
    'nintendo_account_disabled' => (
      '此 Nintendo Account 已被停用。请查看任天堂官方账号状态或联系官方支持。',
      'This Nintendo Account is disabled. Check its status with Nintendo or contact official support.',
    ),
    'nintendo_sign_in_required' => (
      '任天堂登录授权已失效，请重新登录该账号。',
      'Nintendo sign-in authorization is no longer valid. Sign in to this account again.',
    ),
    'splatnet_version_outdated' => (
      '鱿鱼圈暂不接受当前网页版本。请稍后刷新；持续失败时检查应用更新。',
      'SplatNet no longer accepts this web version. Refresh later, or check for an app update if it persists.',
    ),
    'splatnet_user_not_registered' => (
      '此账号尚无可用的喷射战士 3 在线资料。请先在游戏中完成在线游玩后重试。',
      'No online Splatoon 3 profile is available for this account. Play online in the game first and try again.',
    ),
    'nso_membership_required' => (
      '此账号需要有效的 Nintendo Switch Online 会员。',
      'This account needs an active Nintendo Switch Online membership.',
    ),
    'nintendo_age_restricted' => (
      '此功能受到账号年龄或家长控制限制，请检查任天堂账号设置。',
      'Account age or parental controls restrict this feature. Check your Nintendo Account settings.',
    ),
    'nintendo_client_update_required' => (
      'Nintendo Switch Online 服务要求更新客户端，请检查应用更新。',
      'Nintendo Switch Online requires an updated client. Check for an app update.',
    ),
    'splatnet_service_maintenance' => (
      '鱿鱼圈正在维护，请稍后重试。',
      'SplatNet is under maintenance. Try again later.',
    ),
    'nintendo_service_maintenance' => (
      'Nintendo Switch Online 服务正在维护，请稍后重试。',
      'Nintendo Switch Online is under maintenance. Try again later.',
    ),
    'splatnet_service_unavailable' || 'nintendo_service_unavailable' => (
      '任天堂服务暂不可用，请稍后重试。',
      'The Nintendo service is temporarily unavailable. Try again later.',
    ),
    'nintendo_service_closed' => (
      '此 Nintendo Switch Online 服务已停止提供。',
      'This Nintendo Switch Online service is closed.',
    ),
    'nintendo_sender_friend_limit' => (
      '你的好友数量已达上限，请先在主机上管理好友。',
      'Your friend list is full. Manage your friends on your console first.',
    ),
    'nintendo_receiver_friend_limit' => (
      '对方的好友数量已达上限，暂时无法添加。',
      'The other user’s friend list is full.',
    ),
    'nintendo_friend_request_pending' => (
      '好友申请已存在，请等待对方处理。',
      'A friend request is already pending.',
    ),
    'nintendo_already_friend' => ('你们已经是好友。', 'You are already friends.'),
    'nintendo_friend_request_blocked' => (
      '当前无法向此用户发送好友申请，请检查主机上的屏蔽设置。',
      'A friend request cannot be sent to this user. Check the blocking settings on your console.',
    ),
    'nintendo_request_forbidden' => (
      '此账号无权执行该操作，请检查官方账号及隐私设置。',
      'This account is not permitted to perform this action. Check the official account and privacy settings.',
    ),
    'splatnet_request_invalid' || 'nintendo_request_invalid' => (
      '任天堂服务未接受本次请求，请检查输入或应用更新后重试。',
      'The Nintendo service did not accept this request. Check your input or app updates and try again.',
    ),
    'splatnet_response_invalid' || 'nintendo_response_invalid' => (
      '任天堂服务返回了无法识别的数据，请稍后重试。',
      'The Nintendo service returned an unrecognized response. Try again later.',
    ),
    'nintendo_request_failed' => (
      'Nintendo Switch Online 未能完成本次操作，请稍后重试。',
      'Nintendo Switch Online could not complete this operation. Try again later.',
    ),
    _ => null,
  };
  return messages == null
      ? null
      : l10n.select(zh: messages.$1, en: messages.$2);
}

String accountToolErrorText(AppLocalizations l10n, Object error) {
  final condition = nintendoConditionText(l10n, error);
  if (condition != null) return condition;
  if (error is FileSystemException) {
    return l10n.select(
      zh: '无法完成本地文件操作。请稍后重试。',
      en: 'The local file operation could not be completed. Try again shortly.',
    );
  }
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
