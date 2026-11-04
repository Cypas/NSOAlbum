import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import 'android_back_guard.dart';

/// The route owns its input until its exit transition has finished.
Future<String?> androidTextPrompt(
  BuildContext context, {
  required String title,
  String initialValue = '',
  String? hint,
  String? confirmLabel,
}) => showDialog<String>(
  context: context,
  builder: (_) => _TextPrompt(
    title: title,
    initialValue: initialValue,
    hint: hint,
    confirmLabel: confirmLabel,
  ),
);

class _TextPrompt extends StatefulWidget {
  const _TextPrompt({
    required this.title,
    required this.initialValue,
    this.hint,
    this.confirmLabel,
  });

  final String title;
  final String initialValue;
  final String? hint;
  final String? confirmLabel;

  @override
  State<_TextPrompt> createState() => _TextPromptState();
}

class _TextPromptState extends State<_TextPrompt> {
  late final input = TextEditingController(text: widget.initialValue);

  @override
  void initState() {
    super.initState();
    input.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AndroidBackGuard(
    dirty: input.text != widget.initialValue,
    child: AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: input,
        autofocus: true,
        decoration: InputDecoration(hintText: widget.hint),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: Text(context.l10n.select(zh: '取消', en: 'Cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, input.text.trim()),
          child: Text(
            widget.confirmLabel ?? context.l10n.select(zh: '保存', en: 'Save'),
          ),
        ),
      ],
    ),
  );
}
