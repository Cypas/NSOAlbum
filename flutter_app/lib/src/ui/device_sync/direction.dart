import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

/// Shared direction presentation, independent of which device hosts the session.
class DeviceSyncDirectionLabel extends StatelessWidget {
  const DeviceSyncDirectionLabel({super.key, required this.phoneToDesktop});

  final bool phoneToDesktop;

  @override
  Widget build(BuildContext context) {
    final desktop = context.l10n.select(zh: '桌面', en: 'Desktop');
    final phone = context.l10n.select(zh: '手机', en: 'Phone');
    final source = phoneToDesktop ? phone : desktop;
    final target = phoneToDesktop ? desktop : phone;
    Widget device(String key, String name, IconData icon) => Row(
      key: Key(key),
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: 4),
        Flexible(child: Text(name)),
      ],
    );
    return Semantics(
      key: const Key('device-sync-direction'),
      label: '$source → $target',
      child: ExcludeSemantics(
        child: Wrap(
          spacing: 6,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            device(
              'device-direction-source',
              source,
              phoneToDesktop ? Icons.smartphone : Icons.desktop_windows,
            ),
            const Icon(Icons.arrow_forward, size: 18),
            device(
              'device-direction-target',
              target,
              phoneToDesktop ? Icons.desktop_windows : Icons.smartphone,
            ),
          ],
        ),
      ),
    );
  }
}
