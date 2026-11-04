import 'package:flutter/material.dart';

import '../../backend/app_backend.dart';
import '../../backend/nintendo_account_tools_backend.dart';
import '../../l10n/app_localizations.dart';
import 'account_tool_errors.dart';
import 'gear_seed_page.dart';
import 'nintendo_friends_page.dart';
import 'splatnet_browser_page.dart';

class AccountToolsActions extends StatelessWidget {
  const AccountToolsActions({
    super.key,
    required this.backend,
    required this.profile,
    required this.mobile,
  });
  final AppBackend backend;
  final NintendoAccountProfile profile;
  final bool mobile;

  @override
  Widget build(BuildContext context) {
    final tools = backend is NintendoAccountToolsBackend
        ? backend as NintendoAccountToolsBackend
        : null;
    Future<void> page(Widget child) =>
        Navigator.of(context)
            .push<void>(MaterialPageRoute(builder: (_) => child));
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(
            onPressed: tools == null
                ? null
                : () => page(
                    NintendoFriendsPage(
                      backend: tools,
                      profile: profile,
                      mobile: mobile,
                      includeSplatoonActivity:
                          backend.settings.showSplatoonFriendActivity,
                    ),
                  ),
            icon: const Icon(Icons.people_outline),
            label: Text(context.l10n.select(zh: '好友列表', en: 'Friends')),
          ),
          OutlinedButton.icon(
            onPressed: tools == null
                ? null
                : () async {
                    try {
                      await openSplatNetPage(
                        context,
                        backend: backend,
                        profile: profile,
                        mobile: mobile,
                      );
                    } catch (error) {
                      if (!context.mounted) return;
                      await showDialog<void>(
                        context: context,
                        builder: (_) => AlertDialog(
                          content: AccountToolError(error: error),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(),
                              child: Text(
                                context.l10n.select(zh: '确定', en: 'OK'),
                              ),
                            ),
                          ],
                        ),
                      );
                    }
                  },
            icon: const Icon(Icons.language),
            label: Text(context.l10n.select(zh: '鱿鱼圈', en: 'SplatNet 3')),
          ),
          OutlinedButton.icon(
            onPressed: tools == null
                ? null
                : () => page(
                    GearSeedPage(
                      backend: tools,
                      profile: profile,
                      mobile: mobile,
                    ),
                  ),
            icon: const Icon(Icons.auto_awesome_outlined),
            label: Text(context.l10n.select(zh: '观星', en: 'Gear Seed')),
          ),
        ],
      ),
    );
  }
}
