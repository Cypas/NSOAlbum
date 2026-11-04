import 'dart:io';

import 'service_contract.dart';

/// The OS query returns active interfaces. Public/link-local/loopback addresses
/// are not pairing choices; Rust still validates the final bound address.
final class DeviceLanDiscovery {
  DeviceLanDiscovery({Future<List<NetworkInterface>> Function()? interfaces})
    : _interfaces =
          interfaces ??
          (() => NetworkInterface.list(type: InternetAddressType.IPv4));
  final Future<List<NetworkInterface>> Function() _interfaces;

  Future<List<DeviceLanAddress>> list() async {
    final choices = <String, DeviceLanAddress>{};
    for (final interface in await _interfaces()) {
      for (final address in interface.addresses) {
        if (address.type != InternetAddressType.IPv4) continue;
        final bytes = address.rawAddress;
        final private =
            bytes.length == 4 &&
            (bytes[0] == 10 ||
                (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
                (bytes[0] == 192 && bytes[1] == 168));
        if (!private ||
            address.isLoopback ||
            address.isLinkLocal ||
            address.isMulticast) {
          continue;
        }
        choices['${interface.name}\u0000${address.address}'] = DeviceLanAddress(
          interfaceName: interface.name,
          address: address.address,
        );
      }
    }
    final ordered = choices.values.toList()
      ..sort((a, b) {
        final interface = a.interfaceName.compareTo(b.interfaceName);
        return interface != 0 ? interface : a.address.compareTo(b.address);
      });
    return List.unmodifiable(ordered);
  }
}
