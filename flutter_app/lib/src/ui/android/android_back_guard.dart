import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

Future<bool> confirmAndroidDiscard(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          context.l10n.select(zh: '放弃未保存的修改？', en: 'Discard unsaved changes?'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.select(zh: '继续编辑', en: 'Keep editing')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.select(zh: '放弃修改', en: 'Discard')),
          ),
        ],
      ),
    ) ==
    true;

class AndroidBackGuard extends StatefulWidget {
  const AndroidBackGuard({
    super.key,
    required this.child,
    this.busy = false,
    this.dirty = false,
  });

  final Widget child;
  final bool busy;
  final bool dirty;

  static Future<void> back(BuildContext context) async {
    if (MediaQuery.viewInsetsOf(context).bottom > 0) {
      FocusManager.instance.primaryFocus?.unfocus();
      return;
    }
    final state = context.findAncestorStateOfType<_AndroidBackGuardState>();
    if (state != null) {
      await state.requestBack();
    } else {
      await Navigator.of(context).maybePop();
    }
  }

  @override
  State<AndroidBackGuard> createState() => _AndroidBackGuardState();
}

class _AndroidBackGuardState extends State<AndroidBackGuard> {
  bool confirming = false;
  bool allowPop = false;

  Future<void> requestBack() async {
    if (confirming) return;
    if (MediaQuery.viewInsetsOf(context).bottom > 0) {
      FocusManager.instance.primaryFocus?.unfocus();
      return;
    }
    if (widget.busy) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.select(
              zh: '正在处理，请稍候。',
              en: 'Processing. Please wait.',
            ),
          ),
        ),
      );
      return;
    }
    confirming = true;
    final leave = !widget.dirty || await confirmAndroidDiscard(context);
    confirming = false;
    if (!leave || !mounted) return;
    setState(() => allowPop = true);
    // Let PopScope publish the changed disposition before requesting the pop.
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => PopScope<Object?>(
    canPop:
        allowPop ||
        (!widget.busy &&
            !widget.dirty &&
            MediaQuery.viewInsetsOf(context).bottom == 0),
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) requestBack();
    },
    child: widget.child,
  );
}
