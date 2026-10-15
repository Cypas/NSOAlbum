import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../backend/app_backend.dart';
import '../../backend/sync_failure_status.dart';
import '../../l10n/app_localizations.dart';
import '../../rust/models.dart';
import '../../rust/settings.dart';
import '../../state/sync_controller.dart';
import '../../state/transfer_controller.dart';
import '../display_time.dart';
import '../account_tools/account_tools_actions.dart';
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
                    for (final account in controller.accounts)
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
    final status = _accountStatus(context);
    final identity = Column(
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
              zh: '上次尝试：${formatNsoAttemptTime(attempt.attemptedAt)}',
              en: 'Last attempt: ${formatNsoAttemptTime(attempt.attemptedAt)}',
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
    return ExpansionTile(
      key: PageStorageKey('android-account-${profile.accountId}'),
      title: LayoutBuilder(
        builder: (context, constraints) {
          final stacked =
              constraints.maxWidth < 250 ||
              MediaQuery.textScalerOf(context).scale(14) > 21;
          if (stacked) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [identity, const SizedBox(height: 12), details],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 100, child: identity),
              const SizedBox(width: 12),
              Expanded(child: details),
            ],
          );
        },
      ),
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

  ({String text, Color color}) _accountStatus(BuildContext context) {
    ({String text, Color color}) status(String zh, String en, Color color) =>
        (text: context.l10n.select(zh: zh, en: en), color: color);
    final active = Colors.blue.shade600;
    final success = Colors.green.shade600;
    final warning = Colors.amber.shade700;
    final failure = Colors.red.shade600;
    final neutral = Colors.grey.shade600;
    if (current) {
      return cancelling
          ? status('正在取消同步', 'Cancelling sync', active)
          : status('正在同步', 'Syncing', active);
    }
    if (authPaused) {
      return status(
        '登录已失效，等待重新登录',
        'Sign-in expired; waiting for sign-in',
        failure,
      );
    }
    if (error != null) {
      switch (syncFailureStatus(error!)) {
        case 'rate_limited':
          return status(
            '请求过于频繁，等待重试',
            'Rate limited; waiting to retry',
            warning,
          );
        case 'authentication_failure':
          return status(
            '登录已失效，等待重新登录',
            'Sign-in expired; waiting for sign-in',
            failure,
          );
        case 'cancelled':
          return status('同步已取消', 'Sync cancelled', neutral);
        default:
          return (text: androidReadableError(context, error!), color: failure);
      }
    }
    if (result != null) {
      if (result!.failed > BigInt.zero) {
        return status(
          '同步完成但有部分项目失败',
          'Sync completed with some failed items',
          warning,
        );
      }
      return status('同步完成', 'Sync complete', success);
    }
    switch (history?.latestAttempt?.status) {
      case 'success':
      case 'completed':
        return status('上次同步成功', 'Last sync succeeded', success);
      case 'rate_limited':
        return status('请求过于频繁，等待重试', 'Rate limited; waiting to retry', warning);
      case 'cancelled':
        return status('上次同步已取消', 'Last sync was cancelled', neutral);
      case 'failure':
        return status('上次同步未完成', 'Last sync did not complete', failure);
      case 'partial_failure':
        return status(
          '上次同步有部分项目失败',
          'Last sync had some failed items',
          warning,
        );
      case 'authentication_failure':
        return status(
          '登录已失效，等待重新登录',
          'Sign-in expired; waiting for sign-in',
          failure,
        );
    }
    return status('等待同步', 'Waiting to sync', neutral);
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
