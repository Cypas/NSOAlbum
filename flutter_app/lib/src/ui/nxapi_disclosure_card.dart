import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';

/// Product-author disclosure shown before Nintendo sign-in.
class NxapiDisclosureCard extends StatelessWidget {
  const NxapiDisclosureCard({super.key});

  Future<void> _openProviderLink(BuildContext context) async {
    try {
      final opened = await launchUrl(
        Uri.parse('https://github.com/samuelthomas2774/nxapi-znca-api'),
        mode: LaunchMode.externalApplication,
      );
      if (opened) return;
    } catch (_) {
      // A missing browser or platform handler must not interrupt sign-in.
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: SelectableText(
          context.l10n.select(zh: '无法打开链接。', en: 'Unable to open the link.'),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Card(
      key: const Key('nxapi-login-disclosure'),
      margin: EdgeInsets.zero,
      elevation: 4,
      shadowColor: colors.primary.withValues(alpha: 0.3),
      color: colors.primaryContainer.withValues(alpha: 0.45),
      child: ExpansionTile(
        key: const Key('nxapi-disclosure-toggle'),
        leading: Icon(Icons.warning_amber_rounded, color: colors.primary),
        title: Text(
          context.l10n.select(
            zh: 'NXAPI 第三方登录说明',
            en: 'Third-party NXAPI sign-in notice',
          ),
          style: theme.textTheme.titleMedium,
        ),
        shape: const Border(),
        collapsedShape: const Border(),
        children: [
          Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  context.l10n.select(
                    zh: '为获取到您的Nintendo Switch Online数据，程序将要求登录您的Nintendo账户。由于Nintendo限制，在登录过程中会涉及到使用第三方Nintendo Switch Online Api以实现加密包体获取，你的 Nintendo 账号 id_token 将被发送到第三方 API（nxapi-znca-api）用于完成令牌校验。',
                    en: 'To access your Nintendo Switch Online data, the application will ask you to sign in to your Nintendo Account. Due to Nintendo restrictions, the sign-in process uses a third-party Nintendo Switch Online API to obtain encrypted request bodies. Your Nintendo Account id_token will be sent to a third-party API (nxapi-znca-api) to complete token verification.',
                  ),
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                SelectableText(
                  context.l10n.select(
                    zh: '请注意，由于涉及到了第三方Api进行操作，该操作可能存在部分风险或稳定性较差，开发者不对账户安全性进行保证。但请放心，id_token并不会泄露您的账户信息。您的Nintendo Switch Online账户数据将会被加密保存至本地。',
                    en: 'Please note that using a third-party API may involve risks or reduced reliability, and the developer cannot guarantee account security. However, please rest assured that id_token does not disclose your account information. Your Nintendo Switch Online account data will be encrypted and stored locally.',
                  ),
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  key: const Key('nxapi-provider-link'),
                  onPressed: () => _openProviderLink(context),
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  label: const Text('nxapi-znca-api'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
