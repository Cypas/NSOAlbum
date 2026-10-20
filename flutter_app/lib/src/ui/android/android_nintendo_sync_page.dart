import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../rust/models.dart';
import '../../rust/settings.dart';
import '../../state/settings_copy.dart';
import '../../state/sync_controller.dart';
import '../../state/transfer_controller.dart';
import '../nxapi_disclosure_card.dart';
import '../display_time.dart';
import 'android_back_guard.dart';
import 'android_account_status.dart';
import 'android_page_frame.dart';

class AndroidNintendoSyncPage extends StatefulWidget {
  const AndroidNintendoSyncPage({super.key, required this.controller});
  final TransferController controller;
  @override
  State<AndroidNintendoSyncPage> createState() =>
      _AndroidNintendoSyncPageState();
}

class _AndroidNintendoSyncPageState extends State<AndroidNintendoSyncPage> {
  final callback = TextEditingController();
  bool adding = false;
  @override
  void dispose() {
    callback.dispose();
    super.dispose();
  }

  Future<void> savePolicy({bool? enabled, int? interval, int? sleep}) async {
    final state = widget.controller;
    final policy = state.settings.value.syncPolicy;
    try {
      await state.settings.save(
        copyAppSettings(
          state.settings.value,
          syncPolicy: SyncPolicy(
            enabled: enabled ?? policy.enabled,
            activeIntervalMinutes: interval ?? policy.activeIntervalMinutes,
            sleepAfterHours: sleep ?? policy.sleepAfterHours,
          ),
        ),
      );
      await state.onAccountChanged?.call();
    } catch (error) {
      if (mounted) androidMessage(context, error);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      widget.controller,
      widget.controller.sync,
      widget.controller.settings,
    ]),
    builder: (context, _) {
      final state = widget.controller;
      final settings = state.settings.value;
      final syncing =
          state.sync.state == SyncState.running ||
          state.sync.state == SyncState.cancelling;
      return AndroidBackGuard(
        busy: state.busy,
        child: AndroidPageFrame(
          title: context.l10n.select(zh: 'Nintendo 同步', en: 'Nintendo Sync'),
          secondary: true,
          child: AndroidPageList(
            children: [
              for (final account in state.accounts)
                Card(
                  key: ValueKey('android-sync-account-${account.accountId}'),
                  color: state.selectedAccountId == account.accountId
                      ? Theme.of(context).colorScheme.secondaryContainer
                      : null,
                  child: Stack(
                    children: [
                      InkWell(
                        onTap: state.busy || syncing
                            ? null
                            : () => state.selectAccount(account.accountId),
                        borderRadius: BorderRadius.circular(12),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 12, 44, 12),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  CircleAvatar(
                                    radius: 28,
                                    foregroundImage:
                                        account.avatarBytes?.isNotEmpty == true
                                        ? MemoryImage(account.avatarBytes!)
                                        : null,
                                    child:
                                        account.avatarBytes?.isNotEmpty == true
                                        ? null
                                        : const Icon(Icons.person_outline),
                                  ),
                                  const SizedBox(height: 6),
                                  SizedBox(
                                    width: 76,
                                    child: Text(
                                      account.nickname,
                                      textAlign: TextAlign.center,
                                      softWrap: true,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: _AndroidAccountStatus(
                                  history: state.histories[account.accountId],
                                  active:
                                      syncing &&
                                      state.sync.currentAccountId ==
                                          account.accountId,
                                  syncState: state.sync.state,
                                  error: state
                                      .sync
                                      .accountErrors[account.accountId],
                                  result: state
                                      .sync
                                      .accountResults[account.accountId],
                                  authPaused: state.sync.authPausedAccountIds
                                      .contains(account.accountId),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Positioned(
                        top: 2,
                        right: 2,
                        child: IconButton(
                          tooltip: context.l10n.select(
                            zh: '移除账号',
                            en: 'Remove account',
                          ),
                          icon: const Icon(Icons.person_remove_outlined),
                          onPressed: state.busy || syncing
                              ? null
                              : () async {
                                  final confirm = await showDialog<bool>(
                                    context: context,
                                    builder: (context) => AlertDialog(
                                      title: Text(
                                        context.l10n.select(
                                          zh: '移除账号？',
                                          en: 'Remove account?',
                                        ),
                                      ),
                                      content: Text(account.nickname),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(context, false),
                                          child: Text(
                                            context.l10n.select(
                                              zh: '取消',
                                              en: 'Cancel',
                                            ),
                                          ),
                                        ),
                                        FilledButton(
                                          onPressed: () =>
                                              Navigator.pop(context, true),
                                          child: Text(
                                            context.l10n.select(
                                              zh: '移除',
                                              en: 'Remove',
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (confirm == true) {
                                    await state.removeAccount(
                                      account.accountId,
                                    );
                                  }
                                },
                        ),
                      ),
                    ],
                  ),
                ),
              if (state.accounts.isNotEmpty) ...[
                TextButton.icon(
                  onPressed: state.busy
                      ? null
                      : () => setState(() => adding = true),
                  icon: const Icon(Icons.person_add_outlined),
                  label: Text(
                    context.l10n.select(zh: '添加账号', en: 'Add account'),
                  ),
                ),
              ],
              if (state.accounts.isEmpty || adding) ...[
                const NxapiDisclosureCard(),
                Text(
                  context.l10n.select(
                    zh: '打开登录页面，登录后将“选择此人”按钮的完整链接地址粘贴到下方。',
                    en: 'Sign in, then paste the full link address of “Select this person” below.',
                  ),
                ),
                Image.asset('assets/images/nintendo/nso_login_help.png'),
                OutlinedButton.icon(
                  onPressed: state.busy
                      ? null
                      : () async {
                          final success = await state.beginLogin();
                          if (!context.mounted) return;
                          if (!success && state.error != null) {
                            androidMessage(context, state.error!);
                          }
                        },
                  icon: const Icon(Icons.open_in_browser),
                  label: Text(
                    context.l10n.select(zh: '打开登录页面', en: 'Open sign-in page'),
                  ),
                ),
                TextField(
                  controller: callback,
                  enabled: !state.busy,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: context.l10n.select(
                      zh: '登录回调地址',
                      en: 'Sign-in callback URL',
                    ),
                  ),
                ),
                FilledButton(
                  onPressed: state.busy
                      ? null
                      : () async {
                          if (callback.text.trim().isEmpty) return;
                          if (!state.loginStarted) {
                            androidMessage(
                              context,
                              context.l10n.select(
                                zh: '请先打开登录页面后再输入回调地址。',
                                en: 'Open the sign-in page before entering the callback URL.',
                              ),
                              isError: true,
                            );
                            return;
                          }
                          final success = await state.completeLogin(
                            callback.text.trim(),
                          );
                          if (!context.mounted) return;
                          if (success) {
                            callback.clear();
                            setState(() => adding = false);
                          } else if (state.error != null) {
                            androidMessage(context, state.error!);
                          }
                        },
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (state.loginInProgress) ...[
                        const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Text(
                        context.l10n.select(
                          zh: state.loginInProgress ? '登录中，请稍后' : '完成登录',
                          en: state.loginInProgress
                              ? 'Signing in, please wait'
                              : 'Complete sign-in',
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              Text(
                context.l10n.select(zh: '自动同步', en: 'Automatic sync'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  context.l10n.select(
                    zh: '启用自动同步策略',
                    en: 'Enable automatic sync',
                  ),
                ),
                value: settings.syncPolicy.enabled,
                onChanged: state.settings.saving
                    ? null
                    : (value) => savePolicy(enabled: value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  context.l10n.select(zh: '启动时自动同步', en: 'Sync on launch'),
                ),
                value: settings.autoSyncOnLaunch,
                onChanged: state.settings.saving
                    ? null
                    : (value) async {
                        try {
                          await state.settings.save(
                            copyAppSettings(settings, autoSyncOnLaunch: value),
                          );
                        } catch (error) {
                          if (context.mounted) androidMessage(context, error);
                        }
                      },
              ),
              DropdownButtonFormField<int>(
                initialValue: settings.syncPolicy.activeIntervalMinutes,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: context.l10n.select(
                    zh: '活跃期检查周期',
                    en: 'Active check interval',
                  ),
                ),
                items: [
                  for (final minutes in [30, 45, 60, 90, 120])
                    DropdownMenuItem(
                      value: minutes,
                      child: Text(
                        context.l10n.select(
                          zh: '$minutes 分钟',
                          en: '$minutes minutes',
                        ),
                      ),
                    ),
                ],
                onChanged: state.settings.saving
                    ? null
                    : (value) => savePolicy(interval: value),
              ),
              TextFormField(
                initialValue: '${settings.syncPolicy.sleepAfterHours}',
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: context.l10n.select(
                    zh: '无新媒体后进入休眠（小时）',
                    en: 'Sleep after no new media (hours)',
                  ),
                ),
                onFieldSubmitted: (value) {
                  final hours = int.tryParse(value);
                  if (hours != null && hours > 0) savePolicy(sleep: hours);
                },
              ),
              Text(
                context.l10n.select(
                  zh: '休眠期间每24小时检查；发现新媒体后恢复活跃期。',
                  en: 'Checks every 24 hours while asleep; new media restores active checks.',
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _AndroidAccountStatus extends StatelessWidget {
  const _AndroidAccountStatus({
    required this.history,
    required this.active,
    required this.syncState,
    required this.error,
    required this.result,
    required this.authPaused,
  });
  final SyncRuntimeState? history;
  final bool active;
  final SyncState syncState;
  final Object? error;
  final SyncSummary? result;
  final bool authPaused;

  @override
  Widget build(BuildContext context) {
    final attempt = history?.latestAttempt;
    final status = androidAccountStatus(
      context,
      current: active,
      cancelling: syncState == SyncState.cancelling,
      authPaused: authPaused,
      history: history,
      result: result,
      error: error,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          label: status.text,
          child: ExcludeSemantics(
            child: Row(
              children: [
                ExcludeSemantics(
                  child: Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: status.color,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(status.text, softWrap: true)),
              ],
            ),
          ),
        ),
        if (attempt != null) ...[
          const SizedBox(height: 4),
          Text(
            context.l10n.select(
              zh: '上次尝试：${formatNsoAttemptTime(attempt.attemptedAt, includeSeconds: false)}',
              en: 'Last attempt: ${formatNsoAttemptTime(attempt.attemptedAt, includeSeconds: false)}',
            ),
          ),
          Text(
            context.l10n.select(
              zh: '媒体：${attempt.downloaded} 已下载 · ${attempt.duplicates} 重复 · 已存在 ${attempt.skippedRemote ?? '未记录'} · ${attempt.failed} 失败',
              en: 'Media: ${attempt.downloaded} downloaded · ${attempt.duplicates} duplicate · Existing ${attempt.skippedRemote ?? 'not recorded'} · ${attempt.failed} failed',
            ),
            softWrap: true,
          ),
        ],
      ],
    );
  }
}
