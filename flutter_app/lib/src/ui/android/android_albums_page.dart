import 'package:flutter/material.dart';

import '../../backend/app_backend.dart';
import '../../l10n/app_localizations.dart';
import '../../rust/models.dart';
import '../../state/library_controller.dart';
import '../../state/settings_controller.dart';
import 'android_album_editor.dart';
import 'android_library_page.dart';
import 'android_layout.dart';
import 'android_media_card.dart';
import 'android_page_frame.dart';
import '../device_sync/album_source_label.dart';

class AndroidAlbumsPage extends StatefulWidget {
  const AndroidAlbumsPage({
    super.key,
    required this.backend,
    required this.settings,
    this.revision = 0,
  });
  final AppBackend backend;
  final SettingsController settings;
  final int revision;
  @override
  State<AndroidAlbumsPage> createState() => _AndroidAlbumsPageState();
}

class _AndroidAlbumsPageState extends State<AndroidAlbumsPage> {
  late Future<List<_AlbumEntry>> albums = loadAlbums();
  Future<List<_AlbumEntry>> loadAlbums() async {
    final values = await widget.backend.listAlbums();
    final entries = <_AlbumEntry>[];
    for (final album in values) {
      final media = album.mediaCount == BigInt.zero
          ? <MediaAsset>[]
          : await widget.backend.listMedia(albumId: album.id, limit: 1);
      entries.add(_AlbumEntry(album, media.firstOrNull));
    }
    return entries;
  }

  void reload() {
    if (mounted) {
      setState(() {
        albums = loadAlbums();
      });
    }
  }

