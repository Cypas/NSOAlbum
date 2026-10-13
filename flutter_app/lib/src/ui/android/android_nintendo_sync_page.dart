import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../rust/settings.dart';
import '../../state/settings_copy.dart';
import '../../state/sync_controller.dart';
import '../../state/transfer_controller.dart';
import '../nxapi_disclosure_card.dart';
import 'android_back_guard.dart';
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
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    account.accountId == state.selectedAccountId
                        ? Icons.account_circle
                        : Icons.account_circle_outlined,
                  ),
                  title: Text(account.nickname),
                  subtitle:
                      state.histories[account.accountId]?.latestAttempt == null
                      ? null
                      : Text(
                          '${state.histories[account.accountId]!.latestAttempt!.attemptedAt.toLocal()}',
                        ),
                  onTap: state.busy || syncing
                      ? null
                      : () => state.selectAccount(account.accountId),
                  trailing: IconButton(
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
                              await state.removeAccount(account.accountId);
                            }
                          },
                  ),
                ),
              if (state.accounts.isNotEmpty) ...[
                FilledButton.icon(
                  onPressed: state.busy
                      ? null
                      : (syncing ? state.sync.cancel : state.sync.run),
                  icon: Icon(syncing ? Icons.stop : Icons.sync),
                  label: Text(
                    context.l10n.select(
                      zh: syncing ? '取消同步' : '立即同步',
                      en: syncing ? 'Cancel sync' : 'Sync now',
                    ),
                  ),
                ),
                if (state.sync.progress case final progress?)
                  Text(
                    context.l10n.select(
                      zh: '已处理 ${progress.processedItems} / ${progress.totalItems} · 已同步 ${progress.synchronizedItems} · 失败 ${progress.failedItems}',
                      en: 'Processed ${progress.processedItems} / ${progress.totalItems} · Synchronized ${progress.synchronizedItems} · Failed ${progress.failedItems}',
                    ),
                  ),
                if (state.sync.summary case final result?)
                  Text(
                    context.l10n.select(
                      zh: '发现 ${result.totalFound} · 下载 ${result.downloaded} · 重复 ${result.duplicates} · 失败 ${result.failed}',
                      en: 'Found ${result.totalFound} · Downloaded ${result.downloaded} · Duplicates ${result.duplicates} · Failed ${result.failed}',
                    ),
                  ),
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
                      : () => state.perform(state.backend.beginNintendoLogin),
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
                          final success = await state.completeLogin(
                            callback.text.trim(),
                          );
                          if (success && mounted) {
                            callback.clear();
                            setState(() => adding = false);
                          }
                        },
                  child: Text(
                    context.l10n.select(zh: '完成登录', en: 'Complete sign-in'),
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
              if (state.error != null) SelectableText(state.error.toString()),
              if (state.sync.error != null)
                SelectableText(state.sync.error.toString()),
            ],
          ),
        ),
      );
    },
  );
}
