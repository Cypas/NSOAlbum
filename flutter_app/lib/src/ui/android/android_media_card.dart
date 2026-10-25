import 'dart:io';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../rust/models.dart';
import '../../rust/settings.dart';
import '../video_preview_cache.dart';
import '../video_thumbnail.dart';
import 'android_tag.dart';

class AndroidMediaThumbnail extends StatefulWidget {
  const AndroidMediaThumbnail({
    super.key,
    required this.asset,
    @visibleForTesting this.requestFactory,
  });
  final MediaAsset asset;
  @visibleForTesting
  final PreviewRequest<VideoThumbnailData> Function(MediaAsset asset)?
  requestFactory;

  @override
  State<AndroidMediaThumbnail> createState() => _AndroidMediaThumbnailState();
}

class _AndroidMediaThumbnailState extends State<AndroidMediaThumbnail> {
  Future<VideoThumbnailData>? thumbnail;
  PreviewRequest<VideoThumbnailData>? thumbnailRequest;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(AndroidMediaThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset.sha256 != widget.asset.sha256 ||
        oldWidget.asset.kind != widget.asset.kind) {
      load();
    }
  }

  void load() {
    thumbnailRequest?.cancel();
    thumbnailRequest = null;
    if (widget.asset.kind != MediaKind.video) {
      thumbnail = null;
      return;
    }
    final request =
        widget.requestFactory?.call(widget.asset) ??
        VideoThumbnailCache.request(widget.asset, onError: (_, _) async {});
    thumbnailRequest = request;
    thumbnail = request.future
        .then(
          (data) => data ?? const VideoThumbnailData(),
          onError: (Object _, StackTrace _) => const VideoThumbnailData(),
        )
        .whenComplete(request.cancel);
  }

  @override
  void dispose() {
    thumbnailRequest?.cancel();
    super.dispose();
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
        cacheWidth:
            (MediaQuery.sizeOf(context).width *
                    MediaQuery.devicePixelRatioOf(context) /
                    2)
                .round()
                .clamp(160, 720),
        errorBuilder: (_, _, _) => placeholder,
      );
    }
    return FutureBuilder<VideoThumbnailData>(
      future: thumbnail,
      builder: (_, snapshot) => Stack(
        fit: StackFit.expand,
        children: [
          snapshot.data?.bytes == null
              ? placeholder
              : Image.memory(
                  snapshot.data!.bytes!,
                  fit: BoxFit.cover,
                  cacheWidth: 360,
                ),
          if ((snapshot.data?.duration ?? Duration.zero) > Duration.zero)
            Positioned(
              right: 5,
              bottom: 5,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: .75),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 1,
                  ),
                  child: Text(
                    '▶ ${androidDuration(snapshot.data!.duration)}',
                    style: const TextStyle(color: Colors.white, fontSize: 10),
                  ),
                ),
              ),
            ),
        ],
      ),
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
                    style: IconButton.styleFrom(
                      minimumSize: const Size(26, 26),
                      padding: const EdgeInsets.all(4),
                    ),
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
                      size: selecting ? 16 : 22,
                      color: !selecting && asset.favorite ? Colors.red : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 7),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Wrap(
                  spacing: 4,
                  runSpacing: 3,
                  children: [
                    if (settings.showGameTag && asset.gameName.isNotEmpty)
                      AndroidTag(
                        label: asset.gameName,
                        game: true,
                        compact: true,
                      ),
                    for (final tag in asset.tags)
                      AndroidTag(label: tag, compact: true),
                  ],
                ),
                if (settings.showNotePreview &&
                    asset.note?.trim().isNotEmpty == true) ...[
                  const SizedBox(height: 3),
                  Text(
                    _notePreview(asset.note!),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

String _notePreview(String value) {
  final characters = value.trim().characters;
  return characters.length <= 15
      ? characters.toString()
      : '${characters.take(15)}…';
}

String androidDuration(Duration value) {
  final hours = value.inHours;
  final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$minutes:$seconds' : '${value.inMinutes}:$seconds';
}
