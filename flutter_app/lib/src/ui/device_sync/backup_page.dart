import 'dart:async';

import 'package:flutter/material.dart';

import '../../backend/device_sync/account_gate.dart';
import '../../backend/device_sync/service_contract.dart';
import '../../l10n/app_localizations.dart';
import '../display_time.dart';
import 'display.dart';
import 'frame.dart';

class DeviceSyncBackupPage extends StatefulWidget {
  const DeviceSyncBackupPage({
    super.key,
    required this.browser,
    required this.mobile,
    this.onLibraryChanged,
  });
  final DeviceBackupBrowserController browser;
  final bool mobile;
  final Future<void> Function()? onLibraryChanged;
  @override
  State<DeviceSyncBackupPage> createState() => _DeviceSyncBackupPageState();
}

class _DeviceSyncBackupPageState extends State<DeviceSyncBackupPage> {
  DeviceBackupPageView? _page;
  DeviceRestorePreviewView? _preview;
  Object? _error;
  DeviceRestoreResult? _result;
  bool _busy = false, _leaving = false, _allowPop = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_act(() => _load()));
    });
  }

  Future<void> _act(Future<void> Function() operation) async {
    if (_busy || _leaving || widget.browser.closed) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await operation();
    } catch (error) {
      if (mounted && !_leaving) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load({String? cursor}) async {
    final page = await widget.browser.page(cursor: cursor);
    if (mounted && !_leaving) {
      setState(() {
        _page = page;
        _preview = null;
      });
    }
  }

  Future<void> _prepare(DeviceBackupEntry entry) async {
    var authorized = false;
    if (entry.metadata.includesAccounts == true) {
      authorized =
          await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              scrollable: true,
              title: Text(
                context.l10n.select(
                  zh: '允许读取账号恢复预览？',
                  en: 'Allow account restore preview?',
                ),
              ),
              content: Text(
                context.l10n.select(
                  zh: '此备份包含全部账号与登录凭据。允许后才会读取系统安全存储以比较账号变化；这不会确认恢复。拒绝不会读取账号材料。',
                  en: 'This backup includes accounts and sign-in credentials. Allow protected storage reads to compare account changes. This does not confirm restoration. Declining reads no account materials.',
                ),
              ),
              actions: [
                TextButton(
                  key: const Key('device-decline-account-preview'),
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(context.l10n.select(zh: '取消', en: 'Cancel')),
                ),
                FilledButton(
                  key: const Key('device-allow-account-preview'),
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(
                    context.l10n.select(
                      zh: '允许读取预览',
                      en: 'Allow preview reads',
                    ),
                  ),
                ),
              ],
            ),
          ) ==
          true;
      if (!authorized || !mounted || _leaving) return;
    }
    final preview = await widget.browser.prepareRestore(
      entry,
      accountsAuthorized: authorized,
    );
    if (mounted && !_leaving) {
      setState(() {
        _preview = preview;
        _result = null;
      });
    }
  }

  Future<void> _confirm(DeviceRestorePreviewView shown) async {
    try {
      final result = await widget.browser.confirmRestore(shown);
      if (result.finalized) await widget.onLibraryChanged?.call();
      if (mounted && !_leaving) {
        setState(() {
          _result = result;
          _preview = null;
        });
        if (result.finalized && !result.cleanupPending) await _load();
      }
    } catch (_) {
      if (mounted) setState(() => _preview = null);
      rethrow;
    }
  }

  Future<void> _back() async {
    if (_leaving) return;
    final browser = widget.browser;
    final route = ModalRoute.of(context);
    setState(() => _leaving = true);
    try {
      await browser.close();
      if (!mounted || !identical(browser, widget.browser)) return;
      if (!browser.settled) throw const DeviceSyncBusy();
      setState(() => _allowPop = true);
      await WidgetsBinding.instance.endOfFrame;
      if (mounted &&
          identical(browser, widget.browser) &&
          route?.isCurrent == true) {
        Navigator.of(context).pop();
      } else if (mounted && identical(browser, widget.browser)) {
        setState(() => _leaving = false);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error;
          _leaving = false;
        });
      }
    }
  }

  @override
  void dispose() {
    unawaited(widget.browser.close().catchError((Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DeviceSyncFrame(
    mobile: widget.mobile,
    title: context.l10n.select(zh: '备份与恢复', en: 'Backups and restore'),
    onBack: () => unawaited(_back()),
    canPop: _allowPop,
    child: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          context.l10n.select(
            zh: '同步覆盖与恢复前保留的备份不会自动删除。恢复前会比较变化，并保留本机当前数据的安全备份。',
            en: 'Backups retained before overwrite or restore are not automatically deleted. Review changes before restoring. A safety backup of the current library is retained.',
          ),
        ),
        if (_busy || _leaving)
          Text(
            context.l10n.select(
              zh: '正在安全处理，请稍候…',
              en: 'Processing safely. Please wait…',
            ),
          ),
        if (_error case final error?)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(deviceSyncError(context, error)),
          ),
        if (_result case final result?)
          Text(
            result.finalized
                ? result.cleanupPending
                      ? context.l10n.select(
                          zh: '恢复已提交，仍需完成安全清理。',
                          en: 'Restore committed; safe cleanup is still pending.',
                        )
                      : context.l10n.select(
                          zh: '恢复完成。已保留恢复前安全备份。',
                          en: 'Restore complete. A pre-restore safety backup was retained.',
                        )
                : context.l10n.select(
                    zh: '恢复尚未完成，需要数据恢复检查。',
                    en: 'Restore is incomplete. A data recovery check is required.',
                  ),
          ),
        if (_preview case final preview?) ...[
          DeviceChangeCounts(
            title: context.l10n.select(zh: '媒体', en: 'Media'),
            counts: preview.library.media,
          ),
          DeviceChangeCounts(
            title: context.l10n.select(zh: '相册', en: 'Albums'),
            counts: preview.library.albums,
          ),
          if (preview.accounts case final accounts?)
            DeviceAccountChanges(counts: accounts)
          else
            Text(
              context.l10n.select(
                zh: '账号保持不变。',
                en: 'Accounts remain unchanged.',
              ),
            ),
          Text(
            context.l10n.select(
              zh: '恢复将替换本机当前图库。请选择下方确认后才会写入。',
              en: 'Restore replaces this device’s current library. Nothing is written until you confirm below.',
            ),
          ),
          FilledButton(
            key: const Key('device-confirm-restore'),
            onPressed: _busy || _leaving
                ? null
                : () => _act(() => _confirm(preview)),
            child: Text(
              context.l10n.select(
                zh: '确认在本机恢复',
                en: 'Confirm restore on this device',
              ),
            ),
          ),
          OutlinedButton(
            key: const Key('device-discard-restore'),
            onPressed: _busy || _leaving
                ? null
                : () => _act(() async {
                    await widget.browser.discardPreview();
                    if (mounted) setState(() => _preview = null);
                  }),
            child: Text(
              context.l10n.select(zh: '放弃此预览', en: 'Discard this preview'),
            ),
          ),
        ] else ...[
          if (_page?.items.isEmpty == true)
            Text(context.l10n.select(zh: '没有可用备份。', en: 'No backups found.')),
          for (var i = 0; i < (_page?.items.length ?? 0); i++)
            _entry(_page!.items[i], i),
          if (_page?.next case final cursor?)
            OutlinedButton(
              key: const Key('device-backup-next'),
              onPressed: _busy || _leaving
                  ? null
                  : () => _act(() => _load(cursor: cursor)),
              child: Text(context.l10n.select(zh: '下一页', en: 'Next page')),
            ),
          OutlinedButton(
            key: const Key('device-backup-reload'),
            onPressed: _busy || _leaving ? null : () => _act(() => _load()),
            child: Text(
              context.l10n.select(zh: '刷新备份列表', en: 'Refresh backups'),
            ),
          ),
        ],
      ],
    ),
  );

  Widget _entry(DeviceBackupEntry entry, int index) {
    final metadata = entry.metadata;
    final eligible =
        metadata.backup != null &&
        metadata.includesAccounts != null &&
        metadata.unavailableReason == null;
    final parsed = metadata.createdAt == null
        ? null
        : DateTime.tryParse(metadata.createdAt!);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              metadata.sourceName ??
                  context.l10n.select(
                    zh: '未知来源设备',
                    en: 'Unknown source device',
                  ),
            ),
            Text(
              parsed == null
                  ? context.l10n.select(zh: '备份时间未知', en: 'Backup time unknown')
                  : formatUserDateTime(parsed),
            ),
            Text(
              metadata.includesAccounts == null
                  ? context.l10n.select(
                      zh: '账号范围未知，不能恢复。',
                      en: 'Unknown account scope; restoration is unavailable.',
                    )
                  : metadata.includesAccounts!
                  ? context.l10n.select(
                      zh: '包含账号与登录凭据',
                      en: 'Includes accounts and sign-in credentials',
                    )
                  : context.l10n.select(
                      zh: '仅图库，账号保持不变',
                      en: 'Library only; accounts remain unchanged',
                    ),
            ),
            if (metadata.unavailableReason != null || metadata.backup == null)
              Text(
                context.l10n.select(
                  zh: '此备份不完整、不可读取或仅用于内部恢复，无法在此恢复。',
                  en: 'This backup is incomplete, unreadable, or reserved for internal recovery and cannot be restored here.',
                ),
              ),
            if (eligible)
              OutlinedButton(
                key: Key('device-backup-preview-$index'),
                onPressed: _busy || _leaving
                    ? null
                    : () => _act(() => _prepare(entry)),
                child: Text(
                  context.l10n.select(
                    zh: '查看恢复预览',
                    en: 'Review restore changes',
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
