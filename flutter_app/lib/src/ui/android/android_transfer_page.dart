import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../backend/app_backend.dart';
import '../../l10n/app_localizations.dart';
import '../../rust/models.dart';
import '../../rust/settings.dart';
import '../../state/sync_controller.dart';
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
      builder: (context, _) {
        final syncing = controller.sync.running;
        return AndroidPageList(
          children: [
            Card(
              child: Column(
                children: [
                  ListTile(
                    key: const Key('android-sync-entry'),
                    leading: const Icon(Icons.cloud_sync_outlined),
                    title: Text(
                      context.l10n.select(
                        zh: 'Nintendo 同步',
                        en: 'Nintendo Sync',
                      ),
                    ),
                    subtitle: Text(
                      syncing
                          ? context.l10n.select(zh: '正在同步…', en: 'Syncing…')
                          : controller.accounts.isEmpty
                          ? context.l10n.select(
                              zh: '登录账号并配置自动同步',
                              en: 'Sign in and configure automatic sync',
                            )
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
                  if (controller.accounts.isNotEmpty) ...[
                    const Divider(height: 1),
                    for (final account in controller.accounts)
                      _AccountStatusTile(
                        profile: account,
                        history: controller.histories[account.accountId],
                        result:
                            controller.sync.accountResults[account.accountId],
                        error: controller.sync.accountErrors[account.accountId],
                        current:
                            controller.sync.currentAccountId ==
                            account.accountId,
                        authPaused: controller.sync.authPausedAccountIds
                            .contains(account.accountId),
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          key: const Key('android-sync-all'),
                          onPressed: controller.busy
                              ? null
                              : () async {
                                  if (syncing) {
                                    await controller.sync.cancel();
                                  } else {
                                    await controller.sync.run();
                                    if (context.mounted &&
                                        controller.sync.error != null) {
                                      androidMessage(
                                        context,
                                        controller.sync.error!,
                                      );
                                    }
                                  }
                                },
                          icon: Icon(syncing ? Icons.stop : Icons.sync),
                          label: Text(
                            context.l10n.select(
                              zh: syncing ? '取消同步' : '同步全部账号',
                              en: syncing ? 'Cancel sync' : 'Sync all accounts',
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (syncing || controller.sync.totalAccounts > 0)
              _OverallSyncProgress(
                sync: controller.sync,
                currentAccountName: controller.accounts
                    .where(
                      (profile) =>
                          profile.accountId == controller.sync.currentAccountId,
                    )
                    .firstOrNull
                    ?.nickname,
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
          ],
        );
      },
    ),
  );
}

class _AccountStatusTile extends StatelessWidget {
  const _AccountStatusTile({
    required this.profile,
    required this.history,
    required this.result,
    required this.error,
    required this.current,
    required this.authPaused,
  });

  final NintendoAccountProfile profile;
  final SyncRuntimeState? history;
  final SyncSummary? result;
  final Object? error;
  final bool current;
  final bool authPaused;

  @override
  Widget build(BuildContext context) {
    final attempt = history?.latestAttempt;
    return ExpansionTile(
      leading: CircleAvatar(
        foregroundImage: profile.avatarBytes?.isNotEmpty == true
            ? MemoryImage(profile.avatarBytes!)
            : null,
        child: profile.avatarBytes?.isNotEmpty == true
            ? null
            : const Icon(Icons.person_outline),
      ),
      title: Text(profile.nickname),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_accountStatus(context)),
          if (attempt != null)
            Text(
              context.l10n.select(
                zh: '上次尝试：${attempt.attemptedAt.toLocal()}',
                en: 'Last attempt: ${attempt.attemptedAt.toLocal()}',
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          if (result != null)
            Text(
              context.l10n.select(
                zh: '下载 ${result!.downloaded} · 重复 ${result!.duplicates} · 失败 ${result!.failed}',
                en: 'Downloaded ${result!.downloaded} · Duplicates ${result!.duplicates} · Failed ${result!.failed}',
              ),
            ),
        ],
      ),
      trailing: error == null ? null : const Icon(Icons.info_outline),
      children: [
        if (error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: SelectableText(androidSafeDiagnostic(error!))),
                IconButton(
                  tooltip: context.l10n.select(
                    zh: '复制诊断信息',
                    en: 'Copy diagnostic',
                  ),
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(text: androidSafeDiagnostic(error!)),
                    );
                    if (context.mounted) {
                      androidMessage(
                        context,
                        context.l10n.select(zh: '已复制', en: 'Copied'),
                        isError: false,
                      );
                    }
                  },
                  icon: const Icon(Icons.copy_outlined),
                ),
              ],
            ),
          ),
      ],
    );
  }

  String _accountStatus(BuildContext context) {
    if (current) {
      return context.l10n.select(zh: '正在同步', en: 'Syncing');
    }
    if (authPaused) {
      return context.l10n.select(
        zh: '登录已失效，等待重新登录',
        en: 'Sign-in expired; waiting for sign-in',
      );
    }
    if (error != null) {
      return androidReadableError(context, error!);
    }
    if (result != null) {
      if (result!.failed > BigInt.zero) {
        return context.l10n.select(
          zh: '同步完成但有部分项目失败',
          en: 'Sync completed with some failed items',
        );
      }
      return context.l10n.select(zh: '同步完成', en: 'Sync complete');
    }
    switch (history?.latestAttempt?.status) {
      case 'success':
      case 'completed':
        return context.l10n.select(zh: '上次同步成功', en: 'Last sync succeeded');
      case 'rate_limited':
        return context.l10n.select(
          zh: '请求过于频繁，等待重试',
          en: 'Rate limited; waiting to retry',
        );
      case 'cancelled':
        return context.l10n.select(
          zh: '上次同步已取消',
          en: 'Last sync was cancelled',
        );
      case 'failure':
      case 'partial_failure':
        return context.l10n.select(
          zh: history?.latestAttempt?.status == 'partial_failure'
              ? '上次同步有部分项目失败'
              : '上次同步未完成',
          en: history?.latestAttempt?.status == 'partial_failure'
              ? 'Last sync had some failed items'
              : 'Last sync did not complete',
        );
      case 'authentication_failure':
        return context.l10n.select(
          zh: '登录已失效，等待重新登录',
          en: 'Sign-in expired; waiting for sign-in',
        );
    }
    return context.l10n.select(zh: '等待同步', en: 'Waiting to sync');
  }
}

class _OverallSyncProgress extends StatelessWidget {
  const _OverallSyncProgress({
    required this.sync,
    required this.currentAccountName,
  });
  final SyncController sync;
  final String? currentAccountName;

  @override
  Widget build(BuildContext context) {
    final media = sync.progress;
    final total = media?.totalItems ?? BigInt.zero;
    final value = total > BigInt.zero
        ? (media!.processedItems.toDouble() / total.toDouble()).clamp(0.0, 1.0)
        : null;
    final accountValue = sync.totalAccounts > 0
        ? (sync.completedAccounts / sync.totalAccounts).clamp(0.0, 1.0)
        : null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              sync.state == SyncState.cancelled
                  ? context.l10n.select(
                      zh: '账号同步已取消 · 已处理 ${sync.completedAccounts} / ${sync.totalAccounts}',
                      en: 'Account sync cancelled · Processed ${sync.completedAccounts} / ${sync.totalAccounts}',
                    )
                  : sync.totalAccounts == 0
                  ? context.l10n.select(
                      zh: '正在准备账号队列…',
                      en: 'Preparing account queue…',
                    )
                  : context.l10n.select(
                      zh: '账号 ${sync.completedAccounts} / ${sync.totalAccounts}',
                      en: 'Accounts ${sync.completedAccounts} / ${sync.totalAccounts}',
                    ),
            ),
            const SizedBox(height: 8),
            if (sync.state != SyncState.cancelled)
              LinearProgressIndicator(
                key: const Key('android-account-progress'),
                value: accountValue,
              ),
            if (currentAccountName != null)
              Text(
                context.l10n.select(
                  zh: '当前账号：$currentAccountName',
                  en: 'Current account: $currentAccountName',
                ),
              ),
            if (sync.state != SyncState.cancelled) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(
                key: const Key('android-media-progress'),
                value: value,
              ),
            ],
            if (media != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  context.l10n.select(
                    zh: '当前媒体 ${media.processedItems} / ${media.totalItems} · 已同步 ${media.synchronizedItems} · 失败 ${media.failedItems}',
                    en: 'Current media ${media.processedItems} / ${media.totalItems} · Synchronized ${media.synchronizedItems} · Failed ${media.failedItems}',
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
