import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/ui/account_tools/splatnet_close.dart';

void main() {
  test('ordinary webpage navigation does not exit SplatNet', () async {
    for (final label in ['返回', 'Home', 'Close', '閉じる']) {
      final result = await _runCloseScript('''
const event = click(${jsonEncode(label)});
return {calls, prevented: event.prevented};
''');
      expect(result, {'calls': [], 'prevented': false});
    }
  });

  test('official native close APIs send one route close without closing the web surface', () async {
    final result = await _runCloseScript(r'''
window.closeWebView?.();
window.jsBridge?.closeWebView?.();
window.vh?.closeWebView?.();
return {calls, nativeCloseCalls};
''');
    expect(result, {
      'calls': [
        ['splatnetClosed'],
      ],
      'nativeCloseCalls': 0,
    });
  });

  test('close bridge is unavailable outside the official top frame', () async {
    for (final options in [
      (origin: 'https://attacker.invalid', frame: false),
      (origin: 'https://api.lp1.av5ja.srv.nintendo.net', frame: true),
    ]) {
      final result = await _runCloseScript(
        r'''
window.closeWebView?.();
return {installed: typeof window.closeWebView === 'function', calls};
''',
        origin: options.origin,
        frame: options.frame,
      );
      expect(result, {'installed': false, 'calls': []});
    }
  });

  test(
    'specific close control blocks navigation but a modal close stays local',
    () async {
      for (final label in [
        '关闭鱿鱼圈',
        '關閉魷魚圈',
        'イカリング3を閉じる',
        'Close SplatNet 3',
      ]) {
        final result = await _runCloseScript('''
const event = click(${jsonEncode(label)});
return {calls, prevented: event.prevented, stopped: event.stopped};
''');
        expect(result, {
          'calls': [
            ['splatnetClosed'],
          ],
          'prevented': true,
          'stopped': true,
        });
      }
      final modal = await _runCloseScript(r'''
const event = click('关闭');
return {calls, prevented: event.prevented, stopped: event.stopped};
''');
      expect(modal, {'calls': [], 'prevented': false, 'stopped': false});
    },
  );

  test(
    'document-start bridge can wait for the native JS channel to become ready',
    () async {
      final result = await _runCloseScript(r'''
window.closeWebView?.();
window.flutter_inappwebview = channel;
window.closeWebView?.();
return {calls, nativeCloseCalls};
''', channelReady: false);
      expect(result, {
        'calls': [
          ['splatnetClosed'],
        ],
        'nativeCloseCalls': 0,
      });
    },
  );

  test('returns to the caller even when webview cleanup fails', () async {
    var returned = false;
    Object? cleanupError;
    await closeSplatNetAndReturn(
      closeResources: () async => throw StateError('synthetic cleanup failure'),
      onCleanupError: (error) => cleanupError = error,
      returnToCaller: () async => returned = true,
    );
    expect(cleanupError, isA<StateError>());
    expect(returned, isTrue);
  });
}

Future<Object?> _runCloseScript(
  String action, {
  String origin = 'https://api.lp1.av5ja.srv.nintendo.net',
  bool frame = false,
  bool channelReady = true,
}) async {
  final result = await Process.run('node', [
    '-e',
    '''
const vm = require('node:vm');
const calls = [];
let nativeCloseCalls = 0;
const channel = {callHandler: (...args) => {
  calls.push(args);
  return Promise.resolve(null);
}};
const window = {
  location: {origin: ${jsonEncode(origin)}},
  vh: {}, close: () => nativeCloseCalls++,
  flutter_inappwebview: ${channelReady ? 'channel' : 'undefined'},
};
window.top = ${frame ? '{}' : 'window'};
const listeners = [];
class Element {
  constructor(text) { this.innerText = text; }
  closest() { return this; }
  getAttribute() { return null; }
}
const document = {addEventListener: (type, callback) => {
  if (type === 'click') listeners.push(callback);
}};
function click(label) {
  const event = {
    target: new Element(label), prevented: false, stopped: false,
    preventDefault() { this.prevented = true; },
    stopImmediatePropagation() { this.stopped = true; },
  };
  for (const listener of listeners) listener(event);
  return event;
}
vm.runInNewContext(${jsonEncode(splatNetCloseWatcherScript)}, {
  window, document, Element,
});
const result = (() => { $action })();
console.log(JSON.stringify(result));
''',
  ]);
  expect(result.exitCode, 0, reason: '${result.stderr}');
  return jsonDecode((result.stdout as String).trim());
}
