import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/device_sync/lan_addresses.dart';

void main() {
  test('active private LAN choices retain multiple interfaces and exclude other scopes', () async {
    final discovery = DeviceLanDiscovery(
      interfaces: () async => [
        _Interface('Wireless', [
          '192.168.31.66',
          '192.168.31.67',
          '8.8.8.8',
          '127.0.0.1',
          '169.254.1.2',
        ]),
        _Interface('Ethernet', [
          '10.0.0.2',
          '172.16.0.2',
          '172.31.255.254',
          '172.15.255.254',
          '172.32.0.1',
          '192.167.1.1',
          '192.169.1.1',
          '0.0.0.0',
          '224.1.2.3',
        ]),
      ],
    );
    final choices = await discovery.list();
    expect(choices.map((choice) => (choice.interfaceName, choice.address)), [
      ('Ethernet', '10.0.0.2'),
      ('Ethernet', '172.16.0.2'),
      ('Ethernet', '172.31.255.254'),
      ('Wireless', '192.168.31.66'),
      ('Wireless', '192.168.31.67'),
    ]);
  });

  test(
    'network lookup failure is not converted to a public or loopback fallback',
    () async {
      final failure = SocketException('Synthetic OS lookup failure');
      final discovery = DeviceLanDiscovery(
        interfaces: () async => throw failure,
      );
      await expectLater(discovery.list(), throwsA(same(failure)));
    },
  );
}

class _Interface implements NetworkInterface {
  _Interface(this.name, List<String> values)
    : addresses = values
          .map((value) => _Address(InternetAddress(value)))
          .toList();
  @override
  final String name;
  @override
  int get index => 1;
  @override
  final List<InterfaceAddress> addresses;
}

class _Address implements InterfaceAddress {
  _Address(this._value);
  final InternetAddress _value;
  @override
  String get address => _value.address;
  @override
  InternetAddressType get type => _value.type;
  @override
  String get host => _value.host;
  @override
  Uint8List get rawAddress => _value.rawAddress;
  @override
  bool get isLoopback => _value.isLoopback;
  @override
  bool get isLinkLocal => _value.isLinkLocal;
  @override
  bool get isMulticast => _value.isMulticast;
  @override
  Future<InternetAddress> reverse() =>
      throw StateError('LAN discovery must not query DNS.');
  @override
  int get prefixLength => 24;
  @override
  InternetAddress? get broadcast => null;
}
