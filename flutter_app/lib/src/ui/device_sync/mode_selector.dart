import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import 'direction.dart';

/// Explicit alternatives, independent of transport roles or native authority.
class DeviceSyncModeSelector extends StatelessWidget {
  const DeviceSyncModeSelector({
    super.key,
    required this.phoneToDesktop,
    required this.overwrite,
    required this.includeAccounts,
    required this.enabled,
    required this.onDirectionChanged,
    required this.onOverwriteChanged,
    required this.onAccountsChanged,
  });

  final bool phoneToDesktop, overwrite, includeAccounts, enabled;
  final ValueChanged<bool> onDirectionChanged;
  final ValueChanged<bool> onOverwriteChanged;
  final ValueChanged<bool> onAccountsChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _group(
        context,
        key: 'device-direction',
        title: context.l10n.select(zh: '同步方向', en: 'Direction'),
        value: phoneToDesktop,
        options: (
          const DeviceSyncDirectionLabel(phoneToDesktop: false),
          const DeviceSyncDirectionLabel(phoneToDesktop: true),
        ),
        keys: ('device-desktop-to-phone', 'device-phone-to-desktop'),
        onChanged: onDirectionChanged,
      ),
      _group(
        context,
        key: 'device-overwrite',
        title: context.l10n.select(zh: '同步模式', en: 'Sync mode'),
        value: overwrite,
        options: (
          Text(context.l10n.select(zh: '融合', en: 'Merge'), softWrap: true),
          Text(context.l10n.select(zh: '覆盖', en: 'Overwrite'), softWrap: true),
        ),
        keys: ('device-mode-merge', 'device-mode-overwrite'),
        onChanged: onOverwriteChanged,
      ),
      Text(
        overwrite
            ? context.l10n.select(
                zh: '以来源图库为准，移出接收端独有项目并保留恢复备份。',
                en: 'Use the source library, remove receiver-only items and retain a recovery backup.',
              )
            : context.l10n.select(
                zh: '合并两端内容，保留接收端独有项目。',
                en: 'Combine both libraries and keep receiver-only items.',
              ),
      ),
      _group(
        context,
        key: 'device-include-accounts',
        title: context.l10n.select(zh: '账号范围', en: 'Accounts'),
        value: includeAccounts,
        options: (
          Text(
            context.l10n.select(zh: '不传输账号', en: 'Exclude accounts'),
            softWrap: true,
          ),
          Text(
            context.l10n.select(zh: '包含全部账号', en: 'Include all accounts'),
            softWrap: true,
          ),
        ),
        keys: ('device-library-only', 'device-with-accounts'),
        onChanged: onAccountsChanged,
      ),
      if (includeAccounts)
        Text(
          context.l10n.select(
            zh: '包含 Nintendo 账号、登录凭据及历史账号显示名称。选择后会在本次会话中安全处理账号同步授权。',
            en: 'Includes Nintendo accounts, sign-in credentials and account display-name history. Account-sync authorization is handled securely for this session after you continue.',
          ),
        ),
      const SizedBox(height: 12),
    ],
  );

  Widget _group(
    BuildContext context, {
    required String key,
    required String title,
    required bool value,
    required (Widget, Widget) options,
    required (String, String) keys,
    required ValueChanged<bool> onChanged,
  }) => Padding(
    key: Key(key),
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(title, style: Theme.of(context).textTheme.titleMedium),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceChip(
              key: Key(keys.$1),
              label: options.$1,
              selected: !value,
              onSelected: enabled ? (_) => onChanged(false) : null,
            ),
            ChoiceChip(
              key: Key(keys.$2),
              label: options.$2,
              selected: value,
              onSelected: enabled ? (_) => onChanged(true) : null,
            ),
          ],
        ),
      ],
    ),
  );
}
