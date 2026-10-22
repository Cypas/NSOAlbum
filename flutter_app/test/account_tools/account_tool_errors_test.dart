import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/ui/account_tools/account_tool_errors.dart';

void main() {
  test(
    'copying OAuth failure details keeps endpoint and codes but no credentials',
    () {
      final diagnostic = accountToolSafeDiagnostic(
        'network error: stage=nxapi_oauth reason=timeout '
        'url=https://nxapi-auth.fancy.org.uk/api/oauth/token '
        'code_kind=none code=none refresh_token=PRIVATE',
      );
      expect(diagnostic, contains('/api/oauth/token code_kind=none code=none'));
      expect(diagnostic, isNot(contains('PRIVATE')));
    },
  );

  test('NXAPI network timeouts never ask for a new sign-in or a browser proxy change', () {
    const error =
        'network error: stage=nxapi_oauth reason=timeout proxy=default elapsed_ms=30000';
    for (final language in ['zh', 'en']) {
      final l10n = AppLocalizations(Locale(language));
      final message = accountToolErrorText(l10n, error);
      expect(message, contains('NXAPI'));
      expect(
        message.toLowerCase(),
        contains(language == 'zh' ? '超时' : 'timed out'),
      );
      expect(message, isNot(contains('重新登录')));
      expect(message, isNot(contains('Sign in again')));
      expect(message, isNot(contains('内嵌浏览器')));
      expect(message, isNot(contains('embedded browser')));
      expect(nintendoConditionText(l10n, error), message);
    }
  });

  test('all known service conditions avoid generic sign-in advice', () {
    for (final code in [
      'splatnet_user_not_registered',
      'nso_membership_required',
      'nintendo_age_restricted',
      'nintendo_client_update_required',
      'nintendo_service_maintenance',
      'splatnet_service_unavailable',
      'nintendo_service_unavailable',
      'nintendo_service_closed',
      'nintendo_sender_friend_limit',
      'nintendo_receiver_friend_limit',
      'nintendo_friend_request_pending',
      'nintendo_already_friend',
      'nintendo_friend_request_blocked',
      'nintendo_request_forbidden',
      'splatnet_request_invalid',
      'nintendo_request_invalid',
      'splatnet_response_invalid',
      'nintendo_response_invalid',
    ]) {
      for (final language in ['zh', 'en']) {
        final l10n = AppLocalizations(Locale(language));
        final message = nintendoConditionText(
          l10n,
          'provider failed: $code (status 999)',
        );
        expect(message, isNotNull, reason: code);
        expect(message, isNot(contains(code)));
        expect(message, isNot(contains('重新登录')));
        expect(message, isNot(contains('Sign in again')));
        expect(accountToolErrorText(l10n, code), message);
      }
    }
    expect(
      nintendoConditionText(const AppLocalizations(Locale('en')), 'HTTP 499'),
      isNull,
      reason: 'An unrelated HTTP status alone is not evidence of a ban.',
    );
  });

  test(
    'known account restrictions show specific guidance in both languages',
    () {
      for (final (code, zh, en) in [
        (
          'nintendo_sign_in_required',
          '任天堂登录授权已失效，请重新登录该账号。',
          'Nintendo sign-in authorization is no longer valid. Sign in to this account again.',
        ),
        (
          'splatnet_access_restricted',
          '此账号的鱿鱼圈访问受限，可能已被封禁。请以任天堂官方提示为准。',
          'SplatNet access is restricted for this account and may be suspended. Check Nintendo’s official notices.',
        ),
        (
          'nintendo_account_not_linked',
          '此 Nintendo Account 尚未关联 Switch 用户。请在主机上完成关联后重试。',
          'This Nintendo Account is not linked to a Switch user. Link it on your console and try again.',
        ),
        (
          'nintendo_user_not_activated',
          '此账号尚未完成 Nintendo Switch Online 初始化。请先在官方应用中完成设置。',
          'Nintendo Switch Online setup is incomplete for this account. Complete setup in the official app first.',
        ),
        (
          'nintendo_account_disabled',
          '此 Nintendo Account 已被停用。请查看任天堂官方账号状态或联系官方支持。',
          'This Nintendo Account is disabled. Check its status with Nintendo or contact official support.',
        ),
        (
          'splatnet_version_outdated',
          '鱿鱼圈暂不接受当前网页版本。请稍后刷新；持续失败时检查应用更新。',
          'SplatNet no longer accepts this web version. Refresh later, or check for an app update if it persists.',
        ),
        (
          'splatnet_service_maintenance',
          '鱿鱼圈正在维护，请稍后重试。',
          'SplatNet is under maintenance. Try again later.',
        ),
      ]) {
        expect(
          accountToolErrorText(const AppLocalizations(Locale('zh')), code),
          zh,
        );
        expect(
          accountToolErrorText(const AppLocalizations(Locale('en')), code),
          en,
        );
      }
    },
  );

  test(
    'local profile access failure is not described as a network failure',
    () {
      const error = FileSystemException(
        'Deletion failed',
        r'C:\Users\synthetic-owner\AppData\Local\session-private',
        OSError('Access denied', 5),
      );
      expect(
        accountToolErrorText(const AppLocalizations(Locale('zh')), error),
        '无法完成本地文件操作。请稍后重试。',
      );
      expect(
        accountToolErrorText(const AppLocalizations(Locale('en')), error),
        'The local file operation could not be completed. Try again shortly.',
      );
    },
  );

  test(
    'local filesystem diagnostics redact the path but retain the OS code',
    () {
      final diagnostic = accountToolSafeDiagnostic(
        const FileSystemException(
          'Deletion failed',
          r'C:\Users\synthetic-owner\AppData\Local\session-private',
          OSError('Access denied', 5),
        ),
      );
      expect(diagnostic, isNot(contains('synthetic-owner')));
      expect(diagnostic, isNot(contains('session-private')));
      expect(diagnostic, contains('errno = 5'));
    },
  );

  test('an unavailable SplatNet profile does not request another sign-in', () {
    const error =
        'SplatNet is not available for this account; play online first';
    expect(
      accountToolErrorText(const AppLocalizations(Locale('zh')), error),
      '此账号尚无可用的喷射战士 3 在线资料。',
    );
    expect(
      accountToolErrorText(const AppLocalizations(Locale('en')), error),
      'No online Splatoon 3 profile is available for this account.',
    );
  });

  test('missing exportable equipment is not shown as a network error', () {
    for (final error in [
      'No equipment is available to export; refresh SplatNet after obtaining equipment',
      'SplatNet equipment or player identity is unavailable',
    ]) {
      expect(
        accountToolErrorText(const AppLocalizations(Locale('zh')), error),
        '此账号暂无可导出的装备资料。',
      );
      expect(
        accountToolErrorText(const AppLocalizations(Locale('en')), error),
        'There is no equipment available to export for this account.',
      );
    }
  });

  test(
    'header diagnostics never expose bearer tokens or secondary cookies',
    () {
      final text = accountToolSafeDiagnostic(
        'network error\n'
        'Authorization: Bearer bearer-secret\n'
        'Cookie: _gtoken=cookie-one; bullet=cookie-two\n'
        'Set-Cookie: session=set-cookie-secret; Path=/\n'
        'retry after 60 seconds',
      );
      for (final secret in [
        'bearer-secret',
        'cookie-one',
        'cookie-two',
        'set-cookie-secret',
      ]) {
        expect(text, isNot(contains(secret)));
      }
      expect(text, contains('retry after 60 seconds'));
    },
  );

  test('diagnostics remove custom callbacks and proxy userinfo for any scheme', () {
    final text = accountToolSafeDiagnostic(
      'redirect npf71b963c1b7b6d119://auth#session_token_code=callback-secret '
      'proxy socks5://proxy-user:proxy-password@127.0.0.1:7890 '
      'proxy http://http-user:http-password@127.0.0.1:7890',
    );
    for (final secret in [
      'npf71b963c1b7b6d119',
      'callback-secret',
      'proxy-user',
      'proxy-password',
      'http-user',
      'http-password',
    ]) {
      expect(text, isNot(contains(secret)));
    }
  });

  test('copiable diagnostics redact all game and account credentials', () {
    final text = accountToolSafeDiagnostic(
      'gtoken=secret-one bullet_token:secret-two '
      'game_web_token="secret-three" session_token=secret-four '
      'https://example.org/api?token=secret-five#private',
    );
    for (final secret in [
      'secret-one',
      'secret-two',
      'secret-three',
      'secret-four',
      'secret-five',
    ]) {
      expect(text, isNot(contains(secret)));
    }
  });
}
