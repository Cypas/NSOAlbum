import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../android/android_back_guard.dart';
import '../android/android_page_frame.dart';
import '../desktop_window_drag_area.dart';

class AccountToolFrame extends StatelessWidget {
  const AccountToolFrame({
    super.key,
    required this.mobile,
    required this.title,
    required this.child,
    this.actions,
    this.onBack,
  });

  final bool mobile;
  final String title;
  final Widget child;
  final List<Widget>? actions;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    if (mobile) {
      final frame = AndroidPageFrame(
        title: title,
        secondary: true,
        onBack: onBack,
        actions: actions,
        child: child,
      );
      // A browser owns system back as well as its arrow (keyboard/history/pop).
      return onBack == null ? AndroidBackGuard(child: frame) : frame;
    }
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: IconButton(
          tooltip: context.l10n.select(zh: '返回', en: 'Back'),
          onPressed: onBack ?? () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.arrow_back),
        ),
        title: DesktopWindowDragArea(
          child: SizedBox(width: double.infinity, child: Text(title)),
        ),
        actions: actions,
      ),
      body: SafeArea(top: false, child: child),
    );
  }
}
