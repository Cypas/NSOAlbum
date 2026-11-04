import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../backend/app_backend.dart';
import '../../backend/app_logger.dart';
import '../../l10n/app_localizations.dart';
import 'android_page_frame.dart';

class AndroidLogViewerPage extends StatefulWidget {
  const AndroidLogViewerPage({super.key, required this.backend});
  final AppBackend backend;

  @override
  State<AndroidLogViewerPage> createState() => _AndroidLogViewerPageState();
}

class _AndroidLogViewerPageState extends State<AndroidLogViewerPage> {
  List<_LogBlock> entries = [];
  String filter = '';
  String level = '';
  String module = '';
  bool loading = false;
  bool failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    if (loading) return;
    setState(() {
      loading = true;
      failed = false;
    });
    try {
      final file = File(widget.backend.logFilePath);
      final blocks = <_LogBlock>[];
      final seenPaths = <String>{};
      for (final candidate in [
        File('${file.path}.1'),
        file,
        File('${file.parent.path}/rust_core.log.1'),
        File('${file.parent.path}/rust_core.log'),
      ]) {
        if (seenPaths.add(candidate.absolute.path) &&
            await candidate.exists()) {
          blocks.addAll(_parseLogBlocks(await candidate.readAsLines()));
        }
      }
      final ordered = blocks.indexed.toList()
        ..sort((left, right) {
          final time = left.$2.timestamp.compareTo(right.$2.timestamp);
          return time != 0 ? time : left.$1.compareTo(right.$1);
        });
      if (mounted) {
        setState(
          () => entries = ordered
              .skip(ordered.length > 300 ? ordered.length - 300 : 0)
              .map((entry) => entry.$2)
              .toList(),
        );
      }
    } catch (error, stack) {
      await widget.backend.logError('Log viewer read failed', error, stack);
      if (mounted) setState(() => failed = true);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final shown = entries
        .where(
          (entry) =>
              (filter.isEmpty ||
                  entry.text.toLowerCase().contains(filter.toLowerCase())) &&
              (level.isEmpty || entry.text.contains('[$level]')) &&
              (module.isEmpty || entry.text.toLowerCase().contains(module)),
        )
        .toList();
    return AndroidPageFrame(
      title: context.l10n.select(zh: '最近日志', en: 'Recent logs'),
      secondary: true,
      actions: [
        IconButton(
          tooltip: context.l10n.select(zh: '刷新', en: 'Refresh'),
          onPressed: loading ? null : _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
      child: AndroidPageList(
        children: [
          if (loading) const LinearProgressIndicator(),
          if (failed)
            Text(
              context.l10n.select(
                zh: '无法读取日志，请重试。',
                en: 'Unable to read logs. Please retry.',
              ),
            ),
          Wrap(
            spacing: 8,
            children: [
              DropdownButton<String>(
                key: const Key('android-log-level'),
                value: level,
                items: [
                  DropdownMenuItem(
                    value: '',
                    child: Text(
                      context.l10n.select(zh: '全部级别', en: 'All levels'),
                    ),
                  ),
                  for (final item in ['INFO', 'ERROR'])
                    DropdownMenuItem(value: item, child: Text(item)),
                ],
                onChanged: (next) => setState(() => level = next ?? ''),
              ),
              DropdownButton<String>(
                key: const Key('android-log-module'),
                value: module,
                items: [
                  DropdownMenuItem(
                    value: '',
                    child: Text(
                      context.l10n.select(zh: '全部模块', en: 'All modules'),
                    ),
                  ),
                  for (final entry in {
                    'sync': context.l10n.select(zh: '同步', en: 'Sync'),
                    'network': context.l10n.select(zh: '网络', en: 'Network'),
                    'splatnet': context.l10n.select(zh: '鱿鱼圈', en: 'SplatNet'),
                    'device_sync': context.l10n.select(
                      zh: '设备同步',
                      en: 'Device sync',
                    ),
                  }.entries)
                    DropdownMenuItem(
                      value: entry.key,
                      child: Text(entry.value),
                    ),
                ],
                onChanged: (next) => setState(() => module = next ?? ''),
              ),
            ],
          ),
          TextField(
            key: const Key('android-log-filter'),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.filter_alt_outlined),
              hintText: context.l10n.select(zh: '筛选日志', en: 'Filter logs'),
            ),
            onChanged: (next) => setState(() => filter = next),
          ),
          if (shown.isEmpty)
            Text(context.l10n.select(zh: '暂无日志', en: 'No logs yet')),
          for (final entry in shown)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (entry.text.contains('[ERROR]'))
                  Align(
                    alignment: Alignment.centerRight,
                    child: IconButton(
                      key: const Key('android-log-copy'),
                      tooltip: context.l10n.select(
                        zh: '复制脱敏诊断',
                        en: 'Copy redacted diagnostic',
                      ),
                      onPressed: () => Clipboard.setData(
                        ClipboardData(text: androidSafeLog(entry.text)),
                      ),
                      icon: const Icon(Icons.copy_outlined),
                    ),
                  ),
                SelectionArea(
                  child: SelectableText(androidSafeLog(entry.text)),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

String androidSafeLog(String value) => sanitizeDiagnostic(value);

class _LogBlock {
  const _LogBlock(this.timestamp, this.text);
  final DateTime timestamp;
  final String text;
}

List<_LogBlock> _parseLogBlocks(List<String> lines) {
  final header = RegExp(r'^(\d{4}-\d{2}-\d{2}T\S+)\s+\[[A-Z]+\]');
  final result = <_LogBlock>[];
  var timestamp = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  var content = <String>[];
  void finish() {
    if (content.isEmpty) return;
    result.add(
      _LogBlock(
        timestamp,
        collapseRepeatedAsyncSuspension(content.join('\n').trimRight()),
      ),
    );
    content = [];
  }

  for (final line in lines) {
    final match = header.firstMatch(line);
    final next = match == null ? null : DateTime.tryParse(match[1]!);
    if (next != null) {
      finish();
      timestamp = next;
    }
    content.add(line);
  }
  finish();
  return result;
}
