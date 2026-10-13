import 'dart:async';

import 'package:flutter/material.dart';

import '../../backend/app_backend.dart';
import '../../l10n/app_localizations.dart';
import '../../release_update.dart';
import '../../state/library_controller.dart';
import '../../state/settings_controller.dart';
import '../../state/sync_controller.dart';
import '../../state/transfer_controller.dart';
import 'android_albums_page.dart';
import 'android_library_page.dart';
import 'android_settings_page.dart';
import 'android_transfer_page.dart';

class AndroidShell extends StatefulWidget {
  const AndroidShell({
    super.key,
    required this.backend,
    required this.settings,
    required this.sync,
    this.onNintendoAccountChanged,
    this.onCheckForUpdates,
    this.latestReleaseVersion,
    this.updateStatus,
  });
  final AppBackend backend;
  final SettingsController settings;
  final SyncController sync;
  final Future<void> Function()? onNintendoAccountChanged;
  final Future<void> Function()? onCheckForUpdates;
  final String? latestReleaseVersion;
  final UpdateStatusKind? updateStatus;
  @override
  State<AndroidShell> createState() => _AndroidShellState();
}

class _AndroidShellState extends State<AndroidShell> {
  final navigator = GlobalKey<NavigatorState>();
  final destination = ValueNotifier<int>(0);
  late final library = LibraryController(widget.backend);
  late final transfer = TransferController(
    widget.backend,
    widget.settings,
    widget.sync,
    onAccountChanged: widget.onNintendoAccountChanged,
    onImported: library.reload,
  );
  SyncState? previous;
  @override
  void initState() {
    super.initState();
    unawaited(transfer.refresh());
    widget.sync.addListener(syncChanged);
  }

  void syncChanged() {
    if (widget.sync.state == SyncState.completed &&
        previous != SyncState.completed) {
      unawaited(library.reload());
      unawaited(transfer.refresh());
    }
    previous = widget.sync.state;
  }

  @override
  void dispose() {
    widget.sync.removeListener(syncChanged);
    library.dispose();
    transfer.dispose();
    destination.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: destination,
    builder: (context, selected, _) => PopScope<Object?>(
      canPop: selected == 0 && MediaQuery.viewInsetsOf(context).bottom == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && MediaQuery.viewInsetsOf(context).bottom > 0) {
          FocusManager.instance.primaryFocus?.unfocus();
          return;
        }
        if (!didPop && !(navigator.currentState?.canPop() ?? false)) {
          destination.value = 0;
        }
      },
      child: Scaffold(
        key: const Key('android-shell'),
        // Each page owns keyboard resizing. Resizing here would strip the
        // insets from the nested routes and their shared back guard.
        resizeToAvoidBottomInset: false,
        body: NavigatorPopHandler<Object?>(
          onPopWithResult: (_) => navigator.currentState?.maybePop(),
          child: Navigator(
            key: navigator,
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (context) => ValueListenableBuilder<int>(
                valueListenable: destination,
                builder: (context, value, _) => IndexedStack(
                  index: value,
                  children: [
                    AndroidLibraryPage(
                      controller: library,
                      settings: widget.settings,
                    ),
                    AndroidAlbumsPage(
                      backend: widget.backend,
                      settings: widget.settings,
                    ),
                    AndroidTransferPage(controller: transfer),
                    AndroidSettingsPage(
                      controller: widget.settings,
                      backend: widget.backend,
                      onCheckForUpdates: widget.onCheckForUpdates,
                      latestReleaseVersion: widget.latestReleaseVersion,
                      updateStatus: widget.updateStatus,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: selected,
          onDestinationSelected: (value) async {
            FocusManager.instance.primaryFocus?.unfocus();
            if (navigator.currentState?.canPop() ?? false) {
              // maybePop honours the active page's dirty/busy back guard.
              // popUntil would discard drafts without asking.
              await navigator.currentState?.maybePop();
              return;
            }
            destination.value = value;
          },
          destinations: [
            NavigationDestination(
              icon: const Icon(Icons.photo_library_outlined),
              label: context.l10n.select(zh: '图库', en: 'Library'),
            ),
            NavigationDestination(
              icon: const Icon(Icons.collections_bookmark_outlined),
              label: context.l10n.select(zh: '相册', en: 'Albums'),
            ),
            NavigationDestination(
              icon: const Icon(Icons.sync),
              label: context.l10n.select(zh: '导入与同步', en: 'Sync & Import'),
            ),
            NavigationDestination(
              icon: const Icon(Icons.settings_outlined),
              label: context.l10n.select(zh: '设置', en: 'Settings'),
            ),
          ],
        ),
      ),
    ),
  );
}
