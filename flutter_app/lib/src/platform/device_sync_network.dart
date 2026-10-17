import 'dart:convert';
import 'dart:io';

import 'package:network_info_plus/network_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

enum DeviceWifiMatch { sameName, differentName, unknown }

/// An ephemeral hint, never a device identity or a transport authorization.
final class DeviceWifiSnapshot {
  const DeviceWifiSnapshot({this.ssid, this.address});
  final String? ssid, address;

  DeviceWifiMatch compareName(String? peer) => ssid == null || peer == null
      ? DeviceWifiMatch.unknown
      : ssid == peer
      ? DeviceWifiMatch.sameName
      : DeviceWifiMatch.differentName;

  String? ssidForAddress(String? selected) =>
      selected != null && address == selected ? ssid : null;
}

/// Reads only on demand; no scans, BSSID, location fixes or network history.
final class DeviceNetworkReader {
  DeviceNetworkReader({
    bool? android,
    bool? windows,
    bool? macos,
    Future<bool> Function()? requestAccess,
    Future<String?> Function()? readName,
    Future<String?> Function()? readAddress,
  }) : _android = android ?? Platform.isAndroid,
       _windows = windows ?? Platform.isWindows,
       _macos = macos ?? Platform.isMacOS,
       _requestAccess = requestAccess ?? _requestAndroidAccess,
       _readName = readName ?? NetworkInfo().getWifiName,
       _readAddress = readAddress ?? NetworkInfo().getWifiIP;

  final bool _android, _windows, _macos;
  final Future<bool> Function() _requestAccess;
  final Future<String?> Function() _readName, _readAddress;

  static Future<bool> _requestAndroidAccess() async =>
      (await Permission.locationWhenInUse.request()).isGranted;

  Future<DeviceWifiSnapshot> read({bool requestPermission = false}) async {
    try {
      if (_android) {
        final granted = requestPermission
            ? await _requestAccess()
            : (await Permission.locationWhenInUse.status).isGranted;
        if (!granted) return const DeviceWifiSnapshot();
      }
      final first = _normalize(await _readName());
      final address = await _readAddress();
      final last = _normalize(await _readName());
      if (first != last) return const DeviceWifiSnapshot();
      // The locked plugin uses CoreWLAN's current interface for SSID, but en0
      // for IP. These can differ on Macs. Never claim a false association.
      return DeviceWifiSnapshot(ssid: first, address: _macos ? null : address);
    } catch (_) {
      // OS privacy restrictions and plugin failures are not connection failures.
      // Network names and raw platform diagnostics never enter logs.
      return const DeviceWifiSnapshot();
    }
  }

  String? _normalize(String? name) {
    if (name == null) return null;
    var value = name;
    // network_info_plus Windows 8.2.2 represents DOT11_SSID bytes as code units.
    if (_windows) value = utf8.decode(value.codeUnits);
    if (_android &&
        value.length >= 2 &&
        value.startsWith('"') &&
        value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    if (value.isEmpty ||
        value == '<unknown ssid>' ||
        utf8.encode(value).length > 32 ||
        value.runes.any((c) => c < 32 || (c >= 127 && c <= 159))) {
      return null;
    }
    return value;
  }
}
