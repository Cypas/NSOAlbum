import 'package:flutter/material.dart';

import '../../backend/app_backend.dart';
import '../../l10n/app_localizations.dart';
import 'account_tools_actions.dart';

/// Keeps desktop selection/portrait hit targets separate from tool expansion.
class AccountToolsExpander extends StatefulWidget {
  const AccountToolsExpander({
    super.key,
    required this.header,
    required this.backend,
    required this.profile,
    this.selected = false,
    this.onHeaderTap,
  });
  final Widget header;
  final AppBackend backend;
  final NintendoAccountProfile profile;
  final bool selected;
  final VoidCallback? onHeaderTap;
  @override
  State<AccountToolsExpander> createState() => _AccountToolsExpanderState();
}

class _AccountToolsExpanderState extends State<AccountToolsExpander> {
  bool expanded = false;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      key: Key('nintendo-account-bubble-${widget.profile.accountId}'),
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      color: null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outlineVariant, width: .8),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () {
            widget.onHeaderTap?.call();
            _toggle();
          },
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(child: widget.header),
                    IconButton(
                      key: Key(
                        'account-tools-expand-${widget.profile.accountId}',
                      ),
                      tooltip: expanded
                          ? context.l10n.select(
                              zh: '收起账号工具',
                              en: 'Collapse account tools',
                            )
                          : context.l10n.select(
                              zh: '展开账号工具',
                              en: 'Expand account tools',
                            ),
                      isSelected: expanded,
                      onPressed: _toggle,
                      icon: Icon(
                        expanded ? Icons.expand_less : Icons.expand_more,
                      ),
                    ),
                  ],
                ),
                if (expanded)
                  AccountToolsActions(
                    backend: widget.backend,
                    profile: widget.profile,
                    mobile: false,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _toggle() {
    if (!mounted) return;
    setState(() => expanded = !expanded);
  }
}
