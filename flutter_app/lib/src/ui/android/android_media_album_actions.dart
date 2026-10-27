import 'package:flutter/material.dart';

import '../../backend/app_backend.dart';
import '../../l10n/app_localizations.dart';
import '../../rust/models.dart';
import '../device_sync/album_source_label.dart';

Future<void> showAndroidMediaAlbumAction(
  BuildContext context, {
  required AppBackend backend,
  required MediaAsset item,
  AlbumSummary? sourceAlbum,
  required bool move,
}) async {
  final albums = (await backend.listAlbums())
      .where(
        (album) =>
            album.albumType == 'manual' &&
            (!move || sourceAlbum == null || album.id != sourceAlbum.id),
      )
      .toList();
  if (!context.mounted) return;
  final target = await showDialog<AlbumSummary>(
    context: context,
    builder: (dialogContext) => SimpleDialog(
      title: Text(
        context.l10n.select(
          zh: move ? '移动到普通相册' : '复制到普通相册',
          en: move ? 'Move to regular album' : 'Copy to regular album',
        ),
      ),
      children: [
        if (albums.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              context.l10n.select(
                zh: '请先创建普通相册。',
                en: 'Create a regular album first.',
              ),
            ),
          ),
        for (final album in albums)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogContext, album),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(album.name),
                AlbumSourceLabel(
                  name: album.sourceDeviceName,
                  systemKey: album.systemKey,
                ),
              ],
            ),
          ),
      ],
    ),
  );
  if (target == null || !context.mounted) return;
  await backend.addMediaToAlbum(target.id, item.id);
  if (move && sourceAlbum?.albumType == 'manual') {
    await backend.removeMediaFromAlbum(sourceAlbum!.id, item.id);
  }
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          context.l10n.select(
            zh: move ? '已移动到“${target.name}”。' : '已复制到“${target.name}”。',
            en: move
                ? 'Moved to “${target.name}”.'
                : 'Copied to “${target.name}”.',
          ),
        ),
      ),
    );
  }
}
