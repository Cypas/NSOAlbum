import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../backend/app_backend.dart';
import '../../l10n/app_localizations.dart';
import '../../rust/models.dart';
import '../../rust/settings.dart';
import '../../state/sync_controller.dart';
import '../../state/transfer_controller.dart';
import '../display_time.dart';
import '../account_tools/account_tools_actions.dart';
import '../device_sync/entry.dart';
import 'android_account_expander.dart';
import 'android_account_status.dart';
import 'android_custom_import_page.dart';
import 'android_nintendo_sync_page.dart';
import 'android_page_frame.dart';

class AndroidTransferPage extends StatelessWidget {
  const AndroidTransferPage({
    super.key,
    required this.controller,
    this.onDeviceSyncChanged,
  });
  final TransferController controller;
  final Future<void> Function()? onDeviceSyncChanged;

  @override
  Widget build(BuildContext context) => AndroidPageFrame(
    title: context.l10n.select(zh: '导入与同步', en: 'Sync & Import'),
    child: AnimatedBuilder(
      animation: Listenable.merge([controller, controller.sync]),
      builder: (context, _) {
        final syncing = controller.sync.running;
        final profiles = controller.accounts;
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
                          : context.l10n.select(
                              zh: '登录账号并配置自动同步',
                              en: 'Sign in and configure automatic sync',
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
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          context.l10n.select(
                            zh: '已登录账号 ${profiles.length}',
                            en: 'Signed-in accounts: ${profiles.length}',
                          ),
                        ),
                      ),
                    ),
                    for (final account in profiles)
                      _AccountStatusTile(
                        backend: controller.backend,
                        profile: account,
                        history: controller.histories[account.accountId],
                        result:
                            controller.sync.accountResults[account.accountId],
                        error: controller.sync.accountErrors[account.accountId],
                        current:
                            syncing &&
                            controller.sync.currentAccountId ==
                                account.accountId,
                        cancelling:
                            controller.sync.state == SyncState.cancelling,
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
            if (syncing) _OverallSyncProgress(sync: controller.sync),
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
            DeviceSyncEntry(
              backend: controller.backend,
              mobile: true,
              onLibraryChanged: () async {
                if (onDeviceSyncChanged case final changed?) {
                  await changed();
                } else {
                  controller.onImported?.call();
                  await controller.refresh();
                }
              },
            ),
          ],
        );
      },
    ),
  );
}

class _AccountStatusTile extends StatelessWidget {
  const _AccountStatusTile({
    required this.backend,
    required this.profile,
    required this.history,
    required this.result,
    required this.error,
    required this.current,
    required this.cancelling,
    required this.authPaused,
  });

  final NintendoAccountProfile profile;
  final AppBackend backend;
  final SyncRuntimeState? history;
  final SyncSummary? result;
  final Object? error;
  final bool current;
  final bool cancelling;
  final bool authPaused;

  @override
  Widget build(BuildContext context) {
    final attempt = history?.latestAttempt;
    final status = androidAccountStatus(
      context,
      current: current,
      cancelling: cancelling,
      authPaused: authPaused,
      error: error,
      result: result,
      history: history,
    );
    final identity = SizedBox(
      // Keep identity compact; large text wraps within its own column.
      width: 80,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            foregroundImage: profile.avatarBytes?.isNotEmpty == true
                ? MemoryImage(profile.avatarBytes!)
                : null,
            child: profile.avatarBytes?.isNotEmpty == true
                ? null
                : const Icon(Icons.person_outline),
          ),
          const SizedBox(height: 6),
          Text(profile.nickname, textAlign: TextAlign.center, softWrap: true),
        ],
      ),
    );
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          label: status.text,
          child: ExcludeSemantics(
            child: Row(
              children: [
                Container(
                  key: Key('android-account-status-dot-${profile.accountId}'),
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: status.color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(child: Text(status.text)),
              ],
            ),
          ),
        ),
        if (attempt != null)
          Text(
            context.l10n.select(
              zh: '上次尝试：${formatNsoAttemptTime(attempt.attemptedAt, includeSeconds: false)}',
              en: 'Last attempt: ${formatNsoAttemptTime(attempt.attemptedAt, includeSeconds: false)}',
            ),
          ),
        if (result != null)
          Text(
            context.l10n.select(
              zh: '下载 ${result!.downloaded} · 重复 ${result!.duplicates} · 失败 ${result!.failed}',
              en: 'Downloaded ${result!.downloaded} · Duplicates ${result!.duplicates} · Failed ${result!.failed}',
            ),
          ),
      ],
    );
    return AndroidAccountExpander(
      key: PageStorageKey('android-account-${profile.accountId}'),
      identity: identity,
      details: details,
      children: [
        AccountToolsActions(backend: backend, profile: profile, mobile: true),
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
}

class _OverallSyncProgress extends StatelessWidget {
  const _OverallSyncProgress({required this.sync});
  final SyncController sync;

  @override
  Widget build(BuildContext context) {
    final media = sync.progress;
    final total = media?.totalItems ?? BigInt.zero;
    final value = total > BigInt.zero
        ? (media!.processedItems.toDouble() / total.toDouble()).clamp(0.0, 1.0)
        : null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.select(
                zh: sync.state == SyncState.cancelling ? '正在取消同步…' : '正在同步…',
                en: sync.state == SyncState.cancelling
                    ? 'Cancelling sync…'
                    : 'Syncing…',
              ),
            ),
            const SizedBox(height: 8),
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
