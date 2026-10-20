import 'package:flutter/material.dart';

import '../../backend/app_backend.dart';
import '../../l10n/app_localizations.dart';
import 'device_sync_page.dart';
import 'multi_device_sync_page.dart';
import 'page_access.dart';

class DeviceSyncEntry extends StatelessWidget {
  const DeviceSyncEntry({
    super.key,
    required this.backend,
    required this.mobile,
    required this.onLibraryChanged,
  });
  final AppBackend backend;
  final bool mobile;
  final Future<void> Function() onLibraryChanged;
  Future<void> _open(BuildContext context) async {
    if (!mobile) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => MultiDeviceSyncPage(
            backend: backend,
            onLibraryChanged: onLibraryChanged,
          ),
        ),
      );
      return;
    }
    final access = BackendDeviceSyncPageAccess(backend);
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          // The route builder can run again on locale/theme/insets changes.
          // A push owns one access object; the page releases it on disposal.
          builder: (_) => DeviceSyncPage(
            access: access,
            mobile: true,
            onLibraryChanged: onLibraryChanged,
          ),
        ),
      );
    } catch (_) {
      // Also retire it when the route was never installed. Adapter disposal is
      // idempotent if navigation failed after the page already disposed.
      access.dispose();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.l10n.select(
                zh: '无法打开设备同步，请重试。',
                en: 'Unable to open device sync. Please retry.',
              ),
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => Card(
      child: ListTile(
        key: const Key('device-sync-entry'),
        leading: const Icon(Icons.devices_outlined),
        title: Text(
          context.l10n.select(zh: '多设备同步', en: 'Multi-device sync'),
        ),
        subtitle: Text(
          context.l10n.select(
            zh: '在电脑与 Android 之间同步图库',
            en: 'Sync libraries between desktop and Android',
          ),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _open(context),
      ),
  );
}
