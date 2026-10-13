import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import 'android_back_guard.dart';
import 'android_layout.dart';

class AndroidPageFrame extends StatelessWidget {
  const AndroidPageFrame({
    super.key,
    required this.title,
    required this.child,
    this.actions,
    this.secondary = false,
    this.onBack,
  });

  final String title;
  final Widget child;
  final List<Widget>? actions;
  final bool secondary;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      automaticallyImplyLeading: false,
      leading: secondary
          ? IconButton(
              key: const Key('android-page-back'),
              tooltip: context.l10n.select(zh: '返回', en: 'Back'),
              icon: const Icon(Icons.arrow_back),
              onPressed: onBack ?? () => AndroidBackGuard.back(context),
            )
          : null,
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: actions,
    ),
    body: SafeArea(top: false, child: child),
  );
}

class AndroidPageList extends StatelessWidget {
  const AndroidPageList({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => ListView(
    padding: EdgeInsets.all(
      androidPagePadding(MediaQuery.sizeOf(context).width),
    ),
    children: [
      for (final child in children)
        Padding(padding: const EdgeInsets.only(bottom: 12), child: child),
    ],
  );
}

void androidMessage(BuildContext context, Object error) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: SelectableText(error.toString()),
      duration: const Duration(seconds: 8),
    ),
  );
}
