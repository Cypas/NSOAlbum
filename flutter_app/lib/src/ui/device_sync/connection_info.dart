import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../platform/device_sync_network.dart';

/// Connection hints stay separate from the security/session progress panel.
class DeviceSyncConnectionInfo extends StatelessWidget {
  const DeviceSyncConnectionInfo({
    super.key,
    required this.usb,
    required this.mobile,
    required this.wifi,
    this.selectedAddress,
    this.peerSsid,
  });
  final bool usb, mobile;
  final DeviceWifiSnapshot wifi;
  final String? selectedAddress, peerSsid;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final ssid = wifi.ssidForAddress(selectedAddress);
    final title = usb
        ? l10n.select(zh: 'USB 文件传输', en: 'USB file transfer')
        : !mobile && ssid != null
        ? l10n.select(zh: 'Wi-Fi：$ssid', en: 'Wi-Fi: $ssid')
        : l10n.select(zh: 'Wi-Fi / 局域网', en: 'Wi-Fi / Local network');
    final match = wifi.compareName(peerSsid);
    return Padding(
      key: const Key('device-connection-info'),
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          if (!usb && !mobile && ssid == null)
            Text(
              wifi.ssid != null && wifi.address == null
                  ? l10n.select(
                      zh: '本机 Wi-Fi：${wifi.ssid}。所选地址与此 Wi-Fi 的对应关系未知。',
                      en: 'This computer’s Wi-Fi: ${wifi.ssid}. Its association with the selected address is unknown.',
                    )
                  : wifi.address != null && selectedAddress != null
                  ? l10n.select(
                      zh: '所选局域网地址不属于当前 Wi-Fi。',
                      en: 'The selected local network address is not the current Wi-Fi address.',
                    )
                  : l10n.select(
                      zh: 'Wi-Fi 名称不可用。仍可通过局域网连接。',
                      en: 'Wi-Fi name unavailable. Local network connections are still available.',
                    ),
            ),
          if (!usb && mobile) ...[
            Text(
              l10n.select(
                zh: '电脑 Wi-Fi：${peerSsid ?? '未知'}',
                en: 'Computer Wi-Fi: ${peerSsid ?? 'Unknown'}',
              ),
            ),
            Text(
              l10n.select(
                zh: '本机 Wi-Fi：${wifi.ssid ?? '未知'}',
                en: 'This device’s Wi-Fi: ${wifi.ssid ?? 'Unknown'}',
              ),
            ),
            Text(switch (match) {
              DeviceWifiMatch.sameName => l10n.select(
                zh: 'Wi-Fi 名称相同。请继续核对两端确认码。',
                en: 'Wi-Fi names match. Continue by checking the confirmation code on both devices.',
              ),
              DeviceWifiMatch.differentName => l10n.select(
                zh: 'Wi-Fi 名称不同，仍会尝试连接电脑。请检查是否在同一局域网。',
                en: 'Wi-Fi names differ. The computer connection will still be attempted. Check that both devices are on the same local network.',
              ),
              DeviceWifiMatch.unknown => l10n.select(
                zh: 'Wi-Fi 名称不可用，仍会尝试局域网连接。',
                en: 'Wi-Fi name unavailable. A local network connection will still be attempted.',
              ),
            }),
          ],
        ],
      ),
    );
  }
}
