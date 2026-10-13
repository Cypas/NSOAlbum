import 'dart:async';

import 'package:flutter/foundation.dart';

import '../backend/app_backend.dart';
import '../rust/models.dart';
import '../rust/settings.dart';
import 'settings_controller.dart';
import 'settings_copy.dart';
import 'sync_controller.dart';

Future<void> completeNintendoAccountLogin({
  required AppBackend backend,
  required SettingsController settings,
  required String callback,
}) async {
  await backend.completeNintendoLogin(callback);
  final policy = settings.value.syncPolicy;
  if (!policy.enabled) {
    await settings.save(
      copyAppSettings(
        settings.value,
        syncPolicy: SyncPolicy(
          enabled: true,
          activeIntervalMinutes: policy.activeIntervalMinutes,
          sleepAfterHours: policy.sleepAfterHours,
        ),
      ),
    );
  }
}

class TransferController extends ChangeNotifier {
  TransferController(
    this.backend,
    this.settings,
    this.sync, {
    this.onAccountChanged,
    this.onImported,
  });

  final AppBackend backend;
  final SettingsController settings;
  final SyncController sync;
  final Future<void> Function()? onAccountChanged;
  final VoidCallback? onImported;
  List<NintendoAccountProfile> accounts = [];
  Map<String, SyncRuntimeState> histories = {};
  String? selectedAccountId;
  List<GameTagSummary> games = [];
  List<String> paths = [];
  String gameName = '';
  ImportSummary? importSummary;
  Object? error;
  bool busy = false;
  bool disposed = false;

  void publish() {
    if (!disposed) notifyListeners();
  }

  Future<void> refresh() async {
    try {
      final nextAccounts = await backend.listNintendoAccounts();
      final nextSelected = await backend.selectedNintendoAccountId;
      final nextGames = await backend.listGameTags();
      final nextHistories = <String, SyncRuntimeState>{};
      if (backend case final SyncHistoryBackend historyBackend) {
        for (final profile in nextAccounts) {
          nextHistories[profile.accountId] = await historyBackend
              .loadSyncAccountHistory(profile.accountId);
        }
      }
      if (disposed) return;
      accounts = nextAccounts;
      selectedAccountId = nextSelected;
      games = nextGames;
      histories = nextHistories;
      error = null;
    } catch (exception) {
      if (!disposed) error = exception;
    }
    publish();
  }

  Future<bool> perform(Future<void> Function() operation) async {
    if (busy || disposed) return false;
    busy = true;
    error = null;
    publish();
    try {
      await operation();
      return true;
    } catch (exception) {
      if (!disposed) error = exception;
      return false;
    } finally {
      busy = false;
      publish();
    }
  }

  Future<bool> selectAccount(String id) => perform(() async {
    await backend.selectNintendoAccount(id);
    await refresh();
    await onAccountChanged?.call();
  });

  Future<bool> removeAccount(String id) => perform(() async {
    await backend.removeNintendoAccount(id);
    await refresh();
    await onAccountChanged?.call();
  });

  Future<bool> completeLogin(String callback) => perform(() async {
    await completeNintendoAccountLogin(
      backend: backend,
      settings: settings,
      callback: callback,
    );
    await refresh();
    await onAccountChanged?.call();
    if (!disposed) unawaited(sync.run());
  });

  void addPaths(Iterable<String> selected) {
    if (busy || disposed) return;
    paths = {...paths, ...selected}.toList();
    importSummary = null;
    publish();
  }

  Future<bool> importSelected() => perform(() async {
    if (paths.isEmpty || gameName.trim().isEmpty) {
      throw StateError('Select media and a game tag before importing.');
    }
    importSummary = await backend.importCustomFiles(
      List.of(paths),
      gameName.trim(),
    );
    onImported?.call();
    await refresh();
  });

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}
