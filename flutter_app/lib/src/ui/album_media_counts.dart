import 'package:flutter/widgets.dart';

import '../l10n/app_localizations.dart';
import '../rust/models.dart';

String albumMediaCountText(BuildContext context, AlbumSummary album) {
  final imageNoun = album.imageCount == BigInt.one ? 'photo' : 'photos';
  final videoNoun = album.videoCount == BigInt.one ? 'video' : 'videos';
  return context.l10n.select(
    zh: '${album.imageCount} 张图片 · ${album.videoCount} 个视频',
    en: '${album.imageCount} $imageNoun · ${album.videoCount} $videoNoun',
  );
}