  @override
  void didUpdateWidget(AndroidAlbumsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision) reload();
  }

  Future<void> edit([AlbumSummary? album]) async {
    await Navigator.of(context).push(
      MaterialPageRoute<bool>(
        builder: (_) =>
            AndroidAlbumEditor(backend: widget.backend, album: album),
      ),
    );
    reload();
  }

  @override
  Widget build(BuildContext context) => AndroidPageFrame(
    title: context.l10n.select(zh: '相册', en: 'Albums'),
    actions: [
      IconButton(
        tooltip: context.l10n.select(zh: '创建相册', en: 'Create album'),
        onPressed: edit,
        icon: const Icon(Icons.add),
      ),
    ],
    child: FutureBuilder<List<_AlbumEntry>>(
      future: albums,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return AndroidPageList(
            children: [
              Text(androidReadableError(context, snapshot.error!)),
              TextButton(
                onPressed: reload,
                child: Text(context.l10n.select(zh: '重试', en: 'Retry')),
              ),
            ],
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final values = List.of(snapshot.data!)
          ..sort((a, b) {
            if (a.album.systemKey == 'favorites') return -1;
            if (b.album.systemKey == 'favorites') return 1;
            return 0;
          });
        return AnimatedBuilder(
          animation: widget.settings,
          builder: (context, _) => LayoutBuilder(
            builder: (context, constraints) {
              final padding = androidPagePadding(constraints.maxWidth);
              final spacing = androidCardSpacing(constraints.maxWidth);
              final columns = androidGalleryColumns(
                width: constraints.maxWidth - padding * 2,
                preferredColumns: widget.settings.value.galleryColumns,
                textScaler: MediaQuery.textScalerOf(context),
                spacing: spacing,
              );
              final tileWidth =
                  (constraints.maxWidth -
                      padding * 2 -
                      spacing * (columns - 1)) /
                  columns;
              return GridView.builder(
                padding: EdgeInsets.all(padding),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  crossAxisSpacing: spacing,
                  mainAxisSpacing: spacing,
                  // Keep the preview at 16:9, but reduce the total card
                  // height reserved for the metadata/actions below it.
                  // This is intentionally separate from the preview ratio.
                  mainAxisExtent:
                      tileWidth * 9 / 16 +
                      MediaQuery.textScalerOf(context).scale(14) * 7 +
                      26,
                ),
                itemCount: values.length,
                itemBuilder: (context, index) {
                  final album = values[index].album;
                  return Card(
                    key: ValueKey('android-album-${album.id}'),
                    elevation: 4,
                    shadowColor: Theme.of(context).colorScheme.shadow
                        .withValues(alpha: .35),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        AspectRatio(
                          aspectRatio: 16 / 9,
                          child: InkWell(
                            onTap: () => openAlbum(album),
                            child: values[index].cover != null
                                ? AndroidMediaThumbnail(
                                    asset: values[index].cover!,
                                  )
                                : ColoredBox(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .surfaceContainerHighest,
                                    child: Icon(
                                      album.systemKey == 'favorites'
                                          ? Icons.favorite
                                          : Icons.photo_album_outlined,
                                    ),
                                  ),
                          ),
                        ),
                        Expanded(
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 10,
                            ),
                            title: Text(
                              album.systemKey == 'favorites'
                                  ? context.l10n.select(
                                      zh: '收藏',
                                      en: 'Favorites',
                                    )
                                  : album.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  context.l10n.select(
                                    zh: '${album.mediaCount} 个媒体',
                                    en: '${album.mediaCount} media',
                                  ),
                                ),
                                Text(
                                  context.l10n.select(
                                    zh: album.albumType == 'smart'
                                        ? '自动相册'
                                        : '普通相册',
                                    en: album.albumType == 'smart'
                                        ? 'Smart album'
                                        : 'Regular album',
                                  ),
                                  key: Key('android-album-type-${album.id}'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                                AlbumSourceLabel(
                                  name: album.sourceDeviceName,
                                  systemKey: album.systemKey,
                                ),
                              ],
                            ),
                            trailing: album.systemKey != null
                                ? null
                                : PopupMenuButton<String>(
                                    tooltip: context.l10n.select(
                                      zh: '更多',
                                      en: 'More',
                                    ),
                                    itemBuilder: (_) => [
                                      PopupMenuItem(
                                        value: 'edit',
                                        child: Text(
                                          context.l10n.select(
                                            zh: '编辑相册',
                                            en: 'Edit album',
                                          ),
                                        ),
                                      ),
                                      PopupMenuItem(
                                        value: 'delete',
                                        child: Text(
                                          context.l10n.select(
                                            zh: '删除相册',
                                            en: 'Delete album',
                                          ),
                                        ),
                                      ),
                                    ],
                                    onSelected: (value) async {
                                      if (value == 'edit') {
                                        await edit(album);
                                        return;
                                      }
                                      final approved = await showDialog<bool>(
                                        context: context,
                                        builder: (context) => AlertDialog(
                                          title: Text(
                                            context.l10n.select(
                                              zh: '删除相册？',
                                              en: 'Delete album?',
                                            ),
                                          ),
                                          content: Text(
                                            context.l10n.select(
                                              zh: '将删除相册及其成员关系，不直接删除媒体原件。',
                                              en: 'Deletes the album and its memberships, not media originals.',
                                            ),
                                          ),
                                          actions: [
                                            TextButton(
                                              onPressed: () =>
                                                  Navigator.pop(context, false),
                                              child: Text(
                                                context.l10n.select(
                                                  zh: '取消',
                                                  en: 'Cancel',
                                                ),
                                              ),
                                            ),
                                            FilledButton(
                                              onPressed: () =>
                                                  Navigator.pop(context, true),
                                              child: Text(
                                                context.l10n.select(
                                                  zh: '删除',
                                                  en: 'Delete',
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                      if (approved == true) {
                                        try {
                                          await widget.backend.deleteAlbum(
                                            album.id,
                                          );
                                          reload();
                                        } catch (error) {
                                          if (context.mounted) {
                                            androidMessage(context, error);
                                          }
                                        }
                                      }
                                    },
                                  ),
                            onTap: () => openAlbum(album),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        );
      },
    ),
  );

  Future<void> openAlbum(AlbumSummary album) async {
    final controller = LibraryController(widget.backend, albumId: album.id);
    final route = MaterialPageRoute<void>(
      builder: (_) => AndroidLibraryPage(
        controller: controller,
        settings: widget.settings,
        album: album,
        onBack: () => Navigator.of(context).pop(),
      ),
    );
    try {
      await Navigator.of(context).push(route);
      // The pop future resolves before the exiting page stops rebuilding.
      // Keep its controller alive until the overlay entries are removed.
      await route.completed;
    } finally {
      controller.dispose();
    }
    reload();
  }
}

class _AlbumEntry {
  const _AlbumEntry(this.album, this.cover);
  final AlbumSummary album;
  final MediaAsset? cover;
}
