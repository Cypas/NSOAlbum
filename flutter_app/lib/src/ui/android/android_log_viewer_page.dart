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
  String value = '';
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
      final lines = <String>[];
      for (final candidate in [
        File('${file.path}.1'),
        file,
        File('${file.parent.path}/rust_core.log.1'),
        File('${file.parent.path}/rust_core.log'),
      ]) {
        if (await candidate.exists()) {
          lines.addAll(await candidate.readAsLines());
        }
      }
      lines.sort();
      if (mounted) setState(() => value = lines.takeLast(300).join('\n'));
    } catch (error, stack) {
      await widget.backend.logError('Log viewer read failed', error, stack);
      if (mounted) setState(() => failed = true);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final shown = value
        .split('\n')
        .where(
          (line) =>
              (filter.isEmpty ||
                  line.toLowerCase().contains(filter.toLowerCase())) &&
              (level.isEmpty || line.contains('[$level]')) &&
              (module.isEmpty || line.toLowerCase().contains(module)),
        )
        .join('\n');
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
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              IconButton(
                key: const Key('android-log-copy'),
                tooltip: context.l10n.select(zh: '复制日志', en: 'Copy logs'),
                onPressed: () => Clipboard.setData(
                  ClipboardData(text: androidSafeLog(shown)),
                ),
                icon: const Icon(Icons.copy_outlined),
              ),
            ],
          ),
          SelectableText(
            shown.isEmpty
                ? context.l10n.select(zh: '暂无日志', en: 'No logs yet')
                : androidSafeLog(shown),
          ),
        ],
      ),
    );
  }
}

String androidSafeLog(String value) => sanitizeDiagnostic(value);

extension on Iterable<String> {
  Iterable<String> takeLast(int count) {
    final list = toList();
    return list.length <= count ? list : list.sublist(list.length - count);
  }
}
