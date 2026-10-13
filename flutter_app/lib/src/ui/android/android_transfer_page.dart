import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../state/transfer_controller.dart';
import 'android_custom_import_page.dart';
import 'android_nintendo_sync_page.dart';
import 'android_page_frame.dart';

class AndroidTransferPage extends StatelessWidget {
  const AndroidTransferPage({super.key, required this.controller});
  final TransferController controller;

  @override
  Widget build(BuildContext context) => AndroidPageFrame(
    title: context.l10n.select(zh: '导入与同步', en: 'Sync & Import'),
    child: AnimatedBuilder(
      animation: Listenable.merge([controller, controller.sync]),
      builder: (context, _) => AndroidPageList(
        children: [
          Card(
            child: ListTile(
              key: const Key('android-sync-entry'),
              leading: const Icon(Icons.cloud_sync_outlined),
              title: Text(
                context.l10n.select(zh: 'Nintendo 同步', en: 'Nintendo Sync'),
              ),
              subtitle: Text(
                controller.sync.state.name == 'running'
                    ? context.l10n.select(zh: '正在同步…', en: 'Syncing…')
                    : context.l10n.select(
                        zh: '已连接 ${controller.accounts.length} 个账号',
                        en: '${controller.accounts.length} connected accounts',
                      ),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      AndroidNintendoSyncPage(controller: controller),
                ),
              ),
            ),
          ),
          Card(
            child: ListTile(
              key: const Key('android-import-entry'),
              leading: const Icon(Icons.add_photo_alternate_outlined),
              title: Text(
                context.l10n.select(zh: '自定义导入', en: 'Custom Import'),
              ),
              subtitle: Text(
                context.l10n.select(
                  zh: '从设备选择图片、视频或目录',
                  en: 'Choose photos, videos, or a folder',
                ),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      AndroidCustomImportPage(controller: controller),
                ),
              ),
            ),
          ),
          if (controller.importSummary case final result?)
            Text(
              context.l10n.select(
                zh: '导入 ${result.imported} · 重复 ${result.duplicates} · 失败 ${result.failed}',
                en: 'Imported ${result.imported} · Duplicates ${result.duplicates} · Failed ${result.failed}',
              ),
            ),
          if (controller.error != null)
            SelectableText(controller.error.toString()),
        ],
      ),
    ),
  );
}
