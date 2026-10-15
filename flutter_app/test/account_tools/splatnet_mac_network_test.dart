import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/platform/splatnet_mac_network.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('io.github.cypas.nsoalbum/splatnet_network');
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return true;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('macOS configures its app data store before page creation', () async {
    await SplatNetMacNetwork.configure(Uri.parse('http://127.0.0.1:7890'));
    expect(calls.single.method, 'configure');
    expect(calls.single.arguments, {'host': '127.0.0.1', 'port': 7890});
  });

  test('an unavailable native proxy fails closed', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => false);
    await expectLater(
      SplatNetMacNetwork.configure(Uri.parse('http://127.0.0.1:7890')),
      throwsA(isA<UnsupportedError>()),
    );
  });
}
