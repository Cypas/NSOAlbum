import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../backend/app_backend.dart';
import '../../backend/nintendo_account_tools_backend.dart';
import '../../l10n/app_localizations.dart';
import '../../rust/models.dart';
import 'account_tool_errors.dart';
import 'account_tool_frame.dart';
import 'account_tool_operation.dart';

class GearSeedPage extends StatefulWidget {
  const GearSeedPage({
    super.key,
    required this.backend,
    required this.profile,
    required this.mobile,
    this.saveExport,
  });
  final NintendoAccountToolsBackend backend;
  final NintendoAccountProfile profile;
  final bool mobile;
  final Future<String?> Function(SeedExportPayload payload)? saveExport;
  @override
  State<GearSeedPage> createState() => _GearSeedPageState();
}

class _GearSeedPageState extends State<GearSeedPage> {
  String? operationId;
  bool saving = false;
  Object? error;
  String? message;

  Future<void> export() async {
    if (operationId != null || saving) return;
    final id = accountToolOperationId('seed-export');
    setState(() {
      operationId = id;
      error = null;
      message = null;
    });
    try {
      final payload = await widget.backend.prepareSeedExport(
        widget.profile.accountId,
        id,
      );
      if (!mounted || operationId != id) return;
      setState(() => saving = true);
      final path =
          await (widget.saveExport?.call(payload) ??
              FilePicker.saveFile(
                fileName: payload.fileName,
                bytes: payload.bytes,
                mimeType: 'application/json',
                dialogTitle: context.l10n.select(
                  zh: '保存观星文件',
                  en: 'Save gear seed JSON',
                ),
              ));
      if (mounted && operationId == id && path != null) {
        setState(() => message = context.l10n.select(zh: '已保存', en: 'Saved'));
      }
    } catch (failure) {
      if (mounted && operationId == id) setState(() => error = failure);
    } finally {
      if (mounted && operationId == id) {
        setState(() {
          operationId = null;
          saving = false;
        });
      }
    }
  }

  void cancel() {
    final id = operationId;
    if (id == null || saving) return;
    setState(() {
      operationId = null;
      message = context.l10n.select(zh: '操作已取消。', en: 'Operation cancelled.');
    });
    unawaited(cancelAccountToolQuietly(widget.backend, id));
  }

  Future<void> tutorial() async {
    try {
      final opened = await launchUrl(
        Uri.parse('https://blog.ayano.top/archives/525/'),
        mode: LaunchMode.externalApplication,
      );
      if (!opened) throw StateError('browser unavailable');
    } catch (failure) {
      if (mounted) setState(() => error = failure);
    }
  }

  @override
  void dispose() {
    final id = operationId;
    operationId = null;
    if (id != null) unawaited(cancelAccountToolQuietly(widget.backend, id));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AccountToolFrame(
    mobile: widget.mobile,
    title: context.l10n.select(zh: '观星', en: 'Gear Seed'),
    child: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(widget.profile.nickname),
        const SizedBox(height: 16),
        Card(
          child: ListTile(
            leading: const Icon(Icons.open_in_browser),
            title: Text(context.l10n.select(zh: '观星教程', en: 'Gear seed guide')),
            onTap: tutorial,
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: operationId != null || saving ? null : export,
          icon: operationId != null || saving
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.download),
          label: Text(
            context.l10n.select(
              zh: saving
                  ? '请选择保存位置…'
                  : operationId != null
                  ? '正在获取观星数据…'
                  : '下载喷三观星文件',
              en: saving
                  ? 'Choose a save location…'
                  : operationId != null
                  ? 'Fetching gear data…'
                  : 'Export Splatoon 3 gear JSON',
            ),
          ),
        ),
        if (operationId != null && !saving) ...[
          const LinearProgressIndicator(),
          TextButton(
            onPressed: cancel,
            child: Text(context.l10n.select(zh: '取消', en: 'Cancel')),
          ),
        ],
        if (error != null) AccountToolError(error: error!, onRetry: export),
        if (message != null) Semantics(liveRegion: true, child: Text(message!)),
      ],
    ),
  );
}
