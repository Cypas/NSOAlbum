import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/ui/account_tools/account_tool_errors.dart';

void main() {
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
