import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

class AppImageViewerItem {
  const AppImageViewerItem({required this.image, required this.label});

  final ImageProvider image;
  final String label;
}

Future<void> showAppImageViewer(
  BuildContext context, {
  required List<AppImageViewerItem> items,
  int initialIndex = 0,
  Future<void> Function(int index)? onSave,
}) {
  if (items.isEmpty) return Future.value();
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black87,
    builder: (context) => _AppImageViewerDialog(
      items: items,
      initialIndex: initialIndex.clamp(0, items.length - 1),
      onSave: onSave,
    ),
  );
}

class _AppImageViewerDialog extends StatefulWidget {
  const _AppImageViewerDialog({
    required this.items,
    required this.initialIndex,
    this.onSave,
  });

  final List<AppImageViewerItem> items;
  final int initialIndex;
  final Future<void> Function(int index)? onSave;

  @override
  State<_AppImageViewerDialog> createState() => _AppImageViewerDialogState();
}

class _AppImageViewerDialogState extends State<_AppImageViewerDialog> {
  late final PageController controller = PageController(
    initialPage: widget.initialIndex,
  );
  late int index = widget.initialIndex;
  bool saving = false;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void _move(int delta) {
    final target = index + delta;
    if (target < 0 || target >= widget.items.length) return;
    unawaited(
      controller.animateToPage(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  Future<void> _save() async {
    final save = widget.onSave;
    if (save == null || saving) return;
    setState(() => saving = true);
    try {
      await save(index);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Dialog.fullscreen(
    backgroundColor: const Color(0xff111318),
    child: Stack(
      children: [
        PageView.builder(
          key: const Key('app-image-viewer-pages'),
          controller: controller,
          itemCount: widget.items.length,
          onPageChanged: (value) => setState(() => index = value),
          itemBuilder: (context, itemIndex) => Padding(
            padding: const EdgeInsets.fromLTRB(72, 64, 72, 72),
            child: InteractiveViewer(
              key: ValueKey('app-image-viewer-image-$itemIndex'),
              minScale: 0.5,
              maxScale: 6,
              child: Center(
                child: Image(
                  image: widget.items[itemIndex].image,
                  fit: BoxFit.contain,
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: 18,
          top: 16,
          child: IconButton.filledTonal(
            key: const Key('app-image-viewer-close'),
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close_rounded),
          ),
        ),
        Positioned(
          right: 18,
          top: 16,
          child: Row(
            children: [
              if (widget.onSave != null)
                FilledButton.tonalIcon(
                  key: const Key('app-image-viewer-save'),
                  onPressed: saving ? null : _save,
                  icon: saving
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_alt_rounded),
                  label: Text(context.l10n.select(zh: '另存为', en: 'Save as')),
                ),
              const SizedBox(width: 12),
              Text(
                '${index + 1} / ${widget.items.length}',
                style: const TextStyle(color: Colors.white70),
              ),
            ],
          ),
        ),
        if (index > 0)
          Positioned(
            left: 18,
            top: 0,
            bottom: 0,
            child: Center(
              child: IconButton.filledTonal(
                key: const Key('app-image-viewer-previous'),
                onPressed: () => _move(-1),
                icon: const Icon(Icons.chevron_left_rounded),
              ),
            ),
          ),
        if (index + 1 < widget.items.length)
          Positioned(
            right: 18,
            top: 0,
            bottom: 0,
            child: Center(
              child: IconButton.filledTonal(
                key: const Key('app-image-viewer-next'),
                onPressed: () => _move(1),
                icon: const Icon(Icons.chevron_right_rounded),
              ),
            ),
          ),
        Positioned(
          left: 72,
          right: 72,
          bottom: 20,
          child: Text(
            widget.items[index].label,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white),
          ),
        ),
      ],
    ),
  );
}
