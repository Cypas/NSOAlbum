import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/ui/account_tools/splatnet_policy.dart';

void main() {
  test('only the exact HTTPS game origin may receive a credential', () {
    for (final url in [
      'https://api.lp1.av5ja.srv.nintendo.net/',
      'https://api.lp1.av5ja.srv.nintendo.net:443/home?lang=zh-CN',
    ]) {
      expect(SplatNetPolicy.isOfficial(Uri.parse(url)), isTrue);
    }
    for (final url in [
      'http://api.lp1.av5ja.srv.nintendo.net/',
      'https://api.lp1.av5ja.srv.nintendo.net.attacker.invalid/',
      'https://api.lp1.av5ja.srv.nintendo.net:8443/',
      'https://user@api.lp1.av5ja.srv.nintendo.net/',
      'file:///tmp/index.html',
      'https://attacker.invalid/',
    ]) {
      expect(SplatNetPolicy.isOfficial(Uri.parse(url)), isFalse);
    }
  });

  test('external navigation never forwards URL credentials or parameters', () {
    expect(
      SplatNetPolicy.externalUrl(
        Uri.parse('https://example.org/help?gtoken=secret#private'),
      ).toString(),
      'https://example.org/help',
    );
    expect(
      SplatNetPolicy.externalUrl(Uri.parse('javascript:alert(1)')),
      isNull,
    );
  });

  test(
    'a replaced or released page lease cannot inject into a new account',
    () {
      final first = SplatNetPageLease.acquire('account-a');
      expect(first.validFor('account-a'), isTrue);
      expect(first.validFor('account-b'), isFalse);
      final second = SplatNetPageLease.acquire('account-b');
      expect(first.validFor('account-a'), isFalse);
      first.release();
      expect(second.validFor('account-b'), isTrue);
      second.release();
      expect(second.validFor('account-b'), isFalse);
    },
  );

  test(
    'proxy configuration never embeds authentication in browser arguments',
    () {
      expect(
        SplatNetProxyConfiguration.resolve(
          platform: 'windows',
          proxyUrl: 'http://127.0.0.1:7890',
        ).windowsArguments,
        '--proxy-server=http://127.0.0.1:7890',
      );
      expect(
        () => SplatNetProxyConfiguration.resolve(
          platform: 'windows',
          proxyUrl: 'http://username:password@127.0.0.1:7890',
        ),
        throwsA(isA<UnsupportedError>()),
      );
      expect(
        () => SplatNetProxyConfiguration.resolve(
          platform: 'macos',
          proxyUrl: 'https://127.0.0.1:7890',
        ),
        throwsA(isA<UnsupportedError>()),
      );
      expect(
        SplatNetProxyConfiguration.resolve(
          platform: 'android',
          proxyUrl: 'http://saved-desktop.invalid:7890',
        ).proxy,
        isNull,
      );
    },
  );

  test('delivery round-trips the exact synthetic token only in the official top frame', () async {
    const token = r'''synthetic-"quoted"-\one\\two''';
    final script = SplatNetPolicy.deliverScript(token);
    final result = await Process.run('node', [
      '-e',
      '''
const vm = require('vm');
function run(origin, frame) {
  const deliveries = [];
  const win = {
    location: {origin},
    onGameWebTokenReceive: (...args) => deliveries.push(args)
  };
  win.top = frame ? {} : win;
  vm.runInNewContext(${jsonEncode(script)}, {window: win});
  return deliveries;
}
console.log(JSON.stringify([
  run('https://api.lp1.av5ja.srv.nintendo.net', false),
  run('https://attacker.invalid', false),
  run('https://api.lp1.av5ja.srv.nintendo.net', true)
]));
''',
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final deliveries = jsonDecode((result.stdout as String).trim()) as List;
    expect(deliveries, [
      [
        [token],
      ],
      [],
      [],
    ]);
  });

  test(
    'token bridge runs in the official top frame and never returns a token',
    () async {
      final probe = await Process.run('node', ['--version']);
      if (probe.exitCode != 0) {
        fail('Node is required for the executable JavaScript boundary test');
      }
      final script = SplatNetPolicy.bootstrapScript;
      final result = await Process.run('node', [
        '-e',
        '''
const vm = require('vm');
function run(origin, frame) {
  const calls = [];
  const win = {location: {origin}, flutter_inappwebview: {
    callHandler: (...args) => { calls.push(args); return Promise.resolve(null); }
  }};
  win.top = frame ? {} : win;
  win.window = win;
  const context = {window:win, location:win.location, URL, console};
  vm.runInNewContext(${jsonEncode(script)}, context);
  const fn = win.requestGameWebToken;
  const bridgeFn = win.jsBridge?.requestGameWebToken;
  if (fn) fn();
  if (bridgeFn) bridgeFn();
  return {calls, installed: !!fn, bridgeInstalled: !!bridgeFn};
}
console.log(JSON.stringify([
  run('https://api.lp1.av5ja.srv.nintendo.net', false),
  run('https://attacker.invalid', false),
  run('https://api.lp1.av5ja.srv.nintendo.net', true)
]));
''',
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final data = jsonDecode((result.stdout as String).trim()) as List;
      expect(data[0]['calls'], [
        ['nsoRequestGameWebToken'],
        ['nsoRequestGameWebToken'],
      ]);
      expect(data[0]['installed'], isTrue);
      expect(data[0]['bridgeInstalled'], isTrue);
      expect(data[1]['installed'], isFalse);
      expect(data[1]['bridgeInstalled'], isFalse);
      expect(data[2]['installed'], isFalse);
      expect(data[2]['bridgeInstalled'], isFalse);
    },
  );
}
