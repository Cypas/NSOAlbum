import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../android/android_page_frame.dart';
import '../desktop_window_drag_area.dart';

class DeviceSyncFrame extends StatelessWidget {
  const DeviceSyncFrame({
    super.key,
    required this.mobile,
    required this.title,
    required this.onBack,
    required this.child,
    this.canPop = false,
  });
  final bool mobile, canPop;
  final String title;
  final VoidCallback onBack;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    void back() {
      if (MediaQuery.viewInsetsOf(context).bottom > 0) {
        FocusManager.instance.primaryFocus?.unfocus();
      } else {
        onBack();
      }
    }

    return PopScope<Object?>(
      canPop: canPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) back();
      },
      child: mobile
          ? AndroidPageFrame(
              title: title,
              secondary: true,
              onBack: back,
              child: child,
            )
          : Scaffold(
              appBar: AppBar(
                automaticallyImplyLeading: false,
                leading: IconButton(
                  tooltip: context.l10n.select(zh: '返回', en: 'Back'),
                  icon: const Icon(Icons.arrow_back),
                  onPressed: back,
                ),
                title: DesktopWindowDragArea(
                  child: SizedBox(
                    width: double.infinity,
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
              body: SafeArea(top: false, child: child),
            ),
    );
  }
}
