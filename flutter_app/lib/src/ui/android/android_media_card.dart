import 'dart:io';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../rust/models.dart';
import '../../rust/settings.dart';
import '../video_thumbnail.dart';

class AndroidMediaThumbnail extends StatefulWidget {
  const AndroidMediaThumbnail({super.key, required this.asset});
  final MediaAsset asset;
  @override
  State<AndroidMediaThumbnail> createState() => _AndroidMediaThumbnailState();
}

class _AndroidMediaThumbnailState extends State<AndroidMediaThumbnail> {
  Future<VideoThumbnailData>? thumbnail;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(AndroidMediaThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset.sha256 != widget.asset.sha256) load();
  }

  void load() {
    thumbnail = widget.asset.kind == MediaKind.video
        ? VideoThumbnailCache.load(widget.asset, onError: (_, _) async {})
        : null;
  }

  @override
  Widget build(BuildContext context) {
    final placeholder = ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          widget.asset.kind == MediaKind.video
              ? Icons.videocam_outlined
              : Icons.image_outlined,
        ),
      ),
    );
    if (widget.asset.kind == MediaKind.image) {
      return Image.file(
        File(widget.asset.storagePath),
        fit: BoxFit.cover,
        cacheWidth: 600,
        errorBuilder: (_, _, _) => placeholder,
      );
    }
    return FutureBuilder<VideoThumbnailData>(
      future: thumbnail,
      builder: (_, snapshot) => snapshot.data?.bytes == null
          ? placeholder
          : Image.memory(snapshot.data!.bytes!, fit: BoxFit.cover),
    );
  }
}

class AndroidMediaCard extends StatelessWidget {
  const AndroidMediaCard({
    super.key,
    required this.asset,
    required this.settings,
    required this.onOpen,
    required this.onMenu,
    required this.onFavorite,
    this.selecting = false,
    this.selected = false,
  });
  final MediaAsset asset;
  final AppSettings settings;
  final VoidCallback onOpen;
  final VoidCallback onMenu;
  final VoidCallback onFavorite;
  final bool selecting;
  final bool selected;

  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    margin: EdgeInsets.zero,
    child: InkWell(
      onTap: onOpen,
      onLongPress: onMenu,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Stack(
              fit: StackFit.expand,
              children: [
                AndroidMediaThumbnail(asset: asset),
                Positioned(
                  top: 0,
                  right: 0,
                  child: IconButton.filledTonal(
                    tooltip: context.l10n.select(
                      zh: selecting ? '选择媒体' : '收藏',
                      en: selecting ? 'Select media' : 'Favorite',
                    ),
                    onPressed: selecting ? onOpen : onFavorite,
                    icon: Icon(
                      selecting
                          ? (selected
                                ? Icons.check_circle
                                : Icons.radio_button_unchecked)
                          : (asset.favorite
                                ? Icons.favorite
                                : Icons.favorite_border),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  asset.originalName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (settings.compactTagDisplay)
                  Text(
                    [
                      if (settings.showGameTag) asset.gameName,
                      if (asset.tags.isNotEmpty)
                        context.l10n.select(
                          zh: '${asset.tags.length} 个标签',
                          en: '${asset.tags.length} tags',
                        ),
                    ].where((text) => text.isNotEmpty).join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  )
                else ...[
                  if (settings.showGameTag)
                    Text(
                      asset.gameName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  if (asset.tags.isNotEmpty)
                    Text(
                      context.l10n.select(
                        zh: '${asset.tags.length} 个标签',
                        en: '${asset.tags.length} tags',
                      ),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
                if (settings.showNotePreview &&
                    (asset.note?.isNotEmpty ?? false))
                  Text(
                    asset.note!.characters.take(15).toString(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
