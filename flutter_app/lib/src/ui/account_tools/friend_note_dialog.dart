import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../android/android_page_frame.dart';

/// Owns the editor until the dialog's route has finished leaving the overlay.
Future<String?> showFriendNoteDialog(
  BuildContext context,
  String note, {
  required Future<void> Function(String) onSave,
}) => showDialog<String>(
  context: context,
  builder: (_) => _FriendNoteDialog(note: note, onSave: onSave),
);

class _FriendNoteDialog extends StatefulWidget {
  const _FriendNoteDialog({required this.note, required this.onSave});
  final String note;
  final Future<void> Function(String) onSave;

  @override
  State<_FriendNoteDialog> createState() => _FriendNoteDialogState();
}

class _FriendNoteDialogState extends State<_FriendNoteDialog> {
  late final input = TextEditingController(text: widget.note);
  bool saving = false;
  Object? error;

  Future<void> save() async {
    if (saving) return;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final note = input.text;
      await widget.onSave(note);
      if (mounted) Navigator.pop(context, note);
    } catch (failure) {
      if (mounted) setState(() => error = failure);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !saving,
    child: AlertDialog(
      title: Text(context.l10n.select(zh: '编辑备注', en: 'Edit note')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: input,
            maxLength: 20,
            autofocus: true,
            enabled: !saving,
          ),
          if (error != null) Text(androidReadableError(context, error!)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: saving ? null : () => Navigator.pop(context),
          child: Text(context.l10n.select(zh: '取消', en: 'Cancel')),
        ),
        FilledButton(
          onPressed: saving ? null : save,
          child: Text(context.l10n.select(zh: '保存', en: 'Save')),
        ),
      ],
    ),
  );
}
