import 'package:flutter/material.dart';

import '../../backend/app_backend.dart';
import '../../l10n/app_localizations.dart';
import 'backup_page.dart';
import 'device_sync_page.dart';
import 'frame.dart';
import 'page_access.dart';

class MultiDeviceSyncPage extends StatelessWidget {
  const MultiDeviceSyncPage({
    super.key,
    required this.backend,
    required this.onLibraryChanged,
    this.embedded = false,
  });

  final AppBackend backend;
  final Future<void> Function() onLibraryChanged;
  final bool embedded;

  Future<void> _openDeviceSync(BuildContext context) async {
    final access = BackendDeviceSyncPageAccess(backend);
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => DeviceSyncPage(
            access: access,
            mobile: false,
            onLibraryChanged: onLibraryChanged,
          ),
        ),
      );
    } catch (error, stack) {
      await backend.logError('[device_sync] Open pairing failed', error, stack);
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

  Future<void> _openBackups(BuildContext context) async {
    final access = BackendDeviceSyncPageAccess(backend);
    try {
      final browser = access.openBackups();
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => DeviceSyncBackupPage(
            browser: browser,
            mobile: false,
            onLibraryChanged: onLibraryChanged,
          ),
        ),
      );
    } catch (error, stack) {
      await backend.logError('[device_sync] Open backups failed', error, stack);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.l10n.select(
                zh: '无法打开备份，请完成恢复检查后重试。',
                en: 'Unable to open backups. Complete the recovery check and retry.',
              ),
            ),
          ),
        );
      }
    } finally {
      access.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: ListTile(
            key: const Key('device-sync-entry'),
            leading: const Icon(Icons.devices_outlined),
            title: Text(
              context.l10n.select(zh: '设备间同步', en: 'Sync between devices'),
            ),
            subtitle: Text(
              context.l10n.select(
                zh: '在电脑与 Android 之间传输图库数据',
                en: 'Transfer library data between this computer and Android',
              ),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openDeviceSync(context),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            key: const Key('device-sync-backup-entry'),
            leading: const Icon(Icons.restore),
            title: Text(
              context.l10n.select(zh: '备份与恢复', en: 'Backups and restore'),
            ),
            subtitle: Text(
              context.l10n.select(
                zh: '浏览并恢复此图库的本地备份',
                en: 'Browse and restore local library backups',
              ),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openBackups(context),
          ),
        ),
      ],
    );
    if (embedded) return content;
    return DeviceSyncFrame(
      mobile: false,
      title: context.l10n.select(zh: '多设备同步', en: 'Multi-device sync'),
      canPop: true,
      onBack: () => Navigator.of(context).maybePop(),
      child: content,
    );
  }
}
